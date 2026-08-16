//! A file as a return value — the handler names it, nilo opens it, and the
//! bytes never enter this process (ADR 0037).
//!
//! ```zig
//! fn invoice(files: *Files, id: u32) !?nilo.FileBody {
//!     const name = try files.nameOf(id) orelse return null;
//!     return .{ .dir = files.dir, .name = name, .content_type = "application/pdf" };
//! }
//! ```
//!
//! A return type rather than a `c.sendFile(…)` call, and for `Redirect`'s
//! reason (ADR 0032): the signature is the whole contract, and an answer
//! written by a side effect is an answer the generated API description
//! cannot see. `?` means here what it means everywhere else — a 404, and a
//! document that says so (ADR 0024).
//!
//! The `dir` is not decoration. A handler serves out of a directory
//! something opened on purpose and holds as a Service, and the name is
//! opened relative to that descriptor rather than resolved as a path. That
//! is the property ADR 0010 bought by refusing disk IO outright, and it is
//! kept here by the shape of the type: there is nowhere to put a path, so
//! there is no normalisation step to get wrong. What is left — a `..`
//! segment inside the name — is checked below, once, before anything is
//! opened.
//!
//! A symlink inside the directory is followed. Refusing them breaks ordinary
//! deployments and no static server on the internet refuses them by default
//! (ADR 0037), so `O_NOFOLLOW` is deliberately absent.

const std = @import("std");
const builtin = @import("builtin");

const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const typed = @import("typed.zig");
const Ctx = @import("ctx.zig").Ctx;

/// The declaration a `FileBody` carries, so the compile-time engine can tell
/// one from an ordinary return value — `Redirect`'s `nilo_redirect`, for
/// the same job.
pub const marker = "nilo_file";

/// An answer that is a file on disk.
pub const FileBody = struct {
    /// There is nothing for the marker to carry: unlike `Redirect(status)`
    /// or `Response(T)`, this type is not generic and has no compile-time
    /// parameter to hand on. Its presence is the whole message.
    pub const nilo_file = {};

    /// The directory the file is opened relative to — one a Service opened
    /// at startup and holds open, never one worked out per request.
    dir: bulkhead.Dir,

    /// The name inside that directory. Checked before it is used (see
    /// `checkName`), so a value that reached here straight from a request is
    /// a 404 rather than a way out of the directory.
    ///
    /// Borrowed for as long as the response takes to write, not copied — the
    /// same rule `Redirect.location` follows, so a name from a Service, a
    /// literal, or something built in the request arena are all safe.
    name: []const u8,

    /// What the bytes are. The default is the honest one for a file nobody
    /// said anything about, and it is the string a browser reads as "save
    /// this rather than try to show it".
    content_type: []const u8 = "application/octet-stream",

    /// Sent as `Cache-Control`. Empty leaves the header off.
    cache_control: []const u8 = "",

    /// Headers to send with the file, held by value for the reason
    /// `Response.headers` are (ADR 0019): a list written in the handler dies
    /// with the handler.
    ///
    /// This is where a download's filename goes:
    ///
    /// ```zig
    /// return .{
    ///     .dir = files.dir,
    ///     .name = name,
    ///     .content_type = "application/pdf",
    ///     .headers = .of(&.{.{
    ///         .name = "Content-Disposition",
    ///         .value = "attachment; filename=\"invoice-42.pdf\"",
    ///     }}),
    /// };
    /// ```
    ///
    /// A `download_as` field was considered and refused. Three reasons, and
    /// the third is the one that settles it. A type already carrying
    /// arbitrary headers does not want a field per popular header, or
    /// `Redirect` would have a `set_cookie` beside its `headers`. Quoting a
    /// filename properly is RFC 6266, not one line — a `"` or a `\` has to
    /// be escaped and a non-ASCII name needs `filename*=UTF-8''…` beside the
    /// plain one — and guessing at somebody else's filenames is exactly the
    /// kind of guess this codebase declines to make. And `attachment` is not
    /// the only answer: `inline` with a filename is what a PDF opening in a
    /// browser tab wants, and a field called `download_as` could only ever
    /// say one of the two.
    headers: typed.Headers = .{},
};

