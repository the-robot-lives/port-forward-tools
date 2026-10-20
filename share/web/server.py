#!/usr/bin/env python3
"""cluster-port-forward web/API server — stdlib only, loopback-only.

Spawned by the daemon (`cluster-port-forward __daemon-loop`). Serves the web UI
and the local JSON API on 127.0.0.1:$CPF_WEB_PORT. GETs are computed from the
shared state TSV + socket probes; mutations exec the cluster-port-forward CLI
(hidden __api-* commands) so every input is validated by the existing
profile/spec parser — never interpolated raw into shell commands.
"""
import json
import os
import re
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("CPF_WEB_PORT", "4321"))
STATE_FILE = os.environ.get("CPF_DAEMON_STATE", "")
BIN = os.environ.get("CPF_WEB_BIN", "cluster-port-forward")
SHARE_DIR = os.environ.get("CPF_WEB_SHARE", "")
L2K_HOST = os.environ.get("CPF_WEB_L2K_HOST", "127.0.0.1")
DAEMON_PID = os.environ.get("CPF_DAEMON_PID", "")
DAEMON_PROFILE = os.environ.get("CPF_DAEMON_PROFILE", "")

SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
SPEC_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$")
PROF_RE = re.compile(r"^[A-Za-z0-9./][A-Za-z0-9._/-]{0,200}$")  # bare name or path; no ".."
POD_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,251}$")
PORT_RE = re.compile(r"^[0-9]{1,5}$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$")
NS_RE = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")


def probe(port, host="127.0.0.1", timeout=0.6):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def pid_alive(pid):
    if not pid or not str(pid).isdigit():
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except OSError:
        return False


