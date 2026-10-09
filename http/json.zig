//! Writing a response as JSON.
//!
//! `std.json` is what this falls back to, and for a while it was all there
//! was. What it costs is not obvious from reading it: it writes a JSON string
//! a byte at a time, through the writer, checking each one for something that
//! needs escaping. On the ~1KB payload that is nilo's primary metric that
//! came to 1038ns — more than everything else the request does put together.
//!
//! So the shapes a handler actually returns get a writer of their own,
//! generated while compiling from the type:
//!
//! - Every constant part of the output — the braces, the quoted field names,
//!   the colons and commas — is one comptime string. A struct of four fields
//!   is four `writeAll`s of a literal, not a writer call per punctuation mark.
//! - A string is scanned 32 bytes at a time for the three things JSON cannot
//!   carry as-is, and the run in between is written whole. Almost every string
//!   has none at all, which makes it one scan and one `writeAll`.
//!
//! 1038ns → 126ns on that payload, 75ns → 22ns on a small one.
//!
//! **The output is byte-for-byte what `std.json` would have written, except for
//! a float.** That is not a hope: `covers` decides while compiling which types
//! this path is allowed to touch, anything else goes to `std.json` unchanged,
//! and the tests at the bottom hold the two against each other value by value.
//! A float is the one thing both paths spell themselves, the way serde_json
//! does (`jsonfloat.zig`): the same shortest digits, but `1.0` where `std.json`
//! writes `1`, `1e+16` where it writes seventeen digits, `5e-324` where it
//! writes 320 characters, and `null` for infinity and NaN
//! ([ADR 096](../docs/adr/096-a-byte-that-is-not-text-is-not-a-string.md)).

const std = @import("std");
const Str = @import("nilo_core").Str;
const mark = @import("jsonmark.zig");
const convert = @import("convert.zig");
const field_mod = @import("field.zig");
const fail = @import("fail.zig");
const patch_mod = @import("patch.zig");
const jsonfloat = @import("jsonfloat.zig");

/// Serialise `value` as JSON. Uses the generated writer when the type is one
/// it covers, and `std.json` when it is not — decided while compiling, so
/// there is no runtime branch either way.
pub fn write(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    if (comptime covers(T)) return writeValue(T, w, value);
    comptime refuseRenameOnTheFallback(T);
    return stringify(w, value);
}

/// `write` into memory the caller owns: the bytes of `value` as JSON, which
/// the caller frees with `gpa`. For a job's payload, an alert body or a test's
/// expected text, where there is no writer in hand and no request to borrow an
/// arena from. Same rules as `write`, because it is `write` (a response is
/// written by the same function, so the two cannot drift apart).
pub fn alloc(gpa: std.mem.Allocator, value: anytype) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // An `Allocating` writer fails only by running out of memory.
    write(&out.writer, value) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// What `std.json.Stringify.value` does, except that a float is spelled by
/// `jsonfloat.zig`, which asks whether it is finite first ([ADR 096](../docs/adr/096-a-byte-that-is-not-text-is-not-a-string.md)).
///
/// **Every value that is not `covers`' goes through here**, so the rule holds on
/// every path out of `http/` and not only the fast one.
fn stringify(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    var jw: FiniteJson = .{ .inner = .{ .writer = w, .options = .{} }, .writer = w };
    return jw.write(value);
}

/// A `std.json.Stringify` that spells every float the way `jsonfloat.zig` does.
///
/// `Stringify` has no hook for a number: a float is a `print("{}")` inside
/// `write`, so infinity came out as the bare word `inf`, NaN as the string
/// `"nan"`, `1.0` as `1` and `f64::MAX` as 309 digits. But a type's `jsonStringify(self, jw: anytype)` is handed whatever
/// writer the caller has, which is what makes this possible at all: this type
/// walks the shapes `Stringify.write` walks, calls itself for every child, and
/// hands the leaves to the `Stringify` it wraps, so the bytes are the ones
/// `std.json` writes and a float inside a `std.json.Value`, a map, a tuple or a
/// type's own `jsonStringify` is seen on the way past. Its punctuation state
/// lives in `inner`, so the two never disagree about a comma.
///
/// **A `jsonStringify` that names `*std.json.Stringify` as its parameter is the
/// type author's own** and is handed `inner` as it always was; its floats are
/// theirs to guard. One that takes `anytype`, which is how every nilo type and
/// every one in `std.json` is written, gets this type and is covered.
const FiniteJson = struct {
    inner: std.json.Stringify,
    /// Kept because a `jsonStringify` may reach for `jw.writer`.
    writer: *std.Io.Writer,

    const Error = std.Io.Writer.Error;

    pub fn beginObject(self: *FiniteJson) Error!void {
        return self.inner.beginObject();
    }
    pub fn endObject(self: *FiniteJson) Error!void {
        return self.inner.endObject();
    }
    pub fn beginArray(self: *FiniteJson) Error!void {
        return self.inner.beginArray();
    }
    pub fn endArray(self: *FiniteJson) Error!void {
        return self.inner.endArray();
    }
    pub fn objectField(self: *FiniteJson, key: []const u8) Error!void {
        return self.inner.objectField(key);
    }
    pub fn objectFieldRaw(self: *FiniteJson, quoted_key: []const u8) Error!void {
        return self.inner.objectFieldRaw(quoted_key);
    }
    pub fn beginObjectFieldRaw(self: *FiniteJson) Error!void {
        return self.inner.beginObjectFieldRaw();
    }
    pub fn endObjectFieldRaw(self: *FiniteJson) void {
        self.inner.endObjectFieldRaw();
    }
    pub fn beginWriteRaw(self: *FiniteJson) Error!void {
        return self.inner.beginWriteRaw();
    }
    pub fn endWriteRaw(self: *FiniteJson) void {
        self.inner.endWriteRaw();
    }
    pub fn print(self: *FiniteJson, comptime fmt: []const u8, args: anytype) Error!void {
        return self.inner.print(fmt, args);
    }

    pub fn write(self: *FiniteJson, v: anytype) Error!void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .float, .comptime_float => {
                // `std.json` has no hook for a number, so the leaf is written
                // raw: the comma and the colon are still the `Stringify`'s.
                try self.inner.beginWriteRaw();
                try jsonfloat.write(self.writer, v);
                self.inner.endWriteRaw();
            },
            .optional => {
                if (v) |payload| return self.write(payload);
                return self.inner.write(null);
            },
            .@"enum", .@"union", .@"struct" => {
                if (comptime std.meta.hasFn(T, "jsonStringify")) return self.own(v);
                switch (@typeInfo(T)) {
                    .@"union" => |info| {
                        // Untagged is `std.json`'s own compile error.
                        if (info.tag_type == null) return self.inner.write(v);
                        try self.beginObject();
                        inline for (info.field_names, info.field_types) |f_name, f_type| {
                            if (v == @field(info.tag_type.?, f_name)) {
                                try self.objectField(f_name);
                                if (f_type == void) {
                                    try self.beginObject();
                                    try self.endObject();
                                } else {
                                    try self.write(@field(v, f_name));
                                }
                                break;
                            }
                        }
                        return self.endObject();
                    },
                    .@"struct" => |info| {
                        if (info.is_tuple) try self.beginArray() else try self.beginObject();
                        inline for (info.field_names, info.field_types) |f_name, f_type| {
                            if (f_type == void) continue;
                            if (!info.is_tuple) try self.objectField(f_name);
                            try self.write(@field(v, f_name));
                        }
                        return if (info.is_tuple) self.endArray() else self.endObject();
                    },
                    else => return self.inner.write(v),
                }
            },
            .pointer => |p| switch (p.size) {
                .one => switch (@typeInfo(p.child)) {
                    .array => return self.write(@as([]const std.meta.Elem(p.child), v)),
                    else => return self.write(v.*),
                },
                .many, .slice => {
                    if (p.size == .many and p.sentinel() == null) return self.inner.write(v);
                    const slice = if (p.size == .many) std.mem.span(v) else v;
                    // A string, which is what `std.json` makes of text and
                    // what it makes of anything else it cannot call one.
                    if (p.child == u8 and std.unicode.utf8ValidateSlice(slice)) return self.inner.write(slice);
                    try self.beginArray();
                    for (slice) |x| try self.write(x);
                    return self.endArray();
                },
                else => return self.inner.write(v),
            },
            .array => return self.write(&v),
            .vector => |info| {
                const array: [info.len]info.child = v;
                return self.write(&array);
            },
            else => return self.inner.write(v),
        }
    }

    /// The value's own `jsonStringify`, handed this writer unless it asks for a
    /// `std.json.Stringify` by name.
    fn own(self: *FiniteJson, v: anytype) Error!void {
        const params = @typeInfo(@TypeOf(@TypeOf(v).jsonStringify)).@"fn".param_types;
        if (params.len == 2 and params[1] == *std.json.Stringify) {
            return v.jsonStringify(&self.inner);
        }
        return v.jsonStringify(self);
    }
};

/// Read a JSON body into a `T`, with every number read the way a query's is
/// ([ADR 084](../docs/adr/084-a-number-in-a-request-is-not-a-zig-literal.md)).
///
/// **`std.json` reads a number token with `parseInt` and `parseFloat`, which is
/// Zig's literal grammar**, and a *string* token is handed to them too: `"1_0"`
/// was 10, `"+7"` was 7, `"nan"` was a NaN and `1e999` was infinity. A `u128`
/// posted as `2e38` was worse than a wrong value: `sliceToInt` converts through
/// an `i128` and the cast panics in ReleaseSafe. `std.json` offers no hook for a
/// number, so this is the same walk it makes over a struct, a list and an
/// optional, with the two leaves swapped for `convert.spelledAsNumber` and the
/// parse that follows it. Everything else, a type with its own `jsonParse`
/// included, is handed to `std.json.innerParse` unchanged, so what it reads and
/// how it refuses is what it always was.
///
/// One pass over the bytes, no allocation `std.json` did not make: the number's
/// token is the one `std.json` would have taken, and a body that was fine is
/// still fine. A number inside a type this walk does not enter (a type
/// with its own `jsonParse`, a `std.json.Value`) still goes by that type's rules.
pub fn parseLeaky(
    comptime T: type,
    gpa: std.mem.Allocator,
    input: []const u8,
    options: std.json.ParseOptions,
) std.json.ParseError(std.json.Scanner)!T {
    const Body = struct {
        value: T,

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            resolved: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!@This() {
            return .{ .value = try innerRead(T, allocator, source, resolved) };
        }
    };
    const parsed = std.json.parseFromSliceLeaky(Body, gpa, input, options) catch |err| {
        if (err == error.DuplicateField) saySecondKey(gpa, input);
        return err;
    };
    return parsed.value;
}

/// A JSON value that was already parsed, read into a `T` the way `parseLeaky`
/// reads text: the same walk, so a number is spelled as a query's is and a
/// `?T` the object left out is null (`field.zig`).
///
/// **For the diagnosis, which has the body as a `std.json.Value` and no text.**
/// `std.json.parseFromValueLeaky` walks a value with its own rules, which
/// refuse an absent `?T` and read `"1_0"` as a number, so a field read through
/// it disagreed with the same field read from the body. The value is written
/// back out and read again, which costs one more pass over a body that was
/// already going to be refused.
pub fn parseValueLeaky(
    comptime T: type,
    gpa: std.mem.Allocator,
    value: std.json.Value,
    options: std.json.ParseOptions,
) std.json.ParseError(std.json.Scanner)!T {
    const text = try std.json.Stringify.valueAlloc(gpa, value, .{});
    return parseLeaky(T, gpa, text, options);
}

