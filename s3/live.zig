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
//! docker run -d --name seaweedfs -p 9100:8333 \
//!   -e AWS_ACCESS_KEY_ID=niloadmin -e AWS_SECRET_ACCESS_KEY=nilosecret123 \
//!   chrislusf/seaweedfs:4.47 server -dir=/data -s3 -s3.port=8333
//! python3 bench/s3_setup.py
//!
//! S3_ENDPOINT=http://127.0.0.1:9100 S3_ACCESS_KEY=niloadmin \
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
const multipart_mod = @import("multipart.zig");
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

/// Where every key here lives: a folder per optimize mode, because `zig build
/// test-s3` runs the Debug and the ReleaseSafe binary **at the same time**
/// against one server, and a key the two shared was the other binary's to
/// delete between this one's write and its read. The presigned POST found it
/// first and took a key of its own; the list, which reads four keys back and
/// counts them, found it the first time CI ran against a real MinIO.
const home = "live/" ++ @tagName(@import("builtin").mode) ++ "/";

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
            try live.put(&scope, home ++ "one.txt", .{
                .bytes = body,
                .content_type = "text/plain",
            });

            const got = try live.get(&scope, home ++ "one.txt");
            try testing.expectEqualStrings(body, got.bytes.view());
            try testing.expectEqualStrings("text/plain", got.content_type.view());
            try testing.expectEqual(@as(u64, body.len), got.len);
            // A real server quotes its ETag, which is what makes a caller
            // handing it back as `if-none-match` work at all.
            try testing.expect(got.etag.len() > 2);

            try live.delete(&scope, home ++ "one.txt");
            try testing.expectError(error.NotFound, live.get(&scope, home ++ "one.txt"));
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
            const key = home ++ "wati sari$1+2/café & co.txt";
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

            try live.put(&scope, home ++ "range.txt", .{
                .bytes = "0123456789abcdef",
                .content_type = "text/plain",
            });
            defer live.delete(&scope, home ++ "range.txt") catch {};

            const part = try live.getRange(&scope, home ++ "range.txt", .{ .from = 4, .to = 9 });
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

            try live.put(&scope, home ++ "big.bin", .{
                .bytes = big,
                .content_type = "application/octet-stream",
            });
            defer live.delete(&scope, home ++ "big.bin") catch {};

            try testing.expectError(error.TooLarge, live.get(&scope, home ++ "big.bin"));

            // And the way through it, which is the whole reason `getRange`
            // exists: without it a large object has no way in at all.
            const head = try live.getRange(&scope, home ++ "big.bin", .{ .from = 0, .to = 1023 });
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
            try live.putStream(&scope, home ++ "streamed.txt", .{
                .reader = &source,
                .len = @as(u64, body.len),
                .content_type = "text/plain",
            });
            defer live.delete(&scope, home ++ "streamed.txt") catch {};

            var reading: Live.Reading = .idle;
            defer reading.close();

            try live.stream(&scope, home ++ "streamed.txt", &reading);
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

            try live.put(&scope, home ++ "meta.json", .{
                .bytes = "{\"ada\":true}",
                .content_type = "application/json",
            });
            defer live.delete(&scope, home ++ "meta.json") catch {};

            const meta = try live.head(&scope, home ++ "meta.json");
            try testing.expectEqual(@as(u64, 12), meta.len);
            try testing.expectEqualStrings("application/json", meta.content_type.view());

            try testing.expectError(error.NotFound, live.head(&scope, home ++ "nothing-here"));
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

            try live.put(&scope, home ++ "cond.txt", .{
                .bytes = "unchanged",
                .content_type = "text/plain",
            });
            defer live.delete(&scope, home ++ "cond.txt") catch {};

            const first = try live.get(&scope, home ++ "cond.txt");
            const tag = try first.etag.keep(testing.allocator);
            defer testing.allocator.free(tag);

            switch (try live.getIf(&scope, home ++ "cond.txt", tag)) {
                .unmodified => {},
                .object => return error.ExpectedUnmodified,
            }

            // And an ETag that is not the object's is a full answer, which is
            // the case a client that always sends 304 would get wrong.
            switch (try live.getIf(&scope, home ++ "cond.txt", "\"not-the-etag\"")) {
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

            try live.put(&scope, home ++ "presigned.txt", .{
                .bytes = "anybody with the link",
                .content_type = "text/plain",
            });
            defer live.delete(&scope, home ++ "presigned.txt") catch {};

            const link = try live.presign(&scope, home ++ "presigned.txt", 900);

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

test "a presigned POST is a form a real server accepts" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const key = home ++ "posted.txt";
            defer live.delete(&scope, key) catch {};

            const posted = try live.presignPost(&scope, key, .{
                .seconds = 900,
                .content_type = "text/plain",
                .max_bytes = 1 << 20,
            });

            // Every field, then the file, in that order. `canned.zig` can say
            // the policy is the document that was signed; only a real server
            // can say the document is one S3 agrees to, and this is the whole
            // reason the test is here rather than there.
            const boundary = "nilotestboundary8c1f";
            var body: std.Io.Writer.Allocating = .init(testing.allocator);
            defer body.deinit();

            for (posted.fields) |field| {
                try body.writer.print(
                    "--" ++ boundary ++ "\r\n" ++
                        "Content-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n",
                    .{ field.name, field.value },
                );
            }
            try body.writer.print(
                "--" ++ boundary ++ "\r\n" ++
                    "Content-Disposition: form-data; name=\"file\"; filename=\"posted.txt\"\r\n" ++
                    "Content-Type: text/plain\r\n\r\n{s}\r\n" ++
                    "--" ++ boundary ++ "--\r\n",
                .{"a browser put this here"},
            );

            // The Store's own Fitting, which signs nothing by itself — the
            // whole claim a POST policy makes — rather than `std.http.Client`
            // directly: Garage answers the form with a 204 and no
            // `content-length`, which std's own reader waits on until the
            // server reaps the socket, and `nilo_fetch` is where that is
            // closed (ADR 176). The test found it the moment the form was
            // accepted.
            const result = try store.client.send(&scope, .POST, posted.url, body.written(), .{
                .headers = &.{.{
                    .name = "Content-Type",
                    .value = "multipart/form-data; boundary=" ++ boundary,
                }},
            });

            // S3 answers 204 to a POST with no `success_action_status`.
            try testing.expect(result.status == .no_content or result.status == .ok);

            // And the object is there, with the bytes the browser sent.
            const object = try live.get(&scope, key);
            try testing.expectEqualStrings("a browser put this here", object.bytes.view());
            try testing.expectEqualStrings("text/plain", object.content_type.view());
        }
    }.run);
}

