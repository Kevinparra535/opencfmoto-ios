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
  asc.py create-signing --app-bundle-resource-id ID --mirror-bundle-resource-id ID \\
                        --app-bundle-id X --mirror-bundle-id Y --app-group G --out DIR --suffix S
  asc.py upload --ipa PATH --app-id ID --version 1.2.3 --build N [--timeout-min 30]
  asc.py wait-build --app-id ID --build N [--timeout-min 90] [--poll-sec 60]
  asc.py cleanup [--state DIR/state.json] [--cert-id C] [--profile-ids P1,P2]

Environment: ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY (the text of the .p8 file; CRLF, stray
spaces, a one-line paste or literal "\\n" sequences are tolerated) or ASC_PRIVATE_KEY_PATH.
Optional: ASC_API_BASE (tests), ASC_POLL_SCALE (tests: multiplies every wait and timeout),
ASC_OPENSSL (openssl binary). GITHUB_OUTPUT / GITHUB_STEP_SUMMARY receive key=value outputs and a
Markdown summary when set; outputs are echoed to stdout as key=value lines too.

Exit codes: 0 ok, 1 failed (reason in an ::error annotation, Spanish then English), 2 usage,
3 upload refused before the file was committed (the workflow falls back to `xcrun altool`),
4 the new provisioning profiles lack the App Group (owner action on developer.apple.com).

