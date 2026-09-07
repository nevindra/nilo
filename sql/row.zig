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
//! And a third shape, for a Row that **no table has**: the merged page of a
//! `UNION ALL`, a `GROUP BY` rollup, a card joining four tables
//! ([ADR 0155](../docs/adr/0155-a-row-that-owns-no-table.md)).
//!
//! ```zig
//! const TimelineRow = struct {
//!     pub const nilo_table = .projection;
//!
//!     at: sql.Timestamp,
//!     kind: Str,
//! };
//! ```
//!
//! `db.raw` and `tx.raw` fill one, because there the caller wrote the
//! statement. Everything that writes its own SQL refuses it by name, which is
//! the point: before this, such a Row had to name a table it did not
//! represent, and `db.checking` would then take that name at its word.
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

/// The one word the marker may be instead of a table or another Row.
pub const projection_word = "projection";

/// Whether `T` is a **projection**: a Row that reads and owns no table
/// ([ADR 0155](../docs/adr/0155-a-row-that-owns-no-table.md)).
///
/// A `UNION ALL` over two tables, a `GROUP BY` rollup, a search across seven
/// tables, a card joining four — none of them is a table's shape, and until
/// this existed each one had to name a table it did not represent so that
/// `assertRow` would pass. That is a lie in the source, and the comment above
/// each saying the name is decoration does not make it a true one.
///
/// What it buys is a **sharper** refusal rather than a looser one: a
/// projection is fillable by `db.raw` and `tx.raw`, and everything that names
/// a table — `select`, `find`, `count`, `insert`, `update`, `delete`,
/// `db.checking`, the migration tool — now refuses it by name instead of
/// going to a live database looking for `events.body`.
pub fn isProjection(comptime T: type) bool {
    // `comptime` on the condition rather than on the block: it folds the
    // branch, so `@field` below is never analysed for a type that has no
    // marker to read.
    if (comptime !isRow(T)) return false;
    const decl = @field(T, marker);
    if (@TypeOf(decl) != @TypeOf(.enum_literal)) return false;
    // `==` rather than comparing `@tagName` with `std.mem.eql`: the compiler
    // settles two enum literals in one step, and the string version spends a
    // caller's backwards branches on a ten-byte comparison (ADR 0157 is the
    // same lesson one module over).
    return decl == .projection;
}

/// The table `Row` reads, following a borrowed marker to the Row that names
/// one. Every other entry point goes through here, so the chain is walked in
/// exactly one place.
pub fn tableOf(comptime Row: type) []const u8 {
    return comptime specOf(Row).name;
}

/// A table name taken apart. `.name = "app.users"` is two identifiers and one
/// of them decides which schema the introspection query looks in, so the split
/// happens once, here, rather than in each of the seven places that write a
/// `FROM`.
pub const Qualified = struct {
    /// Null means *whatever `search_path` resolves to*, which is what a bare
    /// name has always meant and stays the default.
    schema: ?[]const u8,
    table: []const u8,
};

