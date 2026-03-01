#!/usr/bin/env python3
"""Minimal mock NullClaw worker for end-to-end testing.

Usage:
    python3 tests/mock_worker.py <port>

Accepts POST /webhook with JSON body {"message": "...", "session_key": "..."}.
Returns {"status":"ok","response":"Mock response to: <first 50 chars of message>"}.
Returns 404 for all other paths.
"""

import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler


class MockWorkerHandler(BaseHTTPRequestHandler):
    """Handle webhook requests from NullBoiler."""

    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "not found"}).encode())
            return

        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body)
        except (json.JSONDecodeError, ValueError):
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "invalid JSON"}).encode())
            return

        message = data.get("message", "")
        session_key = data.get("session_key", "")

        print(
            f"[mock_worker] POST /webhook session_key={session_key} "
            f"message={message[:50]!r}",
            file=sys.stderr,
        )

        # Build response
        truncated = message[:50]
        response = {"status": "ok", "response": f"Mock response to: {truncated}"}

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response).encode())

    def do_GET(self):
        self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"error": "not found"}).encode())

    def log_message(self, fmt, *args):
        """Redirect default access log to stderr."""
        print(f"[mock_worker] {fmt % args}", file=sys.stderr)


def main():
    try:
        port = int(sys.argv[1])
    except (IndexError, ValueError):
        print(f"Usage: {sys.argv[0]} PORT", file=sys.stderr)
        sys.exit(1)
    server = HTTPServer(("127.0.0.1", port), MockWorkerHandler)
    print(f"[mock_worker] listening on 127.0.0.1:{port}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
