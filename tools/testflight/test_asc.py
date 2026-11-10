#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for tools/testflight/asc.py against an in-process fake App Store Connect, plus the
build_and_sign.sh steps that run on any OS and the shell blocks of the TestFlight workflow.

    python3 tools/testflight/test_asc.py [TestClass[.test_name] ...]

No network and no secrets: a throwaway EC P-256 key signs the JWTs, certificates are issued for
the CSR the way Apple does (by a throwaway CA), and http.server on 127.0.0.1 plays App Store
Connect and Apple's upload storage. The fake behaves like the live API where that differs from
the OpenAPI spec (`limit` refused on bundleIdCapabilities, the transient false 404 of the Build
Upload API reads, duplicate build numbers refused with 409). asc.py runs as a subprocess, exactly
as the workflow runs it, with every wait scaled down (ASC_POLL_SCALE); build_and_sign.sh and the
workflow's `run:` blocks run with /bin/bash (3.2 on macOS). Under GitHub Actions each failing test
is also printed as an ::error annotation (raw job logs are not always readable; annotations are).
"""
import atexit
import base64
import contextlib
import hashlib
import importlib.util
import io
import itertools
import json
import os
import plistlib
import re
import shutil
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

sys.dont_write_bytecode = True   # no __pycache__ next to the sources when asc.py is imported
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ASC_PATH = os.path.join(HERE, "asc.py")
SCRIPT_PATH = os.path.join(HERE, "build_and_sign.sh")
WORKFLOW_PATH = os.path.join(REPO, ".github", "workflows", "testflight.yml")
BASH = "/bin/bash" if os.path.isfile("/bin/bash") else (shutil.which("bash") or "bash")
KEY_ID = "ABC123DEFG"
ISSUER = "69a6de70-1234-47e3-e053-5b8c7c11a4d1"
TEAM = "ABCDE12345"
PREFIX = "com.t"
APP_BID = "com.t.opencfmoto"
MIRROR_BID = "com.t.opencfmoto.mirror"
GROUP = "group.com.t.opencfmoto"
APP_ID = "1234567890"
REPO_ID = "123"           # GITHUB_REPOSITORY_ID of "this repository" in the tests
# GitHub masks every line of a multi-line secret: these exact lines would print as ***.
ARMOR_LINES = ("-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----")


def _load_asc():
    spec = importlib.util.spec_from_file_location("asc", ASC_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


asc = _load_asc()


# ---------------------------------------------------------------- key material and helpers

def openssl(*args, data=None):
    proc = subprocess.run(["openssl", *args], input=data, capture_output=True, timeout=60)
    if proc.returncode != 0:
        raise RuntimeError(f"openssl {' '.join(args)}: {proc.stderr.decode('utf-8', 'replace')}")
    return proc.stdout


class Material:
    """Made once per run: the API key (.p8 = PKCS#8 EC P-256, like Apple's), a CA standing in for
    Apple's and an Apple-like distribution certificate of someone else (team ID in OU)."""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="asc-test-keys-")
        atexit.register(shutil.rmtree, self.dir, True)
        self.p8 = self.path("AuthKey_TEST.p8")
        openssl("genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", self.p8)
        with open(self.p8, encoding="ascii") as fh:
            self.pem = fh.read()
        self.pub = self.path("pub.pem")
        openssl("pkey", "-in", self.p8, "-pubout", "-out", self.pub)
        cert_pem = self.path("apple.pem")
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", self.path("apple.key"),
                "-out", cert_pem, "-days", "2",
                "-subj", f"/UID={TEAM}/CN=Apple Distribution: Test Owner ({TEAM})/OU={TEAM}/O=Test Owner/C=US")
        self.cert_der = openssl("x509", "-in", cert_pem, "-outform", "der")

    def path(self, name):
        return os.path.join(self.dir, name)


KEYS = None


def setUpModule():
    global KEYS
    KEYS = Material()


def b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def raw_to_der(raw):
    """The inverse of asc.der_to_raw_signature: r||s back to DER for `openssl dgst -verify`."""
    def integer(value):
        value = value.lstrip(b"\x00") or b"\x00"
        if value[0] & 0x80:
            value = b"\x00" + value
        return b"\x02" + bytes([len(value)]) + value
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


def verify_jwt(token):
    header, payload, signature = token.split(".")
    raw = b64url_decode(signature)
    if len(raw) != 64:
        return False
    work = tempfile.mkdtemp(prefix="asc-test-verify-")
    try:
        data_path, sig_path = os.path.join(work, "data"), os.path.join(work, "sig.der")
        with open(data_path, "wb") as fh:
            fh.write(f"{header}.{payload}".encode("ascii"))
        with open(sig_path, "wb") as fh:
            fh.write(raw_to_der(raw))
        proc = subprocess.run(["openssl", "dgst", "-sha256", "-verify", KEYS.pub, "-signature",
                               sig_path, data_path], capture_output=True, timeout=60)
        return proc.returncode == 0 and b"Verified OK" in proc.stdout
    finally:
        shutil.rmtree(work, ignore_errors=True)


def jwt_parts(token):
    header, payload, _ = token.split(".")
    return json.loads(b64url_decode(header)), json.loads(b64url_decode(payload))


def decode_command(text):
    for code, char in (("%0A", "\n"), ("%0D", "\r"), ("%3A", ":"), ("%2C", ","), ("%25", "%")):
        text = text.replace(code, char)
    return text


def error_doc(status, code, title, detail=None):
    return {"errors": [{"id": "e1", "status": str(status), "code": code, "title": title,
                        "detail": detail or title}]}


def iso(seconds_ago=0.0):
    """An App Store Connect date, `seconds_ago` before now."""
    return time.strftime("%Y-%m-%dT%H:%M:%S.000+0000", time.gmtime(time.time() - seconds_ago))


def user(uid, mail, roles):
    return {"type": "users", "id": uid,
            "attributes": {"username": mail, "firstName": "Test", "lastName": uid, "roles": roles}}


# The live API's answer for `limit` on a relationship that does not support it (FB25354273).
LIMIT_ILLEGAL = {"errors": [{"id": "e1", "status": "400", "code": "PARAMETER_ERROR.ILLEGAL",
                             "title": "A parameter provided is not allowed for this request",
                             "detail": "The parameter 'limit' can not be used with this request : "
                                       "This relationship does not support this parameter.",
                             "source": {"parameter": "limit"}}]}
# Apple's transient 404 on Build Upload API reads for an app that exists (fastlane#29908).
FALSE_404 = error_doc(404, "NOT_FOUND", "The specified resource does not exist",
                      f"There is no resource of type 'apps' with id '{APP_ID}'")
SERVER_ERROR = error_doc(500, "UNEXPECTED_ERROR", "An unexpected error occurred.")
BAD_GATEWAY = error_doc(502, "BAD_GATEWAY", "Bad Gateway")


# ---------------------------------------------------------------- certificates like Apple's

def der(tag, content):
    length = len(content)
    if length < 0x80:
        head = bytes([length])
    else:
        size = (length.bit_length() + 7) // 8
        head = bytes([0x80 | size]) + length.to_bytes(size, "big")
    return bytes([tag]) + head + content


def der_oid(dotted):
    first, second, *rest = (int(part) for part in dotted.split("."))
    body = bytearray([40 * first + second])
    for value in rest:
        chunk = [value & 0x7F]
        value >>= 7
        while value:
            chunk.append(0x80 | (value & 0x7F))
            value >>= 7
        body += bytes(reversed(chunk))
    return der(0x06, bytes(body))


def der_name(*pairs):
    """An X.501 name: the country as PrintableString, everything else as UTF8String."""
    return der(0x30, b"".join(
        der(0x31, der(0x30, der_oid(oid) + der(0x13 if oid == "2.5.4.6" else 0x0C, value.encode())))
        for oid, value in pairs))


def der_element(data, offset):
    """(start of the content, end) of the DER element at `offset`."""
    length, i = data[offset + 1], offset + 2
    if length & 0x80:
        count = length & 0x7F
        length, i = int.from_bytes(data[i:i + count], "big"), i + count
    return i, i + length


def csr_public_key_info(csr_pem):
    """The SubjectPublicKeyInfo element of a PEM certificate request."""
    data = base64.b64decode("".join(line for line in csr_pem.splitlines()
                                    if line and not line.startswith("-----")))
    request, _ = der_element(data, 0)          # CertificationRequest
    i, _ = der_element(data, request)          # CertificationRequestInfo
    for _ in range(2):                         # version, subject
        i = der_element(data, i)[1]
    return data[i:der_element(data, i)[1]]


def issue_certificate(csr_pem, serial):
    """What Apple does with a CSR: a certificate for the CSR's key with Apple's subject (team ID
    in OU; the CSR's own subject is ignored), signed by the test CA. Built here rather than with
    `openssl x509 -req`, whose options differ between OpenSSL 3 and LibreSSL."""
    algorithm = der(0x30, der_oid("1.2.840.113549.1.1.11") + b"\x05\x00")   # sha256WithRSA

    def utc(when):
        return der(0x17, time.strftime("%y%m%d%H%M%SZ", time.gmtime(when)).encode())

    now = time.time()
    tbs = der(0x30, der(0xA0, der(0x02, b"\x02"))
              + der(0x02, serial.to_bytes(serial.bit_length() // 8 + 1, "big"))
              + algorithm
              + der_name(("2.5.4.3", "Apple Worldwide Developer Relations Certification Authority"),
                         ("2.5.4.11", "G3"), ("2.5.4.10", "Apple Inc."), ("2.5.4.6", "US"))
              + der(0x30, utc(now - 3600) + utc(now + 365 * 86400))
              + der_name(("0.9.2342.19200300.100.1.1", TEAM),
                         ("2.5.4.3", f"Apple Distribution: Test Owner ({TEAM})"),
                         ("2.5.4.11", TEAM), ("2.5.4.10", "Test Owner"), ("2.5.4.6", "US"))
              + csr_public_key_info(csr_pem))
    signature = openssl("dgst", "-sha256", "-sign", KEYS.path("apple.key"), data=tbs)
    return der(0x30, tbs + algorithm + der(0x03, b"\x00" + signature))


def make_csr(directory):
    """key.pem + csr.pem in `directory`, as create-signing leaves them; returns the CSR text."""
    key, csr = os.path.join(directory, "key.pem"), os.path.join(directory, "csr.pem")
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr,
            "-subj", "/CN=OpenCfMoto CI/O=OpenCfMoto/C=US")
    with open(csr, encoding="ascii") as fh:
        return fh.read()


# ---------------------------------------------------------------- fake App Store Connect

class Recorded:
    def __init__(self, method, path, query, headers, body):
        self.method, self.path, self.query, self.headers, self.body = method, path, query, headers, body

    def json(self):
        return json.loads(self.body.decode("utf-8"))


class Fault:
    """An injected answer. `effect`: Apple does the work first, then the answer goes wrong.
    Status 0: no answer at all (the connection closes)."""

    def __init__(self, method, path, status, doc=None, headers=None, times=1, effect=False):
        self.method, self.pattern, self.status = method, re.compile(path), status
        self.doc, self.headers, self.times, self.effect = doc, headers or {}, times, effect


# A .mobileprovision is CMS SignedData around an XML plist: some DER-ish bytes on both sides.
CMS_HEAD = (b"0\x80\x06\t*\x86H\x86\xf7\r\x01\x07\x02\xa0\x800\x80\x02\x01\x011\x0b0\t\x06\x05+"
            b"\x0e\x03\x02\x1a\x05\x000\x80\x06\t*\x86H\x86\xf7\r\x01\x07\x01\xa0\x80$\x80\x04\x82\x10\x00")
CMS_TAIL = b"\x00\x00\x00\x00\xa0\x82\x03\x00" + bytes(range(256))


class FakeASC:
    ROUTES = [
        ("GET", r"/v1/bundleIds", "list_bundle_ids"),
        ("POST", r"/v1/bundleIds", "create_bundle_id"),
        ("GET", r"/v1/bundleIds/([^/]+)/bundleIdCapabilities", "list_caps"),
        ("POST", r"/v1/bundleIdCapabilities", "create_cap"),
        ("GET", r"/v1/apps", "list_apps"),
        ("GET", r"/v1/builds", "list_builds"),
        ("GET", r"/v1/apps/([^/]+)/buildUploads", "list_build_uploads"),
        ("GET", r"/v1/certificates", "list_certs"),
        ("POST", r"/v1/certificates", "create_cert"),
        ("GET", r"/v1/certificates/([^/]+)", "get_cert"),
        ("DELETE", r"/v1/certificates/([^/]+)", "delete_cert"),
        ("GET", r"/v1/profiles", "list_profiles"),
        ("POST", r"/v1/profiles", "create_profile"),
        ("DELETE", r"/v1/profiles/([^/]+)", "delete_profile"),
        ("GET", r"/v1/profiles/([^/]+)/relationships/certificates", "list_profile_cert_links"),
        ("POST", r"/v1/buildUploads", "create_build_upload"),
        ("GET", r"/v1/buildUploads/([^/]+)", "get_build_upload"),
        ("DELETE", r"/v1/buildUploads/([^/]+)", "delete_build_upload"),
        ("POST", r"/v1/buildUploadFiles", "create_upload_file"),
        ("GET", r"/v1/buildUploadFiles/([^/]+)", "get_upload_file"),
        ("PATCH", r"/v1/buildUploadFiles/([^/]+)", "patch_upload_file"),
        ("GET", r"/v1/apps/([^/]+)/betaGroups", "list_groups"),
        ("POST", r"/v1/betaGroups", "create_group"),
        ("POST", r"/v1/betaGroups/([^/]+)/relationships/builds", "link_build"),
        ("GET", r"/v1/betaGroups/([^/]+)/betaTesters", "list_group_testers"),
        ("POST", r"/v1/betaTesters", "create_tester"),
        ("GET", r"/v1/users", "list_users"),
    ]

    def __init__(self):
        self.lock = threading.RLock()
        self.base = ""
        self.next_base = None          # host put in links.next (None: our own)
        self.page_size = 2             # small pages: every list exercises links.next
        self.include_limit = 2         # certificates shown per profile with include=certificates
        self.include_total = "count"   # that linkage's meta.paging.total: "count", "missing", "zero"
        self.requests = []
        self.faults = []
        self.counter = itertools.count(1)
        self.seed_id = TEAM
        self.bundle_ids = []
        self.bundle_list_lag = 0       # listings that do not show a newly registered App ID yet
        self._bundle_lag = {}          # bundle resource id -> listings that still miss it
        self._hidden_bundles = set()
        self.capabilities = {}         # bundle resource id -> [capabilityType]
        self.capability_conflicts = set()
        self.apps = []
        self.builds = []               # (app id, build resource)
        self.beta_details = {}         # build id -> its buildBetaDetails.externalBuildState (None: the
                                       # answer leaves the detail out)
        self.build_script = {}         # version -> processingState per poll (None: not visible)
        self.build_uploads = {}        # id -> {"app", "committed", "scripted", "data": resource}
        self.upload_files = {}         # id -> {"upload": buildUploads id, "data": resource}
        self.part_sizes = None         # None: two equal halves
        self.upload_script = ["PROCESSING", "COMPLETE"]   # states after the commit, one per poll
        self.upload_details = {}       # state -> {"errors": [...], "warnings": [...]}
        self.commit_lag = 0            # file reads that still show a fresh commit as not received
        self.certificates = {}         # id -> {"type": certificateType, "content": DER}
        self.created_certs = []        # ids made by POST /v1/certificates
        self.cert_limit = False        # True (409) or a status: the team is full
        self.cert_list_lag = 0         # listings that do not show new certificates yet
        self._lagging = False
        self.profiles = {}             # id -> {"name", "certs", "type", "content", "uuid", "created"}
        self.assigned_groups = {}      # bundle identifier -> App Groups assigned on the portal
        self.beta_groups = []          # (app id, betaGroups resource)
        self.group_builds = {}
        self.group_testers = {}        # group id -> [e-mail]
        self.tester_conflicts = set()
        self.users = []

    # -- plumbing

    def new_id(self, prefix):
        return f"{prefix}{next(self.counter):04d}"

    def fail(self, method, path, status, doc=None, headers=None, times=1, effect=False):
        self.faults.append(Fault(method, path, status, doc, headers, times, effect))

    def handle(self, h):
        parts = urllib.parse.urlsplit(h.path)
        query = {k: v[-1] for k, v in urllib.parse.parse_qs(parts.query, keep_blank_values=True).items()}
        length = int(h.headers.get("Content-Length") or 0)
        body = h.rfile.read(length) if length else b""
        rec = Recorded(h.command, parts.path, query, {k.lower(): v for k, v in h.headers.items()}, body)
        with self.lock:
            self.requests.append(rec)
            fault = next((f for f in self.faults if f.times > 0 and f.method == h.command
                          and f.pattern.fullmatch(parts.path)), None)
            if fault:
                fault.times -= 1
                if fault.effect:            # Apple did the work; only the answer goes wrong
                    self.dispatch(rec)
                if fault.status == 0:       # no answer at all: the connection just closes
                    return None
                return self.send(h, fault.status, fault.doc, fault.headers)
            if parts.path.startswith("/upload/"):
                return self.send(h, 200)      # Apple's storage: no Authorization expected
            auth = rec.headers.get("authorization", "")
            if not auth.startswith("Bearer ") or auth.count(".") != 2:
                return self.send(h, 401, error_doc(401, "NOT_AUTHORIZED", "Authentication credentials are missing or invalid."))
            status, doc = self.dispatch(rec)
            return self.send(h, status, doc)

    def dispatch(self, rec):
        for method, pattern, name in self.ROUTES:
            match = re.fullmatch(pattern, rec.path)
            if match and method == rec.method:
                return getattr(self, name)(rec, *match.groups())
        return 404, error_doc(404, "NOT_FOUND", f"no route {rec.method} {rec.path}")

    @staticmethod
    def send(h, status, doc=None, headers=None):
        """`doc`: a JSON document, or bytes sent as they are (a page from a proxy, say)."""
        raw = isinstance(doc, bytes)
        payload = b"" if doc is None else doc if raw else json.dumps(doc).encode("utf-8")
        h.send_response(status)
        for key, value in (headers or {}).items():
            h.send_header(key, value)
        if payload:
            h.send_header("Content-Type", "text/html" if raw else "application/json")
        h.send_header("Content-Length", str(len(payload)))
        h.end_headers()
        if payload:
            h.wfile.write(payload)

    def page(self, rec, items):
        start = int(rec.query.get("cursor") or 0)
        limit = min(int(rec.query.get("limit") or 50), self.page_size)
        doc = {"data": items[start:start + limit], "links": {"self": self.base + rec.path},
               "meta": {"paging": {"total": len(items), "limit": limit}}}
        if start + limit < len(items):
            query = dict(rec.query, cursor=str(start + limit))
            doc["links"]["next"] = (self.next_base or self.base) + rec.path + "?" + urllib.parse.urlencode(query)
        return 200, doc

    # -- seeding helpers

    def add_bundle(self, identifier, platform="IOS"):
        bundle = {"type": "bundleIds", "id": self.new_id("B"),
                  "attributes": {"identifier": identifier, "name": "Existing", "platform": platform,
                                 "seedId": self.seed_id}}
        self.bundle_ids.append(bundle)
        return bundle

    def bundle(self, identifier):
        return next(b for b in self.bundle_ids if b["attributes"]["identifier"] == identifier)

    def add_app(self, bundle_id, app_id):
        self.apps.append({"type": "apps", "id": app_id,
                          "attributes": {"bundleId": bundle_id, "name": "OpenCfMoto", "sku": "opencfmoto"}})

    def add_build(self, app, version, state="VALID", expired=False, external="READY_FOR_BETA_SUBMISSION"):
        """`external`: its TestFlight state (buildBetaDetails.externalBuildState); None: the build
        beta detail is missing from the answers."""
        build = {"type": "builds", "id": self.new_id("BLD"),
                 "attributes": {"version": version, "processingState": state, "expired": expired,
                                "uploadedDate": "2026-11-01T10:00:00Z"}}
        self.builds.append((app, build))
        self.beta_details[build["id"]] = external
        return build

    def add_upload(self, app, version, state="COMPLETE", errors=None, created="2026-11-01T10:00:00Z"):
        """A build upload that already reached Apple (REST or altool)."""
        upload_id = self.new_id("U")
        self.build_uploads[upload_id] = {"app": app, "committed": True, "scripted": False, "data": {
            "type": "buildUploads", "id": upload_id,
            "attributes": {"cfBundleVersion": version, "cfBundleShortVersionString": "2.3.4",
                           "platform": "IOS", "createdDate": created,
                           "state": {"state": state, "errors": errors or [], "warnings": [], "infos": []}}}}
        return upload_id

    def add_cert(self, content, kind="DISTRIBUTION"):
        cert_id = self.new_id("C")
        self.certificates[cert_id] = {"type": kind, "content": content}
        return cert_id

    def issue(self, csr_pem):
        """A certificate Apple made from this CSR (as if POST /v1/certificates had run)."""
        cert_id = self.add_cert(issue_certificate(csr_pem, 0x1000 + len(self.certificates)))
        self.created_certs.append(cert_id)
        return cert_id

    def add_profile(self, name, certs, kind="IOS_APP_STORE", created=None):
        """`created`: its createdDate (default: just now)."""
        profile_id = self.new_id("P")
        self.profiles[profile_id] = {"name": name, "certs": list(certs), "type": kind,
                                     "content": b"", "uuid": "", "created": iso() if created is None else created}
        return profile_id

    def add_group(self, app, name, internal, all_builds):
        group = {"type": "betaGroups", "id": self.new_id("G"),
                 "attributes": {"name": name, "isInternalGroup": internal,
                                "hasAccessToAllBuilds": all_builds}}
        self.beta_groups.append((app, group))
        return group

    # -- routes: App IDs and the app record

    def list_bundle_ids(self, rec):
        ident = rec.query.get("filter[identifier]", "")
        platform = rec.query.get("filter[platform]")
        if "cursor" not in rec.query:            # a new listing: may still miss a new App ID
            self._hidden_bundles = {b for b, left in self._bundle_lag.items() if left > 0}
            for bundle_id in self._hidden_bundles:
                self._bundle_lag[bundle_id] -= 1
        # Like Apple, filter[identifier] matches substrings: X also returns X.mirror.
        items = [b for b in self.bundle_ids if ident in b["attributes"]["identifier"]
                 and b["id"] not in self._hidden_bundles
                 and (platform is None or b["attributes"]["platform"] == platform)]
        return self.page(rec, items)

    def create_bundle_id(self, rec):
        attributes = rec.json()["data"]["attributes"]
        if any(b["attributes"]["identifier"] == attributes["identifier"] for b in self.bundle_ids):
            return 409, error_doc(409, "ENTITY_ERROR.ATTRIBUTE.INVALID", "An attribute value is invalid.",
                                  "An App ID with Identifier is not available.")
        bundle = {"type": "bundleIds", "id": self.new_id("B"),
                  "attributes": dict(attributes, seedId=self.seed_id)}
        self.bundle_ids.append(bundle)
        self._bundle_lag[bundle["id"]] = self.bundle_list_lag
        return 201, {"data": bundle}

    def list_caps(self, rec, bundle_id):
        if "limit" in rec.query:       # live behaviour, although the OpenAPI spec lists `limit`
            return 400, LIMIT_ILLEGAL
        items = [{"type": "bundleIdCapabilities", "id": f"{bundle_id}_{c}",
                  "attributes": {"capabilityType": c}} for c in self.capabilities.get(bundle_id, [])]
        return self.page(rec, items)

    def create_cap(self, rec):
        data = rec.json()["data"]
        bundle_id = data["relationships"]["bundleId"]["data"]["id"]
        capability = data["attributes"]["capabilityType"]
        caps = self.capabilities.setdefault(bundle_id, [])
        if capability in caps or capability in self.capability_conflicts:
            if capability not in caps:
                caps.append(capability)
            return 409, error_doc(409, "ENTITY_ERROR.RELATIONSHIP.INVALID", "The capability is already enabled.")
        caps.append(capability)
        return 201, {"data": {"type": "bundleIdCapabilities", "id": f"{bundle_id}_{capability}",
                              "attributes": {"capabilityType": capability}}}

    def list_apps(self, rec):
        bundle_id = rec.query.get("filter[bundleId]", "")
        return self.page(rec, [a for a in self.apps if bundle_id in a["attributes"]["bundleId"]])

    # -- routes: builds and build uploads

    def list_builds(self, rec):
        app, version = rec.query.get("filter[app]"), rec.query.get("filter[version]")
        if version is not None and version in self.build_script:
            script = self.build_script[version]
            state = script.pop(0) if len(script) > 1 else script[0]
            if state is not None:
                build = next((b for a, b in self.builds if a == app and b["attributes"]["version"] == version), None)
                build = build or self.add_build(app, version, state)
                build["attributes"]["processingState"] = state
        items = [b for a, b in self.builds if app is None or a == app]
        if version is not None:   # loose on purpose: "7" also returns "17"
            items = [b for b in items if version in b["attributes"]["version"]]
        status, doc = self.page(rec, items)
        if "buildBetaDetail" in (rec.query.get("include") or "").split(","):
            # Like Apple: every build has one build beta detail; the page's come in `included`.
            doc["data"] = [dict(b, relationships={"buildBetaDetail": {"data": {
                "type": "buildBetaDetails", "id": f"D{b['id']}"}}}) for b in doc["data"]]
            doc["included"] = [
                {"type": "buildBetaDetails", "id": f"D{b['id']}",
                 "attributes": {"autoNotifyEnabled": False, "internalBuildState": "IN_BETA_TESTING",
                                "externalBuildState": self.beta_details.get(b["id"])}}
                for b in doc["data"] if self.beta_details.get(b["id"], "READY_FOR_BETA_SUBMISSION") is not None]
        return status, doc

    def list_build_uploads(self, rec, app):
        return self.page(rec, [u["data"] for u in self.build_uploads.values() if u["app"] == app])

    def create_build_upload(self, rec):
        data = rec.json()["data"]
        app = data["relationships"]["app"]["data"]["id"]
        version = data["attributes"]["cfBundleVersion"]
        used = [u for u in self.build_uploads.values() if u["app"] == app
                and u["data"]["attributes"]["cfBundleVersion"] == version
                and u["data"]["attributes"]["state"]["state"] != "AWAITING_UPLOAD"]
        used += [b for a, b in self.builds if a == app and b["attributes"]["version"] == version]
        if used:   # what App Store Connect (and so altool) answers for a build number already used
            return 409, {"errors": [{
                "id": "e1", "status": "409", "code": "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE",
                "title": "The provided entity includes an attribute with a value that has already been used",
                "detail": "The bundle version must be higher than the previously uploaded version.",
                "source": {"pointer": "/data/attributes/cfBundleVersion"}}]}
        upload = {"type": "buildUploads", "id": self.new_id("U"),
                  "attributes": dict(data["attributes"], createdDate="2026-11-01T12:00:00Z",
                                     state={"state": "AWAITING_UPLOAD", "errors": [], "warnings": [], "infos": []})}
        self.build_uploads[upload["id"]] = {"app": app, "committed": False, "scripted": True, "data": upload}
        return 201, {"data": upload}

    def get_build_upload(self, rec, upload_id):
        entry = self.build_uploads.get(upload_id)
        if entry is None:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist",
                                  f"There is no resource of type 'buildUploads' with id '{upload_id}'")
        upload = entry["data"]
        if entry["scripted"] and entry["committed"] and not self.commit_lag:   # else AWAITING_UPLOAD
            state = self.upload_script.pop(0) if len(self.upload_script) > 1 else self.upload_script[0]
            details = self.upload_details.get(state, {})
            upload["attributes"]["state"] = {"state": state, "errors": details.get("errors", []),
                                             "warnings": details.get("warnings", []), "infos": []}
        return 200, {"data": upload}

    def delete_build_upload(self, rec, upload_id):
        if self.build_uploads.pop(upload_id, None) is None:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
        return 204, None

    def create_upload_file(self, rec):
        data = rec.json()["data"]
        file_id, size = self.new_id("F"), data["attributes"]["fileSize"]
        sizes = self.part_sizes or [size - size // 2, size // 2]
        operations, offset = [], 0
        for number, length in enumerate(sizes, 1):
            operations.append({"method": "PUT", "url": f"{self.base}/upload/{file_id}/part{number}?X-Signature=s{number}",
                               "length": length, "offset": offset, "partNumber": number,
                               "expiration": "2030-01-01T00:00:00Z",
                               "requestHeaders": [{"name": "Content-Type", "value": "application/octet-stream"},
                                                  {"name": "X-Apple-Part", "value": str(number)}]})
            offset += length
        upload_file = {"type": "buildUploadFiles", "id": file_id,
                       "attributes": dict(data["attributes"], uploadOperations=operations,
                                          assetDeliveryState={"state": "AWAITING_UPLOAD"})}
        self.upload_files[file_id] = {"upload": data["relationships"]["buildUpload"]["data"]["id"],
                                      "data": upload_file}
        return 201, {"data": upload_file}

    def get_upload_file(self, rec, file_id):
        entry = self.upload_files.get(file_id)
        if entry is None:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
        data = entry["data"]
        if self.commit_lag > 0:        # just after a commit Apple can still say AWAITING_UPLOAD
            self.commit_lag -= 1
            data = dict(data, attributes=dict(data["attributes"], assetDeliveryState={"state": "AWAITING_UPLOAD"}))
        return 200, {"data": data}

    def patch_upload_file(self, rec, file_id):
        entry = self.upload_files.get(file_id)
        if entry is None:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
        entry["data"]["attributes"]["assetDeliveryState"] = {"state": "UPLOAD_COMPLETE"}
        upload = self.build_uploads.get(entry["upload"])
        if upload is not None:
            upload["committed"] = True
        return 200, {"data": entry["data"]}

    # -- routes: certificates and profiles

    def cert_resource(self, cert_id):
        info = self.certificates[cert_id]
        return {"type": "certificates", "id": cert_id,
                "attributes": {"certificateType": info.get("type", "DISTRIBUTION"),
                               "certificateContent": base64.b64encode(info.get("content", b"")).decode("ascii"),
                               "name": "Apple Distribution: Test Owner", "displayName": "Test Owner",
                               "platform": "IOS", "serialNumber": cert_id,
                               "expirationDate": "2027-11-01T10:00:00.000+0000"}}

    def list_certs(self, rec):
        if "cursor" not in rec.query:            # a new listing, not a further page
            self._lagging = self.cert_list_lag > 0
            self.cert_list_lag = max(0, self.cert_list_lag - 1)
        hidden = set(self.created_certs) if self._lagging else set()
        wanted = rec.query.get("filter[certificateType]")
        items = [self.cert_resource(c) for c, info in self.certificates.items() if c not in hidden
                 and (wanted is None or info.get("type", "DISTRIBUTION") in wanted.split(","))]
        return self.page(rec, items)

    def get_cert(self, rec, cert_id):
        if cert_id not in self.certificates:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
        return 200, {"data": self.cert_resource(cert_id)}

    def create_cert(self, rec):
        if self.cert_limit:
            status = 409 if self.cert_limit is True else self.cert_limit
            return status, error_doc(status, "ENTITY_ERROR.ATTRIBUTE.INVALID",
                                     "There is a problem with the request entity",
                                     "You already have a current Distribution certificate or a pending certificate request.")
        attributes = rec.json()["data"]["attributes"]
        cert_id = self.add_cert(issue_certificate(attributes["csrContent"], 0x1000 + len(self.certificates)),
                                attributes["certificateType"])
        self.created_certs.append(cert_id)
        return 201, {"data": self.cert_resource(cert_id)}

    def delete_cert(self, rec, cert_id):
        if self.certificates.pop(cert_id, None) is None:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
        return 204, None

    def profile_resource(self, profile_id, with_certs):
        info = self.profiles[profile_id]
        certs = list(info.get("certs") or [])
        relation = {"links": {"self": f"{self.base}/v1/profiles/{profile_id}/relationships/certificates"}}
        if with_certs:   # include=certificates shows only the first few; `total` is optional
            relation["data"] = [{"type": "certificates", "id": c} for c in certs[:self.include_limit]]
            paging = {"limit": self.include_limit}
            if self.include_total != "missing":
                paging["total"] = len(certs) if self.include_total == "count" else 0
            relation["meta"] = {"paging": paging}
        return {"type": "profiles", "id": profile_id,
                "attributes": {"name": info.get("name", ""), "profileType": info.get("type", "IOS_APP_STORE"),
                               "profileState": "ACTIVE", "platform": "IOS", "uuid": info.get("uuid", ""),
                               "createdDate": info.get("created", ""),
                               "profileContent": base64.b64encode(info.get("content", b"")).decode("ascii")},
                "relationships": {"certificates": relation}}

    def list_profiles(self, rec):
        name = rec.query.get("filter[name]")
        with_certs = "certificates" in (rec.query.get("include") or "").split(",")
        items = [self.profile_resource(p, with_certs) for p, info in self.profiles.items()
                 if name is None or name in info.get("name", "")]   # not exact, on purpose
        status, doc = self.page(rec, items)
        if with_certs:
            shown = []
            for item in doc["data"]:
                shown += [c["id"] for c in item["relationships"]["certificates"]["data"] if c["id"] not in shown]
            doc["included"] = [self.cert_resource(c) for c in shown if c in self.certificates]
        return status, doc

    def list_profile_cert_links(self, rec, profile_id):
        if "limit" in rec.query:       # unknown live behaviour: refuse it as on bundleIdCapabilities
            return 400, LIMIT_ILLEGAL
        if profile_id not in self.profiles:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
        return self.page(rec, [{"type": "certificates", "id": c}
                               for c in self.profiles[profile_id].get("certs") or []])

    def create_profile(self, rec):
        data = rec.json()["data"]
        name = data["attributes"]["name"]
        if any(info.get("name") == name for info in self.profiles.values()):   # names are unique
            return 409, error_doc(409, "ENTITY_ERROR.ATTRIBUTE.INVALID", "An attribute value is invalid.",
                                  f"Multiple profiles found with the name '{name}'.")
        bundle = next(b for b in self.bundle_ids if b["id"] == data["relationships"]["bundleId"]["data"]["id"])
        identifier = bundle["attributes"]["identifier"]
        caps = self.capabilities.get(bundle["id"], [])
        ents = {"application-identifier": f"{self.seed_id}.{identifier}",
                "com.apple.developer.team-identifier": self.seed_id, "beta-reports-active": True,
                "get-task-allow": False, "keychain-access-groups": [f"{self.seed_id}.*"]}
        if "APP_GROUPS" in caps and self.assigned_groups.get(identifier):
            ents["com.apple.security.application-groups"] = list(self.assigned_groups[identifier])
        if "HOT_SPOT" in caps:
            ents["com.apple.developer.networking.HotspotConfiguration"] = True
        if "ACCESS_WIFI_INFORMATION" in caps:
            ents["com.apple.developer.networking.wifi-info"] = True
        profile_id = self.new_id("P")
        uuid = "%08x-0000-4000-8000-%012x" % (next(self.counter), next(self.counter))
        plist = plistlib.dumps({"AppIDName": bundle["attributes"]["name"], "Entitlements": ents,
                                "Name": name, "TeamIdentifier": [self.seed_id], "UUID": uuid})
        self.profiles[profile_id] = {"name": name, "type": data["attributes"]["profileType"],
                                     "certs": [c["id"] for c in data["relationships"]["certificates"]["data"]],
                                     "content": CMS_HEAD + plist + CMS_TAIL, "uuid": uuid,
                                     "bundle": bundle["id"], "created": iso()}
        return 201, {"data": self.profile_resource(profile_id, False)}

    def delete_profile(self, rec, profile_id):
        if self.profiles.pop(profile_id, None) is None:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
        return 204, None

    # -- routes: TestFlight

    def list_groups(self, rec, app):
        return self.page(rec, [g for a, g in self.beta_groups if a == app])

    def create_group(self, rec):
        data = rec.json()["data"]
        group = {"type": "betaGroups", "id": self.new_id("G"), "attributes": dict(data["attributes"])}
        self.beta_groups.append((data["relationships"]["app"]["data"]["id"], group))
        return 201, {"data": group}

    def link_build(self, rec, group_id):
        self.group_builds.setdefault(group_id, []).extend(item["id"] for item in rec.json()["data"])
        return 204, None

    def list_group_testers(self, rec, group_id):
        items = [{"type": "betaTesters", "id": f"T{i}", "attributes": {"email": mail}}
                 for i, mail in enumerate(self.group_testers.get(group_id, []))]
        return self.page(rec, items)

    def create_tester(self, rec):
        data = rec.json()["data"]
        mail = data["attributes"]["email"]
        groups = [g["id"] for g in data["relationships"]["betaGroups"]["data"]]
        if mail in self.tester_conflicts or any(mail in self.group_testers.get(g, []) for g in groups):
            return 409, error_doc(409, "ENTITY_ERROR", "The tester already exists.")
        for group in groups:
            self.group_testers.setdefault(group, []).append(mail)
        return 201, {"data": {"type": "betaTesters", "id": self.new_id("T"), "attributes": data["attributes"]}}

    def list_users(self, rec):
        return self.page(rec, self.users)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _dispatch(self):
        self.server.fake.handle(self)

    do_GET = do_POST = do_PATCH = do_DELETE = do_PUT = _dispatch


class OtherHost:
    """Another web server: records whatever reaches it (nothing should, with the token)."""

    def __init__(self):
        self.requests = []
        seen = self.requests

        class Recorder(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _record(self):
                seen.append({k.lower(): v for k, v in self.headers.items()})
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", "11")
                self.end_headers()
                self.wfile.write(b'{"data":[]}')

            do_GET = do_POST = do_PATCH = do_DELETE = _record

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05},
                                       daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:%d/collect" % self.server.server_address[1]

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)


