//! Bulkhead — the internal boundary between nilo and the Engine.
//!
//! Everything nilo needs from the Engine goes through this file. No part
//! of nilo outside `src/engine/` may name zio. Swapping the Engine means
//! swapping the one import below, without touching a line of user code.
//!
//! The contract an Engine has to meet:
//! - reading the fields of `Options` that name a socket, a buffer or a
//!   deadline. The struct itself is declared here, not by the Engine, so
//!   that swapping the Engine cannot change what a user writes.
//! - `serve(gpa, options, stop, state, ready, handler)` — listen, accept
//!   connections, and run `handler(state, in, out, deadlines, waker, peer)`
//!   for each one concurrently until that connection is done. `state` is
//!   carried through as-is (normally `*App`). Returns when `stop` is set.
//! - `ready(state, io, limits, port)` inside that call — run once, after the
//!   port is taken and before the first connection is accepted, and hand over
//!   the `std.Io` the Engine runs on. This is the one thing here that exists
//!   for a caller rather than for nilo: a connection pool cannot be built
//!   before `listen()`, because the event loop it has to dial through does
//!   not exist yet, and a pool built without one blocks the thread every
//!   request shares (ADR 037). The type is std's, not zio's, so this hands
//!   out nothing that names the Engine. `port` is the one actually bound —
//!   the kernel's answer when `Options.port` was 0 — and null for a unix
//!   socket; it is how a test asks for any free port instead of walking a
//!   range of them.
//! - `stopping(state)` inside that call — run once on the way out, after
//!   the last connection has been cut off and before the Engine's loop is
//!   torn down. The mirror of `ready`, and it exists for the same caller: a
//!   Service that put work on the loop in `ready` has to take it off, or
//!   the loop cannot be shut down at all. It takes no `Io` and cannot fail
//!   — a service is stopped on the loop it was started on, and there is
//!   nobody left to hand an error to. It runs on the failure paths too,
//!   including a `ready` that refused the boot (ADR 121).
//! - `Limits.arm`/`release`/`fired` — put a time limit on an operation that
//!   is *not* a read or write of a connection nilo holds, and say afterwards
//!   whether that limit is what cancelled it. `Deadlines` below covers
//!   inbound, where nilo owns the socket and can set a timeout on it;
//!   outbound the socket belongs to a driver, so the only thing left to bound
//!   is the unit of work itself. An Engine that cannot cancel an operation in
//!   flight can no longer meet this contract (ADR 056). The type is
//!   `nilo_core`'s, because the caller is a Service and a Service may not
//!   import `nilo_http`.
//! - `Peer` — who is at the other end of a connection. `accept` already
//!   knows, so this asks the Engine for nothing it did not have.
//! - `Deadlines.limit`/`Deadlines.timedOut` — put a time limit on the next
//!   read or write of one connection, and say afterwards whether that limit
//!   is what a failure was. An Engine that waits on sockets already has to
//!   be able to wait with a limit, so this asks for nothing new of it
//!   (ADR 022).
//! - `Waker.wait`/`Waker.post` — park a connection until its socket is
//!   readable *or* another fiber has something to say to it, and wake one
//!   from anywhere. Everything else in nilo is woken by the client at the
//!   other end, which is what makes a broadcast impossible without this. An
//!   Engine that waits on sockets can already wait on two things — it has to,
//!   to wait with a deadline at all — so this asks for nothing new of it
//!   beyond a handle to say so with.
//! - a read that flushes first — the `in` handed to `handler` puts whatever
//!   `out` still holds on the wire before it reads the socket. nilo skips
//!   the flush on a response whose successor is already in the read buffer,
//!   so a pipelined batch leaves as one write, and this is what makes the
//!   skip safe rather than a bet: no read can park a connection with a
//!   response still in memory (ADR 201). One load of the writer's fill on
//!   each read that reaches the socket, and nothing on a read that does not.
//! - `Waker.halfClose` — send the peer a FIN without closing the socket, so
//!   a refused request's answer reaches it before the reset that closing on
//!   unread input would send (ADR 195). One `shutdown(2)`; an Engine that
//!   owns a socket has it.
//! - `Stop`/`explained` — the flag that ends `serve`, and which startup
//!   failures it has already explained in words.
//! - `debug_io` — wired into `std_options_debug_io` so that `std.log`
//!   does not block the event loop.
//! - `Binding`/`bindSlot`/`unbindSlot`/`slot` — one pointer bound to the
//!   unit of work currently running (a fiber, a thread, whatever the
//!   Engine uses), for hidden per-request state (ADR 006).
//! - `bindsOn(io)`: whether `io` is the Engine's own loop, so a slot can be
//!   bound under it; the boot work asks before it binds one (ADR 129).
//! - `monotonicNanos` — a monotonic clock. Zig 0.16's `std.time` carries
//!   only constants, and the Engine already keeps a clock, so the logger
//!   asks for it here rather than reaching for a syscall of its own.
//! - `Mutex` — a lock that parks the unit of work rather than the OS
//!   thread under it. Handlers run concurrently on several threads, so a
//!   Service with mutable state needs one; and `std.Thread.Mutex` is the
//!   wrong tool, because blocking the thread also stops every other fiber
//!   sharing it — including, possibly, the one holding the lock. Taking one
//!   can be refused, so the Engine also has to offer a way of taking it that
//!   cannot be: a cleanup path has nowhere to put a `Canceled`.
//! - `Condition`/`waitWithin` — park on a `Mutex` until woken, oldest
//!   waiter first, with or without a limit on how long. `Gate` is built on
//!   it and on nothing else of the Engine's: its arrival order is the
//!   queue's order, and a waiter woken just as its limit ran out has to
//!   come back woken rather than timed out (ADR 222). An Engine that has a
//!   parking lock has a wait queue under it already.
//! - `spawn`/`spawnLocal`: start a fiber the running server owns, dealt
//!   to the next executor or kept on the caller's. An Engine with one
//!   thread has one answer to both (ADR 028, ADR 220).
//! - `blocking`/`sleep` — the general form of that same problem. A handler
//!   that calls anything blocking stops every other request sharing its
//!   thread, and the Engine is the only layer that knows how to wait
//!   without doing that (ADR 013). `blockingReserved` is `blocking` that
//!   never queues behind a job already running, for a caller that holds a
//!   connection while it waits (ADR 064).
//! - `Dir`/`File` — open a directory, open a file inside it by name, ask
//!   what it is, close either, and replace a whole file with bytes
//!   already in hand. Five calls, and deliberately no sixth: no seek, no
//!   file held open for writing, and nothing that walks a directory while a
//!   request is waiting on it. The list is that short because everything
//!   past it is already standard — the reader is a `std.Io.File.Reader` and
//!   the bytes leave through `sendFile`, which is a slot in the
//!   `std.Io.Writer` vtable the Engine fills in anyway — so an Engine that
//!   has a `std.Io` has these already and owes nothing it was not going to
//!   write (ADR 009, ADR 097).
//!
//! The Reader/Writer handed to the handler are plain std types
//! (`*std.Io.Reader`, `*std.Io.Writer`), so the HTTP layer has no idea
//! which Engine is behind them.

const std = @import("std");
const builtin = @import("builtin");

const engine = @import("engine/zio.zig");
const watchdog = @import("watchdog.zig");

/// Re-exported so nothing above has to know that the type came from a layer
/// below rather than from here. It lives in `nilo_core` because a Service
/// holds one and a Service may not import `nilo_http` (ADR 056).
pub const Limits = @import("nilo_core").Limits;

// The check ADR 056 says this file owes. Core declares a fixed slot for the
// Engine's arming state and cannot measure what goes in it, because it may
// not name an Engine; this is the one place that can do both.
comptime {
    if (engine.limit_state_size > Limits.slot_size) @compileError(std.fmt.comptimePrint(
        "nilo: this Engine needs {d} bytes to arm an operation deadline and " ++
            "core.Limits.slot_size is {d}.\n  Raise slot_size in core/limits.zig to at least {d}.",
        .{ engine.limit_state_size, Limits.slot_size, engine.limit_state_size },
    ));
    if (engine.limit_state_align > Limits.slot_align) @compileError(std.fmt.comptimePrint(
        "nilo: this Engine arms an operation deadline at {d}-byte alignment and " ++
            "core.Limits.slot_align is {d}.\n  Raise slot_align in core/limits.zig.",
        .{ engine.limit_state_align, Limits.slot_align },
    ));
}

const engine_limits: Limits.VTable = .{
    .arm = struct {
        fn f(_: ?*anyopaque, state: *anyopaque, ms: u32) void {
            engine.armOperation(state, ms);
        }
    }.f,
    .release = struct {
        fn f(_: ?*anyopaque, state: *anyopaque) void {
            engine.releaseOperation(state);
        }
    }.f,
    .fired = struct {
        fn f(_: ?*anyopaque, state: *anyopaque) bool {
            return engine.firedOperation(state);
        }
    }.f,
    // A service's wait on its own socket parks the fiber like any other
    // wait; the watchdog learns of it here, or charges it to the handler
    // (ADR 210).
    .waiting = struct {
        fn f(_: ?*anyopaque) u64 {
            return watchdog.waitingAnywhere();
        }
    }.f,
    .waited = struct {
        fn f(_: ?*anyopaque, token: u64) void {
            watchdog.waitedAnywhere(token);
        }
    }.f,
};

/// What a Service is handed at startup. There is no `target`: the Engine arms
/// the fiber that is running, and it already knows which one that is.
pub const engine_limits_value: Limits = .{ .vtable = &engine_limits };

pub const debug_io = engine.debug_io;
pub const Peer = engine.Peer;

/// What one look at an open file said: its length and its modification time.
/// See `File.stat`.
pub const Stat = engine.Stat;

