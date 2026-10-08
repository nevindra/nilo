//! The two halves of `bucket.list` that are neither a socket nor a signature
//! ([ADR 058](../docs/adr/058-most-of-an-s3-client-is-not-s3.md)):
//! the query a `ListObjectsV2` request carries, and the five element names
//! read back out of what it answers.
//!
//! This is the file that holds the XML, and it holds as little of it as it
//! can. A list result is a document AWS wrote, which is the opposite of what
//! every other call in the module handles — and the reason `LIST` was left
//! out for a cycle. What closed it is the observation `code.zig` already
//! made about error bodies: a fixed, flat document with five interesting
//! names in it is a scan for those names rather than a parser. There is no
//! tree here, no namespaces and no attributes are read, and anything the
//! server says that is not one of the five is stepped over.
//!
//! Two encodings meet in the answer, and both are handled where they arise.
//! The request asks for `encoding-type=url`, so a key comes back
//! percent-encoded and is decoded with Core's `percent`, a well-defined
//! coding, unlike the bare XML text that would otherwise need `&amp;` and
//! friends handled in every key. It is the form flavour of it, not the one a
//! key was written with on the way out: AWS and MinIO both send a space as
//! `+` and a plus as `%2B`, so `+` decodes to a space. The canned server
//! wrote `%20`, and only a real one said otherwise. An ETag is not covered
//! by that and arrives as `&quot;…&quot;` from AWS and `&#34;…&#34;` from
//! MinIO, whose XML is Go's, so the five entities XML predefines and a
//! numeric reference to an ASCII character are unescaped for it and for the
//! continuation token, and for nothing else.

const std = @import("std");
const core = @import("nilo_core");

const percent = core.percent;

/// The longest continuation token this module will send back. AWS's are
/// a few hundred characters of base64; MinIO's and Garage's are shorter.
/// A cursor is opaque, so this is a ceiling on what was handed back rather
/// than on anything a caller wrote.
pub const cursor_max = 1024;

/// The most objects one page may ask for, which is S3's own ceiling. A
/// number over it is refused rather than clamped: the caller sized their
/// arena by what they asked for, and a server quietly answering fewer would
/// leave a loop that never notices it was capped.
pub const keys_max = 1000;

/// What a page asks for.
pub const Listing = struct {
    /// Only keys starting with this. Empty is the whole bucket.
    prefix: []const u8 = "",
    /// How many at most, up to `keys_max`.
    max_keys: u16 = keys_max,
    /// Where the previous page stopped — `Page.next`, handed back as it
    /// was. Null is the first page.
    cursor: ?[]const u8 = null,
};

/// The longest canonical query `query` can write for a bucket whose keys
/// are at most `key_max` bytes: every parameter name, the fixed values, and
/// a prefix and a cursor each encoded at three bytes a character.
pub fn queryMax(key_max: usize) usize {
    return "continuation-token=".len + cursor_max * 3 +
        "&encoding-type=url".len +
        "&list-type=2".len +
        "&max-keys=1000".len +
        "&prefix=".len + key_max * 3;
}

/// The canonical query string: parameters in byte order of their names,
/// values percent-encoded with `/` as data, nothing absent written. This is
/// what goes on the wire *and* what is signed, in one spelling, which is
/// the property `sign.Request.query` asks for.
///
/// The order is `continuation-token`, `encoding-type`, `list-type`,
/// `max-keys`, `prefix` — alphabetical, and fixed here rather than sorted at
/// run time, for the reason `SignedHeaders` is a walk rather than a sort.
pub fn query(out: []u8, listing: Listing) []const u8 {
    var w = std.Io.Writer.fixed(out);
    var first = true;

    if (listing.cursor) |cursor| {
        w.writeAll("continuation-token=") catch unreachable;
        percent.encodeWrite(&w, cursor, .unreserved) catch unreachable;
        first = false;
    }

    if (!first) w.writeByte('&') catch unreachable;
    w.writeAll("encoding-type=url&list-type=2&max-keys=") catch unreachable;
    w.print("{d}", .{listing.max_keys}) catch unreachable;

    if (listing.prefix.len > 0) {
        w.writeAll("&prefix=") catch unreachable;
        percent.encodeWrite(&w, listing.prefix, .unreserved) catch unreachable;
    }

    return w.buffered();
}

/// One `<Contents>` block, as slices into the body. Encoded still: the key
/// is percent-encoded and the ETag carries entities. `bucket.list` decodes
/// both into the Scope; this type exists so that the scan and the decoding
/// are two steps that can each be tested on their own.
pub const Raw = struct {
    key: []const u8,
    size: []const u8,
    etag: []const u8,
    last_modified: []const u8,
};

