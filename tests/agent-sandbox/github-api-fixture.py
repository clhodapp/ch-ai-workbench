# SPDX-License-Identifier: MIT
"""Isolated VM GitHub endpoint. Accept only the VM's disposable keyring token."""
import http.server
import json
import ssl
import sys


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        valid = self.headers.get("Authorization", "").split()[-1:] == ["ghp_vm_keyring_fixture"]
        body = json.dumps({"login": "vm-alice"} if valid else {"message": "Requires authentication"}).encode()
        self.send_response(200 if valid else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.2", 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
