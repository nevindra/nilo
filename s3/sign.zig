//! SigV4 — the half of an object-store client that is actually S3
//! ([ADR 0069](../docs/adr/0069-a-signing-key-changes-once-a-day.md)).
//!
//! Nothing here does IO, allocates, or knows that a connection exists. It
//! turns a request that is about to go out into two strings — an
//! `Authorization` header, or a query string for a presigned URL — and every
//! one of its tests is a vector AWS published.
//!
//! ## The canonical request is never built
//!
//! SigV4 hashes a canonical form of the request:
//!
//! ```
//! GET\n/test.txt\n\nhost:examplebucket.s3.amazonaws.com\n…\n\nhost;range;…\n<payload hash>
//! ```
//!
//! Every implementation this was checked against assembles that into a buffer
//! and then hashes the buffer. It is only ever *consumed* by a hash, and a key
//! may be 1,024 bytes before encoding and 3,072 after — so the buffer is the
//! largest thing in the whole operation and it exists to be read once,
//! sequentially, by something that does not need it contiguous.
//!
//! So it is streamed into the hasher instead, through `Hashing` below.
//! **The canonical request never exists as bytes anywhere.** That is worth
//! roughly 3 KiB of a handler's stack, which by
//! [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md) is 3 KiB
//! per *connection* rather than per request, and it costs one twenty-line
//! writer.
//!
//! ## The header set is a constant, and the compiler holds it
//!
//! SigV4 signs a sorted list of header names. `Signed` below is that list, one
//! optional field each, **in the order SigV4 wants them** — and a `comptime`
//! block asserts the field names are sorted by their wire spelling, so a
//! tenth header added in the wrong place is a compile error rather than a 403
//! from AWS. Walking the fields in declaration order is therefore already
//! sorted: there is no per-request sort anywhere in this file
//! ([ADR 0068](../docs/adr/0068-a-bucket-is-a-type-and-a-key-is-not.md)).

const std = @import("std");
const core = @import("nilo_core");

const percent = core.percent;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const algorithm = "AWS4-HMAC-SHA256";
pub const terminator = "aws4_request";

/// What `x-amz-content-sha256` says when the payload is not hashed. Legal over
/// `https://` and refused by nothing that matters there, because TLS already
/// says the bytes arrived as sent — the argument, and the milliseconds it
/// saves, are in ADR 0069.
pub const unsigned_payload = "UNSIGNED-PAYLOAD";

/// SHA-256 of nothing, which is what a GET or a DELETE carries. A constant
/// rather than a hash of `""` computed at startup: it is in every AWS example
/// and reads as itself to anybody comparing.
pub const empty_payload = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// The longest secret this will derive a key from. AWS's are 40 characters and
/// STS's are the same shape; the cap exists so that deriving needs no
/// allocation, and `open` refuses a longer one by name rather than truncating
/// it into a signature nobody can debug.
pub const secret_max = 256;

/// The longest access key id. AWS's are 20 characters, and 128 is the
/// documented ceiling.
pub const akid_max = 128;

/// The longest session token kept beside a signature. STS hands out 400–1,000
/// bytes for the ordinary roles and this is the ceiling AWS documents for the
/// header.
pub const token_max = 2048;

// ---- the header set ----

