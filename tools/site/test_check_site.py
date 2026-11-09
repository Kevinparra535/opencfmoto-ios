#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Tests for tools/site/check_site.py (standard library only, any OS).

Each test writes a small site that passes every check, breaks one thing and expects that problem; the
repository's own site/ must pass as it is.

usage: python3 tools/site/test_check_site.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import check_site  # noqa: E402

SOURCE = check_site.SOURCE
TESTFLIGHT = check_site.TESTFLIGHT
ENCODED = "https%3A%2F%2Fgithub.com%2FKevinparra535%2Fopencfmoto-ios%2Freleases%2Flatest%2Fdownload%2Faltstore-source.json"
SIDESTORE = "sidestore://source?url=" + ENCODED
ALTSTORE = "altstore-classic://source?url=" + ENCODED
FORBIDDEN = ("base", "iframe", "frame", "frameset", "object", "embed", "applet", "form")


def site_script() -> str:
    """The inline script of the repository's site/index.html, as check_site.Page collects it. The fixture
    carries it, so that it passes the ALLOWED_SCRIPT_SHA256 pin like the real page."""
    page = check_site.Page("index.html")
    with open(os.path.join(ROOT, "site", "index.html"), encoding="utf-8") as fh:
        page.feed(fh.read())
    page.close()
    if len(page.scripts) != 1:
        raise SystemExit(f"site/index.html has {len(page.scripts)} inline scripts; the test fixture expects 1")
    return page.scripts[0][0]


SCRIPT = site_script()

HEAD = """<!DOCTYPE html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<link rel="icon" href="{icon}">
<style>body {{ background: url("data:image/gif;base64,R0lGODlhAQABAAAAACw=") }}</style>
</head>
"""

INDEX = HEAD.format(lang="es", title="OpenCfMoto", icon="icon.png") + """<body>
<a href="#english">English</a>
<h1 id="inicio">OpenCfMoto para iPhone</h1>
<p><a href="{testflight}">Probar en TestFlight</a> <strong>testflight.apple.com/<wbr>join/<wbr>aWur6hxp</strong></p>
<div id="botones">
<a href="{sidestore}">Añadir a SideStore</a>
<a href="{altstore}">Añadir a AltStore</a>
</div>
<textarea id="fuente" readonly>{source}</textarea>
<button type="button" data-copy="fuente" hidden>Copiar</button>
<p><a href="https://github.com/Kevinparra535/opencfmoto-ios/releases/latest">IPA</a>
<a href="https://github.com/zanderp/open-cfmoto">Android</a> <a href="https://sidestore.io">SideStore</a>
<a href="https://apps.apple.com/app/localdevvpn/id6755608044">LocalDevVPN</a> <a href="mailto:someone@example.com">mail</a>
<a href="privacy/">privacidad</a> <a href="privacy/index.html#arriba">arriba</a></p>
<section id="english" lang="en"><section id="step-en"><p><a href="#botones">buttons</a> <a href="#inicio">top</a></p></section>
<p><a href="{testflight}">Try it on TestFlight</a> or open https://testflight.apple.com/join/aWur6hxp.</p>
<input id="source" readonly value="{source}"></section>
<script>@SITE_SCRIPT@</script>
</body>
</html>
""".format(sidestore=SIDESTORE, altstore=ALTSTORE, source=SOURCE, testflight=TESTFLIGHT).replace("@SITE_SCRIPT@", SCRIPT)

PRIVACY = HEAD.format(lang="es", title="Privacidad", icon="../icon.png").replace(
    "<title>", '<meta http-equiv="refresh" content="0; url=https://github.com/Kevinparra535/opencfmoto-ios/blob/main/PRIVACY.md">\n<title>') + """<body>
<h1 id="arriba">Privacidad</h1>
<p><a href="https://github.com/Kevinparra535/opencfmoto-ios/blob/main/PRIVACY.md">PRIVACY.md</a> <a href="../">inicio</a></p>
</body>
</html>
"""

