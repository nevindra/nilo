//! The body a failure goes out with, when nilo's is not the one your clients
//! already read ([ADR 024](../docs/adr/024-every-failure-answers-as-json.md)).
//!
//! ```zig
//! const ApiError = struct {
//!     code: u16,
//!     detail: []const u8,
//!
//!     pub fn nilo_failure(status: u16, message: []const u8) ApiError {
//!         return .{ .code = status, .detail = message };
//!     }
//! };
//!
//! try app.failures(ApiError);
//! ```
//!
//! Every failure nilo assembles — a fail function's sentence, a 404 for a
//! route nobody registered, a 400 for a body that did not fit, a 500 for an
//! error nothing mapped — went out as `{"error":"…","status":400}`, and
//! ADR 024 says why one shape is right. It is right for an application
//! that has no shape yet. An application with three other services and a
//! frontend that already reads `{"code":…,"detail":…}` from all of them has
//! one, and the only way to send it was a middleware that caught the error
//! and wrote the response itself — which loses the message the fail function
//! wrote, the `Allow` a 405 carries, the `WWW-Authenticate` a 401 carries,
//! and the CORS headers, in that order.
//!
//! **The shape is a struct, and the struct is the whole contract.** Its fields
//! say what the JSON looks like, the way a handler's return type does; nilo
//! writes it with the same JSON writer a handler's answer goes through; the
//! API description derives the `Failure` schema from the fields, so the
//! document and the wire cannot disagree. `nilo_failure` is the one function
//! the type has to carry: given the status and the sentence, fill the struct.
//! Nothing here is a writer, because a writer would have to be trusted about
//! what it wrote, and a type does not have to be.
//!
//! **What it costs.** Nothing on a request that succeeds: the shape is read
//! once, on a failure, from a field on `App` that is null unless `failures`
//! was called. On a failure it is a JSON write into the same fixed buffer the
//! default shape uses — no allocation, which is the invariant ADR 024 names:
//! the failure path must not have a failure path of its own. The buffer has
//! room for the longest message a Failure can hold, fully escaped, plus 256
//! bytes for the envelope around it; a shape that needs more is a shape that
//! is putting something other than the status and the message in the body,
//! and it gets nilo's own shape instead, sentence intact — which the first
//! failure in development shows, and which costs no log line on every App.
//!
//! **What it is not.** The five answers that go out before there is a Ctx —
//! a malformed head, a head too long, a head that timed out, a body under a
//! coding nilo cannot read, a request shed past `max_in_flight` — keep
//! nilo's shape. They are compile-time constants written in one `writeAll`,
//! answered to a client that did not manage to send an HTTP request nilo
//! could route, and the reason they are constants (ADR 159: a shed request
//! costs one write) is worth more than their envelope.

const std = @import("std");
const json = @import("json.zig");
const naming = @import("names.zig");
const fail = @import("fail.zig");

