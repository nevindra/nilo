//! A time zone, read while compiling.
//!
//! `Zone` is the TZif file for one IANA zone ([RFC 9636](https://www.rfc-editor.org/rfc/rfc9636))
//! parsed into constants: the explicit transitions, the offset types they
//! switch between, and the POSIX TZ string footer that carries the rules
//! forward for ever. The file is chosen by `zone(name)` at comptime and only
//! that file is embedded, so a program pays on the binary axis for the zones it
//! names (about 150 bytes each in the vendored release) and not for the other
//! three hundred ([ADR 161](../docs/adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)).
//!
//! **Our own code, never the host's.** `mktime`, `localtime_r` and the
//! zoneinfo directory are the host's: they make the answer depend on a
//! libc and a file that a scratch image does not have, and `mktime` decides a
//! skipped or repeated wall time with `tm_isdst = -1` in a way the standard
//! leaves unspecified. `Zone.segmentAt` answers from the constants alone, so
//! `zig test job/job.zig` runs the same on every machine.
//!
//! **Segments, not a lookup of "the offset at a moment".** What a schedule
//! needs is the stretch of real time over which one offset holds, so it can
//! walk the wall clock inside it and convert each candidate by plain
//! addition. Where two segments meet, the offsets before and after say whether
//! the clock was put forward (a skipped window) or back (a repeated one),
//! and `cron.zig` applies the job's `skipped` and `repeated` to exactly those.
//!
//! **Before the cut-off.** The data is compiled with `zic -r @<cutoff>`, which
//! drops history and writes a placeholder type (`-00`, offset 0) for the time
//! before it. A schedule that asks about a moment earlier than the cut-off is
//! answered with the first real offset, because that is the rule it would
//! have run under had the history been kept, and offset 0 is never right.
//!
//! **A file whose footer disagrees with its last transition is refused.**
//! After the last explicit transition a reader must use the footer
//! (RFC 9636 section 3.3); if the footer would not have produced the offset the
//! last transition switched to, one of the two is damaged, and a schedule
//! built on it would run at the wrong hour for ever.

const std = @import("std");
const tzdata = @import("nilo_tzdata");

/// `Segment.start` of a zone's first segment, and `Segment.end` of its last.
pub const beginning: i64 = std.math.minInt(i64);
pub const forever: i64 = std.math.maxInt(i64);

/// One stretch of real time over which a zone keeps one offset. `end` is
/// exclusive, and is where the next segment starts.
pub const Segment = struct {
    start: i64,
    end: i64,
    /// Seconds east of UTC.
    off: i32,
    dst: bool,
};

/// What a footer's `Jn`, `n` or `Mm.w.d` names, in any year.
pub const Date = union(enum) {
    /// `Jn`: day 1 to 365, February 29 never counted.
    julian1: u16,
    /// `n`: day 0 to 365, February 29 counted.
    julian0: u16,
    /// `Mm.w.d`: day `d` (0 is Sunday) of week `w` of month `m`, where week 5
    /// is the last.
    month: struct { m: u8, w: u8, d: u8 },

    fn epochDay(self: Date, year: i64) i64 {
        switch (self) {
            .julian1 => |n| {
                const day: i64 = @as(i64, n) - 1 + @intFromBool(isLeap(year) and n >= 60);
                return daysFromCivil(year, 1, 1) + day;
            },
            .julian0 => |n| return daysFromCivil(year, 1, 1) + n,
            .month => |md| {
                const first = daysFromCivil(year, md.m, 1);
                // 1970-01-01 was a Thursday, and Sunday is 0.
                const weekday_of_first = @mod(first + 4, 7);
                var day = first + @mod(@as(i64, md.d) - weekday_of_first, 7) + 7 * (@as(i64, md.w) - 1);
                const length = daysInMonth(year, md.m);
                while (day >= first + length) day -= 7;
                return day;
            },
        }
    }
};

/// When a footer switches, as a day and a local time of day. Version 3 of the
/// format allows the time to run from -167 to 167 hours, which is how Jerusalem
/// says `/26`, Nuuk `/-1` and Gaza `/50`.
pub const Change = struct {
    date: Date,
    /// Seconds after local midnight, signed.
    time: i32 = 2 * 3600,
};

