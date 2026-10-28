//! The process series the metrics page carries beside nilo's own: resident and
//! virtual memory, open descriptors and their limit, start time and CPU time,
//! under the names every Prometheus client library uses so an existing
//! dashboard reads them unchanged (ADR 079).
//!
//! **Read at the scrape and at no other time.** Nothing here is kept, started
//! or counted: a scrape opens four files under `/proc/self` and the directory
//! of descriptors, parses them out of a buffer on the stack, and prints. A
//! request that is not the scrape never reaches this file, and an App that
//! never called `app.metrics` never links it. No allocation, so the page's one
//! arena block is all a scrape takes.
//!
//! **Linux only, and absent elsewhere rather than zero.** `/proc` is the one
//! source that needs no library and no `Io`; on another target the series are
//! left off the page, because a gauge that says 0 bytes of memory is a lie a
//! dashboard draws as a line. The check is on the target at compile time, so
//! the other targets carry none of the code.
//!
//! The system calls are `std.os.linux`'s own rather than `std.Io.Dir`'s: the
//! page's writer is handed no `Io`, and a scrape that waited on a file would be
//! a handler holding its thread (ADR 013) for files the kernel answers from
//! memory.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this target has the series at all.
pub const supported = builtin.os.tag == .linux;

/// `USER_HZ`, which `/proc` counts CPU time and start time in. The kernel's
/// ABI fixes it at 100 on every architecture Linux userspace sees, whatever
/// the tick rate inside the kernel is.
const ticks_per_s = 100;

pub const Snapshot = struct {
    resident_bytes: u64,
    virtual_bytes: u64,
    open_fds: u64,
    /// The soft limit; null when it is unlimited, which Prometheus clients
    /// leave off rather than print as a number.
    max_fds: ?u64,
    start_time_s: u64,
    cpu_ticks: u64,
};

/// Everything the page prints, or null where `/proc` cannot be read (a
/// container without it mounted, a sandbox that denies it): the series are
/// then absent, like on another target.
pub fn read() ?Snapshot {
    if (comptime !supported) return null;

    var stat_buf: [1024]u8 = undefined;
    const stat = parseStat(slurp("/proc/self/stat", &stat_buf) orelse return null) orelse return null;

    var statm_buf: [128]u8 = undefined;
    const statm = parseStatm(slurp("/proc/self/statm", &statm_buf) orelse return null) orelse return null;

    var up_buf: [64]u8 = undefined;
    const uptime_s = parseUptime(slurp("/proc/uptime", &up_buf) orelse return null) orelse return null;

    var now: std.os.linux.timespec = undefined;
    if (std.posix.errno(std.os.linux.clock_gettime(.REALTIME, &now)) != .SUCCESS) return null;
    const now_s: u64 = @intCast(now.sec);
    const age_s = uptime_s -| (stat.start_ticks / ticks_per_s);

    const page = std.heap.pageSize();
    return .{
        .resident_bytes = statm.resident_pages * page,
        .virtual_bytes = statm.size_pages * page,
        .open_fds = countFds() orelse return null,
        .max_fds = maxFds(),
        .start_time_s = now_s -| age_s,
        .cpu_ticks = stat.cpu_ticks,
    };
}

/// The series, in the text format. Prints nothing where there are none.
pub fn write(w: *std.Io.Writer) !void {
    const s = read() orelse return;

    try w.print(
        \\# HELP process_cpu_seconds_total Total user and system CPU time spent, in seconds.
        \\# TYPE process_cpu_seconds_total counter
        \\process_cpu_seconds_total {d}.{d:0>2}
        \\# HELP process_open_fds Number of open file descriptors.
        \\# TYPE process_open_fds gauge
        \\process_open_fds {d}
        \\
    , .{ s.cpu_ticks / ticks_per_s, s.cpu_ticks % ticks_per_s, s.open_fds });
    if (s.max_fds) |max| try w.print(
        \\# HELP process_max_fds Maximum number of open file descriptors.
        \\# TYPE process_max_fds gauge
        \\process_max_fds {d}
        \\
    , .{max});
    try w.print(
        \\# HELP process_virtual_memory_bytes Virtual memory size in bytes.
        \\# TYPE process_virtual_memory_bytes gauge
        \\process_virtual_memory_bytes {d}
        \\# HELP process_resident_memory_bytes Resident memory size in bytes.
        \\# TYPE process_resident_memory_bytes gauge
        \\process_resident_memory_bytes {d}
        \\# HELP process_start_time_seconds Start time of the process since the Unix epoch, in seconds.
        \\# TYPE process_start_time_seconds gauge
        \\process_start_time_seconds {d}
        \\
    , .{ s.virtual_bytes, s.resident_bytes, s.start_time_s });
}

// ---- reading /proc ----

/// A small file, read whole into `buf`. Null if it cannot be opened or read.
/// `/proc` files answer a read in one piece, but the loop is here because a
/// short read is not an error.
fn slurp(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const linux = std.os.linux;
    const opened = linux.openat(linux.AT.FDCWD, path, .{ .CLOEXEC = true }, 0);
    if (std.posix.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);

    var len: usize = 0;
    while (len < buf.len) {
        const rc = linux.read(fd, buf[len..].ptr, buf.len - len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return null,
        }
        if (rc == 0) break;
        len += rc;
    }
    return buf[0..len];
}

