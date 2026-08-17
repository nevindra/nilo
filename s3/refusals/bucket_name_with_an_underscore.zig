//! An underscore is legal in an old-style S3 bucket name and illegal in a host
//! name, so the failure only shows up under virtual-host addressing — which is
//! the default, and which is why this is caught here rather than by DNS.

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Avatars = s3.Bucket("my_avatars", .{});
    _ = Avatars;
}