/// A walk over the `<Contents>` blocks of a list body, in order.
pub const Objects = struct {
    body: []const u8,
    at: usize = 0,

    pub fn init(body: []const u8) Objects {
        return .{ .body = body };
    }

    /// The next block, or null at the end. A block missing any of the four
    /// names is stepped over rather than returned half-filled: a server
    /// that leaves one out has answered something this module does not
    /// read, and a row with an empty key is worse than one fewer row.
    pub fn next(self: *Objects) ?Raw {
        while (true) {
            const start = std.mem.indexOfPos(u8, self.body, self.at, "<Contents>") orelse return null;
            const from = start + "<Contents>".len;
            const end = std.mem.indexOfPos(u8, self.body, from, "</Contents>") orelse {
                self.at = self.body.len;
                return null;
            };
            self.at = end + "</Contents>".len;

            const block = self.body[from..end];
            const key = between(block, "<Key>", "</Key>") orelse continue;
            const size = between(block, "<Size>", "</Size>") orelse continue;
            const etag = between(block, "<ETag>", "</ETag>") orelse continue;
            const last_modified = between(block, "<LastModified>", "</LastModified>") orelse continue;
            return .{ .key = key, .size = size, .etag = etag, .last_modified = last_modified };
        }
    }

    /// How many blocks there are, without keeping any — so the caller can
    /// allocate the page once, at its size.
    pub fn count(body: []const u8) usize {
        var walk: Objects = .init(body);
        var n: usize = 0;
        while (walk.next() != null) n += 1;
        return n;
    }
};

/// The cursor for the page after this one, null when this was the last, and
/// `error.Failed` when the page says there is more and gives no way to it.
///
/// Read from `<IsTruncated>` first and `<NextContinuationToken>` second,
/// because a server may write the token on the last page too and the flag
/// is the one that says whether it means anything.
///
/// **A truncated page without a usable token is a failure, not the end.** A
/// loop that walks a bucket (a backup, a cleanup) cannot tell a listing that
/// stopped early from one that finished, so reading the missing token as
/// "last page" is silent data loss; an empty token would go back as
/// `continuation-token=`, a 400, and one over `cursor_max` is one `list`
/// itself refuses to send. `Failed` is loud and retryable. The length is that
/// of the token once its entities are characters, which is what goes back.
pub fn nextCursor(body: []const u8) error{Failed}!?[]const u8 {
    const truncated = between(body, "<IsTruncated>", "</IsTruncated>") orelse return null;
    if (!std.mem.eql(u8, truncated, "true")) return null;
    const token = between(body, "<NextContinuationToken>", "</NextContinuationToken>") orelse {
        std.log.warn("nilo_s3: a list answered IsTruncated without a NextContinuationToken", .{});
        return error.Failed;
    };
    const len = unescapedLen(token);
    if (len == 0 or len > cursor_max) {
        std.log.warn(
            "nilo_s3: a list answered IsTruncated with a continuation token of {d} bytes, " ++
                "and a usable one is 1 to {d}",
            .{ len, cursor_max },
        );
        return error.Failed;
    }
    return token;
}

/// Whether the answer says its keys are percent-encoded, which is the server
/// echoing the `encoding-type=url` the request asked for. A key is decoded
/// only then: a server that ignores the parameter sends keys as they are, and
/// decoding those turns a literal `%41` into `A` (the S3 API echoes the
/// element, and so do MinIO and Garage). An element inside a key cannot match
/// this, because XML writes its `<` as `&lt;`.
pub fn keysEncoded(body: []const u8) bool {
    const kind = between(body, "<EncodingType>", "</EncodingType>") orelse return false;
    return std.mem.eql(u8, kind, "url");
}

/// The text between one opening tag and its closing tag, at the first
/// place the opening tag appears. Null when either is missing — different
/// from `code.zig`'s `between`, which answers `""`, because here a missing
/// name is a row to skip rather than a code to read as absent.
fn between(text: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, open) orelse return null;
    const from = start + open.len;
    const end = std.mem.indexOfPos(u8, text, from, close) orelse return null;
    return text[from..end];
}

/// How long `text` is once its entities are characters. Never longer than
/// `text`, so a buffer of `text.len` always holds the answer.
pub fn unescapedLen(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (entityAt(text, i)) |e| {
            n += 1;
            i += e.len;
        } else {
            n += 1;
            i += 1;
        }
    }
    return n;
}

