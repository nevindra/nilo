//! The column types Zig does not have a word for (ADR 036).
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
//! 038). What stayed is this module's opinion about which column it goes in.
//!
//! ## The list is not closed
//!
//! Everything above is a type this module *chose* to know about, and a list
//! chosen by one module is a list that stops somewhere. Past it is a
//! protocol: a struct or an enum carrying `nilo_column`, `nilo_read(text,
//! arena)` and `nilo_write(arena)` is a column type, whoever wrote it, and it
//! travels as the text Postgres prints — `"col"::text` out, `$1::inet` in.
//!
//! `AsText(name)` is that protocol's smallest instance, `Interval` and `Inet`
//! are two instances of `AsText`, and **`Decimal` is one too** — which is the
//! argument for the protocol rather than a coincidence. The hardest column
//! type this module ships is expressible in it, so the door is wide enough
//! (ADR 049).

const std = @import("std");
const core = @import("nilo_core");
const id = @import("nilo_id");

/// A moment, as microseconds since 1970-01-01 UTC, and a calendar day, as
/// days since 1970-01-01: `nilo_core`'s types, re-exported so a Row still
/// says `sql.Timestamp` and `sql.Date`. They moved down because the App layer
/// reads and writes them too, in a build with no database in it (ADR 057).
/// **What stayed is the opinion about the column**: `declaredColumn` below
/// answers `timestamptz` and `date` for them, and the Wires do the rest.
///
/// On SQLite a `Timestamp` column is an `INTEGER` of microseconds (ADR 067),
/// and SQLite's date functions read a bare number as a Julian day or, with
/// `'unixepoch'`, as seconds: `strftime('%m', col)` is NULL. Divide by
/// 1,000,000 and say `'unixepoch'`.
pub const Timestamp = core.Timestamp;
pub const Date = core.Date;

/// Days from 1970-01-01 to 2000-01-01, which is what the Postgres wire counts
/// a `date` from. Public because the Wire that converts is another file.
pub const date_days_from_epoch_to_y2k: i32 = 10_957;

/// The unit a Unix-count column counts in.
pub const Unit = enum { seconds, millis };

/// **A moment held as a plain count of a stated unit since the epoch**, for the
/// `INTEGER` column somebody else's schema already has. `Timestamp` is
/// microseconds and says so; a table whose `created_at` holds Unix
/// milliseconds read through it is the wrong year with no error, because an
/// `INTEGER` column has no unit for the schema check to compare (ADR 067).
/// The unit goes in the type, where a reader and the compiler can see it, and
/// the conversion is one multiply or one divide at the edge of the column
/// (ADR 036).
///
/// ```zig
/// created_at: sql.UnixMillis,   // INTEGER, milliseconds
/// seen_at: sql.UnixSeconds,     // INTEGER, seconds
/// ```
///
/// **It is an integer column on both databases** (`int8` on Postgres, `INTEGER`
/// on SQLite), so the check refuses a `timestamptz`, a `TEXT` and a `date`
/// under it, which is the half of the wrong-unit mistake a database can see.
/// What it cannot see is an `INTEGER` holding microseconds under
/// `UnixMillis`: both are integers, and that is on the caller's schema.
///
/// `.count` is the number as stored; `toTimestamp` and `fromTimestamp` cross to
/// `Timestamp` (one multiply, saturating, and one floor division). JSON is the
/// number, not RFC 3339, because a column kept as a count is almost always a
/// contract that says count; go through `toTimestamp` to print a date.
pub fn Unix(comptime unit: Unit) type {
    return struct {
        const Self = @This();

        count: i64,

        /// What marks the type for the Wires and the Dialects, which treat it
        /// as the `i64` it is on the wire.
        pub const nilo_unix = unit;
        pub const nilo_openapi = .{ .type = "integer", .format = "int64" };

        const per_second: i64 = switch (unit) {
            .seconds => 1,
            .millis => std.time.ms_per_s,
        };

        pub fn now() Self {
            return fromTimestamp(Timestamp.now());
        }

        /// Floor division, so a moment before 1970 truncates toward the past
        /// and a round trip through `toTimestamp` is the identity.
        pub fn fromTimestamp(t: Timestamp) Self {
            return .{ .count = @divFloor(t.micros, std.time.us_per_s / per_second) };
        }

        /// Saturates rather than overflowing, so a column holding something
        /// that is not a moment at all (a microsecond count under
        /// `UnixMillis`) reaches `writeRfc3339` as `error.OutOfRange`, not as a
        /// panic in Debug or a wrapped year in ReleaseFast.
        pub fn toTimestamp(self: Self) Timestamp {
            return .{ .micros = self.count *| (std.time.us_per_s / per_second) };
        }

        /// The decimal digits, which is what a path param, a query field and a
        /// keyset cursor carry (`nilo_parse` is what makes a type one, ADR 113).
        pub fn nilo_parse(text: []const u8) ?Self {
            const n = std.fmt.parseInt(i64, text, 10) catch return null;
            return .{ .count = n };
        }

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.write(self.count);
        }

        pub fn jsonParse(
            gpa: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!Self {
            const token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
            const text = switch (token) {
                inline .number, .allocated_number => |slice| slice,
                else => return error.UnexpectedToken,
            };
            defer switch (token) {
                .allocated_number => gpa.free(text),
                else => {},
            };
            return nilo_parse(text) orelse error.InvalidCharacter;
        }

        pub fn jsonParseFromValue(
            gpa: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) std.json.ParseFromValueError!Self {
            _ = gpa;
            _ = options;
            return switch (source) {
                .integer => |n| .{ .count = n },
                else => error.UnexpectedToken,
            };
        }
    };
}

