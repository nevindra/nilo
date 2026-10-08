//! A route can say "cache this answer for a minute"
//! ([ADR 188](../docs/adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)).
//!
//! ```zig
//! const Pages = cache.Space("pages", []const u8, .{ .max_bytes = 32 << 10 });
//!
//! fn frontPage(page: nilo.Cached(Pages, .{ .ttl_s = 60 }), db: *sql.Db, c: *nilo.Ctx) !Front
//! ```
//!
//! **The cache is as shared as the Space that holds it.** A `cache.Space` is
//! one process's, so two instances keep two copies and can answer the same
//! path differently inside `ttl_s` (ADR 110).
//!
//! The first request runs the handler and keeps what it returned under the
//! path and the query; every request for the same path and query inside
//! `ttl_s` gets that back, byte for byte, with `Cache-Status: nilo; hit` on
//! it, and the handler does not run. It is `Idempotent` with the key made of
//! the request line instead of a header the client sent, on a GET or a HEAD,
//! and with one difference where the two meet: a second request that finds
//! the first still being answered **waits for it** rather than being told
//! 409. A retry too soon is a client bug; twenty browsers asking for the
//! front page in the same hundred milliseconds is Tuesday, and the answer
//! all twenty want is the one being made.
//!
//! **The wait is bounded, and by the request's own deadline first.** It
//! reads again every `poll_ms`, for at most `max_wait_ms` — or half of what
//! `nilo.deadline(ms)` left the route, whichever is less, so a route with a
//! deadline keeps the other half for making its own answer. A request that
//! waits the bound out runs the handler itself and overwrites the marker
//! with what it made; nothing is refused for the server's own tardiness.
//! This is done here rather than in `nilo_cache` because this is the layer
//! with an `Io` to wait on — the cache's lock spins and nothing that waits
//! may go inside it (ADR 109).
//!
//! **What is kept is what the handler returned, whatever the status.** A
//! `Status(404, Missing)` the handler chose is kept and served again; a
//! `fail.notFound(…)` or an error is not, the marker is released, and the
//! next request runs the handler. What the handler answers to `?T` being
//! null — the framework's own 404 — is not kept either, for the same
//! reason a failure is not.
//!
//! **What it costs** is what `Idempotent` costs, on the route that asks and
//! nowhere else: one arena allocation of the Space's `max_bytes` to read a
//! kept answer into, one to encode the answer being kept, and the JSON
//! buffer the handler's answer was going to take anyway — and one more to
//! join the path and the query when there is a query. Nothing on the stack
//! (ADR 062). The allocation-budget test in `app.zig` runs a route with no
//! `Cached` on it and is untouched: a route that did not ask runs the code
//! it ran before.
//!
//! **The record and the marker are `idempotent.zig`'s**, used rather than
//! copied: a kept answer is the same thing in both, and the `in_flight`
//! kind is the claim both make. What differs — the key, the wait, the
//! verb — is here. The Space is yours and this module names no cache:
//! `Pages` is any type with `getInto`, `putIfAbsent`, `putFor`, `del`,
//! `max_bytes` and `Held`, which a `nilo_cache` bytes Space has.

const std = @import("std");
const http1 = @import("http1.zig");
const idempotent = @import("idempotent.zig");
const naming = @import("names.zig");
const str_mod = @import("nilo_core");

const Str = str_mod.Str;

/// The response header that says whether the answer was made for this
/// request or served again, in the words of RFC 9211.
pub const status_name = "Cache-Status";
pub const hit_value = "nilo; hit";
pub const miss_value = "nilo; fwd=miss";

/// How often a request waiting on another's answer reads again.
pub const poll_ms: u32 = 10;
/// The most it waits, on a route with no deadline. A route with one waits
/// at most half of what is left of it.
pub const max_wait_ms: u32 = 2_000;

/// What the key is made of.
pub const By = union(enum) {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.CachedBy";

    /// The path alone. `?page=2` and `?page=3` are one entry, which is
    /// right only when the handler ignores the query.
    path,
    /// The path and the query string as it arrived. `?a=1&b=2` and
    /// `?b=2&a=1` are two entries; nothing is normalised.
    path_and_query,
    /// The path, the query, and one request header's value — the shape
    /// `Vary` names, for a page that answers differently to
    /// `Accept-Language`. A header the request did not send is the empty
    /// value, which is one more entry rather than a miss.
    header: []const u8,
};

