//! A bucket name S3 itself will not accept. Two characters is not a name; it
//! is a typo that would answer 400 on the first request in production.

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Tiny = s3.Bucket("ab", .{});
    _ = Tiny;
}
