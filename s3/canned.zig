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

const fetch = @import("nilo_fetch");

const bucket_mod = @import("bucket.zig");
const multipart_mod = @import("multipart.zig");
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
    /// The Content-Length as sent, which `body` may not have room for: a
    /// multipart part is megabytes, and what a test asserts on is that the
    /// right number arrived, with the first `body.len` bytes to look at.
    declared_len: u64 = 0,

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
    /// A body that arrives a byte at a time instead of at once.
    slow: ?Slow = null,
};

/// `pieces` bytes, `gap_ms` apart. With `hold` the length claimed is one
/// more than is sent and the connection is then kept open until the client
/// closes it: a transfer that went quiet, or one a test keeps open on
/// purpose.
const Slow = struct {
    pieces: usize,
    gap_ms: u32,
    hold: bool = false,
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
    /// Filled by `serveScript`: each request of a protocol, in order.
    played: [8]Played = undefined,
    played_count: usize = 0,

    /// Port 0, and the kernel's answer read back — the account of why this
    /// was a walk of a thousand ports for a cycle, and of the premise that
    /// walk stood on, is on `fetch/live.zig`'s `open`. What it cost here
    /// was a range that had to stay disjoint from that file's by comment,
    /// and once did not: `error.NoFreePort` on the sixth of ten consecutive
    /// `zig build test-all` runs, in whichever s3 test came next.
    fn open(io: std.Io) !Canned {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try address.listen(io, .{});
        return .{ .server = server, .io = io, .port = server.socket.address.getPort() };
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

    /// What `serveScript` keeps of each request, after `seen` is reused for
    /// the next: enough for a test to assert the protocol's shape.
    const Played = struct {
        method: [16]u8 = undefined,
        method_len: usize = 0,
        target: [1024]u8 = undefined,
        target_len: usize = 0,
        body_prefix: [512]u8 = undefined,
        body_prefix_len: usize = 0,
        declared_len: u64 = 0,
        verified: bool = false,
        /// The two headers a copy is about: where it reads from, and what
        /// the object it makes is said to be.
        copy_source: [256]u8 = undefined,
        copy_source_len: usize = 0,
        content_type: [128]u8 = undefined,
        content_type_len: usize = 0,

        fn methodText(self: *const Played) []const u8 {
            return self.method[0..self.method_len];
        }

        fn targetText(self: *const Played) []const u8 {
            return self.target[0..self.target_len];
        }

        fn bodyPrefix(self: *const Played) []const u8 {
            return self.body_prefix[0..self.body_prefix_len];
        }

        fn copySource(self: *const Played) []const u8 {
            return self.copy_source[0..self.copy_source_len];
        }

        fn contentType(self: *const Played) []const u8 {
            return self.content_type[0..self.content_type_len];
        }

        fn keep(room: []u8, len: *usize, value: ?[]const u8) void {
            const v = value orelse return;
            len.* = @min(v.len, room.len);
            @memcpy(room[0..len.*], v[0..len.*]);
        }
    };

    /// One answer per request, in order — a protocol rather than a call.
    /// A client may put the sequence on one pooled connection or dial
    /// again, so a closed connection moves to the next accept rather than
    /// ending the script.
    fn serveScript(self: *Canned, answers: []const Answer) !void {
        // Refused with a name, not an index panic at `played`, for the
        // first script longer than the log.
        if (answers.len > self.played.len) return error.ScriptLongerThanPlayedLog;
        var i: usize = 0;
        while (i < answers.len) {
            var stream = try self.server.accept(self.io);
            defer stream.close(self.io);

            var in_buf: [16 << 10]u8 = undefined;
            var out_buf: [64 << 10]u8 = undefined;
            var reader = stream.reader(self.io, &in_buf);
            var writer = stream.writer(self.io, &out_buf);

            while (i < answers.len) {
                self.seen = .{};
                self.answer = answers[i];
                self.answerOne(&reader.interface, &writer.interface) catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => return err,
                };
                var kept: Played = .{ .verified = self.verified, .declared_len = self.seen.declared_len };
                @memcpy(kept.method[0..self.seen.method_len], self.seen.methodText());
                kept.method_len = self.seen.method_len;
                const target_len = @min(self.seen.target_len, kept.target.len);
                @memcpy(kept.target[0..target_len], self.seen.targetText()[0..target_len]);
                kept.target_len = target_len;
                const body_len = @min(self.seen.body_len, kept.body_prefix.len);
                @memcpy(kept.body_prefix[0..body_len], self.seen.bodyText()[0..body_len]);
                kept.body_prefix_len = body_len;
                Played.keep(&kept.copy_source, &kept.copy_source_len, self.seen.header("x-amz-copy-source"));
                Played.keep(&kept.content_type, &kept.content_type_len, self.seen.header("content-type"));
                self.played[self.played_count] = kept;
                self.played_count += 1;
                i += 1;
            }
        }
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
        const is_head = std.mem.eql(u8, self.seen.methodText(), "HEAD");
        if (self.answer.slow) |slow| {
            // With a body, the pieces are spaces ahead of it: how S3 keeps a
            // long answer's connection alive before the document arrives.
            try w.print("Content-Length: {d}\r\n\r\n", .{slow.pieces + @intFromBool(slow.hold) + body.len});
            try w.flush();
            if (is_head) return;
            for (0..slow.pieces) |_| {
                try std.Io.sleep(self.io, .fromMilliseconds(slow.gap_ms), .awake);
                try w.writeByte(if (body.len > 0) ' ' else 'x');
                try w.flush();
            }
            if (body.len > 0) {
                try w.writeAll(body);
                try w.flush();
            }
            // Until the client lets go, which is `EndOfStream` here.
            if (slow.hold) _ = r.takeByte() catch {};
            return;
        }
        try w.print("Content-Length: {d}\r\n\r\n", .{self.answer.claim_len orelse body.len});
        // A HEAD carries no body however long it says it is, which is the
        // whole of what makes `head` a cheap call.
        if (!is_head) try w.writeAll(body);
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

        self.seen.declared_len = content_length;
        self.seen.body_len = @min(content_length, self.seen.body.len);
        if (self.seen.body_len != 0) try r.readSliceAll(self.seen.body[0..self.seen.body_len]);
        // The rest of a body bigger than the capture, off the socket so the
        // next request on this connection starts at a request line.
        if (content_length > self.seen.body_len)
            try r.discardAll64(content_length - self.seen.body_len);
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
            // Trimall, as S3 does it: no whitespace at either end, and one
            // space for every run inside. Written with `tokenizeAny` rather
            // than the byte walk `sign.zig` uses, so the two can disagree.
            var words = std.mem.tokenizeAny(u8, value, " \t");
            var first_word = true;
            while (words.next()) |word| {
                if (!first_word) w.writeByte(' ') catch return false;
                w.writeAll(word) catch return false;
                first_word = false;
            }
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

// The servers below are started with `io.concurrent` rather than `io.async`,
// for the reason `fetch/live.zig`'s `Canned` gives at length: `async` may run
// the server on the test's own thread, and does on `Threaded` whenever the
// pool is momentarily full — which every bounded call through `nilo_fetch`
// now makes it (ADR 056). A server on the caller's thread is an `accept`
// nobody connects to.
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

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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
            // no TLS underneath to say the bytes arrived as sent (ADR 060).
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash("cinta laut dan langit", &digest, .{});
            var hex: [64]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
            try testing.expectEqualStrings(&hex, canned.seen.header("x-amz-content-sha256").?);
        }
    }.run);
}