/// Put a sentence about the key an object has twice on this request's Failure.
///
/// `std.json` refuses a repeated key and says only that it did, which reached a
/// client as a bare `Bad Request`. It is refused rather than resolved because
/// two parsers that keep a different one of the two read two different
/// requests, which is the disagreement ADR 084 and ADR 070 are about, and a
/// tagged union's discriminator is the key where it matters most: a front end
/// that keeps the last one sees another variant (ADR 016). Reached only after a
/// parse that already failed, so the second walk costs a body nobody wanted.
fn saySecondKey(gpa: std.mem.Allocator, input: []const u8) void {
    // Cleared first: the Failure speaks only when it is set afresh, so what
    // a handler caught earlier cannot be taken for this sentence (ADR 004).
    if (fail.current()) |failure| failure.clear();
    const key = firstRepeatedKey(gpa, input) orelse return;
    // The Failure rather than a returned error: the caller returns the error
    // `std.json` gave, and the status table already maps it to a 400.
    if (fail.current()) |failure| failure.set(
        400,
        "the request body has the key \"{s}\" twice, and nilo does not guess which one is meant",
        .{key},
    );
}

/// The first key that an object in `input` has more than once, or null.
fn firstRepeatedKey(gpa: std.mem.Allocator, input: []const u8) ?[]const u8 {
    const Level = struct {
        is_object: bool,
        expect_key: bool = true,
        keys: std.ArrayList([]const u8) = .empty,
    };
    var scan = std.json.Scanner.initCompleteInput(gpa, input);
    defer scan.deinit();
    var stack: std.ArrayList(Level) = .empty;

    while (true) {
        const token = scan.nextAlloc(gpa, .alloc_if_needed) catch return null;
        switch (token) {
            .end_of_document => return null,
            .object_begin, .array_begin => {
                stack.append(gpa, .{ .is_object = token == .object_begin }) catch return null;
                continue;
            },
            .object_end, .array_end => _ = stack.pop(),
            .string, .allocated_string => |text| if (stack.items.len > 0) {
                const top = &stack.items[stack.items.len - 1];
                if (top.is_object and top.expect_key) {
                    for (top.keys.items) |seen| if (std.mem.eql(u8, seen, text)) return text;
                    top.keys.append(gpa, text) catch return null;
                    top.expect_key = false;
                    continue;
                }
            },
            else => {},
        }
        // A value is over, so an object around it wants a key next.
        if (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.is_object) top.expect_key = true;
        }
    }
}

