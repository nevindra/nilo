//! S3 answers 411 to a body whose length it was not told, and a reader has no
//! length to ask for. Saying so here makes *I do not know the size* a compile
//! error rather than a production surprise; upload of unknown size needs
//! multipart, which is on the roadmap with its reason attached.

const std = @import("std");
const s3 = @import("nilo_s3");
const core = @import("nilo_core");

const Videos = s3.Bucket("videos", .{});

export fn refusal() void {
    var videos: Videos = undefined;
    var run: core.Run = undefined;
    var source: std.Io.Reader = undefined;
    videos.putStream(&run, "one.mp4", .{
        .reader = &source,
        .content_type = "video/mp4",
    }) catch {};
}