/// Unix milliseconds in an integer column: the unit JavaScript and most
/// observability stores keep.
pub const UnixMillis = Unix(.millis);
/// Unix seconds in an integer column.
pub const UnixSeconds = Unix(.seconds);

/// Whether `T` is a `Unix(unit)`, optional included. Asked by both Wires and
/// both Dialects, which treat one as the `i64` it travels as.
pub fn isUnix(comptime T: type) bool {
    return comptime blk: {
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        break :blk @typeInfo(Inner) == .@"struct" and @hasDecl(Inner, "nilo_unix");
    };
}

/// Whether `T` is the calendar day, optional included. Asked by both Wires,
/// which each decode it themselves — the same shape `isBytes` has and for the
/// same reason.
pub fn isDate(comptime T: type) bool {
    return comptime blk: {
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        break :blk Inner == Date;
    };
}

/// Sixteen bytes, in the order Postgres stores them — `nilo_id`'s type
/// rather than one of this module's own (ADR 038).
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
pub const Decimal = AsText("numeric");

/// A column read and written as **text**, whichever Postgres type it is.
///
/// This is the escape hatch the rest of this file used not to have. Every
/// other type here is one this module chose to know about; past them the wire
/// half was closed, so a project with an `interval`, an `inet`, a `money` or
/// a PostGIS `geometry` could name the column in a schema check and then not
/// read it. `AsText` opens it, and it opens it with the one representation
/// Postgres guarantees for everything it has: `column::text` on the way out,
/// `$1::interval` on the way in.
///
/// ```zig
/// const Money = sql.AsText("money");
///
/// const Sale = struct {
///     pub const nilo_table = .{ .name = "sales", .key = .id };
///     id: i64,
///     amount: Money,
/// };
/// ```
///
/// The value is the text Postgres prints, kept in the request arena like any
/// other text a row comes back with, and written into JSON as a string. What
/// it means is the caller's business — this type carries a value and knows
/// how to write itself, which is the line every type in this file holds.
///
/// **A project that wants structure rather than text writes the protocol
/// itself** rather than using this: any struct or enum with `nilo_column`,
/// `nilo_read(text, arena)` and `nilo_write(arena)` is a column type, and
/// this is that protocol's smallest instance
/// ([ADR 049](../docs/adr/049-a-column-type-can-come-from-outside-this-module.md)).
pub fn AsText(comptime column: []const u8) type {
    return struct {
        const Self = @This();

        /// Exactly what Postgres printed: `1234.56`, `3 days 04:05:06`,
        /// `192.168.0.1/24`.
        text: []const u8,

        pub const nilo_column = column;

        /// Text on the wire, and said out loud so a generated client is told
        /// so (ADR 016). No `format`: what `AsText("money")` holds is
        /// whatever Postgres printed, and naming a format would be a claim
        /// about a column this type deliberately knows nothing about.
        pub const nilo_openapi = .{ .type = "string" };

        /// Kept, because the bytes handed over are the driver's read buffer
        /// and die at the next row (`wire.zig`).
        pub fn nilo_read(raw: []const u8, arena: std.mem.Allocator) !Self {
            return .{ .text = try arena.dupe(u8, raw) };
        }

        /// The text as it stands. Nothing to build, so the arena goes unused
        /// — a type that has to format itself is the reason the parameter is
        /// there at all.
        pub fn nilo_write(self: Self, arena: std.mem.Allocator) ![]const u8 {
            _ = arena;
            return self.text;
        }

        pub fn jsonStringify(self: Self, jw: anytype) !void {
            try jw.write(self.text);
        }
    };
}