/// What `parseLeaky` does at each level, public because a type that hands over
/// its own `jsonParse` and holds a `T` (`Patch`, a tagged variant) reads that
/// `T` through it.
pub fn innerRead(
    comptime T: type,
    gpa: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!T {
    // A `Patch` is a number in a body as often as any field is, and its own
    // reader hands the value to `std.json`, so it is read here instead: null is
    // `.cleared` and anything else is the value, read by this walk.
    if (comptime patch_mod.isPatch(T)) {
        if (try source.peekNextTokenType() == .null) {
            _ = try source.next();
            return .cleared;
        }
        return .{ .value = try innerRead(T.nilo_patch, gpa, source, options) };
    }
    // A map has a `jsonParse` of `std.json`'s, which would read a number
    // inside it by Zig's literal grammar, so it is read here instead
    // (ADR 084). A `std.json.Value` is left to `std.json` on purpose: it keeps
    // a string a string, and a number too large for a float as the text it
    // was written in (`number_string`), so no number in it is ever guessed.
    if (comptime mapValue(T)) |V| return readMap(T, V, gpa, source, options);
    // A type that parses itself, and `Str`, are the type's to read.
    if (comptime T == Str or readsItself(T)) return std.json.innerParse(T, gpa, source, options);

    switch (@typeInfo(T)) {
        .int => |i| {
            const token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
            const text = switch (token) {
                inline .number, .allocated_number, .string, .allocated_string => |slice| slice,
                else => return error.UnexpectedToken,
            };
            if (!convert.spelledAsNumber(text, i.signedness == .signed, false)) return error.InvalidNumber;
            return std.fmt.parseInt(T, text, 10);
        },
        .float => {
            const token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
            const text = switch (token) {
                inline .number, .allocated_number, .string, .allocated_string => |slice| slice,
                else => return error.UnexpectedToken,
            };
            if (!convert.spelledAsNumber(text, true, true)) return error.InvalidNumber;
            const parsed = try std.fmt.parseFloat(T, text);
            if (!std.math.isFinite(parsed)) return error.Overflow;
            return parsed;
        },
        .optional => |o| switch (try source.peekNextTokenType()) {
            .null => {
                _ = try source.next();
                return null;
            },
            else => return try innerRead(o.child, gpa, source, options),
        },
        .@"struct" => |s| {
            if (comptime s.is_tuple) {
                if (.array_begin != try source.next()) return error.UnexpectedToken;
                var r: T = undefined;
                inline for (s.field_types, 0..) |f_type, i| r[i] = try innerRead(f_type, gpa, source, options);
                if (.array_end != try source.next()) return error.UnexpectedToken;
                return r;
            }
            if (.object_begin != try source.next()) return error.UnexpectedToken;
            return readFields(T, null, false, gpa, source, options, options);
        },
        .@"union" => |u| {
            // `std.json`'s encoding of a tagged union, an object of one key,
            // read by its own walk with the payload swapped for this one, so a
            // number in an arm is spelled as every other is (ADR 084). An
            // untagged union is `std.json`'s own compile error.
            if (comptime u.tag_type == null) return std.json.innerParse(T, gpa, source, options);
            if (.object_begin != try source.next()) return error.UnexpectedToken;
            const key = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
            const name = switch (key) {
                inline .string, .allocated_string => |slice| slice,
                else => return error.UnexpectedToken,
            };
            inline for (u.field_names, u.field_types) |f_name, f_type| {
                if (std.mem.eql(u8, f_name, name)) {
                    const value: T = if (comptime f_type == void) void_arm: {
                        if (.object_begin != try source.next()) return error.UnexpectedToken;
                        if (.object_end != try source.next()) return error.UnexpectedToken;
                        break :void_arm @unionInit(T, f_name, {});
                    } else @unionInit(T, f_name, try innerRead(f_type, gpa, source, options));
                    if (.object_end != try source.next()) return error.UnexpectedToken;
                    return value;
                }
            }
            return error.UnknownField;
        },
        .array => |a| {
            if (comptime a.child == u8) return std.json.innerParse(T, gpa, source, options);
            if (.array_begin != try source.next()) return error.UnexpectedToken;
            var r: T = undefined;
            for (&r) |*element| element.* = try innerRead(a.child, gpa, source, options);
            if (.array_end != try source.next()) return error.UnexpectedToken;
            return r;
        },
        .pointer => |p| {
            if (comptime p.size != .slice or p.child == u8) return std.json.innerParse(T, gpa, source, options);
            if (.array_begin != try source.peekNextTokenType()) return error.UnexpectedToken;
            _ = try source.next();
            var list: std.array_list.Managed(p.child) = .init(gpa);
            while (true) {
                if (.array_end == try source.peekNextTokenType()) {
                    _ = try source.next();
                    break;
                }
                try list.ensureUnusedCapacity(1);
                list.appendAssumeCapacity(try innerRead(p.child, gpa, source, options));
            }
            if (p.sentinel()) |sentinel| return try list.toOwnedSliceSentinel(sentinel);
            return try list.toOwnedSlice();
        },
        else => return std.json.innerParse(T, gpa, source, options),
    }
}

/// Refuse, while compiling, a struct read from a body that skips a field it
/// could not fill: a skipped field is never read, so it needs a default or a
/// `?T` to stand in for it (ADR 148). Asked where a type is first read from a
/// body and not where it is marked, because a type that is only ever written
/// skips a password hash with no default and has no reader to refuse it.
pub fn refuseUnreadableSkips(comptime T: type) void {
    comptime mark.checkSkipsReadable(T, struct {
        fn absent(comptime name: []const u8) bool {
            const info = @typeInfo(T).@"struct";
            for (info.field_names, info.field_types, info.field_attrs) |f_name, f_type, f_attrs| {
                if (std.mem.eql(u8, f_name, name)) return field_mod.FieldRule(f_type, f_attrs).may_be_absent;
            }
            unreachable;
        }
    }.absent);
}

/// The fields of an object whose `{` has been taken, read into `T`.
///
/// **`tag` is a tagged union's discriminator that the caller has already read**
/// (`jsonmark.zig`), so a key by that name that no field of `T` claims is not an
/// unknown field: it is the discriminator again, which is refused when
/// `tag_again`, and skipped when the caller read the object once to find it
/// and is reading it a second time. `options` is what the object itself is
/// held to and `nested` what everything inside its fields is: a variant's
/// payload is checked for unknown keys here and not below, which is the
/// reading a tagged variant has always had (ADR 016).
pub fn readFields(
    comptime T: type,
    comptime tag: ?[]const u8,
    comptime tag_again: bool,
    gpa: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
    nested: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!T {
    const s = @typeInfo(T).@"struct";
    comptime @setEvalBranchQuota(convert.budget(s.field_names));
    comptime refuseUnreadableSkips(T);

    var r: T = undefined;
    var seen = @as([s.field_names.len]bool, @splat(false));

    while (true) {
        const name_token = try source.nextAllocMax(gpa, .alloc_if_needed, options.max_value_len.?);
        const name = switch (name_token) {
            inline .string, .allocated_string => |slice| slice,
            .object_end => break,
            else => return error.UnexpectedToken,
        };

        inline for (s.field_names, s.field_types, s.field_attrs, 0..) |f_name, f_type, f_attrs, i| {
            if (f_attrs.@"comptime") @compileError("comptime fields are not supported: " ++ @typeName(T) ++ "." ++ f_name);
            // The key a client sends is the wire spelling, settled while
            // compiling like the writer's (ADR 148); a skipped field has no
            // key, so a client sending its name meets the unknown-key path.
            if (!(comptime mark.fieldSkipped(T, f_name)) and std.mem.eql(u8, (comptime mark.fieldWire(T, f_name)), name)) {
                if (seen[i]) switch (options.duplicate_field_behavior) {
                    .use_first => {
                        // Read and dropped: the type check is the point.
                        _ = try innerRead(f_type, gpa, source, nested);
                        break;
                    },
                    .@"error" => return error.DuplicateField,
                    .use_last => {},
                };
                @field(r, f_name) = try innerRead(f_type, gpa, source, nested);
                seen[i] = true;
                break;
            }
        } else {
            if (comptime tag) |t| if (std.mem.eql(u8, name, t)) {
                if (comptime tag_again) return error.DuplicateField;
                try source.skipValue();
                continue;
            };
            if (options.ignore_unknown_fields or comptime mark.ignoresUnknown(T)) {
                try source.skipValue();
            } else {
                return error.UnknownField;
            }
        }
    }
    // A field the object left out is its default or null, or the client's
    // mistake: the rule a query and a form follow (`field.zig`).
    inline for (s.field_names, s.field_types, s.field_attrs, 0..) |f_name, f_type, f_attrs, i| {
        if (!seen[i]) {
            const rule = field_mod.FieldRule(f_type, f_attrs);
            if (comptime rule.may_be_absent) @field(r, f_name) = rule.absent() else return error.MissingField;
        }
    }
    return r;
}

/// What a `std.json.ArrayHashMap(V)` holds, or null for any other type.
fn mapValue(comptime T: type) ?type {
    comptime {
        if (@typeInfo(T) != .@"struct" or !@hasField(T, "map")) return null;
        const M = @FieldType(T, "map");
        if (@typeInfo(M) != .@"struct" or !@hasDecl(M, "Entry")) return null;
        if (!@hasField(M.Entry, "value_ptr")) return null;
        const V = @typeInfo(@FieldType(M.Entry, "value_ptr")).pointer.child;
        return if (T == std.json.ArrayHashMap(V)) V else null;
    }
}

/// `std.json.ArrayHashMap(V).jsonParse` with `innerRead` reading each value, so
/// a number in a map is spelled the way every other number in a body is
/// (ADR 084). The same walk, the same allocations, the same refusals.
fn readMap(
    comptime T: type,
    comptime V: type,
    gpa: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) std.json.ParseError(@TypeOf(source.*))!T {
    var map: std.StringArrayHashMapUnmanaged(V) = .empty;
    errdefer map.deinit(gpa);

    if (.object_begin != try source.next()) return error.UnexpectedToken;
    while (true) {
        const token = try source.nextAlloc(gpa, options.allocate.?);
        switch (token) {
            inline .string, .allocated_string => |key| {
                const slot = try map.getOrPut(gpa, key);
                if (slot.found_existing) switch (options.duplicate_field_behavior) {
                    .use_first => {
                        _ = try innerRead(V, gpa, source, options);
                        continue;
                    },
                    .@"error" => return error.DuplicateField,
                    .use_last => {},
                };
                slot.value_ptr.* = try innerRead(V, gpa, source, options);
            },
            .object_end => break,
            else => return error.UnexpectedToken,
        }
    }
    return .{ .map = map };
}

/// Whether a type reads itself, which is the one thing `std.json` asks of it.
pub fn readsItself(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => std.meta.hasFn(T, "jsonParse"),
        else => false,
    };
}

/// A struct that renames or skips its fields cannot be written by `std.json`,
/// which does not read the marker
/// ([ADR 148](../docs/adr/148-a-field-name-is-a-spelling-too.md)).
///
/// **The fallback is the hole this closes.** `covers` errs narrow on purpose:
/// one field it does not recognise — an array of bytes, an untagged union, a
/// tuple, a type with its own `jsonStringify`, anything past eight deep — sends
/// the whole value to `std.json`. A renamed struct anywhere in that value would
/// then go out spelled the way it is written, and a skipped field would go out
/// at all, while `openapi.schemaWithin` promised otherwise, and nothing would
/// fail.
///
/// So it is a compile error rather than a quiet disagreement, which is the same
/// answer ADR 016 reached for a type that writes its own JSON and describes its
/// fields.
fn refuseRenameOnTheFallback(comptime T: type) void {
    comptime {
        const Renamed = mark.renamedFieldsWithin(T) orelse return;
        @compileError(
            "nilo: `" ++ @import("names.zig").of(Renamed) ++ "` renames or skips its fields, and this " ++
                "value goes to `std.json`, which does not read the marker (ADR 148).\n" ++
                "  `covers` sends the whole value to `std.json` when one shape in it is not " ++
                "nilo's to write: a tuple, an array of bytes, an untagged union, a type with " ++
                "its own `jsonStringify`, or anything nested more than eight deep.\n" ++
                "  The keys would go out spelled as they are written, and a skipped field would go " ++
                "out at all, while the API description promised otherwise. Take `rename_all` " ++
                "and `skip` off, or take out the shape that cannot be written here.",
        );
    }
}

/// Whether `T` writes its own JSON **and says what that JSON looks like** —
/// `jsonStringify` beside a `nilo_openapi` naming a scalar
/// ([ADR 148](../docs/adr/148-a-field-name-is-a-spelling-too.md)).
///
/// Such a type is a **leaf**: the generated writer hands the value itself to
/// `std.json` and keeps writing the object around it, rather than giving up on
/// the whole response. `sql.Uuid`, `sql.Timestamp`, `sql.AsText` and `id.Uuid`
/// are all one, which is what makes the difference: a product whose every key
/// is a uuid had no response this file could write at all, so `rename_all` was
/// refused on every one of them (ADR 148) and the fast writer never ran.
///
/// **`nilo_openapi` is the gate rather than `jsonStringify` alone**, and the
/// two halves are the same sentence read twice. A marker may only name
/// `"string"`, `"integer"`, `"number"` or `"boolean"` (`openapi.toldOf`), so a
/// type carrying one has already promised its JSON is a single scalar with
/// nothing nested inside it — which is exactly the promise this needs to keep
/// writing the punctuation on both sides of it. A type that writes its own
/// JSON and says nothing about it stays `std.json`'s whole value, as it was.
fn writesItsOwnScalar(comptime T: type) bool {
    comptime {
        if (!hasDecl(T, "jsonStringify")) return false;
        if (!hasDecl(T, "nilo_openapi")) return false;
        const said = T.nilo_openapi;
        if (!@hasField(@TypeOf(said), "type")) return false;
        // Read here rather than deferred to `openapi.zig`, which is the file
        // that owns the refusal: a marker with a `type` this does not know is
        // left to `std.json` exactly as it was, so a badly written one changes
        // no byte and still gets its own sentence the moment it reaches a
        // document.
        for ([_][]const u8{ "string", "integer", "number", "boolean" }) |kind| {
            if (std.mem.eql(u8, said.type, kind)) return true;
        }
        return false;
    }
}

/// Whether the generated writer handles `T`. Deliberately narrow: a type
/// this does not recognise is `std.json`'s to write, and the cost of being
/// wrong here is a response that differs from what nilo used to send.
///
/// Answerable only while compiling — it reads the types of a struct's fields —
/// so call it as `comptime covers(T)`.
pub fn covers(comptime T: type) bool {
    // The walk costs about eight branches a field it passes, so the default
    // 1,000 ran out near 125 fields whatever the depth: a detail page of
    // shallow lists stopped compiling in this file, with advice no caller
    // could act on. Raised here because this is where the work is asked for
    // (ADR 126), and 20,000 is `renamedFieldsWithin`'s figure for the same
    // types: some 2,500 fields.
    @setEvalBranchQuota(20_000);
    return coversWithin(T, 0);
}

/// How far into nested types to follow before answering no.
///
/// **A type holding a list of its own type has no bottom to recurse to** — a
/// comment with replies, a category with children — and `covers` used to walk
/// one until the compiler gave up, with a message in nilo's own file whose
/// advice (raise the branch quota) buys more recursion rather than an answer.
/// Answering false at the ceiling sends the value to `std.json`, which writes
/// it correctly: its recursion is over a *value* at run time rather than over a
/// type while compiling, so the fallback this fell off is the one that works.
///
/// Eight, the same as `openapi.schemaWithin`'s and for the same reason
/// (ADR 034). The two walk the same types and disagreeing about how deep is
/// how a response and its description come apart.
const max_depth = 8;

fn coversWithin(comptime T: type, comptime depth: usize) bool {
    if (depth >= max_depth) return false;
    // Asked first, and before the depth of anything inside it matters: a leaf
    // is written by `std.json` whole, so what its fields look like is not this
    // walk's business (ADR 148).
    if (writesItsOwnScalar(T)) return true;
    // A document is its value ([ADR 163](../docs/adr/163-a-document-is-its-value.md)):
    // covered when the value is a shape this writer walks — and when it is
    // not, the value is a leaf handed to `std.json` whole with the object
    // around it still this writer's, on the promise every `jsonStringify`
    // makes anyway, that it writes one JSON value. `sql.Json(std.json.Value)`
    // is that case. What is still refused is a marker inside the value that
    // `std.json` would not read, which is the fallback's own rule (ADR 148)
    // applied one level down.
    if (comptime mark.documentOf(T)) |Inner| {
        if (coversWithin(Inner, depth + 1)) return true;
        return mark.renamedFieldsWithin(Inner) == null;
    }
    // Reading the marker is what checks it, and this is the line that makes the
    // check happen at all: a `.tag` on a struct describes nothing and would
    // otherwise sit there doing nothing in silence.
    if (mark.marked(T)) _ = mark.of(T);
    if (T == Str) return true;
    // **Any slice of bytes is text**, not a list of numbers — the reading
    // `std.json` and `openapi.schemaWithin` both already give it. Named by
    // exact type this used to miss `[:0]const u8`, which is what `@tagName`
    // returns and what a field crossing a C boundary is spelled as: it fell
    // through to the `.pointer` arm and went out as `[104,101,108,108,111]`
    // while the generated document said `type: string`.
    if (isByteSlice(T)) return true;
    return switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float => true,
        // An enum with a writer of its own is not just its tag name.
        .@"enum" => !hasDecl(T, "jsonStringify"),
        .optional => |o| coversWithin(o.child, depth + 1),

        // A tagged union, in both encodings.
        //
        // Externally tagged — `{"metrics":{…}}` — is what `std.json` writes and
        // what this used to hand to it. Covering it here changes no byte and is
        // worth 258ns → 90ns on a 374-byte payload, because `covers` is
        // answered for the *whole* value: one union field anywhere sent the
        // entire response to `std.json`, strings included.
        //
        // Internally tagged — `{"signal":"metrics",…}` — is what the type asks
        // for with `nilo_json`, and `std.json` has no way to write it at all
        // (ADR 016). An empty variant is only writable in that encoding: there
        // is a name to send and no object to put it in.
        .@"union" => |u| covered: {
            if (hasDecl(T, "jsonStringify")) break :covered false;
            // Nothing in an untagged union says which arm is live, so nothing
            // can write it. Same reading `openapi.zig` gives it (ADR 016).
            if (u.tag_type == null) break :covered false;
            // Reading the marker is also what checks it, so a `.tag` on the
            // wrong shape is refused the moment the type reaches a response.
            const tagged = if (mark.of(T)) |m| m.tag != null else false;
            for (u.field_types) |f_type| {
                if (f_type == void) {
                    if (!tagged) break :covered false;
                    continue;
                }
                if (!coversWithin(f_type, depth + 1)) break :covered false;
            }
            break :covered true;
        },
        // `std.json` writes a `[N]u8` as a *string*, not as a list of numbers:
        // `[3]u8{ 1, 2, 3 }` comes out as three escaped characters in quotes.
        // Rather than reproduce that rule and its edges, an array of bytes is
        // left to it.
        .array => |a| a.child != u8 and coversWithin(a.child, depth + 1),
        .pointer => |p| p.size == .slice and coversWithin(p.child, depth + 1),
        .@"struct" => |s| covered: {
            // A tuple is a JSON array to std.json, and reading that back off
            // the type is more care than the shape deserves; a type that
            // writes itself has the last word on how it looks.
            if (s.is_tuple) break :covered false;
            if (hasDecl(T, "jsonStringify")) break :covered false;
            for (s.field_types) |f_type| {
                if (!coversWithin(f_type, depth + 1)) break :covered false;
            }
            break :covered true;
        },
        else => false,
    };
}