pub const Dst = struct {
    /// Seconds east of UTC while it is in effect.
    off: i32,
    start: Change,
    end: Change,
};

/// The POSIX TZ string at the end of a TZif file: what holds after the last
/// explicit transition, for ever.
pub const Rule = struct {
    /// Seconds east of UTC outside daylight saving. POSIX writes it the other
    /// way round (`CET-1`), which `parseRule` undoes.
    std_off: i32,
    dst: ?Dst = null,

    const Event = struct { at: i64, to_dst: bool };

    /// The two switches of one year, in UTC. The start is read in standard
    /// time and the end in daylight time, which is the clock each was
    /// written against.
    fn year(self: Rule, y: i64) [2]Event {
        const d = self.dst.?;
        return .{
            .{ .at = d.start.date.epochDay(y) * 86400 + d.start.time - self.std_off, .to_dst = true },
            .{ .at = d.end.date.epochDay(y) * 86400 + d.end.time - d.off, .to_dst = false },
        };
    }

    /// The stretch around `t`. Only for a rule with daylight time.
    ///
    /// Three years of switches, sorted: a switch written as `/167` or `/-1`
    /// can fall in the next or the last year, so the year `t` is in alone
    /// would miss the one that applies.
    pub fn segmentAt(self: Rule, t: i64) Segment {
        const d = self.dst.?;
        const y = civilFromDays(@divFloor(t, 86400)).year;
        var events: [6]Event = undefined;
        for (0..3) |i| {
            const two = self.year(y - 1 + @as(i64, @intCast(i)));
            events[2 * i] = two[0];
            events[2 * i + 1] = two[1];
        }
        // Insertion sort: six items, almost sorted already.
        for (1..events.len) |i| {
            var j = i;
            while (j > 0 and events[j - 1].at > events[j].at) : (j -= 1) std.mem.swap(Event, &events[j - 1], &events[j]);
        }
        var last: ?usize = null;
        for (events, 0..) |e, i| {
            if (e.at <= t) last = i else break;
        }
        const at = last orelse return .{ .start = beginning, .end = events[0].at, .off = if (events[0].to_dst) self.std_off else d.off, .dst = !events[0].to_dst };
        const to_dst = events[at].to_dst;
        return .{
            .start = events[at].at,
            .end = if (at + 1 < events.len) events[at + 1].at else forever,
            .off = if (to_dst) d.off else self.std_off,
            .dst = to_dst,
        };
    }
};

pub const Type = struct {
    /// Seconds east of UTC.
    utoff: i32,
    dst: bool,
    /// `-00`, the type `zic -r` writes for a time before its cut-off.
    placeholder: bool,
};

/// One zone. Every slice points at comptime constants; `segmentAt` reads
/// nothing else.
pub const Zone = struct {
    /// The name the schedule was given.
    name: []const u8,
    /// Transition instants in Unix seconds, ascending.
    at: []const i64,
    /// For each transition, the index in `types` that holds from it on.
    kind: []const u8,
    types: []const Type,
    /// The type in effect before the first transition.
    before: u8,
    /// The footer, null when the file has none.
    rule: ?Rule,

    /// The stretch of real time around `t` over which one offset holds.
    pub fn segmentAt(self: *const Zone, t: i64) Segment {
        const n = self.at.len;
        if (n == 0) return self.tail(t, beginning);
        if (t < self.at[0]) {
            const ty = self.types[self.firstReal()];
            return .{ .start = beginning, .end = self.at[0], .off = ty.utoff, .dst = ty.dst };
        }
        // The last transition at or before `t`.
        var lo: usize = 0;
        var hi: usize = n;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.at[mid] <= t) lo = mid else hi = mid;
        }
        if (lo + 1 < n) {
            const ty = self.types[self.kind[lo]];
            return .{ .start = self.at[lo], .end = self.at[lo + 1], .off = ty.utoff, .dst = ty.dst };
        }
        return self.tail(t, self.at[lo]);
    }

    /// What holds after the last explicit transition (at `floor`): the footer.
    fn tail(self: *const Zone, t: i64, floor: i64) Segment {
        if (self.rule) |rule| {
            if (rule.dst != null) {
                var s = rule.segmentAt(t);
                s.start = @max(s.start, floor);
                return s;
            }
            return .{ .start = floor, .end = forever, .off = rule.std_off, .dst = false };
        }
        const ty = self.types[if (self.kind.len > 0) self.kind[self.kind.len - 1] else self.before];
        return .{ .start = floor, .end = forever, .off = ty.utoff, .dst = ty.dst };
    }

    /// The type a moment before the first transition is read with.
    fn firstReal(self: *const Zone) u8 {
        if (self.types[self.before].placeholder and self.kind.len > 0) return self.kind[0];
        return self.before;
    }
};