/// Bytes rather than text — a `bytea` or a `BLOB`. Declared in `wire.zig`
/// because both Wires have to name it and `postgres.zig` imports that file and
/// not this one; re-exported here so a Row writes `sql.Bytes` beside
/// `sql.Timestamp` and `sql.Uuid` rather than reaching into the Wire.
pub const Bytes = @import("wire.zig").Bytes;

/// Whether `T` is the binary column, optional included.
///
/// Asked before `declaredColumn` and before the pointer branch in every
/// `accepts`, because both of those answer `text` for it — which is the whole
/// reason a binary column could not be named until this type existed.
pub fn isBytes(comptime T: type) bool {
    return comptime blk: {
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        break :blk Inner == Bytes;
    };
}

/// A `interval` column, as Postgres prints it — `3 days 04:05:06`.
///
/// Text rather than a struct of months, days and microseconds, for the reason
/// at the top of this file: an interval is only *useful* as a struct if
/// something adds it to a date, and calendar arithmetic is the half of a date
/// library that has nothing to do with a database.
pub const Interval = AsText("interval");

/// An `inet` column — an address, with an optional mask: `192.168.0.1/24`,
/// `::1`. `cidr` is `AsText("cidr")` and is a different column type, so it is
/// not this one under another name.
pub const Inet = AsText("inet");

/// Whether `T` is a number carried as text: `Decimal`, or any
/// `AsText("numeric")`, optional included. The one question a Dialect that
/// stores it as text has to be asked before it orders, compares or sums it,
/// because there `"100.00" < "9.99"` (ADR 049, `dialect.decimal_compares`).
pub fn isNumericText(comptime T: type) bool {
    return comptime blk: {
        const column = asText(T) orelse break :blk false;
        break :blk std.mem.eql(u8, column, "numeric");
    };
}

/// The Postgres type a text column names, or null when `T` is not one.
///
/// A type is one when it carries `nilo_read` and `nilo_write` beside its
/// `nilo_column`. Carrying one of the pair and not the other is a Refusal
/// rather than a type quietly treated as something else: the two are how a
/// value gets there and back, and half of that is a column that can be
/// written and never read.
pub fn asText(comptime T: type) ?[]const u8 {
    return comptime blk: {
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };
        switch (@typeInfo(Inner)) {
            .@"struct", .@"enum" => {},
            else => break :blk null,
        }

        const reads = @hasDecl(Inner, "nilo_read");
        const writes = @hasDecl(Inner, "nilo_write");
        if (!reads and !writes) break :blk null;
        if (reads != writes) @compileError(
            "nilo: " ++ @typeName(Inner) ++ " is being used as a column type and has `" ++
                (if (reads) "nilo_read" else "nilo_write") ++ "` without `" ++
                (if (reads) "nilo_write" else "nilo_read") ++ "`.\n" ++
                "  A column type travels both ways: `nilo_read(text, arena)` builds one " ++
                "out of what Postgres printed, `nilo_write(arena)` gives back the text to " ++
                "send. `sql.AsText(\"…\")` is both of them for a type that is just the text.",
        );

        break :blk declaredColumn(Inner) orelse @compileError(
            "nilo: " ++ @typeName(Inner) ++ " reads and writes itself as text and has not " ++
                "said which column it is.\n" ++
                "  Add `pub const nilo_column = \"interval\"` — the Postgres type name, " ++
                "which is what the cast on both sides of the wire has to spell and what " ++
                "the schema check compares against.",
        );
    };
}

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

