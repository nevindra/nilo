//! zfast — an HTTP framework for Zig that puts writing code first. Its
//! vocabulary is in CONTEXT.md, its design decisions in docs/adr/.

pub const App = @import("app.zig").App;

/// What `app.group("/api/v1")` hands back: one prefix and everything
/// registered beneath it. Named here so a plugin can spell out the type it
/// takes instead of using `anytype`.
pub const Group = @import("app.zig").Group;

pub const Ctx = @import("ctx.zig").Ctx;
pub const Str = @import("str.zig").Str;
pub const Method = @import("http1.zig").Method;
pub const Options = @import("bulkhead.zig").Options;

/// One of the two root-file lines, and the one that keeps `std.log` from
/// blocking the event loop:
///
/// ```zig
/// pub const std_options_debug_io = zfast.debug_io;
/// ```
///
/// Note which is which — `debug_io` goes into `std_options_debug_io`, and
/// `std_options` below goes into `std_options`. The two are easy to write
/// the wrong way round, and each fixes a different symptom.
///
/// `listen()` says so at startup if it is missing, because the symptom
/// otherwise is a server that is merely slow.
pub const debug_io = @import("bulkhead.zig").debug_io;

/// The other half of the wiring: `pub const std_options = zfast.std_options;`
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
///     .log_scope_levels = zfast.std_options.log_scope_levels,
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
///     lock: zfast.Mutex = .init,
///     users: std.ArrayList(User) = .empty,
/// };
///
/// try store.lock.lock();
/// defer store.lock.unlock();
/// ```
pub const Mutex = @import("bulkhead.zig").Mutex;

/// Somewhere to put work that is not a request: a fiber of its own, owned
/// by the server rather than by whatever started it (ADR 0029).
///
/// ```zig
/// try zfast.spawn(flushMetrics, .{&exporter});
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

/// Run a blocking call without stopping the thread it is on.
///
/// Many requests share one OS thread, so a handler that blocks stops all of
/// them — a database driver, `std.fs`, `std.http.Client`, anything that
/// waits on a syscall. Hand it to this instead and only the one request
/// waits (ADR 0014):
///
/// ```zig
/// fn getUser(db: *Db, id: u32) !User {
///     return zfast.blocking(Db.query, .{ db, id });
/// }
/// ```
///
/// The return value is whatever the function returns, errors included. It
/// allocates nothing, and outside a running server it simply calls the
/// function — so a handler using it is still testable as an ordinary
/// function (ADR 0003).
pub const blocking = @import("bulkhead.zig").blocking;

/// Wait, without stopping the thread. `std.Thread.sleep` would park every
/// other request sharing it; this parks only this one.
///
/// Fails with `error.Canceled` if the request went away while waiting,
/// which maps to a 503 the way `Mutex.lock` does.
pub const sleep = @import("bulkhead.zig").sleep;

/// Fail functions — `fail.notFound("no user {d}", .{id})` and friends,
/// callable from anywhere (ADR 0005).
pub const fail = @import("fail.zig");

/// A response whose status the handler picks while it runs, headers of its
/// own, or both: `Response(User){ .status = 201, .headers = …, .value = user }`.
///
/// `Response(void)` is an empty one — `.{ .status = 204 }` after a DELETE.
///
/// The status being a runtime field is why the API description can only
/// write `default` for one of these. Where the status is part of the
/// contract rather than a decision, `Status` below says so (ADR 0024).
pub const Response = @import("typed.zig").Response;

/// A response whose status is part of the signature, so the API description
/// can name it: `Status(201, User)`, `Status(204, void)` (ADR 0024).
///
/// ```zig
/// fn createUser(incoming: NewUser) !zfast.Status(201, User) {
///     return .{ .value = made };
/// }
/// ```
pub const Status = @import("typed.zig").Status;

/// One response header, as `Response.headers` takes them.
pub const Header = @import("typed.zig").Header;

/// The headers a `Response` carries, held by value: `.headers = .of(&.{…})`.
/// Copying is the point — a list written in a handler dies with the handler
/// (ADR 0019).
pub const Headers = @import("typed.zig").Headers;

/// A response written in pieces, from `c.stream(status, content_type)` —
/// for a body whose length nobody knows when the head goes out (ADR 0020).
pub const Stream = @import("stream.zig").Stream;