fn writeValue(comptime T: type, w: *std.Io.Writer, value: T) std.Io.Writer.Error!void {
    // A leaf writes itself, and `std.json` is what calls it — so the bytes are
    // the ones this file's contract promises, and the object around it stays
    // this file's to write (ADR 148).
    if (comptime writesItsOwnScalar(T)) return stringify(w, value);
    // A document as its value — walked here when it can be, and otherwise the
    // same bytes its own `jsonStringify` would have written (ADR 163).
    if (comptime mark.documentOf(T)) |Inner| {
        if (comptime covers(Inner)) return writeValue(Inner, w, value.value);
        return stringify(w, value.value);
    }
    if (T == Str) return writeText(w, value.view());
    if (comptime isByteSlice(T)) return writeText(w, value);

    switch (@typeInfo(T)) {
        .bool => return w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => return w.printInt(value, 10, .lower, .{}),
        // Spelled the way serde_json spells it, not the way `std.json` does:
        // `1.0` and not `1`, `1e+16` and not seventeen digits, and `null` for
        // a value JSON has no spelling for, where `std.json` writes the bare
        // word `inf` and the string `"nan"` (ADR 096, `jsonfloat.zig`).
        .float, .comptime_float => return jsonfloat.write(w, value),
        // A tag name is a Zig identifier, so it can never need escaping and the
        // quotes around it belong in the same literal as the name. That is what
        // makes `rename_all` free: the spelling is settled while compiling, so
        // a renamed enum writes exactly as much as a plain one.
        .@"enum" => |e| {
            if (e.mode == .exhaustive) switch (value) {
                inline else => |tag| return w.writeAll(
                    comptime "\"" ++ mark.wire(@tagName(tag), mark.of(T)) ++ "\"",
                ),
            };
            // A non-exhaustive enum can hold a value no field names, and
            // `@tagName` on one is a panic: std.json reads `{"kind":7}` into
            // exactly that, and so can a database integer. A named value goes
            // out as its name and an unnamed one as its number, which is what
            // std.json writes and what reading it back expects.
            inline for (e.field_names, e.field_values) |f_name, f_value| {
                if (@backingInt(value) == f_value) return w.writeAll(comptime "\"" ++ f_name ++ "\"");
            }
            return w.printInt(@backingInt(value), 10, .lower, .{});
        },
        .optional => return if (value) |payload|
            writeValue(@TypeOf(payload), w, payload)
        else
            w.writeAll("null"),

        .array, .pointer => {
            try w.writeByte('[');
            for (value, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(@TypeOf(item), w, item);
            }
            return w.writeByte(']');
        },

        .@"union" => {
            const m = comptime mark.of(T);
            const key = comptime if (m) |said| said.tag else null;
            switch (value) {
                inline else => |payload, active| {
                    const arm = comptime mark.wire(@tagName(active), m);
                    const Payload = @TypeOf(payload);

                    if (comptime key) |k| {
                        // Internally tagged: the discriminator and the
                        // variant's own fields share one object, so the arm is
                        // written flat rather than nested. An empty variant is
                        // the whole object.
                        if (Payload == void) {
                            return w.writeAll(comptime "{\"" ++ k ++ "\":\"" ++ arm ++ "\"}");
                        }
                        try w.writeAll(comptime "{\"" ++ k ++ "\":\"" ++ arm ++ "\"");
                        // The payload's *own* marker names its fields, not the
                        // union's — a union's `rename_all` renames variants and
                        // stops there, which is the line `a tag and a case
                        // together rename the variant but not its fields` holds
                        // (ADR 016, ADR 148).
                        const inner = comptime mark.of(Payload);
                        const payload_info = @typeInfo(Payload).@"struct";
                        inline for (payload_info.field_names, payload_info.field_types) |f_name, f_type| {
                            if (comptime mark.skipped(inner, f_name)) continue;
                            try w.writeAll(comptime ",\"" ++ mark.wire(f_name, inner) ++ "\":");
                            try writeValue(f_type, w, @field(payload, f_name));
                        }
                        return w.writeByte('}');
                    }

                    // Externally tagged: one object, one key, the variant's
                    // name — byte for byte what `std.json` writes.
                    try w.writeAll(comptime "{\"" ++ arm ++ "\":");
                    try writeValue(Payload, w, payload);
                    return w.writeByte('}');
                },
            }
        },

        .@"struct" => |s| {
            if (s.field_names.len == 0) return w.writeAll("{}");
            // What the type said its keys are spelled as
            // ([ADR 148](../docs/adr/148-a-field-name-is-a-spelling-too.md)).
            // Null for the types that said nothing, which is nearly all of them
            // and costs the same as it always did: the name is settled while
            // compiling either way, so a renamed struct writes exactly as much
            // as a plain one.
            const m = comptime mark.of(T);
            // A skipped field is not written, and which field opens the
            // object is settled while compiling like the rest (ADR 148).
            comptime var opened = false;
            inline for (s.field_names, s.field_types) |f_name, f_type| {
                if (comptime mark.skipped(m, f_name)) continue;
                // The brace or comma, the quoted name and the colon are one
                // string settled while compiling.
                try w.writeAll(comptime (if (!opened) "{\"" else ",\"") ++
                    mark.wire(f_name, m) ++ "\":");
                opened = true;
                try writeValue(f_type, w, @field(value, f_name));
            }
            if (comptime !opened) return w.writeAll("{}");
            return w.writeByte('}');
        },

        else => comptime unreachable,
    }
}

/// A run of bytes as JSON: a string when it is text, and the array of numbers
/// `std.json` writes when it is not.
///
/// **JSON has no way to carry a byte that is not text.** A `[]const u8` holding
/// `\xff` was written inside quotes and the response was not valid JSON — the
/// one place left where this file's contract, that the output is byte-for-byte
/// what `std.json` would have written, was untrue
/// ([ADR 096](../docs/adr/096-a-byte-that-is-not-text-is-not-a-string.md)).
/// `std.json` asks `utf8ValidateSlice` first and falls back to `[104,101]`, so
/// that is what this asks and that is what this writes.
///
/// The cost is the validation, the same function `std.json` calls: a
/// 32-byte-at-a-time scan that only walks UTF-8 past the first byte over 0x7f,
/// so ASCII is one vector pass.
fn writeText(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) return writeByteArray(w, text);
    return writeString(w, text);
}

/// The bytes as a JSON array of numbers, which is what `std.json` writes for a
/// `[]const u8` it cannot call a string.
fn writeByteArray(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (bytes, 0..) |b, i| {
        if (i > 0) try w.writeByte(',');
        try w.printInt(b, 10, .lower, .{});
    }
    return w.writeByte(']');
}

/// A JSON string. Only three things need escaping — a quote, a backslash, and
/// anything below a space — so the run of bytes up to the next one of those is
/// found 32 at a time and written whole.
///
/// Public because the logger writes JSON lines of its own and a request path
/// is a stranger's text: a newline in one would forge a log line. One escaper
/// rather than two is what keeps that true in both places.
pub fn writeString(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    try writeEscaped(w, text);
    return w.writeByte('"');
}

/// A JSON string for text that has to be one whatever it holds: every byte
/// that is not part of a UTF-8 character is written as U+FFFD, the
/// replacement character, and the rest is escaped exactly as `writeString`
/// does.
///
/// For a sentence a client displays, a failure's message above all, where
/// `%ff` in a path is a stranger's bytes and a message cut at the byte limit
/// can end inside a character. ADR 096's byte array is for a value a handler
/// returns; a message that went out as `[255]` would be shown as numbers
/// (ADR 024). Valid text, which is nearly all of it, pays one validation pass
/// and takes `writeString`. Each bad byte becomes three bytes, fewer than the
/// six a control character takes as `\u00xx`, so a buffer sized for the worst
/// escape holds the worst replacement.
pub fn writeLossyString(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(text)) return writeString(w, text);
    try w.writeByte('"');
    var run: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const lead = text[i];
        if (lead < 0x80) {
            i += 1;
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(lead) catch 0;
        if (n != 0 and i + n <= text.len and std.unicode.utf8ValidateSlice(text[i..][0..n])) {
            i += n;
            continue;
        }
        try writeEscaped(w, text[run..i]);
        try w.writeAll("\u{FFFD}");
        i += 1;
        run = i;
    }
    try writeEscaped(w, text[run..]);
    return w.writeByte('"');
}

/// What goes between the quotes of `writeString`.
fn writeEscaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var at: usize = 0;
    while (nextEscape(text, at)) |i| {
        try w.writeAll(text[at..i]);
        at = i + 1;
        try w.writeAll(switch (text[i]) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            // The rest of the control characters have no short form.
            else => {
                try w.print("\\u{x:0>4}", .{text[i]});
                continue;
            },
        });
    }
    try w.writeAll(text[at..]);
}

const lanes = 32;
const Chunk = @Vector(lanes, u8);

/// The next byte at or after `from` that a JSON string cannot carry as it is.
fn nextEscape(text: []const u8, from: usize) ?usize {
    const quote: Chunk = @splat('"');
    const backslash: Chunk = @splat('\\');
    const space: Chunk = @splat(0x20);

    var i = from;
    while (i + lanes <= text.len) : (i += lanes) {
        const block: Chunk = text[i..][0..lanes].*;
        // Below a space covers every control character, including the ones
        // with a short escape.
        const hits = (block == quote) | (block == backslash) | (block < space);
        const bits: u32 = @bitCast(hits);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return null;
}

/// Whether `T` is a run of bytes and therefore text: `[]const u8`, `[]u8`, and
/// every sentinel-terminated or aligned spelling of the two.
///
/// Public because three layers have to give the same answer to it — this file
/// writes the bytes, `typed.contentTypeFor` labels them and
/// `openapi.schemaWithin` describes them — and the last of those reading
/// `p.child == u8` while the first read the exact type is how a response and
/// its own description came to disagree.
pub fn isByteSlice(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.size == .slice and p.child == u8,
        else => false,
    };
}

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

// ---- tests ----
//
// Every one of these asserts the same thing: that what this file writes is
// exactly what std.json would have written. That is the whole contract — the
// speed is only allowed to exist because the bytes are identical.

const testing = std.testing;

/// Assert the generated writer and std.json produce the same bytes, and that
/// this type is actually on the fast path (a test that silently fell back
/// would pass while proving nothing).
fn expectSame(value: anytype) !void {
    comptime std.debug.assert(covers(@TypeOf(value)));

    var mine: std.Io.Writer.Allocating = .init(testing.allocator);
    defer mine.deinit();
    try write(&mine.writer, value);

    var theirs: std.Io.Writer.Allocating = .init(testing.allocator);
    defer theirs.deinit();
    try std.json.Stringify.value(value, .{}, &theirs.writer);

    try testing.expectEqualStrings(theirs.written(), mine.written());
}

test "scalars come out the way std.json writes them" {
    try expectSame(@as(u32, 0));
    try expectSame(@as(u32, 7));
    try expectSame(@as(i32, -42));
    try expectSame(@as(u64, std.math.maxInt(u64)));
    try expectSame(@as(i64, std.math.minInt(i64)));
    try expectSame(@as(u8, 255));
    try expectSame(true);
    try expectSame(false);
}

test "a float is spelled the way serde_json spells it, and every other scalar the way std.json does" {
    const Floats = struct { a: f64, b: f64, c: f64, d: f64, e: f64, f: f64, g: f32, h: f32 };
    try expectJson(
        "{\"a\":12.5,\"b\":0.0,\"c\":-0.0,\"d\":1000000000000000.0,\"e\":1e+16,\"f\":1e-7,\"g\":1.1,\"h\":3.4028235e+38}",
        Floats{ .a = 12.5, .b = 0, .c = -0.0, .d = 1e15, .e = 1e16, .f = 1e-7, .g = 1.1, .h = std.math.floatMax(f32) },
    );
    try expectJson("1.0", @as(f64, 1));
    try expectJson("-0.125", @as(f64, -0.125));
    try expectJson("1.7976931348623157e+308", std.math.floatMax(f64));
    try expectJson("5e-324", std.math.floatTrueMin(f64));
    try expectJson("1234567890.0", @as(f64, 1234567890.0));
}

