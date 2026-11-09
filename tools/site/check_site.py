#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Checks the GitHub Pages landing page (site/) before it is deployed. Standard library only.

usage: check_site.py [--base /opencfmoto-ios/] SITE_DIR

Every file under SITE_DIR is an .html page or a raster image (IMAGE_EXTENSIONS): no CSS, JavaScript, SVG,
font, .htm or hidden file is published (CSS and SVG go inline in the pages). Every SITE_DIR/**/*.html must:
- be UTF-8 with <!DOCTYPE html>, parse (html.parser), and have <html lang="…">, <meta charset="utf-8">, a
  viewport <meta> (width=device-width) and a non-empty <title>;
- load nothing from another site: src, srcset, imagesrcset, poster, background and data of every element,
  every <link href> and the href of other non-link elements (SVG <image>, <use>), and @import / url(…) in
  <style> and in style="…" are relative or data:image/… only, and no quoted string in that CSS is an absolute
  or protocol-relative URL (image-set("https://…")); no <link rel=stylesheet>, <script src>, <base>,
  <iframe>, <frame>, <object>, <embed>, <applet>, <form>; no on…="…" event attributes, no ping= or
  attributionsrc= (hyperlink-auditing pings); every inline script is a reviewed one (its SHA-256 is in
  ALLOWED_SCRIPT_SHA256) and uses no network or navigation API (fetch, XMLHttpRequest, sendBeacon,
  WebSocket, EventSource, Worker, import(), eval, innerHTML, location, …);