/// Everything `listen()` takes.
///
/// Declared here rather than in the Engine, even though most of it is the
/// Engine's to read: this is the struct a user writes by hand, and ADR 001
/// promises the Engine can be swapped without touching user code. An
/// options struct owned by zio would have broken that promise the first
/// time zio was replaced. The Engine reads the fields it knows and never
/// names the rest.
pub const Options = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Options";

    /// What `tls` names: the two PEM files a TLS listener presents. Paths,
    /// read once at `listen()`, relative to the working directory unless
    /// absolute. Change the files and restart; nothing here watches them.
    pub const Tls = struct {
        /// The certificate chain, leaf first, as every issuer hands it out.
        cert: []const u8,
        /// The leaf's private key, unencrypted. ECDSA P-256 is what was
        /// measured; RSA is accepted by the library.
        key: []const u8,
    };

    /// One more address to answer on, named by `also`. The three fields a
    /// second listener can differ in and no others: everything else about
    /// a connection — its buffers, its deadlines, how many the process
    /// holds — is the server's rather than the port's
    /// ([ADR 213](../docs/adr/213-a-server-answers-on-more-than-one-address.md)).
    pub const Listener = struct {
        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = "nilo.Listener";

        /// Read exactly as `Options.address` is, `unix:` spelling included.
        address: []const u8 = "127.0.0.1",
        /// Ignored when `address` names a unix socket.
        port: u16 = 8787,
        /// Serve HTTPS on this one. Independent of every other listener's:
        /// a plain port and a TLS port in one process is what the field
        /// exists for, and each certificate is that listener's alone.
        tls: ?Tls = null,
        /// Speak gRPC on this one rather than HTTP/1.1: HTTP/2 with prior
        /// knowledge (h2c), or with `tls` set as well, HTTP/2 chosen by ALPN
        /// (`h2`, and nothing else offered). Each unary call is answered by
        /// the route `app.post` registered at its path
        /// ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).
        /// Needs `.grpc = true` on the dependency, and is refused at
        /// `listen()` without it.
        grpc: bool = false,
    };

    /// An IPv4 or IPv6 address in the usual notation: `"127.0.0.1"` and
    /// `"::1"` for this machine only, `"0.0.0.0"` and `"::"` for every
    /// interface. A host name is not resolved — this is the address to bind
    /// to, and a name would make which interface it lands on a lookup's
    /// business rather than yours.
    ///
    /// **`"unix:/run/nilo.sock"` listens on a path instead**, which is what
    /// the proxy ADR 027 puts in front should reach the server over: there
    /// is no port to leave open, and the file's permissions are who may
    /// connect ([ADR 103](../docs/adr/103-a-path-is-an-address-to-listen-on.md)).
    /// `port` is not read at all then. A socket left behind by a server that
    /// was killed is taken away on the next start when `reuse_address` is on,
    /// and the path is removed when this server stops.
    ///
    /// A request that arrives that way has no client address — `Ctx.peer()`
    /// is empty — so a server behind a proxy over a socket wants
    /// `.trusted_proxies` set and reads `X-Forwarded-For`, which it is
    /// allowed to do because nothing remote can open a unix socket.
    address: []const u8 = "127.0.0.1",
    /// Ignored when `address` names a unix socket.
    port: u16 = 8787,
    /// On by default so that stopping the server and starting it again
    /// works. Without it, connections left in TIME_WAIT hold the port and
    /// the restart fails with `AddressInUse` — which, during development,
    /// is every single restart. It does not let two servers share a port:
    /// a second listener on the same address is still refused.
    ///
    /// On a unix socket it means the matching thing: a socket file left
    /// behind by a process that is gone is removed before binding. Only a
    /// path that is a socket, and only when connecting to it is refused —
    /// a file, a directory, or a socket something is still listening on is
    /// left alone.
    reuse_address: bool = true,

    /// How many completed handshakes the kernel holds for `accept` before it
    /// starts dropping them. 4,096, up from zio's 128.
    ///
    /// This is a queue *capacity*, not a count of anything held: the kernel
    /// allocates only for connections actually waiting in it, so raising it
    /// costs nothing on a quiet server. What it buys is a burst — every
    /// client reconnecting at once after a deploy, a load balancer's health
    /// checks landing together, a benchmark opening a thousand sockets in
    /// one go. Past the backlog a SYN is dropped rather than refused, the
    /// client's TCP retries it a second later, and nothing in this
    /// process's log says so: what a person sees is a p99 on connection
    /// setup of one second, against an accept loop that was never busy.
    /// At 128, 623 of a thousand connections opened at once took that
    /// second; at 1,024 none did, and a burst of four thousand still lost
    /// some; at 4,096 none did either
    /// ([ADR 198](../docs/adr/198-a-backlog-is-sized-for-the-burst-not-the-load.md)).
    ///
    /// 4,096 is `net.core.somaxconn` on a current Linux, which is also
    /// what Go listens with; the kernel caps this at that sysctl silently,
    /// so on an old kernel whose ceiling is 128 the number here is 128.
    /// `max_connections` is the other half of the arithmetic: this bounds
    /// what waits to be accepted, that bounds what is held once it has been.
    backlog: u31 = 4096,

    /// How many OS threads run fibers. 0 means one per core, or one more
    /// than a container's CPU quota where there is one, which the affinity
    /// mask cannot see; at most 64 either way, and a larger number is held
    /// to 64 (ADR 230).
    ///
    /// zio's own default is a single executor. That is the right default
    /// for a library that might be embedded in someone else's thread, and
    /// the wrong one for a server process, which would otherwise leave
    /// every core but one idle.
    ///
    /// The consequence is that handlers really do run at the same time on
    /// different threads, so a Service that gets written to needs
    /// `nilo.Mutex` (ADR 010). Set this to 1 and that stops being true —
    /// but so does using the machine.
    threads: u8 = 0,

    /// Bytes of the connection's read buffer. It doubles as the ceiling on
    /// the size of a request head: a head that does not fit is answered
    /// with 431.
    ///
    /// Sixteen kilobytes, up from eight, because a head is mostly cookies
    /// and a browser behind a single sign-on carries several kilobytes of
    /// them — an identity token in a cookie is 4–8 KB on its own, and the
    /// 431 it earned under the old default was answered to the one client
    /// least able to do anything about it (ADR 196). It is what Go's
    /// `net/http` and nginx's `large_client_header_buffers` allow too.
    /// What it costs is paid only while a connection is busy: an idle one
    /// gives the pages back (ADR 062), so the 4,669 bytes per idle
    /// connection do not move, and an active one holds two more pages than
    /// it did.
    read_buffer: usize = 16 * 1024,

    /// Serve HTTPS on this listener: TLS 1.3, with the certificate chain
    /// and private key read from these two PEM files when `listen()` is
    /// called ([ADR 212](../docs/adr/212-tls-is-an-option-a-build-asks-for.md)).
    /// Set it and every connection is handshaken before its first request;
    /// the routes, the handlers and the `Ctx` see nothing different.
    ///
    /// **Off is still the recommendation** for a server that has a proxy in
    /// front of it, and ADR 027 says why. This is for the server that has
    /// nothing in front of it: an internal tool on a VM, a service on a
    /// private network that its policy says must be encrypted, a machine
    /// with one port and a certificate and nobody who wants to run a
    /// second process.
    ///
    /// It has to be built in. The library behind it is fetched and linked
    /// only when the dependency is asked for it, `.tls = true` in
    /// `b.dependency("nilo", …)` (`-Dtls` in this repository), and a
    /// build without that refuses this option at `listen()` in one line
    /// rather than serving plain HTTP on a port the caller believed was
    /// encrypted. What that build costs, measured (ADR 212): **560 KB** of
    /// binary, before a single certificate is loaded, and **one page per
    /// idle connection** on every listener of that build, TLS or not,
    /// 9,293 bytes against 5,191. A TLS connection then costs what a plain
    /// one in that build costs plus fourteen bytes at idle (9,307), because
    /// its 33 KB of record buffers are handed back with the rest at every
    /// idle transition. Where it is paid is the handshake: about **300 µs
    /// of CPU for every new connection** on a Ryzen 9700X, twenty times a
    /// plain accept, and half a microsecond a request on a connection kept
    /// alive (3.5–4.0 µs against 3.0–3.5). A server whose clients connect once and
    /// stay does not notice; one whose clients connect per request pays
    /// the handshake per request, and that is the deployment a proxy with
    /// session resumption is for.
    ///
    /// TLS 1.3 only, which every browser and client library of the last
    /// six years speaks and nothing older does. One certificate per
    /// listener: no selection by name, no client certificates, no session
    /// tickets, and no reload without a restart, each of which is a
    /// use case waiting for a caller (`docs/todo.md`).
    ///
    /// The handshake is bounded by `header_timeout_ms` and
    /// `write_timeout_ms`, because until it is done that is what a
    /// connection is: a client that has not yet sent a request head. A
    /// client that connects and goes quiet, or speaks plain HTTP to this
    /// port, is dropped when the first of those runs out.
    tls: ?Tls = null,

    /// Speak gRPC on `address` and `port` rather than HTTP/1.1, the way
    /// `Listener.grpc` does on an entry in `also`: h2c, or HTTP/2 by ALPN when
    /// `tls` is set. For a server that answers nothing but gRPC; one that
    /// serves both gives gRPC an entry in `also` instead
    /// ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).
    grpc: bool = false,

    /// More addresses to answer on, beside the one `address` and `port`
    /// name ([ADR 213](../docs/adr/213-a-server-answers-on-more-than-one-address.md)).
    ///
    /// ```zig
    /// try app.listen(.{
    ///     .port = 8080,
    ///     .also = &.{
    ///         .{ .port = 8081, .tls = .{ .cert = "cert.pem", .key = "key.pem" } },
    ///     },
    /// });
    /// ```
    ///
    /// **One server, one set of routes, one pool of threads.** A request is
    /// answered the same way whichever port it arrived on, and the handler
    /// is not told which: the listener decides how the bytes are carried
    /// and nothing above it. `max_connections` counts sockets across all of
    /// them rather than per port, because what it protects is this
    /// process's descriptor table.
    ///
    /// **What it costs, which is why it is a list rather than the default.**
    /// Each extra listener is one more socket and one more acceptor fiber
    /// per thread, parked in `accept` for the life of the server:
    /// **82 KB on a sixteen-thread server** (330 KB for four extra ones,
    /// measured), which is about 5.3 KB a thread rather than the 4 KB the
    /// stack alone would suggest. Nothing per connection and nothing per request: an idle
    /// connection measured 9,300 bytes with one listener and 9,300 with
    /// two, at ten thousand of them. Both numbers are in ADR 213.
    ///
    /// A TLS listener here still needs the build to have asked for TLS
    /// (`.tls = true` on the dependency), and is refused at `listen()` the
    /// same way `tls` above is. `boundPort()` answers for `port`, the
    /// first listener, because a test that asked the kernel to choose asked
    /// about that one.
    also: []const Listener = &.{},

    /// Bytes of the connection's write buffer. A response that fits in it
    /// leaves as one write; a bigger one is split across several.
    ///
    /// Together with `read_buffer` this is most of what an idle connection
    /// costs, so it is worth turning down for a server holding many
    /// connections open and up for one serving large responses.
    write_buffer: usize = 4 * 1024,

    /// Bytes of a connection's request arena that survive between requests.
    ///
    /// The arena is reset after every request keeping this much, so anything a
    /// request allocates **beyond** this figure is handed back to the operating
    /// system and taken again next time — which is a page fault, and a page the
    /// kernel zeroes, for every 4 KiB of it. On a route answering a megabyte
    /// that is 257 minor faults a request, and lifting this past the response
    /// took the same route from 7,908 req/s to 11,069
    /// ([ADR 075](../docs/adr/075-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)).
    ///
    /// The default is small because the memory is **per connection**, not per
    /// thread: raising it to a megabyte on a server holding ten thousand
    /// connections is ten gigabytes, and every connection that once served a
    /// big response keeps its block for as long as it stays open. Raise it to
    /// just past the largest response a route assembles in the arena, and only
    /// on a server whose connection count you know.
    ///
    /// Leaving it alone is the right answer for a server whose responses fit
    /// in it, which is most of them.
    arena_keep: usize = 16 * 1024,

    // ---- deadlines (ADR 022) ----
    //
    // Zero turns any one of these off. All four off is what nilo did
    // before 0.1.0, and it meant a client could hold a fiber by opening a
    // connection and saying nothing.

    /// How long a client has to finish sending a request head, counted from
    /// its first byte. Not per read — for the whole head, which is what
    /// makes it a limit at all: a client dribbling one byte a second is
    /// inside any per-read limit and never finishes.
    ///
    /// Ten seconds is far more than a real client needs on a real link, and
    /// the cost of being wrong is a 408 to somebody on a bad connection who
    /// will retry.
    header_timeout_ms: u32 = 10_000,
    /// How long a connection may sit between one request and the next
    /// before it is closed.
    ///
    /// This is the number that decides how much memory idle clients hold —
    /// 4,669 bytes each, whatever the buffers are set to, because a connection
    /// that has gone quiet gives them back (ADR 062) — so a server with many
    /// visitors and few of them active wants it lower than a server with a
    /// handful of chatty ones. Above what browsers hold a connection for on
    /// their own (Chrome and Firefox let go at around a minute), so in
    /// practice the client is normally the one that closes.
    idle_timeout_ms: u32 = 75_000,
    /// How long any single read of a request body may take.
    ///
    /// Per read, not for the whole body: how long a legitimate body takes
    /// depends on its size and the client's line, and a server cannot put a
    /// number on either in advance. A client that stops sending halfway
    /// through can be caught without guessing at that.
    body_timeout_ms: u32 = 30_000,
    /// The rate a buffered body has to arrive at, in **bytes a second**, once
    /// `body_grace_ms` has gone by. 0 turns it off and leaves
    /// `body_timeout_ms` on its own.
    ///
    /// This is what `body_timeout_ms` cannot do. A per-read limit is satisfied
    /// by any client that sends *something* often enough, so one byte every
    /// twenty-nine seconds holds a fiber and a step of the arena for as long
    /// as it likes ([ADR 022](../docs/adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)).
    /// A rate turns the announced length into a deadline —
    /// `body_grace_ms + bytes / body_min_rate` — so how long a body may take
    /// is a function of how big it said it was.
    ///
    /// **This is an admission policy, and 8 KiB/s is the slowest upload the
    /// server will sit through.** At the default `max_body` the whole of a
    /// one-megabyte body has 138 seconds. A client below the rate is a 408,
    /// so a server whose clients are on a bad link should lower it rather
    /// than raise the timeout.
    body_min_rate: u32 = 8 * 1024,
    /// The head start before the rate is asked for, covering the pause
    /// between a head arriving and the body behind it — including the one an
    /// `Expect: 100-continue` client takes to hear back.
    body_grace_ms: u32 = 10_000,
    /// How long any single write to the client may take.
    ///
    /// The answer to a client that asks for something and then stops
    /// reading: the socket's buffers fill, the next write blocks, and
    /// without this it blocks for as long as TCP takes to give up. It is
    /// also what bounds a server-sent event stream whose reader has walked
    /// away — the write fails, the handler gets an error, the fiber
    /// unwinds.
    ///
    /// Armed again for every request, and cut to a route's deadline when
    /// that is nearer than this (`Deadlines.armWrite`, ADR 105).
    write_timeout_ms: u32 = 30_000,

    /// How long any request has, in total, from its head arriving to its
    /// answer leaving — counted the way `nilo.deadline(ms)` counts for one
    /// route, given here to every route at once. 0, the default, means no
    /// such limit ([ADR 105](../docs/adr/105-a-route-can-say-how-long-it-has.md)).
    ///
    /// **What it bounds is every wait nilo owns** — reading the body, writing
    /// the response — each cut down to whichever of this and its own limit
    /// comes first, and `c.overdue()` answers a handler doing its own work.
    /// What it does not do is interrupt a handler that is running rather
    /// than waiting; there is no cancellation here, and deliberately none
    /// ([ADR 082](../docs/adr/082-a-cleanup-path-is-not-cancellable.md)).
    ///
    /// **A request that takes the connection over lets go of it** — a
    /// stream, a WebSocket, a body read in pieces — because those are meant
    /// to outlive an ordinary request, and a number chosen for the ordinary
    /// ones would cut every event stream off at the same second. A route
    /// that wants a deadline through a takeover says so with
    /// `nilo.deadline(ms)`, which is kept.
    ///
    /// Off by default rather than thirty seconds, which is what every other
    /// server ships: the four deadlines above already answer a client that
    /// stalls, and a total is a policy about the handlers behind it that
    /// only their author can set. Thirty seconds is a reasonable one for an
    /// API; an hour is for a report.
    request_deadline_ms: u32 = 0,

    /// The most connections this process holds at once. 0 means no limit.
    ///
    /// A connection costs a measured 4,669 bytes before it has asked for
    /// anything, so this number times five kilobytes is what the server
    /// may hold: the default is about 47 MB. That is the whole point of
    /// having it. Without a cap a server does not fail at a number
    /// somebody chose, it fails when the machine runs out, and what
    /// notices is the OOM killer — which takes the process down along with
    /// every request that was being answered correctly.
    ///
    /// Past it, a connection is accepted and closed at once: no request is
    /// read and no status is sent. A client finds out immediately, which
    /// is what lets a load balancer try another instance, and the log says
    /// so once a minute for as long as it lasts. Ten thousand is above
    /// what an ordinary service sees and below what a small machine
    /// minds; a server holding WebSockets open wants it raised, and the
    /// arithmetic above is how to decide by how much.
    ///
    /// It bounds connections, not requests. One connection makes many
    /// requests in a row, and a WebSocket is one connection for as long as
    /// the tab is open.
    max_connections: u32 = 10_000,

    /// The most requests this process answers at once. 0, the default,
    /// means no limit.
    ///
    /// Past it, a request whose head has arrived is answered `503` with
    /// `Retry-After: 1` at once, and the connection is closed, so the
    /// balancer in front can send the retry somewhere with room. Nothing
    /// waits: a request over the limit costs one write of a constant and
    /// is gone ([ADR 159](../docs/adr/159-a-server-past-its-limit-says-so-at-once.md)).
    ///
    /// Requests, not connections — `max_connections` is the other one. Ten
    /// thousand idle keep-alive connections hold no work; a hundred requests
    /// inside a slow handler are the load. `nilo_requests_in_flight` on the
    /// metrics page is what the number should be set from, and there is no
    /// default because 256 is right for a 40 ms handler and wrong for a 4 s
    /// one.
    max_in_flight: u32 = 0,

    /// Stop on Ctrl-C (SIGINT) and on SIGTERM, which is what a container
    /// runtime or a supervisor sends when it wants the process to go.
    ///
    /// On by default because the alternative is worse in both directions:
    /// during development, a server that ignores Ctrl-C has to be hunted
    /// down with `kill`; in production, a deploy that sends SIGTERM would
    /// otherwise kill requests mid-response. Turn it off if the surrounding
    /// program installs handlers of its own — then call `App.shutdown()`
    /// from them.
    stop_on_signal: bool = true,

    /// How long a stop waits for requests already in flight before giving
    /// up on them. 0 means don't wait.
    ///
    /// Long enough for an ordinary request to finish, short enough that a
    /// deploy is not held up by one slow handler. What is waited on is
    /// requests being answered, not connections held open: a browser tab
    /// parked on a keep-alive connection is holding no work, so Ctrl-C does
    /// not spend a single millisecond of this on it.
    shutdown_grace_ms: u32 = 10_000,

    // ---- what a request may do ----

    /// The most `Ctx.body()` will read into the request arena. Past it, a
    /// 413 that names `bodyStream()` as the way to take more.
    ///
    /// A megabyte is a JSON body's worth. It is deliberately not a file
    /// upload's worth: this body is held whole, in memory, per request, so
    /// raising it raises what a handful of concurrent clients can make the
    /// server hold. `bodyStream()` has no such ceiling because it holds
    /// nothing — it is bounded by the buffer the handler passes in.
    max_body: usize = 1024 * 1024,

    /// How many proxies stand in front of this server, for reading a
    /// client's address out of `X-Forwarded-For`.
    ///
    /// Zero — the default — means trust nothing: `Ctx.clientIp()` is the
    /// address the connection actually came from, and a header claiming
    /// otherwise is ignored. That is the only safe default, because
    /// `X-Forwarded-For` is a header like any other and anyone can send
    /// one.
    ///
    /// A count rather than a list of addresses, and counted from the right,
    /// which is what makes it hard to get wrong. Each proxy appends the
    /// address it heard from, so the rightmost entry was written by the
    /// proxy nearest this server and the leftmost is whatever the original
    /// client claimed. With one proxy in front, a client sending
    /// `X-Forwarded-For: 1.2.3.4` arrives as `1.2.3.4, 203.0.113.9` — and
    /// counting one from the right reads `203.0.113.9`, the address the
    /// proxy saw, while the forgery sits to the left and is never looked
    /// at. Set this to the number of proxies you run, not to the number of
    /// entries you have seen in the header.
    ///
    /// Fewer entries than hops means the chain is not what this says it is,
    /// so the socket's own address is used rather than a guess.
    ///
    /// **`.trusted_proxies` below is the better answer** where you can name
    /// your network, and it wins when both are set.
    trusted_hops: u8 = 0,

    /// Which addresses in front of this server are allowed to say who the
    /// client is
    /// ([ADR 102](../docs/adr/102-a-proxy-is-trusted-by-which-one-it-is.md)).
    ///
    /// ```zig
    /// try app.listen(.{ .trusted_proxies = &.{"private"} });
    /// ```
    ///
    /// Each entry is a CIDR (`10.0.0.0/8`, `fd00::/8`), a bare address meaning
    /// only that host, or one of two names: `"private"` for the RFC 1918
    /// ranges plus carrier-grade NAT, link-local, unique-local v6 and the
    /// loopback, and `"loopback"` for the loopback alone. A v4 rule matches a
    /// client that arrived v4-mapped, so a server bound to `::` needs the rule
    /// written once.
    ///
    /// **This describes the network instead of counting it**, which is what
    /// makes it hard to get wrong in a way nothing notices. `trusted_hops` is
    /// a number that has to match how many proxies are in front today; grow a
    /// hop and it keeps answering, with the wrong address and no complaint.
    /// Here the header is read only when the connection came from an address
    /// you named, entries written by addresses you named are skipped, and the
    /// first one left is the client — whatever the chain's length turned out
    /// to be.
    ///
    /// Empty is the default and means the same as it always did: trust
    /// nothing, and `Ctx.clientIp()` is the address the connection came from.
    /// An entry that is not an address stops the server at `listen()` with a
    /// sentence naming it.
    ///
    /// The text is borrowed and has to outlive the App, which a literal does.
    trusted_proxies: []const []const u8 = &.{},

    /// How many password hashes may be in flight at once (ADR 044).
    ///
    /// Eight, and the number is measured rather than picked. Argon2id at the
    /// default Cost is bound by memory bandwidth, not by cores: on a 16-core
    /// machine the throughput ceiling is ~280 hash/s and it is reached at 8
    /// concurrent, not at 32. Going to 32 buys nothing — 263 hash/s, slightly
    /// *worse* — and costs 608 MiB of transient allocation instead of 152 MiB
    /// and 110 ms per hash instead of 31 ms.
    ///
    /// Left ungated, the ceiling would be the Engine's blocking pool, which
    /// is twice the core count and sized for calls that wait on a disk rather
    /// than calls that eat a core and 19 MiB. That matters beyond the hashing
    /// itself: `Ctx.entropy` goes to the same pool, so a flood of sign-ins
    /// with no Gate in front of them would queue every session cookie in the
    /// server behind it.
    ///
    /// This bounds concurrency, not queueing. Past it, requests wait their
    /// turn — a sign-in gets slower, and `header_timeout_ms` is what
    /// eventually answers a client that will not wait.
    password_hashes_at_once: u16 = 8,

    /// How long a handler may run without yielding before nilo says so in
    /// the log. 0 turns it off (ADR 013).
    ///
    /// Many requests share one OS thread, so a handler that waits on the
    /// operating system directly stops all of them. `nilo.blocking` is the
    /// way not to, and nothing in the type system can make anybody use it —
    /// the wrong version compiles and passes its tests. This is what
    /// notices instead, and it notices on the first request rather than
    /// under load, which is the point: the bug is invisible in development
    /// precisely because there is nobody else to be slow for.
    ///
    /// What is measured is the longest stretch the fiber ran without
    /// parking, not time the request took: a wait on `nilo.blocking`,
    /// `nilo.sleep`, a `nilo.Mutex`, the request body or the response write
    /// ends a stretch, because in every one of those the thread is off
    /// serving somebody else. So a request that takes the connection over is
    /// watched on the same terms: a stream by its writes, a body reader by
    /// its reads, a WebSocket by one message at a time.
    ///
    /// A wait through the server's `Io` (a `std.Io.Event` or `Queue`) is a
    /// park however long it is: what counts is the run since the loop's last
    /// turn after the stretch began (ADR 013).
    ///
    /// A quarter of a second is far longer than any handler that is not
    /// waiting, and long enough that ordinary CPU work does not trip it.
    /// Deliberately on outside `Debug` too: the cost is two clock readings
    /// per request, and a detector that only runs where the bug cannot
    /// happen would never have fired.
    block_warning_ms: u32 = 250,

    /// The secret `Session(T)` cookies are sealed with — exactly
    /// `nilo.session.key_len` (32) bytes. Null means this application has no
    /// sessions, and a handler that asks for one anyway fails with a sentence
    /// naming this option.
    ///
    /// **Where it comes from is yours**, the same line nilo draws around
    /// authentication: an environment variable, a mounted file, a secrets
    /// manager. What nilo will not do is have a default, because a default
    /// key is a key everybody who has read this repository already has.
    ///
    /// It has to be the *same on every instance* behind a load balancer, or a
    /// request will land on the machine that cannot read its own cookies —
    /// which looks like users being randomly signed out. It also has to
    /// survive a restart for the same reason.
    ///
    /// Checked at `listen()`: the wrong length stops the server with a
    /// message, rather than every request failing once the traffic arrives.
    session_secret: ?[]const u8 = null,

    /// Secrets a session cookie is still opened under when `session_secret`
    /// does not open it. Nothing is ever sealed under one (ADR 225).
    ///
    /// **This is how the secret changes without signing everybody out.** Put
    /// the new secret in `session_secret` and the old one here, and every
    /// cookie out there keeps working until it expires. The expiry inside the
    /// seal is what bounds the wait: once the longest `max_age` you seal with
    /// has passed since the switch, no cookie sealed under the old secret can
    /// open anyway, and it can be dropped from here.
    ///
    /// **On several instances, change it in two deploys.** While a deploy
    /// rolls out, some instances seal under the new secret and the rest do
    /// not know it yet. So the first deploy adds the new secret here and
    /// changes nothing else, and the second swaps the two.
    ///
    /// **Not for a secret that leaked.** A fallback still opens every cookie
    /// sealed under it, including the ones somebody forged with it. Drop a
    /// leaked secret outright, and everybody signs in again.
    ///
    /// At most `nilo.session.max_fallbacks` (3), each 32 bytes, none the same
    /// as `session_secret` or another. Each is one more decryption for a
    /// cookie the current secret does not open, and nothing for one it does.
    session_fallback_secrets: []const []const u8 = &.{},

    /// Read a session cookie named `session` as well as `__Host-session`.
    ///
    /// **Off, because a sibling subdomain can plant a `session` cookie** with
    /// `Domain=example.com`, and a visitor who carries no `__Host-session`
    /// of this host's (signed out, or never signed in) would open the
    /// planted one and work inside the attacker's account. `__Host-session`
    /// is the one a browser keeps only from this host, and it is what a
    /// session is written as by default (ADR 033).
    ///
    /// **On for two kinds of program.** One whose session sets a `domain`,
    /// a `path` other than `/` or `secure = false`, which a browser refuses
    /// under the prefix, so it can only be written as `session`; a `set`
    /// that would write one with this off fails with a message naming it.
    /// And one upgrading from 0.6.0, which wrote every session as `session`:
    /// on for as long as the longest `max_age` it sealed with, every `set`
    /// moves its visitor to the prefixed name, and then off.
    session_plain_name: bool = false,
};

