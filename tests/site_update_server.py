#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# site_update_server.py — a tiny HTTPS file server for the SU-C site-update test.
# Serves files from a directory over TLS so the guest's `/bin/swupdate site <url>`
# can fetch a signed SWSITE bundle. The guest does not verify the certificate (the
# bundle's Ed25519 signature is the trust anchor), so a self-signed cert is fine.
#
# Usage: site_update_server.py PORT CERT KEY DIR

import sys, ssl, os
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
CERT = sys.argv[2]
KEY = sys.argv[3]
DIR = sys.argv[4]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"   # close after each response (EOF-delimited body)

    def do_GET(self):
        name = os.path.basename(self.path.lstrip("/")) or "index.html"
        path = os.path.join(DIR, name)
        if not os.path.isfile(path):
            self.send_response(404)
            self.send_header("Connection", "close")
            self.end_headers()
            return
        with open(path, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


httpd = HTTPServer(("0.0.0.0", PORT), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
