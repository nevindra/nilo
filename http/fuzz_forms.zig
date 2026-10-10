//! What a multipart body has to be true for, whatever a stranger sends it
//! ([ADR 030](../docs/adr/030-a-form-is-the-body-read-by-another-rule.md),
//! [ADR 034](../docs/adr/034-a-binding-hands-its-failures-to-the-handler.md)).
//!
//! `fuzz.zig` holds the request head to its properties and `fuzz_frames.zig`
//! holds an HTTP/2 connection to its own; this holds the third parser of bytes
//! a stranger chooses, `form.parse` over a multipart body, which cuts the body
//! into parts with indexes it computes by hand. A slip there is a panic a
//! request reaches in `ReleaseSafe` and undefined behaviour in `ReleaseFast`,
//! so the run is in `ReleaseSafe` (see the `fuzz` step in `build.zig`).
//!
//! The input is a content type, a NUL, then the body (no NUL: the whole input
//! is the body under a boundary of `niloBoundary`). The properties:
//!
//! - It does not panic and does not leak, for any body under any boundary
//!   `form.kindOf` accepts.
//! - The answer is a `Fields` or a refusal (`error.Failed`, the 400), never
//!   anything else but `error.OutOfMemory`.
//! - Every slice of a `Fields` lies inside the body, bar the default content
//!   type of a file part, and `multipart` is set.
//! - No more than `form.max_parts` text fields and as many files.
//!
//! A body built from known parts is also read back as exactly those parts, in
//! the tests at the bottom, so the property is not only "nothing broke".
//!
//! What a stranger feeds it is a body nearly valid and then damaged: a
//! boundary inside a file, a bare LF for a CRLF, a part never closed, a
//! `name` quoted and unquoted, `filename*`, a part count either side of
//! `max_parts`, a preamble, an epilogue, transport padding after a boundary.
//!
//! `zig build fuzz -- --forms` generates inputs for it; `zig build test`
//! replays the corpus at the bottom.

const std = @import("std");
const form = @import("form.zig");
const fail = @import("fail.zig");

const testing = std.testing;

/// The boundary of an input that names none of its own.
const default_content_type = "multipart/form-data; boundary=niloBoundary";

/// Run one input through the parser and check what came back. A failure
/// prints the input as a corpus line first, the way `fuzz.checkOne` does.
pub fn checkOne(gpa: std.mem.Allocator, bytes: []const u8) !void {
    check(gpa, bytes) catch |err| {
        dump(bytes);
        return err;
    };
}

fn check(gpa: std.mem.Allocator, bytes: []const u8) !void {
    const content_type: []const u8, const raw_body: []const u8 = if (std.mem.indexOfScalar(u8, bytes, 0)) |nul|
        .{ bytes[0..nul], bytes[nul + 1 ..] }
    else
        .{ default_content_type, bytes };

    // A heap copy of exactly the body's size, so a slice that wandered off
    // it is not hiding in the spare room of a buffer the generator owns.
    const body = try gpa.dupe(u8, raw_body);
    defer gpa.free(body);

    const kind = form.kindOf(content_type);
    const boundary = switch (kind) {
        .multipart => |b| b,
        else => return,
    };
    try testing.expect(boundary.len > 0);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    const fields = form.parse(arena_state.allocator(), kind, body) catch |err| switch (err) {
        error.Failed, error.OutOfMemory => return,
    };

    try testing.expect(fields.multipart);
    try testing.expect(fields.text.len <= form.max_parts);
    try testing.expect(fields.files.len <= form.max_parts);
    for (fields.text) |p| {
        try expectInside(body, p.name);
        try expectInside(body, p.value);
    }
    for (fields.files) |f| {
        try expectInside(body, f.name);
        try expectInside(body, f.filename);
        try expectInside(body, f.bytes);
        if (!std.mem.eql(u8, f.content_type, "application/octet-stream")) try expectInside(body, f.content_type);
    }
}

/// `part` is a window onto `body` and not onto anything else. An empty one
/// can sit anywhere, since no byte of it is read.
fn expectInside(body: []const u8, part: []const u8) !void {
    if (part.len == 0) return;
    const lo = @intFromPtr(body.ptr);
    const at = @intFromPtr(part.ptr);
    try testing.expect(at >= lo and at + part.len <= lo + body.len);
}

