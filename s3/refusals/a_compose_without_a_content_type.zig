//! A join has no source of its own whose content type it could keep, as a
//! `copy` does, so the joined object's type is the caller's to say, the
//! same way `putMultipart` asks for it at the initiate.

const s3 = @import("nilo_s3");
const core = @import("nilo_core");

const Videos = s3.Bucket("videos", .{});

export fn refusal() void {
    var videos: Videos = undefined;
    var run: core.Run = undefined;
    videos.compose(&run, "whole.mp4", &.{ "part-1", "part-2" }, .{}) catch {};
}