/// What `Cached(Pages, …)` takes beside the Space.
pub const Options = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.CachedOptions";

    /// How long a kept answer is served before the handler runs again, in
    /// seconds. No default: the number is the whole of what the argument
    /// says, and zero is a Refusal.
    ttl_s: u32,
    /// What the key is made of. The path and the query, unless said.
    by: By = .path_and_query,
};

/// A kept answer, served again for `ttl_s` — as a typed argument, so the
/// route says it in its signature.
///
/// ```zig
/// fn frontPage(page: nilo.Cached(Pages, .{ .ttl_s = 60 }), db: *sql.Db, c: *nilo.Ctx) !Front
/// ```
///
/// `.key` is what the answer is kept under: the path, or the path, a `?`
/// and the query, or those and the header `by` named after a NUL.
pub fn Cached(comptime Pages: type, comptime options: Options) type {
    return struct {
        pub const nilo_cached = .{ .pages = Pages, .ttl_s = options.ttl_s, .by = options.by };
        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 074).
        pub const nilo_type_name = "nilo.Cached(" ++ naming.of(Pages) ++ ", …)";

        /// What the answer is kept under.
        key: Str,
    };
}

/// The headers that say who is calling. Refused as a key here, and as a
/// `FromHeader` argument beside a `Cached` in `typed.rolesOf`.
pub const credentials = [_][]const u8{ "Cookie", "Authorization", "Proxy-Authorization" };

/// Whether an argument of the handler says who the caller is, which a route
/// whose answer is served to the next caller must not read. An
/// `Authorization`, a `Verified`, a credential `FromHeader`, and a resolved
/// type that declares `pub const nilo_reads_caller = true;`, as
/// `Session(T)` does. A `*Ctx` can read anything and is not refused.
pub fn readsTheCaller(comptime P: type, comptime is_authorization: bool, comptime is_verified: bool) bool {
    comptime {
        if (is_authorization or is_verified) return true;
        switch (@typeInfo(P)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => {},
            else => return false,
        }
        if (@hasDecl(P, "nilo_reads_caller")) return P.nilo_reads_caller;
        if (@hasDecl(P, "nilo_header")) {
            for (credentials) |secret| if (std.ascii.eqlIgnoreCase(P.nilo_header.name, secret)) return true;
        }
        return false;
    }
}

/// Everything the type and its options have to get right, said at the
/// route the way `Idempotent`'s Space check is.
pub fn check(comptime P: type, comptime route: []const u8) void {
    comptime {
        const spec = P.nilo_cached;
        checkSpace(spec.pages, route);
        const who = "the `Cached(" ++ naming.of(spec.pages) ++ ", …)` on route \"" ++ route ++ "\"";
        if (spec.ttl_s == 0) @compileError(
            "nilo: " ++ who ++ " has a `ttl_s` of 0, and an answer kept for no time is a handler that runs every time.\n" ++
                "  Say how long the answer is good for — `.{ .ttl_s = 60 }` — or drop the argument.",
        );
        switch (spec.by) {
            .path, .path_and_query => {},
            .header => |name| {
                if (name.len == 0) @compileError(
                    "nilo: " ++ who ++ " keys its answers on a header and names none.\n" ++
                        "  `.by = .{ .header = \"Accept-Language\" }` is the shape; `.path_and_query` if the answer does not vary by one.",
                );
                for (credentials) |secret| {
                    if (std.ascii.eqlIgnoreCase(name, secret)) @compileError(
                        "nilo: " ++ who ++ " keys its answers on the `" ++ name ++ "` header, and a credential is not a key.\n" ++
                            "  Every caller would get an entry of their own with the secret in it, which is a session store " ++
                            "rather than a cache. Key on what the answer varies by — `Accept-Language` — and answer " ++
                            "per user without the cache.",
                    );
                }
            },
        }
    }
}

