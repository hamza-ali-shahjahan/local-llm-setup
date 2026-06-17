"""Stress tests for the website-cloning DEPTH upgrade (Phases 1-3).

All offline and bounded: every page is a local HTML fixture rendered via
Playwright's set_content() — no network, no SSRF, no API keys. We prove the three
things the upgrade promises:

  Phase 1 — a JS-RENDERED page (content built by an inline <script>) actually
            reads. The raw stdlib parse sees an empty shell; the browser render
            surfaces the headings, sections, computed colours and fonts.
  Phase 2 — motion (@keyframes / animations / transitions), hover interaction
            states, responsive breakpoints and a framework guess are captured.
  Phase 3 — fidelity() scores motion + design tokens, so a clone that drops the
            animations and radius/shadow tokens is docked below a perfect match.
"""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server  # noqa: E402

AS = load_agent_server()
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
HAVE_PLAYWRIGHT = AS._have_playwright()


def read_fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return f.read()


def render_digest(html, deep=True):
    """Mirror digest(url) without the network: render the HTML in the browser,
    parse the RENDERED markup with the same _Digest, and merge browser tokens."""
    _rhtml, data = AS._inspect_html_via_browser(html, deep=deep)
    d = AS._Digest("")
    try: d.feed(_rhtml)
    except Exception: pass
    out = AS._build_digest(d, "")
    AS._merge_rendered(out, data)
    out["rendered"] = True
    return out


@unittest.skipUnless(HAVE_PLAYWRIGHT, "render-based inspect needs the Playwright backend")
class Phase1RenderTests(unittest.TestCase):
    """The raw parse misses everything; the rendered parse sees the real page."""

    def test_raw_parse_is_blind_to_js_content(self):
        # Parsing the RAW fixture (no JS executed) finds no real content — this is
        # exactly why the old urllib path failed on sites like disrupt.com.
        raw = read_fixture("js_app.html")
        d = AS._Digest("")
        d.feed(raw)
        out = AS._build_digest(d, "")
        self.assertEqual(out["headings"], [], "raw HTML has no rendered headings")
        # only the empty <div id=root> shell is present — none of the real sections
        section_ids = {s.get("id") for s in out["sections"]}
        self.assertNotIn("features", section_ids)
        self.assertNotIn("pricing", section_ids)
        self.assertEqual(out["palette"], [], "no colours without the rendered CSS")

    def test_rendered_parse_sees_headings_and_sections(self):
        out = render_digest(read_fixture("js_app.html"))
        texts = " ".join(h["text"] for h in out["headings"])
        self.assertIn("Disrupt the status quo", texts)
        self.assertIn("Features", texts)
        self.assertGreaterEqual(len(out["sections"]), 3, "hero + features + pricing sections")
        self.assertGreater(out["visible_elements"], 5)
        self.assertTrue(out["rendered"])

    def test_rendered_palette_and_fonts_are_computed(self):
        out = render_digest(read_fixture("js_app.html"))
        # the brand pink is applied as a background -> appears as a computed rgb()
        joined = " ".join(out["palette"]).lower()
        self.assertIn("233, 30, 99", joined, "brand #e91e63 -> rgb(233, 30, 99)")
        self.assertIn("inter", " ".join(out["fonts"]).lower())


@unittest.skipUnless(HAVE_PLAYWRIGHT, "motion/state capture needs the Playwright backend")
class Phase2DepthTests(unittest.TestCase):
    """Motion language, interaction states, responsive + framework detection."""

    def setUp(self):
        self.out = render_digest(read_fixture("js_app.html"))

    def test_keyframes_and_transitions_captured(self):
        motion = self.out["motion"]
        self.assertIn("floaty", [k.lower() for k in motion.get("keyframes", [])])
        anim = " ".join(motion.get("animations", [])).lower()
        self.assertIn("floaty", anim)
        self.assertTrue(motion.get("transitions"), "the .btn background transition should be seen")

    def test_design_tokens_captured(self):
        t = self.out["tokens"]
        self.assertTrue(any("px" in r for r in t["radii"]), "border-radius tokens (18px / 8px)")
        self.assertTrue(t["shadows"], "the hero box-shadow should be captured")
        self.assertTrue(t["font_sizes"], "a type scale should be captured")

    def test_hover_state_delta_captured(self):
        # .btn:hover flips the background to the brand pink — a real computed delta.
        changes = [c for s in self.out["states"] for c in [s.get("hover_changes", {})] if "bg" in c]
        self.assertTrue(changes, "at least one element must report a hover background change")

    def test_responsive_breakpoints_probed(self):
        r = self.out["responsive"]
        self.assertTrue(set(r.keys()) & {"390", "768", "1280"}, "breakpoints were measured")
        for sig in r.values():
            self.assertIn("scrollW", sig)


@unittest.skipUnless(HAVE_PLAYWRIGHT, "fidelity-with-motion needs the Playwright backend")
class Phase3FidelityTests(unittest.TestCase):
    """fidelity() now weights motion + tokens, not just palette/fonts/sections."""

    @classmethod
    def setUpClass(cls):
        cls.orig = render_digest(read_fixture("js_app.html"))
        cls.partial = render_digest(read_fixture("clone_partial.html"))

    def test_perfect_self_match_scores_full(self):
        f = AS.fidelity(self.orig, self.orig)
        self.assertEqual(f["score"], 100)
        self.assertEqual(f["motion_match"], 100)
        self.assertEqual(f["token_match"], 100)

    def test_partial_clone_is_docked_for_missing_motion(self):
        f = AS.fidelity(self.orig, self.partial)
        self.assertEqual(f["motion_match"], 0, "the clone dropped every @keyframe/animation")
        self.assertIn("floaty", f["missing_animations"])
        self.assertLess(f["token_match"], 100, "radius/shadow tokens were dropped too")
        self.assertLess(f["score"], 100, "an incomplete clone must not score perfect")
        # but it still gets real credit for the structure/colours it DID match
        self.assertGreaterEqual(f["palette_match"], 50)

    def test_score_keys_backward_compatible(self):
        f = AS.fidelity(self.orig, self.partial)
        for k in ("score", "palette_match", "font_match", "section_coverage",
                  "heading_match", "missing_colors", "missing_fonts"):
            self.assertIn(k, f)


if __name__ == "__main__":
    unittest.main()