class UntrustedTls:
    """A TLS server on 127.0.0.1 whose certificate no client trusts (self-signed), like Apple's
    upload storage seen through a proxy that intercepts TLS: each connection gets its handshake
    and nothing more."""

    def __init__(self):
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(KEYS.path("apple.pem"), KEYS.path("apple.key"))
        self.connections, self.stop = 0, threading.Event()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.sock.settimeout(0.1)
        self.port = self.sock.getsockname()[1]
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except OSError:                     # the accept timeout: look at self.stop again
                continue
            self.connections += 1
            conn.settimeout(10)
            try:
                with self.context.wrap_socket(conn, server_side=True):
                    pass
            except OSError:                     # the client refused the certificate
                pass
            finally:
                conn.close()

    def close(self):
        self.stop.set()
        self.thread.join(5)
        self.sock.close()


# ---------------------------------------------------------------- test base

class AscTest(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.fake = FakeASC()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server.fake = self.fake
        self.fake.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05},
                                       daemon=True)
        self.thread.start()
        self.tmp = tempfile.mkdtemp(prefix="asc-test-")
        self.github_output = os.path.join(self.tmp, "github_output")
        self.step_summary = os.path.join(self.tmp, "step_summary")
        for path in (self.github_output, self.step_summary):
            open(path, "w").close()
        self.project_yml = os.path.join(self.tmp, "project.yml")
        with open(self.project_yml, "w", encoding="utf-8") as fh:
            fh.write('settings:\n  base:\n    MARKETING_VERSION: "2.3.4"\n    CURRENT_PROJECT_VERSION: "1"\n')

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def asc_env(self, env=None):
        full_env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.tmp,
                    "LANG": "C.UTF-8", "PYTHONIOENCODING": "utf-8",
                    "ASC_KEY_ID": KEY_ID, "ASC_ISSUER_ID": ISSUER, "ASC_PRIVATE_KEY": KEYS.pem,
                    "ASC_API_BASE": self.fake.base, "ASC_POLL_SCALE": "0.001",
                    "GITHUB_ACTIONS": "true", "GITHUB_OUTPUT": self.github_output,
                    "GITHUB_STEP_SUMMARY": self.step_summary, "GITHUB_REPOSITORY_ID": REPO_ID}
        for key, value in (env or {}).items():
            if value is None:
                full_env.pop(key, None)
            else:
                full_env[key] = value
        return full_env

    def run_asc(self, *args, expect=0, env=None):
        proc = subprocess.run([sys.executable, ASC_PATH, *args], env=self.asc_env(env), capture_output=True,
                              encoding="utf-8", errors="replace", timeout=120)
        if expect is not None:
            self.assertEqual(proc.returncode, expect,
                             f"asc.py {' '.join(args)} exited {proc.returncode}\n{self.transcript(proc)}")
        return proc

    def run_in_process(self, *args, env=None):
        """asc.main() in this process (to spy on it); returns (exit code, output)."""
        out = io.StringIO()
        with mock.patch.dict(os.environ, self.asc_env(env), clear=True), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = asc.main(list(args))
        return code, out.getvalue()

    @staticmethod
    def transcript(proc):
        text = (proc.stdout or "") + (f"\n[stderr]\n{proc.stderr}" if proc.stderr else "")
        # "| " so that a printed failure never turns into a workflow command in CI.
        return "\n".join("    | " + line for line in text.splitlines()[-80:])

    def outputs(self):
        result = {}
        with open(self.github_output, encoding="utf-8") as fh:
            for line in fh:
                key, _, value = line.rstrip("\n").partition("=")
                result[key] = value
        return result

    def summary(self):
        with open(self.step_summary, encoding="utf-8") as fh:
            return fh.read()

    def calls(self, method=None, path=None):
        return [r for r in self.fake.requests if (method is None or r.method == method)
                and (path is None or re.fullmatch(path, r.path))]

    @staticmethod
    def annotations(proc, level):
        found = []
        for line in proc.stdout.splitlines():
            match = re.match(rf"::{level} title=([^:]*)::(.*)$", line)
            if match:
                found.append((decode_command(match.group(1)), decode_command(match.group(2))))
        return found

    def annotation(self, proc, level):
        found = self.annotations(proc, level)
        self.assertTrue(found, f"no ::{level} annotation\n{self.transcript(proc)}")
        return found[-1]

    def assert_new_run_advice(self, message):
        """Retry advice says how: a new run (a re-run repeats the old commit)."""
        for needle in ("Actions ▸ TestFlight ▸ Run workflow", "ejecución nueva", "new run", "Re-run"):
            self.assertIn(needle, message)


# ---------------------------------------------------------------- JWT and key handling

class JwtTest(unittest.TestCase):
    def test_der_to_raw_signature(self):
        cases = [bytes([0x80] + [1] * 31) + bytes([0x7F] + [2] * 31),   # high bit: DER pads 0x00
                 bytes(31) + b"\x05" + bytes([0xFF] * 32),               # small r: DER drops zeros
                 bytes([0x01] * 64)]
        for raw in cases:
            self.assertEqual(asc.der_to_raw_signature(raw_to_der(raw)), raw)
        good = raw_to_der(cases[0])
        for bad in (b"", b"\x31\x00", good[:-1], good + b"\x00", b"\x30\x06\x02\x01\x01\x04\x01\x01",
                    b"\x30\x25\x02\x21" + b"\x01" * 33 + b"\x02\x00"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                asc.der_to_raw_signature(bad)

    def test_jwt_structure_and_openssl_verification(self):
        token, exp = asc.make_jwt(KEY_ID, ISSUER, KEYS.pem, now=1_700_000_000)
        parts = token.split(".")
        self.assertEqual(len(parts), 3)
        self.assertNotIn("=", token)
        header, payload = jwt_parts(token)
        self.assertEqual(header, {"alg": "ES256", "kid": KEY_ID, "typ": "JWT"})
        self.assertEqual(payload["iss"], ISSUER)
        self.assertEqual(payload["aud"], "appstoreconnect-v1")
        self.assertEqual(payload["iat"], 1_700_000_000)
        self.assertEqual(payload["exp"], exp)
        self.assertTrue(0 < payload["exp"] - payload["iat"] <= 1200)
        self.assertEqual(len(b64url_decode(parts[2])), 64)          # raw r||s, not DER
        self.assertTrue(verify_jwt(token))
        forged = dict(payload, iss="someone-else")
        self.assertFalse(verify_jwt(f"{parts[0]}.{b64url(json.dumps(forged).encode())}.{parts[2]}"))

    def test_private_key_paste_variants(self):
        canonical = asc.normalize_private_key(KEYS.pem)
        self.assertEqual(canonical, KEYS.pem)
        lines = KEYS.pem.strip().splitlines()
        body = "".join(lines[1:-1])
        variants = {
            "crlf": KEYS.pem.replace("\n", "\r\n"),
            "spaces and blank lines": "  \n" + "\n".join(f"  {line}  " for line in lines) + "\n\n  ",
            "one line": lines[0] + body + lines[-1],
            "one line, spaces": " ".join(lines),
            "literal backslash-n": "\\n".join(lines),
            "quoted, literal backslash-n": '"' + "\\n".join(lines) + '\\n"',
            "wrapped at 76": "\n".join([lines[0]] + [body[i:i + 76] for i in range(0, len(body), 76)] + [lines[-1]]),
            "body only": body,
            "the file base64-encoded": base64.b64encode(KEYS.pem.encode("ascii")).decode("ascii"),
        }
        for name, text in variants.items():
            with self.subTest(name):
                self.assertEqual(asc.normalize_private_key(text), canonical)
        token, _ = asc.make_jwt(KEY_ID, ISSUER, asc.normalize_private_key(variants["one line"]))
        self.assertTrue(verify_jwt(token))
        for bad in ("", "hello", "-----BEGIN PRIVATE KEY-----\nAAAA",
                    "-----BEGIN PRIVATE KEY-----\n!!!!\n-----END PRIVATE KEY-----"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                asc.normalize_private_key(bad)

    def test_team_from_subject_both_openssl_flavours(self):
        self.assertEqual(asc.team_from_subject(
            f"subject=UID = {TEAM}, CN = Apple Distribution: Test Owner ({TEAM}), OU = {TEAM}, O = Test Owner, C = US"), TEAM)
        self.assertEqual(asc.team_from_subject(
            f"subject= /UID={TEAM}/CN=Apple Distribution: Test Owner ({TEAM})/OU={TEAM}/O=Test Owner/C=US"), TEAM)
        self.assertEqual(asc.team_from_subject("subject=CN = x, O = Org"), "")

    def test_team_from_the_subject_printed_by_this_openssl(self):
        # The real output of whichever openssl is first on PATH (LibreSSL in the macOS CI job).
        subject = openssl("x509", "-noout", "-subject", "-in", KEYS.path("apple.pem")).decode("utf-8")
        self.assertEqual(asc.team_from_subject(subject), TEAM, subject)

    def test_profile_plist_and_retry_delay(self):
        plist = plistlib.dumps({"UUID": "u", "Entitlements": {"a": True}})
        self.assertEqual(asc.profile_plist(CMS_HEAD + plist + CMS_TAIL)["UUID"], "u")
        with self.assertRaises(ValueError):
            asc.profile_plist(CMS_HEAD + CMS_TAIL)
        self.assertEqual(asc.retry_delay(0, "7"), 7.0)
        self.assertEqual(asc.retry_delay(3), 16.0)
        self.assertEqual(asc.retry_delay(10), 60.0)
        self.assertEqual(asc.retry_delay(0, "100000"), 300.0)

    def test_public_key_of_a_key_its_csr_and_its_certificate_agree(self):
        # The reconciliation compares these three with this openssl (LibreSSL in the macOS job).
        work = tempfile.mkdtemp(prefix="asc-test-pub-")
        self.addCleanup(shutil.rmtree, work, True)
        csr = make_csr(work)
        from_key = asc.public_key_of(os.path.join(work, "key.pem"))
        self.assertTrue(from_key)
        self.assertEqual(asc.public_key_of(os.path.join(work, "csr.pem")), from_key)
        cert = issue_certificate(csr, 0x1234)
        printed = openssl("x509", "-inform", "der", "-noout", "-pubkey", data=cert)
        self.assertEqual(asc._pem_public_key(printed), from_key)
        subject = openssl("x509", "-inform", "der", "-noout", "-subject", data=cert).decode("utf-8")
        self.assertEqual(asc.team_from_subject(subject), TEAM, subject)
        self.assertNotEqual(asc._pem_public_key(openssl("x509", "-inform", "der", "-noout", "-pubkey",
                                                        data=KEYS.cert_der)), from_key)

    def test_which_answers_are_unclear_and_which_409_means_a_used_build_number(self):
        def err(status, **error):
            return asc.ApiError("POST", "/v1/x", status, [error] if error else [])
        for status in (0, 408, 500, 502, 503, 504, 201):        # 201: success with a lost body
            self.assertTrue(err(status).ambiguous, status)
        for status in (400, 401, 403, 404, 409, 422, 429):
            self.assertFalse(err(status).ambiguous, status)
        duplicate = [err(409, code="ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE"),
                     err(409, code="ENTITY_ERROR", source={"pointer": "/data/attributes/cfBundleVersion"}),
                     err(409, detail="The bundle version must be higher than the previously uploaded version.")]
        for item in duplicate:
            self.assertTrue(asc.is_duplicate_build(item), item.errors)
        for item in (err(409, code="ENTITY_ERROR.RELATIONSHIP.INVALID", detail="app not available"),
                     err(422, code="ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE")):
            self.assertFalse(asc.is_duplicate_build(item), item.errors)
        self.assertTrue(err(404, detail="There is no resource of type 'apps' with id '1'").false_404)
        self.assertFalse(err(404, detail="There is no resource of type 'buildUploads' with id '1'").false_404)

    def test_408_is_explained_like_a_network_error(self):
        failure = asc.explain(asc.ApiError("POST", "/v1/certificates", 408, [{"code": "REQUEST_TIMEOUT"}]))
        self.assertEqual(failure.title, "Error de red / Network error")
        self.assertIn("HTTP 408", failure.es)
        self.assertIn("ejecución nueva", failure.es)

    def test_manual_steps_name_what_the_portal_shows_ids_only_in_parentheses(self):
        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY_ID": "123", "GITHUB_RUN_ID": "4242",
                                          "BUILD_NUMBER": ""}):
            es, en = asc.manual_revoke(["C1"], ["P1", "P2"])
        for needle in ("el certificado «Apple Distribution» creado hoy (id C1), púlsalo ▸ Revoke",
                       "los perfiles «OpenCfMoto CI r123-4242-… app» y «OpenCfMoto CI r123-4242-… mirror» que "
                       "queden (ids P1, P2), cada uno ▸ Remove (ningún otro «OpenCfMoto CI …»)",
                       asc.URL_CERTIFICATES, asc.URL_PROFILES):
            self.assertIn(needle, es)
        for needle in ("the «Apple Distribution» certificate created today (id C1), click it ▸ Revoke",
                       "the «OpenCfMoto CI r123-4242-… app» and «OpenCfMoto CI r123-4242-… mirror» profiles "
                       "that are left (ids P1, P2), each ▸ Remove (no other «OpenCfMoto CI …» one)"):
            self.assertIn(needle, en)
        es, en = asc.manual_revoke()
        self.assertIn("el certificado «Apple Distribution» creado hoy, púlsalo", es)
        self.assertNotIn("(id", es + en)
        self.assertIn("los certificados «Apple Distribution» creados hoy (ids C1, C2)",
                      asc.manual_revoke(["C1", "C2"])[0])
        # The build number in the names: the finish job's BUILD_NUMBER, or what the teardown recorded.
        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY_ID": "123", "GITHUB_RUN_ID": "4242",
                                          "BUILD_NUMBER": "7"}):
            self.assertIn("«OpenCfMoto CI r123-4242-… b7 app» y «OpenCfMoto CI r123-4242-… b7 mirror»",
                          asc.manual_revoke(["C1"], ["P1"])[0])
            self.assertIn("«OpenCfMoto CI r123-4242-1 b8 app»", asc.manual_revoke(suffix="r123-4242-1", build="8")[0])
            self.assertIn("«OpenCfMoto CI r123-4242-1 app»", asc.manual_revoke(suffix="r123-4242-1", build="")[0])

    def test_manual_steps_never_send_the_owner_after_the_kept_certificate(self):
        # Another run's set (the latest accepted build's) can hold a certificate «created today» too:
        # whenever the steps say «revoke a certificate», they also say which one must stay.
        for es, en in (asc.manual_revoke(["C1"]), asc.manual_revoke(), asc.manual_revoke(["C1"], ["P1"])):
            self.assertIn(asc.KEPT_CAUTION_ES, es)
            self.assertIn(asc.KEPT_CAUTION_EN, en)
        for needle in ("«OpenCfMoto CI … bN app» y «… bN mirror»", "«Invalid Binary» (ITMS-90035)", "de otra ejecución",
                       "con N el número de esa build"):
            self.assertIn(needle, asc.KEPT_CAUTION_ES)
        es, en = asc.manual_revoke([], ["P1"], certs=False)          # only profiles: no certificate at all
        self.assertNotIn(asc.KEPT_CAUTION_ES, es)
        self.assertNotIn(asc.KEPT_CAUTION_EN, en)

    def test_manual_steps_name_only_this_runs_profiles(self):
        # The leftover sweep keeps another repository's or a Mac's «OpenCfMoto CI …» profiles for
        # 12 hours (that run may still be building): the manual steps never send the owner after
        # every profile named like that, only after this run's.
        es, en = asc.manual_revoke(["C1"], ["P1"], suffix="r123-4242-1")
        self.assertIn("«OpenCfMoto CI r123-4242-1 app» y «OpenCfMoto CI r123-4242-1 mirror» que queden (id P1)", es)
        self.assertIn("«OpenCfMoto CI r123-4242-1 app» and «OpenCfMoto CI r123-4242-1 mirror» profiles", en)
        for env, label in (({"GITHUB_RUN_ID": "4242"}, "4242-…"), ({}, "…")):      # no repository id; a Mac
            with mock.patch.dict(os.environ, env, clear=True):
                self.assertIn(f"«OpenCfMoto CI {label} app» y «OpenCfMoto CI {label} mirror»", asc.manual_revoke()[0])
        # Only what can be left: the certificate went (profiles only), or no profile was made.
        es, en = asc.manual_revoke([], ["P1"], suffix="r123-4242-1", certs=False)
        self.assertTrue(es.startswith("Borra a mano lo que quede. En "), es)
        self.assertTrue(en.startswith("Delete what is left by hand. At "), en)
        self.assertNotIn(asc.URL_CERTIFICATES, es + en)
        es, en = asc.manual_revoke(["C1"], profiles=False)
        self.assertNotIn(asc.URL_PROFILES, es + en)
        self.assertIn("(id C1), púlsalo ▸ Revoke", es)
        for es, en in (asc.manual_revoke(["C1"], ["P1"]), asc.manual_revoke(suffix="r1-2-3")):
            self.assertNotIn("los perfiles «OpenCfMoto CI …»", es)
            self.assertNotIn("the «OpenCfMoto CI …» profiles", en)

    def test_profile_names_carry_the_repository_and_match_what_the_janitor_knows(self):
        github = {"GITHUB_REPOSITORY_ID": "123", "GITHUB_RUN_ID": "18700000001", "GITHUB_RUN_ATTEMPT": "2"}
        with mock.patch.dict(os.environ, github):
            self.assertEqual(asc.default_suffix(), "r123-18700000001-2")
        with mock.patch.dict(os.environ, {}, clear=True):
            local = asc.default_suffix()
        self.assertRegex(local, r"^local[0-9]{14}-1$")                      # a manual run on a Mac
        for suffix in ("r123-18700000001-2", local, "4242-1"):
            for role in ("app", "mirror"):
                self.assertTrue(asc.CI_PROFILE_RE.fullmatch(f"OpenCfMoto CI {suffix} {role}"), suffix)
        for name in ("OpenCfMoto CI manual build", "OpenCfMoto CI manual app", "OpenCfMoto CI r1-2-3 app x",
                     "OpenCfMoto CI-like, not ours", "OpenCfMoto CI r1-2-3 ipad"):
            self.assertIsNone(asc.CI_PROFILE_RE.fullmatch(name), name)

    def test_profile_names_carry_the_build_and_round_trip_through_the_janitors_pattern(self):
        github = {"GITHUB_REPOSITORY_ID": "123456789", "GITHUB_RUN_ID": "18700000001", "GITHUB_RUN_ATTEMPT": "12"}
        with mock.patch.dict(os.environ, github):
            suffix = asc.default_suffix()
        for role in ("app", "mirror"):
            name = asc.profile_name(suffix, "12345", role)
            self.assertEqual(name, f"OpenCfMoto CI r123456789-18700000001-12 b12345 {role}")
            self.assertLess(len(name), 64)                 # no documented limit; these stay short
            match = asc.CI_PROFILE_RE.fullmatch(name)
            self.assertEqual((match.group("repo"), match.group("run"), match.group("build")),
                             ("123456789", "18700000001", "12345"))
            # Names from before the build number: still this CI's, with no build (leftovers).
            match = asc.CI_PROFILE_RE.fullmatch(asc.profile_name(suffix, "", role))
            self.assertEqual((match.group("repo"), match.group("build")), ("123456789", None))
        with mock.patch.dict(os.environ, {}, clear=True):
            local = asc.profile_name(asc.default_suffix(), "7", "app")
        self.assertRegex(local, r"^OpenCfMoto CI local[0-9]{14}-1 b7 app$")
        self.assertIsNone(asc.CI_PROFILE_RE.fullmatch(local).group("repo"))
        self.assertEqual(asc.profile_name("4242-1", "7a", "app"), "OpenCfMoto CI 4242-1 app")   # digits only
        for name in ("OpenCfMoto CI r1-2-3 b app", "OpenCfMoto CI r1-2-3 bx app", "OpenCfMoto CI r1-2-3 b7x app",
                     "OpenCfMoto CI r1-2-3 b-7 app", "OpenCfMoto CI r1-2-3 b7 b8 app", "OpenCfMoto CI r1-2-3 b7app",
                     "OpenCfMoto CI r1-2-3 app b7", "OpenCfMoto CI r1-2-3  b7 app"):
            self.assertIsNone(asc.CI_PROFILE_RE.fullmatch(name), name)

    def test_iso_dates_with_any_offset(self):
        self.assertEqual(asc._timestamp("2026-11-01T10:00:00Z"), asc._timestamp("2026-11-01T03:00:00.123-07:00"))
        self.assertEqual(asc._timestamp("2026-11-01T10:00:00Z"), asc._timestamp("2026-11-01T15:30:00+0530"))
        self.assertGreater(asc._timestamp("2026-11-01T10:00:01Z"), asc._timestamp("2026-11-01T10:00:00Z"))
        self.assertEqual(asc._timestamp("yesterday"), 0.0)
        self.assertEqual(asc._timestamp(None), 0.0)