- link (<a> / <area> href, <meta http-equiv="refresh"> url) only to: a #fragment of the page, a relative path
  that exists under SITE_DIR (and its #fragment), mailto:, an https URL on ALLOWED_LINKS, exactly TESTFLIGHT
  (the public TestFlight beta: any other testflight.apple.com URL, a mistyped join code too, is an error), or
  the SideStore / AltStore Classic add-source links (sidestore://source?url=…, altstore-classic://source?url=…)
  whose url is exactly SOURCE, percent-encoded: AltStore and SideStore identify a source by its URL;
- print a testflight.apple.com/… address (for people reading on a computer) only as TESTFLIGHT's, with or
  without https://, and a «<host>/join/<code>» address only on testflight.apple.com (a mistyped or lookalike
  host fails);
- 404.html: relative references only root-relative ("/opencfmoto-ios/…"): GitHub Pages serves it at any depth.
The site's index.html also: <html lang="es">, an id="english" element with lang="en", each add-source link
exactly once, a link to TESTFLIGHT and its printed address (testflight.apple.com/join/…, the text people type
on the iPhone) both in the Spanish part (outside id="english") and in the English part, and a read-only field
(<textarea readonly> or <input readonly>) showing exactly SOURCE: the copy button needs JavaScript, the field
does not.

Exit 0 when everything passes; 1 with one ::error annotation per problem; 2 on usage errors.
"""
from __future__ import annotations

import argparse
import hashlib
import html.parser
import os
import posixpath
import re
import sys
import urllib.parse

SOURCE = "https://github.com/Kevinparra535/opencfmoto-ios/releases/latest/download/altstore-source.json"
DEEP_LINK_SCHEMES = ("sidestore", "altstore-classic")
# The public TestFlight beta (the owner's link): the only testflight.apple.com URL the pages may carry, so that
# a mistyped join code fails the check instead of sending riders to someone else's beta or to an error page.
TESTFLIGHT = "https://testflight.apple.com/join/aWur6hxp"
TESTFLIGHT_HOST = "testflight.apple.com"
# A testflight.apple.com/… address printed as text: the path ends at the first character a join code never has.
TESTFLIGHT_TEXT = re.compile(r"testflight\.apple\.com(/[A-Za-z0-9/_-]*)", re.IGNORECASE)
# Any «<host>/join/<code>» address printed as text: its host must be TESTFLIGHT_HOST, so that a mistyped or lookalike
# host (testflight.aple.com, testflight-apple.com) fails instead of sending people who type it to another site.
PRINTED_JOIN = re.compile(r"([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)/join/[A-Za-z0-9]*", re.IGNORECASE)
DEFAULT_BASE = "/opencfmoto-ios/"

# https links the pages may carry: (host, path prefix). The prefix matches whole path segments, so
# /Kevinparra535/opencfmoto-ios covers …/opencfmoto-ios/releases but not …/opencfmoto-ios-other.
ALLOWED_LINKS = (
    ("github.com", "/Kevinparra535/opencfmoto-ios"),
    ("github.com", "/zanderp/open-cfmoto"),
    ("github.com", "/nab138/iloader"),
    ("sidestore.io", "/"),
    ("docs.sidestore.io", "/"),
    ("altstore.io", "/"),
    ("faq.altstore.io", "/"),
    ("sideloadly.io", "/"),
    ("apps.apple.com", "/"),
)

# Besides the .html pages, the only files the site may publish (the icon): no CSS, script, SVG or font files.
IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico")

# The reviewed inline scripts (the copy buttons of site/index.html): the SHA-256 of the text between <script>
# and </script> (pages are read with universal newlines, so a \r\n checkout hashes the same). Any other script
# fails the check, so a change to it gets a review: read the new script, then put the SHA-256 the check prints
# here.
ALLOWED_SCRIPT_SHA256 = {
    "f651ff1c66054f35dd04c7c9564a0473fa4b6c3e6f00180a83d458bc4205f0e3",  # site/index.html: the copy buttons
}

FORBIDDEN_TAGS = {"base", "iframe", "frame", "frameset", "object", "embed", "applet", "form"}
NAVIGATION_TAGS = {"a", "area"}
RESOURCE_ATTRIBUTES = {"src", "poster", "background", "data", "action", "formaction"}
SRCSET_ATTRIBUTES = {"srcset", "imagesrcset"}
PING_ATTRIBUTES = {"ping", "attributionsrc"}
SCRIPT_RISKS = re.compile(
    r"\b(?:fetch|XMLHttpRequest|sendBeacon|WebSocket|EventSource|SharedWorker|Worker|importScripts|eval|Function"
    r"|location|innerHTML|outerHTML|insertAdjacentHTML)\b|\bimport\s*\(|document\s*\.\s*write|\.\s*(?:src|srcset|href)\b"
    r"|\bopen\s*\(")
CSS_URL = re.compile(r"""url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)""", re.IGNORECASE)
# @import "x.css", @import'x.css', @import url(x.css): minified CSS writes no space after @import.
CSS_IMPORT = re.compile(r"""@import\s*(?:url\(\s*)?["']?([^"')\s;]*)""", re.IGNORECASE)
# A quoted CSS string that is an absolute or protocol-relative URL: image-set("https://…" 1x) and the like.
CSS_QUOTED_URL = re.compile(r"""["']\s*((?:[a-z][a-z0-9+.-]*:)?//[^"']*)""", re.IGNORECASE)
REFRESH_URL = re.compile(r"""^\s*\d+(?:\.\d*)?\s*[;,]\s*url\s*=\s*["']?([^"']*)["']?\s*$""", re.IGNORECASE)


class Problem:
    def __init__(self, path: str, line: int, message: str):
        self.path, self.line, self.message = path, line, message

    def annotation(self, shown_root: str) -> str:
        where = posixpath.join(shown_root, self.path) if shown_root else self.path
        text = self.message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        return f"::error file={where},line={self.line},title=Site check::{text}"

    def __repr__(self) -> str:
        return f"{self.path}:{self.line}: {self.message}"


class Page(html.parser.HTMLParser):
    """One HTML file: what the checks need, with line numbers."""

    def __init__(self, rel: str):
        super().__init__(convert_charrefs=True)
        self.rel = rel
        self.doctype = False
        self.html_lang = None
        self.charset = False
        self.viewport = False
        self.title = None
        self.ids: dict = {}            # id / <a name> -> first line
        self.duplicate_ids: list = []  # (id, line)
        self.english_lang = None       # lang of the id="english" element; "" when it has none
        self.navigation: list = []     # (url, line, what, english): english = inside the id="english" element
        self.resources: list = []      # (url, line, what)
        self.text: list = []           # the text outside <title>, <script>, <style>, <textarea>: (data, line, english)
        self.scripts: list = []        # (code, line)
        self.styles: list = []         # (css, line, what)
        self.readonly_values: list = []  # read-only <input value> / <textarea> text: (value, line)
        self.field_values: list = []   # every <input value> / <textarea> text: (value, line)
        self.problems: list = []
        self._stack_text = None        # "title" / "script" / "style" / "textarea" while inside one
        self._readonly = False         # the open <textarea> is read-only
        self._buffer: list = []
        self._buffer_line = 0
        self._english_tag = None       # the tag of the id="english" element while inside it
        self._english_depth = 0        # open elements with that tag name since it began (it included)

    # ------------------------------------------------------------ parser callbacks

    def handle_decl(self, decl):
        if decl.strip().lower() == "doctype html":
            self.doctype = True

    def handle_starttag(self, tag, attrs):
        line = self.getpos()[0]
        values: dict = {}
        for name, value in attrs:
            values.setdefault(name, value)
        if self._english_depth:
            if tag == self._english_tag:
                self._english_depth += 1
        elif values.get("id") == "english":
            self._english_tag, self._english_depth = tag, 1
        english = self._english_depth > 0
        if tag in FORBIDDEN_TAGS:
            self.problem(line, f"<{tag}> is not allowed on these pages")
        if tag == "link" and "stylesheet" in (values.get("rel") or "").lower().split():
            self.problem(line, "<link rel=stylesheet>: inline <style> only")
        for name, value in attrs:
            if name.startswith("on"):
                self.problem(line, f"<{tag} {name}=…>: no event attributes; put the code in the inline script")
            if name in PING_ATTRIBUTES:
                self.problem(line, f"<{tag} {name}>: no hyperlink-auditing pings")
            if name == "id" and value:
                self.add_id(value, line)
            if name in RESOURCE_ATTRIBUTES and value is not None:
                self.resources.append((value, line, f"<{tag} {name}>"))
            if name in SRCSET_ATTRIBUTES and value:
                for candidate in value.split(","):
                    url = candidate.strip().split(" ")[0] if candidate.strip() else ""
                    if url:
                        self.resources.append((url, line, f"<{tag} {name}>"))
            if name == "style" and value:
                self.styles.append((value, line, f"<{tag} style>"))
        href = values.get("href", values.get("xlink:href"))
        if href is not None:
            if tag in NAVIGATION_TAGS:
                self.navigation.append((href, line, f"<{tag} href>", english))
            else:
                self.resources.append((href, line, f"<{tag} href>"))
        if tag == "a" and values.get("name"):
            self.add_id(values["name"], line)
        if tag == "html":
            self.html_lang = (values.get("lang") or "").strip()
        elif tag == "meta":
            if values.get("charset") is not None:
                self.charset = values["charset"].strip().lower() == "utf-8"
            if (values.get("name") or "").lower() == "viewport" and "width=device-width" in (values.get("content") or "").replace(" ", ""):
                self.viewport = True
            if (values.get("http-equiv") or "").lower() == "refresh":
                match = REFRESH_URL.match(values.get("content") or "")
                if match:
                    self.navigation.append((match.group(1).strip(), line, "<meta http-equiv=refresh>", english))
                else:
                    self.problem(line, "<meta http-equiv=refresh> needs content=\"0; url=…\"")
        elif tag == "script":
            if values.get("src") is not None:
                self.problem(line, "<script src>: no external or separate scripts, only a small inline one")
            self.start_text("script", line)
        elif tag in ("title", "style", "textarea"):
            self.start_text(tag, line)
            self._readonly = tag == "textarea" and "readonly" in values
        elif tag == "input":
            value = values.get("value")
            if value is not None:
                self.field_values.append((value, line))
                if "readonly" in values:
                    self.readonly_values.append((value, line))
        if values.get("id") == "english":
            self.english_lang = (values.get("lang") or "").strip()

    def handle_endtag(self, tag):
        if self._english_depth and tag == self._english_tag:
            self._english_depth -= 1
        if self._stack_text == tag:
            text = "".join(self._buffer)
            if tag == "title":
                self.title = text.strip()
            elif tag == "script":
                self.scripts.append((text, self._buffer_line))
            elif tag == "style":
                self.styles.append((text, self._buffer_line, "<style>"))
            elif tag == "textarea":
                # The HTML parser drops one newline right after <textarea>; so does this check.
                text = text[2:] if text.startswith("\r\n") else text[1:] if text.startswith("\n") else text
                self.field_values.append((text, self._buffer_line))
                if self._readonly:
                    self.readonly_values.append((text, self._buffer_line))
            self._stack_text = None
            self._buffer = []

    def handle_data(self, data):
        if self._stack_text:
            self._buffer.append(data)
        else:
            self.text.append((data, self.getpos()[0], self._english_depth > 0))

    # ------------------------------------------------------------ helpers

    def start_text(self, tag, line):
        self._stack_text = tag
        self._buffer = []
        self._buffer_line = line

    def add_id(self, value, line):
        if value in self.ids:
            self.duplicate_ids.append((value, line))
        else:
            self.ids[value] = line

    def problem(self, line, message):
        self.problems.append(Problem(self.rel, line, message))


def is_local(url: str) -> bool:
    """A relative reference (no scheme, no host) or data: — nothing fetched from another site."""
    parts = urllib.parse.urlsplit(url.strip())
    if parts.scheme:
        return parts.scheme.lower() == "data"
    return not parts.netloc and not url.strip().startswith("//")


def script_sha256(code: str) -> str:
    """The SHA-256 ALLOWED_SCRIPT_SHA256 lists for an inline script's text."""
    return hashlib.sha256(code.encode("utf-8")).hexdigest()


def allowed_https(url: str) -> bool:
    parts = urllib.parse.urlsplit(url)
    try:
        port = parts.port
    except ValueError:
        return False
    if parts.scheme != "https" or parts.username or parts.password or port is not None:
        return False
    host = (parts.hostname or "").lower()
    # What the browser opens: percent-decoded, dot segments resolved (…/opencfmoto-ios/../x is not ours).
    path = posixpath.normpath(urllib.parse.unquote(parts.path or "/"))
    path = "/" + path.lstrip("/")
    for allowed_host, prefix in ALLOWED_LINKS:
        if host != allowed_host:
            continue
        if prefix == "/" or path == prefix or path.startswith(prefix.rstrip("/") + "/"):
            return True
    return False


def deep_link_problem(url: str):
    """None when url is <scheme>://source?url=<SOURCE percent-encoded>, else the reason."""
    parts = urllib.parse.urlsplit(url)
    if parts.netloc != "source" or parts.path or parts.fragment:
        return f"must be {parts.scheme}://source?url=… (the add-source link)"
    items = urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
    if len(items) != 1 or items[0][0] != "url":
        return "needs exactly one query item: url=<the source URL, percent-encoded>"
    if items[0][1] != SOURCE:
        return f"its url is «{items[0][1]}», not the release source {SOURCE}"
    if parts.query != "url=" + urllib.parse.quote(SOURCE, safe=""):
        return "its url must be percent-encoded (encodeURIComponent): url=" + urllib.parse.quote(SOURCE, safe="")
    return None


class Site:
    def __init__(self, root: str, base: str = DEFAULT_BASE):
        self.root = root
        self.base = "/" + base.strip("/") + "/" if base.strip("/") else "/"
        self.pages: dict = {}
        self.problems: list = []

    def problem(self, rel, line, message):
        self.problems.append(Problem(rel, line, message))

    # ------------------------------------------------------------ files

    def load(self):
        for directory, dirs, files in os.walk(self.root):
            dirs.sort()
            for name in sorted(files):
                path = os.path.join(directory, name)
                rel = os.path.relpath(path, self.root).replace(os.sep, "/")
                extension = posixpath.splitext(name)[1].lower()
                hidden = any(part.startswith(".") for part in rel.split("/"))
                if hidden or extension not in (".html",) + IMAGE_EXTENSIONS:
                    kind = ("a hidden file" if hidden else f"a {extension} file" if extension
                            else "a file without extension")
                    self.problem(rel, 1, f"{kind}: only .html pages and images are published: CSS and SVG go inline")
                    continue
                if extension != ".html":
                    continue  # an image (the icon)
                try:
                    with open(path, encoding="utf-8") as fh:
                        text = fh.read()
                except UnicodeDecodeError:
                    self.problem(rel, 1, "not UTF-8")
                    continue
                page = Page(rel)
                try:
                    page.feed(text)
                    page.close()
                except Exception as exc:  # html.parser seldom raises, but never let it pass silently
                    self.problem(rel, page.getpos()[0], f"does not parse: {exc}")
                    continue
                self.pages[rel] = page
        if "index.html" not in self.pages:
            self.problem("index.html", 1, "the site has no index.html")

    def target(self, rel: str, path: str):
        """The site file a relative reference opens (posix, relative to the site), or (None, reason)."""
        decoded = urllib.parse.unquote(path)
        if decoded.startswith("/"):
            if decoded in (self.base, self.base.rstrip("/")):
                inside = ""
            elif decoded.startswith(self.base):
                inside = decoded[len(self.base):]
            else:
                return None, f"root-relative path outside the site ({self.base})"
        else:
            inside = posixpath.join(posixpath.dirname(rel), decoded)
        wants_directory = decoded == "" or decoded.endswith("/") or decoded.endswith("/.") or decoded in (".", "..")
        normal = posixpath.normpath(inside) if inside else "."
        if normal == ".." or normal.startswith("../") or normal.startswith("/"):
            return None, "points outside the site"
        normal = "" if normal == "." else normal
        full = os.path.join(self.root, *normal.split("/")) if normal else self.root
        if os.path.isdir(full):
            index = posixpath.join(normal, "index.html") if normal else "index.html"
            if os.path.isfile(os.path.join(self.root, *index.split("/"))):
                return index, None
            return None, "a folder without index.html"
        if wants_directory:
            return None, "no such folder in the site"
        if os.path.isfile(full):
            return normal, None
        return None, "no such file in the site"

    # ------------------------------------------------------------ checks

    def check(self):
        self.load()
        for rel, page in sorted(self.pages.items()):
            self.problems.extend(page.problems)
            self.check_basics(rel, page)
            for url, line, what in page.resources:
                self.check_resource(rel, url, line, what)
            for css, line, what in page.styles:
                for match in CSS_URL.finditer(css):
                    url = next(g for g in match.groups() if g is not None)
                    self.check_resource(rel, url, line, f"{what} url()")
                for match in CSS_IMPORT.finditer(css):
                    self.check_resource(rel, match.group(1), line, f"{what} @import")
                for match in CSS_QUOTED_URL.finditer(css):
                    self.problem(rel, line, f"{what} names «{match.group(1)}»: no quoted URL of another site in CSS "
                                            f"(image-set(), @import, …)")
            for code, line in page.scripts:
                for match in SCRIPT_RISKS.finditer(code):
                    self.problem(rel, line, f"the inline script uses «{match.group(0)}»: it may only copy text")
                digest = script_sha256(code)
                if digest not in ALLOWED_SCRIPT_SHA256:
                    self.problem(rel, line, f"the inline script changed (SHA-256 {digest}): review it, then update "
                                            f"ALLOWED_SCRIPT_SHA256 in tools/site/check_site.py")
            for url, line, what, _english in page.navigation:
                self.check_link(rel, page, url, line, what)
            for value, line in page.field_values:
                if "altstore-source.json" in value and value.strip() != SOURCE:
                    self.problem(rel, line, f"a field shows «{value}», not the release source {SOURCE}")
            self.check_printed_testflight(rel, page)
        index = self.pages.get("index.html")
        if index is not None:
            self.check_index(index)
        return self.problems

    def check_basics(self, rel, page):
        if not page.doctype:
            self.problem(rel, 1, "needs <!DOCTYPE html> (without it browsers use quirks mode)")
        if not page.html_lang:
            self.problem(rel, 1, "needs <html lang=\"…\">")
        if not page.charset:
            self.problem(rel, 1, "needs <meta charset=\"utf-8\">")
        if not page.viewport:
            self.problem(rel, 1, "needs <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
        if not page.title:
            self.problem(rel, 1, "needs a non-empty <title>")
        for value, line in page.duplicate_ids:
            self.problem(rel, line, f"the id «{value}» is used twice")

    def check_resource(self, rel, url, line, what):
        if not is_local(url):
            self.problem(rel, line, f"{what} loads «{url}» from elsewhere: use a file under site/ or data:image/…")
            return
        url = url.strip()
        if url.lower().startswith("data:"):
            # data:text/css or data:text/html could carry their own @import / <img src>: images only.
            media = url[5:].split(",", 1)[0].split(";", 1)[0].strip().lower()
            if not media.startswith("image/"):
                shown = url if len(url) <= 60 else url[:59] + "…"
                self.problem(rel, line, f"{what} «{shown}»: a data: URL may only be an image (data:image/…)")
            return
        self.check_local(rel, url, line, what, page=None)

    def check_local(self, rel, url, line, what, page):
        parts = urllib.parse.urlsplit(url)
        if rel == "404.html" and parts.path and not parts.path.startswith("/"):
            self.problem(rel, line, f"{what} «{url}»: 404.html is served at any depth, so its links must be "
                                    f"root-relative ({self.base}…)")
            return
        if not parts.path:
            if page is not None and parts.fragment and parts.fragment not in page.ids:
                self.problem(rel, line, f"{what} «{url}»: no id «{parts.fragment}» on this page")
            return
        target, reason = self.target(rel, parts.path)
        if target is None:
            self.problem(rel, line, f"{what} «{url}»: {reason}")
            return
        if parts.fragment and target in self.pages and parts.fragment not in self.pages[target].ids:
            self.problem(rel, line, f"{what} «{url}»: no id «{parts.fragment}» in {target}")

    def check_link(self, rel, page, url, line, what):
        url = url.strip()
        if not url:
            self.problem(rel, line, f"{what} is empty")
            return
        parts = urllib.parse.urlsplit(url)
        scheme = parts.scheme.lower()
        if not scheme and not parts.netloc and not url.startswith("//"):
            self.check_local(rel, url, line, what, page)
        elif scheme == "mailto":
            if not parts.path:
                self.problem(rel, line, f"{what} «{url}»: mailto: without an address")
        elif scheme == "https":
            if (parts.hostname or "").lower() == TESTFLIGHT_HOST:
                if url != TESTFLIGHT:
                    self.problem(rel, line, f"{what} «{url}»: the only TestFlight link allowed is the public beta "
                                            f"{TESTFLIGHT} (tools/site/check_site.py TESTFLIGHT)")
            elif not allowed_https(url):
                self.problem(rel, line, f"{what} «{url}» is not on the allow-list (tools/site/check_site.py ALLOWED_LINKS)")
        elif scheme in DEEP_LINK_SCHEMES:
            reason = deep_link_problem(url)
            if reason:
                self.problem(rel, line, f"{what} «{url}»: {reason}")
        else:
            self.problem(rel, line, f"{what} «{url}»: only #fragments, site paths, mailto:, allowed https links "
                                    f"and the {' / '.join(s + '://source' for s in DEEP_LINK_SCHEMES)} links")

    def check_printed_testflight(self, rel, page):
        """A testflight.apple.com/… address printed for people reading on a computer is TESTFLIGHT's, and so is the
        host of any printed «<host>/join/<code>» address. The text is joined first: <wbr> splits the printed address
        into several pieces."""
        text, starts, offset = "", [], 0
        for data, line, _english in page.text:
            starts.append((offset, line))
            text += data
            offset += len(data)
        expected = urllib.parse.urlsplit(TESTFLIGHT).path
        wrong = [(match.start(), match.group(0)) for match in TESTFLIGHT_TEXT.finditer(text) if match.group(1) != expected]
        # Another host: testflight.apple.com's own addresses are TESTFLIGHT_TEXT's (one problem each).
        wrong += [(match.start(), match.group(0)) for match in PRINTED_JOIN.finditer(text)
                  if match.group(1).lower() != TESTFLIGHT_HOST]
        for position, shown in sorted(wrong):
            line = next(line for start, line in reversed(starts) if start <= position)
            self.problem(rel, line, f"the page shows the address «{shown}», not the public TestFlight beta "
                                    f"{TESTFLIGHT} (tools/site/check_site.py TESTFLIGHT)")

    def check_index(self, page):
        rel = page.rel
        if page.html_lang and page.html_lang != "es":
            self.problem(rel, 1, f"<html lang=\"{page.html_lang}\">: the page is Spanish first, lang=\"es\"")
        if "english" not in page.ids:
            self.problem(rel, 1, "no id=\"english\" section (the English half, linked from the top)")
        elif page.english_lang != "en":
            self.problem(rel, page.ids["english"], "the id=\"english\" element needs lang=\"en\"")
        for scheme in DEEP_LINK_SCHEMES:
            lines = [line for url, line, _what, _english in page.navigation
                     if urllib.parse.urlsplit(url.strip()).scheme.lower() == scheme]
            if len(lines) != 1:
                where = f" (lines {', '.join(map(str, lines))})" if lines else ""
                self.problem(rel, lines[1] if len(lines) > 1 else 1,
                             f"the {scheme}://source link must be on the page exactly once, found {len(lines)}{where}")
        if not any(value == SOURCE for value, _ in page.readonly_values):
            self.problem(rel, 1, f"no read-only field (<textarea readonly> or <input readonly value=…>) showing exactly "
                                 f"{SOURCE}")
        # The public TestFlight beta, in both languages: the English half has its own button.
        testflight = [english for url, _line, _what, english in page.navigation if url.strip() == TESTFLIGHT]
        if False not in testflight:
            self.problem(rel, 1, f"no link to the public TestFlight beta {TESTFLIGHT} in the Spanish part (outside "
                                 f"id=\"english\")")
        if "english" in page.ids and True not in testflight:
            self.problem(rel, page.ids["english"], f"no link to the public TestFlight beta {TESTFLIGHT} in the English "
                                                   f"part (id=\"english\")")
        # Its address printed in each part, for people reading on a computer (they type it on the iPhone), exactly
        # like the read-only field shows SOURCE: an empty or mistyped printed address fails.
        printed = TESTFLIGHT.split("://", 1)[1]
        spanish_text = "".join(data for data, _line, in_english in page.text if not in_english)
        if printed not in spanish_text:
            self.problem(rel, 1, f"the Spanish part (outside id=\"english\") does not show the address {printed} "
                                 f"(the text people reading on a computer type on the iPhone)")
        english_text = "".join(data for data, _line, in_english in page.text if in_english)
        if "english" in page.ids and printed not in english_text:
            self.problem(rel, page.ids["english"], f"the English part (id=\"english\") does not show the address "
                                                   f"{printed} (the text people reading on a computer type on the "
                                                   f"iPhone)")


def check_site(root: str, base: str = DEFAULT_BASE) -> list:
    """Every problem of the site in root (empty when it passes)."""
    return Site(root, base).check()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("site", help="the folder GitHub Pages publishes (site)")
    parser.add_argument("--base", default=DEFAULT_BASE, help=f"the site's path on github.io (default {DEFAULT_BASE})")
    args = parser.parse_args(argv)
    if not os.path.isdir(args.site):
        parser.error(f"{args.site} is not a folder")
    problems = check_site(args.site, args.base)
    shown = args.site.replace(os.sep, "/").rstrip("/")
    for p in problems:
        print(p.annotation(shown), flush=True)
    pages = sum(1 for _d, _s, files in os.walk(args.site) for f in files if f.lower().endswith(".html"))
    if problems:
        print(f"site check: {len(problems)} problem(s) in {pages} page(s)", flush=True)
        return 1
    print(f"site check: {pages} page(s) OK (no external requests, links allowed, add-source links to {SOURCE}, "
          f"TestFlight link {TESTFLIGHT})", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
