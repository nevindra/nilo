//! Answering with a file nobody is holding in memory (ADR 0037).
//!
//! One response, assembled from a descriptor and a length: the head goes
//! into the connection's write buffer, and the bytes go from the file to the
//! socket without passing through this process — `sendFile` is a slot in the
//! `std.Io.Writer` vtable, so what happens underneath is an io_uring splice
//! chain on Linux, `sendfile` on kqueue and IOCP, and a buffer-lending loop
//! everywhere else. Nothing here names the Engine.
//!
//! Two callers share it, and they are the two halves of the same hole: the
//! static tree, for a file too big to have been read at startup, and a
//! handler returning a `FileBody`. Sharing it is not tidiness — a second
//! copy of the `If-Range` handling below is exactly how the corrupt-download
//! bug ADR 0021 exists to prevent gets back in.
//!
//! **The caller opens the file; this closes it.** Every way out of `send`
//! goes through one `defer`, and there are more of them than there look to
//! be: a 304, a 416, a HEAD, a whole file, a part of one, a `stat` that
//! failed, a seek that failed, and a client that vanished mid-transfer. A
//! caller made responsible for the descriptor would have to get all eight
//! right, and would be holding an fd across a `try` it did not write. On the
//! caller's side the whole story is one line: open it, hand it over.

const std = @import("std");

const bulkhead = @import("bulkhead.zig");
const http1 = @import("http1.zig");
const range_mod = @import("range.zig");
const static_mod = @import("static.zig");
const watchdog = @import("watchdog.zig");
const Ctx = @import("ctx.zig").Ctx;

/// One open file, and everything the head has to say about it.
///
/// The text fields are borrowed for as long as the response takes to write,
/// not copied: they belong to a loaded file, to a Service, or to the
/// caller's own stack frame, all three of which outlive this call. Nothing
/// here reaches for the request arena (ADR 0018).
pub const Contents = struct {
    /// Open. Closed by `send`, on every path out of it.
    file: bulkhead.File,

    /// How many bytes to promise in `Content-Length`, and what a `Range` is
    /// measured against. Null asks the file.
    ///
    /// Both callers exist. A handler answering with a file has nothing to
    /// say here and wants the `stat` done for it. The static tree does have
    /// something to say — it recorded the size when it walked the directory,
    /// and its ETag is made of that number, so re-statting could hand a
    /// client a length and a tag that describe two different files.
    size: ?u64 = null,

    content_type: []const u8,

    /// A strong ETag, quotes included. Empty leaves the header off — and
    /// with it `If-None-Match` and `If-Range`, which would have nothing to
    /// compare against.
    etag: []const u8 = "",

    /// Sent as `Cache-Control`. Empty leaves the header off.
    cache_control: []const u8 = "",
};

/// Write the whole response: the conditional headers, the range, and the
/// bytes.
///
/// The order is the one a static file already answered in, because it is the
/// order the RFC's precedence rules want and because the two paths have to
/// stay indistinguishable to a client: an `If-None-Match` that matches wins
/// over a `Range`, and an `If-Range` that does not match turns a 206 back
/// into a 200 rather than into a corrupt download.
pub fn send(c: *Ctx, contents: Contents) !void {
    std.debug.assert(!c._sent); // one request, one response

    // The descriptor is this function's from here, and this is the only line
    // that gives it back — see the module comment.
    defer contents.file.close();

    const total = contents.size orelse try contents.file.size();

    if (contents.etag.len > 0) try c.setStaticHeader("ETag", contents.etag);
    if (contents.cache_control.len > 0) try c.setStaticHeader("Cache-Control", contents.cache_control);
    // Said on every answer, the 304 and the 416 included: it is how a client
    // learns it may ask for part of this at all.
    try c.setStaticHeader("Accept-Ranges", "bytes");

    // A repeat visitor costs a comparison and a head — no body, and no bytes
    // read from the disk at all.
    if (contents.etag.len > 0) {
        if (c.header("If-None-Match")) |sent| {
            if (static_mod.etagMatches(sent.view(), contents.etag)) {
                return c.send(304, contents.content_type, "");
            }
        }
    }

    // `If-Range` means "only give me the part if this is still the file I
    // started with". A client resuming a download sends the tag it was given;
    // anything else, and the safe answer is all of it. The comparison is the
    // strong one RFC 9110 §13.1.5 asks for, which is a different function from
    // the `If-None-Match` above and not the same rule spelled twice
    // (ADR 0094) — a `W/` tag and a bare `*` both mean "close enough", and
    // close enough is not what a client stapling these bytes onto a prefix it
    // already holds is entitled to. A file with no tag matches nothing.
    const still_the_same = if (c.header("If-Range")) |sent|
        static_mod.etagMatchesStrong(sent.view(), contents.etag)
    else
        true;

    // Lives until this function returns, which is after the head has been
    // written, so the header below borrows it rather than copying it into the
    // request arena.
    var buf: [range_mod.max_content_range]u8 = undefined;
    switch (range_mod.parse(headerValue(c, "Range"), total, still_the_same)) {
        .whole => {},
        .part => |part| {
            try c.setStaticHeader("Content-Range", range_mod.contentRange(&buf, part, total));
            return writeBody(c, contents, 206, part.start, part.len());
        },
        .unsatisfiable => {
            // The one answer whose whole content is "you have the wrong idea
            // about how big this is", which the header carries and the body
            // does not need to repeat.
            try c.setStaticHeader("Content-Range", range_mod.unsatisfiableRange(&buf, total));
            return c.send(416, contents.content_type, "");
        },
    }

    return writeBody(c, contents, 200, 0, total);
}

