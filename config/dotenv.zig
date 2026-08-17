//! A `.env`, read as a source — and the file is somebody else's to open
//! (ADR 0064).
//!
//! ```zig
//! // Read it however you like. An arena that lives as long as the program
//! // is the usual answer; `@embedFile` works for a file with no secrets in
//! // it. What matters is that the text outlives the Config.
//! const text = std.fs.cwd().readFileAlloc(arena, ".env", 64 * 1024) catch "";
//! const file = config.Dotenv{ .text = text };
//!
//! const read = config.from(Settings, config.layered(.{
//!     config.Env{ .environ = init.minimal.environ },  // a set variable wins
//!     file,                                           // the file is the floor
//! }));
//!
//! try file.report(stderr);   // writes nothing when the file is clean
//! const settings = read.value() orelse {
//!     try read.report(stderr);
//!     std.process.exit(2);
//! };
//! ```
//!
//! **This takes text, not a path, and that is the whole shape of it.** The
//! module opens no file, so it allocates nothing, imports nothing, and
//! `zig test config/dotenv.zig` runs every line below against string
//! literals — which is the entry condition for this layer rather than a
//! nicety (ADR 0042). A `.env` is a format, and the refusal ADR 0043 wrote
//! was never about formats: it was about the parser every importer would
//! carry. Fifty lines that need no dependency are on the other side of that.
//!
//! **The text has to outlive the Config**, exactly as `Fixed`'s pairs do and
//! the environment block does. A `[]const u8` field points *into* this text,
//! so freeing it leaves a Config pointing at nothing:
//!
//! ```zig
//! const text = try std.fs.cwd().readFileAlloc(gpa, ".env", 64 * 1024);
//! defer gpa.free(text);   // ← the Config points here. Do not.
//! ```
//!
//! **A line that is not a setting is reported, not skipped.** A `.env` with
//! `DATABASE_URL postgres://…` on line 7 — no `=`, a typo somebody makes
//! once a year — would otherwise read as "DATABASE_URL is not set", and the
//! fifteen minutes that follows is the failure this whole module exists to
//! stop. So the four verbs are the ones `Read` already uses:
//!
//! ```
//! 2 lines are not settings:
//!   line 7 has no `=`, so it sets nothing
//!   line 12 has nothing in front of its `=`
//! ```
//!
//! **A report never quotes a value**, which is the one place this departs
//! from `Read.report` and it is deliberate: a `.env` is where a password
//! lives, and a startup message is the thing that ends up in a log
//! aggregator. The line number is what somebody needs to find it, and the
//! name is quoted only where the name is what went wrong.

const std = @import("std");

/// A `.env`'s text, read as a source of settings.
///
/// A linear scan per lookup, for `Fixed`'s reason: a Config has a dozen
/// settings and is read once before the socket opens, so a map here would be
/// machinery bought with an allocation to save a comparison that happens ten
/// times in the life of the process.
pub const Dotenv = struct {
    /// The file's contents. Held, never copied — so it has to outlive every
    /// use of the Config read through it.
    text: []const u8,

    /// What one name was set to, or null when the file does not set it.
    ///
    /// The first line setting a name wins, which is `Fixed`'s rule and the
    /// same one for the same reason: the order is what says which is which.
    pub fn get(self: Dotenv, name: []const u8) ?[]const u8 {
        var lines = Lines.init(self.text);
        while (lines.next()) |line| switch (line.what) {
            .setting => |s| if (std.mem.eql(u8, s.name, name)) return s.value,
            else => {},
        };
        return null;
    }

    /// Whether any line meant to be a setting and is not.
    pub fn failed(self: Dotenv) bool {
        var it = self.failures();
        return it.next() != null;
    }

    /// How many lines meant to be settings and are not.
    pub fn failedCount(self: Dotenv) usize {
        var n: usize = 0;
        var it = self.failures();
        while (it.next()) |_| n += 1;
        return n;
    }

    /// Walk the lines that are not settings, in the order the file has them.
    ///
    /// A rescan rather than a list, because a file has an unbounded number
    /// of lines and this module allocates nothing. It is walked once, at
    /// startup, by a process that is deciding whether to keep going.
    pub fn failures(self: Dotenv) Failures {
        return .{ .lines = Lines.init(self.text) };
    }

    pub const Failures = struct {
        lines: Lines,

        pub fn next(self: *Failures) ?BadLine {
            while (self.lines.next()) |line| switch (line.what) {
                .wrong => |w| return .{
                    .number = line.number,
                    .why = w.why,
                    .name = w.name,
                },
                else => {},
            };
            return null;
        }
    };

    /// Write every line that is not a setting, one per line, under a line
    /// saying how many there are. Writes nothing at all when there are none,
    /// so it is safe to call unconditionally — which is what lets the
    /// canonical `main` call it without a branch of its own.
    pub fn report(self: Dotenv, w: *std.Io.Writer) !void {
        const n = self.failedCount();
        if (n == 0) return;
        if (n == 1) {
            try w.writeAll("1 line is not a setting:\n");
        } else {
            try w.print("{d} lines are not settings:\n", .{n});
        }
        var it = self.failures();
        while (it.next()) |line| {
            try w.writeAll("  ");
            try line.say(w);
            try w.writeAll("\n");
        }
    }
};

