"""What a WebSocket connection costs while nobody is typing.

Scenarios against `bench/ws_server.zig`, and the same scenarios against
[gws](https://github.com/lxzan/gws) in `bench/compare/gws/` — the Go library
whose low memory footprint is what put the question. Each on a freshly started
server so every reading has its own baseline. Open N sockets in steps, do at
most one message on each, then let them sit and read `VmRSS` — the method
[ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md) used for
HTTP, so all of it goes in one table.

    zig build bench-ws-server -Doptimize=ReleaseFast
    (cd bench/compare/gws && go build -o gws-bench .)

    python3 bench/ws_idle.py                 # nilo, every scenario
    python3 bench/ws_idle.py gws             # gws, every scenario it has
    python3 bench/ws_idle.py both            # both, one after the other
    python3 bench/ws_idle.py nilo ws-small   # one of them

Go's `VmRSS` includes a heap the collector has not handed back, so a raw
reading would charge gws for garbage rather than for connections. Its server
exposes `/gc`, and every gws row is read twice — as it stands, and after a
`runtime.GC()` and `debug.FreeOSMemory()`. Both are reported, because the first
is what a deployment holds and the second is what the connections cost.

The process helpers come from `bench/compare/drive.py` rather than a second
copy: reading `VmRSS` over a process tree is the one thing both harnesses have
to do identically, or their numbers cannot be compared.

Not `bench/mem.py`, which measures the same axis for HTTP. That one finds a
server by port and speaks keep-alive, and every part of this file that is not
`drive.py` is the part it could not do: the handshake, the frame writer, the
one-message-per-socket scenarios, starting a second server that is not nilo,
and the `/gc` reading Go needs. The shared half is shared; the rest is not the
same measurement wearing a different name.
"""
import json
import os
import resource
import socket
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "compare"))
from drive import rss_kb, stop, tree, wait_up  # noqa: E402

STEPS = tuple(int(s) for s in os.environ.get("STEPS", "500,1000,2000").split(","))
SETTLE = float(os.environ.get("SETTLE", "3"))

# Zero waits forever. nilo's default of 30,000 would have every fiber in the
# measurement waking to ping, which is a different thing to measure —
# `IDLE_MS=30000 python3 bench/ws_idle.py` measures that one on purpose. The
# gws server sets no deadline for the same reason.
IDLE_MS = os.environ.get("IDLE_MS", "0")

TARGETS = {
    "nilo": dict(
        label="nilo",
        cmd=[os.path.join(REPO, "zig-out", "bin", "nilo-bench-ws-server")],
        port=8789,
        env={"IDLE_MS": IDLE_MS},
        # Four WebSocket routes that differ in one thing each, so a number
        # always has something standing next to it.
        paths={"http": "/health", "idle": "/ws/idle", "small": "/ws/small",
               "big": "/ws/big", "deep": "/ws/deep"},
    ),
    "gws": dict(
        label="gws",
        cmd=[os.path.join(HERE, "compare", "gws", "gws-bench")],
        port=8790,
        env={},
        # One echo route for all of them: gws hands the handler a pooled
        # message rather than taking a buffer from it, so "how big is the
        # receive buffer" is a question its API does not have. That is the
        # comparison, not a gap in the harness.
        paths={"http": "/health", "idle": "/ws", "small": "/ws", "big": "/ws"},
        gc="/gc",
    ),
}

SCENARIOS = [
    dict(key="http", route="http", msg=None, http=True,
         label="HTTP keep-alive, one 6-byte response"),
    dict(key="ws-idle", route="idle", msg=None,
         label="WebSocket, upgraded and never spoken to"),
    dict(key="ws-small", route="small", msg=6,
         label="WebSocket, one 6-byte echo"),
    dict(key="ws-big", route="big", msg=6, skip_for={"gws"},
         label="WebSocket, 64 KiB receive buffer, one 6-byte echo"),
    dict(key="ws-big-msg", route="big", msg=60 * 1024,
         label="WebSocket, one 60 KiB echo"),
    dict(key="ws-deep", route="deep", msg=6, skip_for={"gws"},
         label="WebSocket, 64 KiB of stack touched"),
]


# ------------------------------------------------------------------ the client

def handshake(path, port):
    return (f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
            f"Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Version: 13\r\n"
            f"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n").encode()


def masked_frame(payload, opcode=0x1):
    """One client frame, built once and sent on every connection.

    A client must mask (RFC 6455 §5.3) and the key is per frame, not per
    connection — so masking once and reusing the bytes is a real frame, and it
    keeps the harness from spending its time in a Python XOR loop instead of
    opening sockets.
    """
    key = b"\x9a\x21\x7f\x0c"
    n = len(payload)
    head = bytearray([0x80 | opcode])
    if n < 126:
        head.append(0x80 | n)
    elif n < 65536:
        head.append(0x80 | 126)
        head += struct.pack(">H", n)
    else:
        head.append(0x80 | 127)
        head += struct.pack(">Q", n)
    head += key
    masked = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
    return bytes(head) + masked


def recv_exact(s, n, buf):
    """`n` bytes out of `buf`, refilling from the socket. Returns the rest."""
    while len(buf) < n:
        chunk = s.recv(65536)
        if not chunk:
            raise OSError("closed")
        buf += chunk
    return buf[:n], buf[n:]


