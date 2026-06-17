#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# acme_mock_server.py — a deliberately tiny mock ACME (RFC 8555) server for
# exercising the SwiftOS native ACME client (/bin/acme) end-to-end over real
# TLS, WITHOUT the heavy Pebble + inbound-challenge-validation infrastructure.
#
# It speaks just enough of the protocol to drive the client through the full
# flow (directory -> newNonce -> newAccount -> newOrder -> authz -> challenge ->
# finalize -> certificate), auto-"validating" the http-01 challenge instead of
# fetching it back from the guest. It does NOT verify the client's JWS
# signatures (the host p256/jose tests already cover signing); instead it
# captures the finalize CSR so the harness can validate it with `openssl req
# -verify`. TLS is a self-signed cert; the client does not verify certificates.
#
# Usage: acme_mock_server.py PORT CERT KEY BASE_URL ISSUED_PEM CSR_OUT REQLOG

import sys, ssl, json, base64
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT      = int(sys.argv[1])
CERT      = sys.argv[2]
KEY       = sys.argv[3]
BASE      = sys.argv[4].rstrip("/")
ISSUED    = sys.argv[5]
CSR_OUT   = sys.argv[6]
REQLOG    = sys.argv[7]

with open(ISSUED, "rb") as f:
    ISSUED_PEM = f.read()

STATE = {"nonce": 0, "challenge_posted": False, "finalized": False}


def b64u_decode(s: str) -> bytes:
    s = s + "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)


def log(line: str):
    with open(REQLOG, "a") as f:
        f.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # close after each response -> client reads to EOF

    def log_message(self, *a):       # silence stderr access log
        pass

    def _nonce(self) -> str:
        STATE["nonce"] += 1
        return f"nonce{STATE['nonce']:08d}"

    def _send(self, code, body=b"", ctype="application/json", location=None):
        self.send_response(code)
        self.send_header("Replay-Nonce", self._nonce())
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if location:
            self.send_header("Location", location)
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, code, obj, location=None):
        self._send(code, json.dumps(obj).encode(), "application/json", location)

    def _read_body(self) -> bytes:
        n = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(n) if n else b""

    def do_HEAD(self):
        log(f"HEAD {self.path}")
        if self.path == "/newNonce":
            self._send(200)
        else:
            self._send(405)

    def do_GET(self):
        log(f"GET {self.path}")
        if self.path == "/directory":
            self._json(200, {
                "newNonce":   f"{BASE}/newNonce",
                "newAccount": f"{BASE}/newAccount",
                "newOrder":   f"{BASE}/newOrder",
                "keyChange":  f"{BASE}/keyChange",
                "revokeCert": f"{BASE}/revokeCert",
            })
        elif self.path == "/newNonce":
            self._send(200)
        else:
            self._send(404)

    def do_POST(self):
        body = self._read_body()
        log(f"POST {self.path} {len(body)}B")
        if self.path == "/newAccount":
            self._json(201, {"status": "valid"}, location=f"{BASE}/account/1")
        elif self.path == "/newOrder":
            self._json(201, {
                "status": "pending",
                "identifiers": [{"type": "dns", "value": "example.test"}],
                "authorizations": [f"{BASE}/authz/1"],
                "finalize": f"{BASE}/finalize/1",
            }, location=f"{BASE}/order/1")
        elif self.path == "/authz/1":
            status = "valid" if STATE["challenge_posted"] else "pending"
            chal_status = "valid" if STATE["challenge_posted"] else "pending"
            self._json(200, {
                "status": status,
                "identifier": {"type": "dns", "value": "example.test"},
                "challenges": [{
                    "type": "http-01",
                    "url": f"{BASE}/chal/1",
                    "token": "MOCKTOKEN-abc123",
                    "status": chal_status,
                }],
            })
        elif self.path == "/chal/1":
            STATE["challenge_posted"] = True
            self._json(200, {"type": "http-01", "url": f"{BASE}/chal/1",
                             "token": "MOCKTOKEN-abc123", "status": "processing"})
        elif self.path == "/finalize/1":
            # Capture the CSR for external validation by the harness.
            try:
                jws = json.loads(body.decode())
                payload = json.loads(b64u_decode(jws["payload"]).decode())
                der = b64u_decode(payload["csr"])
                with open(CSR_OUT, "wb") as f:
                    f.write(der)
                log(f"captured CSR {len(der)}B")
            except Exception as e:
                log(f"CSR capture failed: {e}")
            STATE["finalized"] = True
            self._json(200, {
                "status": "valid",
                "finalize": f"{BASE}/finalize/1",
                "certificate": f"{BASE}/cert/1",
                "authorizations": [f"{BASE}/authz/1"],
            }, location=f"{BASE}/order/1")
        elif self.path == "/order/1":
            st = "valid" if STATE["finalized"] else "pending"
            obj = {"status": st, "finalize": f"{BASE}/finalize/1",
                   "authorizations": [f"{BASE}/authz/1"]}
            if STATE["finalized"]:
                obj["certificate"] = f"{BASE}/cert/1"
            self._json(200, obj)
        elif self.path == "/cert/1":
            self._send(200, ISSUED_PEM, "application/pem-certificate-chain")
        else:
            self._send(404)


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_cert_chain(CERT, KEY)
    httpd = HTTPServer(("0.0.0.0", PORT), Handler)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    log(f"mock ACME server listening on {PORT}, base {BASE}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