// -- what a schedule's wall times can meet --------------------------------

/// Whether a fixed-time schedule can land in a window the clock skips or
/// repeats, which is what makes it declare `skipped` and `repeated`.
pub const Needs = struct {
    skipped: bool = false,
    repeated: bool = false,
};

/// The windows of `zone` after the data's cut-off: the explicit transitions
/// after it, and the footer's switches for the nine years after the last of
/// those (a window sits in the same month every year, and nine years cover
/// every pairing of a leap year with a weekday rule).
///
/// A window is a stretch of wall-clock minutes: for a clock put forward from
/// `before` to `after` it is `[t + before, t + after)` and no time exists
/// there; for one put back it is `[t + after, t + before)` and each time
/// happens twice. The schedule *meets* it when some minute in it is in its
/// minute, hour and month sets. The day fields are left out on purpose: a
/// weekday rule decides which year a window falls on a given day, and
/// asking would make a declaration appear and vanish with the calendar.
/// Transitions that change no offset (Canada in 2026) are neither window.
pub fn needs(comptime z: *const Zone, comptime minute: u60, comptime hour: u24, comptime month: u13) Needs {
    return comptime blk: {
        @setEvalBranchQuota(1_000_000);
        var out: Needs = .{};
        var last_explicit: i64 = tzdata.cutoff;
        for (z.at, 0..) |t, i| {
            if (t > last_explicit) last_explicit = t;
            if (t <= tzdata.cutoff) continue;
            const before = if (i == 0) z.types[z.before].utoff else z.types[z.kind[i - 1]].utoff;
            const after = z.types[z.kind[i]].utoff;
            window(&out, t, before, after, minute, hour, month);
        }
        if (z.rule) |rule| {
            if (rule.dst) |d| {
                const from = civilFromDays(@divFloor(last_explicit, 86400)).year;
                var y = from;
                while (y < from + 9) : (y += 1) {
                    for (rule.year(y)) |e| {
                        if (e.at <= last_explicit) continue;
                        const before = if (e.to_dst) rule.std_off else d.off;
                        const after = if (e.to_dst) d.off else rule.std_off;
                        window(&out, e.at, before, after, minute, hour, month);
                    }
                }
            }
        }
        break :blk out;
    };
}

fn window(out: *Needs, t: i64, before: i32, after: i32, minute: u60, hour: u24, month: u13) void {
    if (after == before) return;
    const skipped = after > before;
    const lo = t + @min(before, after);
    const hi = t + @max(before, after);
    if (meets(lo, hi, minute, hour, month)) {
        if (skipped) out.skipped = true else out.repeated = true;
    }
}

fn meets(lo: i64, hi: i64, minute: u60, hour: u24, month: u13) bool {
    // A window of more than two days is a date line moving, which no
    // schedule is written around: it meets everything.
    if (hi - lo > 2 * 86400) return true;
    var w = lo - @mod(lo, 60);
    while (w < hi) : (w += 60) {
        if (w < lo) continue;
        const civil = civilFromDays(@divFloor(w, 86400));
        const sod: u32 = @intCast(@mod(w, 86400));
        const m: u6 = @intCast(sod / 60 % 60);
        const h: u5 = @intCast(sod / 3600);
        if ((minute >> m) & 1 == 1 and (hour >> h) & 1 == 1 and (month >> @intCast(civil.month)) & 1 == 1) return true;
    }
    return false;
}

// -- the calendar -----------------------------------------------------------

fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn daysInMonth(y: i64, m: i64) i64 {
    return switch (m) {
        2 => if (isLeap(y)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Days since 1970-01-01 of a civil date (Hinnant's `days_from_civil`).
pub fn daysFromCivil(y: i64, m: i64, d: i64) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: i64, day: i64 };

/// The civil date of a day count since 1970-01-01 (Hinnant's `civil_from_days`).
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = yoe + era * 400 + @intFromBool(m <= 2),
        .month = m,
        .day = doy - @divFloor(153 * mp + 2, 5) + 1,
    };
}

// -- reading the file -------------------------------------------------------

pub const ParseError = error{
    NotTzif,
    /// Version 1 has 32-bit times only, and no footer.
    UnsupportedVersion,
    Truncated,
    BadTypeIndex,
    BadFooter,
    FooterDisagrees,
};

fn be(comptime T: type, bytes: []const u8, at: usize) ParseError!T {
    const n = @sizeOf(T);
    if (at + n > bytes.len) return error.Truncated;
    return std.mem.readInt(T, bytes[at..][0..n], .big);
}

/// Parse one TZif file's 64-bit block and footer. Comptime only, so every
/// slice in the result is a constant and a bad file is a compile error.
pub fn parse(comptime name: []const u8, comptime bytes: []const u8) ParseError!Zone {
    comptime {
        @setEvalBranchQuota(2_000_000);
        if (bytes.len < 44 or !std.mem.eql(u8, bytes[0..4], "TZif")) return error.NotTzif;
        if (bytes[4] < '2') return error.UnsupportedVersion;

        // The version 1 block comes first, 32-bit and of no use; skip it.
        const v1_counts = try counts(bytes, 0);
        const v1_len = v1_counts.timecnt * 4 + v1_counts.timecnt + v1_counts.typecnt * 6 +
            v1_counts.charcnt + v1_counts.leapcnt * 8 + v1_counts.isstdcnt + v1_counts.isutcnt;
        const head = 44 + v1_len;
        if (head + 44 > bytes.len or !std.mem.eql(u8, bytes[head..][0..4], "TZif")) return error.Truncated;

        const c = try counts(bytes, head);
        var p = head + 44;
        const times_at = p;
        p += c.timecnt * 8;
        const kinds_at = p;
        p += c.timecnt;
        const types_at = p;
        p += c.typecnt * 6;
        const chars_at = p;
        p += c.charcnt + c.leapcnt * 12 + c.isstdcnt + c.isutcnt;
        if (p > bytes.len) return error.Truncated;
        if (c.typecnt == 0) return error.BadTypeIndex;

        var at: [c.timecnt]i64 = undefined;
        var kind: [c.timecnt]u8 = undefined;
        for (0..c.timecnt) |i| {
            at[i] = try be(i64, bytes, times_at + i * 8);
            kind[i] = bytes[kinds_at + i];
            if (kind[i] >= c.typecnt) return error.BadTypeIndex;
        }
        var types: [c.typecnt]Type = undefined;
        for (0..c.typecnt) |i| {
            const o = types_at + i * 6;
            const abbr = bytes[o + 5];
            const chars = bytes[chars_at..][0..c.charcnt];
            types[i] = .{
                .utoff = try be(i32, bytes, o),
                .dst = bytes[o + 4] != 0,
                .placeholder = abbr + 3 <= chars.len and std.mem.eql(u8, chars[abbr..][0..3], "-00"),
            };
        }

        // The footer is `\n<TZ string>\n`.
        if (p >= bytes.len or bytes[p] != '\n') return error.BadFooter;
        const end = std.mem.indexOfScalarPos(u8, bytes, p + 1, '\n') orelse return error.BadFooter;
        const footer = bytes[p + 1 .. end];

        const final_at = at;
        const final_kind = kind;
        const final_types = types;
        const result: Zone = .{
            .name = name,
            .at = &final_at,
            .kind = &final_kind,
            .types = &final_types,
            .before = 0,
            .rule = if (footer.len == 0) null else try parseRule(footer),
        };

        // The footer takes over after the last transition, so the offset it
        // gives there has to be the one that transition switched to.
        if (c.timecnt > 0) {
            if (result.rule) |rule| {
                const last = at[c.timecnt - 1];
                const want = types[kind[c.timecnt - 1]].utoff;
                const got = if (rule.dst != null) rule.segmentAt(last).off else rule.std_off;
                if (want != got) return error.FooterDisagrees;
            }
        }
        return result;
    }
}

const Counts = struct { isutcnt: usize, isstdcnt: usize, leapcnt: usize, timecnt: usize, typecnt: usize, charcnt: usize };

fn counts(bytes: []const u8, at: usize) ParseError!Counts {
    return .{
        .isutcnt = try be(u32, bytes, at + 20),
        .isstdcnt = try be(u32, bytes, at + 24),
        .leapcnt = try be(u32, bytes, at + 28),
        .timecnt = try be(u32, bytes, at + 32),
        .typecnt = try be(u32, bytes, at + 36),
        .charcnt = try be(u32, bytes, at + 40),
    };
}

/// `std offset [dst [offset] ,start[/time],end[/time]]`, where a name is
/// letters or anything between `<` and `>`.
fn parseRule(comptime s: []const u8) ParseError!Rule {
    comptime {
        var i: usize = 0;
        try skipName(s, &i);
        const std_off = -try parseTime(s, &i);
        if (i == s.len) return .{ .std_off = std_off };

        try skipName(s, &i);
        var dst_off = std_off + 3600;
        if (i < s.len and s[i] != ',') dst_off = -try parseTime(s, &i);
        // A name with no rules would use the C library's default ones,
        // which a TZif file never relies on.
        if (i >= s.len or s[i] != ',') return error.BadFooter;
        i += 1;
        const start = try parseChange(s, &i);
        if (i >= s.len or s[i] != ',') return error.BadFooter;
        i += 1;
        const end = try parseChange(s, &i);
        if (i != s.len) return error.BadFooter;
        return .{ .std_off = std_off, .dst = .{ .off = dst_off, .start = start, .end = end } };
    }
}

fn skipName(s: []const u8, i: *usize) ParseError!void {
    if (i.* < s.len and s[i.*] == '<') {
        const close = std.mem.indexOfScalarPos(u8, s, i.*, '>') orelse return error.BadFooter;
        i.* = close + 1;
        return;
    }
    const from = i.*;
    while (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) i.* += 1;
    if (i.* - from < 3) return error.BadFooter;
}

/// `[+-]hh[:mm[:ss]]`, hours up to 167 (version 3 of the format), in seconds.
fn parseTime(s: []const u8, i: *usize) ParseError!i32 {
    var sign: i32 = 1;
    if (i.* < s.len and (s[i.*] == '+' or s[i.*] == '-')) {
        if (s[i.*] == '-') sign = -1;
        i.* += 1;
    }
    var total: i32 = 0;
    var unit: i32 = 3600;
    var field: usize = 0;
    while (field < 3) : (field += 1) {
        const from = i.*;
        var v: i32 = 0;
        while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) v = v * 10 + (s[i.*] - '0');
        if (i.* == from or i.* - from > 3) return error.BadFooter;
        total += v * unit;
        unit = @divTrunc(unit, 60);
        if (i.* < s.len and s[i.*] == ':' and field < 2) i.* += 1 else break;
    }
    return sign * total;
}