def read_rows():
    rows = []
    if not STATE_FILE or not os.path.isfile(STATE_FILE):
        return rows
    with open(STATE_FILE, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            c = (line.split("|") + [""] * 13)[:13]
            now = int(time.time())
            started = int(c[10]) if c[10].isdigit() else now
            port_open = probe(c[6]) if c[3] == "k2l" else probe(c[7], L2K_HOST)
            if c[3] == "l2k" and not c[9]:
                state = "offline"
            elif pid_alive(c[9]) and port_open:
                state = "online"
            elif port_open:
                state = "port-up"
            else:
                state = "offline"
            rows.append({
                "key": c[0], "slug": c[1], "kind": c[2], "direction": c[3],
                "namespace": c[4], "target": c[5], "local_port": int(c[6] or 0),
                "remote_port": int(c[7] or 0), "pod": c[8], "pid": c[9],
                "uptime": now - started, "restarts": int(c[11] or 0),
                "label": c[12], "state": state,
                "supervisor_pid": DAEMON_PID, "profile": DAEMON_PROFILE,
            })
    return rows


def run_cli(args, timeout=120):
    """Exec the CLI; returns (rc, stdout, stderr)."""
    env = dict(os.environ)
    # server-exec'd CLI must run its LOCAL supervisor path, never re-post to
    # the API (it would recurse: up → POST /api/up → up → …)
    env["CPF_API_INTERNAL"] = "1"
    try:
        p = subprocess.run([BIN] + args, capture_output=True, text=True,
                           timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


class Handler(BaseHTTPRequestHandler):
    server_version = "cpf-daemon/1.0"

    def log_message(self, fmt, *args):  # quiet
        pass

    def _send(self, code, payload, ctype="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            v = json.loads(raw.decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError):
            v = None
        if not isinstance(v, dict):
            return None
        return v

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/health":
            online = [r for r in read_rows() if r["state"] == "online"]
            rows = read_rows()
            degraded = any(r["state"] != "online" for r in rows)
            self._send(200, {
                "ok": True, "daemon_pid": DAEMON_PID, "port": PORT,
                "profile": DAEMON_PROFILE, "tunnels": len(rows),
                "online": len(online), "degraded": degraded,
            })
        elif path == "/api/tunnels":
            rows = read_rows()
            code = 200
            if rows and any(r["state"] not in ("online", "port-up") for r in rows):
                code = 503  # degraded; body still carries every row
            self._send(code, {"tunnels": rows, "profile": DAEMON_PROFILE,
                              "daemon_pid": DAEMON_PID})
        elif path in ("/", "/index.html"):
            f = os.path.join(SHARE_DIR, "index.html")
            if SHARE_DIR and os.path.isfile(f):
                with open(f, "rb") as fh:
                    self._send(200, fh.read(), "text/html; charset=utf-8")
            else:
                self._send(404, {"error": "web UI not installed"})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        body = self._json_body()
        if body is None:
            return self._send(400, {"error": "invalid JSON body"})
        try:
            if path == "/api/up":
                return self._up(body)
            if path == "/api/down":
                return self._down(body)
            if path == "/api/restart":
                return self._restart(body)
            if path == "/api/repoint":
                return self._repoint(body)
            if path == "/api/setport":
                return self._setport(body)
            if path == "/api/reload":
                return self._reload(body)
            self._send(404, {"error": "not found"})
        except Exception as exc:  # never leak a traceback to a 200
            self._send(500, {"error": "internal error: %s" % exc})

    def _up(self, body):
        prof = body.get("profile") or DAEMON_PROFILE
        include = body.get("include") or []
        timeout = body.get("timeout", "30s")
        if not isinstance(prof, str) or not PROF_RE.match(prof) or ".." in prof:
            return self._send(400, {"error": "bad profile name"})
        if not isinstance(include, list) or len(include) > 64 or \
                not all(isinstance(s, str) and SPEC_RE.match(s) for s in include):
            return self._send(400, {"error": "bad include specs"})
        if not isinstance(timeout, str) or not re.match(r"^[0-9]+[smh]?$", timeout):
            return self._send(400, {"error": "bad timeout"})
        args = ["up", "--profile", prof, "--timeout", timeout, "--json"]
        for spec in include:
            args += ["--include", spec]
        rc, out, err = run_cli(args, timeout=3700)
        try:
            tunnels = json.loads(out) if out.strip().startswith("[") else []
        except ValueError:
            tunnels = []
        all_online = bool(tunnels) and rc == 0
        payload = {"ok": rc == 0, "all_online": all_online,
                   "tunnels": tunnels, "rc": rc}
        if rc != 0:
            payload["error"] = (err or out).strip()[-500:] or "up failed"
            return self._send(503, payload)
        return self._send(200, payload)

    def _down(self, body):
        slugs = body.get("slug") or []
        if body.get("all"):
            rc, out, err = run_cli(["stop", "all"])
            if rc != 0:
                return self._send(500, {"error": (err or out).strip()[-500:]})
            return self._send(200, {"ok": True, "stopped": "all"})
        if not isinstance(slugs, list) or not slugs or len(slugs) > 64 or \
                not all(isinstance(s, str) and SLUG_RE.match(s) for s in slugs):
            return self._send(400, {"error": "bad slug list"})
        rc, out, err = run_cli(["__api-stop-slugs"] + slugs)
        if rc != 0:
            return self._send(400, {"error": (err or out).strip()[-500:]})
        return self._send(200, {"ok": True, "stopped": slugs})

    def _restart(self, body):
        slug = body.get("slug")
        if not isinstance(slug, str) or not SLUG_RE.match(slug):
            return self._send(400, {"error": "bad slug"})
        rc, out, err = run_cli(["__api-restart", slug])
        if rc != 0:
            return self._send(400, {"error": (err or out).strip()[-500:]})
        return self._send(200, {"ok": True, "restarted": slug})

    def _repoint(self, body):
        lp = body.get("local_port")
        pod = body.get("pod")
        if not isinstance(lp, int) or not 1 <= lp <= 65535:
            return self._send(400, {"error": "bad local_port"})
        if not isinstance(pod, str) or not POD_RE.match(pod):
            return self._send(400, {"error": "bad pod name"})
        rc, out, err = run_cli(["__api-repoint", str(lp), pod])
        if rc != 0:
            return self._send(400, {"error": (err or out).strip()[-500:]})
        return self._send(200, {"ok": True, "repointed": {"local_port": lp, "pod": pod}})

    def _setport(self, body):
        slug = body.get("slug")
        port = body.get("port")
        if not isinstance(slug, str) or not SLUG_RE.match(slug):
            return self._send(400, {"error": "bad slug"})
        if not isinstance(port, int) or not 1 <= port <= 65535 or port % 2 != 0:
            return self._send(400, {"error": "port must be an even number in 1..65535"})
        rc, out, err = run_cli(["__api-setport", slug, str(port)])
        if rc != 0:
            return self._send(400, {"error": (err or out).strip()[-500:]})
        return self._send(200, {"ok": True, "slug": slug, "port": port})

    def _reload(self, body):
        prof = body.get("profile") or DAEMON_PROFILE
        if not isinstance(prof, str) or not PROF_RE.match(prof) or ".." in prof:
            return self._send(400, {"error": "bad profile name"})
        rc, out, err = run_cli(["profile-parse", prof])
        if rc != 0:
            return self._send(400, {"error": (err or out).strip()[-500:]})
        return self._send(200, {"ok": True, "profile": prof, "parsed": out.strip().splitlines()})


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)  # loopback only, always
    srv.serve_forever()


if __name__ == "__main__":
    main()