test "a float is the one place the generated writer and std.json disagree" {
    var mine: std.Io.Writer.Allocating = .init(testing.allocator);
    defer mine.deinit();
    var theirs: std.Io.Writer.Allocating = .init(testing.allocator);
    defer theirs.deinit();
    try write(&mine.writer, .{ .whole = @as(f64, 3), .big = @as(f64, 1e300), .f = @as(f32, 1.1) });
    try std.json.Stringify.value(.{ .whole = @as(f64, 3), .big = @as(f64, 1e300), .f = @as(f32, 1.1) }, .{}, &theirs.writer);
    try testing.expectEqualStrings("{\"whole\":3.0,\"big\":1e+300,\"f\":1.1}", mine.written());
    try testing.expect(std.mem.startsWith(u8, theirs.written(), "{\"whole\":3,\"big\":1000000"));
    try testing.expect(theirs.written().len > 300);
}

test "a float is spelled the same on every shape, covered or fallen back to std.json" {
    const Custom = struct {
        v: f64,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.v);
        }
    };
    const Opt = struct { x: ?f64, y: ?f64, list: []const f64, nested: struct { z: f32 } };
    // Covered: the generated writer.
    try expectJson(
        "{\"x\":2.0,\"y\":null,\"list\":[0.0,1e+16,0.1],\"nested\":{\"z\":0.5}}",
        Opt{ .x = 2, .y = null, .list = &.{ 0, 1e16, 0.1 }, .nested = .{ .z = 0.5 } },
    );
    // A tuple, a type that writes itself, a `std.json.Value`, a map and a
    // comptime literal all miss `covers` and are written by `FiniteJson`.
    comptime std.debug.assert(!covers(Custom));
    comptime std.debug.assert(!covers(std.json.Value));
    comptime std.debug.assert(!covers(std.json.ArrayHashMap(f64)));
    try expectText("[1.0,2.5,1e-7]", .{ @as(f64, 1), @as(f32, 2.5), @as(f64, 1e-7) });
    try expectText("{\"c\":4.0,\"t\":[3.0,\"s\"]}", .{ .c = Custom{ .v = 4 }, .t = .{ @as(f64, 3), "s" } });
    var items = [_]std.json.Value{ .{ .float = 2 }, .{ .float = 1e16 }, .{ .integer = 3 }, .{ .float = 1.5 } };
    try expectText("[2.0,1e+16,3,1.5]", std.json.Value{ .array = .{ .items = &items, .capacity = items.len, .allocator = testing.allocator, .pointer_stability = .{} } });
    var map: std.json.ArrayHashMap(f64) = .{};
    defer map.deinit(testing.allocator);
    try map.map.put(testing.allocator, "a", 1);
    try expectText("{\"a\":1.0}", map);
    try expectText("{\"k\":2.5}", .{ .k = 2.5 });
}

test "a float written by alloc is the same bytes and reads back as the same value" {
    const owned = try alloc(testing.allocator, .{ .a = @as(f64, 0.1) + @as(f64, 0.2), .b = @as(f64, 1e21), .c = @as(f64, 3) });
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("{\"a\":0.30000000000000004,\"b\":1e+21,\"c\":3.0}", owned);
    const back = try std.json.parseFromSlice(struct { a: f64, b: f64, c: f64 }, testing.allocator, owned, .{});
    defer back.deinit();
    try testing.expectEqual(@as(f64, 0.1) + @as(f64, 0.2), back.value.a);
    try testing.expectEqual(@as(f64, 1e21), back.value.b);
    try testing.expectEqual(@as(f64, 3), back.value.c);
}

test "a body of 1 still fills an f64, and 1.0 and 1e2 do too" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const B = struct { x: f64 };
    try testing.expectEqual(@as(f64, 1), (try parseLeaky(B, arena.allocator(), "{\"x\":1}", .{})).x);
    try testing.expectEqual(@as(f64, 1), (try parseLeaky(B, arena.allocator(), "{\"x\":1.0}", .{})).x);
    try testing.expectEqual(@as(f64, 100), (try parseLeaky(B, arena.allocator(), "{\"x\":1e2}", .{})).x);
}

test "a float that is not finite is written as null, never as inf or nan" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const inf = std.math.inf(f64);
    try write(&out.writer, .{ .a = inf, .b = -inf, .c = std.math.nan(f64), .d = std.math.inf(f32), .e = @as(?f64, inf), .f = 1.5 });
    try testing.expectEqualStrings("{\"a\":null,\"b\":null,\"c\":null,\"d\":null,\"e\":null,\"f\":1.5}", out.written());
}

const Reading = struct {
    id: u32,
    delta: i16 = 0,
    ratio: ?f64 = null,
    tags: []const u32 = &.{},
    pair: [2]u8 = .{ 0, 0 },
    name: []const u8 = "",
    inner: struct { n: u8 = 0 } = .{},
    edit: patch_mod.Patch(u8) = .absent,
};

test "a body is read the way std.json reads it, wherever its numbers are not in dispute" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text =
        \\{"id":7,"delta":-3,"ratio":2.5e1,"tags":[1,2,3],"pair":[4,5],"name":"wati","inner":{"n":9},"edit":12}
    ;
    const mine = try parseLeaky(Reading, arena.allocator(), text, .{});
    const theirs = try std.json.parseFromSliceLeaky(Reading, arena.allocator(), text, .{});
    try testing.expectEqual(theirs.id, mine.id);
    try testing.expectEqual(theirs.delta, mine.delta);
    try testing.expectEqual(theirs.ratio, mine.ratio);
    try testing.expectEqualSlices(u32, theirs.tags, mine.tags);
    try testing.expectEqual(theirs.pair, mine.pair);
    try testing.expectEqualStrings(theirs.name, mine.name);
    try testing.expectEqual(theirs.inner.n, mine.inner.n);
    try testing.expectEqual(@as(u8, 12), mine.edit.value);

    // Defaults, a null optional, and a cleared patch.
    const sparse = try parseLeaky(Reading, arena.allocator(), "{\"id\":1,\"ratio\":null,\"edit\":null}", .{});
    try testing.expectEqual(@as(?f64, null), sparse.ratio);
    try testing.expect(sparse.edit == .cleared);
}

