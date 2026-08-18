//! The other half of the A/B. Identical to [`s3_none.zig`](./s3_none.zig)
//! except that the bytes come out of a bucket, so the difference between the
//! two stripped binaries is what object storage costs a program that uses it.
//!
//!     zig build size-s3 -Doptimize=ReleaseFast
//!     ls -l zig-out/bin/nilo-size-s3-*
//!
//! **The delta is not `nilo_s3` alone**, and saying so is the point of
//! measuring it this way rather than a way that flatters the module: it is
//! SigV4 and the bucket, plus `nilo_fetch`, plus `std.http.Client`, plus TLS
//! and the certificate bundle they pull in. That is the honest answer to
//! "what does adding object storage to my server cost", and
//! [`bench/result/fetch.md`](../result/fetch.md) is what separates the layers
//! inside it.
//!
//! The endpoint and the keys are constants rather than environment reads: this
//! program is built and weighed, never run, and a `getPosix` on each would put
//! three string literals in one side of a comparison about S3.

const std = @import("std");
const nilo = @import("nilo_http");
const s3 = @import("nilo_s3");

/// `key_max` matches `bench/s3_server.zig` for the same reason it does there:
/// it sizes a stack buffer in every call, and a byte of handler stack is a
/// byte on every idle connection (ADR 0063).
const Avatars = s3.Bucket("avatars", .{
    .style = .path,
    .max_bytes = 2 << 20,
    .key_max = 128,
});

fn avatar(avatars: *Avatars, c: *nilo.Ctx, id: nilo.Str) !void {
    const got = try avatars.get(c, id.view());
    return c.send(200, "application/octet-stream", got.bytes.view());
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var store = try s3.open(gpa, .{
        .endpoint = "http://127.0.0.1:9000",
        .region = "us-east-1",
        .credentials = .{ .static = .{
            .access_key_id = "niloadmin",
            .secret_access_key = "nilosecret123",
        } },
    });
    defer store.deinit();

    var avatars = try Avatars.open(&store);
    defer avatars.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&avatars);
    try app.get("/avatars/:id", avatar);
    try app.listen(.{ .port = 8080 });
}