/// The head, and then `len` bytes of the file starting at `from`.
fn writeBody(c: *Ctx, contents: Contents, status: u16, from: u64, len: u64) !void {
    // No buffer of its own, and that is deliberate rather than lazy. On the
    // zero-copy path the bytes never enter this process, so a buffer here
    // would be pages nothing writes to; where they do — a platform with no
    // `sendfile`, or a test with no socket — the Engine lends the
    // connection's write buffer, which is already allocated and already the
    // right size. The alternative is a per-request allocation (ADR 0018) or
    // a page of a fiber's stack, for bytes that mostly do not exist.
    var no_buffer: [0]u8 = undefined;
    var reader = contents.file.reader(&no_buffer);

    // Where a 206 starts, worked out before a byte of the head is written so
    // that a file which cannot be positioned is a clean 500 rather than half
    // an answer. On a regular file this is arithmetic rather than a syscall:
    // the reader reads positionally, so its position is a number it hands to
    // `pread` rather than state in the kernel.
    try reader.seekTo(from);

    c._sent = true;
    c._status = status;

    // Putting the answer on the wire is nilo waiting on the client, not the
    // handler running — `Ctx.send`'s reason, and a two-gigabyte file taken
    // slowly is the case it was written for. Without this, a client on a
    // hotel connection would be reported as a handler holding its thread
    // (ADR 0034).
    const w = watchdog.waiting(c._watch);
    defer watchdog.waited(c._watch, w);

    const keep_alive = c.keepAlive();

    // A HEAD gets the head a GET would have got, `Content-Length` and all,
    // and none of the body. Nothing is read from the file, so a HEAD of a
    // four-gigabyte file costs an open, a stat and a close.
    if (c.method == .HEAD) return http1.writeResponseHeadOnly(
        c._out,
        status,
        http1.statusPhrase(status),
        contents.content_type,
        len,
        keep_alive,
        c.extraHeaders(),
    );

    // Left in the write buffer on purpose: `sendFileAll` sends what is
    // already buffered ahead of the file's first bytes, so the head and the
    // start of the body leave together.
    try http1.writeFileHead(
        c._out,
        status,
        http1.statusPhrase(status),
        contents.content_type,
        len,
        keep_alive,
        c.extraHeaders(),
    );

    // A loop rather than one call, because a `std.Io.Limit` is a `usize` and
    // the length of a file is not: on a 32-bit build `limited64` clamps, and
    // without this a four-gigabyte download would look like a truncated file
    // and close the connection for it. On a 64-bit build it goes round once.
    // `sendFileAll` is short only at the end of the file, so nothing left to
    // send and nothing sent means there is no more file.
    var sent: u64 = 0;
    while (sent < len) {
        const n = try c._out.sendFileAll(&reader, .limited64(len - sent));
        if (n == 0) break;
        sent += n;
    }
    try c._out.flush();

    // Fewer bytes than the head promised. The length came from a `stat` that
    // is now out of date — the file was truncated or replaced underneath the
    // transfer — and a client told the connection is good will read the next
    // response as the rest of this body. So the framing is not trusted and
    // the connection goes, which is the one recovery left once the head has
    // already gone out (ADR 0037).
    if (sent < len) {
        c._force_close = true;
        std.log.warn(
            "{s} {s} promised {d} bytes from a file and sent {d}; the file changed " ++
                "underneath the response, so the connection is being closed rather than " ++
                "framing a half body as a whole one",
            .{ @tagName(c.method), c._path, len, sent },
        );
    }
}

/// A request header as plain bytes. The `Str` a handler gets is the right
/// shape for a handler and the wrong one for a parser that takes
/// `?[]const u8`.
fn headerValue(c: *const Ctx, name: []const u8) ?[]const u8 {
    const found = c.header(name) orelse return null;
    return found.view();
}

