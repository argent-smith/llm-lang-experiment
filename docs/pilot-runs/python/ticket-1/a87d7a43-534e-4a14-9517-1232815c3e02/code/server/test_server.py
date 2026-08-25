import os
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import server as syncbox_server


class ParseArgsTests(unittest.TestCase):
    def setUp(self):
        for name in ("SYNCBOX_DATA_DIR", "SYNCBOX_PORT"):
            os.environ.pop(name, None)

    def test_requires_data_dir(self):
        with self.assertRaises(SystemExit):
            syncbox_server.parse_args(["--port", "1234"])

    def test_data_dir_and_default_port(self):
        args = syncbox_server.parse_args(["--data-dir", "/tmp/x"])
        self.assertEqual(args.data_dir, "/tmp/x")
        self.assertEqual(args.port, 8080)

    def test_port_flag_overrides_default(self):
        args = syncbox_server.parse_args(["--data-dir", "/tmp/x", "--port", "9999"])
        self.assertEqual(args.port, 9999)

    def test_env_vars_used_when_flags_absent(self):
        os.environ["SYNCBOX_DATA_DIR"] = "/tmp/from-env"
        os.environ["SYNCBOX_PORT"] = "7777"
        args = syncbox_server.parse_args([])
        self.assertEqual(args.data_dir, "/tmp/from-env")
        self.assertEqual(args.port, 7777)

    def test_flags_override_env_vars(self):
        os.environ["SYNCBOX_DATA_DIR"] = "/tmp/from-env"
        os.environ["SYNCBOX_PORT"] = "7777"
        args = syncbox_server.parse_args(["--data-dir", "/tmp/from-flag", "--port", "1111"])
        self.assertEqual(args.data_dir, "/tmp/from-flag")
        self.assertEqual(args.port, 1111)


class HealthzEndpointTests(unittest.TestCase):
    def setUp(self):
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), syncbox_server.SyncboxRequestHandler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)

    def test_healthz_returns_200(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/healthz") as resp:
            self.assertEqual(resp.status, 200)

    def test_unknown_path_returns_404(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(f"http://127.0.0.1:{self.port}/nope")
        self.assertEqual(ctx.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
