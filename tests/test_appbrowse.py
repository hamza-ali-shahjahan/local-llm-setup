"""Tests for the 🗄️ data-browser backend — reading/editing a deployed app's DB from the builder.

Monkeypatches AS.DEPLOY_DIR to a temp dir and seeds fixture DBs with the real helpers, then
exercises: filesystem enumeration (incl. apps not in _DEPLOYS), read-only browsing that creates
NO phantom tables, the no-secrets guarantee for /users, path-safe slug resolution, pagination,
mutations + the user-delete session cascade, and the origin lock over real HTTP. Stdlib only.
"""
import os, sys, json, time, tempfile, threading, urllib.request, urllib.error, unittest
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server  # noqa: E402

AS = load_agent_server()


class BrowseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self._orig = AS.DEPLOY_DIR
        AS.DEPLOY_DIR = self.tmp
        self.docs_db = os.path.join(self.tmp, "docsapp.db")
        self.users_db = os.path.join(self.tmp, "usersapp.db")
        self.both_db = os.path.join(self.tmp, "bothapp.db")
        AS.data_create(self.docs_db, "todos", {"text": "a"})
        AS.data_create(self.docs_db, "todos", {"text": "b"})
        AS.data_create(self.docs_db, "notes", {"t": "n"})
        AS.auth_signup(self.users_db, "alice", "pw1")
        AS.auth_signup(self.users_db, "bob", "pw2")
        AS.data_create(self.both_db, "items", {"x": 1})
        AS.auth_signup(self.both_db, "carol", "pw3")
        os.makedirs(os.path.join(self.tmp, "dir-without-db"), exist_ok=True)  # app dir, no .db

    def tearDown(self):
        AS.DEPLOY_DIR = self._orig

    def _apps(self):
        return {a["slug"]: a for a in AS._db_apps()["apps"]}

    def test_enumerates_from_filesystem(self):
        apps = self._apps()
        self.assertEqual(set(apps), {"docsapp", "usersapp", "bothapp"})   # the dir-without-.db is absent
        self.assertTrue(apps["docsapp"]["has_docs"]);  self.assertFalse(apps["docsapp"]["has_users"])
        self.assertFalse(apps["usersapp"]["has_docs"]); self.assertTrue(apps["usersapp"]["has_users"])
        self.assertEqual(apps["usersapp"]["users"], 2)
        cols = {c["name"]: c["count"] for c in apps["docsapp"]["collections"]}
        self.assertEqual(cols, {"todos": 2, "notes": 1})
        self.assertFalse(apps["docsapp"]["running"])                      # not in _DEPLOYS

    def test_overview_creates_no_phantom_tables(self):
        before = self._tables(self.users_db)
        AS._db_overview(self.users_db)                                    # browse a users-only DB
        AS._db_apps()
        self.assertEqual(self._tables(self.users_db), before)             # no 'docs' table was created
        self.assertNotIn("docs", self._tables(self.users_db))

    def _tables(self, db_path):
        import sqlite3
        db = sqlite3.connect(db_path)
        t = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        db.close()
        return t

    def test_missing_table_tolerance(self):
        self.assertEqual(AS._db_overview(self.docs_db)["users"], 0)       # docs-only -> users 0, no error
        self.assertEqual(AS._db_overview(self.users_db)["collections"], [])

    def test_users_never_leak_secrets(self):
        users = AS.auth_users(self.users_db)
        self.assertEqual({u["username"] for u in users}, {"alice", "bob"})
        self.assertIn("sessions", users[0])
        blob = json.dumps(AS.auth_users(self.users_db))
        for bad in ("salt", "pwhash", "token"):
            self.assertNotIn(bad, blob)
        import re
        self.assertIsNone(re.search(r"[0-9a-f]{32,}", blob))             # no hash/token hex slipped in
        self.assertEqual(AS.auth_users(self.docs_db), [])                # docs-only -> []

    def test_deploy_db_path_safety(self):
        for bad in ("../../etc/passwd", "..", "foo/bar", "/etc/hosts", "x\x00y", "ghost-slug"):
            with self.assertRaises(Exception):
                AS._deploy_db(bad)
        p = AS._deploy_db("docsapp")
        self.assertEqual(os.path.dirname(p), self.tmp)
        self.assertTrue(p.endswith(".db"))

    def test_pagination(self):
        big = os.path.join(self.tmp, "bigapp.db")
        db = AS._data_open(big)
        for i in range(1100):
            db.execute("INSERT INTO docs(collection,body,created,updated) VALUES(?,?,?,?)", ("big", '{"n":%d}' % i, 0, 0))
        db.commit(); db.close()
        r = AS.data_rows(big, "big")
        self.assertEqual(r["total"], 1100)
        self.assertEqual(len(r["data"]), 200)                            # default cap
        self.assertEqual(AS.data_rows(big, "big", limit=99999)["data"].__len__(), 1000)  # clamped to max
        self.assertEqual(AS.data_rows(big, "big", limit=5, offset=10)["data"][0]["n"], 10)  # offset works

    def test_mutations_and_user_cascade(self):
        rid = AS.data_rows(self.docs_db, "todos")["data"][0]["id"]
        self.assertTrue(AS.data_update(self.docs_db, "todos", rid, {"text": "edited"})["text"] == "edited")
        self.assertEqual(AS.data_get(self.docs_db, "todos", rid)["text"], "edited")
        self.assertTrue(AS.data_delete(self.docs_db, "todos", rid))
        self.assertFalse(AS.data_delete(self.docs_db, "todos", rid))      # idempotent
        s = AS.auth_signup(self.users_db, "dave", "pw")                   # fresh user + session
        self.assertIsNotNone(AS.auth_user_by_token(self.users_db, s["token"]))
        self.assertTrue(AS.auth_delete_user(self.users_db, s["user"]["id"]))
        self.assertIsNone(AS.auth_user_by_token(self.users_db, s["token"]))  # session cascaded -> cookie dead

    def test_malformed_row_does_not_hide_collection(self):
        db = AS._data_open(self.docs_db)   # inject a corrupt body alongside the 2 valid todos
        db.execute("INSERT INTO docs(collection,body,created,updated) VALUES(?,?,?,?)", ("todos", "{not json", 0, 0))
        db.commit(); db.close()
        rows = AS.data_rows(self.docs_db, "todos")          # must NOT raise
        self.assertEqual(rows["total"], 3)
        bad = [r for r in rows["data"] if r.get("_decode_error")]
        self.assertEqual(len(bad), 1)
        self.assertEqual(bad[0]["_raw"], "{not json")
        self.assertEqual(len([r for r in rows["data"] if r.get("text")]), 2)  # the valid rows still visible


