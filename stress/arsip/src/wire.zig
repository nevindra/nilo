//! The other half of the testing story: whole requests, through a real App,
//! with no server and no socket.
//!
//! `handlers.zig` tests the functions. This tests what a client actually gets —
//! the status, the JSON, the header — which is the only place a routing
//! mistake, a serialisation surprise or a middleware in the wrong order can
//! show up. Both run in the same `zig build test`.

const std = @import("std");
const nilo = @import("nilo_http");
const handlers = @import("handlers.zig");
const Archive = @import("archive.zig").Archive;

const testing = std.testing;

/// An App with the whole API on it, plus the store it needs.
const Server = struct {
    app: nilo.App,
    archive: Archive,
    client: nilo.testing.Client,

    fn init(gpa: std.mem.Allocator) !*Server {
        // By pointer: the App holds a pointer to the Archive, so neither may
        // move after `provide`.
        const self = try gpa.create(Server);
        self.* = .{
            .app = nilo.App.init(gpa),
            .archive = .init(gpa),
            .client = try nilo.testing.Client.init(gpa, .{}),
        };
        try self.app.provide(&self.archive);
        try handlers.mount(self.app.group("/v1"));
        self.app.docs(.{ .title = "arsip", .version = "0.1.0" });
        return self;
    }

    fn deinit(self: *Server, gpa: std.mem.Allocator) void {
        self.client.deinit();
        self.archive.deinit();
        self.app.deinit();
        gpa.destroy(self);
    }

    fn send(self: *Server, method: []const u8, path: []const u8, body: ?[]const u8) !nilo.testing.Answer {
        var head: std.Io.Writer.Allocating = .init(testing.allocator);
        defer head.deinit();
        try head.writer.print("{s} {s} HTTP/1.1\r\nHost: t\r\nX-Operator: wati\r\n", .{ method, path });
        if (body) |b| {
            try head.writer.print("Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ b.len, b });
        } else {
            try head.writer.writeAll("\r\n");
        }
        return self.client.send(&self.app, head.written());
    }
};

fn field(body: []const u8, name: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const found = parsed.value.object.get(name) orelse return error.NoSuchField;
    return switch (found) {
        .string => |s| testing.allocator.dupe(u8, s),
        else => error.NotAString,
    };
}

test "the whole life of a document, over the wire" {
    const gpa = testing.allocator;
    var s = try Server.init(gpa);
    defer s.deinit(gpa);

    // A folder that did not exist answers 201; the same folder again answers 200.
    const made = try s.send("PUT", "/v1/folders/kantor", "{\"name\":\"Kantor\",\"visibility\":\"team\"}");
    try testing.expectEqual(@as(u16, 201), made.status);
    const again = try s.send("PUT", "/v1/folders/kantor", "{\"name\":\"Kantor Pusat\"}");
    try testing.expectEqual(@as(u16, 200), again.status);

    // A body with an optional struct, a list of structs, and a list in each.
    const filed = try s.send("POST", "/v1/folders/kantor/docs",
        \\{"title":"Laporan Q3","kind":"invoice",
        \\ "meta":{"author":"wati","type":"invoice","pages":12},
        \\ "tags":["penting"],
        \\ "sections":[{"heading":"Ringkasan","lines":["Naik 12%"]}]}
    );
    try testing.expectEqual(@as(u16, 201), filed.status);
    try testing.expectEqualStrings("/v1/docs/1", filed.header("location").?);

    // The keyword field survives the round trip under its JSON name.
    try testing.expect(std.mem.indexOf(u8, filed.body, "\"type\":\"invoice\"") != null);
    try testing.expect(std.mem.indexOf(u8, filed.body, "\"lines\":[\"Naik 12%\"]") != null);

    // A document that will not move says what it is in, as a 409.
    const back = try s.send("POST", "/v1/docs/1/advance", "{\"to\":\"archived\"}");
    try testing.expectEqual(@as(u16, 409), back.status);
    const message = try field(back.body, "error");
    defer gpa.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "draft") != null);

    const on = try s.send("POST", "/v1/docs/1/advance", "{\"to\":\"review\"}");
    try testing.expectEqual(@as(u16, 200), on.status);

    // Gone means gone.
    const removed = try s.send("DELETE", "/v1/docs/1", null);
    try testing.expectEqual(@as(u16, 204), removed.status);
    const missing = try s.send("GET", "/v1/docs/1", null);
    try testing.expectEqual(@as(u16, 404), missing.status);
}

test "the guard runs whether or not the handler asked for the operator" {
    const gpa = testing.allocator;
    var s = try Server.init(gpa);
    defer s.deinit(gpa);

    const anonymous = try s.client.get(&s.app, "/v1/docs");
    try testing.expectEqual(@as(u16, 401), anonymous.status);

    const named = try s.send("GET", "/v1/docs", null);
    try testing.expectEqual(@as(u16, 200), named.status);

    // ...and the curator prefix refuses somebody who is merely signed in.
    const nosy = try s.send("GET", "/v1/curate/report", null);
    try testing.expectEqual(@as(u16, 403), nosy.status);
}

test "three bad fields in one body are named in one answer" {
    const gpa = testing.allocator;
    var s = try Server.init(gpa);
    defer s.deinit(gpa);

    _ = try s.send("PUT", "/v1/folders/kantor", "{\"name\":\"Kantor\"}");
    const refused = try s.send("POST", "/v1/folders/kantor/docs",
        \\{"title":"x","kind":"gold","visibility":"loud"}
    );

    // 422 rather than 400: the request was understood and its contents were not.
    try testing.expectEqual(@as(u16, 422), refused.status);
    const message = try field(refused.body, "error");
    defer gpa.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "kind") != null);
    try testing.expect(std.mem.indexOf(u8, message, "visibility") != null);
}

test "a query struct that does not fit is refused before the handler runs" {
    const gpa = testing.allocator;
    var s = try Server.init(gpa);
    defer s.deinit(gpa);

    const bad = try s.send("GET", "/v1/docs?sort=sideways", null);
    try testing.expectEqual(@as(u16, 400), bad.status);

    const message = try field(bad.body, "error");
    defer gpa.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "sort") != null);
}

test "the API description names every shape the signatures mention" {
    const gpa = testing.allocator;
    var s = try Server.init(gpa);
    defer s.deinit(gpa);

    const doc = try s.client.get(&s.app, "/openapi.json");
    try testing.expectEqual(@as(u16, 200), doc.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, doc.body, .{});
    defer parsed.deinit();

    const schemas = parsed.value.object.get("components").?.object.get("schemas").?.object;
    // A generic instantiation keeps a name, which is what stops a generated
    // client growing five copies of one shape.
    try testing.expect(schemas.get("Page_Doc") != null);
    try testing.expect(schemas.get("Doc") != null);
    try testing.expect(schemas.get("Failure") != null);
}
