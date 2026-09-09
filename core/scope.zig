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
    /// What `give` put here, for `resolve` to hand back
    /// ([ADR 0165](../docs/adr/0165-a-value-that-reaches-the-bottom.md)).
    ///
    /// Keyed by `@typeName`, exactly as `Ctx` keys the values it works out
    /// per request, so the two answer the same question the same way and a
    /// service function written against a Scope cannot tell which one it is
    /// standing in.
    _given: std.ArrayList(Given) = .empty,

    /// One value this Run was handed.
    const Given = struct {
        type_name: []const u8,
        value: *anyopaque,
    };

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
        var out: [n]u8 = undefined;
        try self.entropyInto(&out);
        return out;
    }

    /// `entropy` for a caller that cannot say the length while compiling
    /// ([ADR 0166](../docs/adr/0166-entropy-a-function-pointer-can-carry.md)).
    ///
    /// `entropy` answers `![n]u8`, which is the right shape for the call it
    /// was built for — a v7 key, in the expression that uses it. It is the
    /// wrong shape for a **vtable**: a function pointer has to name one
    /// return type, so a Scope that was type-erased to cross a function
    /// pointer can carry exactly one width and the second caller is stuck.
    /// Zig has no closures, so type-erasing a Scope is not an exotic thing
    /// to do — it is what anybody storing a callback ends up at.
    ///
    /// Same bytes, same wait, same `error.NoIo`.
    pub fn entropyInto(self: *Run, buf: []u8) !void {
        const io = self._io orelse return error.NoIo;
        try std.Io.randomSecure(io, buf);
    }

    /// Hand this tick a value, for something further down to ask for
    /// ([ADR 0165](../docs/adr/0165-a-value-that-reaches-the-bottom.md)).
    ///
    /// ```zig
    /// var run = nilo.Run.init(gpa);
    /// try run.give(Actor, .{ .agent = "nightly-import" });
    /// try importEverything(&db, &run);   // and anything under it can ask
    /// ```
    ///
    /// **This is the half a request does not need.** Under a server the same
    /// value is declared with `nilo_resolve` and worked out from the request
    /// itself, which is what makes "was it set?" a question the compiler
    /// answers (ADR 0016). A seed and a CLI have no request to work it out
    /// from, so somebody has to say it — and saying it once, here, is what
    /// keeps it off the sixty call sites in between.
    ///
    /// Copied into the tick's arena, so it dies at `reset` and at `deinit`
    /// with everything else the tick allocated. Giving the same type twice
    /// replaces the first, because a tick has one answer to a question.
    pub fn give(self: *Run, comptime V: type, value: V) !void {
        const memory = self._arena.allocator();
        const wanted = @typeName(V);

        const box = try memory.create(V);
        box.* = value;

        for (self._given.items) |*entry| {
            if (!sameType(entry.type_name, wanted)) continue;
            entry.value = @ptrCast(box);
            return;
        }
        // One is the shape this has in practice — who is acting — so the
        // list is sized for that once rather than grown twice.
        if (self._given.capacity == 0) try self._given.ensureTotalCapacity(memory, 2);
        try self._given.append(memory, .{ .type_name = wanted, .value = @ptrCast(box) });
    }

    /// The value of type `V` for this tick, or `error.NotGiven`
    /// ([ADR 0165](../docs/adr/0165-a-value-that-reaches-the-bottom.md)).
    ///
    /// **Spelled the same as `Ctx.resolve` so that one function body compiles
    /// under both**, which is the property the whole Scope exists for and the
    /// second call to be found missing from this side of it — `entropy` was
    /// the first (ADR 0160). What differs is where the value comes from: a
    /// request works it out from a declared resolver, a tick is told.
    ///
    /// `error.NotGiven` rather than a silent null, for the reason a NULL
    /// column is the failure this was reported over: a value nobody set has
    /// to be louder than a value nobody read.
    pub fn resolve(self: *Run, comptime V: type) !V {
        const wanted = @typeName(V);
        for (self._given.items) |entry| {
            if (!sameType(entry.type_name, wanted)) continue;
            return @as(*const V, @ptrCast(@alignCast(entry.value))).*;
        }
        return error.NotGiven;
    }

    /// Throw this tick's memory away and start the next one, keeping the
    /// pages. The same shape `App` uses between requests, for the same
    /// reason: a task that runs every thirty seconds forever should not
    /// grow, and everything it stamped last time should stop being
    /// readable when it says so.
    ///
    /// **What was given goes with it**, because it was allocated from the
    /// same arena and a tick that kept the last tick's actor would be
    /// answering with something it was never told.
    pub fn reset(self: *Run) void {
        self._lifetime.end();
        self._given = .empty;
        _ = self._arena.reset(.retain_capacity);
    }
};

