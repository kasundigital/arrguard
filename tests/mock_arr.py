import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

QUEUE = json.load(open(sys.argv[1]))
LOG = open(sys.argv[2], "a")

class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/api/v3/system/status"): return self._send(200, {"version": "4.0"})
        if self.path.startswith("/api/v3/queue"): return self._send(200, {"records": QUEUE})
        self._send(404, {})
    def do_DELETE(self):
        LOG.write(f"DELETE {self.path}\n"); LOG.flush(); self._send(200, {})
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        try:
            json.loads(body); LOG.write(f"POST {self.path} OK {body}\n"); LOG.flush(); self._send(201, {})
        except Exception:
            LOG.write(f"POST {self.path} INVALID-JSON {body}\n"); LOG.flush(); self._send(400, {"error": "bad json"})

HTTPServer(("127.0.0.1", int(sys.argv[3])), H).serve_forever()