# ---------------------------------------------------------------- check-auth, errors, retries

class CheckAuthTest(AscTest):
    def test_ok_token_masked_and_verifiable(self):
        proc = self.run_asc("check-auth")
        gets = self.calls("GET", "/v1/bundleIds")
        self.assertEqual(len(gets), 1)
        self.assertEqual(gets[0].query.get("limit"), "1")
        token = gets[0].headers["authorization"][len("Bearer "):]
        self.assertTrue(verify_jwt(token))
        header, payload = jwt_parts(token)
        self.assertEqual((header["kid"], payload["iss"]), (KEY_ID, ISSUER))
        self.assertTrue(payload["exp"] - payload["iat"] <= 1200)
        self.assertEqual([line for line in proc.stdout.splitlines() if token in line], [f"::add-mask::{token}"])
        self.assertLess(proc.stdout.index("::add-mask::"), proc.stdout.index("GET /v1/bundleIds"))
        for text in (proc.stderr, self.summary(), open(self.github_output).read()):
            self.assertNotIn(token, text)
        self.assertIn("clave de la API válida", self.summary())

    def test_no_mask_outside_github_actions(self):
        proc = self.run_asc("check-auth", env={"GITHUB_ACTIONS": None})
        token = self.calls("GET", "/v1/bundleIds")[0].headers["authorization"][len("Bearer "):]
        self.assertNotIn("::add-mask::", proc.stdout)
        self.assertNotIn(token, proc.stdout + proc.stderr)

    def test_401_explained_after_one_fresh_token(self):
        self.fake.fail("GET", "/v1/bundleIds", 401,
                       error_doc(401, "NOT_AUTHORIZED", "Authentication credentials are missing or invalid.",
                                 "Provide a properly configured and signed bearer token"), times=99)
        proc = self.run_asc("check-auth", expect=1)
        title, message = self.annotation(proc, "error")
        self.assertIn("401", title)
        for needle in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY", "Revisa", "Check the three"):
            self.assertIn(needle, message)
        self.assertLess(message.index("Revisa"), message.index("Check the three"))   # Spanish first
        self.assert_new_run_advice(message)
        self.assertEqual(len(self.calls("GET", "/v1/bundleIds")), 2)
        self.assertIn("Clave de API rechazada", self.summary())
        self.assertIn("ERROR: Clave de API rechazada", proc.stdout)               # plain paragraph too

    def test_403_agreements(self):
        self.fake.fail("GET", "/v1/bundleIds", 403,
                       error_doc(403, "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED",
                                 "A required agreement is missing or has expired.",
                                 "This request requires an in-effect agreement that has not been signed or has expired."),
                       times=99)
        title, message = self.annotation(self.run_asc("check-auth", expect=1), "error")
        self.assertIn("Acuerdos", title)
        self.assertIn("acepta los acuerdos", message)
        self.assertIn("accept the new agreements", message)
        self.assert_new_run_advice(message)

    def test_403_role(self):
        self.fake.fail("GET", "/v1/bundleIds", 403,
                       error_doc(403, "FORBIDDEN_ERROR", "This request is forbidden for security reasons",
                                 "The API key in use does not allow this request"), times=99)
        title, message = self.annotation(self.run_asc("check-auth", expect=1), "error")
        self.assertIn("403", title)
        self.assertIn("Admin", message)
        # Pending agreements show up on developer.apple.com first (as in the agreements text).
        self.assertEqual(message.count("https://developer.apple.com/account"), 2)   # ES + EN
        self.assertIn("Negocios", message)

    def test_missing_secrets(self):
        proc = self.run_asc("check-auth", expect=1, env={"ASC_ISSUER_ID": None, "ASC_PRIVATE_KEY": "  \n"})
        title, message = self.annotation(proc, "error")
        self.assertIn("ASC_ISSUER_ID, ASC_PRIVATE_KEY", message)
        self.assertEqual(self.fake.requests, [])

    def test_bad_private_key(self):
        proc = self.run_asc("check-auth", expect=1, env={
            "ASC_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\nnot base64!\n-----END PRIVATE KEY-----"})
        title, message = self.annotation(proc, "error")
        self.assertIn("ASC_PRIVATE_KEY", title)
        self.assertEqual(self.fake.requests, [])

    def test_valid_base64_that_is_not_an_ec_key(self):
        proc = self.run_asc("check-auth", expect=1, env={
            "ASC_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\n" + base64.b64encode(b"0" + bytes(60)).decode()
                               + "\n-----END PRIVATE KEY-----"})
        self.assertIn("openssl", self.annotation(proc, "error")[1])
        self.assertEqual(self.fake.requests, [])

    def test_key_errors_never_print_the_masked_armor_lines(self):
        # GitHub masks each line of the secret, so these lines would read *** in the message.
        lines = KEYS.pem.strip().splitlines()
        cases = {"a body line left out": "\n".join(lines[:2] + lines[3:]) + "\n",    # openssl fails
                 "not base64": "-----BEGIN PRIVATE KEY-----\nnot base64!\n-----END PRIVATE KEY-----"}
        for name, key in cases.items():
            with self.subTest(name):
                proc = self.run_asc("check-auth", expect=1, env={"ASC_PRIVATE_KEY": key})
                title, message = self.annotation(proc, "error")
                self.assertIn("ASC_PRIVATE_KEY", title)
                for needle in ("BEGIN PRIVATE KEY", "END PRIVATE KEY", "guiones", "dashes"):
                    self.assertIn(needle, message)
                self.assert_new_run_advice(message)
                for text in (proc.stdout, proc.stderr, self.summary()):
                    for armor in ARMOR_LINES:
                        self.assertNotIn(armor, text)

    def test_key_pasted_on_one_line_and_key_path(self):
        lines = KEYS.pem.strip().splitlines()
        self.run_asc("check-auth", env={"ASC_PRIVATE_KEY": " ".join(lines)})
        self.run_asc("check-auth", env={"ASC_PRIVATE_KEY": None, "ASC_PRIVATE_KEY_PATH": KEYS.p8})
        tokens = [c.headers["authorization"][7:] for c in self.calls("GET", "/v1/bundleIds")]
        self.assertEqual(len(tokens), 2)
        self.assertTrue(all(verify_jwt(t) for t in tokens))

    def test_429_retried_honouring_retry_after(self):
        self.fake.fail("GET", "/v1/bundleIds", 429,
                       error_doc(429, "RATE_LIMIT_EXCEEDED", "The request rate limit has been reached."),
                       headers={"Retry-After": "7"}, times=2)
        proc = self.run_asc("check-auth")
        self.assertEqual(len(self.calls("GET", "/v1/bundleIds")), 3)
        self.assertEqual(proc.stdout.count("in 7 s"), 2)

    def test_5xx_retried_then_explained(self):
        self.fake.fail("GET", "/v1/bundleIds", 503, error_doc(503, "SERVICE_UNAVAILABLE", "Unavailable"), times=99)
        proc = self.run_asc("check-auth", expect=1)
        self.assertEqual(len(self.calls("GET", "/v1/bundleIds")), 1 + asc.API_RETRIES)
        message = self.annotation(proc, "error")[1]
        self.assertIn("system-status", message)
        self.assert_new_run_advice(message)

    def test_a_get_without_answer_is_repeated(self):
        self.fake.fail("GET", "/v1/bundleIds", 0)          # the connection closes, no answer
        self.run_asc("check-auth")
        self.assertEqual(len(self.calls("GET", "/v1/bundleIds")), 2)

    def test_redirects_are_refused_and_the_token_never_leaves(self):
        # Apple's API does not redirect; urllib would otherwise copy the Bearer token to the target.
        for code in (301, 302, 303, 307, 308):
            with self.subTest(code=code):
                other = OtherHost()
                self.addCleanup(other.close)
                self.fake.faults.clear()
                self.fake.fail("GET", "/v1/bundleIds", code, headers={"Location": other.url}, times=10)
                proc = self.run_asc("check-auth", expect=1)
                self.assertEqual(other.requests, [])
                self.assertIn(str(code), self.annotation(proc, "error")[0])

    def test_usage_error_is_annotated(self):
        proc = self.run_asc("upload", "--ipa", "x.ipa", expect=2)
        self.assertIn("uso incorrecto", self.annotation(proc, "error")[0])


# ---------------------------------------------------------------- prepare

