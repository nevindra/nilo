//! A request answered once is answered the same way again
//! ([ADR 0193](../docs/adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)).
//!
//! ```zig
//! const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });
//!
//! fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder, db: *sql.Db, c: *nilo.Ctx) !nilo.Status(201, Order)
//! ```
//!
//! The client sends `Idempotency-Key: <something it made up>` and retries
//! with the same key until it gets an answer. The first request runs the
//! handler and keeps what it answered; every later one with that key gets
//! the kept answer back, byte for byte, with `Idempotent-Replayed: true` on
//! it — the handler does not run, the row is not inserted twice, the card is
//! not charged twice. That is the whole of what a payment API, an order API
//! and a webhook receiver want from the header, and it is the shape
//! Stripe, Adyen and the IETF draft all converge on.
//!
//! **Three refusals nilo writes before the handler runs**, each with the
//! header named:
//!
//! - 400 — no `Idempotency-Key`, or one longer than 255 bytes.
//! - 409 — the same key is still being answered. Two requests with one key
//!   in flight at once is a client retrying too soon, and the second one
//!   waits by asking again.
//! - 422 — the same key on a *different* request: another body, path or
//!   method. A key reused with a new payload is a client bug, and answering
//!   the old response to it would be the wrong order shipped.
//!
//! **What is kept is what the handler returned, not what it failed with.**
//! A `Status(201, Order)`, a `Response(T)` with its own headers, a
//! `Status(409, Problem)` — kept, whatever the status. A `fail.conflict(…)`
//! or an error is not: the marker is dropped and the next retry runs the
//! handler again, which is what a retry after a failure is for.
//!
//! **What it costs.** On the route that asks, and nowhere else: one arena
//! allocation of the Space's `max_bytes` to read a kept answer into, one to
//! encode the answer being kept, and the JSON buffer the handler's answer
//! was going to take anyway. Two cache writes and one read per fresh
//! request; one read per replay. Nothing on the stack — a `Held` there would
//! be `max_bytes` per idle connection for the life of it (ADR 0063).
//!
//! **The Space is yours** and this module names no cache: `Replays` is any
//! type with `getInto`, `putIfAbsent`, `put`, `del` and `max_bytes`, which
//! a `nilo_cache` bytes Space has and a table over Redis could. `by` is
//! whose key it is — an account, a tenant — because two clients choosing
//! the same key must never see each other's answer; leave it off only on an
//! endpoint with one caller.

const std = @import("std");
const http1 = @import("http1.zig");
const naming = @import("names.zig");

pub const header_name = "Idempotency-Key";
pub const replayed_name = "Idempotent-Replayed";
/// The longest key taken. The draft suggests a UUID; this is room for one
/// with a prefix on it and refuses a body-length string somebody pasted in.
pub const max_key = 255;

/// How a kept answer is shaped, and the marker a request in flight leaves.
pub const Kind = enum(u8) {
    in_flight = 0,
    empty = 1,
    text = 2,
    json = 3,

    pub fn contentType(self: Kind) []const u8 {
        return switch (self) {
            .in_flight, .empty => "",
            .text => "text/plain",
            .json => "application/json",
        };
    }
};

/// A kept answer, decoded. `headers` is the handler's own — a `Location`
/// on a 201 — and not the ones middleware set, which set themselves again
/// on the replay.
pub const Record = struct {
    kind: Kind,
    status: u16,
    fingerprint: u64,
    headers: []const u8,
    body: []const u8,

    pub fn eachHeader(self: Record) HeaderIterator {
        return .{ .rest = self.headers };
    }
};

pub const HeaderIterator = struct {
    rest: []const u8,

    pub fn next(self: *HeaderIterator) ?http1.Header {
        if (self.rest.len < 4) return null;
        const nlen = std.mem.readInt(u16, self.rest[0..2], .little);
        const vlen = std.mem.readInt(u16, self.rest[2..4], .little);
        if (self.rest.len < 4 + nlen + vlen) return null;
        const h: http1.Header = .{ .name = self.rest[4..][0..nlen], .value = self.rest[4 + nlen ..][0..vlen] };
        self.rest = self.rest[4 + nlen + vlen ..];
        return h;
    }
};

/// kind, status, fingerprint, header bytes length — then the headers, then
/// the body.
const prefix = 1 + 2 + 8 + 2;

/// The bytes a marker for a request in flight takes.
pub fn marker(fingerprint: u64) [prefix]u8 {
    var out: [prefix]u8 = undefined;
    out[0] = @intFromEnum(Kind.in_flight);
    std.mem.writeInt(u16, out[1..3], 0, .little);
    std.mem.writeInt(u64, out[3..11], fingerprint, .little);
    std.mem.writeInt(u16, out[11..13], 0, .little);
    return out;
}

/// Encode a kept answer into `arena`. `headers` are the handler's own.
pub fn encode(
    arena: std.mem.Allocator,
    kind: Kind,
    status: u16,
    fingerprint: u64,
    headers: []const http1.Header,
    body: []const u8,
) ![]const u8 {
    var hlen: usize = 0;
    for (headers) |h| hlen += 4 + h.name.len + h.value.len;
    if (hlen > std.math.maxInt(u16)) return error.TooLarge;

    const out = try arena.alloc(u8, prefix + hlen + body.len);
    out[0] = @intFromEnum(kind);
    std.mem.writeInt(u16, out[1..3], status, .little);
    std.mem.writeInt(u64, out[3..11], fingerprint, .little);
    std.mem.writeInt(u16, out[11..13], @intCast(hlen), .little);
    var at: usize = prefix;
    for (headers) |h| {
        std.mem.writeInt(u16, out[at..][0..2], @intCast(h.name.len), .little);
        std.mem.writeInt(u16, out[at + 2 ..][0..2], @intCast(h.value.len), .little);
        @memcpy(out[at + 4 ..][0..h.name.len], h.name);
        @memcpy(out[at + 4 + h.name.len ..][0..h.value.len], h.value);
        at += 4 + h.name.len + h.value.len;
    }
    @memcpy(out[at..][0..body.len], body);
    return out;
}

