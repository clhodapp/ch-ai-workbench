# SPDX-License-Identifier: MIT
"""A System One server for the tic-check checks: POST /v1/systemone answers every noul
question with the probability ANSWERS (a JSON file of {dimension: probability}, re-read on
each request) gives it, 0.05 when it gives none, and appends each request body as one JSON
line to LOG.

usage: stub-systemone.py PORT ANSWERS LOG
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, answers_path, log_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(log_path, "a") as log:
            log.write(json.dumps(body) + "\n")
        with open(answers_path) as f:
            probs = json.load(f)
        out = json.dumps(
            {
                "model": body["model"],
                "answers": {name: {"type": "noul", "noul": probs.get(name, 0.05)} for name in body["questions"]},
                "usage": {"input_tokens": 1, "output_tokens": 0},
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, format, *args):
        pass


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
