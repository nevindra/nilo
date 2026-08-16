//! Scope — one lifetime, and the memory that belongs to it (ADR 0041).
//!
//! A request is the Scope a handler runs in. `Ctx` hands out the request
//! arena and stamps text with the request's lifetime, and
//! [ADR 0040](../docs/adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
//! added those two calls for exactly one reason: a module beside the
//! framework needed a supported way to allocate for a request and to say
//! how long the result lives. Naming the pair is all it takes for such a
//! module to stop naming `Ctx` at all — which is what lets `nilo_sql` run
//! in a program that has no server in it, with a `Run` handed over instead.
//!
//! It is a shape checked while compiling, not an interface with a function
//! table. A vtable would put an indirect call on every allocation a module
//! makes, which is the path [ADR 0018](../docs/adr/0018-the-trade-budget-has-three-axes.md)
//! guards hardest, to buy a polymorphism nobody has asked for. What is here
//! instead costs nothing at run time and refuses the wrong type in a
//! sentence.

const std = @import("std");
const str_mod = @import("str.zig");

const Str = str_mod.Str;
const Lifetime = str_mod.Lifetime;

/// Refuse anything that is not a Scope, in nilo's own words.
///
/// `called` names the call being written rather than the type alone,
/// because a type that is not a Scope is never the interesting half of the
/// message — which argument of which call it was handed to is.
pub fn check(comptime T: type, comptime called: []const u8) void {
    comptime {
        const Holder = switch (@typeInfo(T)) {
            .pointer => |p| if (p.size == .one) p.child else T,
            else => T,
        };

        // The continuation lines are indented the way every other refusal in
        // nilo indents them, because the build step that holds these messages
        // matches the first line (ADR 0027).
        const advice =
            "\n  Pass the `*Ctx` the handler was given, or a `nilo.Run` if there is no request.";

        switch (@typeInfo(Holder)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => {},
            else => @compileError("nilo: " ++ called ++ " needs a Scope, and " ++
                @typeName(T) ++ " cannot be one.\n" ++
                "  A Scope hands out memory and a lifetime, so it has to be a type with" ++
                " declarations." ++ advice),
        }

        if (!@hasDecl(Holder, "arena") or !@hasDecl(Holder, "str"))
            @compileError("nilo: " ++ called ++ " needs a Scope and " ++ @typeName(T) ++
                " is not one.\n" ++
                "  A Scope has `arena()`, for memory that lasts as long as the work does," ++
                " and `str()`, which stamps text with that lifetime; this type has " ++
                (if (@hasDecl(Holder, "arena"))
                    "the first and not the second."
                else if (@hasDecl(Holder, "str"))
                    "the second and not the first."
                else
                    "neither.") ++ advice);

        const Arena = @typeInfo(@TypeOf(Holder.arena)).@"fn".return_type.?;
        if (Arena != std.mem.Allocator)
            @compileError("nilo: " ++ called ++ " needs a Scope, and " ++ @typeName(T) ++
                "'s `arena()` answers " ++ @typeName(Arena) ++ " rather than a std.mem.Allocator.\n" ++
                "  Something has to own the memory the result lives in, and that is what" ++
                " says so." ++ advice);

        const Text = @typeInfo(@TypeOf(Holder.str)).@"fn".return_type.?;
        if (Text != Str)
            @compileError("nilo: " ++ called ++ " needs a Scope, and " ++ @typeName(T) ++
                "'s `str()` answers " ++ @typeName(Text) ++ " rather than a Str.\n" ++
                "  A Scope is what decides how long text lives, so that call is the one" ++
                " that says it." ++ advice);
    }
}

/// A Scope for work that is not a request: a CLI run, the tick of a
/// scheduled task, a test that wants one without an App around it.
///
/// It owns its arena and the Lifetime that goes with it, so text it stamps
/// goes stale at `reset` and at `deinit` exactly the way a request's does —
/// the debug trap watches a `Run` on the same terms it watches a handler,
/// which is the point of it being a Scope rather than a bare allocator.
pub const Run = struct {
    _arena: std.heap.ArenaAllocator,
    _lifetime: Lifetime,

    pub fn init(gpa: std.mem.Allocator) Run {
        return .{ ._arena = .init(gpa), ._lifetime = .init() };
    }

    pub fn deinit(self: *Run) void {
        self._lifetime.deinit();
        self._arena.deinit();
    }

    pub fn arena(self: *Run) std.mem.Allocator {
        return self._arena.allocator();
    }

    pub fn str(self: *Run, bytes: []const u8) Str {
        return .fromRequest(bytes, &self._lifetime);
    }

    /// Throw this tick's memory away and start the next one, keeping the
    /// pages. The same shape `App` uses between requests, for the same
    /// reason: a task that runs every thirty seconds forever should not
    /// grow, and everything it stamped last time should stop being
    /// readable when it says so.
    pub fn reset(self: *Run) void {
        self._lifetime.end();
        _ = self._arena.reset(.retain_capacity);
    }
};

const testing = std.testing;

test "a Run hands out memory and a lifetime" {
    var run = Run.init(testing.allocator);
    defer run.deinit();

    const copied = try run.arena().dupe(u8, "wati");
    const text = run.str(copied);
    try testing.expectEqualStrings("wati", text.view());
}

test "a Run is a Scope" {
    check(*Run, "a test");
}

test "text stamped by a Run goes stale when the tick ends" {
    if (!str_mod.trap_enabled) return;
    var run = Run.init(testing.allocator);
    defer run.deinit();

    const text = run.str(try run.arena().dupe(u8, "this tick"));
    try testing.expect(text.alive());
    run.reset();
    try testing.expect(!text.alive());
}

test "a Run keeps its pages across a reset" {
    var run = Run.init(testing.allocator);
    defer run.deinit();

    for (0..64) |_| {
        _ = try run.arena().alloc(u8, 1024);
        run.reset();
    }
}

test "text stamped by a Run is stale for good once the Run is over" {
    if (!str_mod.trap_enabled) return;
    var run = Run.init(testing.allocator);
    const text = run.str(try run.arena().dupe(u8, "gone"));
    try testing.expect(text.alive());
    run.deinit();
    try testing.expect(!text.alive());
}
