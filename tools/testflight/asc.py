#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""App Store Connect helper for the TestFlight workflow (.github/workflows/testflight.yml).

The owner has no Mac, so everything Apple needs happens here with an App Store Connect API key
(repository secrets): App IDs and capabilities, a short-lived distribution certificate and App
Store provisioning profiles, the build upload (REST Build Upload API) and the internal TestFlight
group. Python 3.9+ standard library plus the `openssl` command line tool (OpenSSL 3 on Ubuntu,
LibreSSL as macOS /usr/bin/openssl), using only flags both understand.

  asc.py check-auth
  asc.py prepare --prefix PREFIX [--setup-only]
  asc.py next-build --app-id ID
  asc.py janitor [--run-id ID] [--app-id ID]
  asc.py create-signing --app-bundle-resource-id ID --mirror-bundle-resource-id ID \\
                        --app-bundle-id X --mirror-bundle-id Y --app-group G --out DIR [--suffix S] \\
                        [--build N]
  asc.py upload --ipa PATH --app-id ID --version 1.2.3 --build N [--timeout-min 30] \\
                [--committed-marker PATH]
  asc.py wait-build --app-id ID --build N [--timeout-min 90] [--poll-sec 60]
  asc.py settle-signing --app-id ID --build N --state STATE --run-id ID [--cert-id C] \\
                        [--profile-ids P1,P2]                    (finish job, after wait-build)
  asc.py cleanup [--state DIR/state.json] [--cert-id C] [--profile-ids P1,P2] [--suffix S] [--build N]
  asc.py cleanup --state DIR/state.json --duplicates-only     (teardown of an uploaded build)

Signing sets: each run signs with a distribution certificate of its own, made from a private key
that exists only on the build runner (the teardown deletes it; Apple only ever sees the CSR), plus
two App Store profiles named after the run and the build. Apple checks a build's signature again
when it is submitted to TestFlight beta review, and marks a build signed with a revoked
certificate «Invalid Binary» (ITMS-90035). So the set of a build Apple accepted (processing VALID)
stays: nobody can sign with it any more (the key is gone), it only keeps that signature valid.
It is revoked once a newer build is accepted, unless its build is still waiting for or in beta
review (settle-signing, janitor). Every other set is revoked as soon as nothing needs it.

Environment: ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY (the text of the .p8 file; CRLF, stray
spaces, a one-line paste or literal "\\n" sequences are tolerated) or ASC_PRIVATE_KEY_PATH.
Optional: ASC_API_BASE (tests), ASC_POLL_SCALE (tests: multiplies every wait and timeout),
ASC_OPENSSL (openssl binary). GITHUB_OUTPUT / GITHUB_STEP_SUMMARY receive key=value outputs and a
Markdown summary when set. Outputs are echoed to stdout too: states and numbers as key=value
lines, identifiers (team, App Store Connect ids, profiles...) by name only, as the log is public.
GITHUB_REPOSITORY_ID, GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT (set by GitHub Actions) name the CI
profiles and tell the janitor which of them belong to this repository.

Exit codes: 0 ok, 1 failed (reason in an ::error annotation, Spanish then English), 2 usage,
3 upload refused before the file was committed (the workflow falls back to `xcrun altool`),
4 the new provisioning profiles lack the App Group (owner action on developer.apple.com).

The repository is public, so logs and summaries are too. What this script prints:
- never: the team ID, the account holder's name (build_and_sign.sh only counts the signing
  identity), the key, the JWT (masked), request bodies (the CSR) and responses (certificate and
  profile content, user e-mails), presigned upload URLs;
- request lines and API errors: the method, the path with every resource id and every query value
  replaced by «…» (redact_api_path) and the status; summaries name what was made or removed by
  type, name and date;
- App Store Connect ids (certificates, profiles) only where the owner may have to revoke or delete
  something by hand (manual_revoke and the cleanup warnings), and inside Apple's own error texts,
  which can quote one;
- as they are: bundle identifiers, the App Group, profile names, the version, build numbers, states.
The workflow passes ids between its jobs as outputs; GitHub lists them in the env of the steps that
use them (docs/TESTFLIGHT.md says so).
"""
from __future__ import annotations

import argparse
import base64
import binascii
import calendar
import email.utils
import hashlib
import http.client
import json
import os
import plistlib
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_API_BASE = "https://api.appstoreconnect.apple.com"
USER_AGENT = "opencfmoto-testflight/1"
API_TIMEOUT = 60            # seconds per API request
COMMIT_TIMEOUT = 300        # the upload commit: Apple checks the whole file before it answers
UPLOAD_TIMEOUT = 600        # seconds per upload operation (one slice of the .ipa)
API_RETRIES = 5             # retries for 429, and for 5xx / network errors when safe to repeat
UPLOAD_OP_RETRIES = 3       # retries per upload operation
UPLOAD_POLL_SEC = 15
COMMIT_CHECK_MIN = 2        # after a commit with no clear answer, look for it this long
RECHECK_SEC = 5             # pause before looking for what an unanswered POST may have created
PENDING_RECHECK_SEC = (10, 20, 30)   # cleanup: a cut-off certificate request may still complete
PENDING_RECHECK_BUDGET_SEC = 150     # ...but no new look after this long (real seconds, not scaled):
                                     # GitHub stops Clean up a few minutes after a cancel
FALSE_404_PAUSES = (3, 6, 12)   # Apple's transient 404 on Build Upload API reads
# Apple refuses tokens whose `exp` is more than 20 minutes ahead (clock skew included): use 19.
JWT_LIFETIME = 19 * 60
JWT_REFRESH_MARGIN = 120    # mint a new token when less than this is left

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_UPLOAD_REFUSED, EXIT_APP_GROUP = 0, 1, 2, 3, 4

APP_BUNDLE_NAME = "OpenCfMoto"            # App ID names: letters, digits and spaces only
MIRROR_BUNDLE_NAME = "OpenCfMoto Mirror"
APP_CAPABILITIES = ("APP_GROUPS", "HOT_SPOT", "ACCESS_WIFI_INFORMATION")
MIRROR_CAPABILITIES = ("APP_GROUPS",)
BETA_GROUP_NAME = "OpenCfMoto (interno)"
TESTER_ROLE = "ACCOUNT_HOLDER"            # only the owner becomes a tester
CI_PROFILE_PREFIX = "OpenCfMoto CI "      # create-signing names its profiles like this
# The whole names create-signing gives (profile_name with default_suffix and the build number):
# "OpenCfMoto CI r<repository id>-<run id>-<attempt> b<build> app|mirror" on GitHub, "OpenCfMoto CI
# local<date and time>-1 b<build> app|mirror" on a Mac. Names from before the build number was in
# them (no « b<build>») are leftovers: their certificates are revoked already, or sign nothing
# Apple still checks. Apple documents no length limit for profile names; these stay under 64.
CI_PROFILE_RE = re.compile(r"OpenCfMoto CI (?:r(?P<repo>[0-9]+)-)?(?P<run>[0-9]+|local[0-9]+)"
                           r"-[0-9]+(?: b(?P<build>[0-9]+))? (?:app|mirror)")
CI_LEFTOVER_HOURS = 12      # longer than any run (build job 60 min, finish job 120 min)
# buildBetaDetails.externalBuildState of a build submitted to TestFlight beta review and not
# reviewed yet: Apple checks its signature again, so its certificate must stay.
REVIEW_PENDING = frozenset({"WAITING_FOR_BETA_REVIEW", "IN_BETA_REVIEW"})
FINISH_JOB = "Processing, TestFlight group, keep or revoke the certificate"   # testflight.yml
ENT_APP_GROUPS = "com.apple.security.application-groups"
ENT_HOTSPOT = "com.apple.developer.networking.HotspotConfiguration"
ENT_WIFI_INFO = "com.apple.developer.networking.wifi-info"

URL_IDENTIFIERS = "https://developer.apple.com/account/resources/identifiers/list"
URL_APP_GROUPS = "https://developer.apple.com/account/resources/identifiers/list/applicationGroup"
URL_CERTIFICATES = "https://developer.apple.com/account/resources/certificates/list"
URL_PROFILES = "https://developer.apple.com/account/resources/profiles/list"
URL_ASC_APPS = "https://appstoreconnect.apple.com/apps"
URL_APPLE_STATUS = "https://developer.apple.com/system-status/"
GUIDE = "docs/TESTFLIGHT.md"

# How to try again after fixing something: a re-run repeats the old commit (and its options).
NEW_RUN_ES = ("lanza una ejecución nueva: Actions ▸ TestFlight ▸ Run workflow (el botón «Re-run» "
              "repite el mismo commit)")
NEW_RUN_EN = "start a new run: Actions ▸ TestFlight ▸ Run workflow (a «Re-run» repeats the same commit)"
# GitHub masks each line of a multi-line secret, so the exact PEM armor lines would print as ***.
PASTE_KEY_ES = ("Abre AuthKey_XXXXXXXXXX.p8 con un editor de texto y pega TODO su contenido en el "
                "secreto ASC_PRIVATE_KEY, incluidas la primera línea (la de BEGIN PRIVATE KEY, con sus "
                f"guiones) y la última (la de END PRIVATE KEY); ver el paso 2 de {GUIDE}. Después "
                f"{NEW_RUN_ES}.")
PASTE_KEY_EN = ("Open AuthKey_XXXXXXXXXX.p8 in a text editor and paste ALL of it into the "
                "ASC_PRIVATE_KEY secret, including the first line (the BEGIN PRIVATE KEY one, with "
                f"its dashes) and the last one (END PRIVATE KEY); see step 2 of {GUIDE}. Then "
                f"{NEW_RUN_EN}.")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OPENSSL = os.environ.get("ASC_OPENSSL") or "openssl"

PREFIX_RE = re.compile(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*")
VERSION_RE = re.compile(r"\d+(\.\d+){0,2}")
RESOURCE_ID_RE = re.compile(r"[A-Za-z0-9._-]+")
UUID_RE = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")


# ---------------------------------------------------------------- output (annotations, outputs)

def _esc_data(text) -> str:
    return str(text).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def _esc_prop(text) -> str:
    return _esc_data(text).replace(":", "%3A").replace(",", "%2C")


def log(message: str = "") -> None:
    print(message, flush=True)


# The resource id after an API collection: /v1/certificates/<id>, /v1/bundleIds/<id>/bundleIdCapabilities…
_API_PATH_ID_RE = re.compile(r"^(/v[0-9]+/[A-Za-z]+/)[^/?]+")


def redact_api_path(path: str) -> str:
    """An API path as the public log shows it (request lines, API errors): the resource id after the
    collection becomes «…», and so does every query value (filters name bundle ids, ids, versions;
    links.next carries cursors). "/v1/profiles/ABC/relationships/certificates?limit=200" →
    "/v1/profiles/…/relationships/certificates?limit=…"."""
    head, sep, query = path.partition("?")
    head = _API_PATH_ID_RE.sub("\\1…", head)
    if not sep:
        return head
    return head + "?" + "&".join(f"{part.split('=', 1)[0]}=…" for part in query.split("&") if part)


def annotate(level: str, title: str, message: str) -> None:
    """A workflow annotation: the only thing readable without access to the raw log."""
    print(f"::{level} title={_esc_prop(title)}::{_esc_data(message)}", flush=True)


def append_summary(markdown: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(markdown.rstrip("\n") + "\n\n")
    except OSError as exc:
        log(f"(cannot write the step summary: {exc})")


# Outputs whose values are states, numbers or the version: echoed to the log as name=value. Every
# other output is an identifier (team, App IDs and their resource ids, the app record, certificate,
# profiles, uploads, builds, the TestFlight group): the log is public, so it shows only the name.
LOGGED_OUTPUT_VALUES = frozenset({"ready", "uploaded", "committed", "processed", "processing_state",
                                  "build_number", "marketing_version"})


def set_output(name: str, value) -> None:
    text = "" if value is None else str(value).replace("\r", " ").replace("\n", " ")
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{name}={text}\n")
    if name in LOGGED_OUTPUT_VALUES:
        log(f"{name}={text}")
    else:
        log(f"{name}: {'set' if text else 'empty'} (value not shown: the log is public)")


_REPORT_LABELS = {"error": ("ERROR", "Error"), "warning": ("AVISO / WARNING", "Aviso / Warning"),
                  "notice": ("NOTA / NOTE", "Nota / Note")}


def report(level: str, title: str, es: str, en: str) -> None:
    """Annotation + plain paragraphs in the log + step summary; Spanish first, then English."""
    annotate(level, title, f"{es}\n\n{en}")
    label, head = _REPORT_LABELS[level]
    log(f"\n{label}: {title}\n\n{es}\n\n{en}\n")
    append_summary(f"#### {head}: {title}\n\n{es}\n\n{en}")


def md_table(rows) -> str:
    lines = ["| | |", "|---|---|"]
    lines += [f"| {key} | {value} |" for key, value in rows]
    return "\n".join(lines)


class Failure(Exception):
    """A failure explained to the owner (Spanish + English), with the exit code to use."""

    def __init__(self, title: str, es: str, en: str, code: int = EXIT_FAILED):
        super().__init__(title)
        self.title, self.es, self.en, self.code = title, es, en, code


# ---------------------------------------------------------------- time (scaled in tests)

def time_scale() -> float:
    try:
        return max(0.0, float(os.environ.get("ASC_POLL_SCALE") or 1))
    except ValueError:
        return 1.0


def pause(seconds: float) -> None:
    time.sleep(max(0.0, seconds) * time_scale())


def deadline_after(minutes: float) -> float:
    return time.monotonic() + max(0.0, minutes) * 60 * time_scale()


# ---------------------------------------------------------------- files and openssl

def write_private_file(path: str, data: bytes) -> None:
    """Create `path` for its owner only (0600) and write `data`. O_EXCL never reuses an existing
    file and never follows a planted symlink."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)


def write_file(path: str, data: bytes) -> None:
    with open(path, "wb") as fh:
        fh.write(data)


def remove_if_present(path: str) -> None:
    if os.path.lexists(path):
        os.unlink(path)


def run_openssl(args, data: bytes = None, check: bool = True) -> subprocess.CompletedProcess:
    cmd = [OPENSSL] + list(args)
    extra = {"input": data} if data is not None else {"stdin": subprocess.DEVNULL}
    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=120, **extra)
    except FileNotFoundError:
        raise Failure("Falta openssl / openssl not found",
                      f"No se encontró el programa «{OPENSSL}», necesario para firmar.",
                      f"The «{OPENSSL}» program, needed for signing, was not found.") from None
    except subprocess.TimeoutExpired:
        raise Failure("openssl no responde / openssl hangs",
                      f"«openssl {args[0]}» no terminó en 120 s.",
                      f"«openssl {args[0]}» did not finish within 120 s.") from None
    if check and proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()[-600:]
        raise Failure(f"openssl {args[0]} falló / failed",
                      f"La orden «openssl {args[0]}» falló: {detail}",
                      f"«openssl {args[0]}» failed: {detail}")
    return proc


def ssl_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    paths = ssl.get_default_verify_paths()
    has_file = bool(paths.cafile) and os.path.isfile(paths.cafile)
    try:
        has_dir = bool(paths.capath) and bool(os.listdir(paths.capath))
    except OSError:
        has_dir = False
    if not (has_file or has_dir):
        # python.org builds for macOS ship without CA certificates until «Install Certificates»
        # runs; the system bundle (the one /usr/bin/openssl uses) verifies Apple's servers.
        for candidate in ("/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt"):
            if os.path.isfile(candidate):
                ctx.load_verify_locations(cafile=candidate)
                break
    return ctx


# ---------------------------------------------------------------- API key and JWT (ES256)

_PEM_BLOCK = re.compile(r"-----BEGIN ([A-Z0-9 ]+?)-----(.*?)-----END \1-----", re.S)


def normalize_private_key(text: str) -> str:
    """Canonical PEM for the .p8 text, however it was pasted into the secret: CRLF, surrounding
    spaces or quotes, literal "\\n", BEGIN/END and the base64 on one line (re-wrapped at 64),
    only the base64 body, or the whole file base64-encoded once more."""
    s = (text or "").strip().strip("\"'").strip()
    s = s.replace("\\r", "").replace("\\n", "\n").replace("\r\n", "\n").replace("\r", "\n")
    match = _PEM_BLOCK.search(s)
    if match:
        label, body = match.group(1).strip(), match.group(2)
    elif "-----BEGIN" in s:
        raise ValueError("it has a BEGIN line but no matching END line")
    else:
        compact = re.sub(r"\s+", "", s)
        try:
            inner = base64.b64decode(compact, validate=True).decode("ascii")
        except (binascii.Error, ValueError, UnicodeDecodeError):
            inner = ""
        if "-----BEGIN" in inner:
            return normalize_private_key(inner)
        label, body = "PRIVATE KEY", compact
    body = re.sub(r"\s+", "", body)
    try:
        der = base64.b64decode(body, validate=True)
    except (binascii.Error, ValueError):
        raise ValueError("the text between BEGIN and END is not valid base64") from None
    if len(der) < 32 or der[0] != 0x30:
        raise ValueError("it does not look like a private key")
    wrapped = "\n".join(body[i:i + 64] for i in range(0, len(body), 64))
    return f"-----BEGIN {label}-----\n{wrapped}\n-----END {label}-----\n"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_length(der: bytes, i: int):
    first = der[i]
    i += 1
    if first < 0x80:
        return first, i
    count = first & 0x7F
    if not 1 <= count <= 2:
        raise ValueError("unsupported DER length")
    return int.from_bytes(der[i:i + count], "big"), i + count


def der_to_raw_signature(der: bytes, size: int = 32) -> bytes:
    """openssl writes ECDSA signatures as DER SEQUENCE { INTEGER r, INTEGER s }; JWS ES256 wants
    r and s as fixed 32-byte big-endian numbers back to back (RFC 7518 §3.4), not DER."""
    try:
        if der[0] != 0x30:
            raise ValueError("not a DER SEQUENCE")
        total, i = _der_length(der, 1)
        if i + total != len(der):
            raise ValueError("bad SEQUENCE length")
        raw = b""
        for _ in range(2):
            if der[i] != 0x02:
                raise ValueError("expected an INTEGER")
            length, i = _der_length(der, i + 1)
            value = der[i:i + length]
            if len(value) != length:
                raise ValueError("truncated INTEGER")
            i += length
            value = value.lstrip(b"\x00")   # DER adds a 0x00 when the high bit is set
            if len(value) > size:
                raise ValueError("INTEGER too large for P-256")
            raw += value.rjust(size, b"\x00")
        if i != len(der):
            raise ValueError("trailing bytes after the signature")
        return raw
    except IndexError:
        raise ValueError("truncated DER signature") from None


