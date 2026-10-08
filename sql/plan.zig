//! Which columns of a statement can be NULL because an outer join may find
//! nothing, read off the plan Postgres would run it by
//! ([ADR 233](../docs/adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md)).
//!
//! `db.raw` fills a Row by position, and a non-optional field that meets a
//! NULL fails the whole statement. The NULL that took a page down in the port
//! came through a `LEFT JOIN LATERAL`: the subject of an event outlives its
//! row. Postgres does not say which columns of an answer may be NULL: the
//! `RowDescription` has a type and a source column and nothing else, and a
//! `NOT NULL` column read through the far side of a `LEFT JOIN` still names
//! its table. **The plan does say it.** `EXPLAIN (VERBOSE, FORMAT JSON)`
//! lists every node's output as the expressions it computes, and every
//! join's type; a column the top of the plan passes through unchanged from
//! the side of a `Left`, `Right` or `Full` join that may find nothing is
//! NULL on the rows that found nothing.
//!
//! **Only what is certain is said.** The planner has already turned an outer
//! join into an inner one wherever a condition throws away the NULLs
//! (`WHERE i.title IS NOT NULL`, `i.title = $1`), so a join still marked
//! `Left` in the plan is one whose NULLs reach the answer. An expression
//! (`COALESCE(i.title, '')`, a function, an aggregate) is not judged, and a
//! column renamed by a subquery or a CTE scan (`s.b`, `x.title`) is not
//! followed: in both cases the answer is "cannot say", which the caller reads
//! as "not NULL". A column missed is a check that did less; a column wrongly
//! called NULL would fail a statement that works.
//!
//! EXPLAIN's names are unique across the whole plan (`e`, `e_1`), which is
//! what lets an output be matched to the join it came out of by its text.
//! `UNION` is read by position, because an `Append` names its columns after
//! its first branch: `i.title` above it may be `d.name` in the second.
//!
//! Nothing here names Postgres's driver: the input is the plan's text, so the
//! tests below are plans captured from a real server.
//!
//! **The JSON is read by a reader of its own**, rather than by `std.json`.
//! `std.json.Value` is an array hash map per object and a float parser for
//! every number, and it was +88 KB on a stripped program whose one route is a
//! `db.raw`: for a check that runs once per statement and reads four keys,
//! all strings. This one keeps objects as lists and skips numbers unread,
//! since no number in a plan is looked at.

const std = @import("std");

/// For each of the first `width` columns of the statement `json` is the plan
/// of, whether it is certainly NULL on some row because of an outer join.
/// `json` is what `EXPLAIN (VERBOSE, FORMAT JSON)` answered. A plan this does
/// not understand answers false for every column.
pub fn outerNullable(arena: std.mem.Allocator, json: []const u8, width: usize) ![]bool {
    const out = try arena.alloc(bool, width);
    @memset(out, false);
    var reader: Reader = .{ .text = json, .arena = arena };
    const parsed = reader.value() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => return out,
    };
    const root = switch (parsed) {
        .array => |items| if (items.len > 0) items[0] else return out,
        else => parsed,
    };
    const top = field(root, "Plan") orelse return out;
    var kept: Names = .{};
    try collectKept(arena, top, false, &kept);
    const found = try positional(arena, top, &kept) orelse return out;
    for (out, 0..) |*slot, i| {
        if (i < found.len) slot.* = found[i];
    }
    return out;
}

