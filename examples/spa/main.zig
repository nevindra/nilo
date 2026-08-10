//! A single-page app served next to its own JSON API — the shape most
//! small web apps actually have.
//!
//! ```
//! zig build run-spa      # then open http://127.0.0.1:8787
//! ```
//!
//! `public/` is read into memory when the server starts, not per request
//! (ADR 0010). Every file gets an ETag at load, so a reload costs a 304
//! and no body.

const std = @import("std");
const zfast = @import("zfast");

// The two lines every zfast root file wants: one keeps `std.log` from
// blocking the event loop, the other keeps the Engine's debug chatter out
// of your logs. `listen()` says so at startup if either is missing.
pub const std_options = zfast.std_options;
pub const std_options_debug_io = zfast.debug_io;
pub const panic = zfast.panic;

const Task = struct { id: u32, title: []const u8, done: bool };

const tasks = [_]Task{
    .{ .id = 1, .title = "Read the zfast README", .done = true },
    .{ .id = 2, .title = "Write a handler that is just a function", .done = true },
    .{ .id = 3, .title = "Find out where the ETag came from", .done = false },
};

fn listTasks() []const Task {
    return &tasks;
}

pub fn main() !void {
    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.use(zfast.logger.standard);

    // Routes come first when a path could be either, so the API is never
    // shadowed by a file that happens to share its name.
    try app.get("/api/tasks", listTasks);

    // `spa_fallback` is what makes a browser reload on /tasks/3 reach the
    // client-side router instead of a 404: any path with no file behind it
    // gets index.html.
    try app.staticWith("/", "public", .{
        .spa_fallback = "index.html",
        .cache_control = "public, max-age=60",
    });

    try app.listen(.{});
}
