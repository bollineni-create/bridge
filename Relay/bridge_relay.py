#!/usr/bin/env python3
"""Bridge relay: lets the Bridge app on the iPhone Duo see the board and act on it.

Two paths, the phone tries them in this order:
  Direct (Tailscale): a tiny HTTP server on 127.0.0.1:7787, published only to the owner's own tailnet with
     `tailscale serve` (tailnet port 7788). GET /companion is the board, POST /run {"args": [...]} runs one
     allowlisted command. Every request needs the pairing key (Authorization: Bearer <key>), kept in
     ~/Library/Application Support/Bridge/phone_token and handed to the phone in live/phone-link.json.
  iCloud (fallback, slow: iCloud can take minutes): every few seconds it
  1. copies a slim version of the engine's snapshot to  claude-bridge/live/companion.json
  2. runs requests the phone dropped in                 claude-bridge/live/requests/<id>.json
     and answers in                                     claude-bridge/live/results/<id>.json

Only a fixed list of bridge commands can run, always as the owner (the CLI's default actor), never through a shell.
Standard library only. Runs as the LaunchAgent com.naren.bridge.relay; log at /tmp/bridge-relay.log.
"""
import hmac, http.server, json, os, re, secrets, subprocess, sys, threading, time

HOME = os.path.expanduser("~")
SNAPSHOT = os.path.join(HOME, "Library/Application Support/Bridge/snapshot.json")
FOLDER = os.environ.get("BRIDGE_RELAY_FOLDER") or os.path.join(HOME, "Library/Mobile Documents/com~apple~CloudDocs/AI/claude-bridge")
LIVE = os.path.join(FOLDER, "live")
REQ, RES, DONE = (os.path.join(LIVE, d) for d in ("requests", "results", "processed"))
BRIDGE = next((p for p in ("/opt/homebrew/bin/bridge", "/usr/local/bin/bridge") if os.access(p, os.X_OK)), "bridge")

PORT = int(os.environ.get("BRIDGE_PHONE_PORT", "7787"))          # local only
TS_PORT = PORT + 1                                                 # what the tailnet sees
TOKEN_FILE = os.path.join(HOME, "Library/Application Support/Bridge/phone_token")
LINK = os.path.join(LIVE, "phone-link.json")
TS = next((p for p in ("/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale")
           if os.access(p, os.X_OK)), None)

ID_RE = re.compile(r"^[TNA]\d{1,6}$")
WHO = {"auto", "local", "pro", "ultra"}


def allowed(args):
    """True only for the commands the phone's buttons send, with sane arguments."""
    if not isinstance(args, list) or not args or not all(isinstance(a, str) for a in args):
        return False
    if any(len(a) > 4000 for a in args) or len(args) > 11:
        return False
    cmd, rest = args[0], args[1:]
    if cmd in ("done", "resolve"):
        return len(rest) in (1, 2) and ID_RE.match(rest[0]) is not None
    if cmd == "reply":
        return len(rest) == 2 and rest[0].startswith("T") and ID_RE.match(rest[0]) is not None and bool(rest[1].strip())
    if cmd in ("approve", "deny"):
        return len(rest) == 1 and rest[0].startswith("A") and ID_RE.match(rest[0]) is not None
    if cmd == "assign":
        return len(rest) == 2 and rest[0].startswith("T") and ID_RE.match(rest[0]) is not None and rest[1] in (WHO - {"auto"}) | {"any"}
    if cmd in ("ask", "route", "clarify"):
        if not rest or rest[0].startswith("-"):
            return False
        flags = rest[1:]
        if len(flags) % 2:
            return False
        for k, v in zip(flags[::2], flags[1::2]):
            if k == "--who" and v in WHO:
                continue
            if k == "--where" and v in ("auto", "new", "open", "project"):
                continue
            if k == "--project" and re.match(r"^[a-z +]{1,40}$", v):
                continue
            if k == "--chat" and 0 < len(v) <= 200:
                continue
            return False
        return True
    return False


def log(msg):
    sys.stdout.write(time.strftime("%H:%M:%S ") + msg + "\n")
    sys.stdout.flush()


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


