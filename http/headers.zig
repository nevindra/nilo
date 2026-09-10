//! The headers a response carries, held by value.
//!
//! Its own file rather than a declaration inside `typed.zig`, which is the
//! compile-time engine: this is an ordinary value type with no comptime
//! machinery in it, and two files that are not the engine — `redirect.zig`
//! and `filebody.zig` — need only this out of that whole module. Reaching a
//! layer up for one struct is how a layer stops being one.
//!
//! `typed.zig` re-exports it, so `nilo.Headers` is unchanged.

const std = @import("std");
const naming = @import("names.zig");
const Header = @import("http1.zig").Header;

/// The headers a `Response` carries, held by value rather than pointed at.
///
/// That is the whole reason this type exists. `headers: []const Header` read
/// beautifully and was a use-after-return: a list written in the handler
/// lives in the handler's own stack frame, and nilo reads it after the
/// handler has returned. With every value a literal the compiler puts the
/// list in static memory and it happens to work; with a computed one — and a
/// `Location` never is a literal — `Debug` gets away with it and release
/// segfaults ([ADR 0019](../docs/adr/0019-a-response-owns-its-headers.md)).
///
/// `of` copies while the list is still alive, which is why it has to be
/// called where the list is written:
///
/// ```zig
/// .headers = .of(&.{
///     .{ .name = "Location", .value = try std.fmt.allocPrint(arena, "/users/{d}", .{id}) },
/// }),
/// ```
///
/// What is copied is the two slices, not the bytes they point at, so the
/// usual rule still holds for the *value*: a literal, something a Service
/// owns, or something built in the request arena. `c.setHeader` remains the
/// way to set a header without a count to think about.
pub const Headers = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 0122).
    pub const nilo_type_name = "nilo.Headers";

    /// How many one response can carry. Enough for the ones a handler
    /// actually decides — `Location`, a couple of `Set-Cookie`, a cache
    /// directive — and small enough that carrying them by value is 264
    /// bytes rather than something worth measuring. Past this, `c.setHeader`
    /// has no limit.
    pub const room = 8;

    entries: [room]Header = undefined,
    count: usize = 0,

    /// Copy a list of headers written out in place. The list may be a
    /// pointer to one (`&.{…}`, which is what reads best) or the tuple
    /// itself; either way its length is known while compiling, which is what
    /// lets a ninth header be a compile error rather than a surprise.
    pub fn of(list: anytype) Headers {
        // The `.one` is doing work: a slice is a pointer too, and
        // dereferencing one is an error from inside this function rather
        // than the message below — the exact failure ADR 0015 is about.
        const items = switch (@typeInfo(@TypeOf(list))) {
            .pointer => |p| if (p.size == .one) list.* else notAList(@TypeOf(list)),
            else => list,
        };
        const count = comptime lengthOf(@TypeOf(items));
        var made: Headers = .{ .count = count };
        inline for (0..count) |i| {
            made.entries[i] = .{ .name = items[i].name, .value = items[i].value };
        }
        return made;
    }

    /// The headers that were set, in the order they were written.
    pub fn view(self: *const Headers) []const Header {
        return self.entries[0..self.count];
    }

    fn lengthOf(comptime Items: type) usize {
        comptime {
            const count = switch (@typeInfo(Items)) {
                .array => |a| a.len,
                .@"struct" => |s| if (s.is_tuple) s.fields.len else notAList(Items),
                else => notAList(Items),
            };
            if (count > room) @compileError(std.fmt.comptimePrint(
                "nilo: a Response can carry {d} headers and this one was given {d}.\n" ++
                    "  Set the rest with `c.setHeader`, which has no limit.",
                .{ room, count },
            ));
            return count;
        }
    }

    fn notAList(comptime Items: type) noreturn {
        @compileError(
            "nilo: Response headers have to be written out where they are set — " ++
                ".of(&.{.{ .name = \"Location\", .value = where }}) — and this is a " ++
                naming.of(Items) ++ ".\n" ++
                "  A slice would not say how many there are until the program runs, and the " ++
                "response has to hold them itself.",
        );
    }
};