/// A stream of server-sent events, from `c.events()`.
pub const Events = @import("stream.zig").Events;

/// A request body read in pieces, from `c.bodyStream()` — for the ones too
/// big to hold in the request arena (ADR 0020).
pub const Body = @import("body.zig").Body;

/// An open WebSocket connection, from `c.upgrade()` (ADR 0022).
pub const Socket = @import("websocket.zig").Socket;

/// Everything else WebSocket: `Message`, `Kind`, `Close`, `Options`.
pub const websocket = @import("websocket.zig");

/// Saying something to sockets a handler does not hold. Provide one as a
/// service, `join` on the way in, `defer leave` on the way out, and `say`
/// reaches everybody in it.
pub const Room = @import("room.zig").Room;

/// Everything else Room: `Options`, `Full`, `Ticket`.
pub const room = @import("room.zig");

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
/// fn search(params: zfast.Query(Search)) ![]const Item { … }
/// ```
pub const Query = @import("typed.zig").Query;

/// An HTML form body, read into a struct of yours — the same idea as
/// `Query(T)`, on the body instead of the query string (ADR 0031).
///
/// ```zig
/// const SignUp = struct { email: Str, password: Str, avatar: ?zfast.Upload = null };
/// fn signUp(incoming: zfast.Form(SignUp)) !zfast.Redirect(303) { … }
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
/// fn signUp(b: zfast.Bound(zfast.Form(SignUp))) !zfast.Redirect(303) {
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
/// layer — zfast's job stops at "this did not convert to a `u32`", and
/// whether the age is plausible stays yours.
pub const Bound = @import("bound.zig").Bound;

/// A response that sends the client somewhere else, with the status in the
/// type so the API description can name it (ADR 0032).
///
/// ```zig
/// fn signUp(incoming: zfast.Form(SignUp)) !zfast.Redirect(303) {
///     return .to("/welcome");
/// }
/// ```
///
/// 303 is the one a form POST wants — it turns the follow-up into a GET, so
/// a reload does not post again. 301 and 308 are permanent, 302 and 307
/// temporary; the pair ending in 7 and 8 keep the method.
pub const Redirect = @import("redirect.zig").Redirect;

/// An answer that is a file on disk, named by the handler and never held in
/// memory (ADR 0037).
///
/// ```zig
/// fn invoice(files: *Files, id: u32) !?zfast.FileBody {
///     const name = files.nameOf(id) orelse return null;
///     return .{ .dir = files.dir, .name = name, .content_type = "application/pdf" };
/// }
/// ```
///
/// A return type rather than a call, for `Redirect`'s reason: the signature
/// is the contract, so the generated API description says the endpoint
/// answers with bytes — and the `?` says it answers 404 (ADR 0024).
///
/// The file is opened relative to `dir` and never resolved as a path, so a
/// name is checked and then handed to the kernel rather than joined onto
/// anything. A name with a `..` segment, an absolute one, or one with a NUL
/// in it opens nothing and answers 404, the same as a file that is not
/// there. The bytes go from the file to the socket without passing through
/// this process, and `Range`, `If-Range` and `If-None-Match` are answered
/// exactly as they are for a static file.
pub const FileBody = @import("filebody.zig").FileBody;

/// A directory, opened once and held open — what a Service hands a
/// `FileBody` (ADR 0037).
///
/// ```zig
/// const Files = struct { dir: zfast.Dir };
///
/// var files: Files = .{ .dir = try zfast.Dir.open("uploads") };
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
/// (ADR 0030). Its defaults are `Secure`, `HttpOnly`, `SameSite=Lax` and
/// `Path=/`, so a plain one is already the careful one.
pub const Cookie = @import("cookie.zig").Cookie;

/// `SameSite`, for a cookie that needs one of the other answers.
pub const SameSite = @import("cookie.zig").SameSite;

/// The session: a struct of yours, sealed into one cookie the client holds.
///
/// ```zig
/// const Signed = struct { user: u32, admin: bool = false };
///
/// fn signIn(s: zfast.Session(Signed)) !zfast.Redirect(303) {
///     try s.set(.{ .user = 7 });
///     return .to("/");
/// }
///
/// fn me(s: zfast.Session(Signed)) !?Profile {
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
/// needs and `?T` cannot say (ADR 0026).
///
/// ```zig
/// const EditTodo = struct { title: zfast.Patch(zfast.Str) = .absent };
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

