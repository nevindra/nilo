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

/// How a failure body is written, once `app.failures(T)` has said which
/// type: the status and the sentence in, the struct's JSON out. What the
/// document says it looks like is `openapi.schemaOf(T)`, taken beside this
/// in `app.zig` — this file stays outside the App's core by not naming it.
pub const Write = *const fn (status: u16, message: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void;

/// Connect's failure body for a request that asked for it, and null for any
/// other (ADR 257): handed the request's head and the error, it says which
/// shape this failure takes over the App's own. The error is read here, not
/// by the shape, so `Write` keeps the signature an App's own shape has. Set by the first route that reads or
/// answers a message, so a program with none links none of it.
pub const Pick = *const fn (head: []const u8, err: anyerror) ?Write;

pub fn writerOf(comptime T: type) Write {
    comptime check(T);
    const Writer = struct {
        fn write(status: u16, message: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
            return json.write(w, T.nilo_failure(status, message));
        }
    };
    return &Writer.write;
}

/// Everything that can be wrong with the type, said at `app.failures`.
pub fn check(comptime T: type) void {
    comptime {
        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: `app.failures` was given " ++ naming.of(T) ++
                ", and the shape of a failure body is a struct.\n" ++
                "  Its fields are the JSON a failed request answers with. Write one — " ++
                "`const ApiError = struct { code: u16, detail: []const u8, … }` — with a " ++
                "`pub fn nilo_failure(status: u16, message: []const u8) ApiError` that fills it.",
        );
        if (!@hasDecl(T, "nilo_failure")) @compileError(
            "nilo: " ++ naming.of(T) ++ " has no `nilo_failure`, so nilo cannot fill it " ++
                "from a status and a message.\n" ++
                "  Add `pub fn nilo_failure(status: u16, message: []const u8) " ++ naming.of(T) ++
                " { return .{ … }; }`. `message` is the fail function's sentence and lives as " ++
                "long as the response; a field of `[]const u8` can hold it as it is.",
        );
        const F = @TypeOf(T.nilo_failure);
        const fits = switch (@typeInfo(F)) {
            .@"fn" => |f| f.params.len == 2 and
                f.params[0].type == u16 and
                f.params[1].type == []const u8 and
                f.return_type == T,
            else => false,
        };
        if (!fits) @compileError(
            "nilo: " ++ naming.of(T) ++ "'s `nilo_failure` is not `fn (status: u16, message: []const u8) " ++
                naming.of(T) ++ "`.\n" ++
                "  It is handed the status and the sentence, and hands back the struct, and " ++
                "nothing else: it cannot fail, because the failure path must not have a " ++
                "failure path of its own (ADR 024).",
        );
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
    try write(404, "no user \"7\"", &w);
    try testing.expectEqualStrings("{\"code\":404,\"detail\":\"no user \\\"7\\\"\"}", w.buffered());
}

test "a nested shape is written whole" {
    const write = writerOf(Nested);
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(503, "later", &w);
    try testing.expectEqualStrings(
        "{\"error\":{\"status\":503,\"message\":\"later\",\"retryable\":true}}",
        w.buffered(),
    );
}
