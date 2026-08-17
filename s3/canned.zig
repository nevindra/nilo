//! A fake S3 on a loopback socket, which checks the signature.
//!
//! `sign.zig`'s own tests pin the arithmetic against vectors AWS published:
//! given this canonical request, that signature. What they cannot say is
//! whether the request nilo *sends* is the request nilo *signed* — a host
//! header spelled differently by std, a key encoded twice, a header signed and
//! then not sent. Every one of those produces a perfectly correct signature
//! over the wrong bytes, and the only symptom is a 403 from a server that will
//! not say why.
//!
//! So the server below rebuilds the canonical request **from the bytes that
//! arrived**, off the wire, without calling `canonicalHash` — and answers 403
//! when it disagrees. The client's claim and the server's reading are then two
//! independent paths, which is the only arrangement in which agreeing means
//! anything.
//!
//! It runs under `std.Io.Threaded`, so all of this is in `zig build test-s3`
//! with no container anywhere. `live.zig` is the half that needs a real one.

const std = @import("std");
const core = @import("nilo_core");

const bucket_mod = @import("bucket.zig");
const sign = @import("sign.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;
const testing = std.testing;

const akid = "AKIAIOSFODNN7EXAMPLE";
const secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";

/// One request, as the server read it off the socket.
const Seen = struct {
    method: [16]u8 = undefined,
    method_len: usize = 0,
    target: [4096]u8 = undefined,
    target_len: usize = 0,
    names: [32][64]u8 = undefined,
    name_lens: [32]usize = undefined,
    values: [32][3072]u8 = undefined,
    value_lens: [32]usize = undefined,
    count: usize = 0,
    body: [8192]u8 = undefined,
    body_len: usize = 0,

    fn methodText(self: *const Seen) []const u8 {
        return self.method[0..self.method_len];
    }

    fn targetText(self: *const Seen) []const u8 {
        return self.target[0..self.target_len];
    }

    fn header(self: *const Seen, name: []const u8) ?[]const u8 {
        for (0..self.count) |i| {
            if (std.ascii.eqlIgnoreCase(self.names[i][0..self.name_lens[i]], name)) {
                return self.values[i][0..self.value_lens[i]];
            }
        }
        return null;
    }

    fn bodyText(self: *const Seen) []const u8 {
        return self.body[0..self.body_len];
    }

    fn path(self: *const Seen) []const u8 {
        const t = self.targetText();
        const q = std.mem.indexOfScalar(u8, t, '?') orelse return t;
        return t[0..q];
    }

    fn query(self: *const Seen) []const u8 {
        const t = self.targetText();
        const q = std.mem.indexOfScalar(u8, t, '?') orelse return "";
        return t[q + 1 ..];
    }
};

/// What the server should answer with, once it is happy with the signature.
const Answer = struct {
    status: []const u8 = "200 OK",
    body: []const u8 = "",
    content_type: []const u8 = "image/png",
    etag: []const u8 = "\"9a0364b9e99bb480dd25e1f0284c8555\"",
    /// Claim a length other than the body's, for the test about a ceiling.
    claim_len: ?u64 = null,
    /// Sent instead of a body when the request failed.
    error_body: []const u8 = "",
};

const Canned = struct {
    server: std.Io.net.Server,
    io: std.Io,
    port: u16,
    answer: Answer = .{},
    seen: Seen = .{},
    /// Filled in by `serveOne`: whether the signature the client sent is the
    /// one this server computed from what arrived.
    verified: bool = false,
    /// What the server computed, for a failure message worth reading.
    expected: [64]u8 = undefined,
    got: [64]u8 = undefined,

    fn open(io: std.Io) !Canned {
        var candidate: u16 = 39_600;
        while (candidate < 39_800) : (candidate += 1) {
            const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(candidate) };
            const server = address.listen(io, .{}) catch continue;
            return .{ .server = server, .io = io, .port = candidate };
        }
        return error.NoFreePort;
    }

    fn endpoint(self: *Canned, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port});
    }

    fn close(self: *Canned) void {
        self.server.socket.close(self.io);
    }

    fn serveOne(self: *Canned) !void {
        return self.serveMany(1);
    }

    /// `n` requests **on one connection**, which is what a pooling client
    /// expects and what the earlier version of this got wrong: closing after
    /// each request left `std.http.Client` holding a dead pooled connection,
    /// and the second call failed with `HttpConnectionClosing` rather than
    /// measuring anything. HTTP/1.1 is keep-alive by default, so answering
    /// with a `Content-Length` and not closing is the whole of it.
    fn serveMany(self: *Canned, n: usize) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);

        var in_buf: [16 << 10]u8 = undefined;
        var out_buf: [64 << 10]u8 = undefined;
        var reader = stream.reader(self.io, &in_buf);
        var writer = stream.writer(self.io, &out_buf);

        for (0..n) |_| {
            // Fresh, or the second request's headers land after the first
            // request's and `check` rebuilds a canonical form nobody sent.
            self.seen = .{};
            try self.answerOne(&reader.interface, &writer.interface);
        }
    }

    fn answerOne(self: *Canned, r: *std.Io.Reader, w: *std.Io.Writer) !void {
        try self.readRequest(r);
        self.verified = self.check();

        if (!self.verified) {
            const body =
                \\<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match.</Message></Error>
            ;
            try w.print(
                "HTTP/1.1 403 Forbidden\r\nContent-Type: application/xml\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ body.len, body },
            );
            try w.flush();
            return;
        }

        const failing = self.answer.error_body.len != 0;
        const body = if (failing) self.answer.error_body else self.answer.body;
        try w.print("HTTP/1.1 {s}\r\n", .{self.answer.status});
        try w.print("Content-Type: {s}\r\n", .{
            if (failing) "application/xml" else self.answer.content_type,
        });
        try w.print("ETag: {s}\r\n", .{self.answer.etag});
        try w.print("Content-Length: {d}\r\n\r\n", .{self.answer.claim_len orelse body.len});
        // A HEAD carries no body however long it says it is, which is the
        // whole of what makes `head` a cheap call.
        if (!std.mem.eql(u8, self.seen.methodText(), "HEAD")) try w.writeAll(body);
        try w.flush();
    }

    fn readRequest(self: *Canned, r: *std.Io.Reader) !void {
        const line = try r.takeDelimiterInclusive('\n');
        const first = std.mem.trimEnd(u8, line, "\r\n");
        var parts = std.mem.splitScalar(u8, first, ' ');
        const method = parts.next() orelse return error.BadRequest;
        const target = parts.next() orelse return error.BadRequest;

        @memcpy(self.seen.method[0..method.len], method);
        self.seen.method_len = method.len;
        @memcpy(self.seen.target[0..target.len], target);
        self.seen.target_len = target.len;

        var content_length: usize = 0;
        while (true) {
            const next = try r.takeDelimiterInclusive('\n');
            const trimmed = std.mem.trimEnd(u8, next, "\r\n");
            if (trimmed.len == 0) break;

            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
            const name = trimmed[0..colon];
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");

            const i = self.seen.count;
            @memcpy(self.seen.names[i][0..name.len], name);
            self.seen.name_lens[i] = name.len;
            @memcpy(self.seen.values[i][0..value.len], value);
            self.seen.value_lens[i] = value.len;
            self.seen.count += 1;

            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = try std.fmt.parseInt(usize, value, 10);
            }
        }

        self.seen.body_len = @min(content_length, self.seen.body.len);
        if (self.seen.body_len != 0) try r.readSliceAll(self.seen.body[0..self.seen.body_len]);
    }

    /// Rebuild the canonical request from what arrived, and see whether the
    /// signature over it is the one the client sent.
    ///
    /// Deliberately written out by hand rather than through `canonicalHash`:
    /// two implementations that agree say something, and one implementation
    /// checked against itself says nothing.
    fn check(self: *Canned) bool {
        const auth = self.seen.header("authorization") orelse return false;

        const credential = fieldOf(auth, "Credential=") orelse return false;
        const signed_headers = fieldOf(auth, "SignedHeaders=") orelse return false;
        const claimed = fieldOf(auth, "Signature=") orelse return false;

        // `AKIAIOSFODNN7EXAMPLE/20260817/us-east-1/s3/aws4_request`
        var scope_parts = std.mem.splitScalar(u8, credential, '/');
        const key_id = scope_parts.next() orelse return false;
        if (!std.mem.eql(u8, key_id, akid)) return false;
        const date = scope_parts.next() orelse return false;
        const region = scope_parts.next() orelse return false;
        if (date.len != 8) return false;
        const credential_scope = credential[key_id.len + 1 ..];

        var hashing: sign.Hashing = .init();
        const w = &hashing.interface;
        w.writeAll(self.seen.methodText()) catch return false;
        w.writeByte('\n') catch return false;
        // As received. Encoding it again here is the mistake this whole file
        // exists to catch, so it is not encoded again here.
        w.writeAll(self.seen.path()) catch return false;
        w.writeByte('\n') catch return false;
        w.writeAll(self.seen.query()) catch return false;
        w.writeByte('\n') catch return false;

        var names = std.mem.splitScalar(u8, signed_headers, ';');
        while (names.next()) |name| {
            const value = self.seen.header(name) orelse return false;
            w.writeAll(name) catch return false;
            w.writeByte(':') catch return false;
            w.writeAll(value) catch return false;
            w.writeByte('\n') catch return false;
        }
        w.writeByte('\n') catch return false;
        w.writeAll(signed_headers) catch return false;
        w.writeByte('\n') catch return false;

        const payload = self.seen.header("x-amz-content-sha256") orelse sign.unsigned_payload;
        w.writeAll(payload) catch return false;
        const canonical = hashing.final();

        const stamp_text = self.seen.header("x-amz-date") orelse return false;
        var stamp: sign.Stamp = .{ .text = undefined };
        if (stamp_text.len != 16) return false;
        @memcpy(&stamp.text, stamp_text);

        var sts_buf: [sign.string_to_sign_max]u8 = undefined;
        const sts = sign.stringToSign(&sts_buf, &stamp, credential_scope, canonical);

        const key = sign.derive(secret, date[0..8], region) catch return false;
        const computed = sign.signature(key, sts);

        _ = std.fmt.bufPrint(&self.expected, "{x}", .{&computed}) catch return false;
        const room = @min(claimed.len, self.got.len);
        @memcpy(self.got[0..room], claimed[0..room]);

        return std.mem.eql(u8, &self.expected, claimed);
    }
};

