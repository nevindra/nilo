//! The half that writes the SQL — the entire contract this module asks of a
//! database's grammar, listed here the way `bulkhead.zig` lists the Engine's
//! (ADR 0039).
//!
//! There are two seams rather than one, because two different things get
//! replaced and they get replaced independently. Swapping the Postgres driver
//! changes how bytes reach the socket and leaves the SQL identical; adding a
//! second database changes the SQL itself, long before anything reaches a seam
//! placed at the socket. So: a Dialect writes, a Wire speaks.
//!
//! **A Dialect is entirely comptime and touches no I/O.** That is not a
//! coincidence, it is the line the code already split along — which is why
//! fitting the seam now costs a call to `placeholder` instead of a literal
//! `$`, and fitting it later would cost a rewrite of every generated string.
//!
//! A Dialect is also allowed to **refuse**. Postgres writes `in` as
//! `= ANY($1)`, which keeps the SQL a constant however long the list is;
//! SQLite has no arrays and would have to expand the list into placeholders,
//! which makes the statement depend on a runtime length and breaks ADR 0039's
//! rule. A Dialect that cannot express something says so at compile time
//! rather than emitting something that means something else.
//!
//! What ships is one Dialect. The point of the seam is that `$1` is not
//! hardcoded, not that a second one exists yet.

const std = @import("std");
const core = @import("nilo_core");
const types = @import("types.zig");

/// How a Dialect spells a list membership test, asked by the where walker
/// before it writes one.
pub const ListForm = enum {
    /// `col = ANY($1)`, one parameter carrying an array. The statement stays
    /// a constant whatever the list length is.
    any_array,
    /// `col IN ($1, $2, …)`, one placeholder per element. Correct SQL, and it
    /// makes the statement depend on a length only known at runtime.
    expanded,
    /// Not available. `in` becomes a Refusal naming the Dialect.
    unsupported,
};

/// What a Dialect will accept in a column for a given Zig type, or `null`
/// when it declines to judge — an enum read as a Postgres enum has a type
/// name that comes from the database rather than from Zig, and guessing it
/// would fail honest schemas.
pub const Accepts = ?[]const []const u8;

/// How a read holds on to the rows it matched, until the transaction around
/// it ends. Written as `.lock = .update` in a select's options.
///
/// Four rather than the eight Postgres has, and the four are the jobs: hold a
/// row to change it, fail rather than queue, take the next one nobody is
/// holding, and stop a row changing while it is read. `FOR NO KEY UPDATE` and
/// `FOR KEY SHARE` are weaker forms that exist to reduce contention between
/// foreign keys, which is a tuning answer rather than a shape — `db.raw`
/// writes one where it is measured to matter.
pub const Lock = enum {
    /// Hold every matching row against another writer, and wait for anyone
    /// already holding it. The read half of read-modify-write.
    update,
    /// The same, except that a row somebody else holds fails the statement
    /// immediately with `error.Locked` rather than waiting.
    update_nowait,
    /// The same, except that a row somebody else holds is left out of the
    /// answer. A work queue: several workers run the same statement and each
    /// one gets rows none of the others has.
    update_skip_locked,
    /// Hold every matching row against a writer, and let other readers hold
    /// it too. For a read whose answer must still be true at commit.
    share,
};

