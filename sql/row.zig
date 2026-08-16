//! A Row — a struct of the caller's own, one field per column, carrying the
//! marker that names its table (ADR 0039).
//!
//! ```zig
//! const User = struct {
//!     pub const nilo_table = .{ .name = "users", .key = .id };
//!
//!     id: i64,
//!     email: Str,
//!     age: i32,
//! };
//! ```
//!
//! The marker is the fourth of its kind. `nilo_resolve`, `nilo_query` and
//! `nilo_response` are the others, and `resolve.zig` asks that they all read
//! alike — so this is not a new mechanism, it is the one already in use.
//!
//! **The table name is written, never guessed.** `User` to `users` looks
//! clever until `Category`, and every framework that guesses ends up shipping
//! a list of irregular nouns. A rule that fits in one sentence beats a clever
//! one with exceptions. `.key` is the one thing allowed a default, because
//! `id` involves no guessing at all.
//!
//! A narrower Row — the two columns a list page needs, rather than the ten the
//! table has — names another Row instead of a table:
//!
//! ```zig
//! const UserCard = struct {
//!     pub const nilo_table = User;
//!
//!     id: i64,
//!     email: Str,
//! };
//! ```
//!
//! That is not a second concept. It is a Row whose table came from somewhere
//! else, and it is worth the overload for one reason: the fields are checked
//! against `User` **while compiling**, so a typo fails at `zig build` with no
//! database in the room. Written out longhand, the same typo would survive
//! until the schema comparison reached a live Postgres.
//!
//! Everything here answers a question about a type rather than about a
//! request, so all of it is settled before the binary exists — the first half
//! of ADR 0039's rule.

const std = @import("std");
/// Named here only so that `Borrowed` knows which field type means *text
/// that lives as long as the work does*. Nothing else in this file asks any
/// other layer anything — and what it asks is Core, not the framework
/// (ADR 0041).
const core = @import("nilo_core");
const types_mod = @import("types.zig");

/// The declaration a Row carries. Named the way `nilo_resolve`,
/// `nilo_query` and `nilo_response` are, so the markers the compile-time
/// engine looks for all read alike.
pub const marker = "nilo_table";

/// How far a Row may borrow another Row's table before this gives up. Nothing
/// legitimate nests this deep; the limit exists so that a type holding itself
/// stops with a message rather than an eval-quota crash. Same reason the
/// schema walker and the staleness trap have one.
const max_borrow_depth = 8;

/// Whether `T` is a Row. Asked before anything else, so that a plain struct
/// handed to `select` is refused by name rather than by a missing field.
pub fn isRow(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, marker),
        else => false,
    };
}

/// The table `Row` reads, following a borrowed marker to the Row that names
/// one. Every other entry point goes through here, so the chain is walked in
/// exactly one place.
pub fn tableOf(comptime Row: type) []const u8 {
    return comptime specOf(Row).name;
}

/// The column that identifies a row, as written text. `.key` defaults to `id`
/// when the Row has a field of that name and is required when it does not —
/// there is nothing to infer from a Row whose identity column is `user_id`.
pub fn keyOf(comptime Row: type) []const u8 {
    return comptime blk: {
        const spec = specOf(Row);
        const named = spec.key orelse {
            if (!hasColumn(Row, "id")) @compileError(
                "nilo: " ++ @typeName(Row) ++ " has no column `id`, so its " ++
                    marker ++ " has to say which column identifies a row.\n" ++
                    "  Write `.key = .<column>` alongside `.name`.",
            );
            break :blk "id";
        };
        if (!hasColumn(Row, named)) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s key names the column `" ++ named ++
                "`, which is not one of its columns.\n" ++
                "  The key has to be a column the Row reads, or nothing can " ++
                "identify what was read.",
        );
        break :blk named;
    };
}

/// The columns `Row` reads, in the order it declares them. This is the
/// `SELECT` list and the order results are filled in, so the two cannot drift.
pub fn columnsOf(comptime Row: type) []const []const u8 {
    return comptime blk: {
        assertRow(Row);
        const fields = @typeInfo(Row).@"struct".fields;
        var out: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| out[i] = f.name;
        const frozen = out;
        break :blk &frozen;
    };
}

