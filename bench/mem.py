#!/usr/bin/env python3
"""Memory per idle connection, which is the third row of ADR 017's budget.

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
    python3 bench/mem.py --port 8790 --path /stream --hold
    python3 bench/mem.py --port 8787 --path /health --tls
    python3 bench/mem.py --port 50051 --path /pkg.Service/Method --grpc
    python3 bench/mem.py --port 8787 --h2                  # HTTP/2, nothing in flight
    python3 bench/mem.py --port 8787 --h2 --get --path /health   # ... after one GET (ADR 259)

The server is found by port rather than named, so this works against any of
them — `nilo-hello`, `nilo-bench-sql-server`, `nilo-bench-fetch-server`, or
something that is not nilo at all.
"""

import argparse
import socket
import ssl
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


def frame(kind, flags, stream, payload=b""):
    return len(payload).to_bytes(3, "big") + bytes([kind, flags]) + stream.to_bytes(4, "big") + payload


def literal(name, value):
    """An HPACK literal, never indexed and not Huffman-coded: the one shape
    that needs no table on either side."""
    def string(b):
        assert len(b) < 127
        return bytes([len(b)]) + b
    return b"\x10" + string(name.encode()) + string(value.encode())


def open_grpc(host, port, path, timeout):
    """One h2c connection with one unary call already answered on it
    (ADR 220): the preface, SETTINGS, a call with an empty message, and
    every frame read until that call's trailers. What is left is a gRPC
    connection between calls, which is what a client's channel is nearly
    all of its life."""
    s = socket.create_connection((host, port), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    block = (
        b"\x83\x86"  # :method POST, :scheme http
        + literal(":path", path)
        + literal(":authority", host)
        + literal("content-type", "application/grpc")
        + literal("te", "trailers")
    )
    s.sendall(
        b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        + frame(0x4, 0, 0)
        + frame(0x1, 0x4, 1, block)
        + frame(0x0, 0x1, 1, b"\x00\x00\x00\x00\x00")
    )
    buf = b""
    while True:
        while len(buf) < 9:
            chunk = s.recv(65536)
            if not chunk:
                raise SystemExit("the server closed the connection")
            buf += chunk
        length = int.from_bytes(buf[0:3], "big")
        while len(buf) < 9 + length:
            chunk = s.recv(65536)
            if not chunk:
                raise SystemExit("the server closed the connection")
            buf += chunk
        kind, flags = buf[3], buf[4]
        buf = buf[9 + length :]
        if kind == 0x4 and not flags & 0x1:
            s.sendall(frame(0x4, 0x1, 0))
        elif kind == 0x7:
            raise SystemExit("the server sent GOAWAY")
        elif kind == 0x1 and flags & 0x1:
            return s


def open_h2(host, port, path, timeout, get):
    """One HTTP/2 connection on a plain port (ADR 259): the preface and the
    SETTINGS exchange both ways, so the connection is HTTP/2 and has said
    everything a client says before its first request. With `get`, one GET at
    `path` is answered and drained as well. What is left is a connection with
    no request in flight, which is a browser's tab between clicks.

    The first header block opens with the size update to 0 that the server's
    SETTINGS oblige a client to send once it has acknowledged them (RFC 7541
    §4.2)."""
    s = socket.create_connection((host, port), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + frame(0x4, 0, 0))
    buf = b""

    def next_frame():
        nonlocal buf
        while len(buf) < 9:
            chunk = s.recv(65536)
            if not chunk:
                raise SystemExit("the server closed the connection")
            buf += chunk
        length = int.from_bytes(buf[0:3], "big")
        while len(buf) < 9 + length:
            chunk = s.recv(65536)
            if not chunk:
                raise SystemExit("the server closed the connection")
            buf += chunk
        kind, flags = buf[3], buf[4]
        buf = buf[9 + length :]
        return kind, flags

    settings, acked = False, False
    while not (settings and acked):
        kind, flags = next_frame()
        if kind == 0x4 and flags & 0x1:
            acked = True
        elif kind == 0x4:
            settings = True
            s.sendall(frame(0x4, 0x1, 0))
        elif kind == 0x7:
            raise SystemExit("the server sent GOAWAY")
    if not get:
        return s

    block = (
        b"\x20"  # the size update to 0
        + b"\x82\x86"  # :method GET, :scheme http
        + literal(":path", path)
        + literal(":authority", host)
    )
    s.sendall(frame(0x1, 0x5, 1, block))
    while True:
        kind, flags = next_frame()
        if kind == 0x7:
            raise SystemExit("the server sent GOAWAY")
        if kind in (0x0, 0x1) and flags & 0x1:
            return s


def open_one(host, port, path, timeout, hold=False, tls=None):
    """One keep-alive connection with one request already served on it.

    `hold` is for a response that has no end to drain to: an event stream the
    server is holding open. The head and whatever arrived with it are read and
    then the connection is left alone, which is a handler still suspended
    rather than a connection between requests — and those are different
    numbers, because a suspended handler holds its stack as well as its
    buffers (ADR 062). Draining is what the ordinary path does to make sure
    nothing is backed up; here there is nothing to back up yet.
    """
    s = socket.create_connection((host, port), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if tls:
        # The same connection through TLS 1.3, for a server built with
        # -Dtls (ADR 212). The certificate is not checked because the one
        # the benchmark server presents is the suite's self-signed fixture;
        # one context serves every connection.
        s = tls.wrap_socket(s, server_hostname=host)
    s.sendall(
        f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: keep-alive\r\n\r\n".encode()
    )

    # Drain the whole response. A connection with bytes still backed up in it
    # is not idle, and would be measured holding buffers it is about to read.
    # Both framings, because a streamed route has no length to announce and
    # reading only `Content-Length` would leave a megabyte in the socket and
    # call the connection idle.
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            raise SystemExit("the server closed the connection")
        buf += chunk

    if hold:
        return s

    head, body = buf.split(b"\r\n\r\n", 1)
    length, chunked = 0, False
    for line in head.split(b"\r\n"):
        low = line.lower()
        if low.startswith(b"content-length:"):
            length = int(line.split(b":")[1])
        elif low.startswith(b"transfer-encoding:") and b"chunked" in low:
            chunked = True

    def more():
        chunk = s.recv(65536)
        if not chunk:
            raise SystemExit("the server closed the connection")
        return chunk

    if chunked:
        # Size line, that many bytes, CRLF, until a zero-sized one. The
        # trailer is empty here, so the final CRLF ends it.
        while True:
            while b"\r\n" not in body:
                body += more()
            line, body = body.split(b"\r\n", 1)
            size = int(line.split(b";")[0], 16)
            if size == 0:
                while not body.startswith(b"\r\n"):
                    body += more()
                return s
            while len(body) < size + 2:
                body += more()
            body = body[size + 2 :]

    while len(body) < length:
        body += more()
    return s


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--path", default="/health")
    p.add_argument("--steps", default="500,1000,2000,5000,10000")
    p.add_argument("--settle", type=float, default=2.0, help="seconds before each read")
    p.add_argument(
        "--hold",
        action="store_true",
        help="read the head and stop, for a response the server is holding open",
    )
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument(
        "--grpc",
        action="store_true",
        help="speak h2c with prior knowledge and make one unary call at --path (ADR 220)",
    )
    p.add_argument(
        "--h2",
        action="store_true",
        help="speak HTTP/2 with prior knowledge on a plain port: the preface and SETTINGS only, "
        "or with --get one GET at --path first (ADR 259)",
    )
    p.add_argument(
        "--get",
        action="store_true",
        help="with --h2, make one GET at --path on each connection before it is left idle",
    )
    p.add_argument(
        "--tls",
        action="store_true",
        help="connect through TLS 1.3, against `zig build bench-tls-server -Dtls`",
    )
    args = p.parse_args()

    steps = [int(x) for x in args.steps.split(",")]
    tls_ctx = None
    if args.tls:
        tls_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        tls_ctx.check_hostname = False
        tls_ctx.verify_mode = ssl.CERT_NONE
        tls_ctx.minimum_version = ssl.TLSVersion.TLSv1_3
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
                held.append(
                    open_grpc(args.host, args.port, args.path, args.timeout)
                    if args.grpc
                    else open_h2(args.host, args.port, args.path, args.timeout, args.get)
                    if args.h2
                    else open_one(args.host, args.port, args.path, args.timeout, args.hold, tls_ctx)
                )
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
