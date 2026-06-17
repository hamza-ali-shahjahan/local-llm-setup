"""Stress tests for FEATURE 2 — local git sync.

Deterministic and offline: everything runs in a temp dir, no network, no remote. We
assert a real git repo is produced with exactly the expected single commit, a correct
.gitignore (node_modules etc. actually ignored), and a .zip export that includes the
.git history. The optional remote is only *configured*, never pushed — verified here.
"""
import os, sys, pathlib, shutil, subprocess, tempfile, zipfile, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server  # noqa: E402

AS = load_agent_server()
HAVE_GIT = shutil.which("git") is not None


def git(args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


@unittest.skipUnless(HAVE_GIT, "git is not installed")
class GitSyncTests(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="gitsync_base_")
        self.proj_name = "my-app"
        self.proj = os.path.join(self.base, self.proj_name)
        os.makedirs(self.proj)
        # a few realistic project files, plus things that MUST be ignored
        self._write("index.html", "<h1>hi</h1>")
        self._write("app.js", "console.log('hi')")
        self._write("README.md", "# my app")
        self._write(".env", "SECRET=should-not-be-committed")
        self._write(os.path.join("node_modules", "left-pad", "index.js"), "module.exports=1")
        self._write("debug.log", "noisy log line")

    def tearDown(self):
        shutil.rmtree(self.base, ignore_errors=True)

    def _write(self, rel, content):
        p = os.path.join(self.proj, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(content)

    def sync(self, **kw):
        kw.setdefault("base", self.base)
        kw.setdefault("path", self.proj_name)
        kw.setdefault("deterministic", True)
        return AS.git_sync(**kw)

    def test_creates_real_repo_with_one_commit(self):
        r = self.sync(message="scaffold: initial commit")
        self.assertTrue(os.path.isdir(os.path.join(self.proj, ".git")))
        self.assertTrue(r["initialized"])
        self.assertTrue(r["commit_made"])
        self.assertEqual(r["commits_total"], 1, "should be exactly one commit")
        # the reported hash is the real HEAD
        head = git(["rev-parse", "HEAD"], self.proj).stdout.strip()
        self.assertEqual(r["commit"], head)
        self.assertEqual(git(["log", "-1", "--pretty=%s"], self.proj).stdout.strip(),
                         "scaffold: initial commit")
        self.assertEqual(r["branch"], "main")
        # working tree clean after commit
        self.assertEqual(git(["status", "--porcelain"], self.proj).stdout.strip(), "")

    def test_gitignore_written_and_effective(self):
        r = self.sync()
        gi = os.path.join(self.proj, ".gitignore")
        self.assertTrue(r["gitignore_written"])
        self.assertTrue(os.path.isfile(gi))
        body = pathlib.Path(gi).read_text(encoding="utf-8")
        for pat in ("node_modules/", ".env", "*.log"):
            self.assertIn(pat, body)
        tracked = set(git(["ls-files"], self.proj).stdout.split())
        # source files tracked
        self.assertIn("index.html", tracked)
        self.assertIn("app.js", tracked)
        self.assertIn(".gitignore", tracked)
        # ignored things NOT tracked
        self.assertNotIn(".env", tracked)
        self.assertNotIn("debug.log", tracked)
        self.assertFalse(any(t.startswith("node_modules/") for t in tracked),
                         "node_modules must not be committed")

    def test_export_zip_includes_git_history(self):
        r = self.sync()
        self.assertIsNotNone(r["zip_path"])
        self.assertTrue(os.path.isfile(r["zip_path"]))
        self.assertGreater(r["zip_bytes"], 0)
        with zipfile.ZipFile(r["zip_path"]) as z:
            names = z.namelist()
        self.assertIn("index.html", names)
        self.assertTrue(any(n.startswith(".git/") for n in names),
                        "the export must include the .git history")
        # restoring the zip yields a working repo on the same commit
        restore = tempfile.mkdtemp(prefix="gitsync_restore_")
        try:
            with zipfile.ZipFile(r["zip_path"]) as z:
                z.extractall(restore)
            self.assertEqual(git(["rev-parse", "HEAD"], restore).stdout.strip(), r["commit"])
        finally:
            shutil.rmtree(restore, ignore_errors=True)

    def test_deterministic_commit_hash_is_reproducible(self):
        a = self.sync()
        # wipe and rebuild identical content -> identical commit hash (pinned author/dates)
        shutil.rmtree(self.proj)
        os.makedirs(self.proj)
        self._write("index.html", "<h1>hi</h1>")
        self._write("app.js", "console.log('hi')")
        self._write("README.md", "# my app")
        self._write(".env", "SECRET=should-not-be-committed")
        self._write(os.path.join("node_modules", "left-pad", "index.js"), "module.exports=1")
        self._write("debug.log", "noisy log line")
        b = self.sync()
        self.assertEqual(a["commit"], b["commit"],
                         "same content + pinned identity/date must reproduce the hash")

    def test_idempotent_second_run_makes_no_empty_commit(self):
        self.sync()
        again = self.sync()
        self.assertFalse(again["initialized"])
        self.assertFalse(again["commit_made"], "no changes -> no new commit")
        self.assertEqual(again["commits_total"], 1)

    def test_remote_is_configured_but_never_pushed(self):
        r = self.sync(remote="https://github.com/example/repo.git")
        self.assertTrue(r["remote_set"])
        self.assertEqual(git(["remote", "get-url", "origin"], self.proj).stdout.strip(),
                         "https://github.com/example/repo.git")
        # the tool never pushes — there is no upstream tracking branch / no push ref
        self.assertIn("origin", r["push_hint"])
        self.assertEqual(git(["rev-parse", "--symbolic-full-name", "@{u}"], self.proj).returncode, 128,
                         "no upstream should be set (nothing was pushed)")

    def test_does_not_clobber_existing_gitignore(self):
        existing = "custom-ignore/\n"
        with open(os.path.join(self.proj, ".gitignore"), "w") as f:
            f.write(existing)
        r = self.sync()
        self.assertFalse(r["gitignore_written"])
        self.assertEqual(pathlib.Path(self.proj, ".gitignore").read_text(), existing)

    def test_rejects_path_escape(self):
        with self.assertRaises(ValueError):
            AS.git_sync(path="../../etc", base=self.base)


if __name__ == "__main__":
    unittest.main()
