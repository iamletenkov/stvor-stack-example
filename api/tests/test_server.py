import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import ProxyHandler, build_opener

from server import create_server, increment_count, secret_present


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.secrets = self.root / "secrets"
        self.secrets.mkdir()
        self.config = self.root / "build-config.json"
        self.config.write_text('{"version":"1.1.0"}', encoding="utf-8")
        self.env = patch.dict(os.environ, {
            "DEMO_ROBOT_LABEL": "Демонстрационный робот",
            "DEMO_COLOR": "green",
            "DEMO_GREETING": "Hello, robot",
            "DEMO_SECRETS_DIR": str(self.secrets),
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.client = build_opener(ProxyHandler({}))

    @contextlib.contextmanager
    def running(self):
        server = create_server("127.0.0.1", 0, self.root / "data", self.config)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def get_json(self, url):
        with self.client.open(url, timeout=2) as response:
            self.assertEqual(response.headers.get_content_type(), "application/json")
            return json.load(response)

    def test_status_and_health(self):
        with self.running() as url:
            self.assertEqual(self.get_json(url + "/healthz"), {"ok": True})
            self.assertEqual(self.get_json(url + "/status"), {
                "version": "1.1.0",
                "DEMO_ROBOT_LABEL": "Демонстрационный робот",
                "DEMO_COLOR": "green",
                "DEMO_GREETING": "Hello, robot",
                "api_token_present": False,
                "start_count": 1,
            })

    def test_count_changes_only_on_restart_and_survives_version_change(self):
        with self.running() as url:
            for _ in range(3):
                self.assertEqual(self.get_json(url + "/status")["start_count"], 1)
        self.config.write_text('{"version":"1.0.0"}', encoding="utf-8")
        with self.running() as url:
            status = self.get_json(url + "/status")
            self.assertEqual(status["start_count"], 2)
            self.assertEqual(status["version"], "1.0.0")

    def test_secret_is_only_a_boolean_and_never_logged(self):
        marker = "synthetic-" + "private-value"
        token = self.secrets / "api_token"
        token.write_text(marker, encoding="utf-8")
        token.chmod(0o444)
        output = io.StringIO()
        with contextlib.redirect_stderr(output), contextlib.redirect_stdout(output):
            with self.running() as url:
                status = self.get_json(url + "/status")
                self.assertIs(status["api_token_present"], True)
                self.assertNotIn(marker, json.dumps(status))
                with self.assertRaises(HTTPError) as error:
                    self.client.open(url + "/" + marker, timeout=2)
                self.assertEqual(error.exception.code, 404)
        self.assertNotIn(marker, output.getvalue())

    def test_empty_secret_is_absent(self):
        (self.secrets / "api_token").write_bytes(b"")
        with self.running() as url:
            self.assertIs(self.get_json(url + "/status")["api_token_present"], False)

    def test_default_parameters(self):
        os.environ.pop("DEMO_ROBOT_LABEL", None)
        os.environ.pop("DEMO_COLOR", None)
        os.environ.pop("DEMO_GREETING", None)
        with self.running() as url:
            status = self.get_json(url + "/status")
            self.assertEqual(status["DEMO_ROBOT_LABEL"], "Demo robot")
            self.assertEqual(status["DEMO_COLOR"], "blue")
            self.assertEqual(status["DEMO_GREETING"], "")

    def test_secret_is_read_from_compose_secrets_dir_by_default(self):
        os.environ.pop("DEMO_SECRETS_DIR", None)
        with patch("server.DEFAULT_SECRETS_DIR", self.secrets):
            (self.secrets / "api_token").write_text("synthetic-value", encoding="utf-8")
            with self.running() as url:
                self.assertIs(self.get_json(url + "/status")["api_token_present"], True)


class StorageTests(unittest.TestCase):
    def test_counter_persists_and_does_not_leave_temporary_files(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory) / "data"
            for expected in range(1, 4):
                self.assertEqual(increment_count(data), expected)
                self.assertEqual((data / "start-count").read_text(encoding="ascii"), str(expected))
                self.assertEqual([file.name for file in data.iterdir()], ["start-count"])

    def test_corrupt_counter_fails_without_resetting_data(self):
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory)
            counter = data / "start-count"
            for value in ["corrupt", "-1"]:
                counter.write_text(value, encoding="ascii")
                with self.assertRaises(ValueError):
                    increment_count(data)
                self.assertEqual(counter.read_text(encoding="ascii"), value)

    def test_secret_presence_for_missing_empty_nonempty_and_invalid_file(self):
        with tempfile.TemporaryDirectory() as directory:
            secrets = Path(directory)
            token = secrets / "api_token"
            self.assertIs(secret_present(secrets), False)
            token.write_bytes(b"")
            self.assertIs(secret_present(secrets), False)
            token.write_bytes(b"synthetic-value")
            token.chmod(0o444)
            self.assertIs(secret_present(secrets), True)
            self.assertIs(secret_present(token), False)


if __name__ == "__main__":
    unittest.main()
