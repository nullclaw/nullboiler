#!/usr/bin/env python3
"""PicoClaw -> NullBoiler sync webhook bridge.

Exposes POST /webhook and forwards requests to:
    picoclaw agent --message "<message>" --session "<session_key>"

Response shape:
    {"status":"ok","response":"..."}
"""

import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


BRIDGE_TOKEN = os.environ.get("PICOCLAW_BRIDGE_TOKEN", "").strip()
PICOCLAW_BIN = os.environ.get("PICOCLAW_BIN", "picoclaw")
DEFAULT_PORT = int(os.environ.get("PICOCLAW_BRIDGE_PORT", "18795"))


class BridgeHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/webhook":
            self._write_json(404, {"error": "not found"})
            return

        if BRIDGE_TOKEN:
            auth = self.headers.get("Authorization", "")
            expected = f"Bearer {BRIDGE_TOKEN}"
            if auth != expected:
                self._write_json(401, {"error": "unauthorized"})
                return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._write_json(400, {"error": "invalid Content-Length"})
            return

        raw_body = self.rfile.read(content_length)
        try:
            payload = json.loads(raw_body)
        except (json.JSONDecodeError, ValueError):
            self._write_json(400, {"error": "invalid JSON"})
            return

        message = payload.get("message") or payload.get("text") or ""
        session_key = payload.get("session_key") or payload.get("session_id") or "nullboiler:default"
        if not isinstance(message, str) or not message.strip():
            self._write_json(400, {"error": "message is required"})
            return

        if not isinstance(session_key, str) or not session_key.strip():
            session_key = "nullboiler:default"

        cmd = [
            PICOCLAW_BIN,
            "agent",
            "--message",
            message,
            "--session",
            session_key,
        ]
        try:
            result = subprocess.run(
                cmd,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except subprocess.CalledProcessError as exc:
            self._write_json(
                502,
                {
                    "error": "picoclaw command failed",
                    "details": exc.stderr.strip()[:400],
                },
            )
            return
        except FileNotFoundError:
            self._write_json(500, {"error": f"{PICOCLAW_BIN} not found in PATH"})
            return

        output = result.stdout.strip()
        if not output:
            output = "(empty response)"

        self._write_json(200, {"status": "ok", "response": output})

    def do_GET(self):
        if self.path == "/health":
            self._write_json(200, {"status": "ok"})
            return
        self._write_json(404, {"error": "not found"})

    def _write_json(self, status_code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"[picoclaw-bridge] {fmt % args}", file=sys.stderr)


def main():
    try:
        port = int(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PORT
    except ValueError:
        print("Usage: picoclaw_webhook_bridge.py [PORT]", file=sys.stderr)
        sys.exit(1)

    server = HTTPServer(("127.0.0.1", port), BridgeHandler)
    print(f"[picoclaw-bridge] listening on http://127.0.0.1:{port}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