/// A Space that can keep an answer for a time of the route's choosing:
/// bytes in, bytes out, a claim, and a `putFor`. Said while compiling, in
/// the words of what is missing.
fn checkSpace(comptime Pages: type, comptime route: []const u8) void {
    comptime {
        const shape = "\n  Give it a `cache.Space` holding `[]const u8`: " ++
            "`const Pages = cache.Space(\"pages\", []const u8, .{ .max_bytes = 32 << 10 });`" ++
            "\n  and `app.provide(&pages)` once it is opened.";
        switch (@typeInfo(Pages)) {
            .@"struct" => {},
            else => @compileError(
                "nilo: the `Cached(" ++ naming.of(Pages) ++ ", …)` on route \"" ++ route ++
                    "\" names " ++ naming.of(Pages) ++ " as where answers are kept, and it is not a Space." ++ shape,
            ),
        }
        const needed = [_][]const u8{ "getInto", "putIfAbsent", "putFor", "del", "max_bytes", "Held" };
        for (needed) |decl| if (!@hasDecl(Pages, decl)) @compileError(
            "nilo: the `Cached(" ++ naming.of(Pages) ++ ", …)` on route \"" ++ route ++
                "\" names " ++ naming.of(Pages) ++ " as where answers are kept, and it has no `" ++
                decl ++ "`, so it is not a Space that holds bytes." ++ shape,
        );
        if (Pages.Held == void) @compileError(
            "nilo: the `Cached(" ++ naming.of(Pages) ++ ", …)` on route \"" ++ route ++
                "\" names a Space that holds a flat value, and a kept answer is bytes." ++ shape,
        );
        if (Pages.max_bytes < 256) @compileError(
            "nilo: the `Cached(" ++ naming.of(Pages) ++ ", …)` on route \"" ++ route ++
                "\" names a Space whose `max_bytes` is " ++ std.fmt.comptimePrint("{d}", .{Pages.max_bytes}) ++
                ", and a kept answer needs room for a status, its headers and a body.\n" ++
                "  256 is the least that is useful; a page usually wants a few thousand.",
        );
    }
}

/// What `typed.cachedBegin` hands the rest of the request; the claim, the
/// wait and the put live there beside `idempotentBegin`, so that this file
/// names nothing in the App's core (see `http_core` in build.zig).
pub const Begun = struct {
    key: Str,
    /// The Space's key: what `By` said, joined.
    under: []const u8,
    fingerprint: u64,
    /// False when nothing can be kept under this key — one too long for
    /// the Space — so the answer goes out and is not put.
    keep: bool = true,
};

pub const Outcome = union(enum) { replayed, fresh: Begun };

/// What the record carries beside the answer: a hash of the key, so bytes
/// that were never this key's record are a miss rather than an answer.
pub fn fingerprintOf(key: []const u8) u64 {
    return std.hash.Wyhash.hash(0x1d4, key);
}

/// Whether a `Cached(…)` may sit on a route with this verb: a read, and
/// nothing that writes. A kept answer is served to whoever asks next, and
/// the request the second client sent was not the one the first sent — the
/// body, the account, the order placed. `app.post` says this while
/// compiling; `app.route(method, …)` says it when the route is registered.
pub fn allows(method: http1.Method) bool {
    return method == .GET or method == .HEAD;
}

// ---- tests ----

const testing = std.testing;

