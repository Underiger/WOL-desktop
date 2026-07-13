#!/usr/bin/env python3
"""Minimal WoL HTTP API for Tomori (Pi Zero 1WH).

Endpoints:
  POST /wake    Send a Wake-on-LAN magic packet (requires Bearer token)
  GET  /status  Health check, always returns 200 OK

All configuration comes from environment variables (see
configs/wol-api.env.example) so secrets never live in this file:
  WOL_TOKEN      Bearer token required for /wake (required)
  WOL_MAC        Target MAC address           (default: 50:EB:F6:5C:CE:3E)
  WOL_BROADCAST  Broadcast address to send to (default: 192.168.0.255)
  WOL_PORT       Port to listen on            (default: 8080)
"""

import hmac
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WOL_TOKEN = os.environ.get("WOL_TOKEN", "")
WOL_MAC = os.environ.get("WOL_MAC", "50:EB:F6:5C:CE:3E")
WOL_BROADCAST = os.environ.get("WOL_BROADCAST", "192.168.0.255")
WOL_PORT = int(os.environ.get("WOL_PORT", "8080"))


class Handler(BaseHTTPRequestHandler):
    server_version = "wol-api/1.0"

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not header.startswith(prefix):
            return False
        token = header[len(prefix):]
        return hmac.compare_digest(token, WOL_TOKEN)

    def do_GET(self):
        if self.path == "/status":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/wake":
            self._send_json(404, {"error": "not found"})
            return

        if not WOL_TOKEN or not self._authorized():
            self._send_json(401, {"error": "unauthorized"})
            return

        try:
            subprocess.run(
                ["wakeonlan", "-i", WOL_BROADCAST, WOL_MAC],
                check=True,
                capture_output=True,
                timeout=10,
            )
        except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired) as exc:
            self._send_json(500, {"error": f"failed to send magic packet: {exc}"})
            return

        self._send_json(200, {"status": "sent", "mac": WOL_MAC, "broadcast": WOL_BROADCAST})


def main():
    if not WOL_TOKEN:
        sys.stderr.write("WARNING: WOL_TOKEN is not set; /wake will reject all requests\n")
    server = ThreadingHTTPServer(("0.0.0.0", WOL_PORT), Handler)
    sys.stderr.write(f"wol-api listening on 0.0.0.0:{WOL_PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
