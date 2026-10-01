//! The spellings a multipart upload is made of, so `bucket.zig` holds none
//! of them: the three canonical queries, the `UploadId` read out of the
//! initiate answer, the completion document, and the check that a completion
//! answered 200 actually completed
//! ([ADR 058](../docs/adr/058-most-of-an-s3-client-is-not-s3.md)).
//!
//! The same split `listing.zig` made for `list`: the scan and the writing
//! are here, where each can be tested on bytes alone, and the protocol —
//! initiate, parts, complete, abort on the way out — is `bucket.putMultipart`.

const std = @import("std");
const percent = @import("nilo_core").percent;

/// S3's floor for every part but the last. A smaller part is refused by the
/// server at `CompleteMultipartUpload` time, after the bytes went up, which
/// is why `putMultipart` refuses it before any byte moves.
pub const part_min: usize = 5 << 20;

/// S3's ceiling on parts per upload. Reached, the upload has outgrown its
/// `part_bytes` and the honest answer is an error naming the fix, not part
/// 10,001 refused by the server.
pub const parts_max: usize = 10_000;

/// What `putMultipart` uses when the source does not say: 8 MiB a part,
/// which carries objects to 80 GB before `parts_max` is near.
pub const default_part_bytes: usize = 8 << 20;

/// The longest `UploadId` the part calls can carry. AWS and the S3
/// implementations this module is tested against hand out far less; one
/// larger cannot fit the URL buffer the part calls are sized by, so the
/// bucket refuses it with its length named — after aborting the upload the
/// initiate already opened, which is why `uploadIdOf` hands an oversized id
/// back rather than swallowing it.
pub const upload_id_max: usize = 1024;

/// The longest canonical query a part or completion call can write: the two
/// parameter names, a five-digit part number, and an id encoded at three
/// bytes a character.
pub const query_max: usize = "partNumber=10000&uploadId=".len + upload_id_max * 3;

/// `uploads=`, the initiate marker. The `=` is written because the canonical
/// form SigV4 hashes carries it, and the bytes sent must be the bytes signed.
pub const initiate_query = "uploads=";

/// `partNumber=3&uploadId=…`, canonical: the two names are already in byte
/// order, fixed here rather than sorted at run time, the same reason
/// `listing.query` is a fixed list.
pub fn partQuery(out: []u8, part_number: usize, upload_id: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    w.print("partNumber={d}&uploadId=", .{part_number}) catch unreachable;
    percent.encodeWrite(&w, upload_id, .unreserved) catch unreachable;
    return w.buffered();
}

/// `uploadId=…`, for the completion POST and the abort DELETE.
pub fn finishQuery(out: []u8, upload_id: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(out);
    w.writeAll("uploadId=") catch unreachable;
    percent.encodeWrite(&w, upload_id, .unreserved) catch unreachable;
    return w.buffered();
}

/// The `<UploadId>` out of an `InitiateMultipartUploadResult`, as a slice
/// into the body. Null when the tag is missing or empty. **Length is the
/// caller's check**: an id past `upload_id_max` cannot be used, but the
/// initiate it came from has already succeeded, so the bucket needs the id
/// in hand to abort that upload before refusing it.
pub fn uploadIdOf(xml: []const u8) ?[]const u8 {
    const open = "<UploadId>";
    const start = (std.mem.indexOf(u8, xml, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, xml, start, "</UploadId>") orelse return null;
    const id = xml[start..end];
    if (id.len == 0) return null;
    return id;
}

/// How many bytes `writeCompletion` writes for this many parts: the frame,
/// and per part the tags, a five-digit number and an ETag.
pub fn completionLen(etags: []const []const u8) usize {
    var total: usize = "<CompleteMultipartUpload>".len + "</CompleteMultipartUpload>".len;
    for (etags) |etag| {
        total += "<Part><PartNumber>".len + 5 + "</PartNumber><ETag>".len +
            etag.len + "</ETag></Part>".len;
    }
    return total;
}

/// The completion document, parts in the order they went up. The ETag is
/// written as the server handed it back, quotes and all: S3 accepts both
/// spellings and an MD5-with-quotes needs no XML escaping.
pub fn writeCompletion(w: *std.Io.Writer, etags: []const []const u8) !void {
    try w.writeAll("<CompleteMultipartUpload>");
    for (etags, 1..) |etag, number| {
        try w.print("<Part><PartNumber>{d}</PartNumber><ETag>{s}</ETag></Part>", .{ number, etag });
    }
    try w.writeAll("</CompleteMultipartUpload>");
}

/// Whether a completion that answered 200 completed. **S3 can answer a
/// `CompleteMultipartUpload` with 200 and an error in the body** — the same
/// trap the roadmap pinned to `COPY` — so the status is not the answer: the
/// body is, and it has to say `CompleteMultipartUploadResult` and not
/// `<Error>`.
pub fn completedOk(xml: []const u8) bool {
    if (std.mem.indexOf(u8, xml, "<Error") != null) return false;
    return std.mem.indexOf(u8, xml, "<CompleteMultipartUploadResult") != null;
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "the part query is canonical and the id is encoded" {
    var buf: [query_max]u8 = undefined;
    try testing.expectEqualStrings(
        "partNumber=3&uploadId=abc%2Bdef%3D%3D",
        partQuery(&buf, 3, "abc+def=="),
    );
    try testing.expectEqualStrings("uploadId=plain", finishQuery(&buf, "plain"));
}

test "the upload id is read out of the initiate answer" {
    const body =
        "<?xml version=\"1.0\"?><InitiateMultipartUploadResult>" ++
        "<Bucket>b</Bucket><Key>k</Key><UploadId>2~XyZ</UploadId>" ++
        "</InitiateMultipartUploadResult>";
    try testing.expectEqualStrings("2~XyZ", uploadIdOf(body).?);
    try testing.expect(uploadIdOf("<UploadId></UploadId>") == null);
    try testing.expect(uploadIdOf("<NoSuchTag/>") == null);
    // Oversized comes back as it is: the bucket aborts the upload it names
    // before refusing it, which it cannot do without the id.
    try testing.expectEqual(upload_id_max + 1, uploadIdOf(
        "<UploadId>" ++ ("x" ** (upload_id_max + 1)) ++ "</UploadId>",
    ).?.len);
}

test "the completion document carries every part in order, sized exactly" {
    const etags: []const []const u8 = &.{ "\"aa\"", "\"bb\"" };
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeCompletion(&w, etags);
    try testing.expectEqualStrings(
        "<CompleteMultipartUpload>" ++
            "<Part><PartNumber>1</PartNumber><ETag>\"aa\"</ETag></Part>" ++
            "<Part><PartNumber>2</PartNumber><ETag>\"bb\"</ETag></Part>" ++
            "</CompleteMultipartUpload>",
        w.buffered(),
    );
    try testing.expect(w.buffered().len <= completionLen(etags));
}

test "a 200 with an error in the body is not a completion" {
    try testing.expect(completedOk(
        "<?xml version=\"1.0\"?><CompleteMultipartUploadResult><ETag>\"x\"</ETag>" ++
            "</CompleteMultipartUploadResult>",
    ));
    try testing.expect(!completedOk(
        "<?xml version=\"1.0\"?><Error><Code>InternalError</Code></Error>",
    ));
    try testing.expect(!completedOk(""));
}