// ---- tests ----
//
// Everything below drives a real file on disk through a real App, because
// there is nothing in here worth testing that is not the agreement between
// four parts: the head, the range arithmetic, the position the reader is
// left at, and the bytes that come out. A test client has no socket, so the
// send falls back to std's read-and-drain path — the same bytes by a
// different route, which is exactly the fallback a platform without
// `sendfile` takes.

const testing = std.testing;

const App = @import("app.zig").App;
const nilo_testing = @import("testing.zig");

/// A directory with one file in it, written for one test and removed
/// afterwards. The `Dir` is what a static Set or a Service would hold open.
const OneFile = struct {
    tmp: std.testing.TmpDir,
    dir: bulkhead.Dir,

    const name = "big.bin";

    fn init(bytes: []const u8) !OneFile {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });

        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        return .{ .tmp = tmp, .dir = try bulkhead.Dir.open(path) };
    }

    fn deinit(self: *OneFile) void {
        self.dir.close();
        self.tmp.cleanup();
    }
};

/// The one under test, reached from a handler. A test holds it in a global
/// rather than in a Service because what is being tested is the response,
/// not the wiring that finds a directory.
var open_files: ?*OneFile = null;
var answer_etag: []const u8 = "\"abc\"";

fn fileHandler(c: *Ctx) anyerror!void {
    const files = open_files.?;
    const file = try files.dir.openFile(OneFile.name);
    return c.sendFile(.{
        .file = file,
        .content_type = "application/octet-stream",
        .etag = answer_etag,
        .cache_control = "public, max-age=60",
    });
}

/// The same, with the size given rather than asked for — what the static
/// tree does with the number it recorded at load.
fn knownSizeHandler(c: *Ctx) anyerror!void {
    const files = open_files.?;
    const file = try files.dir.openFile(OneFile.name);
    return c.sendFile(.{
        .file = file,
        .size = 10,
        .content_type = "text/plain",
        .etag = answer_etag,
    });
}

fn missingHandler(c: *Ctx) anyerror!void {
    const files = open_files.?;
    const file = files.dir.openFile("not-there.bin") catch |err| {
        try testing.expectEqual(error.FileNotFound, err);
        return c.sendText(404, "no such file");
    };
    return c.sendFile(.{ .file = file, .content_type = "text/plain" });
}

const alphabet = "abcdefghij";

fn appWithFile(app: *App) !void {
    try app.get("/file", fileHandler);
    try app.get("/known", knownSizeHandler);
    try app.get("/missing", missingHandler);
}

test "the whole file goes out, with the headers every file answer carries" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/file");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("10", answer.header("Content-Length").?);
    try testing.expectEqualStrings("bytes", answer.header("Accept-Ranges").?);
    try testing.expectEqualStrings("\"abc\"", answer.header("ETag").?);
    try testing.expectEqualStrings("public, max-age=60", answer.header("Cache-Control").?);
    try testing.expectEqualStrings("application/octet-stream", answer.header("Content-Type").?);
    try testing.expectEqualStrings(alphabet, answer.body);
    try testing.expect(answer.keep_alive);
}

test "a size the caller already knows is used rather than asked for again" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/known");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("10", answer.header("Content-Length").?);
    try testing.expectEqualStrings(alphabet, answer.body);
}

test "a range is answered from the middle of the file without reading the rest" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.send(&app, "GET /file HTTP/1.1\r\nRange: bytes=3-5\r\n\r\n");
    try testing.expectEqual(@as(u16, 206), answer.status);
    try testing.expectEqualStrings("bytes 3-5/10", answer.header("Content-Range").?);
    try testing.expectEqualStrings("3", answer.header("Content-Length").?);
    try testing.expectEqualStrings("def", answer.body);
}

test "a suffix range counts back from the end" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.send(&app, "GET /file HTTP/1.1\r\nRange: bytes=-4\r\n\r\n");
    try testing.expectEqual(@as(u16, 206), answer.status);
    try testing.expectEqualStrings("bytes 6-9/10", answer.header("Content-Range").?);
    try testing.expectEqualStrings("ghij", answer.body);
}

test "a range past the end says how big the file actually is" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.send(&app, "GET /file HTTP/1.1\r\nRange: bytes=99-\r\n\r\n");
    try testing.expectEqual(@as(u16, 416), answer.status);
    try testing.expectEqualStrings("bytes */10", answer.header("Content-Range").?);
    // The 416 carries the headers every other answer carries, so a client
    // that has just been told the size can ask again properly.
    try testing.expectEqualStrings("bytes", answer.header("Accept-Ranges").?);
    try testing.expectEqualStrings("\"abc\"", answer.header("ETag").?);
    try testing.expectEqualStrings("", answer.body);
}

