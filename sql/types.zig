//! The column types Zig does not have a word for (ADR 0039).
//!
//! Postgres has `timestamptz`, `uuid` and `jsonb`. Zig has no date type, no
//! UUID and no opinion about JSON in a column. The gap could have been left
//! open — `i64`, `[16]u8`, `Str` — and that was the alternative weighed and
//! dropped, on the grounds that it makes the most common columns in any table
//! the worst ones to read. `created_at: i64` does not say whether it counts
//! seconds or microseconds, and a `[16]u8` returned from a handler leaves as
//! sixteen numbers rather than a UUID.
//!
//! The line these hold, and the reason there is no `.addDays`:
//!
//! > **A type here carries a value and knows how to write itself. It does not
//! > calculate.**
//!
//! Time zones and calendar arithmetic are what turn a date library from a
//! weekend into a permanent obligation — `Asia/Jakarta` is not an offset, it
//! is a history, and the IANA database it lives in ships several times a year
//! because governments change their minds. None of that is needed to read a
//! column: Postgres stores `timestamptz` as microseconds since the epoch in
//! UTC, and applies a zone only when it displays one. So the expensive half of
//! a date library is the half with nothing to do with a database.
//!
//! `Timestamp` is therefore deliberately open: it is an `i64` whose unit is
//! stated, and anyone who wants arithmetic can build it on top in a package of
//! their own without asking nilo's permission. This is the floor for that
//! work, not a refusal of it.
//!
//! **`Uuid` is no longer one of these.** It is `nilo_id`'s, imported here and
//! re-exported, because generating a key and reading one back are the same
//! sixteen bytes and only one of those two jobs is about a database (ADR
//! 0042). What stayed is this module's opinion about which column it goes in.

const std = @import("std");
const core = @import("nilo_core");
const id = @import("nilo_id");

/// A moment, as microseconds since 1970-01-01 UTC — the same integer Postgres
/// keeps in a `timestamptz`, so reading one is a copy rather than a
/// conversion.
///
/// Writes itself as RFC 3339 in UTC, which is what a JSON body wants and what
/// `format: date-time` in the generated document promises.
pub const Timestamp = struct {
    /// Microseconds since the epoch. Postgres counts from 2000-01-01 on the
    /// wire; the Wire converts once, on the way in, so nothing above this
    /// line has to know that.
    micros: i64,

    pub const nilo_column = "timestamptz";

    /// Now, which this could not answer until Core had a clock (ADR 0045).
    /// A copy rather than a conversion: `nowMicros` counts in the unit this
    /// column stores.
    ///
    /// It is a wall clock, so it is what a `created_at` wants and what
    /// nothing measuring a duration should use — two rows written a second
    /// apart can carry timestamps in either order if an operator moves the
    /// clock between them.
    pub fn now() Timestamp {
        return .{ .micros = core.nowMicros() };
    }

    pub fn fromSeconds(secs: i64) Timestamp {
        return .{ .micros = secs * std.time.us_per_s };
    }

    pub fn seconds(self: Timestamp) i64 {
        return @divFloor(self.micros, std.time.us_per_s);
    }

    /// RFC 3339 in UTC, to the second: `2026-08-16T09:30:00Z`. Fractional
    /// microseconds are dropped rather than printed, because a body that
    /// sometimes carries them and sometimes does not is worse to consume than
    /// one that never does.
    pub fn writeRfc3339(self: Timestamp, w: *std.Io.Writer) !void {
        const secs = self.seconds();
        if (secs < 0) return error.BeforeEpoch;

        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
        const day = epoch_secs.getEpochDay();
        const time = epoch_secs.getDaySeconds();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            time.getHoursIntoDay(),
            time.getMinutesIntoHour(),
            time.getSecondsIntoMinute(),
        });
    }

    pub fn jsonStringify(self: Timestamp, jw: anytype) !void {
        var buf: [32]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        self.writeRfc3339(&w) catch return jw.write(null);
        try jw.write(w.buffered());
    }
};

/// Sixteen bytes, in the order Postgres stores them — `nilo_id`'s type
/// rather than one of this module's own (ADR 0042).
///
/// It moved down a layer because two modules wanted it and only one of them
/// is about databases: reading a `uuid` column and generating a key are the
/// same value, and a Service declaring a second `Uuid` would have made
/// `id.v7()` something a caller had to convert before inserting.
///
/// **What did not move is the opinion about the column.** `nilo_id` has
/// never heard of Postgres, so `nilo_column = "uuid"` is not a declaration on
/// the type; `declaredColumn` below answers for it. Imports point downward
/// and so does knowledge — a marker on a Core-layer type is the easy way to
/// break the second rule while keeping the first.
pub const Uuid = id.Uuid;