The repository is public, so logs and summaries are too: request bodies (CSR) and responses
(certificate / profile content, user e-mails) are never printed, and the JWT is masked.
"""
from __future__ import annotations

import argparse
import base64
import binascii
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
UPLOAD_TIMEOUT = 600        # seconds per upload operation (one slice of the .ipa)
API_RETRIES = 5             # retries for 429 / 5xx / network errors
UPLOAD_OP_RETRIES = 3       # retries per upload operation
UPLOAD_POLL_SEC = 15
# Apple refuses tokens whose `exp` is more than 20 minutes ahead (clock skew included): use 19.
JWT_LIFETIME = 19 * 60
JWT_REFRESH_MARGIN = 120    # mint a new token when less than this is left

EXIT_OK, EXIT_FAILED, EXIT_USAGE, EXIT_UPLOAD_REFUSED, EXIT_APP_GROUP = 0, 1, 2, 3, 4

APP_BUNDLE_NAME = "OpenCfMoto"            # App ID names: letters, digits and spaces only
MIRROR_BUNDLE_NAME = "OpenCfMoto Mirror"
APP_CAPABILITIES = ("APP_GROUPS", "HOT_SPOT", "ACCESS_WIFI_INFORMATION")
MIRROR_CAPABILITIES = ("APP_GROUPS",)
BETA_GROUP_NAME = "OpenCfMoto (interno)"
ADMIN_ROLES = {"ACCOUNT_HOLDER", "ADMIN"}
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


def set_output(name: str, value) -> None:
    text = "" if value is None else str(value).replace("\r", " ").replace("\n", " ")
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(f"{name}={text}\n")
    log(f"{name}={text}")


def report(level: str, title: str, es: str, en: str) -> None:
    """Annotation + plain paragraphs in the log + step summary; Spanish first, then English."""
    annotate(level, title, f"{es}\n\n{en}")
    label = "ERROR" if level == "error" else "AVISO / WARNING"
    log(f"\n{label}: {title}\n\n{es}\n\n{en}\n")
    head = "Error" if level == "error" else "Aviso / Warning"
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
            "AuthKey_XXXXXXXXXX.p8 que descargaste al crear la clave de la API (una clave EC P-256), "
            "incluidas las líneas -----BEGIN PRIVATE KEY----- y -----END PRIVATE KEY-----.",
            "openssl could not sign with ASC_PRIVATE_KEY. It must be the whole content of the "
            "AuthKey_XXXXXXXXXX.p8 file downloaded when the API key was created (an EC P-256 key), "
            "including the -----BEGIN PRIVATE KEY----- and -----END PRIVATE KEY----- lines.")
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
            f"Actions ▸ New repository secret (pasos en {GUIDE}).",
            f"The secrets {names} are missing. Add them at GitHub ▸ Settings ▸ Secrets and "
            f"variables ▸ Actions ▸ New repository secret (steps in {GUIDE}).")
    try:
        pem = normalize_private_key(raw)
    except ValueError as exc:
        raise Failure(
            "ASC_PRIVATE_KEY no válida / invalid",
            f"El secreto ASC_PRIVATE_KEY no parece el contenido de un archivo .p8 ({exc}). Abre "
            "AuthKey_XXXXXXXXXX.p8 con un editor de texto y pega TODO su contenido, incluidas las "
            "líneas -----BEGIN PRIVATE KEY----- y -----END PRIVATE KEY-----.",
            f"The ASC_PRIVATE_KEY secret does not look like the content of a .p8 file ({exc}). "
            "Open AuthKey_XXXXXXXXXX.p8 in a text editor and paste ALL of it, including the "
            "-----BEGIN PRIVATE KEY----- and -----END PRIVATE KEY----- lines.") from None
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


class Client:
    def __init__(self, creds: Credentials, base: str = None):
        self.creds = creds
        self.base = (base or os.environ.get("ASC_API_BASE") or DEFAULT_API_BASE).rstrip("/")
        self.ssl = ssl_context()
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

    def request(self, method: str, path: str, body: dict = None, params: dict = None) -> dict:
        url = self.url(path, params)
        shown = url[len(self.base):]
        data = json.dumps(body).encode("utf-8") if body is not None else None
        attempt, refreshed = 0, False
        while True:
            headers = {"Authorization": f"Bearer {self.token()}", "Accept": "application/json",
                       "User-Agent": USER_AGENT}
            if data is not None:
                headers["Content-Type"] = "application/json"
            request = urllib.request.Request(url, data=data, method=method, headers=headers)
            retry_after, network_error = None, ""
            try:
                with urllib.request.urlopen(request, timeout=API_TIMEOUT, context=self.ssl) as resp:
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
            # 429 (nothing was done) and 5xx (Apple's gateway, nearly always before anything was
            # done) are repeated. A POST cut off by a network error is not: Apple may have created
            # the resource, and a second distribution certificate would be left behind unrevoked.
            retryable = status == 429 or status >= 500 or (status == 0 and method != "POST")
            if retryable and attempt < API_RETRIES:
                delay = retry_delay(attempt, retry_after)
                attempt += 1
                log(f"    retry {attempt}/{API_RETRIES} in {delay:g} s")
                pause(delay)
                continue
            errors = _parse_errors(raw) if status else [{"code": "NETWORK", "detail": network_error}]
            raise ApiError(method, shown, status, errors)

    def get_all(self, path: str, params: dict = None, max_pages: int = 50) -> list:
        """Every item of a list endpoint, following links.next."""
        items, pages = [], 1
        doc = self.request("GET", path, params=params)
        while True:
            data = doc.get("data")
            if isinstance(data, list):
                items.extend(d for d in data if isinstance(d, dict))
            nxt = (doc.get("links") or {}).get("next")
            if not nxt or pages >= max_pages:
                return items
            doc = self.request("GET", nxt)
            pages += 1


def explain(err: ApiError, context_es: str = "", context_en: str = "") -> Failure:
    detail = err.describe()
    pre_es = f"{context_es}: " if context_es else ""
    pre_en = f"{context_en}: " if context_en else ""
    if err.status == 401:
        return Failure(
            "Clave de API rechazada / API key rejected (401)",
            f"{pre_es}App Store Connect rechazó la clave de la API (HTTP 401). Revisa los tres "
            "secretos (GitHub ▸ Settings ▸ Secrets and variables ▸ Actions): ASC_KEY_ID = el «Key "
            "ID» de 10 caracteres; ASC_ISSUER_ID = el «Issuer ID» (un UUID) que aparece encima de "
            "la lista de claves en App Store Connect ▸ Usuarios y acceso ▸ Integraciones ▸ App "
            "Store Connect API ▸ «Claves de equipo»; ASC_PRIVATE_KEY = el archivo .p8 completo. "
            "Debe ser una clave de equipo (no individual) y no estar revocada. "
            f"Detalle: {detail}",
            f"{pre_en}App Store Connect rejected the API key (HTTP 401). Check the three secrets "
            "(GitHub ▸ Settings ▸ Secrets and variables ▸ Actions): ASC_KEY_ID = the 10-character "
            "Key ID; ASC_ISSUER_ID = the Issuer ID (a UUID) shown above the key list in App Store "
            "Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect API ▸ Team Keys; "
            "ASC_PRIVATE_KEY = the whole .p8 file. It must be a Team key (not an Individual key) "
            f"and not revoked. Detail: {detail}")
    if err.status == 403 and "agreement" in err.text():
        return Failure(
            "Acuerdos pendientes / Agreements to accept (403)",
            f"{pre_es}Apple exige aceptar acuerdos pendientes antes de usar la API (HTTP 403). "
            "Entra con la cuenta del titular (Account Holder) en https://developer.apple.com/account "
            "y en App Store Connect ▸ Negocios (Business), acepta los acuerdos o términos nuevos y "
            f"vuelve a ejecutar el workflow. Detalle: {detail}",
            f"{pre_en}Apple requires pending agreements to be accepted before the API can be used "
            "(HTTP 403). Sign in as the Account Holder at https://developer.apple.com/account and "
            "App Store Connect ▸ Business, accept the new agreements or terms and run the workflow "
            f"again. Detail: {detail}")
    if err.status == 403:
        return Failure(
            "Permiso denegado / Not allowed (403)",
            f"{pre_es}La clave de la API no tiene permiso para esta operación (HTTP 403). Crea una "
            "clave con el rol «Admin» (App Store Connect ▸ Usuarios y acceso ▸ Integraciones ▸ App "
            "Store Connect API ▸ Claves de equipo; los certificados y perfiles necesitan Admin) y "
            "actualiza ASC_KEY_ID y ASC_PRIVATE_KEY. Si ya es Admin, mira si hay acuerdos "
            f"pendientes en App Store Connect ▸ Negocios. Detalle: {detail}",
            f"{pre_en}The API key is not allowed to do this (HTTP 403). Create a key with the "
            "«Admin» role (App Store Connect ▸ Users and Access ▸ Integrations ▸ App Store Connect "
            "API ▸ Team Keys; certificates and profiles need Admin) and update ASC_KEY_ID and "
            "ASC_PRIVATE_KEY. If it already is Admin, check for pending agreements in App Store "
            f"Connect ▸ Business. Detail: {detail}")
    if err.status == 429:
        return Failure(
            "Límite de peticiones / Rate limited (429)",
            f"{pre_es}Apple limita las peticiones a la API (HTTP 429) y siguió rechazándolas tras "
            f"{API_RETRIES} reintentos. Espera una hora y vuelve a ejecutar. Detalle: {detail}",
            f"{pre_en}Apple rate-limits the API (HTTP 429) and kept refusing after {API_RETRIES} "
            f"retries. Wait an hour and run again. Detail: {detail}")
    if err.status == 0:
        return Failure(
            "Error de red / Network error",
            f"{pre_es}No se pudo hablar con App Store Connect (error de red). Suele ser temporal: "
            f"vuelve a ejecutar el workflow. Detalle: {detail}",
            f"{pre_en}Could not reach App Store Connect (network error). This is usually "
            f"temporary: run the workflow again. Detail: {detail}")
    if err.status >= 500:
        return Failure(
            f"App Store Connect no responde / not responding ({err.status})",
            f"{pre_es}App Store Connect devolvió errores internos (HTTP {err.status}) varias veces "
            f"seguidas. Suele ser temporal: mira {URL_APPLE_STATUS} y vuelve a ejecutar más "
            f"tarde. Detalle: {detail}",
            f"{pre_en}App Store Connect kept returning internal errors (HTTP {err.status}). This is "
            f"usually temporary: check {URL_APPLE_STATUS} and run again later. Detail: {detail}")
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
          "plataforma iOS, un nombre (p. ej. «OpenCfMoto»; si ya está cogido en la App Store, "
          f"añade algo como tu nombre), idioma principal, Bundle ID `{app_bid}` (elígelo de la "
          "lista), SKU `opencfmoto`, acceso completo ▸ Crear.")
    en = (f"{number}. Create the app in App Store Connect: {URL_ASC_APPS} ▸ «+» ▸ «New App»: "
          "platform iOS, a name (e.g. «OpenCfMoto»; if the App Store name is taken, add something "
          f"like your name), primary language, bundle ID `{app_bid}` (pick it from the list), "
          "SKU `opencfmoto`, Full Access ▸ Create.")
    return es, en


RUN_AGAIN_ES = "Después vuelve a ejecutar el workflow TestFlight sin marcar «Solo preparar»."
RUN_AGAIN_EN = "Then run the TestFlight workflow again without ticking «Solo preparar»."

MANUAL_REVOKE_ES = (
    f"Revoca a mano lo que quede: en {URL_CERTIFICATES} el certificado «Apple Distribution» creado "
    f"hoy por la clave de la API (púlsalo ▸ Revoke) y en {URL_PROFILES} los perfiles «OpenCfMoto "
    "CI …» (▸ Remove). Un certificado olvidado ocupa uno de los pocos certificados de distribución "
    "que permite Apple.")
MANUAL_REVOKE_EN = (
    f"Revoke what is left by hand: at {URL_CERTIFICATES} the «Apple Distribution» certificate "
    f"created today by the API key (click it ▸ Revoke) and at {URL_PROFILES} the «OpenCfMoto CI …» "
    "profiles (▸ Remove). A forgotten certificate uses one of the few distribution certificates "
    "Apple allows.")


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
        return client.request("POST", "/v1/bundleIds", body)["data"], True
    except ApiError as err:
        if err.status != 409:
            raise explain(err, f"Registrar el App ID {identifier}",
                          f"Registering the App ID {identifier}") from None
    found = lookup(None)    # registered earlier with another platform (e.g. UNIVERSAL)?
    if found:
        return found, False
    raise Failure(
        "Bundle ID no disponible / Bundle ID not available",
        f"Apple no deja registrar `{identifier}`: ya lo usa otro equipo de desarrollador. Define "
        "la variable del repositorio BUNDLE_ID_PREFIX (GitHub ▸ Settings ▸ Secrets and variables ▸ "
        "Actions ▸ Variables) con un prefijo propio, p. ej. `com.tunombre`.",
        f"Apple will not register `{identifier}`: another developer team already uses it. Set "
        "the repository variable BUNDLE_ID_PREFIX (GitHub ▸ Settings ▸ Secrets and variables ▸ "
        "Actions ▸ Variables) to a prefix of your own, e.g. `com.yourname`.")


def ensure_capabilities(client: Client, bundle: dict, wanted) -> list:
    """Enable the capabilities missing on an App ID; returns the ones enabled now."""
    path = f"/v1/bundleIds/{bundle['id']}/bundleIdCapabilities"
    existing = {attrs(c).get("capabilityType") for c in client.get_all(path, {"limit": "200"})}
    added = []
    for capability in wanted:
        if capability in existing:
            continue
        body = {"data": {"type": "bundleIdCapabilities",
                         "attributes": {"capabilityType": capability},
                         "relationships": {"bundleId": {"data": {"type": "bundleIds",
                                                                 "id": bundle["id"]}}}}}
        try:
            client.request("POST", "/v1/bundleIdCapabilities", body)
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
    numbers += [_first_int(attrs(u).get("cfBundleVersion"))
                for u in client.get_all(f"/v1/apps/{app_id}/buildUploads", {"limit": "200"})]
    numbers = [n for n in numbers if n is not None]
    return max(numbers) + 1 if numbers else 1


def cmd_prepare(args) -> int:
    prefix = args.prefix.strip()
    if not PREFIX_RE.fullmatch(prefix):
        raise Failure("Prefijo no válido / Invalid prefix",
                      f"«{prefix}» no sirve como prefijo de Bundle ID (solo letras, cifras, guiones y "
                      "puntos, p. ej. com.tunombre). Revisa la variable BUNDLE_ID_PREFIX.",
                      f"«{prefix}» is not a valid bundle ID prefix (letters, digits, hyphens and dots "
                      "only, e.g. com.yourname). Check the BUNDLE_ID_PREFIX variable.",
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
    build_number = ""
    if app and not args.setup_only:
        build_number = str(next_build_number(client, app_id))
    ready = bool(app) and not args.setup_only

    for key, value in (("ready", "true" if ready else "false"), ("team_id", team_id),
                       ("app_bundle_id", app_bid), ("mirror_bundle_id", mirror_bid),
                       ("app_bundle_resource_id", app_bundle["id"]),
                       ("mirror_bundle_resource_id", mirror_bundle["id"]), ("app_group", group),
                       ("app_id", app_id), ("build_number", build_number),
                       ("marketing_version", marketing)):
        set_output(key, value)

    def state(new):
        return "registrado ahora / registered now" if new else "ya existía / already there"

    rows = [("App ID (app)", f"`{app_bid}` — {state(app_new)}"),
            ("App ID (extensión / extension)", f"`{mirror_bid}` — {state(mirror_new)}"),
            ("Capacidades activadas ahora / capabilities enabled now",
             "; ".join(f"`{bid}`: {', '.join(caps)}" for bid, caps in
                       ((app_bid, app_added), (mirror_bid, mirror_added)) if caps) or "—"),
            ("Team ID", f"`{team_id}`"),
            ("App Group", f"`{group}` (la API no puede comprobarlo / the API cannot check it)"),
            ("App en App Store Connect / app record",
             f"`{app_id}`" if app else "falta / missing"),
            ("Versión / version", marketing + (f" (build {build_number})" if build_number else ""))]
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
        es = ("Todo listo, ejecuta sin «Solo preparar». (Si aún no creaste el App Group "
              f"`{group}` y lo asignaste a los dos App IDs, hazlo antes; la ejecución completa lo "
              "comprueba y te dice cómo.)")
        en = ("All set: run again without «Solo preparar». (If you have not created the App Group "
              f"`{group}` and assigned it to both App IDs yet, do that first; the full run checks "
              "it and tells you how.)")
        log("todo listo, ejecuta sin Solo preparar / all set, run without 'Solo preparar'")
        append_summary(f"{summary}\n\n{es}\n\n{en}")
        return EXIT_OK
    append_summary(f"{summary}\n\nSe compila, firma y sube la build {build_number}. / Build "
                   f"{build_number} is now compiled, signed and uploaded.")
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


def cert_limit_failure(err: ApiError) -> Failure:
    return Failure(
        "Límite de certificados / Certificate limit",
        "Apple no deja crear otro certificado de distribución: el equipo ya tiene el máximo de "
        f"certificados «Apple Distribution». Entra en {URL_CERTIFICATES}, revoca los «Apple "
        "Distribution» que no uses (por ejemplo los que dejó un workflow interrumpido: los crea "
        "la clave de la API) y vuelve a ejecutar. Si otro workflow TestFlight está en marcha, "
        f"espera a que termine: revoca su certificado al final. Detalle: {err.describe()}",
        "Apple will not create another distribution certificate: the team already has the "
        f"maximum number of «Apple Distribution» certificates. Open {URL_CERTIFICATES}, revoke the "
        "«Apple Distribution» certificates you do not use (e.g. ones left by an interrupted "
        "workflow: the API key creates them) and run again. If another TestFlight workflow is "
        "running, wait for it to finish: it revokes its certificate at the end. "
        f"Detail: {err.describe()}")


def cmd_create_signing(args) -> int:
    out = os.path.abspath(args.out)
    profiles_dir = os.path.join(out, "profiles")
    os.makedirs(profiles_dir, exist_ok=True)
    os.chmod(out, 0o700)
    state_path = os.path.join(out, "state.json")
    state = {"cert_id": None, "profile_ids": []}
    save_state(state_path, state)
    suffix = re.sub(r"[^A-Za-z0-9 -]+", "-", args.suffix).strip(" -") or "run"
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
    body = {"data": {"type": "certificates",
                     "attributes": {"csrContent": csr, "certificateType": "DISTRIBUTION"}}}
    try:
        cert = client.request("POST", "/v1/certificates", body)["data"]
    except ApiError as err:
        if err.status == 409:
            raise cert_limit_failure(err) from None
        raise explain(err, "Crear el certificado de distribución",
                      "Creating the distribution certificate") from None
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
        name = f"OpenCfMoto CI {suffix} {role}"
        log(f"Creating the App Store provisioning profile «{name}» for {bundle_id}")
        body = {"data": {"type": "profiles",
                         "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
                         "relationships": {
                             "bundleId": {"data": {"type": "bundleIds", "id": resource_id}},
                             "certificates": {"data": [{"type": "certificates", "id": cert_id}]}}}}
        try:
            profile = client.request("POST", "/v1/profiles", body)["data"]
        except ApiError as err:
            if err.status == 409:
                raise Failure(
                    "No se pudo crear el perfil / Profile not created",
                    f"Apple no aceptó el perfil «{name}» (HTTP 409). Si ya existe uno con ese "
                    f"nombre, bórralo en {URL_PROFILES} y vuelve a ejecutar. Detalle: "
                    f"{err.describe()}",
                    f"Apple refused the profile «{name}» (HTTP 409). If one with that name "
                    f"already exists, remove it at {URL_PROFILES} and run again. Detail: "
                    f"{err.describe()}") from None
            raise explain(err, f"Crear el perfil «{name}»", f"Creating the profile «{name}»") from None
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
               f"El certificado es del equipo {team} pero un perfil indica {profile_teams}.",
               f"The certificate belongs to team {team} but a profile says {profile_teams}.")

    # 4. The entitlements Apple put in the profiles. App Groups cannot be created or assigned to
    #    an App ID through the API, so a missing group is the owner's one-time web step.
    rows, missing_group, missing_other = [], [], []
    for role, bundle_id, name, uuid, plist in created:
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
        rows.append((f"Perfil / profile ({role})", f"{name} (`{uuid}`) — {', '.join(flags)}"))

    summary = "### TestFlight · firma / signing\n\n" + md_table(
        [("Certificado / certificate", f"`{cert_id}` (Apple Distribution, team `{team}`)")] + rows)
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
            es_parts.append(f"Faltan capacidades en el perfil de la app ({listed}). Vuelve a "
                            "ejecutar el workflow (el paso «prepare» activa Hotspot y Access WiFi "
                            f"Information) o actívalas en {URL_IDENTIFIERS} ▸ `{args.app_bundle_id}`.")
            en_parts.append(f"Capabilities are missing in the app profile ({listed}). Run the "
                            "workflow again (the «prepare» step enables Hotspot and Access WiFi "
                            f"Information) or enable them at {URL_IDENTIFIERS} ▸ "
                            f"`{args.app_bundle_id}`.")
        es_parts.append("Los perfiles se generan de nuevo en cada ejecución. " + RUN_AGAIN_ES)
        en_parts.append("The profiles are generated again on every run. " + RUN_AGAIN_EN)
        append_summary(summary)
        title = ("Falta el App Group en los perfiles / App Group missing from the profiles"
                 if missing_group else "Faltan capacidades / Capabilities missing")
        raise Failure(title, "\n\n".join(es_parts), "\n\n".join(en_parts),
                      code=EXIT_APP_GROUP if missing_group else EXIT_FAILED)
    append_summary(summary + "\n\nCertificado y perfiles son temporales: se revocan y borran al "
                   "final del workflow. / The certificate and profiles are temporary: they are "
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
    http.client rather than urllib: urllib would add a form Content-Type of its own."""
    method = str(op.get("method") or "PUT").upper()
    parts = urllib.parse.urlsplit(str(op.get("url") or ""))
    try:
        offset, length = int(op.get("offset") or 0), int(op.get("length") or 0)
    except (TypeError, ValueError):
        offset, length = 0, 0
    headers = {}
    for header in op.get("requestHeaders") or []:
        if isinstance(header, dict) and header.get("name"):
            headers[str(header["name"])] = str(header.get("value") or "")
    if parts.scheme not in ("https", "http") or not parts.hostname or length <= 0 or offset < 0:
        return f"part {index}/{total}: unusable upload operation from Apple"
    with open(path, "rb") as fh:
        fh.seek(offset)
        chunk = fh.read(length)
    if len(chunk) != length:
        return f"part {index}/{total}: the file has no bytes {offset}..{offset + length}"
    target = (parts.path or "/") + (f"?{parts.query}" if parts.query else "")
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
        except (OSError, http.client.HTTPException) as exc:
            last = f"{type(exc).__name__}: {exc}"
            log(f"  upload part {index}/{total} ({length} bytes at {offset}): {last}")
            continue
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


