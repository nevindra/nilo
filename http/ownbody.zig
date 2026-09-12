//! A type that writes its own answer (ADR 0195).
//!
//! ```zig
//! const Invoice = struct {
//!     number: u32,
//!     total: i64,
//!
//!     pub const nilo_content_type = "application/xml";
//!
//!     pub fn nilo_write(self: Invoice, w: *std.Io.Writer) !void {
//!         try w.print("<invoice><number>{d}</number><total>{d}</total></invoice>", .{ self.number, self.total });
//!     }
//! };
//!
//! fn showInvoice(db: *Db, id: u32) !?Invoice { … }
//! ```
//!
//! A returned value is JSON, bytes are text, and there was no third answer:
//! a handler with an XML consumer took a `*Ctx` and called `c.send` with
//! bytes it had assembled itself, and the generated description said the
//! route wrote something it could not read. This is the third answer, and
//! it is the shape the other side of the request already has — `nilo_parse`
//! reads a path param, `nilo_json` spells a struct's JSON, `nilo_openapi`
//! describes it — a declaration read by name, so a type in any layer can
//! carry it without importing this one.
//!
//! **Two declarations, and both or neither.** `nilo_content_type` is what
//! goes on the `Content-Type` line; `nilo_write` puts the body on a writer.
//! One without the other is a refusal, because each is meaningless alone:
//! a content type with nothing written under it, or bytes labelled as
//! whatever `contentTypeFor` would have guessed.
//!
//! **What it costs is what JSON costs.** The body is written into the
//! request arena through the same `Writer.Allocating` `sendJson` uses,
//! starting at the same `json_hint`, and goes out through `c.send`. One
//! allocation, the one a JSON answer already makes. Everything here is
//! `comptime` on the type, so a program with no such type links none of it.
//!
//! **What it is not.** A serialiser. nilo does not know XML, CSV or HTML and
//! is not going to (ADR 0195 says why); it knows how to send bytes under a
//! label, and this lets a type say which bytes and which label.

const std = @import("std");

const naming = @import("names.zig");

/// Whether `T` carries both declarations. A type carrying one is caught by
/// `check`, which every route runs while compiling; here the answer is
/// simply whether the pair is present.
pub fn writesItsOwnBody(comptime T: type) bool {
    comptime {
        return switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "nilo_content_type") and @hasDecl(T, "nilo_write"),
            else => false,
        };
    }
}

/// Everything that can be wrong with the pair, said at the route.
pub fn check(comptime pattern: []const u8, comptime T: type) void {
    comptime {
        const container = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => true,
            else => false,
        };
        if (!container) return;
        const has_type = @hasDecl(T, "nilo_content_type");
        const has_write = @hasDecl(T, "nilo_write");
        if (!has_type and !has_write) return;

        if (has_type and !has_write) @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" returns " ++ naming.of(T) ++
                ", which names a `nilo_content_type` and has no `nilo_write`.\n" ++
                "  A content type says what the bytes are, and nothing here writes any. Add " ++
                "`pub fn nilo_write(self: " ++ naming.of(T) ++ ", w: *std.Io.Writer) !void`, or " ++
                "take the content type off and let the value go out as JSON.",
        );
        if (has_write and !has_type) @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" returns " ++ naming.of(T) ++
                ", which has a `nilo_write` and no `nilo_content_type`.\n" ++
                "  Bytes a type writes itself need a label, and nilo will not guess one. Add " ++
                "`pub const nilo_content_type = \"application/xml\";` — or whatever they are.",
        );

        const ct = T.nilo_content_type;
        const CT = @TypeOf(ct);
        const is_text = switch (@typeInfo(CT)) {
            .pointer => |p| p.size == .slice and p.child == u8 or
                (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8),
            else => false,
        };
        if (!is_text) @compileError(
            "nilo: " ++ naming.of(T) ++ "'s `nilo_content_type` is a " ++ @typeName(CT) ++
                ", and a content type is text.\n" ++
                "  Write `pub const nilo_content_type = \"application/xml\";`.",
        );
        const text: []const u8 = ct;
        if (text.len == 0) @compileError(
            "nilo: " ++ naming.of(T) ++ "'s `nilo_content_type` is empty, so its answer would " ++
                "go out with no label.\n" ++
                "  Say what the bytes are — `\"application/xml\"`, `\"text/csv\"` — or take " ++
                "both declarations off and let the value go out as JSON.",
        );
        for (text) |ch| if (ch < 0x20 or ch == 0x7f) @compileError(
            "nilo: " ++ naming.of(T) ++ "'s `nilo_content_type` has a control character in " ++
                "it, which would end the header line early.\n" ++
                "  A content type is one line: `\"application/xml\"`.",
        );

        const W = @TypeOf(T.nilo_write);
        const fits = switch (@typeInfo(W)) {
            .@"fn" => |f| f.params.len == 2 and
                (f.params[0].type == T or f.params[0].type == *const T or f.params[0].type == *T) and
                f.params[1].type == *std.Io.Writer,
            else => false,
        };
        if (!fits) @compileError(
            "nilo: " ++ naming.of(T) ++ "'s `nilo_write` is not `fn (self: " ++ naming.of(T) ++
                ", w: *std.Io.Writer) !void`.\n" ++
                "  It is handed the value and the writer the body goes to, and nothing else: " ++
                "the status and the headers are the handler's, through `Response(T)`.",
        );
    }
}

// ---- tests ----

const testing = std.testing;

const Plain = struct {
    n: u32,
    pub const nilo_content_type = "text/csv";
    pub fn nilo_write(self: Plain, w: *std.Io.Writer) !void {
        try w.print("n\n{d}\n", .{self.n});
    }
};

test "a type carrying both declarations writes its own body, and one carrying neither does not" {
    try testing.expect(comptime writesItsOwnBody(Plain));
    try testing.expect(comptime !writesItsOwnBody(struct { n: u32 }));
    try testing.expect(comptime !writesItsOwnBody(u32));
    try testing.expect(comptime !writesItsOwnBody([]const u8));
}

test "the check passes a type that has the pair right, and says nothing about one that has neither" {
    // Both compile-time; if either refused, this file would not build.
    comptime check("/csv", Plain);
    comptime check("/plain", struct { n: u32 });
    comptime check("/int", u32);
}