/// A `numeric` column — the digits, exactly as they are stored, and no
/// arithmetic.
///
/// **Money in an `f64` is wrong**, and it is wrong quietly: `0.1 + 0.2` is the
/// example everybody knows and a total that is out by a cent after a thousand
/// lines is the version that reaches a customer. `numeric` is the column type
/// that exists to stop it, and reading one into a float gives the whole thing
/// back.
///
/// So this holds the text. That is the same line `Timestamp` holds and for
/// the same reason — **a type here carries a value and knows how to write
/// itself; it does not calculate.** Arbitrary-precision arithmetic is a
/// library, and a much larger one than a database module has any business
/// containing: rounding modes alone are a standard. What this owes is that
/// the digits which went in are the digits that come out, and that whoever
/// wants to add two of them can.
///
/// **It writes itself into JSON as a string**, which is a decision rather
/// than an oversight. A bare JSON number is exact on the wire and stops being
/// exact the moment a consumer parses it — `JSON.parse` answers a double, so
/// a client would silently get back the `f64` the column type was chosen to
/// avoid. A string arrives intact and makes the reader say what they want to
/// do with it. It is also the only representation that can carry the values
/// Postgres allows and JSON has no syntax for: `nan`, `inf`, `-inf`.
///
/// Read and written as text on the wire too — `"total"::text` on the way out
/// and `$1::numeric` on the way in — because Postgres keeps a `numeric` in a
/// binary form the driver can only build from a float. The cast is what makes
/// the round trip exact, and it is the Dialect that writes it.
pub const Decimal = struct {
    /// The digits as Postgres printed them: `1234.56`, `-0.004`, `nan`.
    /// Request-lifetime, like any other text a row comes back with.
    text: []const u8,

    pub const nilo_column = "numeric";

    /// Asked by the Dialect, which has to know before it writes the SQL
    /// rather than after the value arrives.
    pub const nilo_decimal = {};

    pub fn jsonStringify(self: Decimal, jw: anytype) !void {
        try jw.write(self.text);
    }
};

/// The element type of a list column — `text[]`, `int4[]` — or null when `T`
/// is not one.
///
/// **A plain slice, with no wrapper**, and the reason is that a slice already
/// says everything a wrapper would. `Array(T)` would sit beside `Json(T)` and
/// look consistent, but `Json(T)` earns its parentheses: a bare struct field
/// cannot say "this is a jsonb", and its `jsonStringify` has to unwrap so the
/// response body is not `{"value":…}`. `[]const i32` can only mean one thing.
/// The only slice with a second meaning is `[]const u8`, which is text and was
/// already spoken for — so that one is *not* a list, and `[]const []const u8`
/// is a list of text.
///
/// Nothing is refused here. A slice of something no Dialect will accept in a
/// column is caught by `checking`, which is where every other unreadable
/// column type is caught.
pub fn listElement(comptime T: type) ?type {
    const Inner = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    const info = @typeInfo(Inner);
    if (info != .pointer) return null;
    if (info.pointer.size != .slice) return null;
    // Text, and the one slice this cannot claim.
    if (info.pointer.child == u8) return null;
    return info.pointer.child;
}

/// Whether `T` is a `Decimal`, optional included. The Dialect asks this while
/// building a statement, so it is a comptime question about a type and never
/// about a value.
pub fn isDecimal(comptime T: type) bool {
    const Inner = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    return @typeInfo(Inner) == .@"struct" and @hasDecl(Inner, "nilo_decimal");
}

/// A `json` or `jsonb` column, read into a struct of the caller's own.
///
/// The fourth of a shape this repo already has three of — `Query(T)`,
/// `Form(T)`, `Session(T)` — so there is nothing new to learn about what the
/// parentheses mean. The bytes are parsed into `T` when the row is filled, in
/// the request arena, which is the cost and it is stated: a column read this
/// way is parsed per row.
pub fn Json(comptime T: type) type {
    return struct {
        const Self = @This();

        value: T,

        pub const nilo_column = "jsonb";
        pub const nilo_json_of = T;

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.write(self.value);
        }
    };
}

/// Whether `T` is a `Json(...)`, and of what. Asked by the Wire when it has
/// bytes to turn into a field.
pub fn jsonPayload(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .@"struct" => if (@hasDecl(T, "nilo_json_of")) T.nilo_json_of else null,
        else => null,
    };
}

/// The column type a nilo-provided type expects, when it has an opinion.
/// The Dialect asks; a plain Zig type answers `null` and is mapped by the
/// Dialect's own table instead.
/// **An enum may declare it too, and that is the one case where the answer
/// can only come from the caller.** A Postgres enum's type name lives in the
/// database; nothing on the Zig side can derive it, which is why
/// `dialect.accepts` declines to judge one. A Row that says so gets both
/// halves back: the column is checked at startup like any other, and a batch
/// insert can name the type its parameter casts to.
///
/// ```zig
/// const Role = enum {
///     admin,
///     member,
///
///     pub const nilo_column = "user_role";
/// };
/// ```
pub fn declaredColumn(comptime T: type) ?[]const u8 {
    // `Uuid` comes from `nilo_id`, which knows nothing about databases, so
    // the answer for it is here rather than on the type (ADR 0042). Every
    // type this module owns says so itself.
    if (T == Uuid) return "uuid";
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum" => if (@hasDecl(T, "nilo_column")) T.nilo_column else null,
        else => null,
    };
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