/// How a failure body is written, once `app.failures(T)` has said which
/// type: the status, the sentence and the fields that did not fit in, the
/// struct's JSON out. What the document says it looks like is
/// `openapi.schemaOf(T)`, taken beside this in `app.zig` — this file stays
/// outside the App's core by not naming it.
///
/// `fields` is nilo's own list, and `mapped` is that list after the
/// application's `nilo_field` has turned each entry into its own type (see
/// `Map`), or null when it could not be. A shape whose `nilo_failure` takes
/// two parameters ignores both; one that takes three reads whichever it needs.
pub const Write = *const fn (
    status: u16,
    message: []const u8,
    fields: []const fail.FieldFailure,
    mapped: ?*const anyopaque,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void;

/// The one allocation a shape with its own field type makes, in the request
/// arena and before the body is measured, so the counting pass and the
/// writing pass see the same list. Null when the arena has no room, which the
/// writer reads as an empty list: a hook that cannot fail cannot be handed a
/// failure either (ADR 024).
pub const Map = *const fn (arena: std.mem.Allocator, fields: []const fail.FieldFailure) ?*const anyopaque;

/// Connect's failure body for a request that asked for it, and null for any
/// other (ADR 257): handed the request's head and the error, it says which
/// shape this failure takes over the App's own. The error is read here, not
/// by the shape, so `Write` keeps the signature an App's own shape has. Set by the first route that reads or
/// answers a message, so a program with none links none of it.
pub const Pick = *const fn (head: []const u8, err: anyerror) ?Write;

/// Whether `T`'s `nilo_failure` takes the fields (ADR 024): three parameters
/// and not two, decided by arity so that a shape which does not want them
/// pays for nothing.
pub fn takesFields(comptime T: type) bool {
    check(T);
    return @typeInfo(@TypeOf(T.nilo_failure)).@"fn".param_types.len == 3;
}

/// The type of one entry of the third parameter, or `fail.FieldFailure` for a
/// shape that takes none.
fn entryOf(comptime T: type) type {
    if (!takesFields(T)) return fail.FieldFailure;
    return @typeInfo(@typeInfo(@TypeOf(T.nilo_failure)).@"fn".param_types[2].?).pointer.child;
}

/// The mapping step for `T`, or null when there is nothing to map: a shape
/// that takes no fields, and one that takes nilo's own `FieldFailure`, which
/// the writer reads straight from the failure.
pub fn mapperOf(comptime T: type) ?Map {
    if (!takesFields(T)) return null;
    const E = entryOf(T);
    if (E == fail.FieldFailure) return null;
    const Mapper = struct {
        fn map(arena: std.mem.Allocator, fields: []const fail.FieldFailure) ?*const anyopaque {
            const out = arena.alloc(E, fields.len) catch return null;
            for (fields, out) |f, *slot| slot.* = E.nilo_field(f);
            return out.ptr;
        }
    };
    return &Mapper.map;
}

pub fn writerOf(comptime T: type) Write {
    comptime check(T);
    const Writer = struct {
        fn write(
            status: u16,
            message: []const u8,
            fields: []const fail.FieldFailure,
            mapped: ?*const anyopaque,
            w: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            if (comptime !takesFields(T)) return json.write(w, T.nilo_failure(status, message));
            const E = comptime entryOf(T);
            const list: []const E = if (comptime E == fail.FieldFailure)
                fields
            else if (mapped) |p|
                @as([*]const E, @ptrCast(@alignCast(p)))[0..fields.len]
            else
                &.{};
            return json.write(w, T.nilo_failure(status, message, list));
        }
    };
    return &Writer.write;
}

/// Everything that can be wrong with the type, said at `app.failures`.
pub fn check(comptime T: type) void {
    comptime {
        const name = naming.of(T);
        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: `app.failures` was given " ++ name ++
                ", and the shape of a failure body is a struct.\n" ++
                "  Its fields are the JSON a failed request answers with. Write one — " ++
                "`const ApiError = struct { code: u16, detail: []const u8, … }` — with a " ++
                "`pub fn nilo_failure(status: u16, message: []const u8) ApiError` that fills it.",
        );
        if (!@hasDecl(T, "nilo_failure")) @compileError(
            "nilo: " ++ name ++ " has no `nilo_failure`, so nilo cannot fill it " ++
                "from a status and a message.\n" ++
                "  Add `pub fn nilo_failure(status: u16, message: []const u8) " ++ name ++
                " { return .{ … }; }`. `message` is the fail function's sentence and lives as " ++
                "long as the response; a field of `[]const u8` can hold it as it is.",
        );
        const two = "`fn (status: u16, message: []const u8) " ++ name ++ "`";
        const three = "`fn (status: u16, message: []const u8, fields: []const E) " ++ name ++ "`";
        const F = @TypeOf(T.nilo_failure);
        const f = switch (@typeInfo(F)) {
            .@"fn" => |f| f,
            else => @compileError("nilo: " ++ name ++ "'s `nilo_failure` is not a function, and it has to be " ++
                two ++ " or " ++ three ++ "."),
        };
        const fits = (f.param_types.len == 2 or f.param_types.len == 3) and
            f.param_types[0] == u16 and
            f.param_types[1] == []const u8 and
            f.return_type == T;
        if (!fits) @compileError(
            "nilo: " ++ name ++ "'s `nilo_failure` is not " ++ two ++ " or " ++ three ++ ".\n" ++
                "  It is handed the status and the sentence (and, in the second form, the fields " ++
                "that did not fit), and hands back the struct, and " ++
                "nothing else: it cannot fail, because the failure path must not have a " ++
                "failure path of its own (ADR 024).",
        );
        if (f.param_types.len == 3) {
            const third = f.param_types[2] orelse @compileError(
                "nilo: " ++ name ++ "'s `nilo_failure` has a third parameter whose type is not written: " ++
                    "it has to be `fields: []const E`.",
            );
            const is_list = switch (@typeInfo(third)) {
                .pointer => |p| p.size == .slice and p.attrs.@"const",
                else => false,
            };
            if (!is_list) @compileError(
                "nilo: " ++ name ++ "'s `nilo_failure` takes " ++ naming.of(third) ++
                    " as its third parameter, and the fields that did not fit arrive as a `[]const E`.\n" ++
                    "  Make it `fields: []const nilo.FieldFailure`, or a slice of a type of yours with a " ++
                    "`pub fn nilo_field(f: nilo.FieldFailure) E` that maps one entry.",
            );
            const E = @typeInfo(third).pointer.child;
            if (E != fail.FieldFailure) {
                const has = switch (@typeInfo(E)) {
                    .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(E, "nilo_field"),
                    else => false,
                };
                if (!has) @compileError(
                    "nilo: " ++ naming.of(E) ++ " is neither `nilo.FieldFailure` nor a type with a `nilo_field`, " ++
                        "so nilo cannot fill the fields of " ++ name ++ "'s failure body.\n" ++
                        "  Add `pub fn nilo_field(f: nilo.FieldFailure) " ++ naming.of(E) ++
                        " { return .{ … }; }`, or take `[]const nilo.FieldFailure` as it is.",
                );
                const M = @TypeOf(E.nilo_field);
                const maps = switch (@typeInfo(M)) {
                    .@"fn" => |m| m.param_types.len == 1 and m.param_types[0] == fail.FieldFailure and
                        m.return_type == E,
                    else => false,
                };
                if (!maps) @compileError(
                    "nilo: " ++ naming.of(E) ++ "'s `nilo_field` is not `fn (f: nilo.FieldFailure) " ++
                        naming.of(E) ++ "`.\n" ++
                        "  It is handed one entry and hands back the type, and nothing else — " ++
                        "not an error union either: it cannot fail, because the failure path must " ++
                        "not have a failure path of its own (ADR 024).",
                );
            }
        }
    }
}