/// The five entities XML predefines, `&quot;`, `&amp;`, `&lt;`, `&gt;` and
/// `&apos;`, and a numeric reference to an ASCII character, `&#34;` or
/// `&#x22;`, which is how Go's encoder writes a quote. An ETag and a cursor
/// are ASCII, so a reference past it is not something either can hold, and
/// keeping every entity one byte keeps the answer no longer than the text.
/// Anything else is left as the bytes it was, which is what `percent.decode`
/// does with a broken escape and for the same reason — a value that fails to
/// decode is still a value, and refusing it would refuse the whole page.
pub fn unescapeInto(dst: []u8, text: []const u8) []u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (entityAt(text, i)) |e| {
            dst[n] = e.ch;
            n += 1;
            i += e.len;
        } else {
            dst[n] = text[i];
            n += 1;
            i += 1;
        }
    }
    return dst[0..n];
}

const Entity = struct { ch: u8, len: usize };

fn entityAt(text: []const u8, i: usize) ?Entity {
    if (text[i] != '&') return null;
    const rest = text[i..];
    const table = .{
        .{ "&quot;", '"' },
        .{ "&amp;", '&' },
        .{ "&lt;", '<' },
        .{ "&gt;", '>' },
        .{ "&apos;", '\'' },
    };
    inline for (table) |row| {
        if (std.mem.startsWith(u8, rest, row[0])) return .{ .ch = row[1], .len = row[0].len };
    }
    return numericAt(rest);
}

/// `&#34;` or `&#x22;`, for a character below 0x80, or null. More than
/// eight digits is not a reference this could accept, so it is not parsed.
fn numericAt(rest: []const u8) ?Entity {
    if (!std.mem.startsWith(u8, rest, "&#")) return null;
    const hex = rest.len > 2 and (rest[2] == 'x' or rest[2] == 'X');
    const start: usize = if (hex) 3 else 2;
    const semi = std.mem.indexOfScalarPos(u8, rest, start, ';') orelse return null;
    if (semi == start or semi - start > 8) return null;
    const value = std.fmt.parseInt(u8, rest[start..semi], if (hex) 16 else 10) catch return null;
    if (value >= 0x80) return null;
    return .{ .ch = value, .len = semi + 1 };
}

const testing = std.testing;

test "the query is canonical: sorted by name, encoded, and absent when empty" {
    var buf: [queryMax(512)]u8 = undefined;

    try testing.expectEqualStrings(
        "encoding-type=url&list-type=2&max-keys=1000",
        query(&buf, .{}),
    );
    try testing.expectEqualStrings(
        "encoding-type=url&list-type=2&max-keys=50&prefix=photos%2F2026%2F",
        query(&buf, .{ .prefix = "photos/2026/", .max_keys = 50 }),
    );
    // The cursor sorts first, and a `+` or `/` in it is data.
    try testing.expectEqualStrings(
        "continuation-token=1a2b%2Bc%2F%3D&encoding-type=url&list-type=2&max-keys=1000&prefix=a%20b",
        query(&buf, .{ .prefix = "a b", .cursor = "1a2b+c/=" }),
    );
}

test "queryMax is a ceiling rather than an estimate" {
    const key_max = 8;
    const room = queryMax(key_max);
    const buf = try testing.allocator.alloc(u8, room);
    defer testing.allocator.free(buf);
    // Every character encodes to three bytes, at the longest each may be.
    const worst_prefix = &@as([key_max]u8, @splat('\x01'));
    const worst_cursor = &@as([cursor_max]u8, @splat('\x01'));
    const q = query(buf, .{ .prefix = worst_prefix, .cursor = worst_cursor, .max_keys = 1000 });
    try testing.expectEqual(room, q.len);
}

const two_objects =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    \\  <Name>files</Name><Prefix>photos%2F</Prefix><KeyCount>2</KeyCount><MaxKeys>2</MaxKeys>
    \\  <EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>
    \\  <NextContinuationToken>1dEs3p+aG&amp;e=</NextContinuationToken>
    \\  <Contents>
    \\    <Key>photos%2Fwati%20sari.png</Key>
    \\    <LastModified>2026-09-18T10:11:12.000Z</LastModified>
    \\    <ETag>&quot;9a0364b9e99bb480dd25e1f0284c8555&quot;</ETag>
    \\    <Size>1024</Size>
    \\    <StorageClass>STANDARD</StorageClass>
    \\  </Contents>
    \\  <Contents>
    \\    <Key>photos%2Ftwo.png</Key>
    \\    <LastModified>2026-09-18T10:11:13.000Z</LastModified>
    \\    <ETag>&quot;abc&quot;</ETag>
    \\    <Size>0</Size>
    \\    <Owner><ID>x</ID><DisplayName>y</DisplayName></Owner>
    \\  </Contents>
    \\</ListBucketResult>