def sign_es256(key_pem: str, data: bytes) -> bytes:
    tmp = tempfile.mkdtemp(prefix="asc-jwt-")
    try:
        key_path = os.path.join(tmp, "AuthKey.p8")
        write_private_file(key_path, key_pem.encode("ascii"))
        proc = run_openssl(["dgst", "-sha256", "-sign", key_path], data=data, check=False)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if proc.returncode != 0 or not proc.stdout:
        raise Failure(
            "ASC_PRIVATE_KEY no válida / invalid",
            "openssl no pudo firmar con ASC_PRIVATE_KEY. Debe ser el contenido completo del archivo "
            "AuthKey_XXXXXXXXXX.p8 que descargaste al crear la clave de la API (una clave EC "
            f"P-256). {PASTE_KEY_ES}",
            "openssl could not sign with ASC_PRIVATE_KEY. It must be the whole content of the "
            "AuthKey_XXXXXXXXXX.p8 file downloaded when the API key was created (an EC P-256 "
            f"key). {PASTE_KEY_EN}")
    return proc.stdout


def make_jwt(key_id: str, issuer_id: str, key_pem: str, now: float = None,
             lifetime: int = JWT_LIFETIME):
    """App Store Connect team-key token: ES256 over header.payload; returns (token, exp)."""
    iat = int(time.time() if now is None else now)
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": iat, "exp": iat + lifetime, "aud": "appstoreconnect-v1"}
    signing_input = ".".join(b64url(json.dumps(part, separators=(",", ":")).encode("utf-8"))
                             for part in (header, payload))
    der = sign_es256(key_pem, signing_input.encode("ascii"))
    return f"{signing_input}.{b64url(der_to_raw_signature(der))}", iat + lifetime


class Credentials:
    def __init__(self, key_id: str, issuer_id: str, key_pem: str):
        self.key_id, self.issuer_id, self.key_pem = key_id, issuer_id, key_pem


def load_credentials() -> Credentials:
    key_id = (os.environ.get("ASC_KEY_ID") or "").strip()
    issuer = (os.environ.get("ASC_ISSUER_ID") or "").strip()
    raw = os.environ.get("ASC_PRIVATE_KEY") or ""
    key_path = (os.environ.get("ASC_PRIVATE_KEY_PATH") or "").strip()
    if not raw.strip() and key_path:
        try:
            with open(key_path, encoding="utf-8") as fh:
                raw = fh.read()
        except OSError as exc:
            raise Failure("No se puede leer la clave / Cannot read the key",
                          f"No se pudo leer ASC_PRIVATE_KEY_PATH ({exc.strerror}).",
                          f"Could not read ASC_PRIVATE_KEY_PATH ({exc.strerror}).") from None
    missing = [name for name, value in (("ASC_KEY_ID", key_id), ("ASC_ISSUER_ID", issuer),
                                        ("ASC_PRIVATE_KEY", raw.strip())) if not value]
    if missing:
        names = ", ".join(missing)
        raise Failure(
            "Faltan secretos / Missing secrets",
            f"Faltan los secretos {names}. Créalos en GitHub ▸ Settings ▸ Secrets and variables ▸ "
            f"Actions ▸ New repository secret (pasos en {GUIDE}). Después {NEW_RUN_ES}.",
            f"The secrets {names} are missing. Add them at GitHub ▸ Settings ▸ Secrets and "
            f"variables ▸ Actions ▸ New repository secret (steps in {GUIDE}). Then {NEW_RUN_EN}.")
    try:
        pem = normalize_private_key(raw)
    except ValueError as exc:
        raise Failure(
            "ASC_PRIVATE_KEY no válida / invalid",
            f"El secreto ASC_PRIVATE_KEY no parece el contenido de un archivo .p8 ({exc}). "
            f"{PASTE_KEY_ES}",
            f"The ASC_PRIVATE_KEY secret does not look like the content of a .p8 file ({exc}). "
            f"{PASTE_KEY_EN}") from None
    return Credentials(key_id, issuer, pem)


# ---------------------------------------------------------------- App Store Connect client

class ApiError(Exception):
    def __init__(self, method: str, path: str, status: int, errors):
        self.method, self.path, self.status = method, path, status
        self.errors = [e for e in (errors or []) if isinstance(e, dict)]
        super().__init__(self.describe())

    def text(self) -> str:
        return " ".join(str(e.get(k) or "") for e in self.errors
                        for k in ("code", "title", "detail")).lower()

    @property
    def ambiguous(self) -> bool:
        """No clear answer (network error, timeout, 408, 5xx, or a success whose body was lost):
        Apple may or may not have done what was asked."""
        return self.status in (0, 408) or self.status >= 500 or 200 <= self.status < 300

    @property
    def false_404(self) -> bool:
        """Apple's transient 404 on Build Upload API reads for an app that exists
        ("There is no resource of type 'apps' with id …"; fastlane#29908)."""
        return self.status == 404 and "type 'apps'" in self.text()

    def pointers(self) -> list:
        return [str(e["source"].get("pointer") or "") for e in self.errors
                if isinstance(e.get("source"), dict)]

    def describe(self, details: bool = True) -> str:
        """`details=False` keeps only the error codes (Apple's detail texts can quote an e-mail)."""
        parts = []
        for error in self.errors[:4]:
            bits = [str(error[k]) for k in (("code", "title", "detail") if details else ("code",))
                    if error.get(k)]
            parts.append(" · ".join(b for i, b in enumerate(bits) if b not in bits[:i]))
        parts = [p for p in parts if p]
        status = f"HTTP {self.status}" if self.status else "network error"
        return f"{self.method} {self.path} → {status}" + (f": {'; '.join(parts)}" if parts else "")


def _parse_errors(raw: bytes):
    text = raw.decode("utf-8", "replace").strip()
    try:
        errors = json.loads(text).get("errors")
        if isinstance(errors, list):
            return errors
    except (ValueError, AttributeError):
        pass
    return [{"detail": text[:300]}] if text else []


def retry_delay(attempt: int, retry_after: str = None) -> float:
    if retry_after:
        value = retry_after.strip()
        try:
            return min(300.0, max(0.0, float(value)))
        except ValueError:
            try:
                when = email.utils.parsedate_to_datetime(value)
                return min(300.0, max(0.0, when.timestamp() - time.time()))
            except (TypeError, ValueError, IndexError):
                pass
    return min(60.0, 2.0 * 2 ** attempt)


def attrs(resource) -> dict:
    return (resource or {}).get("attributes") or {}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Apple's API does not redirect: a 3xx becomes an error and the token never follows it."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, creds: Credentials, base: str = None):
        self.creds = creds
        self.base = (base or os.environ.get("ASC_API_BASE") or DEFAULT_API_BASE).rstrip("/")
        self.ssl = ssl_context()
        self.opener = urllib.request.build_opener(_NoRedirect,
                                                  urllib.request.HTTPSHandler(context=self.ssl))
        self._token, self._token_exp = "", 0.0

    def token(self, fresh: bool = False) -> str:
        if fresh or not self._token or self._token_exp - time.time() < JWT_REFRESH_MARGIN:
            token, exp = make_jwt(self.creds.key_id, self.creds.issuer_id, self.creds.key_pem)
            if os.environ.get("GITHUB_ACTIONS") == "true":
                print(f"::add-mask::{token}", flush=True)   # before any use: the log is public
            self._token, self._token_exp = token, exp
        return self._token

    def url(self, path: str, params: dict = None) -> str:
        if "://" in path:
            # links.next: keep its path and query but always send them to our own base URL, so
            # the token can never go to another host.
            parts = urllib.parse.urlsplit(path)
            path = parts.path + (f"?{parts.query}" if parts.query else "")
        url = self.base + path
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params, safe="[],")
        return url

    def request(self, method: str, path: str, body: dict = None, params: dict = None,
                idempotent: bool = None, timeout: float = API_TIMEOUT) -> dict:
        """One API call. 429 (nothing was done) and one 401 (fresh token) are always repeated.
        A network error, 408 or 5xx is repeated only for GET/DELETE or when `idempotent` (a
        repeat is harmless): Apple may already have done what an unanswered POST asked."""
        if idempotent is None:
            idempotent = method in ("GET", "DELETE")
        url = self.url(path, params)
        shown = redact_api_path(url[len(self.base):])   # the log is public: no ids, no query values
        data = json.dumps(body).encode("utf-8") if body is not None else None
        attempt, refreshed = 0, False
        while True:
            headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
            if data is not None:
                headers["Content-Type"] = "application/json"
            request = urllib.request.Request(url, data=data, method=method, headers=headers)
            request.add_unredirected_header("Authorization", f"Bearer {self.token()}")
            retry_after, network_error = None, ""
            try:
                with self.opener.open(request, timeout=timeout) as resp:
                    status, raw = resp.status, resp.read()
            except urllib.error.HTTPError as exc:
                status = exc.code
                try:
                    raw = exc.read()
                except (OSError, http.client.HTTPException):
                    raw = b""
                retry_after = exc.headers.get("Retry-After") if exc.headers is not None else None
            except (urllib.error.URLError, OSError, http.client.HTTPException) as exc:
                status, raw = 0, b""
                network_error = str(getattr(exc, "reason", exc))
            if 200 <= status < 300:
                log(f"  {method} {shown} -> {status}")
                if not raw.strip():
                    return {}
                try:
                    return json.loads(raw.decode("utf-8"))
                except ValueError:
                    raise ApiError(method, shown, status, [{"detail": "response is not JSON"}]) from None
            log(f"  {method} {shown} -> {status or 'network error: ' + network_error}")
            if status == 401 and not refreshed:
                refreshed = True                  # e.g. a token minted on a skewed clock
                self.token(fresh=True)
                continue
            unclear = status in (0, 408) or status >= 500
            retryable = status == 429 or (idempotent and unclear)
            if retryable and attempt < API_RETRIES:
                delay = retry_delay(attempt, retry_after)
                attempt += 1
                log(f"    retry {attempt}/{API_RETRIES} in {delay:g} s")
                pause(delay)
                continue
            errors = _parse_errors(raw) if status else [{"code": "NETWORK", "detail": network_error}]
            raise ApiError(method, shown, status, errors)

    def get_all(self, path: str, params: dict = None, max_pages: int = 50,
                included: list = None) -> list:
        """Every item of a list endpoint, following links.next. `included`, when given, collects
        the resources an include= parameter brought along."""
        items, pages = [], 1
        doc = self.request("GET", path, params=params)
        while True:
            data = doc.get("data")
            if isinstance(data, list):
                items.extend(d for d in data if isinstance(d, dict))
            if included is not None and isinstance(doc.get("included"), list):
                included.extend(d for d in doc["included"] if isinstance(d, dict))
            nxt = (doc.get("links") or {}).get("next")
            if not nxt or pages >= max_pages:
                return items
            doc = self.request("GET", nxt)
            pages += 1


def read_uploads(client: Client, path: str, params: dict = None, every_page: bool = False):
    """A Build Upload API read (buildUploads, buildUploadFiles). Apple sometimes answers these
    with a false 404 for an app that exists: try again a few times before giving up."""
    for delay in FALSE_404_PAUSES + (None,):
        try:
            if every_page:
                return client.get_all(path, params)
            return client.request("GET", path, params=params)
        except ApiError as err:
            if delay is None or not err.false_404:
                raise
            log(f"    Apple's transient 404 (type 'apps'): trying again in {delay:g} s")
            pause(delay)


def explain(err: ApiError, context_es: str = "", context_en: str = "") -> Failure:
    detail = err.describe()
    pre_es = f"{context_es}: " if context_es else ""
    pre_en = f"{context_en}: " if context_en else ""
    if err.false_404:
        return Failure(
            "Fallo temporal de Apple / Temporary Apple error (404)",
            f"{pre_es}App Store Connect respondió varias veces que la app no existe (HTTP 404), "
            "aunque existe: es un fallo temporal conocido de la API de subidas de Apple. No tienes "
            f"que cambiar nada: espera unos minutos y {NEW_RUN_ES}. Detalle: {detail}",
            f"{pre_en}App Store Connect answered several times that the app does not exist (HTTP "
            "404), although it does: a known temporary fault of Apple's upload API. Nothing to "
            f"change: wait a few minutes and {NEW_RUN_EN}. Detail: {detail}")
    if err.status == 401:
        return Failure(
            "Clave de API rechazada / API key rejected (401)",
            f"{pre_es}App Store Connect rechazó la clave de la API (HTTP 401). Revisa los tres "
            "secretos (GitHub ▸ Settings ▸ Secrets and variables ▸ Actions): ASC_KEY_ID = el «Key "
            "ID» de 10 caracteres; ASC_ISSUER_ID = el «Issuer ID» (un UUID) que aparece encima de "
            "la lista de claves en App Store Connect ▸ Usuarios y acceso ▸ Integraciones ▸ App "
            "Store Connect API ▸ «Claves de equipo»; ASC_PRIVATE_KEY = el archivo .p8 completo. "
            f"Debe ser una clave de equipo (no individual) y no estar revocada. Después {NEW_RUN_ES}. "
            f"Detalle: {detail}",
            f"{pre_en}App Store Connect rejected the API key (HTTP 401). Check the three secrets "
            "(GitHub ▸ Settings ▸ Secrets and variables ▸ Actions): ASC_KEY_ID = the 10-character "
            "Key ID; ASC_ISSUER_ID = the Issuer ID (a UUID) shown above the key list in App Store "
            "Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API ▸ Team Keys; "
            "ASC_PRIVATE_KEY = the whole .p8 file. It must be a Team key (not an Individual key) "
            f"and not revoked. Then {NEW_RUN_EN}. Detail: {detail}")
    if err.status == 403 and "agreement" in err.text():
        return Failure(
            "Acuerdos pendientes / Agreements to accept (403)",
            f"{pre_es}Apple exige aceptar acuerdos pendientes antes de usar la API (HTTP 403). "
            "Entra con la cuenta del titular (Account Holder) en https://developer.apple.com/account "
            "y en App Store Connect ▸ Negocios (Business), acepta los acuerdos o términos nuevos y "
            f"después {NEW_RUN_ES}. Detalle: {detail}",
            f"{pre_en}Apple requires pending agreements to be accepted before the API can be used "
            "(HTTP 403). Sign in as the Account Holder at https://developer.apple.com/account and "
            f"App Store Connect ▸ Business, accept the new agreements or terms, then {NEW_RUN_EN}. "
            f"Detail: {detail}")
    if err.status == 403:
        return Failure(
            "Permiso denegado / Not allowed (403)",
            f"{pre_es}La clave de la API no tiene permiso para esta operación (HTTP 403). Crea una "
            "clave con el rol «Admin» (App Store Connect ▸ Usuarios y acceso ▸ Integraciones ▸ App "
            "Store Connect API ▸ Claves de equipo; los certificados y perfiles necesitan Admin) y "
            "actualiza ASC_KEY_ID y ASC_PRIVATE_KEY. Si ya es Admin, mira si hay acuerdos "
            "pendientes en https://developer.apple.com/account y en App Store Connect ▸ Negocios "
            f"(Business). Después {NEW_RUN_ES}. Detalle: {detail}",
            f"{pre_en}The API key is not allowed to do this (HTTP 403). Create a key with the "
            "«Admin» role (App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect "
            "API ▸ Team Keys; certificates and profiles need Admin) and update ASC_KEY_ID and "
            "ASC_PRIVATE_KEY. If it already is Admin, check for pending agreements at "
            "https://developer.apple.com/account and in App Store Connect ▸ Business. Then "
            f"{NEW_RUN_EN}. Detail: {detail}")
    if err.status == 429:
        return Failure(
            "Límite de peticiones / Rate limited (429)",
            f"{pre_es}Apple limita las peticiones a la API (HTTP 429) y siguió rechazándolas tras "
            f"{API_RETRIES} reintentos. Espera una hora y {NEW_RUN_ES}. Detalle: {detail}",
            f"{pre_en}Apple rate-limits the API (HTTP 429) and kept refusing after {API_RETRIES} "
            f"retries. Wait an hour, then {NEW_RUN_EN}. Detail: {detail}")
    if err.status in (0, 408):      # 408: the request timed out on the way, like a network error
        return Failure(
            "Error de red / Network error",
            f"{pre_es}No se pudo hablar con App Store Connect (error de red). Suele ser temporal: "
            f"{NEW_RUN_ES}. Detalle: {detail}",
            f"{pre_en}Could not reach App Store Connect (network error). This is usually "
            f"temporary: {NEW_RUN_EN}. Detail: {detail}")
    if err.status >= 500:
        return Failure(
            f"App Store Connect no responde / not responding ({err.status})",
            f"{pre_es}App Store Connect devolvió errores internos (HTTP {err.status}). Suele ser "
            f"temporal: mira {URL_APPLE_STATUS} y, más tarde, {NEW_RUN_ES}. Detalle: {detail}",
            f"{pre_en}App Store Connect returned internal errors (HTTP {err.status}). This is "
            f"usually temporary: check {URL_APPLE_STATUS} and later {NEW_RUN_EN}. "
            f"Detail: {detail}")
    return Failure(
        f"App Store Connect: HTTP {err.status}",
        f"{pre_es}App Store Connect rechazó la petición. Detalle: {detail}",
        f"{pre_en}App Store Connect refused the request. Detail: {detail}")


# ---------------------------------------------------------------- owner instructions

def app_group_steps(app_bid: str, mirror_bid: str, group: str):
    es = (f"1. Crea el App Group: abre {URL_APP_GROUPS}, pulsa «+», elige «App Groups» ▸ "
          f"Continue, descripción «OpenCfMoto», identificador `{group}` ▸ Continue ▸ Register.\n"
          f"2. Asígnalo a los DOS App IDs: en {URL_IDENTIFIERS} abre `{app_bid}`, junto a «App "
          f"Groups» pulsa «Configure» (o «Edit»), marca `{group}` ▸ Continue ▸ Save ▸ Confirm. "
          f"Repite con `{mirror_bid}`.")
    en = (f"1. Create the App Group: open {URL_APP_GROUPS}, click «+», choose «App Groups» ▸ "
          f"Continue, description «OpenCfMoto», identifier `{group}` ▸ Continue ▸ Register.\n"
          f"2. Assign it to BOTH App IDs: at {URL_IDENTIFIERS} open `{app_bid}`, next to «App "
          f"Groups» click «Configure» (or «Edit»), tick `{group}` ▸ Continue ▸ Save ▸ Confirm. "
          f"Do the same for `{mirror_bid}`.")
    return es, en


