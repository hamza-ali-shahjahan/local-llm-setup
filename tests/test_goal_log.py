"""Stress tests for Goal Mode's learning / limits log.

Deterministic and offline: append + read run entirely against a temp file (we point the
server's GOAL_LOG there), no network, no API keys. We assert a pursued-goal record
round-trips with a server-stamped timestamp, the running count is correct, malformed
lines are skipped rather than crashing the read, the limit is honoured, and a missing
log reads as empty. This is the persistence behind forge -> agree -> pursue -> learn.
"""
import os, sys, tempfile, shutil, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server  # noqa: E402

AS = load_agent_server()


class GoalLogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="goallog_")
        self._orig = AS.GOAL_LOG
        AS.GOAL_LOG = os.path.join(self.tmp, "goal_runs.jsonl")   # never touch the real log

    def tearDown(self):
        AS.GOAL_LOG = self._orig
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_append_roundtrips_with_timestamp_and_count(self):
        rec = {"kind": "clone", "url": "https://example.com", "target": 75,
               "final_score": 68, "reached": False, "rounds": [{"round": 0, "score": 68}]}
        n = AS.append_goal_run(rec)
        self.assertEqual(n, 1)
        runs = AS.read_goal_runs()
        self.assertEqual(len(runs), 1)
        got = runs[0]
        self.assertEqual(got["kind"], "clone")
        self.assertEqual(got["final_score"], 68)
        self.assertEqual(got["reached"], False)
        self.assertIn("ts", got)                       # the server stamps the time
        self.assertIsInstance(got["ts"], int)

    def test_count_increments_and_order_preserved(self):
        for i in range(3):
            n = AS.append_goal_run({"kind": "build", "i": i})
            self.assertEqual(n, i + 1)
        runs = AS.read_goal_runs()
        self.assertEqual([r["i"] for r in runs], [0, 1, 2])

    def test_malformed_lines_are_skipped(self):
        AS.append_goal_run({"ok": 1})
        with open(AS.GOAL_LOG, "a", encoding="utf-8") as f:
            f.write("not json at all\n\n")            # a garbage line + a blank line
        AS.append_goal_run({"ok": 2})
        runs = AS.read_goal_runs()
        self.assertEqual([r["ok"] for r in runs], [1, 2])   # junk ignored, real records kept

    def test_read_honours_limit(self):
        for i in range(10):
            AS.append_goal_run({"i": i})
        runs = AS.read_goal_runs(limit=3)
        self.assertEqual([r["i"] for r in runs], [7, 8, 9])   # most recent 3

    def test_read_missing_file_is_empty(self):
        AS.GOAL_LOG = os.path.join(self.tmp, "does-not-exist.jsonl")
        self.assertEqual(AS.read_goal_runs(), [])


if __name__ == "__main__":
    unittest.main()
