//! A moment and a calendar day, in the layer under every other (ADR 036, ADR 057).
//!
//! These two lived in `nilo_sql`, which exists only in a build with `.sql =
//! true` and so fetches both database drivers. A service with a date in a
//! JSON body had to turn that on or carry text. They are here because two
//! layers need them: the App layer reads and writes them in a body, a query
//! and a path, and `nilo_sql` stores them. `nilo_sql` re-exports both, so a
//! Row still says `sql.Timestamp`.
//!
//! The line they hold is the one they always held: **a type here carries a
//! value and knows how to write itself. It does not calculate.** Time zones
//! and calendar arithmetic are a permanent obligation (`Asia/Jakarta` is a
//! history, not an offset), and nothing needed to read a column or a body
//! needs them. `Timestamp` is deliberately open: an `i64` whose unit is
//! stated, a floor for anyone who wants arithmetic to build on.
//!
//! **Nothing here names a database.** The column a type belongs in
//! (`timestamptz`, `date`), the Postgres wire's count from 2000 and the
//! SQLite storage are `nilo_sql`'s, answered by `declaredColumn` and its two
//! Wires, because a marker on a Core type that says "Postgres" is the easy
//! way to break the downward rule (ADR 038). What is here is dialect-free:
//! the representation, RFC 3339 and ISO 8601 text both ways, and
//! `nilo_openapi`, which says `format: date-time` and `format: date`.

const std = @import("std");
const clock = @import("clock.zig");

