//! S3 refuses a bucket named like an IP address, and finding that out from AWS
//! is worse than finding it out from the compiler.

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Numbered = s3.Bucket("192.168.1.1", .{});
    _ = Numbered;
}