test "a body refuses what std.json refuses, and what its numbers are spelled wrong for" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.MissingField, parseLeaky(Reading, a, "{}", .{}));
    try testing.expectError(error.UnknownField, parseLeaky(Reading, a, "{\"id\":1,\"x\":2}", .{}));
    try testing.expectError(error.DuplicateField, parseLeaky(Reading, a, "{\"id\":1,\"id\":2}", .{}));
    try testing.expectError(error.UnexpectedToken, parseLeaky(Reading, a, "{\"id\":true}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Reading, a, "{\"id\":\"1_0\"}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Reading, a, "{\"id\":\"+7\"}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Reading, a, "{\"id\":1.0}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Reading, a, "{\"id\":1,\"ratio\":\"nan\"}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Reading, a, "{\"id\":1,\"tags\":[1,\"0x1\"]}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Reading, a, "{\"id\":1,\"edit\":\"+1\"}", .{}));
    try testing.expectError(error.Overflow, parseLeaky(Reading, a, "{\"id\":1,\"ratio\":1e999}", .{}));
    try testing.expectError(error.Overflow, parseLeaky(Reading, a, "{\"id\":4294967296}", .{}));
    // A quoted number that is spelled like a number is still one.
    try testing.expectEqual(@as(u32, 10), (try parseLeaky(Reading, a, "{\"id\":\"10\"}", .{})).id);
}

test "a number in a map or a tuple is read, and one in a dynamic value is never guessed, by the rule every other field is by the rule every other field is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Counts = struct { by_name: std.json.ArrayHashMap(u8), pair: struct { u8, f64 } = .{ 0, 0 }, any: ?std.json.Value = null };

    const ok = try parseLeaky(Counts, a, "{\"by_name\":{\"a\":1,\"b\":\"10\"},\"pair\":[2,0.5],\"any\":{\"n\":[1,2.5,\"1_0\"]}}", .{});
    try testing.expectEqual(@as(u8, 10), ok.by_name.map.get("b").?);
    try testing.expectEqual(@as(u8, 2), ok.pair[0]);
    // A string in a dynamic value is a string, and is not read as a number.
    try testing.expectEqualStrings("1_0", ok.any.?.object.get("n").?.array.items[2].string);

    try testing.expectError(error.InvalidNumber, parseLeaky(Counts, a, "{\"by_name\":{\"a\":\"1_0\"}}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Counts, a, "{\"by_name\":{\"a\":\"+7\"}}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Counts, a, "{\"by_name\":{},\"pair\":[\"1_0\",1]}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Counts, a, "{\"by_name\":{},\"pair\":[1,\"nan\"]}", .{}));
    try testing.expectError(error.Overflow, parseLeaky(Counts, a, "{\"by_name\":{\"a\":300}}", .{}));
    // A number too large for a float stays the text it was written in.
    const huge = try parseLeaky(Counts, a, "{\"by_name\":{},\"any\":[1e999]}", .{});
    try testing.expectEqualStrings("1e999", huge.any.?.array.items[0].number_string);
    try testing.expectError(error.DuplicateField, parseLeaky(Counts, a, "{\"by_name\":{\"a\":1,\"a\":2}}", .{}));
    try testing.expectError(error.UnexpectedToken, parseLeaky(Counts, a, "{\"by_name\":[1]}", .{}));
    try testing.expectError(error.UnexpectedToken, parseLeaky(Counts, a, "{\"by_name\":{},\"pair\":[1]}", .{}));
}

test "a number in an externally tagged union is read by the rule every other field is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Shape = union(enum) { a: u32, b: struct { n: u8 }, none: void };
    const Own = union(enum) {
        a: u32,
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
            _ = allocator;
            _ = options;
            _ = try source.next();
            _ = try source.next();
            _ = try source.next();
            _ = try source.next();
            return .{ .a = 99 };
        }
    };
    const Holder = struct { s: Shape, o: ?Own = null };

    try testing.expectEqual(@as(u32, 7), (try parseLeaky(Holder, a, "{\"s\":{\"a\":7}}", .{})).s.a);
    try testing.expectEqual(@as(u32, 10), (try parseLeaky(Holder, a, "{\"s\":{\"a\":\"10\"}}", .{})).s.a);
    try testing.expectEqual(@as(u8, 3), (try parseLeaky(Holder, a, "{\"s\":{\"b\":{\"n\":3}}}", .{})).s.b.n);
    try testing.expect((try parseLeaky(Holder, a, "{\"s\":{\"none\":{}}}", .{})).s == .none);

    try testing.expectError(error.InvalidNumber, parseLeaky(Holder, a, "{\"s\":{\"a\":\"1_0\"}}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Holder, a, "{\"s\":{\"a\":\"+7\"}}", .{}));
    try testing.expectError(error.InvalidNumber, parseLeaky(Holder, a, "{\"s\":{\"b\":{\"n\":\"0x1\"}}}", .{}));
    try testing.expectError(error.Overflow, parseLeaky(Holder, a, "{\"s\":{\"b\":{\"n\":300}}}", .{}));
    try testing.expectError(error.UnknownField, parseLeaky(Holder, a, "{\"s\":{\"c\":1}}", .{}));
    try testing.expectError(error.UnexpectedToken, parseLeaky(Holder, a, "{\"s\":{\"a\":1,\"none\":{}}}", .{}));
    try testing.expectError(error.UnexpectedToken, parseLeaky(Holder, a, "{\"s\":{}}", .{}));
    try testing.expectError(error.UnexpectedToken, parseLeaky(Holder, a, "{\"s\":[1]}", .{}));
    try testing.expectError(error.UnexpectedToken, parseLeaky(Holder, a, "{\"s\":{\"none\":1}}", .{}));

    // A union that reads itself is left to its own reader.
    try testing.expectEqual(@as(u32, 99), (try parseLeaky(Holder, a, "{\"s\":{\"a\":1},\"o\":{\"a\":\"1_0\"}}", .{})).o.?.a);
}

test "a repeated key is found at any depth, and a body without one has none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("k", firstRepeatedKey(a, "{\"k\":1,\"k\":2}").?);
    try testing.expectEqualStrings("kind", firstRepeatedKey(a, "{\"s\":{\"kind\":\"a\",\"r\":[{\"x\":1}],\"kind\":\"b\"}}").?);
    try testing.expect(firstRepeatedKey(a, "{\"k\":{\"k\":1},\"j\":[{\"k\":1},{\"k\":2}],\"v\":\"k\"}") == null);
}

test "a string with nothing to escape, and one with everything" {
    try expectSame(@as([]const u8, ""));
    try expectSame(@as([]const u8, "wati"));
    try expectSame(@as([]const u8, "quote\" backslash\\ slash/"));
    try expectSame(@as([]const u8, "newline\n return\r tab\t"));
    try expectSame(@as([]const u8, "backspace\x08 formfeed\x0c"));
    try expectSame(@as([]const u8, "control\x00\x01\x0b\x0e\x1f end"));
    try expectSame(@as([]const u8, "café ☕ emoji 🎉"));
}

test "a run of bytes that is not text is a list of numbers, not a string" {
    // JSON has no way to carry a byte that is not text, and `std.json` answers
    // that by writing the array instead. Written inside quotes, as this used
    // to, the response is simply not valid JSON (ADR 096).
    try expectSame(@as([]const u8, "\xff"));
    try expectSame(@as([]const u8, "caf\xe9")); // latin-1, not UTF-8
    try expectSame(@as([]const u8, "\xc3")); // a lead byte with nothing after it
    try expectSame(@as([]const u8, "ok\x80bad"));
    try expectSame(@as([]const u8, "\xed\xa0\x80")); // a surrogate half
    // A quote inside bytes that are not text: the array wins, so nothing is
    // escaped at all.
    try expectSame(@as([]const u8, "\xff\"\n"));
    // And the whole of it stays true one type over.
    var lifetime = @import("nilo_core").Lifetime{};
    try expectSame(Str.fromRequest("\xff", &lifetime));
    try expectSame(struct { name: []const u8, id: u32 }{ .name = "\xfe\xff", .id = 7 });
}

test "an escape lands on every offset of a block boundary" {
    // The scan works 32 bytes at a time, so a quote just before, on, and just
    // after a boundary are three different paths through it.
    var buf: [80]u8 = undefined;
    for (0..72) |at| {
        @memset(&buf, 'x');
        buf[at] = '"';
        try expectSame(@as([]const u8, buf[0..72]));
    }
    // And one long run with no escape at all, which is the common case.
    @memset(&buf, 'x');
    try expectSame(@as([]const u8, &buf));
}

test "a Str goes out as a plain JSON string" {
    var lifetime = @import("nilo_core").Lifetime{};
    try expectSame(Str.fromRequest("wati sari", &lifetime));
    try expectSame(Str.fromRequest("with a \" in it", &lifetime));
    try expectSame(struct { name: Str, id: u32 }{
        .name = Str.fromRequest("wati", &lifetime),
        .id = 7,
    });
}

test "structs, nesting, optionals and enums" {
    try expectSame(struct {}{});
    try expectSame(struct { id: u32, name: []const u8 }{ .id = 7, .name = "wati" });
    try expectSame(struct { a: ?u32, b: ?u32 }{ .a = null, .b = 3 });
    try expectSame(struct { kind: enum { free, paid } }{ .kind = .paid });
    try expectSame(struct {
        outer: u32,
        inner: struct { deep: struct { x: bool } },
    }{ .outer = 1, .inner = .{ .deep = .{ .x = true } } });
    try expectSame(struct { maybe: ?struct { x: u8 } }{ .maybe = .{ .x = 2 } });
}

test "a non-exhaustive enum holding a value no field names is written as its number" {
    // std.json reads `{"kind":7}` into exactly this, and so can a database
    // integer; echoing it back must not reach `@tagName` on an unnamed value.
    const Kind = enum(u8) { free, paid, _ };
    try expectSame(struct { kind: Kind }{ .kind = .paid });
    try expectSame(struct { kind: Kind }{ .kind = @fromBackingInt(@intCast(7)) });
}

test "a sentinel-terminated string is a string, not a list of its bytes" {
    // `[:0]const u8` is what `@tagName` returns, what `allocPrintSentinel`
    // returns, and what a field crossing a C boundary is spelled as. Named by
    // exact type, `covers` missed all three: the value went out as
    // `[104,101,108,108,111]` while `openapi.schemaWithin` — reading the same
    // type as `p.child == u8` — described it as a string.
    try expectSame(@as([:0]const u8, "hello"));
    try expectSame(@as([:0]const u8, ""));
    try expectSame(@as([:0]const u8, "with a \" in it"));
    try expectSame(struct { name: [:0]const u8, id: u32 }{ .name = "wati", .id = 7 });
    try expectSame(@as([]const [:0]const u8, &.{ "a", "b" }));

    // A mutable one, and the plain pair that always worked.
    var buf = [_:0]u8{ 'h', 'i' };
    try expectSame(@as([:0]u8, &buf));
    try expectSame(@as([]const u8, "hello"));
    try expectSame(@as([]u8, buf[0..2]));
}

test "a type that holds a list of itself is std.json's to write" {
    // `covers` recursed through `.pointer` with no floor, so an ordinary JSON
    // tree — a comment with replies, a category with children — did not come
    // out wrong: it failed to compile, with a message in this file whose
    // advice was to raise the branch quota, which buys more recursion rather
    // than an answer. Eight deep and then no, the same ceiling
    // `openapi.schemaWithin` has (ADR 034).
    const Comment = struct {
        body: []const u8,
        replies: []const @This(),
    };
    comptime std.debug.assert(!covers(Comment));

    // And the fallback is not a degraded answer — it is the correct one,
    // because `std.json` recurses over a value at run time rather than over a
    // type while compiling.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, Comment{
        .body = "top",
        .replies = &.{.{ .body = "under", .replies = &.{} }},
    });
    try testing.expectEqualStrings(
        \\{"body":"top","replies":[{"body":"under","replies":[]}]}
    , out.written());

    // A shape that is merely deep rather than endless is still on the fast
    // path, so the ceiling has not quietly swallowed ordinary types.
    try expectSame(struct { a: struct { b: struct { c: struct { d: u32 } } } }{
        .a = .{ .b = .{ .c = .{ .d = 1 } } },
    });
}

test "a response as wide as a detail page is still on the fast path" {
    // Shallow and wide: a record holding a list of bills, each bill holding
    // eight lists of its own records. Nowhere near eight deep, and it failed to
    // compile anyway, in this file, with advice to raise a quota no caller can
    // reach: the default budget is spent by fields walked, not by depth.
    const Line = struct {
        fn of(comptime n: u8) type {
            return struct {
                const which = n;
                id: u64,
                bill_id: u64,
                amount: i64,
                paid: bool,
                note: []const u8,
                actor: []const u8,
                reference: ?[]const u8,
                at: i64,
                year: u16,
                month: u8,
                status: enum { open, closed },
                reason: ?[]const u8,
                reduced: ?i64,
                reviewed: bool,
            };
        }
    };
    const Bill = struct {
        bill: Line.of(0),
        payments: []const Line.of(1),
        notices: []const Line.of(2),
        acknowledgments: []const Line.of(3),
        objection: ?Line.of(4),
        receipts: []const Line.of(5),
        delivery: ?Line.of(6),
        amendments: []const Line.of(7),
        penalties: []const Line.of(8),
        total: i64,
        outstanding: i64,
    };
    const Detail = struct {
        id: u64,
        name: []const u8,
        owner: Line.of(9),
        bills: []const Bill,
        history: []const Line.of(10),
    };
    comptime std.debug.assert(covers(Detail));
    try expectSame(Detail{
        .id = 1,
        .name = "Jl. Sultan Thaha",
        .owner = .{ .id = 2, .bill_id = 0, .amount = 0, .paid = false, .note = "", .actor = "uji", .reference = null, .at = 0, .year = 2026, .month = 0, .status = .open, .reason = null, .reduced = null, .reviewed = true },
        .bills = &.{},
        .history = &.{},
    });
}

test "lists" {
    try expectSame(@as([]const u32, &.{}));
    try expectSame(@as([]const u32, &.{ 1, 2, 3 }));
    try expectSame(@as([]const []const u8, &.{ "a", "b\"c" }));
    try expectSame([3]u32{ 1, 2, 3 });
    // An array of bytes is a string to std.json, not a list, so it is left to
    // it rather than guessed at.
    comptime std.debug.assert(!covers([3]u8));
    const User = struct { id: u32, name: []const u8 };
    try expectSame(@as([]const User, &.{
        .{ .id = 1, .name = "wati" },
        .{ .id = 2, .name = "sari" },
    }));
}

test "the primary metric's own payload" {
    const bio = repeat("A systems nerd who writes Zig before breakfast. ", 19);
    try expectSame(struct {
        id: u32,
        name: []const u8,
        email: []const u8,
        bio: []const u8,
    }{ .id = 7, .name = "Routed Tester", .email = "tester@example.dev", .bio = bio });
}

test "a type that writes itself is left alone, and so is a tuple" {
    // Both have to fall back, or this file would be deciding how they look.
    const Custom = struct {
        n: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n);
        }
    };
    comptime std.debug.assert(!covers(Custom));
    comptime std.debug.assert(!covers(struct { u32, u32 }));
    // Nothing in an untagged union says which arm is live, so nothing can
    // write it — the same reading `openapi.zig` gives it (ADR 016).
    comptime std.debug.assert(!covers(union { a: u32, b: bool }));
    // A struct holding one of those falls back with it.
    comptime std.debug.assert(!covers(struct { inner: Custom }));

    // And the fallback still produces std.json's own output.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, Custom{ .n = 5 });
    try testing.expectEqualStrings("5", out.written());
}

/// What `write` produced, for a type whose whole point is *not* being what
/// `std.json` would have written. `expectSame` is the right check for every
/// other shape here and the wrong one for these.
fn expectJson(expected: []const u8, value: anytype) !void {
    comptime std.debug.assert(covers(@TypeOf(value)));
    return expectText(expected, value);
}

/// What `expectJson` checks, for a value that may be one `covers` does not touch.
fn expectText(expected: []const u8, value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, value);
    try testing.expectEqualStrings(expected, out.written());
}

test "a union that says nothing is written the way std.json writes it" {
    const Link = union(enum) { url: []const u8, id: u32 };
    try expectSame(Link{ .url = "https://example.dev" });
    try expectSame(Link{ .id = 9 });

    // And so is one nested in a struct, which is the shape that used to send
    // the whole response to std.json.
    const Held = struct { name: []const u8, link: Link };
    try expectSame(Held{ .name = "wati", .link = .{ .id = 9 } });
}