/// The input as a Zig string literal, ready to be pasted into the corpus.
pub fn dump(bytes: []const u8) void {
    std.debug.print("    \"", .{});
    for (bytes) |b| std.debug.print("\\x{x:0>2}", .{b});
    std.debug.print("\",  // {d} bytes\n", .{bytes.len});
}

// ---- generating something worth checking ----

const content_types = [_][]const u8{
    "multipart/form-data; boundary=niloBoundary",
    "multipart/form-data; boundary=\"niloBoundary\"",
    "multipart/form-data; charset=utf-8; boundary=niloBoundary",
    "Multipart/Form-Data;BOUNDARY=niloBoundary",
    "multipart/form-data; boundary=niloBoundary; x=y",
    "multipart/form-data; boundary=\"a b\"",
    "multipart/form-data; boundary=b",
    "multipart/form-data; boundary=\"----WebKitFormBoundaryAbC\"",
    "multipart/form-data; boundary=a-b",
    "multipart/form-data; boundary=\"\"",
    "multipart/form-data; boundary=\"open",
    "multipart/form-data",
};

/// The boundary each content type above names, or the empty string where it
/// names none the body can be built around. The generator builds a body
/// under one of these and sometimes pairs it with a different content type.
const boundaries = [_][]const u8{ "niloBoundary", "b", "----WebKitFormBoundaryAbC", "a b", "a-b", "x" };

const dispositions = [_][]const u8{
    "Content-Disposition: form-data; name=\"f\"",
    "Content-Disposition: form-data; name=f",
    "Content-Disposition: form-data; name=\"f\"; filename=\"x.png\"",
    "Content-Disposition: form-data; name=\"f\"; filename=x.png",
    "Content-Disposition: form-data; name=\"f\"; filename=\"\"",
    "Content-Disposition: form-data; name=\"f\"; filename*=UTF-8''x.png",
    "Content-Disposition: form-data; name=\"f\"; filename=\"x.png\"; filename*=UTF-8''x.png",
    "Content-Disposition: form-data; filename=\"x.png\"",
    "Content-Disposition: form-data",
    "Content-Disposition: form-data; name=\"f",
    "Content-Disposition: form-data; name=\"\"",
    "Content-Disposition: form-data ; name = \"f\" ;filename = \"x\"",
    "Content-Disposition: form-data; name=\"f\"; name=\"g\"",
    "Content-Disposition: form-data; name=\"f;filename=y\"",
    "Content-Disposition: form-data; name=\"f\";",
    "Content-Disposition: form-data; name=",
    "content-disposition:form-data;name=\"f\"",
    "CONTENT-DISPOSITION: form-data; NAME=\"f\"; FILENAME=\"x\"",
    "Content-Disposition",
    "Content-Disposition:",
    "Content-Type: text/plain",
    "",
};

const content_headers = [_][]const u8{
    "",
    "Content-Type: image/png",
    "Content-Type:",
    "content-type: text/plain; charset=utf-8",
    "X-Other: value",
};

const contents = [_][]const u8{
    "",
    "v",
    "hello world",
    "line one\r\nline two\r\n",
    "a\r\n\r\nb",
    "a\n\nb",
    "\r",
    "\n",
    "\r\n",
    "--",
    "--niloBoundary",
    "x\r\n--niloBoundary",
    "x\r\n--niloBoundary--",
    "x\n--niloBoundary\ny",
    "x--niloBoundary y",
    "--b",
    "\r\n--b\r\n",
    "\x00\xff\x00",
    "-",
};

/// The bytes that break framing here, which is where the damage goes.
const delicious = [_]u8{ '\r', '\n', '-', '"', ';', '=', '*', ' ', '\t', ':', 0xff, 'b' };

/// The buffer a generated input needs: a body of `max_parts + 2` compact
/// parts is a little over 13 KiB.
pub const buffer_len = 32 * 1024;

