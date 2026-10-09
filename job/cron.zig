//! A schedule, read while compiling.
//!
//! Five fields — minute, hour, day of month, month, day of week — in the
//! spelling every operator already knows, because a schedule spelled a new way
//! is a schedule somebody has to look up. `*`, `a`, `a-b`, `a,b,c`, `*/n` and
//! `a-b/n` in every field; `sun`–`sat` and `jan`–`dec` where a name is easier
//! to read than a number.
//!
//! The text is comptime and the parse is comptime, so a field out of range or
//! a stray character is a compile error naming the field rather than a job
//! that never runs ([ADR 161](../docs/adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)).
//! What comes out is five bitsets, and `next` walks forward from a moment to
//! the first minute they all admit.
//!
//! **UTC unless `.in` names a zone.** `job.cron("0 3 * * *")` is three in the
//! morning UTC, and `.in("Asia/Jakarta")` after it is three in the morning
//! there. A zone is IANA data compiled into the program while compiling, only
//! the one named (`tz.zig` says how and what it costs), and the answer is
//! still UTC microseconds: `Tick.run_at` and every stored time stay UTC, and
//! the zone is only how the wall clock is read.
//!
//! A wall clock does two awkward things a year, and what a schedule does about
//! them is the caller's to say (ADR 161). **A schedule whose hour field is
//! exactly `*` is read as an interval** ("every quarter hour"): a wall time
//! inside a skipped hour has no tick, and a repeated hour ticks on both
//! passes, in real-time order, and nothing is declared. **Every other
//! schedule is a fixed time** ("at 02:30", `9,17`), and one whose minutes,
//! hours and months can meet a window the zone skips or repeats must declare
//! `skipped` and `repeated` on the job, which `Cron.needs` works out while
//! compiling from the zone's own transitions, not from a guess that it is
//! always 02:00. Asia/Jakarta never asks.
//!
//! When both the day-of-month and the day-of-week fields are restricted, a
//! day matches if **either** does, which is what every cron since Vixie has
//! done and what `0 0 1,15 * mon` has always meant.

const std = @import("std");
const tz = @import("tz.zig");

/// What a fixed-time schedule in a zone does with a wall time that the clock
/// skips: 02:30 on the night the clocks go from 02:00 to 03:00 does not exist.
pub const Skipped = enum {
    /// Run it once, late: the wall time read with the offset from before the
    /// gap, so 02:30 runs at 03:30 (RFC 5545 section 3.3.5, and Temporal's
    /// "compatible" disambiguation).
    run_late,
    /// There is no tick that night. A tick that is not run this way is not
    /// a missed one: it never existed.
    skip,
};

/// What a fixed-time schedule in a zone does with a wall time the clock reads
/// twice, 02:30 on the night the clocks go back from 03:00 to 02:00.
pub const Repeated = enum {
    /// Run on the first pass only.
    first,
    /// Run on the second pass only.
    second,
    /// Run on both.
    both,
};