;

test "the objects are read in order, as the encoded slices the body holds" {
    var walk: Objects = .init(two_objects);
    const first = walk.next().?;
    try testing.expectEqualStrings("photos%2Fwati%20sari.png", first.key);
    try testing.expectEqualStrings("1024", first.size);
    try testing.expectEqualStrings("&quot;9a0364b9e99bb480dd25e1f0284c8555&quot;", first.etag);
    try testing.expectEqualStrings("2026-09-18T10:11:12.000Z", first.last_modified);
    const second = walk.next().?;
    try testing.expectEqualStrings("photos%2Ftwo.png", second.key);
    try testing.expectEqualStrings("0", second.size);
    try testing.expect(walk.next() == null);
    try testing.expect(walk.next() == null);
    try testing.expectEqual(@as(usize, 2), Objects.count(two_objects));
}

test "a truncated page names its cursor, and a whole one names none" {
    try testing.expectEqualStrings("1dEs3p+aG&amp;e=", (try nextCursor(two_objects)).?);

    const last = "<ListBucketResult><IsTruncated>false</IsTruncated>" ++
        "<NextContinuationToken>stale</NextContinuationToken></ListBucketResult>";
    try testing.expect((try nextCursor(last)) == null);
    try testing.expect((try nextCursor("<ListBucketResult></ListBucketResult>")) == null);
}

test "a truncated page without a usable token is a failure, and the key coding is read from the answer" {
    const open = "<ListBucketResult><IsTruncated>true</IsTruncated>";
    try testing.expectError(error.Failed, nextCursor(open ++ "</ListBucketResult>"));
    try testing.expectError(error.Failed, nextCursor(open ++ "<NextContinuationToken></NextContinuationToken>"));
    try testing.expectError(error.Failed, nextCursor(
        open ++ "<NextContinuationToken>" ++ &@as([(cursor_max + 1)]u8, @splat('c')) ++ "</NextContinuationToken>",
    ));
    try testing.expectEqualStrings(&@as([cursor_max]u8, @splat('c')), (try nextCursor(
        open ++ "<NextContinuationToken>" ++ &@as([cursor_max]u8, @splat('c')) ++ "</NextContinuationToken>",
    )).?);
    try testing.expect(keysEncoded(two_objects));
    try testing.expect(!keysEncoded("<ListBucketResult><Key>%41</Key></ListBucketResult>"));
}

test "a block missing one of the four names is stepped over rather than half-read" {
    const body =
        "<Contents><Key>a</Key><Size>1</Size></Contents>" ++
        "<Contents><Key>b</Key><Size>2</Size><ETag>&quot;e&quot;</ETag><LastModified>t</LastModified></Contents>" ++
        "<Contents><Key>c</Key>";
    var walk: Objects = .init(body);
    try testing.expectEqualStrings("b", walk.next().?.key);
    try testing.expect(walk.next() == null);
    try testing.expectEqual(@as(usize, 1), Objects.count(body));
    try testing.expectEqual(@as(usize, 0), Objects.count(""));
}

test "the five entities and an ASCII reference become their characters, and anything else stays" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("\"abc\"", unescapeInto(&buf, "&quot;abc&quot;"));
    try testing.expectEqualStrings("a&b<c>d'e", unescapeInto(&buf, "a&amp;b&lt;c&gt;d&apos;e"));
    // What MinIO sends, because Go's encoder writes a quote as `&#34;`.
    try testing.expectEqualStrings("\"abc\"", unescapeInto(&buf, "&#34;abc&#34;"));
    try testing.expectEqualStrings("'\"", unescapeInto(&buf, "&#x27;&#X22;"));
    // Unknown, past ASCII, malformed, or a bare ampersand: left as the bytes they were.
    try testing.expectEqualStrings("&#233;&bogus;&#;&#x;&#12a;&", unescapeInto(&buf, "&#233;&bogus;&#;&#x;&#12a;&"));
    try testing.expectEqualStrings("", unescapeInto(&buf, ""));
    try testing.expectEqual(@as(usize, 5), unescapedLen("&quot;abc&quot;"));
    try testing.expectEqual(@as(usize, 5), unescapedLen("&#34;abc&#34;"));
    try testing.expectEqual(@as(usize, 14), unescapedLen("&#233;&bogus;&"));
}