test "a union that says its tag writes the tag beside the variant's own fields" {
    const Condition = union(enum) {
        pub const nilo_json = .{ .tag = "signal" };

        metrics: struct { metric_name: []const u8, threshold: f64 },
        logs: struct { query: []const u8, count_over: u32 },
    };

    try expectJson(
        \\{"signal":"metrics","metric_name":"system.cpu.utilization","threshold":0.9}
    , Condition{ .metrics = .{ .metric_name = "system.cpu.utilization", .threshold = 0.9 } });

    try expectJson(
        \\{"signal":"logs","query":"level:error","count_over":5}
    , Condition{ .logs = .{ .query = "level:error", .count_over = 5 } });
}

test "a variant carrying nothing is the tag on its own" {
    const Step = union(enum) {
        pub const nilo_json = .{ .tag = "step" };

        queued,
        running: struct { pid: u32 },
    };

    // Written out rather than as `Step.queued`, which is the *tag* enum's
    // field and would be a different type entirely.
    try expectJson(
        \\{"step":"queued"}
    , Step{ .queued = {} });
    try expectJson(
        \\{"step":"running","pid":41}
    , Step{ .running = .{ .pid = 41 } });
}

test "a tag and a case together rename the variant but not its fields" {
    const Channel = union(enum) {
        pub const nilo_json = .{ .tag = "kind", .rename_all = .@"kebab-case" };

        web_hook: struct { target_url: []const u8 },
        discord_dm: struct { user_id: u32 },
    };

    // The variant is renamed because it is a value on the wire. `target_url`
    // is a field name and is left alone, which is the line this cut draws.
    try expectJson(
        \\{"kind":"web-hook","target_url":"https://example.dev/hook"}
    , Channel{ .web_hook = .{ .target_url = "https://example.dev/hook" } });
    try expectJson(
        \\{"kind":"discord-dm","user_id":7}
    , Channel{ .discord_dm = .{ .user_id = 7 } });
}

test "an enum that says its case comes out in it, and one that does not is its tag name" {
    const Agg = enum {
        pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };

        avg,
        rate_per_second,
    };
    try expectJson("\"AVG\"", Agg.avg);
    try expectJson("\"RATE_PER_SECOND\"", Agg.rate_per_second);

    const Plain = enum { avg, rate_per_second };
    try expectSame(Plain.rate_per_second);
}

test "a renamed enum inside a struct is renamed there too" {
    const Severity = enum {
        pub const nilo_json = .{ .rename_all = .UPPERCASE };

        info,
        critical,
    };
    const Alert = struct { id: u32, severity: Severity };

    try expectJson(
        \\{"id":3,"severity":"CRITICAL"}
    , Alert{ .id = 3, .severity = .critical });
}

test "a struct that says its case sends its field names in it" {
    // What this replaces, counted in one caller's port: 10 response structs, 77
    // fields, 5 mapping functions written out field by field and 5 arena loops,
    // and the whole job of all of it was `full_name` becoming `fullName`
    // (ADR 148).
    const Contact = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };

        id: u32,
        full_name: []const u8,
        partner_id: u32,
        email_address: ?[]const u8,
    };

    try expectJson(
        \\{"id":7,"fullName":"Wati","partnerId":3,"emailAddress":null}
    , Contact{ .id = 7, .full_name = "Wati", .partner_id = 3, .email_address = null });

    // A field with no underscore in it is untouched, which is most of them.
    const Plain = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        id: u32,
        name: []const u8,
    };
    try expectJson(
        \\{"id":1,"name":"Sari"}
    , Plain{ .id = 1, .name = "Sari" });

    // And a struct that says nothing is still byte-for-byte std.json's, which
    // is the contract this whole file rests on.
    try expectSame(struct { full_name: []const u8 }{ .full_name = "Wati" });
}

test "a renamed struct nested inside another is renamed where it sits" {
    const Partner = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        partner_id: u32,
        display_name: []const u8,
    };
    // The outer struct says nothing, so its own fields are written as they are
    // — the marker is per type rather than inherited, which is the same rule a
    // union's `rename_all` already follows about its payload's fields.
    const Page = struct {
        total_count: u32,
        items: []const Partner,
    };

    try expectJson(
        \\{"total_count":2,"items":[{"partnerId":1,"displayName":"Wati"},{"partnerId":2,"displayName":"Sari"}]}
    , Page{ .total_count = 2, .items = &.{
        .{ .partner_id = 1, .display_name = "Wati" },
        .{ .partner_id = 2, .display_name = "Sari" },
    } });
}

test "a renamed struct as wide as a table is written, with every key respelled" {
    // Thirteen fields: the width at which the collision check used to run out
    // of comptime branches before the writer ran (item 62 of the port that
    // reported it; `jsonmark.checkRenames` sizes its own now).
    const Wide = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        project_id: u32,
        customer_name: []const u8,
        customer_code: []const u8,
        started_on_date: []const u8,
        finished_on_date: ?[]const u8,
        contract_value: u64,
        contract_currency: []const u8,
        owner_staff_id: u32,
        owner_full_name: []const u8,
        department_name: []const u8,
        status_label: []const u8,
        created_at_time: []const u8,
        updated_at_time: []const u8,
    };
    try expectJson(
        \\{"projectId":7,"customerName":"PT Maju","customerCode":"MJ","startedOnDate":"2026-01-02","finishedOnDate":null,"contractValue":1250000,"contractCurrency":"IDR","ownerStaffId":3,"ownerFullName":"Wati Sari","departmentName":"Engineering","statusLabel":"active","createdAtTime":"2026-01-02T00:00:00Z","updatedAtTime":"2026-01-03T00:00:00Z"}
    , Wide{
        .project_id = 7,
        .customer_name = "PT Maju",
        .customer_code = "MJ",
        .started_on_date = "2026-01-02",
        .finished_on_date = null,
        .contract_value = 1_250_000,
        .contract_currency = "IDR",
        .owner_staff_id = 3,
        .owner_full_name = "Wati Sari",
        .department_name = "Engineering",
        .status_label = "active",
        .created_at_time = "2026-01-02T00:00:00Z",
        .updated_at_time = "2026-01-03T00:00:00Z",
    });
}

test "every case a struct can ask for, on one field" {
    const Lower = struct {
        pub const nilo_json = .{ .rename_all = .lowercase };
        not_found: u32,
    };
    const Upper = struct {
        pub const nilo_json = .{ .rename_all = .UPPERCASE };
        not_found: u32,
    };
    const Pascal = struct {
        pub const nilo_json = .{ .rename_all = .PascalCase };
        not_found: u32,
    };
    const Screaming = struct {
        pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };
        not_found: u32,
    };
    const Kebab = struct {
        pub const nilo_json = .{ .rename_all = .@"kebab-case" };
        not_found: u32,
    };

    try expectJson("{\"notfound\":1}", Lower{ .not_found = 1 });
    try expectJson("{\"NOTFOUND\":1}", Upper{ .not_found = 1 });
    try expectJson("{\"NotFound\":1}", Pascal{ .not_found = 1 });
    try expectJson("{\"NOT_FOUND\":1}", Screaming{ .not_found = 1 });
    try expectJson("{\"not-found\":1}", Kebab{ .not_found = 1 });
}

test "the payload of a tagged variant is renamed by its own marker, not by the union's" {
    // The line ADR 016 drew and ADR 148 kept: a union's `rename_all` renames
    // variants, and a payload's own marker is what renames the payload's
    // fields. Two markers, each about its own type.
    const Inner = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        target_url: []const u8,
    };
    const Channel = union(enum) {
        pub const nilo_json = .{ .tag = "kind", .rename_all = .@"kebab-case" };

        web_hook: Inner,
        discord_dm: struct { user_id: u32 },
    };

    try expectJson(
        \\{"kind":"web-hook","targetUrl":"https://example.dev/hook"}
    , Channel{ .web_hook = .{ .target_url = "https://example.dev/hook" } });

    // The variant whose payload says nothing keeps its own spelling, which is
    // what the pre-existing test at the top of this pair asserts.
    try expectJson(
        \\{"kind":"discord-dm","user_id":7}
    , Channel{ .discord_dm = .{ .user_id = 7 } });
}

test "a union with a variant the writer cannot touch falls back whole" {
    const Custom = struct {
        n: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n);
        }
    };
    // One arm out of reach takes the union with it, exactly as one field does
    // for a struct — `covers` errs narrow on purpose.
    comptime std.debug.assert(!covers(union(enum) { a: u32, b: Custom }));

    // A union that writes itself is left alone whatever its arms are.
    const Writes = union(enum) {
        a: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.a);
        }
    };
    comptime std.debug.assert(!covers(Writes));
}

/// A stand-in for the four types item 46 was actually about — `sql.Uuid`,
/// `sql.Timestamp`, `sql.AsText` and `id.Uuid`. Spelled out here rather than
/// imported because `http/` may not name `sql/`, and the contract between them
/// is two declarations by name and nothing else (ADR 042, ADR 016).
const Key = struct {
    bytes: [4]u8,

    pub const nilo_openapi = .{ .type = "string", .format = "uuid" };

    pub fn jsonStringify(self: Key, jw: anytype) !void {
        var text: [8]u8 = undefined;
        for (self.bytes, 0..) |b, i| {
            _ = std.fmt.bufPrint(text[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
        }
        try jw.write(&text);
    }
};

test "a type that writes its own JSON and says what it looks like is a leaf, not a wall" {
    // The whole of ADR 148: this used to answer false, and one such field
    // anywhere sent the entire response to `std.json`.
    comptime std.debug.assert(covers(Key));
    comptime std.debug.assert(covers(struct { id: Key, name: []const u8 }));
    comptime std.debug.assert(covers(struct { id: ?Key, ids: []const Key }));

    // And every one of them is still byte-for-byte what `std.json` writes,
    // which is the contract at the top of this file.
    try expectSame(Key{ .bytes = .{ 0xde, 0xad, 0xbe, 0xef } });
    try expectSame(struct { id: Key, name: []const u8 }{
        .id = .{ .bytes = .{ 1, 2, 3, 4 } },
        .name = "wati",
    });
    try expectSame(struct { id: ?Key, name: []const u8 }{ .id = null, .name = "wati" });
}

/// A stand-in for `sql.Json(T)`, which `http/` may not import: a document,
/// exactly a `T` under `.value`, whose own writer says so in one line.
fn Doc(comptime T: type) type {
    return struct {
        value: T,
        pub const nilo_json_of = T;
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.value);
        }
    };
}

test "a document is written as its value, inside a struct that renames its fields" {
    // Item 63: a Row with a `jsonb` column could not rename its fields, because
    // `Json(T)` writes itself and does not say it is a scalar — it is not one.
    // It says something stronger, which type it is exactly (ADR 163).
    const Theme = struct { theme: []const u8, contrast: u8 };
    const Row = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        row_id: u32,
        settings: Doc(Theme),
        spare: ?Doc(Theme),
    };
    comptime std.debug.assert(covers(Row));
    try expectJson(
        \\{"rowId":7,"settings":{"theme":"dark","contrast":3},"spare":null}
    , Row{ .row_id = 7, .settings = .{ .value = .{ .theme = "dark", .contrast = 3 } }, .spare = null });

    // And a plain document is byte-for-byte what its own writer sends.
    try expectSame(Doc(Theme){ .value = .{ .theme = "light", .contrast = 1 } });
    try expectSame(struct { a: Doc(u32), b: []const Doc(bool) }{
        .a = .{ .value = 9 },
        .b = &.{ .{ .value = true }, .{ .value = false } },
    });
}