/// A Scope that has been type-erased, for the one place a shape checked while
/// compiling cannot reach: the other side of a function pointer
/// ([ADR 0177](../docs/adr/0177-a-scope-that-crosses-a-function-pointer.md)).
///
/// ```zig
/// // The bus stores this, and it is one type whether it is called from a
/// // request or from a `Run` in a test.
/// const Reaction = *const fn (scope: *nilo.AnyScope, payload: []const u8) anyerror!void;
///
/// fn notify(scope: *nilo.AnyScope, payload: []const u8) !void {
///     const copy = try scope.arena().dupe(u8, payload);
///     …
/// }
///
/// var erased = nilo.AnyScope.of(c);   // or `.of(&run)`
/// try reaction(&erased, payload);
/// ```
///
/// **This is not a second way to write a handler, and it is not the Scope
/// getting a vtable.** ADR 0041 keeps the ordinary Scope a shape checked while
/// compiling because a vtable would put an indirect call on every allocation a
/// module makes; every call in nilo and in `nilo_sql` still takes `anytype` and
/// still costs nothing. This is one erased wrapper, made by whoever is about to
/// cross a function pointer, and paid for only there.
///
/// **Why anything needs it.** Zig has no closures, so a callback is a function
/// pointer and a function pointer cannot be generic over the Scope it runs
/// under (ADR 0166). Anything with a bus, a queue or a job registry hits this,
/// and the alternative is that each of them writes the same fifty lines of
/// pointer-and-vtable — each copy a fresh chance to hand a handler the wrong
/// lifetime.
///
/// **It borrows and owns nothing.** The pointer inside is the Scope's own, so
/// an `AnyScope` may not outlive the `Ctx` or `Run` it was made from. In
/// practice it is a local beside the call, which is the only shape that is
/// obviously right.
///
/// `resolve` is deliberately not here: it is generic over the type asked for,
/// so it cannot cross a function pointer any more than `entropy` could — which
/// is why `entropyInto` exists and is what this carries instead.
pub const AnyScope = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 0122).
    pub const nilo_type_name = "nilo.AnyScope";

    _scope: *anyopaque,
    _table: *const Table,

    /// The three calls a Scope makes across a function pointer. `arena` and
    /// `str` are what `check` above asks of every Scope; `entropyInto` is the
    /// third because minting a key is what a reaction does that a query does
    /// not, and it is spelled `Into` rather than `entropy` because a function
    /// pointer names one return type and `![n]u8` is a different one per width
    /// (ADR 0166).
    pub const Table = struct {
        arena: *const fn (*anyopaque) std.mem.Allocator,
        str: *const fn (*anyopaque, []const u8) Str,
        entropyInto: *const fn (*anyopaque, []u8) anyerror!void,
    };

    /// Erase `scope`, which is a `*Ctx` or a `*Run`.
    ///
    /// The table is a comptime constant per Scope type, so this is two stores
    /// and no allocation.
    pub fn of(scope: anytype) AnyScope {
        const P = @TypeOf(scope);
        comptime check(P, "nilo.AnyScope.of");
        comptime {
            const info = @typeInfo(P);
            if (info != .pointer or info.pointer.size != .one) @compileError(
                "nilo: `nilo.AnyScope.of` was given a " ++ @typeName(P) ++ " by value, and an " ++
                    "erased Scope holds a pointer to the one it was made from.\n" ++
                    "  Pass the `*Ctx` the handler was given, or `&run`.",
            );
            if (!@hasDecl(info.pointer.child, "entropyInto")) @compileError(
                "nilo: `nilo.AnyScope.of` needs a Scope with `entropyInto`, and " ++
                    @typeName(P) ++ " has `entropy` alone.\n" ++
                    "  A function pointer names one return type, so the erased call is the one" ++
                    " that takes a buffer rather than the one that answers `![n]u8` (ADR 0166).\n" ++
                    "  `*Ctx` and `nilo.Run` both have it.",
            );
        }
        const S = @typeInfo(P).pointer.child;

        const erased = struct {
            const table: Table = .{
                .arena = takeArena,
                .str = takeStr,
                .entropyInto = takeEntropy,
            };
            fn takeArena(p: *anyopaque) std.mem.Allocator {
                return S.arena(@ptrCast(@alignCast(p)));
            }
            fn takeStr(p: *anyopaque, bytes: []const u8) Str {
                return S.str(@ptrCast(@alignCast(p)), bytes);
            }
            fn takeEntropy(p: *anyopaque, buf: []u8) anyerror!void {
                return S.entropyInto(@ptrCast(@alignCast(p)), buf);
            }
        };
        return .{ ._scope = @ptrCast(@constCast(scope)), ._table = &erased.table };
    }

    pub fn arena(self: *AnyScope) std.mem.Allocator {
        return self._table.arena(self._scope);
    }

    pub fn str(self: *AnyScope, bytes: []const u8) Str {
        return self._table.str(self._scope, bytes);
    }

    /// `n` bytes of randomness, the width said where the call is written.
    ///
    /// The same spelling `Ctx` and `Run` have, so a function body written
    /// against one of those compiles against this — which is the whole point of
    /// the erasure and would be lost if the only call here were the buffer one.
    pub fn entropy(self: *AnyScope, comptime n: usize) ![n]u8 {
        var out: [n]u8 = undefined;
        try self.entropyInto(&out);
        return out;
    }

    /// The same bytes at a width nobody said while compiling — what the vtable
    /// actually carries (ADR 0166).
    pub fn entropyInto(self: *AnyScope, buf: []u8) !void {
        return self._table.entropyInto(self._scope, buf);
    }
};

