//! nilo — an HTTP framework for Zig that puts writing code first. Its
//! vocabulary is in CONTEXT.md, its design decisions in docs/adr/.

pub const App = @import("app.zig").App;

/// What `app.group("/api/v1")` hands back: one prefix and everything
/// registered beneath it. Named here so a plugin can spell out the type it
/// takes instead of using `anytype`.
pub const Group = @import("app.zig").Group;
/// A group and the middlewares its routes are excused from — what `without`
/// hands back (ADR 008). Named here because a plugin taking one by type
/// rather than as `anytype` has to be able to write it down.
pub const GroupOf = @import("app.zig").GroupOf;

/// A group, the middlewares its routes are excused from, and the ones they
/// carry of their own — what `with` hands back (ADR 099). `GroupOf` is this
/// with nothing carried.
pub const GroupWith = @import("app.zig").GroupWith;

/// One route, as `app.routes()` reports it (ADR 100).
pub const Registered = @import("app.zig").Registered;
pub const Routes = @import("app.zig").Routes;

/// Building a URL out of a route pattern, checked while compiling. `Ctx.url`
/// is the same call with the request arena behind it (ADR 100).
pub const url = @import("url.zig");

pub const Ctx = @import("ctx.zig").Ctx;
pub const Str = @import("nilo_core").Str;

/// A Scope for work that is not a request — a CLI run, the tick of a
/// scheduled task, a test (ADR 038). A `Ctx` is the Scope a handler has;
/// this is the one a program with no request in it hands to a module that
/// wants one, `nilo_sql` included.
pub const Run = @import("nilo_core").Run;

/// A Scope with its type erased, for a callback stored as a function pointer
/// ([ADR 144](../docs/adr/144-a-scope-that-crosses-a-function-pointer.md)).
///
/// ```zig
/// const Reaction = *const fn (scope: *nilo.AnyScope, payload: []const u8) anyerror!void;
///
/// var erased = nilo.AnyScope.of(c);   // or `.of(&run)` outside a request
/// try reaction(&erased, payload);
/// ```
///
/// Zig has no closures, so anything with a bus, a queue or a job registry
/// stores a function pointer — and a function pointer cannot be generic over
/// the Scope it runs under, which is what a reaction written for the server and
/// tested under a `Run` needs. This is that wrapper, offered once rather than
/// rewritten per caller.
///
/// **The ordinary Scope is unchanged**: `db.select(Row, c, …)` still takes
/// `anytype` and still costs no indirect call (ADR 038). The vtable is paid
/// for only where somebody erases one, and it borrows — an `AnyScope` may not
/// outlive the `Ctx` or `Run` it was made from.
pub const AnyScope = @import("nilo_core").AnyScope;

/// Percent coding, both directions
/// ([ADR 057](../docs/adr/057-percent-is-needed-by-two-layers.md)).
///
/// The framework decodes with it on the way in, and it is re-exported here
/// because the caller who needs the *other* direction is a handler: anything
/// putting somebody else's text into a URL it is about to fetch. That is the
/// second layer the ADR is named for, and a handler cannot reach `nilo_core`
/// without adding an import to its build.
pub const percent = @import("nilo_core").percent;

/// The reader a type marked with `nilo_json` hands to `std.json`, so that a
/// body carrying an internally tagged union or a renamed enum can be read back
/// ([ADR 016](../docs/adr/016-the-api-description-comes-from-the-signatures.md)):
///
/// ```zig
/// const Condition = union(enum) {
///     pub const nilo_json = .{ .tag = "signal" };
///     pub const jsonParse = nilo.jsonParseFor(@This());
///
///     metrics: MetricCondition,
///     logs: LogCondition,
/// };
/// ```
///
/// Writing needs no such line — `json.write` asks the marker itself. Reading
/// does, because `std.json` is what chooses a parser for a type and nothing can
/// add a declaration to a type somebody else wrote.
pub const jsonParseFor = @import("jsonmark.zig").parseFor;

/// Write `value` as JSON to a `*std.Io.Writer` by the rules a response is
/// written by, outside a request: a job's payload, an alert body, the expected
/// text in a test. Struct fields in declaration order, a non-finite float as
/// `null`, a `Str` as text, a `nilo_json` marker honoured, and the bytes
/// `std.json` would have written for anything the generated writer does not
/// cover. It is the function `c.json` calls, so the two cannot disagree.
///
/// ```zig
/// try nilo.writeJson(&writer, .{ .alert = "disk", .free = 0.07 });
/// ```
pub const writeJson = @import("json.zig").write;

/// `writeJson` into a slice the caller frees with `gpa`.
pub const jsonAlloc = @import("json.zig").alloc;

pub const Method = @import("http1.zig").Method;
pub const Options = @import("bulkhead.zig").Options;

/// One of the two root-file lines, and the one that keeps `std.log` from
/// blocking the event loop:
///
/// ```zig
/// pub const std_options_debug_io = nilo.debug_io;
/// ```
///
/// Note which is which — `debug_io` goes into `std_options_debug_io`, and
/// `std_options` below goes into `std_options`. The two are easy to write
/// the wrong way round, and each fixes a different symptom.
///
/// `listen()` says so at startup if it is missing, because the symptom
/// otherwise is a server that is merely slow.
pub const debug_io = @import("bulkhead.zig").debug_io;

/// The other half of the wiring: `pub const std_options = nilo.std_options;`
///
/// All it does is turn the Engine's debug chatter down to warnings. Without
/// it a debug build opens with `debug(zio): Spawning worker thread 1` and
/// buries your own logs — the Engine is an implementation detail, so it
/// should not be the first thing anybody sees.
///
/// To keep your own settings, start from this one:
///
/// ```zig
/// pub const std_options: std.Options = .{
///     .log_level = .debug,
///     .log_scope_levels = nilo.std_options.log_scope_levels,
/// };
/// ```
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .zio, .level = .warn }},
};

