import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TARGET_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._send(200, {"status": "ok"})

    def do_POST(self):
        if self.path != "/deploy":
            return self._send(404, {"error": "not found"})
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        target, tag, apply = req.get("target"), str(req.get("tag", "")), bool(req.get("apply"))
        if not TARGET_RE.match(str(target)) or not TAG_RE.match(tag) or tag == "latest":
            return self._send(400, {"error": "target/tag invalidos"})
        cmd = ["bash", "/deploy/deploy-ecs.sh", "deploy", target, tag] + (["--apply"] if apply else [])
        try:
            p = subprocess.run(cmd, input=target + "\n", capture_output=True, text=True, timeout=1800, env=os.environ)
            self._send(200, {"exitCode": p.returncode, "output": p.stdout + p.stderr})
        except subprocess.TimeoutExpired:
            self._send(200, {"exitCode": 124, "output": "timeout"})


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