test "a header value with two spaces in a row is signed the way S3 reads it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try files.put(&scope, "a.pdf", .{
                .bytes = "x",
                .content_type = "application/pdf",
                .content_disposition = "attachment; filename=\"a  b.pdf\"",
            });

            served.await(io) catch {};
            // The wire keeps the caller's bytes, and the signature is over the
            // folded ones, which the fake rebuilds on its own.
            try testing.expectEqualStrings(
                "attachment; filename=\"a  b.pdf\"",
                canned.seen.header("content-disposition").?,
            );
            try expectVerified(&canned);
        }
    }.run);
}

test "an empty content type is neither signed nor sent" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try files.put(&scope, "a.bin", .{ .bytes = "x", .content_type = "" });

            served.await(io) catch {};
            try expectVerified(&canned);
            try testing.expect(canned.seen.header("content-type") == null);
            const auth = canned.seen.header("authorization").?;
            try testing.expect(std.mem.indexOf(u8, fieldOf(auth, "SignedHeaders=").?, "content-type") == null);
        }
    }.run);
}

test "a streamed put frames its body by length rather than in chunks" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

// Named for what it checks. It used to say "with its code in the log", which
// nothing here holds: the assertions are the mapped error and the signature,
// and the log line is neither read nor captured. A test name is a claim, and
// this file's own history has four entries about claims with nothing behind
// them.
test "S3 saying no becomes one of the seven" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            // The refusal path logs the S3 code on purpose, which is right in a
            // program and noise in a suite — `zig build` prints a red
            // `failed command:` for any step that writes to stderr.
            testing.log_level = .err;
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{
                .status = "404 Not Found",
                .error_body =
                \\<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>
                ,
            };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

test "a list is a signed question about the bucket, and the answer is a page with a cursor" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{
                .content_type = "application/xml",
                .body =
                \\<?xml version="1.0" encoding="UTF-8"?>
                \\<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                \\<Name>files</Name><Prefix>photos%2F</Prefix><KeyCount>2</KeyCount><MaxKeys>2</MaxKeys>
                \\<EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>
                \\<NextContinuationToken>1dEs3p+aG/e=</NextContinuationToken>
                \\<Contents><Key>photos%2Fwati+sari%2B1.png</Key><LastModified>2026-09-18T10:11:12.000Z</LastModified>
                \\<ETag>&quot;9a0364b9e99bb480dd25e1f0284c8555&quot;</ETag><Size>1024</Size><StorageClass>STANDARD</StorageClass></Contents>
                \\<Contents><Key>photos%2Ftwo.png</Key><LastModified>2026-09-18T10:11:13.000Z</LastModified>
                \\<ETag>&#34;abc&#34;</ETag><Size>0</Size></Contents>
                \\</ListBucketResult>
                ,
            };

            // Two pages on one connection, the way a loop over a cursor
            // reaches a real server.
            var served = try io.concurrent(Canned.serveMany, .{ &canned, @as(usize, 2) });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // A page at all is the first request verified: the server
            // answers a signature it did not compute with a 403, which
            // `list` would have handed back as `Rejected`. What it was
            // asked is read off the second request, because `serveMany`
            // clears `seen` the moment it starts reading the next one.
            const first = try files.list(&scope, .{ .prefix = "photos/", .max_keys = 2 });

            try testing.expectEqual(@as(usize, 2), first.objects.len);
            // Decoded: the key out of its percent coding, with `+` a space
            // and `%2B` a plus the way a real server writes them, and the
            // ETag out of its entities and quoted the way `head` hands it
            // back.
            try testing.expectEqualStrings("photos/wati sari+1.png", first.objects[0].key.view());
            try testing.expectEqual(@as(u64, 1024), first.objects[0].size);
            try testing.expectEqualStrings("\"9a0364b9e99bb480dd25e1f0284c8555\"", first.objects[0].etag.view());
            try testing.expectEqualStrings("2026-09-18T10:11:12.000Z", first.objects[0].last_modified.view());
            try testing.expectEqualStrings("photos/two.png", first.objects[1].key.view());
            // Go's encoder, and so MinIO, writes the quote as `&#34;`.
            try testing.expectEqualStrings("\"abc\"", first.objects[1].etag.view());
            try testing.expectEqual(@as(u64, 0), first.objects[1].size);
            try testing.expectEqualStrings("1dEs3p+aG/e=", first.next.?.view());

            // The cursor goes back as it was, encoded for the query and
            // signed as that — nothing follows it for the caller.
            const second = try files.list(&scope, .{
                .prefix = "photos/",
                .max_keys = 2,
                .cursor = first.next.?.view(),
            });
            served.await(io) catch {};
            try expectVerified(&canned);
            try testing.expectEqualStrings("GET", canned.seen.methodText());
            try testing.expectEqualStrings("/files/", canned.seen.path());
            try testing.expectEqualStrings(
                "continuation-token=1dEs3p%2BaG%2Fe%3D&encoding-type=url&list-type=2&max-keys=2&prefix=photos%2F",
                canned.seen.query(),
            );
            try testing.expectEqualStrings(sign.empty_payload, canned.seen.header("x-amz-content-sha256").?);
            try testing.expectEqual(@as(usize, 2), second.objects.len);
        }
    }.run);
}

/// One list answered with `body`, the way a server would. The page is in
/// `scope`, so it outlives the server and the Store that made it.
fn listAnswered(io: std.Io, scope: *core.Run, body: []const u8) !bucket_mod.Page {
    var canned = try Canned.open(io);
    defer canned.close();
    canned.answer = .{ .content_type = "application/xml", .body = body };

    var served = try io.concurrent(Canned.serveOne, .{&canned});
    defer served.cancel(io) catch {};

    var buf: [64]u8 = undefined;
    var store = try started(io, &canned, &buf);
    defer store.deinit();

    var files = try Files.open(&store);
    defer files.deinit();

    return files.list(scope, .{ .max_keys = 2 });
}

test "a truncated page with no continuation token fails rather than ending the listing" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            // Read as the last page, this is silent data loss for a loop that
            // walks a bucket: it looks exactly like a complete listing.
            try testing.expectError(error.Failed, listAnswered(io, &scope,
                \\<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>
                \\<Contents><Key>a</Key><LastModified>t</LastModified><ETag>&quot;e&quot;</ETag><Size>1</Size></Contents>
                \\</ListBucketResult>
            ));
        }
    }.run);
}

test "a truncated page with an empty or over-long continuation token fails" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            // An empty one would go back as `continuation-token=`, a 400.
            try testing.expectError(error.Failed, listAnswered(io, &scope,
                \\<ListBucketResult><IsTruncated>true</IsTruncated>
                \\<NextContinuationToken></NextContinuationToken></ListBucketResult>
            ));
            // One past the ceiling `list` itself refuses to send back.
            const long = "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>" ++
                "c" ** 1025 ++ "</NextContinuationToken></ListBucketResult>";
            try testing.expectError(error.Failed, listAnswered(io, &scope, long));
        }
    }.run);
}