/// How many OS threads `options` means: `threads` when it was set, and at
/// 0 one per core or a CPU quota plus one (ADR 230). The Engine's own reading of its own field,
/// so that anything the App sizes to the thread count (the compressors
/// `app.compress` keeps, one per thread, ADR 211) is sized to the number
/// the Engine starts.
pub const threadCount = engine.threadCount;

/// Listen, and run `handler(state, in, out, deadlines)` for every
/// connection. The one call here that is a wrapper rather than a re-export,
/// and only for this: the Engine hands over something it can put a time
/// limit on, and this is where that becomes a `Deadlines` carrying nilo's
/// policy. Neither side has to know about the other's half of it.
pub fn serve(
    gpa: std.mem.Allocator,
    options: Options,
    stop: *Stop,
    state: anytype,
    comptime ready: anytype,
    comptime stopping: anytype,
    comptime handler: anytype,
    comptime grpc_handler: anytype,
) !void {
    const State = @TypeOf(state);

    // The limits travel to each connection through the Engine's `state`,
    // which is carried as-is, so `serve` needs no new parameter and the
    // Engine needs no idea what is in here.
    const Carried = struct { state: State, limits: Deadlines };

    const Bridge = struct {
        fn run(
            carried: Carried,
            in: *std.Io.Reader,
            out: *std.Io.Writer,
            clocks: *engine.Clocks,
            wake: *engine.Wake,
            peer: Peer,
        ) void {
            var deadlines = carried.limits;
            deadlines.target = clocks;
            const waker: Waker = .{ .vtable = &engine_waker, .target = wake };
            handler(carried.state, in, out, deadlines, waker, peer);
        }

        /// The same for a listener that speaks gRPC (ADR 220). Its own
        /// function rather than a flag on `run`, for the reason the Engine
        /// keeps `runTls` apart: nothing is added to the plain path.
        fn runGrpc(
            carried: Carried,
            in: *std.Io.Reader,
            out: *std.Io.Writer,
            clocks: *engine.Clocks,
            wake: *engine.Wake,
            peer: Peer,
        ) void {
            var deadlines = carried.limits;
            deadlines.target = clocks;
            const waker: Waker = .{ .vtable = &engine_waker, .target = wake };
            grpc_handler(carried.state, in, out, deadlines, waker, peer);
        }

        /// The startup hook, unwrapped from what the Engine carries. The
        /// deadlines travelling beside `state` are a connection's business
        /// and there is no connection yet, so only the state goes through —
        /// along with the one clock that is not a connection's, which is what
        /// a Service bounds an outbound call with (ADR 056).
        fn start(carried: Carried, io: std.Io, port: ?u16) anyerror!void {
            return ready(carried.state, io, engine_limits_value, port);
        }

        /// The shutdown hook, unwrapped the same way. No `io` and no error:
        /// a service is stopped on the loop it was started on, and there is
        /// nobody left to hand a failure to (ADR 121).
        fn winddown(carried: Carried) void {
            return stopping(carried.state);
        }
    };

    return engine.serve(gpa, options, stop, Carried{
        .state = state,
        .limits = .{
            .vtable = &engine_deadlines,
            .header_ms = options.header_timeout_ms,
            .idle_ms = options.idle_timeout_ms,
            .body_ms = options.body_timeout_ms,
            .body_min_rate = options.body_min_rate,
            .body_grace_ms = options.body_grace_ms,
            .write_ms = options.write_timeout_ms,
        },
    }, Bridge.start, Bridge.winddown, Bridge.run, Bridge.runGrpc);
}