def app_record_step(app_bid: str, number: int):
    es = (f"{number}. Crea la app en App Store Connect: {URL_ASC_APPS} ▸ «+» ▸ «Nueva app»: "
          "plataforma iOS, un nombre (p. ej. «OpenCfMoto»; si ya está ocupado en la App Store, "
          f"añade algo como tu nombre), idioma principal, Bundle ID `{app_bid}` (elígelo de la "
          "lista), SKU `opencfmoto`, acceso completo ▸ Crear.")
    en = (f"{number}. Create the app in App Store Connect: {URL_ASC_APPS} ▸ «+» ▸ «New App»: "
          "platform iOS, a name (e.g. «OpenCfMoto»; if the App Store name is taken, add something "
          f"like your name), primary language, bundle ID `{app_bid}` (pick it from the list), "
          "SKU `opencfmoto`, Full Access ▸ Create.")
    return es, en


RUN_AGAIN_ES = ("Después lanza una ejecución nueva sin marcar «Solo preparar»: Actions ▸ TestFlight "
                "▸ Run workflow (el botón «Re-run» repite el mismo commit y las mismas opciones).")
RUN_AGAIN_EN = ("Then start a new run without ticking «Solo preparar»: Actions ▸ TestFlight ▸ Run "
                "workflow (a «Re-run» repeats the same commit and options).")

def _ids(ids) -> str:
    """" (id X)" / " (ids X, Y)": the developer portal's lists do not show ids, so they only
    come after what the lists do show (type, date, name)."""
    ids = list(ids)
    return f" ({'id' if len(ids) == 1 else 'ids'} {', '.join(ids)})" if ids else ""


def build_tag(build) -> str:
    """The build number as profile names carry it: digits only, "" for anything else."""
    text = str(build or "").strip()
    return text if re.fullmatch(r"[0-9]+", text) else ""


def profile_name(suffix: str, build: str, role: str) -> str:
    """A CI profile's name: «OpenCfMoto CI <suffix> b<build> app|mirror» (CI_PROFILE_RE), or
    without « b<build>» when no build number is known."""
    tag = build_tag(build)
    return f"{CI_PROFILE_PREFIX}{suffix}{f' b{tag}' if tag else ''} {role}"


def run_profile_names(suffix: str = "", build=None):
    """(app, mirror): this run's two profiles as the developer portal's Profiles list names them.
    `suffix`: the exact one create-signing used (the teardown knows it). Without it, the name is
    made from this run's ids as default_suffix() makes it, with «…» for the attempt (the finish
    job's attempt can differ from the build job's); «…» alone outside GitHub Actions. `build`: the
    build number in the names (None: BUILD_NUMBER, which every job that signs or cleans up has)."""
    if not suffix:
        run = os.environ.get("GITHUB_RUN_ID") or ""
        repo = os.environ.get("GITHUB_REPOSITORY_ID") or ""
        suffix = "…"
        if re.fullmatch(r"[0-9]+", run):
            suffix = f"{run}-…"
            if re.fullmatch(r"[0-9]+", repo):
                suffix = f"r{repo}-{suffix}"
    if build is None:
        build = os.environ.get("BUILD_NUMBER") or ""
    return profile_name(suffix, build, "app"), profile_name(suffix, build, "mirror")


# A run's own manual steps must never send the owner after the certificate the workflow keeps on
# purpose: it can be «created today» as well (an earlier run of the same day).
KEPT_CAUTION_ES = ("No revoques el certificado que el workflow conserva a propósito para la "
                   "última build que Apple aceptó (lo usan sus perfiles «OpenCfMoto CI … bN app» "
                   "y «… bN mirror», de otra ejecución, con N el número de esa build): mientras "
                   "esa build esté en revisión o sea la que vas a enviar a las pruebas externas, "
                   "revocarlo hace que Apple la marque «Invalid Binary» (ITMS-90035).")
KEPT_CAUTION_EN = ("Do not revoke the certificate the workflow keeps on purpose for the latest "
                   "build Apple accepted (its profiles «OpenCfMoto CI … bN app» and «… bN "
                   "mirror», of another run, N being that build's number, use it): while that "
                   "build is in review or is the one you will send to external testing, revoking "
                   "it makes Apple mark it «Invalid Binary» (ITMS-90035).")


def manual_revoke(cert_ids=(), profile_ids=(), suffix: str = "", certs: bool = True,
                  profiles: bool = True, build=None):
    """(es, en): how to revoke by hand what this run created today, the way the developer portal
    lists it: the certificate by its type and date, the profiles by this run's names, never every
    «OpenCfMoto CI …» one (another repository's or a Mac's run may still be using its own), and
    never the certificate kept for the latest accepted build (KEPT_CAUTION).
    `certs=False` / `profiles=False`: nothing of that kind can be left (it went, none was made,
    or another message names it). `build`: as in run_profile_names."""
    cert_ids, profile_ids = list(cert_ids), list(profile_ids)
    certs = certs or not profiles
    es, en = [], []
    if certs:
        many = len(cert_ids) > 1
        es.append(f"En {URL_CERTIFICATES}: " + (
            f"los certificados «Apple Distribution» creados hoy{_ids(cert_ids)}, púlsalos uno a uno "
            "▸ Revoke." if many else
            f"el certificado «Apple Distribution» creado hoy{_ids(cert_ids)}, púlsalo ▸ Revoke."))
        en.append(f"At {URL_CERTIFICATES}: " + (
            f"the «Apple Distribution» certificates created today{_ids(cert_ids)}, click each ▸ "
            "Revoke." if many else
            f"the «Apple Distribution» certificate created today{_ids(cert_ids)}, click it ▸ Revoke."))
    if profiles:
        app, mirror = run_profile_names(suffix, build)
        es.append(f"En {URL_PROFILES}: los perfiles «{app}» y «{mirror}» que queden"
                  f"{_ids(profile_ids)}, cada uno ▸ Remove (ningún otro «OpenCfMoto CI …»).")
        en.append(f"At {URL_PROFILES}: the «{app}» and «{mirror}» profiles that are left"
                  f"{_ids(profile_ids)}, each ▸ Remove (no other «OpenCfMoto CI …» one).")
    if certs:
        es.append(KEPT_CAUTION_ES)
        en.append(KEPT_CAUTION_EN)
        es.append("Un certificado olvidado ocupa uno de los pocos certificados de distribución que "
                  "permite Apple.")
        en.append("A forgotten certificate uses one of the few distribution certificates Apple allows.")
    return (" ".join(["Revoca a mano lo que quede." if certs else "Borra a mano lo que quede."] + es),
            " ".join(["Revoke what is left by hand." if certs else "Delete what is left by hand."] + en))


# After a build reached Apple its certificate must outlive the build job, and it stays after the
# finish job too when Apple accepts the build. A duplicate certificate (made by an unanswered
# request, in no profile) signs nothing; told apart from the build's own it can go, but revoking
# the build's own by mistake would break the build, so when in doubt it stays until it expires.
AFTER_FINISH_ES = (f"Cuando termine el trabajo «{FINISH_JOB}», el certificado de esta "
                   "build sigue en la cuenta si Apple la aceptó (lo usan sus perfiles «OpenCfMoto "
                   "CI … bN app» y «… bN mirror», con N el número de esta build): no lo revoques "
                   "mientras esa build esté en revisión o sea la que vas a enviar. En "
                   f"{URL_CERTIFICATES} revoca solo el duplicado (el de este aviso, si da su id; "
                   "púlsalo ▸ Revoke). Ante la duda, déjalo: no firma nada; solo ocupa uno de los "
                   "pocos certificados de distribución que permite Apple hasta que caduque.")
AFTER_FINISH_EN = (f"Once the «{FINISH_JOB}» job has finished, this build's certificate stays "
                   "in the account if Apple accepted the build (its profiles «OpenCfMoto CI … bN "
                   "app» and «… bN mirror», N being this build's number, use it): do not revoke it "
                   "while that build is in review or is the one you will submit. At "
                   f"{URL_CERTIFICATES} revoke only the duplicate (the one this warning names, if "
                   "it gives its id; click it ▸ Revoke). When in doubt, leave it: it signs "
                   "nothing; it only uses one of the few distribution certificates Apple allows "
                   "until it expires.")


# ---------------------------------------------------------------- check-auth

def cmd_check_auth(args) -> int:
    creds = load_credentials()
    if not re.fullmatch(r"[A-Z0-9]{10}", creds.key_id):
        report("warning", "ASC_KEY_ID inusual / unusual",
               "ASC_KEY_ID no tiene la forma habitual (10 letras mayúsculas o cifras). Comprueba "
               "que es el «Key ID» de la clave y no otro dato.",
               "ASC_KEY_ID does not look like a Key ID (10 upper-case letters or digits). Check "
               "that it is the key's Key ID and not something else.")
    if not UUID_RE.fullmatch(creds.issuer_id):
        report("warning", "ASC_ISSUER_ID inusual / unusual",
               "ASC_ISSUER_ID no tiene la forma de un UUID (8-4-4-4-12). Es el «Issuer ID» que "
               "aparece encima de la lista de claves de equipo.",
               "ASC_ISSUER_ID does not look like a UUID (8-4-4-4-12). It is the Issuer ID shown "
               "above the Team Keys list.")
    client = Client(creds)
    try:
        client.request("GET", "/v1/bundleIds", params={"limit": "1"})
    except ApiError as err:
        raise explain(err, "Comprobación de la clave", "API key check") from None
    log("App Store Connect API key OK / clave de la API válida")
    append_summary("**App Store Connect:** clave de la API válida / API key valid.")
    return EXIT_OK


# ---------------------------------------------------------------- prepare

