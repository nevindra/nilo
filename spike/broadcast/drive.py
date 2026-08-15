#!/usr/bin/env python3
"""SPIKE driver — throwaway, deleted with spike/.

Three questions, three checks:

  1. Does a broadcast reach the other sockets at all?
  2. Do frames written by several fibers into one socket interleave?
     Every frame is parsed strictly; a torn frame shows up as a length
     that does not line up rather than as anything subtle.
  3. What happens to everybody else when one client stops reading?
     That is the question mode A and mode B are supposed to answer
     differently, and it is measured in milliseconds, not opinions.

    python3 drive.py talk      # N clients, all reading, check for tears
    python3 drive.py slow      # one client stops reading, time the rest
"""

import base64
import os
import socket
import struct
import sys
import threading
import time

HOST, PORT = "127.0.0.1", 8788


def handshake(sock):
    key = base64.b64encode(os.urandom(16)).decode()
    sock.sendall(
        f"GET /ws HTTP/1.1\r\nHost: {HOST}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
        f"Sec-WebSocket-Key: {key}\r\n\r\n".encode()
    )
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError("server closed during handshake")
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    if b"101" not in head.split(b"\r\n")[0]:
        raise RuntimeError(f"handshake refused: {head.splitlines()[0]!r}")
    return rest


def frame(payload: bytes) -> bytes:
    mask = os.urandom(4)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    n = len(payload)
    if n < 126:
        header = struct.pack("!BB", 0x81, 0x80 | n)
    elif n < 1 << 16:
        header = struct.pack("!BBH", 0x81, 0x80 | 126, n)
    else:
        header = struct.pack("!BBQ", 0x81, 0x80 | 127, n)
    return header + mask + masked