def upload_refused(client: Client, upload_id: str, reason: str, err: ApiError = None) -> int:
    """Exit 3: nothing was committed, so the workflow can retry with `xcrun altool`. The
    dangling build upload is deleted first."""
    if upload_id:
        try:
            client.request("DELETE", f"/v1/buildUploads/{upload_id}")
            log(f"Deleted the unfinished build upload {upload_id}")
        except (ApiError, Failure) as exc:
            log(f"(could not delete the build upload {upload_id}: {exc})")
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

    # Commit: Apple checks the MD5 of the whole file.
    body = {"data": {"type": "buildUploadFiles", "id": upload_file["id"],
                     "attributes": {"uploaded": True,
                                    "sourceFileChecksums": {"file": {"hash": digest,
                                                                     "algorithm": "MD5"}}}}}
    try:
        client.request("PATCH", f"/v1/buildUploadFiles/{upload_file['id']}", body)
    except ApiError as err:
        return upload_refused(client, upload_id, err.describe(), err)
    return wait_for_upload(client, upload_id, args)


def wait_for_upload(client: Client, upload_id: str, args) -> int:
    deadline = deadline_after(args.timeout_min)
    state, details = "AWAITING_UPLOAD", {}
    while True:
        try:
            doc = client.request("GET", f"/v1/buildUploads/{upload_id}")
            details = attrs(doc.get("data")).get("state") or {}
            state = details.get("state") or state
        except ApiError as err:
            if err.status in (401, 403):
                raise
            log(f"  (status check failed, trying again: {err.describe()})")
        if state in ("COMPLETE", "FAILED") or time.monotonic() >= deadline:
            break
        log(f"  build upload {upload_id}: {state}")
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
        errors = details.get("errors") or []
        for item in errors:
            annotate("error", "App Store Connect", _state_detail(item))
        set_output("uploaded", "false")
        listing = "; ".join(_state_detail(e) for e in errors) or "sin detalles / no details"
        raise Failure("Apple rechazó la subida / Apple rejected the upload",
                      f"App Store Connect marcó la subida de la build {args.build} como FAILED: "
                      f"{listing}. Corrige lo indicado y vuelve a ejecutar el workflow.",
                      f"App Store Connect marked the upload of build {args.build} as FAILED: "
                      f"{listing}. Fix what it reports and run the workflow again.")
    if state == "AWAITING_UPLOAD":
        return upload_refused(client, upload_id,
                              f"after {args.timeout_min:g} min Apple still had not received the file")
    report("warning", "Apple sigue procesando la subida / Upload still processing",
           f"Tras {args.timeout_min:g} min Apple sigue procesando la subida (estado {state}). El "
           "archivo ya está en Apple: el siguiente paso espera a la build.",
           f"After {args.timeout_min:g} min Apple is still processing the upload (state {state}). "
           "The file is with Apple already: the next step waits for the build.")
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


