// http.zig — the direct in-language competitor, named in zfast's history.md.
const std = @import("std");
const httpz = @import("httpz");

const PORT = 8806;
const MAX_ID: u32 = 1_000_000;

// Same payload as zfast's src/main.zig, byte for byte.
const bio = "A systems nerd who writes Zig before breakfast. " ** 19;

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    bio: []const u8,
};

pub fn main(init: std.process.Init) !void {
    var server = try httpz.Server(void).init(init.io, init.gpa, .{
        .address = .localhost(PORT),
    }, {});
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/users/:id", getUser, .{});
    router.get("/health", health, .{});

    try server.listen();
}

fn getUser(req: *httpz.Request, res: *httpz.Response) !void {
    res.header("Access-Control-Allow-Origin", "*");

    const raw = req.param("id").?;
    const id = std.fmt.parseInt(u32, raw, 10) catch return notFound(res, raw);
    if (id == 0 or id > MAX_ID) return notFound(res, raw);

    // Serialised per request, like zfast.
    try res.json(User{
        .id = id,
        .name = "Routed Tester",
        .email = "tester@example.dev",
        .bio = bio,
    }, .{});
}

fn notFound(res: *httpz.Response, raw: []const u8) !void {
    res.setStatus(.not_found);
    res.body = try std.fmt.allocPrint(res.arena, "no user {s}", .{raw});
}

fn health(_: *httpz.Request, res: *httpz.Response) !void {
    res.body = "alive\n";
}