pub fn generate(random: std.Random, buf: []u8) []const u8 {
    return switch (random.weightedIndex(u16, &.{ 45, 25, 20, 10 })) {
        0 => build(random, buf, .{}),
        1 => damage(random, build(random, buf, .{}), buf),
        // A count of parts at the wall, one under it and one over it.
        2 => build(random, buf, .{ .many = true }),
        else => noise(random, buf),
    };
}

const Shape = struct { many: bool = false };

fn build(random: std.Random, buf: []u8, shape: Shape) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    buildInto(random, &w, shape) catch {};
    return w.buffered();
}

fn buildInto(random: std.Random, w: *std.Io.Writer, shape: Shape) !void {
    const which = random.uintLessThan(usize, boundaries.len);
    const boundary = boundaries[which];
    // Most inputs name their boundary the plain way; the rest pair the body
    // with any content type, which is a body under a boundary it does not
    // use, or no boundary at all.
    const content_type: []const u8 = switch (random.uintLessThan(u8, 8)) {
        0 => pick(random, &content_types),
        1 => "multipart/form-data; boundary=\"x\"",
        else => "",
    };
    if (content_type.len > 0) {
        try w.writeAll(content_type);
        try w.writeByte(0);
    } else {
        try w.print("multipart/form-data; boundary={s}", .{if (std.mem.indexOfScalar(u8, boundary, ' ') != null) "\"a b\"" else boundary});
        try w.writeByte(0);
    }

    const crlf: []const u8 = if (random.uintLessThan(u8, 4) == 0) "\n" else "\r\n";

    // A preamble, which is text before the first boundary a reader skips.
    switch (random.uintLessThan(u8, 6)) {
        0 => try w.print("preamble{s}", .{crlf}),
        1 => try w.print("{s}{s}", .{ crlf, crlf }),
        else => {},
    }

    const parts: usize = if (shape.many)
        switch (random.uintLessThan(u8, 5)) {
            0 => form.max_parts - 1,
            1 => form.max_parts,
            2 => form.max_parts + 1,
            3 => form.max_parts + 2,
            else => random.uintLessThan(usize, 2 * form.max_parts),
        }
    else
        random.uintLessThan(usize, 5);

    for (0..parts) |_| {
        // Mostly the same line ending throughout; now and then a part of
        // the other kind, as a hand-written fixture would.
        const line: []const u8 = if (random.uintLessThan(u8, 12) == 0) (if (crlf.len == 2) "\n" else "\r\n") else crlf;
        try w.print("--{s}", .{boundary});
        if (random.uintLessThan(u8, 12) == 0) try w.writeAll(pick(random, &.{ "  ", "\t", " \r" }));
        try w.writeAll(line);
        if (shape.many) {
            // Compact: a part per few dozen bytes, so the wall is reached.
            try w.print("Content-Disposition: form-data; name=\"f\"{s}{s}v{s}", .{ line, line, line });
            continue;
        }
        const d = pick(random, &dispositions);
        if (d.len > 0) try w.print("{s}{s}", .{ d, line });
        const h = pick(random, &content_headers);
        if (h.len > 0) try w.print("{s}{s}", .{ h, line });
        // The blank line, unless the point is that there isn't one.
        if (random.uintLessThan(u8, 16) != 0) try w.writeAll(line);
        try w.writeAll(pick(random, &contents));
        // The break in front of the next boundary, unless the point is that
        // there isn't one.
        if (random.uintLessThan(u8, 16) != 0) try w.writeAll(line);
    }

    switch (random.uintLessThan(u8, 8)) {
        0 => {},
        1 => try w.print("--{s}", .{boundary}),
        2 => try w.print("--{s}{s}", .{ boundary, crlf }),
        3 => try w.print("--{s}--{s}epilogue", .{ boundary, crlf }),
        4 => try w.print("--{s}-", .{boundary}),
        else => try w.print("--{s}--{s}", .{ boundary, crlf }),
    }
}

