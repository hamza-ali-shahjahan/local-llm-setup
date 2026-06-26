"""Tests for the keyless web-search tool (FEATURE: web search).

Two layers, mirroring the rest of the suite:
  • The parsers (_parse_ddg / _parse_searxng) are pure and run against a saved fixture
    and a literal dict — deterministic, offline, no network. These guard the part most
    likely to break: DuckDuckGo's HTML shape and its redirect-URL wrapping.
  • The live DuckDuckGo round-trip is gated behind LLM_SEARCH_LIVE=1 (needs network),
    same pattern as the Visual-RAG live test, so CI/offline runs stay deterministic.

We import the dogfooded source of truth (~/.local-llm-setup/agent-server.py) that the
installers embed verbatim — test_bake.py asserts that invariant.
"""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server  # noqa: E402

AS = load_agent_server()
FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "ddg_results.html")


class DDGParseTest(unittest.TestCase):
    def setUp(self):
        with open(FIXTURE, encoding="utf-8") as f:
            self.html = f.read()

    def test_extracts_results_with_title_and_url(self):
        res = AS._parse_ddg(self.html, k=6)
        self.assertEqual(len(res), 4)
        self.assertEqual(res[0]["title"], "Python (programming language) — Example")
        self.assertEqual(res[0]["url"], "https://example.com/python")

    def test_redirect_urls_are_decoded_to_real_destination(self):
        # Every result URL must be the real site, never the DDG redirect wrapper.
        for r in AS._parse_ddg(self.html, k=6):
            self.assertNotIn("duckduckgo.com/l/", r["url"])
            self.assertTrue(r["url"].startswith("http"), r["url"])

    def test_snippets_are_captured(self):
        res = AS._parse_ddg(self.html, k=6)
        self.assertIn("high-level", res[0]["snippet"])
        self.assertTrue(all(r["snippet"] for r in res))

    def test_k_caps_the_result_count(self):
        self.assertEqual(len(AS._parse_ddg(self.html, k=2)), 2)
        self.assertEqual(len(AS._parse_ddg(self.html, k=1)), 1)

    def test_empty_html_is_safe(self):
        self.assertEqual(AS._parse_ddg("", k=5), [])
        self.assertEqual(AS._parse_ddg("<html><body>no results</body></html>", k=5), [])


class SearxngParseTest(unittest.TestCase):
    def test_maps_json_and_drops_urlless_rows(self):
        data = {"results": [
            {"title": "Alpha", "url": "https://a.example", "content": "first"},
            {"title": "Beta", "url": "https://b.example", "content": "second"},
            {"title": "no url here", "content": "should be dropped"},
        ]}
        res = AS._parse_searxng(data, k=6)
        self.assertEqual([r["url"] for r in res], ["https://a.example", "https://b.example"])
        self.assertEqual(res[0]["snippet"], "first")

    def test_handles_empty_or_missing(self):
        self.assertEqual(AS._parse_searxng({}, k=5), [])
        self.assertEqual(AS._parse_searxng({"results": []}, k=5), [])


class WebSearchGuardTest(unittest.TestCase):
    def test_empty_query_raises(self):
        with self.assertRaises(ValueError):
            AS.web_search("   ")


@unittest.skipUnless(os.environ.get("LLM_SEARCH_LIVE") == "1",
                     "set LLM_SEARCH_LIVE=1 to run the live DuckDuckGo round-trip")
class LiveSearchTest(unittest.TestCase):
    def test_real_query_returns_usable_results(self):
        out = AS.web_search("python programming language", k=5)
        self.assertGreaterEqual(out["count"], 1)
        self.assertEqual(out["provider"], "duckduckgo")
        top = out["results"][0]
        self.assertTrue(top["url"].startswith("http"))
        self.assertTrue(top["title"])


if __name__ == "__main__":
    unittest.main()