/// The shape `Cached` asks of a Space, over a map with a clock of its own:
/// what `nilo_cache`'s bytes Space has, written here because `http/`
/// names no cache — and because the real one's clock is the kernel's,
/// which a test cannot move. `now_s` is this one's, and a test moves it.
/// Locked, because the stampede test reaches it from a second thread; a
/// spin, the way the real one's is, since a plain thread has no `Io` for
/// `std.Io.Mutex` to wait on.
const FakePages = struct {
    pub const Held = [max_bytes]u8;
    pub const max_bytes: usize = 4096;

    const Entry = struct { value: []const u8, expires_s: ?i64 };

    const Lock = struct {
        held: std.atomic.Value(bool) = .init(false),

        fn lock(l: *Lock) void {
            while (l.held.swap(true, .acquire)) std.atomic.spinLoopHint();
        }

        fn unlock(l: *Lock) void {
            l.held.store(false, .release);
        }
    };

    map: std.StringHashMap(Entry),
    gpa: std.mem.Allocator,
    now_s: i64 = 1_000,
    lock: Lock = .{},

    fn init(gpa: std.mem.Allocator) FakePages {
        return .{ .map = .init(gpa), .gpa = gpa };
    }

    fn deinit(self: *FakePages) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.value);
        }
        self.map.deinit();
    }

    fn live(self: *FakePages, e: Entry) bool {
        const until = e.expires_s orelse return true;
        return self.now_s < until;
    }

    pub fn getInto(self: *FakePages, key: []const u8, out: []u8) ?[]const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        const e = self.map.get(key) orelse return null;
        if (!self.live(e)) return null;
        if (e.value.len > out.len) return null;
        @memcpy(out[0..e.value.len], e.value);
        return out[0..e.value.len];
    }

    pub fn putIfAbsent(self: *FakePages, key: []const u8, value: []const u8) error{TooLarge}!bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.map.get(key)) |e| if (self.live(e)) return false;
        try self.write(key, value, null);
        return true;
    }

    pub fn putFor(self: *FakePages, key: []const u8, value: []const u8, ttl_s: u32) error{TooLarge}!void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.write(key, value, if (ttl_s == 0) null else self.now_s + ttl_s);
    }

    fn write(self: *FakePages, key: []const u8, value: []const u8, expires_s: ?i64) error{TooLarge}!void {
        if (value.len > max_bytes or key.len > 512) return error.TooLarge;
        const k = self.gpa.dupe(u8, key) catch return error.TooLarge;
        const v = self.gpa.dupe(u8, value) catch return error.TooLarge;
        if (self.map.fetchRemove(k)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value.value);
        }
        self.map.put(k, .{ .value = v, .expires_s = expires_s }) catch return error.TooLarge;
    }

    pub fn del(self: *FakePages, key: []const u8) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const old = self.map.fetchRemove(key) orelse return false;
        self.gpa.free(old.key);
        self.gpa.free(old.value.value);
        return true;
    }

    fn has(self: *FakePages, key: []const u8) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const e = self.map.get(key) orelse return false;
        return self.live(e);
    }
};

const Renders = struct { count: u32 = 0 };
const Page = struct { id: u32, served: u32 };

fn showPage(page: Cached(FakePages, .{ .ttl_s = 60 }), id: u32, renders: *Renders) !typed.Response(Page) {
    _ = page;
    if (id == 0) return fail.unprocessable("there is no page 0", .{});
    renders.count += 1;
    return .{
        .value = .{ .id = id, .served = renders.count },
        .headers = .of(&.{.{ .name = "X-Page-Version", .value = "v1" }}),
    };
}

fn showByLanguage(page: Cached(FakePages, .{ .ttl_s = 60, .by = .{ .header = "Accept-Language" } }), renders: *Renders) !Page {
    _ = page;
    renders.count += 1;
    return .{ .id = 1, .served = renders.count };
}

fn showByPath(page: Cached(FakePages, .{ .ttl_s = 60, .by = .path }), renders: *Renders) !Page {
    _ = page;
    renders.count += 1;
    return .{ .id = 1, .served = renders.count };
}

fn showWithCookie(page: Cached(FakePages, .{ .ttl_s = 60 }), renders: *Renders) typed.Response(Page) {
    _ = page;
    renders.count += 1;
    return .{
        .value = .{ .id = 1, .served = renders.count },
        .headers = .of(&.{ .{ .name = "Set-Cookie", .value = "sid=first; Path=/" }, .{ .name = "X-Page-Version", .value = "v1" } }),
    };
}

const Fixture = struct {
    pages: FakePages,
    renders: Renders = .{},
    app: App,
    client: nilo_testing.Client,

    fn init() !Fixture {
        return .{
            .pages = FakePages.init(testing.allocator),
            .app = App.init(testing.allocator),
            .client = try nilo_testing.Client.init(testing.allocator, .{}),
        };
    }

    /// Provide both services once the struct is where it will stay.
    fn wire(self: *Fixture) !void {
        try self.app.provide(&self.pages);
        try self.app.provide(&self.renders);
    }

    fn deinit(self: *Fixture) void {
        self.client.deinit();
        self.app.deinit();
        self.pages.deinit();
    }
};

