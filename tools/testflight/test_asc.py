#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for tools/testflight/asc.py against an in-process fake App Store Connect.

    python3 tools/testflight/test_asc.py [TestClass[.test_name] ...]

No network and no secrets: a throwaway EC P-256 key signs the JWTs, a self-signed certificate
stands in for Apple's, and http.server on 127.0.0.1 plays App Store Connect and Apple's upload
storage. asc.py runs as a subprocess, exactly as the workflow runs it, with every wait scaled
down (ASC_POLL_SCALE). Under GitHub Actions each failing test is also printed as an ::error
annotation (raw job logs are not always readable; annotations are).
"""
import atexit
import base64
import hashlib
import importlib.util
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
    """Made once per run: the API key (.p8 = PKCS#8 EC P-256, like Apple's) and an Apple-like
    distribution certificate (self-signed, team ID in OU)."""

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


# ---------------------------------------------------------------- fake App Store Connect

class Recorded:
    def __init__(self, method, path, query, headers, body):
        self.method, self.path, self.query, self.headers, self.body = method, path, query, headers, body

    def json(self):
        return json.loads(self.body.decode("utf-8"))


class Fault:
    def __init__(self, method, path, status, doc=None, headers=None, times=1):
        self.method, self.pattern, self.status = method, re.compile(path), status
        self.doc, self.headers, self.times = doc, headers or {}, times


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
        ("POST", r"/v1/certificates", "create_cert"),
        ("DELETE", r"/v1/certificates/([^/]+)", "delete_cert"),
        ("POST", r"/v1/profiles", "create_profile"),
        ("DELETE", r"/v1/profiles/([^/]+)", "delete_profile"),
        ("POST", r"/v1/buildUploads", "create_build_upload"),
        ("GET", r"/v1/buildUploads/([^/]+)", "get_build_upload"),
        ("DELETE", r"/v1/buildUploads/([^/]+)", "delete_build_upload"),
        ("POST", r"/v1/buildUploadFiles", "create_upload_file"),
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
        self.upload_list = []          # (app id, buildUploads resource) for the build number
        self.build_uploads = {}
        self.upload_files = {}
        self.part_sizes = None         # None: two equal halves
        self.upload_script = ["PROCESSING", "COMPLETE"]
        self.upload_details = {}       # state -> {"errors": [...], "warnings": [...]}
        self.cert_der = b""
        self.cert_limit = False
        self.certificates = {}
        self.profiles = {}
        self.assigned_groups = {}      # bundle identifier -> App Groups assigned on the portal
        self.beta_groups = []          # (app id, betaGroups resource)
        self.group_builds = {}
        self.group_testers = {}        # group id -> [e-mail]
        self.tester_conflicts = set()
        self.users = []

    # -- plumbing

    def new_id(self, prefix):
        return f"{prefix}{next(self.counter):04d}"

    def fail(self, method, path, status, doc=None, headers=None, times=1):
        self.faults.append(Fault(method, path, status, doc, headers, times))

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
                return self.send(h, fault.status, fault.doc, fault.headers)
            if parts.path.startswith("/upload/"):
                return self.send(h, 200)      # Apple's storage: no Authorization expected
            auth = rec.headers.get("authorization", "")
            if not auth.startswith("Bearer ") or auth.count(".") != 2:
                return self.send(h, 401, error_doc(401, "NOT_AUTHORIZED", "Authentication credentials are missing or invalid."))
            for method, pattern, name in self.ROUTES:
                match = re.fullmatch(pattern, parts.path)
                if match and method == h.command:
                    status, doc = getattr(self, name)(rec, *match.groups())
                    return self.send(h, status, doc)
        return self.send(h, 404, error_doc(404, "NOT_FOUND", f"no route {h.command} {parts.path}"))

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

    def add_upload(self, app, version):
        self.upload_list.append((app, {"type": "buildUploads", "id": self.new_id("U"),
                                       "attributes": {"cfBundleVersion": version,
                                                      "cfBundleShortVersionString": "2.3.4"}}))

    def add_group(self, app, name, internal, all_builds):
        group = {"type": "betaGroups", "id": self.new_id("G"),
                 "attributes": {"name": name, "isInternalGroup": internal,
                                "hasAccessToAllBuilds": all_builds}}
        self.beta_groups.append((app, group))
        return group

    # -- routes

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
        return self.page(rec, [u for a, u in self.upload_list if a == app])

    def create_cert(self, rec):
        if self.cert_limit:
            return 409, error_doc(409, "ENTITY_ERROR.ATTRIBUTE.INVALID",
                                  "There is a problem with the request entity",
                                  "You already have a current Distribution certificate or a pending certificate request.")
        attributes = rec.json()["data"]["attributes"]
        cert_id = self.new_id("C")
        self.certificates[cert_id] = attributes
        return 201, {"data": {"type": "certificates", "id": cert_id,
                              "attributes": {"certificateType": attributes["certificateType"],
                                             "certificateContent": base64.b64encode(self.cert_der).decode("ascii"),
                                             "name": "Apple Distribution: Test Owner",
                                             "serialNumber": "1234ABCD"}}}

    def delete_cert(self, rec, cert_id):
        if self.certificates.pop(cert_id, None) is None:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
        return 204, None

    def create_profile(self, rec):
        data = rec.json()["data"]
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
        name = data["attributes"]["name"]
        plist = plistlib.dumps({"AppIDName": bundle["attributes"]["name"], "Entitlements": ents,
                                "Name": name, "TeamIdentifier": [self.seed_id], "UUID": uuid})
        content = CMS_HEAD + plist + CMS_TAIL
        self.profiles[profile_id] = {"content": content, "bundle": bundle["id"]}
        return 201, {"data": {"type": "profiles", "id": profile_id,
                              "attributes": {"name": name, "profileType": data["attributes"]["profileType"],
                                             "profileState": "ACTIVE", "platform": "IOS", "uuid": uuid,
                                             "profileContent": base64.b64encode(content).decode("ascii")}}}

    def delete_profile(self, rec, profile_id):
        if self.profiles.pop(profile_id, None) is None:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
        return 204, None

    def create_build_upload(self, rec):
        data = rec.json()["data"]
        upload = {"type": "buildUploads", "id": self.new_id("U"),
                  "attributes": dict(data["attributes"], state={"state": "AWAITING_UPLOAD"})}
        self.build_uploads[upload["id"]] = upload
        return 201, {"data": upload}

    def get_build_upload(self, rec, upload_id):
        upload = self.build_uploads.get(upload_id)
        if upload is None:
            return 404, error_doc(404, "NOT_FOUND", "The specified resource does not exist")
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
        self.upload_files[file_id] = upload_file
        return 201, {"data": upload_file}

    def patch_upload_file(self, rec, file_id):
        upload_file = self.upload_files[file_id]
        upload_file["attributes"]["assetDeliveryState"] = {"state": "UPLOAD_COMPLETE"}
        return 200, {"data": upload_file}

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
        if mail in self.tester_conflicts:
            return 409, error_doc(409, "ENTITY_ERROR", "The tester already exists.")
        for group in data["relationships"]["betaGroups"]["data"]:
            self.group_testers.setdefault(group["id"], []).append(mail)
        return 201, {"data": {"type": "betaTesters", "id": self.new_id("T"), "attributes": data["attributes"]}}

    def list_users(self, rec):
        return self.page(rec, self.users)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _dispatch(self):
        self.server.fake.handle(self)

    do_GET = do_POST = do_PATCH = do_DELETE = do_PUT = _dispatch


# ---------------------------------------------------------------- test base

class AscTest(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.fake = FakeASC()
        self.fake.cert_der = KEYS.cert_der
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

    def run_asc(self, *args, expect=0, env=None):
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
        proc = subprocess.run([sys.executable, ASC_PATH, *args], env=full_env, capture_output=True,
                              encoding="utf-8", errors="replace", timeout=120)
        if expect is not None:
            self.assertEqual(proc.returncode, expect,
                             f"asc.py {' '.join(args)} exited {proc.returncode}\n{self.transcript(proc)}")
        return proc

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
        self.assertIn("system-status", self.annotation(proc, "error")[1])

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
            "app_id": "", "build_number": "", "marketing_version": "2.3.4"})
        summary = self.summary()
        for needle in (GROUP, APP_BID, MIRROR_BID, "Nueva app", "New App", "Solo preparar",
                       "identifiers/list/applicationGroup", "Asígnalo a los DOS App IDs", "Assign it to BOTH"):
            self.assertIn(needle, summary)
        self.assertEqual(self.annotations(proc, "error"), [])
        self.assertEqual(self.calls("GET", "/v1/builds"), [])
        self.assertIn("ready=false", proc.stdout)                 # outputs echoed to stdout too

    def test_new_account_full_run_fails_with_the_steps(self):
        proc = self.prepare(expect=1)
        title, message = self.annotation(proc, "error")
        self.assertIn("App Store Connect", title)
        for needle in (GROUP, "Nueva app", "New App", APP_BID):
            self.assertIn(needle, message)
        self.assertEqual(self.outputs()["ready"], "false")

    def test_existing_ids_exact_match_conflict_and_build_number(self):
        f = self.fake
        # filter[identifier] is a substring match: X.mirror (and X.other) come back first for X.
        mirror, _, app = f.add_bundle(MIRROR_BID), f.add_bundle("com.t.opencfmoto.other"), f.add_bundle(APP_BID)
        f.capabilities[app["id"]] = ["APP_GROUPS", "IN_APP_PURCHASE"]
        f.capabilities[mirror["id"]] = ["APP_GROUPS"]
        f.capability_conflicts = {"HOT_SPOT"}         # enabled but not listed: POST answers 409
        f.add_app("com.t.opencfmoto2", "999")          # filter[bundleId] substring match
        f.add_app(APP_BID, APP_ID)
        for version in ("3", "10.2", "x", "7", "1"):
            f.add_build(APP_ID, version)
        f.add_build("999", "50")                       # another app
        for version in ("12", "11"):
            f.add_upload(APP_ID, version)
        proc = self.prepare()
        self.assertEqual(self.calls("POST", "/v1/bundleIds"), [])
        self.assertEqual([c.json()["data"]["attributes"]["capabilityType"]
                          for c in self.calls("POST", "/v1/bundleIdCapabilities")],
                         ["HOT_SPOT", "ACCESS_WIFI_INFORMATION"])
        out = self.outputs()
        self.assertEqual((out["app_bundle_resource_id"], out["mirror_bundle_resource_id"]), (app["id"], mirror["id"]))
        self.assertEqual((out["ready"], out["app_id"], out["build_number"], out["team_id"]),
                         ("true", APP_ID, "13", TEAM))
        self.assertTrue(any("cursor" in c.query for c in self.calls("GET", "/v1/builds")))   # links.next
        self.assertEqual(self.annotations(proc, "error"), [])
        self.assertIn("build 13", self.summary())

    def test_first_build_is_1(self):
        self.seed_ready_account()
        self.prepare()
        self.assertEqual((self.outputs()["ready"], self.outputs()["build_number"]), ("true", "1"))

    def test_setup_only_with_the_app_present(self):
        self.seed_ready_account()
        proc = self.prepare("--setup-only")
        self.assertIn("todo listo, ejecuta sin Solo preparar", proc.stdout)
        out = self.outputs()
        self.assertEqual((out["ready"], out["app_id"], out["build_number"]), ("false", APP_ID, ""))
        self.assertEqual(self.calls("POST", r".*"), [])
        self.assertEqual(self.calls("GET", "/v1/builds"), [])

    def test_links_next_never_sends_the_token_to_another_host(self):
        self.seed_ready_account()
        for version in ("4", "9", "2", "5", "8"):
            self.fake.add_build(APP_ID, version)
        self.fake.next_base = "http://evil.invalid:9"   # asc.py must reuse our base URL
        self.prepare()
        self.assertEqual(self.outputs()["build_number"], "10")
        self.assertEqual(len(self.calls("GET", "/v1/builds")), 3)

    def test_universal_bundle_id_is_reused(self):
        app = self.fake.add_bundle(APP_BID, platform="UNIVERSAL")
        self.prepare("--setup-only")
        self.assertEqual(self.outputs()["app_bundle_resource_id"], app["id"])
        self.assertEqual(len(self.calls("POST", "/v1/bundleIds")), 2)   # the 409 one + the mirror

    def test_bundle_id_taken_by_another_team(self):
        self.fake.fail("POST", "/v1/bundleIds", 409,
                       error_doc(409, "ENTITY_ERROR.ATTRIBUTE.INVALID", "An attribute value is invalid.",
                                 "An App ID with Identifier 'com.t.opencfmoto' is not available."))
        proc = self.prepare(expect=1)
        self.assertIn("BUNDLE_ID_PREFIX", self.annotation(proc, "error")[1])

    def test_invalid_prefix(self):
        proc = self.run_asc("prepare", "--prefix", "com.bad prefix!", "--project-yml", self.project_yml, expect=2)
        self.assertIn("BUNDLE_ID_PREFIX", self.annotation(proc, "error")[1])
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
        with open(os.path.join(self.out, "cert.cer"), "rb") as fh:
            self.assertEqual(fh.read(), KEYS.cert_der)
        self.assertEqual(openssl("x509", "-in", os.path.join(self.out, "cert.pem"), "-outform", "der"), KEYS.cert_der)

        out = self.outputs()
        cert_id = next(iter(self.fake.certificates))
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
        public = proc.stdout + proc.stderr + self.summary()
        for secret in ("CERTIFICATE REQUEST", "PRIVATE KEY", base64.b64encode(KEYS.cert_der).decode()[:40], "<?xml"):
            self.assertNotIn(secret, public)
        self.assertIn("OpenCfMoto CI 4242-1 mirror", self.summary())
        self.assertEqual(self.annotations(proc, "error"), [])

    def test_missing_app_group_exits_4_after_recording_everything(self):
        self.fake.assigned_groups = {APP_BID: [GROUP]}     # not assigned to the extension's App ID
        proc = self.create(expect=4)
        title, message = self.annotation(proc, "error")
        self.assertIn("App Group", title)
        for needle in (MIRROR_BID, GROUP, "identifiers/list/applicationGroup", "Asígnalo", "Assign it"):
            self.assertIn(needle, message)
        out = self.outputs()
        self.assertEqual(self.state(), {"cert_id": out["cert_id"],
                                        "profile_ids": [out["profile_app_id"], out["profile_mirror_id"]]})

    def test_missing_hotspot_capability(self):
        self.fake.capabilities[self.app["id"]] = ["APP_GROUPS"]
        message = self.annotation(self.create(expect=1), "error")[1]
        self.assertIn("HotspotConfiguration", message)
        self.assertIn("wifi-info", message)

    def test_certificate_limit(self):
        self.fake.cert_limit = True
        title, message = self.annotation(self.create(expect=1), "error")
        for needle in ("Apple Distribution", "certificates/list", "revoca", "revoke"):
            self.assertIn(needle, message)
        self.assertEqual(self.state(), {"cert_id": None, "profile_ids": []})
        self.assertNotIn("cert_id", self.outputs())

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

    def upload(self, *extra, expect=0):
        return self.run_asc("upload", "--ipa", self.ipa, "--app-id", APP_ID, "--version", "2.3.4",
                            "--build", "7", *extra, expect=expect)

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
        self.assertEqual(self.outputs()["uploaded"], "true")
        self.assertIn("90725: SDK version issue", [m for _, m in self.annotations(proc, "warning")])
        self.assertEqual(len(self.calls("GET", r"/v1/buildUploads/.*")), 2)
        self.assertEqual(self.calls("DELETE"), [])
        self.assertNotIn("X-Signature", proc.stdout + proc.stderr)   # pre-signed URLs stay out of the log
        self.assertIn("build 7", self.summary())

    def test_failed_processing_reports_each_error(self):
        self.fake.upload_script = ["PROCESSING", "FAILED"]
        self.fake.upload_details = {"FAILED": {"errors": [{"code": "90062", "description": "Invalid bundle version"},
                                                          {"code": "90190", "description": "Bad icon"}]}}
        proc = self.upload(expect=1)
        messages = [m for _, m in self.annotations(proc, "error")]
        self.assertIn("90062: Invalid bundle version", messages)
        self.assertIn("90190: Bad icon", messages)
        self.assertEqual(self.outputs()["uploaded"], "false")
        self.assertEqual(self.calls("DELETE"), [])

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

    def test_refused_upload_creation_exits_3_without_delete(self):
        self.fake.fail("POST", "/v1/buildUploads", 409,
                       error_doc(409, "ENTITY_ERROR.ATTRIBUTE.INVALID", "invalid",
                                 "The bundle version must be higher than the previously uploaded version."))
        proc = self.upload(expect=3)
        self.assertEqual(self.calls("DELETE"), [])
        self.assertIn("previously uploaded", self.annotation(proc, "warning")[1])

    def test_server_errors_retried_then_refused(self):
        self.fake.fail("POST", "/v1/buildUploadFiles", 500,
                       error_doc(500, "UNEXPECTED_ERROR", "An unexpected error occurred."), times=99)
        self.upload(expect=3)
        self.assertEqual(len(self.calls("POST", "/v1/buildUploadFiles")), 1 + asc.API_RETRIES)
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

    def test_still_processing_at_the_timeout(self):
        self.fake.upload_script = ["PROCESSING"]
        proc = self.upload("--timeout-min", "0.5")
        self.assertIn("procesando", self.annotation(proc, "warning")[1])
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
        self.fake.users = [user("U1", "owner@example.com", ["ACCOUNT_HOLDER", "ADMIN"]),
                           user("U2", "admin@example.com", ["ADMIN"]),
                           user("U3", "dev@example.com", ["DEVELOPER"])]

    def wait(self, *extra, expect=0):
        return self.run_asc("wait-build", "--app-id", APP_ID, "--build", "7", *extra, expect=expect)

    def test_valid_creates_the_group_and_adds_admins(self):
        f = self.fake
        f.add_build(APP_ID, "17")                      # filter[version]=7 may return it: exact match
        f.build_script["7"] = [None, "PROCESSING", "VALID"]
        f.tester_conflicts = {"admin@example.com"}    # 409: already a tester, fine
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
        self.assertEqual(sorted(t["attributes"]["email"] for t in testers), ["admin@example.com", "owner@example.com"])
        for tester in testers:
            self.assertEqual(tester["relationships"]["betaGroups"]["data"], [{"type": "betaGroups", "id": group_id}])
        self.assertEqual(self.calls("POST", r"/v1/betaGroups/.*/relationships/builds"), [])
        self.assertEqual(self.annotations(proc, "warning"), [])
        self.assertGreaterEqual(len(self.calls("GET", "/v1/builds")), 3)
        public = proc.stdout + proc.stderr + self.summary()
        for mail in ("owner@example.com", "admin@example.com", "dev@example.com"):
            self.assertNotIn(mail, public)                 # the repository (and its logs) is public
        self.assertIn("TestFlight", self.summary())

    def test_existing_internal_group_without_all_builds_gets_the_build(self):
        f = self.fake
        f.build_script["7"] = ["VALID"]
        f.add_group(APP_ID, "Public", internal=False, all_builds=True)
        team = f.add_group(APP_ID, "Team", internal=True, all_builds=False)
        f.group_testers[team["id"]] = ["Owner@Example.com"]
        self.wait()
        out = self.outputs()
        self.assertEqual(self.calls("POST", "/v1/betaGroups"), [])
        links = self.calls("POST", rf"/v1/betaGroups/{team['id']}/relationships/builds")
        self.assertEqual([c.json() for c in links], [{"data": [{"type": "builds", "id": out["build_id"]}]}])
        self.assertEqual([c.json()["data"]["attributes"]["email"] for c in self.calls("POST", "/v1/betaTesters")],
                         ["admin@example.com"])
        self.assertEqual(out["beta_group"], "Team")

    def test_prefers_the_internal_group_with_access_to_all_builds(self):
        f = self.fake
        f.build_script["7"] = ["VALID"]
        f.add_group(APP_ID, "Limited", internal=True, all_builds=False)
        f.add_group(APP_ID, "Everything", internal=True, all_builds=True)
        self.wait()
        self.assertEqual(self.outputs()["beta_group"], "Everything")
        self.assertEqual(self.calls("POST", r"/v1/betaGroups.*"), [])

    def test_invalid_build(self):
        self.fake.build_script["7"] = ["PROCESSING", "INVALID"]
        proc = self.wait(expect=1)
        self.assertIn("Apple rechazó la build 7; revisa el correo de App Store Connect (códigos ITMS)",
                      self.annotation(proc, "error")[1])
        out = self.outputs()
        self.assertEqual((out["processed"], out["processing_state"]), ("true", "INVALID"))
        self.assertEqual(self.calls("POST"), [])

    def test_timeout_warns_and_succeeds(self):
        self.fake.build_script["7"] = [None]
        proc = self.wait("--timeout-min", "1", "--poll-sec", "20")
        self.assertIn("7", self.annotation(proc, "warning")[1])
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