/// Read one back. Null for bytes another version of this module wrote, or
/// that were never a record — which is a miss, and the request runs.
pub fn decode(bytes: []const u8) ?Record {
    if (bytes.len < prefix) return null;
    if (bytes[0] > @intFromEnum(Kind.json)) return null;
    const kind: Kind = @enumFromInt(bytes[0]);
    const hlen = std.mem.readInt(u16, bytes[11..13], .little);
    if (bytes.len < prefix + hlen) return null;
    return .{
        .kind = kind,
        .status = std.mem.readInt(u16, bytes[1..3], .little),
        .fingerprint = std.mem.readInt(u64, bytes[3..11], .little),
        .headers = bytes[prefix..][0..hlen],
        .body = bytes[prefix + hlen ..],
    };
}

/// What tells "the same request again" from "the same key on a different
/// request": the method, the path, the query and every byte of the body.
pub fn fingerprintOf(method: []const u8, path: []const u8, query: []const u8, body: []const u8) u64 {
    var h = std.hash.Wyhash.init(0x1d3);
    h.update(method);
    h.update("\x00");
    h.update(path);
    h.update("\x00");
    h.update(query);
    h.update("\x00");
    h.update(body);
    return h.final();
}

/// A Space that can keep an answer: bytes in, bytes out, and a claim. Said
/// while compiling, in the words of what is missing.
pub fn checkSpace(comptime Replays: type, comptime route: []const u8) void {
    comptime {
        const shape = "\n  Give it a `cache.Space` holding `[]const u8`: " ++
            "`const Replays = cache.Space(\"replay\", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });`" ++
            "\n  and `app.provide(&replays)` once it is opened.";
        switch (@typeInfo(Replays)) {
            .@"struct" => {},
            else => @compileError(
                "nilo: the `Idempotent(" ++ naming.of(Replays) ++ ", …)` on route \"" ++ route ++
                    "\" names " ++ naming.of(Replays) ++ " as where answers are kept, and it is not a Space." ++ shape,
            ),
        }
        const needed = [_][]const u8{ "getInto", "putIfAbsent", "put", "del", "max_bytes", "Held" };
        for (needed) |decl| if (!@hasDecl(Replays, decl)) @compileError(
            "nilo: the `Idempotent(" ++ naming.of(Replays) ++ ", …)` on route \"" ++ route ++
                "\" names " ++ naming.of(Replays) ++ " as where answers are kept, and it has no `" ++
                decl ++ "`, so it is not a Space that holds bytes." ++ shape,
        );
        if (Replays.Held == void) @compileError(
            "nilo: the `Idempotent(" ++ naming.of(Replays) ++ ", …)` on route \"" ++ route ++
                "\" names a Space that holds a flat value, and a kept answer is bytes." ++ shape,
        );
        if (Replays.max_bytes < 256) @compileError(
            "nilo: the `Idempotent(" ++ naming.of(Replays) ++ ", …)` on route \"" ++ route ++
                "\" names a Space whose `max_bytes` is " ++ std.fmt.comptimePrint("{d}", .{Replays.max_bytes}) ++
                ", and a kept answer needs room for a status, its headers and a body.\n" ++
                "  256 is the least that is useful; a JSON answer usually wants a few thousand.",
        );
    }
}

// ---- tests ----

const testing = std.testing;

test "a kept answer comes back with its status, its headers and its body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const headers = [_]http1.Header{.{ .name = "Location", .value = "/orders/7" }};
    const bytes = try encode(arena.allocator(), .json, 201, 0xabc, &headers, "{\"id\":7}");
    const back = decode(bytes).?;
    try testing.expectEqual(Kind.json, back.kind);
    try testing.expectEqual(@as(u16, 201), back.status);
    try testing.expectEqual(@as(u64, 0xabc), back.fingerprint);
    try testing.expectEqualStrings("{\"id\":7}", back.body);
    var it = back.eachHeader();
    const h = it.next().?;
    try testing.expectEqualStrings("Location", h.name);
    try testing.expectEqualStrings("/orders/7", h.value);
    try testing.expect(it.next() == null);
}

test "a marker is a record with nothing in it but the fingerprint, and junk is a miss" {
    const m = marker(42);
    const back = decode(&m).?;
    try testing.expectEqual(Kind.in_flight, back.kind);
    try testing.expectEqual(@as(u64, 42), back.fingerprint);
    try testing.expectEqualStrings("", back.body);

    try testing.expect(decode("short") == null);
    var bad = marker(1);
    bad[0] = 9;
    try testing.expect(decode(&bad) == null);
}

test "the fingerprint changes with any of the four things it reads" {
    const base = fingerprintOf("POST", "/orders", "", "{}");
    try testing.expect(base != fingerprintOf("PUT", "/orders", "", "{}"));
    try testing.expect(base != fingerprintOf("POST", "/orders/", "", "{}"));
    try testing.expect(base != fingerprintOf("POST", "/orders", "dry=1", "{}"));
    try testing.expect(base != fingerprintOf("POST", "/orders", "", "{ }"));
    try testing.expectEqual(base, fingerprintOf("POST", "/orders", "", "{}"));
}