/// Postgres, and for now the only one.
pub const Postgres = struct {
    pub const name = "postgres";

    /// Numbered from one, and numbered by the walker rather than counted
    /// here, so a condition that writes two parameters cannot lose track.
    pub fn placeholder(comptime n: usize) []const u8 {
        return "$" ++ std.fmt.comptimePrint("{d}", .{n});
    }

    /// Identifiers are always quoted. Not for safety — every identifier here
    /// is a Zig field name, and the request never supplies one — but because
    /// unquoted Postgres folds to lowercase and reserves words. A column
    /// honestly named `order` or `user` is a syntax error unquoted, and a
    /// field named `userId` would silently look for `userid`.
    pub fn quote(comptime ident: []const u8) []const u8 {
        return comptime blk: {
            for (ident) |ch| {
                if (ch == '"') @compileError(
                    "nilo: the column name `" ++ ident ++ "` contains a quote.\n" ++
                        "  A column name comes from a Zig field name, and one written " ++
                        "with `@\"…\"` can hold characters SQL cannot.",
                );
            }
            break :blk "\"" ++ ident ++ "\"";
        };
    }

    /// A relation, quoted, with its schema in front when it has one.
    ///
    /// Two identifiers rather than one, which is the whole of the bug this
    /// replaces: `quote("app.users")` produced `"app.users"`, a single
    /// identifier with a dot in its name, and Postgres then looked for a table
    /// nobody had created. A dialect with no schemas answers by ignoring the
    /// first half, which is why this is the Dialect's call and not the Row's.
    pub fn qualify(comptime schema: ?[]const u8, comptime table: []const u8) []const u8 {
        return comptime if (schema) |s| quote(s) ++ "." ++ quote(table) else quote(table);
    }

    pub const list_form: ListForm = .any_array;

    /// `LIMIT`/`OFFSET`, which most dialects agree on and one day one will not.
    pub fn limit(comptime placeholder_text: []const u8) []const u8 {
        return " LIMIT " ++ placeholder_text;
    }

    pub fn offset(comptime placeholder_text: []const u8) []const u8 {
        return " OFFSET " ++ placeholder_text;
    }

    /// How this Dialect spells a row lock, or `null` when it has none — a
    /// database with one writer at a time has nothing to say here, and the
    /// caller gets a Refusal naming it rather than a lock that silently is
    /// not one.
    ///
    /// It goes on the end, after `LIMIT` and `OFFSET`, because that is where
    /// the grammar puts it and because the rows it locks are the rows that
    /// came back.
    pub fn lock(comptime mode: Lock) ?[]const u8 {
        return switch (mode) {
            .update => " FOR UPDATE",
            .update_nowait => " FOR UPDATE NOWAIT",
            .update_skip_locked => " FOR UPDATE SKIP LOCKED",
            .share => " FOR SHARE",
        };
    }

    /// How a column of type `T` is asked for in a `SELECT` list, given its
    /// quoted name.
    ///
    /// Everything is asked for as itself except a **text column** — a type
    /// that reads and writes itself as the text Postgres prints, which is
    /// `Decimal`, `Interval`, `Inet` and anything a project declared the same
    /// way (ADR 0055). Those are asked for as `::text`, because that is the
    /// one representation every Postgres type has and the only one a module
    /// that does not know the type can decode.
    ///
    /// **Measured on `numeric`, and it is not load-bearing there today.**
    /// With the cast removed, the live round trip still comes back with every
    /// digit intact, so pg.zig is handing that column over as text already.
    /// What the cast buys is that the answer stops depending on a driver's
    /// choice of result format — which is a choice nilo does not make, did not
    /// design, and would find out about by getting binary where it expected
    /// digits. For a type the driver has never heard of it is load-bearing on
    /// both sides.
    ///
    /// Column *names* do not matter here: this module reads by position
    /// because the caller wrote the `SELECT` list (ADR 0039), so a cast that
    /// changes what Postgres would have called the column changes nothing.
    pub fn readAs(comptime quoted: []const u8, comptime T: type) []const u8 {
        return if (comptime types.asText(T) != null) quoted ++ "::text" else quoted;
    }

    /// How a value of type `T` is bound, given its placeholder — the mirror
    /// of `readAs`.
    ///
    /// A text column binds as its text and is cast back to the type it named:
    /// `$1::numeric`, `$1::interval`. **This half is load-bearing even where
    /// the read half is not.** For a `Decimal` the alternative is pg.zig's
    /// `Numeric` encoder, which takes a float and prints it — exactly the trip
    /// through binary floating point that a `numeric` column is chosen to
    /// avoid; for a type the driver has never heard of there is no encoder at
    /// all, and the cast is what makes text enough.
    ///
    /// `list` is `.in` and `.not_in`, where one placeholder holds the whole
    /// list and the cast has to name an array.
    pub fn bindAs(
        comptime placeholder_text: []const u8,
        comptime T: type,
        comptime list: bool,
    ) []const u8 {
        return comptime blk: {
            const named = types.asText(T) orelse break :blk placeholder_text;
            break :blk placeholder_text ++ "::" ++ named ++ if (list) "[]" else "";
        };
    }

    /// How a whole column's worth of values is named in a statement that
    /// sends a batch as one parameter per column — `$1::int8[]` — or `null`
    /// when this Dialect cannot name the type.
    ///
    /// The cast is not decoration. `unnest($1)` gives Postgres nothing to
    /// infer a parameter type from, and it answers *could not determine data
    /// type of parameter $1* rather than guessing. So the array form has to be
    /// written out, and the name comes from the same table the schema check
    /// reads: the first entry of `accepts` is the column type this Dialect
    /// would expect, and the widening alternatives after it are for judging a
    /// column rather than for naming one.
    ///
    /// A column whose own type is a list has no array form — `unnest` on a
    /// two-dimensional array flattens it, which would insert one row per
    /// element rather than one per array. `null`, and the caller gets a
    /// Refusal naming the column.
    pub fn arrayOf(comptime T: type) ?[]const u8 {
        return comptime blk: {
            if (types.listElement(T) != null) break :blk null;
            // Digits, cast twice — the array form of what `bindAs` does to a
            // single `numeric`, and for the same reason. `$1::numeric[]`
            // alone would have the driver encode the text as binary numeric
            // limbs; `::text[]` first says what is actually on the wire and
            // lets Postgres do the conversion it is good at.
            if (types.asText(T)) |named| break :blk "text[]::" ++ named ++ "[]";
            // The document, cast the same way, and this one is a workaround
            // rather than a design. pg.zig's `jsonb[]` encoder reserves five
            // bytes of prefix for every element and writes four for a NULL —
            // the version byte it counted is not written — so an array with a
            // NULL in it is a byte too long and Postgres answers *incorrect
            // binary data format*. Its `text[]` encoder gets the same case
            // right, so the digits-and-cast route is taken here too. Delete
            // this line when pg.zig's `encodeNullables` sizes what it writes.
            const Inner = switch (@typeInfo(T)) {
                .optional => |o| o.child,
                else => T,
            };
            if (types.jsonPayload(Inner) != null) break :blk "text[]::jsonb[]";
            const named = acceptsInner(T) orelse break :blk null;
            break :blk named[0] ++ "[]";
        };
    }

    /// What the schema comparison asks, once, on the first connection that
    /// succeeds. `udt_name` rather than `data_type` because it answers `int4`
    /// and `timestamptz` — the names anyone writing a migration typed — where
    /// `data_type` answers `integer` and `timestamp with time zone`.
    ///
    /// Two parameters: the schema, which is null for a Row that named none and
    /// then means whatever `search_path` resolves to, and the table.
    /// `information_schema.columns` covers views and materialized-view-backed
    /// relations as well as tables, so a Row over a view is introspected by
    /// the same query with nothing added.
    pub const introspect =
        \\SELECT column_name, udt_name, is_nullable
        \\FROM information_schema.columns
        \\WHERE table_schema = COALESCE($1, current_schema()) AND table_name = $2
        \\ORDER BY ordinal_position
    ;

    /// The column types this Dialect will read `T` out of.
    ///
    /// Deliberately a list rather than one name: `text` and `varchar` are the
    /// same thing to a reader, and refusing a `varchar(255)` because the Row
    /// said `Str` would be a check that fails on correct schemas — which is
    /// the fastest way to teach somebody to turn a check off.
    /// **Comptime, and the `comptime` keyword here is load-bearing.** Without
    /// it the `&.{…}` below is the address of a temporary: correct in Debug,
    /// where the bytes happen to still be there, and an empty string in
    /// ReleaseSafe. The suite caught it in the mode people deploy in, which is
    /// what having both modes is for.
    pub fn accepts(comptime T: type) Accepts {
        return comptime acceptsInner(T);
    }

    fn acceptsInner(comptime T: type) Accepts {
        const Inner = switch (@typeInfo(T)) {
            .optional => |o| o.child,
            else => T,
        };

        // Text, in the spelling this framework prefers. `Str` comes from Core,
        // which knows nothing about databases, so the answer for it is here
        // rather than on the type — the same arrangement `declaredColumn`
        // makes for `Uuid`, and for the same reason (ADR 0042).
        if (Inner == core.Str) return &.{ "text", "varchar", "bpchar", "char", "name" };

        if (types.declaredColumn(Inner)) |declared| {
            if (std.mem.eql(u8, declared, "timestamptz")) return &.{ "timestamptz", "timestamp" };
            if (std.mem.eql(u8, declared, "jsonb")) return &.{ "jsonb", "json" };
            const one = [_][]const u8{declared};
            return &one;
        }

        // A list column, judged by what it holds. **Exact rather than
        // widening, which is the opposite of the scalar rule below**: an
        // `int4` reads into an `i64` happily, and an `int4[]` does not read
        // into a `[]const i64` at all, because the driver picks its element
        // decoder off the array's own OID and refuses a mismatch. Accepting
        // `_int8` for a `[]const i32` here would move that refusal from
        // `checking` at startup to the first request that reads the column.
        if (types.listElement(Inner)) |Item| return listAccepts(Item);

        return switch (@typeInfo(Inner)) {
            .bool => &.{"bool"},
            .float => |f| switch (f.bits) {
                32 => &.{"float4"},
                64 => &.{ "float8", "float4" },
                else => null,
            },
            .int => |i| intAccepts(i),
            // A Zig enum reads out of `text`, out of a `varchar`, or out of a
            // Postgres enum whose type name lives in the database and cannot
            // be derived from this side. Judging the third would fail honest
            // schemas, so this declines rather than guesses.
            .@"enum" => null,
            .pointer => |p| if (p.size == .slice and p.child == u8)
                &.{ "text", "varchar", "bpchar", "char", "name" }
            else
                null,
            .@"struct" => null,
            else => null,
        };
    }

    /// The array types a list of `Item` may be read out of. `null` means this
    /// Dialect will not judge it, and `checking` then says so with the column
    /// named — which beats the driver's own `@compileError` from four frames
    /// inside pg.zig, which is what a Row reading an array used to get.
    fn listAccepts(comptime Item: type) Accepts {
        // A slice of optionals is how a column that holds NULLs among its
        // elements is read, and it is the same array type either way — the
        // null flag lives in the value rather than in the column.
        const Bare = switch (@typeInfo(Item)) {
            .optional => |o| o.child,
            else => Item,
        };

        // Text has three spellings in a column and two as an array element:
        // a `Str` and a `[]const u8` are the same bytes to a reader.
        if (Bare == core.Str) return &.{ "_text", "_varchar" };

        return switch (@typeInfo(Bare)) {
            .bool => &.{"_bool"},
            .float => |f| switch (f.bits) {
                32 => &.{"_float4"},
                64 => &.{"_float8"},
                else => null,
            },
            .int => |i| if (i.signedness == .unsigned) null else switch (i.bits) {
                16 => &.{"_int2"},
                32 => &.{"_int4"},
                64 => &.{"_int8"},
                // Postgres has no unsigned array element and no width between
                // these, so widening a `u32` the way the scalar rule does
                // would name an array the driver cannot decode into it.
                else => null,
            },
            .pointer => |p| if (p.size == .slice and p.child == u8)
                &.{ "_text", "_varchar" }
            else
                null,
            else => null,
        };
    }

    fn intAccepts(comptime info: std.builtin.Type.Int) Accepts {
        // Postgres has no unsigned integers, so an unsigned Zig type reads
        // out of the next width up — the one that can hold all of it.
        const effective = if (info.signedness == .signed) info.bits else info.bits + 1;
        return switch (effective) {
            0...16 => &.{ "int2", "int4", "int8" },
            17...32 => &.{ "int4", "int8" },
            33...64 => &.{"int8"},
            else => null,
        };
    }
};

