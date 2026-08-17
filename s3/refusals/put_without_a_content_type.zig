//! S3 stores what it is told an object is, and there is nothing in a slice of
//! bytes to guess it from. A `nilo.Upload` out of a form carries one; a struct
//! written by hand has to say.

const s3 = @import("nilo_s3");
const core = @import("nilo_core");

const Avatars = s3.Bucket("avatars", .{});

export fn refusal() void {
    var avatars: Avatars = undefined;
    var run: core.Run = undefined;
    avatars.put(&run, "one.png", .{ .bytes = "the bytes" }) catch {};
}
