#!/usr/bin/env python3
# Minimal npm-registry HTTP fixture for SwiftOS npm install smoke tests.
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
FIXTURE = ROOT / "fixtures" / "npm-registry"
PACKAGES = {
    "is-odd": ("is-odd-packument.json", {"3.0.1": "is-odd-3.0.1.tgz"}),
    "is-number": ("is-number-packument.json", {"6.0.0": "is-number-6.0.0.tgz"}),
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("npm-registry: " + (fmt % args) + "\n")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        for name, (pack_name, tarballs) in PACKAGES.items():
            if path in (f"/{name}", f"/{name}/"):
                raw = (FIXTURE / pack_name).read_text()
                body = raw.replace("http://REGISTRY", f"http://{self.headers.get('Host', '127.0.0.1')}")
                self._ok(body.encode(), "application/json")
                return
            for version, tb_name in tarballs.items():
                if path == f"/{name}/-/{tb_name}":
                    body = (FIXTURE / tb_name).read_bytes()
                    self._ok(body, "application/octet-stream")
                    return
        self.send_error(404, "not found")

    def _ok(self, body: bytes, ctype: str):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} PORT", file=sys.stderr)
        return 2
    port = int(sys.argv[1])
    for name, (pack_name, tarballs) in PACKAGES.items():
        if not (FIXTURE / pack_name).is_file():
            print(f"missing {FIXTURE / pack_name}", file=sys.stderr)
            return 2
        for tb in tarballs.values():
            if not (FIXTURE / tb).is_file():
                print(f"missing {FIXTURE / tb}", file=sys.stderr)
                return 2
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())