/// The five fields as sets. Every slice is a comptime constant pointing into
/// the binary, and `next` reads nothing else.
pub const Cron = struct {
    minute: u60,
    hour: u24,
    /// Bit 1 is the first of the month; bit 0 is never set.
    day: u32,
    /// Bit 1 is January; bit 0 is never set.
    month: u13,
    /// Bit 0 is Sunday.
    weekday: u7,
    /// Whether the day field *started with* `*` (`*`, `*/2`), which decides
    /// the either-or rule above: Vixie and cronie set the flag on the first
    /// character, so `*/2` is "unrestricted" for that rule while still
    /// limiting the days itself.
    any_day: bool,
    any_weekday: bool,
    /// Whether the hour field is exactly `*`, which is what makes a zoned
    /// schedule an interval rather than a fixed time.
    every_hour: bool = true,
    /// The zone the fields are read in, null for UTC. A pointer to a
    /// comptime constant (`tz.zone`).
    zone: ?*const tz.Zone = null,
    /// The text of the schedule and the zone's name, for a Refusal that
    /// names them.
    text: []const u8 = "",
    zone_name: []const u8 = "",

    /// What `next` answers when no minute ever comes: the largest moment
    /// there is, a row due at which is never claimed. `parse` refuses the
    /// dates that cause it, so a schedule written as text cannot get here;
    /// it is what a `Cron` built by hand, or an AND of day and weekday no
    /// calendar satisfies, answers instead of a worker that never returns.
    pub const never: i64 = std.math.maxInt(i64);

    /// What a zoned fixed-time schedule does with a wall time the clock
    /// skips or repeats. A schedule that declares nothing is one that
    /// `needs` says does not need to; `next` reads it as `.{}`.
    pub const Policy = struct {
        skipped: Skipped = .run_late,
        repeated: Repeated = .first,
    };

    /// Which of `skipped` and `repeated` this schedule has to declare: both
    /// false for UTC, for an interval, and for a fixed time that no window of
    /// its zone can meet. Comptime, because the zone is.
    pub fn needs(comptime self: Cron) tz.Needs {
        const z = self.zone orelse return .{};
        if (self.every_hour) return .{};
        return tz.needs(z, self.minute, self.hour, self.month);
    }

    /// The first minute strictly after `after_micros` that this admits, in
    /// microseconds since the epoch — the unit `nilo.nowMicros` answers in.
    /// `never` when there is none.
    ///
    /// Strictly after, so a schedule asked "what comes after the tick that
    /// just ran" never answers the tick that just ran.
    pub fn next(self: Cron, after_micros: i64) i64 {
        return self.nextWith(after_micros, .{});
    }

    /// `next`, with the job's declarations for a zoned fixed-time schedule.
    /// UTC and interval schedules have no wall time to skip or repeat and
    /// read nothing from `policy`.
    pub fn nextWith(self: Cron, after_micros: i64, policy: Policy) i64 {
        const after_secs: i64 = @divFloor(@max(after_micros, 0), std.time.us_per_s);
        if (self.zone) |z| return self.nextZoned(z, after_secs, policy);
        // The next whole minute after `after`, which is where a schedule that
        // fires on the minute could first fire.
        const t = self.matchFrom(@intCast((@divFloor(after_secs, 60) + 1) * 60)) orelse return never;
        return @intCast(t * std.time.us_per_s);
    }

    /// A zoned schedule: walk the zone's stretches of one offset in order
    /// and, inside each, the wall clock with the schedule's own fields, so
    /// that ticks come out in real-time order even across a repeated hour.
    ///
    /// A wall time that does not exist (the clock went from 02:00 to 03:00)
    /// is simply never produced by the stretch after it, which is `.skip`;
    /// `.run_late` adds the skipped times to that stretch read with the
    /// offset from before the gap, so 02:30 runs at 03:30 (RFC 5545
    /// section 3.3.5). A repeated wall time is produced by both stretches, which
    /// is `.both`; `.first` leaves the second out and `.second` the first.
    fn nextZoned(self: Cron, z: *const tz.Zone, after_secs: i64, policy: Policy) i64 {
        // An interval has no wall time to protect, so it reads as `.skip`
        // and `.both`, which is what the walk does with no extras.
        const fixed = !self.every_hour;
        var cursor: i64 = after_secs + 1;
        // Two stretches a year; a leap-day schedule waits eight years, and
        // a weekday on top of that twenty-eight.
        for (0..4096) |_| {
            const seg = z.segmentAt(cursor);
            var lo = cursor + seg.off;
            var hi = if (seg.end == tz.forever) tz.forever else seg.end + seg.off;
            if (fixed and policy.repeated == .first and seg.start != tz.beginning) {
                const before = z.segmentAt(seg.start - 1);
                if (before.off > seg.off) lo = @max(lo, seg.start + before.off);
            }
            if (fixed and policy.repeated == .second and seg.end != tz.forever) {
                const after = z.segmentAt(seg.end);
                if (after.off < seg.off) hi = @min(hi, seg.end + after.off);
            }
            var best: ?i64 = null;
            if (self.wallFrom(lo)) |w| {
                if (w < hi) best = w - seg.off;
            }
            if (fixed and policy.skipped == .run_late and seg.start != tz.beginning) {
                const before = z.segmentAt(seg.start - 1);
                if (before.off < seg.off) {
                    const gap_lo = @max(seg.start, cursor) + before.off;
                    const gap_hi = seg.start + seg.off;
                    if (gap_lo < gap_hi) {
                        if (self.wallFrom(gap_lo)) |w| {
                            if (w < gap_hi) best = if (best) |b| @min(b, w - before.off) else w - before.off;
                        }
                    }
                }
            }
            if (best) |u| return u * std.time.us_per_s;
            if (seg.end == tz.forever) return never;
            cursor = seg.end;
        }
        return never;
    }

    /// The first wall-clock minute at or after `local` (seconds on the wall
    /// clock, read as if it were UTC) that the fields admit.
    fn wallFrom(self: Cron, local: i64) ?i64 {
        const up = local + @mod(-local, 60);
        const m = self.matchFrom(@intCast(@max(up, 0))) orelse return null;
        return @intCast(m);
    }

    /// The first whole minute at or after `from` (seconds, a multiple of 60)
    /// that the fields admit, read as UTC. The calendar walk is the same for
    /// a wall clock, which is why a zone only has to change what it is
    /// started from.
    fn matchFrom(self: Cron, from: u64) ?u64 {
        var t: u64 = from;

        // A bound rather than a `while (true)`, and a bound in *time*: a count
        // of turns of the loop was a bound on nothing, because most turns
        // step a whole day or month, so a date that never comes took years of
        // simulated calendar to exhaust, each turn walking the years since
        // 1970 (ADR 161). The Gregorian calendar repeats, weekdays and all,
        // every 400 years, so a match that is not found inside one is not
        // coming.
        const stop = t + @as(u64, 400 * 366) * std.time.epoch.secs_per_day;
        while (t < stop) {
            const es: std.time.epoch.EpochSeconds = .{ .secs = t };
            const epoch_day = es.getEpochDay();
            const year_day = epoch_day.calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const month_no: u5 = month_day.month.numeric();

            if (!bitSet(u13, self.month, month_no)) {
                // Skip to the first minute of the next month.
                const days_left = std.time.epoch.getDaysInMonth(year_day.year, month_day.month) - month_day.day_index;
                t = (epoch_day.day + days_left) * std.time.epoch.secs_per_day;
                continue;
            }

            const dom: u6 = @as(u6, month_day.day_index) + 1;
            // 1970-01-01 was a Thursday, and Sunday is 0.
            const dow: u3 = @intCast((epoch_day.day + 4) % 7);
            if (!self.dayMatches(dom, dow)) {
                t = (epoch_day.day + 1) * std.time.epoch.secs_per_day;
                continue;
            }

            const day_secs = es.getDaySeconds();
            const hour = day_secs.getHoursIntoDay();
            if (!bitSet(u24, self.hour, hour)) {
                t = epoch_day.day * std.time.epoch.secs_per_day + (@as(u64, hour) + 1) * 3600;
                continue;
            }

            const minute = day_secs.getMinutesIntoHour();
            if (!bitSet(u60, self.minute, minute)) {
                t += 60;
                continue;
            }

            return t;
        }
        return null;
    }

    /// The same schedule read on the wall clock of `name`, an IANA zone.
    /// Comptime, and a Refusal for a zone nobody has data for.
    pub fn in(comptime self: Cron, comptime name: []const u8) Cron {
        if (self.zone != null) @compileError(
            "nilo: the schedule \"" ++ self.text ++ "\" is already in " ++ self.zone_name ++ ", and `.in(\"" ++ name ++ "\")` cannot move it again.\n" ++
                "  Say the zone once: `job.cron(\"...\").in(\"" ++ name ++ "\")`.",
        );
        var out = self;
        out.zone = tz.zone(name);
        out.zone_name = name;
        return out;
    }

    fn dayMatches(self: Cron, dom: u6, dow: u3) bool {
        const dom_ok = bitSet(u32, self.day, dom);
        const dow_ok = bitSet(u7, self.weekday, dow);
        // Either field starting with `*` makes it an AND, as in Vixie's
        // `if (dom_star || dow_star) dom && dow`. A bare `*` has every bit
        // set, so for it this is what the code said before.
        if (self.any_day or self.any_weekday) return dom_ok and dow_ok;
        return dom_ok or dow_ok;
    }
};