class OriginLockTest(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp())
        self._orig = AS.DEPLOY_DIR
        AS.DEPLOY_DIR = self.tmp
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), AS.H)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown(); self.srv.server_close()
        AS.DEPLOY_DIR = self._orig

    def _post(self, path, origin=None, body=None):
        headers = {"Content-Type": "application/json"}
        if origin:
            headers["Origin"] = origin
        r = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path),
                                   data=json.dumps(body or {}).encode(), method="POST", headers=headers)
        try:
            resp = urllib.request.urlopen(r, timeout=5)
            return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, None

    def _tables(self, db_path):
        import sqlite3
        db = sqlite3.connect(db_path)
        t = {x[0] for x in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        db.close()
        return t

    def test_data_endpoints_are_origin_locked(self):
        for path in ("/api/agent/data/apps", "/api/agent/data/users"):
            self.assertEqual(self._post(path, origin="http://evil.example")[0], 403)   # foreign origin blocked
            self.assertEqual(self._post(path, origin=None)[0], 200)                     # no Origin (same-origin) ok

    def test_write_endpoints_create_no_phantom_table(self):
        authdb = os.path.join(self.tmp, "authonly.db")
        AS.auth_signup(authdb, "u", "p")                      # users+sessions only, no docs table
        before = self._tables(authdb)
        st, j = self._post("/api/agent/data/delete", body={"slug": "authonly", "collection": "todos", "id": 1})
        self.assertEqual(st, 200); self.assertFalse(j["deleted"])     # clean no-op
        st, j = self._post("/api/agent/data/update", body={"slug": "authonly", "collection": "todos", "id": 1, "body": {"x": 1}})
        self.assertEqual(st, 200); self.assertFalse(j["ok"])          # row not found, no write
        self.assertEqual(self._tables(authdb), before)               # NO phantom 'docs' table injected
        self.assertNotIn("docs", self._tables(authdb))

    def test_missing_id_gives_clean_error(self):
        AS.auth_signup(os.path.join(self.tmp, "x.db"), "u", "p")
        st, j = self._post("/api/agent/data/delete", body={"slug": "x", "collection": "c"})  # no id
        self.assertFalse(j["ok"]); self.assertIn("id is required", j["error"])


if __name__ == "__main__":
    unittest.main()