/// The node's outputs by position: which are certainly NULL on some row, or
/// null when this cannot say anything about the node. `kept` is every column
/// a table scan reads outside the far side of any outer join: a name in it
/// also comes from a side that always has a row, which is how a `LATERAL`
/// that repeats a column of the row it hangs off (`e.kind` inside it, the
/// same `e.kind` beside it) keeps that column from being called NULL.
fn positional(arena: std.mem.Allocator, node: Value, kept: *const Names) std.mem.Allocator.Error!?[]bool {
    const kind = text(node, "Node Type") orelse return null;

    // A `UNION`: a column is NULL when it is in any branch. The branches are
    // the members, in the order the statement wrote them.
    if (isAppend(kind)) {
        var merged: ?[]bool = null;
        for (children(node)) |child| {
            if (!relationIs(child, "Member")) continue;
            const one = try positional(arena, child, kept) orelse continue;
            if (merged) |m| {
                for (m, 0..) |*slot, i| {
                    if (i < one.len and one[i]) slot.* = true;
                }
            } else merged = try arena.dupe(bool, one);
        }
        return merged;
    }

    const outputs = strings(node, "Output") orelse return null;
    var nulls: Names = .{};
    try collectNullable(arena, node, &nulls);

    const out = try arena.alloc(bool, outputs.len);
    for (outputs, out) |expr, *slot| {
        slot.* = isColumn(expr.string) and nulls.contains(expr.string) and !kept.contains(expr.string);
    }

    // A node that hands its only input on as it came, column for column. Above
    // a `UNION` that is what carries the branches' answer up: the names here
    // are the first branch's and say nothing about the second.
    if (passesThrough(kind, node)) {
        if (onlyChild(node)) |child| {
            if (try positional(arena, child, kept)) |below| {
                for (out, 0..) |*slot, i| {
                    if (i < below.len and below[i]) slot.* = true;
                }
            }
        }
    }
    return out;
}

/// Every output of every node on the side of an outer join that may find
/// nothing, anywhere under `node`.
fn collectNullable(arena: std.mem.Allocator, node: Value, into: *Names) std.mem.Allocator.Error!void {
    for (children(node)) |child| {
        if (farSide(node, child)) try everyOutput(arena, child, into);
        try collectNullable(arena, child, into);
    }
}

/// The outputs of every scan, a node with nothing under it, that is not on
/// the far side of an outer join.
fn collectKept(arena: std.mem.Allocator, node: Value, far: bool, into: *Names) std.mem.Allocator.Error!void {
    const below = children(node);
    if (below.len == 0) {
        if (far) return;
        if (strings(node, "Output")) |outputs| {
            for (outputs) |expr| try into.add(arena, expr.string);
        }
        return;
    }
    for (below) |child| try collectKept(arena, child, far or farSide(node, child), into);
}

/// Whether `child` is the side of the join `node` that may find nothing:
/// the inner input of a `Left`, the outer of a `Right`, either of a `Full`.
fn farSide(node: Value, child: Value) bool {
    const join = text(node, "Join Type") orelse return false;
    if (std.mem.eql(u8, join, "Left")) return relationIs(child, "Inner");
    if (std.mem.eql(u8, join, "Right")) return relationIs(child, "Outer");
    if (std.mem.eql(u8, join, "Full")) return relationIs(child, "Inner") or relationIs(child, "Outer");
    return false;
}

/// Whether an output is a column as it was read, `alias.column` or the
/// `(alias.column)` a `LATERAL` shows a column of its outer row as, rather
/// than an expression or a constant computed above the join, which is not
/// judged.
fn isColumn(expr: []const u8) bool {
    var name = expr;
    if (name.len >= 2 and name[0] == '(' and name[name.len - 1] == ')') name = name[1 .. name.len - 1];
    var dots: usize = 0;
    var quoted = false;
    for (name) |c| {
        if (c == '"') {
            quoted = !quoted;
        } else if (quoted) {
            continue;
        } else if (c == '.') {
            dots += 1;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) {
            return false;
        }
    }
    return !quoted and dots >= 1;
}

fn everyOutput(arena: std.mem.Allocator, node: Value, into: *Names) std.mem.Allocator.Error!void {
    if (strings(node, "Output")) |outputs| {
        for (outputs) |expr| try into.add(arena, expr.string);
    }
    for (children(node)) |child| try everyOutput(arena, child, into);
}

fn isAppend(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "Append") or std.mem.eql(u8, kind, "Merge Append");
}

/// Whether `node` hands its input on column for column. Sorting, limiting
/// and gathering do; an `Aggregate` or a `SetOp` does only as the top of a
/// `UNION` (`UNION` without `ALL` is an aggregate over the branches), which
/// is when its only child is the `Append`.
fn passesThrough(kind: []const u8, node: Value) bool {
    for ([_][]const u8{ "Limit", "Sort", "Incremental Sort", "Unique", "Materialize", "Gather", "Gather Merge" }) |same| {
        if (std.mem.eql(u8, kind, same)) return true;
    }
    if (std.mem.eql(u8, kind, "Aggregate") or std.mem.eql(u8, kind, "SetOp")) {
        const child = onlyChild(node) orelse return false;
        return isAppend(text(child, "Node Type") orelse "");
    }
    return false;
}