test "a key is percent-decoded only when the answer says it is encoded" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            const plain = try listAnswered(io, &scope,
                \\<ListBucketResult><IsTruncated>false</IsTruncated>
                \\<Contents><Key>100%41+a b</Key><LastModified>t</LastModified><ETag>&quot;e&quot;</ETag><Size>1</Size></Contents>
                \\</ListBucketResult>
            );
            try testing.expectEqualStrings("100%41+a b", plain.objects[0].key.view());

            const encoded = try listAnswered(io, &scope,
                \\<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>
                \\<Contents><Key>100%2541+a+b</Key><LastModified>t</LastModified><ETag>&quot;e&quot;</ETag><Size>1</Size></Contents>
                \\</ListBucketResult>
            );
            try testing.expectEqualStrings("100%41 a b", encoded.objects[0].key.view());
        }
    }.run);
}

test "a list asking for more than a page, or a prefix longer than a key, is refused before a socket" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // Nothing is served: a refusal here never reaches the wire.
            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.Rejected, files.list(&scope, .{ .max_keys = 1001 }));
            try testing.expectError(error.Rejected, files.list(&scope, .{ .max_keys = 0 }));
            const long = "k" ** 513;
            try testing.expectError(error.Rejected, files.list(&scope, .{ .prefix = long }));
            const cursor = "c" ** 1025;
            try testing.expectError(error.Rejected, files.list(&scope, .{ .cursor = cursor }));
        }
    }.run);
}

test "a streamed get pipes the object out without holding it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .body = "a body too big to want in an arena", .content_type = "video/mp4" };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var reading: Files.Reading = .idle;
            defer reading.close();

            try files.stream(&scope, "video/one.mp4", &reading);

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

/// A Store with the streaming knobs a test wants small.
fn startedWith(io: std.Io, canned: *Canned, buf: []u8, extra: struct {
    timeout_ms: u32 = 30_000,
    stall_ms: u32 = 30_000,
    max_in_flight: u32 = 32,
    max_streams: u32 = 0,
}) !Store {
    var store = try Store.open(testing.allocator, .{
        .endpoint = try canned.endpoint(buf),
        .region = "us-east-1",
        .credentials = .{ .static = .{ .access_key_id = akid, .secret_access_key = secret } },
        .timeout_ms = extra.timeout_ms,
        .stall_ms = extra.stall_ms,
        .max_in_flight = extra.max_in_flight,
        .max_streams = extra.max_streams,
    });
    errdefer store.deinit();
    try store.nilo_start(io, .off);
    return store;
}

fn nowMs() i64 {
    return @divTrunc(core.monotonicMicros(), std.time.us_per_ms);
}

test "a streamed get that is slower than the call timeout but never goes quiet completes" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // 24 bytes, 60 ms apart: 1.44 s against a call timeout of 150 ms,
            // and no gap anywhere near the one-second stall bound. A second
            // because the gaps are sleeps, and on the loaded macOS runner a
            // 60 ms sleep was measured at up to 135 ms (fetch's twin of this
            // test, in `fetch/live.zig`, says the same).
            canned.answer = .{ .slow = .{ .pieces = 24, .gap_ms = 60 } };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try startedWith(io, &canned, &buf, .{ .timeout_ms = 150, .stall_ms = 1000 });
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var reading: Files.Reading = .idle;
            defer reading.close();
            try files.stream(&scope, "video/one.mp4", &reading);

            var out: [32]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);
            try testing.expectEqual(@as(u64, 24), try reading.pipe(&w));
            try testing.expectEqualStrings("x" ** 24, w.buffered());
        }
    }.run);
}

test "a streamed get whose peer goes quiet is cut at the stall bound, not left to the call timeout" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .slow = .{ .pieces = 2, .gap_ms = 20, .hold = true } };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try startedWith(io, &canned, &buf, .{ .stall_ms = 150 });
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var reading: Files.Reading = .idle;
            defer reading.close();
            try files.stream(&scope, "video/one.mp4", &reading);

            var out: [32]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);
            const began = nowMs();
            try testing.expectError(error.TimedOut, reading.pipe(&w));
            // The Store's call timeout is 30 s; this ended on the stall bound.
            try testing.expect(nowMs() - began < 5_000);
        }
    }.run);
}

test "a streamed get takes the call timeout the caller set for it, and only that one" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // Moving all the time, so only the whole-call limit can end it.
            canned.answer = .{ .slow = .{ .pieces = 40, .gap_ms = 25 } };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try startedWith(io, &canned, &buf, .{ .stall_ms = 5_000 });
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var reading: Files.Reading = .{ .timeout_ms = 200 };
            defer reading.close();
            try files.stream(&scope, "video/one.mp4", &reading);

            var out: [64]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);
            try testing.expectError(error.TimedOut, reading.pipe(&w));
        }
    }.run);
}

test "a streamed put that keeps moving outlasts the call timeout, and one that goes quiet is cut" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try startedWith(io, &canned, &buf, .{ .timeout_ms = 150, .stall_ms = 1000 });
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // 1.44 s against a 150 ms call timeout, a byte every 60 ms, under
            // a one-second stall bound. It was 8 bytes under 300 ms, and a
            // 60 ms sleep on the loaded macOS runner went past that.
            var source: fetch.testing.Dribble = .init(io, 24, 60);
            try files.putStream(&scope, "big/one.bin", .{
                .reader = &source.reader,
                .len = @as(u64, 24),
                .content_type = "application/octet-stream",
            });
            try testing.expectEqualStrings("y" ** 24, canned.seen.bodyText());
        }
    }.run);
}

test "a streamed put whose source goes quiet is cut at the stall bound" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try startedWith(io, &canned, &buf, .{ .stall_ms = 100 });
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var source: fetch.testing.Dribble = .init(io, 2, 1_500);
            const began = nowMs();
            try testing.expectError(error.TimedOut, files.putStream(&scope, "big/one.bin", .{
                .reader = &source.reader,
                .len = @as(u64, 2),
                .content_type = "application/octet-stream",
            }));
            try testing.expect(nowMs() - began < 1_200);
            // Both the permit and the stream slot came back.
            try testing.expectEqual(@as(usize, store.options.max_in_flight), store.client.gate.permits);
            try testing.expectEqual(@as(usize, store.options.max_streams), store.streams.permits);
        }
    }.run);
}

test "a streamed put takes the whole-call limit its source names" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try startedWith(io, &canned, &buf, .{ .stall_ms = 5_000 });
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var source: fetch.testing.Dribble = .init(io, 40, 25);
            try testing.expectError(error.TimedOut, files.putStream(&scope, "big/one.bin", .{
                .reader = &source.reader,
                .len = @as(u64, 40),
                .content_type = "application/octet-stream",
                .timeout_ms = @as(u32, 200),
            }));
        }
    }.run);
}