def slim(snap):
    """Only what the companion shows. Done tasks from the last 2 days, open ones all."""
    cutoff = time.time() - 2 * 86400
    tasks = [t for t in snap.get("tasks", []) if t.get("status") != "done" or (t.get("done_ts") or 0) > cutoff]
    keep_t = ("id", "title", "for", "status", "holder", "live", "due", "overdue", "result", "output", "progress", "done_ts")
    keep_r = ("id", "state", "text", "note", "detail", "since", "app", "probe")
    return {
        "generated": snap.get("generated") or time.time(),
        "runners": [{k: r.get(k) for k in keep_r} for r in snap.get("runners", [])],
        "tasks": [{k: t.get(k) for k in keep_t} for t in tasks][:300],
        "counts": snap.get("counts", {}),
        "attention": snap.get("attention", []),
        "actions": [{k: a.get(k) for k in ("id", "kind", "summary", "status")} for a in snap.get("actions", []) if a.get("status") == "approval"],
    }


_last = {"body": None, "at": 0.0}


def publish():
    try:
        with open(SNAPSHOT, encoding="utf-8") as f:
            snap = json.load(f)
    except (OSError, ValueError):
        return
    s = slim(snap)
    body = json.dumps({k: v for k, v in s.items() if k != "generated"}, sort_keys=True)
    # Only write when something changed, or every 30 s so the phone can tell the Mac is alive.
    if body == _last["body"] and time.time() - _last["at"] < 30:
        return
    write_json(os.path.join(LIVE, "companion.json"), s)
    _last.update(body=body, at=time.time())


def run_args(args):
    """Run one allowlisted command as the owner; (ok, output)."""
    if not allowed(args):
        log("refused %r" % (args,))
        return False, "ERROR: Bridge on the Mac doesn't take that from the phone"
    try:
        p = subprocess.run([BRIDGE] + args, capture_output=True, text=True, timeout=90,
                           env={**os.environ, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "BRIDGE_AS": ""})
        ok, out = p.returncode == 0, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        ok, out = False, "ERROR: took too long on the Mac"
    log("ran %s -> %s" % (" ".join(args[:2])[:80], "ok" if ok else out[-120:]))
    return ok, out


def handle(name):
    path = os.path.join(REQ, name)
    if name.startswith(".") and name.endswith(".icloud"):           # not downloaded yet
        subprocess.run(["brctl", "download", path], capture_output=True)
        return
    if not name.endswith(".json"):
        return
    try:
        with open(path, encoding="utf-8") as f:
            req = json.load(f)
    except (OSError, ValueError):
        return
    rid = str(req.get("id") or name[:-5])
    if not re.match(r"^[A-Za-z0-9-]{8,64}$", rid):
        os.replace(path, os.path.join(DONE, name))
        return
    ok, out = run_args(req.get("args"))
    write_json(os.path.join(RES, rid + ".json"), {"id": rid, "ok": ok, "out": out[-6000:], "ts": time.time()})
    os.replace(path, os.path.join(DONE, name))


# ------------------------------------------------------------------ direct path (Tailscale)
def phone_token():
    """The pairing key the phone must send. Made once, readable only by the owner."""
    try:
        t = open(TOKEN_FILE, encoding="utf-8").read().strip()
    except OSError:
        t = ""
    if len(t) < 32:
        t = secrets.token_urlsafe(32)
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, t.encode())
        os.close(fd)
    return t


class PhoneHandler(http.server.BaseHTTPRequestHandler):
    server_version = "Bridge"
    token = ""

    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(b)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(b)
        except (BrokenPipeError, ConnectionResetError):
            pass                        # the phone gave up waiting; nothing to tell it

    def _authed(self):
        return bool(self.token) and hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + self.token)

    def do_GET(self):
        if not self._authed():
            return self._send(401, {"ok": False, "out": "ERROR: this phone isn't paired with Bridge"})
        if self.path.split("?")[0] == "/companion":
            try:
                with open(SNAPSHOT, encoding="utf-8") as f:
                    board = slim(json.load(f))
            except (OSError, ValueError):
                return self._send(503, {"ok": False, "out": "ERROR: the engine hasn't written a snapshot"})
            return self._send(200, board)
        if self.path == "/ping":
            return self._send(200, {"ok": True, "ts": time.time()})
        self._send(404, {"ok": False, "out": "ERROR: not found"})

    def do_POST(self):
        if not self._authed():
            return self._send(401, {"ok": False, "out": "ERROR: this phone isn't paired with Bridge"})
        if self.path != "/run":
            return self._send(404, {"ok": False, "out": "ERROR: not found"})
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > 20000:
            return self._send(413, {"ok": False, "out": "ERROR: request too large"})
        try:
            args = json.loads(self.rfile.read(n)).get("args")
        except (ValueError, AttributeError):
            return self._send(400, {"ok": False, "out": "ERROR: bad request"})
        t0 = time.time()
        ok, out = run_args(args)
        log("direct %s from %s in %.2fs" % ((args or ["?"])[0], self.client_address[0], time.time() - t0))
        self._send(200, {"ok": ok, "out": out[-6000:], "ts": time.time()})