/// The one child that feeds `node`'s rows, leaving out an `InitPlan` or a
/// `SubPlan`, which compute values rather than rows. Null when there are
/// several.
fn onlyChild(node: Value) ?Value {
    var found: ?Value = null;
    for (children(node)) |child| {
        if (relationIs(child, "InitPlan") or relationIs(child, "SubPlan")) continue;
        if (found != null) return null;
        found = child;
    }
    return found;
}

fn children(node: Value) []const Value {
    const plans = field(node, "Plans") orelse return &.{};
    return switch (plans) {
        .array => |items| items,
        else => &.{},
    };
}

fn relationIs(node: Value, want: []const u8) bool {
    const got = text(node, "Parent Relationship") orelse return false;
    return std.mem.eql(u8, got, want);
}

fn field(node: Value, name: []const u8) ?Value {
    const fields = switch (node) {
        .object => |fields| fields,
        else => return null,
    };
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

fn text(node: Value, name: []const u8) ?[]const u8 {
    const got = field(node, name) orelse return null;
    return switch (got) {
        .string => |s| s,
        else => null,
    };
}

/// A list of strings, or null when the field is absent or holds anything
/// else. What `Output` is.
fn strings(node: Value, name: []const u8) ?[]const Value {
    const got = field(node, name) orelse return null;
    const items = switch (got) {
        .array => |items| items,
        else => return null,
    };
    for (items) |item| if (item != .string) return null;
    return items;
}

/// A set of names, as a list: a plan names tens of columns, and a hash map
/// is code this file would carry for nothing.
const Names = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Names, arena: std.mem.Allocator, name: []const u8) !void {
        if (!self.contains(name)) try self.items.append(arena, name);
    }

    fn contains(self: *const Names, name: []const u8) bool {
        for (self.items.items) |have| {
            if (std.mem.eql(u8, have, name)) return true;
        }
        return false;
    }
};

/// A JSON value as far as a plan needs one: objects and arrays as lists,
/// strings decoded, and every number, `true`, `false` and `null` skipped
/// unread.
const Value = union(enum) {
    object: []const Field,
    array: []const Value,
    string: []const u8,
    scalar,
};

const Field = struct { name: []const u8, value: Value };

const Reader = struct {
    text: []const u8,
    arena: std.mem.Allocator,
    at: usize = 0,
    depth: usize = 0,

    const Error = error{ Malformed, OutOfMemory };

    fn value(self: *Reader) Error!Value {
        self.space();
        if (self.at >= self.text.len) return error.Malformed;
        return switch (self.text[self.at]) {
            '{' => .{ .object = try self.object() },
            '[' => .{ .array = try self.array() },
            '"' => .{ .string = try self.string() },
            else => self.scalar(),
        };
    }

    fn object(self: *Reader) Error![]const Field {
        try self.enter();
        defer self.depth -= 1;
        var fields: std.ArrayList(Field) = .empty;
        if (self.peek() == '}') {
            self.at += 1;
            return fields.items;
        }
        while (true) {
            self.space();
            if (self.peek() != '"') return error.Malformed;
            const name = try self.string();
            self.space();
            if (self.peek() != ':') return error.Malformed;
            self.at += 1;
            try fields.append(self.arena, .{ .name = name, .value = try self.value() });
            if (try self.more('}')) continue;
            return fields.items;
        }
    }

    fn array(self: *Reader) Error![]const Value {
        try self.enter();
        defer self.depth -= 1;
        var items: std.ArrayList(Value) = .empty;
        if (self.peek() == ']') {
            self.at += 1;
            return items.items;
        }
        while (true) {
            try items.append(self.arena, try self.value());
            if (try self.more(']')) continue;
            return items.items;
        }
    }

    /// Past the opening bracket, with a bound on how deep a plan may nest
    /// before this stops reading it rather than recursing on.
    fn enter(self: *Reader) Error!void {
        self.depth += 1;
        if (self.depth > 512) return error.Malformed;
        self.at += 1;
        self.space();
    }

    /// After a member: a comma and another, or the closing bracket.
    fn more(self: *Reader, close: u8) Error!bool {
        self.space();
        const c = self.peek();
        self.at += 1;
        if (c == ',') return true;
        if (c == close) return false;
        return error.Malformed;
    }

    fn string(self: *Reader) Error![]const u8 {
        self.at += 1;
        const start = self.at;
        var plain = true;
        while (self.at < self.text.len) : (self.at += 1) {
            switch (self.text[self.at]) {
                '"' => break,
                '\\' => {
                    plain = false;
                    self.at += 1;
                },
                else => {},
            }
        } else return error.Malformed;
        const raw = self.text[start..self.at];
        self.at += 1;
        if (plain) return raw;
        return unescape(self.arena, raw);
    }

    fn scalar(self: *Reader) Error!Value {
        const start = self.at;
        while (self.at < self.text.len) : (self.at += 1) {
            switch (self.text[self.at]) {
                ',', ']', '}', ' ', '\t', '\r', '\n' => break,
                else => {},
            }
        }
        if (self.at == start) return error.Malformed;
        return .scalar;
    }

    fn peek(self: *const Reader) u8 {
        return if (self.at < self.text.len) self.text[self.at] else 0;
    }

    fn space(self: *Reader) void {
        while (self.at < self.text.len and std.ascii.isWhitespace(self.text[self.at])) self.at += 1;
    }
};