/// Every header this module may sign, in canonical order.
///
/// Only `host` is always there. The field name is the header name with `-`
/// written as `_`, which is what `wireName` undoes.
///
/// **`x-amz-date` and `x-amz-content-sha256` are optional here even though
/// every signed *request* carries them**, and that is the shape a presigned
/// URL forces: it moves both into the query string, signs `host` alone, and
/// puts the payload hash only on the last line of the canonical request. A
/// version of this that made them mandatory produced a presigned signature
/// that was wrong in exactly one place, and the AWS vector at the bottom of
/// this file is what said so.
pub const Signed = struct {
    cache_control: ?[]const u8 = null,
    content_disposition: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    host: []const u8,
    range: ?[]const u8 = null,
    x_amz_content_sha256: ?[]const u8 = null,
    x_amz_date: ?[]const u8 = null,
    x_amz_security_token: ?[]const u8 = null,
    x_amz_server_side_encryption: ?[]const u8 = null,

    /// The header name a field stands for.
    ///
    /// A `comptime` expression rather than a `comptime` block, because this is
    /// called from an `inline for` whose *body* runs at run time: the value
    /// has to be comptime without the function being.
    pub fn wireName(comptime field: []const u8) []const u8 {
        return comptime blk: {
            var out: [field.len]u8 = undefined;
            for (field, 0..) |ch, i| out[i] = if (ch == '_') '-' else ch;
            const frozen = out;
            break :blk &frozen;
        };
    }

    /// The value in a field, whether or not it is optional.
    fn valueOf(self: Signed, comptime field: std.builtin.Type.StructField) ?[]const u8 {
        const v = @field(self, field.name);
        return switch (@typeInfo(field.type)) {
            .optional => v,
            else => v,
        };
    }
};

// The sortedness the whole design rests on, checked where it cannot be
// forgotten. Adding a header to `Signed` in the wrong place stops the build
// here rather than producing signatures S3 rejects with
// `SignatureDoesNotMatch` and no hint as to which byte did it.
comptime {
    const fields = @typeInfo(Signed).@"struct".fields;
    for (fields[1..], 0..) |field, i| {
        const before = Signed.wireName(fields[i].name);
        const here = Signed.wireName(field.name);
        if (std.mem.order(u8, before, here) != .lt) @compileError(
            "nilo: the headers SigV4 signs have to be listed in sorted order, and `" ++
                here ++ "` is not after `" ++ before ++ "`.\n" ++
                "  SigV4 signs a sorted list, and this file walks the fields in the order" ++
                " they are written so that nothing has to be sorted per request.",
        );
    }
}

/// The longest `SignedHeaders` list `Signed` can produce: every name, joined
/// by semicolons. Comptime, so a caller's buffer cannot be one byte short.
pub const signed_headers_max = blk: {
    var n: usize = 0;
    for (@typeInfo(Signed).@"struct".fields) |field| n += Signed.wireName(field.name).len + 1;
    break :blk n;
};

// ---- a writer that is a hash ----

/// A `std.Io.Writer` whose sink is a SHA-256.
///
/// It exists so that `percent.encodeWrite` and `w.print` can be used to build
/// the canonical request without the canonical request ever being anywhere.
/// The buffer is empty on purpose: with no capacity every write goes straight
/// to `drain`, which is the hash, so there is nothing held and nothing to
/// flush.
pub const Hashing = struct {
    hasher: Sha256,
    interface: std.Io.Writer,

    pub fn init() Hashing {
        return .{
            .hasher = Sha256.init(.{}),
            .interface = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Hashing = @alignCast(@fieldParentPtr("interface", w));
        // `buffer[0..end]` first, which for a buffer of no capacity is
        // nothing — but the contract says to consume it, and a future reader
        // giving this a buffer should not have to notice.
        self.hasher.update(w.buffer[0..w.end]);
        w.end = 0;

        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.hasher.update(bytes);
            written += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| self.hasher.update(last);
        return written + last.len * splat;
    }

    pub fn final(self: *Hashing) [32]u8 {
        self.hasher.update(self.interface.buffer[0..self.interface.end]);
        self.interface.end = 0;
        var out: [32]u8 = undefined;
        self.hasher.final(&out);
        return out;
    }
};

// ---- time ----

/// The two spellings of one instant that SigV4 wants: `20260817T014233Z` for
/// `x-amz-date`, and its first eight characters for the credential scope.
pub const Stamp = struct {
    text: [16]u8,

    pub fn at(unix_seconds: i64) Stamp {
        const secs: u64 = @intCast(@max(unix_seconds, 0));
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const time = epoch.getDaySeconds();

        var out: Stamp = .{ .text = undefined };
        _ = std.fmt.bufPrint(&out.text, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            time.getHoursIntoDay(),
            time.getMinutesIntoHour(),
            time.getSecondsIntoMinute(),
        }) catch unreachable; // sixteen bytes into sixteen bytes
        return out;
    }

    pub fn iso(self: *const Stamp) []const u8 {
        return &self.text;
    }

    pub fn date(self: *const Stamp) *const [8]u8 {
        return self.text[0..8];
    }
};