fn parseNumber(s: []const u8, i: *usize) ParseError!u16 {
    const from = i.*;
    var v: u16 = 0;
    while (i.* < s.len and std.ascii.isDigit(s[i.*])) : (i.* += 1) v = v * 10 + (s[i.*] - '0');
    if (i.* == from or i.* - from > 3) return error.BadFooter;
    return v;
}

fn parseChange(s: []const u8, i: *usize) ParseError!Change {
    var date: Date = undefined;
    if (i.* < s.len and s[i.*] == 'M') {
        i.* += 1;
        const m = try parseNumber(s, i);
        if (i.* >= s.len or s[i.*] != '.') return error.BadFooter;
        i.* += 1;
        const w = try parseNumber(s, i);
        if (i.* >= s.len or s[i.*] != '.') return error.BadFooter;
        i.* += 1;
        const d = try parseNumber(s, i);
        if (m < 1 or m > 12 or w < 1 or w > 5 or d > 6) return error.BadFooter;
        date = .{ .month = .{ .m = @intCast(m), .w = @intCast(w), .d = @intCast(d) } };
    } else if (i.* < s.len and s[i.*] == 'J') {
        i.* += 1;
        const n = try parseNumber(s, i);
        if (n < 1 or n > 365) return error.BadFooter;
        date = .{ .julian1 = n };
    } else {
        const n = try parseNumber(s, i);
        if (n > 365) return error.BadFooter;
        date = .{ .julian0 = n };
    }
    var time: i32 = 2 * 3600;
    if (i.* < s.len and s[i.*] == '/') {
        i.* += 1;
        time = try parseTime(s, i);
    }
    return .{ .date = date, .time = time };
}

