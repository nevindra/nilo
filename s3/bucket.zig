//! A bucket is a type, and a key is not
//! ([ADR 0068](../docs/adr/0068-a-bucket-is-a-type-and-a-key-is-not.md)).
//!
//! ```zig
//! const Avatars = s3.Bucket("avatars", .{ .max_bytes = 5 << 20 });
//!
//! var avatars = try Avatars.open(&store);
//! try app.provide(&avatars);
//!
//! fn getAvatar(id: Uuid, avatars: *Avatars, c: *nilo.Ctx) !s3.Object {
//!     return avatars.get(c, try key(c, id));
//! }
//! ```
//!
//! Two buckets are two types, therefore two Services, and which one a handler
//! reaches is written in its argument list — the shape ADR 0060 already chose
//! for a second database. The type-keyed registry resolves `*Avatars` with
//! nothing added to it, and a program registering two buckets of the same type
//! is refused by the check that is already there.
//!
//! ## What is settled while compiling, and what is not
//!
//! Not "as much as possible": **whatever is a property of the bucket rather
//! than of the deployment.** The name, the addressing style, the ceilings and
//! the encryption are the bucket's; the endpoint, the region and the
//! credentials are the deployment's, and they come from a `Config` so that
//! development and production are one binary (ADR 0043).
//!
//! That looks like it gives up what putting the bucket in a type was for, and
//! it does not: **the win was never comptime, it was not formatting a host per
//! request.** `open` builds the host once and holds it. Zero allocations per
//! request either way — one at startup instead of one at compile time.
//!
//! What comptime buys is the half that cannot be bought any other way: the
//! Refusals below, and a `SignedHeaders` list that is a walk rather than a
//! sort.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("nilo_fetch");