fn bitSet(comptime T: type, set: T, n: anytype) bool {
    const Shift = std.math.Log2Int(T);
    if (n >= @bitSizeOf(T)) return false;
    return (set >> @as(Shift, @intCast(n))) & 1 == 1;
}

/// Parse five fields, refusing in nilo's own words.
///
/// Comptime only: there is no run-time parser, because a schedule read out of
/// a config file at start-up would be a schedule the compiler cannot check,
/// and the whole reason this is a type is that it can (ADR 161).
pub fn parse(comptime text: []const u8) Cron {
    return comptime blk: {
        @setEvalBranchQuota(20_000);
        var fields: [5][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, text, " \t");
        while (it.next()) |f| {
            if (count == 5) @compileError(
                "nilo: the schedule \"" ++ text ++ "\" has more than five fields.\n" ++
                    "  A schedule is `minute hour day month weekday`, and seconds are not one of them.",
            );
            fields[count] = f;
            count += 1;
        }
        if (count != 5) @compileError(
            "nilo: the schedule \"" ++ text ++ "\" has " ++ std.fmt.comptimePrint("{d}", .{count}) ++
                " field(s), and a schedule has five.\n" ++
                "  `minute hour day month weekday` — `0 3 * * *` is three in the morning, every day.",
        );

        const minute = field(u60, text, "minute", fields[0], 0, 59, &.{});
        const hour = field(u24, text, "hour", fields[1], 0, 23, &.{});
        const day = field(u32, text, "day", fields[2], 1, 31, &.{});
        const month = field(u13, text, "month", fields[3], 1, 12, &month_names);
        var weekday = field(u8, text, "weekday", fields[4], 0, 7, &weekday_names);
        // `7` is Sunday too, the way every cron reads it.
        if (weekday & (1 << 7) != 0) weekday |= 1;

        const any_day = fields[2][0] == '*';
        const any_weekday = fields[4][0] == '*';

        // With either field starred a day must satisfy both, so the day
        // field has to name a day some month has. Otherwise (`0 0 31 2 *`,
        // `0 0 30 feb *`, `0 0 31 4,6,9,11 *`) the schedule is a worker
        // that never finds its next tick, which a compile error says now
        // and `next` used to say as a loop that did not end (ADR 161). When
        // both are restricted a weekday alone is enough to fire.
        if ((any_day or any_weekday) and !someDayExists(day, month)) @compileError(
            "nilo: the schedule \"" ++ text ++ "\" never fires, because no month it names has a day it names.\n" ++
                "  Its day field (`" ++ fields[2] ++ "`) and month field (`" ++ fields[3] ++ "`) share no date: " ++
                "February has at most 29 days, and April, June, September and November have 30.",
        );

        break :blk .{
            .minute = minute,
            .hour = hour,
            .day = day,
            .month = month,
            .weekday = @truncate(weekday),
            .any_day = any_day,
            .any_weekday = any_weekday,
            .every_hour = std.mem.eql(u8, fields[1], "*"),
            .text = text,
        };
    };
}