// ---- the derived key ----

/// The four HMACs of ADR 0069, done once a day rather than once a request.
///
/// `AWS4` + secret, then the date, the region, the service, the terminator.
/// What comes out signs every request made on that date in that region.
pub fn derive(secret: []const u8, date: *const [8]u8, region: []const u8) error{SecretTooLong}![32]u8 {
    if (secret.len > secret_max) return error.SecretTooLong;

    var seed: [4 + secret_max]u8 = undefined;
    @memcpy(seed[0..4], "AWS4");
    @memcpy(seed[4..][0..secret.len], secret);

    var key: [32]u8 = undefined;
    HmacSha256.create(&key, date, seed[0 .. 4 + secret.len]);
    HmacSha256.create(&key, region, &key);
    HmacSha256.create(&key, "s3", &key);
    HmacSha256.create(&key, terminator, &key);
    return key;
}

/// `20260817/ap-southeast-1/s3/aws4_request` — what a signature says it is
/// good for. Short enough to build on the stack every time it is wanted.
pub const scope_max = 8 + 1 + 64 + 1 + 2 + 1 + terminator.len;

pub fn scope(out: *[scope_max]u8, date: *const [8]u8, region: []const u8) []const u8 {
    return std.fmt.bufPrint(out, "{s}/{s}/s3/{s}", .{ date, region, terminator }) catch
        unreachable; // `region` is checked at `open`
}

// ---- signing a request ----

/// What is about to go out, in the form this file can sign it.
///
/// `path` is the **raw** key with its prefix — `/photos/wati sari.png` — and
/// is percent-encoded here, once, per RFC 3986 with `/` left alone. Encoding
/// it twice is what several AWS services want and S3 does not
/// ([ADR 0066](../docs/adr/0066-percent-is-needed-by-two-layers.md) says so
/// where whoever is signing will be reading).
pub const Request = struct {
    method: []const u8,
    /// Everything before the key, already safe to write as it stands: `""`
    /// for virtual-host addressing, `/bucket` for path style.
    prefix: []const u8 = "",
    key: []const u8,
    /// Canonical already — sorted, encoded. Empty for everything but a
    /// presigned URL.
    query: []const u8 = "",
    headers: Signed,
    /// The last line of the canonical request: a hex SHA-256 of the body, or
    /// `UNSIGNED-PAYLOAD`. Separate from the header of the same name because a
    /// presigned URL has the line and not the header.
    payload: []const u8,
};

/// The `SignedHeaders` list, written into `out`, and how much of it was used.
///
/// Declaration order is canonical order, held by the `comptime` block above,
/// so this is a walk rather than a sort.
pub fn signedHeaders(out: *[signed_headers_max]u8, headers: Signed) []const u8 {
    var n: usize = 0;
    inline for (@typeInfo(Signed).@"struct".fields) |field| {
        if (headers.valueOf(field) != null) {
            if (n != 0) {
                out[n] = ';';
                n += 1;
            }
            const name = Signed.wireName(field.name);
            @memcpy(out[n..][0..name.len], name);
            n += name.len;
        }
    }
    return out[0..n];
}

/// SHA-256 of the canonical request, without the canonical request.
pub fn canonicalHash(req: Request, headers_list: []const u8) [32]u8 {
    var hashing: Hashing = .init();
    const w = &hashing.interface;

    // Nothing here can fail: the sink is a hash, and `Hashing.drain` has no
    // way to refuse. `catch unreachable` says that once rather than nine
    // times.
    w.writeAll(req.method) catch unreachable;
    w.writeByte('\n') catch unreachable;

    w.writeAll(req.prefix) catch unreachable;
    w.writeByte('/') catch unreachable;
    percent.encodeWrite(w, req.key, .path) catch unreachable;
    w.writeByte('\n') catch unreachable;

    w.writeAll(req.query) catch unreachable;
    w.writeByte('\n') catch unreachable;

    inline for (@typeInfo(Signed).@"struct".fields) |field| {
        if (req.headers.valueOf(field)) |value| {
            w.writeAll(Signed.wireName(field.name)) catch unreachable;
            w.writeByte(':') catch unreachable;
            // Trimmed, because SigV4 canonicalises the value and a stray
            // space is a signature that does not match.
            w.writeAll(std.mem.trim(u8, value, " \t")) catch unreachable;
            w.writeByte('\n') catch unreachable;
        }
    }
    w.writeByte('\n') catch unreachable;

    w.writeAll(headers_list) catch unreachable;
    w.writeByte('\n') catch unreachable;
    w.writeAll(req.payload) catch unreachable;

    return hashing.final();
}

