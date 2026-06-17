"""Guard test — the builder is the source of truth at ~/.local-llm-setup, baked verbatim
into both installers by tools/bake.py. If they drift, a user's one-command install ships
stale code. `tools/bake.py --check` is the invariant; this test asserts it passes.
"""
import os, sys, subprocess, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server, REPO  # noqa: E402


class BakeInSyncTest(unittest.TestCase):
    def test_installers_embed_current_source(self):
        r = subprocess.run([sys.executable, os.path.join(REPO, "tools", "bake.py"), "--check"],
                           cwd=REPO, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, "bake drift:\n" + r.stdout + r.stderr)


class ServerSurfaceTest(unittest.TestCase):
    def test_tools_and_functions_present(self):
        AS = load_agent_server()
        for fn in ("screenshot", "git_sync", "find_browser", "_have_playwright",
                   "_png_dims", "_shot_playwright", "_shot_chrome"):
            self.assertTrue(hasattr(AS, fn), f"missing {fn}")

    def test_png_dims_helper(self):
        AS = load_agent_server()
        # 1x1 PNG IHDR -> width/height parse
        import struct, zlib
        ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
        png = (b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + ihdr +
               struct.pack(">I", zlib.crc32(b"IHDR" + ihdr) & 0xffffffff))
        self.assertEqual(AS._png_dims(png), (1, 1))
        self.assertEqual(AS._png_dims(b"not a png"), (0, 0))


if __name__ == "__main__":
    unittest.main()