/// Whether some month in `months` has a day in `days`. February counts 29,
/// because a leap year comes round.
fn someDayExists(days: u32, months: u13) bool {
    for (1..13) |m| {
        if (months & (@as(u13, 1) << @intCast(m)) == 0) continue;
        const longest: u5 = switch (m) {
            2 => 29,
            4, 6, 9, 11 => 30,
            else => 31,
        };
        // Bits 1 to `longest`.
        const mask: u64 = (@as(u64, 1) << longest << 1) - 2;
        if (@as(u64, days) & mask != 0) return true;
    }
    return false;
}

const month_names = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const weekday_names = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };

/// One field into a bitset. `names` maps a word to `low + index`, for the
/// two fields that have words.
fn field(
    comptime T: type,
    comptime whole: []const u8,
    comptime name: []const u8,
    comptime text: []const u8,
    comptime low: u8,
    comptime high: u8,
    comptime names: []const []const u8,
) T {
    comptime {
        var set: T = 0;
        var parts = std.mem.splitScalar(u8, text, ',');
        while (parts.next()) |part| {
            if (part.len == 0) refuse(whole, name, text, "an empty entry between two commas");

            // `x/n`
            var step: u8 = 1;
            var range = part;
            if (std.mem.indexOfScalar(u8, part, '/')) |slash| {
                range = part[0..slash];
                step = number(whole, name, text, part[slash + 1 ..], 1, 255, &.{});
                if (step == 0) refuse(whole, name, text, "a step of 0");
            }

            var from: u8 = low;
            var to: u8 = high;
            if (std.mem.eql(u8, range, "*")) {
                // whole range
            } else if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
                from = number(whole, name, text, range[0..dash], low, high, names);
                to = number(whole, name, text, range[dash + 1 ..], low, high, names);
                if (from > to) refuse(whole, name, text, "a range that runs backwards");
            } else {
                from = number(whole, name, text, range, low, high, names);
                // `5/15` means from 5 to the end, the way Vixie reads it.
                to = if (step == 1) from else high;
            }

            var v: u16 = from;
            while (v <= to) : (v += step) {
                set |= @as(T, 1) << @intCast(v);
            }
        }
        return set;
    }
}

fn number(
    comptime whole: []const u8,
    comptime name: []const u8,
    comptime text: []const u8,
    comptime word: []const u8,
    comptime low: u8,
    comptime high: u8,
    comptime names: []const []const u8,
) u8 {
    comptime {
        if (word.len == 0) refuse(whole, name, text, "a number that is missing");
        for (names, 0..) |n, i| {
            if (std.ascii.eqlIgnoreCase(n, word)) return low + i;
        }
        const v = std.fmt.parseInt(u8, word, 10) catch
            refuse(whole, name, text, "`" ++ word ++ "`, which is not a number");
        if (v < low or v > high) @compileError(
            "nilo: the schedule \"" ++ whole ++ "\" has " ++ std.fmt.comptimePrint("{d}", .{v}) ++
                " in its " ++ name ++ " field, and that field runs from " ++
                std.fmt.comptimePrint("{d}", .{low}) ++ " to " ++ std.fmt.comptimePrint("{d}", .{high}) ++ ".",
        );
        return v;
    }
}

fn refuse(comptime whole: []const u8, comptime name: []const u8, comptime text: []const u8, comptime what: []const u8) noreturn {
    @compileError(
        "nilo: the schedule \"" ++ whole ++ "\" has " ++ what ++ " in its " ++ name ++ " field (`" ++ text ++ "`).\n" ++
            "  A field is `*`, a number, `a-b`, `a,b`, `*/n` or `a-b/n`.",
    );
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

fn micros(comptime iso: []const u8) i64 {
    // "YYYY-MM-DDTHH:MM" in UTC, for tests that want a readable moment.
    const year = std.fmt.parseInt(u16, iso[0..4], 10) catch unreachable;
    const month = std.fmt.parseInt(u4, iso[5..7], 10) catch unreachable;
    const day = std.fmt.parseInt(u5, iso[8..10], 10) catch unreachable;
    const hour = std.fmt.parseInt(u5, iso[11..13], 10) catch unreachable;
    const minute = std.fmt.parseInt(u6, iso[14..16], 10) catch unreachable;

    var days: u64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u4 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(m)));
    days += day - 1;
    const secs = days * 86_400 + @as(u64, hour) * 3600 + @as(u64, minute) * 60;
    return @intCast(secs * std.time.us_per_s);
}

test "every minute is the minute after" {
    const c = comptime parse("* * * * *");
    try testing.expectEqual(micros("2026-09-13T10:01"), c.next(micros("2026-09-13T10:00")));
    // Strictly after: a moment inside the minute still answers the next one.
    try testing.expectEqual(micros("2026-09-13T10:01"), c.next(micros("2026-09-13T10:00") + 30 * std.time.us_per_s));
}