class PrepareTest(AscTest):
    def prepare(self, *extra, expect=0):
        return self.run_asc("prepare", "--prefix", PREFIX, "--project-yml", self.project_yml, *extra,
                            expect=expect)

    def seed_ready_account(self):
        f = self.fake
        app, mirror = f.add_bundle(APP_BID), f.add_bundle(MIRROR_BID)
        f.capabilities[app["id"]] = ["APP_GROUPS", "HOT_SPOT", "ACCESS_WIFI_INFORMATION"]
        f.capabilities[mirror["id"]] = ["APP_GROUPS"]
        f.add_app(APP_BID, APP_ID)
        return app, mirror

    def test_new_account_setup_only(self):
        proc = self.prepare("--setup-only")
        self.assertEqual([c.json()["data"]["attributes"] for c in self.calls("POST", "/v1/bundleIds")], [
            {"identifier": APP_BID, "name": "OpenCfMoto", "platform": "IOS"},
            {"identifier": MIRROR_BID, "name": "OpenCfMoto Mirror", "platform": "IOS"}])
        app, mirror = self.fake.bundle(APP_BID)["id"], self.fake.bundle(MIRROR_BID)["id"]
        enabled = [(c.json()["data"]["relationships"]["bundleId"]["data"]["id"],
                    c.json()["data"]["attributes"]["capabilityType"])
                   for c in self.calls("POST", "/v1/bundleIdCapabilities")]
        self.assertEqual(enabled, [(app, "APP_GROUPS"), (app, "HOT_SPOT"), (app, "ACCESS_WIFI_INFORMATION"),
                                   (mirror, "APP_GROUPS")])
        self.assertEqual(self.outputs(), {
            "ready": "false", "team_id": TEAM, "app_bundle_id": APP_BID, "mirror_bundle_id": MIRROR_BID,
            "app_bundle_resource_id": app, "mirror_bundle_resource_id": mirror, "app_group": GROUP,
            "app_id": "", "marketing_version": "2.3.4"})
        summary = self.summary()
        for needle in (GROUP, APP_BID, MIRROR_BID, "Nueva app", "New App", "Solo preparar",
                       "identifiers/list/applicationGroup", "Asígnalo a los DOS App IDs", "Assign it to BOTH",
                       "si ya está ocupado en la App Store"):
            self.assertIn(needle, summary)
        self.assertNotIn("cogido", summary)
        self.assert_new_run_advice(summary)
        self.assertEqual(self.annotations(proc, "error"), [])
        self.assertEqual(self.calls("GET", "/v1/builds"), [])
        self.assertIn("ready=false", proc.stdout)                 # outputs echoed to stdout too

    def test_identifier_outputs_are_logged_by_name_only(self):
        # The log is public: the team ID and the identifiers go to GITHUB_OUTPUT only; states and
        # the version keep their name=value echo.
        proc = self.prepare("--setup-only")
        out, lines = self.outputs(), proc.stdout.splitlines()
        self.assertEqual(out["team_id"], TEAM)
        for name in ("team_id", "app_bundle_id", "mirror_bundle_id", "app_bundle_resource_id",
                     "mirror_bundle_resource_id", "app_group"):
            self.assertEqual([line for line in lines if line.startswith(name + "=")], [], name)
            self.assertIn(f"{name}: set (value not shown: the log is public)", lines)
        self.assertIn("app_id: empty (value not shown: the log is public)", lines)
        self.assertIn("ready=false", lines)
        self.assertIn("marketing_version=2.3.4", lines)
        self.assertNotIn(TEAM, proc.stdout + proc.stderr + self.summary())

    def test_new_account_full_run_fails_with_the_steps(self):
        proc = self.prepare(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertIn("App Store Connect", title)
        for needle in (GROUP, "Nueva app", "New App", APP_BID):
            self.assertIn(needle, message)
        self.assert_new_run_advice(message)
        self.assertEqual(self.outputs()["ready"], "false")

    def test_capabilities_are_listed_without_limit(self):
        # The fake refuses `limit` there, as the live API does (although the spec lists it).
        app = self.fake.add_bundle(APP_BID)
        status, doc = self.fake.list_caps(Recorded("GET", "", {"limit": "200"}, {}, b""), app["id"])
        self.assertEqual((status, doc["errors"][0]["code"]), (400, "PARAMETER_ERROR.ILLEGAL"))
        self.fake.capabilities[app["id"]] = ["APP_GROUPS", "HOT_SPOT", "ACCESS_WIFI_INFORMATION"]
        self.prepare("--setup-only")
        reads = self.calls("GET", r"/v1/bundleIds/[^/]+/bundleIdCapabilities")
        self.assertGreaterEqual(len(reads), 3)                    # two App IDs, one of them paged
        self.assertTrue(all("limit" not in c.query for c in reads))
        self.assertEqual([c.json()["data"]["attributes"]["capabilityType"]
                          for c in self.calls("POST", "/v1/bundleIdCapabilities")], ["APP_GROUPS"])

    def test_existing_ids_exact_match_and_conflict(self):
        f = self.fake
        # filter[identifier] is a substring match: X.mirror (and X.other) come back first for X.
        mirror, _, app = f.add_bundle(MIRROR_BID), f.add_bundle("com.t.opencfmoto.other"), f.add_bundle(APP_BID)
        f.capabilities[app["id"]] = ["APP_GROUPS", "IN_APP_PURCHASE"]
        f.capabilities[mirror["id"]] = ["APP_GROUPS"]
        f.capability_conflicts = {"HOT_SPOT"}         # enabled but not listed: POST answers 409
        f.add_app("com.t.opencfmoto2", "999")          # filter[bundleId] substring match
        f.add_app(APP_BID, APP_ID)
        f.add_build(APP_ID, "7")
        proc = self.prepare()
        self.assertEqual(self.calls("POST", "/v1/bundleIds"), [])
        self.assertEqual([c.json()["data"]["attributes"]["capabilityType"]
                          for c in self.calls("POST", "/v1/bundleIdCapabilities")],
                         ["HOT_SPOT", "ACCESS_WIFI_INFORMATION"])
        out = self.outputs()
        self.assertEqual((out["app_bundle_resource_id"], out["mirror_bundle_resource_id"]), (app["id"], mirror["id"]))
        self.assertEqual((out["ready"], out["app_id"], out["team_id"]), ("true", APP_ID, TEAM))
        self.assertNotIn("build_number", out)          # chosen by next-build in the build job
        self.assertEqual(self.calls("GET", "/v1/builds"), [])
        self.assertEqual(self.calls("GET", r"/v1/apps/[^/]+/buildUploads"), [])
        self.assertEqual(self.annotations(proc, "error"), [])
        self.assertIn("2.3.4", self.summary())

    def test_setup_only_with_the_app_present(self):
        self.seed_ready_account()
        proc = self.prepare("--setup-only")
        self.assertIn("todo listo, ejecuta sin Solo preparar", proc.stdout)
        out = self.outputs()
        self.assertEqual((out["ready"], out["app_id"]), ("false", APP_ID))
        self.assertNotIn("build_number", out)
        self.assertEqual(self.calls("POST", r".*"), [])
        self.assertEqual(self.calls("GET", "/v1/builds"), [])
        self.assert_new_run_advice(self.summary())

    def test_universal_bundle_id_is_reused(self):
        app = self.fake.add_bundle(APP_BID, platform="UNIVERSAL")
        self.prepare("--setup-only")
        self.assertEqual(self.outputs()["app_bundle_resource_id"], app["id"])
        self.assertEqual(len(self.calls("POST", "/v1/bundleIds")), 2)   # the 409 one + the mirror

    def test_bundle_id_registered_but_the_answer_lost(self):
        # A 5xx after Apple registered it: repeated (harmless), the 409 leads to the lookup.
        self.fake.fail("POST", "/v1/bundleIds", 500, SERVER_ERROR, effect=True)
        self.prepare("--setup-only")
        self.assertEqual([b["attributes"]["identifier"] for b in self.fake.bundle_ids], [APP_BID, MIRROR_BID])
        self.assertEqual(len(self.calls("POST", "/v1/bundleIds")), 3)
        self.assertEqual(self.outputs()["app_bundle_resource_id"], self.fake.bundle(APP_BID)["id"])

    def test_capability_enabled_but_the_answer_lost(self):
        # A repeat after a lost answer gets 409 (already enabled), which is fine.
        app, _ = self.seed_ready_account()
        self.fake.capabilities[app["id"]] = ["APP_GROUPS"]
        self.fake.fail("POST", "/v1/bundleIdCapabilities", 500, SERVER_ERROR, effect=True)
        proc = self.prepare()
        self.assertEqual(self.fake.capabilities[app["id"]], ["APP_GROUPS", "HOT_SPOT", "ACCESS_WIFI_INFORMATION"])
        self.assertEqual(len(self.calls("POST", "/v1/bundleIdCapabilities")), 3)
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_bundle_id_taken_by_another_team(self):
        self.fake.fail("POST", "/v1/bundleIds", 409,
                       error_doc(409, "ENTITY_ERROR.ATTRIBUTE.INVALID", "An attribute value is invalid.",
                                 "An App ID with Identifier 'com.t.opencfmoto' is not available."))
        proc = self.prepare(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertEqual(title, "Bundle ID no disponible / Bundle ID not available")
        for needle in ("BUNDLE_ID_PREFIX", "Si es la primera ejecución, lanza una ejecución nueva una vez",
                       "If this is the first run, start one new run"):
            self.assertIn(needle, message)
        self.assert_new_run_advice(message)
        # After the 409 the App ID is looked up three times (any platform) before giving up.
        lookups = [c for c in self.calls("GET", "/v1/bundleIds")
                   if "filter[platform]" not in c.query and "cursor" not in c.query]
        self.assertEqual(len(lookups), 3)

    def test_a_lost_answer_and_a_lagging_list_are_not_taken_for_another_team(self):
        # The App ID is registered but the answer is lost; the repeat gets 409, and the list still
        # misses the new App ID twice: looking again (not «define BUNDLE_ID_PREFIX») is right.
        self.fake.bundle_list_lag = 2
        self.fake.fail("POST", "/v1/bundleIds", 502, BAD_GATEWAY, effect=True)
        proc = self.prepare("--setup-only")
        self.assertEqual(self.annotations(proc, "error"), [])
        self.assertEqual([b["attributes"]["identifier"] for b in self.fake.bundle_ids], [APP_BID, MIRROR_BID])
        self.assertEqual(self.outputs()["app_bundle_resource_id"], self.fake.bundle(APP_BID)["id"])
        self.assertEqual(len(self.calls("POST", "/v1/bundleIds")), 3)      # app, its repeat, mirror

    def test_invalid_prefix(self):
        proc = self.run_asc("prepare", "--prefix", "com.bad prefix!", "--project-yml", self.project_yml, expect=2)
        self.assertIn("BUNDLE_ID_PREFIX", self.annotation(proc, "error")[1])
        self.assertEqual(self.fake.requests, [])

    def test_leftovers_of_an_interrupted_run_are_removed(self):
        self.seed_ready_account()
        cert = self.fake.add_cert(KEYS.cert_der)
        self.fake.add_profile(f"OpenCfMoto CI r{REPO_ID}-77-1 app", [cert])
        self.fake.add_profile(f"OpenCfMoto CI r{REPO_ID}-77-1 mirror", [cert])
        keep = self.fake.add_profile("My own profile", [])
        proc = self.prepare("--setup-only")
        self.assertEqual(list(self.fake.profiles), [keep])
        self.assertEqual(self.fake.certificates, {})
        title, message = self.annotation(proc, "notice")
        self.assertIn("Restos", title)
        self.assertIn(f"OpenCfMoto CI r{REPO_ID}-77-1 mirror", message)
        self.assertIn("certificado «Apple Distribution» que caduca el 2027-11-01, perfil", message)
        self.assertNotIn(cert, proc.stdout)
        self.assertEqual(self.outputs()["ready"], "false")
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_prepare_decides_about_the_signing_sets_by_the_apps_builds(self):
        self.seed_ready_account()
        f = self.fake
        f.add_build(APP_ID, "6")
        f.add_build(APP_ID, "7")
        names = {}
        for build in (6, 7):
            cert = f.add_cert(KEYS.cert_der)
            names[build] = [f.add_profile(f"OpenCfMoto CI r{REPO_ID}-{100 + build}-1 b{build} {role}", [cert])
                            for role in ("app", "mirror")], cert
        proc = self.prepare("--setup-only")
        self.assertEqual(set(f.profiles), set(names[7][0]))
        self.assertEqual(set(f.certificates), {names[7][1]})
        self.assertIn("Apple aceptó una build más reciente que la 6 (la 7)", self.annotation(proc, "notice")[1])
        self.assertIn("la build 7 es la más reciente que Apple aceptó", self.summary())
        self.assertEqual(self.calls("GET", "/v1/builds")[0].query.get("filter[app]"), APP_ID)
        # A failed builds listing only warns: the run goes on, and the set stays.
        f.fail("GET", "/v1/builds", 500, SERVER_ERROR, times=99)
        proc = self.prepare()
        self.assertEqual(self.outputs()["ready"], "true")
        self.assertEqual(set(f.profiles), set(names[7][0]))
        self.assertEqual(self.annotation(proc, "warning")[0], "Certificados sin comprobar / Certificates not checked")
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_a_sweep_problem_only_warns(self):
        self.seed_ready_account()
        self.fake.fail("GET", "/v1/profiles", 403,
                       error_doc(403, "FORBIDDEN_ERROR", "This request is forbidden for security reasons"), times=99)
        proc = self.prepare()
        self.assertEqual(self.outputs()["ready"], "true")
        title, message = self.annotation(proc, "warning")
        self.assertIn("Limpieza incompleta", title)
        self.assertIn("HTTP 403", message)
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_a_failed_profile_listing_on_a_clean_account_asks_for_nothing_by_hand(self):
        # Nothing was created today and there may be no leftovers at all: no manual steps that
        # would send the owner hunting for an «Apple Distribution» certificate to revoke.
        self.seed_ready_account()
        self.fake.fail("GET", "/v1/profiles", 500, SERVER_ERROR, times=99)
        proc = self.prepare()
        self.assertEqual(self.outputs()["ready"], "true")
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Limpieza incompleta / Cleanup incomplete")
        for needle in ("No hace falta hacer nada: la próxima ejecución lo intenta otra vez",
                       "Nothing to do: the next run tries again", "HTTP 500"):
            self.assertIn(needle, message)
        for wrong in ("creado hoy", "created today", "Revoca a mano", "certificates/list", "{URL_"):
            self.assertNotIn(wrong, message)
        self.assertEqual(self.calls("DELETE"), [])


# ---------------------------------------------------------------- next-build

class NextBuildTest(AscTest):
    def next_build(self, expect=0, env=None):
        return self.run_asc("next-build", "--app-id", APP_ID, expect=expect, env=env)

    def test_one_more_than_any_build_or_upload(self):
        f = self.fake
        for version in ("3", "10.2", "x", "7", "1"):
            f.add_build(APP_ID, version)
        f.add_build("999", "50")                       # another app
        for version in ("12", "11"):
            f.add_upload(APP_ID, version)
        f.add_upload("999", "60")
        github_env = os.path.join(self.tmp, "github_env")
        proc = self.next_build(env={"GITHUB_ENV": github_env})
        self.assertEqual(self.outputs(), {"build_number": "13"})
        with open(github_env, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), "BUILD_NUMBER=13\n")
        self.assertIn("build_number=13", proc.stdout)
        self.assertTrue(any("cursor" in c.query for c in self.calls("GET", "/v1/builds")))   # links.next
        self.assertTrue(self.calls("GET", rf"/v1/apps/{APP_ID}/buildUploads"))
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_first_build_is_1(self):
        self.next_build()
        self.assertEqual(self.outputs()["build_number"], "1")

    def test_links_next_never_sends_the_token_to_another_host(self):
        for version in ("4", "9", "2", "5", "8"):
            self.fake.add_build(APP_ID, version)
        self.fake.next_base = "http://evil.invalid:9"   # asc.py must reuse our base URL
        self.next_build()
        self.assertEqual(self.outputs()["build_number"], "10")
        self.assertEqual(len(self.calls("GET", "/v1/builds")), 3)

    def test_apples_false_404_is_tried_again(self):
        self.fake.add_upload(APP_ID, "4")
        self.fake.fail("GET", r"/v1/apps/[^/]+/buildUploads", 404, FALSE_404, times=2)
        proc = self.next_build()
        self.assertEqual(self.outputs()["build_number"], "5")
        self.assertEqual(len(self.calls("GET", rf"/v1/apps/{APP_ID}/buildUploads")), 3)
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_a_false_404_that_persists_is_explained(self):
        self.fake.fail("GET", r"/v1/apps/[^/]+/buildUploads", 404, FALSE_404, times=99)
        proc = self.next_build(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertIn("Fallo temporal de Apple", title)
        for needle in ("temporal", "temporary", "No tienes que cambiar nada"):
            self.assertIn(needle, message)
        self.assert_new_run_advice(message)
        self.assertEqual(len(self.calls("GET", rf"/v1/apps/{APP_ID}/buildUploads")),
                         1 + len(asc.FALSE_404_PAUSES))
        self.assertNotIn("build_number", self.outputs())

    def test_another_404_is_not_tried_again(self):
        self.fake.fail("GET", r"/v1/apps/[^/]+/buildUploads", 404,
                       error_doc(404, "NOT_FOUND", "The specified resource does not exist",
                                 "The path provided does not match a defined resource type."), times=99)
        proc = self.next_build(expect=1)
        self.assertIn("HTTP 404", self.annotation(proc, "error")[0])
        self.assertEqual(len(self.calls("GET", rf"/v1/apps/{APP_ID}/buildUploads")), 1)


# ---------------------------------------------------------------- janitor

class JanitorTest(AscTest):
    OURS = f"OpenCfMoto CI r{REPO_ID}"      # this repository's CI profiles start like this

    def remaining(self):
        return sorted(info["name"] for info in self.fake.profiles.values())

    def test_removes_ci_leftovers_but_keeps_certificates_other_profiles_use(self):
        f = self.fake
        ci_cert, shared, other, extra = (f.add_cert(KEYS.cert_der) for _ in range(4))
        app = f.add_profile(f"{self.OURS}-41-1 app", [ci_cert])
        mirror = f.add_profile(f"{self.OURS}-41-1 mirror", [ci_cert, shared])
        # The owner's own profile: include=certificates shows only the first two of its three
        # certificates, and the one it shares with a CI profile is the third.
        own = f.add_profile("My App Store profile", [other, extra, shared])
        lookalike = f.add_profile("OpenCfMoto CI-like, not ours", [other])
        proc = self.run_asc("janitor")
        # The certificate first: the profiles are the only way back to it if its revocation fails.
        self.assertEqual([c.path for c in self.calls("DELETE")],
                         [f"/v1/certificates/{ci_cert}", f"/v1/profiles/{app}", f"/v1/profiles/{mirror}"])
        self.assertEqual(set(f.profiles), {own, lookalike})
        self.assertEqual(set(f.certificates), {shared, other, extra})
        listings = self.calls("GET", "/v1/profiles")
        self.assertGreaterEqual(len(listings), 2)                      # paged
        self.assertTrue(all(c.query.get("include") == "certificates" for c in listings))
        links = self.calls("GET", rf"/v1/profiles/{own}/relationships/certificates")
        self.assertTrue(links)
        self.assertTrue(all("limit" not in c.query for c in links))
        title, message = self.annotation(proc, "notice")
        self.assertIn("Restos borrados", title)
        for needle in (f"{self.OURS}-41-1 app", "«Apple Distribution» que caduca el 2027-11-01, perfil",
                       "No tienes que hacer nada", "Nothing to do"):
            self.assertIn(needle, message)
        self.assertEqual(self.annotations(proc, "warning"), [])
        # What went is named by type, date and name; no id reaches the public log.
        for resource_id in (ci_cert, app, mirror):
            self.assertNotIn(resource_id, proc.stdout)

    def test_nothing_left_is_quiet(self):
        self.fake.add_profile("My App Store profile", [self.fake.add_cert(KEYS.cert_der)])
        proc = self.run_asc("janitor")
        self.assertEqual(self.calls("DELETE"), [])
        self.assertEqual(self.annotations(proc, "notice") + self.annotations(proc, "warning"), [])

    def test_already_gone_is_fine(self):
        cert = self.fake.add_cert(KEYS.cert_der)
        self.fake.add_profile(f"{self.OURS}-9-1 app", [cert])
        self.fake.fail("DELETE", r"/v1/certificates/.*", 404,
                       error_doc(404, "NOT_FOUND", "The specified resource does not exist"))
        proc = self.run_asc("janitor")
        self.assertEqual(self.fake.profiles, {})
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_problems_only_warn_with_their_own_manual_steps(self):
        # Not «revoke the certificate created today»: these are leftovers of earlier runs.
        cert = self.fake.add_cert(KEYS.cert_der)
        profile = self.fake.add_profile(f"{self.OURS}-9-1 app", [cert])
        self.fake.fail("DELETE", r"/v1/certificates/.*", 500, SERVER_ERROR, times=99)
        proc = self.run_asc("janitor")
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Limpieza incompleta / Cleanup incomplete")
        for needle in (f"certificado «Apple Distribution» que caduca el 2027-11-01 (id {cert})",
                       f"«Apple Distribution» certificate expiring 2027-11-01 (id {cert})",
                       f"se conserva su perfil «{self.OURS}-9-1 app» para que la próxima ejecución lo encuentre",
                       f"its profile «{self.OURS}-9-1 app» is kept so that the next run finds it",
                       "No hace falta hacer nada", "Nothing to do", "revoca solo los certificados que nombra",
                       "revoke only the certificates it names", asc.URL_CERTIFICATES, asc.URL_PROFILES):
            self.assertIn(needle, message)
        for wrong in ("{URL_", "creado hoy", "created today"):
            self.assertNotIn(wrong, message)
        self.assertEqual(list(self.fake.profiles), [profile])    # the way back to the certificate stays

    def test_a_certificate_it_could_not_revoke_is_revoked_by_the_next_run(self):
        # The sweep finds certificates only through these profiles, so they stay until their
        # certificate is revoked: «la próxima ejecución lo intenta otra vez» holds for certificates
        # too. Here the finish job's sweep (a lost runner), then the next run's prepare.
        f = self.fake
        cert = f.add_cert(KEYS.cert_der)
        app, mirror = (f.add_profile(f"{self.OURS}-112-1 {role}", [cert]) for role in ("app", "mirror"))
        f.fail("DELETE", rf"/v1/certificates/{cert}", 409, error_doc(409, "ENTITY_ERROR", "Not allowed now"))
        proc = self.run_asc("janitor", "--run-id", "112")
        self.assertEqual([c.path for c in self.calls("DELETE")], [f"/v1/certificates/{cert}"])
        self.assertEqual(set(f.profiles), {app, mirror})
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Limpieza incompleta / Cleanup incomplete")
        for needle in (f"(id {cert}): DELETE /v1/certificates/… → HTTP 409",
                       f"se conservan sus perfiles «{self.OURS}-112-1 app» y «{self.OURS}-112-1 mirror» para que "
                       "la próxima ejecución lo encuentre",
                       f"its profiles «{self.OURS}-112-1 app» and «{self.OURS}-112-1 mirror» are kept so that "
                       "the next run finds it",
                       "No hace falta hacer nada: la próxima ejecución lo intenta otra vez",
                       "Nothing to do: the next run tries again"):
            self.assertIn(needle, message)
        self.assertEqual(self.annotations(proc, "notice"), [])           # nothing went
        proc = self.run_asc("janitor")                                   # the next run's prepare
        self.assertEqual((f.profiles, f.certificates), ({}, {}))
        title, message = self.annotation(proc, "notice")
        self.assertIn("Restos borrados", title)
        self.assertIn("«Apple Distribution» que caduca el", message)
        self.assertNotIn(cert, proc.stdout)                              # gone: no id to look for
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_missing_secrets_warn_and_exit_0(self):
        proc = self.run_asc("janitor", env={"ASC_KEY_ID": None})
        self.assertIn("ASC_KEY_ID", self.annotation(proc, "warning")[1])
        self.assertEqual(self.fake.requests, [])

    def test_a_profile_of_the_owner_named_like_ci_is_kept(self):
        # Only the exact names create-signing gives: the owner's own profile and certificate stay.
        f = self.fake
        owner_cert, ci_cert = f.add_cert(KEYS.cert_der), f.add_cert(KEYS.cert_der)
        owner = {f.add_profile("OpenCfMoto CI manual build", [owner_cert], created=iso(99 * 3600)),
                 f.add_profile("OpenCfMoto CI manual app", [owner_cert], created=iso(99 * 3600)),
                 f.add_profile(f"{self.OURS}-41-1 app (copy)", [owner_cert]),
                 f.add_profile(f"{self.OURS}-41-1 app", [owner_cert], kind="IOS_APP_DEVELOPMENT")}
        f.add_profile(f"{self.OURS}-41-1 app", [ci_cert])
        self.run_asc("janitor")
        self.assertEqual(set(f.profiles), owner)
        self.assertEqual(set(f.certificates), {owner_cert})

    def test_other_repositories_and_mac_runs_go_only_once_abandoned(self):
        # The concurrency group is per repository: another repository's run (or a Mac's) may still
        # be building with its profiles, so they go only once older than 12 hours.
        f = self.fake
        old = iso(48 * 3600)
        live = {f"OpenCfMoto CI r999-111-1 {r}": f.add_cert(KEYS.cert_der) for r in ("app", "mirror")}
        live["OpenCfMoto CI local20261101120000-1 app"] = f.add_cert(KEYS.cert_der)
        live["OpenCfMoto CI 500-1 app"] = f.add_cert(KEYS.cert_der)
        undated = f.add_cert(KEYS.cert_der)
        for name, cert in live.items():
            f.add_profile(name, [cert], created=iso(3600))
        f.add_profile("OpenCfMoto CI r999-90-1 app", [undated], created="")      # unknown age: kept
        gone = [f.add_cert(KEYS.cert_der) for _ in range(3)]
        f.add_profile("OpenCfMoto CI r999-100-1 app", [gone[0]], created=old)
        f.add_profile("OpenCfMoto CI local20261030120000-1 app", [gone[1]], created=old)
        f.add_profile(f"{self.OURS}-110-1 app", [gone[2]])                       # ours, fresh
        proc = self.run_asc("janitor")
        self.assertEqual(self.remaining(), sorted(list(live) + ["OpenCfMoto CI r999-90-1 app"]))
        self.assertEqual(set(f.certificates), set(live.values()) | {undated})
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_the_finish_job_sweeps_only_its_own_run(self):
        f = self.fake
        mine = f.add_cert(KEYS.cert_der)
        for name in (f"{self.OURS}-112-1 app", f"{self.OURS}-112-1 mirror", f"{self.OURS}-112-2 app"):
            f.add_profile(name, [mine])
        kept = [f"{self.OURS}-111-1 app", "OpenCfMoto CI r999-112-1 app", "OpenCfMoto CI local20261030120000-1 app"]
        for name in kept:
            f.add_profile(name, [f.add_cert(KEYS.cert_der)], created=iso(48 * 3600))
        self.run_asc("janitor", "--run-id", "112")
        self.assertEqual(self.remaining(), sorted(kept))
        self.assertNotIn(mine, f.certificates)
        self.run_asc("janitor", "--run-id", "11x", expect=2)                    # digits only

    def test_without_a_repository_id_only_abandoned_profiles_go(self):
        f = self.fake
        f.add_profile(f"{self.OURS}-41-1 app", [f.add_cert(KEYS.cert_der)])
        f.add_profile(f"{self.OURS}-40-1 app", [f.add_cert(KEYS.cert_der)], created=iso(48 * 3600))
        self.run_asc("janitor", env={"GITHUB_REPOSITORY_ID": None})
        self.assertEqual(self.remaining(), [f"{self.OURS}-41-1 app"])

    def _the_shared_certificate_survives(self, total):
        f = self.fake
        f.include_total = total
        ci_cert, other, extra = (f.add_cert(KEYS.cert_der) for _ in range(3))
        f.add_profile(f"{self.OURS}-41-1 app", [ci_cert])
        own = f.add_profile("My App Store profile", [other, extra, ci_cert])   # the 3rd is not shown
        self.run_asc("janitor")
        self.assertIn(ci_cert, f.certificates)
        self.assertTrue(self.calls("GET", rf"/v1/profiles/{own}/relationships/certificates"))

    def test_a_cut_short_linkage_without_total_is_read_in_full(self):
        self._the_shared_certificate_survives("missing")     # PagingInformation: total is optional

    def test_a_cut_short_linkage_with_total_0_is_read_in_full(self):
        self._the_shared_certificate_survives("zero")        # the shape of captured live answers

    def test_a_complete_linkage_costs_no_extra_read(self):
        f = self.fake
        f.include_limit, f.include_total = 2147483647, "zero"
        f.add_profile(f"{self.OURS}-41-1 app", [f.add_cert(KEYS.cert_der)])
        f.add_profile("My App Store profile", [f.add_cert(KEYS.cert_der) for _ in range(3)])
        self.run_asc("janitor")
        self.assertEqual(self.calls("GET", r"/v1/profiles/[^/]+/relationships/certificates"), [])


# ---------------------------------------------------------------- signing sets of accepted builds

class SigningSetTest(AscTest):
    """This repository's signing sets: a certificate and the profiles «OpenCfMoto CI r<repository>-
    <run>-<attempt> b<build> app|mirror». Beta review checks a build's signature again, so the set
    of a build Apple accepted stays; it goes once a newer build is accepted unless its build waits
    for or is in beta review; a refused build's goes at once; nothing goes on missing data
    (settle-signing in the finish job, the janitor in every prepare)."""

    def add_set(self, build, run=None, repo=REPO_ID, created=None):
        """A run's signing set: (certificate id, [app profile id, mirror profile id])."""
        f = self.fake
        cert = f.add_cert(KEYS.cert_der)
        run = 100 + int(build) if run is None else run
        stem = f"OpenCfMoto CI {f'r{repo}-' if repo else ''}{run}-1 b{build}"
        return cert, [f.add_profile(f"{stem} {role}", [cert], created=created) for role in ("app", "mirror")]

    def alive(self, sets):
        """{build: whether its certificate and both profiles are still there}."""
        f = self.fake
        return {build: cert in f.certificates and all(p in f.profiles for p in profiles)
                for build, (cert, profiles) in sets.items()}

    def reset(self):
        f = self.fake
        for store in (f.builds, f.requests, f.faults):
            store.clear()
        for store in (f.certificates, f.profiles, f.beta_details):
            store.clear()
        open(self.step_summary, "w").close()

    def settle(self, state, sets=None, build="7", run="107", expect=0):
        args = ["settle-signing", "--app-id", APP_ID, "--build", build, "--state", state, "--run-id", run]
        if sets:
            cert, profiles = sets
            args += ["--cert-id", cert, "--profile-ids", ",".join(profiles)]
        return self.run_asc(*args, expect=expect)

    def deletes(self):
        return [c.path for c in self.calls("DELETE")]

    # settle-signing: the finish job once the wait is over

    def test_an_accepted_build_keeps_its_set_and_older_ones_go_unless_in_review(self):
        for review in ("WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"):
            with self.subTest(review=review):
                self.reset()
                f = self.fake
                f.add_build(APP_ID, "5", external="IN_BETA_TESTING")     # approved earlier: superseded now
                f.add_build(APP_ID, "6", external=review)                 # submitted, not reviewed yet
                f.add_build(APP_ID, "7")                                   # this run's, just accepted
                sets = {b: self.add_set(b) for b in (5, 6, 7)}
                proc = self.settle("VALID", sets[7])
                self.assertEqual(self.alive(sets), {5: False, 6: True, 7: True})
                cert, (app, mirror) = sets[5]
                # The certificate first: the profiles are the only way back to it if that fails.
                self.assertEqual(self.deletes(), [f"/v1/certificates/{cert}", f"/v1/profiles/{app}",
                                                  f"/v1/profiles/{mirror}"])
                title, message = self.annotation(proc, "notice")
                self.assertEqual(title, "Certificados anteriores revocados / Older certificates revoked")
                for needle in ("Apple aceptó una build más reciente que la 5 (la 7)",
                               "Apple accepted a newer build than 5 (7)",
                               "certificado «Apple Distribution» que caduca el 2027-11-01, perfil «OpenCfMoto CI "
                               f"r{REPO_ID}-105-1 b5 app»", "No tienes que hacer nada", "Nothing to do"):
                    self.assertIn(needle, message)
                summary = self.summary()
                for needle in ("el de la build 7 se queda en la cuenta hasta que Apple acepte una build más reciente",
                               "The certificate of build 7 stays in the account until Apple accepts a newer build",
                               "la build 6 está en la revisión de TestFlight", "build 6 is in TestFlight beta review",
                               asc.KEPT_NOTE_ES, asc.KEPT_NOTE_EN):
                    self.assertIn(needle, summary)
                self.assertEqual(self.annotations(proc, "warning") + self.annotations(proc, "error"), [])
                reads = [c for c in self.calls("GET", "/v1/builds") if "cursor" not in c.query]
                self.assertEqual([(c.query.get("filter[app]"), c.query.get("include")) for c in reads],
                                 [(APP_ID, "buildBetaDetail")])          # one listing, with the beta state

    def test_an_accepted_build_keeps_its_set_even_when_a_newer_build_shows_up(self):
        # A newer build accepted meanwhile (uploaded from elsewhere) never takes away the set of the
        # build this run just got accepted: the next run's janitor decides about that one.
        f = self.fake
        for version in ("7", "8"):
            f.add_build(APP_ID, version)
        sets = {7: self.add_set(7)}
        self.settle("VALID", sets[7])
        self.assertEqual(self.alive(sets), {7: True})
        self.assertEqual(self.deletes(), [])

    def test_a_refused_build_s_set_goes_at_once_and_nothing_else(self):
        for state in ("INVALID", "FAILED", "invalid"):
            for with_ids in (True, False):
                with self.subTest(state=state, ids=with_ids):
                    self.reset()
                    f = self.fake
                    f.add_build(APP_ID, "6")                              # still the newest accepted one
                    sets = {b: self.add_set(b) for b in (6, 7)}
                    proc = self.settle(state, sets[7] if with_ids else None)
                    self.assertEqual(self.alive(sets), {6: True, 7: False})
                    self.assertIn("Apple rechazó la build 7: su certificado temporal y sus perfiles se revocan",
                                  self.summary())
                    self.assertIn("Apple rejected build 7: its temporary certificate and profiles are revoked",
                                  self.summary())
                    self.assertEqual(self.calls("GET", "/v1/builds"), [])   # no newer build: nothing else goes
                    self.assertEqual(self.annotations(proc, "warning"), [])

    def test_without_a_clear_state_every_set_stays_for_the_next_run(self):
        # Still processing at the time limit, no answer, the wait cancelled: unknown yet.
        for state in ("PROCESSING", "NOT_FOUND", ""):
            with self.subTest(state=state):
                self.reset()
                f = self.fake
                f.add_build(APP_ID, "6")
                f.add_build(APP_ID, "7", state="PROCESSING")
                sets = {b: self.add_set(b) for b in (6, 7)}
                proc = self.settle(state, sets[7])
                self.assertEqual(self.alive(sets), {6: True, 7: True})
                self.assertEqual(self.fake.requests, [])
                for needle in ("el de la build 7 se queda por ahora: Apple aún no terminó de procesarla",
                               "La próxima ejecución lo decide", "The certificate of build 7 stays for now"):
                    self.assertIn(needle, self.summary())
                self.assertEqual(self.annotations(proc, "warning"), [])
        self.settle("VALID", build="7x", expect=2)                       # a build number is digits only

    # janitor: every prepare (and the finish job after an accepted build)

    def test_the_janitor_decides_every_set_by_its_build(self):
        f = self.fake
        f.add_build(APP_ID, "3", external="IN_BETA_TESTING")             # approved: superseded
        f.add_build(APP_ID, "4", external="IN_BETA_REVIEW")              # in review: stays
        f.add_build(APP_ID, "5", external="WAITING_FOR_BETA_REVIEW")     # submitted: stays
        f.add_build(APP_ID, "6", state="INVALID")                         # «Invalid Binary»: goes
        f.add_build(APP_ID, "7")                                          # the newest accepted one: stays
        f.add_build(APP_ID, "8", state="PROCESSING", external="PROCESSING")   # newer, not done: stays
        f.add_build(APP_ID, "9", expired=True, external="IN_BETA_TESTING")    # expired by hand: goes
        f.add_build(APP_ID, "10", external="EXPIRED")                     # expired: goes
        f.add_build(APP_ID, "12", state="FAILED")                         # refused: goes
        f.add_build(APP_ID, "1.0")                                        # not a plain number: not ours
        f.add_build("999", "20")                                          # another app's: not counted
        # 2: older and not listed (never processed): goes; 11: newer and not listed yet: stays.
        sets = {b: self.add_set(b) for b in (2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)}
        proc = self.run_asc("janitor", "--app-id", APP_ID)
        self.assertEqual(self.alive(sets), {2: False, 3: False, 4: True, 5: True, 6: False, 7: True, 8: True,
                                            9: False, 10: False, 11: True, 12: False})
        paths = self.deletes()
        last_cert = max(i for i, p in enumerate(paths) if p.startswith("/v1/certificates/"))
        first_profile = min(i for i, p in enumerate(paths) if p.startswith("/v1/profiles/"))
        self.assertLess(last_cert, first_profile)                         # certificates first
        title, message = self.annotation(proc, "notice")
        self.assertEqual(title, "Certificados anteriores revocados / Older certificates revoked")
        for needle in ("Apple rechazó la build 12", "la build 10 caducó", "la build 9 caducó", "Apple rechazó la build 6",
                       "Apple aceptó una build más reciente que la 3 (la 7)",
                       "Apple aceptó una build más reciente que la 2 (la 7)", "Apple rejected build 12",
                       "build 9 expired", "Apple accepted a newer build than 3 (7)"):
            self.assertIn(needle, message)
        summary = self.summary()
        for needle in ("Apple aún no terminó con la build 11", "Apple aún no terminó con la build 8",
                       "la build 7 es la más reciente que Apple aceptó", "la build 5 está en la revisión de TestFlight",
                       "la build 4 está en la revisión de TestFlight", "build 7 is the newest build Apple accepted"):
            self.assertIn(needle, summary)
        self.assertEqual(self.annotations(proc, "warning"), [])
        for resource_id in [c for c, _ in sets.values()] + [p for _, ps in sets.values() for p in ps]:
            self.assertNotIn(resource_id, proc.stdout)                    # named by build and date only

    def test_a_failed_builds_listing_keeps_every_set_and_warns(self):
        f = self.fake
        for version in ("5", "7"):
            f.add_build(APP_ID, version)
        sets = {b: self.add_set(b) for b in (5, 7)}
        before = f.add_cert(KEYS.cert_der)      # a name from before the build number: needs no build data
        f.add_profile(f"OpenCfMoto CI r{REPO_ID}-90-1 app", [before])
        f.fail("GET", "/v1/builds", 500, SERVER_ERROR, times=99)
        proc = self.run_asc("janitor", "--app-id", APP_ID)
        self.assertEqual(self.alive(sets), {5: True, 7: True})          # never revoked on missing data
        self.assertNotIn(before, f.certificates)                          # the leftover goes as before
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Certificados sin comprobar / Certificates not checked")
        for needle in ("GET /v1/builds?filter[app]=…&include=…&limit=… → HTTP 500", "no se revocó ninguno de ellos",
                       "No hace falta hacer nada", "none of them was revoked", "Nothing to do"):
            self.assertIn(needle, message)
        self.assertIn("no se pudo leer el estado de la build 7", self.summary())
        self.assertNotIn("Older certificates revoked", proc.stdout)

    def test_a_build_without_its_testflight_state_keeps_its_set_and_warns(self):
        f = self.fake
        f.add_build(APP_ID, "5", external=None)          # its build beta detail is not in the answer
        f.add_build(APP_ID, "6", external="IN_BETA_TESTING")
        f.add_build(APP_ID, "7")
        sets = {b: self.add_set(b) for b in (5, 6, 7)}
        proc = self.run_asc("janitor", "--app-id", APP_ID)
        self.assertEqual(self.alive(sets), {5: True, 6: False, 7: True})
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Certificados sin comprobar / Certificates not checked")
        self.assertIn("no se pudo leer el estado de TestFlight de la build 5", message)
        self.assertIn("the TestFlight state of build 5 could not be read", message)
        self.assertIn("Apple aceptó una build más reciente que la 6 (la 7)", self.annotation(proc, "notice")[1])

    def test_without_the_app_every_set_stays(self):
        sets = {7: self.add_set(7)}
        proc = self.run_asc("janitor")                    # no --app-id: no builds to go by
        self.assertEqual(self.alive(sets), {7: True})
        self.assertEqual(self.calls("GET", "/v1/builds"), [])
        self.assertIn("sin el id de la app en App Store Connect", self.annotation(proc, "warning")[1])

    def test_another_repository_s_sets_are_never_touched(self):
        f = self.fake
        old = iso(48 * 3600)
        theirs = {b: self.add_set(b, repo="999", created=old) for b in (3, 9)}
        mac_old = {4: self.add_set(4, repo="", run="local20261030120000", created=old)}
        mac_new = {5: self.add_set(5, repo="", run="local20261110120000", created=iso(3600))}
        before = f.add_cert(KEYS.cert_der)
        f.add_profile(f"OpenCfMoto CI r{REPO_ID}-90-1 app", [before])   # ours, from before the build number
        f.add_build(APP_ID, "7")
        mine = {7: self.add_set(7)}
        proc = self.run_asc("janitor", "--app-id", APP_ID)
        self.assertEqual(self.alive(theirs), {3: True, 9: True})          # that repository's runs decide
        self.assertEqual(self.alive(mac_old), {4: False})                 # a Mac run's: the 12-hour rule
        self.assertEqual(self.alive(mac_new), {5: True})
        self.assertEqual(self.alive(mine), {7: True})
        self.assertNotIn(before, f.certificates)
        self.assertIn("Restos borrados", self.annotation(proc, "notice")[0])
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_a_retired_set_whose_certificate_cannot_be_revoked_keeps_its_profiles(self):
        f = self.fake
        for version in ("6", "7"):
            f.add_build(APP_ID, version)
        sets = {b: self.add_set(b) for b in (6, 7)}
        f.fail("DELETE", rf"/v1/certificates/{sets[6][0]}", 500, SERVER_ERROR, times=99)
        proc = self.run_asc("janitor", "--app-id", APP_ID)
        self.assertEqual(self.alive(sets), {6: True, 7: True})            # the way back to it stays
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Limpieza incompleta / Cleanup incomplete")
        self.assertIn(f"se conservan sus perfiles «OpenCfMoto CI r{REPO_ID}-106-1 b6 app» y «OpenCfMoto CI "
                      f"r{REPO_ID}-106-1 b6 mirror» para que la próxima ejecución lo encuentre", message)
        f.faults.clear()
        self.run_asc("janitor", "--app-id", APP_ID)                        # the next run
        self.assertEqual(self.alive(sets), {6: False, 7: True})

    def test_the_finish_job_after_a_lost_runner_sweeps_only_its_own_run(self):
        # janitor --run-id: that run's sets go whatever their build (the build job ended without
        # knowing whether it uploaded); no other set, and no build data needed.
        f = self.fake
        f.add_build(APP_ID, "6")
        sets = {6: self.add_set(6, run=111), 7: self.add_set(7, run=112)}
        self.run_asc("janitor", "--run-id", "112")
        self.assertEqual(self.alive(sets), {6: True, 7: False})
        self.assertEqual(self.calls("GET", "/v1/builds"), [])


# ---------------------------------------------------------------- create-signing

class CreateSigningTest(AscTest):
    def setUp(self):
        super().setUp()
        f = self.fake
        self.app, self.mirror = f.add_bundle(APP_BID), f.add_bundle(MIRROR_BID)
        f.capabilities[self.app["id"]] = ["APP_GROUPS", "HOT_SPOT", "ACCESS_WIFI_INFORMATION"]
        f.capabilities[self.mirror["id"]] = ["APP_GROUPS"]
        f.assigned_groups = {APP_BID: [GROUP], MIRROR_BID: [GROUP]}
        self.out = os.path.join(self.tmp, "signing")

    def create(self, expect=0):
        return self.run_asc("create-signing", "--app-bundle-resource-id", self.app["id"],
                            "--mirror-bundle-resource-id", self.mirror["id"], "--app-bundle-id", APP_BID,
                            "--mirror-bundle-id", MIRROR_BID, "--app-group", GROUP, "--out", self.out,
                            "--suffix", "4242-1", expect=expect)

    def state(self):
        with open(os.path.join(self.out, "state.json"), encoding="utf-8") as fh:
            return json.load(fh)

    def alive(self):
        return [c for c in self.fake.created_certs if c in self.fake.certificates]

    def assert_one_certificate_recorded(self, proc, posts=1, unclear=False):
        """`unclear`: a request got no clear answer, which state.json keeps for the teardown."""
        out = self.outputs()
        self.assertEqual(len(self.calls("POST", "/v1/certificates")), posts)
        self.assertEqual(self.alive(), [out["cert_id"]])
        self.assertEqual(self.state(), dict({"cert_id": out["cert_id"],
                                             "profile_ids": [out["profile_app_id"], out["profile_mirror_id"]]},
                                            **({"cert_unclear": True} if unclear else {})))
        with open(os.path.join(self.out, "cert.cer"), "rb") as fh:
            self.assertEqual(fh.read(), self.fake.certificates[out["cert_id"]]["content"])
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_happy_path(self):
        proc = self.create()
        key = os.path.join(self.out, "key.pem")
        self.assertEqual(stat.S_IMODE(os.stat(key).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(self.out).st_mode), 0o700)
        sent = self.calls("POST", "/v1/certificates")[0].json()["data"]["attributes"]
        self.assertEqual(sent["certificateType"], "DISTRIBUTION")
        self.assertTrue(sent["csrContent"].startswith("-----BEGIN CERTIFICATE REQUEST-----"))
        csr = os.path.join(self.tmp, "sent.csr")
        with open(csr, "w", encoding="ascii") as fh:
            fh.write(sent["csrContent"])
        openssl("req", "-in", csr, "-noout", "-verify")
        self.assertEqual(openssl("req", "-in", csr, "-noout", "-pubkey"), openssl("pkey", "-in", key, "-pubout"))
        cert_id = next(iter(self.fake.certificates))
        issued = self.fake.certificates[cert_id]["content"]
        with open(os.path.join(self.out, "cert.cer"), "rb") as fh:
            self.assertEqual(fh.read(), issued)
        self.assertEqual(openssl("x509", "-in", os.path.join(self.out, "cert.pem"), "-outform", "der"), issued)
        self.assertEqual(openssl("x509", "-in", os.path.join(self.out, "cert.pem"), "-noout", "-pubkey"),
                         openssl("pkey", "-in", key, "-pubout"))     # Apple's certificate is for our key

        out = self.outputs()
        self.assertEqual((out["cert_id"], out["cert_team_id"]), (cert_id, TEAM))
        self.assertNotIn("team ID not found in the certificate subject", proc.stdout)   # from the OU
        bodies = [c.json()["data"] for c in self.calls("POST", "/v1/profiles")]
        self.assertEqual([b["attributes"] for b in bodies],
                         [{"name": "OpenCfMoto CI 4242-1 app", "profileType": "IOS_APP_STORE"},
                          {"name": "OpenCfMoto CI 4242-1 mirror", "profileType": "IOS_APP_STORE"}])
        self.assertEqual([b["relationships"]["bundleId"]["data"] for b in bodies],
                         [{"type": "bundleIds", "id": self.app["id"]}, {"type": "bundleIds", "id": self.mirror["id"]}])
        self.assertEqual([b["relationships"]["certificates"]["data"] for b in bodies],
                         [[{"type": "certificates", "id": cert_id}]] * 2)
        for role in ("app", "mirror"):
            path = os.path.join(self.out, "profiles", out[f"profile_{role}_uuid"] + ".mobileprovision")
            with open(path, "rb") as fh:
                self.assertEqual(fh.read(), self.fake.profiles[out[f"profile_{role}_id"]]["content"])
            self.assertEqual(out[f"profile_{role}_name"], f"OpenCfMoto CI 4242-1 {role}")
        self.assertEqual(self.state(), {"cert_id": cert_id,
                                        "profile_ids": [out["profile_app_id"], out["profile_mirror_id"]]})
        self.assertEqual(out["profile_ids"], f"{out['profile_app_id']},{out['profile_mirror_id']}")
        self.assertEqual(self.calls("GET", "/v1/certificates"), [])     # nothing to reconcile
        public = proc.stdout + proc.stderr + self.summary()
        for secret in ("CERTIFICATE REQUEST", "PRIVATE KEY", base64.b64encode(issued).decode()[:40], "<?xml"):
            self.assertNotIn(secret, public)
        self.assertIn("OpenCfMoto CI 4242-1 mirror", self.summary())
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_the_team_id_and_the_ids_stay_out_of_the_log(self):
        proc = self.create()
        out, lines = self.outputs(), proc.stdout.splitlines()
        self.assertEqual(out["cert_team_id"], TEAM)               # the build job still gets it
        for name in ("cert_id", "cert_team_id", "profile_app_id", "profile_mirror_id", "profile_ids",
                     "profile_app_name", "profile_mirror_name", "profile_app_uuid", "profile_mirror_uuid"):
            self.assertEqual([line for line in lines if line.startswith(name + "=")], [], name)
            self.assertIn(f"{name}: set (value not shown: the log is public)", lines)
        self.assertNotIn(TEAM, proc.stdout + proc.stderr + self.summary())

    def test_a_team_mismatch_warning_names_no_team(self):
        self.fake.seed_id = "QWERT67890"                         # the profiles' TeamIdentifier
        proc = self.create()
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Team ID distinto / Team ID mismatch")
        for team in (TEAM, "QWERT67890"):
            self.assertNotIn(team, proc.stdout + proc.stderr + self.summary())

    def test_certificate_made_but_the_answer_was_an_error(self):
        self.fake.add_cert(KEYS.cert_der)                  # someone else's: never adopted
        self.fake.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        proc = self.create()
        self.assert_one_certificate_recorded(proc, unclear=True)
        self.assertEqual(self.calls("GET", "/v1/certificates")[0].query.get("filter[certificateType]"),
                         "DISTRIBUTION")

    def test_certificate_made_but_no_answer_at_all(self):
        self.fake.fail("POST", "/v1/certificates", 0, effect=True)
        proc = self.create()
        self.assert_one_certificate_recorded(proc, unclear=True)

    def test_certificate_not_made_is_asked_for_once_more(self):
        self.fake.fail("POST", "/v1/certificates", 503, error_doc(503, "SERVICE_UNAVAILABLE", "Unavailable"))
        proc = self.create()
        self.assert_one_certificate_recorded(proc, posts=2, unclear=True)

    def test_429_on_the_certificate_request_is_repeated(self):
        self.fake.fail("POST", "/v1/certificates", 429,
                       error_doc(429, "RATE_LIMIT_EXCEEDED", "The request rate limit has been reached."))
        proc = self.create()
        self.assert_one_certificate_recorded(proc, posts=2)
        self.assertEqual(self.calls("GET", "/v1/certificates"), [])

    def test_a_certificate_the_listing_showed_late_is_revoked(self):
        self.fake.cert_list_lag = 1                       # the first listing misses the new one
        self.fake.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        proc = self.create()
        first, second = self.fake.created_certs
        self.assertEqual(self.outputs()["cert_id"], second)
        self.assertIn(f"/v1/certificates/{first}", [c.path for c in self.calls("DELETE")])
        self.assert_one_certificate_recorded(proc, posts=2, unclear=True)

    def test_a_list_that_lags_after_the_second_request_is_waited_for(self):
        # The first request made a certificate but got no answer; the list misses it twice. It is
        # trusted only once it shows the certificate the second request made, so the first one
        # is found and revoked in this step (a build that reaches Apple has no other sweep).
        self.fake.cert_list_lag = 2
        self.fake.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        proc = self.create()
        first, second = self.fake.created_certs
        self.assertEqual(self.outputs()["cert_id"], second)
        self.assertIn(f"/v1/certificates/{first}", [c.path for c in self.calls("DELETE")])
        self.assert_one_certificate_recorded(proc, posts=2, unclear=True)

    def test_the_second_certificate_is_recorded_before_the_listings_that_follow(self):
        # Those listings can take minutes while Apple's API fails, long enough for a cancel's Clean
        # up to stop this step: by then state.json must already name the certificate it got.
        f = self.fake
        f.cert_list_lag = 1                       # the look after the unanswered request misses it
        f.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        real, recorded = f.list_certs, []

        def listing(rec):
            if "cursor" not in rec.query and len(self.calls("POST", "/v1/certificates")) == 2:
                with open(os.path.join(self.out, "state.json"), encoding="utf-8") as fh:
                    recorded.append(json.load(fh))
            return real(rec)
        f.list_certs = listing
        proc = self.create()
        first, second = f.created_certs
        self.assertTrue(recorded)
        self.assertEqual((recorded[0]["cert_id"], recorded[0].get("cert_pending")), (second, True))
        self.assertIn(f"/v1/certificates/{first}", [c.path for c in self.calls("DELETE")])
        self.assert_one_certificate_recorded(proc, posts=2, unclear=True)

    def test_an_unreadable_success_is_quoted_not_the_error_after_it(self):
        # Apple said it made the certificate (201 with a page the client cannot read), the list
        # never shows it, and the second request gets a 503: the message quotes the 201.
        f = self.fake
        f.cert_list_lag = 2
        f.fail("POST", "/v1/certificates", 201, b"<html><body>proxy</body></html>", effect=True)
        f.fail("POST", "/v1/certificates", 503, error_doc(503, "SERVICE_UNAVAILABLE", "Unavailable"))
        proc = self.create(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertEqual(title, "Certificado sin confirmar / Certificate not confirmed")
        for needle in ("Apple dijo que creó el certificado de distribución, pero su respuesta no se pudo leer "
                       "(POST /v1/certificates → HTTP 201: response is not JSON)",
                       "Apple said it created the distribution certificate, but its answer could not be read "
                       "(POST /v1/certificates → HTTP 201: response is not JSON)"):
            self.assertIn(needle, message)
        self.assertNotIn("HTTP 503", message)
        self.assertEqual(len(self.calls("POST", "/v1/certificates")), 2)
        self.assertEqual(self.state(), {"cert_id": None, "profile_ids": [], "cert_pending": True, "cert_unclear": True})

    def test_a_duplicate_it_cannot_revoke_warns_at_once_and_spares_the_builds(self):
        # A lost runner means no Clean up, and nothing else finds a certificate that is in no
        # profile: the owner is told now. Never in a way that points at the kept certificate.
        f = self.fake
        f.cert_list_lag = 1
        f.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        f.fail("DELETE", r"/v1/certificates/.*", 500, SERVER_ERROR, times=99)
        proc = self.create()
        first, second = f.created_certs
        self.assertEqual(self.outputs()["cert_id"], second)
        self.assertEqual(self.alive(), [first, second])
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Limpieza incompleta / Cleanup incomplete")
        for needle in ("No se pudo revocar un certificado duplicado de esta ejecución (DELETE /v1/certificates/… → "
                       "HTTP 500", "El paso «Clean up» lo intenta otra vez", asc.AFTER_FINISH_ES,
                       "Could not revoke a duplicate certificate of this run (DELETE /v1/certificates/…",
                       asc.AFTER_FINISH_EN):
            self.assertIn(needle, message)
        # No id at all: the request line and the API error show «…» instead (the log is public).
        for wrong in ("Revoca a mano lo que quede", first, second):
            self.assertNotIn(wrong, message)
        self.assertNotIn(first, proc.stdout)
        self.assertNotIn(second, proc.stdout)
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_a_failing_list_after_the_second_request_leaves_the_duplicate_to_the_teardown(self):
        f = self.fake
        f.cert_list_lag = 1                       # the look after the unanswered request misses it
        f.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        real, listings = f.list_certs, []

        def failing_after_the_first(rec):
            if "cursor" not in rec.query:
                listings.append(rec)
            return (500, SERVER_ERROR) if len(listings) >= 2 else real(rec)
        f.list_certs = failing_after_the_first
        proc = self.create()
        first, second = f.created_certs
        out = self.outputs()
        self.assertEqual((out["cert_id"], self.state()["cert_pending"]), (second, True))
        self.assertEqual(self.alive(), [first, second])
        self.assertEqual(self.annotations(proc, "error"), [])
        # The teardown of a build that reached Apple: only the duplicate goes, the build's stays.
        f.list_certs = real
        os.unlink(os.path.join(self.out, "key.pem"))
        proc = self.run_asc("cleanup", "--state", os.path.join(self.out, "state.json"), "--duplicates-only")
        self.assertEqual(self.alive(), [second])
        self.assertEqual(self.state(), {"cert_id": second, "profile_ids": [out["profile_app_id"], out["profile_mirror_id"]],
                                        "cert_pending": True, "cert_unclear": True})
        self.assertEqual(len(f.profiles), 2)
        self.assertEqual(self.annotations(proc, "warning"), [])
        self.assertIn(f"revocado un certificado duplicado de esta ejecución / revoked a duplicate certificate "
                      f"of this run: {first}", self.summary())

    def test_an_outage_is_explained_as_an_outage(self):
        # Two requests without an answer, two listings that worked and showed nothing: Apple made
        # no certificate. Not «could not check» and no manual revocation, but the outage advice.
        self.fake.fail("POST", "/v1/certificates", 503, error_doc(503, "SERVICE_UNAVAILABLE", "Unavailable"), times=2)
        proc = self.create(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertEqual(title, "App Store Connect no responde / not responding (503)")
        for needle in ("system-status", "Se buscó dos veces", "No hace falta revocar nada a mano",
                       "looked for twice", "Nothing to revoke by hand", "Clean up"):
            self.assertIn(needle, message)
        for wrong in ("sin confirmar", "no se pudo comprobar", "could not be checked", "Revoca a mano"):
            self.assertNotIn(wrong, message)
        self.assert_new_run_advice(message)
        self.assertEqual(len(self.calls("POST", "/v1/certificates")), 2)
        self.assertEqual(self.state(), {"cert_id": None, "profile_ids": [], "cert_pending": True, "cert_unclear": True})
        # The teardown looks once more (and a while) and has nothing to revoke: no warning either.
        os.unlink(os.path.join(self.out, "key.pem"))
        proc = self.run_asc("cleanup", "--state", os.path.join(self.out, "state.json"))
        self.assertEqual(self.annotations(proc, "warning"), [])
        self.assertIn("nada que revocar", self.summary())
        self.assertEqual(self.fake.certificates, {})

    def test_unconfirmed_certificate_is_explained_and_cleanup_finds_it(self):
        self.fake.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        self.fake.fail("GET", "/v1/certificates", 500, SERVER_ERROR, times=99)
        proc = self.create(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertIn("Certificado sin confirmar", title)
        for needle in ("no se pudo comprobar si llegó a crearlo", "could not be checked", "«Clean up»",
                       "el certificado «Apple Distribution» creado hoy, púlsalo ▸ Revoke",
                       "the «Apple Distribution» certificate created today, click it ▸ Revoke",
                       "certificates/list"):
            self.assertIn(needle, message)
        self.assert_new_run_advice(message)
        self.assertEqual(self.state(), {"cert_id": None, "profile_ids": [], "cert_pending": True,
                                        "cert_unclear": True})
        self.assertEqual(len(self.calls("POST", "/v1/certificates")), 1)
        # The build job's teardown: key.pem goes first, then cleanup finds it by the CSR's key.
        self.fake.faults.clear()
        os.unlink(os.path.join(self.out, "key.pem"))
        proc = self.run_asc("cleanup", "--state", os.path.join(self.out, "state.json"))
        self.assertEqual(self.fake.certificates, {})
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_certificate_limit(self):
        self.fake.cert_limit = True
        title, message = self.annotation(self.create(expect=1), "error")
        self.assertIn("Límite de certificados", title)
        for needle in ("Apple Distribution", "certificates/list", "revoca", "revoke"):
            self.assertIn(needle, message)
        self.assert_new_run_advice(message)
        self.assertEqual(self.state(), {"cert_id": None, "profile_ids": []})
        self.assertNotIn("cert_id", self.outputs())

    def test_certificate_limit_as_a_422(self):
        self.fake.cert_limit = 422
        title, _ = self.annotation(self.create(expect=1), "error")
        self.assertIn("Límite de certificados", title)

    def test_the_certificate_limit_names_the_certificate_kept_for_the_latest_build(self):
        # Revoking it would make Apple refuse that build in beta review: the message says which one
        # it is (by build and expiry date, as the portal lists it) and what revoking it breaks.
        f = self.fake
        kept = f.add_cert(KEYS.cert_der)
        for role in ("app", "mirror"):
            f.add_profile(f"OpenCfMoto CI r{REPO_ID}-41-1 b7 {role}", [kept])
        f.add_profile("OpenCfMoto CI r999-41-1 b9 app", [f.add_cert(KEYS.cert_der)])   # another repository's
        f.cert_limit = True
        title, message = self.annotation(self.create(expect=1), "error")
        self.assertEqual(title, "Límite de certificados / Certificate limit")
        for needle in ("Este workflow conserva a propósito el certificado de la última build que Apple aceptó",
                       "(ahora: la build 7, certificado que caduca el 2027-11-01)", "«Invalid Binary» (ITMS-90035)",
                       "si todos son del workflow, el de la build más antigua",
                       "This workflow keeps on purpose the certificate of the latest build Apple accepted",
                       "(now: build 7, certificate expiring 2027-11-01)", "unless Apple accepts its build"):
            self.assertIn(needle, message)
        self.assertNotIn("build 9", message)
        self.assertNotIn(kept, message)
        self.assert_new_run_advice(message)
        # Without the listing the rule still stands, without the «now».
        f.fail("GET", "/v1/profiles", 500, SERVER_ERROR, times=99)
        _, message = self.annotation(self.create(expect=1), "error")
        self.assertIn("Este workflow conserva a propósito", message)
        self.assertNotIn("(ahora:", message)

    def test_the_build_number_names_the_profiles(self):
        args = ["create-signing", "--app-bundle-resource-id", self.app["id"], "--mirror-bundle-resource-id",
                self.mirror["id"], "--app-bundle-id", APP_BID, "--mirror-bundle-id", MIRROR_BID, "--app-group", GROUP,
                "--out", self.out, "--suffix", f"r{REPO_ID}-4242-1"]
        proc = self.run_asc(*args, "--build", "7")
        names = [c.json()["data"]["attributes"]["name"] for c in self.calls("POST", "/v1/profiles")]
        self.assertEqual(names, [f"OpenCfMoto CI r{REPO_ID}-4242-1 b7 app", f"OpenCfMoto CI r{REPO_ID}-4242-1 b7 mirror"])
        out = self.outputs()
        self.assertEqual((out["profile_app_name"], out["profile_mirror_name"]), tuple(names))
        self.assertTrue(all(asc.CI_PROFILE_RE.fullmatch(name).group("build") == "7" for name in names))
        for needle in ("Si Apple acepta la build, el certificado y los perfiles se quedan hasta que acepte una build más "
                       "reciente", "If Apple accepts the build, the certificate and profiles stay"):
            self.assertIn(needle, self.summary())
        self.assertEqual(self.annotations(proc, "error"), [])
        before = len(self.fake.requests)
        self.run_asc(*args, "--build", "7a", expect=2)                  # digits only, refused before any request
        self.assertEqual(len(self.fake.requests), before)

    def test_an_invalid_csr_422_is_not_the_limit(self):
        self.fake.fail("POST", "/v1/certificates", 422,
                       error_doc(422, "ENTITY_ERROR.ATTRIBUTE.INVALID", "An attribute value is invalid.",
                                 "The certificate signing request is not valid."))
        title, _ = self.annotation(self.create(expect=1), "error")
        self.assertIn("HTTP 422", title)
        self.assertNotIn("Límite", title)
        self.assertEqual(self.state(), {"cert_id": None, "profile_ids": []})

    def test_profile_made_but_the_answer_lost_is_found_by_name(self):
        lookalike = self.fake.add_profile("OpenCfMoto CI 4242-1 apple", [])   # filter[name] returns it too
        self.fake.fail("POST", "/v1/profiles", 500, SERVER_ERROR, effect=True)
        proc = self.create()
        out = self.outputs()
        self.assertEqual(len(self.calls("POST", "/v1/profiles")), 2)     # never asked twice for one
        self.assertEqual(sorted(self.fake.profiles),
                         sorted([lookalike, out["profile_app_id"], out["profile_mirror_id"]]))
        self.assertNotIn(lookalike, (out["profile_app_id"], out["profile_mirror_id"]))
        self.assertEqual(self.calls("GET", "/v1/profiles")[0].query.get("filter[name]"), "OpenCfMoto CI 4242-1 app")
        self.assertEqual(self.state()["profile_ids"], [out["profile_app_id"], out["profile_mirror_id"]])
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_profile_not_made_is_asked_for_once_more(self):
        self.fake.fail("POST", "/v1/profiles", 503, error_doc(503, "SERVICE_UNAVAILABLE", "Unavailable"))
        self.create()
        self.assertEqual(len(self.calls("POST", "/v1/profiles")), 3)
        self.assertEqual(len(self.fake.profiles), 2)

    def test_missing_app_group_exits_4_after_recording_everything(self):
        self.fake.assigned_groups = {APP_BID: [GROUP]}     # not assigned to the extension's App ID
        proc = self.create(expect=4)
        title, message = self.annotation(proc, "error")
        self.assertIn("App Group", title)
        for needle in (MIRROR_BID, GROUP, "identifiers/list/applicationGroup", "Asígnalo", "Assign it"):
            self.assertIn(needle, message)
        self.assert_new_run_advice(message)
        out = self.outputs()
        self.assertEqual(self.state(), {"cert_id": out["cert_id"],
                                        "profile_ids": [out["profile_app_id"], out["profile_mirror_id"]]})

    def test_missing_hotspot_capability(self):
        self.fake.capabilities[self.app["id"]] = ["APP_GROUPS"]
        message = self.annotation(self.create(expect=1), "error")[1]
        self.assertIn("HotspotConfiguration", message)
        self.assertIn("wifi-info", message)
        self.assertIn("Prepare (App Store Connect)", message)      # the job name the UI shows
        self.assertEqual(message.count("Access Wi-Fi Information"), 2)   # Apple's name, ES + EN
        self.assertNotIn("WiFi", message)

    def test_profile_failure_keeps_the_certificate_recorded_for_cleanup(self):
        self.fake.fail("POST", "/v1/profiles", 422, error_doc(422, "ENTITY_ERROR", "The request entity is invalid"))
        self.create(expect=1)
        cert_id = self.outputs()["cert_id"]
        self.assertEqual(self.state(), {"cert_id": cert_id, "profile_ids": []})
        self.run_asc("cleanup", "--state", os.path.join(self.out, "state.json"))
        self.assertEqual(self.fake.certificates, {})
        self.assertEqual(self.calls("DELETE")[-1].path, f"/v1/certificates/{cert_id}")


# ---------------------------------------------------------------- upload

class UploadTest(AscTest):
    def setUp(self):
        super().setUp()
        self.ipa = os.path.join(self.tmp, "OpenCfMoto.ipa")
        self.data = bytes((i * 7 + 3) % 256 for i in range(1000))
        with open(self.ipa, "wb") as fh:
            fh.write(self.data)
        self.marker = os.path.join(self.tmp, "committed")

    def upload_args(self, *extra):
        return ("upload", "--ipa", self.ipa, "--app-id", APP_ID, "--version", "2.3.4", "--build", "7",
                "--committed-marker", self.marker, *extra)

    def upload(self, *extra, expect=0):
        return self.run_asc(*self.upload_args(*extra), expect=expect)

    def test_happy_path_with_two_operations(self):
        self.fake.part_sizes = [640, 360]
        self.fake.upload_details = {"COMPLETE": {"warnings": [{"code": "90725", "description": "SDK version issue"}]}}
        proc = self.upload()
        created = self.calls("POST", "/v1/buildUploads")[0].json()["data"]
        self.assertEqual(created["attributes"], {"cfBundleShortVersionString": "2.3.4", "cfBundleVersion": "7",
                                                 "platform": "IOS"})
        self.assertEqual(created["relationships"]["app"]["data"], {"type": "apps", "id": APP_ID})
        upload_id = self.outputs()["upload_id"]
        file_req = self.calls("POST", "/v1/buildUploadFiles")[0].json()["data"]
        self.assertEqual(file_req["attributes"], {"assetType": "ASSET", "fileName": "OpenCfMoto.ipa",
                                                  "fileSize": 1000, "uti": "com.apple.ipa"})
        self.assertEqual(file_req["relationships"]["buildUpload"]["data"], {"type": "buildUploads", "id": upload_id})
        parts = self.calls("PUT", r"/upload/.*")
        self.assertEqual([p.path.rsplit("/", 1)[1] for p in parts], ["part1", "part2"])
        self.assertEqual([p.body for p in parts], [self.data[:640], self.data[640:]])
        for number, part in enumerate(parts, 1):
            self.assertEqual(part.headers.get("content-type"), "application/octet-stream")
            self.assertEqual(part.headers.get("x-apple-part"), str(number))
            self.assertNotIn("authorization", part.headers)
            self.assertEqual(part.query.get("X-Signature"), f"s{number}")
        file_id = next(iter(self.fake.upload_files))
        patch = self.calls("PATCH", r"/v1/buildUploadFiles/.*")
        self.assertEqual(len(patch), 1)
        self.assertEqual(patch[0].path, f"/v1/buildUploadFiles/{file_id}")
        self.assertEqual(patch[0].json(), {"data": {"type": "buildUploadFiles", "id": file_id, "attributes": {
            "uploaded": True, "sourceFileChecksums": {"file": {"hash": hashlib.md5(self.data).hexdigest(),
                                                               "algorithm": "MD5"}}}}})
        out = self.outputs()
        self.assertEqual((out["uploaded"], out["committed"]), ("true", "true"))
        self.assertTrue(os.path.isfile(self.marker))
        self.assertIn("90725: SDK version issue", [m for _, m in self.annotations(proc, "warning")])
        self.assertEqual(len(self.calls("GET", r"/v1/buildUploads/.*")), 2)
        self.assertEqual(self.calls("GET", r"/v1/buildUploadFiles/.*"), [])
        self.assertEqual(self.calls("DELETE"), [])
        self.assertNotIn("X-Signature", proc.stdout + proc.stderr)   # pre-signed URLs stay out of the log
        self.assertIn("build 7", self.summary())

    def test_a_stale_marker_is_removed_first(self):
        open(self.marker, "w").close()
        self.fake.fail("POST", "/v1/buildUploads", 422, error_doc(422, "ENTITY_ERROR", "invalid"))
        self.upload(expect=3)
        self.assertFalse(os.path.exists(self.marker))

    def test_failed_processing_reports_each_error_and_drops_the_marker(self):
        self.fake.upload_script = ["PROCESSING", "FAILED"]
        self.fake.upload_details = {"FAILED": {"errors": [{"code": "90062", "description": "Invalid bundle version"},
                                                          {"code": "90190", "description": "Bad icon"}]}}
        proc = self.upload(expect=1)
        messages = [m for _, m in self.annotations(proc, "error")]
        self.assertIn("90062: Invalid bundle version", messages)
        self.assertIn("90190: Bad icon", messages)
        title, message = self.annotation(proc, "error")
        self.assertIn("Apple rechazó la subida", title)
        self.assert_new_run_advice(message)
        out = self.outputs()
        self.assertEqual((out["uploaded"], out["committed"]), ("false", "true"))
        self.assertFalse(os.path.exists(self.marker))      # nothing left for the finish job
        self.assertEqual(self.calls("DELETE"), [])

    def test_redundant_binary_90189_says_start_a_new_run(self):
        self.fake.upload_script = ["FAILED"]
        self.fake.upload_details = {"FAILED": {"errors": [{
            "code": "ITMS-90189", "description": "Redundant Binary Upload. You've already uploaded a build "
                                                 "with build number '7' for version number '2.3.4'."}]}}
        proc = self.upload(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertIn("La build ya existe", title)
        self.assert_new_run_advice(message)
        self.assertTrue(any(m.startswith("ITMS-90189: Redundant Binary Upload") for _, m in self.annotations(proc, "error")))
        self.assertFalse(os.path.exists(self.marker))

    def test_a_build_number_already_used_exits_1_not_3(self):
        self.fake.add_upload(APP_ID, "7")                  # build 7 reached Apple in an earlier run
        proc = self.upload(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertIn("La build ya existe", title)
        self.assertIn("ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE", message)
        self.assert_new_run_advice(message)
        self.assertEqual(self.calls("POST", "/v1/buildUploadFiles"), [])
        self.assertEqual(self.calls("DELETE"), [])
        self.assertEqual(self.outputs().get("uploaded"), "false")
        self.assertFalse(os.path.exists(self.marker))
        self.assertEqual(self.annotations(proc, "warning"), [])    # no altool fallback announced

    def test_other_refusal_of_the_upload_record_exits_3_without_delete(self):
        self.fake.fail("POST", "/v1/buildUploads", 409,
                       error_doc(409, "ENTITY_ERROR.RELATIONSHIP.INVALID", "invalid",
                                 "The app is not available for build uploads."))
        proc = self.upload(expect=3)
        self.assertEqual(self.calls("DELETE"), [])
        self.assertIn("not available for build uploads", self.annotation(proc, "warning")[1])

    def test_refused_file_creation_deletes_the_dangling_upload(self):
        self.fake.fail("POST", "/v1/buildUploadFiles", 422,
                       error_doc(422, "ENTITY_ERROR.ATTRIBUTE.INVALID", "invalid", "fileSize too large"))
        proc = self.upload(expect=3)
        upload_id = self.outputs()["upload_id"]
        self.assertEqual([c.path for c in self.calls("DELETE")], [f"/v1/buildUploads/{upload_id}"])
        self.assertEqual(self.calls("PUT"), [])
        message = self.annotation(proc, "warning")[1]
        self.assertIn("altool", message)
        self.assertIn("fileSize too large", message)
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_server_error_on_the_file_reservation_is_not_repeated(self):
        # Not idempotent: a repeat could reserve a second file; altool takes over instead.
        self.fake.fail("POST", "/v1/buildUploadFiles", 500, SERVER_ERROR, times=99)
        self.upload(expect=3)
        self.assertEqual(len(self.calls("POST", "/v1/buildUploadFiles")), 1)
        self.assertEqual(len(self.calls("DELETE", r"/v1/buildUploads/.*")), 1)

    def test_upload_operation_retried_then_refused(self):
        self.fake.fail("PUT", r"/upload/.*/part2", 503, times=99)
        self.upload(expect=3)
        self.assertEqual(len([c for c in self.calls("PUT") if c.path.endswith("part2")]), 1 + asc.UPLOAD_OP_RETRIES)
        self.assertEqual(self.calls("PATCH"), [])
        self.assertEqual(len(self.calls("DELETE", r"/v1/buildUploads/.*")), 1)

    def test_upload_operation_recovers_after_one_failure(self):
        self.fake.fail("PUT", r"/upload/.*/part1", 500)
        self.upload()
        self.assertEqual(len([c for c in self.calls("PUT") if c.path.endswith("part1")]), 2)
        self.assertEqual(self.outputs()["uploaded"], "true")

    def test_commit_without_answer_after_apple_took_the_file(self):
        self.fake.fail("PATCH", r"/v1/buildUploadFiles/.*", 0, effect=True)
        proc = self.upload()
        self.assertEqual(len(self.calls("PATCH")), 1)                  # never repeated
        self.assertTrue(self.calls("GET", r"/v1/buildUploadFiles/.*"))
        self.assertEqual(self.calls("DELETE"), [])
        out = self.outputs()
        self.assertEqual((out["committed"], out["uploaded"]), ("true", "true"))
        self.assertTrue(os.path.isfile(self.marker))
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_commit_answered_5xx_after_apple_took_the_file(self):
        self.fake.fail("PATCH", r"/v1/buildUploadFiles/.*", 504,
                       error_doc(504, "GATEWAY_TIMEOUT", "Gateway Timeout"), effect=True)
        self.upload()
        self.assertEqual(len(self.calls("PATCH")), 1)
        self.assertEqual(self.calls("DELETE"), [])
        self.assertTrue(os.path.isfile(self.marker))

    def test_commit_seen_late_is_still_found(self):
        # A single read just after the commit can still say AWAITING_UPLOAD: keep looking.
        self.fake.commit_lag = 2
        self.fake.fail("PATCH", r"/v1/buildUploadFiles/.*", 0, effect=True)
        self.run_asc(*self.upload_args(), env={"ASC_POLL_SCALE": "0.01"})   # a roomier window
        self.assertEqual(len(self.calls("GET", r"/v1/buildUploadFiles/.*")), 2)
        self.assertEqual(self.calls("DELETE"), [])
        self.assertEqual(self.outputs()["uploaded"], "true")
        self.assertTrue(os.path.isfile(self.marker))

    def test_the_marker_exists_while_the_commit_is_at_apple(self):
        # A cancel during the commit (or the check after an unclear one) stops asc.py with Apple
        # possibly taking the file: the marker must already be there, so the teardown keeps the
        # certificate and the finish job waits for the build.
        seen, real = [], self.fake.patch_upload_file

        def patch(rec, file_id):
            seen.append(os.path.exists(self.marker))
            return real(rec, file_id)
        self.fake.patch_upload_file = patch
        self.upload()
        self.assertEqual(seen, [True])
        self.assertTrue(os.path.isfile(self.marker))

    def test_a_failing_file_read_does_not_hide_the_uploads_state(self):
        # The commit's answer is lost after Apple took the file, and the file read keeps failing
        # (a plain 404 here): the upload read says PROCESSING, so nothing is deleted or re-sent.
        self.fake.fail("PATCH", r"/v1/buildUploadFiles/.*", 0, effect=True)
        self.fake.fail("GET", r"/v1/buildUploadFiles/.*", 404,
                       error_doc(404, "NOT_FOUND", "The specified resource does not exist",
                                 "There is no resource of type 'buildUploadFiles' with id 'F0002'"), times=999)
        proc = self.run_asc(*self.upload_args(), env={"ASC_POLL_SCALE": "0.01"})
        self.assertTrue(self.calls("GET", r"/v1/buildUploads/.*"))
        self.assertEqual(self.calls("DELETE"), [])
        self.assertTrue(os.path.isfile(self.marker))
        self.assertEqual((self.outputs()["committed"], self.outputs()["uploaded"]), ("true", "true"))
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_nothing_readable_after_an_unclear_commit_never_deletes(self):
        unavailable = error_doc(503, "SERVICE_UNAVAILABLE", "Unavailable")
        self.fake.fail("PATCH", r"/v1/buildUploadFiles/.*", 504,
                       error_doc(504, "GATEWAY_TIMEOUT", "Gateway Timeout"), effect=True)
        self.fake.fail("GET", r"/v1/buildUploadFiles/.*", 503, unavailable, times=10 ** 6)
        self.fake.fail("GET", r"/v1/buildUploads/.*", 503, unavailable, times=10 ** 6)
        proc = self.upload("--timeout-min", "0.5")
        self.assertEqual(self.calls("DELETE"), [])
        self.assertTrue(os.path.isfile(self.marker))
        self.assertEqual(self.outputs()["uploaded"], "true")
        self.assertIn("Apple sigue procesando", self.annotation(proc, "warning")[0])

    def test_one_early_awaiting_read_then_failures_never_deletes(self):
        # Just after a commit Apple can still say AWAITING_UPLOAD; only the last round's answers
        # count, and here the last rounds could not read anything.
        f = self.fake
        f.fail("PATCH", r"/v1/buildUploadFiles/.*", 0, effect=True)
        f.commit_lag = 2                        # the first file read and upload read: AWAITING_UPLOAD

        def then_unavailable(real):
            count = [0]

            def handler(rec, *groups):
                count[0] += 1
                if count[0] > 1:
                    return 503, error_doc(503, "SERVICE_UNAVAILABLE", "Unavailable")
                return real(rec, *groups)
            return handler
        f.get_upload_file = then_unavailable(f.get_upload_file)
        f.get_build_upload = then_unavailable(f.get_build_upload)
        proc = self.upload("--timeout-min", "0.5")
        self.assertIn("file AWAITING_UPLOAD, upload AWAITING_UPLOAD", proc.stdout)
        self.assertEqual(self.calls("DELETE"), [])
        self.assertTrue(os.path.isfile(self.marker))
        self.assertEqual(self.outputs()["uploaded"], "true")

    def test_a_presigned_url_is_never_printed(self):
        # http.client refuses a URL with a space or a control character with an error that quotes
        # the whole URL (signature included), and a header value with a line feed with one that
        # quotes the value: neither may reach the public log, annotation or summary.
        secret = "SIGSECRET42"
        cases = {"a space in the query": lambda op: op.update(url=f"{op['url']}&X-Amz-Credential=AKIA {secret}"),
                 "a control character": lambda op: op.update(url=f"{op['url']}&sig=\x01{secret}"),
                 "a non-ASCII character": lambda op: op.update(url=f"{op['url']}&sig=\u00e9{secret}"),
                 "a line feed in a header": lambda op: op["requestHeaders"].append(
                     {"name": "X-Amz-Security-Token", "value": f"a\nb{secret}"})}
        real = self.fake.create_upload_file
        for name, change in cases.items():
            with self.subTest(name):
                def create(rec, change=change):
                    status, doc = real(rec)
                    change(doc["data"]["attributes"]["uploadOperations"][0])
                    return status, doc
                self.fake.create_upload_file = create
                open(self.step_summary, "w").close()
                proc = self.upload(expect=3)
                for text in (proc.stdout, proc.stderr, self.summary()):
                    for leak in (secret, "X-Signature", "/upload/"):
                        self.assertNotIn(leak, text)
                message = self.annotation(proc, "warning")[1]
                self.assertIn("part 1/2: unusable upload", message)
                self.assertEqual(self.calls("PUT"), [])        # nothing was sent
                self.assertFalse(os.path.exists(self.marker))

    def test_an_upload_host_with_an_untrusted_certificate_is_retried_and_named(self):
        # ssl.SSLCertVerificationError is an OSError and a ValueError: a network problem to retry
        # and name (it quotes the host only), not «unusable upload operation from Apple».
        server = UntrustedTls()
        self.addCleanup(server.close)
        secret = "SIGSECRET42"
        op = {"method": "PUT", "url": f"https://127.0.0.1:{server.port}/upload/F1/part1?X-Signature={secret}",
              "offset": 0, "length": 100,
              "requestHeaders": [{"name": "Content-Type", "value": "application/octet-stream"}]}
        out = io.StringIO()
        with mock.patch.dict(os.environ, self.asc_env(), clear=True), \
                mock.patch.object(asc.urllib.request, "getproxies", return_value={}), \
                contextlib.redirect_stdout(out):
            problem = asc.send_upload_operation(self.ipa, op, 1, 2, asc.ssl_context())
        self.assertIn("SSLCertVerificationError", problem)
        self.assertIn(f"part 1/2 (100 bytes at offset 0) still failing after {asc.UPLOAD_OP_RETRIES} retries", problem)
        self.assertEqual(server.connections, 1 + asc.UPLOAD_OP_RETRIES)
        for leak in (secret, "X-Signature", "/upload/"):
            self.assertNotIn(leak, problem + out.getvalue())

    def test_commit_without_answer_and_never_received(self):
        self.fake.fail("PATCH", r"/v1/buildUploadFiles/.*", 0)          # nothing reached Apple
        proc = self.upload(expect=3)
        self.assertEqual(len(self.calls("PATCH")), 1)
        self.assertTrue(self.calls("GET", r"/v1/buildUploadFiles/.*"))
        upload_id = self.outputs()["upload_id"]
        self.assertEqual([c.path for c in self.calls("DELETE")], [f"/v1/buildUploads/{upload_id}"])
        self.assertFalse(os.path.exists(self.marker))
        self.assertNotIn("committed", self.outputs())
        self.assertIn("altool", self.annotation(proc, "warning")[1])

    def test_commit_refused_deletes_and_falls_back(self):
        self.fake.fail("PATCH", r"/v1/buildUploadFiles/.*", 409,
                       error_doc(409, "ENTITY_ERROR.ATTRIBUTE.INVALID", "invalid", "Checksum mismatch."))
        self.upload(expect=3)
        self.assertEqual(len(self.calls("DELETE", r"/v1/buildUploads/.*")), 1)
        self.assertEqual(self.calls("GET", r"/v1/buildUploadFiles/.*"), [])
        self.assertFalse(os.path.exists(self.marker))

    def test_commit_has_its_own_long_timeout_and_is_never_repeated(self):
        seen = []
        real = asc.Client.request

        def spy(client, method, path, body=None, params=None, idempotent=None, timeout=asc.API_TIMEOUT):
            seen.append((method, path.split("?")[0], timeout))
            return real(client, method, path, body, params, idempotent, timeout)

        self.fake.fail("PATCH", r"/v1/buildUploadFiles/.*", 503,
                       error_doc(503, "SERVICE_UNAVAILABLE", "Unavailable"), effect=True)
        with mock.patch.object(asc.Client, "request", spy):
            code, output = self.run_in_process(*self.upload_args())
        self.assertEqual(code, 0, output)
        commits = [s for s in seen if s[0] == "PATCH"]
        self.assertEqual(len(commits), 1)
        self.assertGreaterEqual(commits[0][2], 300)
        self.assertTrue(all(s[2] == asc.API_TIMEOUT for s in seen if s[0] != "PATCH"))
        self.assertEqual(len(self.calls("PATCH")), 1)

    def test_still_processing_at_the_timeout_keeps_the_marker(self):
        self.fake.upload_script = ["PROCESSING"]
        proc = self.upload("--timeout-min", "0.5")
        message = self.annotation(proc, "warning")[1]
        self.assertIn("procesando", message)
        self.assertIn(f"«{asc.FINISH_JOB}»", message)
        self.assertEqual(self.outputs()["uploaded"], "true")
        self.assertTrue(os.path.isfile(self.marker))

    def test_never_received_after_the_commit_gives_up_and_drops_the_marker(self):
        self.fake.upload_script = ["AWAITING_UPLOAD"]
        self.upload("--timeout-min", "0.5", expect=3)
        self.assertFalse(os.path.exists(self.marker))
        self.assertEqual(len(self.calls("DELETE", r"/v1/buildUploads/.*")), 1)
        self.assertEqual(self.outputs()["uploaded"], "false")

    def test_unreadable_status_after_an_accepted_commit_never_deletes(self):
        self.fake.fail("GET", r"/v1/buildUploads/.*", 500, SERVER_ERROR, times=999)
        proc = self.upload("--timeout-min", "0.5")
        self.assertEqual(self.calls("DELETE"), [])
        self.assertEqual(self.outputs()["uploaded"], "true")
        self.assertTrue(os.path.isfile(self.marker))
        self.assertIn("estado ?", self.annotation(proc, "warning")[1])

    def test_false_404_while_waiting_is_tolerated(self):
        self.fake.fail("GET", r"/v1/buildUploads/.*", 404, FALSE_404, times=2)
        self.upload()
        self.assertEqual(self.outputs()["uploaded"], "true")

    def test_missing_ipa(self):
        proc = self.run_asc("upload", "--ipa", os.path.join(self.tmp, "none.ipa"), "--app-id", APP_ID,
                            "--version", "2.3.4", "--build", "7", expect=1)
        self.assertIn(".ipa", self.annotation(proc, "error")[0])
        self.assertEqual(self.fake.requests, [])


# ---------------------------------------------------------------- wait-build

class WaitBuildTest(AscTest):
    def setUp(self):
        super().setUp()
        self.fake.users = [user("U1", "owner@example.com", ["ADMIN", "ACCOUNT_HOLDER"]),
                           user("U2", "admin@example.com", ["ADMIN"]),
                           user("U3", "dev@example.com", ["DEVELOPER", "APP_MANAGER"]),
                           user("U4", "money@example.com", ["FINANCE", "ADMIN", "SALES"])]

    def wait(self, *extra, expect=0):
        return self.run_asc("wait-build", "--app-id", APP_ID, "--build", "7", *extra, expect=expect)

    def testers_added(self):
        return [c.json()["data"]["attributes"]["email"] for c in self.calls("POST", "/v1/betaTesters")]

    def test_valid_creates_the_group_and_adds_only_the_account_holder(self):
        f = self.fake
        f.add_build(APP_ID, "17")                      # filter[version]=7 may return it: exact match
        f.build_script["7"] = [None, "PROCESSING", "VALID"]
        proc = self.wait()
        out = self.outputs()
        build = next(b for _, b in f.builds if b["attributes"]["version"] == "7")
        self.assertEqual((out["processed"], out["processing_state"], out["build_id"], out["beta_group"]),
                         ("true", "VALID", build["id"], "OpenCfMoto (interno)"))
        group = self.calls("POST", "/v1/betaGroups")[0].json()["data"]
        self.assertEqual(group["attributes"], {"name": "OpenCfMoto (interno)", "isInternalGroup": True,
                                               "hasAccessToAllBuilds": True})
        self.assertEqual(group["relationships"]["app"]["data"], {"type": "apps", "id": APP_ID})
        group_id = f.beta_groups[0][1]["id"]
        testers = [c.json()["data"] for c in self.calls("POST", "/v1/betaTesters")]
        self.assertEqual([t["attributes"]["email"] for t in testers], ["owner@example.com"])   # never other admins
        self.assertEqual(testers[0]["relationships"]["betaGroups"]["data"], [{"type": "betaGroups", "id": group_id}])
        self.assertEqual(self.calls("POST", r"/v1/betaGroups/.*/relationships/builds"), [])
        self.assertEqual(self.annotations(proc, "warning"), [])
        self.assertGreaterEqual(len(self.calls("GET", "/v1/builds")), 3)
        self.assertEqual(len(self.calls("GET", rf"/v1/apps/{APP_ID}/buildUploads")), 1)   # only while no build
        public = proc.stdout + proc.stderr + self.summary()
        for mail in ("owner@example.com", "admin@example.com", "dev@example.com", "money@example.com"):
            self.assertNotIn(mail, public)                 # the repository (and its logs) is public
        self.assertIn("TestFlight", self.summary())

    def test_existing_internal_group_without_all_builds_gets_the_build(self):
        f = self.fake
        f.build_script["7"] = ["VALID"]
        f.add_group(APP_ID, "Public", internal=False, all_builds=True)
        team = f.add_group(APP_ID, "Team", internal=True, all_builds=False)
        f.group_testers[team["id"]] = ["Owner@Example.com"]
        proc = self.wait()
        out = self.outputs()
        self.assertEqual(self.calls("POST", "/v1/betaGroups"), [])
        links = self.calls("POST", rf"/v1/betaGroups/{team['id']}/relationships/builds")
        self.assertEqual([c.json() for c in links], [{"data": [{"type": "builds", "id": out["build_id"]}]}])
        self.assertEqual(self.testers_added(), [])         # the owner is in already; nobody else
        self.assertEqual(out["beta_group"], "Team")
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_build_link_answer_lost_is_repeated_harmlessly(self):
        f = self.fake
        f.build_script["7"] = ["VALID"]
        team = f.add_group(APP_ID, "Team", internal=True, all_builds=False)
        f.fail("POST", r"/v1/betaGroups/[^/]+/relationships/builds", 500, SERVER_ERROR, effect=True)
        proc = self.wait()
        self.assertEqual(len(self.calls("POST", rf"/v1/betaGroups/{team['id']}/relationships/builds")), 2)
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_prefers_the_internal_group_with_access_to_all_builds(self):
        f = self.fake
        f.build_script["7"] = ["VALID"]
        f.add_group(APP_ID, "Limited", internal=True, all_builds=False)
        f.add_group(APP_ID, "Everything", internal=True, all_builds=True)
        self.wait()
        self.assertEqual(self.outputs()["beta_group"], "Everything")
        self.assertEqual(self.calls("POST", r"/v1/betaGroups.*"), [])

    def test_no_account_holder_visible_warns_with_the_manual_steps(self):
        self.fake.build_script["7"] = ["VALID"]
        self.fake.users = [u for u in self.fake.users if "ACCOUNT_HOLDER" not in u["attributes"]["roles"]]
        proc = self.wait()
        title, message = self.annotation(proc, "warning")
        self.assertIn("a mano", title)
        for needle in ("Account Holder", "titular", "Pruebas internas", "Internal Testing", "OpenCfMoto (interno)"):
            self.assertIn(needle, message)
        self.assertEqual(self.testers_added(), [])
        self.assertEqual(self.outputs()["processed"], "true")
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_group_made_but_the_answer_lost_is_found_again(self):
        self.fake.build_script["7"] = ["VALID"]
        self.fake.fail("POST", "/v1/betaGroups", 502, BAD_GATEWAY, effect=True)
        proc = self.wait()
        self.assertEqual(len(self.fake.beta_groups), 1)
        self.assertEqual(len(self.calls("POST", "/v1/betaGroups")), 1)
        self.assertEqual(self.outputs()["beta_group"], "OpenCfMoto (interno)")
        self.assertEqual(self.testers_added(), ["owner@example.com"])
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_tester_answer_lost_is_repeated_harmlessly(self):
        self.fake.build_script["7"] = ["VALID"]
        self.fake.fail("POST", "/v1/betaTesters", 500, SERVER_ERROR, effect=True)
        proc = self.wait()
        self.assertEqual(len(self.calls("POST", "/v1/betaTesters")), 2)     # the repeat gets 409
        self.assertEqual(self.fake.group_testers[self.fake.beta_groups[0][1]["id"]], ["owner@example.com"])
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_invalid_build(self):
        self.fake.build_script["7"] = ["PROCESSING", "INVALID"]
        proc = self.wait(expect=1)
        message = self.annotation(proc, "error")[1]
        self.assertIn("Apple rechazó la build 7; revisa el correo de App Store Connect (códigos ITMS)", message)
        self.assert_new_run_advice(message)
        out = self.outputs()
        self.assertEqual((out["processed"], out["processing_state"]), ("true", "INVALID"))
        self.assertEqual(self.calls("POST"), [])

    def test_a_refused_upload_ends_the_wait_at_once(self):
        f = self.fake
        f.build_script["7"] = [None]
        f.add_upload(APP_ID, "7", state="FAILED", created="2026-11-01T09:30:00Z",
                     errors=[{"code": "ITMS-90062", "description": "an older refusal"}])
        f.add_upload(APP_ID, "7", state="FAILED", created="2026-11-01T03:00:00.000-07:00",   # 10:00 UTC
                     errors=[{"code": "ITMS-90474", "description": "Invalid bundle: iPad orientations"},
                             {"code": "ITMS-90683", "description": "Missing purpose string"}])
        f.add_upload(APP_ID, "7", state="AWAITING_UPLOAD", created="2026-11-01T11:00:00Z")   # left behind
        f.add_upload(APP_ID, "17", state="FAILED", created="2026-11-01T12:00:00Z")           # another build
        proc = self.wait(expect=1)
        out = self.outputs()
        self.assertEqual((out["processed"], out["processing_state"], out["build_id"], out["beta_group"]),
                         ("true", "FAILED", "", ""))
        messages = [m for _, m in self.annotations(proc, "error")]
        self.assertIn("ITMS-90474: Invalid bundle: iPad orientations", messages)    # the newest one
        self.assertIn("ITMS-90683: Missing purpose string", messages)
        self.assertNotIn("ITMS-90062: an older refusal", messages)
        title, message = self.annotation(proc, "error")
        self.assertIn("Apple rechazó la subida", title)
        self.assert_new_run_advice(message)
        self.assertEqual(len(self.calls("GET", "/v1/builds")), 1)          # no 90-minute wait
        self.assertEqual(self.calls("POST"), [])

    def test_a_newer_upload_of_the_same_build_keeps_the_wait_going(self):
        f = self.fake
        f.build_script["7"] = [None]
        f.add_upload(APP_ID, "7", state="FAILED", created="2026-11-01T09:00:00Z",
                     errors=[{"code": "ITMS-90062", "description": "old"}])
        f.add_upload(APP_ID, "7", state="PROCESSING", created="2026-11-01T10:00:00Z")
        proc = self.wait("--timeout-min", "1", "--poll-sec", "20")
        self.assertIn("sigue en proceso", self.annotation(proc, "warning")[0])
        self.assertEqual(self.outputs()["processing_state"], "NOT_FOUND")
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_a_coming_build_beats_a_newer_refused_upload(self):
        # Two uploads of build 7: the first is still processing (its build will appear), a second
        # one of the same number was refused later (e.g. a redundant altool upload): keep waiting.
        for state in ("PROCESSING", "COMPLETE"):
            with self.subTest(older=state):
                f = self.fake
                f.build_uploads.clear()
                f.build_script["7"] = [None]
                f.add_upload(APP_ID, "7", state=state, created="2026-11-01T09:30:00Z")
                f.add_upload(APP_ID, "7", state="FAILED", created="2026-11-01T10:00:00Z",
                             errors=[{"code": "ITMS-90189", "description": "Redundant Binary Upload"}])
                proc = self.wait("--timeout-min", "1", "--poll-sec", "20")
                self.assertIn("sigue en proceso", self.annotation(proc, "warning")[0])
                self.assertEqual(self.annotations(proc, "error"), [])
                self.assertEqual(self.outputs()["processing_state"], "NOT_FOUND")

    def test_the_upload_check_survives_apples_false_404(self):
        f = self.fake
        f.build_script["7"] = [None]
        f.add_upload(APP_ID, "7", state="FAILED", errors=[{"code": "ITMS-90474", "description": "x"}])
        f.fail("GET", r"/v1/apps/[^/]+/buildUploads", 404, FALSE_404, times=1)
        self.wait(expect=1)
        self.assertEqual(self.outputs()["processing_state"], "FAILED")
        self.assertEqual(len(self.calls("GET", "/v1/builds")), 1)

    def test_timeout_warns_and_succeeds(self):
        self.fake.build_script["7"] = [None]
        proc = self.wait("--timeout-min", "1", "--poll-sec", "20")
        message = self.annotation(proc, "warning")[1]
        self.assertIn("7", message)
        self.assertIn("A veces Apple tarda más", message)
        self.assertNotIn("días", message)
        out = self.outputs()
        self.assertEqual((out["processed"], out["processing_state"], out["build_id"]), ("false", "NOT_FOUND", ""))
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_tester_setup_failures_only_warn(self):
        self.fake.build_script["7"] = ["VALID"]
        self.fake.fail("GET", "/v1/users", 403,
                       error_doc(403, "FORBIDDEN_ERROR", "This request is forbidden for security reasons"), times=99)
        proc = self.wait()
        message = self.annotation(proc, "warning")[1]
        self.assertIn("Pruebas internas", message)
        self.assertIn("Internal Testing", message)
        self.assertEqual(self.outputs()["processed"], "true")
        self.assertEqual(self.annotations(proc, "error"), [])


# ---------------------------------------------------------------- cleanup

class CleanupTest(AscTest):
    def write_state(self, state):
        path = os.path.join(self.tmp, "state.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
        return path

    def test_profiles_first_and_404_is_fine(self):
        self.fake.certificates = {"C1": {}}
        self.fake.profiles = {"P1": {}}                  # P2 is already gone
        proc = self.run_asc("cleanup", "--state", self.write_state({"cert_id": "C1", "profile_ids": ["P1", "P2"]}))
        self.assertEqual([c.path for c in self.calls("DELETE")],
                         ["/v1/profiles/P1", "/v1/profiles/P2", "/v1/certificates/C1"])
        self.assertEqual((self.fake.certificates, self.fake.profiles), ({}, {}))
        self.assertEqual(self.annotations(proc, "warning"), [])
        self.assertIn("already gone", self.summary())

    def test_ids_from_arguments_are_merged(self):
        self.fake.certificates = {"C1": {}}
        self.fake.profiles = {"P1": {}, "P3": {}}
        self.run_asc("cleanup", "--state", self.write_state({"cert_id": "C1", "profile_ids": ["P1"]}),
                     "--cert-id", "C1", "--profile-ids", "P1, P3")
        self.assertEqual([c.path for c in self.calls("DELETE")],
                         ["/v1/profiles/P1", "/v1/profiles/P3", "/v1/certificates/C1"])

    def test_failures_warn_with_manual_steps_and_exit_0(self):
        self.fake.certificates = {"C1": {}}
        self.fake.fail("DELETE", "/v1/certificates/C1", 500, error_doc(500, "UNEXPECTED_ERROR", "boom"), times=99)
        proc = self.run_asc("cleanup", "--cert-id", "C1")
        message = self.annotation(proc, "warning")[1]
        self.assertIn("certificates/list", message)
        self.assertIn("Revoca", message)
        self.assertIn("Revoke", message)

    def test_nothing_recorded(self):
        proc = self.run_asc("cleanup", "--state", os.path.join(self.tmp, "missing.json"))
        self.assertEqual(self.fake.requests, [])
        self.assertIn("Nothing to clean up", proc.stdout)

    def test_missing_secrets_warn_and_exit_0(self):
        proc = self.run_asc("cleanup", "--cert-id", "C1", env={"ASC_KEY_ID": None})
        self.assertIn("ASC_KEY_ID", self.annotation(proc, "warning")[1])

    def test_tampered_state_ids_are_not_used_in_urls(self):
        self.fake.profiles = {"P1": {}}
        proc = self.run_asc("cleanup", "--state", self.write_state({"cert_id": "../../v1/apps", "profile_ids": ["P1"]}))
        self.assertEqual([c.path for c in self.calls("DELETE")], ["/v1/profiles/P1"])
        self.assertIn("invalid id", self.annotation(proc, "warning")[1])

    def test_this_runs_certificates_are_found_by_the_csr_even_unrecorded(self):
        csr = make_csr(self.tmp)                         # csr.pem next to state.json
        os.unlink(os.path.join(self.tmp, "key.pem"))      # teardown deletes the key first
        ours = self.fake.issue(csr)
        foreign = self.fake.add_cert(KEYS.cert_der)
        development = self.fake.add_cert(KEYS.cert_der, kind="DEVELOPMENT")
        proc = self.run_asc("cleanup", "--state", self.write_state(
            {"cert_id": None, "profile_ids": [], "cert_pending": True}))
        self.assertEqual([c.path for c in self.calls("DELETE")], [f"/v1/certificates/{ours}"])
        self.assertEqual(set(self.fake.certificates), {foreign, development})
        self.assertEqual(self.calls("GET", "/v1/certificates")[0].query.get("filter[certificateType]"),
                         "DISTRIBUTION")
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_an_unconfirmed_request_that_cannot_be_checked_warns(self):
        make_csr(self.tmp)
        self.fake.fail("GET", "/v1/certificates", 500, SERVER_ERROR, times=99)
        proc = self.run_asc("cleanup", "--state", self.write_state(
            {"cert_id": None, "profile_ids": [], "cert_pending": True}))
        # The step's summary agrees with its warning (not «nothing to revoke»).
        self.assertIn("certificado sin confirmar: sigue el aviso «Certificado sin confirmar»", self.summary())
        self.assertNotIn("nada que revocar", self.summary())
        title, message = self.annotation(proc, "warning")
        self.assertIn("Certificado sin confirmar", title)
        for needle in ("no se pudo comprobar", "certificates/list", "«Apple Distribution» creado hoy", "HTTP 500"):
            self.assertIn(needle, message)
        self.assertNotIn(asc.URL_PROFILES, message)          # this run made no profile

    def test_an_unconfirmed_request_without_its_key_says_why(self):
        proc = self.run_asc("cleanup", "--state", self.write_state(
            {"cert_id": None, "profile_ids": [], "cert_pending": True}))     # no csr.pem next to it
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Certificado sin confirmar / Certificate not confirmed")
        self.assertIn("(no está csr.pem, la clave de esta ejecución)", message)
        self.assertIn("(csr.pem, this run's key, is missing)", message)
        self.assertNotIn("()", message)
        self.assertEqual(self.fake.requests, [])

    # A certificate request of this run that was cut off (a cancel) or got no clear answer
    # (state.json: cert_pending) may still be completed by Apple after the teardown's first look.

    def cut_off_request(self):
        csr = make_csr(self.tmp)
        os.unlink(os.path.join(self.tmp, "key.pem"))     # teardown deletes the key first
        return csr, self.write_state({"cert_id": None, "profile_ids": [], "cert_pending": True})

    def listings(self, after=None, fail_from=None):
        """Wrap GET /v1/certificates: `after(n)` runs after the n-th listing; from listing
        `fail_from` on, it answers 500."""
        real, count = self.fake.list_certs, [0]

        def listing(rec):
            if "cursor" not in rec.query:
                count[0] += 1
            if fail_from and count[0] >= fail_from:
                return 500, SERVER_ERROR
            result = real(rec)
            if after and "cursor" not in rec.query:
                after(count[0])
            return result
        self.fake.list_certs = listing
        return count

    def ours_alive(self):
        return [c for c in self.fake.created_certs if c in self.fake.certificates]

    def test_a_cut_off_request_that_apple_completes_later_is_revoked(self):
        csr, state = self.cut_off_request()
        count = self.listings(after=lambda n: n == 1 and self.fake.issue(csr))
        proc = self.run_asc("cleanup", "--state", state)
        self.assertEqual(len(self.fake.created_certs), 1)
        self.assertEqual(self.ours_alive(), [])
        self.assertEqual(self.annotations(proc, "warning"), [])
        self.assertEqual(count[0], 1 + len(asc.PENDING_RECHECK_SEC))

    def test_two_requests_the_second_completes_after_the_first_was_found(self):
        csr, state = self.cut_off_request()
        self.fake.issue(csr)                               # the first request made one already
        self.listings(after=lambda n: n == 1 and self.fake.issue(csr))
        self.run_asc("cleanup", "--state", state)
        self.assertEqual(len(self.fake.created_certs), 2)
        self.assertEqual(self.ours_alive(), [])

    def test_a_cut_off_request_whose_certificate_the_list_shows_late(self):
        csr, state = self.cut_off_request()
        self.fake.issue(csr)
        self.fake.cert_list_lag = 1
        self.run_asc("cleanup", "--state", state)
        self.assertEqual(self.ours_alive(), [])

    def test_a_failing_recheck_after_a_find_still_revokes_it_and_warns(self):
        csr, state = self.cut_off_request()
        self.fake.issue(csr)
        self.listings(fail_from=2)
        proc = self.run_asc("cleanup", "--state", state)
        self.assertEqual(self.ours_alive(), [])
        self.assertIn("Certificado sin confirmar", self.annotation(proc, "warning")[0])

    def test_a_cut_off_request_that_never_shows_up_needs_nothing_by_hand(self):
        _, state = self.cut_off_request()
        count = self.listings()
        proc = self.run_asc("cleanup", "--state", state)
        self.assertIn("nada que revocar / nothing to revoke (se buscó un rato", self.summary())
        self.assertEqual(self.annotations(proc, "warning"), [])
        self.assertEqual(count[0], 1 + len(asc.PENDING_RECHECK_SEC))

    def test_a_settled_run_is_listed_once(self):
        csr = make_csr(self.tmp)
        cert = self.fake.issue(csr)
        count = self.listings()
        self.run_asc("cleanup", "--state", self.write_state({"cert_id": cert, "profile_ids": [],
                                                             "cert_unclear": True}))
        self.assertEqual(count[0], 1)
        self.assertEqual(self.ours_alive(), [])

    def test_failures_name_the_certificate_the_way_the_portal_shows_it(self):
        self.fake.certificates = {"C1": {}}
        self.fake.profiles = {"P1": {}}
        self.fake.fail("DELETE", "/v1/.*", 500, error_doc(500, "UNEXPECTED_ERROR", "boom"), times=99)
        # The finish job: this run's profile names from its ids (its attempt may differ).
        proc = self.run_asc("cleanup", "--cert-id", "C1", "--profile-ids", "P1", env={"GITHUB_RUN_ID": "112"})
        message = self.annotation(proc, "warning")[1]
        for needle in ("el certificado «Apple Distribution» creado hoy (id C1)",
                       "los perfiles «OpenCfMoto CI r123-112-… app» y «OpenCfMoto CI r123-112-… mirror» que queden "
                       "(id P1), cada uno ▸ Remove (ningún otro «OpenCfMoto CI …»)",
                       "the «Apple Distribution» certificate created today (id C1)"):
            self.assertIn(needle, message)
        self.assertNotIn("«OpenCfMoto CI …» (id P1)", message)
        # The teardown knows the exact suffix create-signing used.
        proc = self.run_asc("cleanup", "--profile-ids", "P1", "--suffix", "r123-112-1")
        message = self.annotation(proc, "warning")[1]
        self.assertIn("«OpenCfMoto CI r123-112-1 app» y «OpenCfMoto CI r123-112-1 mirror» que queden (id P1)", message)
        self.assertNotIn(asc.URL_CERTIFICATES, message)      # only a profile failed: no certificate to hunt for
        # ...and the build number it put in the names (recorded by build_and_sign.sh), over BUILD_NUMBER.
        for env, build in (({}, "8"), ({"BUILD_NUMBER": "9"}, "8")):
            proc = self.run_asc("cleanup", "--profile-ids", "P1", "--suffix", "r123-112-1", "--build", build, env=env)
            self.assertIn("«OpenCfMoto CI r123-112-1 b8 app» y «OpenCfMoto CI r123-112-1 b8 mirror» que queden (id P1)",
                          self.annotation(proc, "warning")[1])
        proc = self.run_asc("cleanup", "--profile-ids", "P1", "--suffix", "r123-112-1", env={"BUILD_NUMBER": "9"})
        self.assertIn("«OpenCfMoto CI r123-112-1 b9 app»", self.annotation(proc, "warning")[1])   # the finish job

    def test_what_a_listing_shows_is_revoked_before_the_next_look(self):
        # The DELETEs do not wait for the re-checks (a minute or more): GitHub stops Clean up a few
        # minutes after a cancel, and what was revoked by then stays revoked.
        csr = make_csr(self.tmp)
        os.unlink(os.path.join(self.tmp, "key.pem"))
        ours = self.fake.issue(csr)
        self.fake.profiles = {"P1": {}}
        seen = []
        self.listings(after=lambda n: seen.append([c.path for c in self.calls("DELETE")]))
        proc = self.run_asc("cleanup", "--state", self.write_state(
            {"cert_id": None, "profile_ids": ["P1"], "cert_pending": True}))
        self.assertEqual(len(seen), 1 + len(asc.PENDING_RECHECK_SEC))
        self.assertEqual(seen[0], [])
        self.assertEqual(seen[1], ["/v1/profiles/P1", f"/v1/certificates/{ours}"])
        self.assertEqual([c.path for c in self.calls("DELETE")], seen[1])      # each one once
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_slow_answers_end_the_search_in_time_and_warn(self):
        # Re-checks stop once Clean up has used its budget (real time: GitHub's limit); what was
        # found is revoked, and the warning says the check could not be finished.
        csr = make_csr(self.tmp)
        os.unlink(os.path.join(self.tmp, "key.pem"))
        ours = self.fake.issue(csr)
        count = self.listings()
        state = self.write_state({"cert_id": None, "profile_ids": [], "cert_pending": True})
        with mock.patch.object(asc, "PENDING_RECHECK_BUDGET_SEC", 0):
            code, output = self.run_in_process("cleanup", "--state", state)
        self.assertEqual(code, 0, output)
        self.assertEqual(count[0], 1)
        self.assertEqual([c.path for c in self.calls("DELETE")], [f"/v1/certificates/{ours}"])
        title, message = self.annotation(types.SimpleNamespace(stdout=output, stderr=""), "warning")
        self.assertEqual(title, "Certificado sin confirmar / Certificate not confirmed")
        for needle in ("se dejó de buscar para que este paso termine a tiempo", "the search stopped for this step "
                       "to end in time", "creado hoy, púlsalo ▸ Revoke"):
            self.assertIn(needle, message)
        self.assertIn("certificado sin confirmar: sigue el aviso", self.summary())

    # cleanup --duplicates-only: the teardown of a build that reached Apple.

    def test_duplicates_only_revokes_a_second_certificate_and_keeps_the_builds(self):
        csr = make_csr(self.tmp)
        os.unlink(os.path.join(self.tmp, "key.pem"))
        first, second = self.fake.issue(csr), self.fake.issue(csr)
        foreign = self.fake.add_cert(KEYS.cert_der)
        profile = self.fake.add_profile(f"OpenCfMoto CI r{REPO_ID}-5-1 app", [second])
        proc = self.run_asc("cleanup", "--duplicates-only", "--state", self.write_state(
            {"cert_id": second, "profile_ids": [profile], "cert_unclear": True}))
        self.assertEqual([c.path for c in self.calls("DELETE")], [f"/v1/certificates/{first}"])
        self.assertEqual(set(self.fake.certificates), {second, foreign})
        self.assertEqual(list(self.fake.profiles), [profile])
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_duplicates_only_does_nothing_after_clear_answers(self):
        make_csr(self.tmp)
        for state in ({"cert_id": "C1", "profile_ids": ["P1"]}, None):
            path = self.write_state(state) if state else os.path.join(self.tmp, "missing.json")
            proc = self.run_asc("cleanup", "--duplicates-only", "--state", path)
            self.assertEqual(self.fake.requests, [])
            self.assertEqual(self.annotations(proc, "warning"), [])

    def test_duplicates_only_never_points_at_the_builds_certificate(self):
        # Its warnings never give the generic steps («revoke the certificate created today»): that
        # one is still needed until the finish job has waited for Apple's processing, and it stays
        # after it too when Apple accepts the build. Only the duplicate may go, when told apart.
        make_csr(self.tmp)
        state = self.write_state({"cert_id": "C9", "profile_ids": ["P1"], "cert_pending": True})
        self.fake.fail("GET", "/v1/certificates", 500, SERVER_ERROR, times=99)
        for env in ({}, {"ASC_KEY_ID": None}):
            with self.subTest(env=env):
                proc = self.run_asc("cleanup", "--duplicates-only", "--state", state, env=env)
                title, message = self.annotation(proc, "warning")
                self.assertEqual(title, "Certificado sin confirmar / Certificate not confirmed")
                for needle in (f"Cuando termine el trabajo «{asc.FINISH_JOB}», el certificado de esta build sigue en "
                               "la cuenta si Apple la aceptó", "no lo revoques mientras esa build esté en revisión",
                               "revoca solo el duplicado", "Ante la duda, déjalo: no firma nada",
                               f"Once the «{asc.FINISH_JOB}» job has finished, this build's certificate stays",
                               "revoke only the duplicate", "When in doubt, leave it"):
                    self.assertIn(needle, message)
                for wrong in ("Revoca a mano lo que quede", "si aún queda un certificado «Apple Distribution» creado hoy",
                              "«Processing, TestFlight group, revoke the certificate»"):
                    self.assertNotIn(wrong, message)
                self.assertEqual(self.calls("DELETE"), [])


# ---------------------------------------------------------------- build_and_sign.sh steps

class RedactApiPathTest(unittest.TestCase):
    def test_ids_and_query_values_are_never_shown(self):
        for path, shown in (
                ("/v1/certificates/CERTID12345", "/v1/certificates/…"),
                ("/v1/profiles/PROFID67890", "/v1/profiles/…"),
                ("/v1/bundleIds/B0001/bundleIdCapabilities", "/v1/bundleIds/…/bundleIdCapabilities"),
                ("/v1/profiles/P1/relationships/certificates?limit=200",
                 "/v1/profiles/…/relationships/certificates?limit=…"),
                ("/v1/apps/1234567890/buildUploads?filter[cfBundleVersion]=7&limit=200",
                 "/v1/apps/…/buildUploads?filter[cfBundleVersion]=…&limit=…"),
                ("/v1/apps?filter[bundleId]=com.t.opencfmoto", "/v1/apps?filter[bundleId]=…"),
                ("/v1/profiles?filter[name]=OpenCfMoto%20CI%20r123-1-1%20app&include=certificates",
                 "/v1/profiles?filter[name]=…&include=…"),
                ("/v2/appStoreVersionExperiments/X1", "/v2/appStoreVersionExperiments/…"),
                ("/v1/apps", "/v1/apps"),
                ("/v1/certificates", "/v1/certificates"),
                ("/v1/buildUploads?", "/v1/buildUploads?")):
            self.assertEqual(asc.redact_api_path(path), shown, path)


class PublicLogIdsTest(AscTest):
    """The log and the step summary are public: request lines and API errors show no resource id
    and no query value, and the summaries name what was made by type and name. Ids show only where
    the owner may have to revoke or delete something by hand (manual_revoke and the cleanup
    warnings), never the team ID."""

    def seed(self):
        f = self.fake
        app, mirror = f.add_bundle(APP_BID), f.add_bundle(MIRROR_BID)
        f.capabilities[app["id"]] = ["APP_GROUPS", "HOT_SPOT", "ACCESS_WIFI_INFORMATION"]
        f.capabilities[mirror["id"]] = ["APP_GROUPS"]
        f.assigned_groups = {APP_BID: [GROUP], MIRROR_BID: [GROUP]}
        f.add_app(APP_BID, APP_ID)
        return app["id"], mirror["id"]

    def public_text(self, proc):
        summary = self.summary() if os.path.exists(self.step_summary) else ""
        return proc.stdout + proc.stderr + summary

    def assert_no_ids(self, proc, ids):
        text = self.public_text(proc)
        for resource_id in ids:
            self.assertTrue(resource_id)
            self.assertNotIn(resource_id, text, f"id {resource_id!r} printed:\n{self.transcript(proc)}")

    def test_prepare_names_the_app_record_without_its_id(self):
        app, mirror = self.seed()
        proc = self.run_asc("prepare", "--prefix", PREFIX, "--project-yml", self.project_yml)
        self.assertEqual(self.outputs()["app_id"], APP_ID)            # the next jobs still get it
        self.assert_no_ids(proc, [APP_ID, app, mirror, TEAM])
        self.assertIn("| App en App Store Connect / app record | encontrada / found |", self.summary())
        self.assertIn("  GET /v1/bundleIds/…/bundleIdCapabilities -> 200", proc.stdout)

    def test_signing_upload_and_cleanup_print_no_ids(self):
        app, mirror = self.seed()
        out_dir = os.path.join(self.tmp, "signing")
        proc = self.run_asc("create-signing", "--app-bundle-resource-id", app, "--mirror-bundle-resource-id", mirror,
                            "--app-bundle-id", APP_BID, "--mirror-bundle-id", MIRROR_BID, "--app-group", GROUP,
                            "--out", out_dir, "--suffix", "4242-1")
        out = self.outputs()
        made = [out["cert_id"], out["profile_app_id"], out["profile_mirror_id"], out["profile_app_uuid"],
                out["profile_mirror_uuid"]]
        self.assert_no_ids(proc, [app, mirror, TEAM] + made)
        summary = self.summary()
        self.assertIn("| Certificado / certificate | Apple Distribution (temporal, de esta ejecución / "
                      "temporary, this run's) |", summary)
        self.assertIn("| Perfil / profile (app) | OpenCfMoto CI 4242-1 app — App Group: sí / yes", summary)

        ipa = os.path.join(self.tmp, "OpenCfMoto.ipa")
        with open(ipa, "wb") as fh:
            fh.write(bytes(range(256)) * 4)
        proc = self.run_asc("upload", "--ipa", ipa, "--app-id", APP_ID, "--version", "2.3.4", "--build", "7")
        self.assertEqual(self.outputs()["uploaded"], "true")
        self.assert_no_ids(proc, [APP_ID, self.outputs()["upload_id"], *self.fake.upload_files] + made)

        proc = self.run_asc("cleanup", "--state", os.path.join(out_dir, "state.json"))
        self.assertEqual(self.annotations(proc, "warning"), [])
        self.assert_no_ids(proc, made)
        self.assertIn("revocado o borrado / revoked or deleted: profile, profile, certificate.", self.summary())
        self.assertIn("  DELETE /v1/certificates/… -> 204", proc.stdout)

    def test_keeping_and_retiring_signing_sets_print_no_ids(self):
        self.seed()
        f = self.fake
        made = []
        for build in (6, 7):
            f.add_build(APP_ID, str(build))
            cert = f.add_cert(KEYS.cert_der)
            made += [cert] + [f.add_profile(f"OpenCfMoto CI r{REPO_ID}-{100 + build}-1 b{build} {role}", [cert])
                              for role in ("app", "mirror")]
        proc = self.run_asc("settle-signing", "--app-id", APP_ID, "--build", "7", "--state", "VALID", "--run-id", "107",
                            "--cert-id", made[3], "--profile-ids", f"{made[4]},{made[5]}")
        self.assertNotIn(made[0], f.certificates)
        self.assert_no_ids(proc, [APP_ID, TEAM] + made + [b["id"] for _, b in f.builds])
        self.assertIn("  GET /v1/builds?filter[app]=…&include=…&limit=… -> 200", proc.stdout)

    def test_ids_only_in_what_the_owner_revokes_by_hand(self):
        self.fake.certificates = {"C1": {}}
        self.fake.profiles = {"P1": {}}
        self.fake.fail("DELETE", "/v1/certificates/C1", 500, error_doc(500, "UNEXPECTED_ERROR", "boom"), times=99)
        proc = self.run_asc("cleanup", "--cert-id", "C1", "--profile-ids", "P1")
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Limpieza incompleta / Cleanup incomplete")
        self.assertIn("certificate C1: DELETE /v1/certificates/… → HTTP 500", message)
        self.assertIn("(id C1)", message)                              # how to find it by hand
        self.assertNotIn("/v1/certificates/C1", proc.stdout)
        self.assertNotIn("P1", message)                                # deleted: nothing to look for
        self.assertNotIn("/v1/profiles/P1", proc.stdout)
        self.assertIn("revocado o borrado / revoked or deleted: profile.", self.summary())


class ScriptTest(AscTest):
    """Runs shell code with /bin/bash (3.2 on macOS, as on the TestFlight runner) and a python3 on
    PATH that is this interpreter, against the fake."""

    def setUp(self):
        super().setUp()
        self.bindir = os.path.join(self.tmp, "bin")
        os.makedirs(self.bindir)
        shim = os.path.join(self.bindir, "python3")
        with open(shim, "w", encoding="utf-8") as fh:
            fh.write(f'#!/bin/sh\nexec "{sys.executable}" "$@"\n')
        os.chmod(shim, 0o755)

    def bash(self, args, env, expect=0, cwd=None):
        full = self.asc_env(env)
        full["PATH"] = self.bindir + os.pathsep + full["PATH"]
        proc = subprocess.run([BASH] + list(args), env=full, cwd=cwd or REPO, capture_output=True,
                              encoding="utf-8", errors="replace", timeout=300)
        if expect is not None:
            self.assertEqual(proc.returncode, expect, f"bash {' '.join(args)} exited {proc.returncode}\n"
                                                      f"{self.transcript(proc)}")
        return proc


class BuildScriptTest(ScriptTest):
    """tools/testflight/build_and_sign.sh create-signing, install-profiles and teardown (the steps
    that do not need macOS) with the real asc.py."""

    def setUp(self):
        super().setUp()
        f = self.fake
        self.app, self.mirror = f.add_bundle(APP_BID), f.add_bundle(MIRROR_BID)
        f.capabilities[self.app["id"]] = ["APP_GROUPS", "HOT_SPOT", "ACCESS_WIFI_INFORMATION"]
        f.capabilities[self.mirror["id"]] = ["APP_GROUPS"]
        f.assigned_groups = {APP_BID: [GROUP], MIRROR_BID: [GROUP]}
        self.work = os.path.join(self.tmp, "work")
        self.signing = os.path.join(self.work, "signing")

    def step_env(self, env=None):
        base = {"TF_WORK": self.work, "APP_BUNDLE_RESOURCE_ID": self.app["id"],
                "MIRROR_BUNDLE_RESOURCE_ID": self.mirror["id"], "APP_BUNDLE_ID": APP_BID,
                "MIRROR_BUNDLE_ID": MIRROR_BID, "APP_GROUP": GROUP, "GITHUB_RUN_ID": "4242",
                "GITHUB_RUN_ATTEMPT": "1", "BUILD_NUMBER": "7", "TF_LEFTOVER_WAIT_SEC": "0",
                "TF_KILL_WAIT_SEC": "1"}
        base.update(env or {})
        return base

    def step(self, name, env=None, expect=0):
        return self.bash([SCRIPT_PATH, name], self.step_env(env), expect=expect)

    def start_step(self, name, env=None):
        """The step in its own process group, not waited for (the test cuts it off)."""
        full = self.asc_env(self.step_env(env))
        full["PATH"] = self.bindir + os.pathsep + full["PATH"]
        return subprocess.Popen([BASH, SCRIPT_PATH, name], env=full, cwd=REPO, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, encoding="utf-8", errors="replace",
                                start_new_session=True)

    def alive(self):
        return [c for c in self.fake.created_certs if c in self.fake.certificates]

    def unclear_certificate_then_uploaded(self):
        """create-signing after a certificate request without a clear answer (state.json keeps
        cert_unclear, so the teardown looks for a duplicate), then an upload that got through."""
        self.fake.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        self.step("create-signing")
        open(os.path.join(self.work, "uploaded"), "w").close()

    def hang_listings(self):
        """GET /v1/certificates hangs (Apple's API not answering) until the test ends."""
        release, real = threading.Event(), self.fake.list_certs
        self.addCleanup(release.set)
        self.server.handle_error = lambda *args: None      # the answer then goes to a closed socket

        def hanging(rec):
            release.wait(20)
            return real(rec)
        self.fake.list_certs = hanging

    def test_a_teardown_cut_off_while_it_asks_apple_has_already_said_uploaded(self):
        # GitHub stops Clean up a few minutes after a cancel or at the job's time limit. Cut off
        # while asking Apple about a duplicate, it must already have said uploaded=true: otherwise
        # the finish job takes the job for one that lost its runner and revokes the build's
        # certificate at once, before Apple has processed the build.
        self.unclear_certificate_then_uploaded()
        before = len(self.calls("GET", "/v1/certificates"))
        self.hang_listings()
        proc = self.start_step("teardown")
        try:
            deadline = time.monotonic() + 60
            while (len(self.calls("GET", "/v1/certificates")) == before and proc.poll() is None
                   and time.monotonic() < deadline):
                time.sleep(0.05)
            self.assertGreater(len(self.calls("GET", "/v1/certificates")), before, "the teardown never asked Apple")
            self.assertEqual(self.outputs().get("uploaded"), "true")
        finally:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate(timeout=30)
        self.assertNotIn("teardown", self.outputs())            # it was cut off before its end
        self.assertEqual(len(self.alive()), 1)                  # the build's certificate stays

    def test_the_look_for_a_duplicate_is_bounded_and_then_warns(self):
        self.unclear_certificate_then_uploaded()
        self.hang_listings()
        proc = self.step("teardown", env={"TF_DUPLICATES_WAIT_SEC": "2"})
        out = self.outputs()
        self.assertEqual((out["uploaded"], out["teardown"]), ("true", "done"))
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Certificado sin confirmar / Certificate not confirmed")
        name = f"OpenCfMoto CI r{REPO_ID}-4242-1 b7"
        for needle in ("App Store Connect no respondió a tiempo (2 s)", "did not answer in time (2 s)",
                       f"Cuando termine el trabajo «{asc.FINISH_JOB}», el certificado de esta build sigue en la "
                       f"cuenta si Apple la aceptó (lo usan sus perfiles «{name} app» y «… mirror»)",
                       "no lo revoques mientras esa build esté en revisión", "Ante la duda, déjalo",
                       f"its profiles «{name} app» and «… mirror» use it", "When in doubt, leave it",
                       asc.URL_CERTIFICATES):
            self.assertIn(needle, message)
        for wrong in ("Revoca a mano lo que quede", "si aún queda un certificado"):   # never the build's own
            self.assertNotIn(wrong, message)
        self.assertEqual(len(self.alive()), 1)

    def test_the_teardown_without_the_key_names_only_this_runs_profiles(self):
        self.step("create-signing")
        proc = self.step("teardown", env={"ASC_KEY_ID": None, "ASC_ISSUER_ID": None, "ASC_PRIVATE_KEY": None})
        out = self.outputs()
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Revoca a mano / Revoke by hand")
        name = f"OpenCfMoto CI r{REPO_ID}-4242-1 b7"
        for needle in (f"borra los perfiles «{name} app» y «{name} mirror» (ids {out['profile_ids']}) (cada uno ▸ "
                       "Remove; ningún otro «OpenCfMoto CI …»)",
                       f"delete the «{name} app» and «{name} mirror» profiles (ids {out['profile_ids']})",
                       f"revoca el certificado «Apple Distribution» creado hoy (id {out['cert_id']})",
                       asc.KEPT_CAUTION_ES, asc.KEPT_CAUTION_EN):
            self.assertIn(needle, message)
        self.assertNotIn("los perfiles «OpenCfMoto CI …»", message)
        self.assertEqual((len(self.alive()), len(self.fake.profiles)), (1, 2))   # nothing revoked without it

    def test_the_teardown_names_this_runs_profiles_when_it_cannot_delete_them(self):
        self.step("create-signing")
        self.fake.fail("DELETE", r"/v1/profiles/.*", 500, SERVER_ERROR, times=99)
        proc = self.step("teardown")
        self.assertEqual(self.alive(), [])                       # the certificate went
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Limpieza incompleta / Cleanup incomplete")
        name = f"OpenCfMoto CI r{REPO_ID}-4242-1 b7"
        self.assertIn(f"Borra a mano lo que quede. En {asc.URL_PROFILES}: los perfiles «{name} app» y "
                      f"«{name} mirror» que queden (ids ", message)
        for wrong in ("los perfiles «OpenCfMoto CI …»", asc.URL_CERTIFICATES):
            self.assertNotIn(wrong, message)

    def test_the_teardown_of_an_uploaded_build_revokes_only_a_duplicate_certificate(self):
        f = self.fake
        f.cert_list_lag = 1                 # the look after the unanswered request misses its certificate
        f.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        real, listings = f.list_certs, []

        def failing_after_the_first(rec):
            if "cursor" not in rec.query:
                listings.append(rec)
            return (500, SERVER_ERROR) if len(listings) >= 2 else real(rec)
        f.list_certs = failing_after_the_first
        self.step("create-signing")
        first, second = f.created_certs
        with open(os.path.join(self.signing, "state.json"), encoding="utf-8") as fh:
            state = json.load(fh)
        self.assertEqual((state["cert_id"], state.get("cert_pending")), (second, True))
        f.list_certs = real
        open(os.path.join(self.work, "uploaded"), "w").close()    # the upload step got through
        proc = self.step("teardown")
        self.assertEqual(self.alive(), [second])                   # the build's certificate stays
        self.assertEqual(sorted(info["name"] for info in f.profiles.values()),
                         [f"OpenCfMoto CI r{REPO_ID}-4242-1 b7 app", f"OpenCfMoto CI r{REPO_ID}-4242-1 b7 mirror"])
        out = self.outputs()
        self.assertEqual((out["uploaded"], out["teardown"]), ("true", "done"))
        self.assertEqual(self.annotations(proc, "warning"), [])
        self.assertFalse(os.path.exists(os.path.join(self.signing, "key.pem")))
        # The finish job then revokes the build's certificate and profiles by their ids.
        self.run_asc("cleanup", "--cert-id", out["cert_id"], "--profile-ids", out["profile_ids"])
        self.assertEqual((self.alive(), f.profiles), ([], {}))

    def test_the_teardown_of_an_uploaded_build_after_clear_answers_asks_apple_nothing(self):
        self.step("create-signing")
        open(os.path.join(self.work, "committed"), "w").close()   # Apple has (or may have) the file
        before = len(self.fake.requests)
        self.step("teardown")
        self.assertEqual(len(self.fake.requests), before)
        self.assertEqual(self.outputs()["uploaded"], "true")
        self.assertEqual(len(self.alive()), 1)

    def test_a_second_manual_run_installs_only_its_own_profiles(self):
        # `build_and_sign.sh all` on a Mac, twice, with the same work directory (no GitHub run).
        mac = {"GITHUB_RUN_ID": None, "GITHUB_RUN_ATTEMPT": None, "GITHUB_REPOSITORY_ID": None,
               "GITHUB_ACTIONS": None, "GITHUB_OUTPUT": None, "GITHUB_STEP_SUMMARY": None}
        names = []
        for _ in range(2):
            self.step("create-signing", env=mac)
            self.assertEqual(len(os.listdir(os.path.join(self.signing, "profiles"))), 2)
            names += [info["name"] for info in self.fake.profiles.values()]
            self.step("install-profiles", env=mac)
            installed = os.path.join(self.tmp, "Library", "MobileDevice", "Provisioning Profiles")
            self.assertEqual(len(os.listdir(installed)), 2)
            self.step("teardown", env=mac)                           # not uploaded: revoked at once
            self.assertEqual((self.alive(), self.fake.profiles), ([], {}))
        for name in names:
            self.assertRegex(name, r"^OpenCfMoto CI local[0-9]{14}-1 b7 (app|mirror)$")
            self.assertTrue(asc.CI_PROFILE_RE.fullmatch(name))


class SigningLogPrivacyTest(ScriptTest):
    """build_and_sign.sh setup-keychain and archive with fake macOS tools (uname, security, curl,
    openssl, xcodebuild): the log is public, and a signing identity is named after the account
    holder, so identities are only counted and tool output never shows a name or the team ID."""

    NAME, OTHER_TEAM = "Jane Q Pérez", "ZYXWV98765"
    SHA1, SHA2 = "0123456789ABCDEF0123456789ABCDEF01234567", "89ABCDEF0123456789ABCDEF0123456789ABCDEF"

    def setUp(self):
        super().setUp()
        self.work = os.path.join(self.tmp, "work")
        self.signing = os.path.join(self.work, "signing")
        self.fakes = os.path.join(self.tmp, "fakes")
        os.makedirs(self.signing)
        os.makedirs(self.fakes)
        for name in ("key.pem", "cert.pem"):
            with open(os.path.join(self.signing, name), "w", encoding="ascii") as fh:
                fh.write("not a real key or certificate\n")
        tools = {
            "uname": "#!/bin/sh\necho Darwin\n",
            "curl": '#!/bin/bash\nout=""; prev=""\nfor a in "$@"; do [ "$prev" = -o ] && out=$a; prev=$a; done\n'
                    'printf der > "$out"\n',
            "security": '#!/bin/bash\ncase "$1" in\n'
                        '  find-identity) if [ "$2" = -v ]; then cat "$FAKES/valid.txt"; else cat "$FAKES/all.txt"; fi ;;\n'
                        '  list-keychains) [ "$3" = -s ] || echo \'    "/fake/login.keychain-db"\' ;;\n'
                        'esac\nexit 0\n',
            "xcodebuild": '#!/bin/bash\ncat "$FAKES/xcodebuild.txt"\nexit 65\n',
            "openssl": '#!/bin/bash\n'
                       'wwdr="CN = Apple Worldwide Developer Relations Certification Authority, OU = G3, '
                       'O = Apple Inc., C = US"\n'
                       'case "$1" in\n'
                       '  version) echo "LibreSSL 3.3.6" ;;\n'
                       '  rand) echo 0123456789abcdef0123456789abcdef0123456789abcdef ;;\n'
                       '  pkcs12) prev=""; for a in "$@"; do [ "$prev" = -out ] && printf p12 > "$a"; prev=$a; done ;;\n'
                       '  x509) case "$*" in *-issuer*) echo "issuer=$wwdr" ;; *) echo "subject=$wwdr" ;; esac ;;\n'
                       'esac\n',
        }
        for name, text in tools.items():
            path = os.path.join(self.bindir if name != "openssl" else self.fakes, name)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
            os.chmod(path, 0o755)

    def identities(self, valid, everything):
        for name, text in (("valid.txt", valid), ("all.txt", everything)):
            with open(os.path.join(self.fakes, name), "w", encoding="utf-8") as fh:
                fh.write(text)

    def run_step(self, name, env=None, expect=0):
        base = {"TF_WORK": self.work, "TF_SIGNING_DIR": self.signing, "OPENSSL": os.path.join(self.fakes, "openssl"),
                "FAKES": self.fakes}
        base.update(env or {})
        return self.bash([SCRIPT_PATH, name], base, expect=expect)

    def assert_nobody_named(self, proc):
        public = proc.stdout + proc.stderr + self.summary()
        for private in (self.NAME, "Jane", "Pérez", TEAM, self.OTHER_TEAM):
            self.assertNotIn(private, public)

    def test_setup_keychain_counts_the_identity_and_never_prints_it(self):
        line = f'  1) {self.SHA1} "Apple Distribution: {self.NAME} ({TEAM})"'
        self.identities(f"{line}\n     1 valid identities found\n",
                        f"Policy: Code Signing\n  Matching identities\n{line}\n     1 identities found\n\n"
                        f"  Valid identities only\n{line}\n     1 valid identities found\n")
        proc = self.run_step("setup-keychain")
        self.assertIn("(1 Apple Distribution identity; name and team not shown)", proc.stdout)
        self.assert_nobody_named(proc)
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_no_valid_distribution_identity_fails_without_naming_any(self):
        development = f'  1) {self.SHA2} "Apple Development: {self.NAME} ({self.OTHER_TEAM})"'
        untrusted = f'  2) {self.SHA1} "Apple Distribution: {self.NAME} ({TEAM})" (CSSMERR_TP_NOT_TRUSTED)'
        self.identities("     0 valid identities found\n",
                        f"Policy: Code Signing\n  Matching identities\n{development}\n{untrusted}\n"
                        "     2 identities found\n\n  Valid identities only\n     0 valid identities found\n")
        proc = self.run_step("setup-keychain", expect=1)
        title, message = self.annotation(proc, "error")
        self.assertEqual(title, "TestFlight (setup-keychain)")
        self.assertIn("identidades de firma en el llavero, válidas o no: 2", message)
        self.assertIn("code-signing identities in the keychain, valid or not: 2", message)
        self.assert_nobody_named(proc)

    def test_a_failed_archive_shows_and_annotates_no_name_and_no_team_id(self):
        with open(os.path.join(self.work, "state.env"), "w", encoding="utf-8") as fh:
            fh.write(f"S_TEAM_ID={TEAM}\n")
        with open(os.path.join(self.work, "keychain-password"), "w", encoding="ascii") as fh:
            fh.write("x")
        with open(os.path.join(self.fakes, "xcodebuild.txt"), "w", encoding="utf-8") as fh:
            fh.write(f'Signing Identity:     "Apple Distribution: {self.NAME} ({TEAM})"\n'
                     f"    DEVELOPMENT_TEAM = {TEAM}\n"
                     f"/w/App/Sources/A.swift:3:1: error: No signing certificate for team {TEAM}\n"
                     f'error: Provisioning profile "OpenCfMoto CI app" doesn\'t include signing certificate '
                     f'"Apple Development: {self.NAME} ({self.OTHER_TEAM})".\n'
                     f"error: CN = iPhone Distribution: {self.NAME} ({self.OTHER_TEAM})\n"
                     "** ARCHIVE FAILED **\n")
        proc = self.run_step("archive", env={"BUILD_NUMBER": "7", "APP_GROUP": GROUP}, expect=1)
        self.assert_nobody_named(proc)
        self.assertIn('"Apple Development: <name>"', proc.stdout)                 # what failed stays readable
        self.assertIn("DEVELOPMENT_TEAM = <team id>", proc.stdout)
        self.assertIn("No signing certificate for team <team id>", proc.stdout)    # the annotation too
        self.assertIn("** ARCHIVE FAILED **", proc.stdout)
        title, _message = self.annotation(proc, "error")
        self.assertEqual(title, "TestFlight (archive)")


# ---------------------------------------------------------------- workflow shell blocks

def workflow_steps(path=WORKFLOW_PATH):
    """{(job id, step name): the step's `run:` script} of a workflow file. A small reader for this
    repository's own layout (block scalars, two-space indents): the macOS python3 has no YAML
    module."""
    steps, job, name, in_jobs = {}, None, None, False
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if line == "jobs:":
            in_jobs = True
            continue
        match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if in_jobs and match:
            job, name = match.group(1), None
            continue
        match = re.match(r"^(\s*)- (name|uses): (.*)$", line)
        if match:
            name = match.group(3).strip() if match.group(2) == "name" else None
            continue
        match = re.match(r"^(\s*)run: (.*)$", line)
        if match and job and name:
            if match.group(2).strip() != "|":
                steps[(job, name)] = match.group(2).strip()
                continue
            block, indent = [], None
            while i < len(lines):
                text = lines[i]
                if text.strip():
                    width = len(text) - len(text.lstrip(" "))
                    if indent is None:
                        indent = width
                    if width < indent:
                        break
                block.append(text[indent:] if indent is not None else "")
                i += 1
            steps[(job, name)] = "\n".join(block).rstrip("\n") + "\n"
    return steps


class WorkflowTextTest(ScriptTest):
    """What the TestFlight workflow's own shell blocks tell the owner, run the way GitHub runs them
    (bash --noprofile --norc -eo pipefail) with each case's step environment."""

    STEPS = None

    def run_step(self, job, name, env, expect=0, cwd=None):
        if WorkflowTextTest.STEPS is None:
            WorkflowTextTest.STEPS = workflow_steps()
        script = self.STEPS[(job, name)]
        self.assertNotIn("${{", script)                       # only env reaches the scripts
        path = os.path.join(self.tmp, "step.sh")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(script)
        base = {"GITHUB_SERVER_URL": "https://github.com", "GITHUB_REPOSITORY": "owner/opencfmoto-ios",
                "GITHUB_RUN_ID": "112", "MARKETING_VERSION": "2.3.4", "BUILD_NUMBER": "7"}
        base.update(env)
        return self.bash(["--noprofile", "--norc", "-eo", "pipefail", path], base, expect=expect, cwd=cwd)

    def test_the_prefix_error_title_is_bilingual(self):
        proc = self.run_step("prepare", "Bundle id prefix", {"PREFIX_VARIABLE": "com.bad prefix", "OWNER": "x"},
                             expect=1)
        title, message = self.annotation(proc, "error")
        self.assertEqual(title, "Prefijo no válido / Invalid prefix")
        self.assertIn("BUNDLE_ID_PREFIX", message)
        self.assertIn("El prefijo «com.bad prefix» no es válido", message)
        self.run_step("prepare", "Bundle id prefix", {"PREFIX_VARIABLE": "", "OWNER": "Kevinparra535"})
        self.assertEqual(self.outputs()["prefix"], "com.kevinparra535")

    def test_no_variable_name_runs_into_a_non_ascii_character(self):
        # macOS bash with a non-UTF-8 locale (bash 3.2 here) takes the first byte of «, », ▸ or …
        # right after $name as part of the name: «$app» expands the unset $app\xc2 (an error under
        # set -u, an empty text without it). ${app} is safe everywhere.
        for path in (SCRIPT_PATH, WORKFLOW_PATH):
            with open(path, "rb") as fh:
                for number, line in enumerate(fh, 1):
                    found = re.search(rb"\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]", line)
                    self.assertIsNone(found, f"{os.path.basename(path)}:{number}: use ${{name}} before a non-ASCII "
                                             f"character: {found.group(0) if found else b''!r}")

    def build_summary(self, **env):
        open(self.step_summary, "w").close()
        self.run_step("build", "Summary", dict({"UPLOAD_OUTCOME": "", "METHOD": ""}, **env))
        return self.summary()

    def test_the_build_summary_names_a_revocation_only_when_a_certificate_was_made(self):
        for outcome, made in (("skipped", False), ("failure", True), ("success", True)):
            with self.subTest(signing=outcome):
                text = self.build_summary(UPLOADED="false", UPLOAD_OUTCOME="skipped", SIGNING_OUTCOME=outcome)
                self.assertIn("No se subió ninguna build", text)
                self.assertEqual("El paso «Clean up» revoca el certificado" in text, made)
                self.assertEqual("The «Clean up» step revokes the temporary certificate" in text, made)

    def test_the_build_summary_after_a_cancel_during_the_upload_stays_true(self):
        for outcome in ("cancelled", "failure"):
            with self.subTest(upload=outcome):
                text = self.build_summary(UPLOADED="true", UPLOAD_OUTCOME=outcome, SIGNING_OUTCOME="success")
                for needle in ("Apple tiene (o puede tener) el archivo", "(si no cancelaste la ejecución)",
                               "Apple has (or may have) the file", "(unless you cancelled the run)"):
                    self.assertIn(needle, text)
                self.assertNotIn("ya llegó a Apple", text)

    def revoke_step(self, cwd=None, **env):
        open(self.step_summary, "w").close()
        return self.run_step("finish", "Keep or revoke the signing certificate and profiles",
                             dict({"CERT_ID": "", "PROFILE_IDS": "", "UPLOADED": "false", "TEARDOWN": "done",
                                   "SIGNING": "", "STATE": "", "APP_ID": APP_ID}, **env), cwd=cwd)

    @staticmethod
    def workflow_text():
        with open(WORKFLOW_PATH, encoding="utf-8") as fh:
            return fh.read()

    def test_the_finish_job_names_no_revocation_when_no_certificate_was_made(self):
        self.revoke_step(SIGNING="skipped")
        self.assertIn("no hay nada que revocar: el trabajo «Build, sign and upload (macOS)» se detuvo antes de crear "
                      "el certificado", self.summary())
        self.assertNotIn("ya lo revocó el paso «Clean up»", self.summary())
        self.revoke_step(CERT_ID="C1", PROFILE_IDS="P1,P2", SIGNING="success")
        self.assertIn("ya lo revocó el paso «Clean up»", self.summary())
        self.assertEqual(self.fake.requests, [])
        # SIGNING: the build job's certificate step outcome (skipped: the job stopped before it).
        self.assertIn("signing: ${{ steps.signing.outcome }}", self.workflow_text())
        self.assertIn("SIGNING: ${{ needs.build.outputs.signing }}", self.workflow_text())

    def test_the_finish_job_without_a_certificate_id_points_at_the_clean_up_warning(self):
        # The certificate step ran but no id came out (an unclear answer, a cancel during it):
        # Clean up looked for the certificate by this run's key and warned if it could not revoke
        # it. The finish summary must not tell the owner «nothing to revoke» over that warning.
        for signing in ("failure", "cancelled", "success", ""):
            with self.subTest(signing=signing):
                self.revoke_step(SIGNING=signing)
                text = self.summary()
                for needle in ("no registró ningún certificado: o no llegó a crearlo, o su paso «Clean up» ya lo "
                               "revocó", "(«Certificado sin confirmar» o «Limpieza incompleta»), haz lo que dice",
                               "If that step left a warning", "do what it says"):
                    self.assertIn(needle, text)
                for wrong in ("no hay nada que revocar", "Nothing to revoke"):
                    self.assertNotIn(wrong, text)
        self.assertEqual(self.fake.requests, [])

    def test_the_finish_job_without_a_checkout_names_what_the_portal_shows(self):
        empty = os.path.join(self.tmp, "no-checkout")
        os.makedirs(empty)
        run = f"OpenCfMoto CI r{REPO_ID}-112-… b7"         # this run's (the build job's attempt: «…»)
        for ids, cert, profiles in ((dict(CERT_ID="C1", PROFILE_IDS="P1,P2"), " (id C1)", " (ids P1,P2)"),
                                    ({}, "", "")):
            with self.subTest(ids=ids):
                proc = self.revoke_step(cwd=empty, UPLOADED="false", TEARDOWN="", **ids)
                title, message = self.annotation(proc, "warning")
                self.assertEqual(title, "Revoca a mano / Revoke by hand")
                for needle in (f"revoca el certificado «Apple Distribution» creado hoy{cert} (púlsalo ▸ Revoke)",
                               f"borra los perfiles «{run} app» y «{run} mirror»{profiles} (cada uno ▸ Remove; "
                               "ningún otro «OpenCfMoto CI …»)",
                               f"revoke the «Apple Distribution» certificate created today{cert}",
                               f"delete the «{run} app» and «{run} mirror» profiles{profiles} (each ▸ Remove; no "
                               "other «OpenCfMoto CI …» one)",
                               "No revoques el que el workflow conserva para la última build que Apple aceptó",
                               "Do not revoke the one the workflow keeps for the latest build Apple accepted"):
                    self.assertIn(needle, message)
                self.assertNotIn("los perfiles «OpenCfMoto CI …»", message)

    def test_the_finish_job_without_a_checkout_never_revokes_an_uploaded_builds_certificate_blindly(self):
        # Apple may have accepted the build: a «Solo preparar» run decides with the build's state.
        empty = os.path.join(self.tmp, "no-checkout")
        os.makedirs(empty)
        run = f"OpenCfMoto CI r{REPO_ID}-112-… b7"
        proc = self.revoke_step(cwd=empty, UPLOADED="true", CERT_ID="C1", PROFILE_IDS="P1,P2")
        title, message = self.annotation(proc, "warning")
        self.assertEqual(title, "Certificado sin decidir / Certificate not settled")
        for needle in ("Lanza una ejecución nueva con «Solo preparar» marcado", f"«{run} app» y «{run} mirror»",
                       "si Apple aceptó la build 7 y es la más reciente", "No revoques ese certificado a mano",
                       "«Invalid Binary» (ITMS-90035)", "Start a new run with «Solo preparar» ticked",
                       "if Apple accepted build 7 and it is the newest", "Do not revoke that certificate by hand"):
            self.assertIn(needle, message)
        for wrong in ("revoca el certificado «Apple Distribution» creado hoy", "Revoke by hand"):
            self.assertNotIn(wrong, message)
        self.assertEqual(self.fake.requests, [])

    def test_the_finish_job_sweeps_up_only_its_own_run(self):
        f = self.fake
        ours = f.add_cert(KEYS.cert_der)
        for name in (f"OpenCfMoto CI r{REPO_ID}-112-1 app", f"OpenCfMoto CI r{REPO_ID}-112-1 mirror"):
            f.add_profile(name, [ours])
        kept = [f"OpenCfMoto CI r{REPO_ID}-111-1 app", "OpenCfMoto CI r999-112-1 app"]
        for name in kept:
            f.add_profile(name, [f.add_cert(KEYS.cert_der)], created=iso(48 * 3600))
        proc = self.revoke_step(UPLOADED="", TEARDOWN="")       # the build job lost its runner
        self.assertEqual(sorted(info["name"] for info in f.profiles.values()), sorted(kept))
        self.assertNotIn(ours, f.certificates)
        self.assertIn("Restos borrados", self.annotation(proc, "notice")[0])

    def test_the_finish_job_keeps_an_accepted_builds_set_and_revokes_a_refused_ones(self):
        f = self.fake
        for version in ("6", "7"):
            f.add_build(APP_ID, version)

        def signing_set(build, run):
            cert = f.add_cert(KEYS.cert_der)
            return cert, [f.add_profile(f"OpenCfMoto CI r{REPO_ID}-{run}-1 b{build} {role}", [cert])
                          for role in ("app", "mirror")]
        older, mine = signing_set(6, 111), signing_set(7, 112)          # this run: GITHUB_RUN_ID 112, build 7
        ids = dict(CERT_ID=mine[0], PROFILE_IDS=",".join(mine[1]))
        self.revoke_step(UPLOADED="true", STATE="", **ids)               # the wait was cancelled: unknown yet
        self.assertEqual(self.calls("DELETE"), [])
        self.assertIn("el de la build 7 se queda por ahora", self.summary())
        self.revoke_step(UPLOADED="true", STATE="VALID", **ids)
        self.assertIn(mine[0], f.certificates)
        self.assertNotIn(older[0], f.certificates)
        self.assertEqual(set(f.profiles), set(mine[1]))
        self.assertIn("el de la build 7 se queda en la cuenta hasta que Apple acepte una build más reciente", self.summary())
        self.revoke_step(UPLOADED="true", STATE="INVALID", **ids)        # the same set, had Apple refused it
        self.assertEqual((f.certificates, f.profiles), ({}, {}))
        self.assertIn("Apple rechazó la build 7", self.summary())
        builds = [c for c in self.calls("GET", "/v1/builds") if "cursor" not in c.query]
        self.assertEqual(len(builds), 1)                                  # only after the accepted build
        self.assertIn("STATE: ${{ steps.wait.outputs.processing_state }}", self.workflow_text())

    def test_the_finish_job_is_named_as_the_messages_name_it(self):
        text = self.workflow_text()
        self.assertIn(f"    name: {asc.FINISH_JOB}\n", text)
        with open(SCRIPT_PATH, encoding="utf-8") as fh:
            script = fh.read()
        self.assertIn(f'FINISH_JOB="{asc.FINISH_JOB}"', script)
        with open(os.path.join(REPO, "docs", "TESTFLIGHT.md"), encoding="utf-8") as fh:
            guide = fh.read()
        self.assertIn(asc.FINISH_JOB, guide)
        for name, content in (("testflight.yml", text), ("build_and_sign.sh", script), ("TESTFLIGHT.md", guide)):
            self.assertNotIn("Processing, TestFlight group, revoke the certificate", content, name)

    def test_the_build_summary_says_an_accepted_builds_certificate_stays(self):
        text = self.build_summary(UPLOADED="true", UPLOAD_OUTCOME="success", SIGNING_OUTCOME="success", METHOD="rest")
        for needle in ("si Apple la acepta, conserva su certificado hasta que acepte una build más reciente",
                       "if Apple accepts it, keeps its certificate until Apple accepts a newer build"):
            self.assertIn(needle, text)

    def test_the_finish_summary_of_an_accepted_build_says_how_to_reach_external_testers(self):
        text = self.finish_summary(STATE="VALID", OUTCOME="success", GROUP="OpenCfMoto (interno)")
        for needle in ("Para las pruebas externas (el enlace público), envía esta build a revisión",
                       "TestFlight ▸ tu grupo externo ▸ Builds «+» ▸ esta build ▸ What to Test ▸ Submit Review",
                       "Su certificado se queda en la cuenta hasta que Apple acepte una build más reciente",
                       "For external testing (the public link), submit this build for review",
                       "Its certificate stays in the account until Apple accepts a newer build"):
            self.assertIn(needle, text)
        self.assertNotIn("Para las pruebas externas", self.finish_summary(STATE="INVALID", OUTCOME="failure"))

    def finish_summary(self, **env):
        open(self.step_summary, "w").close()
        self.run_step("finish", "Summary", dict({"STATE": "", "GROUP": "", "OUTCOME": "", "BUILD_RESULT": "success",
                                                 "UPLOADED": "true", "TEARDOWN": "done"}, **env))
        return self.summary()

    def test_the_finish_summary_after_a_cancel_before_the_build_job_cleaned_up(self):
        text = self.finish_summary(UPLOADED="", TEARDOWN="", BUILD_RESULT="cancelled", OUTCOME="skipped")
        self.assertIn("La ejecución se canceló antes de que el trabajo «Build, sign and upload (macOS)» empezara "
                      "o terminara su limpieza", text)
        self.assertNotIn("se perdió el runner", text)
        text = self.finish_summary(UPLOADED="", TEARDOWN="", BUILD_RESULT="failure", OUTCOME="skipped")
        self.assertIn("se perdió el runner", text)

    def test_after_a_cancel_that_clean_up_handled_no_summary_asks_for_a_fix(self):
        # Cancelled during archive, export or upload, and Clean up ran: the only annotation is
        # GitHub's «The operation was canceled», so no summary sends the owner to fix errors.
        text = self.build_summary(UPLOADED="false", UPLOAD_OUTCOME="cancelled", SIGNING_OUTCOME="success",
                                  JOB_STATUS="cancelled")
        for needle in ("Se canceló la ejecución (o el trabajo superó su tiempo máximo) y no se subió ninguna build.",
                       "El paso «Clean up» revoca el certificado", "Cuando quieras, lanza una ejecución nueva",
                       "The run was cancelled (or the job hit its time limit)"):
            self.assertIn(needle, text)
        text = self.finish_summary(UPLOADED="false", TEARDOWN="done", BUILD_RESULT="cancelled", OUTCOME="skipped")
        for needle in ("La ejecución se canceló (o el trabajo «Build, sign and upload (macOS)» superó su tiempo máximo)",
                       "revocó lo que se llegó a crear", "Cuando quieras, lanza una ejecución nueva", "The run was cancelled"):
            self.assertIn(needle, text)
        self.assertNotIn("se perdió el runner", text)
        for summary in (text, self.build_summary(UPLOADED="false", UPLOAD_OUTCOME="cancelled",
                                                 SIGNING_OUTCOME="success", JOB_STATUS="cancelled")):
            for wrong in ("anotaciones de error", "mira sus anotaciones", "Cuando lo hayas corregido", "Once that is fixed"):
                self.assertNotIn(wrong, summary)
        # A failure still asks for the fix.
        text = self.build_summary(UPLOADED="false", UPLOAD_OUTCOME="skipped", SIGNING_OUTCOME="success",
                                  JOB_STATUS="failure")
        self.assertIn("lee las anotaciones de error", text)
        text = self.finish_summary(UPLOADED="false", TEARDOWN="done", BUILD_RESULT="failure", OUTCOME="skipped")
        self.assertIn("Cuando lo hayas corregido", text)
        for wiring in ("JOB_STATUS: ${{ job.status }}", "BUILD_RESULT: ${{ needs.build.result }}"):
            self.assertIn(wiring, self.workflow_text())

    def test_the_finish_summary_never_promises_an_email(self):
        for env in (dict(STATE="PROCESSING", OUTCOME="success"), dict(OUTCOME="skipped"), dict(OUTCOME="failure")):
            with self.subTest(**env):
                text = self.finish_summary(**env)
                self.assertIn("(Apple suele avisar por correo)", text)
                self.assertIn("(Apple usually e-mails you)", text)
                for promise in ("te llegará un correo", "te llega un correo", "(Apple e-mails you)"):
                    self.assertNotIn(promise, text)


# ---------------------------------------------------------------- runner (annotations in CI)

def _esc(text, prop=False):
    text = str(text).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return text.replace(":", "%3A").replace(",", "%2C") if prop else text


class AnnotatingResult(unittest.TextTestResult):
    def _annotate(self, test, err):
        if os.environ.get("GITHUB_ACTIONS") == "true":
            text = self._exc_info_to_string(err, test)
            print(f"::error title={_esc('test_asc ' + test.id(), True)}::{_esc(text[-8000:])}", flush=True)

    def addError(self, test, err):
        super().addError(test, err)
        self._annotate(test, err)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self._annotate(test, err)

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            self._annotate(subtest, err)


def main():
    started = time.monotonic()
    runner = unittest.TextTestRunner(stream=sys.stdout, verbosity=2, resultclass=AnnotatingResult)
    result = unittest.main(module="__main__", testRunner=runner, exit=False).result
    elapsed = time.monotonic() - started
    if os.environ.get("GITHUB_ACTIONS") == "true":
        try:
            tool = subprocess.run(["openssl", "version"], capture_output=True, text=True,
                                  timeout=30).stdout.strip()
        except OSError as exc:
            tool = f"openssl: {exc}"
        level = "notice" if result.wasSuccessful() else "error"
        print(f"::{level} title=TestFlight helper tests::{result.testsRun} tests, {len(result.failures)} "
              f"failures, {len(result.errors)} errors in {elapsed:.1f} s (Python {sys.version.split()[0]}, "
              f"{_esc(tool)})", flush=True)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