/// Two `@typeName` results naming the same type.
///
/// The pointer comparison is the one that fires: `@typeName` of one type is
/// one string in the binary, so two mentions of `V` in the same compilation
/// are the same pointer. The `eql` behind it is for the case where they are
/// not, which costs nothing when the first test already answered.
fn sameType(a: []const u8, b: []const u8) bool {
    return a.ptr == b.ptr or std.mem.eql(u8, a, b);
}

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


test "a value given to a Run reaches whatever asks for it" {
    const Actor = struct { agent: []const u8 };

    var run = Run.init(testing.allocator);
    defer run.deinit();

    try testing.expectError(error.NotGiven, run.resolve(Actor));

    try run.give(Actor, .{ .agent = "nightly-import" });
    try testing.expectEqualStrings("nightly-import", (try run.resolve(Actor)).agent);
}

test "giving the same type twice replaces it, because a tick has one answer" {
    const Actor = struct { agent: []const u8 };

    var run = Run.init(testing.allocator);
    defer run.deinit();

    try run.give(Actor, .{ .agent = "first" });
    try run.give(Actor, .{ .agent = "second" });

    try testing.expectEqualStrings("second", (try run.resolve(Actor)).agent);
    try testing.expectEqual(@as(usize, 1), run._given.items.len);
}

test "two given types do not answer for each other" {
    const Actor = struct { agent: []const u8 };
    const Tenant = struct { id: u32 };

    var run = Run.init(testing.allocator);
    defer run.deinit();

    try run.give(Actor, .{ .agent = "importer" });
    try run.give(Tenant, .{ .id = 7 });

    try testing.expectEqualStrings("importer", (try run.resolve(Actor)).agent);
    try testing.expectEqual(@as(u32, 7), (try run.resolve(Tenant)).id);
}

test "a value given as null is given, and not-given is neither" {
    // The three states a caller has to tell apart, and the reason this is a
    // test rather than a reading of the code: an actor that is null is the
    // ordinary case — a person, not a bot — and an actor nobody set is a bug
    // in the wiring. Collapsing the two makes every bot write look like a
    // human one, for ever, with nothing saying so
    // ([ADR 0165](../docs/adr/0165-a-value-that-reaches-the-bottom.md)).
    const Caller = struct { agent: ?u64 };

    var run = Run.init(testing.allocator);
    defer run.deinit();

    // 1. Nobody gave one.
    try testing.expectError(error.NotGiven, run.resolve(Caller));

    // 2. Given, holding null. A value, not an error.
    try run.give(Caller, .{ .agent = null });
    try testing.expectEqual(@as(?u64, null), (try run.resolve(Caller)).agent);

    // 3. Given, holding something.
    try run.give(Caller, .{ .agent = 7 });
    try testing.expectEqual(@as(?u64, 7), (try run.resolve(Caller)).agent);
}

test "an optional given as null is still given" {
    // The same distinction where the optional is the whole value rather than
    // a field of it, because that is the shape somebody reaches for first.
    var run = Run.init(testing.allocator);
    defer run.deinit();

    try testing.expectError(error.NotGiven, run.resolve(?u64));

    try run.give(?u64, null);
    try testing.expectEqual(@as(?u64, null), try run.resolve(?u64));
}