/// Whether `T` is a file answer, for the compile-time engine.
pub fn isFileBody(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, marker),
        else => false,
    };
}

// ---- the name, which is the security-critical part ----

/// Why a name was refused. An enum rather than a bool because the log line
/// is the only place the reason can go — the client is told nothing (see
/// `send`) — and "this name was refused" without saying which rule it broke
/// leaves whoever has to fix it guessing.
pub const Wrong = enum {
    empty,
    nul,
    absolute,
    /// A `..` that is a whole segment. `..foo` and `foo..` are ordinary
    /// names and are not this.
    parent,
    backslash,
    drive,

    /// The reason, as a fragment finishing "the name …".
    pub fn why(self: Wrong) []const u8 {
        return switch (self) {
            .empty => "is empty",
            .nul => "has a NUL byte in it",
            .absolute => "starts with a slash, so it is a path and not a name",
            .parent => "has a `..` segment, which points out of the directory",
            .backslash => "has a backslash in it, which is a path separator here",
            .drive => "starts with a drive letter, so it is a path and not a name",
        };
    }
};

/// Whether a name may be opened inside a `Dir`, and what is wrong with it if
/// not.
///
/// Segment-aware rather than a search for `..` anywhere in the text, and the
/// difference is not academic: a file legitimately called `..hidden` — or
/// `report..pdf`, or `Fri..Sun.csv` — has to work, while `a/../../etc/passwd`
/// must not. Splitting on the separator and comparing whole segments is the
/// only reading that tells those apart.
///
/// The Windows rules are compiled in only on Windows, deliberately. A
/// backslash is an ordinary character in a POSIX filename, so refusing it
/// everywhere would make a file that exists unservable; refusing it where it
/// separates path segments is what stops `..\..\windows` from walking past
/// the split above.
pub fn checkName(name: []const u8) ?Wrong {
    if (name.len == 0) return .empty;

    // First, because it is the one that makes every check after it a lie: a
    // name the kernel truncates at a NUL is not the name that was inspected,
    // and `ok\x00/../../etc/passwd` would otherwise pass a segment walk and
    // open something else entirely.
    if (std.mem.indexOfScalar(u8, name, 0) != null) return .nul;

    if (name[0] == '/') return .absolute;

    if (builtin.os.tag == .windows) {
        if (std.mem.indexOfScalar(u8, name, '\\') != null) return .backslash;
        // `C:` — and `C:file` is relative to that drive's own working
        // directory, which is not this directory either way.
        if (name.len >= 2 and name[1] == ':' and std.ascii.isAlphabetic(name[0])) return .drive;
    }

    var segments = std.mem.splitScalar(u8, name, '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return .parent;
    }
    return null;
}

// ---- answering with one ----

/// Open the file and hand it to the send primitive, which closes it.
///
/// Called from `typed.sendValue`, after the optional has been unwrapped.
/// Nothing is allocated here: the header values are copied into the request
/// arena by `setHeader`, exactly as a `Response`'s are (ADR 0019), and the
/// rest is borrowed for the length of the call.
pub fn send(c: *Ctx, body: FileBody) !void {
    if (checkName(body.name)) |wrong| return refuse(c, wrong);

    const file = body.dir.openFile(body.name) catch |err| switch (err) {
        // The one open failure with an answer better than a 500: from the
        // client's side, a file the application named and the disk does not
        // have is indistinguishable from one that never existed (ADR 0037).
        error.FileNotFound => return notThere(c),
        else => return err,
    };

    // After the open, not before. A failure between the two would otherwise
    // leave headers set on a response that turns into a 404, and the file is
    // this function's for exactly as long as the line below takes to reach.
    for (body.headers.view()) |h| try c.setHeader(h.name, h.value);

    return c.sendFile(.{
        .file = file,
        // Null asks the file. A handler has nothing to say about a size it
        // never measured, and a `stat` on the way past is what the answer's
        // `Content-Length` is made of.
        .size = null,
        .content_type = body.content_type,
        .cache_control = body.cache_control,
    });
}

