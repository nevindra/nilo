#!/usr/bin/env python3
"""What a server holds for bodies that are announced and never delivered.

The third row of ADR 0018's budget, asked about a request that is still
arriving rather than one that is idle — which is what `bench/mem.py` measures.
The difference is the whole point: an idle keep-alive connection holds its
buffers, and a connection halfway through a body it announced as a megabyte
used to hold the megabyte as well, from the moment the head was parsed.

Each connection opens, sends a head announcing `--announce` bytes, sends
`--sent` of them, and then stops. Nothing is closed, so what the server holds
is what it is holding for a client that has not gone away and has not finished:

    python3 bench/slowloris.py --port 8792 --path /echo
    python3 bench/slowloris.py --port 8792 --path /stream   # the control

The marginal column is the result, the same as in `mem.py`, and for the same
reason: a cost that is a property of a connection has a marginal figure equal
to its average.
"""

import argparse
import socket
import subprocess
import sys
import time


def find_pid(port):
    out = subprocess.run(
        ["ss", "-ltnp", f"sport = :{port}"], capture_output=True, text=True
    ).stdout
    for line in out.splitlines():
        if "pid=" not in line:
            continue
        return int(line.split("pid=")[1].split(",")[0])
    raise SystemExit(f"nothing is listening on port {port}")


def memory_kb(pid):
    """`VmData` as well as `VmRSS`, because they answer different questions.

    A body taken out of the arena before it arrives is mapped and not written
    to, and Linux does not count a page nobody has touched in `VmRSS`. So a
    megabyte committed on the strength of a header is invisible to the
    instrument `bench/mem.py` uses, and reporting only that would have said the
    gap did not exist. `VmData` is the anonymous mapping — what was asked for
    — and `VmRSS` is what is actually resident.
    """
    out = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            for key in ("VmRSS:", "VmData:"):
                if line.startswith(key):
                    out[key[:-1]] = int(line.split()[1])
    if len(out) != 2:
        raise SystemExit(f"process {pid} went away")
    return out


def open_one(host, port, path, announce, sent, timeout):
    """One connection stuck partway through a body it said was bigger."""
    s = socket.create_connection((host, port), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.sendall(
        (
            f"POST {path} HTTP/1.1\r\n"
            f"Host: {host}\r\n"
            f"Content-Type: application/octet-stream\r\n"
            f"Content-Length: {announce}\r\n"
            f"Connection: keep-alive\r\n\r\n"
        ).encode()
    )
    if sent:
        s.sendall(b"x" * sent)
    return s


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--path", default="/echo")
    p.add_argument(
        "--announce",
        type=int,
        default=1024 * 1024,
        help="the Content-Length the request claims; the default is max_body",
    )
    p.add_argument("--sent", type=int, default=1, help="bytes actually delivered")
    p.add_argument("--steps", default="100,250,500,1000")
    p.add_argument("--settle", type=float, default=2.0)
    p.add_argument("--timeout", type=float, default=10.0)
    args = p.parse_args()

    steps = [int(x) for x in args.steps.split(",")]
    pid = find_pid(args.port)

    time.sleep(args.settle)
    base = memory_kb(pid)
    print(f"pid {pid}, path {args.path}, announced {args.announce}, sent {args.sent}")
    print(f"{'connections':>12} {'data/conn':>12} {'rss/conn':>12}")
    print(f"{0:>12} {'—':>12} {'—':>12}")

    held = []
    try:
        for want in steps:
            while len(held) < want:
                held.append(
                    open_one(
                        args.host,
                        args.port,
                        args.path,
                        args.announce,
                        args.sent,
                        args.timeout,
                    )
                )
            time.sleep(args.settle)
            now = memory_kb(pid)
            data = (now["VmData"] - base["VmData"]) * 1024 / len(held)
            rss = (now["VmRSS"] - base["VmRSS"]) * 1024 / len(held)
            print(f"{len(held):>12} {data:>10.0f} B {rss:>10.0f} B")
    except OSError as e:
        print(f"stopped at {len(held)} connections: {e}", file=sys.stderr)
    finally:
        for s in held:
            s.close()


if __name__ == "__main__":
    main()