/// Why one line is not a setting.
///
/// Four, and they are all about the *shape* of the line. Whether the value
/// is any good is the Config's question and `convert.Reason` answers it —
/// `PORT=soon` parses perfectly here and fails there, which is the split
/// that keeps this file from growing a second opinion about types.
pub const Wrong = enum {
    /// No `=` anywhere, so the line sets nothing. A pasted fragment, or a
    /// `key: value` that wandered in from a YAML file.
    no_equals,
    /// An `=` with nothing in front of it.
    empty_name,
    /// A name no environment variable may carry — a space in the middle is
    /// the one that actually happens.
    bad_name,
    /// A value that opens `"` or `'` and never closes it.
    unbalanced_quote,
};

/// One line that meant to be a setting and is not.
pub const BadLine = struct {
    /// Counting from 1, the way an editor does.
    number: usize,
    why: Wrong,
    /// The name the line tried to set, and empty when there was none to
    /// read. Only `bad_name` has one worth showing.
    name: []const u8 = "",

    /// Write nilo's own sentence for this line.
    ///
    /// Here rather than in the caller for `Failure.say`'s reason: a program
    /// printing its own banner around the list should not have to reproduce
    /// the wording.
    pub fn say(self: BadLine, w: *std.Io.Writer) !void {
        switch (self.why) {
            .no_equals => try w.print(
                "line {d} has no `=`, so it sets nothing",
                .{self.number},
            ),
            .empty_name => try w.print(
                "line {d} has nothing in front of its `=`",
                .{self.number},
            ),
            .bad_name => try w.print(
                "line {d} sets \"{s}\", which is not a name an environment variable may carry",
                .{ self.number, self.name },
            ),
            .unbalanced_quote => try w.print(
                "line {d} opens a quote and never closes it",
                .{self.number},
            ),
        }
    }
};

/// What one line turned out to be.
const What = union(enum) {
    setting: struct { name: []const u8, value: []const u8 },
    /// Blank, or a comment. Nothing here, and nothing wrong.
    nothing,
    wrong: struct { why: Wrong, name: []const u8 = "" },
};

const Line = struct {
    number: usize,
    what: What,
};

/// The file, one line at a time.
///
/// Public to the file only. It carries no allocation and no state beyond
/// where it is, which is what lets `get`, `failures` and `failedCount` each
/// take their own and walk the text again.
const Lines = struct {
    rest: []const u8,
    number: usize = 0,

    fn init(text: []const u8) Lines {
        // A byte-order mark is what a Windows editor puts in front of the
        // first name, and a name wearing one matches nothing while looking
        // exactly right in the error. Dropped rather than reported, because
        // "line 1 sets PORT, which is not a name" is a worse message than no
        // message at all.
        const bom = "\xEF\xBB\xBF";
        return .{ .rest = if (std.mem.startsWith(u8, text, bom)) text[bom.len..] else text };
    }

    fn next(self: *Lines) ?Line {
        if (self.rest.len == 0) return null;
        self.number += 1;

        const end = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
        var raw = self.rest[0..end];
        self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else "";
        // CRLF, because a `.env` is a file people edit on other machines.
        if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];

        return .{ .number = self.number, .what = read(raw) };
    }
};