def setup_testers(client: Client, app_id: str, build):
    """Best effort: an internal group with every Admin / Account Holder as tester. Returns
    (group name, testers added); failures only warn. E-mails are never printed (public log)."""
    group_name, added, problems = "", 0, []
    try:
        groups = client.get_all(f"/v1/apps/{app_id}/betaGroups", {"limit": "200"})
        internal = [g for g in groups if attrs(g).get("isInternalGroup")]
        group = (next((g for g in internal if attrs(g).get("hasAccessToAllBuilds")), None)
                 or (internal[0] if internal else None))
        if group is None:
            body = {"data": {"type": "betaGroups",
                             "attributes": {"name": BETA_GROUP_NAME, "isInternalGroup": True,
                                            "hasAccessToAllBuilds": True},
                             "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}
            group = client.request("POST", "/v1/betaGroups", body)["data"]
            log(f"Created the internal TestFlight group «{BETA_GROUP_NAME}»")
        group_id = group["id"]
        group_name = attrs(group).get("name") or BETA_GROUP_NAME
        if build is not None and not attrs(group).get("hasAccessToAllBuilds"):
            try:
                client.request("POST", f"/v1/betaGroups/{group_id}/relationships/builds",
                               {"data": [{"type": "builds", "id": build["id"]}]})
            except ApiError as err:
                if err.status != 409:
                    problems.append(err.describe())
        users = client.get_all("/v1/users", {"limit": "200"})
        admins = [u for u in users if ADMIN_ROLES & set(attrs(u).get("roles") or [])]
        testers = client.get_all(f"/v1/betaGroups/{group_id}/betaTesters", {"limit": "200"})
        present = {str(attrs(t).get("email") or "").lower() for t in testers}
        for user in admins:
            info = attrs(user)
            mail = str(info.get("username") or "").strip()
            if not mail or mail.lower() in present:
                continue
            body = {"data": {"type": "betaTesters",
                             "attributes": {"email": mail, "firstName": info.get("firstName") or "",
                                            "lastName": info.get("lastName") or ""},
                             "relationships": {"betaGroups": {"data": [{"type": "betaGroups",
                                                                        "id": group_id}]}}}}
            try:
                client.request("POST", "/v1/betaTesters", body)
                added += 1
            except ApiError as err:
                if err.status != 409:   # 409: already a tester
                    problems.append(err.describe(details=False))
        log(f"TestFlight group «{group_name}»: {len(admins)} admin user(s), {added} tester(s) added")
    except ApiError as err:
        problems.append(err.describe(details=False))
    except Failure as failure:
        problems.append(failure.en)
    if problems:
        listing = "; ".join(problems)
        report("warning", "TestFlight: añade el tester a mano / add the tester by hand",
               f"No se pudo dejar listo el grupo de TestFlight ({listing}). La build está subida "
               "igualmente. Para instalarla: App Store Connect ▸ Apps ▸ OpenCfMoto ▸ TestFlight ▸ "
               "Pruebas internas ▸ «+» ▸ crea un grupo y añade tu usuario; después abre la app "
               "TestFlight en el iPhone con ese Apple ID.",
               f"Could not finish the TestFlight group ({listing}). The build is uploaded anyway. "
               "To install it: App Store Connect ▸ Apps ▸ OpenCfMoto ▸ TestFlight ▸ Internal "
               "Testing ▸ «+» ▸ create a group and add your user; then open the TestFlight app "
               "on the iPhone with that Apple ID.")
    return group_name, added


def cmd_wait_build(args) -> int:
    if not VERSION_RE.fullmatch(args.build):
        raise Failure("Build no válida / Invalid build",
                      f"--build «{args.build}» debe ser como 1 o 1.2.3.",
                      f"--build «{args.build}» must look like 1 or 1.2.3.", code=EXIT_USAGE)
    client = Client(load_credentials())
    deadline = deadline_after(args.timeout_min)
    build, state = None, ""
    while True:
        try:
            build = find_build(client, args.app_id, args.build) or build
        except ApiError as err:
            if err.status in (401, 403):
                raise
            log(f"  (build check failed, trying again: {err.describe()})")
        state = str(attrs(build).get("processingState") or "") if build else ""
        if state in ("VALID", "INVALID", "FAILED") or time.monotonic() >= deadline:
            break
        log(f"  build {args.build}: {state or 'not visible yet / aún no aparece'}; next check in "
            f"{args.poll_sec:g} s")
        pause(args.poll_sec)
    set_output("build_id", build["id"] if build else "")
    set_output("processing_state", state or "NOT_FOUND")
    # processed=true: Apple finished processing (processing_state says whether it is VALID).
    set_output("processed", "true" if state in ("VALID", "INVALID", "FAILED") else "false")
    if state in ("INVALID", "FAILED"):
        set_output("beta_group", "")
        raise Failure("Apple rechazó la build / Apple rejected the build",
                      f"Apple rechazó la build {args.build}; revisa el correo de App Store Connect "
                      "(códigos ITMS) para ver el motivo, corrígelo y vuelve a ejecutar.",
                      f"Apple rejected build {args.build}; check the App Store Connect e-mail (ITMS "
                      "codes) for the reason, fix it and run again.")
    if state != "VALID":
        report("warning", "La build sigue en proceso / Build still processing",
               f"Tras {args.timeout_min:g} min Apple aún no terminó de procesar la build "
               f"{args.build} (estado: {state or 'aún no aparece'}). Suele tardar más algunos "
               "días; cuando termine llegará un correo y aparecerá en la app TestFlight.",
               f"After {args.timeout_min:g} min Apple has not finished processing build "
               f"{args.build} (state: {state or 'not visible yet'}). It sometimes takes longer; "
               "an e-mail arrives when it is done and it shows up in the TestFlight app.")
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
    try:
        return _cleanup(args)
    except Exception as exc:  # cleanup never fails the job: say what to revoke by hand
        reason = exc.en if isinstance(exc, Failure) else f"{type(exc).__name__}: {exc}"
        report("warning", "Limpieza incompleta / Cleanup incomplete",
               f"La limpieza falló ({reason}). {MANUAL_REVOKE_ES}",
               f"Cleanup failed ({reason}). {MANUAL_REVOKE_EN}")
        return EXIT_OK


def _cleanup(args) -> int:
    cert_ids, profile_ids = [], []
    if args.state:
        state = {}
        try:
            with open(args.state, encoding="utf-8") as fh:
                state = json.load(fh)
        except FileNotFoundError:
            log(f"No state file at {args.state}: nothing was recorded there.")
        except (OSError, ValueError) as exc:
            report("warning", "state.json ilegible / unreadable",
                   f"No se pudo leer {args.state} ({exc}). {MANUAL_REVOKE_ES}",
                   f"Could not read {args.state} ({exc}). {MANUAL_REVOKE_EN}")
        if not isinstance(state, dict):
            state = {}
        if state.get("cert_id"):
            cert_ids.append(str(state["cert_id"]))
        profile_ids += [str(p) for p in state.get("profile_ids") or [] if p]
    cert_ids += [c for c in re.split(r"[,\s]+", args.cert_id or "") if c]
    profile_ids += [p for p in re.split(r"[,\s]+", args.profile_ids or "") if p]
    cert_ids, profile_ids = _unique(cert_ids), _unique(profile_ids)
    bad = [i for i in cert_ids + profile_ids if not RESOURCE_ID_RE.fullmatch(i)]
    cert_ids = [i for i in cert_ids if i not in bad]
    profile_ids = [i for i in profile_ids if i not in bad]
    if not cert_ids and not profile_ids and not bad:
        log("Nothing to clean up / nada que limpiar")
        append_summary("**Limpieza / cleanup:** nada que revocar / nothing to revoke.")
        return EXIT_OK
    client = Client(load_credentials())
    done, failed = [], [f"invalid id «{i}»" for i in bad]
    # Profiles first: they reference the certificate.
    for kind, template, ids in (("profile", "/v1/profiles/{}", profile_ids),
                                ("certificate", "/v1/certificates/{}", cert_ids)):
        for resource_id in ids:
            try:
                client.request("DELETE", template.format(resource_id))
                done.append(f"{kind} `{resource_id}`")
            except ApiError as err:
                if err.status == 404:
                    done.append(f"{kind} `{resource_id}` (ya no existía / already gone)")
                else:
                    failed.append(f"{kind} {resource_id}: {err.describe()}")
    if failed:
        listing = "; ".join(failed)
        report("warning", "Limpieza incompleta / Cleanup incomplete",
               f"No se pudo revocar o borrar: {listing}. {MANUAL_REVOKE_ES}",
               f"Could not revoke or delete: {listing}. {MANUAL_REVOKE_EN}")
    if done:
        append_summary("**Limpieza / cleanup:** revocado o borrado / revoked or deleted: "
                       + ", ".join(done) + ".")
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


def build_parser() -> argparse.ArgumentParser:
    parser = Parser(prog="asc.py", description="App Store Connect helper for the TestFlight workflow.")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("check-auth", help="check the API key (GET /v1/bundleIds)")
    p.set_defaults(func=cmd_check_auth)

    p = sub.add_parser("prepare", help="App IDs, capabilities, app record, next build number")
    p.add_argument("--prefix", required=True, help="bundle ID prefix, e.g. com.example")
    p.add_argument("--setup-only", action="store_true", help="register and explain; never ready")
    p.add_argument("--project-yml", default=os.path.join(REPO_ROOT, "project.yml"),
                   help=argparse.SUPPRESS)
    p.set_defaults(func=cmd_prepare)

    p = sub.add_parser("create-signing", help="distribution certificate + App Store profiles")
    p.add_argument("--app-bundle-resource-id", required=True, type=_resource_id)
    p.add_argument("--mirror-bundle-resource-id", required=True, type=_resource_id)
    p.add_argument("--app-bundle-id", required=True)
    p.add_argument("--mirror-bundle-id", required=True)
    p.add_argument("--app-group", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--suffix", default=os.environ.get("GITHUB_RUN_ID") or str(int(time.time())))
    p.set_defaults(func=cmd_create_signing)

    p = sub.add_parser("upload", help="upload an .ipa with the Build Upload API")
    p.add_argument("--ipa", required=True)
    p.add_argument("--app-id", required=True, type=_resource_id)
    p.add_argument("--version", required=True, help="CFBundleShortVersionString")
    p.add_argument("--build", required=True, help="CFBundleVersion")
    p.add_argument("--timeout-min", type=float, default=30)
    p.set_defaults(func=cmd_upload)

    p = sub.add_parser("wait-build", help="wait for processing, then set up internal testers")
    p.add_argument("--app-id", required=True, type=_resource_id)
    p.add_argument("--build", required=True)
    p.add_argument("--timeout-min", type=float, default=90)
    p.add_argument("--poll-sec", type=float, default=60)
    p.set_defaults(func=cmd_wait_build)

    p = sub.add_parser("cleanup", help="delete the profiles and revoke the certificate")
    p.add_argument("--state")
    p.add_argument("--cert-id")
    p.add_argument("--profile-ids")
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