/// A moment, as microseconds since 1970-01-01 UTC — the same integer Postgres
/// keeps in a `timestamptz`, so reading one is a copy rather than a
/// conversion.
///
/// On SQLite the column is an `INTEGER` of those microseconds (ADR 067), and
/// SQLite's date functions read a bare number as a Julian day or, with
/// `'unixepoch'`, as seconds: `strftime('%m', col)` is NULL. Divide by
/// 1,000,000 and say `'unixepoch'`.
///
/// Writes itself as RFC 3339 in UTC, which is what a JSON body wants and what
/// `format: date-time` in the generated document promises.
pub const Timestamp = struct {
    /// Microseconds since the epoch. Postgres counts from 2000-01-01 on the
    /// wire; the Wire converts once, on the way in, so nothing above this
    /// line has to know that.
    micros: i64,

    /// Bare, as `Uuid`'s is, because `core.Timestamp`, `sql.Timestamp` and
    /// `nilo.Timestamp` are all real import lines for one declaration and
    /// none of them is the reader's (ADR 074, ADR 148).
    pub const nilo_type_name = "Timestamp";

    /// What `jsonStringify` below actually sends, so that a document generated
    /// from a Row carrying one describes a string rather than the `micros`
    /// field nobody sees (ADR 016). Plain data, so no module has to import
    /// `nilo_http` to say it.
    pub const nilo_openapi = .{ .type = "string", .format = "date-time" };

    /// Now, which this could not answer until Core had a clock (ADR 041).
    /// A copy rather than a conversion: `nowMicros` counts in the unit this
    /// column stores.
    ///
    /// It is a wall clock, so it is what a `created_at` wants and what
    /// nothing measuring a duration should use — two rows written a second
    /// apart can carry timestamps in either order if an operator moves the
    /// clock between them.
    pub fn now() Timestamp {
        return .{ .micros = clock.nowMicros() };
    }

    pub fn fromSeconds(secs: i64) Timestamp {
        return .{ .micros = secs * std.time.us_per_s };
    }

    pub fn seconds(self: Timestamp) i64 {
        return @divFloor(self.micros, std.time.us_per_s);
    }

    /// RFC 3339 in UTC with six fractional digits, always:
    /// `2026-08-16T09:30:00.700000Z`. **Whole seconds were the old shape and
    /// they lost data**: a keyset cursor is a timestamp this server printed one
    /// request ago, and one that dropped its microseconds compared as earlier
    /// than the row it came from, so the next page repeated or skipped rows
    /// (ADR 127). Six digits every time, rather than only when there is a
    /// fraction, because a body that sometimes carries them and sometimes does
    /// not is worse to consume than one that always does, and the column has
    /// exactly that resolution.
    ///
    /// **The range is 0001-01-01 to 9999-12-31, the four digits RFC 3339
    /// spells, and a moment outside it is `error.OutOfRange`** — never `null`
    /// and never text `nilo_parse` refuses. A moment before 1970 is the
    /// ordinary case (a date of birth at midnight), so the walk is
    /// `Date.civilFromDays`, which is good for negative days, and not
    /// `std.time.epoch`, which stops at the epoch. Year 0 is refused because
    /// Postgres has none (ADR 127).
    pub fn writeRfc3339(self: Timestamp, w: *std.Io.Writer) !void {
        if (self.micros < first_micros or self.micros > last_micros) return error.OutOfRange;

        const secs = self.seconds();
        const days = @divFloor(secs, std.time.s_per_day);
        const into_day: u32 = @intCast(secs - days * std.time.s_per_day);
        const civil = Date.civilFromDays(days);

        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z", .{
            @as(u16, @intCast(civil.year)),
            civil.month,
            civil.day,
            into_day / 3600,
            into_day / 60 % 60,
            into_day % 60,
            @as(u32, @intCast(@mod(self.micros, std.time.us_per_s))),
        });
    }

    /// 0001-01-01T00:00:00Z and 9999-12-31T23:59:59.999999Z as microseconds:
    /// the ends of what `writeRfc3339` prints and `nilo_parse` reads.
    const first_micros: i64 = -62_135_596_800_000_000;
    const last_micros: i64 = 253_402_300_799_999_999;

    /// The other half of `writeRfc3339`, so that a value this server printed
    /// can be handed back to it
    /// ([ADR 127](../docs/adr/127-what-a-server-prints-it-can-read.md)).
    ///
    /// **The round trip is the property.** Every keyset cursor is a timestamp
    /// the same server wrote one request ago, and a parser that disagrees
    /// with the writer by a microsecond pages past rows or repeats them
    /// without failing — which is why the test below asserts the pair rather
    /// than each half.
    ///
    /// Wider than what the writer prints, on purpose: an offset (`+07:00`)
    /// and fractional seconds both arrive from clients that were never told
    /// what nilo emits, and both have one correct reading. **A time with no
    /// zone at all is refused**, because there is no correct reading of it —
    /// guessing UTC is how a cursor moves by seven hours at a customer who
    /// runs their browser in Jakarta.
    ///
    /// `nilo_parse` rather than a method with a name of its own: the
    /// declaration is what makes a type a path param and, since ADR 113, a
    /// query field. Nothing here imports `nilo_http` to say so (ADR 038).
    pub fn nilo_parse(text: []const u8) ?Timestamp {
        // `2026-10-01T09:30:00Z` is the shortest thing this accepts, and
        // every index below is inside it.
        if (text.len < 20) return null;
        if (text[4] != '-' or text[7] != '-') return null;
        if (text[10] != 'T' and text[10] != 't') return null;
        if (text[13] != ':' or text[16] != ':') return null;

        const year = fixed(i64, text[0..4]) orelse return null;
        const month = fixed(u8, text[5..7]) orelse return null;
        const day = fixed(u8, text[8..10]) orelse return null;
        const hour = fixed(u8, text[11..13]) orelse return null;
        const minute = fixed(u8, text[14..16]) orelse return null;
        const second = fixed(u8, text[17..19]) orelse return null;

        // Year 0 does not exist in Postgres, which refuses `0000-01-01` on
        // insert; reading it here would mint a value the database cannot hold.
        if (year < 1) return null;
        if (month < 1 or month > 12) return null;
        if (day < 1 or day > daysInMonth(year, month)) return null;
        // 59 rather than RFC 3339's 60: a leap second has no microsecond to
        // come back to, so accepting one would break the round trip in the
        // one place this type is used for.
        if (hour > 23 or minute > 59 or second > 59) return null;

        var rest = text[19..];

        // Fractional seconds, truncated at microseconds because that is the
        // resolution the column has. Digits past the sixth are read and
        // dropped rather than refused: they are somebody else's precision,
        // not a mistake.
        var fraction: i64 = 0;
        if (rest.len > 0 and rest[0] == '.') {
            var i: usize = 1;
            var scale: i64 = 100_000;
            while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {
                if (scale > 0) {
                    fraction += @as(i64, rest[i] - '0') * scale;
                    scale = @divTrunc(scale, 10);
                }
            }
            if (i == 1) return null; // a dot with no digits after it
            rest = rest[i..];
        }

        const offset: i64 = if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z'))
            0
        else if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') blk: {
            const hours = fixed(u8, rest[1..3]) orelse return null;
            const minutes = fixed(u8, rest[4..6]) orelse return null;
            if (hours > 23 or minutes > 59) return null;
            const total = @as(i64, hours) * 3600 + @as(i64, minutes) * 60;
            break :blk if (rest[0] == '-') -total else total;
        } else return null;

        const secs = daysFromCivil(year, month, day) * std.time.s_per_day +
            @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second) - offset;
        const micros = secs * std.time.us_per_s + fraction;
        // An offset can carry the first or last day past the ends: `0001-01-01T00:00:00+07:00`
        // is in year 0 in UTC. The writer refuses those, so the reader does.
        if (micros < first_micros or micros > last_micros) return null;
        return .{ .micros = micros };
    }

    /// A fixed-width run of digits, or null when any byte is not one.
    ///
    /// `std.fmt.parseInt` is not this: it takes `+7` and `-0`, neither of
    /// which is a field of a timestamp, and it would read `2026-1O-01` as far
    /// as the letter and stop somewhere useless. Same argument as
    /// `convert.spelledAsNumber`.
    fn fixed(comptime T: type, digits: []const u8) ?T {
        var out: T = 0;
        for (digits) |ch| {
            if (!std.ascii.isDigit(ch)) return null;
            out = out * 10 + @as(T, ch - '0');
        }
        return out;
    }

    fn isLeap(year: i64) bool {
        return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
    }

    fn daysInMonth(year: i64, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeap(year)) 29 else 28,
            else => 0,
        };
    }

    /// Days from 1970-01-01 to a civil date — Howard Hinnant's `days_from_civil`,
    /// which is the inverse of what `std.time.epoch` does on the way out.
    ///
    /// Written here rather than found in std because std has the one
    /// direction: `EpochSeconds` walks days into a date and nothing walks a
    /// date back into days.
    fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
        const shifted = year - @as(i64, @intFromBool(month <= 2));
        const era = @divFloor(shifted, 400);
        const year_of_era = shifted - era * 400;
        const month_term: i64 = @as(i64, month) + (if (month > 2) @as(i64, -3) else @as(i64, 9));
        const day_of_year = @divTrunc(153 * month_term + 2, 5) + @as(i64, day) - 1;
        const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) -
            @divTrunc(year_of_era, 100) + day_of_year;
        return era * 146_097 + day_of_era - 719_468;
    }

    pub fn jsonStringify(self: Timestamp, jw: anytype) !void {
        var buf: [32]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        // A moment outside 0001 to 9999 is an error, not `null`: `null` reads
        // as "no value" and a client cannot tell the two apart (ADR 127).
        // `WriteFailed` because it is the only error `std.json.Stringify`
        // lets a `jsonStringify` return; `ctx.sendJson` builds the body
        // before the head goes out, so the client gets a 500, not half a body.
        self.writeRfc3339(&w) catch return error.WriteFailed;
        try jw.write(w.buffered());
    }

    /// The third arrival, read the way `nilo_parse` reads the other two:
    /// `std.json` picks a reader by this name, so a body field of this type
    /// was read as `{micros: …}` until it existed (ADR 166). Text that is
    /// not a moment is `InvalidCharacter`, which `std.fmt` answers for a
    /// digit that is not one; anything that is not text is the wrong kind.
    pub fn jsonParse(
        gpa: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Timestamp {
        const token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
        const text = switch (token) {
            inline .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };
        defer switch (token) {
            .allocated_string => gpa.free(text),
            else => {},
        };
        return nilo_parse(text) orelse error.InvalidCharacter;
    }

    pub fn jsonParseFromValue(
        gpa: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Timestamp {
        _ = gpa;
        _ = options;
        return switch (source) {
            .string => |text| nilo_parse(text) orelse error.InvalidCharacter,
            else => error.UnexpectedToken,
        };
    }
};

/// A calendar day, as days since 1970-01-01 — no hour, no zone, nothing to
/// convert.
///
/// **A day is not a moment, and that is the whole reason this is a type rather
/// than a `Timestamp` with the time thrown away.** An invoice due date, a date
/// of birth and a public holiday are the same day everywhere on earth: reading
/// one into a `timestamptz` gives it a midnight, and a midnight has a zone, and
/// then a due date moves by a day for a customer in Jakarta. Postgres has a
/// column for exactly this and so does every other database.
///
/// It holds the line the rest of this file holds — **a type here carries a
/// value and knows how to write itself; it does not calculate.** There is no
/// `.addDays` and no `.weekday`. What it owes is that the day which went in is
/// the day that comes out, and that it can be written and read back
/// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
///
/// **Read out of the column rather than out of `::text`**, which is the
/// difference from `sql.AsText("date")` and the reason it exists. A text column
/// is asked for as `column::text` in every `SELECT` list, so a `db.raw`
/// statement reading one has to carry the cast and `rawcheck` refuses it when
/// it does not. This one is asked for as itself: on Postgres the four bytes the
/// column holds, on SQLite the ISO text SQLite's own date functions read.
pub const Date = struct {
    /// Days since 1970-01-01. Postgres counts a `date` from 2000-01-01 on the
    /// wire; the Wire converts once, on the way in, so nothing above this line
    /// has to know that — the same arrangement `Timestamp` has.
    days: i32,

    pub const nilo_type_name = "Date";

    /// What `jsonStringify` sends, so a generated document describes a date
    /// rather than the `days` field nobody sees (ADR 016).
    pub const nilo_openapi = .{ .type = "string", .format = "date" };

    pub fn fromDays(days: i32) Date {
        return .{ .days = days };
    }

    /// The day a moment falls on in UTC. Named `utc` rather than `of` because
    /// that is the whole of what it assumes, and assuming it silently is how a
    /// report for the 1st picks up rows from the 2nd.
    pub fn utcOf(at: Timestamp) Date {
        return .{ .days = @intCast(@divFloor(at.seconds(), std.time.s_per_day)) };
    }

    /// Midnight UTC on this day, for a comparison against a `timestamptz`
    /// column. The one conversion offered, and it says which zone it made up.
    ///
    /// **`error.OutOfRange` for a day whose midnight does not fit in the `i64`
    /// of microseconds**, about year 294,000 on: Postgres holds a `date` to
    /// year 5,874,897, so this used to overflow (and trap in Debug) for a value
    /// the database handed over. A moment past 9999 that does fit is returned;
    /// it just cannot be written as RFC 3339 (ADR 127).
    pub fn atMidnightUtc(self: Date) error{OutOfRange}!Timestamp {
        const per_day = std.time.s_per_day * std.time.us_per_s;
        const micros = std.math.mul(i64, @as(i64, self.days), per_day) catch
            return error.OutOfRange;
        return .{ .micros = micros };
    }

    /// `2026-09-17` — ISO 8601, which is what `date` prints, what a JSON body
    /// wants, and what sorts correctly as text.
    ///
    /// **A day before 1970 is the ordinary case here**, which is why this does
    /// not go through `std.time.epoch` the way `Timestamp.writeRfc3339` does.
    /// That walk starts at the epoch and returns `error.BeforeEpoch` for
    /// anything earlier, and the first thing anybody puts in a `date` column
    /// is a date of birth. The range that survives a round trip is the four
    /// digits ISO spells without a sign, so year 1 to 9999 and nothing else:
    /// Postgres has no year 0 (1 BC is the year before 1 AD), refuses
    /// `0000-01-01` on insert, and reads 1 BC back as year 0, which is
    /// therefore refused here rather than printed (ADR 127).
    pub fn writeIso(self: Date, w: *std.Io.Writer) !void {
        const civil = civilFromDays(self.days);
        if (civil.year < 1 or civil.year > 9999) return error.OutOfRange;
        // `@as(u16, …)` and not the `i64` the arithmetic is in: zero-padding a
        // *signed* integer writes the sign, so `{d:0>4}` on an `i64` 1945 is
        // `+1945`. The year the epoch walk in std hands back is unsigned,
        // which is why nothing here had to know that before.
        try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{
            @as(u16, @intCast(civil.year)),
            civil.month,
            civil.day,
        });
    }

    /// Howard Hinnant's `civil_from_days`, the inverse of the
    /// `Timestamp.daysFromCivil` the parser above uses. Written out rather
    /// than found in std for the reason that one was: std has the one
    /// direction, and it is the direction that stops at 1970.
    ///
    /// Takes an `i64` so `Timestamp.writeRfc3339` can share it: it is good for
    /// negative days, which is what a pre-1970 moment is.
    fn civilFromDays(days: i64) struct { year: i64, month: u8, day: u8 } {
        const shifted = days + 719_468;
        const era = @divFloor(shifted, 146_097);
        const day_of_era = shifted - era * 146_097; // [0, 146096]
        const year_of_era = @divTrunc(
            day_of_era - @divTrunc(day_of_era, 1460) + @divTrunc(day_of_era, 36_524) -
                @divTrunc(day_of_era, 146_096),
            365,
        ); // [0, 399]
        const day_of_year = day_of_era -
            (365 * year_of_era + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100));
        const month_term = @divTrunc(5 * day_of_year + 2, 153); // [0, 11]
        const month: i64 = month_term + (if (month_term < 10) @as(i64, 3) else @as(i64, -9));
        return .{
            .year = year_of_era + era * 400 + @intFromBool(month <= 2),
            .month = @intCast(month),
            .day = @intCast(day_of_year - @divTrunc(153 * month_term + 2, 5) + 1), // [1, 31]
        };
    }

    /// The other half of `writeIso`, so a day this server printed can be
    /// handed back to it. The same property `Timestamp.nilo_parse` holds, and
    /// tested as a pair for the same reason.
    ///
    /// Narrower than the timestamp parser on purpose: `2026-09-17` and nothing
    /// else. A date with a time on it is a moment somebody meant to send
    /// somewhere else, and reading it by dropping the time is how a value
    /// arrives a day out.
    pub fn nilo_parse(text: []const u8) ?Date {
        if (text.len != 10) return null;
        if (text[4] != '-' or text[7] != '-') return null;

        const year = Timestamp.fixed(i64, text[0..4]) orelse return null;
        const month = Timestamp.fixed(u8, text[5..7]) orelse return null;
        const day = Timestamp.fixed(u8, text[8..10]) orelse return null;

        // No year 0: Postgres refuses `0000-01-01` (see `writeIso`).
        if (year < 1) return null;
        if (month < 1 or month > 12) return null;
        if (day < 1 or day > Timestamp.daysInMonth(year, month)) return null;
        return .{ .days = @intCast(Timestamp.daysFromCivil(year, month, day)) };
    }

    pub fn jsonStringify(self: Date, jw: anytype) !void {
        var buf: [16]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        // An error rather than `null`, for the reason `Timestamp` gives (ADR 127).
        self.writeIso(&w) catch return error.WriteFailed;
        try jw.write(w.buffered());
    }

    pub fn jsonParse(
        gpa: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Date {
        const token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
        const text = switch (token) {
            inline .string, .allocated_string => |slice| slice,
            else => return error.UnexpectedToken,
        };
        defer switch (token) {
            .allocated_string => gpa.free(text),
            else => {},
        };
        return nilo_parse(text) orelse error.InvalidCharacter;
    }

    pub fn jsonParseFromValue(
        gpa: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Date {
        _ = gpa;
        _ = options;
        return switch (source) {
            .string => |text| nilo_parse(text) orelse error.InvalidCharacter,
            else => return error.UnexpectedToken,
        };
    }
};

// -- tests ---------------------------------------------------------------

const testing = std.testing;

fn textOf(value: anytype, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try value.writeRfc3339(&w);
    return w.buffered();
}

test "a Timestamp writes itself as RFC 3339 in UTC, with six fractional digits" {
    var buf: [40]u8 = undefined;
    const t = Timestamp.fromSeconds(1_786_872_600);
    try testing.expectEqualStrings("2026-08-16T09:30:00.000000Z", try textOf(t, &buf));
    const frac: Timestamp = .{ .micros = t.micros + 700_000 };
    try testing.expectEqualStrings("2026-08-16T09:30:00.700000Z", try textOf(frac, &buf));
    const last: Timestamp = .{ .micros = t.micros + 999_999 };
    try testing.expectEqualStrings("2026-08-16T09:30:00.999999Z", try textOf(last, &buf));
}

test "what a Timestamp prints, with its microseconds, reads back to the same microsecond" {
    var buf: [40]u8 = undefined;
    for ([_]i64{ 0, 1, 700_000, 999_999, 1_786_872_600_000_001, 1_786_872_600_700_000, 4_102_444_799_999_999 }) |micros| {
        const t: Timestamp = .{ .micros = micros };
        const back = Timestamp.nilo_parse(try textOf(t, &buf)).?;
        try testing.expectEqual(micros, back.micros);
    }
}

test "a Timestamp written to JSON keeps its microseconds" {
    const Row = struct { at: Timestamp };
    const text = try std.json.Stringify.valueAlloc(testing.allocator, Row{ .at = .{ .micros = 1_786_872_600_700_000 } }, .{});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("{\"at\":\"2026-08-16T09:30:00.700000Z\"}", text);
}

test "a leap day is a day, and the year after it is not" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings(
        "2024-02-29T12:00:00.000000Z",
        try textOf(Timestamp.fromSeconds(1_709_208_000), &buf),
    );
    try testing.expectEqualStrings(
        "2025-03-01T12:00:00.000000Z",
        try textOf(Timestamp.fromSeconds(1_740_830_400), &buf),
    );
}