const blanks = " \t";

/// One line's text into what it means.
///
/// The grammar is small on purpose and the things it will not do are the
/// point of it: no escapes, no multi-line values, no `${OTHER}`
/// interpolation, and no comment after a value. That last one keeps
/// `PASSWORD=abc#123` intact, and pays for itself twice — a `PORT=8080 # the
/// port` becomes `PORT has to be a whole number, not "8080 # the port"`,
/// which tells somebody exactly what happened without this file having to
/// guess where their comment started.
fn read(line: []const u8) What {
    const trimmed = std.mem.trim(u8, line, blanks);
    if (trimmed.len == 0) return .nothing;
    if (trimmed[0] == '#') return .nothing;

    // `export KEY=value`, so one file can be both read here and `source`d by
    // a shell. It is three lines, and it is what people's files look like.
    const body = if (std.mem.startsWith(u8, trimmed, "export "))
        std.mem.trimStart(u8, trimmed["export ".len..], blanks)
    else
        trimmed;

    const eq = std.mem.indexOfScalar(u8, body, '=') orelse return .{ .wrong = .{ .why = .no_equals } };

    const name = std.mem.trimEnd(u8, body[0..eq], blanks);
    if (name.len == 0) return .{ .wrong = .{ .why = .empty_name } };
    if (!isName(name)) return .{ .wrong = .{ .why = .bad_name, .name = name } };

    const given = std.mem.trim(u8, body[eq + 1 ..], blanks);
    const value = unquote(given) orelse
        return .{ .wrong = .{ .why = .unbalanced_quote, .name = name } };

    return .{ .setting = .{ .name = name, .value = value } };
}