/// The string SigV4 actually signs, which is short and fixed in shape.
pub const string_to_sign_max = algorithm.len + 1 + 16 + 1 + scope_max + 1 + 64;

pub fn stringToSign(
    out: *[string_to_sign_max]u8,
    stamp: *const Stamp,
    credential_scope: []const u8,
    canonical: [32]u8,
) []const u8 {
    return std.fmt.bufPrint(out, "{s}\n{s}\n{s}\n{x}", .{
        algorithm,
        stamp.iso(),
        credential_scope,
        &canonical,
    }) catch unreachable;
}

/// The signature itself: one HMAC over the string to sign, with the key that
/// changes once a day. The four HMACs `derive` did are not done here, which is
/// the only per-request saving signing has to offer.
pub fn signature(key: [32]u8, string: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    HmacSha256.create(&out, string, &key);
    return out;
}

/// The longest `Authorization` value: the algorithm, a credential, the header
/// list and 64 hex characters.
pub const authorization_max = algorithm.len + " Credential=".len + akid_max + 1 + scope_max +
    ",SignedHeaders=".len + signed_headers_max + ",Signature=".len + 64;

/// The whole of what one signed request needs to keep alive while it is on the
/// wire, held by the caller and nowhere else.
///
/// There is no session token in here, and that is deliberate: it is the only
/// part whose size is a property of the *deployment* rather than of SigV4, it
/// is 400–2,000 bytes, and by
/// [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md) anything
/// on this stack is held per connection for as long as that connection lives.
/// So the buffer for it belongs to whoever knows whether there will be one —
/// `Bucket`, at compile time, where a program on static credentials declares
/// nothing at all.
pub const Signature = struct {
    authorization: [authorization_max]u8 = undefined,
    authorization_len: u16 = 0,
    stamp: Stamp = .{ .text = undefined },

    pub const none: Signature = .{};

    pub fn value(self: *const Signature) []const u8 {
        return self.authorization[0..self.authorization_len];
    }

    pub fn date(self: *const Signature) []const u8 {
        return self.stamp.iso();
    }
};

/// Everything the fast path needs out of the credential cache, copied while
/// its lock is held so that signing itself holds nothing.
pub const Keyed = struct {
    key: [32]u8,
    access_key_id: [akid_max]u8,
    access_key_id_len: u8,
    scope: [scope_max]u8,
    scope_len: u8,

    pub fn akid(self: *const Keyed) []const u8 {
        return self.access_key_id[0..self.access_key_id_len];
    }

    pub fn credentialScope(self: *const Keyed) []const u8 {
        return self.scope[0..self.scope_len];
    }
};

/// Sign `req` and fill in `out`. No allocation, no lock, no clock — the stamp
/// and the key come in already decided, because deciding them is the Store's
/// job and doing it here would put a lock inside a pure function.
pub fn authorize(out: *Signature, keyed: *const Keyed, req: Request) void {
    var list_buf: [signed_headers_max]u8 = undefined;
    const list = signedHeaders(&list_buf, req.headers);

    const canonical = canonicalHash(req, list);

    var sts_buf: [string_to_sign_max]u8 = undefined;
    const sts = stringToSign(&sts_buf, &out.stamp, keyed.credentialScope(), canonical);

    const sig = signature(keyed.key, sts);

    const written = std.fmt.bufPrint(
        &out.authorization,
        "{s} Credential={s}/{s},SignedHeaders={s},Signature={x}",
        .{ algorithm, keyed.akid(), keyed.credentialScope(), list, &sig },
    ) catch unreachable; // `authorization_max` is the sum of the parts
    out.authorization_len = @intCast(written.len);
}

