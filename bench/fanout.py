#!/usr/bin/env python3
"""Events written a second to subscribers of one Room, over HTTP/1.1 and HTTP/2.

    zig build bench-stream-server -Doptimize=ReleaseFast -Dhttp2 -Dtarget=x86_64-linux-gnu
    BLAST_MS=2000 BACKLOG=64 ./zig-out/bin/nilo-bench-stream-server &
    python3 bench/fanout.py --port 8790 --framing h1 --subs 100
    python3 bench/fanout.py --port 8790 --framing h2 --subs 100

`/blast` posts into the room for BLAST_MS as fast as it can and answers how
many it posted; this opens `--subs` subscribers on `/events/room` first
(HTTP/2: `--per-conn` streams to a connection, with windows raised so the
client is never what holds the server), counts the events each was written
until they go quiet, and prints posted, written in all, and written a second
across the burst. Each subscriber's ring is `BACKLOG` posts, so a subscriber
that falls behind drops the oldest or the newest, as a Room does, and
"written" is what the server got out, not what was posted (ADR 260).
"""

import argparse
import selectors
import socket
import sys
import threading
import time

from mem import frame, literal

MARK = b"data: event"


def open_h1(host, port, path):
    s = socket.create_connection((host, port))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\n\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(65536)
    return [s]


def open_h2(host, port, path, streams):
    s = socket.create_connection((host, port))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    big = (1 << 30) - 1
    settings = (4).to_bytes(2, "big") + big.to_bytes(4, "big")
    s.sendall(
        b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
        + frame(0x4, 0, 0, settings)
        + frame(0x8, 0, 0, (big - 65535).to_bytes(4, "big"))
    )
    for i in range(streams):
        block = (b"\x20" if i == 0 else b"") + b"\x82\x86" + literal(":path", path) + literal(":authority", host)
        s.sendall(frame(0x1, 0x5, 2 * i + 1, block))
    return [s]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--framing", choices=["h1", "h2"], required=True)
    p.add_argument("--subs", type=int, default=100)
    p.add_argument("--per-conn", type=int, default=50)
    p.add_argument("--path", default="/events/room")
    a = p.parse_args()

    socks = []
    if a.framing == "h1":
        for _ in range(a.subs):
            socks += open_h1(a.host, a.port, a.path)
    else:
        left = a.subs
        while left > 0:
            n = min(left, a.per_conn)
            socks += open_h2(a.host, a.port, a.path, n)
            left -= n
    time.sleep(1.0)

    counts = {s: 0 for s in socks}
    tails = {s: b"" for s in socks}
    sel = selectors.DefaultSelector()
    for s in socks:
        s.setblocking(False)
        sel.register(s, selectors.EVENT_READ)

    posted = []

    def trigger():
        t = socket.create_connection((a.host, a.port))
        t.sendall(f"GET /blast HTTP/1.1\r\nHost: {a.host}\r\nConnection: close\r\n\r\n".encode())
        data = b""
        while True:
            c = t.recv(4096)
            if not c:
                break
            data += c
        posted.append(int(data.split()[-1]))

    th = threading.Thread(target=trigger)
    start = time.monotonic()
    th.start()
    last = start
    while True:
        ready = sel.select(timeout=0.5)
        if not ready:
            if not th.is_alive() and time.monotonic() - last > 0.5:
                break
            continue
        for key, _ in ready:
            s = key.fileobj
            try:
                chunk = s.recv(1 << 20)
            except BlockingIOError:
                continue
            if not chunk:
                sel.unregister(s)
                continue
            data = tails[s] + chunk
            counts[s] += data.count(MARK)
            tails[s] = data[-(len(MARK) - 1):]
            last = time.monotonic()
    th.join()
    elapsed = last - start
    total = sum(counts.values())
    print(f"{a.framing}: {a.subs} subscribers, posted {posted[0] if posted else '?'}, "
          f"written {total}, over {elapsed:.2f}s: {total / elapsed:,.0f} events/s")
    for s in socks:
        s.close()


if __name__ == "__main__":
    main()