def read_marketing_version(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise Failure("No se encuentra project.yml / project.yml not found",
                      f"No se pudo leer {path} ({exc.strerror}).",
                      f"Could not read {path} ({exc.strerror}).") from None
    match = re.search(r'MARKETING_VERSION:\s*"?([0-9.]+)', text)
    if not match:
        raise Failure("Falta MARKETING_VERSION / MARKETING_VERSION missing",
                      f"No se encontró MARKETING_VERSION en {path} (settings.base).",
                      f"MARKETING_VERSION was not found in {path} (settings.base).")
    return match.group(1)


def ensure_bundle_id(client: Client, identifier: str, name: str):
    """(bundleIds resource, created?). filter[identifier] is a substring match (X also returns
    X.mirror), so the identifier is compared exactly here."""
    def lookup(platform):
        params = {"filter[identifier]": identifier, "limit": "200"}
        if platform:
            params["filter[platform]"] = platform
        for item in client.get_all("/v1/bundleIds", params):
            if attrs(item).get("identifier") == identifier:
                return item
        return None

    found = lookup("IOS")
    if found:
        return found, False
    body = {"data": {"type": "bundleIds",
                     "attributes": {"identifier": identifier, "name": name, "platform": "IOS"}}}
    try:
        # A repeat after a lost answer gets 409 and the lookup below finds the new App ID.
        return client.request("POST", "/v1/bundleIds", body, idempotent=True)["data"], True
    except ApiError as err:
        if err.status != 409:
            raise explain(err, f"Registrar el App ID {identifier}",
                          f"Registering the App ID {identifier}") from None
    for attempt in range(3):
        # Registered by a request whose answer was lost (the list may lag behind it), or earlier
        # with another platform (e.g. UNIVERSAL)?
        found = lookup(None)
        if found:
            return found, False
        if attempt < 2:
            pause(RECHECK_SEC)
    raise Failure(
        "Bundle ID no disponible / Bundle ID not available",
        f"Apple no deja registrar `{identifier}`: ya lo usa otro equipo de desarrollador. Si es la "
        "primera ejecución, lanza una ejecución nueva una vez antes de cambiar el prefijo. Si se "
        "repite, define la variable del repositorio BUNDLE_ID_PREFIX (GitHub ▸ Settings ▸ Secrets "
        "and variables ▸ Actions ▸ Variables) con un prefijo propio, p. ej. `com.tunombre`. "
        f"Después {NEW_RUN_ES}.",
        f"Apple will not register `{identifier}`: another developer team already uses it. If this "
        "is the first run, start one new run before changing the prefix. If it happens again, set "
        "the repository variable BUNDLE_ID_PREFIX (GitHub ▸ Settings ▸ Secrets and variables ▸ "
        f"Actions ▸ Variables) to a prefix of your own, e.g. `com.yourname`. Then {NEW_RUN_EN}.")


def ensure_capabilities(client: Client, bundle: dict, wanted) -> list:
    """Enable the capabilities missing on an App ID; returns the ones enabled now."""
    path = f"/v1/bundleIds/{bundle['id']}/bundleIdCapabilities"
    # No `limit`: the live API answers 400 PARAMETER_ERROR.ILLEGAL for it on this relationship,
    # although the OpenAPI spec lists it.
    existing = {attrs(c).get("capabilityType") for c in client.get_all(path)}
    added = []
    for capability in wanted:
        if capability in existing:
            continue
        body = {"data": {"type": "bundleIdCapabilities",
                         "attributes": {"capabilityType": capability},
                         "relationships": {"bundleId": {"data": {"type": "bundleIds",
                                                                 "id": bundle["id"]}}}}}
        try:
            client.request("POST", "/v1/bundleIdCapabilities", body, idempotent=True)
            added.append(capability)
        except ApiError as err:
            if err.status == 409:   # already enabled
                continue
            identifier = attrs(bundle).get("identifier", bundle["id"])
            raise explain(err, f"Activar {capability} en {identifier}",
                          f"Enabling {capability} on {identifier}") from None
    return added


def find_app(client: Client, bundle_id: str):
    # There is no POST /v1/apps: the App Store Connect record is created by the owner on the web.
    for app in client.get_all("/v1/apps", {"filter[bundleId]": bundle_id, "limit": "200"}):
        if attrs(app).get("bundleId") == bundle_id:
            return app
    return None


def _first_int(version):
    match = re.match(r"\s*(\d+)", str(version or ""))
    return int(match.group(1)) if match else None


def next_build_number(client: Client, app_id: str) -> int:
    """1 + the highest build number Apple has seen (processed builds and raw uploads)."""
    numbers = [_first_int(attrs(b).get("version"))
               for b in client.get_all("/v1/builds", {"filter[app]": app_id, "limit": "200"})]
    uploads = read_uploads(client, f"/v1/apps/{app_id}/buildUploads", {"limit": "200"},
                           every_page=True)
    numbers += [_first_int(attrs(u).get("cfBundleVersion")) for u in uploads]
    numbers = [n for n in numbers if n is not None]
    return max(numbers) + 1 if numbers else 1


def cmd_prepare(args) -> int:
    prefix = args.prefix.strip()
    if not PREFIX_RE.fullmatch(prefix):
        raise Failure("Prefijo no válido / Invalid prefix",
                      f"«{prefix}» no sirve como prefijo de Bundle ID (solo letras, cifras, guiones y "
                      "puntos, p. ej. com.tunombre). Revisa la variable BUNDLE_ID_PREFIX y después "
                      f"{NEW_RUN_ES}.",
                      f"«{prefix}» is not a valid bundle ID prefix (letters, digits, hyphens and dots "
                      f"only, e.g. com.yourname). Check the BUNDLE_ID_PREFIX variable, then "
                      f"{NEW_RUN_EN}.",
                      code=EXIT_USAGE)
    app_bid = f"{prefix}.opencfmoto"
    mirror_bid = f"{app_bid}.mirror"
    group = f"group.{prefix}.opencfmoto"
    marketing = read_marketing_version(args.project_yml)
    client = Client(load_credentials())

    app_bundle, app_new = ensure_bundle_id(client, app_bid, APP_BUNDLE_NAME)
    mirror_bundle, mirror_new = ensure_bundle_id(client, mirror_bid, MIRROR_BUNDLE_NAME)
    app_added = ensure_capabilities(client, app_bundle, APP_CAPABILITIES)
    mirror_added = ensure_capabilities(client, mirror_bundle, MIRROR_CAPABILITIES)
    team_id = attrs(app_bundle).get("seedId") or ""   # App ID prefix = team ID on modern teams
    app = find_app(client, app_bid)
    app_id = app["id"] if app else ""
    # The key works: remove what an interrupted run left and the signing sets no build needs any
    # more (their builds' states come from the app record). Warnings only.
    janitor(client, app_id=app_id)
    ready = bool(app) and not args.setup_only

    for key, value in (("ready", "true" if ready else "false"), ("team_id", team_id),
                       ("app_bundle_id", app_bid), ("mirror_bundle_id", mirror_bid),
                       ("app_bundle_resource_id", app_bundle["id"]),
                       ("mirror_bundle_resource_id", mirror_bundle["id"]), ("app_group", group),
                       ("app_id", app_id), ("marketing_version", marketing)):
        set_output(key, value)

    def state(new):
        return "registrado ahora / registered now" if new else "ya existía / already there"

    rows = [("App ID (app)", f"`{app_bid}` — {state(app_new)}"),
            ("App ID (extensión / extension)", f"`{mirror_bid}` — {state(mirror_new)}"),
            ("Capacidades activadas ahora / capabilities enabled now",
             "; ".join(f"`{bid}`: {', '.join(caps)}" for bid, caps in
                       ((app_bid, app_added), (mirror_bid, mirror_added)) if caps) or "—"),
            ("App Group", f"`{group}` (la API no puede comprobarlo / the API cannot check it)"),
            ("App en App Store Connect / app record",
             "encontrada / found" if app else "falta / missing"),
            ("Versión / version", marketing)]
    summary = "### TestFlight · preparar / prepare\n\n" + md_table(rows)

    if not app:
        group_es, group_en = app_group_steps(app_bid, mirror_bid, group)
        app_es, app_en = app_record_step(app_bid, 3)
        es = ("Falta la app en App Store Connect (Apple no permite crearla con la API). Pasos "
              "pendientes, solo una vez, en la web de Apple (los del App Group, si no los hiciste "
              f"ya):\n\n{group_es}\n{app_es}\n\n{RUN_AGAIN_ES}")
        en = ("The app record is missing in App Store Connect (Apple's API cannot create it). "
              "Remaining one-time steps on Apple's web sites (the App Group ones unless already "
              f"done):\n\n{group_en}\n{app_en}\n\n{RUN_AGAIN_EN}")
        if args.setup_only:
            append_summary(f"{summary}\n\n#### Pasos pendientes / Remaining steps\n\n{es}\n\n{en}")
            log(f"\n{es}\n\n{en}\n")
            return EXIT_OK
        append_summary(summary)
        raise Failure("Falta la app en App Store Connect / App record missing", es, en)
    if args.setup_only:
        es = ("Todo listo. (Si aún no creaste el App Group "
              f"`{group}` y lo asignaste a los dos App IDs, hazlo antes; la ejecución completa lo "
              f"comprueba y te dice cómo.) {RUN_AGAIN_ES}")
        en = ("All set. (If you have not created the App Group "
              f"`{group}` and assigned it to both App IDs yet, do that first; the full run checks "
              f"it and tells you how.) {RUN_AGAIN_EN}")
        log("todo listo, ejecuta sin Solo preparar / all set, run without 'Solo preparar'")
        append_summary(f"{summary}\n\n{es}\n\n{en}")
        return EXIT_OK
    append_summary(f"{summary}\n\nSe compila, firma y sube la versión {marketing}. / Version "
                   f"{marketing} is now compiled, signed and uploaded.")
    return EXIT_OK


# ---------------------------------------------------------------- next-build

def cmd_next_build(args) -> int:
    """Chosen in the build job, not in prepare: a re-run of that job then gets a fresh number."""
    client = Client(load_credentials())
    try:
        number = next_build_number(client, args.app_id)
    except ApiError as err:
        raise explain(err, "Elegir el número de build", "Choosing the build number") from None
    set_output("build_number", number)
    env_file = os.environ.get("GITHUB_ENV")
    if env_file:    # later steps of the job see BUILD_NUMBER
        with open(env_file, "a", encoding="utf-8") as fh:
            fh.write(f"BUILD_NUMBER={number}\n")
    log(f"Build number / número de build: {number}")
    return EXIT_OK


# ---------------------------------------------------------------- janitor (leftovers)

def profile_certificate_ids(client: Client, profile: dict) -> list:
    """Certificate ids a profile listed with include=certificates refers to. That linkage shows at
    most meta.paging.limit of them, and its `total` is optional (0 in captured live answers), so it
    counts as complete only when that is provable: fewer ids than the limit, or a positive total
    they reach. Otherwise the relationship is read in full (no `limit`: see ensure_capabilities)."""
    rel = (profile.get("relationships") or {}).get("certificates") or {}
    data = rel.get("data")
    paging = (rel.get("meta") or {}).get("paging") or {}
    total, limit = paging.get("total"), paging.get("limit")
    ids = [str(d.get("id")) for d in data or [] if isinstance(d, dict) and d.get("id")]
    counted = isinstance(total, int) and total > 0
    complete = isinstance(data, list) and not (counted and total > len(ids)) and (
        (isinstance(limit, int) and len(ids) < limit) or (counted and total <= len(ids)))
    if not complete:
        path = f"/v1/profiles/{profile['id']}/relationships/certificates"
        ids = [str(d.get("id")) for d in client.get_all(path) if d.get("id")]
    return _unique(ids)


def classify_profile(profile: dict, repo_id: str, run_id: str = "", keep_run: str = "",
                     now: float = None):
    """What the sweep does with a profile; only the exact names create-signing gives, App Store
    type only. None: never touched now. "leftover": remove. ("set", build): this repository's
    signing set of that build, whose build decides (set_fate).
    - run_id (the finish job, after a build job that ended without its clean-up): only that run's
      profiles of this repository, as leftovers.
    - keep_run (settle-signing, once that run's build was accepted): that run's profiles stay.
    - This repository's (its id is in the name): a set when the name has « b<build>»; any other
      name is a leftover at any age (GitHub's concurrency group runs one TestFlight run at a time
      per repository, so none of them is in use).
    - Another repository's set: never (that repository's own runs decide about it).
    - Anything else (another repository's names from before the build number, a manual run on a
      Mac): a leftover only once older than CI_LEFTOVER_HOURS (that run may still be building)."""
    info = attrs(profile)
    match = CI_PROFILE_RE.fullmatch(str(info.get("name") or ""))
    if not match or (info.get("profileType") or "IOS_APP_STORE") != "IOS_APP_STORE":
        return None
    ours = bool(repo_id) and match.group("repo") == repo_id
    if run_id:
        return "leftover" if ours and match.group("run") == run_id else None
    if keep_run and ours and match.group("run") == keep_run:
        return None
    build = match.group("build")
    if ours:
        return ("set", int(build)) if build else "leftover"
    if build and match.group("repo"):
        return None
    created = _timestamp(info.get("createdDate"))   # unknown: kept (never removed by mistake)
    now = time.time() if now is None else now
    return "leftover" if created > 0 and now - created > CI_LEFTOVER_HOURS * 3600 else None


class BuildFacts:
    """What App Store Connect says about the builds of one build number."""

    def __init__(self):
        self.refused = False    # one of them is INVALID or FAILED (Apple refused it)
        self.alive = False      # one of them is neither refused nor expired
        self.valid = False      # an alive one is VALID: it can be tested and submitted
        self.pending = False    # an alive one waits for or is in TestFlight beta review
        self.unread = False     # an alive VALID one whose TestFlight state was not in the answer


def app_builds(client: Client, app_id: str) -> dict:
    """{build number: BuildFacts} of the app's builds (GET /v1/builds?include=buildBetaDetail).
    Beta review is read from buildBetaDetails.externalBuildState, not from
    betaAppReviewSubmissions.betaReviewState: every build has exactly one build beta detail, so one
    missing from the answer is missing data (never taken for «not in review»), and it is the build's
    own TestFlight state as App Store Connect shows it (Ready to Submit, Waiting for Review, In Beta
    Review, Expired...). A beta app review submission exists only once a build was submitted, so a
    missing one cannot be told from «never submitted», and its state stays APPROVED or REJECTED
    after the build has expired. Raises ApiError when the listing fails."""
    included = []
    builds = client.get_all("/v1/builds", {"filter[app]": app_id, "include": "buildBetaDetail",
                                           "limit": "200"}, included=included)
    external = {str(d.get("id")): str(attrs(d).get("externalBuildState") or "") for d in included
                if d.get("type") == "buildBetaDetails" and d.get("id")}
    facts = {}
    for build in builds:
        info = attrs(build)
        number = build_tag(info.get("version"))
        if not number:          # not a plain build number: never one this workflow made
            continue
        fact = facts.setdefault(int(number), BuildFacts())
        link = ((build.get("relationships") or {}).get("buildBetaDetail") or {}).get("data")
        state = external.get(str(link.get("id"))) if isinstance(link, dict) else None
        if str(info.get("processingState") or "") in ("INVALID", "FAILED"):
            fact.refused = True
        elif info.get("expired") is not True and state != "EXPIRED":
            fact.alive = True
            if info.get("processingState") == "VALID":
                fact.valid = True
                fact.unread = fact.unread or not state
                fact.pending = fact.pending or state in REVIEW_PENDING
    return facts


def newest_accepted(facts: dict):
    """The newest build Apple accepted that can still be tested or submitted (VALID, not
    expired): the one the owner submits. None when there is none."""
    return max((number for number, fact in facts.items() if fact.valid), default=None)


def set_fate(number: int, facts: dict, newest):
    """(keep?, why in Spanish, why in English, known?) for this repository's signing set of build
    `number`, given the app's builds and the newest accepted one. known=False: kept only for want
    of data. Nothing is revoked on missing data: a build the answer does not show, or whose
    TestFlight state it lacks, keeps its set unless a newer build was accepted (a build that is
    not listed cannot be in beta review)."""
    fact = facts.get(number)
    if fact is not None and not fact.alive:
        if fact.refused:
            return False, f"Apple rechazó la build {number}", f"Apple rejected build {number}", True
        return False, f"la build {number} caducó", f"build {number} expired", True
    if fact is not None and fact.pending:
        return (True, f"la build {number} está en la revisión de TestFlight",
                f"build {number} is in TestFlight beta review", True)
    if newest is not None and number == newest:
        return (True, f"la build {number} es la más reciente que Apple aceptó",
                f"build {number} is the newest build Apple accepted", True)
    if newest is not None and number < newest:
        if fact is not None and fact.unread:
            return (True, f"no se pudo leer el estado de TestFlight de la build {number}",
                    f"the TestFlight state of build {number} could not be read", False)
        return (False, f"Apple aceptó una build más reciente que la {number} (la {newest})",
                f"Apple accepted a newer build than {number} ({newest})", True)
    return (True, f"Apple aún no terminó con la build {number}",
            f"Apple has not finished with build {number} yet", True)


def _expiry(cert: dict) -> str:
    return str(attrs(cert).get("expirationDate") or "")[:10]     # YYYY-MM-DD


def _joined(items, word: str) -> str:
    """«a», «b» y «c» / «a», «b» and «c»."""
    items = list(items)
    return items[0] if len(items) == 1 else f"{', '.join(items[:-1])} {word} {items[-1]}"


class Sweep:
    """What sweep() did: (Spanish, English) texts."""

    def __init__(self):
        self.leftovers = []     # what went that a run had left behind
        self.retired = []       # what went because its build no longer needs it
        self.retired_why = []   # why, per build
        self.kept = []          # why each signing set stays
        self.problems = []      # what should have gone and is left, by name
        self.unchecked = []     # sets kept for want of data (why)


def sweep(client: Client, run_id: str = "", app_id: str = "", keep_run: str = "") -> Sweep:
    """Revoke the certificates of the CI profiles that are left over (classify_profile) or whose
    build no longer needs them (set_fate) and that no profile kept uses, then delete those
    profiles. Certificates go first, and a profile whose certificate could not be revoked stays:
    the sweep finds certificates only through these profiles, so the next run can then try again.
    The app's builds are read only when this repository has signing sets to decide about; without
    them (no app id, a failed listing) every set stays."""
    result = Sweep()
    repo_id = os.environ.get("GITHUB_REPOSITORY_ID") or ""
    repo_id = repo_id if re.fullmatch(r"[0-9]+", repo_id) else ""
    included = []
    profiles = [p for p in client.get_all("/v1/profiles", {"include": "certificates",
                                                           "limit": "200"}, included=included)
                if RESOURCE_ID_RE.fullmatch(str(p.get("id") or ""))]
    now = time.time()
    kinds = {p["id"]: classify_profile(p, repo_id, run_id, keep_run, now) for p in profiles}
    sets = {}                               # build number -> the ids of its profiles
    for profile_id, kind in kinds.items():
        if isinstance(kind, tuple):
            sets.setdefault(kind[1], []).append(profile_id)
            kinds[profile_id] = None        # kept unless set_fate says otherwise
    if sets:
        facts, why = None, ("sin el id de la app en App Store Connect",
                            "without the app's App Store Connect id")
        if app_id:
            try:
                facts = app_builds(client, app_id)
            except ApiError as err:
                why = (err.describe(), err.describe())
        newest = newest_accepted(facts) if facts is not None else None
        for number in sorted(sets, reverse=True):
            if facts is None:
                keep, es, en, known = (True, f"no se pudo leer el estado de la build {number}",
                                       f"the state of build {number} could not be read", False)
            else:
                keep, es, en, known = set_fate(number, facts, newest)
            if keep:
                result.kept.append((es, en))
                if not known:
                    result.unchecked.append(why if facts is None else (es, en))
            else:
                result.retired_why.append((es, en))
                for profile_id in sets[number]:
                    kinds[profile_id] = "retired"
        result.unchecked = _unique(result.unchecked)
    ci = [p for p in profiles if kinds[p["id"]]]
    if not ci:
        return result
    ci_ids = {p["id"] for p in ci}
    in_use = set()          # certificates that the profiles kept still need
    for profile in profiles:
        if profile["id"] not in ci_ids:
            in_use.update(profile_certificate_ids(client, profile))
    links = {p["id"]: [c for c in profile_certificate_ids(client, p) if RESOURCE_ID_RE.fullmatch(c)]
             for p in ci}
    names = {p["id"]: attrs(p).get("name") or p["id"] for p in ci}
    expiry = {str(c.get("id")): _expiry(c) for c in included if c.get("type") == "certificates"}
    unrevoked = set()
    for cert_id in _unique(c for p in ci for c in links[p["id"]]):
        if cert_id in in_use:
            log("A certificate is also in another profile: not revoked")
            continue
        owners = [p for p in ci if cert_id in links[p["id"]]]
        done = (result.retired if any(kinds[p["id"]] == "retired" for p in owners)
                else result.leftovers)
        when = expiry.get(cert_id)
        # The id only in the problem texts, which say how to do it by hand (the portal's list shows
        # the type and the expiry date; the id tells two of a day apart).
        es = f"certificado «Apple Distribution»{f' que caduca el {when}' if when else ''}"
        en = f"«Apple Distribution» certificate{f' expiring {when}' if when else ''}"
        try:
            client.request("DELETE", f"/v1/certificates/{cert_id}")
            done.append((es, en))
        except ApiError as err:
            if err.status != 404:      # 404: already gone
                unrevoked.add(cert_id)
                kept = [f"«{names[p['id']]}»" for p in owners]
                one = len(kept) == 1
                es, en = es + _ids([cert_id]), en + _ids([cert_id])
                result.problems.append((
                    f"{es}: {err.describe()}; se {'conserva su perfil' if one else 'conservan sus perfiles'} "
                    f"{_joined(kept, 'y')} para que la próxima ejecución lo encuentre",
                    f"{en}: {err.describe()}; its {'profile' if one else 'profiles'} "
                    f"{_joined(kept, 'and')} {'is' if one else 'are'} kept so that the next run "
                    "finds it"))
    for profile in ci:
        name = names[profile["id"]]
        if unrevoked.intersection(links[profile["id"]]):
            log(f"Profile «{name}» kept: the next run finds its certificate through it")
            continue
        try:
            client.request("DELETE", f"/v1/profiles/{profile['id']}")
            (result.retired if kinds[profile["id"]] == "retired" else result.leftovers).append(
                (f"perfil «{name}»", f"profile «{name}»"))
        except ApiError as err:
            if err.status != 404:
                result.problems.append((f"perfil «{name}»{_ids([profile['id']])}: {err.describe()}",
                                        f"profile «{name}»{_ids([profile['id']])}: {err.describe()}"))
    return result


KEPT_NOTE_ES = ("Se quedan a propósito: la revisión de TestFlight vuelve a comprobar la firma de una "
                "build, y Apple marca «Invalid Binary» (ITMS-90035) la que firmó un certificado "
                "revocado. Por eso en developer.apple.com puede haber uno o dos certificados «Apple "
                "Distribution» del workflow: no los revoques mientras sus builds estén en revisión o "
                "sean las que vas a enviar. Se revocan solos cuando Apple acepta una build más "
                "reciente y la revisión de la suya ha terminado.")
KEPT_NOTE_EN = ("They stay on purpose: TestFlight beta review checks a build's signature again, and "
                "Apple marks a build signed by a revoked certificate «Invalid Binary» (ITMS-90035). So "
                "developer.apple.com may show one or two «Apple Distribution» certificates of the "
                "workflow: do not revoke them while their builds are in review or are the ones you "
                "will submit. They are revoked by themselves once Apple accepts a newer build and "
                "their own build's review is over.")


def janitor(client: Client = None, run_id: str = "", app_id: str = "", keep_run: str = "") -> Sweep:
    """The sweep, best effort: a problem is a warning, never a failure."""
    try:
        result = sweep(client or Client(load_credentials()), run_id, app_id, keep_run)
    except Exception as exc:  # never fail the caller
        reason = exc.en if isinstance(exc, Failure) else (
            exc.describe() if isinstance(exc, ApiError) else f"{type(exc).__name__}: {exc}")
        result, unnamed = Sweep(), reason
    else:
        unnamed = ""
    if result.leftovers:
        report("notice", "Restos borrados / Leftovers removed",
               "Se borraron restos que una ejecución de TestFlight no había limpiado (perfiles "
               "«OpenCfMoto CI …» y su certificado temporal): "
               f"{', '.join(r[0] for r in result.leftovers)}. No tienes que hacer nada.",
               "Removed what a TestFlight run had not cleaned up (the «OpenCfMoto CI …» profiles "
               f"and their temporary certificate): {', '.join(r[1] for r in result.leftovers)}. "
               "Nothing to do.")
    if result.retired:
        report("notice", "Certificados anteriores revocados / Older certificates revoked",
               "Se revocaron los certificados que el workflow conservaba para builds que ya no los "
               f"necesitan ({'; '.join(w[0] for w in result.retired_why)}) y se borraron sus "
               f"perfiles: {', '.join(r[0] for r in result.retired)}. No tienes que hacer nada.",
               "Revoked the certificates the workflow kept for builds that no longer need them "
               f"({'; '.join(w[1] for w in result.retired_why)}) and deleted their profiles: "
               f"{', '.join(r[1] for r in result.retired)}. Nothing to do.")
    if result.kept:
        es = "; ".join(k[0] for k in result.kept)
        en = "; ".join(k[1] for k in result.kept)
        log(f"Signing sets kept / se quedan: {en}")
        append_summary(f"**Certificados que se quedan / Certificates kept:** {es}. / {en}.\n\n"
                       f"{KEPT_NOTE_ES} / {KEPT_NOTE_EN}")
    if not (result.leftovers or result.retired or result.kept or result.problems or unnamed):
        log("No leftovers from earlier runs / no quedan restos de ejecuciones anteriores")
    if result.problems or unnamed:
        # Not the create-signing manual steps: nothing was created today, and when only the
        # listing failed there may be no leftovers at all. The next run does find whatever is left:
        # a profile stays until its certificate is revoked (sweep).
        es = ("No se pudieron comprobar o borrar todos los restos de ejecuciones de TestFlight "
              f"({'; '.join([p[0] for p in result.problems] + ([unnamed] if unnamed else []))}). "
              "No hace falta hacer nada: la próxima ejecución lo intenta otra vez.")
        en = ("Could not check or remove all leftovers of TestFlight runs "
              f"({'; '.join([p[1] for p in result.problems] + ([unnamed] if unnamed else []))}). "
              "Nothing to do: the next run tries again.")
        if result.problems:
            es += (f" Si prefieres hacerlo a mano: en {URL_PROFILES} borra solo los perfiles que "
                   f"nombra este aviso y en {URL_CERTIFICATES} revoca solo los certificados que "
                   "nombra (ningún otro «Apple Distribution»).")
            en += (f" To do it by hand instead: at {URL_PROFILES} delete only the profiles this "
                   f"warning names and at {URL_CERTIFICATES} revoke only the certificates it names "
                   "(no other «Apple Distribution» one).")
        report("warning", "Limpieza incompleta / Cleanup incomplete", es, en)
    if result.unchecked:
        report("warning", "Certificados sin comprobar / Certificates not checked",
               "No se pudo leer en App Store Connect lo que hace falta para decidir sobre los "
               "certificados que el workflow conserva para sus builds "
               f"({'; '.join(u[0] for u in result.unchecked)}), así que no se revocó ninguno de "
               "ellos: se quedan hasta que una ejecución pueda comprobarlo. No hace falta hacer "
               "nada.",
               "Could not read in App Store Connect what is needed to decide about the "
               "certificates the workflow keeps for its builds "
               f"({'; '.join(u[1] for u in result.unchecked)}), so none of them was revoked: they "
               "stay until a run can check. Nothing to do.")
    return result


def cmd_janitor(args) -> int:
    janitor(run_id=args.run_id or "", app_id=args.app_id or "")
    return EXIT_OK


# ---------------------------------------------------------------- create-signing

def save_state(path: str, state: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)


def profile_plist(data: bytes) -> dict:
    """The plist inside a .mobileprovision: a CMS (PKCS#7) signed blob whose payload is plain
    XML, so it can be read without macOS `security cms -D`."""
    start = data.find(b"<?xml")
    end = data.find(b"</plist>", start + 1) if start >= 0 else -1
    if start < 0 or end < 0:
        raise ValueError("no XML plist inside the profile")
    try:
        result = plistlib.loads(data[start:end + len(b"</plist>")])
    except Exception as exc:  # plistlib raises several types for malformed input
        raise ValueError(f"unreadable plist: {exc}") from None
    if not isinstance(result, dict):
        raise ValueError("the profile plist is not a dictionary")
    return result


def team_from_subject(subject: str) -> str:
    """OU of `openssl x509 -subject`: OpenSSL 3 prints "subject=UID = X, CN = ..., OU = TEAM, ..."
    and LibreSSL "subject= /UID=X/CN=.../OU=TEAM/...". Apple puts the team ID in OU."""
    match = re.search(r"(?:^|[/,\s])OU\s*=\s*([A-Za-z0-9]+)", subject)
    return match.group(1) if match else ""


def kept_certificates(client: Client) -> list:
    """Best effort, for the certificate-limit message: [(build, certificate expiry date)] of this
    repository's signing sets (the certificates the workflow keeps on purpose), newest build
    first; [] when there is none or the listing fails."""
    repo_id = os.environ.get("GITHUB_REPOSITORY_ID") or ""
    repo_id = repo_id if re.fullmatch(r"[0-9]+", repo_id) else ""
    included, found = [], {}
    try:
        profiles = client.get_all("/v1/profiles", {"include": "certificates", "limit": "200"},
                                  included=included)
    except (ApiError, Failure) as exc:
        log(f"(could not list the profiles for the certificate-limit message: {exc})")
        return []
    expiry = {str(c.get("id")): _expiry(c) for c in included if c.get("type") == "certificates"}
    for profile in profiles:
        kind = classify_profile(profile, repo_id)
        if isinstance(kind, tuple):
            data = ((profile.get("relationships") or {}).get("certificates") or {}).get("data")
            ids = [str(d.get("id")) for d in data or [] if isinstance(d, dict)]
            if not found.get(kind[1]):
                found[kind[1]] = next((expiry[c] for c in ids if expiry.get(c)), "")
    return sorted(found.items(), reverse=True)


def cert_limit_failure(err: ApiError, kept=()) -> Failure:
    """`kept`: kept_certificates(), named so that the owner leaves them alone."""
    now_es = "; ".join(f"la build {b}" + (f", certificado que caduca el {d}" if d else "")
                       for b, d in kept)
    now_en = "; ".join(f"build {b}" + (f", certificate expiring {d}" if d else "") for b, d in kept)
    return Failure(
        "Límite de certificados / Certificate limit",
        "Apple no deja crear otro certificado de distribución: el equipo ya tiene el máximo de "
        "certificados «Apple Distribution». Este workflow conserva a propósito el certificado de "
        "la última build que Apple aceptó (y el de una build en la revisión de TestFlight, si la "
        "hay), que usan sus perfiles «OpenCfMoto CI … bN app» y «… bN mirror» (N: el número de "
        "esa build)"
        f"{f' (ahora: {now_es})' if now_es else ''}: no lo revoques mientras esa build esté en "
        "revisión o sea la que vas a enviar a las pruebas externas, porque Apple la marcaría "
        f"«Invalid Binary» (ITMS-90035). Entra en {URL_CERTIFICATES}, revoca otros «Apple "
        "Distribution» que no uses (por ejemplo los que dejó un workflow interrumpido: los crea la "
        "clave de la API); si todos son del workflow, el de la build más antigua (esa build ya no "
        f"podrá enviarse a revisión). Después {NEW_RUN_ES}. Si otro workflow TestFlight está en "
        "marcha, espera a que termine: al final revoca su certificado, salvo el de una build que "
        f"Apple acepte. Detalle: {err.describe()}",
        "Apple will not create another distribution certificate: the team already has the "
        "maximum number of «Apple Distribution» certificates. This workflow keeps on purpose the "
        "certificate of the latest build Apple accepted (and the one of a build in TestFlight beta "
        "review, if any), which its profiles «OpenCfMoto CI … bN app» and «… bN mirror» (N: that "
        "build's number) use"
        f"{f' (now: {now_en})' if now_en else ''}: do not revoke it while that build is in review "
        "or is the one you will send to external testing, as Apple would mark it «Invalid Binary» "
        f"(ITMS-90035). Open {URL_CERTIFICATES}, revoke other «Apple Distribution» certificates "
        "you do not use (e.g. ones left by an interrupted workflow: the API key creates them); if "
        "all of them are the workflow's, the one of the oldest build (that build can then no "
        f"longer be submitted for review). Then {NEW_RUN_EN}. If another TestFlight workflow is "
        "running, wait for it to finish: at the end it revokes its certificate, unless Apple "
        f"accepts its build. Detail: {err.describe()}")


def is_cert_limit(err: ApiError) -> bool:
    """A full team: 409, or a 422 that says so (an invalid CSR is a 422 too)."""
    text = err.text()
    return err.status == 409 or (err.status == 422 and any(
        word in text for word in ("already have", "maximum", "pending certificate", "limit")))


def certificate_refused(err: ApiError, client: Client = None) -> Failure:
    if is_cert_limit(err):
        return cert_limit_failure(err, kept_certificates(client) if client is not None else ())
    return explain(err, "Crear el certificado de distribución", "Creating the distribution certificate")


def lost_certificate_failure(err: ApiError, cause=None) -> Failure:
    """Apple may have made a certificate this run cannot confirm: listing the certificates failed
    (`cause`), or Apple said it made one (a success whose answer was unreadable) that the list
    does not show yet. cert_pending stays set: the «Clean up» step looks again and revokes it."""
    if cause is not None:
        why = cause.en if isinstance(cause, Failure) else (
            cause.describe() if isinstance(cause, ApiError) else str(cause))
        es = (f"Apple no respondió con claridad al crear el certificado de distribución "
              f"({err.describe()}) y no se pudo comprobar si llegó a crearlo ({why}).")
        en = (f"Apple gave no clear answer when creating the distribution certificate "
              f"({err.describe()}) and it could not be checked whether it was created ({why}).")
    else:
        es = (f"Apple dijo que creó el certificado de distribución, pero su respuesta no se pudo "
              f"leer ({err.describe()}) y su lista de certificados aún no lo muestra.")
        en = (f"Apple said it created the distribution certificate, but its answer could not be "
              f"read ({err.describe()}) and its certificate list does not show it yet.")
    return Failure(
        "Certificado sin confirmar / Certificate not confirmed",
        f"{es} El paso «Clean up» de este trabajo lo busca otra vez con la clave de esta ejecución "
        "y lo revoca. Solo si allí aparece el aviso «Certificado sin confirmar», o si ese paso no "
        f"llega a ejecutarse, revócalo a mano: en {URL_CERTIFICATES}, el certificado «Apple "
        f"Distribution» creado hoy, púlsalo ▸ Revoke. Después {NEW_RUN_ES}.",
        f"{en} The «Clean up» step of this job looks for it again with this run's key and revokes "
        "it. Only if that step shows the «Certificado sin confirmar» warning, or does not run at "
        f"all, revoke it by hand: at {URL_CERTIFICATES}, the «Apple Distribution» certificate "
        f"created today, click it ▸ Revoke. Then {NEW_RUN_EN}.")


def _pem_public_key(text: bytes) -> bytes:
    """The DER of the first PUBLIC KEY block in openssl's output, b"" if there is none."""
    match = re.search(rb"-----BEGIN PUBLIC KEY-----(.*?)-----END PUBLIC KEY-----", text or b"", re.S)
    if not match:
        return b""
    try:
        return base64.b64decode(re.sub(rb"\s+", b"", match.group(1)), validate=True)
    except (binascii.Error, ValueError):
        return b""


def public_key_of(path: str) -> bytes:
    """The public key (DER) of this run's private key or CSR. Same flags in OpenSSL 3 and LibreSSL."""
    with open(path, "rb") as fh:
        is_csr = b"CERTIFICATE REQUEST" in fh.read(256)
    args = ["req", "-in", path, "-noout", "-pubkey"] if is_csr else ["pkey", "-in", path, "-pubout"]
    key = _pem_public_key(run_openssl(args).stdout)
    if not key:
        name = os.path.basename(path)
        raise Failure("Clave ilegible / Unreadable key",
                      f"openssl no dio la clave pública de {name}.",
                      f"openssl gave no public key for {name}.")
    return key


def my_certificates(client: Client, key_file: str) -> list:
    """The team's distribution certificates made from this run's key. The key is new for every
    run, so only certificates this run asked for can match."""
    mine, found = public_key_of(key_file), []
    for cert in client.get_all("/v1/certificates", {"filter[certificateType]": "DISTRIBUTION",
                                                    "limit": "200"}):
        cert_id = str(cert.get("id") or "")
        if not RESOURCE_ID_RE.fullmatch(cert_id):
            continue
        if not attrs(cert).get("certificateContent"):
            cert = client.request("GET", f"/v1/certificates/{cert_id}").get("data") or {}
        try:
            der = base64.b64decode(attrs(cert).get("certificateContent") or "")
        except (binascii.Error, ValueError):
            continue
        proc = run_openssl(["x509", "-inform", "der", "-noout", "-pubkey"], data=der, check=False)
        if der and proc.returncode == 0 and _pem_public_key(proc.stdout) == mine:
            found.append(cert)
    return found


def adopt_certificate(client: Client, mine: list, chosen: dict = None) -> dict:
    """Keep one certificate made from this run's key and revoke any other (a lost answer plus a
    second request can make two). state.json says a request was unclear (cert_unclear), so the
    «Clean up» step looks for duplicates again; a revocation that fails here warns all the same:
    if that step never runs (a lost runner), nothing else finds a certificate that is in no
    profile. The warning never points at the kept certificate, which the build still needs."""
    chosen = chosen or mine[0]
    for extra in mine:
        if extra.get("id") == chosen.get("id"):
            continue
        try:
            client.request("DELETE", f"/v1/certificates/{extra['id']}")
            log("Revoked a duplicate certificate of this run")
        except ApiError as err:
            if err.status != 404:
                report("warning", "Limpieza incompleta / Cleanup incomplete",
                       f"No se pudo revocar un certificado duplicado de esta ejecución "
                       f"({err.describe()}). El paso «Clean up» lo intenta otra vez. Solo si ese "
                       f"paso no llega a ejecutarse, o avisa: {AFTER_FINISH_ES}",
                       f"Could not revoke a duplicate certificate of this run ({err.describe()}). "
                       "The «Clean up» step tries again. Only if that step does not run, or warns: "
                       f"{AFTER_FINISH_EN}")
    return chosen


def request_certificate(client: Client, csr: str, key_path: str, state: dict,
                        state_path: str) -> dict:
    """POST /v1/certificates, never repeated blindly: Apple may have created a certificate whose
    answer was lost, and a second one would take another of the team's few slots. After an
    unclear answer, look for a certificate made from this run's key before asking again."""
    body = {"data": {"type": "certificates",
                     "attributes": {"csrContent": csr, "certificateType": "DISTRIBUTION"}}}
    # While cert_pending is set, cleanup looks for (and waits a while for) this run's certificates.
    # cert_unclear stays once a request got no clear answer: even after this run settled on one
    # certificate, that request may have made another, which the teardown then looks for.
    state["cert_pending"] = True
    save_state(state_path, state)

    def settled(cert):
        state.pop("cert_pending", None)
        if cert is not None:
            state["cert_id"] = cert["id"]
        save_state(state_path, state)
        return cert

    def look(unclear: ApiError) -> list:
        try:
            return my_certificates(client, key_path)
        except (ApiError, Failure) as exc:
            raise lost_certificate_failure(unclear, exc) from None

    unclear = []                    # the requests that got no clear answer
    for _ in range(2):
        try:
            cert = client.request("POST", "/v1/certificates", body)["data"]
        except ApiError as err:
            if err.ambiguous:
                unclear.append(err)
                state["cert_unclear"] = True
                save_state(state_path, state)
                log(f"  no clear answer ({err.describe()}): looking for a certificate made from "
                    "this run's key")
                pause(RECHECK_SEC)
                mine = look(err)
                if mine:
                    return settled(adopt_certificate(client, mine))
                continue            # nothing was created: ask once more
            if unclear:
                # Refused after an unanswered request, which may have made the certificate that
                # now fills the team's limit.
                mine = look(unclear[-1])
                if mine:
                    return settled(adopt_certificate(client, mine))
            settled(None)
            raise certificate_refused(err, client) from None
        if not unclear:
            return settled(cert)
        # Created on the second try: the unanswered first request may have made one too. This
        # one is recorded at once (cert_pending stays set), so a stop during the listings below
        # (they can take minutes while Apple's API fails) loses nothing. A listing counts only
        # once it shows the certificate just created (the list can lag).
        state["cert_id"] = cert["id"]
        save_state(state_path, state)
        for attempt in range(4):
            try:
                mine = my_certificates(client, key_path)
            except (ApiError, Failure) as exc:
                log(f"  (could not look for a second certificate: {exc})")
                mine = None
            if mine is not None and any(c.get("id") == cert["id"] for c in mine):
                return settled(adopt_certificate(client, mine, cert))
            if attempt < 3:
                pause(RECHECK_SEC)
        log("  (no listing showed the new certificate yet: the «Clean up» step looks for a second "
            "one)")
        return cert                         # cert_pending stays set: the teardown looks again
    lost = next((err for err in unclear if 200 <= err.status < 300), None)
    if lost is not None:            # Apple said it made one (its answer could not be read)
        raise lost_certificate_failure(lost)
    # Two requests without an answer, and two listings that worked showed no certificate made from
    # this run's key: an outage, not a lost certificate. cert_pending stays set, so the «Clean up»
    # step looks once more (and waits a while) and revokes one that shows up late.
    failure = explain(unclear[-1], "Crear el certificado de distribución",
                      "Creating the distribution certificate")
    failure.es += (". Se buscó dos veces un certificado hecho con la clave de esta ejecución y no "
                   "apareció ninguno; el paso «Clean up» de este trabajo lo busca otra vez y lo "
                   "revoca si aparece. No hace falta revocar nada a mano.")
    failure.en += (". A certificate made from this run's key was looked for twice and none showed "
                   "up; the «Clean up» step of this job looks again and revokes it if it appears. "
                   "Nothing to revoke by hand.")
    raise failure


def profile_failure(err: ApiError, name: str) -> Failure:
    if err.status == 409:
        return Failure(
            "No se pudo crear el perfil / Profile not created",
            f"Apple no aceptó el perfil «{name}» (HTTP 409). Si ya existe uno con ese nombre, "
            f"bórralo en {URL_PROFILES} y después {NEW_RUN_ES}. Detalle: {err.describe()}",
            f"Apple refused the profile «{name}» (HTTP 409). If one with that name already "
            f"exists, remove it at {URL_PROFILES}, then {NEW_RUN_EN}. Detail: {err.describe()}")
    failure = explain(err, f"Crear el perfil «{name}»", f"Creating the profile «{name}»")
    if err.ambiguous:
        failure.es += " Si Apple llegó a crear el perfil, la próxima ejecución lo borra sola."
        failure.en += " If Apple did create the profile, the next run removes it by itself."
    return failure


def find_profile(client: Client, name: str):
    # Exact comparison here: filter[name] semantics (exact, prefix, substring) do not matter.
    for profile in client.get_all("/v1/profiles", {"filter[name]": name, "limit": "200"}):
        if attrs(profile).get("name") == name and RESOURCE_ID_RE.fullmatch(str(profile.get("id"))):
            return profile
    return None


def request_profile(client: Client, body: dict, name: str) -> dict:
    """POST /v1/profiles, not repeated blindly either: after an unclear answer the profile is
    looked up by its name, which is unique per run."""
    unclear = None
    for _ in range(2):
        try:
            return client.request("POST", "/v1/profiles", body)["data"]
        except ApiError as err:
            if not err.ambiguous and (unclear is None or err.status != 409):
                raise profile_failure(err, name) from None
            if err.ambiguous:
                unclear = err
                pause(RECHECK_SEC)
            log(f"  «{name}»: {err.describe()}; looking the profile up by name")
            try:
                found = find_profile(client, name)
            except ApiError:
                raise profile_failure(unclear, name) from None
            if found:
                return found
            if not err.ambiguous:   # 409 after an unanswered request, and still not visible
                raise profile_failure(err, name) from None
    raise profile_failure(unclear, name)


def default_suffix() -> str:
    """The profile name suffix, as build_and_sign.sh makes it: r<repository id>-<run id>-<attempt>
    on GitHub (the janitor knows this repository's profiles by it), local<date and time>-1 on a
    Mac. Every name it gives matches CI_PROFILE_RE."""
    run = os.environ.get("GITHUB_RUN_ID") or ""
    run = run if re.fullmatch(r"[0-9]+", run) else time.strftime("local%Y%m%d%H%M%S")
    attempt = os.environ.get("GITHUB_RUN_ATTEMPT") or ""
    suffix = f"{run}-{attempt if re.fullmatch(r'[0-9]+', attempt) else 1}"
    repo = os.environ.get("GITHUB_REPOSITORY_ID") or ""
    return f"r{repo}-{suffix}" if re.fullmatch(r"[0-9]+", repo) else suffix


def clean_suffix(text: str) -> str:
    """A profile name suffix as it ends up in the names: letters, digits and hyphens only."""
    return re.sub(r"[^A-Za-z0-9-]+", "-", text).strip("-") or "run"


def cmd_create_signing(args) -> int:
    out = os.path.abspath(args.out)
    profiles_dir = os.path.join(out, "profiles")
    os.makedirs(profiles_dir, exist_ok=True)
    os.chmod(out, 0o700)
    state_path = os.path.join(out, "state.json")
    state = {"cert_id": None, "profile_ids": []}
    save_state(state_path, state)
    suffix = clean_suffix(args.suffix or default_suffix())
    build = build_tag(args.build)   # in the profile names: the janitor knows each set's build
    client = Client(load_credentials())

    # 1. Private key + CSR. The key stays here; Apple only sees the CSR. The key file is created
    #    0600 before openssl writes into it (LibreSSL would otherwise follow the umask).
    key_path, csr_path = os.path.join(out, "key.pem"), os.path.join(out, "csr.pem")
    for path in (key_path, csr_path):
        remove_if_present(path)
    write_private_file(key_path, b"")
    log("Creating a private key and a certificate signing request (openssl)")
    run_openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key_path,
                 "-out", csr_path, "-subj", "/CN=OpenCfMoto CI/O=OpenCfMoto/C=US"])
    with open(csr_path, encoding="ascii") as fh:
        csr = fh.read()

    # 2. Distribution certificate, recorded at once so cleanup can revoke it whatever happens.
    log("Requesting an Apple Distribution certificate")
    cert = request_certificate(client, csr, key_path, state, state_path)
    cert_id = cert["id"]
    state["cert_id"] = cert_id
    save_state(state_path, state)
    set_output("cert_id", cert_id)

    try:
        der = base64.b64decode(attrs(cert).get("certificateContent") or "")
    except (binascii.Error, ValueError):
        der = b""
    if not der:
        raise Failure("Certificado vacío / Empty certificate",
                      "Apple no devolvió el contenido del certificado.",
                      "Apple returned no certificate content.")
    cer_path, pem_path = os.path.join(out, "cert.cer"), os.path.join(out, "cert.pem")
    for path in (cer_path, pem_path):
        remove_if_present(path)
    write_file(cer_path, der)
    run_openssl(["x509", "-inform", "der", "-in", cer_path, "-out", pem_path])
    subject = run_openssl(["x509", "-noout", "-subject", "-in", pem_path]).stdout
    team = team_from_subject(subject.decode("utf-8", "replace"))
    if team:
        set_output("cert_team_id", team)

    # 3. App Store profiles, each recorded as soon as it exists.
    created = []
    for role, resource_id, bundle_id in (
            ("app", args.app_bundle_resource_id, args.app_bundle_id),
            ("mirror", args.mirror_bundle_resource_id, args.mirror_bundle_id)):
        name = profile_name(suffix, build, role)   # with default_suffix(): CI_PROFILE_RE
        log(f"Creating the App Store provisioning profile «{name}» for {bundle_id}")
        body = {"data": {"type": "profiles",
                         "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                         "relationships": {
                             "bundleId": {"data": {"type": "bundleIds", "id": resource_id}},
                             "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}}
        profile = request_profile(client, body, name)
        state["profile_ids"].append(profile["id"])
        save_state(state_path, state)
        set_output(f"profile_{role}_id", profile["id"])
        set_output("profile_ids", ",".join(state["profile_ids"]))
        meta = attrs(profile)
        try:
            content = base64.b64decode(meta.get("profileContent") or "")
            plist = profile_plist(content)
        except (binascii.Error, ValueError) as exc:
            raise Failure("Perfil ilegible / Unreadable profile",
                          f"No se pudo leer el perfil «{name}» que devolvió Apple ({exc}).",
                          f"Could not read the profile «{name}» returned by Apple ({exc}).") from None
        uuid = str(meta.get("uuid") or plist.get("UUID") or "")
        if not UUID_RE.fullmatch(uuid):
            raise Failure("Perfil sin UUID / Profile without UUID",
                          f"El perfil «{name}» no trae un UUID válido.",
                          f"The profile «{name}» has no valid UUID.")
        write_file(os.path.join(profiles_dir, f"{uuid}.mobileprovision"), content)
        set_output(f"profile_{role}_name", meta.get("name") or name)
        set_output(f"profile_{role}_uuid", uuid)
        created.append((role, bundle_id, meta.get("name") or name, uuid, plist))

    profile_teams = [str((plist.get("TeamIdentifier") or [""])[0]) for *_, plist in created]
    if not team:
        log("(team ID not found in the certificate subject; using the profile's TeamIdentifier)")
        team = next((t for t in profile_teams if t), "")
        if not team:
            raise Failure("Sin Team ID / No team ID",
                          "No se encontró el Team ID ni en el certificado ni en los perfiles.",
                          "No team ID found in the certificate or in the profiles.")
        set_output("cert_team_id", team)
    elif any(t and t != team for t in profile_teams):
        report("warning", "Team ID distinto / Team ID mismatch",
               "El certificado y uno de los perfiles indican equipos distintos (los Team ID no se "
               "muestran: el registro es público).",
               "The certificate and one of the profiles name different teams (team IDs are not "
               "shown: the log is public).")

    # 4. The entitlements Apple put in the profiles. App Groups cannot be created or assigned to
    #    an App ID through the API, so a missing group is the owner's one-time web step.
    rows, missing_group, missing_other = [], [], []
    for role, bundle_id, name, _uuid, plist in created:   # the UUID stays out of the summary
        ents = plist.get("Entitlements") or {}
        groups = ents.get(ENT_APP_GROUPS) or []
        groups = [groups] if isinstance(groups, str) else list(groups)
        has_group = args.app_group in groups
        if not has_group:
            missing_group.append(bundle_id)
        flags = [f"App Group: {'sí / yes' if has_group else 'NO'}"]
        if role == "app":
            for key, label in ((ENT_HOTSPOT, "Hotspot"), (ENT_WIFI_INFO, "Wi-Fi info")):
                present = bool(ents.get(key))
                flags.append(f"{label}: {'sí / yes' if present else 'NO'}")
                if not present:
                    missing_other.append(f"`{bundle_id}`: {key}")
        rows.append((f"Perfil / profile ({role})", f"{name} — {', '.join(flags)}"))

    summary = "### TestFlight · firma / signing\n\n" + md_table(
        [("Certificado / certificate", "Apple Distribution (temporal, de esta ejecución / temporary, this run's)")]
        + rows)
    if missing_group or missing_other:
        es_parts, en_parts = [], []
        if missing_group:
            listed = ", ".join(f"`{b}`" for b in missing_group)
            steps_es, steps_en = app_group_steps(args.app_bundle_id, args.mirror_bundle_id,
                                                 args.app_group)
            es_parts.append(f"Los perfiles que Apple acaba de generar no incluyen el App Group "
                            f"`{args.app_group}` en {listed}. Apple no permite crear ni asignar "
                            f"App Groups con la API; hazlo una vez en la web:\n\n{steps_es}")
            en_parts.append(f"The profiles Apple just generated do not include the App Group "
                            f"`{args.app_group}` for {listed}. Apple's API cannot create or assign "
                            f"App Groups; do it once on the web:\n\n{steps_en}")
        if missing_other:
            listed = "; ".join(missing_other)
            es_parts.append(f"Faltan capacidades en el perfil de la app ({listed}). Una ejecución "
                            "nueva las activa (el trabajo «Prepare (App Store Connect)» activa "
                            "Hotspot y Access Wi-Fi Information); también puedes activarlas en "
                            f"{URL_IDENTIFIERS} ▸ `{args.app_bundle_id}`.")
            en_parts.append(f"Capabilities are missing in the app profile ({listed}). A new run "
                            "enables them (the «Prepare (App Store Connect)» job enables Hotspot "
                            f"and Access Wi-Fi Information); you can also enable them at "
                            f"{URL_IDENTIFIERS} ▸ `{args.app_bundle_id}`.")
        es_parts.append("Los perfiles se generan de nuevo en cada ejecución. " + RUN_AGAIN_ES)
        en_parts.append("The profiles are generated again on every run. " + RUN_AGAIN_EN)
        append_summary(summary)
        title = ("Falta el App Group en los perfiles / App Group missing from the profiles"
                 if missing_group else "Faltan capacidades / Capabilities missing")
        raise Failure(title, "\n\n".join(es_parts), "\n\n".join(en_parts),
                      code=EXIT_APP_GROUP if missing_group else EXIT_FAILED)
    append_summary(summary + "\n\nSi Apple acepta la build, el certificado y los perfiles se quedan "
                   "hasta que acepte una build más reciente (la revisión de TestFlight vuelve a "
                   "comprobar la firma); si no, se revocan y borran al final del workflow. / If Apple "
                   "accepts the build, the certificate and profiles stay until it accepts a newer "
                   "build (TestFlight beta review checks the signature again); otherwise they are "
                   "revoked and deleted at the end of the workflow.")
    return EXIT_OK


# ---------------------------------------------------------------- upload

def md5_of(path: str) -> str:
    digest = hashlib.md5()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _connection(parts, timeout: float, context: ssl.SSLContext):
    host = parts.hostname
    port = parts.port or (443 if parts.scheme == "https" else 80)
    if parts.scheme != "https":
        return http.client.HTTPConnection(host, port, timeout=timeout)
    proxy_url = urllib.request.getproxies().get("https")
    if proxy_url and not urllib.request.proxy_bypass(host):
        proxy = urllib.parse.urlsplit(proxy_url if "://" in proxy_url else f"http://{proxy_url}")
        conn = http.client.HTTPSConnection(proxy.hostname, proxy.port or 8080, timeout=timeout,
                                           context=context)
        headers = {}
        if proxy.username:
            user = f"{urllib.parse.unquote(proxy.username)}:{urllib.parse.unquote(proxy.password or '')}"
            headers["Proxy-Authorization"] = "Basic " + base64.b64encode(user.encode()).decode()
        conn.set_tunnel(host, port, headers=headers)
        return conn
    return http.client.HTTPSConnection(host, port, timeout=timeout, context=context)


def send_upload_operation(path: str, op: dict, index: int, total: int,
                          context: ssl.SSLContext) -> str:
    """Send bytes [offset, offset+length) of the file exactly as Apple asked (method, URL,
    headers; no Authorization: the URL is pre-signed). Returns "" on success, else the problem.
    http.client rather than urllib: urllib would add a form Content-Type of its own.
    The URL is a write credential (its query holds the signature): no message ever quotes it,
    only its host."""
    method = str(op.get("method") or "PUT").upper()
    parts = urllib.parse.urlsplit(str(op.get("url") or ""))
    unusable = f"part {index}/{total}: unusable upload operation from Apple"
    try:
        offset, length = int(op.get("offset") or 0), int(op.get("length") or 0)
        parts.port      # a port that is not a number raises ValueError here, not later
    except (TypeError, ValueError):
        return unusable
    headers = {}
    for header in op.get("requestHeaders") or []:
        if isinstance(header, dict) and header.get("name"):
            headers[str(header["name"])] = str(header.get("value") or "")
    if parts.scheme not in ("https", "http") or not parts.hostname or length <= 0 or offset < 0:
        return unusable
    target = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
    if any(not text.isascii() or re.search(r"[\x00-\x20\x7f]", text)
           for text in (parts.hostname, target)):
        # http.client would refuse it with an InvalidURL that quotes the whole pre-signed URL.
        return f"part {index}/{total}: unusable upload URL from Apple"
    with open(path, "rb") as fh:
        fh.seek(offset)
        chunk = fh.read(length)
    if len(chunk) != length:
        return f"part {index}/{total}: the file has no bytes {offset}..{offset + length}"
    last = ""
    for attempt in range(UPLOAD_OP_RETRIES + 1):
        if attempt:
            delay = min(60.0, 5.0 * 2 ** (attempt - 1))
            log(f"    retry {attempt}/{UPLOAD_OP_RETRIES} in {delay:g} s")
            pause(delay)
        conn = _connection(parts, UPLOAD_TIMEOUT, context)
        try:
            conn.request(method, target, body=chunk, headers=headers)
            response = conn.getresponse()
            response.read()
            status = response.status
        except http.client.InvalidURL:  # an HTTPException that quotes the whole URL: never printed
            return unusable
        except (OSError, http.client.HTTPException) as exc:
            # Also ssl.SSLCertVerificationError (an OSError and a ValueError): it names the host only.
            last = f"{type(exc).__name__}: {exc}"
            log(f"  upload part {index}/{total} ({length} bytes at {offset}): {last}")
            continue
        except ValueError:              # a header name or value http.client refuses (it quotes it)
            return unusable
        finally:
            conn.close()
        # The URL is a temporary write credential: log the host only, never the URL.
        log(f"  upload part {index}/{total} ({length} bytes at {offset}) to {parts.hostname} "
            f"-> HTTP {status}")
        if 200 <= status < 300:
            return ""
        last = f"HTTP {status}"
    return (f"part {index}/{total} ({length} bytes at offset {offset}) still failing after "
            f"{UPLOAD_OP_RETRIES} retries: {last}")


def _state_detail(item) -> str:
    if not isinstance(item, dict):
        return str(item)
    code, description = item.get("code") or "", item.get("description") or ""
    return f"{code}: {description}" if code and description else str(code or description)


def upload_refused(client: Client, upload_id: str, reason: str, err: ApiError = None,
                   marker: str = "") -> int:
    """Exit 3: nothing was committed (or the upload is given up), so the workflow can retry with
    `xcrun altool`. The dangling build upload is deleted first."""
    if marker:
        remove_if_present(marker)       # nothing left for the finish job to wait for
    if upload_id:
        try:
            client.request("DELETE", f"/v1/buildUploads/{upload_id}")
            log("Deleted the unfinished build upload")
        except (ApiError, Failure) as exc:
            log(f"(could not delete the unfinished build upload: {exc})")
    es = (f"La API de subida de builds de Apple rechazó la subida antes de completarla: {reason}. "
          "El workflow lo intenta ahora con «xcrun altool».")
    en = (f"Apple's Build Upload API refused the upload before it was committed: {reason}. The "
          "workflow now tries «xcrun altool» instead.")
    if err is not None and err.status in (401, 403):
        why = explain(err)
        es, en = f"{es}\n\n{why.es}", f"{en}\n\n{why.en}"
    report("warning", "Build Upload API: se usará altool / falling back to altool", es, en)
    set_output("uploaded", "false")
    return EXIT_UPLOAD_REFUSED


def is_duplicate_build(err: ApiError) -> bool:
    """Apple already has this build number: 409 ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE on
    /data/attributes/cfBundleVersion. altool would be refused the same way."""
    if err.status != 409:
        return False
    codes = [str(e.get("code") or "") for e in err.errors]
    return (any(c.startswith("ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE") for c in codes)
            or "/data/attributes/cfBundleVersion" in err.pointers()
            or "previously uploaded" in err.text())


def duplicate_build_failure(build: str, detail: str) -> Failure:
    return Failure(
        "La build ya existe / Build already exists",
        f"App Store Connect ya tiene una build con el número {build} (de una ejecución anterior) y "
        f"no acepta otra igual. No tienes que cambiar nada: {NEW_RUN_ES}; cada ejecución nueva "
        f"elige un número libre. Detalle: {detail}",
        f"App Store Connect already has a build numbered {build} (from an earlier run) and will "
        f"not take another one. Nothing to change: {NEW_RUN_EN}; every new run picks a free "
        f"number. Detail: {detail}")


def upload_rejected(build: str, errors: list) -> Failure:
    """Apple refused the uploaded file (state FAILED): no build will appear. Each of Apple's
    errors gets its own ::error annotation as well."""
    for item in errors:
        annotate("error", "App Store Connect", _state_detail(item))
    listing = "; ".join(_state_detail(e) for e in errors) or "sin detalles / no details"
    if any(re.search(r"\b90189\b", _state_detail(e)) for e in errors):   # redundant binary
        return duplicate_build_failure(build, listing)
    return Failure("Apple rechazó la subida / Apple rejected the upload",
                   f"App Store Connect marcó la subida de la build {build} como FAILED: {listing}. "
                   f"No aparecerá en TestFlight. Corrige lo indicado y después {NEW_RUN_ES}.",
                   f"App Store Connect marked the upload of build {build} as FAILED: {listing}. "
                   f"It will not appear in TestFlight. Fix what it reports, then {NEW_RUN_EN}.")


def upload_state(upload) -> str:
    return str((attrs(upload).get("state") or {}).get("state") or "")


def create_marker(marker: str) -> None:
    """While the marker exists, Apple has (or may have) the whole file: a build may appear even if
    this step is stopped now, so teardown keeps the certificate for the finish job."""
    if marker:
        try:
            with open(marker, "w", encoding="utf-8"):
                pass
        except OSError as exc:
            log(f"(could not create {marker}: {exc.strerror})")


def mark_committed(marker: str) -> None:
    """Apple confirmed the commit (or showed the file as received after an unclear answer)."""
    set_output("committed", "true")
    create_marker(marker)


def commit_went_through(client: Client, upload_id: str, file_id: str) -> bool:
    """After a commit PATCH with no clear answer (timeout, 5xx): did Apple take the file? Just
    after a commit a read can still say AWAITING_UPLOAD, so keep looking for a while. The file and
    the upload are read separately (one failing read must not hide the other), and the answer is
    "no" only on evidence: a FAILED file, or AWAITING_UPLOAD in every read of the last round.
    Nothing readable is no evidence: never delete what Apple may have committed (wait_for_upload
    gives up later if Apple then still says AWAITING_UPLOAD)."""
    deadline = deadline_after(COMMIT_CHECK_MIN)
    while True:
        seen = []           # this round's answers: True = still AWAITING_UPLOAD
        delivery = state = ""
        try:
            doc = read_uploads(client, f"/v1/buildUploadFiles/{file_id}")
            delivery = str((attrs(doc.get("data")).get("assetDeliveryState") or {}).get("state")
                           or "")
            if delivery in ("UPLOAD_COMPLETE", "COMPLETE"):
                return True
            if delivery == "FAILED":
                return False
            seen.append(delivery == "AWAITING_UPLOAD")
        except ApiError as err:
            log(f"  (file check failed: {err.describe()})")
        try:
            state = upload_state(read_uploads(client, f"/v1/buildUploads/{upload_id}").get("data"))
            if state in ("PROCESSING", "COMPLETE", "FAILED"):
                return True
            seen.append(state == "AWAITING_UPLOAD")
        except ApiError as err:
            log(f"  (upload check failed: {err.describe()})")
        log(f"  file {delivery or '?'}, upload {state or '?'}")
        if time.monotonic() >= deadline:
            if not seen:
                log("  (no readable answer: treated as received, so nothing is deleted)")
            return not (seen and all(seen))
        pause(UPLOAD_POLL_SEC)


def cmd_upload(args) -> int:
    for label, value in (("--version", args.version), ("--build", args.build)):
        if not VERSION_RE.fullmatch(value):
            raise Failure("Versión no válida / Invalid version",
                          f"{label} «{value}» debe ser como 1, 1.2 o 1.2.3.",
                          f"{label} «{value}» must look like 1, 1.2 or 1.2.3.", code=EXIT_USAGE)
    ipa = os.path.abspath(args.ipa)
    if not os.path.isfile(ipa) or os.path.getsize(ipa) == 0:
        raise Failure("No hay .ipa / No .ipa",
                      f"No existe el archivo {ipa} (o está vacío): la exportación no produjo la .ipa.",
                      f"{ipa} does not exist (or is empty): the export produced no .ipa.")
    marker = os.path.abspath(args.committed_marker) if args.committed_marker else ""
    if marker:
        remove_if_present(marker)       # only this upload's commit may create it
    size, digest, file_name = os.path.getsize(ipa), md5_of(ipa), os.path.basename(ipa)
    log(f"Uploading {file_name}: {size} bytes, MD5 {digest}, version {args.version} "
        f"build {args.build}")
    client = Client(load_credentials())

    body = {"data": {"type": "buildUploads",
                     "attributes": {"cfBundleShortVersionString": args.version,
                                    "cfBundleVersion": args.build, "platform": "IOS"},
                     "relationships": {"app": {"data": {"type": "apps", "id": args.app_id}}}}}
    try:
        upload = client.request("POST", "/v1/buildUploads", body)["data"]
    except ApiError as err:
        if is_duplicate_build(err):
            set_output("uploaded", "false")
            raise duplicate_build_failure(args.build, err.describe()) from None
        return upload_refused(client, "", err.describe(), err)
    upload_id = upload["id"]
    set_output("upload_id", upload_id)

    body = {"data": {"type": "buildUploadFiles",
                     "attributes": {"assetType": "ASSET", "fileName": file_name, "fileSize": size,
                                    "uti": "com.apple.ipa"},
                     "relationships": {"buildUpload": {"data": {"type": "buildUploads",
                                                                "id": upload_id}}}}}
    try:
        upload_file = client.request("POST", "/v1/buildUploadFiles", body)["data"]
    except ApiError as err:
        return upload_refused(client, upload_id, err.describe(), err)
    operations = [op for op in attrs(upload_file).get("uploadOperations") or []
                  if isinstance(op, dict)]
    if not operations:
        return upload_refused(client, upload_id, "Apple returned no upload operations")
    operations.sort(key=lambda op: int(op.get("offset") or 0))
    for index, op in enumerate(operations, 1):
        problem = send_upload_operation(ipa, op, index, len(operations), client.ssl)
        if problem:
            return upload_refused(client, upload_id, problem)

    # Commit: Apple checks the MD5 of the whole file before it answers (long timeout). Never
    # repeated: a repeat can be refused after a commit that worked.
    file_id = upload_file["id"]
    body = {"data": {"type": "buildUploadFiles", "id": file_id,
                     "attributes": {"uploaded": True,
                                    "sourceFileChecksums": {"file": {"hash": digest,
                                                                     "algorithm": "MD5"}}}}}
    # From here on Apple may take the file even if this step is stopped (a cancel during the
    # commit or the check after it): the marker keeps the certificate for the finish job. It goes
    # again whenever Apple refuses the upload.
    create_marker(marker)
    try:
        client.request("PATCH", f"/v1/buildUploadFiles/{file_id}", body, timeout=COMMIT_TIMEOUT)
    except ApiError as err:
        if not err.ambiguous:           # a clear refusal (e.g. 409/422 checksum)
            return upload_refused(client, upload_id, err.describe(), err, marker=marker)
        log(f"The commit got no clear answer ({err.describe()}): asking Apple whether it has "
            "the file")
        if not commit_went_through(client, upload_id, file_id):
            return upload_refused(client, upload_id,
                                  f"{err.describe()}; Apple never showed the file as received",
                                  marker=marker)
        log("Apple has (or may have) the file: the commit counts as sent")
    except Failure:     # no new token could be made: the commit was never sent
        remove_if_present(marker)
        raise
    mark_committed(marker)
    return wait_for_upload(client, upload_id, args, marker)


def wait_for_upload(client: Client, upload_id: str, args, marker: str = "") -> int:
    deadline = deadline_after(args.timeout_min)
    state, details = "", {}         # "": no answer yet (the commit itself was accepted)
    while True:
        try:
            doc = read_uploads(client, f"/v1/buildUploads/{upload_id}")
            details = attrs(doc.get("data")).get("state") or {}
            state = details.get("state") or state
        except ApiError as err:
            if err.status in (401, 403):
                raise
            log(f"  (status check failed, trying again: {err.describe()})")
        if state in ("COMPLETE", "FAILED") or time.monotonic() >= deadline:
            break
        log(f"  build upload: {state or '?'}")
        pause(UPLOAD_POLL_SEC)
    for info in details.get("infos") or []:
        log(f"  info: {_state_detail(info)}")
    for warning in details.get("warnings") or []:
        annotate("warning", "App Store Connect", _state_detail(warning))
    if state == "COMPLETE":
        set_output("uploaded", "true")
        set_output("upload_id", upload_id)
        append_summary(f"### TestFlight · subida / upload\n\nLa build {args.build} (versión "
                       f"{args.version}) está subida y Apple la está procesando. / Build "
                       f"{args.build} (version {args.version}) is uploaded and Apple is processing "
                       "it.")
        return EXIT_OK
    if state == "FAILED":
        if marker:
            remove_if_present(marker)   # refused for good: no build will appear
        set_output("uploaded", "false")
        raise upload_rejected(args.build, details.get("errors") or [])
    if state == "AWAITING_UPLOAD":
        return upload_refused(client, upload_id,
                              f"after {args.timeout_min:g} min Apple still had not received the file",
                              marker=marker)
    # PROCESSING, or no readable answer at all after an accepted commit: never delete that.
    report("warning", "Apple sigue procesando la subida / Upload still processing",
           f"Tras {args.timeout_min:g} min Apple sigue procesando la subida (estado "
           f"{state or '?'}). El archivo ya está en Apple: el trabajo «{FINISH_JOB}» espera a la "
           "build.",
           f"After {args.timeout_min:g} min Apple is still processing the upload (state "
           f"{state or '?'}). The file is with Apple already: the «{FINISH_JOB}» job waits for the "
           "build.")
    set_output("uploaded", "true")
    set_output("upload_id", upload_id)
    return EXIT_OK


# ---------------------------------------------------------------- wait-build

def find_build(client: Client, app_id: str, number: str):
    params = {"filter[app]": app_id, "filter[version]": number, "sort": "-uploadedDate",
              "limit": "50"}
    for build in client.get_all("/v1/builds", params, max_pages=2):
        if str(attrs(build).get("version")) == str(number):
            return build
    return None


def _internal_group(groups):
    """An internal group, preferably one that sees every build."""
    internal = [g for g in groups if attrs(g).get("isInternalGroup")]
    return (next((g for g in internal if attrs(g).get("hasAccessToAllBuilds")), None)
            or (internal[0] if internal else None))


def setup_testers(client: Client, app_id: str, build):
    """Best effort: an internal group with the Account Holder (the owner) as its tester. Nobody
    else is added, admins included. Returns (group name, testers added); problems only warn.
    E-mails are never printed (public log)."""
    group_name, added, problems = "", 0, []
    groups_path = f"/v1/apps/{app_id}/betaGroups"
    try:
        group = _internal_group(client.get_all(groups_path, {"limit": "200"}))
        if group is None:
            body = {"data": {"type": "betaGroups",
                             "attributes": {"name": BETA_GROUP_NAME, "isInternalGroup": True,
                                            "hasAccessToAllBuilds": True},
                             "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}
            try:
                group = client.request("POST", "/v1/betaGroups", body)["data"]
            except ApiError as err:
                if not err.ambiguous:
                    raise
                pause(RECHECK_SEC)      # the answer was lost: the group may exist anyway
                group = _internal_group(client.get_all(groups_path, {"limit": "200"}))
                if group is None:
                    raise
            log(f"Created the internal TestFlight group «{BETA_GROUP_NAME}»")
        group_id = group["id"]
        group_name = attrs(group).get("name") or BETA_GROUP_NAME
        if build is not None and not attrs(group).get("hasAccessToAllBuilds"):
            try:    # adding a member twice is harmless (JSON:API relationship)
                client.request("POST", f"/v1/betaGroups/{group_id}/relationships/builds",
                               {"data": [{"type": "builds", "id": build["id"]}]}, idempotent=True)
            except ApiError as err:
                if err.status != 409:
                    problems.append((err.describe(), err.describe()))
        users = client.get_all("/v1/users", {"limit": "200"})
        holders = [u for u in users if TESTER_ROLE in (attrs(u).get("roles") or [])]
        if not holders:
            problems.append(("no se ve al titular de la cuenta (Account Holder) entre los usuarios",
                             "the Account Holder is not among the users the API key can see"))
        testers = client.get_all(f"/v1/betaGroups/{group_id}/betaTesters", {"limit": "200"})
        present = {str(attrs(t).get("email") or "").lower() for t in testers}
        for user in holders:
            info = attrs(user)
            mail = str(info.get("username") or "").strip()
            if not mail or mail.lower() in present:
                continue
            body = {"data": {"type": "betaTesters",
                             "attributes": {"email": mail, "firstName": info.get("firstName") or "",
                                            "lastName": info.get("lastName") or ""},
                             "relationships": {"betaGroups": {"data": [{"type": "betaGroups",
                                                                        "id": group_id}]}}}}
            try:    # a repeat after a lost answer gets 409, which is fine
                client.request("POST", "/v1/betaTesters", body, idempotent=True)
                added += 1
            except ApiError as err:
                if err.status != 409:   # 409: already a tester
                    problems.append((err.describe(details=False),) * 2)
        log(f"TestFlight group «{group_name}»: {added} tester(s) added (the Account Holder only)")
    except ApiError as err:
        problems.append((err.describe(details=False),) * 2)
    except Failure as failure:
        problems.append((failure.es, failure.en))
    if problems:
        where_es = f"«{group_name}»" if group_name else "«+» (crea un grupo interno)"
        where_en = f"«{group_name}»" if group_name else "«+» (create an internal group)"
        report("warning", "TestFlight: añade el tester a mano / add the tester by hand",
               f"No se pudo dejar listo el grupo de TestFlight ({'; '.join(p[0] for p in problems)}). "
               "La build está subida igualmente. Para instalarla, añádete tú: App Store Connect ▸ "
               f"Apps ▸ OpenCfMoto ▸ TestFlight ▸ Pruebas internas ▸ {where_es} ▸ Testers «+» ▸ tu "
               "usuario; después abre la app TestFlight en el iPhone con ese Apple ID.",
               f"Could not finish the TestFlight group ({'; '.join(p[1] for p in problems)}). The "
               "build is uploaded anyway. To install it, add yourself: App Store Connect ▸ Apps ▸ "
               f"OpenCfMoto ▸ TestFlight ▸ Internal Testing ▸ {where_en} ▸ Testers «+» ▸ your "
               "user; then open the TestFlight app on the iPhone with that Apple ID.")
    return group_name, added


_ISO_DATE = re.compile(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(Z|[+-]\d\d:?\d\d)?$")


def _timestamp(text) -> float:
    """Seconds since 1970 for an ISO 8601 date with any offset; 0 when unreadable."""
    match = _ISO_DATE.match(str(text or "").strip())
    if not match:
        return 0.0
    zone = match.group(7) or "Z"
    offset = 0 if zone == "Z" else (
        (1 if zone[0] == "+" else -1) * (int(zone[1:3]) * 60 + int(zone[-2:])) * 60)
    fields = tuple(int(v) for v in match.groups()[:6])
    return calendar.timegm(fields + (0, 0, 0)) - offset


def newest_upload(client: Client, app_id: str, number: str):
    """The newest upload of build `number` that reached Apple (altool uploads are listed too),
    or None. Filtered here rather than with filter[]: the relationship endpoint may not support
    it. AWAITING_UPLOAD records are skipped: Apple leaves those next to good uploads. An upload
    that is PROCESSING or COMPLETE wins over a newer FAILED one (e.g. a redundant second upload
    of the same number): its build is still coming."""
    uploads = read_uploads(client, f"/v1/apps/{app_id}/buildUploads", {"limit": "200"},
                           every_page=True)
    found = [(i, u) for i, u in enumerate(uploads)
             if str(attrs(u).get("cfBundleVersion")) == str(number)
             and upload_state(u) not in ("", "AWAITING_UPLOAD")]
    if not found:
        return None
    found = [p for p in found if upload_state(p[1]) in ("PROCESSING", "COMPLETE")] or found
    return max(found, key=lambda pair: (_timestamp(attrs(pair[1]).get("createdDate")
                                                   or attrs(pair[1]).get("uploadedDate")),
                                        pair[0]))[1]


def cmd_wait_build(args) -> int:
    if not VERSION_RE.fullmatch(args.build):
        raise Failure("Build no válida / Invalid build",
                      f"--build «{args.build}» debe ser como 1 o 1.2.3.",
                      f"--build «{args.build}» must look like 1 or 1.2.3.", code=EXIT_USAGE)
    client = Client(load_credentials())
    deadline = deadline_after(args.timeout_min)
    build, state, refused = None, "", None
    while True:
        try:
            build = find_build(client, args.app_id, args.build) or build
        except ApiError as err:
            if err.status in (401, 403):
                raise
            log(f"  (build check failed, trying again: {err.describe()})")
        state = str(attrs(build).get("processingState") or "") if build else ""
        if state in ("VALID", "INVALID", "FAILED"):
            break
        if build is None:
            # No build yet: did Apple refuse the file? Then none will ever appear.
            try:
                newest = newest_upload(client, args.app_id, args.build)
            except ApiError as err:
                if err.status in (401, 403):
                    raise
                log(f"  (upload check failed, trying again: {err.describe()})")
                newest = None
            if newest is not None and upload_state(newest) == "FAILED":
                refused = newest
                break
        if time.monotonic() >= deadline:
            break
        log(f"  build {args.build}: {state or 'not visible yet / aún no aparece'}; next check in "
            f"{args.poll_sec:g} s")
        pause(args.poll_sec)
    if refused is not None:
        for key, value in (("build_id", ""), ("processing_state", "FAILED"), ("processed", "true"),
                           ("beta_group", "")):
            set_output(key, value)
        raise upload_rejected(args.build, (attrs(refused).get("state") or {}).get("errors") or [])
    set_output("build_id", build["id"] if build else "")
    set_output("processing_state", state or "NOT_FOUND")
    # processed=true: Apple finished processing (processing_state says whether it is VALID).
    set_output("processed", "true" if state in ("VALID", "INVALID", "FAILED") else "false")
    if state in ("INVALID", "FAILED"):
        set_output("beta_group", "")
        raise Failure("Apple rechazó la build / Apple rejected the build",
                      f"Apple rechazó la build {args.build}; revisa el correo de App Store Connect "
                      "(códigos ITMS) para ver el motivo. No aparecerá en TestFlight. Corrígelo y "
                      f"después {NEW_RUN_ES}.",
                      f"Apple rejected build {args.build}; check the App Store Connect e-mail (ITMS "
                      "codes) for the reason. It will not appear in TestFlight. Fix it, then "
                      f"{NEW_RUN_EN}.")
    if state != "VALID":
        report("warning", "La build sigue en proceso / Build still processing",
               f"Tras {args.timeout_min:g} min Apple aún no terminó de procesar la build "
               f"{args.build} (estado: {state or 'aún no aparece'}). A veces Apple tarda más; "
               "cuando termine, la build aparecerá en la app TestFlight (Apple suele avisar por "
               "correo).",
               f"After {args.timeout_min:g} min Apple has not finished processing build "
               f"{args.build} (state: {state or 'not visible yet'}). Apple sometimes takes longer; "
               "when it is done the build shows up in the TestFlight app (Apple usually sends an "
               "e-mail).")
    group_name, added = setup_testers(client, args.app_id, build if state == "VALID" else None)
    set_output("beta_group", group_name)
    lines = [f"### TestFlight · build {args.build}", ""]
    if state == "VALID":
        lines.append(f"La build {args.build} está lista en TestFlight (grupo interno «{group_name}», "
                     f"{added} tester(s) añadidos ahora). Abre la app TestFlight en el iPhone con "
                     f"tu Apple ID de App Store Connect e instálala. / Build {args.build} is ready in "
                     f"TestFlight (internal group «{group_name}», {added} tester(s) added now). Open "
                     "the TestFlight app on the iPhone with your App Store Connect Apple ID and "
                     "install it.")
    else:
        lines.append(f"La build {args.build} aún se está procesando. / Build {args.build} is still "
                     "processing.")
    append_summary("\n".join(lines))
    return EXIT_OK


# ---------------------------------------------------------------- cleanup

def _unique(items):
    seen, result = set(), []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def cmd_cleanup(args) -> int:
    if args.duplicates_only:
        return cleanup_duplicates(args)
    known = {"certs": [], "profiles": []}     # what _cleanup knew of when it stopped
    suffix = clean_suffix(args.suffix) if args.suffix else ""
    try:
        return _cleanup(args, known, suffix)
    except Exception as exc:  # cleanup never fails the job: say what to revoke by hand
        reason = exc.en if isinstance(exc, Failure) else f"{type(exc).__name__}: {exc}"
        es, en = manual_revoke(known["certs"], known["profiles"], suffix, build=args.build)
        report("warning", "Limpieza incompleta / Cleanup incomplete",
               f"La limpieza falló ({reason}). {es}", f"Cleanup failed ({reason}). {en}")
        return EXIT_OK


def read_state(path: str):
    """state.json of create-signing as a dict; None when there is none; OSError / ValueError
    (after a log line) when it cannot be read."""
    try:
        with open(path, encoding="utf-8") as fh:
            state = json.load(fh)
    except FileNotFoundError:
        log(f"No state file at {path}: nothing was recorded there.")
        return None
    except (OSError, ValueError) as exc:
        log(f"(could not read {path}: {exc})")
        raise
    return state if isinstance(state, dict) else {}


def run_key_file(state_path: str) -> str:
    """The CSR stays next to state.json (teardown deletes key.pem only): a certificate made from
    its key is this run's, even one whose id was never recorded (a lost answer, a cancelled
    step)."""
    folder = os.path.dirname(os.path.abspath(state_path))
    return next((p for p in (os.path.join(folder, "csr.pem"), os.path.join(folder, "key.pem"))
                 if os.path.isfile(p)), "")


def _cleanup(args, known: dict, suffix: str = "") -> int:
    started = time.monotonic()
    cert_ids, profile_ids, key_file, pending = [], [], "", False
    if args.state:
        try:
            state = read_state(args.state)
        except (OSError, ValueError) as exc:
            state = {}
            es, en = manual_revoke(suffix=suffix, build=args.build)
            report("warning", "state.json ilegible / unreadable",
                   f"No se pudo leer {args.state} ({exc}). {es}",
                   f"Could not read {args.state} ({exc}). {en}")
        if state is not None:
            if state.get("cert_id"):
                cert_ids.append(str(state["cert_id"]))
            profile_ids += [str(p) for p in state.get("profile_ids") or [] if p]
            key_file = run_key_file(args.state)
            pending = bool(state.get("cert_pending"))
    cert_ids += [c for c in re.split(r"[,\s]+", args.cert_id or "") if c]
    profile_ids += [p for p in re.split(r"[,\s]+", args.profile_ids or "") if p]
    cert_ids, profile_ids = _unique(cert_ids), _unique(profile_ids)
    bad = [i for i in cert_ids + profile_ids if not RESOURCE_ID_RE.fullmatch(i)]
    cert_ids = [i for i in cert_ids if i not in bad]
    profile_ids = [i for i in profile_ids if i not in bad]
    known["certs"], known["profiles"] = cert_ids, profile_ids
    if not cert_ids and not profile_ids and not bad and not key_file and not pending:
        log("Nothing to clean up / nada que limpiar")
        append_summary("**Limpieza / cleanup:** nada que revocar / nothing to revoke.")
        return EXIT_OK
    client = Client(load_credentials())
    done, failed = [], [("invalid", i, f"invalid id «{i}»") for i in bad]   # (kind, id, text)
    tried = set()

    def revoke_known():
        """DELETE every recorded or listed id not tried yet, profiles first (they reference the
        certificate). Each one goes as soon as it is known: after a cancel GitHub stops Clean up
        within minutes, and what was revoked by then stays revoked."""
        for kind, template, ids in (("profile", "/v1/profiles/{}", profile_ids),
                                    ("certificate", "/v1/certificates/{}", cert_ids)):
            for resource_id in ids:
                if (kind, resource_id) in tried:
                    continue
                tried.add((kind, resource_id))
                try:
                    client.request("DELETE", template.format(resource_id))
                    done.append(kind)       # no id: nothing is left to look for by hand
                except ApiError as err:
                    if err.status == 404:
                        done.append(f"{kind} (ya no existía / already gone)")
                    else:
                        failed.append((kind, resource_id, f"{kind} {resource_id}: {err.describe()}"))

    checked = False                     # every listing of this run's certificates worked
    why_es, why_en = "no está csr.pem, la clave de esta ejecución", "csr.pem, this run's key, is missing"
    if key_file:
        checked = True
        # cert_pending: a certificate request of this run was cut off (a cancelled step) or got no
        # clear answer, so Apple may still be making that certificate: look again for a while,
        # also after finding one (two requests may have been sent). Whatever a listing shows is
        # revoked before the next pause. A DELETE problem is not a listing problem: revoke_known
        # stays outside this try (its failures are reported below, or by cmd_cleanup).
        for delay in (0,) + (PENDING_RECHECK_SEC if pending else ()):
            if delay:
                if time.monotonic() - started + delay * time_scale() > PENDING_RECHECK_BUDGET_SEC:
                    checked = False
                    why_es = ("App Store Connect respondía muy despacio y se dejó de buscar para que "
                              "este paso termine a tiempo")
                    why_en = ("App Store Connect answered very slowly, so the search stopped for "
                              "this step to end in time")
                    log(f"  ({why_en}: GitHub stops Clean up a few minutes after a cancel)")
                    break
                log(f"  a certificate request of this run got no clear answer: looking again "
                    f"in {delay:g} s")
                pause(delay)
            try:
                listed = my_certificates(client, key_file)
            except (ApiError, Failure) as exc:
                checked, why_es, why_en = False, str(exc), str(exc)
                log(f"(could not look for this run's certificates: {exc})")
                break
            for cert in listed:
                if cert["id"] not in cert_ids:
                    log("Another certificate was made from this run's key: revoking it too")
                    cert_ids.append(cert["id"])
            revoke_known()
    revoke_known()      # no CSR, or a listing that failed: the recorded ids go all the same
    if pending and not checked:
        es, en = manual_revoke(suffix=suffix, profiles=False, build=args.build)   # profiles: below
        report("warning", "Certificado sin confirmar / Certificate not confirmed",
               "Una petición de certificado de esta ejecución quedó sin respuesta clara y no se "
               f"pudo comprobar si Apple llegó a crear el certificado ({why_es}). {es}",
               "A certificate request of this run got no clear answer and it could not be checked "
               f"whether Apple created the certificate ({why_en}). {en}")
    elif pending:
        log("A certificate request of this run got no clear answer: its certificate was looked "
            f"for during {sum(PENDING_RECHECK_SEC):g} s (any that showed up was revoked)")
    if failed:
        listing = "; ".join(f[2] for f in failed)
        certs_left = [f[1] for f in failed if f[0] == "certificate"]
        profiles_left = [f[1] for f in failed if f[0] == "profile"]
        unknown = any(f[0] == "invalid" for f in failed)    # a tampered id: say both
        es, en = manual_revoke(certs_left, profiles_left, suffix, certs=bool(certs_left) or unknown,
                               profiles=bool(profiles_left) or unknown, build=args.build)
        report("warning", "Limpieza incompleta / Cleanup incomplete",
               f"No se pudo revocar o borrar: {listing}. {es}",
               f"Could not revoke or delete: {listing}. {en}")
    if done:
        append_summary("**Limpieza / cleanup:** revocado o borrado / revoked or deleted: "
                       + ", ".join(done) + ".")
    if pending and not checked:
        append_summary("**Limpieza / cleanup:** certificado sin confirmar: sigue el aviso "
                       "«Certificado sin confirmar» / certificate not confirmed: follow the "
                       "«Certificado sin confirmar» warning.")
    elif not done and not failed:
        log("Nothing to clean up / nada que limpiar")
        looked = (" (se buscó un rato el certificado de una petición sin respuesta clara: no "
                  "apareció ninguno / the certificate of a request without a clear answer was "
                  "looked for a while: none showed up)" if pending and checked else "")
        append_summary(f"**Limpieza / cleanup:** nada que revocar / nothing to revoke{looked}.")
    return EXIT_OK


def cleanup_duplicates(args) -> int:
    """Teardown of a build that reached Apple: the recorded certificate stays for the finish job,
    which keeps it if Apple accepts the build and revokes it if not. A second certificate that an
    unclear request of
    this run made as well is in no profile, so only this run's key finds it: revoke it now.
    Never touches profiles or the recorded certificate, and never gives the generic manual steps
    (they would point at the certificate the build still needs)."""
    try:
        state = read_state(args.state) if args.state else None
    except (OSError, ValueError):
        state = None
    if not state or not (state.get("cert_pending") or state.get("cert_unclear")):
        log("No certificate request of this run went unanswered: no duplicate to look for")
        return EXIT_OK
    keep = str(state.get("cert_id") or "")
    key_file = run_key_file(args.state)
    if not keep or not key_file:
        log("(no recorded certificate or no CSR: duplicates are not looked for)")
        return EXIT_OK
    after_es, after_en = AFTER_FINISH_ES, AFTER_FINISH_EN
    try:
        client = Client(load_credentials())
        extra = [c["id"] for c in my_certificates(client, key_file) if c.get("id") != keep]
    except Exception as exc:  # missing secrets too: never the generic manual steps here
        reason = exc.en if isinstance(exc, Failure) else (
            exc.describe() if isinstance(exc, ApiError) else f"{type(exc).__name__}: {exc}")
        report("warning", "Certificado sin confirmar / Certificate not confirmed",
               "Una petición de certificado de esta ejecución quedó sin respuesta clara y no se "
               f"pudo comprobar si creó un segundo certificado ({reason}). {after_es}",
               "A certificate request of this run got no clear answer and it could not be checked "
               f"whether it made a second certificate ({reason}). {after_en}")
        return EXIT_OK
    revoked, left = [], []
    for cert_id in extra:
        try:
            client.request("DELETE", f"/v1/certificates/{cert_id}")
            revoked.append(cert_id)
            log("Revoked a duplicate certificate of this run (the build's own stays)")
        except ApiError as err:
            if err.status == 404:
                revoked.append(cert_id)
            else:
                left.append(f"{cert_id}: {err.describe()}")
        except Failure as failure:      # e.g. no new token: still no generic manual steps
            left.append(f"{cert_id}: {failure.en}")
    if left:
        report("warning", "Limpieza incompleta / Cleanup incomplete",
               "No se pudo revocar un certificado duplicado de esta ejecución "
               f"({'; '.join(left)}). {after_es}",
               f"Could not revoke a duplicate certificate of this run ({'; '.join(left)}). "
               f"{after_en}")
    if revoked:
        append_summary("**Limpieza / cleanup:** revocado un certificado duplicado de esta ejecución "
                       f"/ revoked a duplicate certificate of this run: {', '.join(revoked)}. Con el "
                       f"de la build decide el trabajo «{FINISH_JOB}» (lo conserva si Apple acepta la "
                       "build) / the build's own certificate is up to the "
                       f"«{FINISH_JOB}» job (it keeps it if Apple accepts the build).")
    elif not left:
        log("No duplicate certificate of this run / ningún certificado duplicado")
    return EXIT_OK


# ---------------------------------------------------------------- settle-signing

def cmd_settle_signing(args) -> int:
    """The finish job, once a build reached Apple and wait-build is over: what happens to this
    run's signing set (its certificate and two profiles). Never fails the job: problems warn.
    - Apple refused the build (processing INVALID or FAILED, or the upload itself FAILED): nothing
      will check its signature, so the set is revoked now, by its ids, or by this run's profile
      names when the build job passed on none.
    - Apple accepted it (VALID): the set stays, since beta review checks the signature again; the
      sets of older builds go, except a build's that waits for or is in beta review (janitor,
      with this run's set left alone).
    - Anything else (still processing at the time limit, no answer, the wait cancelled): the set
      stays for now; the next run's janitor decides with fresh data."""
    state = (args.state or "").strip().upper()
    build = build_tag(args.build)
    shown = build or "?"
    if state in ("INVALID", "FAILED"):
        if args.cert_id or args.profile_ids:
            cmd_cleanup(argparse.Namespace(state=None, cert_id=args.cert_id,
                                           profile_ids=args.profile_ids, suffix="", build=build,
                                           duplicates_only=False))
        else:
            log("The build job passed on no certificate or profile ids: sweeping up this run's "
                "profiles by name")
            janitor(run_id=args.run_id or "")
        append_summary(f"**Certificado / certificate:** Apple rechazó la build {shown}: su "
                       "certificado temporal y sus perfiles se revocan (nada vuelve a comprobar su "
                       f"firma). / Apple rejected build {shown}: its temporary certificate and "
                       "profiles are revoked (nothing checks its signature again).")
        return EXIT_OK
    if state != "VALID":
        log(f"Build {shown} is not processed yet ({state or 'no state'}): its signing set stays for "
            "now; the next run decides")
        append_summary(f"**Certificado / certificate:** el de la build {shown} se queda por ahora: "
                       "Apple aún no terminó de procesarla. La próxima ejecución lo decide (lo "
                       "conserva si Apple la acepta y lo revoca si la rechaza). / The certificate "
                       f"of build {shown} stays for now: Apple has not finished processing it. The "
                       "next run decides (it keeps it if Apple accepts the build and revokes it if "
                       "Apple rejects it).")
        return EXIT_OK
    log(f"Build {shown} was accepted: its signing set stays until Apple accepts a newer build")
    append_summary(f"**Certificado / certificate:** el de la build {shown} se queda en la cuenta "
                   "hasta que Apple acepte una build más reciente: la revisión de TestFlight vuelve "
                   "a comprobar la firma cuando envías la build a las pruebas externas (el enlace "
                   "público). No lo revoques mientras esa build esté en revisión. / The certificate "
                   f"of build {shown} stays in the account until Apple accepts a newer build: "
                   "TestFlight beta review checks the signature again when you send the build to "
                   "external testing (the public link). Do not revoke it while that build is in "
                   "review.")
    janitor(app_id=args.app_id or "", keep_run=args.run_id or "")
    return EXIT_OK


# ---------------------------------------------------------------- command line

class Parser(argparse.ArgumentParser):
    def error(self, message):
        annotate("error", "asc.py: uso incorrecto / bad usage", f"{self.prog}: {message}")
        self.print_usage(sys.stderr)
        self.exit(EXIT_USAGE, f"{self.prog}: error: {message}\n")


def _resource_id(value: str) -> str:
    if not RESOURCE_ID_RE.fullmatch(value or ""):
        raise argparse.ArgumentTypeError(f"not an App Store Connect id: {value!r}")
    return value


def _run_id(value: str) -> str:
    if value and not re.fullmatch(r"[0-9]+", value):
        raise argparse.ArgumentTypeError(f"not a GitHub run id: {value!r}")
    return value


def _build_number(value: str) -> str:
    """A build number as the profile names carry it: digits, or "" when none is known."""
    if value and not re.fullmatch(r"[0-9]+", value):
        raise argparse.ArgumentTypeError(f"not a build number: {value!r}")
    return value


def _optional_resource_id(value: str) -> str:
    return _resource_id(value) if value else ""


def build_parser() -> argparse.ArgumentParser:
    parser = Parser(prog="asc.py", description="App Store Connect helper for the TestFlight workflow.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("check-auth", help="check the API key (GET /v1/bundleIds)")
    p.set_defaults(func=cmd_check_auth)

    p = sub.add_parser("prepare", help="App IDs, capabilities, app record, leftover sweep")
    p.add_argument("--prefix", required=True, help="bundle ID prefix, e.g. com.example")
    p.add_argument("--setup-only", action="store_true", help="register and explain; never ready")
    p.add_argument("--project-yml", default=os.path.join(REPO_ROOT, "project.yml"),
                   help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_prepare)

    p = sub.add_parser("next-build", help="the next free build number (CFBundleVersion)")
    p.add_argument("--app-id", required=True, type=_resource_id)
    p.set_defaults(func=cmd_next_build)

    p = sub.add_parser("janitor", help="remove CI profiles and certificates a run left behind, and "
                                       "the signing sets no build needs any more")
    p.add_argument("--run-id", type=_run_id, default="",
                   help="only that run's profiles of this repository (the finish job)")
    p.add_argument("--app-id", type=_optional_resource_id, default="",
                   help="the app whose builds decide about this repository's signing sets")
    p.set_defaults(func=cmd_janitor)

    p = sub.add_parser("create-signing", help="distribution certificate + App Store profiles")
    p.add_argument("--app-bundle-resource-id", required=True, type=_resource_id)
    p.add_argument("--mirror-bundle-resource-id", required=True, type=_resource_id)
    p.add_argument("--app-bundle-id", required=True)
    p.add_argument("--mirror-bundle-id", required=True)
    p.add_argument("--app-group", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--suffix", default="", help="profile name suffix (default: as "
                                                    "build_and_sign.sh makes it)")
    p.add_argument("--build", type=_build_number, default="",
                   help="the build number this set signs (in the profile names: « b<build>»)")
    p.set_defaults(func=cmd_create_signing)

    p = sub.add_parser("upload", help="upload an .ipa with the Build Upload API")
    p.add_argument("--ipa", required=True)
    p.add_argument("--app-id", required=True, type=_resource_id)
    p.add_argument("--version", required=True, help="CFBundleShortVersionString")
    p.add_argument("--build", required=True, help="CFBundleVersion")
    p.add_argument("--timeout-min", type=float, default=30)
    p.add_argument("--committed-marker", help="file created once Apple has the file (removed "
                                              "again if Apple then refuses it)")
    p.set_defaults(func=cmd_upload)

    p = sub.add_parser("wait-build", help="wait for processing, then set up internal testers")
    p.add_argument("--app-id", required=True, type=_resource_id)
    p.add_argument("--build", required=True)
    p.add_argument("--timeout-min", type=float, default=90)
    p.add_argument("--poll-sec", type=float, default=60)
    p.set_defaults(func=cmd_wait_build)

    p = sub.add_parser("settle-signing", help="after wait-build: keep this run's signing set if "
                                              "Apple accepted the build, else revoke it")
    p.add_argument("--app-id", type=_optional_resource_id, default="")
    p.add_argument("--build", type=_build_number, default="")
    p.add_argument("--state", default="", help="wait-build's processing_state output")
    p.add_argument("--run-id", type=_run_id, default="")
    p.add_argument("--cert-id")
    p.add_argument("--profile-ids")
    p.set_defaults(func=cmd_settle_signing)

    p = sub.add_parser("cleanup", help="delete the profiles and revoke the certificate")
    p.add_argument("--state")
    p.add_argument("--cert-id")
    p.add_argument("--profile-ids")
    p.add_argument("--suffix", default="", help="the profile name suffix create-signing used "
                                                "(names this run's profiles in the manual steps)")
    p.add_argument("--build", type=_build_number, default=None,
                   help="the build number in those names (default: BUILD_NUMBER)")
    p.add_argument("--duplicates-only", action="store_true", help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_cleanup)
    return parser


def main(argv=None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, ValueError):
            pass
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except Failure as failure:
        report("error", failure.title, failure.es, failure.en)
        return failure.code
    except ApiError as err:
        failure = explain(err)
        report("error", failure.title, failure.es, failure.en)
        return failure.code
    except Exception as exc:  # a bug: still leave a readable annotation
        traceback.print_exc()
        report("error", "asc.py: error inesperado / unexpected error",
               f"Error inesperado: {type(exc).__name__}: {exc}",
               f"Unexpected error: {type(exc).__name__}: {exc}")
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main())