test "a day is checked against its own month and its own century, and a second stops at 59" {
    // The century rule both ways: 1900 is divisible by 100 and not by 400,
    // so it has no 29 February; 2000 is divisible by 400, so it does.
    try testing.expect(Timestamp.nilo_parse("1900-02-29T00:00:00Z") == null);
    try testing.expect(Date.nilo_parse("1900-02-29") == null);
    try testing.expectEqual(
        @as(i64, 11_016 * std.time.s_per_day),
        Timestamp.nilo_parse("2000-02-29T00:00:00Z").?.seconds(),
    );
    try testing.expectEqual(@as(i32, 11_016), Date.nilo_parse("2000-02-29").?.days);
    try testing.expect(Date.nilo_parse("2023-02-29") == null);
    try testing.expect(Date.nilo_parse("2024-02-29") != null);

    // A thirty-day month has no 31st, and a thirty-one-day one has.
    try testing.expect(Timestamp.nilo_parse("2026-04-31T00:00:00Z") == null);
    try testing.expect(Date.nilo_parse("2026-04-31") == null);
    try testing.expect(Date.nilo_parse("2026-04-30") != null);
    try testing.expect(Date.nilo_parse("2026-12-31") != null);
    for ([_][]const u8{ "2026-00-10", "2026-13-01", "2026-01-00", "2026-01-32" }) |text| {
        try testing.expect(Date.nilo_parse(text) == null);
    }

    // A leap second, a sixtieth minute and a twenty-fourth hour are all
    // refused: none of them has a microsecond to come back to.
    try testing.expect(Timestamp.nilo_parse("2016-12-31T23:59:60Z") == null);
    try testing.expect(Timestamp.nilo_parse("2026-06-30T23:60:00Z") == null);
    try testing.expect(Timestamp.nilo_parse("2026-06-30T24:00:00Z") == null);
    try testing.expect(Timestamp.nilo_parse("2026-06-30T23:59:59Z") != null);
}

