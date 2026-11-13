"""A small stand-in for the Backblaze B2 native API (v4), for tests and the restore drill only. It is NOT B2: it proves our client follows the
documented call sequence (authorize -> get_upload_url -> upload with X-Bz-Content-Sha1 -> list -> download by id) and handles the failure cases we
care about (wrong key, key without a capability, 503 on upload, checksum mismatch). Real B2 behaviour is only proven by a run against B2."""
import base64
import hashlib
import json
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeB2:
    def __init__(self, bucket_id="4a48fe8875c6214145260818", keys=None):
        # keys: {applicationKeyId: (applicationKey, {capabilities})}
        self.bucket_id = bucket_id
        self.keys = keys or {"keyW": ("secretW", {"writeFiles", "listFiles"}), "keyR": ("secretR", {"listFiles", "readFiles"})}
        self.files = []              # [{fileId, fileName, bytes, sha1, version}]
        self.fail_uploads = 0        # next N uploads answer 503
        self.corrupt_next_ack = False
        self.tokens = {}             # token -> capabilities
        self.upload_calls = 0
        self.log = []                # (method, path) only, never headers
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, code, obj=None, raw=None, headers=None):
                body = raw if raw is not None else json.dumps(obj or {}).encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(body)))
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def _json(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n) or b"{}")

            def _caps(self):
                return outer.tokens.get(self.headers.get("Authorization", ""))

            def do_GET(self):
                u = urllib.parse.urlparse(self.path)
                outer.log.append(("GET", u.path))
                if u.path.endswith("/b2_authorize_account"):
                    try:
                        kid, key = base64.b64decode(self.headers["Authorization"].split()[1]).decode().split(":", 1)
                    except Exception:
                        return self._send(401, {"code": "unauthorized"})
                    if kid not in outer.keys or outer.keys[kid][0] != key:
                        return self._send(401, {"code": "bad_auth_token"})
                    token = "tok-" + hashlib.sha1((kid + str(len(outer.tokens))).encode()).hexdigest()[:16]
                    outer.tokens[token] = outer.keys[kid][1]
                    base = f"http://127.0.0.1:{outer.port}"
                    return self._send(200, {"authorizationToken": token, "accountId": "acct",
                                            "apiInfo": {"storageApi": {"apiUrl": base, "downloadUrl": base, "s3ApiUrl": base,
                                                                         "allowed": {"capabilities": sorted(outer.keys[kid][1]),
                                                                                     "buckets": [{"id": outer.bucket_id, "name": "fake"}], "namePrefix": None}}}})
                if u.path.endswith("/b2_download_file_by_id"):
                    caps = self._caps()
                    if caps is None:
                        return self._send(401, {"code": "bad_auth_token"})
                    if "readFiles" not in caps:
                        return self._send(401, {"code": "unauthorized", "message": "capability readFiles required"})
                    fid = urllib.parse.parse_qs(u.query).get("fileId", [""])[0]
                    f = next((x for x in outer.files if x["fileId"] == fid), None)
                    if not f:
                        return self._send(404, {"code": "not_found"})
                    return self._send(200, raw=f["bytes"], headers={"X-Bz-Content-Sha1": f["sha1"], "X-Bz-File-Name": urllib.parse.quote(f["fileName"])})
                self._send(404, {"code": "not_found"})

            def do_POST(self):
                u = urllib.parse.urlparse(self.path)
                outer.log.append(("POST", u.path))
                if u.path.startswith("/upload/"):
                    outer.upload_calls += 1
                    caps = self._caps()
                    if caps is None or "writeFiles" not in caps:
                        return self._send(401, {"code": "unauthorized"})
                    n = int(self.headers.get("Content-Length") or 0)
                    data = self.rfile.read(n)
                    if outer.fail_uploads > 0:
                        outer.fail_uploads -= 1
                        return self._send(503, {"code": "service_unavailable"})
                    sha1 = self.headers.get("X-Bz-Content-Sha1", "")
                    if sha1 != hashlib.sha1(data).hexdigest():
                        return self._send(400, {"code": "bad_request", "message": "Sha1 did not match data received"})
                    name = urllib.parse.unquote(self.headers["X-Bz-File-Name"])
                    f = {"fileId": f"4_zfake_{len(outer.files):06d}", "fileName": name, "bytes": data, "sha1": sha1}
                    outer.files.append(f)
                    ack_sha = "0" * 40 if outer.corrupt_next_ack else sha1
                    outer.corrupt_next_ack = False
                    return self._send(200, {"fileId": f["fileId"], "fileName": name, "contentSha1": ack_sha, "contentLength": len(data), "bucketId": outer.bucket_id})
                body = self._json()
                caps = self._caps()
                if caps is None:
                    return self._send(401, {"code": "bad_auth_token"})
                if u.path.endswith("/b2_get_upload_url"):
                    if "writeFiles" not in caps:
                        return self._send(401, {"code": "unauthorized", "message": "capability writeFiles required"})
                    if body.get("bucketId") != outer.bucket_id:
                        return self._send(400, {"code": "bad_bucket_id"})
                    up_token = "up-" + hashlib.sha1(str(len(outer.tokens)).encode()).hexdigest()[:12]
                    outer.tokens[up_token] = {"writeFiles"}
                    return self._send(200, {"bucketId": outer.bucket_id, "uploadUrl": f"http://127.0.0.1:{outer.port}/upload/{outer.bucket_id}", "authorizationToken": up_token})
                if u.path.endswith("/b2_list_file_names"):
                    if "listFiles" not in caps:
                        return self._send(401, {"code": "unauthorized"})
                    pre = body.get("prefix") or ""
                    items = [{"fileId": f["fileId"], "fileName": f["fileName"], "contentLength": len(f["bytes"]), "contentSha1": f["sha1"], "action": "upload"}
                             for f in outer.files if f["fileName"].startswith(pre)]
                    return self._send(200, {"files": items, "nextFileName": None})
                self._send(404, {"code": "not_found"})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.port = self.server.server_address[1]
        self.url = f"http://127.0.0.1:{self.port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *a):
        self.server.shutdown()
        self.server.server_close()

    @property
    def auth_url(self):
        return f"{self.url}/b2api/v4/b2_authorize_account"
