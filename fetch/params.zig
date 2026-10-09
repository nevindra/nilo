//! How a struct of params becomes bytes on the wire: a query string, a form
//! body, and a path segment of a `Target`. Internal to `nilo_fetch`: `fetch.zig`
//! and `target.zig` import it and the module root re-exports none of it, so what
//! a dependent may name is only what `docs/reference/fetch.md` lists
//! (`withQuery`, `formBody`, `basicAuth`).
//!
//! One walk serves both spellings (`Style`): a query writes a space `%20`, a
//! form body writes it `+`, and everything else is the same encoding
//! ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)). The measuring
//! pass and the writing pass are two walks over the same fields, so a caller
//! allocates exactly once.

const std = @import("std");
const core = @import("nilo_core");

const Str = core.Str;

/// The `content-type` of a form body.
pub const form_content_type = "application/x-www-form-urlencoded";

/// The Refusal for params that are not a struct with one field per param,
/// and for any field no query string can carry. `skip` names the fields
/// that are not the query's — a target's path segments — so they are held
/// to a segment's rules instead (ADR 061).
pub fn checkQuery(comptime P: type, comptime called: []const u8, comptime skip: []const []const u8) void {
    checkParams(P, called, skip, "query");
}

/// `checkQuery` for a form body: the same struct, the same field types, and
/// a message that says "form" because that is what the caller wrote.
pub fn checkForm(comptime P: type, comptime called: []const u8) void {
    checkParams(P, called, &.{}, "form");
}

fn checkParams(comptime P: type, comptime called: []const u8, comptime skip: []const []const u8, comptime kind: []const u8) void {
    const info = @typeInfo(P);
    // A walk over every param, each asked whether it is skipped: a query of
    // 400 params stopped at "evaluation exceeded 1000 backwards branches" at
    // a line in this file, and a person reads that as a fault in the 400th
    // ([ADR 126](../docs/adr/126-a-check-pays-for-its-own-branches.md)).
    const width = switch (info) {
        .@"struct" => |st| st.field_names.len,
        else => 0,
    };
    @setEvalBranchQuota(1_000 + 20 * @as(u32, @intCast(width * (skip.len + 1))));
    // `.{}` is the empty tuple to Zig and "no params" to a caller, so it
    // passes; a tuple with something in it has no names to be params.
    const named = switch (info) {
        .@"struct" => |st| !st.is_tuple or st.field_names.len == 0,
        else => false,
    };
    if (!named) @compileError("nilo: " ++ called ++ " was handed a " ++ @typeName(P) ++
        " for its params, and a " ++ kind ++ " is a struct with one field per param.");
    inline for (info.@"struct".field_names, info.@"struct".field_types) |name, FT| {
        if (comptime !among(skip, name)) comptime checkParamField(name, FT, kind);
    }
}

/// What goes between a base and the first param: nothing when the base
/// already ends on a separator, `&` when it already has a query, `?`
/// otherwise. Every param after the first gets `&`.
pub fn querySeparator(base: []const u8) ?u8 {
    if (base.len == 0) return '?';
    if (base[base.len - 1] == '?' or base[base.len - 1] == '&') return null;
    if (std.mem.indexOfScalar(u8, base, '?') != null) return '&';
    return '?';
}

/// How many bytes `params` add after a base, with `first` the separator
/// before the first of them. The measuring half of `withQuery`, shared with
/// a target's URL so that one is also one allocation sized exactly.
pub fn queryLen(params: anytype, first: ?u8, comptime skip: []const []const u8) usize {
    return paramsLen(params, first, skip, .query);
}

/// How `params` are spelled: a query string writes a space `%20`, a form
/// body writes it `+` and a literal `+` `%2B` (the
/// `application/x-www-form-urlencoded` of RFC 6749 §4.1.3). Everything else
/// is the same encoding, which is why the two share one walk
/// ([ADR 061](../docs/adr/061-a-fitting-borrows-the-loop.md)).
pub const Style = enum { query, form };

/// `queryLen` in either style.
pub fn paramsLen(params: anytype, first: ?u8, comptime skip: []const []const u8, comptime style: Style) usize {
    var len: usize = 0;
    var written: usize = 0;
    inline for (@typeInfo(@TypeOf(params)).@"struct".field_names) |name| {
        if (comptime among(skip, name)) continue;
        if (queryValue(@field(params, name))) |v| {
            if (written > 0 or first != null) len += 1;
            len += textLen(name, style) + 1 + v.lenAs(style);
            written += 1;
        }
    }
    return len;
}

/// The writing half of `queryLen`, into a writer already sized by it.
pub fn queryWrite(w: *std.Io.Writer, params: anytype, first: ?u8, comptime skip: []const []const u8) void {
    paramsWrite(w, params, first, skip, .query);
}