// ---- tests ----

const testing = std.testing;

const Enveloped = struct {
    code: u16,
    detail: []const u8,

    pub fn nilo_failure(status: u16, message: []const u8) Enveloped {
        return .{ .code = status, .detail = message };
    }
};

const Nested = struct {
    @"error": Inner,

    const Inner = struct { status: u16, message: []const u8, retryable: bool };

    pub fn nilo_failure(status: u16, message: []const u8) Nested {
        return .{ .@"error" = .{ .status = status, .message = message, .retryable = status == 503 } };
    }
};

test "a shape writes the struct its nilo_failure filled, escaped like any JSON" {
    const write = writerOf(Enveloped);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(404, "no user \"7\"", &.{}, null, &w);
    try testing.expectEqualStrings("{\"code\":404,\"detail\":\"no user \\\"7\\\"\"}", w.buffered());
}

test "a nested shape is written whole" {
    const write = writerOf(Nested);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(503, "later", &.{}, null, &w);
    try testing.expectEqualStrings(
        "{\"error\":{\"status\":503,\"message\":\"later\",\"retryable\":true}}",
        w.buffered(),
    );
}

const Listed = struct {
    detail: []const u8,
    fields: []const fail.FieldFailure,

    pub fn nilo_failure(status: u16, message: []const u8, fields: []const fail.FieldFailure) Listed {
        _ = status;
        return .{ .detail = message, .fields = fields };
    }
};

const Renamed = struct {
    code: u16,
    errors: []const Err,

    const Err = struct {
        path: []const u8,
        msg: []const u8,

        pub fn nilo_field(f: fail.FieldFailure) Err {
            return .{ .path = f.field, .msg = f.message };
        }
    };

    pub fn nilo_failure(status: u16, message: []const u8, errors: []const Err) Renamed {
        _ = message;
        return .{ .code = status, .errors = errors };
    }
};

const two_fields = [_]fail.FieldFailure{
    .{ .field = "email", .code = .missing, .message = "\"email\" is required" },
    .{ .field = "age", .code = .not_that_type, .message = "\"age\" has to be a whole number", .expected = "a whole number" },
};

test "a shape that takes two parameters is not handed the fields, and neither maps nor sizes them" {
    try testing.expect(!takesFields(Enveloped));
    try testing.expect(mapperOf(Enveloped) == null);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writerOf(Enveloped)(400, "bad", &two_fields, null, &w);
    try testing.expectEqualStrings("{\"code\":400,\"detail\":\"bad\"}", w.buffered());
}

test "a shape that takes nilo's own FieldFailure is handed the list as it is, with no mapping" {
    try testing.expect(takesFields(Listed));
    try testing.expect(mapperOf(Listed) == null);
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writerOf(Listed)(400, "bad", two_fields[0..1], null, &w);
    try testing.expectEqualStrings(
        "{\"detail\":\"bad\",\"fields\":[{\"field\":\"email\",\"code\":\"missing\",\"message\":\"\\\"email\\\" is required\",\"expected\":null}]}",
        w.buffered(),
    );
}

test "a shape with its own field type is handed the list nilo_field mapped" {
    const map = mapperOf(Renamed).?;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const mapped = map(arena.allocator(), &two_fields);
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writerOf(Renamed)(400, "bad", &two_fields, mapped, &w);
    try testing.expectEqualStrings(
        "{\"code\":400,\"errors\":[{\"path\":\"email\",\"msg\":\"\\\"email\\\" is required\"},{\"path\":\"age\",\"msg\":\"\\\"age\\\" has to be a whole number\"}]}",
        w.buffered(),
    );
}

test "a mapping the arena refused gives the hook an empty list" {
    const map = mapperOf(Renamed).?;
    var none: [0]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&none);
    const mapped = map(fba.allocator(), &two_fields);
    try testing.expect(mapped == null);
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writerOf(Renamed)(400, "bad", &two_fields, mapped, &w);
    try testing.expectEqualStrings("{\"code\":400,\"errors\":[]}", w.buffered());
}
