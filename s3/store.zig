//! The Store — one endpoint, one region, one set of credentials, and the
//! derived key they turn into
//! ([ADR 0069](../docs/adr/0069-a-signing-key-changes-once-a-day.md)).
//!
//! A `Bucket` is what a handler holds; this is what every Bucket in the
//! program shares. It owns three things a bucket does not: the connection
//! pool and its gate (borrowed whole from `nilo_fetch`), the credentials, and
//! the signing key derived from them.
//!
//! **nilo owns the cache, the expiry and the derived key. The program owns
//! fetching.** `.static` is one struct literal; `.fetch` is one function, and
//! neither of them writes a lock.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("nilo_fetch");

const sign = @import("sign.zig");

/// What signs a request. `expires_at` is what makes the difference between a
/// program that runs all morning and a program that answers 403 after lunch.
pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    /// Set by STS, IMDS and IRSA; absent for a long-lived key pair.
    session_token: ?[]const u8 = null,
    /// Unix seconds. Null means they do not expire, which is what a static
    /// key pair means and what nothing temporary ever does.
    expires_at: ?i64 = null,
};

/// Where credentials come from.
///
/// Two entry points to one mechanism, so nothing in the signing path knows
/// which was used. A third source, if one ever earns its place, is a third tag
/// and no new machinery.
pub const Source = union(enum) {
    /// A key pair for the life of the process.
    static: Credentials,
    /// Called once at startup, and again when the ones in hand are within
    /// `refresh_margin_s` of expiring. **Called lazily, on the request that
    /// notices** — there is no background task here, which is the same reason
    /// ADR 0060 gave for refusing automatic replica routing.
    ///
    /// Whatever it allocates from `gpa` is freed by the Store when the next
    /// refresh replaces it.
    fetch: *const fn (gpa: std.mem.Allocator, io: std.Io) anyerror!Credentials,
};

pub const Options = struct {
    /// `https://s3.ap-southeast-1.amazonaws.com`, or `http://127.0.0.1:9000`
    /// for a MinIO in a container. Scheme, host and port; no path.
    ///
    /// **The scheme decides whether payloads are hashed** — `UNSIGNED-PAYLOAD`
    /// over TLS, a real SHA-256 over plaintext. There is nothing to configure
    /// and the reasoning is in ADR 0069.
    endpoint: []const u8,
    region: []const u8 = "us-east-1",
    credentials: Source,

    /// How many S3 calls may be in flight across the whole process. The
    /// ceiling on live connections, and therefore on memory: each HTTPS one
    /// holds 59,151 bytes of TLS and socket buffers, so this number times that
    /// is what the store may cost.
    max_in_flight: u32 = 32,
    /// How long one call may take, end to end.
    timeout_ms: u32 = 30_000,
    /// How much of an unread body is worth reading to keep a connection.
    max_drain: usize = 64 << 10,
    /// How long before expiry a refresh happens. Five minutes, so that the
    /// request paying for the refresh is never a request that would otherwise
    /// have failed.
    refresh_margin_s: i64 = 300,
};