test "the epoch itself is written as the epoch" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00.000000Z",
        try textOf(Timestamp.fromSeconds(0), &buf),
    );
}

test "a moment before the epoch is written, and reads back to the same microsecond" {
    var buf: [40]u8 = undefined;
    const before: Timestamp = .{ .micros = -1 };
    try testing.expectEqualStrings("1969-12-31T23:59:59.999999Z", try textOf(before, &buf));
    try testing.expectEqual(@as(i64, -1), Timestamp.nilo_parse("1969-12-31T23:59:59.999999Z").?.micros);

    // A date of birth at midnight, and a moment with a fraction before 1970:
    // both pairs, because a parser that disagrees with the writer by a
    // microsecond pages past rows (ADR 127).
    for ([_]i64{
        -1,
        -1_000_000,
        -1_000_001,
        -86_400_000_000,
        -1_606 * 86_400_000_000, // 1965-08-09
        -2_208_988_800_000_000 + 123_456, // 1900-01-01
        -62_135_596_800_000_000, // 0001-01-01
    }) |micros| {
        const t: Timestamp = .{ .micros = micros };
        const back = Timestamp.nilo_parse(try textOf(t, &buf)) orelse
            return error.WriterPrintedSomethingTheParserRefused;
        try testing.expectEqual(micros, back.micros);
    }
}