/// The value of `name=` in an `Authorization` header, up to the next comma.
fn fieldOf(auth: []const u8, name: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, auth, name) orelse return null;
    const from = at + name.len;
    const rest = auth[from..];
    const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
    return rest[0..end];
}

// ---- the harness ----

fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

/// A Store pointed at the canned server, started the way `listen()` would
/// start it — with `.off` for Limits, because there is no Engine here and that
/// is the property this file holds.
fn started(io: std.Io, canned: *Canned, buf: []u8) !Store {
    var store = try Store.open(testing.allocator, .{
        .endpoint = try canned.endpoint(buf),
        .region = "us-east-1",
        .credentials = .{ .static = .{
            .access_key_id = akid,
            .secret_access_key = secret,
        } },
    });
    errdefer store.deinit();
    try store.nilo_start(io, .off);
    return store;
}

/// Path style, because the canned server is a bare host and a virtual-host
/// bucket would need DNS to point `avatars.127.0.0.1` somewhere.
const Files = bucket_mod.Bucket("files", .{ .style = .path, .max_bytes = 1 << 20 });

fn expectVerified(canned: *const Canned) !void {
    if (canned.verified) return;
    std.debug.print(
        "\nthe server did not accept the signature\n  computed: {s}\n  sent:     {s}\n",
        .{ canned.expected, canned.got },
    );
    return error.SignatureRejected;
}

