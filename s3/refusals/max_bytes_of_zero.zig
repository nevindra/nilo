//! A ceiling of zero is a bucket that refuses every get before making it —
//! which is what somebody writes when they mean "no ceiling".

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Avatars = s3.Bucket("avatars", .{ .max_bytes = 0 });
    _ = Avatars;
}