/// `Row` with every `Str` replaced by `[]const u8`.
///
/// This is the shape a row takes when it is read one at a time: its text
/// belongs to the driver's read buffer and is good only until the next row
/// is pulled. `Str` means *text that lives as long as the request*, with no
/// asterisk — so text that does not is not called one. The type tells the
/// truth rather than hiding the rule behind a name that promises safety
/// (ADR 0039).
///
/// It is the same rule `Body.read` already followed by returning `[]u8`.
/// Nothing here is new; it is applied one layer over.
///
/// The result carries no `nilo_table`, so it is not itself a Row and cannot
/// be handed back to `select`. That is deliberate: what you may do with a
/// borrowed row is read it before the next `next()`, and nothing else.
pub fn Borrowed(comptime Row: type) type {
    return comptime blk: {
        assertRow(Row);
        const fields = @typeInfo(Row).@"struct".fields;
        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        for (fields, 0..) |f, i| {
            names[i] = f.name;
            types[i] = borrowedType(f.type);
        }
        const frozen_names = names;
        const frozen_types = types;
        // The field order is the Row's, which is also the `SELECT` list's,
        // which is also the order columns are read back in. One order, kept
        // in one place, so the three cannot drift.
        break :blk @Struct(.auto, null, &frozen_names, &frozen_types, &@splat(.{}));
    };
}

/// What one column's type becomes when the row is borrowed. Only `Str` moves;
/// an `i64` is a value and has nothing to outlive.
fn borrowedType(comptime T: type) type {
    comptime {
        if (T == core.Str) return []const u8;
        if (T == ?core.Str) return ?[]const u8;
        // A `Decimal` is digits rather than a number, so it points into the
        // read buffer exactly as text does and moves for the same reason. It
        // becomes `[]const u8` rather than a borrowed `Decimal`, because a
        // type whose whole content is a slice should say out loud how long
        // that slice is good for.
        if (types_mod.isDecimal(T)) return if (@typeInfo(T) == .optional) ?[]const u8 else []const u8;
        return T;
    }
}

/// Whether `Row` reads a column by that name. The one question the where
/// walker asks, and the one that turns a typo into a Refusal.
pub fn hasColumn(comptime Row: type, comptime column: []const u8) bool {
    return comptime blk: {
        for (@typeInfo(Row).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, column)) break :blk true;
        }
        break :blk false;
    };
}

/// The type `Row` reads a column into.
pub fn ColumnType(comptime Row: type, comptime column: []const u8) type {
    comptime {
        for (@typeInfo(Row).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, column)) return f.type;
        }
        @compileError("nilo: " ++ @typeName(Row) ++ " has no column `" ++ column ++ "`.");
    }
}

/// The column name closest to `wrong`, when one is close enough to be worth
/// naming. A message that says what was meant is the difference between a
/// Refusal that helps and one that only stops you (ADR 0027).
pub fn nearest(comptime Row: type, comptime wrong: []const u8) ?[]const u8 {
    return comptime blk: {
        var best: ?[]const u8 = null;
        var best_distance: usize = std.math.maxInt(usize);
        for (@typeInfo(Row).@"struct".fields) |f| {
            const d = distance(wrong, f.name);
            if (d < best_distance) {
                best_distance = d;
                best = f.name;
            }
        }
        // Past a third of the name, "did you mean" is a guess rather than a
        // help, and a wrong suggestion costs more than none.
        const room = @max(wrong.len, 1) / 3 + 1;
        break :blk if (best_distance <= room) best else null;
    };
}

/// The message a column that does not exist stops with. One function so that
/// every caller — the where walker, the order list, an update's `set` — says
/// it the same way.
pub fn noSuchColumn(
    comptime Row: type,
    comptime wrong: []const u8,
    comptime what: []const u8,
) noreturn {
    comptime {
        const head = "nilo: " ++ @typeName(Row) ++ " has no column `" ++ wrong ++
            "`, asked for in " ++ what ++ ".";
        if (nearest(Row, wrong)) |near| {
            @compileError(head ++ "\n  Did you mean `" ++ near ++ "`?");
        }
        @compileError(head ++ "\n  Its columns are: " ++ columnList(Row) ++ ".");
    }
}