test "the ends of the range a Timestamp can write are 0001-01-01 and 9999-12-31" {
    var buf: [40]u8 = undefined;
    const first: Timestamp = .{ .micros = Timestamp.first_micros };
    const last: Timestamp = .{ .micros = Timestamp.last_micros };
    try testing.expectEqualStrings("0001-01-01T00:00:00.000000Z", try textOf(first, &buf));
    try testing.expectEqualStrings("9999-12-31T23:59:59.999999Z", try textOf(last, &buf));
    try testing.expectEqual(first.micros, Timestamp.nilo_parse("0001-01-01T00:00:00Z").?.micros);
    try testing.expectEqual(last.micros, Timestamp.nilo_parse("9999-12-31T23:59:59.999999Z").?.micros);
}

test "a moment outside 0001 to 9999 is an error, never null and never text the parser refuses" {
    var buf: [40]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try testing.expectError(
        error.OutOfRange,
        (Timestamp{ .micros = Timestamp.first_micros - 1 }).writeRfc3339(&w),
    );
    try testing.expectError(
        error.OutOfRange,
        (Timestamp{ .micros = Timestamp.last_micros + 1 }).writeRfc3339(&w),
    );
    try testing.expectError(
        error.OutOfRange,
        (Timestamp{ .micros = std.math.minInt(i64) }).writeRfc3339(&w),
    );
    try testing.expectError(
        error.OutOfRange,
        (Timestamp{ .micros = std.math.maxInt(i64) }).writeRfc3339(&w),
    );

    // Through JSON it stays an error: `null` reads as "no value".
    const Row = struct { at: Timestamp };
    var json_buf: [64]u8 = undefined;
    var json_sink = std.Io.Writer.fixed(&json_buf);
    try testing.expectError(error.WriteFailed, std.json.Stringify.value(
        Row{ .at = .{ .micros = Timestamp.last_micros + 1 } },
        .{},
        &json_sink,
    ));
    const before = try std.json.Stringify.valueAlloc(
        testing.allocator,
        Row{ .at = .{ .micros = -1 } },
        .{},
    );
    defer testing.allocator.free(before);
    try testing.expectEqualStrings("{\"at\":\"1969-12-31T23:59:59.999999Z\"}", before);
}

