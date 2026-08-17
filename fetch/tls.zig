//! The one test that reaches the internet, and the reason it exists.
//!
//! Everything in `fetch/live.zig` runs against `Canned`, a loopback server
//! written for the test — which means every reading it takes is of a server
//! that behaves the way the test author expected. That is enough to hold most
//! of this module and not enough to hold any of it that meets the real world.
//!
//! **The first request this file ever made came back as 388 bytes of gzip.**
//! `std.http.Client` advertises `Accept-Encoding: gzip, deflate` by default and
//! `Response.reader` hands back the *compressed* bytes; decompressing is a
//! different call. Twelve canned tests passed over that bug because `Canned`
//! never compresses anything. So `send` now asks for identity, and this file is
//! what would notice if that line were ever deleted
//! ([ADR 0033](../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
//! applies to a default as much as to a guard).
//!
//! TLS is the other half. `std.crypto.tls.Client` is 1,670 lines that no test
//! here had ever executed: certificate verification, hostname matching, the
//! handshake, the record layer. A module whose headline example is an
//! `https://` URL should have run one.
//!
//! ## It needs the network, so it is not in `zig build test`
//!
//! Run it deliberately:
//!
//! ```
//! zig build smoke-tls -Dnetwork
//! ```
//!
//! Without `-Dnetwork` every test here skips and says so. That is a deliberate
//! silent pass and the reason it is tolerable is that **this step is not part
//! of `test` or `test-all`** — nothing that gates a change can be quietly
//! green because a machine had no route out. It is run before a release and
//! after anything touches `send`, and `bench/result/fetch.md` records what it
//! found.
//!
//! The endpoints are two of the most stable on the web and neither is anyone's
//! production service: `example.com`, which IANA maintains for exactly this,
//! and `expired.badssl.com`, which exists to be refused.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");
const net_config = @import("net_config");

const testing = std.testing;

/// The whole harness: a loop, a client, a Scope. No Engine — TLS is
/// `std.crypto.tls.Client` reading through whatever `Io` it was handed, so the
/// Fitting's entry condition holds here too (ADR 0070).
fn withClient(comptime body: fn (*fetch.Client, *core.Run) anyerror!void) !void {
    if (!net_config.enabled) return error.SkipZigTest;

    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var client: fetch.Client = .init(gpa, .{ .timeout_ms = 20_000 });
    defer client.deinit();
    try client.nilo_start(threaded.io(), .off);

    var scope: core.Run = .init(gpa);
    defer scope.deinit();

    try body(&client, &scope);
}

test "a real HTTPS endpoint answers, and the body is text rather than gzip" {
    try withClient(struct {
        fn run(client: *fetch.Client, scope: *core.Run) !void {
            const res = try client.get(scope, "https://example.com/", .{});
            try testing.expectEqual(std.http.Status.ok, res.status);
            try testing.expect(res.ok());

            const body = res.body.view();

            // The assertion that matters. A gzipped body is also non-empty,
            // also 200, and also arrives without an error — so the only thing
            // that separates the working case from the bug is reading it.
            try testing.expect(std.mem.indexOf(u8, body, "<title>Example Domain</title>") != null);

            // And it is not compressed *and* correct by accident: gzip starts
            // with 0x1f 0x8b, which is the exact byte pair the first run of
            // this test found where `<!doctype` should have been.
            try testing.expect(!(body.len >= 2 and body[0] == 0x1f and body[1] == 0x8b));
        }
    }.run);
}

test "a certificate that expired is refused rather than trusted" {
    try withClient(struct {
        fn run(client: *fetch.Client, scope: *core.Run) !void {
            // The Refusal half. Without this the test above proves only that
            // *something* came back over 443; it does not prove anything was
            // checked. `expired.badssl.com` serves a valid response behind a
            // certificate that expired in 2015.
            const res = client.get(scope, "https://expired.badssl.com/", .{});
            try testing.expectError(error.TlsInitializationFailed, res);
        }
    }.run);
}

test "a body ceiling holds over TLS, where the bytes arrive in records" {
    try withClient(struct {
        fn run(client: *fetch.Client, scope: *core.Run) !void {
            // `live.zig` proves the ceiling against a plain socket. Over TLS
            // the body arrives decrypted a record at a time through a
            // different reader, which is a different path to stop on.
            const res = client.get(scope, "https://example.com/", .{ .max_body = 64 });
            try testing.expectError(fetch.Client.Error.BodyTooLarge, res);
        }
    }.run);
}