NOT_FOUND = HEAD.format(lang="es", title="No encontrada", icon="/opencfmoto-ios/icon.png") + """<body>
<p><a href="/opencfmoto-ios/">Inicio</a> <a href="/opencfmoto-ios/#english">English</a> <a href="#top" id="top">↑</a></p>
</body>
</html>
"""


class CheckSiteTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="check-site-test-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.write("index.html", INDEX)
        self.write("privacy/index.html", PRIVACY)
        self.write("404.html", NOT_FOUND)
        self.write("icon.png", "\x89PNG fake")

    def write(self, rel, text, encoding="utf-8"):
        path = os.path.join(self.root, *rel.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding=encoding, newline="") as fh:  # the line ends as given, on any OS
            fh.write(text)

    def edit(self, rel, old, new, count=1):
        path = os.path.join(self.root, *rel.split("/"))
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        self.assertEqual(text.count(old), count, f"{old!r} in {rel}")
        self.write(rel, text.replace(old, new))

    def problems(self):
        return check_site.check_site(self.root)

    def line_of(self, rel, needle):
        """1-based line of the first line of rel that contains needle."""
        with open(os.path.join(self.root, *rel.split("/")), encoding="utf-8") as fh:
            for number, line in enumerate(fh, 1):
                if needle in line:
                    return number
        self.fail(f"{needle!r} not in {rel}")

    def assert_problem(self, needle, rel="index.html", count=1):
        problems = self.problems()
        found = [p for p in problems if needle in p.message and p.path == rel]
        self.assertEqual(len(found), count, f"{needle!r} in {rel}: {problems}")
        return found[0] if found else None

    # ------------------------------------------------------------ passing sites

    def test_the_fixture_passes(self):
        self.assertEqual(self.problems(), [])

    def test_the_repository_site_passes(self):
        site = os.path.join(ROOT, "site")
        self.assertTrue(os.path.isfile(os.path.join(site, "index.html")), site)
        self.assertEqual(check_site.check_site(site), [])

    def test_allowed_links_match_whole_path_segments(self):
        for url in ("https://github.com/Kevinparra535/opencfmoto-ios", "https://github.com/Kevinparra535/opencfmoto-ios/",
                    "https://github.com/Kevinparra535/opencfmoto-ios/blob/main/docs/INSTALAR.md#english",
                    "https://github.com/nab138/iloader", "https://docs.sidestore.io/docs/intro", "https://faq.altstore.io",
                    "https://sideloadly.io/"):
            self.assertTrue(check_site.allowed_https(url), url)
        for url in ("https://github.com/Kevinparra535/opencfmoto-ios-evil", "https://github.com/Kevinparra535",
                    "https://github.com/Kevinparra535/opencfmoto-ios/../evil",
                    "https://github.com/Kevinparra535/opencfmoto-ios/%2e%2e/evil", "http://github.com/Kevinparra535/opencfmoto-ios",
                    "https://evil@github.com/Kevinparra535/opencfmoto-ios", "https://github.com:8443/Kevinparra535/opencfmoto-ios",
                    "https://github.com:x/Kevinparra535/opencfmoto-ios", "https://sidestore.io.example.com/",
                    "https://altstore.example.com/", "https://example.com/"):
            self.assertFalse(check_site.allowed_https(url), url)

    # ------------------------------------------------------------ basics

    def test_doctype_lang_charset_viewport_title(self):
        self.edit("privacy/index.html", "<!DOCTYPE html>\n", "")
        self.edit("privacy/index.html", '<html lang="es">', "<html>")
        self.edit("privacy/index.html", '<meta charset="utf-8">', '<meta charset="iso-8859-1">')
        self.edit("privacy/index.html", '<meta name="viewport" content="width=device-width, initial-scale=1">', "")
        self.edit("privacy/index.html", "<title>Privacidad</title>", "<title> </title>")
        for needle in ("<!DOCTYPE html>", "<html lang", "<meta charset", "viewport", "non-empty <title>"):
            self.assert_problem(needle, "privacy/index.html")

    def test_not_utf8(self):
        self.write("privacy/index.html", PRIVACY.replace("Privacidad</h1>", "Privacidad ñ</h1>"), encoding="latin-1")
        self.assert_problem("not UTF-8", "privacy/index.html")

    def test_no_index(self):
        os.remove(os.path.join(self.root, "index.html"))
        problems = self.problems()
        self.assertTrue(any("the site has no index.html" in p.message for p in problems), problems)

    def test_duplicate_ids(self):
        self.edit("index.html", '<h1 id="inicio">', '<h1 id="botones">')
        self.edit("index.html", '<a href="#inicio">top</a>', '<a href="#botones">top</a>')
        problem = self.assert_problem("the id «botones» is used twice")
        self.assertEqual(problem.line, self.line_of("index.html", '<div id="botones">'), "reported where it repeats")

    # ------------------------------------------------------------ nothing loaded from elsewhere

    def test_scripts_from_elsewhere_or_with_network_access(self):
        self.edit("index.html", "</body>", '<script src="https://cdn.example.com/a.js"></script>\n</body>')
        self.assert_problem("<script src>: no external or separate scripts")
        self.assert_problem("<script src> loads «https://cdn.example.com/a.js» from elsewhere")

    def test_inline_script_network_and_navigation_apis(self):
        for code in ("fetch('https://example.com')", "new XMLHttpRequest()", "navigator.sendBeacon('/x')",
                     "new WebSocket('wss://x')", "import('https://x/m.js')", "document.write('<img>')",
                     "el.innerHTML = '<img>'", "img.src = 'https://x/p.gif'", "location = 'https://x'",
                     "window.open('https://x')", "eval('1')"):
            with self.subTest(code=code):
                self.setUp()
                self.edit("index.html", "</script>", code + "\n</script>")
                problems = [p for p in self.problems() if "the inline script uses" in p.message]
                self.assertTrue(problems, code)

    def test_the_inline_script_is_pinned(self):
        # SCRIPT_RISKS cannot see every way a script could load something: any script but the reviewed one
        # fails, and the problem gives the SHA-256 to put in ALLOWED_SCRIPT_SHA256 after the review.
        for code in ('document.body.setAttribute("src", "https://evil.example/x.png");',
                     'document.body.style.backgroundImage = "url(https://evil.example/x.png)";',
                     "var unused = 1;"):
            with self.subTest(code=code):
                self.setUp()
                self.edit("index.html", "</script>", code + "\n</script>")
                problem = self.assert_problem("the inline script changed")
                self.assertIn(check_site.script_sha256(SCRIPT + code + "\n"), problem.message)
                self.assertIn("ALLOWED_SCRIPT_SHA256", problem.message)
                self.assertEqual(problem.line, self.line_of("index.html", "<script>"))
                self.assertFalse([p for p in self.problems() if "the inline script uses" in p.message],
                                 "only the pin catches these")
        self.setUp()
        self.edit("index.html", "</body>", "<script>var second = 1;</script>\n</body>")
        self.assert_problem("the inline script changed")
        self.setUp()
        self.edit("index.html", "</body>", "<script></script>\n</body>")
        self.assert_problem("the inline script changed")
        # A checkout with \r\n line ends keeps the reviewed script's hash (the pages are read with universal
        # newlines).
        self.setUp()
        self.write("index.html", INDEX.replace("\n", "\r\n"))
        self.assertEqual(self.problems(), [])

    def test_resources_from_elsewhere(self):
        cases = (
            ('<img src="https://example.com/a.png" alt="">', "<img src> loads «https://example.com/a.png»"),
            ('<img src="//cdn.example.com/a.png" alt="">', "<img src> loads «//cdn.example.com/a.png»"),
            ('<img srcset="a.png 1x, https://example.com/b.png 2x" src="icon.png" alt="">', "<img srcset> loads"),
            ('<link rel="preload" as="image" href="icon.png" imagesrcset="https://evil.example/x.png 1x">',
             "<link imagesrcset> loads «https://evil.example/x.png»"),
            ('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">', "<link href> loads"),
            ("<style>@import url(https://example.com/a.css);</style>", "<style> @import loads"),
            ("<style>@import 'https://example.com/a.css';</style>", "<style> @import loads"),
            ('<style>@import"https://evil.example/a.css";</style>', "<style> @import loads «https://evil.example/a.css»"),
            ("<style>@import url(//evil.example/a.css);</style>", "<style> @import loads «//evil.example/a.css»"),
            ('<style>p { background-image: image-set("https://evil.example/x.png" 1x) }</style>',
             "<style> names «https://evil.example/x.png»"),
            ("<style>p { background-image: image-set('//evil.example/x.png' 1x) }</style>",
             "<style> names «//evil.example/x.png»"),
            ('<p style="background-image: image-set(&quot;HTTPS://evil.example/x.png&quot; 1x)">x</p>',
             "<p style> names «HTTPS://evil.example/x.png»"),
            ('<p style="background: url(http://example.com/a.png)">x</p>', "<p style> url() loads"),
            ('<svg><image href="https://example.com/a.png"/></svg>', "<image href> loads"),
            ('<svg><use xlink:href="https://example.com/s.svg#i"/></svg>', "<use href> loads «https://example.com/s.svg#i»"),
            ('<video poster="https://example.com/a.png"></video>', "<video poster> loads"),
            ('<table background="https://example.com/a.png"><tr><td>x</td></tr></table>', "<table background> loads"),
            ('<object data="https://example.com/a"></object>', "<object data> loads «https://example.com/a»"),
            ('<form action="https://example.com/"></form>', "<form action> loads «https://example.com/»"),
            ('<button formaction="https://example.com/">x</button>', "<button formaction> loads «https://example.com/»"),
        )
        for markup, needle in cases:
            with self.subTest(markup=markup):
                self.setUp()
                self.edit("index.html", "</body>", markup + "\n</body>")
                self.assert_problem(needle)

    def test_local_resources_must_exist(self):
        self.edit("index.html", 'href="icon.png"', 'href="missing.png"')
        self.assert_problem("<link href> «missing.png»: no such file in the site")

    def test_a_css_file_is_not_published(self):
        # A stylesheet next to the pages could @import anything (the check reads only the pages).
        self.write("x.css", "@import url(https://fonts.googleapis.com/css2?family=Inter);\n")
        problem = self.assert_problem("only .html pages and images are published: CSS and SVG go inline", "x.css")
        self.assertIn("a .css file", problem.message)

    def test_an_htm_file_is_not_published(self):
        # GitHub Pages serves extra.htm as a page, but the check reads only *.html.
        self.write("extra.htm", '<img src="https://example.com/a.png" alt="">\n')
        problem = self.assert_problem("only .html pages and images are published", "extra.htm")
        self.assertIn("a .htm file", problem.message)

    def test_only_pages_and_images_are_published(self):
        cases = (
            ("page.xhtml", "a .xhtml file"), ("app.js", "a .js file"), ("logo.svg", "a .svg file"),
            ("fonts/inter.woff2", "a .woff2 file"), ("CNAME", "a file without extension"),
            (".nojekyll", "a hidden file"), (".hidden.html", "a hidden file"), (".well-known/security.txt", "a hidden file"),
        )
        for rel, needle in cases:
            with self.subTest(rel=rel):
                self.setUp()
                self.write(rel, "x\n")
                problem = self.assert_problem("only .html pages and images are published", rel)
                self.assertIn(needle, problem.message)
        self.setUp()
        for rel in ("photo.jpg", "photo2.JPEG", "anim.gif", "pic.webp", "favicon.ico", "img/icon-2x.png"):
            self.write(rel, "fake image\n")
        self.assertEqual(self.problems(), [], "raster images are published as they are")

    def test_no_stylesheet_links(self):
        self.write("x.css", "p { color: red }\n")
        for markup in ('<link rel="stylesheet" href="x.css">', '<link rel="alternate STYLESHEET" href="x.css">'):
            with self.subTest(markup=markup):
                self.edit("index.html", "</head>", markup + "\n</head>")
                self.assert_problem("<link rel=stylesheet>: inline <style> only")
                self.edit("index.html", markup + "\n", "")

    def test_data_urls_must_be_images(self):
        self.edit("index.html", "</head>",
                  '<link rel="stylesheet" href="data:text/css,@import url(https://evil.example/a.css);">\n</head>')
        self.assert_problem("<link rel=stylesheet>: inline <style> only")
        self.assert_problem("<link href> «data:text/css,@import url(https://evil.example/a.css);»: a data: URL may "
                            "only be an image")
        cases = (
            '<img src="data:text/html,&lt;img src=https://evil.example/x.png&gt;" alt="">',
            '<link rel="icon" href="data:text/css,p{}">',
            '<p style="background: url(data:text/css,p{})">x</p>',
            '<img src="data:,x" alt="">',
            '<img src=" DATA:Text/HTML;base64,PHA+eDwvcD4=" alt="">',
        )
        for markup in cases:
            with self.subTest(markup=markup):
                self.setUp()
                self.edit("index.html", "</body>", markup + "\n</body>")
                self.assert_problem("a data: URL may only be an image (data:image/…)")
        self.setUp()
        self.edit("index.html", "</body>", '<img src="data:image/png;base64,iVBORw0KGgo=" alt="">\n'
                                           '<img src="DATA:IMAGE/SVG+XML,%3Csvg%2F%3E" alt="">\n</body>')
        self.assertEqual(self.problems(), [])

    def test_no_hyperlink_auditing_pings(self):
        for markup in ('<a href="#inicio" ping="https://tracker.example/p">x</a>',
                       '<a href="#inicio" attributionsrc="https://tracker.example/a">x</a>',
                       '<img src="icon.png" alt="" attributionsrc>', '<area href="#inicio" ping="/p">'):
            with self.subTest(markup=markup):
                self.setUp()
                self.edit("index.html", "</body>", markup + "\n</body>")
                self.assert_problem("no hyperlink-auditing pings")

    def test_every_forbidden_tag(self):
        self.assertEqual(set(FORBIDDEN), check_site.FORBIDDEN_TAGS, "every forbidden tag needs its case here")
        for tag in FORBIDDEN:
            with self.subTest(tag=tag):
                self.setUp()
                self.edit("index.html", "</body>", f"<{tag}></{tag}>\n</body>")
                self.assert_problem(f"<{tag}> is not allowed")

    def test_forbidden_tags_and_event_attributes(self):
        self.edit("index.html", "</body>", '<iframe title="x"></iframe><form></form>\n<p onclick="go()">x</p>\n</body>')
        self.assert_problem("<iframe> is not allowed")
        self.assert_problem("<form> is not allowed")
        self.assert_problem("no event attributes")

    # ------------------------------------------------------------ links

    def test_links_must_be_on_the_allow_list(self):
        cases = (
            ("https://example.com/", "is not on the allow-list"),
            ("http://github.com/Kevinparra535/opencfmoto-ios", "only #fragments"),
            ("https://github.com/Kevinparra535/opencfmoto-ios-evil", "is not on the allow-list"),
            ("javascript:alert(1)", "only #fragments"),
            ("altstore://source?url=" + ENCODED, "only #fragments"),
            ("altstore-pal://source?url=" + ENCODED, "only #fragments"),
            ("mailto:", "mailto: without an address"),
            ("", "is empty"),
        )
        for url, needle in cases:
            with self.subTest(url=url):
                self.setUp()
                self.edit("index.html", '<a href="https://sidestore.io">', f'<a href="{url}">')
                self.assert_problem(needle)

    def test_add_source_links(self):
        cases = (
            ("sidestore://source?url=https%3A%2F%2Fexample.com%2Fsource.json", "not the release source"),
            ("sidestore://source?url=" + SOURCE, "must be percent-encoded"),
            ("sidestore://source?url=" + ENCODED + "&x=1", "exactly one query item"),
            ("sidestore://source?URL=" + ENCODED, "exactly one query item"),
            ("sidestore://install?url=" + ENCODED, "must be sidestore://source"),
            ("sidestore://source/x?url=" + ENCODED, "must be sidestore://source"),
            ("sidestore://source?url=" + ENCODED + "#x", "must be sidestore://source"),
        )
        for url, needle in cases:
            with self.subTest(url=url):
                self.setUp()
                self.edit("index.html", SIDESTORE, url)
                self.assert_problem(needle)

    def test_each_add_source_link_exactly_once(self):
        self.edit("index.html", '<a href="#botones">buttons</a>', f'<a href="{ALTSTORE}">AltStore</a>')
        self.assert_problem("the altstore-classic://source link must be on the page exactly once, found 2")
        self.edit("index.html", f'<a href="{SIDESTORE}">Añadir a SideStore</a>', "")
        self.assert_problem("the sidestore://source link must be on the page exactly once, found 0")

    def test_the_testflight_link_is_the_public_beta(self):
        # TESTFLIGHT exactly: a mistyped join code, or any other testflight.apple.com page, fails.
        cases = (
            "https://testflight.apple.com/join/aWur6hxq",  # one character off
            "https://testflight.apple.com/join/AWUR6HXP",  # join codes are case-sensitive
            "https://testflight.apple.com/join/aWur6hx",
            "https://testflight.apple.com/join/aWur6hxp/",
            "https://testflight.apple.com/join/aWur6hxp?ref=site",
            "https://testflight.apple.com/join/aWur6hxp#x",
            "https://testflight.apple.com/join/",
            "https://testflight.apple.com/",
            "https://testflight.apple.com",
            "https://testflight.apple.com/v1/app/1234567890",
            "https://TestFlight.Apple.com/join/aWur6hxp",
            "https://someone@testflight.apple.com/join/aWur6hxp",
            "https://testflight.apple.com:443/join/aWur6hxp",
        )
        for url in cases:
            with self.subTest(url=url):
                self.setUp()
                self.edit("index.html", '<a href="https://sidestore.io">', f'<a href="{url}">')
                problem = self.assert_problem(f"<a href> «{url}»: the only TestFlight link allowed is the public beta "
                                              f"{TESTFLIGHT}")
                self.assertEqual(problem.line, self.line_of("index.html", f'"{url}"'))
        # Other pages too; and the other ways to reach TestFlight are not links these pages may carry.
        self.setUp()
        self.edit("404.html", '<a href="#top" id="top">', '<a href="https://testflight.apple.com/join/aWur6hxq" id="top">')
        self.assert_problem("the only TestFlight link allowed is the public beta", "404.html")
        for url in ("http://testflight.apple.com/join/aWur6hxp", "itms-beta://testflight.apple.com/join/aWur6hxp",
                    "https://beta.testflight.apple.com/join/aWur6hxp"):
            with self.subTest(url=url):
                self.setUp()
                self.edit("index.html", '<a href="https://sidestore.io">', f'<a href="{url}">')
                problems = self.problems()
                self.assertEqual(len(problems), 1, problems)
                self.assertIn(f"«{url}»", problems[0].message)
        # The pinned link passes anywhere, as often as the pages need it.
        self.setUp()
        self.edit("404.html", '<a href="#top" id="top">', f'<a href="{TESTFLIGHT}" id="top">')
        self.edit("index.html", '<a href="https://sidestore.io">', f'<a href="{TESTFLIGHT}">')
        self.assertEqual(self.problems(), [])

    def test_a_printed_testflight_address_is_the_public_beta(self):
        # For people reading on a computer: the address they type on the iPhone. <wbr> splits it in pieces.
        cases = (
            ("testflight.apple.com/<wbr>join/<wbr>aWur6hxq", "testflight.apple.com/join/aWur6hxq"),
            ("TESTFLIGHT.apple.com/join/<wbr>aWur6hxQ", "TESTFLIGHT.apple.com/join/aWur6hxQ"),
            ("testflight.apple.com/<wbr>join", "testflight.apple.com/join"),
            ("testflight.apple.com/<wbr>join/<wbr>aWur6hxp/x", "testflight.apple.com/join/aWur6hxp/x"),
        )
        for printed, shown in cases:
            with self.subTest(printed=printed):
                self.setUp()
                self.edit("index.html", "testflight.apple.com/<wbr>join/<wbr>aWur6hxp", printed)
                problem = self.assert_problem(f"the page shows the address «{shown}», not the public TestFlight beta "
                                              f"{TESTFLIGHT}")
                self.assertEqual(problem.line, self.line_of("index.html", printed))
        self.setUp()
        self.edit("404.html", "</p>", " https://testflight.apple.com/join/aWur6hxq</p>")
        self.assert_problem("the page shows the address «testflight.apple.com/join/aWur6hxq»", "404.html")
        # The pinned address passes with or without https:// and before punctuation; the bare host is no address.
        self.setUp()
        self.edit("404.html", "</p>", " (https://testflight.apple.com/join/aWur6hxp), TestFlight: testflight.apple.com.</p>")
        self.assertEqual(self.problems(), [])

    def test_index_links_the_testflight_beta_in_both_languages(self):
        self.edit("index.html", f'<a href="{TESTFLIGHT}">Try it on TestFlight</a>', "")
        problem = self.assert_problem(f"no link to the public TestFlight beta {TESTFLIGHT} in the English part")
        self.assertEqual(problem.line, self.line_of("index.html", '<section id="english"'))
        self.assertFalse([p for p in self.problems() if "in the Spanish part" in p.message])
        self.setUp()
        self.edit("index.html", f'<a href="{TESTFLIGHT}">Probar en TestFlight</a>', "")
        self.assert_problem(f"no link to the public TestFlight beta {TESTFLIGHT} in the Spanish part")
        self.assertFalse([p for p in self.problems() if "in the English part" in p.message])
        # After the English part ends, a link is Spanish again: the English part has none.
        self.setUp()
        self.edit("index.html", f'<a href="{TESTFLIGHT}">Try it on TestFlight</a>', "")
        self.edit("index.html", "<script>", f'<p><a href="{TESTFLIGHT}">TestFlight</a></p>\n<script>')
        self.assert_problem("in the English part")
        # A second link inside the English part does not stand in for the Spanish one. (The fixture's English link
        # comes after a <section> nested in the English one, so the fixture passing shows that it still counts.)
        self.setUp()
        self.edit("index.html", f'<a href="{TESTFLIGHT}">Probar en TestFlight</a>', "")
        self.edit("index.html", '<section id="step-en">', f'<a href="{TESTFLIGHT}">x</a><section id="step-en">')
        self.assert_problem("in the Spanish part")

    def test_local_links_and_fragments(self):
        cases = (
            ('<a href="#nowhere">x</a>', "no id «nowhere» on this page"),
            ('<a href="privacy/index.html#nowhere">x</a>', "no id «nowhere» in privacy/index.html"),
            ('<a href="missing.html">x</a>', "no such file in the site"),
            ('<a href="docs/">x</a>', "no such folder in the site"),
            ('<a href="../../etc/passwd">x</a>', "points outside the site"),
            ('<a href="/other-site/">x</a>', "root-relative path outside the site"),
        )
        for markup, needle in cases:
            with self.subTest(markup=markup):
                self.setUp()
                self.edit("index.html", "</body>", markup + "\n</body>")
                self.assert_problem(needle)

    def test_root_relative_and_folder_links(self):
        self.edit("index.html", "</body>", '<a href="/opencfmoto-ios/privacy/">p</a> <a href="/opencfmoto-ios">i</a>'
                                           ' <a href="privacy">p</a> <a href="./">i</a>\n</body>')
        self.assertEqual(self.problems(), [])
        os.makedirs(os.path.join(self.root, "empty"))
        self.edit("index.html", "</body>", '<a href="empty/">e</a>\n</body>')
        self.assert_problem("a folder without index.html")

    def test_404_links_must_be_root_relative(self):
        self.edit("404.html", 'href="/opencfmoto-ios/icon.png"', 'href="icon.png"')
        self.edit("404.html", '<a href="/opencfmoto-ios/">', '<a href="index.html">')
        self.assert_problem("<link href> «icon.png»: 404.html is served at any depth", "404.html")
        self.assert_problem("<a href> «index.html»: 404.html is served at any depth", "404.html")

    def test_meta_refresh(self):
        self.edit("privacy/index.html", "url=https://github.com/Kevinparra535/opencfmoto-ios/blob/main/PRIVACY.md",
                  "url=https://example.com/privacy")
        self.assert_problem("<meta http-equiv=refresh> «https://example.com/privacy» is not on the allow-list",
                            "privacy/index.html")
        self.edit("privacy/index.html", 'content="0; url=https://example.com/privacy"', 'content="soon"')
        self.assert_problem("needs content=", "privacy/index.html")

    # ------------------------------------------------------------ index.html

    def test_index_languages(self):
        self.edit("index.html", '<html lang="es">', '<html lang="en">')
        self.assert_problem('<html lang="en">: the page is Spanish first')
        self.edit("index.html", '<section id="english" lang="en">', '<section id="english">')
        self.assert_problem('the id="english" element needs lang="en"')
        self.edit("index.html", '<section id="english">', "<section>")
        self.edit("index.html", '<a href="#english">English</a>', "")
        self.assert_problem('no id="english" section')

    def test_index_source_field(self):
        self.edit("index.html", f"<textarea id=\"fuente\" readonly>{SOURCE}</textarea>",
                  "<textarea id=\"fuente\">x</textarea>")
        self.edit("index.html", f'<input id="source" readonly value="{SOURCE}">', '<input id="source" value="x">')
        self.assert_problem("no read-only field")
        self.setUp()
        self.edit("index.html", f'<input id="source" readonly value="{SOURCE}">',
                  '<input id="source" readonly value="https://github.com/Kevinparra535/opencfmoto-ios/releases/download/'
                  'v0.1.0/altstore-source.json">')
        self.assert_problem("a field shows «https://github.com/Kevinparra535/opencfmoto-ios/releases/download/v0.1.0/")
        self.setUp()
        self.edit("index.html", f"<textarea id=\"fuente\" readonly>{SOURCE}</textarea>",
                  f"<textarea id=\"fuente\" readonly>\n{SOURCE}</textarea>")
        self.assertEqual(self.problems(), [], "the newline right after <textarea> is not part of the value")

    def test_a_field_without_readonly_does_not_count(self):
        # The field still shows SOURCE; only readonly is missing (the other field is gone).
        self.edit("index.html", f'<textarea id="fuente" readonly>{SOURCE}</textarea>',
                  f'<textarea id="fuente">{SOURCE}</textarea>')
        self.edit("index.html", f'<input id="source" readonly value="{SOURCE}">', "")
        self.assert_problem("no read-only field")
        self.setUp()
        self.edit("index.html", f'<input id="source" readonly value="{SOURCE}">', f'<input id="source" value="{SOURCE}">')
        self.edit("index.html", f'<textarea id="fuente" readonly>{SOURCE}</textarea>', "")
        self.assert_problem("no read-only field")

    # ------------------------------------------------------------ command line

    def test_command_line(self):
        def run(*args):
            return subprocess.run([sys.executable, "-I", os.path.join(HERE, "check_site.py"), *args],
                                  capture_output=True, text=True, timeout=60, cwd=self.root)
        ok = run(".")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("3 page(s) OK", ok.stdout)
        self.assertIn(f"TestFlight link {TESTFLIGHT}", ok.stdout)
        self.edit("index.html", '<a href="https://sidestore.io">', '<a href="https://example.com/">')
        bad = run(".")
        self.assertEqual(bad.returncode, 1, bad.stdout + bad.stderr)
        line = self.line_of("index.html", "https://example.com/")
        self.assertIn(f"::error file=./index.html,line={line},title=Site check::<a href> «https://example.com/» is not "
                      "on the allow-list", bad.stdout)
        self.assertIn("1 problem(s)", bad.stdout)
        usage = run(os.path.join(self.root, "missing"))
        self.assertEqual(usage.returncode, 2, usage.stdout + usage.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