test "streams are a share of the permits, so a head still gets one when every stream slot is taken" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // Every connection is told the same: a GET that sends a byte and
            // then holds the transfer open, and a HEAD that is answered.
            canned.answer = .{ .slow = .{ .pieces = 1, .gap_ms = 1, .hold = true } };
            var second = canned;
            var third = canned;

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};
            var served_two = try io.concurrent(Canned.serveOne, .{&second});
            defer served_two.cancel(io) catch {};
            var served_three = try io.concurrent(Canned.serveOne, .{&third});
            defer served_three.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try startedWith(io, &canned, &buf, .{ .max_in_flight = 2, .max_streams = 1 });
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // The one stream slot, held open.
            var first: Files.Reading = .idle;
            defer first.close();
            try files.stream(&scope, "a.mp4", &first);

            // A second stream has to wait for it, though a permit is free.
            const Opener = struct {
                fn open(f: *Files, sc: *core.Run, r: *Files.Reading, done: *std.atomic.Value(u32)) !void {
                    defer done.store(1, .release);
                    try f.stream(sc, "b.mp4", r);
                }
            };
            var other: Files.Reading = .idle;
            defer other.close();
            var done: std.atomic.Value(u32) = .init(0);
            var opening = try io.concurrent(Opener.open, .{ &files, &scope, &other, &done });
            defer opening.cancel(io) catch {};
            try std.Io.sleep(io, .fromMilliseconds(150), .awake);
            try testing.expectEqual(@as(u32, 0), done.load(.acquire));

            // And a short call is not queued behind either of them.
            const meta = try files.head(&scope, "a.mp4");
            try testing.expectEqual(@as(u64, 2), meta.len);

            // Letting the first go lets the second in, inside a bound.
            first.close();
            for (0..400) |_| {
                if (done.load(.acquire) != 0) break;
                try std.Io.sleep(io, .fromMilliseconds(5), .awake);
            } else return error.TestTimedOut;
            try opening.await(io);
        }
    }.run);
}

test "a stream that fails to open gives its slot back" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .status = "404 Not Found", .error_body = "<Error><Code>NoSuchKey</Code></Error>" };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try startedWith(io, &canned, &buf, .{ .max_in_flight = 2, .max_streams = 1 });
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var reading: Files.Reading = .idle;
            try testing.expectError(error.NotFound, files.stream(&scope, "gone.mp4", &reading));
            // Released by `stream` itself, before the caller's `close`.
            try testing.expectEqual(@as(usize, 1), store.streams.permits);
            try testing.expectEqual(@as(usize, 2), store.client.gate.permits);
            reading.close();
            try testing.expectEqual(@as(usize, 1), store.streams.permits);
        }
    }.run);
}

test "a conditional get is a union, because a 304 is a success" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .status = "304 Not Modified", .body = "" };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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

            var served = try io.concurrent(Canned.serveOne, .{&canned});
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
            // Says it in a log line, which is the point of the test and noise
            // in the build output. The error is what gets asserted.
            testing.log_level = .err;
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

/// The value of one form field, by name.
fn fieldOfForm(posted: bucket_mod.Posted, name: []const u8) ?[]const u8 {
    for (posted.fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

test "a presigned POST is a form, and its policy decodes to the document that was signed" {
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

            const posted = try files.presignPost(&scope, "receipts/2026/09.pdf", .{
                .seconds = 900,
                .content_type = "application/pdf",
                // Asked for 50 MiB against a bucket whose `max_bytes` is one,
                // so one is what the policy says.
                .max_bytes = 50 << 20,
            });

            // The form posts to the bucket, not to the key. A browser that had
            // to post to the key could not pick its own filename.
            var action: [64]u8 = undefined;
            try testing.expectEqualStrings(
                try std.fmt.bufPrint(&action, "http://127.0.0.1:{d}/files", .{canned.port}),
                posted.url,
            );

            const policy = fieldOfForm(posted, "policy").?;
            const date = fieldOfForm(posted, "x-amz-date").?;
            const credential = fieldOfForm(posted, "x-amz-credential").?;

            // What the browser sends is base64, so the document itself is only
            // reachable by decoding it, which is what S3 does and therefore the
            // only reading of it worth asserting on.
            const decoder = std.base64.standard.Decoder;
            const doc = try scope.arena().alloc(u8, try decoder.calcSizeForSlice(policy));
            try decoder.decode(doc, policy);

            // Built from the two timestamps the form itself carries rather
            // than from a second clock read, so this cannot fail on a second
            // boundary. It also means a policy disagreeing with its own
            // `x-amz-date` field, which is a 403 that reads like a signing
            // bug, fails here.
            const dies: sign.Stamp = .at(posted.expires_at);
            var expiry: [sign.Stamp.expiration_len]u8 = undefined;

            var expected: [512]u8 = undefined;
            try testing.expectEqualStrings(try std.fmt.bufPrint(
                &expected,
                "{{\"expiration\":\"{s}\",\"conditions\":[" ++
                    "{{\"bucket\":\"files\"}}," ++
                    "[\"eq\",\"$key\",\"receipts/2026/09.pdf\"]," ++
                    "{{\"x-amz-algorithm\":\"AWS4-HMAC-SHA256\"}}," ++
                    "{{\"x-amz-credential\":\"{s}\"}}," ++
                    "{{\"x-amz-date\":\"{s}\"}}," ++
                    "[\"eq\",\"$Content-Type\",\"application/pdf\"]," ++
                    "[\"content-length-range\",0,1048576]" ++
                    "]}}",
                .{ dies.expiration(&expiry), credential, date },
            ), doc);

            // Asked for fifteen minutes and the bucket allows an hour, so
            // fifteen minutes is what comes back.
            try testing.expectEqual(@divFloor(core.nowMillis(), 1000) + 900, posted.expires_at);

            // The fields, in the order a form is written against. No token,
            // because these credentials are a static pair. The bucket first,
            // as it is in the policy: Garage refuses a form without the field
            // and AWS reads it off the URL (ADR 177).
            try testing.expectEqual(@as(usize, 8), posted.fields.len);
            try testing.expectEqualStrings("bucket", posted.fields[0].name);
            try testing.expectEqualStrings("files", posted.fields[0].value);
            try testing.expectEqualStrings("key", posted.fields[1].name);
            try testing.expectEqualStrings("receipts/2026/09.pdf", posted.fields[1].value);
            try testing.expectEqualStrings("x-amz-algorithm", posted.fields[2].name);
            try testing.expectEqualStrings("AWS4-HMAC-SHA256", posted.fields[2].value);
            try testing.expectEqualStrings("x-amz-credential", posted.fields[3].name);
            try testing.expectEqualStrings("x-amz-date", posted.fields[4].name);
            try testing.expectEqualStrings("Content-Type", posted.fields[5].name);
            try testing.expectEqualStrings("application/pdf", posted.fields[5].value);
            try testing.expectEqualStrings("policy", posted.fields[6].name);
            // Last, because everything before it is what the signature covers.
            try testing.expectEqualStrings("x-amz-signature", posted.fields[7].name);

            // A credential is the key id and the day's scope, joined the way
            // S3 reads it back.
            var scoped: [128]u8 = undefined;
            try testing.expectEqualStrings(try std.fmt.bufPrint(
                &scoped,
                akid ++ "/{s}/us-east-1/s3/aws4_request",
                .{date[0..8]},
            ), credential);
        }
    }.run);
}

