#!/usr/bin/env python3
"""Memory per idle connection, which is the third row of ADR 0018's budget.

The method `bench/result/http.md` describes, as something that can be run
again rather than a paragraph about what was once done: open keep-alive
connections in steps, send one request on each so the connection is fully
established through the accept path, drain the response so nothing is left
backed up, let it settle, and read the server's `VmRSS`. Connections from
earlier steps stay open, so the last row is N live connections rather than N
opened and closed.

The marginal column is the result, not the total. A cost that is a property of
a connection has a marginal figure equal to its average; one that steps or
compounds does not, and no total will say which you have.

    python3 bench/mem.py --port 8787 --path /health
    python3 bench/mem.py --port 8789 --path /call --steps 200,500,1000

The server is found by port rather than named, so this works against any of
them — `nilo-hello`, `nilo-bench-sql-server`, `nilo-bench-fetch-server`, or
something that is not nilo at all.
"""

import argparse
import socket
import subprocess
import sys
import time


def find_pid(port):
    """The process holding the listening socket on `port`."""
    out = subprocess.run(
        ["ss", "-ltnp", f"sport = :{port}"], capture_output=True, text=True
    ).stdout
    for line in out.splitlines():
        if "pid=" not in line:
            continue
        return int(line.split("pid=")[1].split(",")[0])
    raise SystemExit(f"nothing is listening on port {port}")


def rss_kb(pid):
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    raise SystemExit(f"process {pid} went away")


def open_one(host, port, path, timeout):
    """One keep-alive connection with one request already served on it."""
    s = socket.create_connection((host, port), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.sendall(
        f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: keep-alive\r\n\r\n".encode()
    )

    # Drain the whole response. A connection with bytes still backed up in it
    # is not idle, and would be measured holding buffers it is about to read.
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            raise SystemExit("the server closed the connection")
        buf += chunk

    head, body = buf.split(b"\r\n\r\n", 1)
    length = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    while len(body) < length:
        chunk = s.recv(65536)
        if not chunk:
            raise SystemExit("the server closed the connection")
        body += chunk
    return s


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--path", default="/health")
    p.add_argument("--steps", default="500,1000,2000,5000,10000")
    p.add_argument("--settle", type=float, default=2.0, help="seconds before each read")
    p.add_argument("--timeout", type=float, default=10.0)
    args = p.parse_args()

    steps = [int(x) for x in args.steps.split(",")]
    pid = find_pid(args.port)

    time.sleep(args.settle)
    base = rss_kb(pid)
    print(f"pid {pid}, path {args.path}")
    print(f"{'connections':>12} {'RSS':>12} {'per connection':>16}")
    print(f"{0:>12} {str(base) + ' kB':>12} {'—':>16}")

    held = []
    try:
        for want in steps:
            while len(held) < want:
                held.append(open_one(args.host, args.port, args.path, args.timeout))
            time.sleep(args.settle)
            now = rss_kb(pid)
            per = (now - base) * 1024 / len(held)
            print(f"{len(held):>12} {str(now) + ' kB':>12} {per:>13.0f} B")
    except OSError as e:
        print(f"stopped at {len(held)} connections: {e}", file=sys.stderr)
    finally:
        for s in held:
            s.close()


if __name__ == "__main__":
    main()