// ---- presigning ----

/// How long a presigned URL may claim to live. SigV4 refuses more, and
/// `Bucket` refuses it while compiling rather than letting AWS say so.
pub const expires_max: u32 = 7 * 24 * 60 * 60;

/// The query string of a presigned URL, canonical and therefore also what is
/// signed. Written into `out`, twice: once to hash, once to hand back.
pub const presign_query_max = "X-Amz-Algorithm=".len + algorithm.len +
    "&X-Amz-Credential=".len + (akid_max + scope_max) * 3 +
    "&X-Amz-Date=".len + 16 +
    "&X-Amz-Expires=".len + 10 +
    "&X-Amz-Security-Token=".len + token_max * 3 +
    "&X-Amz-SignedHeaders=".len + "host".len;

/// Build the canonical query for a presigned URL.
///
/// The parameters go out in the order SigV4 sorts them into, which for these
/// six is the order they are written — `Algorithm`, `Credential`, `Date`,
/// `Expires`, `Security-Token`, `SignedHeaders`. That is checked by the test
/// at the bottom of this file against AWS's own example rather than asserted
/// here, because the sort is over the *encoded* names and reading it off is
/// how it goes wrong.
pub fn presignQuery(
    out: *[presign_query_max]u8,
    keyed: *const Keyed,
    stamp: *const Stamp,
    expires: u32,
    token: ?[]const u8,
) []const u8 {
    var w = std.Io.Writer.fixed(out);

    w.writeAll("X-Amz-Algorithm=" ++ algorithm) catch unreachable;

    w.writeAll("&X-Amz-Credential=") catch unreachable;
    percent.encodeWrite(&w, keyed.akid(), .unreserved) catch unreachable;
    // The `/` between the key id and the scope is data here rather than a
    // separator, so it is `%2F` — the one place in this file where a slash is
    // encoded, and the difference between a presigned URL that works and one
    // that returns `SignatureDoesNotMatch`.
    percent.encodeWrite(&w, "/", .unreserved) catch unreachable;
    percent.encodeWrite(&w, keyed.credentialScope(), .unreserved) catch unreachable;

    w.print("&X-Amz-Date={s}&X-Amz-Expires={d}", .{ stamp.iso(), expires }) catch unreachable;

    if (token) |t| {
        w.writeAll("&X-Amz-Security-Token=") catch unreachable;
        percent.encodeWrite(&w, t, .unreserved) catch unreachable;
    }

    w.writeAll("&X-Amz-SignedHeaders=host") catch unreachable;
    return w.buffered();
}

// -- tests ---------------------------------------------------------------
//
// Every expected value below is AWS's own, from *Examples: Signature
// Calculations for Amazon S3*. They are the reason this file can be trusted
// before a single byte reaches a real endpoint — and they were each checked
// against an independent implementation of the specification before being
// written down, rather than copied out of a memory of the page.

const testing = std.testing;

const example_secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
const example_akid = "AKIAIOSFODNN7EXAMPLE";

fn exampleKeyed() !Keyed {
    var keyed: Keyed = .{
        .key = try derive(example_secret, "20130524", "us-east-1"),
        .access_key_id = undefined,
        .access_key_id_len = example_akid.len,
        .scope = undefined,
        .scope_len = 0,
    };
    @memcpy(keyed.access_key_id[0..example_akid.len], example_akid);
    const s = scope(&keyed.scope, "20130524", "us-east-1");
    keyed.scope_len = @intCast(s.len);
    return keyed;
}

test "the empty payload hash is the constant every example carries" {
    var out: [32]u8 = undefined;
    Sha256.hash("", &out, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&out}) catch unreachable;
    try testing.expectEqualStrings(empty_payload, &hex);
}

