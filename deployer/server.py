import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TARGET_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SCRIPT = "/deploy/deploy-ecs.sh"


def run(args, target):
    try:
        p = subprocess.run(
            ["bash", SCRIPT, *args],
            input=target + "\n",
            capture_output=True,
            text=True,
            timeout=1800,
            env=os.environ,
        )
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return 124, "timeout"


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
        length = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(length) or b"{}")
        target = str(req.get("target", ""))
        if not TARGET_RE.match(target):
            return self._send(400, {"error": "target invalido"})

        if self.path == "/deploy":
            tag = str(req.get("tag", ""))
            if not TAG_RE.match(tag) or tag == "latest":
                return self._send(400, {"error": "tag invalida"})
            apply = bool(req.get("apply"))
            code, out = run(["deploy", target, tag] + (["--apply"] if apply else []), target)
            applied = apply and "update-service enviado" in out
            return self._send(200, {"exitCode": code, "applied": applied, "output": out})

        if self.path == "/rollback":
            code, out = run(["rollback", target], target)
            return self._send(200, {"exitCode": code, "output": out})

        self._send(404, {"error": "not found"})


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
