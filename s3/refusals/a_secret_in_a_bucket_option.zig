//! The one that is a leak rather than a mistake.
//!
//! What is written in a bucket's type is compiled into the binary and ships
//! wherever the binary does. Credentials belong to the Store, at run time,
//! where a Config can read them from the environment.

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Avatars = s3.Bucket("avatars", .{
        .secret_access_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    });
    _ = Avatars;
}