/// A lock for a Service that gets written to. Handlers run concurrently on
/// several OS threads, so shared mutable state needs one — and this is the
/// one to use rather than `std.Thread.Mutex`, which stops the whole thread
/// and every other request being served on it.
///
/// ```zig
/// const Store = struct {
///     lock: nilo.Mutex = .init,
///     users: std.ArrayList(User) = .empty,
/// };
///
/// try store.lock.lock();
/// defer store.lock.unlock();
/// ```
pub const Mutex = @import("bulkhead.zig").Mutex;

/// A Mutex with a number bigger than one: `n` fibers through at once and the
/// rest park (ADR 044).
///
/// For a call that is *expensive* rather than slow. `nilo.blocking` already
/// keeps a slow call off the loop and the Engine's pool already caps how many
/// run at once — at twice the core count, which is right for a call waiting on
/// a disk and wrong for one eating a core and a lot of memory.
///
/// ```zig
/// var resizing: nilo.Gate = .open(4);
///
/// try resizing.enter();
/// defer resizing.leave();
/// const thumb = try nilo.blocking(shrink, .{ gpa, bytes });
/// ```
///
/// nilo's own caller is password hashing, and there the Gate is already
/// applied for you — see `Ctx.hashPassword`.
pub const Gate = @import("bulkhead.zig").Gate;

/// A deadline for an operation that is not a read or a write of a connection
/// nilo holds — an outbound call, in practice (ADR 056).
///
/// A Service asks for one by taking a third parameter on its start hook, and
/// bounds one call with it:
///
/// ```zig
/// pub fn nilo_start(self: *Mailer, io: std.Io, limits: nilo.Limits) !void {
///     self.io = io;
///     self.limits = limits;
/// }
///
/// var bound: nilo.Limits.Bound = .idle;
/// defer bound.release();
/// bound.arm(self.limits, 2_000);
/// ```
///
/// `bound.fired()` afterwards is how a handler tells its own deadline from a
/// shutdown: both arrive as `error.Canceled`, and only one of them is worth
/// reporting as a timeout.
pub const Limits = @import("bulkhead.zig").Limits;

/// Somewhere to put work that is not a request: a fiber of its own, owned
/// by the server rather than by whatever started it (ADR 028).
///
/// ```zig
/// try nilo.spawn(flushMetrics, .{&exporter});
/// ```
///
/// The server counts it while it runs and cuts it off when the shutdown
/// grace period ends, exactly as it does a connection. `error.NoServer` if
/// nothing is listening yet — which is what a unit test calling a handler
/// directly gets.
///
/// Two things do not travel into it, and neither is caught by the compiler:
///
/// - **A `Str`.** It points into the request arena, which is reset when the
///   request ends; spawned work outlives the call that started it by
///   definition. Copy anything borrowed from a request before it goes in.
/// - **A fail function.** There is no request to fail, so `fail.notFound`
///   returns a plain error with no message and nobody assembles a response
///   from it. Log instead.
pub const spawn = @import("bulkhead.zig").spawn;

/// The `std.Io` the server runs on, for a fiber `app.spawn` started, which
/// has no `Ctx` to ask. A handler asks with `io: std.Io` or `c.io()`; this is
/// the same value (ADR 244). Called before the server is listening, or with
/// none running, it is a process-wide `std.Io.Threaded` and **not** the
/// server's loop, so do not keep what it returns across `listen()`.
pub const io = @import("bulkhead.zig").loopIo;

/// Run a blocking call without stopping the thread it is on.
///
/// Many requests share one OS thread, so a handler that blocks stops all of
/// them — a database driver, `std.fs`, `std.http.Client`, anything that
/// waits on a syscall. Hand it to this instead and only the one request
/// waits (ADR 013):
///
/// ```zig
/// fn getUser(db: *Db, id: u32) !User {
///     return nilo.blocking(Db.query, .{ db, id });
/// }
/// ```
///
/// The return value is whatever the function returns, errors included. It
/// allocates nothing, and outside a running server it simply calls the
/// function — so a handler using it is still testable as an ordinary
/// function (ADR 002).
pub const blocking = @import("bulkhead.zig").blocking;

/// `blocking`, with a thread of its own rather than a place in the pool's
/// queue, for a call made while holding something other requests wait for.
///
/// A plain `blocking` call can wait behind a slow one already on the pool.
/// That is only a slower request, unless the caller is holding a pooled
/// connection or a lock: then everyone waiting on that waits too. This one
/// gets an idle worker or starts a new one, past the pool's ceiling if it
/// has to, so it is for a call whose callers are already bounded, not for
/// fanning work out. It is what SQLite's `.{ .hop = nilo }` uses for every
/// statement (ADR 064).
pub const blockingReserved = @import("bulkhead.zig").blockingReserved;

/// Wait, without stopping the thread. `std.Thread.sleep` would park every
/// other request sharing it; this parks only this one.
///
/// Fails with `error.Canceled` if the request went away while waiting,
/// which maps to a 503 the way `Mutex.lock` does.
pub const sleep = @import("bulkhead.zig").sleep;

/// Bytes from the operating system's entropy source, off the event loop —
/// what `Ctx.entropy` is underneath, for a buffer you are already holding
/// or for work outside a request (ADR 042).
///
/// Inside a handler prefer `c.entropy(n)`, which answers by value and so
/// fits in the expression that wants it.
pub const randomSecure = @import("bulkhead.zig").randomSecure;