// -- tests ---------------------------------------------------------------

test "a get is signed, and the object comes back whole" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .body = "the bytes of a very small png", .content_type = "image/png" };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const object = try files.get(&scope, "photos/wati.png");

            served.await(io) catch {};
            try expectVerified(&canned);

            try testing.expectEqualStrings("the bytes of a very small png", object.bytes.view());
            try testing.expectEqualStrings("image/png", object.content_type.view());
            try testing.expectEqualStrings("\"9a0364b9e99bb480dd25e1f0284c8555\"", object.etag.view());
            try testing.expectEqual(@as(u64, 29), object.len);

            // Path style, so the bucket is in the path and the host is the
            // bare authority — port and all, because the signature covers it.
            try testing.expectEqualStrings("/files/photos/wati.png", canned.seen.path());
            var host: [32]u8 = undefined;
            try testing.expectEqualStrings(
                try std.fmt.bufPrint(&host, "127.0.0.1:{d}", .{canned.port}),
                canned.seen.header("host").?,
            );
        }
    }.run);
}

test "a key with characters a URL cannot carry is encoded once, and verifies" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .body = "x" };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // A space, a `$`, a `+` and something outside ASCII. Encoding any
            // of them twice, or a `+` as a space, is a signature over bytes
            // the server never sees.
            _ = try files.get(&scope, "foto/wati sari$1+2/café.png");

            served.await(io) catch {};
            try expectVerified(&canned);
            try testing.expectEqualStrings(
                "/files/foto/wati%20sari%241%2B2/caf%C3%A9.png",
                canned.seen.path(),
            );
        }
    }.run);
}