/// Entries in `/proc/self/fd`, less the descriptor this very count holds open
/// to read it.
fn countFds() ?u64 {
    const linux = std.os.linux;
    const opened = linux.openat(linux.AT.FDCWD, "/proc/self/fd", .{ .CLOEXEC = true, .DIRECTORY = true }, 0);
    if (std.posix.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);

    var buf: [2048]u8 align(8) = undefined;
    var count: u64 = 0;
    while (true) {
        const rc = linux.getdents64(fd, &buf, buf.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return null,
        }
        if (rc == 0) break;
        count += entriesIn(buf[0..rc]);
    }
    return count -| 1;
}

/// Directory entries in one `getdents64` buffer, not counting `.` and `..`.
fn entriesIn(buf: []const u8) u64 {
    // `linux_dirent64`: ino u64, off i64, reclen u16, type u8, then the name.
    const name_at = 19;
    var count: u64 = 0;
    var at: usize = 0;
    while (at + name_at < buf.len) {
        const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], builtin.cpu.arch.endian());
        if (reclen == 0) break;
        const name = std.mem.sliceTo(buf[at + name_at ..], 0);
        if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) count += 1;
        at += reclen;
    }
    return count;
}

fn maxFds() ?u64 {
    const linux = std.os.linux;
    var lim: linux.rlimit = undefined;
    if (std.posix.errno(linux.getrlimit(.NOFILE, &lim)) != .SUCCESS) return null;
    if (lim.cur == std.math.maxInt(@TypeOf(lim.cur))) return null;
    return lim.cur;
}

// ---- parsing, kept apart from the reading so a test can feed it text ----

const Stat = struct { cpu_ticks: u64, start_ticks: u64 };

/// `/proc/self/stat`: user and system time (fields 14 and 15) and the start
/// time (field 22). The second field is the command name in parentheses and
/// may hold spaces and parentheses itself, so the fields are counted from the
/// **last** `)`.
fn parseStat(text: []const u8) ?Stat {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    var utime: u64 = 0;
    var stime: u64 = 0;
    var start: u64 = 0;
    // The first token after the name is field 3.
    var field: usize = 3;
    while (it.next()) |token| : (field += 1) {
        switch (field) {
            14 => utime = std.fmt.parseInt(u64, token, 10) catch return null,
            15 => stime = std.fmt.parseInt(u64, token, 10) catch return null,
            22 => {
                start = std.fmt.parseInt(u64, token, 10) catch return null;
                return .{ .cpu_ticks = utime + stime, .start_ticks = start };
            },
            else => {},
        }
    }
    return null;
}

const Statm = struct { size_pages: u64, resident_pages: u64 };

fn parseStatm(text: []const u8) ?Statm {
    var it = std.mem.tokenizeAny(u8, text, " \n");
    const size = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const resident = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return .{ .size_pages = size, .resident_pages = resident };
}

/// Whole seconds of `/proc/uptime`, whose first number is `12345.67`.
fn parseUptime(text: []const u8) ?u64 {
    var it = std.mem.tokenizeAny(u8, text, " .\n");
    return std.fmt.parseInt(u64, it.next() orelse return null, 10) catch null;
}

// ---- tests ----

const testing = std.testing;

test "the command name of a process cannot shift the fields" {
    // A name with a space and a `)` in it, which is what `comm` may be.
    const line = "123 (my (odd) app) S 1 123 123 0 -1 4194560 100 0 0 0 " ++
        "250 50 0 0 20 0 1 0 9000 1000000 500 18446744073709551615";
    const s = parseStat(line).?;
    try testing.expectEqual(@as(u64, 300), s.cpu_ticks);
    try testing.expectEqual(@as(u64, 9000), s.start_ticks);
}

test "a stat line cut short is read as nothing rather than as zeroes" {
    try testing.expect(parseStat("123 (x) S 1 2 3") == null);
    try testing.expect(parseStat("no parenthesis at all") == null);
}

test "statm and uptime are read for the numbers they open with" {
    const m = parseStatm("2048 512 100 10 0 300 0\n").?;
    try testing.expectEqual(@as(u64, 2048), m.size_pages);
    try testing.expectEqual(@as(u64, 512), m.resident_pages);
    try testing.expectEqual(@as(?u64, 12345), parseUptime("12345.67 23456.78\n"));
}

test "a directory buffer is counted without its dot entries" {
    var buf: [128]u8 align(8) = @splat(0);
    const names = [_][]const u8{ ".", "..", "0", "12" };
    var at: usize = 0;
    for (names) |name| {
        const reclen: u16 = @intCast(std.mem.alignForward(usize, 19 + name.len + 1, 8));
        std.mem.writeInt(u16, buf[at + 16 ..][0..2], reclen, builtin.cpu.arch.endian());
        @memcpy(buf[at + 19 ..][0..name.len], name);
        at += reclen;
    }
    try testing.expectEqual(@as(u64, 2), entriesIn(buf[0..at]));
}

test "this process reports a plausible readout" {
    if (comptime !supported) return error.SkipZigTest;
    const s = read() orelse return error.SkipZigTest; // /proc may be denied
    try testing.expect(s.resident_bytes > 0);
    try testing.expect(s.virtual_bytes >= s.resident_bytes);
    // stdin, stdout and stderr at the least.
    try testing.expect(s.open_fds >= 3);
    if (s.max_fds) |max| try testing.expect(max >= s.open_fds);
    // After 2020 and not after now.
    try testing.expect(s.start_time_s > 1_577_836_800);
}
