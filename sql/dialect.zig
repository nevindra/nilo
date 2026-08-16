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
                    "zfast: the column name `" ++ ident ++ "` contains a quote.\n" ++
                        "  A column name comes from a Zig field name, and one written " ++
                        "with `@\"…\"` can hold characters SQL cannot.",
                );
            }
            break :blk "\"" ++ ident ++ "\"";
        };
    }

    pub const list_form: ListForm = .any_array;

    /// `LIMIT`/`OFFSET`, which most dialects agree on and one day one will not.
    pub fn limit(comptime placeholder_text: []const u8) []const u8 {
        return " LIMIT " ++ placeholder_text;
    }

    pub fn offset(comptime placeholder_text: []const u8) []const u8 {
        return " OFFSET " ++ placeholder_text;
    }

    /// What the schema comparison asks, once, on the first connection that
    /// succeeds. `udt_name` rather than `data_type` because it answers `int4`
    /// and `timestamptz` — the names anyone writing a migration typed — where
    /// `data_type` answers `integer` and `timestamp with time zone`.
    pub const introspect =
        \\SELECT column_name, udt_name, is_nullable
        \\FROM information_schema.columns
        \\WHERE table_schema = current_schema() AND table_name = $1
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

        if (types.declaredColumn(Inner)) |declared| {
            if (std.mem.eql(u8, declared, "timestamptz")) return &.{ "timestamptz", "timestamp" };
            if (std.mem.eql(u8, declared, "jsonb")) return &.{ "jsonb", "json" };
            const one = [_][]const u8{declared};
            return &one;
        }

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
            "name",     "placeholder", "quote", "list_form",
            "limit",    "offset",      "accepts", "introspect",
        };
        for (owed) |decl| {
            if (!@hasDecl(D, decl)) @compileError(
                "zfast: " ++ @typeName(D) ++ " is being used as a Dialect and has no `" ++
                    decl ++ "`.\n" ++
                    "  What a Dialect owes is listed at the top of `sql/dialect.zig`.",
            );
        }
    }
}

/// The message `in` stops with on a Dialect that cannot write one. Here
/// rather than in the walker so that every refusal a Dialect makes reads the
/// same way.
pub fn noListForm(comptime D: type, comptime column: []const u8) noreturn {
    @compileError(
        "zfast: the " ++ D.name ++ " dialect has no `in`, asked for on column `" ++
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

test "postgres takes a list as one value, so a statement stays a constant" {
    try testing.expectEqual(ListForm.any_array, Postgres.list_form);
}

test "postgres satisfies the contract this module asks of a Dialect" {
    comptime assertDialect(Postgres);
}