test "a document of a shape this writer cannot walk is a leaf, and its neighbours are still renamed" {
    // `sql.Json(std.json.Value)` — the port's event payload. `std.json.Value`
    // writes itself and is not a scalar, so it is `std.json`'s to write; the
    // object around it is this writer's, which is what lets the Row rename.
    const Row = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        event_id: u32,
        payload: Doc(std.json.Value),
    };
    comptime std.debug.assert(covers(Row));
    comptime std.debug.assert(!covers(std.json.Value));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"who":"wati","n":[1,2,3],"nested":{"ok":true}}
    , .{});
    try expectJson(
        \\{"eventId":4,"payload":{"who":"wati","n":[1,2,3],"nested":{"ok":true}}}
    , Row{ .event_id = 4, .payload = .{ .value = parsed } });
}

test "a document whose value renames its own fields is walked, and one std.json would misspell is refused" {
    // Inside a document the value's own marker is honoured, because the
    // generated writer is what walks it.
    const Inner = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };
        full_name: []const u8,
    };
    try expectJson(
        \\{"card":{"fullName":"Wati"}}
    , struct { card: Doc(Inner) }{ .card = .{ .value = .{ .full_name = "Wati" } } });

    // A value the writer cannot walk, holding a renamed struct: the leaf path
    // would hand it to `std.json`, which writes `full_name` — so `covers` says
    // no and the ordinary fallback refusal (ADR 148) is what the caller sees.
    const Wall = struct {
        inner: Inner,
        raw: [3]u8,
    };
    comptime std.debug.assert(!covers(Doc(Wall)));
    comptime std.debug.assert(!covers(struct { d: Doc(Wall) }));
}

test "a leaf that says nothing about its JSON still takes the value with it" {
    // The line is `nilo_openapi`, not `jsonStringify`. A type that writes
    // itself and never says what it wrote is the shape this file cannot
    // describe, so it stays `std.json`'s whole value exactly as it was.
    const Quiet = struct {
        n: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n);
        }
    };
    comptime std.debug.assert(!covers(Quiet));
    comptime std.debug.assert(!covers(struct { inner: Quiet }));

    // Nor does a marker naming a shape that is not a scalar — there is no such
    // marker today, and if there ever is one this file has to keep writing the
    // punctuation around a value it cannot see the end of.
    const Object = struct {
        n: u32,
        pub const nilo_openapi = .{ .type = "object" };
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n);
        }
    };
    comptime std.debug.assert(!covers(Object));
}

test "a struct of keys can say how its fields are spelled" {
    // Item 46, reopened: every response in the reporting product holds at
    // least one `sql.Uuid`, so `rename_all` was refused on every one of them
    // while the document promised the renamed keys (ADR 148).
    const Contact = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };

        id: Key,
        full_name: []const u8,
        partner_id: Key,
    };

    try expectJson(
        "{\"id\":\"01020304\",\"fullName\":\"Wati\",\"partnerId\":\"0a0b0c0d\"}",
        Contact{
            .id = .{ .bytes = .{ 1, 2, 3, 4 } },
            .full_name = "Wati",
            .partner_id = .{ .bytes = .{ 10, 11, 12, 13 } },
        },
    );
}

test "a skipped field is left out of the object, whichever place it sits in" {
    const Account = struct {
        pub const nilo_json = .{ .skip = &.{ "salt", "password_hash" } };

        salt: []const u8,
        id: u32,
        password_hash: []const u8,
        name: []const u8,
    };
    try expectJson("{\"id\":7,\"name\":\"wati\"}", Account{ .salt = "s", .id = 7, .password_hash = "h", .name = "wati" });

    const Hidden = struct {
        pub const nilo_json = .{ .skip = &.{"secret"} };
        secret: u8,
    };
    try expectJson("{}", Hidden{ .secret = 1 });

    // Inside a tagged variant the payload's own marker is the one that counts.
    const Event = union(enum) {
        pub const nilo_json = .{ .tag = "kind" };
        login: struct {
            pub const nilo_json = .{ .skip = &.{"token"} };
            user: u32,
            token: []const u8,
        },
    };
    try expectJson("{\"kind\":\"login\",\"user\":3}", Event{ .login = .{ .user = 3, .token = "t" } });
}

test "a body is read by the wire spelling and a skipped key is an unknown one" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const Row = struct {
        pub const nilo_json = .{ .rename_all = .camelCase, .rename = .{ .due_at = "due" }, .skip = &.{"password_hash"} };

        full_name: []const u8,
        due_at: u32,
        password_hash: []const u8 = "",
    };
    const row = try parseLeaky(Row, arena.allocator(), "{\"fullName\":\"Wati\",\"due\":7}", .{});
    try testing.expectEqualStrings("Wati", row.full_name);
    try testing.expectEqual(@as(u32, 7), row.due_at);
    try testing.expectEqualStrings("", row.password_hash);

    try testing.expectError(error.UnknownField, parseLeaky(Row, arena.allocator(), "{\"full_name\":\"W\",\"due\":7}", .{}));
    try testing.expectError(error.UnknownField, parseLeaky(Row, arena.allocator(), "{\"fullName\":\"W\",\"dueAt\":7}", .{}));
    try testing.expectError(error.UnknownField, parseLeaky(Row, arena.allocator(), "{\"fullName\":\"W\",\"due\":7,\"password_hash\":\"x\"}", .{}));
    try testing.expectError(error.MissingField, parseLeaky(Row, arena.allocator(), "{\"due\":7}", .{}));
}

test "one field can be spelled on its own, and the entry wins over the case" {
    // Item 67: `estimated_cost_amount_minor` is `estimatedCostMinor` on the
    // wire — the frontend's schema, three screens and the generated client
    // all say so — and `rename_all` cannot get there from the column name
    // (ADR 168).
    const Summary = struct {
        pub const nilo_json = .{
            .rename_all = .camelCase,
            .rename = .{ .estimated_cost_amount_minor = "estimatedCostMinor" },
        };

        id: Key,
        estimated_cost_amount_minor: i64,
        due_at: []const u8,
    };

    try expectJson(
        "{\"id\":\"01020304\",\"estimatedCostMinor\":125000,\"dueAt\":\"2026-10-01\"}",
        Summary{
            .id = .{ .bytes = .{ 1, 2, 3, 4 } },
            .estimated_cost_amount_minor = 125_000,
            .due_at = "2026-10-01",
        },
    );

    // And on its own, with no case beside it: the one field moves and the
    // rest go out as they are written.
    const Bare = struct {
        pub const nilo_json = .{ .rename = .{ .kind_of = "type" } };

        kind_of: []const u8,
        other_one: u8,
    };
    try expectJson("{\"type\":\"note\",\"other_one\":1}", Bare{ .kind_of = "note", .other_one = 1 });
}

/// Write `value` and parse it back with `std.json`, which is the check that what
/// went out is JSON at all, and return the text for the caller to compare.
fn writtenAndParses(out: *std.Io.Writer.Allocating, value: anytype) !void {
    try write(&out.writer, value);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    parsed.deinit();
}

test "a float that is not finite is null on every shape that falls back to std.json" {
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);

    // A tuple, a type that writes itself, a document value, a map, a pointer and
    // a list of itself all miss `covers`. None may let `inf` or `nan` out.
    const Custom = struct {
        v: f64,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("v");
            try jw.write(self.v);
            try jw.endObject();
        }
    };
    comptime std.debug.assert(!covers(Custom));
    comptime std.debug.assert(!covers(struct { f64, f32 }));
    comptime std.debug.assert(!covers(std.json.Value));
    comptime std.debug.assert(!covers(std.json.ArrayHashMap(f64)));

    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writtenAndParses(&out, .{ inf, @as(f32, nan) });
        try testing.expectEqualStrings("[null,null]", out.written());
    }
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try writtenAndParses(&out, Custom{ .v = inf });
        try testing.expectEqualStrings("{\"v\":null}", out.written());
    }
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var items = [_]std.json.Value{ .{ .float = nan }, .{ .float = 2.5 }, .{ .float = -inf } };
        try writtenAndParses(&out, std.json.Value{ .array = .{ .items = &items, .capacity = items.len, .allocator = testing.allocator, .pointer_stability = .{} } });
        try testing.expectEqualStrings("[null,2.5,null]", out.written());
    }
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var map: std.json.ArrayHashMap(f64) = .{};
        defer map.deinit(testing.allocator);
        try map.map.put(testing.allocator, "a", inf);
        try map.map.put(testing.allocator, "b", 1.5);
        try writtenAndParses(&out, map);
        try testing.expectEqualStrings("{\"a\":null,\"b\":1.5}", out.written());
    }
    {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        const Row = struct { at: f64, inner: *const Custom };
        const c: Custom = .{ .v = nan };
        const row: Row = .{ .at = inf, .inner = &c };
        try writtenAndParses(&out, .{ .row = &row, .tail = .{ inf, 1 } });
        try testing.expectEqualStrings("{\"row\":{\"at\":null,\"inner\":{\"v\":null}},\"tail\":[null,1]}", out.written());
    }
}

test "the fallback writes what std.json writes for every value that is not a float it refuses" {
    const Custom = struct {
        n: u32,
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.n);
        }
    };
    const U = union(enum) { a: u8, b: []const u8, c, d: ?f64 };
    const Mixed = struct {
        t: struct { u8, []const u8, ?bool },
        c: Custom,
        u: []const U,
        bytes: [3]u8,
        raw: []const u8,
        e: enum { x, y },
        none: ?u8 = null,
        p: *const u16,
        f: f64,
    };
    const n: u16 = 9;
    const value: Mixed = .{
        .t = .{ 1, "two", null },
        .c = .{ .n = 3 },
        .u = &.{ .{ .a = 1 }, .{ .b = "x\"y" }, .c, .{ .d = 0.25 }, .{ .d = null } },
        .bytes = .{ 104, 105, 33 },
        .raw = "\xff\xfe",
        .e = .y,
        .p = &n,
        .f = 12.5,
    };
    comptime std.debug.assert(!covers(Mixed));

    var mine: std.Io.Writer.Allocating = .init(testing.allocator);
    defer mine.deinit();
    try write(&mine.writer, value);
    var theirs: std.Io.Writer.Allocating = .init(testing.allocator);
    defer theirs.deinit();
    try std.json.Stringify.value(value, .{}, &theirs.writer);
    try testing.expectEqualStrings(theirs.written(), mine.written());
}

test "alloc hands back the bytes write would have written, and frees cleanly" {
    const Row = struct { id: u32, ratio: f64, tags: []const []const u8 };
    const row: Row = .{ .id = 7, .ratio = std.math.nan(f64), .tags = &.{ "a", "b\n" } };

    const owned = try alloc(testing.allocator, row);
    defer testing.allocator.free(owned);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, row);
    try testing.expectEqualStrings(out.written(), owned);
    try testing.expectEqualStrings("{\"id\":7,\"ratio\":null,\"tags\":[\"a\",\"b\\n\"]}", owned);
}

/// `s` written `n` times over, at compile time: what `s ** n` said before
/// Zig 0.17 took the operator away.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    // A comptime-known constant, so that `&built` is a pointer into the
    // binary and the call is as good at runtime as `**` was.
    const built = comptime blk: {
        @setEvalBranchQuota(10 * n + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        break :blk final;
    };
    return &built;
}
