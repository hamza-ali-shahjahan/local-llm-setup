"""Tests for local deploy (FEATURE: one-click local deploy).

Deterministic and offline: deploy() persists an app and serves it on an ephemeral
127.0.0.1 port; we fetch the real URL, assert the content, then stop it and assert the
server is gone. No network, no cloud. Imports the dogfooded source of truth that the
installers embed verbatim (test_bake guards that invariant).
"""
import os, sys, urllib.request, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server  # noqa: E402

AS = load_agent_server()


def _get(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


class SlugTest(unittest.TestCase):
    def test_slug_sanitises(self):
        self.assertEqual(AS._slug("My Cool App!!"), "my-cool-app")
        self.assertEqual(AS._slug("  spaced  out  "), "spaced-out")
        self.assertEqual(AS._slug(""), "app")
        self.assertEqual(AS._slug("a" * 100), "a" * 48)


class DeployTest(unittest.TestCase):
    def tearDown(self):
        for slug in list(getattr(AS, "_DEPLOYS", {}).keys()):
            AS.deploy_stop(slug)

    def test_deploy_serves_then_stops(self):
        res = AS.deploy("Deploy Test One", html="<h1>hello deploy</h1>")
        self.assertTrue(res["ok"])
        self.assertTrue(res["url"].startswith("http://127.0.0.1:"), res["url"])
        self.assertFalse(res["lan"])
        self.assertIn("hello deploy", _get(res["url"]))

        listed = AS.deploys_list()
        self.assertTrue(any(d["slug"] == res["slug"] for d in listed["deploys"]))

        stopped = AS.deploy_stop(res["slug"])
        self.assertTrue(stopped["stopped"])
        with self.assertRaises(Exception):      # connection refused after shutdown
            _get(res["url"], timeout=2)

    def test_redeploy_same_name_replaces_content(self):
        AS.deploy("dup-app", html="<p>one</p>")
        second = AS.deploy("dup-app", html="<p>two</p>")
        self.assertIn("two", _get(second["url"]))
        # only one server for that slug
        self.assertEqual(sum(d["slug"] == second["slug"] for d in AS.deploys_list()["deploys"]), 1)

    def test_empty_deploy_raises(self):
        with self.assertRaises(Exception):
            AS.deploy("nothing-to-serve-xyz")   # no html, no path -> nothing to serve

    def test_stop_unknown_is_safe(self):
        out = AS.deploy_stop("never-deployed-zzz")
        self.assertFalse(out["stopped"])


if __name__ == "__main__":
    unittest.main()
