#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for tools/testflight/asc.py against an in-process fake App Store Connect.

    python3 tools/testflight/test_asc.py [TestClass[.test_name] ...]

No network and no secrets: a throwaway EC P-256 key signs the JWTs, certificates are issued for
the CSR the way Apple does (by a throwaway CA), and http.server on 127.0.0.1 plays App Store
Connect and Apple's upload storage. The fake behaves like the live API where that differs from
the OpenAPI spec (`limit` refused on bundleIdCapabilities, the transient false 404 of the Build
Upload API reads, duplicate build numbers refused with 409). asc.py runs as a subprocess, exactly
as the workflow runs it, with every wait scaled down (ASC_POLL_SCALE). Under GitHub Actions each
failing test is also printed as an ::error annotation (raw job logs are not always readable;
annotations are).
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
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

sys.dont_write_bytecode = True   # no __pycache__ next to the sources when asc.py is imported
HERE = os.path.dirname(os.path.abspath(__file__))
ASC_PATH = os.path.join(HERE, "asc.py")
KEY_ID = "ABC123DEFG"
ISSUER = "69a6de70-1234-47e3-e053-5b8c7c11a4d1"
TEAM = "ABCDE12345"
PREFIX = "com.t"
APP_BID = "com.t.opencfmoto"
MIRROR_BID = "com.t.opencfmoto.mirror"
GROUP = "group.com.t.opencfmoto"
APP_ID = "1234567890"
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
        self.requests = []
        self.faults = []
        self.counter = itertools.count(1)
        self.seed_id = TEAM
        self.bundle_ids = []
        self.capabilities = {}         # bundle resource id -> [capabilityType]
        self.capability_conflicts = set()
        self.apps = []
        self.builds = []               # (app id, build resource)
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
        self.profiles = {}             # id -> {"name", "certs", "type", "content", "uuid"}
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
        payload = b"" if doc is None else json.dumps(doc).encode("utf-8")
        h.send_response(status)
        for key, value in (headers or {}).items():
            h.send_header(key, value)
        if payload:
            h.send_header("Content-Type", "application/json")
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

    def add_build(self, app, version, state="VALID"):
        build = {"type": "builds", "id": self.new_id("BLD"),
                 "attributes": {"version": version, "processingState": state,
                                "uploadedDate": "2026-11-01T10:00:00Z"}}
        self.builds.append((app, build))
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

    def add_profile(self, name, certs, kind="IOS_APP_STORE"):
        profile_id = self.new_id("P")
        self.profiles[profile_id] = {"name": name, "certs": list(certs), "type": kind,
                                     "content": b"", "uuid": ""}
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
        # Like Apple, filter[identifier] matches substrings: X also returns X.mirror.
        items = [b for b in self.bundle_ids if ident in b["attributes"]["identifier"]
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
        return self.page(rec, items)

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
                               "platform": "IOS", "serialNumber": cert_id}}

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
        if with_certs:   # include=certificates shows only the first few, with the total
            relation["data"] = [{"type": "certificates", "id": c} for c in certs[:self.include_limit]]
            relation["meta"] = {"paging": {"total": len(certs), "limit": self.include_limit}}
        return {"type": "profiles", "id": profile_id,
                "attributes": {"name": info.get("name", ""), "profileType": info.get("type", "IOS_APP_STORE"),
                               "profileState": "ACTIVE", "platform": "IOS", "uuid": info.get("uuid", ""),
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
                                     "bundle": bundle["id"]}
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
                    "GITHUB_STEP_SUMMARY": self.step_summary}
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
                       "identifiers/list/applicationGroup", "Asígnalo a los DOS App IDs", "Assign it to BOTH"):
            self.assertIn(needle, summary)
        self.assert_new_run_advice(summary)
        self.assertEqual(self.annotations(proc, "error"), [])
        self.assertEqual(self.calls("GET", "/v1/builds"), [])
        self.assertIn("ready=false", proc.stdout)                 # outputs echoed to stdout too

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
        message = self.annotation(proc, "error")[1]
        self.assertIn("BUNDLE_ID_PREFIX", message)
        self.assert_new_run_advice(message)

    def test_invalid_prefix(self):
        proc = self.run_asc("prepare", "--prefix", "com.bad prefix!", "--project-yml", self.project_yml, expect=2)
        self.assertIn("BUNDLE_ID_PREFIX", self.annotation(proc, "error")[1])
        self.assertEqual(self.fake.requests, [])

    def test_leftovers_of_an_interrupted_run_are_removed(self):
        self.seed_ready_account()
        cert = self.fake.add_cert(KEYS.cert_der)
        self.fake.add_profile("OpenCfMoto CI 77-1 app", [cert])
        self.fake.add_profile("OpenCfMoto CI 77-1 mirror", [cert])
        keep = self.fake.add_profile("My own profile", [])
        proc = self.prepare("--setup-only")
        self.assertEqual(list(self.fake.profiles), [keep])
        self.assertEqual(self.fake.certificates, {})
        title, message = self.annotation(proc, "notice")
        self.assertIn("Restos", title)
        self.assertIn("OpenCfMoto CI 77-1 mirror", message)
        self.assertEqual(self.outputs()["ready"], "false")
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_a_sweep_problem_only_warns(self):
        self.seed_ready_account()
        self.fake.fail("GET", "/v1/profiles", 403,
                       error_doc(403, "FORBIDDEN_ERROR", "This request is forbidden for security reasons"), times=99)
        proc = self.prepare()
        self.assertEqual(self.outputs()["ready"], "true")
        title, message = self.annotation(proc, "warning")
        self.assertIn("Limpieza incompleta", title)
        self.assertIn("certificates/list", message)
        self.assertEqual(self.annotations(proc, "error"), [])


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
    def test_removes_ci_leftovers_but_keeps_certificates_other_profiles_use(self):
        f = self.fake
        ci_cert, shared, other, extra = (f.add_cert(KEYS.cert_der) for _ in range(4))
        app = f.add_profile("OpenCfMoto CI 41-1 app", [ci_cert])
        mirror = f.add_profile("OpenCfMoto CI 41-1 mirror", [ci_cert, shared])
        # The owner's own profile: include=certificates shows only the first two of its three
        # certificates, and the one it shares with a CI profile is the third.
        own = f.add_profile("My App Store profile", [other, extra, shared])
        lookalike = f.add_profile("OpenCfMoto CI-like, not ours", [other])
        proc = self.run_asc("janitor")
        self.assertEqual([c.path for c in self.calls("DELETE")],
                         [f"/v1/profiles/{app}", f"/v1/profiles/{mirror}", f"/v1/certificates/{ci_cert}"])
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
        for needle in ("OpenCfMoto CI 41-1 app", ci_cert, "No tienes que hacer nada", "Nothing to do"):
            self.assertIn(needle, message)
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_nothing_left_is_quiet(self):
        self.fake.add_profile("My App Store profile", [self.fake.add_cert(KEYS.cert_der)])
        proc = self.run_asc("janitor")
        self.assertEqual(self.calls("DELETE"), [])
        self.assertEqual(self.annotations(proc, "notice") + self.annotations(proc, "warning"), [])

    def test_already_gone_is_fine(self):
        cert = self.fake.add_cert(KEYS.cert_der)
        self.fake.add_profile("OpenCfMoto CI 9-1 app", [cert])
        self.fake.fail("DELETE", r"/v1/certificates/.*", 404,
                       error_doc(404, "NOT_FOUND", "The specified resource does not exist"))
        proc = self.run_asc("janitor")
        self.assertEqual(self.fake.profiles, {})
        self.assertEqual(self.annotations(proc, "warning"), [])

    def test_problems_only_warn_with_the_manual_steps(self):
        cert = self.fake.add_cert(KEYS.cert_der)
        self.fake.add_profile("OpenCfMoto CI 9-1 app", [cert])
        self.fake.fail("DELETE", r"/v1/certificates/.*", 500, SERVER_ERROR, times=99)
        proc = self.run_asc("janitor")
        title, message = self.annotation(proc, "warning")
        self.assertIn("Limpieza incompleta", title)
        for needle in (cert, "certificates/list", "Revoca", "Revoke"):
            self.assertIn(needle, message)
        self.assertEqual(self.fake.profiles, {})            # the profiles went anyway

    def test_missing_secrets_warn_and_exit_0(self):
        proc = self.run_asc("janitor", env={"ASC_KEY_ID": None})
        self.assertIn("ASC_KEY_ID", self.annotation(proc, "warning")[1])
        self.assertEqual(self.fake.requests, [])


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

    def assert_one_certificate_recorded(self, proc, posts=1):
        out = self.outputs()
        self.assertEqual(len(self.calls("POST", "/v1/certificates")), posts)
        self.assertEqual([c for c in self.fake.created_certs if c in self.fake.certificates], [out["cert_id"]])
        self.assertEqual(self.state(), {"cert_id": out["cert_id"],
                                        "profile_ids": [out["profile_app_id"], out["profile_mirror_id"]]})
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

    def test_certificate_made_but_the_answer_was_an_error(self):
        self.fake.add_cert(KEYS.cert_der)                  # someone else's: never adopted
        self.fake.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        proc = self.create()
        self.assert_one_certificate_recorded(proc)
        self.assertEqual(self.calls("GET", "/v1/certificates")[0].query.get("filter[certificateType]"),
                         "DISTRIBUTION")

    def test_certificate_made_but_no_answer_at_all(self):
        self.fake.fail("POST", "/v1/certificates", 0, effect=True)
        proc = self.create()
        self.assert_one_certificate_recorded(proc)

    def test_certificate_not_made_is_asked_for_once_more(self):
        self.fake.fail("POST", "/v1/certificates", 503, error_doc(503, "SERVICE_UNAVAILABLE", "Unavailable"))
        proc = self.create()
        self.assert_one_certificate_recorded(proc, posts=2)

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
        self.assert_one_certificate_recorded(proc, posts=2)

    def test_unconfirmed_certificate_is_explained_and_cleanup_finds_it(self):
        self.fake.fail("POST", "/v1/certificates", 502, BAD_GATEWAY, effect=True)
        self.fake.fail("GET", "/v1/certificates", 500, SERVER_ERROR, times=99)
        proc = self.create(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertIn("Certificado sin confirmar", title)
        for needle in ("certificates/list", "Revoca", "Revoke"):
            self.assertIn(needle, message)
        self.assert_new_run_advice(message)
        self.assertEqual(self.state(), {"cert_id": None, "profile_ids": [], "cert_pending": True})
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
        self.assertIn("Processing, TestFlight group, revoke the certificate", message)
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
        f.add_upload(APP_ID, "7", state="COMPLETE", created="2026-11-01T09:30:00Z")
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
        self.assertIn("ITMS-90474: Invalid bundle: iPad orientations", messages)
        self.assertIn("ITMS-90683: Missing purpose string", messages)
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
        title, message = self.annotation(proc, "warning")
        self.assertIn("Certificado sin confirmar", title)
        self.assertIn("certificates/list", message)


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