/// What a `.env` may call a setting: what an environment variable may be
/// called, which is a letter or `_` and then letters, digits and `_`.
///
/// Strict on purpose. A name this refuses would otherwise match no field and
/// come back as `PORT is not set` about a line that plainly sets it.
fn isName(name: []const u8) bool {
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// A value with its quotes taken off, or null when it opened one it never
/// closed.
///
/// The inside is kept verbatim — no escapes, so `"a\nb"` is a backslash and
/// an `n`. A setting that needs a newline in it is a setting a `.env` is the
/// wrong file for.
fn unquote(value: []const u8) ?[]const u8 {
    if (value.len == 0) return value;
    const quote = value[0];
    if (quote != '"' and quote != '\'') return value;
    if (value.len >= 2 and value[value.len - 1] == quote) return value[1 .. value.len - 1];
    return null;
}

const testing = std.testing;

fn one(text: []const u8, name: []const u8) ?[]const u8 {
    return (Dotenv{ .text = text }).get(name);
}

test "a plain setting is read" {
    try testing.expectEqualStrings("9000", one("PORT=9000", "PORT").?);
    try testing.expectEqualStrings("9000", one("PORT=9000\n", "PORT").?);
}

test "a name the file does not set is null" {
    try testing.expectEqual(@as(?[]const u8, null), one("PORT=9000\n", "DATABASE_URL"));
}

test "a name is matched whole, not by prefix" {
    try testing.expectEqual(@as(?[]const u8, null), one("PORT=9000\n", "PORT_RANGE"));
    try testing.expectEqual(@as(?[]const u8, null), one("PORT=9000\n", "POR"));
}

test "settings a Config never asks for are simply not asked for" {
    // A `.env` is shared with other tools, so an unknown name is not a
    // mistake. It is only a mistake when the line is not a setting at all.
    const text = "STRIPE_KEY=sk_test\nPORT=9000\nSOME_OTHER_TOOL=on\n";
    try testing.expectEqualStrings("9000", one(text, "PORT").?);
    try testing.expect(!(Dotenv{ .text = text }).failed());
}

test "blank lines and comments are nothing at all" {
    const text =
        \\# the port this thing serves on
        \\
        \\   # indented, and still a comment
        \\PORT=9000
        \\
    ;
    try testing.expectEqualStrings("9000", one(text, "PORT").?);
    try testing.expect(!(Dotenv{ .text = text }).failed());
}

test "space around the name and the value is not part of either" {
    try testing.expectEqualStrings("9000", one("  PORT  =  9000  ", "PORT").?);
    try testing.expectEqualStrings("9000", one("\tPORT\t=\t9000\t", "PORT").?);
}

test "a value set to nothing is set" {
    // `PORT=` is somebody setting it empty, which `Fixed` and a shell both
    // agree is different from leaving it out.
    try testing.expectEqualStrings("", one("PORT=", "PORT").?);
    try testing.expectEqualStrings("", one("PORT=\"\"", "PORT").?);
}

test "quotes come off, and what is inside them is kept" {
    try testing.expectEqualStrings("a b c", one("GREETING=\"a b c\"", "GREETING").?);
    try testing.expectEqualStrings("a b c", one("GREETING='a b c'", "GREETING").?);
    // Including a `#`, which is exactly why there are no trailing comments.
    try testing.expectEqualStrings("a#b", one("PASSWORD=\"a#b\"", "PASSWORD").?);
    // And a quote of the other kind, kept verbatim.
    try testing.expectEqualStrings("it's", one("MSG=\"it's\"", "MSG").?);
}

test "a `#` in an unquoted value is part of the value" {
    // No trailing comments, so nothing here has to guess.
    try testing.expectEqualStrings("abc#123", one("PASSWORD=abc#123", "PASSWORD").?);
}

test "an `=` in a value is part of the value" {
    // The first `=` splits, and the rest is text — which is what a base64
    // secret and a connection string both need.
    try testing.expectEqualStrings("a=b=c", one("TOKEN=a=b=c", "TOKEN").?);
}

test "an `export` in front is read the same" {
    try testing.expectEqualStrings("9000", one("export PORT=9000", "PORT").?);
    try testing.expectEqualStrings("9000", one("  export   PORT=9000", "PORT").?);
    // A name that merely starts with the letters is not one.
    try testing.expectEqualStrings("1", one("exported=1", "exported").?);
}

test "CRLF is read the same as LF" {
    try testing.expectEqualStrings("9000", one("PORT=9000\r\nDB=x\r\n", "PORT").?);
    try testing.expectEqualStrings("x", one("PORT=9000\r\nDB=x\r\n", "DB").?);
}

test "a byte-order mark in front of the first name is dropped" {
    // Windows editors write one, and a `PORT` wearing it looks right in
    // every error message while matching nothing.
    try testing.expectEqualStrings("9000", one("\xEF\xBB\xBFPORT=9000\n", "PORT").?);
}

test "the first line setting a name wins" {
    try testing.expectEqualStrings("9000", one("PORT=9000\nPORT=8080\n", "PORT").?);
}

test "an empty file reads nothing and is not wrong" {
    try testing.expectEqual(@as(?[]const u8, null), one("", "PORT"));
    try testing.expect(!(Dotenv{ .text = "" }).failed());
    try testing.expectEqual(@as(usize, 0), (Dotenv{ .text = "" }).failedCount());
}

test "a line with no `=` is not a setting" {
    const file = Dotenv{ .text = "PORT=9000\nDATABASE_URL postgres://localhost\n" };
    try testing.expect(file.failed());
    try testing.expectEqual(@as(usize, 1), file.failedCount());

    var it = file.failures();
    const bad = it.next().?;
    try testing.expectEqual(@as(usize, 2), bad.number);
    try testing.expectEqual(Wrong.no_equals, bad.why);
    try testing.expectEqual(@as(?BadLine, null), it.next());

    // And the setting above it still reads.
    try testing.expectEqualStrings("9000", file.get("PORT").?);
}

test "an `=` with nothing in front of it is not a setting" {
    const file = Dotenv{ .text = "=8080\n" };
    var it = file.failures();
    const bad = it.next().?;
    try testing.expectEqual(@as(usize, 1), bad.number);
    try testing.expectEqual(Wrong.empty_name, bad.why);
}

test "a name no environment variable may carry is not a setting" {
    const file = Dotenv{ .text = "MY KEY=1\n2FA=on\nOK_ONE=yes\n" };
    try testing.expectEqual(@as(usize, 2), file.failedCount());

    var it = file.failures();
    const spaced = it.next().?;
    try testing.expectEqual(Wrong.bad_name, spaced.why);
    try testing.expectEqualStrings("MY KEY", spaced.name);

    const digit = it.next().?;
    try testing.expectEqual(@as(usize, 2), digit.number);
    try testing.expectEqualStrings("2FA", digit.name);

    // The good one is unaffected.
    try testing.expectEqualStrings("yes", file.get("OK_ONE").?);
}

test "a leading underscore is a name" {
    try testing.expectEqualStrings("1", one("_PRIVATE=1", "_PRIVATE").?);
}

test "a quote that is opened and never closed is not a setting" {
    const file = Dotenv{ .text = "TOKEN=\"abc\n" };
    var it = file.failures();
    const bad = it.next().?;
    try testing.expectEqual(Wrong.unbalanced_quote, bad.why);
    // Mixing the two kinds is the same mistake.
    const mixed = Dotenv{ .text = "TOKEN='abc\"\n" };
    var mit = mixed.failures();
    try testing.expectEqual(Wrong.unbalanced_quote, mit.next().?.why);
}

test "a lone quote as the whole value is not a setting" {
    const file = Dotenv{ .text = "TOKEN=\"\n" };
    var it = file.failures();
    try testing.expectEqual(Wrong.unbalanced_quote, it.next().?.why);
}

test "every bad line is named at once, not just the first" {
    // The same feature `Read` has, one level down: a file with three
    // mistakes in it costs one run, not three.
    const file = Dotenv{ .text =
        \\PORT=9000
        \\DATABASE_URL postgres://localhost
        \\=8080
        \\MY KEY=1
        \\
    };
    try testing.expectEqual(@as(usize, 3), file.failedCount());

    var it = file.failures();
    try testing.expectEqual(@as(usize, 2), it.next().?.number);
    try testing.expectEqual(@as(usize, 3), it.next().?.number);
    try testing.expectEqual(@as(usize, 4), it.next().?.number);
    try testing.expectEqual(@as(?BadLine, null), it.next());
}

test "the report names every line and how many there are" {
    const file = Dotenv{ .text =
        \\PORT=9000
        \\DATABASE_URL postgres://localhost
        \\MY KEY=1
        \\
    };

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try file.report(&w);

    try testing.expectEqualStrings(
        \\2 lines are not settings:
        \\  line 2 has no `=`, so it sets nothing
        \\  line 3 sets "MY KEY", which is not a name an environment variable may carry
        \\
    , buf[0..w.end]);
}

test "one bad line is reported in the singular" {
    const file = Dotenv{ .text = "TOKEN=\"abc\n" };

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try file.report(&w);

    try testing.expectEqualStrings(
        \\1 line is not a setting:
        \\  line 1 opens a quote and never closes it
        \\
    , buf[0..w.end]);
}

test "a clean file reports nothing at all" {
    const file = Dotenv{ .text = "PORT=9000\n# and a comment\n" };

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try file.report(&w);
    try testing.expectEqual(@as(usize, 0), w.end);
}

test "a report never quotes a value" {
    // The one departure from `Read.report`, and the reason is that this file
    // is where a password lives and a startup message is what reaches a log.
    const file = Dotenv{ .text = "DATABASE_URL=postgres://user:hunter2@host/db\nPGPASSWORD=\"hunter2\n" };

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try file.report(&w);

    try testing.expect(std.mem.indexOf(u8, buf[0..w.end], "hunter2") == null);
}

test "a line number counts every line, including the ones that are nothing" {
    // Blank lines and comments still count, because the number has to be
    // the one an editor shows or it is worse than useless.
    const file = Dotenv{ .text = "\n# a comment\n\nMY KEY=1\n" };
    var it = file.failures();
    try testing.expectEqual(@as(usize, 4), it.next().?.number);
}