/// A string's escapes turned into the bytes they stand for. A `\\u` is kept
/// as written: Postgres escapes only the control characters in a plan, a name
/// holding one is compared against itself spelled the same way, and decoding
/// it would link a number parser and a UTF-8 encoder for nothing.
fn unescape(arena: std.mem.Allocator, raw: []const u8) Reader.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\' or i + 1 >= raw.len or raw[i + 1] == 'u') {
            out.appendAssumeCapacity(raw[i]);
            continue;
        }
        i += 1;
        out.appendAssumeCapacity(switch (raw[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 0x08,
            'f' => 0x0c,
            else => |same| same,
        });
    }
    return out.items;
}

// -- tests ---------------------------------------------------------------
//
// Each plan is one Postgres 17 answered for the statement above it, trimmed to
// the fields read here.

const testing = std.testing;

fn expectNulls(json: []const u8, want: []const bool) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try outerNullable(arena.allocator(), json, want.len);
    try testing.expectEqualSlices(bool, want, got);
}

test "a column from the far side of a LEFT JOIN is NULL, and an expression over it is not judged" {
    // SELECT e.id, i.title, coalesce(i.title, '') FROM events e
    //   LEFT JOIN items i ON i.id = e.item_id
    try expectNulls(
        \\[{"Plan": {"Node Type": "Nested Loop", "Join Type": "Left",
        \\  "Output": ["e.id", "i.title", "COALESCE(i.title, ''::text)"],
        \\  "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id", "e.kind"]},
        \\    {"Node Type": "Index Scan", "Parent Relationship": "Inner", "Output": ["i.id", "i.title"]}]}}]
    , &.{ false, true, false });
}

test "a join a condition turned inner has no NULL to report" {
    // The same with `WHERE i.title IS NOT NULL`: the planner reads the
    // condition and the join is no longer outer.
    try expectNulls(
        \\[{"Plan": {"Node Type": "Nested Loop", "Join Type": "Inner",
        \\  "Output": ["e.id", "i.title"],
        \\  "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id"]},
        \\    {"Node Type": "Index Scan", "Parent Relationship": "Inner", "Output": ["i.id", "i.title"]}]}}]
    , &.{ false, false });
}

test "a LATERAL the planner could not flatten is still the join's far side" {
    // LEFT JOIN LATERAL (SELECT i.title … ORDER BY i.id LIMIT 1) t ON true
    try expectNulls(
        \\[{"Plan": {"Node Type": "Nested Loop", "Join Type": "Left", "Output": ["e.id", "i.title"],
        \\  "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id", "e.kind"]},
        \\    {"Node Type": "Limit", "Parent Relationship": "Inner", "Output": ["i.title", "i.id"],
        \\     "Plans": [{"Node Type": "Index Scan", "Parent Relationship": "Outer", "Output": ["i.title", "i.id"]}]}]}}]
    , &.{ false, true });
}