/// Everything a Dialect owes, checked where it is handed over rather than at
/// the first call that happens to need a missing piece. The same reason
/// `service.zig` checks the registry at `listen()`.
pub fn assertDialect(comptime D: type) void {
    comptime {
        const owed = [_][]const u8{
            "name",   "placeholder", "quote",   "list_form",
            "limit",  "offset",      "accepts", "introspect",
            "readAs", "bindAs",      "arrayOf", "qualify",
            "lock",
        };
        for (owed) |decl| {
            if (!@hasDecl(D, decl)) @compileError(
                "nilo: " ++ @typeName(D) ++ " is being used as a Dialect and has no `" ++
                    decl ++ "`.\n" ++
                    "  What a Dialect owes is listed at the top of `sql/dialect.zig`.",
            );
        }
    }
}

/// The message a `.lock` stops with on a Dialect that has no row locks. Its
/// database serialises writers some other way, so the honest answer is a
/// Refusal rather than a select that quietly holds nothing.
pub fn noRowLock(comptime D: type, comptime Row: type) noreturn {
    @compileError(
        "nilo: the " ++ D.name ++ " dialect has no row lock, asked for by a read of " ++
            @typeName(Row) ++ ".\n" ++
            "  Its database does not let one transaction hold a row against another, " ++
            "so there is nothing to write that would mean what `.lock` means.",
    );
}

