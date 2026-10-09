# Core

**`nilo_core` holds what every other module shares: `Str`, `Run`, the Scope, percent coding, the clock, `Timestamp` and `Date`, `Backoff`, and the WebSocket frame.**

**Guide:** [Handlers](../guide/handlers.md), [Work that is not a request](../guide/background.md), [Decoding a cookie](../guide/cookies.md#decoding-an-encoded-value) · **Design:** [Memory per request and per connection](../design/memory.md), [The clock, entropy, and a UUID](../design/id-clock-entropy.md)

## `Str`

| | |
|---|---|
| `s.view()` | the bytes |
| `s.eql(other)` | compare against a `[]const u8` |
| `s.int(T)` | parse as base-10 |
| `s.len()` | |
| `s.trimmed()` | the bytes with whitespace off both ends, borrowed |
| `s.blank()` | whether there is nothing but whitespace, including nothing at all |
| `s.keep(gpa)` | a copy that outlives the request; the caller frees it |
| `Str.static(bytes)` | text that already outlives any request, which is what a test uses |

`{f}` prints one: `std.log.info("path={f}", .{c.path()})`. `{s}` cannot work, because Zig reserves it for byte slices and a `Str` is a struct.

**Check `blank()` before a write that takes a name, a title or a body.** Required text often arrives as `"  "`: a field somebody tabbed through, or a paste that brought its newline along ([ADR 142](../adr/142-required-text-arrives-as-two-spaces.md)). The whitespace set is `std.ascii.whitespace`, which includes the `\n` that a hand-written `" \t\r\n"` often leaves out. A comment whose whole body is a newline is required text that renders as an empty screen.

`blank()` only reads the bytes. It is not a validation rule: whether a blank title is a 422 is still your decision, the same as with `len()` and `eql()`.

## `Run`

A [Scope](#scope) for work that is not a request: a CLI run, the tick of a scheduled task, a test. You pass it to anything that would otherwise take a `*Ctx`.

```zig
var run = nilo.Run.init(gpa);
defer run.deinit();

const rows = try db.select(User, &run, .{ .where = .{ .age = .{ .gt = 18 } } });
```

| | |
|---|---|
| `nilo.Run.init(gpa)` | |
| `nilo.Run.initIo(gpa, io)` | the same, and able to call `entropy` |
| `run.deinit()` | |
| `run.arena()` | `std.mem.Allocator`: memory that lasts as long as this tick |
| `run.str(bytes)` | `Str`: text you allocated from `run.arena()`, stamped with this tick |
| `run.entropy(n)` | `![n]u8` from the operating system. `error.NoIo` on a Run built by `init` |
| `run.entropyInto(buf)` | `!void`: the same, for a length not known while compiling |
| `run.loop()` | `?std.Io`: the loop this Run was made on, for a job that writes a file or sleeps between attempts; null for a `Run.init(gpa)` |
| `run.give(V, value)` | give this tick a value that code further down can ask for |
| `run.resolve(V)` | `!V`: what `give` stored. `error.NotGiven` if nothing did |
| `run.reset()` | end the tick: the memory is released, what was given goes with it, and every `Str` from it goes stale |

### `run.entropy`

**`entropy` has the same name as [`Ctx.entropy`](./ctx.md#reading), so one function body compiles under both.** "Pass the `*Ctx`, or a `nilo.Run` if there is no request" was not true for the most common function in any program, the one that creates a key, until this existed ([ADR 128](../adr/128-a-scope-that-can-mint-a-key.md)):

```zig
fn create(db: *Db, scope: anytype, title: []const u8) !Doc {
    const key = id.Uuid.v7(try scope.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
    return db.insert(Doc, scope, .{ .id = key, .title = title });
}
```

`init` does not take an `Io`, because handing out memory and stamping a lifetime need none, and most Runs never create a key. `initIo` takes the same `Io` the pool or the `std.Io.Threaded` was started with, which a CLI, a seed and a test all have by the time they build a Run.

### `run.str` and `Str.static`

**Use `run.str` for text you allocated, and [`Str.static`](#str) for a literal.** They make different promises. `run.str` stamps the tick, so the `Str` goes stale when the tick ends and the use-after-request trap can catch it. `Str.static` has no stamp and never goes stale, which is right for a literal in the program's own text. This matters most when a Scope is already at hand and `run.str` looks like the obvious call, for example when building a list, where `run.str` costs a call per element and says something false about a literal:

<!-- compiles -->
```zig
const types: []const Str = &.{ .static("DealValueChanged"), .static("DealWon") };
```

### Passing a value down: `give` and `resolve`

**`resolve` gets a value to code deep in the call stack without passing it through every function on the way.** `nilo_resolve` works a value out once per request and hands it to the handler as an **argument**, which is the top of the call stack. What needs it is often the bottom: an audit row built sixty calls down, where every function in between would otherwise have to carry a value it has no reason to know about ([ADR 133](../adr/133-a-value-that-reaches-the-bottom.md)).

Both scopes have `resolve`, so one function body works under either:

```zig
fn record(db: *Db, scope: anytype, what: Event) !void {
    const actor = try scope.resolve(Actor);   // a *Ctx or a *Run
    _ = try db.insert(AuditRow, scope, .{ .agent = actor.agent, … });
}
```

**Only the source of the value differs.** In a server, `Actor` carries `nilo_resolve` and is worked out from the request, so whether it is set is checked while compiling, and no middleware has to remember to set it (ADR 015). A seed or a CLI has no request to work it out from, so it is given once at the top:

```zig
var run = nilo.Run.initIo(gpa, io);
defer run.deinit();
try run.give(Actor, .{ .agent = "nightly-import" });
```

`run.resolve` returns `error.NotGiven` rather than null, for the same reason `entropy` returns `error.NoIo`: a value nobody set must fail loudly, because the failure this guards against is an audit column that is silently NULL. What was given is copied into the tick's arena, so `reset` clears it. Giving the same type twice replaces it.

**Giving null still counts as giving.** `give` records the type whatever the value, so a `Caller { agent: ?Uuid }` given with `agent = null` resolves to that, and `error.NotGiven` only means nobody called `give`. The three states stay separate. That matters because one of them (nobody wired it up) is a bug, and another (no agent, an ordinary human session) is most of your traffic.

A request never needs `give`. A value read from the request is a `nilo_resolve`, and declaring it removes the third state entirely: the resolver does not depend on the route, and a route asking for the value does not compile without it.

## Scope

**A Scope is not a type: it is the two calls `arena()` and `str()` that [`Run`](#run) lists.** A `Ctx` has them and a `Run` has them, and anything that asks for a Scope takes either ([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)). It is checked while compiling, so passing something else is a Refusal naming the missing call, not an error from inside the module.

**A Scope may also declare `timeLeftMs() ?u32`**, the milliseconds its work has left (`null` for none, `0` once gone). A `Ctx` does, from the route's [`nilo.deadline`](./middleware.md#nilodeadline) or `request_deadline_ms`; a `Run` and an `AnyScope` do not. `nilo_fetch`, `nilo_s3` and `nilo_sql` read it so that a call takes the shorter of its own bound and the time left ([ADR 105](../adr/105-a-route-can-say-how-long-it-has.md)):

| Call | Does |
|---|---|
| `core.timeLeftOf(scope)` | `?u32`: the Scope's `timeLeftMs()`, or `null` for a Scope that does not declare one. Resolved while compiling |
| `core.within(scope, own_ms)` | `error{DeadlineExpired}!u32`: the shorter of `own_ms` and the time left, where `0` means no limit at either end. A Scope with no deadline gives `own_ms` back; one whose time has passed is `error.DeadlineExpired` |

Both live in `nilo_core`. A project that imports `nilo` never has to name it (`nilo.Str` and `nilo.Run` are the same declarations), but a program with no server in it can depend on `nilo_core` alone.

### `AnyScope`

**`AnyScope` is a Scope with its type erased, for passing a Scope through a function pointer** ([ADR 144](../adr/144-a-scope-that-crosses-a-function-pointer.md)). Zig has no closures, so a bus, a queue or a job registry stores a callback as a function pointer. A function pointer names one type per argument, so without this a callback cannot be generic over its Scope and still run both under a request *and* under a `Run` in a test.

```zig
const Reaction = *const fn (scope: *nilo.AnyScope, payload: []const u8) anyerror!void;

fn notify(scope: *nilo.AnyScope, payload: []const u8) !void {
    const kept = try scope.arena().dupe(u8, payload);
    _ = try db.insert(Notice, scope, .{ .body = kept });
}

var erased = nilo.AnyScope.of(c);   // or `.of(&run)` outside a request
try reaction(&erased, payload);
```

| | |
|---|---|
| `nilo.AnyScope.of(scope)` | erase a `*Ctx` or a `*Run`. Two stores, no allocation |
| `erased.arena()` | the wrapped Scope's, through the vtable |
| `erased.str(bytes)` | the same, stamped with the wrapped Scope's lifetime |
| `erased.entropy(n)` | `![n]u8` |
| `erased.entropyInto(buf)` | `!void`, and the one the vtable actually carries |
| `erased.requestId()` | `?Str`: the request's id when it was made from a `*Ctx`, `null` from a `Run` ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)) |
| `erased.resolve(V)` | `!V`: only what the Scope behind it **already holds**, either given to the `Run` or resolved for the request before it was erased. `error.NotGiven` otherwise, because an erased Scope never runs a resolver. So a type that only the far side asks for is resolved in the middleware that checks it (`_ = try c.resolve(V);` before `next.run`), not at the bottom ([ADR 144](../adr/144-a-scope-that-crosses-a-function-pointer.md)) |

It passes the Scope check, so `db.select(Row, &erased, …)` works: a callback can query, and can ask who is acting.

**It also connects two modules that must not import each other.** A module that opens work on behalf of another declares the function it needs as a pointer type, `OpenWork = struct { open: *const fn (tx: *sql.Db.Tx, c: *nilo.AnyScope, in: OpenWorkInput) anyerror!sql.Uuid }`, and the wiring file, which imports both, fills it with a function the other module wrote against a generic Scope. The same body then runs under a `Run` in a test, a `Ctx` on the server and the erased Scope across the pointer, and neither module names the other.

**It borrows.** The pointer inside is the Scope's own, so an `AnyScope` must not outlive the `Ctx` or `Run` it was made from; in practice it is a local variable next to the call. **The ordinary Scope is unchanged**: every call in nilo and in `nilo_sql` still takes `anytype` and still costs no indirect call. The vtable is paid for only where somebody erases a Scope.

**A Scope can also be asked what it knows, through plain functions that take any Scope and answer `null` for one that does not know.** `nilo_core.requestIdOf(S, scope)` is the request id ([ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md)); `routeNameOf(scope)` is the `operationId` of the route its request matched, which is what `nilo_sql` puts on a statement it reports ([ADR 108](../adr/108-a-statement-can-be-watched.md)); `serialOf(scope)` says which request or tick it is on, for a module that keeps something between calls and has to know it is still the same one ([ADR 117](../adr/117-a-statement-that-failed-says-what-the-database-said.md)); `traceBeginOf(scope)` and `traceEndOf(scope, begun, ended)` open and close the span of a call that is leaving, which `nilo_fetch` asks so its `traceparent` names the call ([ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)). `nilo_core.trace` holds the W3C Trace Context they speak.

## `nilo_core.Backoff`

**How long to wait before trying again, as a function of how many times it has been tried, with the jitter that keeps a herd of callers from coming back together.** It is in Core because `nilo_job` waits between a job's attempts and `nilo_fetch` between a call's, the two are siblings, and each needs the same arithmetic ([ADR 057](../adr/057-percent-is-needed-by-two-layers.md), [ADR 271](../adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md)). `job.Backoff` is this type.

| | |
|---|---|
| `.{ .fixed_ms = 50 }` | the same wait every time; nothing random is added |
| `.{ .exponential = .{ .from_ms, .to_ms, .jitter } }` | doubling from `from_ms`, never past `to_ms`; `.jitter` is `.none` (the default), `.full` (anywhere from none to the whole wait) or `.equal` (the top half) |
| `b.ceilingMs(failed)` | the wait after the attempt numbered `failed` (1 for the first) before any jitter, in milliseconds |
| `b.delayMs(failed, random)` | the same with the jitter spent, `random` being any 64 bits; a backoff without jitter ignores them. Core has no `Io`, so the caller draws the bits (`std.Io.random` is a per-executor generator, not a syscall) |

## `nilo_core.ws_frame`

**The WebSocket frame as bytes**: the opcodes and close codes, the header read and written, the masking, the rules a header is held to, the close payload, the text rule and the handshake's accept key. It reads and writes nothing, imports `std` only, and is what the server's `Socket` and `nilo_fetch`'s `WebSocket` share, so a masking loop cannot differ by a byte between the two ends ([ADR 281](../adr/281-nilo-fetch-opens-a-websocket-and-the-framing-is-core.md), [ADR 057](../adr/057-percent-is-needed-by-two-layers.md)). A handler does not call it; a test that wants to write a frame by hand or a client of another transport may.

| | |
|---|---|
| `Opcode`, `Close` | RFC 6455 §5.2's and §7.4.1's numbers; `nilo.websocket.Close` is `Close` |
| `headerFrom(bytes)` | a `?Frame` out of the bytes in hand, or null when there are not yet enough of them; pure, and judges nothing |
| `Frame.wellFormed(sender)` | whether the header is one `.client` or `.server` may send: no reserved bit, masked from a client and not from a server, the length in its shortest form, a control frame small and whole |
| `writeHeader(&buf, opcode, len)`, `writeMaskedHeader(&buf, opcode, len, key)` | the bytes in front of a server's frame and a client's |
| `unmask`, `unmaskInto`, `maskInto` | the XOR with the key, in place or while copying, in 128, 32, 8 and 4 byte steps; `offset` lines the key up across a payload read in pieces |
| `closeIsWellFormed(payload)`, `closePayload(&buf, code, reason)`, `reasonFits(reason)` | a close frame's payload checked and built, the reason cut on a character |
| `validText(bytes)` | UTF-8, which is what text is |
| `accept(key)` | the answer to `Sec-WebSocket-Key` |

## `nilo_core.percent`

**Percent coding by RFC 3986, in both directions.** The server decodes every path param and query value with it, and you never call that half. The encoding half is for building a URL or signing one. It is in Core rather than in `nilo_http`, so a Service can use it too ([ADR 057](../adr/057-percent-is-needed-by-two-layers.md)).

```zig
const percent = @import("nilo_core").percent;

var buf: [256]u8 = undefined;
const key = percent.encodeInto(&buf, "holiday photos/bali.jpg", .path);
// "holiday%20photos/bali.jpg"
```

A handler reaches the same thing as **`nilo.percent`** without another import. That is the other half of ADR 057, and it is what `examples/outbound/` uses to put a path param into a URL it is about to fetch.

| Call | |
|---|---|
| `percent.encodedLen(raw, set)` | `usize`: exact, not an estimate, since every byte becomes one or three |
| `percent.encodeInto(dst, raw, set)` | `[]u8`: the part of `dst` used. `dst` must be at least `encodedLen` long |
| `percent.encodeWrite(w, raw, set)` | straight to a `*std.Io.Writer`, for something assembled a piece at a time |
| `percent.decode(gpa, raw, plus_as_space)` | `![]const u8`: allocates only if there is something to decode, otherwise returns `raw` |
| `percent.decodeInto(dst, raw, plus_as_space)` | `[]u8`: the part of `dst` used |
| `percent.decodedLen(raw)` | `usize` |
| `percent.needed(raw, plus_as_space)` | `bool`: whether decoding would change anything |

`set` is `.path`, where `/` is a separator and stays, or `.unreserved`, where `/` is data and becomes `%2F`. Everything outside RFC 3986's unreserved set (`A-Z`, `a-z`, `0-9`, `-`, `.`, `_`, `~`) is escaped in both. That includes `!`, `*`, `'`, `(` and `)`, which matters if you are used to `encodeURIComponent`.

Three things are not options, because getting any of them wrong fails silently: **a space is always `%20` and never `+`**, **hex is uppercase**, and **there is no allocating encoder**, so measure with `encodedLen` or write with `encodeWrite`. `decode` allocates because the request path needs it to.

`plus_as_space` is the decoder's only switch, and it is for query values: `?q=a+b` means "a b" because HTML forms have encoded it that way since 1995. It stays off for path params, where a `+` is a plain `+`.

## The clock

| | |
|---|---|
| `nilo.nowMicros()` | `i64`: microseconds since the epoch. What `sql.Timestamp` counts |
| `nilo.nowMillis()` | `i64`: milliseconds. What a UUID v7 puts in its first six bytes |
| `nilo.monotonicMicros()` | `i64`: microseconds since an arbitrary point. Subtract two of them to get how long something took |

These are plain functions, not calls on a `Ctx` or a `Run`: reading the wall clock needs no event loop and nobody owns the time, so there is nothing for a Scope to hold ([ADR 041](../adr/041-core-knows-what-time-it-is.md)). They belong to `nilo_core`, so a program with no server in it has them too. A call takes 15ns.

**Use `monotonicMicros` for a duration, never the other two.** A wall clock moves when an operator changes it or NTP steps it, so two readings a second apart can come back in either order. It is the clock `db.watching` uses to time a statement ([ADR 108](../adr/108-a-statement-can-be-watched.md)).

## `Timestamp` and `Date`

| | |
|---|---|
| `nilo.Timestamp` | a moment: `micros: i64`, microseconds since 1970-01-01 UTC. `.now()`, `.fromSeconds(s)`, `.seconds()`, `.writeRfc3339(w)`, `.nilo_parse(text)` |
| `nilo.Date` | a calendar day: `days: i32`, days since 1970-01-01, no hour and no zone. `.fromDays(n)`, `.utcOf(timestamp)`, `.atMidnightUtc()`, `.writeIso(w)`, `.nilo_parse(text)` |

**They work in a build with no database**: as a JSON body field and a JSON response field (an RFC 3339 string and a `YYYY-MM-DD` string), a query field, a path param and a form field, and the OpenAPI document says `type: string` with `format: date-time` and `format: date`. They live in `nilo_core` and `sql.Timestamp` and `sql.Date` are the same types, so a Row field and a request field are one declaration ([ADR 057](../adr/057-percent-is-needed-by-two-layers.md)).

A `Timestamp` is written as RFC 3339 in UTC with six fractional digits (`2026-08-16T09:30:00.700000Z`), from 0001-01-01 to 9999-12-31; a moment outside that is `error.OutOfRange` and a 500 in a response, never `null`. It reads an offset (`+07:00`) and normalises to UTC, and fractional seconds to the microsecond, and **refuses text with no zone**, because there is no correct reading of it. A `Date` reads `2026-09-17` and nothing else: a date with a time on it is refused rather than read by dropping the time. Neither calculates (no zones, no `addDays`).

## `nilo_core.tmpDir`

**A directory for one test, with the path to a file in it.** It is the declaration [`nilo.testing.tmpDir`](./testing.md#testingtmpdir) re-exports, and it is here so a test in a module that cannot name `nilo_http`, such as `nilo_sql`, has the same one ([ADR 250](../adr/250-a-test-directory-hands-back-its-path.md)). Only a test can call it.

## A handler that blocks its thread

**nilo warns when a handler waits on the operating system without going through the event loop.** Such a wait holds the thread that every other request on it is being served by. nilo says so, at most once a second:

```
handler GET /users/7 held its thread for 2003ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
nilo.blocking (ADR 013).
```

A wait inside a service (`db.raw` on its socket, a pool a caller queues on) goes through the loop too, and the service reports it through `Limits.waiting`/`waited` ([ADR 210](../adr/210-a-services-wait-on-its-own-socket-is-a-park.md)). A slow query is not reported here; a blocked thread is.

The warning fires on the first request, even with nobody else waiting, on purpose: under `curl` the mistake would otherwise be invisible. `block_warning_ms` is the threshold, and `0` turns it off. What is measured is the longest stretch the fiber ran **without parking**, so a stream, a body reader and a WebSocket are watched the same way as anything else. A blocking call inside a WebSocket loop is where it costs the most ([ADR 013](../adr/013-handlers-must-not-block-the-thread.md)).

## `nilo.spawn` and `app.spawn`

**`nilo.spawn` starts `f` in a fiber the server owns**: counted while it runs, and cut off when the shutdown grace period ends. It returns `error.NoServer` if nothing is listening. Two things must not be passed into it, and the compiler catches neither: a `Str`, which points into the request arena that is about to be reset, and a fail function, which has no request to fail and so returns a bare error that nobody turns into a response. Copy what you borrow, and log instead of failing.

```zig
try nilo.spawn(flushMetrics, .{&exporter});
```

**From `main`, use `app.spawn`**, because `listen()` does not return. `app.spawn` registers the same work before the server exists and starts it once there is one: after the port is taken, after the services and whatever `app.before` registered, and before the first connection is accepted ([ADR 028](../adr/028-a-spawned-fiber-belongs-to-the-server.md), [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md), [the guide](../guide/background.md)):

```zig
try app.spawn(flushEvery, .{&exporter});
try app.listen(.{});
```

The work is a loop around a wait that can be told to stop: `nilo.sleep` fails with `error.Canceled` when the grace period ends, and that is the only way out.

Sending to a WebSocket that another connection holds does not need this; see [`Room`](./streaming.md#room). It needs no fiber of its own, which is the whole of [ADR 035](../adr/035-a-broadcast-rings-a-bell-it-does-not-write.md).