pub const OpenError = error{
    /// The endpoint is not `http://host[:port]` or `https://host[:port]`.
    BadEndpoint,
    /// A region longer than a credential scope can carry.
    BadRegion,
    OutOfMemory,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    client: fetch.Client,
    source: Source,
    options: Options,

    /// `http` or `https`, decided once. What it decides is the payload hash.
    scheme: Scheme,
    /// The authority out of the endpoint — `s3.amazonaws.com`, or
    /// `127.0.0.1:9000`. A Bucket builds its own host from this.
    authority: []const u8,
    /// Owned copies, because `Options` is a literal at a call site and the
    /// strings in it may be a `Config`'s that outlive nothing.
    owned: []u8 = &.{},

    /// Everything a refresh replaces, under one lock.
    ///
    /// The lock is a plain shared/exclusive one and there is nothing clever
    /// in here on purpose: a `tryLock` pair is about 30 ns against a network
    /// round trip of 5–50 ms, which is 0.00015%, and ADR 0001 puts the bar at
    /// ten per cent. The number is written down so nobody re-derives the
    /// temptation.
    lock: std.Io.RwLock = .init,
    creds: Credentials = .{ .access_key_id = "", .secret_access_key = "" },
    creds_owned: []u8 = &.{},
    keyed: sign.Keyed = undefined,
    /// The date the key in hand was derived for. A key changes once a day.
    key_date: [8]u8 = @splat(0),

    started: bool = false,

    pub const Scheme = enum { http, https };

    /// Everything that can be settled without an event loop.
    ///
    /// **The credentials are not fetched here**, and that differs from the
    /// sketch in ADR 0069 for the reason ADR 0040 exists: a Service that dials
    /// cannot dial before `listen()`, because there is no loop to dial on.
    /// `nilo_start` is where the first fetch happens.
    pub fn open(gpa: std.mem.Allocator, options: Options) OpenError!Store {
        const parsed = try parseEndpoint(options.endpoint);
        if (options.region.len == 0 or options.region.len > 64) return error.BadRegion;

        // One allocation for every string this holds for the life of the
        // process, sliced up rather than allocated one at a time.
        const total = parsed.authority.len + options.region.len + options.endpoint.len;
        const owned = try gpa.alloc(u8, total);
        errdefer gpa.free(owned);

        var at: usize = 0;
        const authority = copyInto(owned, &at, parsed.authority);
        const region = copyInto(owned, &at, options.region);
        const endpoint = copyInto(owned, &at, options.endpoint);

        var kept = options;
        kept.region = region;
        kept.endpoint = endpoint;

        return .{
            .gpa = gpa,
            .client = .init(gpa, .{
                .max_in_flight = options.max_in_flight,
                .timeout_ms = options.timeout_ms,
                .max_drain = options.max_drain,
                // Every body this module reads is bounded by the Bucket's own
                // `max_bytes` before a byte is read, so the Fitting's ceiling
                // is not the one doing the work here.
                .max_body = std.math.maxInt(usize),
            }),
            .source = options.credentials,
            .options = kept,
            .scheme = parsed.scheme,
            .authority = authority,
            .owned = owned,
        };
    }

    pub fn deinit(self: *Store) void {
        self.client.deinit();
        if (self.creds_owned.len != 0) self.gpa.free(self.creds_owned);
        if (self.owned.len != 0) self.gpa.free(self.owned);
    }

    /// Finished once the loop exists (ADR 0040), and idempotent: two Buckets
    /// over one Store both start it, and a program that also provides the
    /// Store itself starts it a third time.
    pub fn nilo_start(self: *Store, io: std.Io, limits: core.Limits) !void {
        if (self.started) return;
        try self.client.nilo_start(io, limits);
        self.started = true;
        // The first fetch, so that a credential source that is misconfigured
        // fails the server's startup rather than its first request.
        try self.refresh(io, core.nowMillis());
    }

    /// The signing key for `now`, and the session token that goes with it.
    ///
    /// The token is copied into `token_buf` while the lock is held. Anything
    /// left pointing into the Store would be a slice a refresh may overwrite
    /// while the request holding it is still being written — one bad signature
    /// per rotation, silently.
    pub fn keyFor(
        self: *Store,
        io: std.Io,
        now_ms: i64,
        token_buf: []u8,
    ) !Signing {
        const now_s = @divFloor(now_ms, 1000);

        {
            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);
            if (self.usable(now_s)) return self.snapshot(token_buf);
        }

        try self.refresh(io, now_ms);

        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        return self.snapshot(token_buf);
    }

    /// What one request holds: a key, the token to send beside it, and when
    /// the credentials behind both stop working.
    ///
    /// The expiry is here rather than read off the Store because reading it
    /// there would be a read of shared state outside the lock — and it is
    /// wanted for exactly one thing, which is telling a presigned URL the
    /// truth about its own life.
    pub const Signing = struct {
        keyed: sign.Keyed,
        token: ?[]const u8,
        expires_at: ?i64,
    };

    /// Whether what is in hand can sign a request at `now_s`. Called under the
    /// lock, shared or exclusive.
    fn usable(self: *const Store, now_s: i64) bool {
        if (self.creds.access_key_id.len == 0) return false;

        var stamp: sign.Stamp = .at(now_s);
        if (!std.mem.eql(u8, &self.key_date, stamp.date())) return false;

        if (self.creds.expires_at) |expiry| {
            if (now_s + self.options.refresh_margin_s >= expiry) return false;
        }
        return true;
    }

    fn snapshot(self: *const Store, token_buf: []u8) !Signing {
        const token = self.creds.session_token orelse return .{
            .keyed = self.keyed,
            .token = null,
            .expires_at = self.creds.expires_at,
        };
        // A bucket declares this buffer from a comptime option, so being one
        // byte short is a configuration mistake with a name rather than a
        // signature that is quietly missing a header.
        if (token.len > token_buf.len) {
            std.log.warn(
                "nilo_s3: the session token is {d} bytes and the bucket's " ++
                    "`session_token_max` is {d}. Raise it.",
                .{ token.len, token_buf.len },
            );
            return error.SessionTokenTooLong;
        }
        @memcpy(token_buf[0..token.len], token);
        return .{
            .keyed = self.keyed,
            .token = token_buf[0..token.len],
            .expires_at = self.creds.expires_at,
        };
    }

    /// Take the credentials again if they need taking, and derive today's key.
    ///
    /// Under the exclusive lock, and it re-checks after taking it: several
    /// fibers can decide at once that a refresh is due, and only the first
    /// should do it.
    fn refresh(self: *Store, io: std.Io, now_ms: i64) !void {
        const now_s = @divFloor(now_ms, 1000);

        try self.lock.lock(io);
        defer self.lock.unlock(io);
        if (self.usable(now_s)) return;

        const expired = switch (self.source) {
            .static => self.creds.access_key_id.len == 0,
            .fetch => if (self.creds.expires_at) |expiry|
                now_s + self.options.refresh_margin_s >= expiry
            else
                self.creds.access_key_id.len == 0,
        };

        if (expired) switch (self.source) {
            .static => |fixed| try self.hold(fixed),
            .fetch => |take| try self.hold(try take(self.gpa, io)),
        };

        var stamp: sign.Stamp = .at(now_s);
        try self.deriveLocked(stamp.date());
    }

    /// Copy a set of credentials in, and let go of the ones they replace.
    fn hold(self: *Store, fresh: Credentials) !void {
        const token = fresh.session_token orelse "";
        const total = fresh.access_key_id.len + fresh.secret_access_key.len + token.len;
        const owned = try self.gpa.alloc(u8, total);
        errdefer self.gpa.free(owned);

        var at: usize = 0;
        const akid = copyInto(owned, &at, fresh.access_key_id);
        const secret = copyInto(owned, &at, fresh.secret_access_key);
        const kept_token = copyInto(owned, &at, token);

        if (self.creds_owned.len != 0) self.gpa.free(self.creds_owned);
        self.creds_owned = owned;
        self.creds = .{
            .access_key_id = akid,
            .secret_access_key = secret,
            .session_token = if (fresh.session_token == null) null else kept_token,
            .expires_at = fresh.expires_at,
        };
        // The key in hand was derived from credentials that are gone.
        self.key_date = @splat(0);
    }

    /// The four HMACs, done here so they are not done per request.
    fn deriveLocked(self: *Store, date: *const [8]u8) !void {
        if (self.creds.access_key_id.len > sign.akid_max) return error.AccessKeyIdTooLong;

        self.keyed = .{
            .key = try sign.derive(self.creds.secret_access_key, date, self.options.region),
            .access_key_id = undefined,
            .access_key_id_len = @intCast(self.creds.access_key_id.len),
            .scope = undefined,
            .scope_len = 0,
        };
        @memcpy(
            self.keyed.access_key_id[0..self.creds.access_key_id.len],
            self.creds.access_key_id,
        );
        const s = sign.scope(&self.keyed.scope, date, self.options.region);
        self.keyed.scope_len = @intCast(s.len);
        self.key_date = date.*;
    }

    /// What `x-amz-content-sha256` says, decided by the scheme and nothing
    /// else (ADR 0069).
    ///
    /// Over `https://` it is `UNSIGNED-PAYLOAD`: hashing buys integrity TLS
    /// has already provided, at 5 ms per 10 MB with SHA-NI and 20 ms without —
    /// on a fiber, where ADR 0014 says a handler must not hold its thread.
    /// Over `http://` it is the only integrity there is, and that path is a
    /// development MinIO rather than production load, so it is paid.
    ///
    /// The same answer for a request that carries no body at all, which needs
    /// no buffer because both answers are constants.
    pub fn payloadNoBody(self: *const Store) []const u8 {
        return if (self.scheme == .https) sign.unsigned_payload else sign.empty_payload;
    }

    /// `hex` is where a real hash is written; it is untouched otherwise.
    pub fn payloadFor(self: *const Store, body: ?[]const u8, hex: *[64]u8) []const u8 {
        if (self.scheme == .https) return sign.unsigned_payload;
        const bytes = body orelse return sign.empty_payload;
        if (bytes.len == 0) return sign.empty_payload;

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        _ = std.fmt.bufPrint(hex, "{x}", .{&digest}) catch unreachable;
        return hex;
    }
};