const engine_waker: Waker.VTable = .{
    .wait = struct {
        fn f(target: ?*anyopaque, limit_ms: u32) Woken {
            const wake: *engine.Wake = @ptrCast(@alignCast(target.?));
            return switch (wake.wait(limit_ms)) {
                .readable => .readable,
                .posted => .posted,
                .timed_out => .timed_out,
                .closed => .closed,
            };
        }
    }.f,
    .post = struct {
        fn f(target: ?*anyopaque) void {
            const wake: *engine.Wake = @ptrCast(@alignCast(target.?));
            wake.post();
        }
    }.f,
    .release_stack = struct {
        fn f(target: ?*anyopaque) void {
            // A TLS connection has a record layer under the buffers the
            // caller just released, 33 KB of it, and it goes back too, on
            // the same two checks: nothing buffered in either direction.
            // The third check, cleartext decrypted and not yet read, is the
            // Engine's, because only it knows where that lives (ADR 212).
            // A plain connection has no such layer and this is one branch.
            if (target) |t| {
                const wake: *engine.Wake = @ptrCast(@alignCast(t));
                if (wake.rawIdle()) |raw| releaseIdlePages(raw.in, raw.out);
            }
            // The stack is *this* fiber's, and the Engine asks the coroutine
            // it is running on rather than being told which connection is
            // asking.
            engine.releaseIdleStack();
        }
    }.f,
    .half_close = struct {
        fn f(target: ?*anyopaque) void {
            const wake: *engine.Wake = @ptrCast(@alignCast(target.?));
            wake.halfClose();
        }
    }.f,
};

const engine_deadlines: Deadlines.VTable = .{
    .limit = struct {
        fn f(target: ?*anyopaque, side: Side, l: Limit) void {
            const clocks: *engine.Clocks = @ptrCast(@alignCast(target.?));
            switch (side) {
                .read => switch (l) {
                    .none => clocks.readNoLimit(),
                    .within_ms => |ms| clocks.readWithinMs(ms),
                    .by_ns => |ns| clocks.readByNanos(ns),
                },
                .write => switch (l) {
                    .none => clocks.writeNoLimit(),
                    .within_ms => |ms| clocks.writeWithinMs(ms),
                    .by_ns => |ns| clocks.writeByNanos(ns),
                },
            }
        }
    }.f,
    .timedOut = struct {
        fn f(target: ?*anyopaque) bool {
            const clocks: *const engine.Clocks = @ptrCast(@alignCast(target.?));
            return clocks.timedOut();
        }
    }.f,
};

/// The "please stop" flag `serve` watches, and `explained` for saying which
/// startup failures have already been put into words.
pub const Stop = engine.Stop;
pub const explained = engine.explained;

pub const Binding = engine.Binding;
pub const binding_unset = engine.binding_unset;
pub const bindSlot = engine.bindSlot;
pub const unbindSlot = engine.unbindSlot;
pub const bindsOn = engine.bindsOn;
pub const monotonicNanos = engine.monotonicNanos;

/// The `std.Io` a handler's work runs on (ADR 244).
///
/// **The running server's loop** when there is one, so a `std.Io.Queue` or
/// `std.Io.Event` a handler waits on parks the fiber and is woken by a fiber
/// started with `app.spawn`, which holds the same loop. Anywhere else (a
/// `testing.Client` driving an App, a handler called as a function) a
/// process-wide `std.Io.Threaded`, started the first time it is asked for and
/// left running: it has real threads, so a writer fiber started on it with
/// `io.concurrent` makes progress while the test waits on it, and it is one
/// `Io` for every caller, which a queue shared between two of them needs.
///
/// A read of one atomic when the server is up, and nothing at all is held per
/// connection or per request (ADR 017).
pub fn loopIo() std.Io {
    if (engine.serverIo()) |served| return served;
    return fallbackIo();
}

/// 0 not started, 1 starting, 2 started.
var fallback_state: std.atomic.Value(u8) = .init(0);
var fallback_threaded: std.Io.Threaded = undefined;

fn fallbackIo() std.Io {
    while (fallback_state.load(.acquire) != 2) {
        if (fallback_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            fallback_threaded = .init(std.heap.page_allocator, .{});
            fallback_state.store(2, .release);
            break;
        }
        std.Thread.yield() catch {};
    }
    return fallback_threaded.io();
}

/// Bytes from the operating system's entropy source, off the event loop.
/// What a session nonce is made of.
///
/// Wrapped rather than re-exported for the reason `Mutex` and `sleep` below
/// are: this parks the fiber on the Engine's blocking pool, so the thread is
/// off serving somebody else and the detector has to be told (ADR 013).
/// Without this, sealing a session cookie would be charged to the handler as
/// time it spent holding its thread.
pub fn randomSecure(buffer: []u8) !void {
    const w = watchdog.waitingAnywhere();
    defer watchdog.waitedAnywhere(w);
    return engine.randomSecure(buffer);
}

/// A monotonic clock reading that is cheap rather than exact.
///
/// `monotonicNanos` costs a measured 27ns, because `CLOCK_MONOTONIC` does
/// the full timekeeping arithmetic on every read. The blocking detector
/// (ADR 013) reads a clock four times per request and compares the answer
/// against a quarter of a second, so it wants the opposite trade — and gets
/// it: 5ns, from a reading that only moves once a millisecond.
///
/// Where there is no such clock this is `monotonicNanos` and the detector
/// simply costs what it costs. Nothing's correctness depends on which one
/// is underneath, only the price of asking.
pub fn coarseNanos() u64 {
    if (builtin.os.tag == .linux) {
        // Through `std.posix.system`, which is `std.os.linux` in a build
        // that does not link libc and libc's own wrapper in one that does.
        //
        // That distinction used to be the point of this comment: it
        // recorded 5ns one way and 600ns the other, on the grounds that
        // only the libc path reached the vDSO. **Re-measured on Zig 0.16
        // and it is no longer true** — `std.os.linux` reaches the vDSO
        // too, and `CLOCK_MONOTONIC_COARSE` is 1–2ns either way (ADR 041).
        // What survives is the reason the *coarse* clock is here at all:
        // it is 2ns against 15ns for `CLOCK_MONOTONIC` read the same way,
        // which is the sort of gap that turns a cheap check into the most
        // expensive thing a request does. (15ns is the raw clock; the 27ns
        // above is `monotonicNanos`, which is the Engine's call and carries
        // its own frame.)
        var ts: std.posix.system.timespec = undefined;
        const rc = std.posix.system.clock_gettime(.MONOTONIC_COARSE, &ts);
        if (std.posix.errno(rc) == .SUCCESS) {
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        }
    }
    return monotonicNanos();
}

