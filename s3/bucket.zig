//! A bucket is a type, and a key is not
//! ([ADR 059](../docs/adr/059-a-bucket-is-a-type-and-a-key-is-not.md)).
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
//! reaches is written in its argument list — the shape ADR 054 already chose
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
//! development and production are one binary (ADR 039).
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
const listing_mod = @import("listing.zig");
const multipart_mod = @import("multipart.zig");
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
/// ([ADR 020](../docs/adr/020-a-range-is-a-slice-and-two-headers.md) settled
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
    /// into a buffer sized `3 × key_max`, and by ADR 062 a handler's stack is
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

        /// The seven failures of ADR 059, plus the two every Zig call can
        /// have. Nothing else escapes this module: a TLS handshake that failed
        /// and a socket that was refused are both `Failed`, with the real
        /// cause in the log, because no handler does anything different about
        /// them.
        pub const Error = code.Error || error{OutOfMemory} || std.Io.Cancelable;

        /// The same list plus the one answer that is a success and therefore
        /// may not be one of them (ADR 023). It exists for exactly the
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
        /// The same two built from the Store's `public_endpoint`, for a URL
        /// handed to a browser — or the two above when there is none. What
        /// `presign` signs and `presignPost` posts to (ADR 177).
        public_host: []const u8,
        public_base: []const u8,
        owned: []u8,

        /// The longest URL this bucket can build, which is what sizes the
        /// buffer on the stack of every call.
        const url_max = "https://".len + host_max + prefix_max + 1 + settings.key_max * 3;
        /// A bucket name, a dot, and an authority, which `Store.open` refuses
        /// past `authority_max`: every `catch unreachable` that formats the
        /// endpoint into a buffer sized from this (`urlForList`, `presign`,
        /// `presignPost`) is held by that one check.
        const host_max = 63 + 1 + store_mod.authority_max;
        const prefix_max = 1 + 63;
        /// The same for a `list`, whose URL is the bucket's root and a query
        /// rather than a key: sized by the query, which is sized by
        /// `key_max` too, since a prefix is the start of a key.
        const list_url_max = "https://".len + host_max + prefix_max + "/?".len + listing_mod.queryMax(settings.key_max);
        /// And for a multipart call, whose URL is a key *and* a query: the
        /// part number and an upload id encoded at three bytes a character.
        const part_url_max = url_max + "?".len + multipart_mod.query_max;

        pub fn open(s: *Store) !Self {
            const host_len = hostLen(s.authority);
            const prefix_len = switch (settings.style) {
                .virtual => 0,
                .path => 1 + name.len,
            };
            const base_len = baseLen(s.scheme, host_len);
            // A second host and base only when the browser's endpoint is not
            // the dialled one; otherwise the public pair aliases the first.
            const two = s.public_authority.ptr != s.authority.ptr;
            const public_host_len = if (two) hostLen(s.public_authority) else 0;
            const public_base_len = if (two) baseLen(s.public_scheme, public_host_len) else 0;

            const owned = try s.gpa.alloc(
                u8,
                host_len + prefix_len + base_len + public_host_len + public_base_len,
            );
            errdefer s.gpa.free(owned);

            var w = std.Io.Writer.fixed(owned);
            writeHost(&w, s.authority);
            const host = owned[0..host_len];

            if (settings.style == .path) w.print("/{s}", .{name}) catch unreachable;
            const prefix = owned[host_len..][0..prefix_len];

            w.print("{s}://{s}", .{ @tagName(s.scheme), host }) catch unreachable;
            const base = owned[host_len + prefix_len ..][0..base_len];

            var public_host = host;
            var public_base = base;
            if (two) {
                const from = host_len + prefix_len + base_len;
                writeHost(&w, s.public_authority);
                public_host = owned[from..][0..public_host_len];
                w.print("{s}://{s}", .{ @tagName(s.public_scheme), public_host }) catch unreachable;
                public_base = owned[from + public_host_len ..][0..public_base_len];
            }

            return .{
                .store = s,
                .host = host,
                .prefix = prefix,
                .base = base,
                .public_host = public_host,
                .public_base = public_base,
                .owned = owned,
            };
        }

        fn hostLen(authority: []const u8) usize {
            return switch (settings.style) {
                .virtual => name.len + 1 + authority.len,
                .path => authority.len,
            };
        }

        fn baseLen(scheme: Store.Scheme, host_len: usize) usize {
            return @tagName(scheme).len + "://".len + host_len;
        }

        fn writeHost(w: *std.Io.Writer, authority: []const u8) void {
            switch (settings.style) {
                .virtual => w.print("{s}.{s}", .{ name, authority }) catch unreachable,
                .path => w.writeAll(authority) catch unreachable,
            }
        }

        pub fn deinit(self: *Self) void {
            self.store.gpa.free(self.owned);
        }

        /// Finished when the loop exists, by finishing the Store (ADR 037).
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
        /// (ADR 023), and the compiler makes the second case unforgettable in
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
            /// A limit on the whole transfer, in milliseconds, **set before
            /// `stream`** (`var r: Files.Reading = .{ .timeout_ms = 600_000 }`).
            /// Null, the default, is none: a stream ends when the object does,
            /// and `Options.stall_ms` is what ends one whose peer went quiet.
            /// The Store's `timeout_ms` is for the short calls and is not
            /// applied here (ADR 060).
            timeout_ms: ?u32 = null,
            /// The Store whose stream slot this holds, null when it holds
            /// none. Given back by `close`, and by `stream` itself when it
            /// fails.
            slot: ?*Store = null,

            pub const idle: Reading = .{};

            /// The object into `w`, allocating nothing, and how many bytes.
            pub fn pipe(self: *Reading, w: *std.Io.Writer) Error!u64 {
                return self.ex.pipe(w) catch |err| return blame(err);
            }

            /// Give back the connection, the permit and then the stream slot,
            /// in the opposite order they were taken. Safe twice, and safe on
            /// one that never began.
            pub fn close(self: *Reading) void {
                self.ex.end();
                if (self.slot) |store| {
                    self.slot = null;
                    store.giveStream();
                }
            }
        };

        /// Open an object for streaming. Nothing is declared for the body to
        /// move through: it goes from the connection's own read buffer to
        /// the writer `pipe` is given, and the buffer this used to take was
        /// a page of stack per connection that no byte ever crossed
        /// (ADR 186).
        pub fn stream(
            self: *Self,
            c: anytype,
            key: []const u8,
            out: *Reading,
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

            // A slot of the stream share before a permit of the whole, so a
            // handful of slow readers can never hold every permit (ADR 060).
            // Taken here, after everything that can fail without waiting.
            try self.store.takeStream();
            out.slot = self.store;
            errdefer out.close();

            const got = out.ex.begin(&self.store.client, .{
                .method = .GET,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                // A 301 from S3 is a bucket in another region, and the
                // reason is in its body: handed over as itself, so
                // `failure` reads it (ADR 183). Never followed, because a
                // signature is over one host.
                .redirects = .expose,
                // No limit on the whole transfer unless the caller set one,
                // and a bound on silence instead.
                .timeout_ms = out.timeout_ms orelse 0,
                .stall_ms = self.store.options.stall_ms,
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
            // Null means the Store's own deadline, today's behaviour: a put
            // is a short call unless `putMultipart`'s small-source branch
            // says otherwise.
            return self.putBounded(c, key, value, null, null);
        }

        /// `put`'s body, with the deadline the caller's to choose: the
        /// small-source branch of `putMultipart` sends up to a whole part
        /// this way, which is a transfer rather than a short call, so it
        /// passes the source's terms where `put` passes the Store's.
        fn putBounded(
            self: *Self,
            c: anytype,
            key: []const u8,
            value: anytype,
            timeout_ms: ?u32,
            stall_ms: ?u32,
        ) Error!void {
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
                .content_type = contentTypeOf(value.content_type),
                .cache_control = optional(value, "cache_control"),
                .content_disposition = optional(value, "content_disposition"),
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const got = ex.begin(&self.store.client, .{
                .method = .PUT,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .content_type = contentTypeOf(value.content_type),
                .headers = headers.slice(),
                .body = .{ .slice = bytes },
                .redirects = .expose,
                .timeout_ms = timeout_ms,
                .stall_ms = stall_ms,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &ex, got);
        }

        /// Put an object whose bytes are not in hand.
        ///
        /// `source` is anything with `.reader`, `.len` and `.content_type`.
        /// **The length is not optional and that is the point**: S3 answers
        /// `411` to a body of unknown length, so asking for it here makes
        /// *I do not know* a compile error rather than a production surprise.
        /// An upload whose size is unknown before it starts is
        /// `putMultipart`'s.
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
                .content_type = contentTypeOf(source.content_type),
                .token_buf = &token_buf,
            });

            // The stream share first, the permit second, and both given back
            // on every path out, an error included (ADR 060).
            try self.store.takeStream();
            defer self.store.giveStream();
            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const got = ex.begin(&self.store.client, .{
                .method = .PUT,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .content_type = contentTypeOf(source.content_type),
                .headers = headers.slice(),
                .body = .{ .stream = .{ .reader = source.reader, .len = source.len } },
                .redirects = .expose,
                // No whole-call limit unless the source names one
                // (`.timeout_ms`), and a bound on silence instead.
                .timeout_ms = optionalMs(source, "timeout_ms") orelse 0,
                .stall_ms = self.store.options.stall_ms,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &ex, got);
        }

        /// Put an object whose size is not known before it starts, or one
        /// too large to send as one body: S3's multipart upload, the whole
        /// protocol in one call
        /// ([ADR 058](../docs/adr/058-most-of-an-s3-client-is-not-s3.md)).
        ///
        /// `source` is anything with `.reader` and `.content_type` — no
        /// `.len`, which is what this call is for. The reader is read to its
        /// end in parts of `.part_bytes` (8 MiB unless the source says
        /// otherwise; under S3's 5 MiB part floor is refused before any byte
        /// moves), each part goes up as its own PUT, and a completion
        /// document seals them into one object. **A source that ends inside
        /// the first part becomes a plain `put`**: one round trip instead of
        /// three, and the ETag stays the content's own MD5 rather than a
        /// multipart digest, which matters to a caller comparing by hash.
        /// **A 200 on the completion is not believed on its own**: S3 can
        /// answer it with an error in the body, so the body is read and has
        /// to say so too. Any failure after the initiate aborts the upload
        /// on the way out, so a lost connection does not leave paid-for
        /// parts parked in the bucket. One bound only a server can hold: the
        /// 10,000-part ceiling is S3's own, and for a reader of unknown
        /// length it can only be met on the way, after those parts went up.
        ///
        /// Each part and the completion run under the source's optional
        /// `.timeout_ms` (none unless it says one) and the Store's
        /// `stall_ms` bound on silence, the same terms `putStream` gives its
        /// one body — the Store's `timeout_ms` is for the short calls, and a
        /// part is not one (ADR 060). `.cache_control` and
        /// `.content_disposition` are read off the source if it has them,
        /// as `put` reads them off its value.
        ///
        /// What it costs in the Scope: one buffer of `part_bytes`, one copy
        /// of each part's ETag, and the completion document. Parts go up one
        /// at a time on the pooled connections — a part is bytes in hand, so
        /// a connection the server reaped retries the way every other call
        /// here does — and the call holds one stream share for its whole
        /// life, the same bound `putStream` honours.
        pub fn putMultipart(self: *Self, c: anytype, key: []const u8, source: anytype) Error!void {
            comptime core.checkScope(@TypeOf(c), "bucket.putMultipart");
            comptime checkMultipartSource(@TypeOf(source));

            const part_bytes: usize = if (comptime @hasField(@TypeOf(source), "part_bytes"))
                source.part_bytes
            else
                multipart_mod.default_part_bytes;
            if (part_bytes < multipart_mod.part_min) {
                std.log.warn(
                    "nilo_s3: `{s}`.putMultipart was asked for parts of {d} bytes; S3 refuses any part but the last under {d}",
                    .{ name, part_bytes, multipart_mod.part_min },
                );
                return error.Rejected;
            }

            // The first part is read before anything is sent, because a
            // source that ends inside it has a known length after all and
            // deserves the plain PUT: one round trip, the content's own MD5.
            const buffer = try c.arena().alloc(u8, part_bytes);
            var n = source.reader.readSliceShort(buffer) catch
                return readerFailed();
            const timeout_ms = optionalMs(source, "timeout_ms") orelse 0;

            // The stream share bounds long uploads exactly as it bounds
            // `putStream`, taken once for the whole protocol — the
            // small-source PUT included, because up to a whole part on a
            // slow link is the long-transfer shape `max_streams` exists to
            // bound, and the caller chose the transfer call (ADR 060).
            try self.store.takeStream();
            defer self.store.giveStream();

            if (n < buffer.len) {
                return self.putBounded(c, key, .{
                    .bytes = buffer[0..n],
                    .content_type = source.content_type,
                    .cache_control = optional(source, "cache_control"),
                    .content_disposition = optional(source, "content_disposition"),
                }, timeout_ms, self.store.options.stall_ms);
            }

            const upload_id = try self.initiateMultipart(
                c,
                key,
                contentTypeOf(source.content_type),
                optional(source, "cache_control"),
                optional(source, "content_disposition"),
            );
            errdefer self.abortMultipart(c, key, upload_id);

            var etags: std.ArrayList([]const u8) = .empty;
            while (true) {
                if (etags.items.len == multipart_mod.parts_max) {
                    std.log.warn(
                        "nilo_s3: `{s}`.putMultipart reached S3's {d}-part ceiling; raise `.part_bytes`",
                        .{ name, multipart_mod.parts_max },
                    );
                    return error.Rejected;
                }
                const etag = try self.putPart(c, key, upload_id, etags.items.len + 1, buffer[0..n], timeout_ms);
                etags.append(c.arena(), etag) catch return error.OutOfMemory;
                if (n < buffer.len) break;
                n = source.reader.readSliceShort(buffer) catch
                    return readerFailed();
                if (n == 0) break;
            }

            try self.completeMultipart(c, key, upload_id, etags.items, timeout_ms);
        }

        fn readerFailed() Error {
            std.log.warn("nilo_s3: `{s}`.putMultipart: the source reader failed", .{name});
            return error.Failed;
        }

        /// The initiate POST. Hands back the `UploadId`, a slice into the
        /// answer's body in the Scope. An id too long for the part calls'
        /// URL buffer is refused — after aborting the upload the initiate
        /// just opened, because by then the id is the one thing in hand.
        fn initiateMultipart(
            self: *Self,
            c: anytype,
            key: []const u8,
            content_type: ?[]const u8,
            cache_control: ?[]const u8,
            content_disposition: ?[]const u8,
        ) Error![]const u8 {
            var url_buf: [part_url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const at = try self.urlToQuery(&url_buf, key);
            const query = multipart_mod.initiate_query;
            @memcpy(url_buf[at..][0..query.len], query);
            const target = url_buf[0 .. at + query.len];
            try self.prepare(&sig, &headers, .{
                .method = "POST",
                .key = key,
                .query = query,
                .payload = self.store.payloadNoBody(),
                .content_type = content_type,
                .cache_control = cache_control,
                .content_disposition = content_disposition,
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const got = ex.begin(&self.store.client, .{
                .method = .POST,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .content_type = content_type,
                .headers = headers.slice(),
                .redirects = .expose,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &ex, got);

            const body = ex.take(c, 8 << 10) catch |err| return blame(err);
            const upload_id = multipart_mod.uploadIdOf(body.view()) orelse {
                std.log.warn("nilo_s3: `{s}` answered the initiate with no usable UploadId", .{name});
                return error.Failed;
            };
            if (upload_id.len > multipart_mod.upload_id_max) {
                self.abortMultipart(c, key, upload_id);
                std.log.warn(
                    "nilo_s3: `{s}` handed out an UploadId of {d} bytes, over the {d} a part call can carry; the upload was aborted",
                    .{ name, upload_id.len, multipart_mod.upload_id_max },
                );
                return error.Failed;
            }
            return upload_id;
        }

        /// One part up, its ETag back, copied into the Scope: the head's
        /// bytes are read over by the next call. The query is written into
        /// the URL buffer once and sliced back out for `prepare`, so the
        /// bytes signed are the bytes sent by construction, the shape
        /// `urlForList` uses.
        fn putPart(
            self: *Self,
            c: anytype,
            key: []const u8,
            upload_id: []const u8,
            part_number: usize,
            bytes: []const u8,
            timeout_ms: u32,
        ) Error![]const u8 {
            var url_buf: [part_url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var hash_buf: [64]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const at = try self.urlToQuery(&url_buf, key);
            const query = multipart_mod.partQuery(url_buf[at..], part_number, upload_id);
            const target = url_buf[0 .. at + query.len];
            try self.prepare(&sig, &headers, .{
                .method = "PUT",
                .key = key,
                .query = query,
                .payload = self.store.payloadFor(bytes, &hash_buf),
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const got = ex.begin(&self.store.client, .{
                .method = .PUT,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .body = .{ .slice = bytes },
                .redirects = .expose,
                // A part is minutes on a slow uplink, not a short call: no
                // whole-call limit unless the source named one, and the
                // stall bound on silence, the terms `putStream` set (ADR 060).
                .timeout_ms = timeout_ms,
                .stall_ms = self.store.options.stall_ms,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &ex, got);
            const etag = got.header("etag") orelse "";
            if (etag.len == 0) {
                // Sent on anyway, the completion would be refused later with
                // `InvalidPart`, an error about the wrong call.
                std.log.warn("nilo_s3: `{s}` answered part {d} without an ETag", .{ name, part_number });
                return error.Failed;
            }
            return keepIn(c, etag);
        }

        /// The completion POST, and the one place a 200 is not an answer:
        /// the body has to say `CompleteMultipartUploadResult`.
        fn completeMultipart(
            self: *Self,
            c: anytype,
            key: []const u8,
            upload_id: []const u8,
            etags: []const []const u8,
            timeout_ms: u32,
        ) Error!void {
            const completion = try c.arena().alloc(u8, multipart_mod.completionLen(etags));
            var doc = std.Io.Writer.fixed(completion);
            multipart_mod.writeCompletion(&doc, etags) catch return error.Failed;
            const body_bytes = doc.buffered();

            var url_buf: [part_url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var hash_buf: [64]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const at = try self.urlToQuery(&url_buf, key);
            const query = multipart_mod.finishQuery(url_buf[at..], upload_id);
            const target = url_buf[0 .. at + query.len];
            try self.prepare(&sig, &headers, .{
                .method = "POST",
                .key = key,
                .query = query,
                .payload = self.store.payloadFor(body_bytes, &hash_buf),
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const got = ex.begin(&self.store.client, .{
                .method = .POST,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .body = .{ .slice = body_bytes },
                .redirects = .expose,
                // On AWS a large completion is assembled while this waits,
                // which can take minutes: the same terms as a part.
                .timeout_ms = timeout_ms,
                .stall_ms = self.store.options.stall_ms,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &ex, got);

            const answer = ex.take(c, 8 << 10) catch |err| return blame(err);
            if (!multipart_mod.completedOk(answer.view())) {
                std.log.warn(
                    "nilo_s3: `{s}` answered the completion 200 with an error in the body",
                    .{name},
                );
                return error.Failed;
            }
        }

        /// Best effort, on the way out of a failed upload: parked parts are
        /// paid-for bytes, and a bucket with no lifecycle rule keeps them
        /// forever. A failed abort is logged and the original error stands.
        ///
        /// The URL is built in the Scope rather than on the stack: an abort
        /// only runs on a failure path, where an allocation is cheap, and it
        /// must carry even an `UploadId` the part calls refused as too long,
        /// which no stack buffer here is sized for.
        fn abortMultipart(self: *Self, c: anytype, key: []const u8, upload_id: []const u8) void {
            var token_buf: [settings.session_token_max]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            const room = self.base.len + self.prefix.len + 1 + key.len * 3 +
                "?uploadId=".len + upload_id.len * 3;
            const url_buf = c.arena().alloc(u8, room) catch return;
            var w = std.Io.Writer.fixed(url_buf);
            w.writeAll(self.base) catch return;
            w.writeAll(self.prefix) catch return;
            w.writeByte('/') catch return;
            core.percent.encodeWrite(&w, key, .path) catch return;
            w.writeByte('?') catch return;
            const at = w.buffered().len;
            const query = multipart_mod.finishQuery(url_buf[at..], upload_id);
            const target = url_buf[0 .. at + query.len];
            self.prepare(&sig, &headers, .{
                .method = "DELETE",
                .key = key,
                .query = query,
                .payload = self.store.payloadNoBody(),
                .token_buf = &token_buf,
            }) catch return;

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const got = ex.begin(&self.store.client, .{
                .method = .DELETE,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .redirects = .expose,
            }) catch return;
            if (!got.ok()) {
                std.log.warn(
                    "nilo_s3: `{s}` could not abort a failed multipart upload; its parts remain until a lifecycle rule or an abort by hand",
                    .{name},
                );
            }
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

            const got = ex.begin(&self.store.client, .{
                .method = .DELETE,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .redirects = .expose,
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

            const got = ex.begin(&self.store.client, .{
                .method = .HEAD,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .redirects = .expose,
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

        /// One page of the bucket's keys under a prefix, and where the next
        /// page starts
        /// ([ADR 058](../docs/adr/058-most-of-an-s3-client-is-not-s3.md)).
        ///
        /// ```zig
        /// var cursor: ?[]const u8 = null;
        /// while (true) {
        ///     const page = try files.list(c, .{ .prefix = "exports/2026/", .max_keys = 200, .cursor = cursor });
        ///     for (page.objects) |o| { … }
        ///     cursor = (page.next orelse break).view();
        /// }
        /// ```
        ///
        /// Bounded three ways, on purpose. The page is at most `max_keys`
        /// objects and at most `keys_max` (1,000, S3's own ceiling — a number
        /// over it is refused rather than clamped, so a loop sized by what it
        /// asked for is never quietly given less). The body is read into the
        /// Scope up to a ceiling derived from `max_keys` and `key_max`, so a
        /// server answering more than it was asked for is `TooLarge` rather
        /// than an arena it fills. And **nothing here follows the cursor for
        /// the caller**: a helper that walked every page would be the call
        /// with unbounded output the module does not have, and would invite
        /// reading a bucket as a database. The cursor is handed back and the
        /// loop is the caller's.
        ///
        /// What it costs: two allocations in the Scope for the body and the
        /// page, plus one per key for the decoded key and one per ETag —
        /// a key arrives percent-encoded and an ETag with its quotes as
        /// entities, and each is decoded once into memory of its own size.
        pub fn list(self: *Self, c: anytype, listing: Listing) Error!Page {
            comptime core.checkScope(@TypeOf(c), "bucket.list");

            if (listing.max_keys == 0 or listing.max_keys > listing_mod.keys_max) {
                std.log.warn(
                    "nilo_s3: `{s}`.list asked for {d} keys a page; S3 answers 1 to {d}",
                    .{ name, listing.max_keys, listing_mod.keys_max },
                );
                return error.Rejected;
            }
            if (listing.prefix.len > settings.key_max) {
                std.log.warn(
                    "nilo_s3: a prefix of {d} bytes is longer than `{s}`'s `key_max` of {d}",
                    .{ listing.prefix.len, name, settings.key_max },
                );
                return error.Rejected;
            }
            if (listing.cursor) |cursor| if (cursor.len > listing_mod.cursor_max) {
                std.log.warn(
                    "nilo_s3: `{s}`.list was handed a cursor of {d} bytes, over the {d} a server hands out",
                    .{ name, cursor.len, listing_mod.cursor_max },
                );
                return error.Rejected;
            };

            var url_buf: [list_url_max]u8 = undefined;
            var token_buf: [settings.session_token_max]u8 = undefined;
            var sig: sign.Signature = .none;
            var headers: Headers = .{};

            // One buffer: the query is written in place, after the `?`, and
            // signed from there — so the bytes signed are the bytes sent
            // by construction rather than by a copy.
            const target = self.urlForList(&url_buf, listing);
            const query = target[std.mem.indexOfScalar(u8, target, '?').? + 1 ..];
            try self.prepare(&sig, &headers, .{
                .method = "GET",
                .key = "",
                .root = true,
                .query = query,
                .payload = self.store.payloadNoBody(),
                .token_buf = &token_buf,
            });

            var ex: fetch.Exchange = .idle;
            defer ex.end();

            const got = ex.begin(&self.store.client, .{
                .method = .GET,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .redirects = .expose,
            }) catch |err| return blame(err);

            if (!got.ok()) return self.failure(c, &ex, got);

            // What a page of this many keys can weigh: a fixed frame, and per
            // object the tags, a date, an ETag, a size, and a key encoded at
            // three bytes a character. A server sending more than that is
            // not answering the question that was asked.
            const bound = 2048 + @as(usize, listing.max_keys) * (320 + settings.key_max * 3);
            const body = ex.take(c, bound) catch |err| return blame(err);
            const xml = body.view();

            // Decided before any key is read, and the cursor before any is
            // kept: a page that cannot be continued fails whole.
            const cursor = listing_mod.nextCursor(xml) catch return error.Failed;
            const encoded = listing_mod.keysEncoded(xml);

            const objects = try c.arena().alloc(Listed, listing_mod.Objects.count(xml));
            var walk: listing_mod.Objects = .init(xml);
            for (objects) |*object| {
                const raw = walk.next() orelse unreachable; // counted a moment ago
                // `+` is a space here, as in a form: that is how AWS and
                // MinIO both write one under `encoding-type=url`, and a `+`
                // in the key itself arrives as `%2B`. Only when the answer
                // echoes `<EncodingType>url</EncodingType>`: a server that
                // ignored the request sends the key as it is.
                const key = if (encoded)
                    core.percent.decode(c.arena(), raw.key, true) catch return error.OutOfMemory
                else
                    c.arena().dupe(u8, raw.key) catch return error.OutOfMemory;
                const etag = try c.arena().alloc(u8, listing_mod.unescapedLen(raw.etag));
                object.* = .{
                    .key = c.str(key),
                    .size = std.fmt.parseInt(u64, raw.size, 10) catch return error.Failed,
                    .etag = c.str(listing_mod.unescapeInto(etag, raw.etag)),
                    .last_modified = c.str(raw.last_modified),
                };
            }

            const next: ?Str = if (cursor) |raw| next: {
                const room = try c.arena().alloc(u8, listing_mod.unescapedLen(raw));
                break :next c.str(listing_mod.unescapeInto(room, raw));
            } else null;

            return .{ .objects = objects, .next = next };
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
            if (key.len == 0) return refuseEmptyKey("presign");
            if (key.len > settings.key_max) return error.Rejected;

            const io = self.store.client.inner.io;
            const now_ms = core.nowMillis();
            const now_s = @divFloor(now_ms, 1000);

            var token_buf: [settings.session_token_max]u8 = undefined;
            const signing = self.store.keyFor(io, now_ms, &token_buf) catch |err|
                return blame(err);

            const expires = try life(wanted_seconds, signing, now_s);

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
                // The host the browser will send, which is the public one
                // when there is one: it is inside the signature (ADR 177).
                .headers = .{ .host = self.public_host },
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

            w.writeAll(self.public_base) catch unreachable;
            w.writeAll(self.prefix) catch unreachable;
            w.writeByte('/') catch unreachable;
            core.percent.encodeWrite(&w, key, .path) catch unreachable;
            w.print("?{s}&X-Amz-Signature={x}", .{ query, &signature }) catch unreachable;

            return .{
                .url = c.str(w.buffered()),
                .expires_at = now_s + expires,
            };
        }

        /// A form a browser can post straight to the bucket, and the moment it
        /// stops working.
        ///
        /// `presign` signs a request nilo has described. This signs the
        /// conditions a request the browser has not made yet has to meet, so it
        /// touches no socket either and the two share everything but the last
        /// step: the signature is one HMAC of the base64 policy with the day's
        /// key rather than one over a canonical request (ADR 112). It is in
        /// nilo rather than in an application because the alternative puts
        /// ADR 060's daily key derivation in two places that have to agree
        /// about a rotation, and the first anybody hears of a disagreement is
        /// every upload failing at 00:00 UTC.
        ///
        /// Life is clamped by `life` below, exactly as `presign`'s is, and
        /// `expires_at` is the true number rather than the one asked for.
        ///
        /// **Size is clamped to the bucket's `max_bytes`, and defaults to it.**
        /// A `content-length-range` condition is therefore always in the
        /// policy, and a form with no ceiling is not something this call can
        /// hand out. The reason is what `max_bytes` means: it is the largest
        /// object this bucket deals in, a browser POST is the one path that
        /// could put a bigger one there without nilo seeing a byte, and an
        /// object over it is one `get` refuses for the rest of its life. A
        /// caller who wants more raises `max_bytes`, which is the same lever
        /// they would pull to read it back.
        ///
        /// Everything in the answer is the Scope's memory, in one allocation
        /// for the text and one for the list. The text is 2,449 bytes for an
        /// ordinary key on static credentials and 15,949 with a 900-byte
        /// session token, both at the ceiling rather than at what was used;
        /// `presign` already allocates about 9 KiB in the second case, so this
        /// is the same order rather than a new cost. The stack is 366 bytes of
        /// named buffers plus `session_token_max`, which is less than
        /// `presign`'s, and deliberately: the policy is arena and by ADR 062
        /// a stack buffer is held per *connection* (ADR 017's second axis).
        pub fn presignPost(self: *Self, c: anytype, key: []const u8, post: Post) Error!Posted {
            comptime core.checkScope(@TypeOf(c), "bucket.presignPost");
            // An empty key is fine for a prefix policy, where it means any key.
            if (key.len == 0 and !post.prefix) return refuseEmptyKey("presignPost");
            if (key.len > settings.key_max) return error.Rejected;

            const io = self.store.client.inner.io;
            const now_ms = core.nowMillis();
            const now_s = @divFloor(now_ms, 1000);

            var token_buf: [settings.session_token_max]u8 = undefined;
            const signing = self.store.keyFor(io, now_ms, &token_buf) catch |err|
                return blame(err);

            const expires = try life(post.seconds, signing, now_s);
            const expires_at = now_s + expires;

            const stamp: sign.Stamp = .at(now_s);
            const dies: sign.Stamp = .at(expires_at);
            var expiry_buf: [sign.Stamp.expiration_len]u8 = undefined;

            var cred_buf: [sign.akid_max + 1 + sign.scope_max]u8 = undefined;
            const credential = std.fmt.bufPrint(&cred_buf, "{s}/{s}", .{
                signing.keyed.akid(),
                signing.keyed.credentialScope(),
            }) catch unreachable; // both halves are capped by `sign`

            const policy: sign.Policy = .{
                .bucket = name,
                .key = key,
                .prefix = post.prefix,
                .expiration = dies.expiration(&expiry_buf),
                .credential = credential,
                .date = stamp.iso(),
                .token = signing.token,
                .content_type = post.content_type,
                .max_bytes = @min(post.max_bytes orelse settings.max_bytes, settings.max_bytes),
            };

            // One allocation, holding the document, the base64 of it, the
            // signature and every field value. The policy is up to 3 KiB with a
            // long key, and by ADR 062 a stack buffer that size is held per
            // *connection*, so it goes in the arena the way `presign`'s URL
            // does. The ceiling is taken and the used part handed back: the
            // arena is reset whole per request, so a second pass to measure
            // first would save nothing.
            const doc_room = sign.policySize(policy);
            const encoder = std.base64.standard.Encoder;
            const total = doc_room + encoder.calcSize(doc_room) + 64 +
                self.public_base.len + self.prefix.len + credential.len +
                stamp.iso().len + key.len +
                sign.textLen(post.content_type) + sign.textLen(signing.token);

            const room = try c.arena().alloc(u8, total);
            var at: usize = 0;

            var pw = std.Io.Writer.fixed(room[at..]);
            sign.writePolicy(&pw, policy) catch unreachable; // `policySize` is the ceiling
            const doc = pw.buffered();
            at += doc.len;

            // What the browser posts, and what is signed. Standard base64
            // rather than the URL-safe alphabet: a policy travels in a form
            // field, not in a query.
            const encoded = encoder.encode(room[at..][0..encoder.calcSize(doc.len)], doc);
            at += encoded.len;

            const signed = sign.signature(signing.keyed.key, encoded);
            const hex = std.fmt.bufPrint(room[at..], "{x}", .{&signed}) catch unreachable;
            at += hex.len;

            // The form's action is the bucket, not the key: a POST policy
            // posts to the bucket and says the key in a field.
            var uw = std.Io.Writer.fixed(room[at..]);
            uw.writeAll(self.public_base) catch unreachable;
            uw.writeAll(self.prefix) catch unreachable;
            const url = uw.buffered();
            at += url.len;

            // The order is fixed, because a form is written against it. The
            // file input goes after all of these: S3 ignores whatever follows
            // the file part, so a `policy` sent after it is one S3 never reads.
            var fields: [9]Field = undefined;
            var n: usize = 0;
            // The policy's first condition, as a field. AWS reads the bucket
            // off the URL and ignores the field; Garage refuses the form
            // without it — *Key 'bucket' is required in policy, but no value
            // was provided* — and the value is a constant in the binary, so
            // it is sent everywhere (ADR 177).
            fields[n] = .{ .name = "bucket", .value = name };
            n += 1;
            fields[n] = .{ .name = "key", .value = cut(room, &at, key) };
            n += 1;
            // The one value that needs no copy, because it is a constant in the
            // binary rather than anything belonging to this request.
            fields[n] = .{ .name = "x-amz-algorithm", .value = sign.algorithm };
            n += 1;
            fields[n] = .{ .name = "x-amz-credential", .value = cut(room, &at, credential) };
            n += 1;
            fields[n] = .{ .name = "x-amz-date", .value = cut(room, &at, stamp.iso()) };
            n += 1;
            if (signing.token) |t| {
                fields[n] = .{ .name = "x-amz-security-token", .value = cut(room, &at, t) };
                n += 1;
            }
            if (post.content_type) |ct| {
                fields[n] = .{ .name = "Content-Type", .value = cut(room, &at, ct) };
                n += 1;
            }
            fields[n] = .{ .name = "policy", .value = encoded };
            n += 1;
            fields[n] = .{ .name = "x-amz-signature", .value = hex };
            n += 1;

            const kept = try c.arena().alloc(Field, n);
            @memcpy(kept, fields[0..n]);

            return .{ .url = url, .fields = kept, .expires_at = expires_at };
        }

        /// How long a presigned anything actually lives: the smallest of what
        /// was asked for, what the bucket allows, and what the credentials have
        /// left.
        ///
        /// One place rather than two. `presign` and `presignPost` both hand
        /// back a number somebody will store in a database, and two copies of
        /// this arithmetic is two chances to clamp against a different pair
        /// (ADR 112).
        fn life(wanted_seconds: u32, signing: Store.Signing, now_s: i64) Error!u32 {
            var expires = @min(wanted_seconds, settings.presign_max);
            if (signing.expires_at) |dies_at| {
                const left = dies_at - now_s;
                if (left <= 0) return error.Rejected;
                expires = @min(expires, std.math.lossyCast(u32, left));
            }
            return expires;
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
            /// Canonical already — `listing.query` writes it so. Empty for
            /// every call but `list`, which is the one call here whose
            /// request is a question rather than a key.
            query: []const u8 = "",
            /// Set by `list` alone: the one call whose request is addressed
            /// to the bucket itself, so the one call whose key is empty.
            root: bool = false,
            token_buf: []u8,
        };

        /// An empty key is not an object, it is the bucket: `GET` on it is a
        /// listing, `DELETE` is DeleteBucket and `PUT` is CreateBucket, so it
        /// changes the operation rather than naming a smaller object. Refused
        /// here, before anything is signed (ADR 059). `list` is the call that
        /// means the root and does not come through here.
        fn refuseEmptyKey(call: []const u8) Error {
            std.log.warn(
                "nilo_s3: `{s}`.{s} was given an empty key, which addresses the " ++
                    "bucket and not an object",
                .{ name, call },
            );
            return error.Rejected;
        }

        /// A header value goes into the request head as it is, and std's
        /// client only asserts against a line break, so a filename from a
        /// user in `content_disposition` would panic a ReleaseSafe build and
        /// split the request on a pooled connection in ReleaseFast. Any byte
        /// under 0x20 but tab, and 0x7f, is refused (RFC 9110 field values).
        fn checkHeader(header_name: []const u8, value: ?[]const u8) Error!void {
            const v = value orelse return;
            for (v) |b| {
                if ((b < 0x20 and b != '\t') or b == 0x7f) {
                    std.log.warn(
                        "nilo_s3: `{s}` was given a `{s}` with a control byte (0x{x:0>2}) in it",
                        .{ name, header_name, b },
                    );
                    return error.Rejected;
                }
            }
        }

        /// Sign, and fill in the headers that go out beside the signature.
        fn prepare(self: *Self, sig: *sign.Signature, headers: *Headers, req: Prepare) Error!void {
            if (req.key.len == 0 and !req.root) return refuseEmptyKey(req.method);
            if (req.key.len > settings.key_max) {
                std.log.warn(
                    "nilo_s3: a key of {d} bytes is longer than `{s}`'s `key_max` of {d}",
                    .{ req.key.len, name, settings.key_max },
                );
                return error.Rejected;
            }
            try checkHeader("content-type", req.content_type);
            try checkHeader("cache-control", req.cache_control);
            try checkHeader("content-disposition", req.content_disposition);
            try checkHeader("if-none-match", req.if_none_match);

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
                .query = req.query,
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

            const got = ex.begin(&self.store.client, .{
                .method = .GET,
                .url = target,
                .host = self.host,
                .authorization = sig.value(),
                .headers = headers.slice(),
                .redirects = .expose,
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

        /// `https://files.s3.amazonaws.com/big.mp4?` and where the query
        /// goes: the multipart calls write their canonical query into the
        /// same buffer after this, once, and slice it back out for
        /// `prepare` — signed bytes and sent bytes are one spelling by
        /// construction, the same one-buffer shape `urlForList` uses.
        fn urlToQuery(self: *Self, buf: *[part_url_max]u8, key: []const u8) Error!usize {
            var w = std.Io.Writer.fixed(buf);
            w.writeAll(self.base) catch return error.Rejected;
            w.writeAll(self.prefix) catch return error.Rejected;
            w.writeByte('/') catch return error.Rejected;
            core.percent.encodeWrite(&w, key, .path) catch return error.Rejected;
            w.writeByte('?') catch return error.Rejected;
            return w.buffered().len;
        }

        /// `https://s3.amazonaws.com/files/?encoding-type=url&list-type=2…`:
        /// the bucket's root and a query, for the one call that asks about
        /// the bucket rather than about a key. Cannot fail: `list_url_max`
        /// is a ceiling on every part, and `list` has already refused a
        /// prefix or a cursor longer than the ceiling was sized for.
        fn urlForList(self: *Self, buf: *[list_url_max]u8, listing: Listing) []const u8 {
            var w = std.Io.Writer.fixed(buf);
            w.writeAll(self.base) catch unreachable;
            w.writeAll(self.prefix) catch unreachable;
            w.writeAll("/?") catch unreachable;
            const written = w.buffered().len;
            const query = listing_mod.query(buf[written..], listing);
            return buf[0 .. written + query.len];
        }

        /// One place where everything `nilo_fetch` and the Store can fail with
        /// becomes one of the seven.
        fn blame(err: anyerror) Error {
            return switch (err) {
                error.TimedOut => error.TimedOut,
                // No bytes moved for `stall_ms`, which a handler answers the
                // way it answers a deadline: the object did not arrive.
                error.Stalled => {
                    std.log.warn("nilo_s3: {s}: a streamed transfer stalled; raise `stall_ms` if the peer is slow rather than gone", .{name});
                    return error.TimedOut;
                },
                // A credential source that did not answer in
                // `fetch_timeout_ms`, with no credentials left to sign with.
                error.CredentialsTimedOut => {
                    std.log.warn("nilo_s3: {s}: the credential source did not answer within `fetch_timeout_ms`", .{name});
                    return error.TimedOut;
                },
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

/// What `list` asks: a prefix, a page size and where to start
/// (`listing.Listing`, named here so a caller writes `s3.Listing`).
pub const Listing = listing_mod.Listing;

/// One object as a list names it: the four things S3 says about a key
/// without being asked for the key. Every text is a `Str` in the Scope.
pub const Listed = struct {
    key: Str,
    size: u64,
    /// Quotes included, the way `head` and `get` hand it back — so a value
    /// from here can be given to `getIf` as it is.
    etag: Str,
    /// As the server wrote it: `2026-09-18T10:11:12.000Z`. Text rather
    /// than a number, because the one thing every caller does with it is
    /// compare or print, and `sql.Timestamp` reads it if a caller wants
    /// arithmetic.
    last_modified: Str,
};

/// One page of a listing. `next` is the cursor to hand back as
/// `Listing.cursor` for the page after this one, and null when this was
/// the last — the loop that follows it is the caller's (ADR 058).
pub const Page = struct {
    objects: []const Listed,
    next: ?Str,
};

/// A URL somebody else can use, and the truth about when it stops working.
pub const Presigned = struct {
    url: Str,
    /// Unix seconds. `min(asked, presign_max, what the credentials have left)`
    /// — the number that is true rather than the number that was requested.
    expires_at: i64,
};

/// What one presigned POST asks for. Run time rather than compile time, unlike
/// a bucket's own options, because a form is built per request and the key it
/// is built around is data (ADR 059).
pub const Post = struct {
    /// How long the form is good for, clamped the way `presign`'s seconds are.
    seconds: u32,
    /// Refuse anything the browser does not label exactly this. Null lets the
    /// browser say what it likes, which is what a box taking receipts and
    /// screenshots and PDFs wants.
    content_type: ?[]const u8 = null,
    /// The upload's ceiling in bytes, clamped to the bucket's `max_bytes` and
    /// defaulted to it. `presignPost` says why.
    max_bytes: ?u64 = null,
    /// Treat `key` as the start of a key rather than the whole of one, which is
    /// what a browser picking its own filename needs. The policy condition
    /// becomes `starts-with`, and the `key` field is what the form extends.
    prefix: bool = false,
};

/// One field of the form, and its value.
///
/// The names are S3's, spelled the way S3 reads them back: `Content-Type` keeps
/// its capitals because the condition signed over it is `$Content-Type`, and a
/// browser that sends the field under any other spelling gets a 403 that reads
/// like a signing bug.
pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

/// Everything a browser needs to upload straight to the bucket: where to post,
/// what to send beside the file, and when the whole thing stops working.
///
/// The fields go into the form in the order they are in here, and the file
/// input goes after all of them. S3 ignores whatever follows the file part, so
/// a `policy` written after it is a `policy` S3 never reads.
pub const Posted = struct {
    /// The bucket, not the key. A POST policy posts to the bucket and says the
    /// key in a field, which is what lets the browser pick the filename.
    url: []const u8,
    fields: []const Field,
    /// Unix seconds, and the same three-way minimum `Presigned.expires_at`
    /// reports.
    expires_at: i64,
};

/// The headers that go out beside a signature. A fixed array because the set
/// is fixed (ADR 059), so there is nothing to allocate and nothing to sort.
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

/// Copy `text` into what is left of `room` and hand back the copy, moving `at`
/// past it. The Scope owns the one buffer, so a field's value is a slice of it
/// rather than an allocation of its own. It is the shape `store.zig` uses for
/// the strings a Store holds for the life of the process.
fn cut(room: []u8, at: *usize, text: []const u8) []const u8 {
    @memcpy(room[at.*..][0..text.len], text);
    defer at.* += text.len;
    return room[at.*..][0..text.len];
}

/// A `Str` or a plain slice, as a slice. Both spellings arrive here: a form
/// `Upload` carries `Str`, and a caller's own struct usually carries neither
/// more nor less than bytes.
fn viewOf(value: anytype) []const u8 {
    return if (@TypeOf(value) == Str) value.view() else value;
}

/// A content type to sign and send, or null when the caller gave none. An
/// empty (or blank) one is absent: signing `content-type:` and sending it
/// empty is a header S3 may drop or reject, and either way a 403 that says
/// nothing. A header left out of the request is left out of `SignedHeaders`
/// with it, because both are driven by this one value.
fn contentTypeOf(value: anytype) ?[]const u8 {
    const v = viewOf(value);
    return if (std.mem.trim(u8, v, " \t").len == 0) null else v;
}

/// A millisecond count the caller's own type may carry, as `optional` is for
/// text: absent, or null, is null.
fn optionalMs(value: anytype, comptime field: []const u8) ?u32 {
    if (!@hasField(@TypeOf(value), field)) return null;
    const v = @field(value, field);
    return switch (@typeInfo(@TypeOf(v))) {
        .optional => if (v) |inner| @intCast(inner) else null,
        else => @intCast(v),
    };
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

        if (settings.session_token_max > sign.token_max) @compileError(
            "nilo: s3.Bucket(\"" ++ name ++ "\") has a `session_token_max` of " ++
                std.fmt.comptimePrint("{d}", .{settings.session_token_max}) ++
                " bytes, and a presigned URL has room for a token of " ++
                std.fmt.comptimePrint("{d}", .{sign.token_max}) ++ " (`sign.token_max`).\n" ++
                "  AWS documents 2048 as the ceiling of the header, so a larger one is not an STS token.",
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

fn checkMultipartSource(comptime T: type) void {
    comptime {
        const advice = "\n  A multipart put takes `.reader` and `.content_type`, and reads until" ++
            " the reader ends: the length does not need to be known, which is what this call" ++
            " is for. `.part_bytes` is optional.";

        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: bucket.putMultipart takes what to read the object from, and " ++ @typeName(T) ++
                " is not one." ++ advice,
        );
        for ([_][]const u8{ "reader", "content_type" }) |field| {
            if (!@hasField(T, field)) @compileError(
                "nilo: bucket.putMultipart needs `." ++ field ++ "` on what it reads from.\n  " ++
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

test "a public endpoint gives a bucket a second host and base, and none gives it the first" {
    // The process dials the store on a Docker network; the browser reaches
    // it through a proxy on a name. Both are built once at `open`, the way
    // the dialled pair is (ADR 177).
    var store = try Store.open(testing.allocator, .{
        .endpoint = "http://garage:3900",
        .public_endpoint = "https://files.example.com/",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer store.deinit();

    const Files = Bucket("files", .{ .style = .path });
    var files = try Files.open(&store);
    defer files.deinit();

    try testing.expectEqualStrings("garage:3900", files.host);
    try testing.expectEqualStrings("http://garage:3900", files.base);
    try testing.expectEqualStrings("files.example.com", files.public_host);
    try testing.expectEqualStrings("https://files.example.com", files.public_base);
    try testing.expectEqualStrings("/files", files.prefix);

    // Virtual-host style puts the bucket in front of the public name too.
    const Avatars = Bucket("avatars", .{});
    var avatars = try Avatars.open(&store);
    defer avatars.deinit();
    try testing.expectEqualStrings("avatars.files.example.com", avatars.public_host);
    try testing.expectEqualStrings("https://avatars.files.example.com", avatars.public_base);

    // And with none, the public pair *is* the dialled pair: same bytes, so a
    // presigned URL under an ordinary store is exactly what it was.
    var plain = try Store.open(testing.allocator, .{
        .endpoint = "http://127.0.0.1:9000",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer plain.deinit();
    var local = try Files.open(&plain);
    defer local.deinit();
    try testing.expectEqual(local.host.ptr, local.public_host.ptr);
    try testing.expectEqual(local.base.ptr, local.public_base.ptr);

    // A public endpoint that is not one is refused the way the endpoint is.
    try testing.expectError(error.BadEndpoint, Store.open(testing.allocator, .{
        .endpoint = "http://127.0.0.1:9000",
        .public_endpoint = "files.example.com",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    }));
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
    // The refusal names the option to raise, in a log line. Right in a program,
    // noise in a suite: `zig build` prints a red `failed command:` for any step
    // that writes to stderr, so a clean run reads like a broken one.
    testing.log_level = .err;
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