/// Whether a password matches a stored hash, with no request in hand — what
/// `c.verifyPassword` is underneath, for a CLI resetting an account, a job
/// re-hashing at a raised Cost, or a test with neither an App nor a Ctx
/// (ADR 044).
///
/// ```zig
/// if (!try nilo.verifyPassword(pw.huge_pages, row.password, typed)) return error.WrongPassword;
/// ```
///
/// The same Gate and the same blocking pool as the method: on the server's
/// loop it holds one of `password_hashes_at_once` permits, and with no loop
/// at all it runs inline. Checking needs no request because the salt is in
/// the stored string; making a hash does, because the salt comes from
/// `c.entropy`, which is why there is no `nilo.hashPassword` beside this.
/// `stored` is `?[]const u8` and null costs what an account costs, here as
/// everywhere.
pub const verifyPassword = @import("password.zig").verifyAnywhere;

/// The same, told what a hash of yours costs (ADR 044).
pub const verifyPasswordWith = @import("password.zig").verifyAnywhereWith;

/// What time it is: microseconds and milliseconds since the epoch, from
/// `nilo_core` (ADR 041). Reading the wall clock needs no event loop, so
/// this is a plain function rather than a call on the `Ctx` — nobody owns
/// the time, and there is nothing to ask permission for.
///
/// `nowMillis()` is the unit a UUID v7 puts in its first six bytes;
/// `nowMicros()` is the one Postgres keeps a `timestamptz` in, which is why
/// `sql.Timestamp.now()` is a copy rather than a conversion.
pub const nowMicros = @import("nilo_core").nowMicros;
pub const nowMillis = @import("nilo_core").nowMillis;

/// Fail functions — `fail.notFound("no user {d}", .{id})` and friends,
/// callable from anywhere (ADR 004).
pub const fail = @import("fail.zig");

/// A response whose status the handler picks while it runs, headers of its
/// own, or both: `Response(User){ .status = 201, .headers = …, .value = user }`.
///
/// `Response(void)` is an empty one — `.{ .status = 204 }` after a DELETE.
///
/// The status being a runtime field is why the API description can only
/// write `default` for one of these. Where the status is part of the
/// contract rather than a decision, `Status` below says so (ADR 023).
pub const Response = @import("typed.zig").Response;

/// A response whose status is part of the signature, so the API description
/// can name it: `Status(201, User)`, `Status(204, void)` (ADR 023).
///
/// ```zig
/// fn createUser(incoming: NewUser) !nilo.Status(201, User) {
///     return .{ .value = made };
/// }
/// ```
pub const Status = @import("typed.zig").Status;

/// One response header, as `Response.headers` takes them.
pub const Header = @import("typed.zig").Header;

/// The headers a `Response` carries, held by value: `.headers = .of(&.{…})`.
/// Copying is the point — a list written in a handler dies with the handler
/// (ADR 018).
pub const Headers = @import("typed.zig").Headers;

/// A response written in pieces, from `c.stream(status, content_type)` —
/// for a body whose length nobody knows when the head goes out (ADR 019).
pub const Stream = @import("stream.zig").Stream;

/// A stream of server-sent events, from `c.events()`. One whose every event
/// comes from Rooms is `c.eventsFrom(rooms, .{})` instead, which hands the
/// stream to the connection and costs what an idle socket costs (ADR 227).
pub const Events = @import("stream.zig").Events;

/// A request body read in pieces, from `c.bodyStream()` — for the ones too
/// big to hold in the request arena (ADR 019).
pub const Body = @import("body.zig").Body;

/// An open WebSocket connection. A loop handed to `c.upgrade(loop, state)` is
/// given one and reads it until the conversation ends (ADR 021, ADR 062).
pub const Socket = @import("websocket.zig").Socket;

/// Everything else WebSocket: `Message`, `Kind`, `Close`, `Options`.
pub const websocket = @import("websocket.zig");

/// Saying something to sockets a handler does not hold. Provide one as a
/// service, `join` on the way in, `defer leave` on the way out, and `say`
/// reaches everybody in it, event streams from `c.eventsFrom` included.
pub const Room = @import("room.zig").Room;

/// Everything else Room: `Options`, `Full`, `Ticket`.
pub const room = @import("room.zig");

/// Rooms by name, lent from a pool sized up front: `rooms.join("user:42",
/// socket)` on every tab a user has open, and `rooms.json("user:42", …)`
/// from anywhere to reach all of them (ADR 228).
pub const Rooms = @import("rooms.zig").Rooms;

/// Everything else Rooms: `Options`, `max_key`, `Error`.
pub const rooms = @import("rooms.zig");

/// One message on an event stream: `.{ .name = "token", .data = text }`.
pub const Event = @import("stream.zig").Event;

/// Driving a request into an App from a test, for the handlers that write
/// their answer instead of returning it. Not part of a running server.
pub const testing = @import("testing.zig");

/// The query string, read into a struct of yours — the named counterpart
/// to a positional path param.
///
/// ```zig
/// const Search = struct { q: Str, page: u32 = 1, tag: ?Str = null };
/// fn search(params: nilo.Query(Search)) ![]const Item { … }
/// ```
pub const Query = @import("typed.zig").Query;

/// A whole number inside a range, as a type — for the `limit` every list
/// endpoint bounds and every document should say it bounds
/// ([ADR 167](../docs/adr/167-a-whole-number-inside-a-range-is-a-type.md)).
///
/// ```zig
/// const ListQuery = struct { limit: nilo.Within(1, 200) = .of(50), offset: u32 = 0 };
/// ```
///
/// `?limit=500` is a 400 naming the range, the document says `minimum` and
/// `maximum`, and the value is `q.value.limit.value`. Read wherever a `u8`
/// is: a path param, a query value, a form field, a JSON body.
pub const Within = @import("within.zig").Within;