test "year 0 and moments an offset pushes outside the range are refused on read" {
    try testing.expectEqual(@as(?Timestamp, null), Timestamp.nilo_parse("0000-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?Timestamp, null), Timestamp.nilo_parse("0000-12-31T23:59:59Z"));
    try testing.expectEqual(@as(?Date, null), Date.nilo_parse("0000-01-01"));
    // Year 1 in the text and year 0 in UTC.
    try testing.expectEqual(@as(?Timestamp, null), Timestamp.nilo_parse("0001-01-01T00:00:00+07:00"));
    try testing.expectEqual(@as(?Timestamp, null), Timestamp.nilo_parse("9999-12-31T23:59:59-01:00"));
    try testing.expect(Timestamp.nilo_parse("0001-01-01T07:00:00+07:00") != null);
}

test "seconds and microseconds are the same moment" {
    const t = Timestamp.fromSeconds(1_786_951_800);
    try testing.expectEqual(@as(i64, 1_786_951_800_000_000), t.micros);
    try testing.expectEqual(@as(i64, 1_786_951_800), t.seconds());
}

test "a Timestamp can say what time it is, and says it in microseconds" {
    const then = Timestamp.fromSeconds(1_767_225_600); // 2026-01-01
    const now = Timestamp.now();
    try testing.expect(now.micros > then.micros);
    // The unit, not the instant: a reading in seconds or milliseconds would
    // land far below a moment that has already happened.
    try testing.expect(now.seconds() > 1_767_225_600);
}

test "what a Timestamp prints, a Timestamp reads back to the same microsecond" {
    // The property, asserted as a pair rather than as two halves: every
    // keyset cursor in a paged list is a value this same writer produced, so
    // a parser that agrees with a spec and not with the writer still pages
    // wrong (ADR 127).
    var buf: [40]u8 = undefined;
    for ([_]i64{
        0, // the epoch itself
        1_786_872_600, // an ordinary afternoon
        1_709_208_000, // a leap day
        1_740_830_400, // the year after one
        4_102_444_800, // 2100, which is not a leap year
    }) |secs| {
        const written = Timestamp.fromSeconds(secs);
        const read = Timestamp.nilo_parse(try textOf(written, &buf)) orelse
            return error.WriterPrintedSomethingTheParserRefused;
        try testing.expectEqual(written.micros, read.micros);
    }
}

test "a timestamp with an offset is the same moment as the Z it stands for" {
    const jakarta = Timestamp.nilo_parse("2026-08-16T16:30:00+07:00").?;
    const utc = Timestamp.nilo_parse("2026-08-16T09:30:00Z").?;
    try testing.expectEqual(utc.micros, jakarta.micros);
    try testing.expectEqual(@as(i64, 1_786_872_600), utc.seconds());

    // And the other sign, which is the one a `-` in the arithmetic gets wrong.
    const bogota = Timestamp.nilo_parse("2026-08-16T04:30:00-05:00").?;
    try testing.expectEqual(utc.micros, bogota.micros);
}

test "fractional seconds are kept to the resolution the column has" {
    const with = Timestamp.nilo_parse("2026-08-16T09:30:00.123456Z").?;
    try testing.expectEqual(@as(i64, 1_786_872_600_123_456), with.micros);

    // Fewer digits are the tenths they say they are, not the last six.
    try testing.expectEqual(
        @as(i64, 1_786_872_600_500_000),
        Timestamp.nilo_parse("2026-08-16T09:30:00.5Z").?.micros,
    );
    // And more are somebody else's precision, dropped rather than refused.
    try testing.expectEqual(
        @as(i64, 1_786_872_600_123_456),
        Timestamp.nilo_parse("2026-08-16T09:30:00.1234567891Z").?.micros,
    );
}

test "a timestamp with no zone is refused, because there is no right reading of it" {
    // The one that matters: a cursor read as UTC when the client meant local
    // moves the page by hours and nothing fails.
    try testing.expectEqual(@as(?Timestamp, null), Timestamp.nilo_parse("2026-08-16T09:30:00"));

    // And the rest of what is not a timestamp.
    for ([_][]const u8{
        "",
        "2026-08-16",
        "2026-08-16 09:30:00Z", // a space where the T goes
        "2026-13-01T00:00:00Z", // no thirteenth month
        "2026-02-30T00:00:00Z", // nor a thirtieth of February
        "2025-02-29T00:00:00Z", // nor a leap day in a year without one
        "2026-08-16T24:00:00Z",
        "2026-08-16T09:60:00Z",
        "2026-1O-01T00:00:00Z", // a letter O where a zero goes
        "2026-08-16T09:30:00.Z", // a dot with no digits
        "2026-08-16T09:30:00+0700", // an offset with no colon
        "2026-08-16T09:30:00Q",
        "yesterday",
    }) |not_one| {
        try testing.expectEqual(@as(?Timestamp, null), Timestamp.nilo_parse(not_one));
    }

    // A leap day in a year that has one still reads.
    try testing.expect(Timestamp.nilo_parse("2024-02-29T12:00:00Z") != null);
}

test "a Timestamp in a JSON body is read from the text a response writes it as" {
    const Body = struct { due_at: Timestamp, seen_at: ?Timestamp = null };
    const parsed = try std.json.parseFromSlice(
        Body,
        testing.allocator,
        "{\"due_at\":\"2026-08-16T16:30:00+07:00\"}",
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqual(Timestamp.nilo_parse("2026-08-16T09:30:00Z").?.micros, parsed.value.due_at.micros);
    try testing.expectEqual(@as(?Timestamp, null), parsed.value.seen_at);

    // The wrong kind, and text with no zone in it — the reading `nilo_parse`
    // refuses on a query value is refused in a body the same way.
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Body, testing.allocator, "{\"due_at\":1723800600}", .{}));
    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(Body, testing.allocator, "{\"due_at\":\"2026-08-16T09:30:00\"}", .{}));

    const held = try std.json.parseFromSlice(std.json.Value, testing.allocator, "\"2026-08-16T09:30:00Z\"", .{});
    defer held.deinit();
    const from_value = try std.json.parseFromValue(Timestamp, testing.allocator, held.value, .{});
    defer from_value.deinit();
    try testing.expectEqual(Timestamp.nilo_parse("2026-08-16T09:30:00Z").?.micros, from_value.value.micros);
}