def read_frame(s, buf):
    """One server frame. Server frames are never masked."""
    head, buf = recv_exact(s, 2, buf)
    n = head[1] & 0x7F
    if n == 126:
        ext, buf = recv_exact(s, 2, buf)
        n = struct.unpack(">H", ext)[0]
    elif n == 127:
        ext, buf = recv_exact(s, 8, buf)
        n = struct.unpack(">Q", ext)[0]
    payload, buf = recv_exact(s, n, buf)
    return payload, buf


def open_ws(path, port, frame):
    """One connection, upgraded, with at most one message echoed on it."""
    s = socket.create_connection(("127.0.0.1", port), 5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.settimeout(10)
    s.sendall(handshake(path, port))
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise OSError("closed during handshake")
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    if b"101" not in head.split(b"\r\n")[0]:
        raise OSError(f"no upgrade: {head.split(chr(13).encode())[0]!r}")
    if frame is not None:
        s.sendall(frame)
        _, rest = read_frame(s, rest)
    return s


def open_http(path, port):
    """The control: one keep-alive request, drained, then held open."""
    s = socket.create_connection(("127.0.0.1", port), 5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.settimeout(10)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n"
              f"Connection: keep-alive\r\n\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise OSError("closed")
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    clen = 0
    for h in head.split(b"\r\n"):
        if h.lower().startswith(b"content-length:"):
            clen = int(h.split(b":")[1])
    while len(rest) < clen:
        rest += s.recv(4096)
    return s


def collect(target):
    """Ask the server to hand back what its heap is not using."""
    path = target.get("gc")
    if not path:
        return
    s = open_http(path, target["port"])
    s.close()
    time.sleep(1)


# ------------------------------------------------------------- one measurement

def measure(target, sc):
    path = target["paths"][sc["route"]]
    proc = subprocess.Popen(target["cmd"], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            env=dict(os.environ, **target["env"]),
                            start_new_session=True)
    try:
        if not wait_up(target["port"]):
            raise OSError("server did not start")
        time.sleep(2)
        pids = tree([proc.pid])
        collect(target)
        base = rss_kb(pids)

        frame = masked_frame(b"x" * sc["msg"]) if sc["msg"] else None
        conns, rows = [], []
        try:
            for want in STEPS:
                while len(conns) < want:
                    if sc.get("http"):
                        conns.append(open_http(path, target["port"]))
                    else:
                        conns.append(open_ws(path, target["port"], frame))
                time.sleep(SETTLE)
                now = rss_kb(pids)
                collect(target)
                after_gc = rss_kb(pids)
                prev_n = rows[-1]["n"] if rows else 0
                prev_rss = rows[-1]["rss_kb"] if rows else base
                rows.append(dict(
                    n=len(conns), rss_kb=now, gc_kb=after_gc,
                    per_conn=(now - base) * 1024 / len(conns),
                    gc_per_conn=(after_gc - base) * 1024 / len(conns),
                    marginal=(now - prev_rss) * 1024 / (len(conns) - prev_n),
                ))
        finally:
            for s in conns:
                s.close()
        return dict(label=sc["label"], path=path, base_kb=base, rows=rows)
    finally:
        stop([proc])


def main():
    argv = sys.argv[1:]
    if argv and argv[0] in TARGETS:
        names, argv = [argv[0]], argv[1:]
    elif argv and argv[0] == "both":
        names, argv = list(TARGETS), argv[1:]
    else:
        names = ["nilo"]
    only = set(argv)

    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    want = max(STEPS) + 256
    if soft < want:
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(want, hard), hard))
        print(f"raised RLIMIT_NOFILE {soft} -> {min(want, hard)}", flush=True)

    out = os.path.join(HERE, "result", "ws-idle.json")
    try:
        with open(out) as f:
            results = json.load(f)
    except (FileNotFoundError, ValueError):
        results = {}

    for name in names:
        target = TARGETS[name]
        if not os.path.exists(target["cmd"][0]):
            print(f"\n{name}: {target['cmd'][0]} is not built — skipping",
                  flush=True)
            continue
        print(f"\n##### {target['label']} #####", flush=True)
        for sc in SCENARIOS:
            if only and sc["key"] not in only:
                continue
            if name in sc.get("skip_for", ()):
                continue
            print(f"\n===== {sc['label']} =====", flush=True)
            try:
                m = measure(target, sc)
            except Exception as e:
                print(f"  FAILED: {type(e).__name__}: {e}", flush=True)
                continue
            results.setdefault(name, {})[sc["key"]] = m
            print(f"  {m['path']}   idle baseline: {m['base_kb']:,} kB",
                  flush=True)
            for r in m["rows"]:
                line = (f"  {r['n']:>6} sockets: {r['rss_kb']:>9,} kB  "
                        f"avg {r['per_conn']:>9,.0f}  "
                        f"marginal {r['marginal']:>9,.0f} B/conn")
                if target.get("gc"):
                    line += f"   after GC {r['gc_per_conn']:>9,.0f}"
                print(line, flush=True)

    with open(out, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nwrote {os.path.relpath(out, REPO)}", flush=True)


if __name__ == "__main__":
    main()