test "what a tick was given goes when the tick does" {
    const Actor = struct { agent: []const u8 };

    var run = Run.init(testing.allocator);
    defer run.deinit();

    try run.give(Actor, .{ .agent = "first tick" });
    run.reset();

    // Not the previous tick's actor, which is the answer that would be
    // wrong rather than merely absent.
    try testing.expectError(error.NotGiven, run.resolve(Actor));
}

test "a Run with no Io fills no buffer and says why" {
    var run = Run.init(testing.allocator);
    defer run.deinit();

    var buf: [10]u8 = undefined;
    try testing.expectError(error.NoIo, run.entropyInto(&buf));
}

test "an erased Scope is still a Scope, and hands out the memory of the one it wraps" {
    var run = Run.init(testing.allocator);
    defer run.deinit();

    // The property the whole type exists for: what `db.select` asks of a Scope
    // is asked of this one too, so a function written against `anytype` takes
    // it without knowing it was erased.
    check(*AnyScope, "a test");

    var erased = AnyScope.of(&run);
    const copied = try erased.arena().dupe(u8, "wati");
    const text = erased.str(copied);
    try testing.expectEqualStrings("wati", text.view());

    // And it is the *same* arena, not one of its own — the pointer the erasure
    // holds is the Run's.
    try testing.expect(erased.arena().ptr == run.arena().ptr);
}

test "text stamped through an erased Scope goes stale when the tick ends" {
    if (!str_mod.trap_enabled) return;
    var run = Run.init(testing.allocator);
    defer run.deinit();

    var erased = AnyScope.of(&run);
    const text = erased.str(try erased.arena().dupe(u8, "this tick"));
    try testing.expect(text.alive());
    // Stamped by the Run through the vtable, so the Run's own reset is what
    // ends it. An erasure that quietly stamped nothing would pass every test
    // that only reads the bytes, which is why this one asks the trap.
    run.reset();
    try testing.expect(!text.alive());
}

test "an erased Scope mints a key, which is what a reaction needs and a query does not" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var run = Run.initIo(testing.allocator, threaded.io());
    defer run.deinit();

    var erased = AnyScope.of(&run);
    const first = try erased.entropy(10);
    const second = try erased.entropy(10);
    try testing.expect(!std.mem.eql(u8, &first, &second));

    // The width a vtable could not have named, which is why the table carries
    // `entropyInto` and `entropy` is written on top of it here.
    var wanted: usize = 32;
    _ = &wanted;
    const buf = try erased.arena().alloc(u8, wanted);
    @memset(buf, 0);
    try erased.entropyInto(buf);
    var all_zero = true;
    for (buf) |b| {
        if (b != 0) all_zero = false;
    }
    try testing.expect(!all_zero);

    // And a Run with no Io says so through the erasure exactly as it does
    // without one.
    var without = Run.init(testing.allocator);
    defer without.deinit();
    var blind = AnyScope.of(&without);
    try testing.expectError(error.NoIo, blind.entropy(10));
}

test "a callback stored as a function pointer runs under whichever Scope it is handed" {
    // This is the shape the type was built for, written out: one function
    // pointer, two Scopes, and no generic anywhere. Before this it was fifty
    // lines of vtable per caller (ADR 0177).
    const Reaction = *const fn (scope: *AnyScope, note: []const u8) anyerror!Str;
    const react: Reaction = struct {
        fn run(scope: *AnyScope, note: []const u8) anyerror!Str {
            const kept = try scope.arena().dupe(u8, note);
            return scope.str(kept);
        }
    }.run;

    var first = Run.init(testing.allocator);
    defer first.deinit();
    var second = Run.init(testing.allocator);
    defer second.deinit();

    var a = AnyScope.of(&first);
    var b = AnyScope.of(&second);
    try testing.expectEqualStrings("in the first", (try react(&a, "in the first")).view());
    try testing.expectEqualStrings("in the second", (try react(&b, "in the second")).view());

    // Two Scopes, two lifetimes, and the erasure kept them apart: ending one
    // tick leaves the other's text alive.
    if (!str_mod.trap_enabled) return;
    const held = try react(&b, "still here");
    first.reset();
    try testing.expect(held.alive());
}

test "entropyInto is the same bytes as entropy, at a width nobody said while compiling" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var run = Run.initIo(testing.allocator, threaded.io());
    defer run.deinit();

    // The width a vtable could not have named: read from a value, not a
    // literal, which is the whole of what this spelling buys.
    var wanted: usize = 32;
    _ = &wanted;
    const buf = try run.arena().alloc(u8, wanted);
    @memset(buf, 0);
    try run.entropyInto(buf);

    var all_zero = true;
    for (buf) |b| {
        if (b != 0) all_zero = false;
    }
    try testing.expect(!all_zero);
}