// -- the one a schedule names ---------------------------------------------

/// The zone called `name`, or a compile error naming it. Zone names are the
/// IANA spellings and are case sensitive, as they are on every system that
/// has them; a name that only differs in case is offered back.
pub fn zone(comptime name: []const u8) *const Zone {
    return comptime blk: {
        const bytes = tzdata.lookup(name) orelse unknown(name);
        const z = parse(name, bytes) catch |err| @compileError(
            "nilo: the time zone data for \"" ++ name ++ "\" is damaged (" ++ @errorName(err) ++ ").\n" ++
                "  It is release " ++ tzdata.version ++ " of the IANA database, and `job/tzdata/refresh.py` writes it again.",
        );
        break :blk &z;
    };
}

fn unknown(comptime name: []const u8) noreturn {
    @setEvalBranchQuota(100_000);
    comptime {
        var hint: []const u8 = "";
        for (tzdata.names) |known| {
            if (std.ascii.eqlIgnoreCase(known, name)) {
                hint = "\n  Zone names are case sensitive: did you mean \"" ++ known ++ "\"?";
                break;
            }
        }
        @compileError(
            "nilo: the time zone \"" ++ name ++ "\" is not one nilo_job has data for." ++ hint ++
                "\n  A zone is spelled as the IANA database does, `Area/City` (\"Asia/Jakarta\", \"Europe/Berlin\", \"America/Argentina/Buenos_Aires\"), " ++
                "and these are release " ++ tzdata.version ++ ".",
        );
    }
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

/// Seconds since the epoch of a UTC moment, for a readable expectation.
fn utc(comptime y: i64, comptime mo: i64, comptime d: i64, comptime h: i64, comptime mi: i64) i64 {
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60;
}

test "the calendar round-trips and knows the epoch" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 20_454), daysFromCivil(2026, 1, 1));
    const c = civilFromDays(daysFromCivil(2028, 2, 29));
    try testing.expectEqual(@as(i64, 2028), c.year);
    try testing.expectEqual(@as(i64, 2), c.month);
    try testing.expectEqual(@as(i64, 29), c.day);
}

test "a footer is read for its names, offsets and rules" {
    const berlin = comptime try parseRule("CET-1CEST,M3.5.0,M10.5.0/3");
    try testing.expectEqual(@as(i32, 3600), berlin.std_off);
    try testing.expectEqual(@as(i32, 7200), berlin.dst.?.off);
    try testing.expectEqual(@as(i32, 7200), berlin.dst.?.start.time);
    try testing.expectEqual(@as(i32, 10_800), berlin.dst.?.end.time);

    // A quoted name, a fixed zone.
    const jakarta = comptime try parseRule("WIB-7");
    try testing.expectEqual(@as(i32, 7 * 3600), jakarta.std_off);
    try testing.expect(jakarta.dst == null);
    const west = comptime try parseRule("<-03>3");
    try testing.expectEqual(@as(i32, -3 * 3600), west.std_off);

    // Version 3 hours: past 24, and negative.
    const jerusalem = comptime try parseRule("IST-2IDT,M3.4.4/26,M10.5.0");
    try testing.expectEqual(@as(i32, 26 * 3600), jerusalem.dst.?.start.time);
    const nuuk = comptime try parseRule("<-02>2<-01>,M3.5.0/-1,M10.5.0/0");
    try testing.expectEqual(@as(i32, -3600), nuuk.dst.?.start.time);
    const gaza = comptime try parseRule("EET-2EEST,M3.4.4/50,M10.4.4/50");
    try testing.expectEqual(@as(i32, 50 * 3600), gaza.dst.?.end.time);

    // Day-of-year dates, and a minutes-and-seconds offset.
    const julian = comptime try parseRule("AAA-5:30:15BBB,J60/2,300");
    try testing.expectEqual(@as(i32, 5 * 3600 + 30 * 60 + 15), julian.std_off);
    try testing.expect(julian.dst.?.start.date == .julian1);
    try testing.expect(julian.dst.?.end.date == .julian0);

    try testing.expectError(error.BadFooter, comptime parseRule("CET-1CEST"));
    try testing.expectError(error.BadFooter, comptime parseRule("CET-1CEST,M13.5.0,M10.5.0"));
}

