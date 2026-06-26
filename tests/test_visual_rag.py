"""Visual RAG tests — the lean, Ollama-native retrieval added to the agent server.

The retrieval CORE is tested deterministically with hand-provided vectors, so these run
with no Ollama and no network: cosine math, the SQLite store roundtrip (incl. float32
vector packing), ranking order, list/clear, and the model-selection rules (an embedding
model is chosen — never a chat model — and Visual RAG only reports "ready" when both an
embedder and a vision model are present).

The end-to-end path against real local models (render-free: caption → embed → retrieve)
is exercised by LiveTest, gated behind LLM_RAG_LIVE=1 so default/CI runs stay hermetic.
"""
import os, sys, tempfile, shutil, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server, REPO  # noqa: E402

AS = load_agent_server()


class CosineTest(unittest.TestCase):
    def test_known_values(self):
        self.assertAlmostEqual(AS._cos([1, 0], [1, 0]), 1.0, places=6)
        self.assertAlmostEqual(AS._cos([1, 0], [0, 1]), 0.0, places=6)
        self.assertAlmostEqual(AS._cos([1, 0], [-1, 0]), -1.0, places=6)
        self.assertAlmostEqual(AS._cos([1, 2, 3], [2, 4, 6]), 1.0, places=6)  # scale-invariant

    def test_degenerate(self):
        self.assertEqual(AS._cos([], [1]), 0.0)         # empty
        self.assertEqual(AS._cos([1, 2], [1]), 0.0)     # mismatched length
        self.assertEqual(AS._cos([0, 0], [1, 1]), 0.0)  # zero vector


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ragtest_")
        self._orig = AS.RAG_DIR
        AS.RAG_DIR = self.tmp

    def tearDown(self):
        AS.RAG_DIR = self._orig
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_roundtrip_and_float32_vectors(self):
        db = AS._rag_db("col")
        AS._rag_add(db, "doc-a", 0, "a red bar chart", [1.0, 0.0, 0.0], b"\x89PNG-a", 12, 34, "em", "vm")
        AS._rag_add(db, "doc-b", 1, "a data table", [0.0, 1.0, 0.0], b"", 0, 0, "em", "vm")
        db.close()
        rows = AS._rag_rows(AS._rag_db("col"), with_png=True)
        self.assertEqual(len(rows), 2)
        a = next(r for r in rows if r["source"] == "doc-a")
        self.assertEqual([round(x, 4) for x in a["vec"]], [1.0, 0.0, 0.0])  # survives pack/unpack
        self.assertEqual(a["png"], b"\x89PNG-a")
        self.assertEqual(a["page"], 0)

    def test_ranking_picks_nearest(self):
        db = AS._rag_db("rank")
        AS._rag_add(db, "bars", 0, "", [1.0, 0.0, 0.0], b"", 0, 0, "e", "v")
        AS._rag_add(db, "pie", 0, "", [0.0, 1.0, 0.0], b"", 0, 0, "e", "v")
        AS._rag_add(db, "table", 0, "", [0.0, 0.0, 1.0], b"", 0, 0, "e", "v")
        db.close()
        rows = AS._rag_rows(AS._rag_db("rank"))
        ranked = sorted(rows, key=lambda r: AS._cos([0.9, 0.1, 0.0], r["vec"]), reverse=True)
        self.assertEqual(ranked[0]["source"], "bars")

    def test_list_and_clear(self):
        db = AS._rag_db("lc")
        AS._rag_add(db, "s", 0, "cap", [1.0], b"", 1, 1, "e", "v")
        db.close()
        self.assertEqual(AS.rag_list("lc")["count"], 1)
        self.assertEqual(AS.rag_list("lc")["tiles"][0]["source"], "s")
        self.assertEqual(AS.rag_clear("lc")["cleared"], 1)
        self.assertEqual(AS.rag_list("lc")["count"], 0)

    def test_collection_name_is_sanitised(self):
        # a path-traversal-y collection name must not escape RAG_DIR
        AS._rag_db("../../evil").close()
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "..", "..", "evil.db")))
        self.assertTrue(any(f.endswith(".db") for f in os.listdir(self.tmp)))


class ModelSelectionTest(unittest.TestCase):
    def setUp(self):
        self._orig = AS._ollama_models
        AS._ollama_models = lambda: ["qwen2.5-coder:14b", "deepseek-r1:14b",
                                     "nomic-embed-text:latest", "qwen2.5vl:7b"]
        self._origdir = AS.RAG_DIR
        AS.RAG_DIR = tempfile.mkdtemp(prefix="ragstatus_")

    def tearDown(self):
        AS._ollama_models = self._orig
        shutil.rmtree(AS.RAG_DIR, ignore_errors=True)
        AS.RAG_DIR = self._origdir

    def test_embed_pick_is_embedder_never_chat(self):
        self.assertEqual(AS.embed_model(), "nomic-embed-text:latest")

    def test_vision_pick(self):
        self.assertEqual(AS.vision_model(), "qwen2.5vl:7b")

    def test_status_ready_when_both_present(self):
        st = AS.rag_status()
        self.assertTrue(st["ready"])
        self.assertEqual(st["embed_model"], "nomic-embed-text:latest")
        self.assertEqual(st["vision_model"], "qwen2.5vl:7b")

    def test_not_ready_without_embedder(self):
        AS._ollama_models = lambda: ["qwen2.5-coder:14b", "qwen2.5vl:7b"]
        self.assertIsNone(AS.embed_model())
        self.assertFalse(AS.rag_status()["ready"])

    def test_ingest_guard_without_source(self):
        r = AS.rag_ingest(collection="x")  # no url/html/image/path
        self.assertFalse(r["ok"])
        self.assertIn("provide one of", r["error"])


@unittest.skipUnless(os.environ.get("LLM_RAG_LIVE") == "1",
                     "set LLM_RAG_LIVE=1 to run the live Ollama end-to-end check")
class LiveTest(unittest.TestCase):
    """Real caption → embed → retrieve against the installed models (no rendering)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="raglive_")
        self._orig = AS.RAG_DIR
        AS.RAG_DIR = self.tmp

    def tearDown(self):
        AS.RAG_DIR = self._orig
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_chart_tiles_retrieve_correctly(self):
        import base64
        sys.path.insert(0, os.path.join(REPO, "tools"))
        import visual_rag as vr  # reuse the proven chart-tile generators
        for name, png in (("bar-chart", vr._bar_chart()), ("table", vr._table_grid())):
            res = AS.rag_ingest(collection="live", image_b64=base64.b64encode(png).decode(), source=name)
            self.assertTrue(res["ok"], res)
        hit = AS.rag_query(collection="live", question="a bar chart comparing values", k=2)
        self.assertTrue(hit["ok"], hit)
        self.assertEqual(hit["hits"][0]["source"], "bar-chart")


if __name__ == "__main__":
    unittest.main()
