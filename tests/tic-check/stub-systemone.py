# SPDX-License-Identifier: MIT
"""A System One server for the tic-check checks: POST /v1/systemone answers every noul
question with the probability ANSWERS (a JSON file of {dimension: value}, re-read on each
request) gives it, 0.05 when it gives none, and every score question with the level
probabilities ANSWERS gives it as a list, all on the first level when it gives none. Each
request body is appended as one JSON line to LOG.

usage: stub-systemone.py PORT ANSWERS LOG
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, answers_path, log_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]


def answer(question, value):
    if question["type"] == "score":
        n = len(question["criteria"])
        probs = value or [1.0] + [0.0] * (n - 1)
        return {
            "type": "score",
            "score": sum(i * p for i, p in enumerate(probs)),
            "legend": {str(i): level for i, level in enumerate(question["criteria"])},
            "probabilities": {str(i): p for i, p in enumerate(probs)},
            "confidence": max(probs),
        }
    return {"type": "noul", "noul": 0.05 if value is None else value}


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
                "answers": {name: answer(q, probs.get(name)) for name, q in body["questions"].items()},
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
