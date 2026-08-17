//! Calling somebody else's API from inside a request.
//!
//! ```
//! zig build run-outbound
//! curl localhost:8787/repos/ziglang/zig
//! curl localhost:8787/repos/ziglang/does-not-exist
//! ```
//!
//! The whole of what `nilo_fetch` is for is in `getCard` below: one call, a
//! deadline on it, a check that the far end agreed, and the answer parsed into
//! a struct this program declared. The client is registered once in `main` and
//! asked for by type, the way every service is
//! ([ADR 0070](../../docs/adr/0070-a-fitting-borrows-the-loop.md)).
//!
//! It calls GitHub's public API, which needs no key and allows 60 requests an
//! hour from one address. Past that it answers 403, and this program says so
//! rather than pretending — which is the case worth having in an example,
//! because an upstream that refuses you is the ordinary Tuesday of calling
//! anything.

const std = @import("std");
const nilo = @import("nilo_http");
const fetch = @import("nilo_fetch");
const fail = nilo.fail;

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// What the upstream sends, trimmed to the fields this program reads.
///
/// GitHub's response has about a hundred more. Nothing has to be listed: the
/// parse takes what it recognises and ignores the rest, so this struct is a
/// statement of what the program depends on rather than a transcription of
/// somebody else's schema.
const Repo = struct {
    full_name: []const u8,
    description: ?[]const u8 = null,
    stargazers_count: u64,
    open_issues_count: u64,
};

/// What this program sends on. A different shape from `Repo` on purpose: an
/// API that forwards its upstream's fields unchanged has made that upstream's
/// schema its own.
const Card = struct {
    name: []const u8,
    blurb: []const u8,
    stars: u64,
    open_issues: u64,
};

fn card(repo: Repo) Card {
    return .{
        .name = repo.full_name,
        .blurb = repo.description orelse "no description",
        .stars = repo.stargazers_count,
        .open_issues = repo.open_issues_count,
    };
}

/// A pointer is a service; a value is request data. `owner` and `name` come
/// from `:owner` and `:name` **by position**, because Zig does not keep
/// argument names (ADR 0003).
fn getCard(api: *fetch.Client, c: *nilo.Ctx, owner: nilo.Str, name: nilo.Str) !Card {
    // Two segments of somebody else's text going into a URL. `%2e%2e%2f` in a
    // path param is how a caller reaches an endpoint this program never meant
    // to offer, so they are encoded rather than pasted — `nilo_core`'s
    // `percent`, which is in Core precisely so both a Service and a handler
    // can reach it ([ADR 0066](../../docs/adr/0066-percent-is-needed-by-two-layers.md)).
    var url: std.Io.Writer.Allocating = .init(c.arena());
    try url.writer.writeAll("https://api.github.com/repos/");
    try nilo.percent.encodeWrite(&url.writer, owner.view(), .unreserved);
    try url.writer.writeByte('/');
    try nilo.percent.encodeWrite(&url.writer, name.view(), .unreserved);

    const res = api.get(c, url.written(), .{
        // Two seconds rather than the client's thirty. A page nobody is
        // waiting behind can afford thirty; this one is inside a request
        // somebody's browser is holding open.
        .timeout_ms = 2_000,
        // GitHub refuses a request with no user agent. Most APIs want a header
        // of some kind, and this is where it goes.
        .headers = &.{.{ .name = "user-agent", .value = "nilo-example" }},
    }) catch |err| switch (err) {
        // The one failure mode a caller of anything has to have an answer for.
        // 504 rather than 500: this program is fine, the thing it asked is not.
        error.TimedOut => return fail.status(504, "github took longer than 2s", .{}),
        else => return err,
    };

    // `res.ok()` is 2xx. A 404 from the far end is a 404 from this one; a 403
    // is the rate limit, and saying which is the difference between an error
    // somebody can act on and one they file a ticket about.
    if (!res.ok()) return switch (@intFromEnum(res.status)) {
        404 => fail.notFound("no repository {s}/{s}", .{ owner.view(), name.view() }),
        403, 429 => fail.status(502, "github is rate-limiting this address", .{}),
        else => fail.status(502, "github answered {d}", .{@intFromEnum(res.status)}),
    };

    // The body is a `Str` in this request's Scope, so the parse borrows from
    // it and nothing is freed by hand. Both die at the end of the request.
    const repo = res.json(Repo, c) catch {
        return fail.status(502, "github sent something this program cannot read", .{});
    };

    return card(repo);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    // One client for the whole process. The pool inside it is keyed by host,
    // so a program calling three APIs still wants exactly one of these.
    var api: fetch.Client = .init(gpa, .{
        // The ceiling that matters on a public API: 32 calls in flight, so a
        // burst of traffic cannot turn into 500 open TLS connections.
        .max_in_flight = 32,
    });
    defer api.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.use(nilo.logger.standard);

    // `provide` before `listen`, like any service. `nilo_start` runs inside
    // `listen()`, which is where the event loop first exists — a client that
    // is called before that gets `error.NotStarted` rather than a crash.
    try app.provide(&api);

    try app.get("/repos/:owner/:name", getCard);

    try app.listen(.{});
}

const testing = std.testing;

// The shaping is an ordinary function of an ordinary struct, so it is tested
// without a server, without a network and without a mock — which is the claim
// the README makes and the reason this file has tests at all. What is *not*
// tested here is the call itself: that needs an upstream, and the ones that
// exercise it live in `fetch/live.zig` and `fetch/tls.zig`.
test "a repository with no description still gets a card" {
    const c = card(.{
        .full_name = "ziglang/zig",
        .description = null,
        .stargazers_count = 36_000,
        .open_issues_count = 3_400,
    });
    try testing.expectEqualStrings("ziglang/zig", c.name);
    try testing.expectEqualStrings("no description", c.blurb);
    try testing.expectEqual(@as(u64, 36_000), c.stars);
}

test "the upstream's field names do not leak into the response" {
    const c = card(.{
        .full_name = "nilo/nilo",
        .description = "a toolkit",
        .stargazers_count = 1,
        .open_issues_count = 0,
    });
    // `stargazers_count` is GitHub's word. `stars` is this program's, and the
    // struct is what makes that a compile-time fact rather than a convention.
    try testing.expectEqual(@as(u64, 1), c.stars);
    try testing.expectEqualStrings("a toolkit", c.blurb);
}