/// A type's name for a compile error: `nilo_type_name` when it has one, so a
/// `Timestamp` is not spelled with the `nilo_core` file it was declared in,
/// looking through an optional and a slice. `@typeName` otherwise, which is
/// the reader's own file for a reader's own type (ADR 074).
pub fn nameOf(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .optional => |o| "?" ++ nameOf(o.child),
        .pointer => |p| if (p.size == .slice) (if (p.attrs.@"const") "[]const " else "[]") ++ nameOf(p.child) else @typeName(T),
        .@"struct" => if (@hasDecl(T, "nilo_type_name")) T.nilo_type_name else @typeName(T),
        else => @typeName(T),
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
    // the answer for it is here rather than on the type (ADR 038). Every
    // other type this module owns says so itself.
    if (T == Uuid) return "uuid";
    // The same for the two `nilo_core` time types: a Core type does not name
    // a Postgres type (ADR 038, ADR 057).
    if (T == Timestamp) return "timestamptz";
    if (T == Date) return "date";
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


test "the wire counts from 2000 and the type counts from 1970" {
    // One shift, in the Wire, so nothing above it has to know — the same
    // arrangement `Timestamp` has for microseconds.
    try testing.expectEqual(@as(i32, 0), Date.nilo_parse("1970-01-01").?.days);
    try testing.expectEqual(
        date_days_from_epoch_to_y2k,
        Date.nilo_parse("2000-01-01").?.days,
    );
}

test "a Date is read out of the column rather than out of a ::text" {
    // The whole difference from `sql.AsText("date")`, and it is one answer:
    // `asText` is null, so the Dialect writes no cast in the SELECT list and
    // `db.raw` needs none either.
    try testing.expectEqual(@as(?[]const u8, null), asText(Date));
    try testing.expectEqualStrings("date", declaredColumn(Date).?);
    try testing.expect(isDate(Date));
    try testing.expect(isDate(?Date));
    try testing.expect(!isDate(Timestamp));
    try testing.expect(!isDate(i32));
}

test "a uuid column and a generated key are the same type" {
    // Not a tautology: two modules built from the same root file are two
    // different modules to Zig, so a second `nilo_id` in the build graph
    // would make `id.v7()` something `db.insert` refuses to bind. Nothing
    // would fail to compile in either module on its own (ADR 038).
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

test "only a numeric text column is a number held as text" {
    try testing.expect(isNumericText(Decimal));
    try testing.expect(isNumericText(?Decimal));
    try testing.expect(isNumericText(AsText("numeric")));
    // Other text columns are not asked to order as numbers, and a plain
    // integer or string never is.
    try testing.expect(!isNumericText(Interval));
    try testing.expect(!isNumericText(Inet));
    try testing.expect(!isNumericText(i64));
    try testing.expect(!isNumericText([]const u8));
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

test "a text column is recognised through an optional, because a column may be null" {
    try testing.expectEqualStrings("numeric", asText(Decimal).?);
    try testing.expectEqualStrings("numeric", asText(?Decimal).?);
    try testing.expectEqual(@as(?[]const u8, null), asText(f64));
    try testing.expectEqual(@as(?[]const u8, null), asText([]const u8));
    // The other types with an opinion about their column are not text
    // columns: each has a shape on the wire this module already decodes.
    try testing.expectEqual(@as(?[]const u8, null), asText(Timestamp));
    try testing.expectEqual(@as(?[]const u8, null), asText(Uuid));
    try testing.expectEqual(@as(?[]const u8, null), asText(Json(struct { a: u8 })));
}

test "the text columns this module ships name the postgres types they are" {
    try testing.expectEqualStrings("numeric", asText(Decimal).?);
    try testing.expectEqualStrings("interval", asText(Interval).?);
    try testing.expectEqualStrings("inet", asText(Inet).?);
    // And one a project declared, which is the point of the escape hatch.
    const Money = AsText("money");
    try testing.expectEqualStrings("money", asText(Money).?);
    try testing.expectEqualStrings("money", declaredColumn(Money).?);
}

test "a text column keeps what it was given rather than the read buffer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buffer = [_]u8{ '1', '.', '5' };
    const held = try Decimal.nilo_read(&buffer, arena.allocator());
    // The bytes the driver hands over die at the next row, so a column type
    // that pointed at them would be a dangling read one statement later.
    buffer = [_]u8{ '9', '9', '9' };
    try testing.expectEqualStrings("1.5", held.text);

    const back = try held.nilo_write(arena.allocator());
    try testing.expectEqualStrings("1.5", back);
}

test "a text column keeps a name a reader can act on" {
    // `AsText` is a generic, so its instances are named after the call. That
    // name reaches every Refusal that prints a column type, which is the one
    // place a reader sees it — `types.AsText("numeric")` says both what it is
    // and which column, where a bare `Decimal` said only the first.
    try testing.expect(std.mem.indexOf(u8, @typeName(Decimal), "numeric") != null);
    try testing.expect(std.mem.indexOf(u8, @typeName(Interval), "interval") != null);
}

test "two text columns of different types are two types" {
    // Not a tautology: they are the same struct body, and if the column name
    // did not reach the type then an `interval` would bind as an `inet`.
    try testing.expect(Interval != Inet);
    try testing.expect(AsText("money") == AsText("money"));
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

test "a UnixMillis crosses to a Timestamp by one multiply, and back by one floor division" {
    const ms = UnixMillis{ .count = 1_790_846_995_323 };
    try testing.expectEqual(@as(i64, 1_790_846_995_323_000), ms.toTimestamp().micros);
    try testing.expectEqual(ms.count, UnixMillis.fromTimestamp(ms.toTimestamp()).count);
    // Before 1970 truncates toward the past, not toward zero.
    try testing.expectEqual(@as(i64, -1), UnixMillis.fromTimestamp(.{ .micros = -1 }).count);
    try testing.expectEqual(@as(i64, 7), UnixSeconds.fromTimestamp(.{ .micros = 7_999_999 }).count);
    try testing.expectEqual(@as(i64, 7_000_000), (UnixSeconds{ .count = 7 }).toTimestamp().micros);
}

test "a count that is no moment saturates instead of overflowing, and then will not print" {
    const absurd = UnixMillis{ .count = std.math.maxInt(i64) };
    try testing.expectEqual(std.math.maxInt(i64), absurd.toTimestamp().micros);
    var buf: [40]u8 = undefined;
    try testing.expectError(error.OutOfRange, textOf(absurd.toTimestamp(), &buf));
}

test "a Unix count is a number in JSON both ways, and the type says so" {
    const gpa = testing.allocator;
    const out = try std.json.Stringify.valueAlloc(gpa, UnixMillis{ .count = 42 }, .{});
    defer gpa.free(out);
    try testing.expectEqualStrings("42", out);

    const back = try std.json.parseFromSlice(UnixSeconds, gpa, "1790846995", .{});
    defer back.deinit();
    try testing.expectEqual(@as(i64, 1_790_846_995), back.value.count);
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(UnixSeconds, gpa, "\"2026\"", .{}));

    try testing.expect(isUnix(UnixMillis) and isUnix(?UnixSeconds));
    try testing.expect(!isUnix(Timestamp) and !isUnix(i64));
    try testing.expectEqual(@as(?UnixMillis, null), UnixMillis.nilo_parse("12ms"));
}

test "Timestamp and Date are nilo_core's types, and the column they belong in is answered here" {
    try testing.expect(Timestamp == core.Timestamp);
    try testing.expect(Date == core.Date);
    try testing.expectEqualStrings("timestamptz", declaredColumn(Timestamp).?);
    try testing.expect(!@hasDecl(core.Timestamp, "nilo_column"));
    try testing.expect(!@hasDecl(core.Date, "nilo_column"));
}