test "a Mm.w.d date finds the last Sunday, and Jn skips the leap day" {
    // Last Sunday of March 2026 is the 29th, of 2027 the 28th.
    const march = Date{ .month = .{ .m = 3, .w = 5, .d = 0 } };
    try testing.expectEqual(daysFromCivil(2026, 3, 29), march.epochDay(2026));
    try testing.expectEqual(daysFromCivil(2027, 3, 28), march.epochDay(2027));
    // The fourth Thursday of March 2026 is the 26th.
    const fourth = Date{ .month = .{ .m = 3, .w = 4, .d = 4 } };
    try testing.expectEqual(daysFromCivil(2026, 3, 26), fourth.epochDay(2026));
    // J60 is March 1 in every year, leap or not; day 60 counted from 0 is not.
    const j60 = Date{ .julian1 = 60 };
    try testing.expectEqual(daysFromCivil(2027, 3, 1), j60.epochDay(2027));
    try testing.expectEqual(daysFromCivil(2028, 3, 1), j60.epochDay(2028));
    const n60 = Date{ .julian0 = 60 };
    try testing.expectEqual(daysFromCivil(2028, 3, 1), n60.epochDay(2028));
    try testing.expectEqual(daysFromCivil(2027, 3, 2), n60.epochDay(2027));
}

test "Berlin switches on the last Sundays of March and October at 01:00 UTC" {
    const berlin = comptime zone("Europe/Berlin");
    const winter = berlin.segmentAt(utc(2026, 2, 1, 12, 0));
    try testing.expectEqual(@as(i32, 3600), winter.off);
    try testing.expect(!winter.dst);
    try testing.expectEqual(utc(2026, 3, 29, 1, 0), winter.end);

    const summer = berlin.segmentAt(winter.end);
    try testing.expectEqual(@as(i32, 7200), summer.off);
    try testing.expect(summer.dst);
    try testing.expectEqual(winter.end, summer.start);
    try testing.expectEqual(utc(2026, 10, 25, 1, 0), summer.end);

    const again = berlin.segmentAt(summer.end);
    try testing.expectEqual(@as(i32, 3600), again.off);
    try testing.expectEqual(utc(2027, 3, 28, 1, 0), again.end);
}

test "a moment before the cut-off is read with the first real offset" {
    const berlin = comptime zone("Europe/Berlin");
    const s = berlin.segmentAt(utc(2025, 7, 1, 0, 0));
    try testing.expectEqual(@as(i32, 3600), s.off);
    try testing.expectEqual(beginning, s.start);
}

test "Jakarta has one segment for ever" {
    const jakarta = comptime zone("Asia/Jakarta");
    const s = jakarta.segmentAt(utc(2026, 6, 1, 0, 0));
    try testing.expectEqual(@as(i32, 7 * 3600), s.off);
    try testing.expectEqual(forever, s.end);
}

test "a southern zone is on daylight time over the new year" {
    const santiago = comptime zone("America/Santiago");
    try testing.expect(santiago.segmentAt(utc(2026, 12, 25, 12, 0)).dst);
    try testing.expect(!santiago.segmentAt(utc(2026, 7, 1, 12, 0)).dst);
    // Chile keeps its switches at 24:00 on a Saturday night (`/24`), which is
    // 03:00 UTC in the autumn and 04:00 in the spring.
    const winter = santiago.segmentAt(utc(2026, 7, 1, 12, 0));
    try testing.expectEqual(@as(i32, -4 * 3600), winter.off);
    try testing.expectEqual(utc(2026, 9, 6, 4, 0), winter.end);
}

test "Nuuk switches an hour before midnight local, which is an hour before 01:00 UTC" {
    const nuuk = comptime zone("America/Nuuk");
    const s = nuuk.segmentAt(utc(2026, 8, 1, 0, 0));
    try testing.expect(s.dst);
    // `/-1` on the last Saturday of October reads 23:00 on the Friday in
    // daylight time (-1h), 00:00 UTC.
    try testing.expectEqual(@as(i32, -3600), s.off);
}