/// One request header, as a typed argument — the same family as `Query(T)`
/// and `Form(T)`, on a header
/// ([ADR 131](../docs/adr/131-a-header-a-handler-can-be-given.md)).
///
/// ```zig
/// fn addComment(actor: nilo.FromHeader("X-Staff-Id", Uuid), body: NewComment) !Comment { … }
/// ```
///
/// `c.header("X-Staff-Id")` reads one too, and the difference is the
/// generated document: a header nilo was told about is a header the document
/// promises, so a client generated from it knows to send one. Absent is null
/// for a `?T` and a 400 for anything else.
///
/// **Not `Header`**: that name is the response side, and has been since
/// 0.2.0.
pub const FromHeader = @import("typed.zig").FromHeader;

/// The `Authorization` header, as a typed argument that reads one scheme
/// and refuses with the challenge a 401 has to carry
/// ([ADR 153](../docs/adr/153-an-authorization-header-a-handler-can-ask-for.md)).
///
/// ```zig
/// fn me(auth: nilo.Authorization(.bearer), issuer: *const Issuer) !Profile { … auth.value … }
/// fn admin(auth: nilo.Authorization(.{ .basic = "admin" })) !void { … auth.user, auth.password … }
/// ```
///
/// The scheme is matched the way RFC 9110 says — case-insensitively — and
/// absent or the wrong scheme is a 401 with `WWW-Authenticate: Bearer` or
/// `Basic realm="…"` on it. A refusal after reading — the token did not
/// verify — is `nilo.Authorization(.bearer).refuse("…", .{})`, which is
/// `fail.unauthorized` with the same header. In the document, a security
/// scheme and a 401. A resolver has no argument list of its own and reads
/// the same thing with `c.authorization(.bearer)`.
pub const Authorization = @import("authorization.zig").Authorization;

/// The same header verified: the claims behind a bearer token, read through
/// the `jwt.Verifier` the argument names, or a 401 with the challenge before
/// the handler runs
/// ([ADR 191](../docs/adr/191-verified-claims-are-a-handler-argument.md)).
///
/// ```zig
/// const Google = jwt.Verifier(Claims, fetch.Client);
/// fn me(user: nilo.Verified(Google)) !Profile { … user.claims.sub … }
/// ```
///
/// The Verifier is a service the route requires, so `listen()` refuses to
/// start without it. A refusal after reading is
/// `nilo.Verified(Google).refuse("…", .{})`. A middleware reads the same
/// thing with `c.verified(Google)`.
pub const Verified = @import("verified.zig").Verified;
/// Text with a shape (ADR 193): a `Str` with a length, a check of your own,
/// or both, refused with one sentence in every slot and described in the
/// document. `Email` and `Url` are presets.
pub const Text = @import("text.zig").Text;
pub const Email = @import("text.zig").Email;
pub const Url = @import("text.zig").Url;
/// What a struct's `nilo_check` writes into (ADR 193).
pub const Rules = @import("bound.zig").Rules;

/// The `Idempotency-Key` header, as a typed argument that makes the route
/// answer once per key
/// ([ADR 155](../docs/adr/155-a-request-answered-once-is-answered-the-same-way-again.md)).
///
/// ```zig
/// const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });
///
/// fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder, db: *sql.Db, c: *nilo.Ctx) !nilo.Status(201, Order)
/// ```
///
/// The first request with a key runs the handler and keeps what it
/// returned; a retry with the same key gets that answer back, with
/// `Idempotent-Replayed: true`, and the handler does not run. No key is a
/// 400, a key still being answered is a 409, a key reused on a different
/// request is a 422. A failure is not kept, so a retry after one runs the
/// handler again. `Replays` is any bytes Space with `putIfAbsentFor` — a
/// `nilo_cache` one — provided as a service; `.by` is whose key it is.
pub const Idempotent = @import("typed.zig").Idempotent;
pub const IdempotentOptions = @import("typed.zig").IdempotentOptions;

/// A kept answer served again for a time, as a typed argument that makes
/// a GET say "cache this for a minute" in its signature
/// ([ADR 188](../docs/adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)).
///
/// ```zig
/// const Pages = cache.Space("pages", []const u8, .{ .max_bytes = 64 << 10 });
///
/// fn frontPage(page: nilo.Cached(Pages, .{ .ttl_s = 60 }), db: *sql.Db, c: *nilo.Ctx) !Front
/// ```
///
/// The first request runs the handler and keeps what it returned under the
/// path and query; every request for the same inside `ttl_s` gets that
/// back, with `Cache-Status: nilo; hit`, and the handler does not run. A
/// request that finds the answer still being made waits for it — bounded,
/// and by the route's deadline first — rather than being told 409. A
/// failure is not kept. GET and HEAD only: a write is a Refusal. `Pages`
/// is any bytes Space with `putIfAbsent` and `putFor` — a `nilo_cache` one
/// — provided as a service; `.by` is what the key is made of.
pub const Cached = @import("cached.zig").Cached;
pub const CachedOptions = @import("cached.zig").Options;
pub const CachedBy = @import("cached.zig").By;

/// An HTML form body, read into a struct of yours — the same idea as
/// `Query(T)`, on the body instead of the query string (ADR 030).
///
/// ```zig
/// const SignUp = struct { email: Str, password: Str, avatar: ?nilo.Upload = null };
/// fn signUp(incoming: nilo.Form(SignUp)) !nilo.Redirect(303) { … }
/// ```
///
/// `application/x-www-form-urlencoded` and `multipart/form-data` are both
/// read — which one a browser sends depends on whether the form has a file
/// in it, and that is not something the endpoint should have to know. The
/// whole body is held in memory, bounded by `max_body`; an upload too big
/// for that is `c.bodyStream()`'s.
pub const Form = @import("form.zig").Form;

/// One file out of a multipart form: its bytes, the name the client gave it
/// and the type it claimed. Used as a field type inside a `Form(T)`.
///
/// The filename is whatever the client sent — `../../etc/passwd` included —
/// so it is a label to show, never a path to write to.
pub const Upload = @import("form.zig").Upload;

