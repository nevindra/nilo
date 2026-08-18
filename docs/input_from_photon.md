# Roadmap input for nilo

Findings from evaluating whether **Photon** could move from Rust to Zig 0.16 + nilo 0.2.0.

Photon is a self-hosted, OTEL-native observability platform: 63,948 lines of Rust across 13
crates, five signals (logs, traces, metrics, uptime, RUM), shipped as a single binary with an
embedded Vue UI.

Every gap below is anchored to a specific place in Photon that needs it, with the line count or
call count that justifies it. Nothing here is speculative "would be nice". Ordered by how much
each one unlocks, not by how hard it is.

Assessed against nilo 0.2.0 (`README.md`, `CHANGELOG.md`, `docs/roadmap.md`, `docs/reference.md`,
`docs/guide/{sql,static-files,streaming,services}.md`) and Zig 0.16.0 stdlib source.

---

## Summary

| # | Gap | Module | Unlocks | Conflicts with a stated non-goal? |
|---|-----|--------|---------|-----------------------------------|
| 1 | Internally-tagged union JSON | `nilo_core` / `nilo_http` | Every REST API with sum types | No |
| 2 | Static files from an embedded blob | `nilo_http` | Single-binary deployment | No |
| 3 | Periodic background jobs | `nilo_http` | 9 of Photon's background loops | No — but touches an open risk |
| 4 | A fiber-aware channel | `nilo_core` | 24 call sites; prerequisite for #3 | No |
| 5 | Dynamic response compression | `nilo_http` | JSON-heavy APIs over a WAN | No — already queued, "waiting on design" |
| 6 | `LIST` and `DELETE` in `nilo_s3` | `nilo_s3` | Any object store with a retention policy | No |