/// The columns of `Row` as one readable line, for a message that has no
/// better suggestion to make than the whole list.
pub fn columnList(comptime Row: type) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (columnsOf(Row), 0..) |c, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ "`" ++ c ++ "`";
        }
        break :blk out;
    };
}

// -- the marker, and the chain it may point along ------------------------

const Spec = struct {
    name: []const u8,
    key: ?[]const u8,
};

/// The table spec `Row` resolves to, following `nilo_table = OtherRow` until
/// a spec that names a table is reached. Every borrowed Row is checked against
/// the one it borrows from on the way past, so the check cannot be skipped by
/// asking a question that does not need it.
fn specOf(comptime Row: type) Spec {
    comptime {
        assertRow(Row);
        var current = Row;
        var depth: usize = 0;
        while (depth < max_borrow_depth) : (depth += 1) {
            const decl = @field(current, marker);
            if (@TypeOf(decl) == type) {
                if (!isRow(decl)) @compileError(
                    "nilo: " ++ @typeName(current) ++ "'s " ++ marker ++ " names " ++
                        @typeName(decl) ++ ", which is not a Row.\n" ++
                        "  A Row borrows a table from another Row, or names one itself " ++
                        "with `.{ .name = \"…\" }`.",
                );
                assertSubset(current, decl);
                current = decl;
                continue;
            }
            return readSpec(current, decl);
        }
        @compileError(
            "nilo: " ++ @typeName(Row) ++ " borrows a table through more than " ++
                std.fmt.comptimePrint("{d}", .{max_borrow_depth}) ++ " Rows.\n" ++
                "  A Row that borrows from itself, directly or in a ring, never " ++
                "reaches a table.",
        );
    }
}

fn readSpec(comptime Row: type, comptime decl: anytype) Spec {
    comptime {
        const D = @TypeOf(decl);
        if (@typeInfo(D) != .@"struct") @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ marker ++ " is a " ++
                @typeName(D) ++ ".\n" ++
                "  It is either `.{ .name = \"users\" }` or another Row to take " ++
                "the table from.",
        );
        if (!@hasField(D, "name")) @compileError(
            "nilo: " ++ @typeName(Row) ++ "'s " ++ marker ++ " does not say `.name`.\n" ++
                "  The table name is written rather than guessed from the type — " ++
                "`User` to `users` reads well until `Category`.",
        );
        for (@typeInfo(D).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "name")) continue;
            if (std.mem.eql(u8, f.name, "key")) continue;
            @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s " ++ marker ++ " sets `." ++ f.name ++
                    "`, which is not part of it.\n" ++
                    "  It takes `.name` and, when the identity column is not `id`, `.key`.",
            );
        }
        const key: ?[]const u8 = if (@hasField(D, "key")) @tagName(decl.key) else null;
        return .{ .name = decl.name, .key = key };
    }
}

/// Every column a borrowed Row reads has to be one the Row it borrows from
/// reads, at the same type. This is the check the overload is worth having:
/// without it a narrower Row's typo would live until a live Postgres saw it.
fn assertSubset(comptime Narrow: type, comptime Wide: type) void {
    comptime {
        for (@typeInfo(Narrow).@"struct".fields) |f| {
            if (!hasColumn(Wide, f.name)) {
                const head = "nilo: " ++ @typeName(Narrow) ++ " reads `" ++ f.name ++
                    "`, which " ++ @typeName(Wide) ++ " does not have.";
                if (nearest(Wide, f.name)) |near| {
                    @compileError(head ++ "\n  Did you mean `" ++ near ++ "`?");
                }
                @compileError(head ++ "\n  Its columns are: " ++ columnList(Wide) ++ ".");
            }
            const theirs = ColumnType(Wide, f.name);
            if (f.type != theirs) @compileError(
                "nilo: " ++ @typeName(Narrow) ++ " reads `" ++ f.name ++ "` as " ++
                    @typeName(f.type) ++ ", and " ++ @typeName(Wide) ++ " reads it as " ++
                    @typeName(theirs) ++ ".\n" ++
                    "  Two Rows over one column have to agree, or one of them is " ++
                    "wrong about the table.",
            );
        }
    }
}