/// A binding that hands its failures back, instead of ending the request.
///
/// ```zig
/// fn signUp(b: nilo.Bound(nilo.Form(SignUp))) !nilo.Redirect(303) {
///     const form = b.value() orelse return b.fail();
///     …
/// }
/// ```
///
/// Wraps whichever slot it is given: `Bound(Form(T))`, `Bound(Query(T))`, or
/// `Bound(T)` for a JSON body. Without it, one field that will not convert is
/// a 400 and the request is over with nothing saying which field; with it, the
/// handler gets the binding *and* its failures by name and chooses what to
/// answer. `b.fail()` is the shortcut — a 422 naming every field that did not
/// bind — and `b.failures()` is there for a body of your own shape.
///
/// `value()` is optional on purpose: a field that did not bind holds nothing
/// worth reading, and there is no way past that into a half-filled struct.
/// What a form showing itself again wants is `b.given("email")`, the text the
/// person actually typed.
///
/// Nothing is allocated per failed field, and this is not a validation
/// layer — nilo's job stops at "this did not convert to a `u32`", and
/// whether the age is plausible stays yours.
pub const Bound = @import("bound.zig").Bound;

/// A response that sends the client somewhere else, with the status in the
/// type so the API description can name it (ADR 031).
///
/// ```zig
/// fn signUp(incoming: nilo.Form(SignUp)) !nilo.Redirect(303) {
///     return .to("/welcome");
/// }
/// ```
///
/// 303 is the one a form POST wants — it turns the follow-up into a GET, so
/// a reload does not post again. 301 and 308 are permanent, 302 and 307
/// temporary; the pair ending in 7 and 8 keep the method.
pub const Redirect = @import("redirect.zig").Redirect;

/// An answer that is a file on disk, named by the handler and never held in
/// memory (ADR 009).
///
/// ```zig
/// fn invoice(files: *Files, id: u32) !?nilo.FileBody {
///     const name = files.nameOf(id) orelse return null;
///     return .{ .dir = files.dir, .name = name, .content_type = "application/pdf" };
/// }
/// ```
///
/// A return type rather than a call, for `Redirect`'s reason: the signature
/// is the contract, so the generated API description says the endpoint
/// answers with bytes — and the `?` says it answers 404 (ADR 023).
///
/// The file is opened relative to `dir` and never resolved as a path, so a
/// name is checked and then handed to the kernel rather than joined onto
/// anything. A name with a `..` segment, an absolute one, or one with a NUL
/// in it opens nothing and answers 404, the same as a file that is not
/// there. The bytes go from the file to the socket without passing through
/// this process, and `Range`, `If-Range` and `If-None-Match` are answered
/// exactly as they are for a static file.
pub const FileBody = @import("filebody.zig").FileBody;
/// An answer that is bytes already in hand, under a label decided per
/// request — somebody else's download passed on with their `Content-Type`
/// ([ADR 173](../docs/adr/173-bytes-handed-on-are-an-answer.md)).
pub const Bytes = @import("bytebody.zig").Bytes;
pub const Versioned = @import("versioned.zig").Versioned;

/// A directory, opened once and held open — what a Service hands a
/// `FileBody` (ADR 009).
///
/// ```zig
/// const Files = struct { dir: nilo.Dir };
///
/// var files: Files = .{ .dir = try nilo.Dir.open("uploads") };
/// defer files.dir.close();
/// try app.provide(&files);
/// ```
///
/// Opening it is startup work: the path is relative to the working directory
/// the server runs in, and it stays open for as long as whatever holds it.
/// Nothing on the request path resolves a path — a `FileBody` names a file
/// *inside* this directory, and the kernel does the rest.
pub const Dir = @import("bulkhead.zig").Dir;

/// A cookie on the way out: `c.setCookie(.{ .name = "session", .value = t })`
/// (ADR 029). Its defaults are `Secure`, `HttpOnly`, `SameSite=Lax` and
/// `Path=/`, so a plain one is already the careful one.
pub const Cookie = @import("cookie.zig").Cookie;

/// `SameSite`, for a cookie that needs one of the other answers.
pub const SameSite = @import("cookie.zig").SameSite;

/// The session: a struct of yours, sealed into one cookie the client holds.
///
/// ```zig
/// const Signed = struct { user: u32, admin: bool = false };
///
/// fn signIn(s: nilo.Session(Signed)) !nilo.Redirect(303) {
///     try s.set(.{ .user = 7 });
///     return .to("/");
/// }
///
/// fn me(s: nilo.Session(Signed)) !?Profile {
///     const signed = s.get() orelse return null;
///     return profiles.find(signed.user);
/// }
/// ```
///
/// Nothing is kept on the server: the whole thing is encrypted and signed
/// with `XChaCha20Poly1305` and travels in the cookie, so there is no store,
/// no expiry sweep, and nothing added to what an idle connection costs.
/// `listen(.{ .session_secret = … })` is where the key comes from.
///
/// What a session may hold is a fixed-size struct — numbers, bools, enums,
/// `[N]u8`, optionals and nested structs of those. Not slices: a browser
/// drops an oversized cookie silently, so the size has to be settled while
/// compiling.
pub const Session = @import("session.zig").Session;

/// Everything else session: `Options` for `setWith`, `key_len` for the
/// secret, and `max_cookie_bytes`.
pub const session = @import("session.zig");

/// A body field that can tell "not sent" from "sent as null" — what a PATCH
/// needs and `?T` cannot say (ADR 025).
///
/// ```zig
/// const EditTodo = struct { title: nilo.Patch(nilo.Str) = .absent };
///
/// switch (incoming.title) {
///     .absent => {},                  // not mentioned: leave it alone
///     .cleared => todo.title = null,  // sent as null: empty it
///     .value => |v| todo.title = try v.keep(gpa),
/// }
/// ```
pub const Patch = @import("patch.zig").Patch;