Three more items sit behind decisions already made. They are recorded at the bottom under
[Stated non-goals](#stated-non-goals-recorded-not-requested), for information only.

---

## 1. Internally-tagged union JSON

**The single highest-leverage item on this list.** If only one thing ships, make it this one.

### What's missing

Zig's `std.json` knows exactly one union encoding: externally tagged.

`lib/std/json/Stringify.zig:419-445` writes:

```json
{"Metrics": {"metric_name": "system.cpu.utilization", "agg": "avg", "threshold": 0.9}}
```

`lib/std/json/static.zig:271` and `:602` parse that same shape back.

Most real REST APIs use internally tagged unions instead, with the variant's fields flattened
into the same object:

```json
{"signal": "metrics", "metric_name": "system.cpu.utilization", "agg": "avg", "threshold": 0.9}
```

There is no way to express that declaratively. You hand-write `jsonStringify` and `jsonParse`
per type.

### Why it matters

This is not one awkward type in one subsystem. In Photon:

| Type | Variants | Where |
|------|----------|-------|
| `Condition` | 4 (metrics/logs/traces/rum) | alert rules |
| `ChannelConfig` | 3 (webhook/discord/telegram) | notification channels |
| `TermKind` | 4 | the query grammar AST |
| OTLP `AnyValue` | 6 | every ingest path |

Plus the string-cased enums that ride along with them: `MetricAgg` (11 variants), `TraceKind`
(6), `RumKind` (6), `Severity` (3), `Cmp` (4) — all serialized as `lowercase` or `snake_case`
rather than the Zig field name.

Two compounding costs:

1. **Volume.** Photon's `model.rs` is 542 lines *including* the domain logic, because Rust's
   `#[derive(Serialize, Deserialize)]` + `#[serde(tag = "signal")]` generates the codec from
   about 10 lines of attributes. Hand-writing the equivalent in Zig is an estimated +300 lines
   of pure boilerplate, and it has to be kept correct by hand as variants are added.
2. **Wire compatibility is not optional.** Those JSON strings are already persisted in SQLite
   columns (`alert_rules.condition`, `alert_channels.config`) and are the contract a browser
   frontend speaks. Adopting Zig's native shape is a data migration plus a frontend rewrite, not
   a formatting preference.

### Why it belongs in nilo

This is a **library gap, not a language gap.** Zig's comptime reflection is fully capable of it —
`std.json` simply made one choice and stopped. And nilo is already in this business: the 0.2.0
changelog notes that types with a custom `jsonStringify` must declare their OpenAPI schema via
`nilo_openapi`, so the hook point already exists and already has a documented contract.

### Possible shape

A marker declaration on the type, in the same style as `nilo_table`:

```zig
const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal", .rename_all = .lowercase };

    metrics: MetricCondition,
    logs: LogCondition,
    traces: TraceCondition,
    rum: RumCondition,
};

const Severity = enum {
    pub const nilo_json = .{ .rename_all = .lowercase };
    info, warning, critical,
};
```

`.tag` covers internally-tagged unions. `.rename_all` covers cased enums, which is the other
half of the problem and is cheap on its own. Between them that is most of what serde's attribute
surface is actually used for in practice.

Worth considering as part of the same design: `.tag` implies the OpenAPI discriminator, so
`nilo_openapi` could derive the schema instead of requiring it to be declared by hand.

---

## 2. Static files from an embedded blob

### What's missing

`docs/guide/static-files.md`: the directory is read into memory at `listen()`, and "the path is
relative to the working directory the server runs in".

There is no way to hand nilo a tree that was embedded into the binary at compile time.

### Why it matters

Photon's core promise is a single binary. The Vue production bundle is compiled into the
executable with `rust-embed`, and there is no `frontend/dist` directory on the deployment host.
With nilo as it stands, that becomes "ship a binary plus a directory, and get the working
directory right" — which is a different product.

This is frustrating precisely *because* the hard part is already built and built well. Gzipped
once at App-build time, ETag per file, SPA fallback, path traversal structurally impossible,
zero-allocation serving with middleware in front. All of that is exactly right. The only thing
missing is a second way to get the bytes in.

Zig already supplies the other half via `@embedFile`. What is missing is the entry point.

### Possible shape

```zig
try app.staticEmbedded("/", @import("dist_manifest").files, .{
    .spa_fallback = "index.html",
    .cache_control = "public, max-age=31536000, immutable",
});
```

...where the manifest is a comptime list of `.{ name, bytes }`, generated by a build step that
walks the directory. The runtime path after that is identical to today's: same in-memory list,
same ETag, same gzip-at-build, same lookup. `max_total_bytes` and `max_file_bytes` stop being
meaningful (nothing can spill — it is all in the binary), which is a simplification rather than
a complication.

The build-step half could reasonably be left to the caller, as long as the API accepts a
comptime file list.

---

## 3. Periodic background jobs

### What's missing

`nilo_start` covers initialization once the loop exists. There is no documented facility for
"wake every N, do work, listen for a control signal, shut down cleanly".

`docs/roadmap.md` lists **"spawned fiber lifetime safety (design needed)"** as an open risk,
which means rolling this by hand today means entering territory nilo has not settled yet.

### Why it matters

Photon has **9 long-lived background loops in `main.rs` alone**, and every one of them is the
same shape:

| Loop | What it does |
|------|--------------|
| 3 compactors (logs/spans/metrics) | drain closed WAL segments → Parquet |
| replicator drain | upload + retention deletes to the durable store |
| segment merge | consolidate small files, bounded per pass |
| alerts scheduler | evaluate due rules, fan out notifications |
| uptime scheduler | run HTTP/TCP/ICMP probes on a per-monitor interval |
| federation pusher | push tenant summaries upstream |
| usage sampler | sample storage/ingest counters |

Every one: tick on an interval, do bounded work, respond to a control channel (rule added, monitor
disabled, shutting down).

This is not an observability-specific need. Session pruning, cache warming, outbox draining,
metrics rollups, and token refresh are all the same shape, and most non-trivial services have at
least one.

**This gap blocks more of Photon than any other item on this list**, including #1. A web
framework that can serve requests but cannot host a supervised recurring job forces the caller
into a second process or into unsupported fiber lifetimes.

### Possible shape

```zig
fn compact(db: *sql.Db, run: *nilo.Run) !void { ... }

try app.every(60 * std.time.ns_per_s, compact);
```

The valuable part is not the timer. It is the surrounding contract:

- Runs on a `Run` scope (not a request arena), so #4's `Str` lifetime trap does not apply.
- Services resolved by type, same as a handler, with the same startup-time "never registered" error.
- Overlap policy stated: skip the tick if the previous run is still going, rather than stacking.
- `app.shutdown()` waits for an in-flight job to finish instead of tearing the fiber out.
- A job that fails is logged and rescheduled, not silently dead.

That last set is exactly the "spawned fiber lifetime safety" question. Answering it once, inside
nilo, is far better than every caller answering it differently and wrongly.

---

## 4. A fiber-aware channel

### What's missing

`nilo.Mutex` exists and is fiber-aware — correctly so, since `std.Thread.Mutex` would block the
whole thread and every other request on it. There is no equivalent for message passing.

### Why it matters

Photon uses **24 `mpsc::channel` sites**:

- WAL group commit: many writers wait for one shared `fsync`, then all acks resolve
- alerts scheduler: rule upsert/remove commands in, sample results back
- replicator: bounded upload queue with retry and re-enqueue
- uptime scheduler: probe results back to the state machine

Multi-producer / single-consumer is the backbone of every background loop in #3. Without it, the
fallback is a mutex-guarded queue plus a sleep-poll, which is both slower and easier to get
wrong.

### Why it belongs in nilo (arguably)

A fair objection: this is std's job. The counter is that Zig 0.16's std does not yet ship a
fiber-aware one, and nilo already made exactly this call for `Mutex` and for the same reason.
`nilo.Channel(T)` next to `nilo.Mutex` is a consistent decision, not scope creep.

### Scope note

**A `select!` equivalent is explicitly not being requested.** That needs language support, and
its absence is survivable. One channel plus a timeout covers all 24 Photon sites; the alerts
scheduler's three-way `select!` restructures into a tick fiber plus a mutex-guarded rule map
without losing anything.

---

## 5. Dynamic response compression

### Status

Already on the roadmap as "response body compression pool (waiting on design)". This is a vote
for it, plus a data point for sizing.

### Why it matters

Static assets are solved — gzipped once at App-build time, which is the right answer for files
that never change. Handler responses are not, and for an API-heavy application that is where the
bytes actually are.

Concrete number from Photon: a page of JSON log records compresses roughly **15x**. For an
observability UI pulled over a WAN, that is the difference between usable and not. It is also
why Photon wraps its entire 67-route surface in a compression layer today.

### The constraint, acknowledged

A gzip compressor wants a 64 KB window. One per connection takes an idle connection from 4,669
bytes to roughly 15x that, which breaks two of the four budget axes. One per request puts an
allocation on a path budgeted for exactly one. Both objections are correct.

A pool borrowed only for the duration of an encode — sized to concurrent *encodes* rather than
to connections or requests — appears to sidestep both, since the window is held only while bytes
are actually moving. Whether that survives contact with the budget is nilo's call, not an
outsider's.

### One detail worth designing in from the start

Compression must be **skippable per route**, and SSE is the case that proves it. Buffering an
event stream to fill a compression window defeats the entire point of the stream. Photon hit
this and had to configure a predicate that excludes `/api/stream/*`. Since nilo's SSE already
sends `X-Accel-Buffering: no` to defeat proxy buffering, defaulting `c.events()` to
uncompressed would be consistent with a choice nilo already made.

---

## 6. `LIST` and `DELETE` in `nilo_s3`

### What's missing

Per the README, `nilo_s3` ships get, put, range, stream, and presign, and excludes LIST and
multipart by design.

### Why it matters

Photon calls `.list()` at **24 sites** and `.delete()` at **24 sites** against the durable store:

- **Retention.** The replicator carries deletes as well as uploads. When a merge or a purge
  unlinks an object from the hot tier, a durable delete is enqueued behind it. Without DELETE,
  the durable replica grows forever and retention silently does not apply to it.
- **Reconciliation.** LIST is how the manifest checks what actually landed after a crash or a
  partial upload.

Without both, `photon-storage` (1,136 lines) cannot move at all. get/put/range/presign is
enough to *write* to an object store, but not enough to *own* one.

The design rationale for excluding LIST is understandable: it is paginated, it is the one call
with unbounded output, and it invites treating a bucket as a database. A deliberately bounded
form would still close the gap:

```zig
const page = try s3.list(c, .{ .prefix = "data/", .max_keys = 1000, .after = cursor });
```

Explicit cursor, explicit cap, no auto-pagination helper. That keeps the "no junk drawer" line
while making retention and reconciliation possible.

**Multipart is not being requested.** Photon's Parquet files stay under the single-put ceiling,
and streaming uploads are a genuinely different problem.

---

## Already good — do not change these

Recording these because a gap list read alone gives a distorted picture. Four things in nilo are
better than what Photon runs today in Rust:

**Static file serving.** Gzipped once at App-build time rather than per request, ETag per file,
SPA fallback built in, path traversal structurally impossible because there is no path to
resolve. Photon's `rust-embed` + per-request compression layer is strictly worse on every axis.
Only the embedded-source gap (#2) keeps it from being adopted as-is.

**SSE.** `c.events()` with `send` / `json` / `comment` / `retry` / `live` / `close`, every send
flushing, and `X-Accel-Buffering: no` on the head. Photon's live-tail is 391 lines of axum
`Stream` plumbing to get to the same place, and it had to discover the proxy-buffering header
the hard way.

**Services.** Type-matched injection, `*const T` and `*T` distinguished, and a missing service
failing at `listen()` with the list of routes that needed it. Failing before the socket opens,
with that error message, is better than anything Photon's manual `Arc` wiring in `main.rs` gives.

**OpenAPI from handler types.** Photon has 67 routes and zero schema — no OpenAPI, no types
shared with the frontend, no generated client. Getting that from the signatures is a real
capability, not a checkbox.

Two more, smaller: `nilo_sql`'s `.any` for OR and literal-null-to-`IS NULL` handle every query
shape Photon's control-plane tables need, and `db.raw()` being present means the abstraction has
an honest exit. `db.checking()` verifying rather than creating is also the right call — it
matches what Photon already does by hand and avoids pretending to be a migration tool.

---

## Stated non-goals, recorded not requested

These are already-made decisions. They are listed with their cost so the trade is visible, not
to reopen it.

**Configuration file parsing.** Photon's config is 1,087 lines of TOML schema. Env-only means
either hand-rolling a TOML parser or redesigning config around environment variables. For a
self-hosted product where operators edit a config file by hand, the second is a real product
change. The 1,087 figure is offered as a data point on how large "just use env vars" can get.

**gRPC.** This one is load-bearing, and worth stating plainly: it permanently blocks
`photon-ingest` (6,085 lines). OTLP over gRPC is the default egress of the OpenTelemetry
Collector — the single most common way telemetry arrives anywhere. "Terminate it in front" works
for TLS because TLS ends at the boundary. It does not work for gRPC, because gRPC is not only
transport: the length-prefixed framing and the protobuf decode reach all the way into the
handler. There is no proxy that turns it into something a nilo handler can read.

This does not argue that nilo should implement gRPC. It argues that "no gRPC" should be read as
"nilo is not for services on the receiving end of the OTel ecosystem", which is a larger
territory than the sentence in the README suggests.

**Panic recovery.** Correct that it is not possible in Zig. Noted only because for one class of
software — observability platforms, databases, anything whose job is to still be running when
everything else is not — an uncatchable panic is a different kind of decision than it is for a
typical web application. Not a request. A flag on which workloads nilo is a good answer for.

---

## Appendix: the evidence base

Photon, by crate, with how each fared in this assessment:

| Crate | LOC | Verdict |
|-------|-----|---------|
| `photon-index` | 1,368 | Zig wins outright — hand-rolled bloom filter, bit-packed binary sidecar, no dependencies |
| `photon-uptime` | 1,837 | Wins, except ICMP needs raw sockets |
| `photon-core/query/` | 1,476 | Slight win — hand-written parser, AST, tree-walking evaluator |
| `photon-wal` | 1,584 | Frame layer wins (`[u32 len][u32 crc32][payload]`, group-commit fsync); payload is Arrow IPC and does not |
| `photon-api` | 10,646 | Mixed, leaning win |
| `photon-alerts` | 2,689 | Mixed, leaning loss — dominated by gaps #1 and #3 |
| `photon-storage` | 1,136 | Blocked on gap #6 |
| `photon-agent` | 728 | Blocked on sysinfo / NVML bindings |
| `photon-core` (rest) | 3,976 | Wall — Arrow schemas and record builders |
| `photon-compact` | 4,477 | Wall — Parquet writer |
| `photon-ingest` | 6,085 | Wall — OTLP gRPC and protobuf |
| `photon-query` | 19,196 | Wall — DataFusion |

The four walls are 33,734 lines, 53% of the codebase. None of them are nilo's problem: Arrow,
Parquet, DataFusion, and protobuf/gRPC have no mature Zig equivalents, and nilo has never
claimed that territory. They are listed so the scope of what nilo *could* address is honest.

### One safety note, outside the roadmap

`docs/guide/services.md` already documents it, and it deserves to stay prominent: a `Str` points
into an arena that dies with the request, a service outlives the request, and storing one
compiles, passes tests, and serves the next request's bytes.

Photon has four stores that persist strings taken straight from request bodies (`AlertStore`,
`RumAppStore`, `UserStore`, `UptimeStore`). Rust's borrow checker closes this at compile time;
Zig does not. This is not a feature request — it is a property of the design, and the guide
handles it about as well as prose can. It is recorded here because it is the single largest
safety regression in a Rust-to-nilo move, and any team weighing that move should see it before
they start rather than after.
