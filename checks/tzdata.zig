//! `zig build tzdata-check -Dnetwork`: whether IANA has published a time zone
//! release newer than the one `nilo_job` carries (ADR 161), as a program the
//! build runs (`checks/main.zig` says why).

const std = @import("std");
const Report = @import("main.zig").Report;

/// The vendored release against the newest one IANA lists.
///
/// **Why this is a check and not a reminder.** A zone's rules are changed by
/// governments, sometimes on a month's notice (Kazakhstan 2024 gave 29 days),
/// and a schedule built on stale data runs an hour off for everyone in that
/// zone until somebody notices. The data is vendored so a build needs no
/// network, which makes staleness silent; this makes it loud on the machine
/// that cuts a release (`docs/releasing.md`), and `-Dtzdata` is how a
/// dependent does not wait for that release.
///
/// Off `test` on purpose, the way `fetch-check` is: it needs the internet, and
/// a gate that passes because a machine had no route is worse than no gate.
pub const TzdataCheck = struct {
    const index = "https://data.iana.org/time-zones/releases/";

    /// `data_file` is `job/tzdata/tzdata.zig`, whose `version` constant is the
    /// release carried.
    pub fn run(r: *Report, data_file: []const u8) anyerror!void {
        const io = r.io;
        const source = try r.root.readFileAlloc(io, data_file, r.gpa, .limited(8 << 20));
        const have = quoted(source, "pub const version = \"") orelse
            return r.fail("nilo: {s} has no `pub const version = \"...\";`", .{data_file});

        var client: std.http.Client = .{ .allocator = r.gpa, .io = io };
        defer client.deinit();
        var body: std.Io.Writer.Allocating = .init(r.gpa);
        const result = client.fetch(.{
            .location = .{ .url = index },
            .response_writer = &body.writer,
        }) catch |err| return r.fail("nilo: asking {s} failed ({t}), so nothing was compared", .{ index, err });
        if (result.status != .ok) return r.fail("nilo: {s} answered {d}, so nothing was compared", .{ index, @backingInt(result.status) });

        const latest = newest(body.written()) orelse
            return r.fail("nilo: {s} lists no tzdata release, so nothing was compared", .{index});
        if (std.mem.eql(u8, latest, have)) {
            std.debug.print("tzdata-check: release {s}, which is the newest\n", .{have});
            return;
        }
        if (older(have, latest)) return r.fail(
            "nilo: IANA has published tzdata {s} and nilo_job carries {s}.\n" ++
                "  Run `python3 -I job/tzdata/refresh.py` and put the result under `## Unreleased` in CHANGELOG.md\n" ++
                "  (docs/releasing.md); a dependent that cannot wait builds with `-Dtzdata=<dir>`.",
            .{ latest, have },
        );
        std.debug.print("tzdata-check: release {s}, newer than the {s} IANA lists\n", .{ have, latest });
    }
};

/// The text after `prefix` up to the next quote.
fn quoted(source: []const u8, prefix: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, source, prefix) orelse return null;
    const from = at + prefix.len;
    const end = std.mem.indexOfScalarPos(u8, source, from, '"') orelse return null;
    return source[from..end];
}

/// The newest `tzdata<year><letter>.tar.gz` in a directory listing.
fn newest(listing: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, listing, at, "tzdata")) |found| {
        at = found + "tzdata".len;
        const rest = listing[at..];
        // Four digits, then lower-case letters, then the extension.
        if (rest.len < 5 or !std.ascii.isDigit(rest[0]) or !std.ascii.isDigit(rest[1]) or
            !std.ascii.isDigit(rest[2]) or !std.ascii.isDigit(rest[3])) continue;
        var end: usize = 4;
        while (end < rest.len and std.ascii.isLower(rest[end])) end += 1;
        if (end == 4 or !std.mem.startsWith(u8, rest[end..], ".tar.gz")) continue;
        const version = rest[0..end];
        if (best == null or older(best.?, version)) best = version;
    }
    return best;
}

/// Whether release `a` came before `b`: by year, then by letters, a shorter
/// run of letters first (`2026z` before `2026aa`).
fn older(a: []const u8, b: []const u8) bool {
    const year = std.mem.order(u8, a[0..4], b[0..4]);
    if (year != .eq) return year == .lt;
    if (a.len != b.len) return a.len < b.len;
    return std.mem.order(u8, a[4..], b[4..]) == .lt;
}

test "the newest release is the one with the later year, then the later letter" {
    const listing =
        \\<a href="tzdata2025c.tar.gz">tzdata2025c.tar.gz</a> <a href="tzdata2026a.tar.gz">x</a>
        \\<a href="tzdata2026e.tar.gz">x</a> <a href="tzdata2026d.tar.gz">x</a> <a href="tzdata2026e.tar.gz.asc">
        \\<a href="tzdata-2026f/">not a release</a>
    ;
    try std.testing.expectEqualStrings("2026e", newest(listing).?);
    try std.testing.expect(older("2026e", "2026f"));
    try std.testing.expect(older("2025z", "2026a"));
    try std.testing.expect(older("2026z", "2026aa"));
    try std.testing.expect(!older("2026e", "2026e"));
}
