//! A statement composed at run time from pieces that cannot carry a string
//! ([ADR 208](../docs/adr/208-a-statement-composed-at-run-time-from-pieces-that-cannot-carry-a-string.md)).
//!
//! `db.raw` takes comptime text (ADR 051), and the property that decision
//! protects is narrower than "the text is a constant": **no run-time string
//! reaches the statement** (ADR 165). A query engine — a semantic layer
//! that turns a model into SQL — cannot write its statements while
//! compiling, because the model is data, but it never needs a run-time
//! *string* in them either: what varies is which table, which column,
//! which function, how many of each. That is a statement made of three
//! kinds of piece, and only three:
//!
//! - **`text`** — comptime. Keywords, functions, punctuation, an interval
//!   the program chose. A slice that arrived at run time does not compile,
//!   because the parameter is `comptime`.
//! - **`ident`** — a name checked at run time to be an identifier and
//!   written quoted, so it can be nothing but a name.
//! - **`param`** — the `n`th placeholder, spelled the way the dialect the
//!   statement will run on spells it. What the request sent is always this.
//!
//! Nothing else has a method, so nothing else can be written. A `Composed`
//! is then handed to `db.composed` like the text of a `db.raw` would be:
//! the Row is filled by position, the run-time width check (ADR 106)
//! holds, the values are converted the way a Row's are (ADR 116), and the
//! values are counted against the placeholders the way `rawcheck` counts
//! them for `raw` — at run time here, because the text is. What it gives
//! up is the comptime column count and the plan name — its text differs
//! per model, so it runs unnamed, which is the 12 µs ADR 051 measured,
//! spent once per statement rather than once per request.

const std = @import("std");

/// How a dialect spells its `n`th placeholder. Read off the dialect once
/// (`Spelling.of(dialect.Postgres)`) so a `Composed` can be built where no
/// `Db` is in scope — a generator with table-driven tests — and still be
/// held against the `Db` it is handed to.
pub const Spelling = enum {
    /// `$1`: Postgres.
    dollar,
    /// `?1`: SQLite.
    question,

    /// The spelling of a dialect type, decided from how it spells `1`.
    pub fn of(comptime D: type) Spelling {
        return comptime if (std.mem.eql(u8, D.placeholder(1), "$1"))
            .dollar
        else if (std.mem.eql(u8, D.placeholder(1), "?1"))
            .question
        else
            @compileError("nilo: `Composed` knows `$n` and `?n`, and " ++ @typeName(D) ++ " spells its first placeholder `" ++ D.placeholder(1) ++ "`.");
    }
};