test "a put sends the bytes it signed, and says what they are" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // The shape a form `Upload` has, without naming `nilo_http` —
            // which is the point of the duck typing rather than a convenience.
            try files.put(&scope, "notes/one.txt", .{
                .bytes = scope.str("cinta laut dan langit"),
                .content_type = scope.str("text/plain"),
            });

            served.await(io) catch {};
            try expectVerified(&canned);

            try testing.expectEqualStrings("PUT", canned.seen.methodText());
            try testing.expectEqualStrings("cinta laut dan langit", canned.seen.bodyText());
            try testing.expectEqualStrings("text/plain", canned.seen.header("content-type").?);
            try testing.expectEqualStrings("21", canned.seen.header("content-length").?);

            // Over `http://` the payload is hashed for real, because there is
            // no TLS underneath to say the bytes arrived as sent (ADR 0069).
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash("cinta laut dan langit", &digest, .{});
            var hex: [64]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
            try testing.expectEqualStrings(&hex, canned.seen.header("x-amz-content-sha256").?);
        }
    }.run);
}

test "a streamed put frames its body by length rather than in chunks" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var source = std.Io.Reader.fixed("bytes arriving from somewhere else");
            try files.putStream(&scope, "big/one.bin", .{
                .reader = &source,
                .len = @as(u64, 34),
                .content_type = "application/octet-stream",
            });

            served.await(io) catch {};
            try expectVerified(&canned);

            try testing.expectEqualStrings("bytes arriving from somewhere else", canned.seen.bodyText());
            try testing.expectEqualStrings("34", canned.seen.header("content-length").?);
            try testing.expect(canned.seen.header("transfer-encoding") == null);
            // Unsigned, because hashing what has not been read yet means
            // reading it twice — and the source may be a socket.
            try testing.expectEqualStrings(
                sign.unsigned_payload,
                canned.seen.header("x-amz-content-sha256").?,
            );
        }
    }.run);
}

test "a range is signed as a header, and asks for the slice it was given" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .status = "206 Partial Content", .body = "0123456789" };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const part = try files.getRange(&scope, "big/one.bin", .{ .from = 0, .to = 9 });

            served.await(io) catch {};
            try expectVerified(&canned);

            try testing.expectEqualStrings("0123456789", part.bytes.view());
            try testing.expectEqualStrings("bytes=0-9", canned.seen.header("range").?);
            // In the signature as well as on the wire, which is the half a
            // client gets wrong.
            try testing.expect(std.mem.indexOf(
                u8,
                canned.seen.header("authorization").?,
                "host;range;x-amz-content-sha256;x-amz-date",
            ) != null);
        }
    }.run);
}

