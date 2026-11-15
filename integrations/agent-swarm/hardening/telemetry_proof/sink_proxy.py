"""Loopback sink: logs (a) telemetry POSTs and (b) any proxy-style request (CONNECT / absolute URI) and refuses them.
Stdlib only. Binds 127.0.0.1 only."""
import http.server, sys, time, json
LOG = sys.argv[2]
def log(kind, detail):
    with open(LOG, "a") as f:
        f.write(json.dumps({"t": round(time.time(), 2), "kind": kind, "detail": detail[:600]}) + "\n")
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def _any(self):
        n = int(self.headers.get("content-length", 0) or 0)
        body = self.rfile.read(n).decode("utf8", "replace") if n else ""
        if self.path.startswith("http://") or self.path.startswith("https://"):
            log("PROXIED_REQUEST", f"{self.command} {self.path}")
        else:
            log("DIRECT_LOOPBACK_REQUEST", f"{self.command} {self.path} {body}")
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    do_GET = do_POST = do_PUT = _any
    def do_CONNECT(self):
        log("PROXIED_CONNECT", self.path)
        self.send_response(403); self.end_headers()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
