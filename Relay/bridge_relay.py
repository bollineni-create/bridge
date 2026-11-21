#!/usr/bin/env python3
"""Bridge relay: lets the Bridge app on the iPhone Duo see the board and act on it, through iCloud.

Every few seconds it
  1. copies a slim version of the engine's snapshot to  claude-bridge/live/companion.json
  2. runs requests the phone dropped in                 claude-bridge/live/requests/<id>.json
     and answers in                                     claude-bridge/live/results/<id>.json

Only a fixed list of bridge commands can run, always as the owner (the CLI's default actor), never through a shell.
Standard library only. Runs as the LaunchAgent com.naren.bridge.relay; log at /tmp/bridge-relay.log.
"""
import json, os, re, subprocess, sys, time

HOME = os.path.expanduser("~")
SNAPSHOT = os.path.join(HOME, "Library/Application Support/Bridge/snapshot.json")
FOLDER = os.environ.get("BRIDGE_RELAY_FOLDER") or os.path.join(HOME, "Library/Mobile Documents/com~apple~CloudDocs/AI/claude-bridge")
LIVE = os.path.join(FOLDER, "live")
REQ, RES, DONE = (os.path.join(LIVE, d) for d in ("requests", "results", "processed"))
BRIDGE = next((p for p in ("/opt/homebrew/bin/bridge", "/usr/local/bin/bridge") if os.access(p, os.X_OK)), "bridge")

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
    args = req.get("args")
    if allowed(args):
        try:
            p = subprocess.run([BRIDGE] + args, capture_output=True, text=True, timeout=90,
                               env={**os.environ, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "BRIDGE_AS": ""})
            ok, out = p.returncode == 0, (p.stdout + p.stderr).strip()
        except subprocess.TimeoutExpired:
            ok, out = False, "ERROR: took too long on the Mac"
        log("ran %s -> %s" % (" ".join(args[:2])[:80], "ok" if ok else out[-120:]))
    else:
        ok, out = False, "ERROR: Bridge on the Mac doesn't take that from the phone"
        log("refused %r" % (args,))
    write_json(os.path.join(RES, rid + ".json"), {"id": rid, "ok": ok, "out": out[-6000:], "ts": time.time()})
    os.replace(path, os.path.join(DONE, name))


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
    n = 0
    wait = waiter()
    while True:
        publish()
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