/// A lock that parks the fiber rather than the OS thread.
///
/// A wrapper rather than a re-export for one reason: waiting on a lock is
/// not the handler holding its thread, and the detector has to be told so
/// or a busy lock would be reported as a blocking handler (ADR 013). The
/// three methods are the Engine's, in the order it defines them.
pub const Mutex = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Mutex";

    _inner: engine.Mutex = .init,

    pub const init: Mutex = .{};

    pub fn lock(self: *Mutex) !void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return self._inner.lock();
    }

    /// `lock`, for a caller that has nothing useful to do with a refusal.
    ///
    /// **A cleanup path should not be cancellable.** `lock` fails with
    /// `Canceled` when the fiber is being shut down, and the two answers to
    /// that — give up, or carry on unlocked — are a resource never released
    /// and a data race. `Room.leave` had the first: it returned before
    /// clearing its seat, leaving the room a `waker` pointing into a `Socket`
    /// whose fiber had ended.
    ///
    /// Only for a section that is short and cannot itself wait, because
    /// nothing can interrupt it. The cancellation is not lost — the Engine
    /// still holds the request, and the next call that can fail will.
    pub fn lockUncancelable(self: *Mutex) void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return self._inner.lockUncancelable();
    }

    /// Take the lock if it is free, without waiting. Never parks, so there
    /// is nothing to forgive.
    pub fn tryLock(self: *Mutex) bool {
        return self._inner.tryLock();
    }

    pub fn unlock(self: *Mutex) void {
        self._inner.unlock();
    }
};

/// A lock that lets a fixed number through at once, and parks the rest.
///
/// A wrapper rather than a re-export for the reason `Mutex` is: waiting for a
/// turn is not the handler holding its thread, and the detector has to be
/// told or a busy Gate reads as a blocking handler (ADR 013).
///
/// **What it is for is a call that is expensive rather than slow.**
/// `nilo.blocking` already keeps a slow call off the loop, and the Engine's
/// pool already caps how many run at once — at twice the core count, which is
/// the right ceiling for a call that is waiting on a disk and the wrong one
/// for a call that is eating 19 MiB and a core. Password hashing is the
/// caller this exists for and the numbers are in ADR 044.
///
/// **Turns go in the order the waiters arrived** (ADR 222). A turn given
/// back while someone is parked is handed to the oldest of them, never put
/// back where a caller arriving that instant could take it first; a caller
/// takes a free turn only when nobody is waiting for one. Without that, a
/// Gate under steady load is not a queue: whoever finishes calls `enter`
/// again within microseconds, ahead of every fiber still waking up, and the
/// ones that waited longest wait longest still.
pub const Gate = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Gate";

    _lock: engine.Mutex = .init,
    /// Turns nobody holds. Above zero only while nobody is waiting: a turn
    /// given back while someone waits goes to them, never here.
    _free: usize,
    /// The waiters, oldest first. Each node lives on its waiter's stack.
    _head: ?*Waiter = null,
    _tail: ?*Waiter = null,
    _waiting: usize = 0,

    /// One parked caller. `leave` sets `granted` under the Gate's lock and
    /// wakes this node's own condition, so the turn is the named waiter's
    /// from that instant — no one arriving later can see it as free, and a
    /// wake that races a timeout or a cancellation is decided by `granted`,
    /// not by which of them the condition happened to report.
    const Waiter = struct {
        next: ?*Waiter = null,
        granted: bool = false,
        wake: engine.Condition = .init,
    };

    /// A Gate that lets `at_once` through. Zero would be a Gate nothing gets
    /// through, so it is read as one.
    pub fn open(at_once: usize) Gate {
        return .{ ._free = @max(1, at_once) };
    }

    /// Wait for a turn. `error.Canceled` if the request went away first,
    /// which is the same answer `Mutex.lock` gives.
    pub fn enter(self: *Gate) error{Canceled}!void {
        return self.wait(null) catch |err| switch (err) {
            error.Canceled => error.Canceled,
            error.TimedOut => unreachable, // no limit, nothing to run out
        };
    }

    /// Wait for a turn for at most `ms`. `error.TimedOut` if none came, and
    /// then the caller holds nothing and owes no `leave`: its place in the
    /// line is gone, and the line behind it moves up. Zero asks only whether
    /// a turn is free now.
    ///
    /// For a caller with something better to do than wait longer — an older
    /// answer to serve, a refusal that names the limit — which is how a
    /// bounded queue in front of a scarce resource is built without a poll.
    pub fn enterWithin(self: *Gate, ms: u64) error{ Canceled, TimedOut }!void {
        return self.wait(ms);
    }

    /// Give the turn back: to the oldest waiter, or to the Gate if there is
    /// none. Never waits, so there is nothing to forgive.
    pub fn leave(self: *Gate) void {
        self._lock.lockUncancelable();
        defer self._lock.unlock();
        self.handOn();
    }

    /// A turn nobody holds goes to the head of the line, or back to the
    /// Gate when the line is empty. The lock is held.
    fn handOn(self: *Gate) void {
        const w = self._head orelse {
            self._free += 1;
            return;
        };
        self._head = w.next;
        if (self._head == null) self._tail = null;
        self._waiting -= 1;
        w.granted = true;
        w.wake.signal();
    }

    /// Take `w` out of the line. The lock is held, and `w` is in it.
    fn unlink(self: *Gate, w: *Waiter) void {
        var prev: ?*Waiter = null;
        var at = self._head;
        while (at) |node| : ({
            prev = node;
            at = node.next;
        }) {
            if (node != w) continue;
            if (prev) |p| p.next = node.next else self._head = node.next;
            if (self._tail == node) self._tail = prev;
            self._waiting -= 1;
            return;
        }
    }

    fn wait(self: *Gate, limit_ms: ?u64) error{ Canceled, TimedOut }!void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        try self._lock.lock();
        defer self._lock.unlock();
        if (self._head == null and self._free > 0) {
            self._free -= 1;
            return;
        }
        if (limit_ms) |ms| if (ms == 0) return error.TimedOut;

        var me: Waiter = .{};
        if (self._tail) |t| t.next = &me else self._head = &me;
        self._tail = &me;
        self._waiting += 1;

        const started = engine.monotonicNanos();
        while (!me.granted) {
            const parked = if (limit_ms) |ms| blk: {
                const spent_ms = (engine.monotonicNanos() -| started) / std.time.ns_per_ms;
                if (spent_ms >= ms) break :blk error.TimedOut;
                break :blk engine.waitWithin(&me.wake, &self._lock, ms - spent_ms);
            } else me.wake.wait(&self._lock);
            parked catch |err| {
                if (!me.granted) {
                    self.unlink(&me);
                    return err;
                }
                // `leave` named this waiter as the wait was ending. A limit
                // that ran out as the turn arrived takes the turn: it came.
                // A cancellation hands it to whoever is next, or the Gate.
                if (err == error.TimedOut) return;
                self.handOn();
                return err;
            };
        }
    }
};

/// Wait, without stopping the thread. Wrapped for the same reason `Mutex`
/// is: a sleeping fiber is not a held thread.
pub fn sleep(ms: u64) error{Canceled}!void {
    const w = watchdog.waitingAnywhere();
    defer watchdog.waitedAnywhere(w);
    return engine.sleep(ms);
}

/// Somewhere to put work that is not a request, owned by the server that
/// is running rather than by the fiber that started it (ADR 028).
pub const spawn = engine.spawn;

/// `spawn`, kept on the calling fiber's thread: for work that answers the
/// fiber that started it, a gRPC call answering its connection (ADR 220).
pub const spawnLocal = engine.spawnLocal;

// ---- files (ADR 009) ----
//
// A file too big to hold is opened rather than read, and this is the whole
// of what that costs the Bulkhead. Both types are wrappers rather than
// re-exports for the reason `Mutex` and `randomSecure` are: every call
// below parks the fiber on the Engine, so the thread is off serving
// somebody else and the blocking detector has to be told, or opening a file
// would be reported as a handler holding its thread (ADR 013). Wrapped
// here rather than at each call site so that nobody has to remember.

/// A directory, opened once and held open.
///
/// The long way round to a file's bytes, on purpose. A name is opened
/// relative to a descriptor that was chosen before the socket was, so
/// nothing carried by a request is ever resolved as a path — which is the
/// property ADR 009 bought by refusing disk IO outright, kept here by the
/// shape of the type rather than by a normalisation step somebody has to
/// get right.
pub const Dir = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Dir";

    _inner: engine.Dir,

    /// Open `path`, relative to the working directory the server runs in.
    ///
    /// Held for as long as whatever opened it — the static tree for the life
    /// of the App, a Service for the life of the process — so this is
    /// startup work, and the request path only ever calls `openFile`.
    pub fn open(path: []const u8) !Dir {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return .{ ._inner = try engine.Dir.open(path) };
    }

    pub fn close(self: Dir) void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        self._inner.close();
    }

    /// Open `name` inside this directory.
    ///
    /// `name` is a name, not a path to work out: it is resolved by the
    /// kernel against this directory's descriptor. A symlink inside the
    /// directory is followed, because refusing them breaks ordinary
    /// deployments and no static server on the internet refuses them by
    /// default (ADR 009).
    ///
    /// `error.FileNotFound` is the one failure with an answer better than a
    /// 500 — from the client's side, a file the list promised and the disk
    /// no longer has is indistinguishable from one that never existed.
    pub fn openFile(self: Dir, name: []const u8) !File {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return .{ ._inner = try self._inner.openFile(name) };
    }

    /// `openFile` for a name that must be a file and nothing standing in for
    /// one: a symlink in the last component fails with `error.SymLinkLoop`
    /// instead of being followed.
    ///
    /// The static tree opens its spilled files through this (ADR 009). The
    /// name was a regular file when the directory was walked, and a request
    /// may be answered long after: a file replaced by a link to somewhere
    /// else would be served out of the tree without it. Refusing at the open
    /// is race-free where a look beforehand is not. `openFile` keeps following
    /// links, which is what a `FileBody` an application chose wants.
    pub fn openFileNoFollow(self: Dir, name: []const u8) !File {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return .{ ._inner = try self._inner.openFileNoFollow(name) };
    }

    /// Write `bytes` to `name` inside this directory, replacing what was
    /// there. Either the whole file lands or none of it does: a reader of
    /// `name` never sees it half-written
    /// ([ADR 097](../docs/adr/097-a-file-is-written-by-the-engine.md)).
    ///
    /// **The name is not checked here.** `filebody.checkName` is what refuses
    /// a `..`, an absolute path, a NUL and a Windows drive letter, and the
    /// caller has to have asked it — `Upload.saveTo` does. This is the same
    /// division `openFile` already has: the Bulkhead says what the Engine can
    /// do, and what a name is allowed to be is a layer up.
    ///
    /// One call rather than an open, a writer and a close: a `File` open for
    /// writing is a second lifetime for every engine to get right. The fiber
    /// parks for it rather than the thread blocking, which is why this is here
    /// and not behind `nilo.blocking`.
    pub fn writeFileAtomic(self: Dir, name: []const u8, bytes: []const u8) !void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return self._inner.writeFileAtomic(name, bytes);
    }
};

