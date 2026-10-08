# Can an idle HTTP/1.1 connection have no fiber?

A connection past the idle peek ends its fiber and is a 512-byte heap record behind one poll completion; a reactor fiber spawns a connection fiber over the same record when its socket is readable. [`design-note.md`](./design-note.md) has the proposal, what it costs and closes off, and what nginx, h2o and Go do. The measurements are in [`bench/result/http.md`](../../bench/result/http.md#a-prototype-an-idle-http11-connection-with-no-fiber). Nothing here is merged and no ADR decides it.

## What is in the directory

- `0001-sizes-and-park-check.patch`: the change the prototype is made against, as it stood on `514e8c1`; the same change is committed after that point, so `0001` is needed only to rebuild the prototype on its base. It takes the 264-byte `Options` out of a connection's spawn arguments (the 512 bytes of the idle-figure entry in [`history.md`](../../docs/history.md)) and adds `zig build park-check`. Without it the prototype's spawn arguments differ and `0002` does not apply.
- `0002-fiberless-idle.patch`: the prototype. A `park` entry in the Waker's table (`http/bulkhead.zig`), a return at the idle peek (`http/serve.zig`), and the record, the reactor and a one-second `stack_pool.shrink_interval` in `http/engine/zio.zig`. Plain listener of a default build only: with `-Dtls` or `-Dhttp2` it compiles to the fiber path.
- `wakelat.py`: the latency of the first request on a connection that has been quiet past the peek, against one sent right after another.
- `think.lua`: a wrk script that waits 300 ms before every request, so every request wakes a parked connection.

## Base and how to apply

The base is commit `514e8c1` of `unify-h1-h2`. From a clean checkout of it:

```
patch -p1 < spike/fiberless-idle/0001-sizes-and-park-check.patch
patch -p1 < spike/fiberless-idle/0002-fiberless-idle.patch
zig build install -Doptimize=ReleaseFast -Dstrip=true -Dtarget=x86_64-linux-gnu -p zig-out
```

`-Dtarget=x86_64-linux-gnu` is for a host whose glibc was built by GCC 16 (see `CLAUDE.md`). Build the same tree without `0002` into another prefix for the before.

## How the numbers were read

Memory per idle connection, the server in a private network namespace (`unshare -rn`, loopback up) pinned to cores 4 to 7:

```
python3 bench/mem.py --port 8787 --steps 1000,5000,10000 --settle 15
```

`--settle 15` for the prototype, because the stack pool gives pages back over seconds (the pool is the largest term, see the note); the fiber build is read the same way. Latency of the first request after a quiet spell:

```
python3 spike/fiberless-idle/wakelat.py 8787 50 20
```

Throughput with the server on cores 0 to 3 and wrk on cores 8 to 11, one server per run, rounds interleaved between the two builds under the shared lock:

```
wrk -t4 -c64 -d10s http://127.0.0.1:8787/
wrk -t4 -c1000 -d12s --latency -s spike/fiberless-idle/think.lua http://127.0.0.1:8787/
```

## What it does not cover

TLS, HTTP/2 and gRPC; an idle deadline for a parked connection; closing parked connections at shutdown; more than one reactor; `zig build test-all`; the fuzzers. `zig build test` passes except `park-check`, which measures a stack the parked connection no longer has.
