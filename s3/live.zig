//! The half of this module's tests that needs a real object store.
//!
//! `canned.zig` proves that what nilo sends is what nilo signed, by checking
//! the signature itself. What it cannot prove is that the *rest* of an S3
//! implementation agrees — that a 404 arrives shaped the way `code.zig`
//! expects, that a presigned URL works in something that did not compute it,
//! that a real server sends `ETag` with the quotes on.
//!
//! Every test here skips when `S3_ENDPOINT` is unset, so this file costs
//! nothing to somebody who has not started a container. With one:
//!
//! ```
//! docker run -d --name minio -p 9000:9000 \
//!   -e MINIO_ROOT_USER=niloadmin -e MINIO_ROOT_PASSWORD=nilosecret123 \
//!   quay.io/minio/minio server /data
//!
//! S3_ENDPOINT=http://127.0.0.1:9000 S3_ACCESS_KEY=niloadmin \
//!   S3_SECRET_KEY=nilosecret123 zig build test-s3
//! ```
//!
//! The bucket has to exist. `bench/s3_setup.py` makes one, and is the same
//! script the benchmark uses.
//!
//! Skipping rather than failing is the same decision `sql/live.zig` made: the
//! loop somebody runs every thirty seconds must not need a container to be up,
//! or it stops being run every thirty seconds. CI sets the variables, so the
//! coverage is not optional there.

const std = @import("std");
const core = @import("nilo_core");
const s3_config = @import("s3_config");

const bucket_mod = @import("bucket.zig");
const store_mod = @import("store.zig");

const Store = store_mod.Store;
const testing = std.testing;

/// Path style, because a bucket on `127.0.0.1` cannot be a DNS label and
/// because MinIO and SeaweedFS both want it.
///
/// The name comes from a build option rather than an argument, and it has to:
/// a bucket is a *type*, so which one these tests use is settled while
/// compiling. That is the design being tested rather than a limitation of it.
const Live = bucket_mod.Bucket(s3_config.bucket, .{ .style = .path, .max_bytes = 4 << 20 });

const Settings = struct {
    endpoint: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8,

    /// Null when there is no endpoint to talk to, which is what makes every
    /// test here skip rather than fail on the machine of somebody who cloned
    /// this to read it.
    ///
    /// **Compiled in rather than read from the environment**, which is the
    /// choice `sql/live.zig` already made and for its reason: a test binary
    /// that behaves differently depending on who ran it is the opposite of
    /// what a test is for. `build.zig` reads the variables, where reading them
    /// is a build input.
    fn read() ?Settings {
        return .{
            .endpoint = s3_config.endpoint orelse return null,
            .access_key = s3_config.access_key orelse return null,
            .secret_key = s3_config.secret_key orelse return null,
            .region = s3_config.region,
        };
    }
};

/// Everything here drives a real socket on `std.Io.Threaded`, the way
/// `fetch/live.zig` does — a Service borrows the loop and this is std's own.
fn withStore(comptime body: fn (*Store) anyerror!void) !void {
    const settings = Settings.read() orelse return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var store = try Store.open(testing.allocator, .{
        .endpoint = settings.endpoint,
        .region = settings.region,
        .credentials = .{ .static = .{
            .access_key_id = settings.access_key,
            .secret_access_key = settings.secret_key,
        } },
    });
    defer store.deinit();
    try store.nilo_start(io, .off);

    try body(&store);
}

test "an object put is an object got, byte for byte" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const body = "cinta laut dan langit, and a few bytes more";
            try live.put(&scope, "live/one.txt", .{
                .bytes = body,
                .content_type = "text/plain",
            });

            const got = try live.get(&scope, "live/one.txt");
            try testing.expectEqualStrings(body, got.bytes.view());
            try testing.expectEqualStrings("text/plain", got.content_type.view());
            try testing.expectEqual(@as(u64, body.len), got.len);
            // A real server quotes its ETag, which is what makes a caller
            // handing it back as `if-none-match` work at all.
            try testing.expect(got.etag.len() > 2);

            try live.delete(&scope, "live/one.txt");
            try testing.expectError(error.NotFound, live.get(&scope, "live/one.txt"));
        }
    }.run);
}

test "a key that needs encoding survives a round trip through a real server" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // The characters that break a client which encodes twice, or
            // encodes a space as `+`.
            const key = "live/wati sari$1+2/café & co.txt";
            try live.put(&scope, key, .{ .bytes = "ada", .content_type = "text/plain" });
            defer live.delete(&scope, key) catch {};

            const got = try live.get(&scope, key);
            try testing.expectEqualStrings("ada", got.bytes.view());
        }
    }.run);
}