/// Stop, in this module's own words, if `T` is not a Row. Public because
/// `db.zig` is the first thing a mistyped call reaches, and being told
/// "`User` has no `nilo_table`" beats being told a field is missing from
/// somewhere three functions further in.
pub fn assertRow(comptime T: type) void {
    comptime {
        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: " ++ @typeName(T) ++ " is not a struct, so it cannot be a Row.\n" ++
                "  A Row is a struct of your own, one field per column.",
        );
        if (!@hasDecl(T, marker)) @compileError(
            "nilo: " ++ @typeName(T) ++ " is not a Row — it has no `" ++ marker ++ "`.\n" ++
                "  Add `pub const " ++ marker ++ " = .{ .name = \"<table>\" };` to it, " ++
                "or `= <OtherRow>` to read the same table as another Row.",
        );
    }
}

/// Levenshtein, for `nearest`. Comptime and over short names, so the square
/// table is cheaper than being clever about it.
fn distance(comptime a: []const u8, comptime b: []const u8) usize {
    comptime {
        @setEvalBranchQuota(10_000 + 64 * (a.len + 1) * (b.len + 1));
        var prev: [64]usize = undefined;
        var cur: [64]usize = undefined;
        if (a.len >= prev.len or b.len >= prev.len) return std.math.maxInt(usize);

        for (0..b.len + 1) |j| prev[j] = j;
        for (a, 0..) |ca, i| {
            cur[0] = i + 1;
            for (b, 0..) |cb, j| {
                const swap: usize = if (ca == cb) 0 else 1;
                cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), prev[j] + swap);
            }
            prev = cur;
        }
        return prev[b.len];
    }
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
};

const UserCard = struct {
    pub const nilo_table = User;

    id: i64,
    email: []const u8,
};

const Membership = struct {
    pub const nilo_table = .{ .name = "memberships", .key = .user_id };

    user_id: i64,
    plan: []const u8,
};

test "a Row names the table it reads" {
    try testing.expectEqualStrings("users", tableOf(User));
    try testing.expectEqualStrings("id", keyOf(User));
}

test "a key that is not id has to be written, and is" {
    try testing.expectEqualStrings("memberships", tableOf(Membership));
    try testing.expectEqualStrings("user_id", keyOf(Membership));
}

test "a narrower Row reads the table of the Row it borrows from" {
    try testing.expectEqualStrings("users", tableOf(UserCard));
    try testing.expectEqualStrings("id", keyOf(UserCard));
}

test "the columns come out in the order the Row declares them" {
    const columns = columnsOf(User);
    try testing.expectEqual(@as(usize, 3), columns.len);
    try testing.expectEqualStrings("id", columns[0]);
    try testing.expectEqualStrings("email", columns[1]);
    try testing.expectEqualStrings("age", columns[2]);
}

test "a borrowed Row keeps its own column list rather than the wider one" {
    try testing.expectEqual(@as(usize, 2), columnsOf(UserCard).len);
    try testing.expectEqual(@as(usize, 3), columnsOf(User).len);
}

test "a column is looked up by name and by type" {
    try testing.expect(hasColumn(User, "email"));
    try testing.expect(!hasColumn(User, "emial"));
    try testing.expectEqual(i32, ColumnType(User, "age"));
}

test "a near miss is named, and something unrelated is not guessed at" {
    try testing.expectEqualStrings("email", nearest(User, "emial").?);
    try testing.expectEqualStrings("age", nearest(User, "ag").?);
    try testing.expectEqual(@as(?[]const u8, null), nearest(User, "created_at"));
}

test "the column list reads as a sentence when there is nothing to suggest" {
    try testing.expectEqualStrings("`id`, `email`, `age`", columnList(User));
}

test "a struct that is not a Row is not mistaken for one" {
    try testing.expect(isRow(User));
    try testing.expect(!isRow(struct { id: i64 }));
    try testing.expect(!isRow(i64));
}
