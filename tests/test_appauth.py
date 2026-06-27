"""Tests for per-app auth (signup / login / sessions) — the login layer a deployed app gets.

Unit: the auth_* functions against a temp SQLite db — PBKDF2 hashing with unique salts,
sessions, wrong-password, duplicate-username, logout-invalidates. Live: deploy an app and
drive /api/auth/* over real HTTP with a cookie jar (signup sets an HttpOnly session cookie,
/me reflects it, logout clears it). Deterministic + offline.
"""
import os, sys, json, tempfile, urllib.request, urllib.error, http.cookiejar, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server  # noqa: E402

AS = load_agent_server()


class AuthFnTest(unittest.TestCase):
    def setUp(self):
        self.db = os.path.join(tempfile.mkdtemp(), "a.db")

    def test_signup_login_session(self):
        s = AS.auth_signup(self.db, "alice", "hunter2")
        self.assertEqual(s["user"]["username"], "alice")
        self.assertTrue(s["token"])
        self.assertEqual(AS.auth_user_by_token(self.db, s["token"])["username"], "alice")
        self.assertEqual(AS.auth_login(self.db, "alice", "hunter2")["user"]["id"], s["user"]["id"])

    def test_wrong_password_and_unknown_user(self):
        AS.auth_signup(self.db, "bob", "correct")
        self.assertIsNone(AS.auth_login(self.db, "bob", "wrong"))
        self.assertIsNone(AS.auth_login(self.db, "nobody", "x"))

    def test_duplicate_username_raises(self):
        AS.auth_signup(self.db, "carol", "p1")
        with self.assertRaises(Exception):
            AS.auth_signup(self.db, "carol", "p2")

    def test_empty_credentials_raise(self):
        with self.assertRaises(Exception):
            AS.auth_signup(self.db, "", "p")
        with self.assertRaises(Exception):
            AS.auth_signup(self.db, "u", "")

    def test_logout_invalidates_session(self):
        s = AS.auth_signup(self.db, "dave", "pw")
        self.assertTrue(AS.auth_logout(self.db, s["token"]))
        self.assertIsNone(AS.auth_user_by_token(self.db, s["token"]))

    def test_password_hashed_with_unique_salt(self):
        AS.auth_signup(self.db, "u1", "samepw")
        AS.auth_signup(self.db, "u2", "samepw")
        db = AS._auth_open(self.db)
        rows = db.execute("SELECT salt, pwhash FROM users ORDER BY id").fetchall()
        db.close()
        self.assertNotEqual(rows[0][0], rows[1][0])      # different salts
        self.assertNotEqual(rows[0][1], rows[1][1])      # -> different hashes for the same password
        self.assertNotIn("samepw", rows[0][1])           # never stored in plaintext


class LiveAuthTest(unittest.TestCase):
    def tearDown(self):
        for slug in list(getattr(AS, "_DEPLOYS", {}).keys()):
            AS.deploy_stop(slug)

    def test_deployed_auth_flow(self):
        dep = AS.deploy("App Auth Test", html="<h1>app</h1>")
        base = dep["url"].rstrip("/")
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        user = "u" + os.urandom(3).hex()

        def req(method, path, body=None):
            data = json.dumps(body).encode() if body is not None else None
            r = urllib.request.Request(base + path, data=data, method=method,
                                       headers={"Content-Type": "application/json"})
            try:
                resp = opener.open(r, timeout=5)
                return resp.status, json.loads(resp.read())
            except urllib.error.HTTPError as e:
                return e.code, json.loads(e.read())

        st, j = req("POST", "/api/auth/signup", {"username": user, "password": "s3cret"})
        self.assertEqual(st, 201)
        self.assertEqual(j["user"]["username"], user)
        self.assertTrue(any(c.name == "session" for c in jar))         # session cookie set
        st, j = req("GET", "/api/auth/me")
        self.assertEqual(j["user"]["username"], user)                  # cookie reflects the login
        st, j = req("POST", "/api/auth/login", {"username": user, "password": "wrong"})
        self.assertEqual(st, 401)                                       # bad password rejected
        st, j = req("POST", "/api/auth/logout")
        self.assertTrue(j["ok"])
        st, j = req("GET", "/api/auth/me")
        self.assertIsNone(j["user"])                                   # logged out


if __name__ == "__main__":
    unittest.main()