pub const Composed = struct {
    out: std.Io.Writer.Allocating,
    spelling: Spelling,
    /// The highest placeholder written, so `db.composed` can hold the
    /// values it is handed against the statement.
    params: u16 = 0,
    /// Which placeholders were written, bit `n - 1` for `param(n)`. The
    /// highest alone cannot tell `param(2)` from `param(1)` and `param(2)`:
    /// a raw statement is refused a gap in its numbering (ADR 204) and this
    /// one is too (`gapless`). It grows on the arena, once per 64 numbers.
    written: std.bit_set.DynamicBitSetUnmanaged = .{},

    pub const Error = error{ NotAnIdentifier, NotAParameter, OutOfMemory };

    /// Writes into `arena`: a Composed lives as long as the Scope that
    /// will run it, the way a `Str` does. `db.compose(c)` is this with the
    /// Db's own spelling.
    pub fn init(arena: std.mem.Allocator, spelling: Spelling) Composed {
        return .{ .out = std.Io.Writer.Allocating.init(arena), .spelling = spelling };
    }

    /// A piece the program wrote. The parameter is `comptime`, so a slice
    /// that arrived at run time does not compile: a run-time string enters
    /// a composed statement as `ident` (checked to be a name) or `param`,
    /// never as text. A `$n` inside the piece is a Refusal: a placeholder
    /// is `param(n)`, which spells it for the dialect and counts it, and
    /// one written as text would be neither. `?n` is refused the same way
    /// as `$n`: this method does not know the dialect, so it refuses both.
    pub fn text(self: *Composed, comptime piece: []const u8) Error!void {
        comptime if (namesAPlaceholder(piece)) @compileError(
            "nilo: `Composed.text` was handed \"" ++ piece ++ "\", which names a placeholder as text.\n" ++
                "  A placeholder in a composed statement is `param(n)`: it is spelled for the dialect " ++
                "(`$n` on Postgres, `?n` on SQLite) and counted against the values. Write the text " ++
                "up to the `$`, then `param(n)`, then the rest.",
        );
        self.out.writer.writeAll(piece) catch return error.OutOfMemory;
    }

    /// A name, checked and quoted. Letters, digits and `_`, not starting
    /// with a digit, at most 63 bytes — the shape both dialects accept as a
    /// quoted name. Anything else is `error.NotAnIdentifier`, which is
    /// the whole of how a string that is not a name is kept out.
    ///
    /// **The name is quoted as written, so its case is kept and is not
    /// folded**: `"streamId"` is a column that was created as `"streamId"`,
    /// which is how nilo's own DDL writes every name (`Dialect.quote`), and
    /// it misses one created unquoted as `streamId`, which Postgres stored as
    /// `streamid`. Folding here would miss the other way, on the tables nilo
    /// made from a camelCase field. A table made by other tooling with
    /// unquoted names is written in lower case (ADR 208).
    pub fn ident(self: *Composed, name: []const u8) Error!void {
        if (!isIdentifier(name)) return error.NotAnIdentifier;
        const w = &self.out.writer;
        w.writeByte('"') catch return error.OutOfMemory;
        w.writeAll(name) catch return error.OutOfMemory;
        w.writeByte('"') catch return error.OutOfMemory;
    }

    /// `"schema"."name"` — two identifiers, each checked.
    pub fn qualified(self: *Composed, schema: []const u8, name: []const u8) Error!void {
        try self.ident(schema);
        try self.text(".");
        try self.ident(name);
    }

    /// The `n`th placeholder, numbered from one, spelled for the dialect;
    /// remembers the highest one written. `0` is `error.NotAParameter`.
    pub fn param(self: *Composed, n: u16) Error!void {
        if (n == 0) return error.NotAParameter;
        const w = &self.out.writer;
        w.writeByte(switch (self.spelling) {
            .dollar => '$',
            .question => '?',
        }) catch return error.OutOfMemory;
        w.print("{d}", .{n}) catch return error.OutOfMemory;
        if (n > self.params) self.params = n;
        const bit: usize = n - 1;
        if (bit >= self.written.bit_length) {
            self.written.resize(self.out.allocator, @as(usize, n), false) catch return error.OutOfMemory;
        }
        self.written.set(bit);
    }

    /// Whether every placeholder from `1` to `params` was written at least
    /// once. `db.composed` counts values against this: `param(2)` alone with
    /// two values passes the highest and leaves `$1` bound to nothing, which
    /// SQLite answers as NULL and Postgres refuses at the first request.
    pub fn gapless(self: *const Composed) bool {
        return self.written.count() == self.params;
    }

    /// A number the program computed: a limit, a bucket width in seconds.
    /// Unsigned, so the piece is digits and nothing else — a negative
    /// number that a statement needs is a `param`.
    pub fn number(self: *Composed, n: u64) Error!void {
        self.out.writer.print("{d}", .{n}) catch return error.OutOfMemory;
    }

    /// The statement so far.
    pub fn view(self: *const Composed) []const u8 {
        return self.out.writer.buffered();
    }
};

/// Whether `piece` carries a `$` or a `?` followed by a digit — a Postgres or
/// a SQLite placeholder written as text, which `text` refuses (see
/// `Composed.text`). A `?` with no digit after it is the JSON operator and
/// stays text.
fn namesAPlaceholder(comptime piece: []const u8) bool {
    comptime {
        var i: usize = 0;
        while (i + 1 < piece.len) : (i += 1) {
            if ((piece[i] == '$' or piece[i] == '?') and std.ascii.isDigit(piece[i + 1])) return true;
        }
        return false;
    }
}

/// What `ident` accepts. Exported so a caller that validates names on the
/// way in — a model checker — applies the same rule.
pub fn isIdentifier(name: []const u8) bool {
    if (name.len == 0 or name.len > 63) return false;
    if (std.ascii.isDigit(name[0])) return false;
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    }
    return true;
}

test "a composed statement is literals, quoted identifiers and parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Composed.init(arena.allocator(), .dollar);
    try s.text("SELECT time_bucket(INTERVAL '1 hour', ");
    try s.ident("bucket");
    try s.text(", ");
    try s.param(1);
    try s.text(") AS b, sum(");
    try s.ident("visits");
    try s.text(") FROM ");
    try s.qualified("public", "q_dwelling__by_stream__h1");
    try s.text(" WHERE ");
    try s.ident("stream_id");
    try s.text(" = ANY(");
    try s.param(2);
    try s.text(") GROUP BY 1 LIMIT ");
    try s.number(10_000);
    try std.testing.expectEqualStrings(
        "SELECT time_bucket(INTERVAL '1 hour', \"bucket\", $1) AS b, sum(\"visits\") FROM \"public\".\"q_dwelling__by_stream__h1\" WHERE \"stream_id\" = ANY($2) GROUP BY 1 LIMIT 10000",
        s.view(),
    );
    try std.testing.expectEqual(@as(u16, 2), s.params);
}