class Reader:
    """Strict frame parser. A torn frame becomes an exception, not a shrug."""

    def __init__(self, sock, leftover=b""):
        self.sock = sock
        self.buf = bytearray(leftover)

    def _need(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk

    def message(self):
        self._need(2)
        first, second = self.buf[0], self.buf[1]
        opcode = first & 0x0F
        if first & 0x70:
            raise ValueError(f"reserved bit set: {first:#04x} — torn frame")
        if second & 0x80:
            raise ValueError("server sent a masked frame — torn frame")
        n = second & 0x7F
        at = 2
        if n == 126:
            self._need(4)
            n = struct.unpack("!H", self.buf[2:4])[0]
            at = 4
        elif n == 127:
            self._need(10)
            n = struct.unpack("!Q", self.buf[2:10])[0]
            at = 10
        if n > 1 << 20:
            raise ValueError(f"absurd frame length {n} — torn frame")
        self._need(at + n)
        payload = bytes(self.buf[at:at + n])
        del self.buf[:at + n]
        if opcode == 0x8:
            raise EOFError
        return payload


def talk(clients=16, each=50):
    """Everybody reads. Any tear anywhere fails the run."""
    socks, readers = [], []
    for _ in range(clients):
        s = socket.create_connection((HOST, PORT))
        s.settimeout(10)
        readers.append(Reader(s, handshake(s)))
        socks.append(s)

    for r in readers:
        r.message()  # the "seat N" greeting

    tears, got = [], [0] * clients

    def drain(i):
        try:
            while True:
                body = readers[i].message()
                if not body.startswith(b"from "):
                    tears.append(f"client {i}: unexpected {body[:40]!r}")
                got[i] += 1
        except (EOFError, socket.timeout, OSError):
            pass  # the run is over and the socket was closed under us
        except (ValueError, struct.error) as e:
            tears.append(f"client {i}: {e}")

    threads = [threading.Thread(target=drain, args=(i,), daemon=True) for i in range(clients)]
    for t in threads:
        t.start()

    # Long enough that a header and its payload cannot both fit in one
    # atomic-looking write, which is what makes interleaving visible.
    for round_no in range(each):
        for i, s in enumerate(socks):
            s.sendall(frame(f"from {i} round {round_no} ".encode() + b"x" * 400))

    time.sleep(2.0)
    for s in socks:
        s.close()
    for t in threads:
        t.join(timeout=2)

    sent = clients * each
    expected = sent * (clients - 1)
    print(f"sent {sent} messages, {sum(got)} of an expected {expected} arrived")
    if tears:
        print(f"TORN FRAMES: {len(tears)}")
        for t in tears[:5]:
            print("  " + t)
        return 1
    print("no torn frames")
    return 0


def slow(clients=8):
    """One client stops reading. Time what that costs everybody else.

    Client 0 is handed the socket and then never reads from it again. Its
    receive buffer fills, then the server's send buffer for it, and then a
    write to it blocks — inside whichever fiber is doing the broadcast.
    Clients 2 and 3 are healthy and only want to talk to each other; the
    question is whether they can.
    """
    socks, readers = [], []
    for _ in range(clients):
        s = socket.create_connection((HOST, PORT))
        s.settimeout(20)
        readers.append(Reader(s, handshake(s)))
        socks.append(s)
    for r in readers:
        r.message()

    # Under the 16 KB the handler's receive buffer holds, or the server
    # closes the *talker* with 1009 before any of this is interesting.
    victim, talker = 0, 1
    payload = b"y" * 8_000
    stuffed = [0]

    def stuff():
        socks[talker].settimeout(5)
        try:
            for _ in range(2000):
                socks[talker].sendall(frame(payload))
                stuffed[0] += 1
        except (OSError, socket.timeout):
            pass

    print("filling the socket of a client that has stopped reading...")
    filler = threading.Thread(target=stuff, daemon=True)
    filler.start()
    filler.join(timeout=15)
    print(f"  the talker got {stuffed[0]} messages in "
          f"({stuffed[0] * len(payload) / 1e6:.1f} MB broadcast to each seat)"
          + ("" if not filler.is_alive() else " and is now stuck"))

    # Two healthy clients, talking only to each other, with that stuck
    # socket sitting in the same room.
    a, b = 2, 3
    socks[a].settimeout(5)
    readers[b].sock.settimeout(5)
    times = []
    for _ in range(5):
        started = time.monotonic()
        try:
            socks[a].sendall(frame(b"ping " + b"z" * 100))
            while True:
                body = readers[b].message()
                if body.startswith(b"ping "):
                    break
        except (EOFError, socket.timeout, OSError) as e:
            print(f"  healthy client never got through: {type(e).__name__}")
            times.append(float("inf"))
            break
        took = time.monotonic() - started
        times.append(took)
        print(f"  {took * 1000:.1f} ms")

    worst = max(times) if times else float("inf")
    print(f"worst round trip between two healthy clients: {worst * 1000:.1f} ms"
          if worst != float("inf") else
          "worst round trip between two healthy clients: never arrived")
    print(f"(victim {victim} never read a byte of it)")
    for s in socks:
        s.close()
    return 0


def idle(clients=400):
    """What does an idle connection cost, in the mode the server is in?

    ADR 0018 measures 8,767 bytes per idle connection and calls it a hard
    invariant. Mode C adds a second fiber to every one of them, so this is
    the number that decides whether mode C is affordable at all.
    """
    pid = None
    for line in os.popen("pgrep -x spike-broadcast").read().split():
        pid = int(line)
    if pid is None:
        print("server not found")
        return 1

    def rss_kb():
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
        return 0

    before = rss_kb()
    socks = []
    for _ in range(clients):
        s = socket.create_connection((HOST, PORT))
        s.settimeout(10)
        Reader(s, handshake(s)).message()  # the greeting, then silence
        socks.append(s)

    time.sleep(3)  # let anything lazy settle
    after = rss_kb()
    each = (after - before) * 1024 / clients
    print(f"RSS {before} kB -> {after} kB over {clients} idle connections")
    print(f"{each:.0f} bytes per idle connection")

    # An idle connection never touches its queue, so the idle number cannot
    # see the difference between a queue per connection and one ring for
    # everybody. Say something on every connection, which writes into every
    # queue there is, and measure again.
    drains = []
    for r in readers_of(socks):
        t = threading.Thread(target=r, daemon=True)
        t.start()
        drains.append(t)
    for s in socks:
        try:
            s.sendall(frame(b"touch every queue " + b"q" * 200))
        except OSError:
            pass
    time.sleep(5)
    loaded = rss_kb()
    print(f"RSS {after} kB -> {loaded} kB once every connection has spoken")
    print(f"{(loaded - before) * 1024 / clients:.0f} bytes per connection under traffic")

    for s in socks:
        s.close()
    return 0


def readers_of(socks):
    """Drain in the background, so the server is never blocked on a client."""
    def make(s):
        def go():
            try:
                while True:
                    if not s.recv(65536):
                        return
            except OSError:
                return
        return go
    return [make(s) for s in socks]


def wedge(clients=8, hold=60):
    """Wedge one client and then hold every socket open, saying nothing.

    Unlike `slow`, this does not close anything at the end — the point is
    to still be wedged when somebody else sends the server a SIGTERM, so
    that shutdown is measured against a writer that genuinely cannot make
    progress rather than one that has already given up.
    """
    socks, readers = [], []
    for _ in range(clients):
        s = socket.create_connection((HOST, PORT))
        s.settimeout(20)
        readers.append(Reader(s, handshake(s)))
        socks.append(s)
    for r in readers:
        r.message()

    payload = b"y" * 8_000
    sent = [0]

    def stuff():
        socks[1].settimeout(5)
        try:
            for _ in range(4000):
                socks[1].sendall(frame(payload))
                sent[0] += 1
        except (OSError, socket.timeout):
            pass

    t = threading.Thread(target=stuff, daemon=True)
    t.start()
    t.join(timeout=20)
    print(f"wedged: client 0 has never read, {sent[0]} messages pushed at it", flush=True)
    print(f"holding {clients} sockets open for {hold}s", flush=True)
    time.sleep(hold)
    return 0


def churn(rounds=300, at_once=12):
    """Join and leave hard, while the room is busy.

    This is the path that worries: a connection ending has to stop its
    writer fiber, and in mode D stopping it means cancelling a fiber that
    may be part way through a socket write. A connection leaving during a
    broadcast is also the moment `Member` — which lives on the handler's
    own stack — stops existing.
    """
    steady, steady_readers = [], []
    for _ in range(4):
        s = socket.create_connection((HOST, PORT))
        s.settimeout(20)
        steady_readers.append(Reader(s, handshake(s)))
        steady.append(s)
    for r in steady_readers:
        r.message()

    def chatter():
        try:
            while not done.is_set():
                steady[0].sendall(frame(b"keep the room busy " + b"k" * 300))
                time.sleep(0.001)
        except OSError:
            pass

    def drain(i):
        try:
            while not done.is_set():
                if not steady[i].recv(65536):
                    return
        except OSError:
            return

    done = threading.Event()
    threading.Thread(target=chatter, daemon=True).start()
    for i in range(1, 4):
        threading.Thread(target=drain, args=(i,), daemon=True).start()

    failures = 0
    for r in range(rounds):
        batch = []
        for _ in range(at_once):
            try:
                s = socket.create_connection((HOST, PORT))
                s.settimeout(5)
                handshake(s)
                batch.append(s)
            except (OSError, RuntimeError):
                failures += 1
        # Leave without a close frame — a tab being shut, which is the
        # common case and the abrupt one.
        for s in batch:
            s.close()

    done.set()
    time.sleep(1)
    alive = os.popen("pgrep -x spike-broadcast").read().strip()
    print(f"{rounds * at_once} connections joined and left abruptly, "
          f"{failures} could not connect")
    print("server still running" if alive else "SERVER DIED")
    for s in steady:
        s.close()
    return 0 if alive else 1


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "talk"
    sys.exit({"talk": talk, "slow": slow, "idle": idle,
              "wedge": wedge, "churn": churn}[what]())