test "an object over the ceiling is refused before a byte of it is read" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // Claims two megabytes against a bucket that holds one, and sends
            // nothing: if the ceiling were checked after reading, this would
            // hang rather than fail.
            canned.answer = .{ .body = "", .claim_len = 2 << 20 };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.TooLarge, files.get(&scope, "big/one.bin"));

            served.await(io) catch {};
            try expectVerified(&canned);
        }
    }.run);
}

test "S3 saying no becomes one of the seven, with its code in the log" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{
                .status = "404 Not Found",
                .error_body =
                \\<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>
                ,
            };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.NotFound, files.get(&scope, "gone.png"));
            served.await(io) catch {};
            try expectVerified(&canned);
        }
    }.run);
}

test "a delete is signed with an empty payload and answers nothing" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .status = "204 No Content", .body = "" };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try files.delete(&scope, "notes/one.txt");

            served.await(io) catch {};
            try expectVerified(&canned);
            try testing.expectEqualStrings("DELETE", canned.seen.methodText());
            try testing.expectEqualStrings(
                sign.empty_payload,
                canned.seen.header("x-amz-content-sha256").?,
            );
        }
    }.run);
}

test "a head asks what an object is without asking for it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{
                .body = "",
                .claim_len = 4096,
                .content_type = "application/pdf",
                .etag = "\"abc123\"",
            };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const meta = try files.head(&scope, "invoices/7.pdf");

            served.await(io) catch {};
            try expectVerified(&canned);

            try testing.expectEqual(@as(u64, 4096), meta.len);
            try testing.expectEqualStrings("application/pdf", meta.content_type.view());
            try testing.expectEqualStrings("\"abc123\"", meta.etag.view());
            try testing.expectEqualStrings("HEAD", canned.seen.methodText());
        }
    }.run);
}

test "a streamed get pipes the object out without holding it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .body = "a body too big to want in an arena", .content_type = "video/mp4" };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var transfer: [1 << 10]u8 = undefined;
            var reading: Files.Reading = .idle;
            defer reading.close();

            try files.stream(&scope, "video/one.mp4", &reading, &transfer);

            // Readable now, because the body has not been touched — which is
            // exactly what a handler needs before it writes its own head.
            try testing.expectEqual(@as(u64, 34), reading.len);
            try testing.expectEqualStrings("video/mp4", reading.content_type);
            try testing.expectEqualStrings("\"9a0364b9e99bb480dd25e1f0284c8555\"", reading.etag);

            var out: [128]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);
            const n = try reading.pipe(&w);

            served.await(io) catch {};
            try expectVerified(&canned);

            try testing.expectEqual(@as(u64, 34), n);
            try testing.expectEqualStrings("a body too big to want in an arena", w.buffered());
        }
    }.run);
}

test "a conditional get is a union, because a 304 is a success" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .status = "304 Not Modified", .body = "" };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            switch (try files.getIf(&scope, "photos/wati.png", "\"9a0364b9e99bb480dd25e1f0284c8555\"")) {
                .unmodified => {},
                .object => return error.ExpectedUnmodified,
            }

            served.await(io) catch {};
            try expectVerified(&canned);
            try testing.expectEqualStrings(
                "\"9a0364b9e99bb480dd25e1f0284c8555\"",
                canned.seen.header("if-none-match").?,
            );
        }
    }.run);
}

test "a bucket with server-side encryption signs the header it sends" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            const Secrets = bucket_mod.Bucket("secrets", .{ .style = .path, .sse = .aes256 });
            var secrets = try Secrets.open(&store);
            defer secrets.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try secrets.put(&scope, "one.txt", .{ .bytes = "hush", .content_type = "text/plain" });

            served.await(io) catch {};
            try expectVerified(&canned);
            try testing.expectEqualStrings(
                "AES256",
                canned.seen.header("x-amz-server-side-encryption").?,
            );
        }
    }.run);
}