_server = {"up": False}


def start_server():
    """Bind 127.0.0.1 only: nothing on the Wi-Fi or the internet can reach it; Tailscale serve forwards the tailnet to it."""
    if _server["up"]:
        return
    PhoneHandler.token = phone_token()
    try:
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), PhoneHandler)
    except OSError as e:
        log("phone server not started: %s" % e)
        return
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, name="phone-server", daemon=True).start()
    _server["up"] = True
    log("phone server on 127.0.0.1:%d" % PORT)


def ts_run(args, timeout):
    """The Tailscale CLI. The app's binary opens the GUI unless told it is being used as a CLI (true under launchd)."""
    return subprocess.run([TS] + args, capture_output=True, text=True, timeout=timeout, env={**os.environ, "TAILSCALE_BE_CLI": "1"})


def tailnet():
    """This Mac on the owner's tailnet, once Tailscale is installed and signed in: {"host", "ip"} or None."""
    if not TS:
        return None
    try:
        j = json.loads(ts_run(["status", "--json"], 8).stdout or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    if j.get("BackendState") != "Running":
        return None
    me = j.get("Self") or {}
    ip = next((i for i in (me.get("TailscaleIPs") or []) if "." in i), "")
    host = (me.get("DNSName") or "").rstrip(".")
    return {"host": host, "ip": ip} if (host or ip) else None


_link = {"at": 0.0, "body": None}


def ensure_link():
    """Every minute: publish the local server to the tailnet (never Funnel) and tell the phone where it is."""
    if time.time() - _link["at"] < 60:
        return
    _link["at"] = time.time()
    t = tailnet()
    if not t:
        return
    try:
        st = ts_run(["serve", "status", "--json"], 8).stdout or ""
        if (":%d" % TS_PORT) not in st:
            r = ts_run(["serve", "--bg", "--http=%d" % TS_PORT, "http://127.0.0.1:%d" % PORT], 15)
            log("tailscale serve :%d -> %s" % (TS_PORT, "ok" if r.returncode == 0 else (r.stderr or r.stdout).strip()[-160:]))
    except (OSError, subprocess.TimeoutExpired) as e:
        log("tailscale serve failed: %s" % e)
        return
    link = {"v": 1, "url": "http://%s:%d" % (t["host"], TS_PORT) if t["host"] else "", "ip_url": "http://%s:%d" % (t["ip"], TS_PORT) if t["ip"] else "",
            "token": PhoneHandler.token}
    body = json.dumps(link, sort_keys=True)
    if body != _link["body"]:
        write_json(LINK, dict(link, updated=time.time()))
        try:
            os.chmod(LINK, 0o600)
        except OSError:
            pass
        _link["body"] = body
        log("phone link: %s" % (link["url"] or link["ip_url"]))


def prune():
    """Results and processed requests older than a day go."""
    cut = time.time() - 86400
    for d in (RES, DONE):
        for n in os.listdir(d):
            p = os.path.join(d, n)
            try:
                if os.path.getmtime(p) < cut:
                    os.remove(p)
            except OSError:
                pass


def waiter():
    """Sleep until something happens: a request lands, or the engine rewrites the snapshot (every second).
    kqueue on both folders, so a phone request runs the moment iCloud delivers it. Falls back to a plain sleep."""
    try:
        import select
        kq = select.kqueue()
        evs = []
        for d in (REQ, os.path.dirname(SNAPSHOT)):
            fd = os.open(d, os.O_RDONLY)
            evs.append(select.kevent(fd, filter=select.KQ_FILTER_VNODE, flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE))
        kq.control(evs, 0, 0)
        return lambda t: kq.control(None, 4, t)
    except Exception:
        return time.sleep


def main():
    for d in (LIVE, REQ, RES, DONE):
        os.makedirs(d, exist_ok=True)
    once = "--once" in sys.argv
    log("relay up · %s" % LIVE)
    start_server()
    n = 0
    wait = waiter()
    while True:
        publish()
        ensure_link()
        # macOS can sit on a file the phone added to iCloud for minutes; asking for the folder pulls it down now.
        try:
            subprocess.run(["brctl", "download", REQ], capture_output=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass
        for name in sorted(os.listdir(REQ)):
            try:
                handle(name)
            except Exception as e:  # one bad request never stops the relay
                log("error on %s: %s" % (name, e))
        n += 1
        if n % 600 == 0:
            prune()
        if once:
            return
        wait(3)


if __name__ == "__main__":
    main()