const code = @import("code.zig");
const sign = @import("sign.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;
const Str = core.Str;

/// How a bucket is addressed.
pub const Style = enum {
    /// `https://avatars.s3.amazonaws.com/key` — what AWS wants, and what a
    /// bucket name has to be a legal DNS label for.
    virtual,
    /// `https://s3.amazonaws.com/avatars/key` — what MinIO, SeaweedFS and
    /// every other implementation on a bare host want.
    path,
};

/// Server-side encryption, as a header S3 already understands.
pub const Sse = enum {
    aes256,
    aws_kms,

    pub fn header(self: Sse) []const u8 {
        return switch (self) {
            .aes256 => "AES256",
            .aws_kms => "aws:kms",
        };
    }
};

/// A slice of an object, as two numbers rather than a string
/// ([ADR 0021](../docs/adr/0021-a-range-is-a-slice-and-two-headers.md) settled
/// the vocabulary). `s3` declares its own rather than duck-typing one: duck
/// typing earns its place for a three-field `Upload` a caller already holds,
/// not for two integers.
pub const Range = struct {
    from: u64,
    /// Inclusive, the way HTTP counts. `.{ .from = 0, .to = 1023 }` is the
    /// first kibibyte.
    to: u64,
};

/// What a bucket's type carries. Every field is a property of the bucket
/// itself; anything that changes between development and production is on the
/// Store.
pub const Options = struct {
    /// The largest object a bounded `get` will hold. Checked against
    /// `content-length` **before a byte is read**, so an object over it costs
    /// one round trip rather than a download.
    max_bytes: usize = 8 << 20,
    style: Style = .virtual,
    sse: ?Sse = null,
    /// The longest life a presigned URL from this bucket may claim.
    presign_max: u32 = 3600,

    /// The longest key this bucket will build a URL for.
    ///
    /// It is a comptime number because it is stack: a key is percent-encoded
    /// into a buffer sized `3 × key_max`, and by ADR 0063 a handler's stack is
    /// held per *connection*. S3's own ceiling is 1,024 bytes and paying 3 KiB
    /// per connection for keys that are almost always under 100 is the wrong
    /// default, so the default is 512 and a program with longer keys says so.
    key_max: usize = 512,

    /// Room for a session token beside a signature, or zero for none.
    ///
    /// **Zero is the right answer for static credentials**, which is most
    /// deployments, and it costs those deployments nothing at all. A program
    /// on IRSA, IMDS or any other STS source sets this to 2048 — and pays for
    /// it per connection, which is why it is not the default.
    session_token_max: usize = 0,
};

/// The type a handler asks for.
///
/// `name` is checked here rather than by S3, and the four Refusals below are
/// the whole of what a bucket can be got wrong about at compile time.
pub fn Bucket(comptime name: []const u8, comptime opts: anytype) type {
    const settings = comptime check(name, opts);

    return struct {
        const Self = @This();

        /// The name, so a caller can print it and a test can assert on it.
        pub const bucket = name;
        pub const options = settings;

        /// The seven failures of ADR 0068, plus the two every Zig call can
        /// have. Nothing else escapes this module: a TLS handshake that failed
        /// and a socket that was refused are both `Failed`, with the real
        /// cause in the log, because no handler does anything different about
        /// them.
        pub const Error = code.Error || error{OutOfMemory} || std.Io.Cancelable;

        /// The same list plus the one answer that is a success and therefore
        /// may not be one of them (ADR 0024). It exists for exactly the
        /// distance between `bounded` and `getIf`, and never reaches a caller.
        const Bounded = Error || error{NotModified};

        store: *Store,
        /// `avatars.s3.amazonaws.com`, or `127.0.0.1:9000` for path style.
        /// Built once at `open` and held — the one thing this type exists for.
        host: []const u8,
        /// `` or `/avatars`, likewise.
        prefix: []const u8,
        /// `https://avatars.s3.amazonaws.com`, so a request appends the key
        /// and nothing else.
        base: []const u8,
        owned: []u8,

        /// The longest URL this bucket can build, which is what sizes the
        /// buffer on the stack of every call.
        const url_max = "https://".len + host_max + prefix_max + 1 + settings.key_max * 3;
        const host_max = 63 + 1 + 255;
        const prefix_max = 1 + 63;

        pub fn open(s: *Store) !Self {
            const host_len = switch (settings.style) {
                .virtual => name.len + 1 + s.authority.len,
                .path => s.authority.len,
            };
            const prefix_len = switch (settings.style) {
                .virtual => 0,
                .path => 1 + name.len,
            };
            const scheme = @tagName(s.scheme);
            const base_len = scheme.len + "://".len + host_len;

            const owned = try s.gpa.alloc(u8, host_len + prefix_len + base_len);
            errdefer s.gpa.free(owned);

            var w = std.Io.Writer.fixed(owned);
            switch (settings.style) {
                .virtual => w.print("{s}.{s}", .{ name, s.authority }) catch unreachable,
                .path => w.writeAll(s.authority) catch unreachable,
            }
            const host = owned[0..host_len];

            if (settings.style == .path) w.print("/{s}", .{name}) catch unreachable;
            const prefix = owned[host_len..][0..prefix_len];

            w.print("{s}://{s}", .{ scheme, host }) catch unreachable;
            const base = owned[host_len + prefix_len ..][0..base_len];

            return .{ .store = s, .host = host, .prefix = prefix, .base = base, .owned = owned };
        }

        pub fn deinit(self: *Self) void {
            self.store.gpa.free(self.owned);
        }

        /// Finished when the loop exists, by finishing the Store (ADR 0040).
        /// Starting a Store twice is a no-op, so providing two buckets over
        /// one Store is the ordinary case rather than a mistake.
        pub fn nilo_start(self: *Self, io: std.Io, limits: core.Limits) !void {
            try self.store.nilo_start(io, limits);
        }

        // ---- reading ----

        /// An object, whole, in the Scope's memory.
        ///
        /// One allocation, and it holds the body and the two pieces of
        /// metadata beside it — see `finishGet`.
        pub fn get(self: *Self, c: anytype, key: []const u8) Error!Object {
            comptime core.checkScope(@TypeOf(c), "bucket.get");
            return self.bounded(c, key, null, null) catch |err| switch (err) {
                // Nothing was asked conditionally, so nothing can answer that
                // it has not changed.
                error.NotModified => unreachable,
                else => |e| e,
            };
        }

        /// Part of an object, so that a 500 MB one can be looked at without
        /// being held. Without this a bounded `get` is the only way in and a
        /// large object has no way in at all.
        pub fn getRange(self: *Self, c: anytype, key: []const u8, range: Range) Error!Object {
            comptime core.checkScope(@TypeOf(c), "bucket.getRange");
            var buf: [64]u8 = undefined;
            const header = std.fmt.bufPrint(&buf, "bytes={d}-{d}", .{ range.from, range.to }) catch
                unreachable;
            return self.bounded(c, key, header, null) catch |err| switch (err) {
                error.NotModified => unreachable,
                else => |e| e,
            };
        }

        /// A get that may answer *nothing has changed*.
        ///
        /// A 304 is a **success**, so it is a union rather than an error
        /// (ADR 0024), and the compiler makes the second case unforgettable in
        /// a way a nullable return would not.
        pub fn getIf(
            self: *Self,
            c: anytype,
            key: []const u8,
            etag: []const u8,
        ) Error!Conditional {
            comptime core.checkScope(@TypeOf(c), "bucket.getIf");
            const object = self.bounded(c, key, null, etag) catch |err| switch (err) {
                error.NotModified => return .unmodified,
                else => |e| return e,
            };
            return .{ .object = object };
        }

        pub const Conditional = union(enum) {
            unmodified,
            object: Object,
        };

        /// A get held open: the head has arrived and the body has not been
        /// read. What a handler streaming an object into its own response
        /// holds.
        ///
        /// **It must not be copied once it is begun**, for the reason a
        /// `fetch.Exchange` must not: it holds one. Declare it, fill it where
        /// it stands, leave it there.
        pub const Reading = struct {
            ex: fetch.Exchange = .idle,
            /// How long the object is, from `content-length`.
            len: u64 = 0,
            /// **Borrowed, and valid only until `pipe`.** They point into the
            /// connection's read buffer, which the first byte of body reads
            /// over — the bargain `sql`'s Borrowed row makes, for the same
            /// reason. A handler sets its response headers from these and then
            /// streams; a handler that wants them afterwards keeps a copy.
            content_type: []const u8 = "",
            etag: []const u8 = "",

            pub const idle: Reading = .{};

            /// The object into `w`, allocating nothing, and how many bytes.
            pub fn pipe(self: *Reading, w: *std.Io.Writer) Error!u64 {
                return self.ex.pipe(w) catch |err| return blame(err);
            }

            pub fn close(self: *Reading) void {
                self.ex.end();
            }
        };

        /// Open an object for streaming. `buf` is what the body moves through,
        /// and its size is the caller's decision because its cost is the
        /// caller's stack (ADR 0063).
        pub fn stream(
            self: *Self,
            c: anytype,
            key: []const u8,
            out: *Reading,
            buf: []u8,
        ) Error!void {
            comptime core.checkScope(@TypeOf(c), "bucket.stream");

            var url_buf: [url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const target = try self.urlFor(&url_buf, key);
            try self.prepare(&sig, &headers, .{
                .method = "GET",
                .key = key,
                .payload = self.store.payloadNoBody(),
                .token_buf = &token_buf,
            });

            const got = out.ex.begin(&self.store.client, .{
                .method = .GET,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .transfer_buffer = buf,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &out.ex, got);

            out.len = got.content_length orelse 0;
            out.content_type = got.content_type orelse "application/octet-stream";
            out.etag = got.header("etag") orelse "";
        }

        // ---- writing ----

        /// Put an object.
        ///
        /// `value` is anything with `.bytes` and `.content_type`, checked while
        /// compiling — the shape `core/scope.zig` uses, so a `nilo.Upload` out
        /// of a form goes straight through and `s3/` never names `nilo_http`,
        /// which the layering forbids. `.cache_control` and
        /// `.content_disposition` are read if the caller's own type has them.
        pub fn put(self: *Self, c: anytype, key: []const u8, value: anytype) Error!void {
            comptime core.checkScope(@TypeOf(c), "bucket.put");
            comptime checkPayload(@TypeOf(value), "bucket.put");

            const bytes = viewOf(value.bytes);

            var url_buf: [url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var hash_buf: [64]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const target = try self.urlFor(&url_buf, key);
            try self.prepare(&sig, &headers, .{
                .method = "PUT",
                .key = key,
                .payload = self.store.payloadFor(bytes, &hash_buf),
                .content_type = viewOf(value.content_type),
                .cache_control = optional(value, "cache_control"),
                .content_disposition = optional(value, "content_disposition"),
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            var transfer: [512]u8 = undefined;
            const got = ex.begin(&self.store.client, .{
                .method = .PUT,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .content_type = viewOf(value.content_type),
                .headers = headers.slice(),
                .body = .{ .slice = bytes },
                .transfer_buffer = &transfer,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &ex, got);
        }

        /// Put an object whose bytes are not in hand.
        ///
        /// `source` is anything with `.reader`, `.len` and `.content_type`.
        /// **The length is not optional and that is the point**: S3 answers
        /// `411` to a body of unknown length, so asking for it here makes
        /// *I do not know* a compile error rather than a production surprise.
        /// Unknown-size upload needs multipart, which is on the roadmap with
        /// its reason attached.
        pub fn putStream(self: *Self, c: anytype, key: []const u8, source: anytype) Error!void {
            comptime core.checkScope(@TypeOf(c), "bucket.putStream");
            comptime checkSource(@TypeOf(source), "bucket.putStream");

            var url_buf: [url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const target = try self.urlFor(&url_buf, key);
            try self.prepare(&sig, &headers, .{
                .method = "PUT",
                .key = key,
                // Always unsigned: hashing what has not been read yet means
                // reading it twice, and the source may be a socket.
                .payload = sign.unsigned_payload,
                .content_type = viewOf(source.content_type),
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            var transfer: [512]u8 = undefined;
            const got = ex.begin(&self.store.client, .{
                .method = .PUT,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .content_type = viewOf(source.content_type),
                .headers = headers.slice(),
                .body = .{ .stream = .{ .reader = source.reader, .len = source.len } },
                .transfer_buffer = &transfer,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &ex, got);
        }

        /// Delete an object. S3 answers 204 whether or not it was there, and
        /// that is passed through rather than turned into a `NotFound` nobody
        /// asked for: deleting something twice is not a failure.
        pub fn delete(self: *Self, c: anytype, key: []const u8) Error!void {
            comptime core.checkScope(@TypeOf(c), "bucket.delete");

            var url_buf: [url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const target = try self.urlFor(&url_buf, key);
            try self.prepare(&sig, &headers, .{
                .method = "DELETE",
                .key = key,
                .payload = self.store.payloadNoBody(),
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            var transfer: [512]u8 = undefined;
            const got = ex.begin(&self.store.client, .{
                .method = .DELETE,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .transfer_buffer = &transfer,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &ex, got);
        }

        /// What is known about an object without reading it: how long it is,
        /// what it claims to be, and its ETag.
        pub fn head(self: *Self, c: anytype, key: []const u8) Error!Meta {
            comptime core.checkScope(@TypeOf(c), "bucket.head");

            var url_buf: [url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const target = try self.urlFor(&url_buf, key);
            try self.prepare(&sig, &headers, .{
                .method = "HEAD",
                .key = key,
                .payload = self.store.payloadNoBody(),
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            var transfer: [512]u8 = undefined;
            const got = ex.begin(&self.store.client, .{
                .method = .HEAD,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .transfer_buffer = &transfer,
            }) catch |err| return blame(err);

            // A HEAD carries no body, so there is no `<Code>` to read and the
            // status is the whole of what S3 said.
            if (!got.ok()) return code.errorFor(got.status, "");

            return .{
                .len = got.content_length orelse 0,
                .content_type = c.str(try keepIn(c, got.content_type orelse "")),
                .etag = c.str(try keepIn(c, got.header("etag") orelse "")),
            };
        }

        // ---- presigning ----

        /// A URL somebody else can use, and the moment it stops working.
        ///
        /// Presigning touches no socket, so it needs neither the loop nor a
        /// permit at the gate. What it does need is the truth about *when*:
        /// a URL signed with temporary credentials dies when they do, not when
        /// `X-Amz-Expires` says, so the life is clamped to the smallest of what
        /// was asked, what the bucket allows, and what the credentials have
        /// left. A caller storing that number in a database has one that is
        /// true.
        pub fn presign(
            self: *Self,
            c: anytype,
            key: []const u8,
            wanted_seconds: u32,
        ) Error!Presigned {
            comptime core.checkScope(@TypeOf(c), "bucket.presign");
            if (key.len > settings.key_max) return error.Rejected;

            const io = self.store.client.inner.io;
            const now_ms = core.nowMillis();
            const now_s = @divFloor(now_ms, 1000);

            var token_buf: [settings.session_token_max]u8 = undefined;
            const signing = self.store.keyFor(io, now_ms, &token_buf) catch |err|
                return blame(err);

            var expires = @min(wanted_seconds, settings.presign_max);
            if (signing.expires_at) |dies_at| {
                const left = dies_at - now_s;
                if (left <= 0) return error.Rejected;
                expires = @min(expires, std.math.lossyCast(u32, left));
            }

            const stamp: sign.Stamp = .at(now_s);
            var query_buf: [sign.presign_query_max]u8 = undefined;
            const query = sign.presignQuery(&query_buf, &signing.keyed, &stamp, expires, signing.token);

            var sig: sign.Signature = .none;
            sig.stamp = stamp;
            const canonical = sign.canonicalHash(.{
                .method = "GET",
                .prefix = self.prefix,
                .key = key,
                .query = query,
                .payload = sign.unsigned_payload,
                .headers = .{ .host = self.host },
            }, "host");

            var sts_buf: [sign.string_to_sign_max]u8 = undefined;
            const sts = sign.stringToSign(&sts_buf, &stamp, signing.keyed.credentialScope(), canonical);
            const signature = sign.signature(signing.keyed.key, sts);

            // The URL goes to a caller who will keep it — put it in an email,
            // store it in a row — so it is the Scope's memory rather than a
            // stack buffer. The one call in this file that allocates, and it
            // allocates once: the arena is reset whole per request, so taking
            // the ceiling and handing back the part that was used costs
            // nothing a second allocation would have saved.
            const room = try c.arena().alloc(u8, url_max + query.len + "?&X-Amz-Signature=".len + 64);
            var w = std.Io.Writer.fixed(room);

            w.writeAll(self.base) catch unreachable;
            w.writeAll(self.prefix) catch unreachable;
            w.writeByte('/') catch unreachable;
            core.percent.encodeWrite(&w, key, .path) catch unreachable;
            w.print("?{s}&X-Amz-Signature={x}", .{ query, &signature }) catch unreachable;

            return .{
                .url = c.str(w.buffered()),
                .expires_at = now_s + expires,
            };
        }

        // ---- the shared middle ----

        /// Everything one request needs decided before it is sent.
        const Prepare = struct {
            method: []const u8,
            key: []const u8,
            payload: []const u8,
            content_type: ?[]const u8 = null,
            cache_control: ?[]const u8 = null,
            content_disposition: ?[]const u8 = null,
            range: ?[]const u8 = null,
            if_none_match: ?[]const u8 = null,
            token_buf: []u8,
        };

        /// Sign, and fill in the headers that go out beside the signature.
        fn prepare(self: *Self, sig: *sign.Signature, headers: *Headers, req: Prepare) Error!void {
            if (req.key.len > settings.key_max) {
                std.log.warn(
                    "nilo_s3: a key of {d} bytes is longer than `{s}`'s `key_max` of {d}",
                    .{ req.key.len, name, settings.key_max },
                );
                return error.Rejected;
            }

            const io = self.store.client.inner.io;
            const now_ms = core.nowMillis();
            const signing = self.store.keyFor(io, now_ms, req.token_buf) catch |err|
                return blame(err);

            sig.stamp = .at(@divFloor(now_ms, 1000));

            const signed: sign.Signed = .{
                .host = self.host,
                .cache_control = req.cache_control,
                .content_disposition = req.content_disposition,
                .content_type = req.content_type,
                .range = req.range,
                .x_amz_content_sha256 = req.payload,
                .x_amz_date = sig.date(),
                .x_amz_security_token = signing.token,
                .x_amz_server_side_encryption = if (settings.sse) |s| s.header() else null,
            };

            sign.authorize(sig, &signing.keyed, .{
                .method = req.method,
                .prefix = self.prefix,
                .key = req.key,
                .headers = signed,
                .payload = req.payload,
            });

            // Everything signed except `host` and `content-type`, which
            // `Exchange` writes as overrides so that std cannot spell them a
            // second way.
            headers.add("x-amz-date", sig.date());
            headers.add("x-amz-content-sha256", req.payload);
            if (req.cache_control) |v| headers.add("cache-control", v);
            if (req.content_disposition) |v| headers.add("content-disposition", v);
            if (req.range) |v| headers.add("range", v);
            if (signing.token) |v| headers.add("x-amz-security-token", v);
            if (settings.sse) |s| headers.add("x-amz-server-side-encryption", s.header());
            // Not signed, because it is a condition rather than content, and
            // S3 does not require it to be. Sent all the same.
            if (req.if_none_match) |v| headers.add("if-none-match", v);
        }

        /// The whole of a bounded get, whichever of the three entry points
        /// asked for it.
        fn bounded(
            self: *Self,
            c: anytype,
            key: []const u8,
            range: ?[]const u8,
            if_none_match: ?[]const u8,
        ) Bounded!Object {
            var url_buf: [url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const target = try self.urlFor(&url_buf, key);
            try self.prepare(&sig, &headers, .{
                .method = "GET",
                .key = key,
                .payload = self.store.payloadNoBody(),
                .range = range,
                .if_none_match = if_none_match,
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            // Small on purpose: the body goes into one allocation sized from
            // `content-length`, so this is only the window it arrives through.
            var transfer: [4 << 10]u8 = undefined;
            const got = ex.begin(&self.store.client, .{
                .method = .GET,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .transfer_buffer = &transfer,
            }) catch |err| return blame(err);

            if (got.status == .not_modified) return error.NotModified;
            if (!got.ok()) return self.failure(c, &ex, got);

            const len = got.content_length orelse return error.Failed;
            // **Before a byte is read**, which is the difference between an
            // object over the ceiling costing one round trip and costing a
            // download. What is left of the body then makes `Exchange.end`
            // drop the connection rather than drain it.
            if (len > settings.max_bytes) return error.TooLarge;

            const content_type = got.content_type orelse "application/octet-stream";
            const etag = got.header("etag") orelse "";

            // One allocation, holding the body and the two pieces of metadata
            // that would otherwise need one each — the head's own bytes are
            // about to be read over, so they cannot simply be pointed at.
            const room = std.math.cast(usize, len) orelse return error.TooLarge;
            const whole = try c.arena().alloc(u8, room + content_type.len + etag.len);
            @memcpy(whole[room..][0..content_type.len], content_type);
            @memcpy(whole[room + content_type.len ..][0..etag.len], etag);

            const body = whole[0..room];
            ex.readInto(body) catch |err| return blame(err);

            return .{
                .bytes = c.str(body),
                .content_type = c.str(whole[room..][0..content_type.len]),
                .etag = c.str(whole[room + content_type.len ..][0..etag.len]),
                .len = len,
            };
        }

        /// Read what S3 said about a failure, log it, and hand the handler one
        /// of the seven.
        fn failure(self: *Self, c: anytype, ex: *fetch.Exchange, got: fetch.Exchange.Head) Error {
            _ = self;
            // Bounded, because an error body is a few hundred bytes and
            // anything claiming to be more is not one.
            const body = ex.take(c, 8 << 10) catch {
                return code.errorFor(got.status, "");
            };
            const reason: code.Reason = .read(body.view());

            if (code.isClockSkew(reason.code)) {
                std.log.warn(
                    "nilo_s3: {s} refused the request as too far from its own clock, " ++
                        "which reads {s}. The container's clock is what to fix.",
                    .{ name, reason.server_time },
                );
            } else if (reason.code.len != 0) {
                std.log.warn("nilo_s3: {s} answered {d} {s}: {s}", .{
                    name,
                    @intFromEnum(got.status),
                    reason.code,
                    reason.message,
                });
            }

            return code.errorFor(got.status, reason.code);
        }

        /// `https://avatars.s3.amazonaws.com/photos/wati%20sari.png`, into a
        /// buffer on the caller's stack.
        fn urlFor(self: *Self, buf: []u8, key: []const u8) Error![]const u8 {
            var w = std.Io.Writer.fixed(buf);
            w.writeAll(self.base) catch return error.Rejected;
            w.writeAll(self.prefix) catch return error.Rejected;
            w.writeByte('/') catch return error.Rejected;
            core.percent.encodeWrite(&w, key, .path) catch return error.Rejected;
            return w.buffered();
        }

        /// One place where everything `nilo_fetch` and the Store can fail with
        /// becomes one of the seven.
        fn blame(err: anyerror) Error {
            return switch (err) {
                error.TimedOut => error.TimedOut,
                error.BodyTooLarge => error.TooLarge,
                error.OutOfMemory => error.OutOfMemory,
                error.Canceled => error.Canceled,
                else => {
                    // The cause is here rather than in the return type,
                    // because no handler does anything different about a
                    // refused socket than about a failed handshake.
                    std.log.warn("nilo_s3: {s} could not be reached: {s}", .{ name, @errorName(err) });
                    return error.Failed;
                },
            };
        }
    };
}

/// What a bounded get answers with.
///
/// `bytes` is a `Str` even though an object is usually not text, and that is
/// not a stretch: `http/form.zig` already says of `Upload.bytes` that it is
/// *"doing lifetime duty rather than claiming the contents are text"*. What a
/// `Str` means here is that these bytes live in the request's arena and go
/// stale when the request does.
pub const Object = struct {
    bytes: Str,
    content_type: Str,
    etag: Str,
    len: u64,
};

/// What a HEAD answers with: everything but the bytes.
pub const Meta = struct {
    len: u64,
    content_type: Str,
    etag: Str,
};

/// A URL somebody else can use, and the truth about when it stops working.
pub const Presigned = struct {
    url: Str,
    /// Unix seconds. `min(asked, presign_max, what the credentials have left)`
    /// — the number that is true rather than the number that was requested.
    expires_at: i64,
};

/// The headers that go out beside a signature. A fixed array because the set
/// is fixed (ADR 0068), so there is nothing to allocate and nothing to sort.
const Headers = struct {
    items: [10]std.http.Header = undefined,
    len: usize = 0,

    fn add(self: *Headers, name: []const u8, value: []const u8) void {
        self.items[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    fn slice(self: *const Headers) []const std.http.Header {
        return self.items[0..self.len];
    }
};

fn keepIn(c: anytype, text: []const u8) ![]const u8 {
    return c.arena().dupe(u8, text);
}

/// A `Str` or a plain slice, as a slice. Both spellings arrive here: a form
/// `Upload` carries `Str`, and a caller's own struct usually carries neither
/// more nor less than bytes.
fn viewOf(value: anytype) []const u8 {
    return if (@TypeOf(value) == Str) value.view() else value;
}

fn optional(value: anytype, comptime field: []const u8) ?[]const u8 {
    if (!@hasField(@TypeOf(value), field)) return null;
    const v = @field(value, field);
    return switch (@typeInfo(@TypeOf(v))) {
        .optional => if (v) |inner| viewOf(inner) else null,
        else => viewOf(v),
    };
}

// ---- the Refusals ----

/// Everything a bucket can be got wrong about while compiling.
fn check(comptime name: []const u8, comptime opts: anytype) Options {
    comptime {
        checkName(name);

        const Given = @TypeOf(opts);
        if (@typeInfo(Given) != .@"struct") @compileError(
            "nilo: s3.Bucket's second argument is the bucket's options, and " ++
                @typeName(Given) ++ " is not a struct literal.\n" ++
                "  s3.Bucket(\"avatars\", .{ .max_bytes = 5 << 20 })",
        );

        var settings: Options = .{};
        for (@typeInfo(Given).@"struct".fields) |field| {
            if (!@hasField(Options, field.name)) {
                checkNotASecret(field.name);
                @compileError(
                    "nilo: s3.Bucket has no option called `" ++ field.name ++ "`.\n" ++
                        "  It takes " ++ optionList() ++ ".",
                );
            }
            @field(settings, field.name) = @field(opts, field.name);
        }

        if (settings.max_bytes == 0) @compileError(
            "nilo: s3.Bucket(\"" ++ name ++ "\") has a `max_bytes` of zero, so every " ++
                "get would be refused before it was made.\n" ++
                "  `max_bytes` is the largest object this bucket will hold in a request arena.",
        );

        if (settings.presign_max > sign.expires_max) @compileError(
            "nilo: s3.Bucket(\"" ++ name ++ "\") has a `presign_max` of " ++
                std.fmt.comptimePrint("{d}", .{settings.presign_max}) ++
                " seconds, and SigV4 refuses anything over seven days (604800).\n" ++
                "  A URL that cannot be signed for that long is better said here than by AWS.",
        );

        if (settings.key_max == 0) @compileError(
            "nilo: s3.Bucket(\"" ++ name ++ "\") has a `key_max` of zero, so no key would fit.",
        );

        if (settings.style == .virtual) checkDnsLabel(name);

        return settings;
    }
}

fn optionList() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(Options).@"struct".fields, 0..) |field, i| {
            if (i != 0) out = out ++ ", ";
            out = out ++ "`" ++ field.name ++ "`";
        }
        return out;
    }
}

/// The one unknown option that gets its own message, because the mistake is
/// not a typo — it is a secret about to be compiled into a binary and shipped
/// wherever that binary goes.
fn checkNotASecret(comptime field: []const u8) void {
    comptime {
        const smells = [_][]const u8{ "secret", "key_id", "access_key", "password", "token", "credential" };
        for (smells) |smell| {
            if (std.mem.indexOf(u8, field, smell) != null) @compileError(
                "nilo: `" ++ field ++ "` is a credential, and a bucket's type is not where one goes.\n" ++
                    "  What is written here is compiled into the binary and ships with it.\n" ++
                    "  Credentials belong to the Store, at run time, where a Config can read them:\n" ++
                    "    var store = try s3.open(gpa, .{ .endpoint = cfg.s3_endpoint,\n" ++
                    "                                    .credentials = .{ .static = .{ … } } });",
            );
        }
    }
}

fn checkName(comptime name: []const u8) void {
    comptime {
        if (name.len < 3 or name.len > 63) @compileError(
            "nilo: `" ++ name ++ "` is " ++ std.fmt.comptimePrint("{d}", .{name.len}) ++
                " characters, and an S3 bucket name is 3 to 63.",
        );
    }
}

/// What virtual-host addressing needs of a name, which is more than S3 needs
/// of one.
fn checkDnsLabel(comptime name: []const u8) void {
    comptime {
        const advice = "\n  Either rename the bucket, or address it by path:" ++
            " s3.Bucket(\"" ++ name ++ "\", .{ .style = .path }).";

        for (name) |ch| switch (ch) {
            'a'...'z', '0'...'9', '-', '.' => {},
            'A'...'Z' => @compileError(
                "nilo: `" ++ name ++ "` has a capital letter in it, and a bucket addressed" ++
                    " as `" ++ name ++ ".s3.amazonaws.com` cannot." ++ advice,
            ),
            '_' => @compileError(
                "nilo: `" ++ name ++ "` has an underscore in it, and a host name cannot." ++ advice,
            ),
            else => @compileError(
                "nilo: `" ++ name ++ "` has a character in it that a host name cannot carry." ++ advice,
            ),
        };

        if (name[0] == '-' or name[0] == '.' or name[name.len - 1] == '-' or name[name.len - 1] == '.')
            @compileError(
                "nilo: `" ++ name ++ "` starts or ends with a dash or a dot, and a host name" ++
                    " cannot." ++ advice,
            );

        if (looksLikeAddress(name)) @compileError(
            "nilo: `" ++ name ++ "` is shaped like an IP address, and S3 refuses a bucket" ++
                " named that way." ++ advice,
        );
    }
}

/// Four dot-separated runs of digits. Written to run at either time — the
/// Refusal calls it while compiling and the test at the bottom of this file
/// calls it after, which is the only way a predicate behind a compile error
/// can be checked at all.
fn looksLikeAddress(name: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |part| {
        parts += 1;
        if (part.len == 0 or part.len > 3) return false;
        for (part) |ch| if (ch < '0' or ch > '9') return false;
    }
    return parts == 4;
}

fn checkPayload(comptime T: type, comptime called: []const u8) void {
    comptime {
        const advice = "\n  Anything with `.bytes` and `.content_type` will do — a `nilo.Upload`" ++
            " out of a form goes straight through.";

        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: " ++ called ++ " takes the thing being stored, and " ++ @typeName(T) ++
                " is not one." ++ advice,
        );
        if (!@hasField(T, "bytes")) @compileError(
            "nilo: " ++ called ++ " needs `.bytes` on the thing being stored.\n  " ++
                @typeName(T) ++ " has none." ++ advice,
        );
        if (!@hasField(T, "content_type")) @compileError(
            "nilo: " ++ called ++ " needs `.content_type` on the thing being stored.\n  " ++
                @typeName(T) ++ " has none, and S3 stores what it is told an object is —" ++
                " there is nothing here to guess it from." ++ advice,
        );
    }
}

fn checkSource(comptime T: type, comptime called: []const u8) void {
    comptime {
        const advice = "\n  A streamed put takes `.reader`, `.len` and `.content_type`:" ++
            " S3 answers 411 to a body whose length it was not told.";

        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: " ++ called ++ " takes what to read the object from, and " ++ @typeName(T) ++
                " is not one." ++ advice,
        );
        for ([_][]const u8{ "reader", "len", "content_type" }) |field| {
            if (!@hasField(T, field)) @compileError(
                "nilo: " ++ called ++ " needs `." ++ field ++ "` on what it reads from.\n  " ++
                    @typeName(T) ++ " has none." ++ advice,
            );
        }
    }
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "a bucket's host and prefix are built once, and by the style" {
    var store = try Store.open(testing.allocator, .{
        .endpoint = "https://s3.ap-southeast-1.amazonaws.com",
        .region = "ap-southeast-1",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer store.deinit();

    const Avatars = Bucket("avatars", .{});
    var avatars = try Avatars.open(&store);
    defer avatars.deinit();

    try testing.expectEqualStrings("avatars.s3.ap-southeast-1.amazonaws.com", avatars.host);
    try testing.expectEqualStrings("", avatars.prefix);
    try testing.expectEqualStrings("https://avatars.s3.ap-southeast-1.amazonaws.com", avatars.base);

    const Invoices = Bucket("invoices", .{ .style = .path });
    var invoices = try Invoices.open(&store);
    defer invoices.deinit();

    try testing.expectEqualStrings("s3.ap-southeast-1.amazonaws.com", invoices.host);
    try testing.expectEqualStrings("/invoices", invoices.prefix);
}

test "a URL is the base, the prefix and the key encoded once" {
    var store = try Store.open(testing.allocator, .{
        .endpoint = "http://127.0.0.1:9000",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer store.deinit();

    const Files = Bucket("files", .{ .style = .path });
    var files = try Files.open(&store);
    defer files.deinit();

    var buf: [2048]u8 = undefined;
    try testing.expectEqualStrings(
        "http://127.0.0.1:9000/files/photos/wati%20sari.png",
        try files.urlFor(&buf, "photos/wati sari.png"),
    );

    // A port is part of the host, because the signature covers the authority
    // and a development endpoint is nothing but a port.
    try testing.expectEqualStrings("127.0.0.1:9000", files.host);
}

test "a key longer than the bucket was built for is refused rather than truncated" {
    var store = try Store.open(testing.allocator, .{
        .endpoint = "http://127.0.0.1:9000",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer store.deinit();

    const Small = Bucket("small", .{ .style = .path, .key_max = 8 });
    var small = try Small.open(&store);
    defer small.deinit();

    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    var sig: sign.Signature = .none;
    var headers: Headers = .{};
    var token: [0]u8 = undefined;
    try testing.expectError(error.Rejected, small.prepare(&sig, &headers, .{
        .method = "GET",
        .key = "a-key-that-is-far-too-long",
        .payload = sign.empty_payload,
        .token_buf = &token,
    }));
}

test "the options a bucket takes are the bucket's own, and comptime" {
    const Avatars = Bucket("avatars", .{ .max_bytes = 5 << 20, .sse = .aes256 });
    try testing.expectEqual(@as(usize, 5 << 20), Avatars.options.max_bytes);
    try testing.expectEqual(Sse.aes256, Avatars.options.sse.?);
    try testing.expectEqualStrings("avatars", Avatars.bucket);
    // The default nobody wrote, which is what makes `.{}` the ordinary case.
    try testing.expectEqual(Style.virtual, Avatars.options.style);
    try testing.expectEqual(@as(usize, 0), Avatars.options.session_token_max);
}

test "a name that virtual-host addressing cannot carry is caught by shape" {
    // The Refusals themselves are in `s3/refusals/`, because a compile error
    // cannot be caught by a test. What can be checked here is the predicate
    // underneath one of them.
    try testing.expect(looksLikeAddress("192.168.1.1"));
    try testing.expect(looksLikeAddress("10.0.0.1"));
    try testing.expect(!looksLikeAddress("avatars"));
    try testing.expect(!looksLikeAddress("1.2.3"));
    try testing.expect(!looksLikeAddress("1.2.3.4.5"));
    try testing.expect(!looksLikeAddress("my.bucket.name.here"));
}

test "a value being stored is read through whichever spelling it carries" {
    var run: core.Run = .init(testing.allocator);
    defer run.deinit();

    // A plain struct, which is what a caller writes.
    const plain = .{ .bytes = "hello", .content_type = "text/plain" };
    try testing.expectEqualStrings("hello", viewOf(plain.bytes));
    try testing.expectEqual(@as(?[]const u8, null), optional(plain, "cache_control"));

    // And one carrying `Str`, which is what a form Upload is.
    const uploaded = .{
        .bytes = run.str("hello"),
        .content_type = run.str("image/png"),
        .cache_control = "max-age=31536000",
    };
    try testing.expectEqualStrings("hello", viewOf(uploaded.bytes));
    try testing.expectEqualStrings("image/png", viewOf(uploaded.content_type));
    try testing.expectEqualStrings("max-age=31536000", optional(uploaded, "cache_control").?);
}
