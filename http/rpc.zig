//! A struct of typed functions served as one RPC service, each `pub fn` a
//! method at `POST /<nilo_service>/<Method>`
//! ([ADR 258](../docs/adr/258-a-struct-of-typed-functions-is-an-rpc-service.md)).
//!
//! ```zig
//! const Greeter = struct {
//!     pub const nilo_service = "helloworld.Greeter";
//!
//!     pub fn sayHello(arena: std.mem.Allocator, in: HelloRequest) !HelloReply {
//!         return .{ .message = try std.fmt.allocPrint(arena, "Hello, {s}", .{in.name}) };
//!     }
//! };
//!
//! try app.rpc(Greeter);
//! ```
//!
//! **The struct is the service and its functions are the methods**, the way
//! a struct is a table in `nilo_sql`: `nilo_service` is the protobuf
//! service's full name, the package and the service as the `.proto` file
//! has them, and a method's name is its function's with the first letter
//! upper-cased, which is how protobuf spells one (`sayHello` is
//! `/helloworld.Greeter/SayHello`). What gRPC, Connect and a browser's
//! `fetch` call is that path, and each method is an ordinary typed route on
//! it: the message read and answered in the spelling the request came in
//! (ADR 256), a failure told to a Connect client in its words (ADR 257),
//! services and middleware as on any route.
//!
//! **Nothing here runs**: the table of methods is worked out while
//! compiling and handed to `post`, so a program that never calls `app.rpc`
//! has none of it and one that does has exactly the routes it would have
//! written by hand.
//!
//! Not `app.service`: a Service in nilo is a thing `app.provide` registers
//! and a handler asks for by type (`CONTEXT.md`), and `app.service(Greeter)`
//! would read as providing one.

const std = @import("std");
const naming = @import("names.zig");
const message = @import("message.zig");

/// One method: the function's name in the struct, and the path it is
/// served at.
pub const Method = struct {
    fn_name: []const u8,
    path: []const u8,
};

/// Every method of `T`, in the order its functions are declared, or a
/// compile error naming what is wrong with it.
pub fn methodsOf(comptime T: type) []const Method {
    comptime {
        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: `app.rpc` was given " ++ naming.of(T) ++ ", which is not a struct.\n" ++
                "  It takes a struct whose `pub fn`s are the methods, named by " ++
                "`pub const nilo_service = \"package.Service\";`.",
        );
        const service = serviceName(T);
        var out: []const Method = &.{};
        for (@typeInfo(T).@"struct".decl_names) |decl_name| {
            const f = @field(T, decl_name);
            if (@typeInfo(@TypeOf(f)) != .@"fn") continue;
            const path = "/" ++ service ++ "/" ++ methodName(decl_name);
            if (!message.speaks(@TypeOf(f))) @compileError(
                "nilo: " ++ naming.of(T) ++ "." ++ decl_name ++ " is a `pub fn` of an RPC service, " ++
                    "so it is served as \"POST " ++ path ++ "\", and it neither reads nor answers a " ++
                    "message.\n" ++
                    "  A method takes a struct with a `wire` table and answers one. If it is a " ++
                    "helper, drop its `pub`; if it is a route of another kind, register it with `app.post`.",
            );
            for (out) |seen| if (std.mem.eql(u8, seen.path, path)) @compileError(
                "nilo: " ++ naming.of(T) ++ "." ++ seen.fn_name ++ " and " ++ naming.of(T) ++ "." ++
                    decl_name ++ " are both served as \"POST " ++ path ++ "\": a method's name is its " ++
                    "function's with the first letter upper-cased.\n" ++
                    "  Rename one of them.",
            );
            out = out ++ &[_]Method{.{ .fn_name = decl_name, .path = path }};
        }
        if (out.len == 0) @compileError(
            "nilo: " ++ naming.of(T) ++ " is given to `app.rpc` and has no `pub fn`, so it serves " ++
                "nothing.\n" ++
                "  Each method is a `pub fn` of the struct that reads or answers a message.",
        );
        return out;
    }
}

/// `nilo_service`, checked: text a gRPC path can carry, the package's
/// parts and the service's name joined by dots.
fn serviceName(comptime T: type) []const u8 {
    comptime {
        if (!@hasDecl(T, "nilo_service")) @compileError(
            "nilo: " ++ naming.of(T) ++ " is given to `app.rpc` and does not say which service it is.\n" ++
                "  Add `pub const nilo_service = \"package.Service\";`, the full name its `.proto` " ++
                "file gives it, which is the first half of every method's path.",
        );
        const name = T.nilo_service;
        const is_text = switch (@typeInfo(@TypeOf(name))) {
            .pointer => |p| p.size == .slice and p.child == u8 or
                (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8),
            else => false,
        };
        if (!is_text) @compileError(
            "nilo: " ++ naming.of(T) ++ "'s `nilo_service` has to be text, the service's full name: " ++
                "`pub const nilo_service = \"package.Service\";`.",
        );
        const text: []const u8 = name;
        var good = text.len > 0 and text[0] != '.' and text[text.len - 1] != '.';
        for (text, 0..) |c, i| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) good = false;
            if (c == '.' and i > 0 and text[i - 1] == '.') good = false;
        }
        if (!good) @compileError(
            "nilo: " ++ naming.of(T) ++ "'s `nilo_service` is \"" ++ text ++ "\", which is not a " ++
                "service's full name.\n" ++
                "  It is the package's parts and the service's name joined by dots, letters, digits " ++
                "and `_` in each, as the `.proto` file has them: \"helloworld.Greeter\".",
        );
        return text;
    }
}

/// A function's name as a method's: the first letter upper-cased.
fn methodName(comptime fn_name: []const u8) []const u8 {
    comptime {
        if (fn_name.len == 0 or !std.ascii.isLower(fn_name[0])) return fn_name;
        return &[_]u8{std.ascii.toUpper(fn_name[0])} ++ fn_name[1..];
    }
}

// ---- tests ----

const testing = std.testing;

test "a method's name is its function's with the first letter upper-cased" {
    try testing.expectEqualStrings("SayHello", comptime methodName("sayHello"));
    try testing.expectEqualStrings("Sum", comptime methodName("Sum"));
    try testing.expectEqualStrings("_x", comptime methodName("_x"));
}