test "three in the morning, every day" {
    const c = comptime parse("0 3 * * *");
    try testing.expectEqual(micros("2026-09-14T03:00"), c.next(micros("2026-09-13T10:00")));
    try testing.expectEqual(micros("2026-09-13T03:00"), c.next(micros("2026-09-13T02:59")));
    // The tick itself is not its own successor.
    try testing.expectEqual(micros("2026-09-14T03:00"), c.next(micros("2026-09-13T03:00")));
}

test "every fifteen minutes lands on the quarter hours" {
    const c = comptime parse("*/15 * * * *");
    try testing.expectEqual(micros("2026-09-13T10:15"), c.next(micros("2026-09-13T10:00")));
    try testing.expectEqual(micros("2026-09-13T10:15"), c.next(micros("2026-09-13T10:07")));
    try testing.expectEqual(micros("2026-09-13T11:00"), c.next(micros("2026-09-13T10:45")));
}

test "sunday by name and by number are the same day" {
    const by_name = comptime parse("0 3 * * sun");
    const by_number = comptime parse("0 3 * * 0");
    const by_seven = comptime parse("0 3 * * 7");
    // 2026-09-13 is a Sunday.
    const from = micros("2026-09-12T12:00");
    try testing.expectEqual(micros("2026-09-13T03:00"), by_name.next(from));
    try testing.expectEqual(micros("2026-09-13T03:00"), by_number.next(from));
    try testing.expectEqual(micros("2026-09-13T03:00"), by_seven.next(from));
    // And the week after, from just past it.
    try testing.expectEqual(micros("2026-09-20T03:00"), by_name.next(micros("2026-09-13T03:00")));
}

test "the first of the month skips whole months" {
    const c = comptime parse("30 0 1 * *");
    try testing.expectEqual(micros("2026-10-01T00:30"), c.next(micros("2026-09-13T10:00")));
    // Across a year end.
    try testing.expectEqual(micros("2027-01-01T00:30"), c.next(micros("2026-12-01T00:30")));
}

test "a month by name, and a range of them" {
    const c = comptime parse("0 0 1 jan-mar *");
    try testing.expectEqual(micros("2027-01-01T00:00"), c.next(micros("2026-09-13T10:00")));
    try testing.expectEqual(micros("2027-02-01T00:00"), c.next(micros("2027-01-01T00:00")));
    try testing.expectEqual(micros("2028-01-01T00:00"), c.next(micros("2027-03-01T00:00")));
}

test "day and weekday both restricted means either" {
    // The 15th, or a Monday, whichever is sooner.
    const c = comptime parse("0 9 15 * mon");
    // 2026-09-13 is Sunday, so Monday the 14th comes before the 15th.
    try testing.expectEqual(micros("2026-09-14T09:00"), c.next(micros("2026-09-13T10:00")));
    try testing.expectEqual(micros("2026-09-15T09:00"), c.next(micros("2026-09-14T09:00")));
}

test "a leap day is waited for" {
    const c = comptime parse("0 0 29 feb *");
    try testing.expectEqual(micros("2028-02-29T00:00"), c.next(micros("2026-09-13T10:00")));
}

test "a list and a range with a step" {
    const c = comptime parse("0 8-18/5 * * 1,3");
    // 2026-09-14 is Monday: 08:00, 13:00, 18:00 that day.
    try testing.expectEqual(micros("2026-09-14T08:00"), c.next(micros("2026-09-13T10:00")));
    try testing.expectEqual(micros("2026-09-14T13:00"), c.next(micros("2026-09-14T08:00")));
    try testing.expectEqual(micros("2026-09-14T18:00"), c.next(micros("2026-09-14T13:00")));
    // Then Wednesday.
    try testing.expectEqual(micros("2026-09-16T08:00"), c.next(micros("2026-09-14T18:00")));
}

test "a day field that starts with a star is unrestricted, so the weekday must match as well" {
    // Vixie and cronie set DOM_STAR on any field that starts with `*`, and a
    // day matches by AND when either field is starred: odd days (`*/2`
    // counts from the 1st) that are also Mondays, not odd days or Mondays.
    const c = comptime parse("0 0 */2 * mon");
    // Monday the 14th is even, so the first is Monday the 21st.
    try testing.expectEqual(micros("2026-09-21T00:00"), c.next(micros("2026-09-13T10:00")));
    // The 28th is even too; the 5th of October is the next odd Monday.
    try testing.expectEqual(micros("2026-10-05T00:00"), c.next(micros("2026-09-21T00:00")));
}

test "a weekday field that starts with a star is unrestricted, so the day must match as well" {
    // Sunday, Tuesday, Thursday and Saturday, and also the 13th: the 13th of
    // October 2026 is the first that falls on one (a Tuesday).
    const c = comptime parse("0 0 13 * */2");
    try testing.expectEqual(micros("2026-10-13T00:00"), c.next(micros("2026-09-13T10:00")));
}