test "a stamp is the two spellings of one instant" {
    // 2013-05-24T00:00:00Z, the instant every AWS example is signed at.
    const stamp: Stamp = .at(1369353600);
    try testing.expectEqualStrings("20130524T000000Z", stamp.iso());
    try testing.expectEqualStrings("20130524", stamp.date());

    // And one that is not midnight, so the time half is doing something.
    const later: Stamp = .at(1369353600 + 3661);
    try testing.expectEqualStrings("20130524T010101Z", later.iso());
}

test "the signing key is the four HMACs, and nothing else" {
    const key = try derive(example_secret, "20130524", "us-east-1");
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&key}) catch unreachable;
    try testing.expectEqualStrings(
        "dbb893acc010964918f1fd433add87c70e8b0db6be30c1fbeafefa5ec6ba8378",
        &hex,
    );
}

test "AWS's GET Object example signs to AWS's signature" {
    const keyed = try exampleKeyed();
    var out: Signature = .none;
    out.stamp = .at(1369353600);

    authorize(&out, &keyed, .{
        .method = "GET",
        .key = "test.txt",
        .payload = empty_payload,
        .headers = .{
            .host = "examplebucket.s3.amazonaws.com",
            .range = "bytes=0-9",
            .x_amz_content_sha256 = empty_payload,
            .x_amz_date = "20130524T000000Z",
        },
    });

    try testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," ++
            "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," ++
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
        out.value(),
    );
}

test "AWS's PUT Object example signs to AWS's signature" {
    // The one with a payload hash, a `$` in the key that has to become `%24`,
    // and two headers this module does not otherwise send — so the canonical
    // form is built rather than guessed.
    const keyed = try exampleKeyed();

    var payload: [32]u8 = undefined;
    Sha256.hash("Welcome to Amazon S3.", &payload, .{});
    var payload_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&payload_hex, "{x}", .{&payload}) catch unreachable;
    try testing.expectEqualStrings(
        "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
        &payload_hex,
    );

    // AWS's example signs `date` and `x-amz-storage-class` as well, which are
    // not in `Signed` — so the canonical hash is built here directly, which is
    // the half `authorize` would otherwise hide.
    var hashing: Hashing = .init();
    const w = &hashing.interface;
    w.writeAll("PUT\n") catch unreachable;
    w.writeAll("/test%24file.text\n") catch unreachable;
    w.writeAll("\n") catch unreachable;
    w.writeAll("date:Fri, 24 May 2013 00:00:00 GMT\n") catch unreachable;
    w.writeAll("host:examplebucket.s3.amazonaws.com\n") catch unreachable;
    w.print("x-amz-content-sha256:{s}\n", .{&payload_hex}) catch unreachable;
    w.writeAll("x-amz-date:20130524T000000Z\n") catch unreachable;
    w.writeAll("x-amz-storage-class:REDUCED_REDUNDANCY\n") catch unreachable;
    w.writeAll("\n") catch unreachable;
    w.writeAll("date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class\n") catch unreachable;
    w.writeAll(&payload_hex) catch unreachable;
    const canonical = hashing.final();

    var stamp: Stamp = .at(1369353600);
    var sts_buf: [string_to_sign_max]u8 = undefined;
    const sts = stringToSign(&sts_buf, &stamp, keyed.credentialScope(), canonical);
    const sig = signature(keyed.key, sts);

    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&sig}) catch unreachable;
    try testing.expectEqualStrings(
        "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd",
        &hex,
    );
}

test "the key in a canonical path is encoded once, and a slash stays a slash" {
    // `$` becomes `%24`, a space becomes `%20`, and the separators survive —
    // which is `percent`'s `.path` set doing exactly what its header says.
    // Encoding it a second time, which several AWS services want, would turn
    // the `%` into `%25` and every signature into a 403.
    var out: [64]u8 = undefined;
    var plain = std.Io.Writer.fixed(&out);
    try percent.encodeWrite(&plain, "photos/wati sari$1.png", .path);
    try testing.expectEqualStrings("photos/wati%20sari%241.png", plain.buffered());
}

