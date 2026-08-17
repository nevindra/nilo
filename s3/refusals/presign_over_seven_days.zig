//! SigV4 refuses `X-Amz-Expires` above 604,800 seconds. A URL asking for two
//! weeks is not quietly signed shorter; it is refused, at run time, by AWS.

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Links = s3.Bucket("links", .{ .presign_max = 14 * 24 * 60 * 60 });
    _ = Links;
}
