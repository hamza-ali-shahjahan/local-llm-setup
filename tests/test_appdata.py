"""Tests for the per-app local data store — the zero-setup backend a DEPLOYED app gets.

Unit layer: the data_* CRUD functions against a temp SQLite file. Live layer: deploy a
tiny app and drive its same-origin /api/data REST API over real HTTP, then stop it —
also asserting the raw .db sits OUTSIDE the served web root. Deterministic + offline.
"""
import os, sys, json, tempfile, urllib.request, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server  # noqa: E402

AS = load_agent_server()


class DataStoreTest(unittest.TestCase):
    def setUp(self):
        self.db = os.path.join(tempfile.mkdtemp(), "t.db")

    def test_crud_roundtrip(self):
        a = AS.data_create(self.db, "todos", {"text": "buy milk", "done": False})
        self.assertIn("id", a)
        self.assertEqual(a["text"], "buy milk")
        b = AS.data_create(self.db, "todos", {"text": "walk dog"})
        lst = AS.data_list(self.db, "todos")
        self.assertEqual([d["id"] for d in lst], [a["id"], b["id"]])  # ordered by id
        self.assertEqual(AS.data_get(self.db, "todos", a["id"])["text"], "buy milk")
        up = AS.data_update(self.db, "todos", a["id"], {"text": "buy milk", "done": True})
        self.assertTrue(up["done"])
        self.assertTrue(AS.data_get(self.db, "todos", a["id"])["done"])
        self.assertTrue(AS.data_delete(self.db, "todos", a["id"]))
        self.assertIsNone(AS.data_get(self.db, "todos", a["id"]))
        self.assertEqual(len(AS.data_list(self.db, "todos")), 1)

    def test_collections_are_isolated(self):
        AS.data_create(self.db, "notes", {"t": "n1"})
        AS.data_create(self.db, "todos", {"t": "t1"})
        self.assertEqual(len(AS.data_list(self.db, "notes")), 1)
        self.assertEqual(len(AS.data_list(self.db, "todos")), 1)

    def test_missing_update_delete(self):
        self.assertIsNone(AS.data_update(self.db, "x", 999, {"a": 1}))
        self.assertFalse(AS.data_delete(self.db, "x", 999))

    def test_bad_collection_raises(self):
        with self.assertRaises(Exception):
            AS.data_list(self.db, "!!!")

    def test_non_dict_body_is_wrapped(self):
        d = AS.data_create(self.db, "vals", 42)
        self.assertEqual(d["value"], 42)
        self.assertIn("id", d)


class LiveDeployDataTest(unittest.TestCase):
    def tearDown(self):
        for slug in list(getattr(AS, "_DEPLOYS", {}).keys()):
            AS.deploy_stop(slug)

    def test_deployed_app_data_api_roundtrip(self):
        dep = AS.deploy("App Data Test", html="<h1>app</h1>")
        base = dep["url"].rstrip("/")
        col = "/api/data/t" + os.urandom(3).hex()   # fresh collection so reruns don't collide

        def req(method, path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            r = urllib.request.Request(base + path, data=data, method=method,
                                       headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(r, timeout=5) as resp:
                return resp.status, json.loads(resp.read())

        st, j = req("GET", col)
        self.assertEqual(j["data"], [])                                  # starts empty
        st, j = req("POST", col, {"text": "ship it"})
        self.assertEqual(st, 201)
        tid = j["data"]["id"]
        st, j = req("GET", col)
        self.assertEqual(len(j["data"]), 1)
        self.assertEqual(j["data"][0]["text"], "ship it")               # persisted
        st, j = req("PUT", col + "/%d" % tid, {"text": "ship it", "done": True})
        self.assertTrue(j["data"]["done"])                              # updated
        st, j = req("DELETE", col + "/%d" % tid)
        self.assertTrue(j["deleted"])
        st, j = req("GET", col)
        self.assertEqual(j["data"], [])                                  # gone

        # the app's static file still serves (the API didn't shadow it)
        with urllib.request.urlopen(base + "/", timeout=5) as resp:
            self.assertIn("<h1>app</h1>", resp.read().decode())
        # the DB lives OUTSIDE the served web root (can't be fetched)
        self.assertFalse(os.path.exists(os.path.join(dep["dir"], os.path.basename(dep["dir"]) + ".db")))
        self.assertTrue(os.path.exists(os.path.realpath(dep["dir"]) + ".db"))


if __name__ == "__main__":
    unittest.main()