/// One open file, on its way to a client.
pub const File = struct {
    _inner: engine.File,

    /// What the file is, asked of the operating system rather than
    /// remembered: how many bytes, and when it last changed.
    ///
    /// Both numbers together rather than a `size` on its own, and that is the
    /// whole of ADR 098. A file response writes a length and an ETag, and
    /// nilo's ETag for a file nobody read is made of exactly these two
    /// numbers — so asking twice, or asking for one and remembering the
    /// other, is how a response comes to promise a length from one file and a
    /// tag from another. One look at one descriptor cannot disagree with
    /// itself.
    pub fn stat(self: File) !Stat {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        return self._inner.stat();
    }

    pub fn close(self: File) void {
        const w = watchdog.waitingAnywhere();
        defer watchdog.waitedAnywhere(w);
        self._inner.close();
    }

    /// A reader over this file, using `buffer` for whatever it has to hold.
    ///
    /// The type that comes back is the standard library's own, and that is
    /// the point rather than an implementation detail: `sendFileAll` takes
    /// exactly this, so the bytes reach the socket through a vtable slot the
    /// Engine already fills in, and the HTTP layer sends a file without ever
    /// naming the Engine (ADR 009). Nothing here does any IO — it is a
    /// struct being built — so there is no wait to forgive.
    pub fn reader(self: File, buffer: []u8) std.Io.File.Reader {
        return self._inner.reader(buffer);
    }
};

// ---- idle connections give their pages back ----

/// Hand the physical pages behind a connection's buffers back to the kernel
/// while it waits for the next request.
///
/// A keep-alive connection holds its read and write buffers until it closes,
/// so every page it ever touched stays resident. Measured: never used 8,766
/// bytes, after a 6-byte response 16,955, after a 982-byte response 21,114.
///
/// The allocation itself stays, which is the point — nothing here allocates or
/// frees, so ADR 017's per-request invariant is untouched and the pages fault
/// back in as zeroes. It costs one syscall per idle transition, which is why
/// the caller only does this when the connection is about to wait.
///
/// Does nothing unless both buffers are empty. A pipelined request already
/// sitting in the read buffer is live data, and so is a response that has not
/// been flushed; discarding either would be a corrupted connection rather than
/// a smaller one.
pub fn releaseIdlePages(in: *std.Io.Reader, out: *std.Io.Writer) void {
    if (in.seek != in.end) return;
    if (out.end != 0) return;
    dontNeed(in.buffer);
    dontNeed(out.buffer);
}

/// Hand back the pages behind a buffer that is not the connection's.
///
/// A WebSocket's message ceiling is a buffer the *handler* declared, usually on
/// its own stack, and a suspended fiber holds every page it ever touched
/// ([ADR 062](../docs/adr/062-where-a-connection-waits-is-what-it-costs.md)) — a
/// socket that once received a 60 KiB message measured 74,809 bytes idle
/// against 13,375 for one that never saw one.
///
/// **The bounds are exact rather than guessed**, which is why this is allowed
/// to exist: `receive` is *handed* the slice, so no arithmetic off a stack
/// limit can run into a neighbouring fiber's live stack. Aligned inward, so a
/// buffer that straddles two pages covers no whole page and nothing happens.
///
/// The caller must be done with the bytes. `Socket.receive` does this only when
/// it has no message half-collected and is about to park, at which point the
/// previous message is already forfeit — the next one overwrites the buffer
/// whatever happens here.
pub fn releaseScratchPages(buf: []u8) void {
    dontNeed(buf);
}

/// `MADV_DONTNEED` over whatever whole pages the slice covers.
///
/// Aligned inward rather than outward: a partial page at either end may be
/// shared with somebody else's allocation, and zeroing that would be a bug of
/// the worst kind — silent, rare, and in another module. The engine allocates
/// these buffers page-aligned so that in practice nothing is trimmed.
///
/// Nothing happens off POSIX. Windows has `DiscardVirtualMemory` for the same
/// job and it is not wired up here, so a Windows build keeps the pages and the
/// old numbers — which is the behaviour that shipped, not a new fault.
fn dontNeed(buf: []u8) void {
    if (builtin.os.tag == .windows) return;
    if (buf.len == 0) return;
    const page = std.heap.pageSize();
    const start = std.mem.alignForward(usize, @intFromPtr(buf.ptr), page);
    const end = std.mem.alignBackward(usize, @intFromPtr(buf.ptr) + buf.len, page);
    if (end <= start) return;
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    // A failure here means the pages stay resident, which is where they were
    // anyway. There is nothing to report and nothing to do about it.
    std.posix.madvise(ptr, end - start, std.posix.MADV.DONTNEED) catch {};
}

// ---- deadlines (ADR 022) ----

/// Which half of a connection a limit is being put on.
pub const Side = enum { read, write };

/// How long the Engine may wait for one read, or one write.
pub const Limit = union(enum) {
    /// As long as it takes. What every wait in nilo did before ADR 022,
    /// and what a connection that has stopped being HTTP goes back to.
    none,
    /// This operation gets this many milliseconds to itself. The next one
    /// gets the same again.
    within_ms: u32,
    /// Every operation from now until the limit is changed shares one
    /// deadline, as a `monotonicNanos` reading. What a run of reads wants
    /// when it is the run that has to finish on time rather than any single
    /// read in it.
    by_ns: u64,
};

/// What ended a `Waker.wait` — the Engine's `Woken`, re-declared here so the
/// layers above never name the Engine.
pub const Woken = enum { readable, posted, timed_out, closed };

/// A connection that can be woken by somebody who is not the client on the
/// other end of it.
///
/// The same shape as `Deadlines` and for the same reason: the Engine owns the
/// machinery, nilo owns the concept, and neither has to know the other's
/// half. It travels the connection chain by value the way `Deadlines` does,
/// and it defaults to a vtable with no Engine behind it — which is what makes
/// the whole HTTP suite runnable against in-memory buffers with no server.
///
/// That default answers `.readable` to everything. A test driving `App`
/// straight has bytes in a fixed buffer or it does not; there is nobody to
/// post to it, and a `receive` that parked waiting for one would hang the
/// suite rather than fail it.
pub const Waker = struct {
    target: ?*anyopaque = null,
    vtable: *const VTable = &no_engine,

    pub const VTable = struct {
        wait: *const fn (target: ?*anyopaque, limit_ms: u32) Woken,
        post: *const fn (target: ?*anyopaque) void,
        /// Hand back the pages of this connection's fiber stack that are below
        /// its current frame, for a connection that has gone quiet, and, on a
        /// TLS connection, the record layer's buffers under the pair the
        /// caller has already given back.
        ///
        /// It sits on `Waker` because `Waker` is what a connection's fiber
        /// looks like from up here: the thing that parks it, wakes it, and now
        /// gives back what parking it costs. nilo has no other handle on a
        /// fiber and is not getting one — naming the Engine anywhere but the
        /// Engine is what ADR 001 refuses.
        release_stack: *const fn (target: ?*anyopaque) void,
        /// Shut the send side of this connection's socket, and nothing else.
        /// See `halfClose`.
        half_close: *const fn (target: ?*anyopaque) void,
    };

    /// No Engine underneath: every wait says "go and read", every post is
    /// dropped. `App.handleRequest` called from a test gets this.
    pub const off: Waker = .{};

    const no_engine: VTable = .{
        .wait = struct {
            fn f(_: ?*anyopaque, _: u32) Woken {
                return .readable;
            }
        }.f,
        .post = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
        .release_stack = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
        .half_close = struct {
            fn f(_: ?*anyopaque) void {}
        }.f,
    };

    /// Park until the socket has something to read, somebody posts, or
    /// `limit_ms` goes by with neither. Zero waits with no limit.
    ///
    /// The caller must have drained its read buffer first — a reader with
    /// bytes still in it is readable whatever the socket thinks, and this
    /// would park a connection that is holding a whole frame already.
    ///
    /// **`.readable` is answered once per arrival of bytes, not once per
    /// call.** A wait that follows a read the caller has already done must
    /// park, not answer `.readable` again for bytes that are gone — an Engine
    /// that gets this wrong sends the caller into a blocking read where
    /// neither a `post` nor the next limit can reach it, and the connection
    /// silently stops taking part in either. It is stated here because it is
    /// the Engine's half of the bargain and it cannot be seen from a test
    /// against `off`, which answers `.readable` to everything by design.
    pub fn wait(self: Waker, limit_ms: u32) Woken {
        return self.vtable.wait(self.target, limit_ms);
    }

    /// Wake the connection. The one call another fiber makes, and the reason
    /// this exists at all.
    pub fn post(self: Waker) void {
        self.vtable.post(self.target);
    }

    /// Give this connection's dead stack pages back, for a connection that has
    /// gone quiet. Everything below the current frame; nothing above it.
    ///
    /// Only correct where the caller is about to wait and means to stay
    /// waiting: the pages fault back in as zeroes, so this pays for itself
    /// once and costs again on every return trip. `Socket.park` calls it
    /// behind the same 200ms peek that gates the buffers.
    pub fn releaseStack(self: Waker) void {
        self.vtable.release_stack(self.target);
    }

    /// Send the peer a FIN and keep the socket open to read from. For a
    /// connection about to be closed with input still unread — a refused head,
    /// a body nobody took — so the answer already written reaches the peer
    /// before the close (ADR 195). Nothing happens with no Engine underneath.
    pub fn halfClose(self: Waker) void {
        self.vtable.half_close(self.target);
    }
};