fn textOf(value: anytype, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try value.writeRfc3339(&w);
    return w.buffered();
}

test "a Timestamp writes itself as RFC 3339 in UTC" {
    var buf: [40]u8 = undefined;
    const t = Timestamp.fromSeconds(1_786_872_600);
    try testing.expectEqualStrings("2026-08-16T09:30:00Z", try textOf(t, &buf));
}

test "a leap day is a day, and the year after it is not" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings(
        "2024-02-29T12:00:00Z",
        try textOf(Timestamp.fromSeconds(1_709_208_000), &buf),
    );
    try testing.expectEqualStrings(
        "2025-03-01T12:00:00Z",
        try textOf(Timestamp.fromSeconds(1_740_830_400), &buf),
    );
}

test "the epoch itself is the first moment it can write" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00Z",
        try textOf(Timestamp.fromSeconds(0), &buf),
    );
}

test "a moment before the epoch is refused rather than printed wrong" {
    var buf: [40]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try testing.expectError(
        error.BeforeEpoch,
        Timestamp.fromSeconds(-1).writeRfc3339(&w),
    );
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

test "a uuid column and a generated key are the same type" {
    // Not a tautology: two modules built from the same root file are two
    // different modules to Zig, so a second `nilo_id` in the build graph
    // would make `id.v7()` something `db.insert` refuses to bind. Nothing
    // would fail to compile in either module on its own (ADR 0042).
    try testing.expectEqual(id.Uuid, Uuid);
}

test "a Uuid knows which column it belongs in, and the type it comes from does not" {
    try testing.expectEqualStrings("uuid", declaredColumn(Uuid).?);
    try testing.expect(!@hasDecl(id.Uuid, "nilo_column"));
}

test "the types that have an opinion about their column say so" {
    try testing.expectEqualStrings("timestamptz", declaredColumn(Timestamp).?);
    try testing.expectEqualStrings("uuid", declaredColumn(Uuid).?);
    try testing.expectEqualStrings("jsonb", declaredColumn(Json(struct { a: u8 })).?);
    try testing.expectEqual(@as(?[]const u8, null), declaredColumn(i64));
}

test "a Decimal keeps the digits it was given, however many there are" {
    // Past f64's 15-or-so significant digits by a wide margin. The point of
    // the type is that this sentence is boring.
    const wide = Decimal{ .text = "12345678901234567890.123456789" };
    try testing.expectEqualStrings("12345678901234567890.123456789", wide.text);
}

test "a Decimal writes itself into JSON as a string" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var jw = std.json.Stringify{ .writer = &w };
    try jw.write(Decimal{ .text = "1234.56" });
    // Quoted, and that is the decision: a bare number is exact here and stops
    // being exact in the consumer, where `JSON.parse` answers a double.
    try testing.expectEqualStrings("\"1234.56\"", w.buffered());
}

test "a Decimal is the one column type that can carry what JSON has no number for" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var jw = std.json.Stringify{ .writer = &w };
    try jw.write(Decimal{ .text = "nan" });
    try testing.expectEqualStrings("\"nan\"", w.buffered());
}

test "a Decimal is recognised through an optional, because a column may be null" {
    try testing.expect(isDecimal(Decimal));
    try testing.expect(isDecimal(?Decimal));
    try testing.expect(!isDecimal(f64));
    try testing.expect(!isDecimal([]const u8));
    try testing.expect(!isDecimal(Timestamp));
}

test "a Json column names the type it carries" {
    const Settings = struct { theme: []const u8 };
    try testing.expectEqual(Settings, jsonPayload(Json(Settings)).?);
    try testing.expectEqual(@as(?type, null), jsonPayload(i64));
}

test "a slice is a list column, and says what it holds" {
    try testing.expectEqual(i32, listElement([]const i32).?);
    try testing.expectEqual(bool, listElement([]const bool).?);
    // A nullable list column is still a list of the same thing.
    try testing.expectEqual(i32, listElement(?[]const i32).?);
    // And a list may hold NULLs, which is a property of the element.
    try testing.expectEqual(?i32, listElement([]const ?i32).?);
}

test "text is the one slice that is not a list" {
    // `[]const u8` was spoken for long before arrays were, so it stays text
    // and a list of text is written out as a list of it.
    try testing.expectEqual(@as(?type, null), listElement([]const u8));
    try testing.expectEqual(@as(?type, null), listElement(?[]const u8));
    try testing.expectEqual([]const u8, listElement([]const []const u8).?);
}

test "a value that is not a slice is not a list" {
    try testing.expectEqual(@as(?type, null), listElement(i64));
    try testing.expectEqual(@as(?type, null), listElement(Timestamp));
    try testing.expectEqual(@as(?type, null), listElement(Json(struct { a: u8 })));
}
