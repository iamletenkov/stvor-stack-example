"""HTTP API стека-примера Stvor; только стандартная библиотека Python.

`GET /healthz` — 200 `{"ok": true}`; `GET /status` — версия из образа, параметры назначения (`DEMO_*` из env),
признак секрета `api_token` (только «есть или нет», без значения) и число запусков из именованного тома.
Секрет читается из `/run/secrets/api_token` (compose `secrets:`); `DEMO_SECRETS_DIR` меняет каталог для тестов.
"""

import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile
from urllib.request import ProxyHandler, build_opener

DEFAULT_SECRETS_DIR = Path("/run/secrets")


def increment_count(data_dir):
    data_dir.mkdir(parents=True, exist_ok=True, mode=0o750)
    counter = data_dir / "start-count"
    previous = int(counter.read_text(encoding="ascii")) if counter.exists() else 0
    if previous < 0:
        raise ValueError("Invalid start count")
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="ascii", dir=data_dir, prefix="start-count-", delete=False
    ) as temporary:
        temporary.write(str(previous + 1))
        temporary.flush()
        os.fsync(temporary.fileno())
    os.replace(temporary.name, counter)
    directory_fd = os.open(data_dir, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return previous + 1


def secret_present(secrets_dir):
    try:
        with (secrets_dir / "api_token").open("rb") as token:
            return bool(token.read(1))
    except OSError:
        return False


def create_server(host="0.0.0.0", port=8080, data_dir=Path("/data"), config_path=None):
    config_path = config_path or Path(__file__).with_name("build-config.json")
    version = json.loads(Path(config_path).read_text(encoding="utf-8"))["version"]
    robot_label = os.environ.get("DEMO_ROBOT_LABEL", "Demo robot")
    color = os.environ.get("DEMO_COLOR", "blue")
    greeting = os.environ.get("DEMO_GREETING", "")
    secrets_dir = Path(os.environ.get("DEMO_SECRETS_DIR", DEFAULT_SECRETS_DIR))

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/healthz":
                self.reply(200, {"ok": True})
            elif self.path == "/status":
                self.reply(200, {
                    "version": version,
                    "DEMO_ROBOT_LABEL": robot_label,
                    "DEMO_COLOR": color,
                    "DEMO_GREETING": greeting,
                    "api_token_present": secret_present(secrets_dir),
                    "start_count": self.server.start_count,
                })
            else:
                self.reply(404, {"error": "not_found"})

        def reply(self, status, payload):
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format_string, *args):
            # Не журналируем URL, заголовки и значения параметров.
            pass

    server = ThreadingHTTPServer((host, port), Handler)
    try:
        server.start_count = increment_count(Path(data_dir))
    except Exception:
        server.server_close()
        raise
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--data-dir", type=Path, default=Path("/data"))
    parser.add_argument("--healthcheck", action="store_true")
    args = parser.parse_args()
    if args.healthcheck:
        try:
            with build_opener(ProxyHandler({})).open(
                f"http://127.0.0.1:{args.port}/healthz", timeout=2
            ) as response:
                return 0 if response.status == 200 else 1
        except OSError:
            return 1
    server = create_server(args.host, args.port, args.data_dir)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