// -- a day, which is not a moment (ADR 181) ------------------------------

fn isoOf(value: Date, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try value.writeIso(&w);
    return w.buffered();
}

test "what a Date prints, a Date reads back to the same day" {
    // The property, as a pair rather than as two halves — the same reason
    // `Timestamp`'s round trip is asserted that way. A day that comes back
    // one out is a due date that moved, and nothing fails.
    var buf: [16]u8 = undefined;
    for ([_][]const u8{
        "0001-01-01", // the bottom of what four digits spell
        "1815-12-10", // a date of birth, which is the case the type is for
        "1900-03-01", // the year 1900 is not a leap year
        "1969-12-31", // the day before the epoch
        "1970-01-01", // the epoch itself
        "2000-01-01", // what the Postgres wire counts from
        "2024-02-29", // a leap day
        "2025-03-01", // the day after one in a year without it
        "2026-09-17",
        "2100-03-01", // the year 2100 is not a leap year
        "9999-12-31", // the top of it
    }) |iso| {
        const read = Date.nilo_parse(iso) orelse return error.ParserRefusedItsOwnOutput;
        try testing.expectEqualStrings(iso, try isoOf(read, &buf));
    }
}

test "a day before 1970 is a day, because a date of birth usually is one" {
    // Neither type stops at the epoch: the first thing anybody puts in a
    // `date` column is somebody's birthday.
    var buf: [16]u8 = undefined;
    const born = Date.nilo_parse("1965-08-09").?;
    try testing.expectEqual(@as(i32, -1606), born.days);
    try testing.expectEqualStrings("1965-08-09", try isoOf(born, &buf));

    // Outside the four digits, the writer says so rather than printing
    // something `nilo_parse` could not read back.
    var w = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.OutOfRange, Date.fromDays(-800_000).writeIso(&w));
}