/// A name that could not name a file in this directory.
///
/// A 404 and not a 400, and the reason is the answer's indistinguishability
/// rather than politeness. Three things can go wrong here — the handler
/// returned null, the file is not on the disk, and the name was refused —
/// and all three mean "there is no such file" to whoever asked. Answering
/// the third differently would make it the one probe that gets a distinct
/// reply, which is a way of confirming that a directory is being served and
/// that the check exists. A 400 would also be the wrong accusation: the name
/// is a value the handler computed, and the client may have had no hand in
/// it at all.
fn refuse(c: *Ctx, wrong: Wrong) fail.Error {
    // Loudly, because a `..` in a name is an application handing a request
    // value straight through, and a 404 that says nothing is a bug that
    // never gets found.
    //
    // The name itself is deliberately not in this line. It is attacker-shaped
    // text going into a log file, and a newline in it would forge a second
    // entry — the same reasoning that makes `Upload`'s filename a label to
    // show and never a path to write to.
    std.log.warn(
        "{s} {s}: a FileBody named a file that cannot be opened in its directory — the " ++
            "name {s} — so nothing was opened and the answer is a 404. A name reaching " ++
            "nilo comes from the application, so this is a request value that arrived " ++
            "somewhere unchecked.",
        .{ @tagName(c.method), c._path, wrong.why() },
    );
    return notThere(c);
}

/// The 404 all three ways of not having a file share, word for word — the
/// same sentence `typed.sendValue` writes when a handler returns null.
fn notThere(c: *Ctx) fail.Error {
    return fail.notFound("there is no {s}", .{c._path});
}

// ---- tests ----

const testing = std.testing;

const App = @import("app.zig").App;
const openapi = @import("openapi.zig");
const nilo_testing = @import("testing.zig");

test "a name is refused by segment, not by substring" {
    // The ones that have to work. `..` inside a name is not a `..` segment,
    // and a file called `..hidden` is a file somebody has.
    for ([_][]const u8{
        "invoice.pdf",
        "..hidden",
        "report..pdf",
        "Fri..Sun.csv",
        "a/b/c.txt",
        "a/./b.txt",
        "...",
        "..a/b",
    }) |name| {
        try testing.expectEqual(@as(?Wrong, null), checkName(name));
    }

    try testing.expectEqual(@as(?Wrong, .empty), checkName(""));
    try testing.expectEqual(@as(?Wrong, .nul), checkName("ok\x00/../../etc/passwd"));
    try testing.expectEqual(@as(?Wrong, .absolute), checkName("/etc/passwd"));
    try testing.expectEqual(@as(?Wrong, .parent), checkName(".."));
    try testing.expectEqual(@as(?Wrong, .parent), checkName("../secret"));
    try testing.expectEqual(@as(?Wrong, .parent), checkName("a/../../etc/passwd"));
    try testing.expectEqual(@as(?Wrong, .parent), checkName("a/.."));

    if (builtin.os.tag == .windows) {
        try testing.expectEqual(@as(?Wrong, .backslash), checkName("..\\..\\windows"));
        try testing.expectEqual(@as(?Wrong, .drive), checkName("C:secret"));
    } else {
        // A POSIX filename may contain a backslash, and refusing it would
        // make a file that exists unservable.
        try testing.expectEqual(@as(?Wrong, null), checkName("a\\b"));
    }
}

/// A directory with one file in it, written for one test and removed
/// afterwards — what a Service holding a `nilo.Dir` looks like.
const Files = struct {
    tmp: std.testing.TmpDir,
    dir: bulkhead.Dir,

    const there = "invoice-1.pdf";
    const contents = "%PDF-1.7 not really";

    fn init() !Files {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = there, .data = contents });

        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
        return .{ .tmp = tmp, .dir = try bulkhead.Dir.open(path) };
    }

    fn deinit(self: *Files) void {
        self.dir.close();
        self.tmp.cleanup();
    }

    /// The four things an application can hand back, one per invoice number.
    fn nameOf(self: *Files, id: u32) ?[]const u8 {
        _ = self;
        return switch (id) {
            1 => there,
            2 => "gone.pdf", // named, and not on the disk
            3 => "../secret", // an unchecked request value, arriving intact
            else => null, // no such invoice
        };
    }
};

