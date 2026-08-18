//! Half of the fourth axis for `nilo_s3` (ADR 0018): the server that stores
//! nothing.
//!
//! One route, one path param, one body written back. It names no object
//! store, so its stripped size is the claim that a program which never
//! imports `nilo_s3` links none of it — not the module, not `nilo_fetch`
//! underneath it, not TLS, not a certificate bundle.
//!
//!     zig build size-s3 -Doptimize=ReleaseFast
//!     ls -l zig-out/bin/nilo-size-s3-*
//!
//! [`s3_get.zig`](./s3_get.zig) is the other half, and the difference between
//! the two is the number. Everything outside the store is deliberately
//! identical between them, down to the route and the response type, so the
//! delta cannot be an artefact of one of them doing more work.

const std = @import("std");
const nilo = @import("nilo_http");

/// The same body the other half answers with, out of the request arena rather
/// than out of a bucket. Answering a `[]const u8` constant instead would make
/// this side smaller for a reason that has nothing to do with S3.
fn avatar(c: *nilo.Ctx, id: nilo.Str) !void {
    const bytes = try c.arena().alloc(u8, 1024);
    @memset(bytes, 'x');
    _ = id;
    return c.send(200, "application/octet-stream", bytes);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.get("/avatars/:id", avatar);
    try app.listen(.{ .port = 8080 });
}