test "a placeholder is spelled for the dialect the statement will run on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Composed.init(arena.allocator(), .question);
    try s.text("SELECT ");
    try s.ident("n");
    try s.text(" FROM t WHERE id = ");
    try s.param(1);
    try s.text(" AND kind = ");
    try s.param(2);
    try std.testing.expectEqualStrings("SELECT \"n\" FROM t WHERE id = ?1 AND kind = ?2", s.view());
    try std.testing.expectEqual(@as(u16, 2), s.params);

    const Dollar = struct {
        pub fn placeholder(comptime n: usize) []const u8 {
            return "$" ++ std.fmt.comptimePrint("{d}", .{n});
        }
    };
    const Question = struct {
        pub fn placeholder(comptime n: usize) []const u8 {
            return "?" ++ std.fmt.comptimePrint("{d}", .{n});
        }
    };
    try std.testing.expectEqual(Spelling.dollar, Spelling.of(Dollar));
    try std.testing.expectEqual(Spelling.question, Spelling.of(Question));
}

test "a name that is not an identifier is refused, so a string cannot get in as one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var s = Composed.init(arena.allocator(), .dollar);
    try std.testing.expectError(error.NotAnIdentifier, s.ident("stream_id\" OR 1=1 --"));
    try std.testing.expectError(error.NotAnIdentifier, s.ident("drop table"));
    try std.testing.expectError(error.NotAnIdentifier, s.ident("1abc"));
    try std.testing.expectError(error.NotAnIdentifier, s.ident(""));
    try std.testing.expectError(error.NotAnIdentifier, s.ident(&@as([64]u8, @splat('a'))));
    try std.testing.expectError(error.NotAParameter, s.param(0));
    // Nothing was written by a refused call.
    try std.testing.expectEqualStrings("", s.view());
    try s.ident("stream_id");
    try std.testing.expectEqualStrings("\"stream_id\"", s.view());
}

test "a dollar that is not a placeholder is text, and a placeholder is not" {
    try std.testing.expect(!comptime namesAPlaceholder("SELECT $$ quoted $$, '$' AS sign FROM t"));
    try std.testing.expect(comptime namesAPlaceholder("WHERE id = $1"));
    try std.testing.expect(comptime namesAPlaceholder("$12::timestamptz"));
    try std.testing.expect(!comptime namesAPlaceholder("$"));
    // SQLite's spelling is refused as text too, and the JSON `?` is not one.
    try std.testing.expect(comptime namesAPlaceholder("WHERE id = ?1"));
    try std.testing.expect(!comptime namesAPlaceholder("WHERE doc ? 'k' AND x = '?'"));
}

test "a placeholder that was skipped is a gap, and a repeated one is not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var only_second = Composed.init(arena.allocator(), .dollar);
    try only_second.text("SELECT ");
    try only_second.param(2);
    try std.testing.expectEqual(@as(u16, 2), only_second.params);
    try std.testing.expect(!only_second.gapless());

    var repeated = Composed.init(arena.allocator(), .question);
    try repeated.param(2);
    try repeated.param(1);
    try repeated.param(2);
    try std.testing.expect(repeated.gapless());

    var none = Composed.init(arena.allocator(), .dollar);
    try std.testing.expect(none.gapless());

    // Past one word of the bit set.
    var wide = Composed.init(arena.allocator(), .dollar);
    var n: u16 = 1;
    while (n <= 70) : (n += 1) try wide.param(n);
    try std.testing.expect(wide.gapless());
    var wide_gap = Composed.init(arena.allocator(), .dollar);
    try wide_gap.param(1);
    try wide_gap.param(70);
    try std.testing.expect(!wide_gap.gapless());
}

test "isIdentifier is the rule a caller can apply on the way in" {
    try std.testing.expect(isIdentifier("q_mpa__by_stream__m1"));
    try std.testing.expect(isIdentifier("_x"));
    try std.testing.expect(!isIdentifier("with space"));
    try std.testing.expect(!isIdentifier("semi;colon"));
    try std.testing.expect(!isIdentifier("quo\"te"));
}
