# Benchmarks

The harnesses behind every number in [`result/`](./result/). How to measure without fooling yourself is in [`docs/history.md`](../docs/history.md#measuring); what a finished run owes is in [`CLAUDE.md`](../CLAUDE.md#a-benchmark-that-was-run-gets-written-down). `zig build --help` lists every step, including the ones below.

## Where a result goes

One file an area, each carrying what was run, the machine, the commit, the numbers, the decision they moved, and whether the number can be pushed further:

| file | area |
|---|---|
| [`http.md`](./result/http.md) | the server |
| [`sql.md`](./result/sql.md) | the database |
| [`fetch.md`](./result/fetch.md) | the way out |
| [`s3.md`](./result/s3.md) | the object store |
| [`cache.md`](./result/cache.md) | the cache |
| [`job.md`](./result/job.md) | the queue |
| [`proto.md`](./result/proto.md) | protobuf, against a decoder written by hand |
| [`build.md`](./result/build.md) | waiting on the build itself |
| [`releases.md`](./result/releases.md) | each release against the one before it, every module |

[`RESULTS.md`](./RESULTS.md) holds the older binary-size runs.

## The primary metric

```
zig build run -Doptimize=ReleaseFast   # the benchmark server (bench/main.zig): GET /users/:id, ~1 KB JSON
./bench/bench.sh       # wrk/oha against it, already running; `zig build run` alone is a Debug build
zig build profile      # where the time inside one request goes, in-process
zig build profile -- --routes <file>   # and matching on a real route table, `METHOD /pattern` a line
```

## Every release

```
python3 bench/release.py main              # main against the tag before it, every module
python3 bench/release.py v0.5.0 v0.6.0     # any refs, oldest first
python3 bench/release.py --only sql,fetch v0.6.0 main   # some modules (and always the server)
```

Each ref is exported into a tree of its own and built pinned, and `bench/release/` (one program a module) is copied in and built against that ref's modules, so today's harness measures last month's tag. It reports instructions and allocations an operation, bytes an idle connection and stripped binary bytes, refs side by side from one run; it needs `valgrind` and x86-64, and **Release numbers** in GitHub Actions runs it on every published release ([ADR 242](../docs/adr/242-a-release-is-measured-against-the-one-before-it.md)). A program that runs one operation `n` times is `zig build <module>` in `bench/release/`.

## Microbenchmarks

```
zig build bench-cache          # what a cache operation costs, and what an entry weighs
zig build bench-cache-hitrate  # what fraction of lookups it answers, against the best it could
zig build bench-compress       # what gzipping a JSON answer costs at each level, in µs and bytes; -Dlibdeflate for the other backend
zig build bench-compress-stack # the stack one gzip writes below its caller, per backend, in the -Doptimize asked for
zig build bench-sql            # what a prepared statement is worth: SQLite always, Postgres if reachable
zig build bench-job            # what a claim and a push cost on job.Memory, SQLite, and Postgres if reachable
zig build bench-proto          # protobuf decode and encode, against a decoder written by hand; pin it with taskset
zig build bench-json-float     # writing a float as JSON, std.json against serde_json's spelling; pin it with taskset
zig build bench-json-segments  # a JSON answer in arena segments against Allocating, instructions and allocations a request; pin it with taskset, `-- --keep N` sets the arena's keep
```

## Servers for a load generator

Each carries control routes beside the one being measured, so a figure has something standing next to it.

```
zig build bench-sql-server     # every request reads Postgres
zig build bench-fetch-server   # every request calls out
zig build bench-s3-server      # every request reads an object store
zig build bench-body-server    # every request reads a body
zig build bench-compress-server # every answer gzipped on sixteen threads; -Dlibdeflate for the other backend
zig build bench-ws-server      # idle WebSockets, for what one costs
zig build bench-stream-server  # held-open streams, for what one costs
zig build bench-tls-server -Dtls   # the benchmark server over TLS; absent without the flag
zig build bench-echo-server -Dtls  # a 10 KB body echoed over TLS and in plain
zig build bench-page-server -Dtls -Dhttp2  # a page with nineteen subresources over TLS; node bench/page_load.mjs drives Chromium at it
zig build autobahn-server      # the echo server `bash bench/autobahn/run.sh` drives wstest at
```

## Clients

```
zig build-exe bench/fetch_tls_pool.zig -O ReleaseFast   # what a pooled outbound connection holds, plain and over TLS; the header has the commands
```

## Scripts

```
python3 bench/mem.py --port … --path …          # memory per idle connection, any server
python3 bench/mem.py --port … --path … --hold   # the same for a stream nobody closes
python3 bench/mem.py --port … --path … --tls    # the same through TLS 1.3, against bench-tls-server
python3 bench/mem.py --port … --path … --tls --h2 --get   # HTTP/2 over TLS, `h2` by ALPN, after one GET
node bench/page_load.mjs --port … --runs 10 [--http1] [--latency 20]   # a page load in headless Chromium: protocol, connections, time
python3 bench/mem.py --port … --path … --h2 --streams-per-conn 100   # a held-open HTTP/2 stream, counted a stream
python3 bench/fanout.py --port … --framing h1|h2     # events written a second to 100 subscribers of one Room
python3 bench/slowloris.py --port … --path …    # what a body that never finishes holds (VmData, not just VmRSS)
python3 bench/compress_rss.py ./zig-out/bin/nilo-bench-compress-server  # what the compressor pool keeps resident (ADR 248)
python3 bench/ws_idle.py both                   # memory per idle WebSocket, nilo and gws
python3 bench/paced.py --pid … --port … --rate …  # µs of CPU a request at a fixed rate: a server that is not busy (ADR 199)
python3 bench/keepalive.py --ports … --pids … --plan BIIIBIII…  # which executor each keep-alive connection lives on, and each executor's CPU, per window (ADR 275); the server is `zig build bench-keepalive-server`
python3 bench/shutdown.py --cmd … --port …      # does SIGTERM come back? (ADR 077)
python3 bench/fdlimit.py --cmd … --port …       # does a descriptor shortage take the server down? (ADR 194)
python3 bench/burst.py --cmd … --port …         # does a burst of connections get through? (ADR 198)
python3 bench/devloop.py --step dev-spa         # does a save the build never reads restart the server? It must not (ADR 190)
python3 bench/s3_setup.py                       # the bucket and objects the S3 server wants
python3 bench/compare-s3/drive.py               # nilo_s3 against Go, Rust and Bun; needs MinIO
bash bench/compare-cache/run.sh                 # nilo_cache against go-cache; needs Go
bash bench/compare-compress/run_all.sh          # nilo's gzip against libdeflate, zlib-ng, zstd, brotli; clones them
```
