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
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 0122).
    pub const nilo_type_name = "nilo.Run";

    _arena: std.heap.ArenaAllocator,
    _lifetime: Lifetime,
    /// What `entropy` asks for bytes, when the Run was given one.
    ///
    /// Optional because the two things a Run does — hand out memory and stamp
    /// a lifetime — need no Io at all, and a great many of them are made in a
    /// test that will never mint a key. Requiring one would make every
    /// existing `Run.init(gpa)` a compile error to buy a call most of them do
    /// not make.
    _io: ?std.Io = null,

    pub fn init(gpa: std.mem.Allocator) Run {
        return .{ ._arena = .init(gpa), ._lifetime = .init() };
    }

    /// A Run that can also mint a key
    /// ([ADR 0160](../docs/adr/0160-a-scope-that-can-mint-a-key.md)).
    ///
    /// The same Io a `nilo_sql` pool or an `std.Io.Threaded` was started
    /// with, which a CLI, a seed and a test all have in hand by the time they
    /// build a Run: they needed one to open the database.
    pub fn initIo(gpa: std.mem.Allocator, io: std.Io) Run {
        return .{ ._arena = .init(gpa), ._lifetime = .init(), ._io = io };
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

    /// `n` bytes from the operating system's entropy source
    /// ([ADR 0160](../docs/adr/0160-a-scope-that-can-mint-a-key.md)).
    ///
    /// ```zig
    /// const key = id.v7(try scope.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
    /// ```
    ///
    /// **Spelled the same as `Ctx.entropy` so that one function body compiles
    /// under both**, which is what the refusal in `check` above has always
    /// promised: *pass the `*Ctx` the handler was given, or a `nilo.Run` if
    /// there is no request*. It was true of every statement in `nilo_sql` and
    /// false of the most common function in any program — the one that mints
    /// a key — so a service function written against a Scope compiled until
    /// somebody wrote `create`.
    ///
    /// **What it does is not what `Ctx.entropy` does, and that is the point.**
    /// There the call goes through the Bulkhead, because a syscall straight
    /// from a fiber stops every request sharing that thread (ADR 0046). Here
    /// there is no fiber and nothing to park: this is `std.Io.randomSecure`,
    /// which is the same bytes. The two agree about the *signature*, which is
    /// all a caller written against a Scope can see, and disagree about the
    /// cost, which is the layer's business rather than the caller's.
    ///
    /// `error.NoIo` when the Run was built by `init` rather than `initIo`.
    /// Not a compile error, because the Io is a value rather than a type; the
    /// call that needs it says so here rather than at every `Run.init` in a
    /// suite that never mints anything.
    pub fn entropy(self: *Run, comptime n: usize) ![n]u8 {
        const io = self._io orelse return error.NoIo;
        var out: [n]u8 = undefined;
        try std.Io.randomSecure(io, &out);
        return out;
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

test "a Run given an Io mints bytes, and one without says so rather than inventing them" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var run = Run.initIo(testing.allocator, threaded.io());
    defer run.deinit();

    // Enough for a v7 key, which is the call this exists for.
    const first = try run.entropy(10);
    const second = try run.entropy(10);
    // Not a proof of randomness — a proof that something filled it. Two draws
    // of ten bytes colliding is not a thing that happens.
    try testing.expect(!std.mem.eql(u8, &first, &second));

    // And the Run that was never given one refuses rather than handing back a
    // key somebody could guess.
    var without = Run.init(testing.allocator);
    defer without.deinit();
    try testing.expectError(error.NoIo, without.entropy(10));
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