/// One connection's time limits, and the way to apply them.
///
/// Passed by value into everything that reads or writes: two pointers and
/// four numbers, copied rather than reached for through the App, because
/// the limits belong to a connection and the App is shared by all of them.
///
/// `.off` is a complete working instance that does nothing. That is what a
/// test driving `App` directly gets, and what a server with every limit set
/// to zero ends up with, so "no deadlines" needs no branch anywhere.
pub const Deadlines = struct {
    target: ?*anyopaque = null,
    vtable: *const VTable = &noop,

    /// Copied from `Options` so that nothing downstream has to be handed
    /// both a clock and a policy. Zero means no limit, field by field.
    header_ms: u32 = 0,
    idle_ms: u32 = 0,
    body_ms: u32 = 0,
    body_min_rate: u32 = 0,
    body_grace_ms: u32 = 0,
    write_ms: u32 = 0,

    /// When this request runs out of time altogether, as a `monotonicNanos`
    /// reading. Zero — the default — means it does not.
    ///
    /// Set by `nilo.deadline` and read here rather than at each call site:
    /// every limit armed below is clamped to it, so a handler waiting on a
    /// client cannot wait past the deadline whichever of the four it is
    /// waiting under ([ADR 105](../docs/adr/105-a-route-can-say-how-long-it-has.md)).
    until_ns: u64 = 0,

    pub const VTable = struct {
        limit: *const fn (target: ?*anyopaque, side: Side, l: Limit) void,
        timedOut: *const fn (target: ?*anyopaque) bool,
    };

    pub const off: Deadlines = .{};

    const noop: VTable = .{
        .limit = struct {
            fn f(_: ?*anyopaque, _: Side, _: Limit) void {}
        }.f,
        .timedOut = struct {
            fn f(_: ?*anyopaque) bool {
                return false;
            }
        }.f,
    };

    /// Waiting on a client that has not said anything yet — a connection
    /// between one keep-alive request and the next.
    pub fn armIdle(self: Deadlines) void {
        self.set(.read, if (self.idle_ms == 0) .none else .{ .within_ms = self.idle_ms });
    }

    /// The first byte of a request head has arrived; the rest of the head
    /// has `header_ms` to follow it.
    ///
    /// All of it, not each read of it, and that distinction is the reason
    /// this exists at all: a client sending one byte a second satisfies any
    /// per-read limit you care to name and never finishes a head.
    pub fn armHeader(self: Deadlines) void {
        if (self.header_ms == 0) return self.set(.read, .none);
        self.set(.read, .{ .by_ns = monotonicNanos() + msToNanos(self.header_ms) });
    }

    /// Reading a request body, one read at a time. Per read rather than for
    /// the whole body, because how long a body legitimately takes is a
    /// function of its size and the client's line, and neither is something
    /// a server may put a number on in advance. What is not legitimate is a
    /// client that stops sending mid-body and holds the fiber, and that is
    /// what a per-read limit catches.
    pub fn armBody(self: Deadlines) void {
        self.set(.read, if (self.body_ms == 0) .none else .{ .within_ms = self.body_ms });
    }

    /// A run of reads that has to deliver `bytes` of a **buffered** body —
    /// one the framework is assembling in the arena, which the client cannot
    /// be allowed to take forever over.
    ///
    /// `armBody`'s per-read limit is the wrong shape for this and the reason
    /// is `armHeader`'s: a client sending a byte every twenty-nine seconds is
    /// inside a thirty-second per-read limit indefinitely. What is different
    /// here — and what makes a deadline possible where ADR 022 says a
    /// request may not have one — is that the client has said how many bytes
    /// are coming, so the deadline is sized from the work rather than
    /// guessed: `body_grace_ms` plus what `bytes` need at `body_min_rate`
    /// ([ADR 022](../docs/adr/022-a-deadline-belongs-to-an-operation-not-to-a-request.md)).
    ///
    /// Armed per run rather than once for the body, because `readSizedBody`
    /// takes the step before it commits the rest and the two are separately
    /// bounded. `body_ms` at zero still means no limit at all, and
    /// `body_min_rate` at zero falls back to the per-read one.
    pub fn armBodyRun(self: Deadlines, bytes: u64) void {
        if (self.body_ms == 0) return self.set(.read, .none);
        if (self.body_min_rate == 0) return self.armBody();

        // A megabyte at a kilobyte a second is 1,000 seconds. `bytes` is not
        // always `max_body`'s: a stream's `max_bytes` is the caller's own
        // number, up to `maxInt(u64)`, so the multiply and the sum saturate and
        // the `@min` below caps what is left.
        const budget_ms: u64 = self.body_grace_ms +| (bytes *| std.time.ms_per_s) / self.body_min_rate;
        self.set(.read, .{ .by_ns = monotonicNanos() + msToNanos(@intCast(@min(budget_ms, std.math.maxInt(u32)))) });
    }

    /// Writing to the client, one write at a time — same reasoning as
    /// `armBody`, in the other direction.
    ///
    /// **Armed again for each request, and again when the route's deadline
    /// is about to matter** (`Ctx.armWriteLimit`), because `until_ns` can
    /// only cut it down once the route has set it. The per-write limit stays
    /// the shape it was: `write_ms` for each write, so a response that is
    /// large and honestly slow is not cut at `write_ms` in total. What the
    /// deadline changes is one case, the one it can be exact about: when
    /// what is left of it is no more than `write_ms`, the write is bounded by
    /// the deadline itself, as an absolute time, because a write that began
    /// inside `write_ms` of the deadline would otherwise outlive it by up to
    /// `write_ms`. A deadline further off than `write_ms` leaves the write on
    /// its own limit, which already stops a client that has stopped reading;
    /// it does not stop one that takes a byte every `write_ms` ([ADR 105](../docs/adr/105-a-route-can-say-how-long-it-has.md)).
    ///
    /// A deadline that has already passed changes nothing: the 503 naming
    /// the budget, or a handler's late answer, still goes out under the
    /// ordinary limit rather than into a write that has run out before it
    /// began.
    pub fn armWrite(self: Deadlines) void {
        var l: Limit = if (self.write_ms == 0) .none else .{ .within_ms = self.write_ms };
        if (self.until_ns != 0) {
            const now = monotonicNanos();
            if (self.until_ns > now and (self.write_ms == 0 or self.until_ns - now <= msToNanos(self.write_ms)))
                l = .{ .by_ns = self.until_ns };
        }
        self.vtable.limit(self.target, .write, l);
    }

    /// Take the limit off reads. For a connection that has stopped being a
    /// series of requests and is allowed to sit quiet — a WebSocket whose
    /// client has nothing to say for an hour is working correctly.
    pub fn readForever(self: Deadlines) void {
        self.set(.read, .none);
    }

    /// Every read from here on shares one limit, `ms` from now: a bound on
    /// the whole of a wait rather than on each read in it. What a per-read
    /// limit cannot give: a peer sending a byte a second is inside any
    /// per-read limit of more than a second for as long as it likes.
    pub fn armAllReads(self: Deadlines, ms: u32) void {
        self.set(.read, .{ .by_ns = monotonicNanos() + msToNanos(ms) });
    }

    /// Each read from here on has `ms`, for a connection that may be slow
    /// in total but may not stop: a WebSocket part way through a frame.
    pub fn armEachRead(self: Deadlines, ms: u32) void {
        self.set(.read, .{ .within_ms = ms });
    }

    /// A deliberately short read limit, used to find out whether a connection
    /// is about to be idle rather than to enforce anything.
    ///
    /// Running out of time here is not an error and does not end the
    /// connection: it is the answer to "is the next request already on its
    /// way?", and the caller arms the real idle limit straight afterwards.
    pub fn armPeek(self: Deadlines, ms: u32) void {
        self.set(.read, .{ .within_ms = ms });
    }

    /// Whether the last read or write failed because it ran out of time,
    /// rather than because the connection broke. Both arrive as
    /// `error.ReadFailed`/`error.WriteFailed` through a `std.Io` interface,
    /// which is why this is a separate question.
    pub fn timedOut(self: Deadlines) bool {
        return self.vtable.timedOut(self.target);
    }

    fn set(self: Deadlines, side: Side, l: Limit) void {
        self.vtable.limit(self.target, side, self.clamped(l));
    }

    /// Cut a limit down to the request's own deadline, if it has one.
    ///
    /// **Every arming above goes through here**, including `armIdle` and
    /// `readForever`, which is what makes the deadline one number rather than
    /// six places to remember. `none` becomes the deadline itself: "as long
    /// as it takes" is exactly what a deadline is for.
    fn clamped(self: Deadlines, l: Limit) Limit {
        if (self.until_ns == 0) return l;
        return switch (l) {
            .none => .{ .by_ns = self.until_ns },
            .within_ms => |ms| .{ .by_ns = @min(monotonicNanos() + msToNanos(ms), self.until_ns) },
            .by_ns => |ns| .{ .by_ns = @min(ns, self.until_ns) },
        };
    }
};

fn msToNanos(ms: u32) u64 {
    return @as(u64, ms) * std.time.ns_per_ms;
}

/// Run a blocking call on the Engine's thread pool, parking this fiber
/// until it comes back (ADR 013).
///
/// The slot travels with it. Without that, a fail function called inside
/// the blocking call would find no request — the worker is a plain thread,
/// not the fiber the slot is bound to — and `fail.notFound(…)` inside a
/// database query would quietly become a 500 instead of a 404. Carrying it
/// is safe because this is a hand-off, not sharing: the fiber is parked for
/// exactly as long as the worker is running, so only one of them is ever
/// looking at the InFlight.
///
/// The `setFallbackSlot` below must keep happening on a thread-pool worker
/// and never on an executor thread. `spawn` (ADR 028) runs fibers with no
/// slot of their own, and those fall through to the threadlocal; if this
/// assignment ever landed on the thread they run on, spawned work would
/// write its failure message into an unrelated request — ADR 006's leak,
/// by another route. It lands on a worker because `engine.blocking` is
/// `zio.blockInPlace`, which submits the call to the thread pool.
pub fn blocking(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) ReturnType(func) {
    return handOff(engine.blocking, func, args);
}

/// `blocking`, with a thread of its own rather than a place in the pool's
/// queue: an idle worker, or a new one past the pool's ceiling.
///
/// For a caller that holds something others wait for while it blocks. A
/// SQLite statement under `.hop` holds its connection, and queued behind
/// one slow call on the only busy worker it held the writer until that
/// call finished, so every write after it timed out (`docs/risks.md`,
/// zio#745). It is not for fanning work out: every call that finds no
/// idle worker starts a thread, which is why SQLite's calls are behind a
/// Gate sized to its connections (ADR 064).
pub fn blockingReserved(func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) ReturnType(func) {
    return handOff(engine.blockingReserved, func, args);
}

/// What `blocking` and `blockingReserved` share: the slot carried to the
/// worker and the wait counted where the fiber is, as `blocking` explains.
fn handOff(comptime submit: anytype, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) ReturnType(func) {
    const Args = @TypeOf(args);
    const Carrier = struct {
        fn run(carried: ?*anyopaque, inner: Args) ReturnType(func) {
            // Run inline, which zio does when the caller cannot park: the
            // fiber's own slot is still the one fail functions find, and the
            // fallback is not needed.
            if (engine.slot() != null) return @call(.auto, func, inner);
            const previous = setFallbackSlot(carried);
            defer _ = setFallbackSlot(previous);
            return @call(.auto, func, inner);
        }
    };
    // Opened and closed on this side of the hand-off on purpose. Inside
    // `Carrier.run` the slot points at the same InFlight, so the arithmetic
    // would be the same — but that code runs on a thread-pool worker, and
    // two threads writing `waited_ns` is a race for no gain (ADR 013).
    const w = watchdog.waitingAnywhere();
    defer watchdog.waitedAnywhere(w);
    return submit(Carrier.run, .{ slot(), args });
}

fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type orelse void;
}

/// A fallback for use outside the Engine: unit tests call App directly,
/// with no fiber, so `engine.slot()` is always null there. On a real
/// server a connection's fiber slot always exists and wins, so what is
/// stored here is never read by one.
///
/// A fiber from `spawn` (ADR 028) has no slot, so it *does* read this. It
/// is safe only because the one place that writes it on a server,
/// `blocking` above, does so on a thread-pool worker, and spawned fibers
/// run on executor threads. Anything that starts setting this on an
/// executor thread reintroduces the cross-request leak ADR 006 exists to
/// prevent, and `serveRequest` once did.
threadlocal var fallback_slot: ?*anyopaque = null;

/// Install the fallback slot, returning the previous one so it can be
/// restored.
///
/// **Refused in Debug from a fiber that has a slot of its own.** That fiber
/// is on an executor, and a value left here across one of its suspensions
/// is read by whichever spawned fiber runs next on the thread. What this
/// cannot see is a spawned fiber, which has no slot, setting it; nothing on
/// the server does.
pub fn setFallbackSlot(p: ?*anyopaque) ?*anyopaque {
    if (builtin.mode == .Debug and p != null) std.debug.assert(engine.slot() == null);
    const previous = fallback_slot;
    fallback_slot = p;
    return previous;
}

/// The slot bound to the running fiber, and never the fallback: null in a
/// test calling App directly, and in a fiber from `spawn`.
pub fn fiberSlot() ?*anyopaque {
    return engine.slot();
}

/// When the loop this fiber runs on last began a turn, in `CLOCK_MONOTONIC`
/// nanoseconds, or null when there is no loop. What the blocking detector asks
/// to tell a park it was not told about from a handler holding its thread
/// (ADR 013).
pub const loopTurnNanos = engine.loopTurnNanos;

/// The slot of the request currently running, or null if there is none.
pub fn slot() ?*anyopaque {
    return engine.slot() orelse fallback_slot;
}

// ---- tests ----

const testing = std.testing;

/// Catches the last limit asked for, so what `arm*` works out can be
/// checked without a socket to apply it to.
const Caught = struct {
    side: Side = .read,
    limit: Limit = .none,
    n: usize = 0,

    fn deadlines(self: *Caught, limits: Deadlines) Deadlines {
        var d = limits;
        d.target = self;
        d.vtable = &.{ .limit = take, .timedOut = never };
        return d;
    }

    fn take(target: ?*anyopaque, side: Side, l: Limit) void {
        const self: *Caught = @ptrCast(@alignCast(target.?));
        self.side = side;
        self.limit = l;
        self.n += 1;
    }

    fn never(_: ?*anyopaque) bool {
        return false;
    }
};

test "an idle limit is a duration, because each wait stands on its own" {
    var caught = Caught{};
    const d = caught.deadlines(.{ .idle_ms = 900 });
    d.armIdle();
    try testing.expectEqual(Side.read, caught.side);
    try testing.expectEqual(Limit{ .within_ms = 900 }, caught.limit);
}

