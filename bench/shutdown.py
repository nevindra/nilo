#!/usr/bin/env python3
"""Does the server come back from a SIGTERM after it has served WebSockets?

Roughly three times in four, it does not: the process never exits and one
executor thread spins at 100% for as long as anybody lets it. This is the
reproduction, kept as something that can be run again rather than a paragraph
about what was once seen.

    zig build bench-ws-server -Doptimize=ReleaseFast
    python3 bench/shutdown.py --cmd ./zig-out/bin/nilo-bench-ws-server \\
        --port 8789 --path /ws/small --runs 12

    zig build bench-stream-server -Doptimize=ReleaseFast      # the HTTP control
    python3 bench/shutdown.py --cmd ./zig-out/bin/nilo-bench-stream-server \\
        --port 8790 --path /health --http --runs 12

Each run starts a fresh server, opens `--conns` WebSocket connections one after
another — handshake, one message echoed, the close handshake, socket closed —
then sends SIGTERM and waits. A run that is still alive after `--patience`
seconds is a hang, and its CPU is sampled so the spin is on the record rather
than inferred.

Found by running the Autobahn suite (`bench/autobahn/`), which left a server at
five cores of nothing. `--http` is the control that says it is the WebSocket
path and not the accept loop: it does the same thing with plain requests.
"""

import argparse
import base64
import os
import signal
import socket
import struct
import subprocess
import sys
import time


def ticks(pid):
    """utime + stime, in clock ticks, or None once the process is gone."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().rsplit(") ", 1)[1].split()
    except OSError:
        return None
    return int(fields[11]) + int(fields[12])


def threads(pid):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("Threads:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


def masked(opcode, payload=b""):
    """One client frame. Every frame from a client is masked (RFC 6455 §5.3)."""
    key = os.urandom(4)
    body = bytes(b ^ key[i % 4] for i, b in enumerate(payload))
    head = bytes([0x80 | opcode])
    if len(payload) < 126:
        head += bytes([0x80 | len(payload)])
    else:
        head += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
    return head + key + body


def one_websocket(host, port, path, timeout):
    """A whole ordinary life: handshake, echo, close handshake, gone."""
    s = socket.create_connection((host, port), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(
        f"GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n".encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            raise SystemExit("the server closed the connection during the handshake")
        buf += chunk
    if b" 101 " not in buf.split(b"\r\n")[0]:
        raise SystemExit("no 101: " + buf.split(b"\r\n")[0].decode(errors="replace"))

    s.sendall(masked(1, b"hello"))
    s.recv(4096)
    s.sendall(masked(8, struct.pack(">H", 1000)))
    try:
        s.recv(4096)
    except OSError:
        pass
    s.close()


def one_request(host, port, path, timeout):
    """The control: the same accept, serve and close with no upgrade in it."""
    s = socket.create_connection((host, port), timeout=timeout)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
    try:
        while s.recv(4096):
            pass
    except OSError:
        pass
    s.close()


def run_once(args):
    """One server's whole life. Returns (hung, ticks_per_second, threads)."""
    server = subprocess.Popen(
        args.cmd.split(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env={**os.environ, "PORT": str(args.port), "IDLE_MS": args.idle_ms},
    )
    try:
        time.sleep(args.warmup)
        speak = one_request if args.http else one_websocket
        for _ in range(args.conns):
            speak(args.host, args.port, args.path, args.timeout)
        time.sleep(0.3)

        server.send_signal(signal.SIGTERM)
        deadline = time.time() + args.patience
        while time.time() < deadline:
            if server.poll() is not None:
                return False, 0.0, None
            time.sleep(0.1)

        # Still here. Sample the spin so the finding carries a number.
        before = ticks(server.pid)
        time.sleep(2)
        after = ticks(server.pid)
        per_second = (after - before) / 2 / os.sysconf("SC_CLK_TCK") if before else 0.0
        return True, per_second, threads(server.pid)
    finally:
        if server.poll() is None:
            server.kill()
            server.wait()
        time.sleep(args.settle)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cmd", required=True, help="the server to start")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--path", default="/")
    p.add_argument("--http", action="store_true", help="plain requests, the control")
    p.add_argument("--conns", type=int, default=6)
    p.add_argument("--runs", type=int, default=12)
    p.add_argument("--warmup", type=float, default=1.0)
    p.add_argument("--settle", type=float, default=0.5)
    p.add_argument("--patience", type=float, default=5.0)
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--idle-ms", default="30000", dest="idle_ms")
    args = p.parse_args()

    hung = 0
    for i in range(1, args.runs + 1):
        stuck, spin, live = run_once(args)
        if stuck:
            hung += 1
            print(f"run {i:>3}: HUNG — {spin:.1f} cores, {live} threads left")
        else:
            print(f"run {i:>3}: exited")

    print(f"\n{hung} of {args.runs} runs never came back from SIGTERM")
    sys.exit(1 if hung else 0)


if __name__ == "__main__":
    main()