fn invoice(files: *Files, id: u32) !?FileBody {
    const named = files.nameOf(id) orelse return null;
    return .{
        .dir = files.dir,
        .name = named,
        .content_type = "application/pdf",
        .cache_control = "private, max-age=60",
        .headers = .of(&.{.{
            .name = "Content-Disposition",
            .value = "attachment; filename=\"invoice.pdf\"",
        }}),
    };
}

fn appServing(app: *App, files: *Files) !void {
    try app.provide(files);
    try app.get("/invoices/:id", invoice);
}

test "a handler returning a FileBody answers with the file" {
    var files = try Files.init();
    defer files.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &files);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/invoices/1");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(Files.contents, answer.body);
    try testing.expectEqualStrings("application/pdf", answer.header("Content-Type").?);
    try testing.expectEqualStrings("private, max-age=60", answer.header("Cache-Control").?);
    try testing.expectEqualStrings(
        "attachment; filename=\"invoice.pdf\"",
        answer.header("Content-Disposition").?,
    );
    // Everything a static file's answer carries, this carries too — including
    // the offer that makes the file resumable.
    try testing.expectEqualStrings("bytes", answer.header("Accept-Ranges").?);
    try testing.expectEqualStrings("19", answer.header("Content-Length").?);
    try testing.expect(answer.keep_alive);
}

test "a range against a FileBody is answered by the shared primitive" {
    // Not a second copy of `sendfile.zig`'s range tests: what this pins is
    // that a FileBody goes *through* that primitive rather than around it,
    // which is the whole reason there is one (ADR 0021).
    var files = try Files.init();
    defer files.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &files);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.send(
        &app,
        "GET /invoices/1 HTTP/1.1\r\nRange: bytes=0-4\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 206), answer.status);
    try testing.expectEqualStrings("bytes 0-4/19", answer.header("Content-Range").?);
    try testing.expectEqualStrings("%PDF-", answer.body);
}

test "`?FileBody` returning null is a 404, the same as every other optional" {
    var files = try Files.init();
    defer files.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &files);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/invoices/9");
    try testing.expectEqual(@as(u16, 404), answer.status);
}

test "a file the application named and the disk does not have is a 404" {
    var files = try Files.init();
    defer files.deinit();

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &files);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/invoices/2");
    try testing.expectEqual(@as(u16, 404), answer.status);
}

test "a name with a `..` segment opens nothing, and says the same 404" {
    var files = try Files.init();
    defer files.deinit();

    // The refusal is logged on purpose — see `refuse` — and a test process
    // writing to stderr gets a red `failed command` block above a suite that
    // passed (see `test_root.zig`). Turned down here rather than for the
    // suite, so a test that trips it by accident still says so.
    const noisy = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = noisy;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &files);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/invoices/3");
    try testing.expectEqual(@as(u16, 404), answer.status);
    // Word for word what the null case answers. A probe cannot tell the two
    // apart, which is the point of `refuse`'s choice of status.
    const missing = try client.get(&app, "/invoices/9");
    try testing.expectEqualStrings(missing.body, answer.body);
}

test "the document describes a FileBody as bytes, and `?` as the 404" {
    var op = comptime typed.operation("/invoices/:id", invoice);
    op.method = .GET;
    const ops = [_]openapi.Operation{op};

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try openapi.write(&out.writer, &ops, .{});
    const document = out.written();

    // `application/octet-stream` and not `application/pdf`: the content type
    // is a field the handler fills in while the request is running, so naming
    // it here would be a guess (ADR 0037).
    try testing.expect(std.mem.indexOf(u8, document,
        \\"200":{"description":"the file's bytes","content":{"application/octet-stream":{"schema":{"type":"string","format":"binary"}}}}
    ) != null);
    // And the `?` is a promise of its own, exactly as it is for `?User`.
    try testing.expect(std.mem.indexOf(u8, document,
        \\"404":{"description":"there is no such thing"
    ) != null);
}