test "temporary credentials send a token, and sign it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .body = "x" };

            var served = io.async(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try Store.open(testing.allocator, .{
                .endpoint = try canned.endpoint(&buf),
                .region = "us-east-1",
                .credentials = .{ .static = .{
                    .access_key_id = akid,
                    .secret_access_key = secret,
                    .session_token = "FQoGZXIvYXdzEBYaDN0EXAMPLETOKEN",
                } },
            });
            defer store.deinit();
            try store.nilo_start(io, .off);

            // The buffer for the token is a comptime option, so a bucket that
            // never sees one declares none at all — this is the bucket that
            // does.
            const Temp = bucket_mod.Bucket("temp", .{ .style = .path, .session_token_max = 2048 });
            var temp = try Temp.open(&store);
            defer temp.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            _ = try temp.get(&scope, "one.txt");

            served.await(io) catch {};
            try expectVerified(&canned);

            try testing.expectEqualStrings(
                "FQoGZXIvYXdzEBYaDN0EXAMPLETOKEN",
                canned.seen.header("x-amz-security-token").?,
            );
            try testing.expect(std.mem.indexOf(
                u8,
                canned.seen.header("authorization").?,
                "x-amz-security-token",
            ) != null);
        }
    }.run);
}

test "a bucket whose token does not fit says which option to raise" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var buf: [64]u8 = undefined;
            var store = try Store.open(testing.allocator, .{
                .endpoint = try canned.endpoint(&buf),
                .credentials = .{ .static = .{
                    .access_key_id = akid,
                    .secret_access_key = secret,
                    .session_token = "a token this bucket has no room for",
                } },
            });
            defer store.deinit();
            try store.nilo_start(io, .off);

            // `session_token_max` defaults to zero, which is right for static
            // key pairs and wrong here — and the failure is a named error
            // rather than a signature quietly missing a header.
            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.Failed, files.get(&scope, "one.txt"));
        }
    }.run);
}

test "a presigned URL carries its own signature, and a life that is true" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // Asked for a day; the bucket's `presign_max` is an hour, so an
            // hour is what comes back — and what the caller is told.
            const link = try files.presign(&scope, "photos/wati.png", 86_400);
            const url = link.url.view();

            const now = @divFloor(core.nowMillis(), 1000);
            try testing.expectEqual(now + 3600, link.expires_at);

            try testing.expect(std.mem.indexOf(u8, url, "/files/photos/wati.png?") != null);
            try testing.expect(std.mem.indexOf(u8, url, "X-Amz-Algorithm=AWS4-HMAC-SHA256") != null);
            try testing.expect(std.mem.indexOf(u8, url, "X-Amz-Expires=3600") != null);
            try testing.expect(std.mem.indexOf(u8, url, "X-Amz-Signature=") != null);
            // Nothing in the URL that would be a header on a signed request:
            // a presigned one signs `host` and says the rest in the query.
            try testing.expect(std.mem.indexOf(u8, url, "X-Amz-SignedHeaders=host") != null);
        }
    }.run);
}

test "two buckets over one store are two types and one connection pool" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            const Avatars = bucket_mod.Bucket("avatars", .{ .style = .path });
            const Invoices = bucket_mod.Bucket("invoices", .{ .style = .path });

            var avatars = try Avatars.open(&store);
            defer avatars.deinit();
            var invoices = try Invoices.open(&store);
            defer invoices.deinit();

            // Two types, so the registry tells them apart with nothing added
            // to it — and one Store, so one gate bounds both.
            try testing.expect(Avatars != Invoices);
            try testing.expectEqualStrings("/avatars", avatars.prefix);
            try testing.expectEqualStrings("/invoices", invoices.prefix);
            try testing.expectEqual(avatars.store, invoices.store);

            // Starting a Store twice is what providing two buckets does.
            try avatars.nilo_start(io, .off);
            try invoices.nilo_start(io, .off);
        }
    }.run);
}