test "a buffered body's limit is a deadline sized from the bytes it is waiting for" {
    var caught = Caught{};
    const d = caught.deadlines(.{ .body_ms = 1100, .body_min_rate = 1024, .body_grace_ms = 500 });

    const before = monotonicNanos();
    d.armBodyRun(2048);
    const after = monotonicNanos();

    // 500ms of grace plus two seconds for two kilobytes at a kilobyte a
    // second, bracketed by two readings of the clock it was worked out from.
    const want = 2500 * std.time.ns_per_ms;
    const at = caught.limit.by_ns;
    try testing.expect(at >= before + want);
    try testing.expect(at <= after + want);
}

test "a body of any size the caller names sizes a deadline instead of overflowing it" {
    // `bodyStreamWith(.{ .max_bytes = maxInt(u64) })` is a caller's number,
    // not one `max_body` bounded, and `bytes * 1000` wraps in ReleaseFast and
    // panics in Debug and ReleaseSafe.
    var caught = Caught{};
    const d = caught.deadlines(.{ .body_ms = 1100, .body_min_rate = 1024, .body_grace_ms = 500 });

    const before = monotonicNanos();
    d.armBodyRun(std.math.maxInt(u64));
    // Capped at the largest budget a deadline is given, rather than the wrapped
    // (small) one a multiplication that overflowed would have produced.
    const cap = @as(u64, std.math.maxInt(u32)) * std.time.ns_per_ms;
    try testing.expect(caught.limit.by_ns >= before + cap);
}

test "a route deadline nearer than the write limit becomes the write limit, and a later or a passed one leaves it" {
    var caught = Caught{};
    var d = caught.deadlines(.{ .write_ms = 30_000 });

    d.until_ns = monotonicNanos() + 2 * std.time.ns_per_s;
    d.armWrite();
    try testing.expectEqual(d.until_ns, caught.limit.by_ns);

    d.until_ns = monotonicNanos() + 60 * std.time.ns_per_s;
    d.armWrite();
    try testing.expectEqual(Limit{ .within_ms = 30_000 }, caught.limit);

    // Past: a late answer, or the 503 for it, still gets the ordinary limit.
    d.until_ns = monotonicNanos() -| std.time.ns_per_ms;
    d.armWrite();
    try testing.expectEqual(Limit{ .within_ms = 30_000 }, caught.limit);

    // No write limit at all: the deadline is the only one there is.
    var bare = Caught{};
    var e = bare.deadlines(.{ .write_ms = 0 });
    e.until_ns = monotonicNanos() + 60 * std.time.ns_per_s;
    e.armWrite();
    try testing.expectEqual(e.until_ns, bare.limit.by_ns);
}

test "a rate of zero leaves the body on the per-read limit it had" {
    // The way out for a server whose clients are slower than any rate worth
    // naming: the old behaviour, unchanged, rather than a number to guess at.
    var caught = Caught{};
    const d = caught.deadlines(.{ .body_ms = 1100, .body_min_rate = 0 });
    d.armBodyRun(2048);
    try testing.expectEqual(Limit{ .within_ms = 1100 }, caught.limit);
}

test "a body timeout of zero means no limit, rate or no rate" {
    // `body_timeout_ms = 0` is the switch for "do not put a clock on a body",
    // and a rate underneath it must not put one back.
    var caught = Caught{};
    const d = caught.deadlines(.{ .body_ms = 0, .body_min_rate = 1024, .body_grace_ms = 500 });
    d.armBodyRun(2048);
    try testing.expectEqual(Limit.none, caught.limit);
}

test "a header limit is a deadline, so a byte at a time does not extend it" {
    var caught = Caught{};
    const d = caught.deadlines(.{ .header_ms = 700 });

    const before = monotonicNanos();
    d.armHeader();
    const after = monotonicNanos();

    // In the future, and by about the right amount — bracketed by two
    // readings of the same clock rather than compared against a constant,
    // because the second one is the only thing that cannot drift.
    const at = caught.limit.by_ns;
    try testing.expect(at >= before + 700 * std.time.ns_per_ms);
    try testing.expect(at <= after + 700 * std.time.ns_per_ms);
}

test "a limit of zero takes the limit off rather than expiring at once" {
    // The difference matters: a duration of zero is a read that fails
    // immediately, which would be a server that answers nothing at all.
    var caught = Caught{};
    const d = caught.deadlines(.{});
    d.armIdle();
    try testing.expectEqual(Limit.none, caught.limit);
    d.armHeader();
    try testing.expectEqual(Limit.none, caught.limit);
    d.armBody();
    try testing.expectEqual(Limit.none, caught.limit);
    d.armWrite();
    try testing.expectEqual(Limit.none, caught.limit);
    try testing.expectEqual(Side.write, caught.side);
    try testing.expectEqual(@as(usize, 4), caught.n);
}

test "the deadlines a test gets by default do nothing, and say nothing timed out" {
    const d: Deadlines = .off;
    d.armIdle();
    d.armHeader();
    d.armBody();
    d.armWrite();
    d.readForever();
    try testing.expect(!d.timedOut());
}

// ---- Gate (ADR 222) ----
//
// Plain threads rather than fibers: the Engine's lock and condition park an
// OS thread when there is no fiber under them, which is what lets these run
// without a Runtime and without this file naming the Engine. The order a
// thread joins the line is made certain by waiting for the Gate to count it
// before the next one starts.

fn gateWaiting(g: *Gate) usize {
    g._lock.lockUncancelable();
    defer g._lock.unlock();
    return g._waiting;
}

/// Until the Gate counts `n` waiting, for at most five seconds. Bounded, and
/// failing when the bound passes, so a line that never forms is a failed test
/// rather than a suite that waits for the CI job's own limit: a waiter that
/// gave up before the next one queued once held macOS CI for thirty minutes.
fn untilWaiting(g: *Gate, n: usize) !void {
    const until = monotonicNanos() + 5 * std.time.ns_per_s;
    while (gateWaiting(g) < n) {
        if (monotonicNanos() > until) return error.LineNeverFormed;
        std.Thread.yield() catch {};
    }
}

const Arrivals = struct {
    gate: *Gate,
    order: [8]u8 = undefined,
    served: std.atomic.Value(usize) = .init(0),

    fn take(self: *Arrivals, who: u8) void {
        self.gate.enter() catch unreachable;
        self.order[self.served.fetchAdd(1, .seq_cst)] = who;
        self.gate.leave();
    }
};

test "a Gate hands a freed turn to the oldest waiter, in the order they came" {
    var g: Gate = .open(1);
    try g.enter();
    var a: Arrivals = .{ .gate = &g };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Arrivals.take, .{ &a, @as(u8, @intCast(i)) });
        try untilWaiting(&g, i + 1);
    }
    g.leave();
    for (threads) |t| t.join();
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, a.order[0..4]);
}

/// A waiter that keeps its turn until the test says, so what the test asks
/// while it holds the turn has one answer however the threads are scheduled.
/// Let go of after five seconds at most, saying so, so a test that fails
/// before it lets go cannot hang the suite.
const Holder = struct {
    gate: *Gate,
    entered: std.atomic.Value(bool) = .init(false),
    let_go: std.atomic.Value(bool) = .init(false),
    gave_up: std.atomic.Value(bool) = .init(false),

    fn take(self: *Holder) void {
        self.gate.enter() catch unreachable;
        self.entered.store(true, .release);
        const until = monotonicNanos() + 5 * std.time.ns_per_s;
        while (!self.let_go.load(.acquire)) {
            if (monotonicNanos() > until) {
                self.gave_up.store(true, .release);
                break;
            }
            std.Thread.yield() catch {};
        }
        self.gate.leave();
    }
};

test "a turn given back while someone waits is theirs, not the next caller's" {
    // The case a first-come lock gets wrong: the fiber that just left asks
    // again at once, and would win every time against one still waking up.
    // The waiter holds its turn until the question has been asked: one that
    // woke, took its turn and gave it back before the question made the
    // answer "free" and the test fail now and then.
    var g: Gate = .open(1);
    try g.enter();
    var h: Holder = .{ .gate = &g };
    const t = try std.Thread.spawn(.{}, Holder.take, .{&h});
    untilWaiting(&g, 1) catch |err| {
        g.leave();
        t.join();
        return err;
    };
    g.leave();
    // Whether or not the waiter has woken yet, the turn is theirs.
    const took = if (g.enterWithin(0)) |_| true else |_| false;
    // Taken wrongly, it is given back, or the waiter would wait on it for ever.
    if (took) g.leave();
    h.let_go.store(true, .release);
    t.join();
    try testing.expect(!took);
    try testing.expect(h.entered.load(.acquire));
    try testing.expect(!h.gave_up.load(.acquire));
    // And once the waiter is done, the turn is free for anyone.
    try g.enterWithin(0);
    g.leave();
}

test "a wait with a limit gives up empty-handed and leaves the line as it found it" {
    var g: Gate = .open(1);
    try g.enter();
    const started = monotonicNanos();
    try testing.expectError(error.TimedOut, g.enterWithin(20));
    const took = monotonicNanos() - started;
    try testing.expect(took >= 20 * std.time.ns_per_ms);
    try testing.expectEqual(@as(usize, 0), gateWaiting(&g));
    // Nothing was taken, so one leave frees exactly the one turn there is.
    g.leave();
    try g.enterWithin(0);
    try testing.expectError(error.TimedOut, g.enterWithin(0));
    g.leave();
}

const Patient = struct {
    fn giveUp(g: *Gate, out: *?anyerror) void {
        // Long enough that the second waiter is in line behind it before it
        // gives up, which is the case this is about; 15 ms was not, on a
        // slow runner.
        g.enterWithin(300) catch |err| {
            out.* = err;
            return;
        };
        out.* = null;
        g.leave();
    }
};

test "a waiter that gave up is skipped, and the one behind it is served" {
    var g: Gate = .open(1);
    try g.enter();
    var gave_up: ?anyerror = null;
    const first = try std.Thread.spawn(.{}, Patient.giveUp, .{ &g, &gave_up });
    try untilWaiting(&g, 1);
    var a: Arrivals = .{ .gate = &g };
    const second = try std.Thread.spawn(.{}, Arrivals.take, .{ &a, 2 });
    untilWaiting(&g, 2) catch |err| {
        first.join();
        g.leave();
        second.join();
        return err;
    };
    first.join();
    try testing.expectEqual(@as(?anyerror, error.TimedOut), gave_up);
    g.leave();
    second.join();
    try testing.expectEqual(@as(u8, 2), a.order[0]);
    try testing.expectEqual(@as(usize, 0), gateWaiting(&g));
    try g.enterWithin(0);
    g.leave();
}

test "a Gate of n lets n through before anyone waits" {
    var g: Gate = .open(3);
    try g.enterWithin(0);
    try g.enterWithin(0);
    try g.enterWithin(0);
    try testing.expectError(error.TimedOut, g.enterWithin(0));
    g.leave();
    try g.enterWithin(0);
    g.leave();
    g.leave();
    g.leave();
}

test "a caller that asks again right after leave does not jump the line" {
    // The case `enterWithin(0)` above cannot reach: `enter` from the caller
    // that just left, before the waiter it handed the turn to has woken.
    // Found in review, where it barged 45 times in 50 on a Gate that counted
    // handed turns instead of naming the waiter they were handed to.
    var barged: usize = 0;
    for (0..50) |_| {
        var g: Gate = .open(1);
        try g.enter();
        var a: Arrivals = .{ .gate = &g };
        const t = try std.Thread.spawn(.{}, Arrivals.take, .{ &a, 7 });
        untilWaiting(&g, 1) catch |err| {
            g.leave();
            t.join();
            return err;
        };
        g.leave();
        try g.enter();
        if (a.served.load(.seq_cst) == 0) barged += 1;
        g.leave();
        t.join();
    }
    try testing.expectEqual(@as(usize, 0), barged);
}