test "a fresh answer is served and kept, and the next request within the TTL is the same bytes without the handler running" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/pages/:id", showPage);

    const first = try f.client.get(&f.app, "/pages/7");
    try testing.expectEqual(@as(u16, 200), first.status);
    try testing.expectEqualStrings(miss_value, first.header(status_name).?);
    try testing.expectEqualStrings("v1", first.header("X-Page-Version").?);
    try testing.expectEqualStrings("{\"id\":7,\"served\":1}", first.body);
    try testing.expectEqual(@as(u32, 1), f.renders.count);
    // The client's buffer is written over by the next request, so the
    // first body is kept aside to compare byte for byte.
    const kept = try testing.allocator.dupe(u8, first.body);
    defer testing.allocator.free(kept);

    const again = try f.client.get(&f.app, "/pages/7");
    try testing.expectEqual(@as(u16, 200), again.status);
    try testing.expectEqualStrings(hit_value, again.header(status_name).?);
    try testing.expectEqualStrings("v1", again.header("X-Page-Version").?);
    try testing.expectEqualStrings("application/json", again.header("Content-Type").?);
    try testing.expectEqualStrings(kept, again.body);
    try testing.expectEqual(@as(u32, 1), f.renders.count);

    // The handler received the key the answer went under.
    try testing.expect(f.pages.has("/pages/7"));
}

// Below the first test on purpose: an import of the App's core is a test's
// here, and `zig build layering` reads it as one only past this line.
const App = @import("app.zig").App;
const nilo_testing = @import("testing.zig");
const deadline = @import("deadline.zig");
const typed = @import("typed.zig");
const fail = @import("fail.zig");
const Ctx = @import("ctx.zig").Ctx;

fn showSettingCookie(page: Cached(FakePages, .{ .ttl_s = 60 }), renders: *Renders, c: *Ctx) !Page {
    _ = page;
    renders.count += 1;
    try c.setCookie(.{ .name = "sid", .value = "first" });
    return .{ .id = 1, .served = renders.count };
}

test "a different query string is a different entry, and the path with no query is a third" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/pages/:id", showPage);

    _ = try f.client.get(&f.app, "/pages/7?lang=id");
    _ = try f.client.get(&f.app, "/pages/7?lang=en");
    _ = try f.client.get(&f.app, "/pages/7");
    try testing.expectEqual(@as(u32, 3), f.renders.count);

    const id_again = try f.client.get(&f.app, "/pages/7?lang=id");
    try testing.expectEqualStrings(hit_value, id_again.header(status_name).?);
    try testing.expectEqualStrings("{\"id\":7,\"served\":1}", id_again.body);
    try testing.expectEqual(@as(u32, 3), f.renders.count);
    try testing.expect(f.pages.has("/pages/7?lang=id"));
    try testing.expect(f.pages.has("/pages/7?lang=en"));
    try testing.expect(f.pages.has("/pages/7"));
}

test "after the TTL the handler runs again and the new answer is the one kept" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/pages/:id", showPage);

    _ = try f.client.get(&f.app, "/pages/7");
    f.pages.now_s += 59;
    const inside = try f.client.get(&f.app, "/pages/7");
    try testing.expectEqualStrings(hit_value, inside.header(status_name).?);
    try testing.expectEqual(@as(u32, 1), f.renders.count);

    f.pages.now_s += 2;
    const after = try f.client.get(&f.app, "/pages/7");
    try testing.expectEqualStrings(miss_value, after.header(status_name).?);
    try testing.expectEqualStrings("{\"id\":7,\"served\":2}", after.body);
    try testing.expectEqual(@as(u32, 2), f.renders.count);

    const kept_afresh = try f.client.get(&f.app, "/pages/7");
    try testing.expectEqualStrings(hit_value, kept_afresh.header(status_name).?);
    try testing.expectEqualStrings("{\"id\":7,\"served\":2}", kept_afresh.body);
}