test "a list from a real server pages under a prefix, and the cursor reaches the rest" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try Live.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // Three under one prefix and one beside it, so the prefix and
            // the page size are both seen to do something.
            const keys = [_][]const u8{ home ++ "list/a.txt", home ++ "list/b c.txt", home ++ "list/d.txt", home ++ "other.txt" };
            for (keys) |key| try live.put(&scope, key, .{ .bytes = "x", .content_type = "text/plain" });
            defer for (keys) |key| live.delete(&scope, key) catch {};

            const first = try live.list(&scope, .{ .prefix = home ++ "list/", .max_keys = 2 });
            try testing.expectEqual(@as(usize, 2), first.objects.len);
            try testing.expectEqualStrings(home ++ "list/a.txt", first.objects[0].key.view());
            try testing.expectEqualStrings(home ++ "list/b c.txt", first.objects[1].key.view());
            try testing.expectEqual(@as(u64, 1), first.objects[0].size);
            // A real server quotes its ETag, and a value from here is one
            // `getIf` understands as it is.
            try testing.expect(first.objects[0].etag.len() > 2);
            try testing.expect(first.next != null);

            const second = try live.list(&scope, .{
                .prefix = home ++ "list/",
                .max_keys = 2,
                .cursor = first.next.?.view(),
            });
            try testing.expectEqual(@as(usize, 1), second.objects.len);
            try testing.expectEqualStrings(home ++ "list/d.txt", second.objects[0].key.view());
            try testing.expect(second.next == null);

            const conditional = try live.getIf(&scope, home ++ "list/a.txt", first.objects[0].etag.view());
            try testing.expect(conditional == .unmodified);
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

/// The multipart tests' own type: reading a two-part object back whole needs
/// a ceiling above `Live`'s 4 MiB, which is itself under test above.
const LiveBig = bucket_mod.Bucket(s3_config.bucket, .{ .style = .path, .max_bytes = 16 << 20 });

test "a multipart put of two parts is one object, byte for byte" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try LiveBig.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            // One full part and a tail: the smallest honest multipart, and
            // the pattern makes a part served out of order readable in a diff.
            const len = multipart_mod.part_min + 123_457;
            const body = try testing.allocator.alloc(u8, len);
            defer testing.allocator.free(body);
            for (body, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 8));

            var reader = std.Io.Reader.fixed(body);
            const key = home ++ "multipart.bin";
            try live.putMultipart(&scope, key, .{
                .reader = &reader,
                .content_type = "application/octet-stream",
                .part_bytes = multipart_mod.part_min,
            });
            defer live.delete(&scope, key) catch {};

            const got = try live.get(&scope, key);
            try testing.expectEqual(@as(u64, len), got.len);
            try testing.expect(std.mem.eql(u8, body, got.bytes.view()));
        }
    }.run);
}

test "a multipart put smaller than one part is one part, and still one object" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try LiveBig.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            const body = "small enough for a single final part";
            var reader = std.Io.Reader.fixed(body);
            const key = home ++ "multipart-small.bin";
            try live.putMultipart(&scope, key, .{
                .reader = &reader,
                .content_type = "application/octet-stream",
            });
            defer live.delete(&scope, key) catch {};

            const got = try live.get(&scope, key);
            try testing.expectEqualStrings(body, got.bytes.view());
        }
    }.run);
}

test "a part size under S3's floor is refused before any byte moves" {
    try withStore(struct {
        fn run(store: *Store) !void {
            var live = try LiveBig.open(store);
            defer live.deinit();

            var scope: core.Run = .init(testing.allocator);
            defer scope.deinit();

            var reader = std.Io.Reader.fixed("whatever");
            try testing.expectError(error.Rejected, live.putMultipart(&scope, home ++ "never.bin", .{
                .reader = &reader,
                .content_type = "application/octet-stream",
                .part_bytes = 1024,
            }));
        }
    }.run);
}
