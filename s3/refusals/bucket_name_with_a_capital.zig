//! The way it usually happens: a name written the way the code around it is,
//! against a scheme where the name becomes a host label.

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Avatars = s3.Bucket("Avatars", .{});
    _ = Avatars;
}