/// The message `in` stops with on a Dialect that cannot write one. Here
/// rather than in the walker so that every refusal a Dialect makes reads the
/// same way.
pub fn noListForm(comptime D: type, comptime column: []const u8) noreturn {
    @compileError(
        "nilo: the " ++ D.name ++ " dialect has no `in`, asked for on column `" ++
            column ++ "`.\n" ++
            "  Its database cannot take a list as one value, and expanding the list " ++
            "into placeholders would make the statement depend on a length that is " ++
            "not known while compiling.",
    );
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "postgres numbers its placeholders from one" {
    try testing.expectEqualStrings("$1", Postgres.placeholder(1));
    try testing.expectEqualStrings("$12", Postgres.placeholder(12));
}

test "an identifier comes out quoted, so a reserved word is still a column" {
    try testing.expectEqualStrings("\"users\"", Postgres.quote("users"));
    try testing.expectEqualStrings("\"order\"", Postgres.quote("order"));
    try testing.expectEqualStrings("\"userId\"", Postgres.quote("userId"));
}

test "an integer reads out of its own width and anything wider" {
    try testing.expectEqualStrings("int8", Postgres.accepts(i64).?[0]);
    try testing.expectEqual(@as(usize, 2), Postgres.accepts(i32).?.len);
    try testing.expectEqualStrings("int4", Postgres.accepts(i32).?[0]);
    try testing.expectEqualStrings("int8", Postgres.accepts(i32).?[1]);
}

test "an unsigned integer reads out of the width that can hold all of it" {
    // u32 does not fit int4, so int8 is the narrowest honest answer.
    try testing.expectEqual(@as(usize, 1), Postgres.accepts(u32).?.len);
    try testing.expectEqualStrings("int8", Postgres.accepts(u32).?[0]);
    try testing.expectEqual(@as(Accepts, null), Postgres.accepts(u64));
}

test "text reads out of every spelling of text" {
    const accepted = Postgres.accepts([]const u8).?;
    try testing.expectEqualStrings("text", accepted[0]);
    try testing.expectEqualStrings("varchar", accepted[1]);
}

test "an optional column is judged by what it wraps" {
    try testing.expectEqualStrings("int8", Postgres.accepts(?i64).?[0]);
    try testing.expectEqualStrings("text", Postgres.accepts(?[]const u8).?[0]);
}

test "a type that names its own column is taken at its word" {
    try testing.expectEqualStrings("uuid", Postgres.accepts(types.Uuid).?[0]);
    try testing.expectEqualStrings("timestamptz", Postgres.accepts(types.Timestamp).?[0]);
    try testing.expectEqualStrings("timestamp", Postgres.accepts(types.Timestamp).?[1]);
    try testing.expectEqualStrings("jsonb", Postgres.accepts(types.Json(struct { a: u8 })).?[0]);
}

test "an enum is not judged, because its type name lives in the database" {
    const Role = enum { admin, user };
    try testing.expectEqual(@as(Accepts, null), Postgres.accepts(Role));
}

test "a qualified relation is two identifiers, not one with a dot in it" {
    try testing.expectEqualStrings("\"app\".\"users\"", Postgres.qualify("app", "users"));
    try testing.expectEqualStrings("\"users\"", Postgres.qualify(null, "users"));
    // The bug this replaces: one identifier named `app.users`, which is a
    // relation nobody created.
    try testing.expectEqualStrings("\"app.users\"", Postgres.quote("app.users"));
}

test "a row lock is four spellings, and each one names a different job" {
    try testing.expectEqualStrings(" FOR UPDATE", Postgres.lock(.update).?);
    try testing.expectEqualStrings(" FOR UPDATE NOWAIT", Postgres.lock(.update_nowait).?);
    try testing.expectEqualStrings(" FOR UPDATE SKIP LOCKED", Postgres.lock(.update_skip_locked).?);
    try testing.expectEqualStrings(" FOR SHARE", Postgres.lock(.share).?);
}

test "postgres takes a list as one value, so a statement stays a constant" {
    try testing.expectEqual(ListForm.any_array, Postgres.list_form);
}

test "postgres satisfies the contract this module asks of a Dialect" {
    comptime assertDialect(Postgres);
}

test "a numeric column is asked for as text, and everything else as itself" {
    try testing.expectEqualStrings(
        "\"total\"::text",
        Postgres.readAs(Postgres.quote("total"), types.Decimal),
    );
    try testing.expectEqualStrings(
        "\"total\"::text",
        Postgres.readAs(Postgres.quote("total"), ?types.Decimal),
    );
    try testing.expectEqualStrings("\"age\"", Postgres.readAs(Postgres.quote("age"), i32));
    try testing.expectEqualStrings(
        "\"email\"",
        Postgres.readAs(Postgres.quote("email"), []const u8),
    );
}

test "a numeric is bound as digits and cast back, so nothing goes through a float" {
    try testing.expectEqualStrings(
        "$1::numeric",
        Postgres.bindAs(Postgres.placeholder(1), types.Decimal, false),
    );
    // `.in` puts the whole list in one parameter, so the cast names an array.
    try testing.expectEqualStrings(
        "$2::numeric[]",
        Postgres.bindAs(Postgres.placeholder(2), types.Decimal, true),
    );
    try testing.expectEqualStrings("$1", Postgres.bindAs(Postgres.placeholder(1), i64, false));
    try testing.expectEqualStrings("$1", Postgres.bindAs(Postgres.placeholder(1), i64, true));
}

test "a list column reads out of the array of what it holds" {
    try testing.expectEqualStrings("_text", Postgres.accepts([]const core.Str).?[0]);
    try testing.expectEqualStrings("_varchar", Postgres.accepts([]const core.Str).?[1]);
    try testing.expectEqualStrings("_text", Postgres.accepts([]const []const u8).?[0]);
    try testing.expectEqualStrings("_int4", Postgres.accepts([]const i32).?[0]);
    try testing.expectEqualStrings("_int8", Postgres.accepts([]const i64).?[0]);
    try testing.expectEqualStrings("_bool", Postgres.accepts([]const bool).?[0]);
    try testing.expectEqualStrings("_float8", Postgres.accepts([]const f64).?[0]);
}

test "an array is judged exactly, where a scalar is judged by what will hold it" {
    // An `int4` reads into an `i64`, so the scalar rule names both.
    try testing.expectEqual(@as(usize, 2), Postgres.accepts(i32).?.len);
    // An `int4[]` does not read into a `[]const i64` at all: the driver picks
    // its element decoder off the array's own OID. Naming `_int8` here would
    // move the refusal from startup to the first request.
    try testing.expectEqual(@as(usize, 1), Postgres.accepts([]const i32).?.len);
    try testing.expectEqualStrings("_int4", Postgres.accepts([]const i32).?[0]);
    // Postgres has no unsigned array element, and no width to widen into.
    try testing.expectEqual(@as(Accepts, null), Postgres.accepts([]const u32));
}

test "a list of optionals is the same column as a list, because NULL is a value" {
    try testing.expectEqualStrings("_text", Postgres.accepts([]const ?core.Str).?[0]);
    try testing.expectEqualStrings("_int4", Postgres.accepts([]const ?i32).?[0]);
    // And a nullable list column is judged by the list, the way every other
    // optional column is judged by what it wraps.
    try testing.expectEqualStrings("_int4", Postgres.accepts(?[]const i32).?[0]);
}

test "text is not a list, so a Str column is still a text column" {
    try testing.expectEqualStrings("text", Postgres.accepts([]const u8).?[0]);
    try testing.expectEqualStrings("text", Postgres.accepts(core.Str).?[0]);
}

test "a whole column's worth of values is named as an array of the column type" {
    try testing.expectEqualStrings("int8[]", Postgres.arrayOf(i64).?);
    try testing.expectEqualStrings("int4[]", Postgres.arrayOf(i32).?);
    try testing.expectEqualStrings("text[]", Postgres.arrayOf(core.Str).?);
    try testing.expectEqualStrings("text[]", Postgres.arrayOf([]const u8).?);
    // Two casts, because what is on the wire is the digits — the array form
    // of the `::numeric` a single one gets. A document goes the same way, for
    // a reason that is the driver's rather than Postgres's.
    try testing.expectEqualStrings("text[]::numeric[]", Postgres.arrayOf(types.Decimal).?);
    try testing.expectEqualStrings(
        "text[]::jsonb[]",
        Postgres.arrayOf(?types.Json(struct { a: u8 })).?,
    );
    try testing.expectEqualStrings("timestamptz[]", Postgres.arrayOf(types.Timestamp).?);
    try testing.expectEqualStrings("uuid[]", Postgres.arrayOf(types.Uuid).?);
    // A nullable column is the same array; NULL is a value in it.
    try testing.expectEqualStrings("int8[]", Postgres.arrayOf(?i64).?);
}

test "a column that is itself a list has no array form, because unnest flattens" {
    try testing.expectEqual(@as(?[]const u8, null), Postgres.arrayOf([]const i32));
    try testing.expectEqual(@as(?[]const u8, null), Postgres.arrayOf([]const core.Str));
    // And neither has an enum that has not said what it is called — its type
    // name lives in the database.
    try testing.expectEqual(@as(?[]const u8, null), Postgres.arrayOf(enum { a, b }));
}

test "a numeric column reads out of numeric and nothing else" {
    try testing.expectEqualStrings("numeric", Postgres.accepts(types.Decimal).?[0]);
    try testing.expectEqual(@as(usize, 1), Postgres.accepts(types.Decimal).?.len);
    // A float column is still a float column: `Decimal` is a choice about how
    // to read `numeric`, not a claim on every number.
    try testing.expectEqualStrings("float8", Postgres.accepts(f64).?[0]);
}