test "a public endpoint is the host in a presigned URL, and the host that is signed" {
    // Item 77: the process dials a store the browser cannot reach, and a
    // URL rewritten after signing is a 403, because the host is inside the
    // signature. The oracle is a second store that *dials* the public name:
    // the two must sign byte for byte the same (ADR 177).
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var buf: [64]u8 = undefined;
            var behind = try Store.open(testing.allocator, .{
                .endpoint = try canned.endpoint(&buf),
                .public_endpoint = "https://files.example.com",
                .region = "us-east-1",
                .credentials = .{ .static = .{ .access_key_id = akid, .secret_access_key = secret } },
            });
            defer behind.deinit();
            try behind.nilo_start(io, .off);

            var direct = try Store.open(testing.allocator, .{
                .endpoint = "https://files.example.com",
                .region = "us-east-1",
                .credentials = .{ .static = .{ .access_key_id = akid, .secret_access_key = secret } },
            });
            defer direct.deinit();
            try direct.nilo_start(io, .off);

            var files = try Files.open(&behind);
            defer files.deinit();
            var same = try Files.open(&direct);
            defer same.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // Both in the same second, or again: the stamp is in the URL and
            // a boundary between the two calls is not what is being tested.
            var tries: usize = 0;
            while (tries < 5) : (tries += 1) {
                const link = try files.presign(&scope, "photos/wati.png", 900);
                const oracle = try same.presign(&scope, "photos/wati.png", 900);
                if (link.expires_at != oracle.expires_at) continue;
                try testing.expectEqualStrings(oracle.url.view(), link.url.view());
                try testing.expect(std.mem.startsWith(u8, link.url.view(), "https://files.example.com/files/photos/wati.png?"));
                break;
            } else return error.ClockNeverSettled;

            // The form posts to the public name too. Nothing else in it
            // changes: a policy names no host.
            const posted = try files.presignPost(&scope, "receipts/09.pdf", .{ .seconds = 900 });
            try testing.expectEqualStrings("https://files.example.com/files", posted.url);
            const oracle = try same.presignPost(&scope, "receipts/09.pdf", .{ .seconds = 900 });
            try testing.expectEqualStrings(oracle.url, posted.url);
        }
    }.run);
}

test "a POST policy is signed with the day's key, and nothing more" {
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

            const posted = try files.presignPost(&scope, "receipts/one.pdf", .{ .seconds = 900 });
            const policy = fieldOfForm(posted, "policy").?;
            const date = fieldOfForm(posted, "x-amz-date").?;

            // The four HMACs and the fifth, written out longhand. Calling
            // `sign.derive` and `sign.signature` here would be the code under
            // test checking itself: this is the specification, typed again.
            const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
            var key: [32]u8 = undefined;
            Hmac.create(&key, date[0..8], "AWS4" ++ secret);
            Hmac.create(&key, "us-east-1", &key);
            Hmac.create(&key, "s3", &key);
            Hmac.create(&key, "aws4_request", &key);

            // The signature is one HMAC of the **base64**, not of the document
            // and not of a canonical request. Signing the decoded bytes is the
            // mistake that produces a perfectly formed 403.
            var mac: [32]u8 = undefined;
            Hmac.create(&mac, policy, &key);

            var hex: [64]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex, "{x}", .{&mac});
            try testing.expectEqualStrings(&hex, fieldOfForm(posted, "x-amz-signature").?);
        }
    }.run);
}

test "a prefix policy says starts-with, so the browser picks the filename" {
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

            // Asked for a day against a `presign_max` of an hour, so an hour
            // is the life, exactly as `presign` clamps it.
            const posted = try files.presignPost(&scope, "attachments/42/", .{
                .seconds = 86_400,
                .prefix = true,
            });
            try testing.expectEqual(@divFloor(core.nowMillis(), 1000) + 3600, posted.expires_at);

            const policy = fieldOfForm(posted, "policy").?;
            const decoder = std.base64.standard.Decoder;
            const doc = try scope.arena().alloc(u8, try decoder.calcSizeForSlice(policy));
            try decoder.decode(doc, policy);

            try testing.expect(std.mem.indexOf(
                u8,
                doc,
                "[\"starts-with\",\"$key\",\"attachments/42/\"]",
            ) != null);

            // No content type was asked for, so nothing constrains it: an
            // attachment box takes a PDF and a screenshot on one form.
            try testing.expect(std.mem.indexOf(u8, doc, "Content-Type") == null);
            try testing.expectEqual(@as(?[]const u8, null), fieldOfForm(posted, "Content-Type"));

            // And the ceiling is there even though nobody asked for one,
            // because a form with no ceiling is not something this call hands
            // out. `Files` is a mebibyte.
            try testing.expect(std.mem.indexOf(u8, doc, "[\"content-length-range\",0,1048576]") != null);

            // The `key` field is what the form extends, so it goes out as it
            // was given rather than as a completed key.
            try testing.expectEqualStrings("attachments/42/", fieldOfForm(posted, "key").?);
        }
    }.run);
}

test "temporary credentials put their token in the form and in the policy" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var buf: [64]u8 = undefined;
            var store = try Store.open(testing.allocator, .{
                .endpoint = try canned.endpoint(&buf),
                .region = "us-east-1",
                .credentials = .{
                    .static = .{
                        .access_key_id = akid,
                        .secret_access_key = secret,
                        .session_token = "FQoGZXIvYXdzEBYaDN0EXAMPLETOKEN",
                        // Ten minutes left, against a form asking for an hour: the
                        // credentials are the smallest of the three, so they are
                        // what `expires_at` reports.
                        .expires_at = @divFloor(core.nowMillis(), 1000) + 600,
                    },
                },
            });
            defer store.deinit();
            try store.nilo_start(io, .off);

            const Temp = bucket_mod.Bucket("temp", .{ .style = .path, .session_token_max = 2048 });
            var temp = try Temp.open(&store);
            defer temp.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const posted = try temp.presignPost(&scope, "one.pdf", .{ .seconds = 3600 });
            try testing.expectEqual(@divFloor(core.nowMillis(), 1000) + 600, posted.expires_at);

            try testing.expectEqualStrings(
                "FQoGZXIvYXdzEBYaDN0EXAMPLETOKEN",
                fieldOfForm(posted, "x-amz-security-token").?,
            );

            const policy = fieldOfForm(posted, "policy").?;
            const decoder = std.base64.standard.Decoder;
            const doc = try scope.arena().alloc(u8, try decoder.calcSizeForSlice(policy));
            try decoder.decode(doc, policy);

            // Sent and signed. A token in the form that the policy does not
            // name is a 403, and a policy naming one the form does not send is
            // the same 403 from the other side.
            try testing.expect(std.mem.indexOf(
                u8,
                doc,
                "{\"x-amz-security-token\":\"FQoGZXIvYXdzEBYaDN0EXAMPLETOKEN\"}",
            ) != null);
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
/// trade [ADR 039](../docs/adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)
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
// the first of [ADR 017](../docs/adr/017-the-trade-budget-has-four-axes.md)'s
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
            var served = try io.concurrent(Canned.serveMany, .{ &canned, @as(usize, 4) });
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

test "an empty key is refused by every object call, because it addresses the bucket" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            testing.log_level = .err;
            var canned = try Canned.open(io);
            defer canned.close();
            // Nothing is served: a refusal here never reaches the wire.
            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.Rejected, files.get(&scope, ""));
            try testing.expectError(error.Rejected, files.getRange(&scope, "", .{ .from = 0, .to = 1 }));
            try testing.expectError(error.Rejected, files.getIf(&scope, "", "\"e\""));
            try testing.expectError(error.Rejected, files.head(&scope, ""));
            try testing.expectError(error.Rejected, files.delete(&scope, ""));
            try testing.expectError(error.Rejected, files.put(&scope, "", .{
                .bytes = scope.str("x"),
                .content_type = scope.str("text/plain"),
            }));
            var source = std.Io.Reader.fixed("x");
            try testing.expectError(error.Rejected, files.putStream(&scope, "", .{
                .reader = &source,
                .len = @as(u64, 1),
                .content_type = "text/plain",
            }));
            var reading: Files.Reading = .idle;
            defer reading.close();
            try testing.expectError(error.Rejected, files.stream(&scope, "", &reading));
            try testing.expectError(error.Rejected, files.presign(&scope, "", 60));
            try testing.expectError(error.Rejected, files.presignPut(&scope, "", 60));
            try testing.expectError(error.Rejected, files.presignPost(&scope, "", .{ .seconds = 60 }));
        }
    }.run);
}

