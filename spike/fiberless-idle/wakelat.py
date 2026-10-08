#!/usr/bin/env python3
"""wakelat.py PORT [conns] [rounds]: latency of the first request on a connection that has been idle past the 200 ms peek, against a request right after another."""
import socket, sys, time, statistics
port = int(sys.argv[1]); n = int(sys.argv[2]) if len(sys.argv) > 2 else 50
rounds = int(sys.argv[3]) if len(sys.argv) > 3 else 20
req = b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
def one(s):
    t = time.perf_counter_ns()
    s.sendall(req)
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d: raise SystemExit("closed")
        buf += d
    head, _, body = buf.partition(b"\r\n\r\n")
    cl = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"): cl = int(line.split(b":")[1])
    while len(body) < cl:
        body += s.recv(4096)
    return (time.perf_counter_ns() - t) / 1000.0
conns = []
for _ in range(n):
    s = socket.create_connection(("127.0.0.1", port)); s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    one(s); conns.append(s)
cold, warm = [], []
for r in range(rounds):
    time.sleep(0.45)
    for s in conns:
        cold.append(one(s))
        time.sleep(0.001)
        warm.append(one(s))
        time.sleep(0.001)
def q(v, p): v = sorted(v); return v[int(len(v) * p) - 1]
for name, v in (("first after idle", cold), ("right after another", warm)):
    print(f"{name:22s} n={len(v)} p50={statistics.median(v):7.1f} us  p90={q(v,.9):7.1f}  p99={q(v,.99):7.1f}  max={max(v):8.1f}")
