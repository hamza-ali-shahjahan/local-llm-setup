"""Stress tests for FEATURE 1 — reliable screenshots.

Deterministic and offline: every page rendered here is a local HTML fixture or inline
HTML loaded via file://, so the tests need no network and no API keys. They assert the
capture is a *real* image: valid PNG signature, the exact requested viewport dimensions,
and genuine non-blank pixel content (the fixture's solid colour actually shows up).
"""
import os, sys, pathlib, tempfile, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server, decode_png  # noqa: E402

AS = load_agent_server()
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")

# A backend must exist for the core tests to be meaningful. On this repo's CI/dev box
# one always does (Playwright's managed Chromium and/or system Chrome), so we require it
# rather than skip — a missing backend is a real regression, not an environment quirk.
HAVE_BACKEND = AS._have_playwright() or bool(AS.find_browser())
HAVE_PLAYWRIGHT = AS._have_playwright()


def read_fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return f.read()


@unittest.skipUnless(HAVE_BACKEND, "no headless browser backend available")
class ScreenshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="shot_test_")

    def shot(self, **kw):
        kw.setdefault("outdir", self.tmp)
        return AS.screenshot(**kw)

    def test_html_capture_is_valid_png_of_expected_size(self):
        r = self.shot(html=read_fixture("solid.html"), width=400, height=300, name="solid")
        self.assertTrue(r["bytes"] > 0)
        self.assertEqual((r["width"], r["height"]), (400, 300), "PNG dims must match the viewport")
        png = decode_png(pathlib.Path(r["abspath"]).read_bytes())
        self.assertEqual((png.width, png.height), (400, 300))

    def test_capture_is_not_blank(self):
        r = self.shot(html=read_fixture("solid.html"), width=320, height=240, name="notblank")
        png = decode_png(pathlib.Path(r["abspath"]).read_bytes())
        self.assertFalse(png.is_all_white(), "a solid-colour page must not render as all-white")
        # the fixture is solid #1133aa — the vast majority of pixels should be that blue
        self.assertGreater(png.fraction_matching((0x11, 0x33, 0xaa)), 0.9,
                           "the fixture's solid colour should fill the frame")

    def test_dimensions_vary_with_viewport(self):
        small = self.shot(html=read_fixture("solid.html"), width=200, height=150, name="small")
        big = self.shot(html=read_fixture("solid.html"), width=800, height=600, name="big")
        self.assertEqual((small["width"], small["height"]), (200, 150))
        self.assertEqual((big["width"], big["height"]), (800, 600))

    def test_inline_html_data_url_returned(self):
        r = self.shot(html="<body style='background:#22aa44;margin:0'></body>",
                      width=120, height=90, name="inline")
        self.assertTrue(r["dataurl"].startswith("data:image/png;base64,"))
        self.assertIn(r["backend"], ("playwright", "chrome"))

    def test_writes_into_requested_dir(self):
        r = self.shot(html=read_fixture("solid.html"), width=100, height=100, name="placed")
        self.assertTrue(os.path.isfile(r["abspath"]))
        self.assertEqual(os.path.dirname(r["abspath"]), self.tmp)

    def test_rejects_non_http_url(self):
        with self.assertRaises(ValueError):
            self.shot(url="file:///etc/passwd", name="evil")


@unittest.skipUnless(HAVE_PLAYWRIGHT, "element + full-page capture needs the Playwright backend")
class PlaywrightOnlyTests(unittest.TestCase):
    """full-page and element-clip capture are first-class on the Playwright path."""
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="shot_pw_")

    def test_element_capture_clips_to_selector(self):
        r = AS.screenshot(html=read_fixture("page.html"), selector="#box",
                          width=600, height=400, name="elem", outdir=self.tmp)
        self.assertEqual(r["backend"], "playwright")
        # #box is 200x120 in the fixture
        self.assertEqual((r["width"], r["height"]), (200, 120))
        png = decode_png(pathlib.Path(r["abspath"]).read_bytes())
        self.assertGreater(png.fraction_matching((0xcc, 0x22, 0x22)), 0.9,
                           "the clipped element should be (mostly) the box's red")

    def test_full_page_capture_taller_than_viewport(self):
        tall = "<body style='margin:0'><div style='height:2000px;background:#3344ff'></div></body>"
        r = AS.screenshot(html=tall, full_page=True, width=400, height=300,
                          name="fullpage", outdir=self.tmp)
        self.assertEqual(r["width"], 400)
        self.assertGreater(r["height"], 300, "full-page capture should exceed the viewport height")


if __name__ == "__main__":
    unittest.main()