test "a Date outside 0001 to 9999 is an error in JSON, never null, and year 0 does not exist" {
    var buf: [16]u8 = undefined;
    // 0000-12-31 is what a Postgres `date` of 1 BC reads back as: Postgres
    // has no year 0, so neither does the writer.
    const year_zero = Date.fromDays(Date.nilo_parse("0001-01-01").?.days - 1);
    var w = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.OutOfRange, year_zero.writeIso(&w));
    // 9999-12-31 is 2_932_896 days after the epoch; the next day is year 10000.
    const past = Date.fromDays(Date.nilo_parse("9999-12-31").?.days + 1);
    try testing.expectError(error.OutOfRange, past.writeIso(&w));

    const Row = struct { on: Date };
    var json_buf: [64]u8 = undefined;
    var json_sink = std.Io.Writer.fixed(&json_buf);
    try testing.expectError(error.WriteFailed, std.json.Stringify.value(
        Row{ .on = past },
        .{},
        &json_sink,
    ));
    const before = try std.json.Stringify.valueAlloc(
        testing.allocator,
        Row{ .on = Date.nilo_parse("0001-01-01").? },
        .{},
    );
    defer testing.allocator.free(before);
    try testing.expectEqualStrings("{\"on\":\"0001-01-01\"}", before);
}

test "a date with a time on it is refused, because dropping the time moves the day" {
    // The narrow parser is the decision. `2026-09-17T23:00:00+07:00` is the
    // 18th in Jakarta and the 17th in UTC, so reading it by throwing the time
    // away picks one of the two silently.
    for ([_][]const u8{
        "",
        "2026-09-17T00:00:00Z",
        "2026-09-17 00:00:00",
        "2026-9-17",
        "2026-13-01",
        "2026-02-30",
        "2025-02-29", // a leap day in a year without one
        "2026-09-1O", // a letter O where a zero goes
        "today",
    }) |not_one| {
        try testing.expectEqual(@as(?Date, null), Date.nilo_parse(not_one));
    }
}

test "a Date writes itself into JSON as the day, and reads one back" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var jw = std.json.Stringify{ .writer = &w };
    try jw.write(Date.nilo_parse("2026-09-17").?);
    try testing.expectEqualStrings("\"2026-09-17\"", w.buffered());

    const Body = struct { due: Date, closed: ?Date = null };
    const parsed = try std.json.parseFromSlice(
        Body,
        testing.allocator,
        "{\"due\":\"2026-09-17\"}",
        .{},
    );
    defer parsed.deinit();
    try testing.expectEqual(Date.nilo_parse("2026-09-17").?.days, parsed.value.due.days);
    try testing.expectEqual(@as(?Date, null), parsed.value.closed);

    // And a moment where a day goes, refused the way the query parser refuses
    // it rather than read by dropping the time.
    try testing.expectError(error.InvalidCharacter, std.json.parseFromSlice(
        Body,
        testing.allocator,
        "{\"due\":\"2026-09-17T00:00:00Z\"}",
        .{},
    ));
}

test "the one conversion a Date offers says which zone it made up" {
    // `utcOf` and `atMidnightUtc` are named for their assumption, because
    // assuming it silently is how a report for the 1st picks up the 2nd.
    const noon = Timestamp.nilo_parse("2026-09-17T12:00:00Z").?;
    try testing.expectEqual(Date.nilo_parse("2026-09-17").?.days, Date.utcOf(noon).days);

    const midnight = try Date.nilo_parse("2026-09-17").?.atMidnightUtc();
    try testing.expectEqual(Timestamp.nilo_parse("2026-09-17T00:00:00Z").?.micros, midnight.micros);

    // A `date` Postgres can hold (it goes to year 5,874,897) whose midnight
    // does not fit in an i64 of microseconds: an error, not an overflow.
    try testing.expectError(error.OutOfRange, Date.fromDays(std.math.maxInt(i32)).atMidnightUtc());
    try testing.expectError(error.OutOfRange, Date.fromDays(std.math.minInt(i32)).atMidnightUtc());
    // And one that fits, before 1970.
    const before = try Date.fromDays(-1).atMidnightUtc();
    try testing.expectEqual(@as(i64, -86_400_000_000), before.micros);

    // Late evening in Jakarta is still the 17th in UTC, which is the whole
    // reason the two are separate types.
    const jakarta_evening = Timestamp.nilo_parse("2026-09-18T01:00:00+07:00").?;
    try testing.expectEqual(Date.nilo_parse("2026-09-17").?.days, Date.utcOf(jakarta_evening).days);
}
