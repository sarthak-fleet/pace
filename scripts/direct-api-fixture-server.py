#!/usr/bin/env python3
"""Minimal OpenAI-compatible SSE fixture for DirectAPIPlannerClient tests.

Serves the OpenAI chat-completions SSE shape at POST /v1/chat/completions:
  data: {"choices":[{"delta":{"content":"Hello"}}]}
  data: {"choices":[{"delta":{"content":" world"}}]}
  data: [DONE]

Error variants:
  - When the request body contains {"trigger_error": "invalid_key"} -> HTTP 401
  - When the request body contains {"trigger_error": "quota"}       -> HTTP 429
  - When the request body contains {"trigger_error": "malformed"}   -> emits a
    `data: {malformed` line so the client's parse-error path is exercised
  - When the request body contains {"trigger_error": "empty"}       -> emits
    only `data: [DONE]` (no content events) so the empty-stream path runs

Stdlib only. Usage:
  python3 scripts/direct-api-fixture-server.py <port>
Prints "READY" to stdout once listening.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CANNED_CONTENT_TOKENS = ["Hello", " world", " from", " the", " fixture"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        # Health check endpoint so tests can probe the fixture if needed.
        if self.path in ("/health", "/v1/health"):
            body = json.dumps({"status": "ok"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path not in ("/v1/chat/completions", "/chat/completions"):
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        raw_body = self.rfile.read(content_length) if content_length else b""
        try:
            request_payload = json.loads(raw_body) if raw_body else {}
        except json.JSONDecodeError:
            request_payload = {}

        trigger_error_kind = request_payload.get("trigger_error", "")

        if trigger_error_kind == "invalid_key":
            error_body = json.dumps({
                "error": {"message": "invalid x-api-key", "type": "authentication_error"}
            }).encode()
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(error_body)))
            self.end_headers()
            self.wfile.write(error_body)
            return

        if trigger_error_kind == "quota":
            error_body = json.dumps({
                "error": {"message": "Rate limit exceeded", "type": "rate_limit_error"}
            }).encode()
            self.send_response(429)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(error_body)))
            self.end_headers()
            self.wfile.write(error_body)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        if trigger_error_kind == "malformed":
            self.wfile.write(b"data: {malformed json line here\n\n")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        if trigger_error_kind == "empty":
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        for content_token in CANNED_CONTENT_TOKENS:
            event_payload = {
                "choices": [
                    {"delta": {"content": content_token}, "index": 0, "finish_reason": None}
                ]
            }
            chunk_event = f"data: {json.dumps(event_payload)}\n\n"
            self.wfile.write(chunk_event.encode())
            self.wfile.flush()

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 19877
    server = HTTPServer(("127.0.0.1", port), Handler)
    print("READY", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
