//! An answer that is bytes already in hand, under a label decided while the
//! request is running
//! ([ADR 173](../docs/adr/173-bytes-handed-on-are-an-answer.md)).
//!
//! ```zig
//! fn bundle(licences: *Licences, c: *nilo.Ctx, id: u32) !?nilo.Bytes {
//!     const got = try licences.download(c, id) orelse return null;
//!     return .{
//!         .body = got.body,
//!         .content_type = got.content_type,
//!         .headers = .of(&.{.{ .name = "Content-Disposition", .value = "attachment" }}),
//!     };
//! }
//! ```
//!
//! A returned value is JSON, bytes are text, a `FileBody` is a file on disk
//! and a type with `nilo_write` chooses its label while compiling — and a
//! handler passing on somebody else's bytes, with *their* `Content-Type`,
//! fitted none of the four. It took a `*Ctx` and called `c.send`, and the
//! generated description said the route wrote something it could not read.
//! This is `FileBody`'s shape with the bytes in memory instead of a `Dir`:
//! the body, the label, and the headers a download wants.
//!
//! **What the document says is what the signature settles**: bytes, as
//! `application/octet-stream` with `format: binary`, exactly as a `FileBody`
//! is described, because the real content type is a field the handler fills
//! in per request and a document that guessed `application/zip` would be
//! wrong the first time upstream sent something else.
//!
//! **What it costs is nothing the handler had not paid.** The bytes are the
//! handler's — in the request arena, or borrowed from a response it holds —
//! and go out through `c.send` as they are. Nothing is copied here.

const std = @import("std");

const Ctx = @import("ctx.zig").Ctx;
const headers_mod = @import("headers.zig");

/// The marker `typed.zig` reads, by name, the way it reads `nilo_file`.
pub const marker = "nilo_bytes";

/// An answer that is bytes in hand.
pub const Bytes = struct {
    /// What a nilo compile error calls this type (ADR 074).
    pub const nilo_type_name = "nilo.Bytes";

    /// Presence is the whole message, as with `FileBody.nilo_file`.
    pub const nilo_bytes = {};

    /// The body, as it goes out. Borrowed for as long as the response takes
    /// to write — the request arena, or a response the handler still holds.
    body: []const u8,

    /// What the bytes are. The default is the honest one for bytes nobody
    /// said anything about, and it is the string a browser reads as "save
    /// this rather than try to show it".
    content_type: []const u8 = "application/octet-stream",

    /// Headers to send with the bytes, held by value for the reason
    /// `Response.headers` are (ADR 018). This is where a download's
    /// `Content-Disposition` goes; `FileBody.headers` says why there is no
    /// `download_as` field, and the same reasons hold here.
    headers: headers_mod.Headers = .{},
};

/// Whether `T` is a bytes answer, for the compile-time engine.
pub fn isBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, marker),
        else => false,
    };
}

/// Set the headers and send. Called from `typed.sendValue` after every
/// wrapper is taken apart, so `?Bytes`, `Status(200, Bytes)` and
/// `Response(Bytes)` all reach it — and the status is the wrapper's, which
/// is the one thing a `FileBody` cannot take and this can.
pub fn send(c: *Ctx, status: u16, value: Bytes) !void {
    for (value.headers.view()) |h| try c.setHeader(h.name, h.value);
    // What the handler returned, which outlived its frame already: not copied
    // when a middleware holds the answer (ADR 008).
    return c.sendKept(status, value.content_type, value.body);
}

// ---- tests ----

const testing = std.testing;

const App = @import("app.zig").App;
const typed = @import("typed.zig");
const openapi = @import("openapi.zig");
const nilo_testing = @import("testing.zig");
const Status = typed.Status;

/// What an upstream service answered, as a proxy holds it: the bytes and
/// the label it came with.
const Licences = struct {
    fn download(self: *Licences, id: u32) ?struct { body: []const u8, content_type: []const u8 } {
        _ = self;
        return switch (id) {
            1 => .{ .body = "PK\x03\x04 not really a zip", .content_type = "application/zip" },
            2 => .{ .body = "<svg/>", .content_type = "image/svg+xml" },
            else => null,
        };
    }
};

fn bundle(licences: *Licences, id: u32) !?Bytes {
    const got = licences.download(id) orelse return null;
    return .{
        .body = got.body,
        .content_type = got.content_type,
        .headers = .of(&.{.{
            .name = "Content-Disposition",
            .value = "attachment; filename=\"bundle.zip\"",
        }}),
    };
}

fn made(licences: *Licences, id: u32) !Status(201, Bytes) {
    const got = licences.download(id) orelse return error.NotThere;
    return .{ .value = .{ .body = got.body, .content_type = got.content_type } };
}

fn appServing(app: *App, licences: *Licences) !void {
    try app.provide(licences);
    try app.get("/bundles/:id", bundle);
    try app.post("/bundles/:id", made);
}

test "a handler returning Bytes answers with them, under the label it chose per request" {
    var licences: Licences = .{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &licences);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const zip = try client.get(&app, "/bundles/1");
    try testing.expectEqual(@as(u16, 200), zip.status);
    try testing.expectEqualStrings("PK\x03\x04 not really a zip", zip.body);
    try testing.expectEqualStrings("application/zip", zip.header("Content-Type").?);
    try testing.expectEqualStrings("attachment; filename=\"bundle.zip\"", zip.header("Content-Disposition").?);
    try testing.expectEqualStrings("21", zip.header("Content-Length").?);

    // The label is the value's, so the same route answers another kind of
    // bytes under another one.
    const svg = try client.get(&app, "/bundles/2");
    try testing.expectEqualStrings("image/svg+xml", svg.header("Content-Type").?);
    try testing.expectEqualStrings("<svg/>", svg.body);

    // `?` is the 404 it is everywhere else.
    const none = try client.get(&app, "/bundles/9");
    try testing.expectEqual(@as(u16, 404), none.status);

    // And a wrapper's status is taken, which a FileBody cannot do.
    const created = try client.post(&app, "/bundles/1", "");
    try testing.expectEqual(@as(u16, 201), created.status);
    try testing.expectEqualStrings("application/zip", created.header("Content-Type").?);
}

test "the document describes Bytes as bytes, the way it describes a FileBody" {
    var op = comptime typed.operation("/bundles/:id", bundle);
    op.method = .GET;
    const ops = [_]openapi.Operation{op};

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try openapi.write(testing.allocator, &out.writer, &ops, .{});
    const document = out.written();

    // `application/octet-stream` and not `application/zip`: the content type
    // is a field the handler fills in while the request is running.
    try testing.expect(std.mem.indexOf(u8, document,
        \\"200":{"description":"the file's bytes","content":{"application/octet-stream":{"schema":{"type":"string","format":"binary"}}}}
    ) != null);
    try testing.expect(std.mem.indexOf(u8, document,
        \\"404":{"description":"there is no such thing"
    ) != null);
}