test "a date that never comes answers never rather than looping for minutes" {
    // Built by hand, since `parse` refuses it: the 31st of February.
    const never: Cron = .{
        .minute = 1,
        .hour = 1,
        .day = 1 << 31,
        .month = 1 << 2,
        .weekday = 0x7f,
        .any_day = false,
        .any_weekday = true,
    };
    try testing.expectEqual(Cron.never, never.next(micros("2026-09-13T10:00")));
}

test "a date exists when some month named has some day named, and February has twenty-nine" {
    const feb: u13 = 1 << 2;
    const thirty_day: u13 = (1 << 4) | (1 << 6) | (1 << 9) | (1 << 11);
    try testing.expect(!someDayExists(1 << 31, feb));
    try testing.expect(!someDayExists(1 << 30, feb));
    try testing.expect(someDayExists(1 << 29, feb));
    try testing.expect(!someDayExists(1 << 31, thirty_day));
    try testing.expect(someDayExists(1 << 30, thirty_day));
    try testing.expect(someDayExists(1 << 31, feb | (1 << 1)));
}

// -- zones ------------------------------------------------------------------

/// The ticks `c` answers one after another from `from`, against `expected`.
/// Each is asked for as the one strictly after the last, which is how a worker
/// asks, so an answer that is not increasing fails here too.
fn expectTicks(c: Cron, policy: Cron.Policy, comptime from: []const u8, comptime expected: []const []const u8) !void {
    var at = micros(from);
    inline for (expected) |iso| {
        at = c.nextWith(at, policy);
        try testing.expectEqual(micros(iso), at);
    }
}

const skip_first: Cron.Policy = .{ .skipped = .skip, .repeated = .first };
const late_second: Cron.Policy = .{ .skipped = .run_late, .repeated = .second };
const late_both: Cron.Policy = .{ .skipped = .run_late, .repeated = .both };

test "a fixed time that no window meets needs no declaration, and is read in the zone" {
    // 03:00 in Berlin: the hour the clocks skip is [02:00, 03:00).
    const c = comptime parse("0 3 * * *").in("Europe/Berlin");
    try testing.expect(!c.needs().skipped and !c.needs().repeated);
    // CET is +1 until 01:00 UTC on 2026-03-29, then CEST is +2, then CET again
    // from 01:00 UTC on 2026-10-25.
    try expectTicks(c, .{}, "2026-03-27T12:00", &.{ "2026-03-28T02:00", "2026-03-29T01:00", "2026-03-30T01:00" });
    try expectTicks(c, .{}, "2026-10-24T12:00", &.{ "2026-10-25T02:00", "2026-10-26T02:00" });
    // And the other year's.
    try expectTicks(c, .{}, "2027-03-27T12:00", &.{ "2027-03-28T01:00", "2027-03-29T01:00" });
    try expectTicks(c, .{}, "2027-10-30T12:00", &.{ "2027-10-31T02:00", "2027-11-01T02:00" });
}

test "Jakarta has no hour to skip, so it never asks, and 03:00 there is 20:00 UTC" {
    const c = comptime parse("0 3 * * *").in("Asia/Jakarta");
    try testing.expect(!c.needs().skipped and !c.needs().repeated);
    const midnight = comptime parse("0 0 * * *").in("Asia/Jakarta");
    try testing.expect(!midnight.needs().skipped and !midnight.needs().repeated);
    try expectTicks(c, .{}, "2026-10-01T00:00", &.{ "2026-10-01T20:00", "2026-10-02T20:00", "2026-10-03T20:00" });
    // The same instants the UTC schedule `0 20 * * *` finds.
    const utc = comptime parse("0 20 * * *");
    try testing.expectEqual(utc.next(micros("2026-10-01T21:00")), c.next(micros("2026-10-01T21:00")));
}

test "a schedule without a zone is still UTC" {
    const c = comptime parse("0 3 * * *");
    try testing.expect(c.zone == null);
    try testing.expect(!c.needs().skipped and !c.needs().repeated);
    try testing.expectEqual(micros("2026-03-29T03:00"), c.next(micros("2026-03-28T10:00")));
}

test "Berlin at 02:00: the skipped hour runs late or not at all" {
    const c = comptime parse("0 2 * * *").in("Europe/Berlin");
    try testing.expect(c.needs().skipped and c.needs().repeated);
    // 2026-03-29 has no 02:00. `.run_late` reads it with the offset from
    // before the gap (+1), which is 01:00 UTC, 03:00 CEST.
    try expectTicks(c, late_both, "2026-03-27T12:00", &.{ "2026-03-28T01:00", "2026-03-29T01:00", "2026-03-30T00:00" });
    // `.skip` has no tick that night: the next is the night after, at 02:00 CEST.
    try expectTicks(c, .{ .skipped = .skip, .repeated = .both }, "2026-03-27T12:00", &.{ "2026-03-28T01:00", "2026-03-30T00:00" });
    // The year after, on 2027-03-28.
    try expectTicks(c, late_both, "2027-03-26T12:00", &.{ "2027-03-27T01:00", "2027-03-28T01:00", "2027-03-29T00:00" });
    try expectTicks(c, .{ .skipped = .skip, .repeated = .both }, "2027-03-26T12:00", &.{ "2027-03-27T01:00", "2027-03-29T00:00" });
}