test "an empty prefix is still a prefix policy and a listing of the root still lists" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{
                .content_type = "application/xml",
                .body = "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>",
            };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const posted = try files.presignPost(&scope, "", .{ .seconds = 60, .prefix = true });
            try testing.expect(posted.fields.len != 0);

            const page = try files.list(&scope, .{});
            try testing.expectEqual(@as(usize, 0), page.objects.len);
            served.await(io) catch {};
            try expectVerified(&canned);
        }
    }.run);
}

test "a header value with a control byte is refused before anything is sent" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            testing.log_level = .err;
            var canned = try Canned.open(io);
            defer canned.close();
            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var files = try Files.open(&store);
            defer files.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.Rejected, files.put(&scope, "a.txt", .{
                .bytes = scope.str("x"),
                .content_type = "text/plain",
                .content_disposition = "attachment; filename=\"a\r\nx-evil: 1\"",
            }));
            try testing.expectError(error.Rejected, files.put(&scope, "a.txt", .{
                .bytes = scope.str("x"),
                .content_type = "text/plain\r\nx-evil: 1",
            }));
            try testing.expectError(error.Rejected, files.put(&scope, "a.txt", .{
                .bytes = scope.str("x"),
                .content_type = "text/plain",
                .cache_control = "no-cache\x00",
            }));
            try testing.expectError(error.Rejected, files.put(&scope, "a.txt", .{
                .bytes = scope.str("x"),
                .content_type = "text/plain",
                .content_disposition = "attachment\x7f",
            }));
            try testing.expectError(error.Rejected, files.getIf(&scope, "a.txt", "\"e\"\r\nx-evil: 1"));
            var source = std.Io.Reader.fixed("x");
            try testing.expectError(error.Rejected, files.putStream(&scope, "a.txt", .{
                .reader = &source,
                .len = @as(u64, 1),
                .content_type = "text/plain\n",
            }));
        }
    }.run);
}

test "a tab in a header value is allowed" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try files.put(&scope, "a.txt", .{
                .bytes = scope.str("x"),
                .content_type = "text/plain",
                .cache_control = "no-cache,\tno-store",
            });
            served.await(io) catch {};
            try expectVerified(&canned);
        }
    }.run);
}

test "a presign with the largest token a bucket may declare fits its buffer" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            // `+` is the worst case: three bytes once percent-encoded.
            const token = "+" ** sign.token_max;
            var buf: [64]u8 = undefined;
            var store = try Store.open(testing.allocator, .{
                .endpoint = try canned.endpoint(&buf),
                .credentials = .{ .static = .{
                    .access_key_id = akid,
                    .secret_access_key = secret,
                    .session_token = token,
                } },
            });
            defer store.deinit();
            try store.nilo_start(io, .off);

            const Temp = bucket_mod.Bucket("temp", .{ .style = .path, .session_token_max = sign.token_max });
            var temp = try Temp.open(&store);
            defer temp.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const link = try temp.presign(&scope, "one.txt", 60);
            try testing.expect(std.mem.indexOf(u8, link.url.view(), "X-Amz-Security-Token=%2B%2B") != null);
        }
    }.run);
}

// ---- multipart: the protocol against a server that checks every signature --

const initiate_answer_body =
    "<InitiateMultipartUploadResult><Bucket>files</Bucket><Key>big.bin</Key>" ++
    "<UploadId>canned-upload</UploadId></InitiateMultipartUploadResult>";
const completed_answer_body =
    "<CompleteMultipartUploadResult><ETag>\"whole\"</ETag></CompleteMultipartUploadResult>";
const error_answer_body =
    "<Error><Code>InternalError</Code><Message>we dropped it</Message></Error>";

/// A source big enough to be a real multipart: one full part and `tail`
/// more. Freed by the caller.
fn multipartBody(tail: usize) ![]u8 {
    const body = try testing.allocator.alloc(u8, multipart_mod.part_min + tail);
    for (body, 0..) |*b, i| b.* = @truncate(i);
    return body;
}

test "a multipart upload signs its three queries, and the completion lists every part" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Answer{
                .{ .body = initiate_answer_body, .content_type = "application/xml" },
                .{ .etag = "\"p1\"" },
                .{ .etag = "\"p2\"" },
                .{ .body = completed_answer_body, .content_type = "application/xml" },
            } });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const body = try multipartBody(123);
            defer testing.allocator.free(body);
            var reader = std.Io.Reader.fixed(body);
            try files.putMultipart(&scope, "big.bin", .{
                .reader = &reader,
                .content_type = "application/octet-stream",
                .part_bytes = multipart_mod.part_min,
            });

            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 4), canned.played_count);
            for (canned.played[0..4]) |step| try testing.expect(step.verified);

            try testing.expectEqualStrings("POST", canned.played[0].methodText());
            try testing.expectEqualStrings("/files/big.bin?uploads=", canned.played[0].targetText());
            try testing.expectEqualStrings("PUT", canned.played[1].methodText());
            try testing.expectEqualStrings("/files/big.bin?partNumber=1&uploadId=canned-upload", canned.played[1].targetText());
            try testing.expectEqual(@as(u64, multipart_mod.part_min), canned.played[1].declared_len);
            try testing.expectEqualStrings("/files/big.bin?partNumber=2&uploadId=canned-upload", canned.played[2].targetText());
            try testing.expectEqual(@as(u64, 123), canned.played[2].declared_len);
            try testing.expectEqualStrings("POST", canned.played[3].methodText());
            try testing.expectEqualStrings("/files/big.bin?uploadId=canned-upload", canned.played[3].targetText());
            try testing.expectEqualStrings(
                "<CompleteMultipartUpload>" ++
                    "<Part><PartNumber>1</PartNumber><ETag>\"p1\"</ETag></Part>" ++
                    "<Part><PartNumber>2</PartNumber><ETag>\"p2\"</ETag></Part>" ++
                    "</CompleteMultipartUpload>",
                canned.played[3].bodyPrefix(),
            );
        }
    }.run);
}

test "a failed part aborts the upload rather than abandoning it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Answer{
                .{ .body = initiate_answer_body, .content_type = "application/xml" },
                .{ .status = "500 Internal Server Error", .error_body = error_answer_body },
                .{ .status = "204 No Content" },
            } });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const body = try multipartBody(0);
            defer testing.allocator.free(body);
            var reader = std.Io.Reader.fixed(body);
            try testing.expectError(error.Unavailable, files.putMultipart(&scope, "big.bin", .{
                .reader = &reader,
                .content_type = "application/octet-stream",
                .part_bytes = multipart_mod.part_min,
            }));

            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 3), canned.played_count);
            try testing.expectEqualStrings("DELETE", canned.played[2].methodText());
            try testing.expectEqualStrings("/files/big.bin?uploadId=canned-upload", canned.played[2].targetText());
            try testing.expect(canned.played[2].verified);
        }
    }.run);
}