test "what the handler failed with is not kept, and the next request runs it again" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/pages/:id", showPage);

    const refused = try f.client.get(&f.app, "/pages/0");
    try testing.expectEqual(@as(u16, 422), refused.status);
    try testing.expect(refused.header(status_name) == null);
    try testing.expect(!f.pages.has("/pages/0"));

    // Not a hit and not a waiter: the marker went with the failure.
    const refused_again = try f.client.get(&f.app, "/pages/0");
    try testing.expectEqual(@as(u16, 422), refused_again.status);
    try testing.expectEqual(@as(u32, 0), f.renders.count);
}

test "a request that finds the answer still being made waits for it, and gets it" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/pages/:id", showPage);

    // Somebody else's request is in flight: its marker is under the key.
    const under = "/pages/7";
    _ = try f.pages.putIfAbsent(under, &idempotent.marker(fingerprintOf(under)));

    // Their answer lands a little later, from another thread — the way a
    // second fiber's would.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const record = try idempotent.encode(arena.allocator(), .json, 200, fingerprintOf(under), &.{}, &.{}, "", "{\"id\":7,\"served\":99}");
    const Lander = struct {
        fn land(pages: *FakePages, bytes: []const u8) void {
            // A plain thread sleeps through an `Io` of its own; 0.16 has no
            // `std.Thread.sleep`.
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            std.Io.sleep(threaded.io(), .fromMilliseconds(40), .awake) catch {};
            pages.putFor("/pages/7", bytes, 60) catch unreachable;
        }
    };
    const t = try std.Thread.spawn(.{}, Lander.land, .{ &f.pages, record });

    const waited = try f.client.get(&f.app, "/pages/7");
    t.join();
    try testing.expectEqual(@as(u16, 200), waited.status);
    try testing.expectEqualStrings(hit_value, waited.header(status_name).?);
    try testing.expectEqualStrings("{\"id\":7,\"served\":99}", waited.body);
    // The handler here never ran: the answer was theirs.
    try testing.expectEqual(@as(u32, 0), f.renders.count);
}

test "a request that waits the bound out runs the handler itself rather than being told 409" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    // A deadline is what bounds the wait: half of 200ms, rather than the
    // two seconds a route with none would wait.
    try f.app.with(deadline.with(200)).get("/pages/:id", showPage);

    const under = "/pages/7";
    _ = try f.pages.putIfAbsent(under, &idempotent.marker(fingerprintOf(under)));

    const made = try f.client.get(&f.app, "/pages/7");
    try testing.expectEqual(@as(u16, 200), made.status);
    try testing.expectEqualStrings(miss_value, made.header(status_name).?);
    try testing.expectEqualStrings("{\"id\":7,\"served\":1}", made.body);
    try testing.expectEqual(@as(u32, 1), f.renders.count);

    // And what it made is what is kept now, in place of the marker.
    const next = try f.client.get(&f.app, "/pages/7");
    try testing.expectEqualStrings(hit_value, next.header(status_name).?);
    try testing.expectEqual(@as(u32, 1), f.renders.count);
}

test "a key made of a header varies the answer by that header" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/front", showByLanguage);

    const id = try f.client.sendRequest(&f.app, .{ .path = "/front", .headers = &.{.{ .name = "Accept-Language", .value = "id" }} });
    try testing.expectEqualStrings("{\"id\":1,\"served\":1}", id.body);
    const en = try f.client.sendRequest(&f.app, .{ .path = "/front", .headers = &.{.{ .name = "Accept-Language", .value = "en" }} });
    try testing.expectEqualStrings("{\"id\":1,\"served\":2}", en.body);
    // No header is an entry of its own, not a miss every time.
    _ = try f.client.get(&f.app, "/front");
    _ = try f.client.get(&f.app, "/front");
    try testing.expectEqual(@as(u32, 3), f.renders.count);

    const id_again = try f.client.sendRequest(&f.app, .{ .path = "/front", .headers = &.{.{ .name = "Accept-Language", .value = "id" }} });
    try testing.expectEqualStrings(hit_value, id_again.header(status_name).?);
    try testing.expectEqualStrings("{\"id\":1,\"served\":1}", id_again.body);
    try testing.expectEqual(@as(u32, 3), f.renders.count);
}