test "Berlin at 02:00: the repeated hour runs on the first pass, the second or both" {
    const c = comptime parse("0 2 * * *").in("Europe/Berlin");
    // 02:00 CEST is 00:00 UTC on 2026-10-25, and 02:00 CET is 01:00 UTC.
    try expectTicks(c, skip_first, "2026-10-24T12:00", &.{ "2026-10-25T00:00", "2026-10-26T01:00" });
    try expectTicks(c, late_second, "2026-10-24T12:00", &.{ "2026-10-25T01:00", "2026-10-26T01:00" });
    try expectTicks(c, late_both, "2026-10-24T12:00", &.{ "2026-10-25T00:00", "2026-10-25T01:00", "2026-10-26T01:00" });
    // And in 2027, on the 31st.
    try expectTicks(c, late_both, "2027-10-30T12:00", &.{ "2027-10-31T00:00", "2027-10-31T01:00", "2027-11-01T01:00" });
    try expectTicks(c, skip_first, "2027-10-30T12:00", &.{ "2027-10-31T00:00", "2027-11-01T01:00" });
    try expectTicks(c, late_second, "2027-10-30T12:00", &.{ "2027-10-31T01:00", "2027-11-01T01:00" });
}

test "a list of hours that skips the window needs nothing, and one that meets it asks" {
    const nine = comptime parse("0 9,17 * * *").in("Europe/Berlin");
    try testing.expect(!nine.needs().skipped and !nine.needs().repeated);
    // `*/2` is not `*`: it is a fixed time, and it names hour 2.
    const even = comptime parse("0 */2 * * *").in("Europe/Berlin");
    try testing.expect(even.needs().skipped and even.needs().repeated);
    // A range through the window, in the month it falls in only.
    const march = comptime parse("30 1-4 * 3 *").in("Europe/Berlin");
    try testing.expect(march.needs().skipped and !march.needs().repeated);
    const october = comptime parse("30 1-4 * 10 *").in("Europe/Berlin");
    try testing.expect(!october.needs().skipped and october.needs().repeated);
}

test "a schedule with an hour field of exactly a star is an interval and declares nothing" {
    const c = comptime parse("*/15 * * * *").in("Europe/Berlin");
    try testing.expect(!c.needs().skipped and !c.needs().repeated);
    const hourly = comptime parse("30 * * * *").in("Europe/Berlin");
    try testing.expect(!hourly.needs().skipped and !hourly.needs().repeated);
}

/// Berlin's wall clock for a UTC instant, as `HH:MM`, for a test that asks
/// whether a tick fell where the clock does not go.
fn berlinClock(secs: i64) [2]i64 {
    const z = comptime tz.zone("Europe/Berlin");
    const local = secs + z.segmentAt(secs).off;
    const sod = @mod(local, 86400);
    return .{ @divFloor(sod, 3600), @divFloor(@mod(sod, 3600), 60) };
}

test "every fifteen minutes in Berlin has no tick in the skipped hour and both passes of the repeated one" {
    const c = comptime parse("*/15 * * * *").in("Europe/Berlin");
    // The clock goes from 01:59 CET to 03:00 CEST, so no tick reads 02:xx.
    var at = micros("2026-03-29T00:00");
    var ticks: usize = 0;
    var last: i64 = at;
    while (true) {
        at = c.next(at);
        if (at > micros("2026-03-29T04:00")) break;
        try testing.expect(at > last);
        last = at;
        ticks += 1;
        const clock = berlinClock(@divFloor(at, std.time.us_per_s));
        try testing.expect(clock[0] != 2);
    }
    // Four hours of UTC, a tick every quarter hour in real time.
    try testing.expectEqual(@as(usize, 16), ticks);

    // The clock goes back from 03:00 CEST to 02:00 CET: 02:xx reads twice,
    // eight ticks, in real-time order.
    at = micros("2026-10-24T22:00");
    ticks = 0;
    var in_two: usize = 0;
    last = at;
    while (true) {
        at = c.next(at);
        if (at > micros("2026-10-25T04:00")) break;
        try testing.expect(at > last);
        last = at;
        ticks += 1;
        if (berlinClock(@divFloor(at, std.time.us_per_s))[0] == 2) in_two += 1;
    }
    try testing.expectEqual(@as(usize, 24), ticks);
    try testing.expectEqual(@as(usize, 8), in_two);
}

test "a gap that is not a multiple of the period shows in real time" {
    // Lord Howe goes from 02:00 (+10:30) to 02:30 (+11:00) on 2026-10-04.
    // Every twenty minutes is :00, :20, :40 on the wall: the 02:00 and 02:20
    // ticks are in the gap, so 01:40 +10:30 (15:10 UTC) is followed by
    // 02:40 +11 (15:40 UTC), thirty minutes later rather than twenty.
    const c = comptime parse("*/20 * * * *").in("Australia/Lord_Howe");
    try expectTicks(c, .{}, "2026-10-03T14:50", &.{ "2026-10-03T15:10", "2026-10-03T15:40", "2026-10-03T16:00" });
}