test "a range asks for a slice and gets exactly that slice" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try live.put(&scope, "live/range.txt", .{
                .bytes = "0123456789abcdef",
                .content_type = "text/plain",
            });
            defer live.delete(&scope, "live/range.txt") catch {};

            const part = try live.getRange(&scope, "live/range.txt", .{ .from = 4, .to = 9 });
            try testing.expectEqualStrings("456789", part.bytes.view());
        }
    }.run);
}

test "an object over the ceiling costs a round trip rather than a download" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // Put five megabytes into a bucket whose type holds four.
            const big = try testing.allocator.alloc(u8, 5 << 20);
            defer testing.allocator.free(big);
            @memset(big, 'x');

            try live.put(&scope, "live/big.bin", .{
                .bytes = big,
                .content_type = "application/octet-stream",
            });
            defer live.delete(&scope, "live/big.bin") catch {};

            try testing.expectError(error.TooLarge, live.get(&scope, "live/big.bin"));

            // And the way through it, which is the whole reason `getRange`
            // exists: without it a large object has no way in at all.
            const head = try live.getRange(&scope, "live/big.bin", .{ .from = 0, .to = 1023 });
            try testing.expectEqual(@as(u64, 1024), head.len);
        }
    }.run);
}

test "a streamed put is a get, and a streamed get is the same bytes" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const body = "streamed in, streamed out, and never held whole";
            var source = std.Io.Reader.fixed(body);
            try live.putStream(&scope, "live/streamed.txt", .{
                .reader = &source,
                .len = @as(u64, body.len),
                .content_type = "text/plain",
            });
            defer live.delete(&scope, "live/streamed.txt") catch {};

            var transfer: [1 << 10]u8 = undefined;
            var reading: Live.Reading = .idle;
            defer reading.close();

            try live.stream(&scope, "live/streamed.txt", &reading, &transfer);
            try testing.expectEqual(@as(u64, body.len), reading.len);

            var out: [128]u8 = undefined;
            var w = std.Io.Writer.fixed(&out);
            _ = try reading.pipe(&w);
            try testing.expectEqualStrings(body, w.buffered());
        }
    }.run);
}

test "a head says what an object is without moving it" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try live.put(&scope, "live/meta.json", .{
                .bytes = "{\"ada\":true}",
                .content_type = "application/json",
            });
            defer live.delete(&scope, "live/meta.json") catch {};

            const meta = try live.head(&scope, "live/meta.json");
            try testing.expectEqual(@as(u64, 12), meta.len);
            try testing.expectEqualStrings("application/json", meta.content_type.view());

            try testing.expectError(error.NotFound, live.head(&scope, "live/nothing-here"));
        }
    }.run);
}

test "an ETag from a real server is one a conditional get understands" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try live.put(&scope, "live/cond.txt", .{
                .bytes = "unchanged",
                .content_type = "text/plain",
            });
            defer live.delete(&scope, "live/cond.txt") catch {};

            const first = try live.get(&scope, "live/cond.txt");
            const tag = try first.etag.keep(testing.allocator);
            defer testing.allocator.free(tag);

            switch (try live.getIf(&scope, "live/cond.txt", tag)) {
                .unmodified => {},
                .object => return error.ExpectedUnmodified,
            }

            // And an ETag that is not the object's is a full answer, which is
            // the case a client that always sends 304 would get wrong.
            switch (try live.getIf(&scope, "live/cond.txt", "\"not-the-etag\"")) {
                .unmodified => return error.ExpectedTheObject,
                .object => |o| try testing.expectEqualStrings("unchanged", o.bytes.view()),
            }
        }
    }.run);
}

test "a presigned URL works in something that did not sign it" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try live.put(&scope, "live/presigned.txt", .{
                .bytes = "anybody with the link",
                .content_type = "text/plain",
            });
            defer live.delete(&scope, "live/presigned.txt") catch {};

            const link = try live.presign(&scope, "live/presigned.txt", 900);

            // Fetched with a plain client carrying no credentials at all,
            // which is the whole claim a presigned URL makes.
            var plain: std.http.Client = .{
                .allocator = testing.allocator,
                .io = store.client.inner.io,
            };
            defer plain.deinit();

            var body: std.Io.Writer.Allocating = .init(testing.allocator);
            defer body.deinit();

            const result = try plain.fetch(.{
                .location = .{ .url = link.url.view() },
                .response_writer = &body.writer,
            });

            try testing.expectEqual(std.http.Status.ok, result.status);
            try testing.expectEqualStrings("anybody with the link", body.written());
        }
    }.run);
}

test "a bucket that is not there is a NotFound rather than a crash" {
    try withStore(struct {
        fn run(store: *Store) !void {
            const Missing = bucket_mod.Bucket("nilo-no-such-bucket", .{ .style = .path });
            var missing = try Missing.open(store);
            defer missing.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            try testing.expectError(error.NotFound, missing.get(&scope, "anything"));
        }
    }.run);
}