test "a completion answered 200 with an error in the body is a failure, and aborts" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{
                &canned,
                &[_]Answer{
                    .{ .body = initiate_answer_body, .content_type = "application/xml" },
                    .{ .etag = "\"p1\"" },
                    // The trap itself: a 200 whose body says no.
                    .{ .body = error_answer_body, .content_type = "application/xml" },
                    .{ .status = "204 No Content" },
                },
            });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const body = try multipartBody(0);
            defer testing.allocator.free(body);
            var reader = std.Io.Reader.fixed(body);
            try testing.expectError(error.Failed, files.putMultipart(&scope, "big.bin", .{
                .reader = &reader,
                .content_type = "application/octet-stream",
                .part_bytes = multipart_mod.part_min,
            }));

            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 4), canned.played_count);
            try testing.expectEqualStrings("DELETE", canned.played[3].methodText());
            try testing.expectEqualStrings("/files/big.bin?uploadId=canned-upload", canned.played[3].targetText());
        }
    }.run);
}

test "a part answered without an ETag fails there, not at the completion" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Answer{
                .{ .body = initiate_answer_body, .content_type = "application/xml" },
                .{ .etag = "" },
                .{ .status = "204 No Content" },
            } });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const body = try multipartBody(0);
            defer testing.allocator.free(body);
            var reader = std.Io.Reader.fixed(body);
            try testing.expectError(error.Failed, files.putMultipart(&scope, "big.bin", .{
                .reader = &reader,
                .content_type = "application/octet-stream",
                .part_bytes = multipart_mod.part_min,
            }));

            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 3), canned.played_count);
            try testing.expectEqualStrings("DELETE", canned.played[2].methodText());
        }
    }.run);
}

test "a source smaller than one part is a plain PUT, one round trip" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Answer{
                .{},
            } });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var reader = std.Io.Reader.fixed("three dozen bytes, give or take");
            try files.putMultipart(&scope, "small.bin", .{
                .reader = &reader,
                .content_type = "text/plain",
                .cache_control = "max-age=60",
            });

            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 1), canned.played_count);
            try testing.expectEqualStrings("PUT", canned.played[0].methodText());
            // No query: the protocol never started.
            try testing.expectEqualStrings("/files/small.bin", canned.played[0].targetText());
            try testing.expect(canned.played[0].verified);
            try testing.expectEqualStrings("three dozen bytes, give or take", canned.played[0].bodyPrefix());
        }
    }.run);
}

// ---- copy and compose: inside the store, and a 200 that is not one --------

const copied_answer_body =
    "<CopyObjectResult><LastModified>2026-10-05T00:00:00.000Z</LastModified>" ++
    "<ETag>&quot;copied&quot;</ETag></CopyObjectResult>";

fn partCopied(comptime etag: []const u8) []const u8 {
    return "<CopyPartResult><LastModified>2026-10-05T00:00:00.000Z</LastModified>" ++
        "<ETag>&quot;" ++ etag ++ "&quot;</ETag></CopyPartResult>";
}

test "a copy names its source in a signed header, and reads the body for its result" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Answer{
                .{ .body = copied_answer_body, .content_type = "application/xml" },
            } });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try files.copy(&scope, "staged/a b.bin", "items/whole.bin");

            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 1), canned.played_count);
            try testing.expect(canned.played[0].verified);
            try testing.expectEqualStrings("PUT", canned.played[0].methodText());
            try testing.expectEqualStrings("/files/items/whole.bin", canned.played[0].targetText());
            try testing.expectEqualStrings("/files/staged/a%20b.bin", canned.played[0].copySource());
        }
    }.run);
}

test "a copy that outlasts the Store's call timeout but never goes quiet completes" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            // The store copies for 1.44 s, sending a space every 60 ms, against
            // a call timeout of 150 ms: only the stall bound may cut a copy,
            // or a large one fails while the store finishes it anyway.
            canned.answer = .{
                .body = copied_answer_body,
                .content_type = "application/xml",
                .slow = .{ .pieces = 24, .gap_ms = 60 },
            };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try startedWith(io, &canned, &buf, .{ .timeout_ms = 150, .stall_ms = 1000 });
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try files.copy(&scope, "staged/big.bin", "items/big.bin");
        }
    }.run);
}

test "a copy answered 200 with an error in the body is a failure" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{
                &canned,
                &[_]Answer{
                    // The trap ADR 058 pinned to COPY: a 200 whose body says no.
                    .{ .body = error_answer_body, .content_type = "application/xml" },
                },
            });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.Failed, files.copy(&scope, "a.bin", "b.bin"));
            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 1), canned.played_count);
        }
    }.run);
}

test "a compose joins its parts by copy, says what the joined object is, and lists every part" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Answer{
                .{ .body = initiate_answer_body, .content_type = "application/xml" },
                .{ .body = partCopied("p1"), .content_type = "application/xml" },
                .{ .body = partCopied("p2"), .content_type = "application/xml" },
                .{ .body = completed_answer_body, .content_type = "application/xml" },
            } });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try files.compose(&scope, "big.bin", &.{ "pieces/1", "pieces/2" }, .{ .content_type = "video/mp4" });

            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 4), canned.played_count);
            for (canned.played[0..4]) |step| try testing.expect(step.verified);
            try testing.expectEqualStrings("/files/big.bin?uploads=", canned.played[0].targetText());
            try testing.expectEqualStrings("video/mp4", canned.played[0].contentType());
            try testing.expectEqualStrings("/files/big.bin?partNumber=1&uploadId=canned-upload", canned.played[1].targetText());
            try testing.expectEqualStrings("/files/pieces/1", canned.played[1].copySource());
            try testing.expectEqualStrings("/files/big.bin?partNumber=2&uploadId=canned-upload", canned.played[2].targetText());
            try testing.expectEqualStrings("/files/pieces/2", canned.played[2].copySource());
            try testing.expectEqualStrings(
                "<CompleteMultipartUpload>" ++
                    "<Part><PartNumber>1</PartNumber><ETag>\"p1\"</ETag></Part>" ++
                    "<Part><PartNumber>2</PartNumber><ETag>\"p2\"</ETag></Part>" ++
                    "</CompleteMultipartUpload>",
                canned.played[3].bodyPrefix(),
            );
        }
    }.run);
}

test "a part copy answered without an ETag fails there, and aborts" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Answer{
                .{ .body = initiate_answer_body, .content_type = "application/xml" },
                .{ .body = "<CopyPartResult><ETag></ETag></CopyPartResult>", .content_type = "application/xml" },
                .{ .status = "204 No Content" },
            } });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.Failed, files.compose(&scope, "big.bin", &.{ "pieces/1", "pieces/2" }, .{ .content_type = "video/mp4" }));
            served.await(io) catch {};
            try testing.expectEqual(@as(usize, 3), canned.played_count);
            try testing.expectEqualStrings("DELETE", canned.played[2].methodText());
            try testing.expectEqualStrings("/files/big.bin?uploadId=canned-upload", canned.played[2].targetText());
        }
    }.run);
}