test "a key made of the path alone answers every query string with one entry" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/front", showByPath);

    _ = try f.client.get(&f.app, "/front?page=2");
    const other = try f.client.get(&f.app, "/front?page=3");
    try testing.expectEqualStrings(hit_value, other.header(status_name).?);
    try testing.expectEqual(@as(u32, 1), f.renders.count);
    try testing.expect(f.pages.has("/front"));
}

test "a Cached route is a read: a GET or a HEAD, and every verb that writes is refused" {
    // `app.post` refuses it while compiling; `app.route(.POST, …)` cannot,
    // and logs an error and returns `error.CachedWrite` instead — which
    // the test runner counts as a failure, so what is asserted here is
    // the rule it applies.
    try testing.expect(typed.isCached("/pages/:id", showPage));
    try testing.expect(!typed.isCached("/pages/:id", struct {
        fn plain(id: u32) u32 {
            return id;
        }
    }.plain));
    try testing.expect(allows(.GET));
    try testing.expect(allows(.HEAD));
    try testing.expect(!allows(.POST));
    try testing.expect(!allows(.PUT));
    try testing.expect(!allows(.PATCH));
    try testing.expect(!allows(.DELETE));
    try testing.expect(!allows(.OPTIONS));

    // And a HEAD registers, taking the same entry a GET would.
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.head("/pages/:id", showPage);
}

test "the Space is a service the route needs, so listen() refuses a missing one by name" {
    // `checkServices` logs an error naming it, which the test runner counts
    // as a failure, so what is asserted is the requirement it reads.
    const needs = comptime typed.requirements("/pages/:id", showPage);
    var named = false;
    for (needs) |r| {
        if (std.mem.eql(u8, r.type_name, @typeName(FakePages))) {
            try testing.expect(r.needs_mutable);
            try testing.expectEqualStrings("/pages/:id", r.route);
            named = true;
        }
    }
    try testing.expect(named);
}

test "an answer that sets a cookie is sent and not kept, so no visitor is handed another's" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/front", showWithCookie);

    const first = try f.client.get(&f.app, "/front");
    try testing.expectEqualStrings("sid=first; Path=/", first.header("Set-Cookie").?);
    try testing.expect(!f.pages.has("/front"));

    // Not a hit: the handler ran again, and made its own cookie.
    const second = try f.client.get(&f.app, "/front");
    try testing.expect(second.header(status_name) == null or !std.mem.eql(u8, second.header(status_name).?, hit_value));
    try testing.expectEqualStrings("sid=first; Path=/", second.header("Set-Cookie").?);
    try testing.expectEqual(@as(u32, 2), f.renders.count);
}

test "a cookie set through the Ctx during a cached handler is not kept" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/front", showSettingCookie);

    const first = try f.client.get(&f.app, "/front");
    try testing.expect(first.header("Set-Cookie") != null);

    const hit = try f.client.get(&f.app, "/front");
    try testing.expectEqualStrings(hit_value, hit.header(status_name).?);
    try testing.expect(hit.header("Set-Cookie") == null);
    try testing.expectEqual(@as(u32, 1), f.renders.count);
}

fn showWithBadHeader(page: Cached(FakePages, .{ .ttl_s = 60 }), renders: *Renders) typed.Response(Page) {
    _ = page;
    renders.count += 1;
    return .{
        .value = .{ .id = 1, .served = renders.count },
        .headers = .of(&.{.{ .name = "X-Page-Version", .value = "v1\r\nX-Injected: yes" }}),
    };
}

test "an answer whose header setHeader refuses is not kept, so the handler runs again rather than a 500 being replayed" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.wire();
    try f.app.get("/front", showWithBadHeader);

    for (0..2) |_| {
        const answer = try f.client.get(&f.app, "/front");
        try testing.expectEqual(@as(u16, 500), answer.status);
        try testing.expect(answer.header(status_name) == null or !std.mem.eql(u8, answer.header(status_name).?, hit_value));
    }
    try testing.expectEqual(@as(u32, 2), f.renders.count);
    try testing.expect(!f.pages.has("/front"));
}