test "a RIGHT JOIN's far side is its outer input, and a FULL JOIN has two" {
    const right =
        \\[{"Plan": {"Node Type": "Hash Join", "Join Type": "Right", "Output": ["e.id", "i.title"],
        \\  "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id"]},
        \\    {"Node Type": "Hash", "Parent Relationship": "Inner", "Output": ["i.title", "i.id"]}]}}]
    ;
    try expectNulls(right, &.{ true, false });
    const full =
        \\[{"Plan": {"Node Type": "Hash Join", "Join Type": "Full", "Output": ["e.id", "i.title"],
        \\  "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id"]},
        \\    {"Node Type": "Hash", "Parent Relationship": "Inner", "Output": ["i.title", "i.id"]}]}}]
    ;
    try expectNulls(full, &.{ true, true });
}

test "a UNION ALL is read by position, under a sort and a limit, whatever its first branch calls the column" {
    // SELECT e.id, i.title FROM events e JOIN items i …
    // UNION ALL SELECT e.id, d.name FROM events e LEFT JOIN deals d …
    // ORDER BY 1 LIMIT 10
    try expectNulls(
        \\[{"Plan": {"Node Type": "Limit", "Output": ["e.id", "i.title"],
        \\ "Plans": [{"Node Type": "Sort", "Parent Relationship": "Outer", "Output": ["e.id", "i.title"],
        \\  "Plans": [{"Node Type": "Append", "Parent Relationship": "Outer",
        \\   "Plans": [
        \\    {"Node Type": "Hash Join", "Join Type": "Inner", "Parent Relationship": "Member", "Output": ["e.id", "i.title"],
        \\     "Plans": [
        \\       {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id"]},
        \\       {"Node Type": "Hash", "Parent Relationship": "Inner", "Output": ["i.title", "i.id"]}]},
        \\    {"Node Type": "Hash Join", "Join Type": "Left", "Parent Relationship": "Member", "Output": ["e_1.id", "d.name"],
        \\     "Plans": [
        \\       {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e_1.id", "e_1.item_id"]},
        \\       {"Node Type": "Hash", "Parent Relationship": "Inner", "Output": ["d.name", "d.id"]}]}]}]}]}}]
    , &.{ false, true });
}

test "a UNION without ALL is an aggregate over the branches, and read the same way" {
    try expectNulls(
        \\[{"Plan": {"Node Type": "Aggregate", "Output": ["e.id", "i.title"],
        \\ "Plans": [{"Node Type": "Append", "Parent Relationship": "Outer",
        \\   "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Member", "Output": ["e.id", "e.kind"]},
        \\    {"Node Type": "Hash Join", "Join Type": "Left", "Parent Relationship": "Member", "Output": ["e_1.id", "d.name"],
        \\     "Plans": [
        \\       {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e_1.id"]},
        \\       {"Node Type": "Hash", "Parent Relationship": "Inner", "Output": ["d.name", "d.id"]}]}]}]}}]
    , &.{ false, true });
}

test "a grouping column from the far side is NULL, and an aggregate is not judged" {
    // SELECT i.title, count(*) … LEFT JOIN items i … GROUP BY i.title
    try expectNulls(
        \\[{"Plan": {"Node Type": "Aggregate", "Output": ["i.title", "count(*)"],
        \\ "Plans": [{"Node Type": "Hash Join", "Join Type": "Left", "Parent Relationship": "Outer", "Output": ["i.title"],
        \\   "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id"]},
        \\    {"Node Type": "Hash", "Parent Relationship": "Inner", "Output": ["i.title", "i.id"]}]}]}}]
    , &.{ true, false });
}