test "a failed part copy aborts the join and never completes it, so the target is left as it was" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(Canned.serveScript, .{ &canned, &[_]Answer{
                .{ .body = initiate_answer_body, .content_type = "application/xml" },
                .{ .body = partCopied("p1"), .content_type = "application/xml" },
                .{ .status = "500 Internal Server Error", .error_body = error_answer_body },
                .{ .status = "204 No Content" },
            } });
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            var files = try Files.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.Unavailable, files.compose(&scope, "big.bin", &.{ "pieces/1", "pieces/2" }, .{ .content_type = "video/mp4" }));
            served.await(io) catch {};
            // Initiate, two part copies, the abort: no completion was ever
            // sent, so no object at `big.bin` was made or replaced.
            try testing.expectEqual(@as(usize, 4), canned.played_count);
            try testing.expectEqualStrings("DELETE", canned.played[3].methodText());
            for (canned.played[0..4]) |step| try testing.expect(!std.mem.eql(u8, step.targetText(), "/files/big.bin?uploadId=canned-upload") or
                std.mem.eql(u8, step.methodText(), "DELETE"));
        }
    }.run);
}

test "a compose of no parts, or more than S3 joins, is refused before a socket" {
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

            try testing.expectError(error.Rejected, files.compose(&scope, "big.bin", &.{}, .{ .content_type = "video/mp4" }));
            const many = try testing.allocator.alloc([]const u8, multipart_mod.parts_max + 1);
            defer testing.allocator.free(many);
            @memset(many, "pieces/x");
            try testing.expectError(error.Rejected, files.compose(&scope, "big.bin", many, .{ .content_type = "video/mp4" }));
            try testing.expectEqual(@as(usize, 0), canned.played_count);
        }
    }.run);
}

test "a presigned PUT signs the method: same key, same moment, different signature" {
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

            // Presigning opens no socket, so the canned server only has to
            // exist for `started`; what is under test is the two canonical
            // requests differing in exactly the method line.
            const get_link = try files.presign(&scope, "one.bin", 60);
            const put_link = try files.presignPut(&scope, "one.bin", 60);

            const get_sig = afterLast(get_link.url.view(), "X-Amz-Signature=");
            const put_sig = afterLast(put_link.url.view(), "X-Amz-Signature=");
            try testing.expect(get_sig.len == 64 and put_sig.len == 64);
            try testing.expect(!std.mem.eql(u8, get_sig, put_sig));

            // Everything but the signature is one spelling: same key, same
            // credential, same query shape.
            try testing.expectEqualStrings(
                get_link.url.view()[0 .. get_link.url.view().len - get_sig.len],
                put_link.url.view()[0 .. put_link.url.view().len - put_sig.len],
            );
        }
    }.run);
}

fn afterLast(text: []const u8, marker: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, text, marker) orelse return "";
    return text[at + marker.len ..];
}

/// A server that refuses on the head and closes with the body unread, the way
/// Garage answers a wrong region: the client's write is still going when the
/// RST arrives.
fn answerEarly(canned: *Canned) !void {
    var stream = try canned.server.accept(canned.io);
    defer stream.close(canned.io);
    var in_buf: [4 << 10]u8 = undefined;
    var reader = stream.reader(canned.io, &in_buf);
    while (std.mem.trimEnd(u8, try reader.interface.takeDelimiterInclusive('\n'), "\r\n").len != 0) {}
    var out_buf: [1 << 10]u8 = undefined;
    var writer = stream.writer(canned.io, &out_buf);
    const xml = "<Error><Code>AuthorizationHeaderMalformed</Code><Message>wrong region</Message></Error>";
    try writer.interface.print(
        "HTTP/1.1 400 Bad Request\r\nContent-Type: application/xml\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ xml.len, xml },
    );
    try writer.interface.flush();
}

test "a put refused before its body was read is Rejected, not a failure to reach" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var served = try io.concurrent(answerEarly, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();
            const Big = bucket_mod.Bucket("big", .{ .style = .path, .max_bytes = 128 << 20 });
            var files = try Big.open(&store);
            defer files.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // Far past what loopback buffers, so the write really fails.
            const bytes = try testing.allocator.alloc(u8, 64 << 20);
            defer testing.allocator.free(bytes);
            @memset(bytes, 'x');

            try testing.expectError(error.Rejected, files.put(&scope, "big.bin", .{
                .bytes = core.Str.static(bytes),
                .content_type = core.Str.static("application/octet-stream"),
            }));
        }
    }.run);
}

test "a bucket opened under a name read at run time signs and sends that name" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.answer = .{ .body = "kept" };

            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            // The name comes from a config the program may free, so it is
            // overwritten after `openAs` to prove the bucket holds its own.
            var from_config: [8]u8 = "tenant-b".*;
            var tenant = try Files.openAs(&store, &from_config);
            defer tenant.deinit();
            @memset(&from_config, 'x');

            // The type is `Files` and its declared name is still "files".
            try testing.expectEqualStrings("files", Files.bucket);
            try testing.expectEqualStrings("tenant-b", tenant.name);
            try testing.expectEqualStrings("/tenant-b", tenant.prefix);

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();
            const object = try tenant.get(&scope, "photos/wati.png");

            served.await(io) catch {};
            // The server recomputes the signature over what it saw, so a
            // verified request is one signed for the path it was sent to.
            try expectVerified(&canned);
            try testing.expectEqualStrings("kept", object.bytes.view());
            try testing.expectEqualStrings("/tenant-b/photos/wati.png", canned.seen.path());
        }
    }.run);
}

test "a presigned POST from a bucket opened at run time names that bucket" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var buf: [64]u8 = undefined;
            var store = try started(io, &canned, &buf);
            defer store.deinit();

            var tenant = try Files.openAs(&store, "tenant-b");
            defer tenant.deinit();
            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const posted = try tenant.presignPost(&scope, "receipts/09.pdf", .{ .seconds = 900 });

            var action: [64]u8 = undefined;
            try testing.expectEqualStrings(
                try std.fmt.bufPrint(&action, "http://127.0.0.1:{d}/tenant-b", .{canned.port}),
                posted.url,
            );
            try testing.expectEqualStrings("tenant-b", fieldOfForm(posted, "bucket").?);

            const policy = fieldOfForm(posted, "policy").?;
            const decoder = std.base64.standard.Decoder;
            const doc = try scope.arena().alloc(u8, try decoder.calcSizeForSlice(policy));
            try decoder.decode(doc, policy);
            try testing.expect(std.mem.indexOf(u8, doc, "{\"bucket\":\"tenant-b\"}") != null);
            try testing.expect(std.mem.indexOf(u8, doc, "\"files\"") == null);
        }
    }.run);
}

test "a name the bucket's style cannot carry is BadBucketName, and opening it allocates once" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();

            var counting: Counting = .{ .child = testing.allocator };
            var buf: [64]u8 = undefined;
            var store = try Store.open(counting.allocator(), .{
                .endpoint = try canned.endpoint(&buf),
                .region = "us-east-1",
                .credentials = .{ .static = .{ .access_key_id = akid, .secret_access_key = secret } },
            });
            defer store.deinit();

            const before = counting.allocs;
            try testing.expectError(error.BadBucketName, Files.openAs(&store, ""));
            try testing.expectError(error.BadBucketName, Files.openAs(&store, "ab"));
            try testing.expectError(error.BadBucketName, Files.openAs(&store, "a" ** 64));
            try testing.expectError(error.BadBucketName, Files.openAs(&store, "has/slash"));
            try testing.expectError(error.BadBucketName, Files.openAs(&store, "has space"));
            try testing.expectError(error.BadBucketName, Files.openAs(&store, "q?x=1"));
            // Refused before anything is built: no allocation to give back.
            try testing.expectEqual(before, counting.allocs);

            var ok = try Files.openAs(&store, "a" ** 63);
            defer ok.deinit();
            try testing.expectEqual(before + 1, counting.allocs);
        }
    }.run);
}