pub const Middleware = @import("middleware.zig").Middleware;
pub const Next = @import("middleware.zig").Next;
/// The answer a middleware holds after `next.hold(c)`, to read and change
/// before it is written (ADR 008).
pub const Answer = @import("middleware.zig").Answer;

/// A monotonic clock reading in nanoseconds, for measuring how long
/// something took.
///
/// Zig 0.16's `std.time` carries only constants — no `milliTimestamp`, no
/// `Timer` — and the Engine keeps a clock anyway, so timing a request looks
/// like this rather than like a syscall of your own:
///
/// ```zig
/// fn timing(c: *nilo.Ctx, next: nilo.Next) !void {
///     const started = nilo.monotonicNanos();
///     try next.run(c);
///     const took_us = (nilo.monotonicNanos() - started) / std.time.ns_per_us;
///     std.log.info("{f} took {d}µs", .{ c.path(), took_us });
/// }
/// ```
///
/// Monotonic, so it is the right thing for a duration and the wrong thing
/// for a date: it counts from an arbitrary point, not from the epoch.
pub const monotonicNanos = @import("bulkhead.zig").monotonicNanos;

/// Built-in middleware.
pub const logger = @import("logger.zig");
pub const cors = @import("cors.zig");
/// A request that changes something, taken only from a page this server
/// serves ([ADR 224](../docs/adr/224-a-request-that-changes-something-says-where-it-came-from.md)).
pub const csrf = @import("csrf.zig");
/// The response headers a browser reads as policy, written as one block:
/// `try app.use(nilo.secure.api(.{}))`, or `nilo.secure.pages(.{})` for a
/// server that serves its own front end
/// ([ADR 246](../docs/adr/246-the-headers-a-browser-reads-as-policy-are-one-block.md)).
pub const secure = @import("secure.zig");
pub const metrics = @import("metrics.zig");

/// Tracing: `try app.trace(.{ .service = "orders" })`, and every request is a
/// span sent to an OpenTelemetry receiver. `nilo.trace.Options` is what it
/// takes, and `c.span(name)` opens one of a handler's own
/// ([ADR 247](../docs/adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)).
pub const trace = @import("trace.zig");

/// Gzip every answer worth gzipping, per request, for a client that asked:
/// `try app.compress(.{})`. `nilo.compress.Options` is what it takes
/// ([ADR 211](../docs/adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)).
pub const compress = @import("compress.zig");

/// How many requests one address may make inside a window, and a 429 when it
/// asks for more: `app.useOn("/api", nilo.allowance.with(.{ .per_window = 100,
/// .window_s = 60 }))`. The table is sized while compiling and lives in
/// `.bss`, so it costs no allocation at startup and none per request
/// ([ADR 092](../docs/adr/092-an-allowance-is-a-table-sized-while-compiling.md)).
pub const allowance = @import("allowance.zig");

/// How long a route gets: `app.with(nilo.deadline(2000)).get("/report", …)`.
///
/// Every wait nilo owns — the body, the write, a stream's pieces, a
/// WebSocket's silence — is cut down to it, and a handler doing its own work
/// asks `c.overdue()`. A running handler is not interrupted, and deliberately
/// is not ([ADR 105](../docs/adr/105-a-route-can-say-how-long-it-has.md)).
pub const deadline = @import("deadline.zig").with;

/// How much body a route takes: `app.with(nilo.maxBody(50 << 20)).post("/import", …)`.
///
/// `listen()`'s `max_body` is one number for every route, and an import and
/// a sign-in do not have the same budget. Bounds every read into the arena
/// and not `c.bodyStream()`, which has its own. Handed `&limit`, the address
/// of a `usize` filled before `listen()`, it reads the number from there on
/// each request, for a cap that comes from configuration
/// ([ADR 156](../docs/adr/156-a-route-can-say-how-much-body-it-takes.md)).
pub const maxBody = @import("maxbody.zig").with;

/// Static files, held in memory (ADR 009). Used through `app.static()`;
/// the module itself is here for its `Options`.
/// What an `Accept` header says about one media type: `.named`, `.anything`,
/// `.unsaid` or `.refused`. `nilo.accept.asks(c.header("Accept"), "text/html")`
/// — the reader the single-page fallback decides with
/// ([ADR 087](../docs/adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md)),
/// exported because a handler answering two content types wants the same
/// question answered and there is no reason to make it parse the header again.
pub const accept = @import("accept.zig");

pub const static = @import("static.zig");

/// Which addresses in front of this server may say who the client is —
/// what `listen(.{ .trusted_proxies = … })` is parsed into (ADR 102).
pub const proxies = @import("proxies.zig");

/// The API description, worked out from the handler signatures (ADR 016).
/// Switched on with `app.docs(.{ .title = "…" })`; the module is here for
/// its `Options` and for the `Schema` a test might want to look at.
pub const openapi = @import("openapi.zig");

/// Opt in to a panic message that names the request that was in flight,
/// by putting this in your root source file:
///
/// ```zig
/// pub const panic = nilo.panic;
/// ```
///
/// Zig cannot recover from a panic — the process is going down either way
/// (ADR 007). What this buys is knowing which endpoint took it down, so
/// `panic while handling GET /users/42` replaces a day of guessing.
pub const panic = std.debug.FullPanic(panicNamingRequest);