/// `queryWrite` in either style.
pub fn paramsWrite(w: *std.Io.Writer, params: anytype, first: ?u8, comptime skip: []const []const u8, comptime style: Style) void {
    var sep = first;
    inline for (@typeInfo(@TypeOf(params)).@"struct".field_names) |name| {
        if (comptime among(skip, name)) continue;
        if (queryValue(@field(params, name))) |v| {
            if (sep) |ch| w.writeByte(ch) catch unreachable;
            sep = '&';
            textWrite(w, name, style) catch unreachable;
            w.writeByte('=') catch unreachable;
            v.writeAs(w, style) catch unreachable;
        }
    }
}

fn among(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// One query param's value, on its way out: digits and the two words go as
/// they are, text is percent-encoded. A path segment of a target is written
/// the same way, which is why the type is shared (ADR 061).
pub const QueryValue = union(enum) {
    /// An int, formatted. Forty bytes holds a 128-bit one with its sign.
    number: struct { buf: [40]u8, len: usize },
    /// `true` or `false`.
    word: []const u8,
    /// Text, encoded on the way out with `/` as data.
    text: []const u8,

    pub fn encodedLen(self: QueryValue) usize {
        return self.lenAs(.query);
    }

    pub fn write(self: QueryValue, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.writeAs(w, .query);
    }

    pub fn lenAs(self: QueryValue, comptime style: Style) usize {
        return switch (self) {
            .number => |n| n.len,
            .word => |s| s.len,
            .text => |s| textLen(s, style),
        };
    }

    pub fn writeAs(self: QueryValue, w: *std.Io.Writer, comptime style: Style) std.Io.Writer.Error!void {
        switch (self) {
            .number => |n| try w.writeAll(n.buf[0..n.len]),
            .word => |s| try w.writeAll(s),
            .text => |s| try textWrite(w, s, style),
        }
    }
};

/// `raw` percent-encoded the way `style` spells it. The form style is the
/// query style with each `%20` written `+`: `core.percent` has no `+` to give
/// on purpose (its header says why, for signatures), so the one difference is
/// made here, where the only caller that wants it is.
pub fn textLen(raw: []const u8, comptime style: Style) usize {
    const n = core.percent.encodedLen(raw, .unreserved);
    if (style == .query) return n;
    return n - 2 * std.mem.count(u8, raw, " ");
}

pub fn textWrite(w: *std.Io.Writer, raw: []const u8, comptime style: Style) std.Io.Writer.Error!void {
    if (style == .query) return core.percent.encodeWrite(w, raw, .unreserved);
    var rest = raw;
    while (std.mem.indexOfScalar(u8, rest, ' ')) |at| {
        try core.percent.encodeWrite(w, rest[0..at], .unreserved);
        try w.writeByte('+');
        rest = rest[at + 1 ..];
    }
    try core.percent.encodeWrite(w, rest, .unreserved);
}

/// The value of one field of a query struct as a `QueryValue`, or null for
/// an optional that is null, which is the param left out.
pub fn queryValue(v: anytype) ?QueryValue {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .null => return null,
        .optional => return if (v) |inner| queryValue(inner) else null,
        .int, .comptime_int => {
            var out: QueryValue = .{ .number = .{ .buf = undefined, .len = 0 } };
            const digits = std.fmt.bufPrint(&out.number.buf, "{d}", .{v}) catch unreachable; // 40 bytes holds any int here
            out.number.len = digits.len;
            return out;
        },
        .bool => return .{ .word = if (v) "true" else "false" },
        else => return .{ .text = if (T == Str) v.view() else v },
    }
}

/// Whether `T` is text this module reads as such: a `Str`, a slice of
/// bytes, or a pointer to an array of them, which is what a string literal
/// is.
pub fn isText(comptime T: type) bool {
    if (T == Str) return true;
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn checkParamField(comptime field: []const u8, comptime T: type, comptime kind: []const u8) void {
    const ok = switch (@typeInfo(T)) {
        .int, .comptime_int, .bool, .null => true,
        .optional => |o| return checkParamField(field, o.child, kind),
        else => isText(T),
    };
    if (!ok) @compileError("nilo: the " ++ kind ++ " field `" ++ field ++ "` is a " ++ @typeName(T) ++
        ", and a " ++ kind ++ " value is an int, a bool, text, or an optional of one.");
}

/// The Refusal for text handed to a JSON call. `std.json` would write it
/// out as one JSON string — `"{\"amount\":500}"`, quotes and escapes and all
/// — and the far end would answer 400 to a body that looked right in the
/// editor. A body already encoded goes through `post`.
pub fn refuseJsonText(comptime T: type, comptime called: []const u8) void {
    if (isText(T)) @compileError("nilo: " ++ called ++ " was handed text, and would send it as one JSON string. " ++
        "A body already encoded goes through post, put, patch or send.");
}

test "text is read as text and a struct is not, which is what the two Refusals rest on" {
    try std.testing.expect(isText([]const u8));
    try std.testing.expect(isText([]u8));
    try std.testing.expect(isText(*const [3:0]u8));
    try std.testing.expect(isText(Str));
    try std.testing.expect(!isText(u32));
    try std.testing.expect(!isText(struct { a: u8 }));
    try std.testing.expect(!isText([]const u32));
}
