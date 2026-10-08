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
//! **UTC, and only UTC.** A time zone is a table of rules that changes twice
//! a year and a dependency to carry it, and the ordinary schedule — clean up
//! every ten minutes, report nightly — does not care which wall clock it is
//! read against. A caller who needs 03:00 Jakarta writes `0 20 * * *` and
//! says so in a comment. `docs/todo.md` carries the gap.
//!
//! When both the day-of-month and the day-of-week fields are restricted, a
//! day matches if **either** does, which is what every cron since Vixie has
//! done and what `0 0 1,15 * mon` has always meant.

const std = @import("std");

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

    /// What `next` answers when no minute ever comes: the largest moment
    /// there is, a row due at which is never claimed. `parse` refuses the
    /// dates that cause it, so a schedule written as text cannot get here;
    /// it is what a `Cron` built by hand, or an AND of day and weekday no
    /// calendar satisfies, answers instead of a worker that never returns.
    pub const never: i64 = std.math.maxInt(i64);

    /// The first minute strictly after `after_micros` that this admits, in
    /// microseconds since the epoch — the unit `nilo.nowMicros` answers in.
    /// `never` when there is none.
    ///
    /// Strictly after, so a schedule asked "what comes after the tick that
    /// just ran" never answers the tick that just ran.
    pub fn next(self: Cron, after_micros: i64) i64 {
        const after_secs: u64 = @intCast(@max(after_micros, 0) / std.time.us_per_s);
        // The next whole minute after `after`, which is where a schedule that
        // fires on the minute could first fire.
        var t: u64 = (after_secs / 60 + 1) * 60;

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

            return @intCast(t * std.time.us_per_s);
        }
        return never;
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