/// A monotonic clock reading in nanoseconds, for measuring how long
/// something took.
///
/// Zig 0.16's `std.time` carries only constants — no `milliTimestamp`, no
/// `Timer` — and the Engine keeps a clock anyway, so timing a request looks
/// like this rather than like a syscall of your own:
///
/// ```zig
/// fn timing(c: *zfast.Ctx, next: zfast.Next) !void {
///     const started = zfast.monotonicNanos();
///     try next.run(c);
///     const took_us = (zfast.monotonicNanos() - started) / std.time.ns_per_us;
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

/// Static files, held in memory (ADR 0010). Used through `app.static()`;
/// the module itself is here for its `Options`.
pub const static = @import("static.zig");

/// The API description, worked out from the handler signatures (ADR 0017).
/// Switched on with `app.docs(.{ .title = "…" })`; the module is here for
/// its `Options` and for the `Schema` a test might want to look at.
pub const openapi = @import("openapi.zig");

/// Opt in to a panic message that names the request that was in flight,
/// by putting this in your root source file:
///
/// ```zig
/// pub const panic = zfast.panic;
/// ```
///
/// Zig cannot recover from a panic — the process is going down either way
/// (ADR 0008). What this buys is knowing which endpoint took it down, so
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
    // handler using `blocking` testable as an ordinary function (ADR 0003).
    try std.testing.expectEqual(@as(u32, 42), try blocking(doubleOrFail, .{21}));
    try std.testing.expectError(error.Failed, blocking(doubleOrFail, .{0}));
}

fn neverRuns(ran: *bool) void {
    ran.* = true;
}

test "spawn with no server says so, rather than starting something nothing owns" {
    // The counterpart of the Mutex test above, and the opposite answer on
    // purpose. A lock with no Engine can do its job alone; a fiber cannot,
    // and there would be nothing to count it or stop it (ADR 0029). Better
    // an error the caller can see than work that quietly never happens.
    var ran = false;
    try std.testing.expectError(error.NoServer, spawn(neverRuns, .{&ran}));
    try std.testing.expect(!ran);
}

test "a fail function in spawned work has no request to fail" {
    // Spawned work has no slot of its own, so it falls through to the
    // threadlocal — which is null here and on an executor thread, and is
    // only ever set on a thread-pool worker. If that ever stops being true
    // this keeps passing and ADR 0007's leak comes back, so the comments in
    // bulkhead.zig are the real guard; this pins the visible half.
    try std.testing.expect(fail.inFlight() == null);
    try std.testing.expectError(error.Failed, doubleOrFail(0));
}

test "a fail function inside blocking reaches the request that made the call" {
    // The half of ADR 0014 that has to be got right: on a real server the
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

test {
    _ = @import("str.zig");
    _ = @import("names.zig");
    _ = @import("patch.zig");
    _ = @import("percent.zig");
    _ = @import("convert.zig");
    _ = @import("cookie.zig");
    _ = @import("session.zig");
    _ = @import("form.zig");
    _ = @import("bound.zig");
    _ = @import("redirect.zig");
    _ = @import("filebody.zig");
    _ = @import("http1.zig");
    _ = @import("bulkhead.zig");
    _ = @import("watchdog.zig");
    _ = @import("engine/zio.zig");
    _ = @import("fuzz.zig");
    _ = @import("json.zig");
    _ = @import("scan.zig");
    _ = @import("static.zig");
    _ = @import("router.zig");
    _ = @import("fail.zig");
    _ = @import("service.zig");
    _ = @import("resolve.zig");
    _ = @import("openapi.zig");
    _ = @import("stream.zig");
    _ = @import("body.zig");
    _ = @import("range.zig");
    _ = @import("sendfile.zig");
    _ = @import("websocket.zig");
    _ = @import("room.zig");
    _ = @import("testing.zig");
    _ = @import("middleware.zig");
    _ = @import("typed.zig");
    _ = @import("ctx.zig");
    _ = @import("logger.zig");
    _ = @import("cors.zig");
    _ = @import("app.zig");
}