test "a column renamed by a subquery or a CTE is not followed, so it is not called NULL" {
    // SELECT s.b FROM (SELECT e.id, i.title AS b … LEFT JOIN … LIMIT 5) s
    try expectNulls(
        \\[{"Plan": {"Node Type": "Subquery Scan", "Output": ["s.b"],
        \\ "Plans": [{"Node Type": "Limit", "Parent Relationship": "Subquery", "Output": ["e.id", "i.title"],
        \\   "Plans": [{"Node Type": "Nested Loop", "Join Type": "Left", "Parent Relationship": "Outer", "Output": ["e.id", "i.title"],
        \\     "Plans": [
        \\      {"Node Type": "Index Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id"]},
        \\      {"Node Type": "Index Scan", "Parent Relationship": "Inner", "Output": ["i.id", "i.title"]}]}]}]}}]
    , &.{false});
    // WITH x AS MATERIALIZED (… LEFT JOIN …) SELECT x.id, x.title FROM x
    try expectNulls(
        \\[{"Plan": {"Node Type": "CTE Scan", "Output": ["x.id", "x.title"],
        \\ "Plans": [{"Node Type": "Hash Join", "Join Type": "Left", "Parent Relationship": "InitPlan", "Output": ["e.id", "i.title"],
        \\   "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id"]},
        \\    {"Node Type": "Hash", "Parent Relationship": "Inner", "Output": ["i.title", "i.id"]}]}]}}]
    , &.{ false, false });
}

test "a LATERAL that repeats a column of its outer row leaves that column alone, and its copy is NULL" {
    // SELECT e.kind, t.k, t.title FROM events e LEFT JOIN LATERAL
    //   (SELECT e.kind AS k, i.title … ORDER BY i.id LIMIT 1) t ON true
    try expectNulls(
        \\[{"Plan": {"Node Type": "Nested Loop", "Join Type": "Left", "Output": ["e.kind", "(e.kind)", "i.title"],
        \\  "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id", "e.item_id", "e.kind"]},
        \\    {"Node Type": "Limit", "Parent Relationship": "Inner", "Output": ["(e.kind)", "i.title", "i.id"],
        \\     "Plans": [{"Node Type": "Index Scan", "Parent Relationship": "Outer", "Output": ["e.kind", "i.title", "i.id"]}]}]}}]
    , &.{ false, true, true });
}

test "a constant is not a column, wherever the plan computes it" {
    try expectNulls(
        \\[{"Plan": {"Node Type": "Nested Loop", "Join Type": "Left", "Output": ["'x'::text", "i.title"],
        \\  "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id"]},
        \\    {"Node Type": "Limit", "Parent Relationship": "Inner", "Output": ["'x'::text", "i.title"],
        \\     "Plans": [{"Node Type": "Index Scan", "Parent Relationship": "Outer", "Output": ["i.title"]}]}]}}]
    , &.{ false, true });
}

test "a quoted name is still a column" {
    try testing.expect(isColumn("i.title"));
    try testing.expect(isColumn("\"Item\".\"Title.x\""));
    try testing.expect(isColumn("(e.kind)"));
    try testing.expect(!isColumn("title"));
    try testing.expect(!isColumn("COALESCE(i.title, ''::text)"));
    try testing.expect(!isColumn("'x'::text"));
    try testing.expect(!isColumn("count(*)"));
}

test "a name with an escape in it is read as the name" {
    // SELECT e.id, "It\"em".title FROM events e LEFT JOIN items "It""em" …
    try expectNulls(
        \\[{"Plan": {"Node Type": "Nested Loop", "Join Type": "Left", "Output": ["e.id", "\"It\"\"em\".title"],
        \\  "Startup Cost": 0.15, "Plan Rows": 1e3, "Parallel Aware": false, "Filter": null,
        \\  "Plans": [
        \\    {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Output": ["e.id"]},
        \\    {"Node Type": "Index Scan", "Parent Relationship": "Inner", "Output": ["\"It\"\"em\".title", "\u00e9.x"]}]}}]
    , &.{ false, true });
}

test "a plan this cannot read says nothing rather than failing" {
    try expectNulls("not json", &.{ false, false });
    try expectNulls("[]", &.{false});
    try expectNulls("[{\"Plan\": {\"Node Type\": ", &.{false});
    try expectNulls(&@as([600]u8, @splat('[')), &.{false});
    try expectNulls("[{\"Plan\": {\"Node Type\": \"Result\"}}]", &.{false});
}