/// What `open` reads out of an endpoint.
const Endpoint = struct {
    scheme: Store.Scheme,
    authority: []const u8,
};

fn parseEndpoint(text: []const u8) OpenError!Endpoint {
    const scheme: Store.Scheme, const rest = if (std.mem.startsWith(u8, text, "https://"))
        .{ .https, text["https://".len..] }
    else if (std.mem.startsWith(u8, text, "http://"))
        .{ .http, text["http://".len..] }
    else
        return error.BadEndpoint;

    // A trailing `/` is what everybody's `S3_ENDPOINT` has in it, so it is
    // taken off rather than refused. Anything past it is a path, and a path in
    // an endpoint means somebody expects nilo to join two of them.
    const authority = std.mem.trimEnd(u8, rest, "/");
    if (authority.len == 0) return error.BadEndpoint;
    if (std.mem.indexOfScalar(u8, authority, '/') != null) return error.BadEndpoint;
    return .{ .scheme = scheme, .authority = authority };
}

fn copyInto(buf: []u8, at: *usize, text: []const u8) []const u8 {
    @memcpy(buf[at.*..][0..text.len], text);
    defer at.* += text.len;
    return buf[at.*..][0..text.len];
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "an endpoint is a scheme and an authority, and nothing else" {
    const https = try parseEndpoint("https://s3.ap-southeast-1.amazonaws.com");
    try testing.expectEqual(Store.Scheme.https, https.scheme);
    try testing.expectEqualStrings("s3.ap-southeast-1.amazonaws.com", https.authority);

    // A port survives, because a development endpoint is nothing but a port
    // and the host header has to carry it.
    const local = try parseEndpoint("http://127.0.0.1:9000");
    try testing.expectEqual(Store.Scheme.http, local.scheme);
    try testing.expectEqualStrings("127.0.0.1:9000", local.authority);

    // The trailing slash everybody's environment variable has.
    const slashed = try parseEndpoint("http://127.0.0.1:9000/");
    try testing.expectEqualStrings("127.0.0.1:9000", slashed.authority);
}

test "an endpoint that is not one is refused by name" {
    try testing.expectError(error.BadEndpoint, parseEndpoint("s3.amazonaws.com"));
    try testing.expectError(error.BadEndpoint, parseEndpoint("ftp://s3.amazonaws.com"));
    try testing.expectError(error.BadEndpoint, parseEndpoint("https://"));
    // A path, which would mean nilo joining two of them and getting it wrong.
    try testing.expectError(error.BadEndpoint, parseEndpoint("https://example.com/bucket"));
}

test "the payload hash is decided by the scheme and nothing else" {
    var hex: [64]u8 = undefined;

    var https = try Store.open(testing.allocator, .{
        .endpoint = "https://s3.amazonaws.com",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer https.deinit();
    try testing.expectEqualStrings(sign.unsigned_payload, https.payloadFor("some bytes", &hex));
    try testing.expectEqualStrings(sign.unsigned_payload, https.payloadFor(null, &hex));

    var plain = try Store.open(testing.allocator, .{
        .endpoint = "http://127.0.0.1:9000",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer plain.deinit();
    // Over plaintext the hash is the only integrity there is, so a body gets
    // one — the empty body included, which is a constant rather than work.
    try testing.expectEqualStrings(sign.empty_payload, plain.payloadFor(null, &hex));
    try testing.expectEqualStrings(sign.empty_payload, plain.payloadFor("", &hex));

    // SHA-256 of "Welcome to Amazon S3.", which is AWS's own PUT example and
    // therefore a value that can be checked against something.
    try testing.expectEqualStrings(
        "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
        plain.payloadFor("Welcome to Amazon S3.", &hex),
    );
}

test "a store keeps its own copy of the strings it was opened with" {
    var endpoint: [32]u8 = undefined;
    var region: [16]u8 = undefined;
    const e = try std.fmt.bufPrint(&endpoint, "https://s3.example.com", .{});
    const r = try std.fmt.bufPrint(&region, "ap-southeast-1", .{});

    var store = try Store.open(testing.allocator, .{
        .endpoint = e,
        .region = r,
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer store.deinit();

    // The caller's buffers, overwritten the way a Config's would be if it were
    // read into a stack buffer and reused.
    @memset(&endpoint, 'x');
    @memset(&region, 'x');

    try testing.expectEqualStrings("s3.example.com", store.authority);
    try testing.expectEqualStrings("ap-southeast-1", store.options.region);
}

test "a region that cannot fit a credential scope is refused at open" {
    const long = "x" ** 65;
    try testing.expectError(error.BadRegion, Store.open(testing.allocator, .{
        .endpoint = "https://s3.example.com",
        .region = long,
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    }));
}
