//! The health route: one page that says whether this process can do its
//! job, by asking the services that know
//! ([ADR 0192](../docs/adr/0192-a-health-route-asks-the-services.md)).
//!
//! ```zig
//! try app.health("/healthz");
//! ```
//!
//! ```
//! 200 {"status":"ok"}
//! 503 {"status":"unavailable","waiting":[{"service":"sql.Db","why":"the database is not answering"}]}
//! 503 {"status":"stopping"}
//! ```
//!
//! **Alive is not ready, and a load balancer wants the second.** A route
//! that answers `ok` because the process is up sends traffic to a server
//! whose database is down, and the application cannot write the honest
//! version because it does not know what the pool knows. So the route asks
//! each service that declared `nilo_ready`, and a service that declared none
//! is assumed ready — the ordinary case for a config struct or a cache.
//!
//! **Stopping is unavailable.** From the moment SIGTERM arrives the page
//! answers 503 with `stopping`, which is how a balancer learns to drain this
//! instance before its listener closes rather than after — the flag a draining
//! response reads to say `Connection: close` (ADR 0020). Every
//! answer carries `Cache-Control: no-store`, because a health answer that a
//! proxy remembers is a health answer about the past.
//!
//! **What it costs.** Nothing per request that is not the probe. The probe
//! itself is one arena allocation for the page and whatever each hook does —
//! a `SELECT 1` for a database, a null test for a service with no hook.
//! Nothing here is held between probes.

const std = @import("std");
const core = @import("nilo_core");
const service = @import("service.zig");

pub const content_type = "application/json";

/// What a probe answered.
pub const Outcome = enum(u16) { ok = 200, unavailable = 503 };

/// Write the page for `entries` into `w`, asking each hook with `scope`,
/// and say which status it earned. Handed the pieces rather than a Ctx so
/// this file stays outside the App's core (`http_core` in build.zig).
pub fn write(
    w: *std.Io.Writer,
    scope: *core.AnyScope,
    entries: []const service.Registry.Entry,
    stopping: bool,
) !Outcome {
    if (stopping) {
        try w.writeAll("{\"status\":\"stopping\"}");
        return .unavailable;
    }

    var waiting: usize = 0;
    for (entries) |e| {
        const hook = e.ready orelse continue;
        const why = hook(e.ptr, scope) orelse continue;
        try w.writeAll(if (waiting == 0)
            "{\"status\":\"unavailable\",\"waiting\":[{\"service\":\""
        else
            ",{\"service\":\"");
        waiting += 1;
        try writeEscaped(w, e.name);
        try w.writeAll("\",\"why\":\"");
        try writeEscaped(w, why);
        try w.writeAll("\"}");
    }
    if (waiting == 0) {
        try w.writeAll("{\"status\":\"ok\"}");
        return .ok;
    }
    try w.writeAll("]}");
    return .unavailable;
}

/// A reason is a sentence somebody wrote, and a type name can carry a
/// quote; neither may break the JSON around it.
fn writeEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
}

// ---- tests ----

const testing = std.testing;

const Pool = struct {
    up: bool,

    pub fn nilo_ready(self: *Pool, _: *core.AnyScope) ?[]const u8 {
        return if (self.up) null else "the database is not answering";
    }
};

const Settings = struct { port: u16 };

test "a page with every service ready is ok, and a service with no hook is assumed ready" {
    var registry = service.Registry.init(testing.allocator);
    defer registry.deinit();
    var pool = Pool{ .up = true };
    var settings = Settings{ .port = 1 };
    try registry.add(&pool);
    try registry.add(&settings);

    var run = core.Run.init(testing.allocator);
    defer run.deinit();
    var scope = core.AnyScope.of(&run);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expectEqual(Outcome.ok, try write(&w, &scope, registry.entries.items, false));
    try testing.expectEqualStrings("{\"status\":\"ok\"}", w.buffered());
}

test "a service that is not ready names itself and says why, and stopping outranks everything" {
    var registry = service.Registry.init(testing.allocator);
    defer registry.deinit();
    var pool = Pool{ .up = false };
    try registry.add(&pool);

    var run = core.Run.init(testing.allocator);
    defer run.deinit();
    var scope = core.AnyScope.of(&run);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try testing.expectEqual(Outcome.unavailable, try write(&w, &scope, registry.entries.items, false));
    try testing.expectEqualStrings(
        "{\"status\":\"unavailable\",\"waiting\":[{\"service\":\"health.Pool\",\"why\":\"the database is not answering\"}]}",
        w.buffered(),
    );

    pool.up = true;
    w = .fixed(&buf);
    try testing.expectEqual(Outcome.unavailable, try write(&w, &scope, registry.entries.items, true));
    try testing.expectEqualStrings("{\"status\":\"stopping\"}", w.buffered());
}

test "a reason with a quote in it does not break the page" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeEscaped(&w, "say \"no\"\n");
    try testing.expectEqualStrings("say \\\"no\\\"\\n", w.buffered());
}