/// One change in one place, near the boundary the parser cares about.
fn damage(random: std.Random, made: []const u8, buf: []u8) []const u8 {
    if (made.len == 0) return made;
    const at = random.uintLessThan(usize, made.len);
    return switch (random.uintLessThan(u8, 4)) {
        0 => blk: {
            buf[at] = delicious[random.uintLessThan(usize, delicious.len)];
            break :blk buf[0..made.len];
        },
        1 => blk: {
            buf[at] ^= @as(u8, 1) << random.int(u3);
            break :blk buf[0..made.len];
        },
        // Cut it short, wherever it happens to be: mid-header, mid-boundary.
        2 => buf[0..at],
        else => blk: {
            if (made.len + 1 > buf.len) break :blk buf[0..made.len];
            std.mem.copyBackwards(u8, buf[at + 1 .. made.len + 1], buf[at..made.len]);
            buf[at] = delicious[random.uintLessThan(usize, delicious.len)];
            break :blk buf[0 .. made.len + 1];
        },
    };
}

fn noise(random: std.Random, buf: []u8) []const u8 {
    const len = random.uintLessThan(usize, @min(buf.len, 256));
    for (buf[0..len]) |*b| {
        b.* = if (random.boolean())
            delicious[random.uintLessThan(usize, delicious.len)]
        else
            random.int(u8);
    }
    return buf[0..len];
}

fn pick(random: std.Random, comptime list: []const []const u8) []const u8 {
    return list[random.uintLessThan(usize, list.len)];
}

// ---- the corpus ----

// Inputs that reach a corner, written as bytes. A line `dump` printed goes
// here, so that `zig build test` holds it after nobody runs the fuzzer again.
const corpus = [_][]const u8{
    // a form of one text part, then the shapes of its ending
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--niloBoundary--\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--niloBoundary--",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--niloBoundary",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\r\n",
    "--niloBoundary\r\n",
    "--niloBoundary",
    "--niloBound",
    "--",
    "",
    "\r\n",
    // bare LF throughout, and mixed
    "--niloBoundary\nContent-Disposition: form-data; name=\"f\"\n\nv\n--niloBoundary--\n",
    "--niloBoundary\nContent-Disposition: form-data; name=\"f\"\r\n\nv\r\n--niloBoundary--\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\n\r\nv\n--niloBoundary--",
    // a boundary inside a file, at the start of a line and not
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x\"\r\n\r\na--niloBoundary b\r\n--niloBoundary--\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"; filename=\"x\"\r\n\r\na\r\n--niloBoundary\r\nContent-Disposition: form-data; name=\"g\"\r\n\r\nv\r\n--niloBoundary--\r\n",
    // names: quoted, unquoted, empty, unterminated, filename*
    "--niloBoundary\r\nContent-Disposition: form-data; name=f\r\n\r\nv\r\n--niloBoundary--\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"\"\r\n\r\nv\r\n--niloBoundary--\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\r\n\r\nv\r\n--niloBoundary--\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"; filename*=UTF-8''x\r\n\r\nv\r\n--niloBoundary--\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"; filename=\"\"\r\n\r\n\r\n--niloBoundary--\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"; filename=\"\"\r\n\r\nv\r\n--niloBoundary--\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\r\n\r\nv\r\n--niloBoundary--\r\n",
    // a head that is all blank lines, and a blank line at the very end
    "--niloBoundary\r\n\r\n\r\n--niloBoundary--\r\n",
    "--niloBoundary\n\n\n--niloBoundary--",
    "--niloBoundary\r\n\r\n",
    "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\n\r\n--niloBoundary--",
    // a preamble, and an epilogue after the end
    "preamble\r\n--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--niloBoundary--\r\nepilogue",
    // transport padding after a boundary
    "--niloBoundary  \r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--niloBoundary--\r\n",
    // content types: quoted and unquoted boundaries, an empty one, an open one
    "multipart/form-data; boundary=\"b\"\x00--b\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n--b--\r\n",
    "multipart/form-data; boundary=\"\"\x00--\r\n\r\n",
    "multipart/form-data; boundary=\"open\x00--open\r\n",
    "multipart/form-data\x00--b\r\n",
};

test "the multipart parser holds its properties over every input we know of" {
    for (corpus) |input| try checkOne(testing.allocator, input);
}