test "every vendored zone parses and agrees with its own footer" {
    @setEvalBranchQuota(100_000_000);
    inline for (tzdata.all) |entry| {
        const z = comptime parse(entry.name, entry.bytes) catch |err| @compileError(entry.name ++ ": " ++ @errorName(err));
        // And answers something sensible two years out.
        const s = z.segmentAt(utc(2028, 6, 15, 12, 0));
        try testing.expect(s.off >= -12 * 3600 and s.off <= 14 * 3600);
    }
}

test "a file whose footer disagrees with its last transition is refused" {
    const berlin = comptime tzdata.lookup("Europe/Berlin").?;
    // Berlin's last transition is to CET (+1h); a footer that says +2h for
    // standard time cannot be right.
    const tampered = comptime blk: {
        var copy: [berlin.len]u8 = berlin[0..berlin.len].*;
        const at = std.mem.indexOf(u8, &copy, "CET-1CEST").?;
        copy[at + 4] = '2'; // CET-2CEST
        break :blk copy;
    };
    try testing.expectError(error.FooterDisagrees, comptime parse("Europe/Berlin", &tampered));
    try testing.expectError(error.NotTzif, comptime parse("x", "not a zone file at all, no, none of it"));
    try testing.expectError(error.Truncated, comptime parse("x", berlin[0..60]));
}

test "a window is a skipped or repeated hour only when the offset changes" {
    const berlin = comptime zone("Europe/Berlin");
    const all_minutes: u60 = (1 << 60) - 1;
    const all_months: u13 = ((1 << 13) - 1) & ~@as(u13, 1);
    // 02:00 meets the hour the clocks skip in March and repeat in October.
    const two = comptime needs(berlin, 1, 1 << 2, all_months);
    try testing.expect(two.skipped and two.repeated);
    // 03:00 does not: the skipped hour is [02:00, 03:00).
    const three = comptime needs(berlin, 1, 1 << 3, all_months);
    try testing.expect(!three.skipped and !three.repeated);
    // The month matters: 02:00 in July never meets a window.
    const july = comptime needs(berlin, 1, 1 << 2, 1 << 7);
    try testing.expect(!july.skipped and !july.repeated);
    // Only March has a skipped hour, only October a repeated one.
    const march = comptime needs(berlin, all_minutes, 1 << 2, 1 << 3);
    try testing.expect(march.skipped and !march.repeated);
    const october = comptime needs(berlin, all_minutes, 1 << 2, 1 << 10);
    try testing.expect(!october.skipped and october.repeated);
    // Jakarta has none.
    const jakarta = comptime zone("Asia/Jakarta");
    const j = comptime needs(jakarta, all_minutes, (1 << 24) - 1, all_months);
    try testing.expect(!j.skipped and !j.repeated);
}

test "a transition that changes the abbreviation and not the offset is no window" {
    // Daylight time becoming standard time of the same offset, as Canada's
    // November 2026 switch did: written by hand so a later release of the
    // data cannot move the expectation.
    const same: Zone = .{
        .name = "Test/Same",
        .at = &.{tzdata.cutoff + 1000},
        .kind = &.{1},
        .types = &.{
            .{ .utoff = -18000, .dst = true, .placeholder = false },
            .{ .utoff = -18000, .dst = false, .placeholder = false },
        },
        .before = 0,
        .rule = null,
    };
    const none = comptime needs(&same, (1 << 60) - 1, (1 << 24) - 1, ((1 << 13) - 1) & ~@as(u13, 1));
    try testing.expect(!none.skipped and !none.repeated);
    // The same transition with an hour added is a skipped window.
    const forward: Zone = .{
        .name = "Test/Forward",
        .at = &.{tzdata.cutoff + 1000},
        .kind = &.{1},
        .types = &.{
            .{ .utoff = -21600, .dst = false, .placeholder = false },
            .{ .utoff = -18000, .dst = true, .placeholder = false },
        },
        .before = 0,
        .rule = null,
    };
    const skipped = comptime needs(&forward, (1 << 60) - 1, (1 << 24) - 1, ((1 << 13) - 1) & ~@as(u13, 1));
    try testing.expect(skipped.skipped and !skipped.repeated);
}
