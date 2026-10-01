//! A multipart put records the object's content type at the initiate, so the
//! source has to carry one, the same way `bucket.put` and `putStream` do.
//! What it does not need is `.len`: the reader is read to its end in parts,
//! which is the whole reason `putMultipart` exists.

const std = @import("std");
const s3 = @import("nilo_s3");
const core = @import("nilo_core");

const Videos = s3.Bucket("videos", .{});

export fn refusal() void {
    var videos: Videos = undefined;
    var run: core.Run = undefined;
    var source: std.Io.Reader = undefined;
    videos.putMultipart(&run, "one.mp4", .{ .reader = &source }) catch {};
}
