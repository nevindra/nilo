//! A single-page app carried inside the binary, next to its own JSON API.
//!
//! ```
//! zig build run-embedded      # then open http://127.0.0.1:8787
//! ```
//!
//! `dist/` stands for what a front-end build writes: an `index.html` and
//! hashed files under `assets/`. `build.zig` lists it into the `frontend`
//! module with `embedDir`, so the program needs no `dist/` beside it and no
//! `@embedFile` written by hand (ADR 009). One set, two policies: the hashed
//! files are cached for a year, and the page that names them is revalidated
//! every time.

const std = @import("std");
const nilo = @import("nilo_http");
const frontend = @import("frontend");

// The two lines every nilo root file wants. `listen()` says so at startup
// if either is missing.
pub const std_options = nilo.std_options; // keeps the Engine's debug chatter out of your logs
pub const std_options_debug_io = nilo.debug_io; // keeps `std.log` from blocking the event loop
pub const panic = nilo.panic; // names the request that was in flight when the process goes down (ADR 007)

const Task = struct { id: u32, title: []const u8 };

const tasks = [_]Task{
    .{ .id = 1, .title = "Build the front end" },
    .{ .id = 2, .title = "Carry it in the binary" },
};

fn listTasks() []const Task {
    return &tasks;
}

/// The whole of what serving the app takes. A path with no route and no file
/// is a 404 for anything that is not a browser opening a page, so a typo in
/// `/api/...` is an error and not `index.html` (ADR 087).
fn mount(app: *nilo.App) !void {
    try app.get("/api/tasks", listTasks);
    try app.embeddedWith("/", &frontend.files, .{
        .spa_fallback = "index.html",
        .cache_control = "no-cache",
        .cache_rules = &.{
            .{ .prefix = "assets/", .cache_control = "public, max-age=31536000, immutable" },
        },
    });
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.use(nilo.logger.standard);
    try mount(&app);

    try app.listen(.{});
}

const testing = std.testing;

test "the page is revalidated and the hashed files are cached for a year" {
    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try mount(&app);
    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const page = try client.get(&app, "/");
    try testing.expectEqual(@as(u16, 200), page.status);
    try testing.expectEqualStrings("no-cache", page.header("Cache-Control").?);

    const script = try client.get(&app, "/assets/app.3f9a1c.js");
    try testing.expectEqual(@as(u16, 200), script.status);
    try testing.expectEqualStrings("public, max-age=31536000, immutable", script.header("Cache-Control").?);
}

test "a reload on a client-side route is the page and a mistyped API path is a 404" {
    var app = nilo.App.init(testing.allocator);
    defer app.deinit();
    try mount(&app);
    var client = try nilo.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const reload = try client.send(&app, "GET /tasks/2 HTTP/1.1\r\nHost: t\r\nSec-Fetch-Mode: navigate\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), reload.status);
    try testing.expect(std.mem.indexOf(u8, reload.body, "<h1>") != null);

    const typo = try client.send(&app, "GET /api/taks HTTP/1.1\r\nHost: t\r\nAccept: */*\r\n\r\n");
    try testing.expectEqual(@as(u16, 404), typo.status);
}