/// The table `Row` reads, split on the dot.
///
/// **One dot, and both halves have to be there.** `"app.users"` is a schema
/// and a table; `"users"` is a table; anything else — `"a.b.c"`, `".users"`,
/// `"app."` — is a mistake with a plausible cause and no plausible meaning, so
/// it stops here rather than reaching Postgres as a relation nobody named.
pub fn qualifiedOf(comptime Row: type) Qualified {
    return comptime blk: {
        const written = tableOf(Row);
        const dot = std.mem.indexOfScalar(u8, written, '.') orelse
            break :blk .{ .schema = null, .table = written };

        const schema = written[0..dot];
        const table = written[dot + 1 ..];
        if (schema.len == 0 or table.len == 0 or
            std.mem.indexOfScalar(u8, table, '.') != null) @compileError(
            "nilo: " ++ @typeName(Row) ++ " names the table `" ++ written ++
                "`, which is not a schema and a table.\n" ++
                "  A qualified name is `schema.table` — one dot, and something on " ++
                "either side of it. A table whose name really contains a dot is out " ++
                "of reach here and is `db.raw`.",
        );
        break :blk .{ .schema = schema, .table = table };
    };
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

/// Whether this program builds the table `Row` reads, or only reads it
/// ([ADR 0162](../docs/adr/0162-a-table-this-program-reads-and-does-not-build.md)).
///
/// **The default is true, and the word exists for a port.** A `.references`
/// names the Row that owns the table, so a foreign key onto `staff` needs a
/// `Staff` Row — and the moment one exists the migration tool wants to create
/// `staff`, which has been there for a year with twenty columns this program
/// has never read. That made the tool all-or-nothing on a schema a program
/// owns part of: usable at 59 tables of 59, unusable at 47 of 59.
///
/// What `.managed = false` changes is only who builds it. The Row is still a
/// Row: `.references` may point at it, `db.checking` still holds it against
/// the live schema, and every statement reads it the same way. `plan`,
/// `createMissing` and `generate` leave it alone.
pub fn managedOf(comptime Row: type) bool {
    return comptime specOf(Row).managed;
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
        if (types_mod.asText(T) != null) return if (@typeInfo(T) == .optional) ?[]const u8 else []const u8;
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
    /// Whether this program **builds** the table, as against merely reading
    /// it ([ADR 0162](../docs/adr/0162-a-table-this-program-reads-and-does-not-build.md)).
    /// True unless the Row says otherwise, because that is what every Row
    /// written before this meant.
    managed: bool = true,
};

/// What may be written in the marker. `.name` and `.key` are read here;
/// `sql/table.zig` reads the other four, and this list is what stops a typo in
/// one of them being silently ignored. One list rather than a check in each
/// file, because a word allowed in one place and refused in another is the
/// mistake this whole arrangement exists to make impossible.
const allowed = [_][]const u8{ "name", "key", "unique", "index", "references", "was", "managed" };

/// The table spec `Row` resolves to, following `nilo_table = OtherRow` until
/// a spec that names a table is reached. Every borrowed Row is checked against
/// the one it borrows from on the way past, so the check cannot be skipped by
/// asking a question that does not need it.
/// The Row at the end of the borrow chain: the one that names a table rather
/// than another Row.
///
/// **This is the only Row allowed to describe the table**, which is what keeps
/// a query type from becoming a migration file in disguise
/// ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
/// Nothing enforces it, because the language does: a borrowing Row's marker is
/// a `type`, and there is nowhere on a type to write `.unique`.
pub fn ownerOf(comptime Row: type) type {
    comptime {
        assertRow(Row);
        var current = Row;
        var depth: usize = 0;
        while (depth < max_borrow_depth) : (depth += 1) {
            const decl = @field(current, marker);
            // A projection owns no table, so every question that starts
            // "which table" ends here rather than at a live database looking
            // for a column of a table nobody meant (ADR 0155). This is the
            // one funnel: `tableOf`, `keyOf` and `qualifiedOf` all come
            // through, and so does everything in `table.zig`.
            if (@TypeOf(decl) == @TypeOf(.enum_literal)) {
                if (decl != .projection) @compileError(
                    "nilo: " ++ @typeName(current) ++ "'s " ++ marker ++ " is `." ++
                        @tagName(decl) ++ "`, which is not a word it takes.\n" ++
                        "  The only one is `." ++ projection_word ++ "`, for a Row that no " ++
                        "table has the shape of. Otherwise it is `.{ .name = \"<table>\" }` " ++
                        "or another Row.",
                );
                @compileError(
                    "nilo: " ++ @typeName(Row) ++ " is a projection, so it has no table to " ++
                        (if (current == Row) "read." else "borrow from " ++ @typeName(current) ++ ".") ++
                        "\n  A projection is filled by `db.raw` and `tx.raw` and by nothing " ++
                        "else: everything here that writes its own SQL has to name a table, " ++
                        "and this Row is the shape of an answer rather than of a table. Give " ++
                        "the statement to `db.raw`, or write `." ++ marker ++
                        " = .{ .name = \"<table>\" }` if there really is one.",
                );
            }
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
            return current;
        }
        @compileError(
            "nilo: " ++ @typeName(Row) ++ " borrows a table through more than " ++
                std.fmt.comptimePrint("{d}", .{max_borrow_depth}) ++ " Rows.\n" ++
                "  A Row that borrows from itself, directly or in a ring, never " ++
                "reaches a table.",
        );
    }
}

fn specOf(comptime Row: type) Spec {
    comptime {
        const owner = ownerOf(Row);
        return readSpec(owner, @field(owner, marker));
    }
}

fn readSpec(comptime Row: type, comptime decl: anytype) Spec {
    comptime {
        // Every field of the marker is compared against the six words allowed
        // in it, and every Row in a schema comes through here — so a program
        // with tens of tables spends the default 1,000 backwards branches on
        // `std.mem.eql` alone, and the compile stops in a file of std's
        // ([ADR 0157](../docs/adr/0157-a-check-pays-for-its-own-branches.md)).
        // Generous rather than exact, for the reason that ADR gives: the
        // budget is the caller's whole evaluation and this raises a ceiling
        // rather than spending an allowance.
        @setEvalBranchQuota(50_000);
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
            for (allowed) |ok| {
                if (std.mem.eql(u8, f.name, ok)) break;
            } else @compileError(
                "nilo: " ++ @typeName(Row) ++ "'s " ++ marker ++ " sets `." ++ f.name ++
                    "`, which is not part of it.\n" ++
                    "  It takes `.name`, and `.key` when the identity column is not " ++
                    "`id`. The four a migration reads are `.unique`, `.index`, " ++
                    "`.references` and `.was`; everything else about the table is SQL " ++
                    "in a step, which nilo will not touch.",
            );
        }
        const key: ?[]const u8 = if (@hasField(D, "key")) @tagName(decl.key) else null;
        const managed: bool = if (@hasField(D, "managed")) decl.managed else true;
        return .{ .name = decl.name, .key = key, .managed = managed };
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
                "`= <OtherRow>` to read the same table as another Row, or `= ." ++
                projection_word ++ "` when no table has this shape and `db.raw` is what " ++
                "fills it (ADR 0155).",
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

const Timeline = struct {
    pub const nilo_table = .projection;

    at: i64,
    kind: []const u8,
};

test "a Row names the table it reads" {
    try testing.expectEqualStrings("users", tableOf(User));
    try testing.expectEqualStrings("id", keyOf(User));
}

test "a projection is a Row, and is the one Row that names no table" {
    // Both halves matter. It has to pass `assertRow`, or `db.raw` would not
    // take it; and it has to be recognisable as a projection, or everything
    // that writes SQL would go looking for a table called `.projection`
    // (ADR 0155).
    try testing.expect(isRow(Timeline));
    try testing.expect(isProjection(Timeline));

    // And the Rows that do own a table are not projections, including the one
    // that borrows: a borrowed marker is a `type`, not a word.
    try testing.expect(!isProjection(User));
    try testing.expect(!isProjection(UserCard));
    try testing.expect(!isProjection(struct { id: i64 }));
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

test "a table name splits on the dot into a schema and a table" {
    const Qualified_ = struct {
        pub const nilo_table = .{ .name = "app.users", .key = .id };
        id: i64,
    };
    const q = qualifiedOf(Qualified_);
    try testing.expectEqualStrings("app", q.schema.?);
    try testing.expectEqualStrings("users", q.table);
}

test "a bare name has no schema, which means whatever the search_path says" {
    const q = qualifiedOf(User);
    try testing.expectEqual(@as(?[]const u8, null), q.schema);
    try testing.expectEqualStrings("users", q.table);
    // `tableOf` still answers what was written, because that is what a
    // message about the Row should say.
    try testing.expectEqualStrings("users", tableOf(User));
}

test "a struct that is not a Row is not mistaken for one" {
    try testing.expect(isRow(User));
    try testing.expect(!isRow(struct { id: i64 }));
    try testing.expect(!isRow(i64));
}
