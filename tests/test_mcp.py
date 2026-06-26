"""Tests for the MCP client (stdlib stdio JSON-RPC).

A minimal mock MCP server (tests/fixtures/mock_mcp_server.py) is launched as a real
subprocess, so the full initialize → notifications/initialized → tools/list → tools/call
handshake is exercised end-to-end — deterministic and offline (no network, no SDK).
"""
import os, sys, json, tempfile, unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _helpers import load_agent_server  # noqa: E402

AS = load_agent_server()
MOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "mock_mcp_server.py")


def _config(tmp, servers):
    p = os.path.join(tmp, "mcp.json")
    with open(p, "w") as f:
        json.dump({"mcpServers": servers}, f)
    return p


class ConfigTest(unittest.TestCase):
    def test_missing_config_is_empty(self):
        self.assertEqual(AS.load_mcp_config("/no/such/path/mcp.json"), {})

    def test_reads_mcpservers_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = _config(tmp, {"x": {"command": "echo", "args": ["hi"]}})
            self.assertIn("x", AS.load_mcp_config(cfg))


class MockServerTest(unittest.TestCase):
    def tearDown(self):
        for name in list(getattr(AS, "_MCP", {}).keys()):
            try: AS._MCP.pop(name).stop()
            except Exception: pass

    def _cfg(self, tmp):
        return _config(tmp, {"mock": {"command": sys.executable, "args": [MOCK]}})

    def test_list_discovers_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = AS.mcp_list(config_path=self._cfg(tmp))
            self.assertEqual(res["count"], 1)
            srv = res["servers"][0]
            self.assertTrue(srv["ok"], srv.get("error"))
            self.assertEqual(srv["info"].get("name"), "mock-mcp")
            names = [t["name"] for t in srv["tools"]]
            self.assertIn("echo", names)
            self.assertIn("add", names)

    def test_call_echo_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = AS.mcp_call("mock", "echo", {"text": "hello mcp"}, config_path=self._cfg(tmp))
            self.assertTrue(out["ok"])
            self.assertFalse(out["isError"])
            self.assertIn("hello mcp", out["text"])

    def test_call_add(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = AS.mcp_call("mock", "add", {"a": 2, "b": 3}, config_path=self._cfg(tmp))
            self.assertIn("5", out["text"])

    def test_unknown_tool_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(Exception):
                AS.mcp_call("mock", "does-not-exist", {}, config_path=self._cfg(tmp))

    def test_unknown_server_raises(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(Exception):
                AS.mcp_call("ghost", "echo", {}, config_path=self._cfg(tmp))

    def test_connection_is_pooled(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = self._cfg(tmp)
            AS.mcp_list(config_path=cfg)
            first = AS._MCP.get("mock")
            AS.mcp_call("mock", "echo", {"text": "x"}, config_path=cfg)
            self.assertIs(AS._MCP.get("mock"), first)  # reused, not relaunched


if __name__ == "__main__":
    unittest.main()
