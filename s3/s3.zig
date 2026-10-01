//! nilo's object-storage module — a bucket is a type, and a key is not.
//!
//! ```zig
//! const s3 = @import("nilo_s3");
//!
//! const Avatars = s3.Bucket("avatars", .{ .max_bytes = 5 << 20 });
//!
//! var store = try s3.open(gpa, .{
//!     .endpoint    = cfg.s3_endpoint,
//!     .region      = cfg.s3_region,
//!     .credentials = .{ .static = .{
//!         .access_key_id     = cfg.aws_access_key_id,
//!         .secret_access_key = cfg.aws_secret_access_key,
//!     } },
//! });
//! defer store.deinit();
//!
//! var avatars = try Avatars.open(&store);
//! defer avatars.deinit();
//! try app.provide(&avatars);
//!
//! fn getAvatar(id: Uuid, avatars: *Avatars, c: *nilo.Ctx) !s3.Object {
//!     var key: [64]u8 = undefined;
//!     return avatars.get(c, try std.fmt.bufPrint(&key, "{f}.png", .{id}));
//! }
//! ```
//!
//! ## Most of an S3 client is not S3
//!
//! It is HTTP, TLS, a connection pool and the policy round them, and none of
//! that is this module's subject
//! ([ADR 058](../docs/adr/058-most-of-an-s3-client-is-not-s3.md) counted:
//! sharing nilo's *server* parser would have covered 24% of the framing and
//! none of the two expensive parts). So the client is `nilo_fetch`, which is
//! `std.http.Client` with a gate, a deadline and a bounded drain in front of
//! it, and **what is left here is signing and the bucket**
//! ([ADR 063](../docs/adr/063-an-object-store-is-a-service-that-dials.md)).
//!
//! | file | what it is |
//! |---|---|
//! | `sign.zig` | SigV4. No IO, no allocation, and every test is an AWS vector |
//! | `store.zig` | the endpoint, the credentials, and the key derived from them |
//! | `bucket.zig` | the type a handler holds, and the calls on it |
//! | `code.zig` | what S3 says when it says no, and what a handler is told |
//! | `canned.zig` | a fake S3 that checks signatures, on a loopback socket |
//! | `live.zig` | the half that needs a real one |
//!
//! | `listing.zig` | the query a `list` sends and the five names it reads back |
//! | `multipart.zig` | the queries, the UploadId and the completion document of `putMultipart` |
//!
//! ## What it will not do
//!
//! `COPY`, because **it is where S3 stops being bytes at a key and starts
//! being a document format**, and it carries a trap of its own: a copy can
//! answer 200 with an error in the body. `LIST` and multipart upload were
//! refused on the same ground for a cycle each, and what let each in is the
//! observation `code.zig` had already made about error bodies: a fixed, flat
//! document with a handful of interesting names in it is a scan rather than
//! a parser (ADR 058). `list` is bounded — one page, a cursor handed back,
//! and no helper that follows it — because the call with unbounded output is
//! the one that invites reading a bucket as a database. `putMultipart` owns
//! the whole protocol in one call, reads the completion's body because a 200
//! there is the same trap `COPY` carries, and aborts on the way out of a
//! failure. `COPY` stays on the roadmap with the reason attached.
//!
//! Arbitrary `x-amz-meta-*` is refused too, on a performance argument that can
//! therefore be revisited with a measurement: the header set being fixed is
//! what makes `SignedHeaders` a walk rather than a per-request sort. Whoever
//! wants it should bring the number.
//!
//! ## Where it sits
//!
//! A **Service**: it borrows the event loop and holds a named destination, the
//! way `nilo_sql` holds a pool to a database in its URL. It imports
//! `nilo_core` and `nilo_fetch` and nothing else, and `zig build layering`
//! holds that.

const std = @import("std");

pub const sign = @import("sign.zig");
pub const code = @import("code.zig");
pub const store = @import("store.zig");
pub const bucket = @import("bucket.zig");

/// The type a handler asks for. Two buckets are two types, therefore two
/// Services, and which one a handler reaches is written in its argument list
/// (ADR 059).
pub const Bucket = bucket.Bucket;

/// What every bucket in the program shares: the endpoint, the region, the
/// credentials, the connection pool and its gate.
pub const Store = store.Store;
pub const Credentials = store.Credentials;
pub const Source = store.Source;
pub const Options = store.Options;

/// Open the Store. **It dials nothing here** — a Service that needs the loop
/// is finished when the loop exists (ADR 037), so the first credential fetch
/// happens in `nilo_start`, which `listen()` calls before it accepts anything.
pub fn open(gpa: std.mem.Allocator, options: Options) store.OpenError!Store {
    return Store.open(gpa, options);
}

pub const Object = bucket.Object;
pub const Meta = bucket.Meta;
pub const Listing = bucket.Listing;
pub const Listed = bucket.Listed;
pub const Page = bucket.Page;
pub const Presigned = bucket.Presigned;
/// A browser's own upload: what to ask for, and the form that comes back
/// (ADR 112).
pub const Post = bucket.Post;
pub const Posted = bucket.Posted;
pub const Field = bucket.Field;
pub const Range = bucket.Range;
pub const Style = bucket.Style;
pub const Sse = bucket.Sse;

/// The seven failures a handler can tell apart, and the whole list. Exactly
/// one carries a default status — `NotFound` is a 404 — because it is the one
/// whose meaning does not change with the request around it (ADR 059).
pub const Error = code.Error;

test {
    // Every file in this module, or its tests never run — the same rule
    // `http/http.zig` states for the framework.
    _ = sign;
    _ = code;
    _ = store;
    _ = bucket;
    _ = @import("listing.zig");
    _ = @import("multipart.zig");
    // A fake S3 on a loopback socket, which needs no container and runs in
    // `zig build test-s3` every time.
    _ = @import("canned.zig");
    // And the half that needs a real one. Every test in there skips when
    // `S3_ENDPOINT` is unset, so this line costs nothing to somebody who has
    // not started a MinIO.
    _ = @import("live.zig");
}