test "Cairo skips midnight itself, so a midnight schedule there declares" {
    const c = comptime parse("0 0 * * *").in("Africa/Cairo");
    // Daylight time starts at 00:00 on the last Friday of April (2026-04-24)
    // and ends at 24:00 on the last Thursday of October: [00:00, 01:00) is
    // skipped, and the repeated hour is 23:00, which midnight is not.
    try testing.expect(c.needs().skipped and !c.needs().repeated);
    // Ticks are 00:00 EET (+2), 22:00 UTC the evening before. The 24th has no
    // midnight: `.run_late` runs it at 01:00 EEST, also 22:00 UTC.
    try expectTicks(c, late_both, "2026-04-22T12:00", &.{ "2026-04-22T22:00", "2026-04-23T22:00", "2026-04-24T21:00" });
    try expectTicks(c, skip_first, "2026-04-22T12:00", &.{ "2026-04-22T22:00", "2026-04-24T21:00" });
}

test "Lord Howe moves its clock by thirty minutes, and a window is thirty minutes wide" {
    // [02:00, 02:30) is skipped on 2026-10-04: minute 0 of hour 2 is in it,
    // minute 30 is not.
    const zero = comptime parse("0 2 * * *").in("Australia/Lord_Howe");
    try testing.expect(zero.needs().skipped);
    const half = comptime parse("30 2 * * *").in("Australia/Lord_Howe");
    try testing.expect(!half.needs().skipped);
    // The repeated half hour is [01:30, 02:00) on 2026-04-05.
    const late = comptime parse("45 1 * * *").in("Australia/Lord_Howe");
    try testing.expect(late.needs().repeated);
    try testing.expect(!half.needs().repeated);

    // 02:00 +10:30 is 15:30 UTC the evening before. On the night of the 4th
    // it runs late, at 02:30 +11, the same instant.
    try expectTicks(zero, late_both, "2026-10-02T12:00", &.{ "2026-10-02T15:30", "2026-10-03T15:30", "2026-10-04T15:00" });
    try expectTicks(zero, skip_first, "2026-10-02T12:00", &.{ "2026-10-02T15:30", "2026-10-04T15:00" });
}

test "a southern zone is read in summer over the new year, with its midnight switches" {
    const c = comptime parse("0 0 * * *").in("America/Santiago");
    // Daylight time starts at 24:00 on the first Saturday of September
    // (2026-09-05 -04 into 2026-09-06 -03): midnight on the 6th is skipped.
    try testing.expect(c.needs().skipped);
    try expectTicks(c, late_both, "2026-09-04T12:00", &.{ "2026-09-05T04:00", "2026-09-06T04:00", "2026-09-07T03:00" });
    try expectTicks(c, skip_first, "2026-09-04T12:00", &.{ "2026-09-05T04:00", "2026-09-07T03:00" });
    // Noon in July is -04 and in December -03.
    const noon = comptime parse("0 12 * * *").in("America/Santiago");
    try testing.expect(!noon.needs().skipped and !noon.needs().repeated);
    try testing.expectEqual(micros("2026-07-15T16:00"), noon.next(micros("2026-07-15T00:00")));
    try testing.expectEqual(micros("2026-12-15T15:00"), noon.next(micros("2026-12-15T00:00")));
}

test "Nuuk switches at a negative hour, which is the evening before" {
    // `M3.5.0/-1`: 23:00 on the Saturday, -02 into -01. The skipped
    // hour is [23:00, 24:00) that Saturday, 2026-03-28.
    const c = comptime parse("0 23 * * *").in("America/Nuuk");
    try testing.expect(c.needs().skipped and c.needs().repeated);
    try expectTicks(c, late_both, "2026-03-26T12:00", &.{ "2026-03-27T01:00", "2026-03-28T01:00", "2026-03-29T01:00", "2026-03-30T00:00" });
    try expectTicks(c, skip_first, "2026-03-26T12:00", &.{ "2026-03-27T01:00", "2026-03-28T01:00", "2026-03-30T00:00" });
    // `M10.5.0/0`: 00:00 -01 back to 23:00 -02 on the Saturday night,
    // 2026-10-24. 23:00 happens at 00:00 UTC and again at 01:00 UTC.
    try expectTicks(c, late_both, "2026-10-23T12:00", &.{ "2026-10-24T00:00", "2026-10-25T00:00", "2026-10-25T01:00" });
}

test "a tick strictly after the moment asked, however it lands" {
    const c = comptime parse("0 2 * * *").in("Europe/Berlin");
    // Asked at the tick itself, or a second before it, in each pass.
    try testing.expectEqual(micros("2026-10-25T01:00"), c.nextWith(micros("2026-10-25T00:00"), late_both));
    try testing.expectEqual(micros("2026-10-25T00:00"), c.nextWith(micros("2026-10-25T00:00") - std.time.us_per_s, late_both));
    try testing.expectEqual(micros("2026-10-26T01:00"), c.nextWith(micros("2026-10-25T01:00"), late_both));
}