test "AWS's presigned example builds AWS's query and signature" {
    const keyed = try exampleKeyed();
    const stamp: Stamp = .at(1369353600);

    var query_buf: [presign_query_max]u8 = undefined;
    const query = presignQuery(&query_buf, &keyed, &stamp, 86_400, null);

    try testing.expectEqualStrings(
        "X-Amz-Algorithm=AWS4-HMAC-SHA256" ++
            "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" ++
            "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host",
        query,
    );

    // `host` alone, and the payload on the last line rather than in a header:
    // everything else this request says, it says in the query string.
    const canonical = canonicalHash(.{
        .method = "GET",
        .key = "test.txt",
        .query = query,
        .payload = unsigned_payload,
        .headers = .{ .host = "examplebucket.s3.amazonaws.com" },
    }, "host");

    var sts_buf: [string_to_sign_max]u8 = undefined;
    const sts = stringToSign(&sts_buf, &stamp, keyed.credentialScope(), canonical);
    const sig = signature(keyed.key, sts);

    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&sig}) catch unreachable;
    try testing.expectEqualStrings(
        "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
        &hex,
    );
}

test "the signed header list is a walk rather than a sort" {
    var buf: [signed_headers_max]u8 = undefined;

    // Written here in an order nobody would sort into, to show that what
    // comes out is decided by the declaration and not by the literal.
    try testing.expectEqualStrings("host;x-amz-content-sha256;x-amz-date", signedHeaders(&buf, .{
        .x_amz_date = "20260817T000000Z",
        .x_amz_content_sha256 = empty_payload,
        .host = "bucket.example.com",
    }));

    try testing.expectEqualStrings(
        "content-type;host;range;x-amz-content-sha256;x-amz-date;" ++
            "x-amz-security-token;x-amz-server-side-encryption",
        signedHeaders(&buf, .{
            .host = "bucket.example.com",
            .content_type = "image/png",
            .range = "bytes=0-1023",
            .x_amz_content_sha256 = unsigned_payload,
            .x_amz_date = "20260817T000000Z",
            .x_amz_security_token = "FQoGZ",
            .x_amz_server_side_encryption = "AES256",
        }),
    );
}

test "a header value with spaces round it signs as the value without them" {
    // SigV4 trims before it signs. A client that does not sends a signature
    // over bytes the server never sees, and the only symptom is a 403.
    const keyed = try exampleKeyed();

    var tidy: Signature = .none;
    tidy.stamp = .at(1369353600);
    authorize(&tidy, &keyed, .{
        .method = "GET",
        .key = "test.txt",
        .payload = empty_payload,
        .headers = .{
            .host = "examplebucket.s3.amazonaws.com",
            .x_amz_content_sha256 = empty_payload,
            .x_amz_date = "20130524T000000Z",
        },
    });

    var padded: Signature = .none;
    padded.stamp = .at(1369353600);
    authorize(&padded, &keyed, .{
        .method = "GET",
        .key = "test.txt",
        .payload = empty_payload,
        .headers = .{
            .host = "  examplebucket.s3.amazonaws.com ",
            .x_amz_content_sha256 = empty_payload,
            .x_amz_date = "20130524T000000Z",
        },
    });

    try testing.expectEqualStrings(tidy.value(), padded.value());
}

test "a secret longer than the ceiling is refused rather than truncated" {
    const long = "x" ** (secret_max + 1);
    try testing.expectError(error.SecretTooLong, derive(long, "20130524", "us-east-1"));
}

test "the hashing writer agrees with hashing the bytes" {
    // The whole of `canonicalHash` rests on this, and it is the sort of thing
    // that is right until somebody gives the writer a buffer.
    const text = "GET\n/test.txt\n\nhost:example.com\n\nhost\n" ++ empty_payload;

    var direct: [32]u8 = undefined;
    Sha256.hash(text, &direct, .{});

    var hashing: Hashing = .init();
    // Written in three pieces, because one call would not exercise the drain
    // being called more than once.
    hashing.interface.writeAll(text[0..10]) catch unreachable;
    hashing.interface.writeAll(text[10..20]) catch unreachable;
    hashing.interface.writeAll(text[20..]) catch unreachable;

    try testing.expectEqualSlices(u8, &direct, &hashing.final());
}