test "a corpus form with two parts is read as those two parts, so the property is looking at fields" {
    const body = "--niloBoundary\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n" ++
        "--niloBoundary\r\nContent-Disposition: form-data; name=\"g\"; filename=\"x\"\r\n\r\nabc\r\n--niloBoundary--\r\n";
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const fields = try form.parse(arena.allocator(), form.kindOf(default_content_type), body);
    try testing.expectEqual(@as(usize, 1), fields.text.len);
    try testing.expectEqualStrings("v", fields.text[0].value);
    try testing.expectEqual(@as(usize, 1), fields.files.len);
    try testing.expectEqualStrings("abc", fields.files[0].bytes);
    try checkOne(testing.allocator, body);
}

// A generator that stopped producing forms would leave the property holding
// over nothing. So a fixed seed's run counts what the parser made of the
// inputs, and each outcome has to turn up.
test "generated inputs hold the property, and reach forms, refusals and the part wall" {
    var prng = std.Random.DefaultPrng.init(0x30);
    const buf = try testing.allocator.alloc(u8, buffer_len);
    defer testing.allocator.free(buf);
    var forms: usize = 0;
    var refused: usize = 0;
    var walled: usize = 0;
    for (0..3000) |_| {
        const input = generate(prng.random(), buf);
        try checkOne(testing.allocator, input);

        const nul = std.mem.indexOfScalar(u8, input, 0) orelse continue;
        const kind = form.kindOf(input[0..nul]);
        if (kind != .multipart) continue;
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        if (form.parse(arena.allocator(), kind, input[nul + 1 ..])) |fields| {
            if (fields.text.len + fields.files.len > 0) forms += 1;
            if (fields.text.len == form.max_parts) walled += 1;
        } else |_| {
            refused += 1;
        }
    }
    try testing.expect(forms >= 300);
    try testing.expect(refused >= 100);
    try testing.expect(walled >= 20);
}

// The property is only worth having if it can fail.
test "the property refuses a slice that does not lie inside the body" {
    const body = "0123456789";
    try expectInside(body, body[2..5]);
    try expectInside(body, "");
    try testing.expectError(error.TestUnexpectedResult, expectInside(body, "elsewhere"));
    const bigger: []const u8 = "0123456789abc";
    try testing.expectError(error.TestUnexpectedResult, expectInside(body, bigger[8..13]));
}

test "a form built from known parts is read back as exactly those parts" {
    var prng = std.Random.DefaultPrng.init(0x31);
    const random = prng.random();
    for (0..200) |_| {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(testing.allocator);
        const boundary = boundaries[random.uintLessThan(usize, boundaries.len)];
        const crlf: []const u8 = if (random.boolean()) "\r\n" else "\n";
        const count = random.uintLessThan(usize, 6);
        // Values never hold a line break or the boundary, so the answer is
        // known: what was put in is what comes out.
        const values = [_][]const u8{ "", "v", "hello world", "a-b", "--", "x y z" };
        var picked: [6]usize = undefined;
        var is_file: [6]bool = undefined;
        for (0..count) |k| {
            picked[k] = random.uintLessThan(usize, values.len);
            is_file[k] = random.boolean();
            try body.print(testing.allocator, "--{s}{s}Content-Disposition: form-data; name=\"n{d}\"", .{ boundary, crlf, k });
            if (is_file[k]) try body.print(testing.allocator, "; filename=\"f{d}\"", .{k});
            try body.print(testing.allocator, "{s}{s}{s}{s}", .{ crlf, crlf, values[picked[k]], crlf });
        }
        try body.print(testing.allocator, "--{s}--{s}", .{ boundary, crlf });

        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const fields = try form.parse(arena.allocator(), .{ .multipart = boundary }, body.items);
        var t: usize = 0;
        var f: usize = 0;
        for (0..count) |k| {
            const want = values[picked[k]];
            if (is_file[k]) {
                // An empty file named is a file, bar `filename=""`.
                try testing.expectEqualStrings(want, fields.files[f].bytes);
                f += 1;
            } else {
                try testing.expectEqualStrings(want, fields.text[t].value);
                t += 1;
            }
        }
        try testing.expectEqual(t, fields.text.len);
        try testing.expectEqual(f, fields.files.len);
    }
}