/// An allocator that counts, so this module's first-axis claim has something
/// holding it.
///
/// A copy of `http/budget.zig` rather than a share of it, and deliberately:
/// `s3/` may not name `nilo_http` — that is sideways, and `zig build layering`
/// refuses it. Twenty-five duplicated lines for a layer property is the same
/// trade [ADR 0043](../docs/adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)
/// made when `nilo_config` grew its own converter.
const Counting = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.vtable.alloc(self.child.ptr, len, a, ra);
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.vtable.resize(self.child.ptr, m, a, n, ra);
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.vtable.remap(self.child.ptr, m, a, n, ra);
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, m, a, ra);
    }
};

/// A Scope whose `arena()` is counted.
///
/// **The counter has to sit above the arena, not below it**, which the first
/// version of this test got backwards: wrapping the allocator a `core.Run` is
/// built on counts the arena's trips to the *backing* allocator, and a warmed
/// arena makes none of those at all — the test read zero and looked like a
/// stronger result than it was. What "allocations per request" means here is
/// trips to the arena, so the counter goes where the caller's allocations
/// land. `http/app.zig`'s budget test wraps an arena the same way round.
const CountedScope = struct {
    _arena: std.heap.ArenaAllocator,
    _counting: Counting,
    _lifetime: core.Lifetime,

    fn init(gpa: std.mem.Allocator) CountedScope {
        return .{
            ._arena = .init(gpa),
            ._counting = undefined,
            ._lifetime = .init(),
        };
    }

    /// Separate from `init` because `_counting` points at `_arena`, and a
    /// struct returned by value has moved by the time the caller holds it.
    fn wire(self: *CountedScope) void {
        self._counting = .{ .child = self._arena.allocator() };
    }

    fn deinit(self: *CountedScope) void {
        self._lifetime.deinit();
        self._arena.deinit();
    }

    // `pub`, because `core.checkScope` asks `@hasDecl` from another file and
    // a private declaration is not visible there. A Scope is a shape, and the
    // shape includes being reachable.
    pub fn arena(self: *CountedScope) std.mem.Allocator {
        return self._counting.allocator();
    }

    pub fn str(self: *CountedScope, bytes: []const u8) core.Str {
        return .fromRequest(bytes, &self._lifetime);
    }

    fn reset(self: *CountedScope) void {
        self._lifetime.end();
        _ = self._arena.reset(.retain_capacity);
    }
};

// A number that is the same on every machine, unlike requests per second, and
// the first of [ADR 0018](../docs/adr/0018-the-trade-budget-has-three-axes.md)'s
// four axes. Until this test existed the claim lived in three doc comments and
// nothing checked it — which is the exact shape this repository has now been
// wrong in five times.
test "a bounded get stays inside its allocation budget" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{
                .body = "the bytes of a very small png",
                .content_type = "image/png",
            };

            // Four rounds on one connection: three to warm, one to measure.
            var served = io.async(Canned.serveMany, .{ &canned, @as(usize, 4) });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: CountedScope = .init(testing.allocator);
            scope.wire();
            defer scope.deinit();

            // Growing the arena is a cost of the first call on a Scope, not of
            // the path being measured — the same warm-up `http/app.zig`'s
            // budget test does, and for the same reason.
            for (0..3) |_| {
                _ = try files.get(&scope, "photos/wati.png");
                scope.reset();
            }

            scope._counting.allocs = 0;
            const object = try files.get(&scope, "photos/wati.png");

            served.await(io) catch {};
            try expectVerified(&canned);
            try testing.expectEqualStrings("the bytes of a very small png", object.bytes.view());

            // One, and it is the body, the content type and the ETag together
            // in a single block — see `finishGet`. Raising this number needs a
            // reason written down beside it.
            try testing.expectEqual(@as(usize, 1), scope._counting.allocs);
        }
    }.run);
}
