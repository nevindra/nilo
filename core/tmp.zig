//! A directory for one test, and the path to it (ADR 250).
//!
//! `std.testing.tmpDir` hands back a `Dir` and a random `sub_path`, and no
//! path. Code under test that opens a file by name, a SQLite database, a
//! socket, a directory `app.static` serves, needs the string, and the only
//! way to get it was to read std's source and write `.zig-cache/tmp/{s}` by
//! hand: nilo's own suite did that sixteen times across two layers, and a
//! program written on nilo did it again. This is that line, written once.
//!
//! **Core holds it because two layers need it** (ADR 057): `http/` tests
//! hand the path to `app.static` and `bulkhead.Dir.open`, and `sql/` tests
//! hand it to SQLite, which `nilo_sql`, a Service, cannot reach through
//! `nilo_http`. `nilo.testing.tmpDir` is this same declaration.
//!
//! **No path borrows the `TmpDir`.** `path` writes into a buffer the caller
//! holds and `pathAlloc` into memory the caller frees, so a `TmpDir` can be
//! returned from a fixture's `init` or kept in a struct field, which is how
//! std's is used, without a path taken earlier pointing at the copy it was
//! taken from.
//!
//! **It is always opened iterable.** std's default opens the directory as a
//! path handle that cannot be listed, and listing one panics with `BADF`
//! inside `std.Io.Threaded`, which reads as an Engine bug (docs/history.md).
//! A test directory gains nothing from that handle, so there is no option to
//! get it.
//!
//! Only a test can call `tmpDir`: std's asserts `builtin.is_test`, and a
//! program that never calls it compiles none of this.

const std = @import("std");

/// What `std.testing.tmpDir` puts under the working directory.
const parent = ".zig-cache/tmp/";

const sub_path_len = @typeInfo(@FieldType(std.testing.TmpDir, "sub_path")).array.len;

/// A directory of its own for one test, removed by `cleanup`.
pub const TmpDir = struct {
    /// The directory, open, for writing a file in by handle.
    dir: std.Io.Dir,
    /// What std handed back, which `cleanup` removes.
    held: std.testing.TmpDir,

    /// How long `path(buf, "")` is: the directory itself, relative to the
    /// working directory, without the terminating zero.
    pub const dir_path_len = parent.len + sub_path_len;

    /// The path of `name` inside the directory, written into `buf` and
    /// terminated with a zero, so SQLite or a libc `open` can take it as it
    /// is. An empty `name` is the directory itself. The path is relative to
    /// the working directory, as std's directory is; a test that changes the
    /// working directory has to resolve it first.
    pub fn path(self: *const TmpDir, buf: []u8, name: []const u8) error{NoSpaceLeft}![:0]u8 {
        if (name.len == 0) return std.mem.printSentinel(buf, parent ++ "{s}", .{&self.held.sub_path}, 0);
        return std.mem.printSentinel(buf, parent ++ "{s}/{s}", .{ &self.held.sub_path, name }, 0);
    }

    /// `path`, into memory `gpa` owns and the caller frees.
    pub fn pathAlloc(self: *const TmpDir, gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}![:0]u8 {
        if (name.len == 0) return std.fmt.allocPrintSentinel(gpa, parent ++ "{s}", .{&self.held.sub_path}, 0);
        return std.fmt.allocPrintSentinel(gpa, parent ++ "{s}/{s}", .{ &self.held.sub_path, name }, 0);
    }

    /// Closes the directory and removes it with everything in it. A path
    /// handed out earlier names nothing afterwards.
    pub fn cleanup(self: *TmpDir) void {
        self.held.cleanup();
        self.* = undefined;
    }
};

/// A new directory under `.zig-cache/tmp/`, open and iterable. Test only.
pub fn tmpDir() TmpDir {
    const held = std.testing.tmpDir(.{ .iterate = true });
    return .{ .dir = held.dir, .held = held };
}

const testing = std.testing;

test "a file written through the directory opens by the path it hands back" {
    var tmp = tmpDir();
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "roles.db", .data = "not really sqlite" });

    var buf: [64]u8 = undefined;
    const path = try tmp.path(&buf, "roles.db");
    try testing.expect(std.mem.startsWith(u8, path, ".zig-cache/tmp/"));
    try testing.expectEqual(@as(u8, 0), path.ptr[path.len]);

    var read: [32]u8 = undefined;
    const got = try std.Io.Dir.cwd().readFile(testing.io, path, &read);
    try testing.expectEqualStrings("not really sqlite", got);
}

test "an empty name is the directory itself, and it can be listed" {
    var tmp = tmpDir();
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "one.txt", .data = "1" });

    var buf: [TmpDir.dir_path_len + 1]u8 = undefined;
    const path = try tmp.path(&buf, "");
    try testing.expectEqual(TmpDir.dir_path_len, path.len);

    var by_path = try std.Io.Dir.cwd().openDir(testing.io, path, .{ .iterate = true });
    defer by_path.close(testing.io);
    var seen: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(testing.io)) |entry| {
        try testing.expectEqualStrings("one.txt", entry.name);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen);
}

test "a path taken before the directory was moved still names it" {
    const Fixture = struct {
        tmp: TmpDir,
        path: [:0]u8,

        fn init(gpa: std.mem.Allocator) !@This() {
            var tmp = tmpDir();
            errdefer tmp.cleanup();
            try tmp.dir.writeFile(testing.io, .{ .sub_path = "wal", .data = "x" });
            return .{ .tmp = tmp, .path = try tmp.pathAlloc(gpa, "wal") };
        }
    };
    const gpa = testing.allocator;
    var fixture = try Fixture.init(gpa);
    defer {
        gpa.free(fixture.path);
        fixture.tmp.cleanup();
    }
    var read: [4]u8 = undefined;
    try testing.expectEqualStrings("x", try std.Io.Dir.cwd().readFile(testing.io, fixture.path, &read));
}

test "a buffer too short for the path is an error, not a cut path" {
    var tmp = tmpDir();
    defer tmp.cleanup();
    var buf: [TmpDir.dir_path_len]u8 = undefined; // one short of the zero
    try testing.expectError(error.NoSpaceLeft, tmp.path(&buf, ""));
}

test "cleanup removes the directory and what is in it" {
    var tmp = tmpDir();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "left.txt", .data = "behind" });
    var buf: [64]u8 = undefined;
    const path = try tmp.path(&buf, "left.txt");
    tmp.cleanup();
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, path, .{}));
}