test "a matching If-None-Match costs a head and nothing else" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.send(&app, "GET /file HTTP/1.1\r\nIf-None-Match: \"abc\"\r\n\r\n");
    try testing.expectEqual(@as(u16, 304), answer.status);
    try testing.expectEqualStrings("", answer.body);
    // A 304 says nothing about a length (ADR: `http1.bodyless`), but it does
    // still describe the representation the client is holding.
    try testing.expect(answer.header("Content-Length") == null);
    try testing.expectEqualStrings("\"abc\"", answer.header("ETag").?);
    try testing.expectEqualStrings("bytes", answer.header("Accept-Ranges").?);
}

test "If-Range matching keeps the range, and not matching sends the whole file" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const resumed = try client.send(
        &app,
        "GET /file HTTP/1.1\r\nRange: bytes=6-\r\nIf-Range: \"abc\"\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 206), resumed.status);
    try testing.expectEqualStrings("ghij", resumed.body);

    // The file the client started with is gone. Byte 6 of the new one is not
    // byte 6 of the old one, so the answer is all of it (ADR 0021).
    const changed = try client.send(
        &app,
        "GET /file HTTP/1.1\r\nRange: bytes=6-\r\nIf-Range: \"stale\"\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 200), changed.status);
    try testing.expectEqualStrings(alphabet, changed.body);
    try testing.expect(changed.header("Content-Range") == null);
}

test "a HEAD gets the length a GET would have sent, and no bytes" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const whole = try client.send(&app, "HEAD /file HTTP/1.1\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), whole.status);
    try testing.expectEqualStrings("10", whole.header("Content-Length").?);
    try testing.expectEqualStrings("", whole.body);

    // And a HEAD of a range still describes the range.
    const part = try client.send(&app, "HEAD /file HTTP/1.1\r\nRange: bytes=0-2\r\n\r\n");
    try testing.expectEqual(@as(u16, 206), part.status);
    try testing.expectEqualStrings("3", part.header("Content-Length").?);
    try testing.expectEqualStrings("bytes 0-2/10", part.header("Content-Range").?);
    try testing.expectEqualStrings("", part.body);
}

test "an empty file is a 200 with nothing in it" {
    var files = try OneFile.init("");
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/file");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("0", answer.header("Content-Length").?);
    try testing.expectEqualStrings("", answer.body);
    // A file with no bytes has no part of it to send, so a range against it
    // is ignored rather than refused (range.zig).
    const ranged = try client.send(&app, "GET /file HTTP/1.1\r\nRange: bytes=0-9\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), ranged.status);
}

test "a file the list promised and the disk does not have opens with FileNotFound" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/missing");
    try testing.expectEqual(@as(u16, 404), answer.status);
}

test "a file with no ETag answers without one, and ignores a conditional" {
    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;
    answer_etag = "";
    defer answer_etag = "\"abc\"";

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.send(&app, "GET /file HTTP/1.1\r\nIf-None-Match: *\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expect(answer.header("ETag") == null);
    try testing.expectEqualStrings(alphabet, answer.body);

    // And an `If-Range` has nothing to be compared with, so the range is not
    // honoured — the safe direction, the same one ADR 0021 took for a date.
    const ranged = try client.send(
        &app,
        "GET /file HTTP/1.1\r\nRange: bytes=0-2\r\nIf-Range: *\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 200), ranged.status);
    try testing.expectEqualStrings(alphabet, ranged.body);
}

/// How many descriptors this process is holding, counted the only way there
/// is to count them. Linux only, which is where this test runs.
fn openDescriptors() !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(std.testing.io)) |_| n += 1;
    return n;
}

test "the descriptor is given back however the answer ends" {
    // The whole ownership decision in one assertion: the caller opens, this
    // closes, and every way out of `send` is one of these five.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var files = try OneFile.init(alphabet);
    defer files.deinit();
    open_files = &files;
    defer open_files = null;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appWithFile(&app);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const requests = [_][]const u8{
        "GET /file HTTP/1.1\r\n\r\n", // the whole file
        "GET /file HTTP/1.1\r\nRange: bytes=2-4\r\n\r\n", // part of it
        "GET /file HTTP/1.1\r\nRange: bytes=500-\r\n\r\n", // a 416
        "GET /file HTTP/1.1\r\nIf-None-Match: \"abc\"\r\n\r\n", // a 304
        "HEAD /file HTTP/1.1\r\n\r\n", // no body at all
    };

    // One round first, so that anything opened once and kept — the temporary
    // directory, whatever the allocator did — is already open when the count
    // is taken.
    for (requests) |request| _ = try client.send(&app, request);

    const before = try openDescriptors();
    for (0..20) |i| {
        const answer = try client.send(&app, requests[i % requests.len]);
        try testing.expect(answer.status == 200 or answer.status == 206 or
            answer.status == 304 or answer.status == 416);
    }
    try testing.expectEqual(before, try openDescriptors());
}
