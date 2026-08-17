//! A typo. Zig would refuse this on its own; what nilo adds is the list of
//! options that do exist, in the message.

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Avatars = s3.Bucket("avatars", .{ .maxBytes = 5 << 20 });
    _ = Avatars;
}
