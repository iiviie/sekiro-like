#!/usr/bin/env python3
"""Tiny localhost sink: POST /<name> writes the body to recs/<name>.json (Studio play server -> disk)."""
import http.server, os, re, sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "recs")
os.makedirs(OUT, exist_ok=True)

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        name = re.sub(r"[^A-Za-z0-9_.-]", "_", self.path.strip("/")) or "rec"
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        with open(os.path.join(OUT, name + ".json"), "wb") as f:
            f.write(body)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok %d" % n)
        print("got", name, n, flush=True)

    def log_message(self, *a):
        pass

http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 8766), H).serve_forever()