fn panicNamingRequest(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // If the request is not reachable — outside a request, or a future
    // Engine that clears its task context before the panic handler runs —
    // say nothing rather than guess. A wrong path in a crash log sends you
    // off debugging the wrong endpoint.
    if (fail.inFlight()) |r| {
        if (r.path.len > 0) {
            var buf: [512]u8 = undefined;
            const named = std.fmt.bufPrint(
                &buf,
                "{s} (while handling {s} {s})",
                .{ msg, r.method, r.path },
            ) catch msg;
            std.debug.defaultPanic(named, first_trace_addr);
        }
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

const std = @import("std");

test "a Mutex still works with no Engine under it, so guarded handlers stay testable" {
    var lock: Mutex = .init;
    try lock.lock();
    try std.testing.expect(!lock.tryLock());
    lock.unlock();
    try std.testing.expect(lock.tryLock());
    lock.unlock();
}

fn doubleOrFail(n: u32) !u32 {
    if (n == 0) return fail.badRequest("zero is not a number to double", .{});
    return n * 2;
}

test "blocking runs the call, keeps its errors, and needs no Engine under it" {
    // Outside a server this runs inline, which is the property that keeps a
    // handler using `blocking` testable as an ordinary function (ADR 002).
    try std.testing.expectEqual(@as(u32, 42), try blocking(doubleOrFail, .{21}));
    try std.testing.expectError(error.Failed, blocking(doubleOrFail, .{0}));
}

fn neverRuns(ran: *bool) void {
    ran.* = true;
}

test "spawn with no server says so, rather than starting something nothing owns" {
    // The counterpart of the Mutex test above, and the opposite answer on
    // purpose. A lock with no Engine can do its job alone; a fiber cannot,
    // and there would be nothing to count it or stop it (ADR 028). Better
    // an error the caller can see than work that quietly never happens.
    var ran = false;
    try std.testing.expectError(error.NoServer, spawn(neverRuns, .{&ran}));
    try std.testing.expect(!ran);
}

test "a fail function in spawned work has no request to fail" {
    // Spawned work has no slot of its own, so it falls through to the
    // threadlocal — which is null here and on an executor thread, and is
    // only ever set on a thread-pool worker. If that ever stops being true
    // this keeps passing and ADR 006's leak comes back, so the comments in
    // bulkhead.zig are the real guard; this pins the visible half.
    try std.testing.expect(fail.inFlight() == null);
    try std.testing.expectError(error.Failed, doubleOrFail(0));
}

test "a fail function inside blocking reaches the request that made the call" {
    // The half of ADR 013 that has to be got right: on a real server the
    // call runs on a pool worker, which is not the fiber the failure box is
    // bound to, so `blocking` carries the slot across. Here there is no
    // fiber at all and the fallback stands in for one — enough to hold the
    // wiring, while the cross-thread half is what the server itself proves.
    const bulkhead = @import("bulkhead.zig");

    var in_flight = fail.InFlight{};
    in_flight.startRequest("GET", "/users/9");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    try std.testing.expectError(error.Failed, blocking(doubleOrFail, .{0}));
    try std.testing.expectEqual(@as(u16, 400), in_flight.failure.status);
    try std.testing.expectEqualStrings(
        "zero is not a number to double",
        in_flight.failure.message(),
    );

    // And the slot the call was handed is put back, so it cannot leak into
    // whatever this thread picks up next.
    try std.testing.expect(bulkhead.slot() == @as(*anyopaque, @ptrCast(&in_flight)));
}

test "a Ctx can be erased, and a callback allocates through it into the request" {
    // The half `core/scope.zig` cannot check: `Ctx.arena` and `Ctx.str` take a
    // `*const Ctx`, and the erasure casts a `*anyopaque` back to `*Ctx` — a
    // coercion that either works here or nowhere (ADR 144). Driven through a
    // real request rather than asserted about, because what is being tested is
    // that the memory really is the request's.
    const Reaction = *const fn (scope: *AnyScope, note: []const u8) anyerror![]const u8;
    const react: Reaction = struct {
        fn run(scope: *AnyScope, note: []const u8) anyerror![]const u8 {
            const kept = try scope.arena().dupe(u8, note);
            return scope.str(kept).view();
        }
    }.run;

    const handler = struct {
        fn show(c: *Ctx) anyerror!void {
            var erased = AnyScope.of(c);
            try c.sendText(200, try react(&erased, "through a function pointer"));
        }
    }.show;

    var app = App.init(std.testing.allocator);
    defer app.deinit();
    try app.get("/erased", handler);

    var client = try testing.Client.init(std.testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/erased");
    try std.testing.expectEqual(@as(u16, 200), answer.status);
    try std.testing.expectEqualStrings("through a function pointer", answer.body);
}

test "every type this module exports is named the way the import line names it" {
    // `names` used to hold a hand-kept table of `file.Type` substrings, and it
    // had fallen eleven types behind these exports — `Bound`, `Session`,
    // `FileBody`, `Dir`, `Stream`, `Events`, `Body`, `Socket`, `Room`, `Limits`
    // and `Gate`. Its own doc said a missing type would be noticed in
    // `refusals/` and not one of them was, because a refusal only covers the
    // message somebody thought to write a refusal for.
    //
    // This is the rule instead of the paragraph (ADR 074). It walks what the
    // module actually exports rather than a second list, so a type added to
    // `http.zig` and forgotten fails the suite the day it lands. What it asks
    // has changed with ADR 074: not whether a table matches the type's *name*,
    // which matched the reader's file names too, but whether the type carries
    // `nilo_type_name` and so says what it is called itself.
    //
    // **Non-generic types only.** `Response(T)`, `Session(T)`, `Bound(T)` and
    // the rest are functions until somebody applies them, so there is no type
    // here to ask. Their markers are held by the tests in the files that
    // declare them.
    const naming = @import("names.zig");
    // Exports that are somebody else's type rather than one of nilo's, where
    // giving it a nilo name would be a lie. `panic` is `std.debug.FullPanic`,
    // and `@typeName` spells it `debug.FullPanic(…)` with no `std.` in front,
    // so the prefix test below cannot see it for what it is.
    //
    // `Middleware` is here for a different reason and it is a stated gap:
    // it is `*const fn (*Ctx, Next) anyerror!void`, and a function type cannot
    // hold a declaration, so it cannot carry a name. What it prints instead is
    // its signature, spelled with the files nilo declared `Ctx` and `Next` in.
    const cannot_be_named = [_][]const u8{ "panic", "Middleware", "CtxHandler", "Handler" };
    @setEvalBranchQuota(200_000);
    inline for (comptime std.meta.declarations(@This())) |decl| {
        @setEvalBranchQuota(200_000);
        const value = @field(@This(), decl.name);
        if (@TypeOf(value) != type) continue;
        if (comptime for (cannot_be_named) |skip| {
            if (std.mem.eql(u8, skip, decl.name)) break true;
        } else false) continue;
        // An error set, an enum of somebody else's, a std type re-exported
        // under our name: only what `@typeName` spells with a nilo file in
        // front of it is this rule's business.
        const spelled = @typeName(value);
        if (comptime std.mem.indexOfScalar(u8, spelled, '.') == null) continue;
        if (comptime std.mem.startsWith(u8, spelled, "std.")) continue;
        if (comptime !naming.covers(value)) {
            @compileError(
                "nilo: `nilo." ++ decl.name ++ "` prints as `" ++ spelled ++
                    "` in a compile error, which names a file the reader never imported.\n" ++
                    "  Give it `pub const nilo_type_name = \"nilo." ++ decl.name ++ "\";`.",
            );
        }
    }
}

test "json can be written outside a request by the rules a response is written by" {
    const Alert = struct {
        name: []const u8,
        free: f64,
        host: Str,
        note: ?[]const u8 = null,
    };
    const value: Alert = .{ .name = "disk \"/\"", .free = std.math.inf(f64), .host = Str.static("db-1") };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJson(&out.writer, value);
    const expected = "{\"name\":\"disk \\\"/\\\"\",\"free\":null,\"host\":\"db-1\",\"note\":null}";
    try std.testing.expectEqualStrings(expected, out.written());

    const owned = try jsonAlloc(std.testing.allocator, value);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings(expected, owned);
}

test {
    // Core is not listed here. It is a module of its own now, with a step of
    // its own (ADR 038) — running it from inside the framework's suite would
    // hide the property that step exists to hold: that it passes with nothing
    // above it.
    _ = @import("names.zig");
    _ = @import("patch.zig");
    _ = @import("convert.zig");
    _ = @import("message.zig");
    _ = @import("code.zig");
    _ = @import("connect.zig");
    _ = @import("rpc.zig");
    _ = @import("cookie.zig");
    _ = @import("session.zig");
    _ = @import("password.zig");
    _ = @import("form.zig");
    _ = @import("bound.zig");
    _ = @import("redirect.zig");
    _ = @import("filebody.zig");
    _ = @import("bytebody.zig");
    _ = @import("versioned.zig");
    _ = @import("verified.zig");
    _ = @import("text.zig");
    _ = @import("http1.zig");
    _ = @import("date.zig");
    _ = @import("failurebody.zig");
    _ = @import("bulkhead.zig");
    _ = @import("watchdog.zig");
    _ = @import("engine/zio.zig");
    _ = @import("fuzz.zig");
    _ = @import("json.zig");
    _ = @import("jsonfloat.zig");
    _ = @import("jsonmark.zig");
    _ = @import("scan.zig");
    _ = @import("accept.zig");
    _ = @import("static.zig");
    _ = @import("encoded.zig");
    _ = @import("router.zig");
    _ = @import("url.zig");
    _ = @import("proxies.zig");
    _ = @import("fail.zig");
    _ = @import("service.zig");
    _ = @import("resolve.zig");
    _ = @import("openapi.zig");
    _ = @import("stream.zig");
    _ = @import("framing.zig");
    _ = @import("body.zig");
    _ = @import("range.zig");
    _ = @import("sendfile.zig");
    _ = @import("websocket.zig");
    _ = @import("scratch.zig");
    _ = @import("room.zig");
    _ = @import("rooms.zig");
    _ = @import("handover.zig");
    _ = @import("testing.zig");
    _ = @import("middleware.zig");
    _ = @import("typed.zig");
    _ = @import("within.zig");
    _ = @import("authorization.zig");
    _ = @import("idempotent.zig");
    _ = @import("cached.zig");
    _ = @import("health.zig");
    _ = @import("ctx.zig");
    _ = @import("logger.zig");
    _ = @import("cors.zig");
    _ = @import("csrf.zig");
    _ = @import("secure.zig");
    _ = @import("trace.zig");
    _ = @import("otlp.zig");
    _ = @import("metrics.zig");
    _ = @import("compress.zig");
    _ = @import("allowance.zig");
    _ = @import("deadline.zig");
    _ = @import("maxbody.zig");
    _ = @import("ownbody.zig");
    _ = @import("headers.zig");
    _ = @import("app.zig");
    _ = @import("hpack.zig");
    _ = @import("h2.zig");
    _ = @import("grpc.zig");
    _ = @import("h2conn.zig");
    _ = @import("h2test.zig");
    _ = @import("fuzz_frames.zig");
    _ = @import("serve.zig");
    _ = @import("wiring.zig");
    _ = @import("behaviour.zig");
    // Types and routes far bigger than any handler declares, for the branch
    // quotas (ADR 126).
    _ = @import("wide.zig");
    // Last, and the only one here that stands a real server up. Nothing else
    // in this suite opens a socket at all (ADR 028).
    _ = @import("live.zig");
    // Except this, in a build that has TLS in it: the same server with a
    // certificate, talked to by std's own TLS client (ADR 212). Under a
    // comptime `if` because the file names the option's machinery, which a
    // build without `-Dtls` does not have; the repository's own test root
    // always does (see `wireTls` in build.zig).
    if (@import("nilo_build").tls) _ = @import("tls_live.zig");
    if (@import("nilo_build").http2) _ = @import("grpc_live.zig");
    if (@import("nilo_build").http2 and @import("nilo_build").tls) _ = @import("grpc_tls_live.zig");
}
