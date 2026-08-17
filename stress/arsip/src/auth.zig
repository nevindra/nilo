//! Signing up, signing in, and who the request is.
//!
//! The claim under test in this file is narrow and is the whole reason M2 exists:
//! **M1 authenticated on an `X-Operator:` header, and turning that into a real
//! sealed-cookie session with an argon2id password behind it should change
//! `authenticate` and nothing else.** Every handler in `handlers.zig` and
//! `intake.zig` still takes an `Operator` or a `Curator` and none of them was
//! touched. Whether that held is in `DX.md`.
//!
//! Three things here are nilo's opinion rather than mine, and each has a comment
//! at the point it bites:
//!
//! - the session is **sealed into the cookie**, so nothing is kept server-side
//!   and a session cannot be revoked (ADR 0035);
//! - a session may hold no slice, because a browser drops an oversized cookie
//!   silently — so the name is a `[24]u8`, not a `[]const u8`;
//! - hashing goes through the `Ctx`, never through `nilo_pw` directly.

const std = @import("std");
const nilo = @import("nilo_http");
const pw = @import("nilo_pw");
const uuid = @import("nilo_id");

const Accounts = @import("accounts.zig").Accounts;
const accounts_mod = @import("accounts.zig");
const Settings = @import("settings.zig").Settings;

const fail = nilo.fail;
const Str = nilo.Str;
const Allocator = std.mem.Allocator;

/// What the cookie carries. **No slice**: `name: []const u8` is a compile error,
/// and the reason is not difficulty — a browser drops an oversized cookie
/// *silently*, so the size has to be checkable, and a size that depends on the
/// data is a size nobody checked (guide/sessions.md).
///
/// So the display name is a fixed array, and everything else is an id to look up.
/// The session goes up the wire on every request, static files included.
pub const Signed = struct {
    /// `i64` since M3, because a key is what the database says it is and
    /// arguing with that costs a cast at every boundary instead of one field.
    account: i64,
    curator: bool = false,
    /// Padded with spaces, because a `[24]u8` has no length. `nameOf` trims.
    name: [24]u8 = @splat(' '),
};

/// **By pointer, and that is not style.** Written `nameOf(signed: Signed)` this
/// returns a slice into a by-value parameter, which Zig is free to pass as a
/// pointer to the caller's temporary — so the slice dangles the moment the
/// function returns, and the test below came back `Sri  ahyuni ????|@?` in Debug.
/// Nothing about it is nilo's doing; it is what a fixed array inside a value
/// costs, and it is the second-order price of "a session may hold no slice".
pub fn nameOf(signed: *const Signed) []const u8 {
    return std.mem.trimEnd(u8, &signed.name, " ");
}

fn packName(text: []const u8) [24]u8 {
    var out: [24]u8 = @splat(' ');
    const take = @min(text.len, out.len);
    @memcpy(out[0..take], text[0..take]);
    return out;
}

// ---- who the request is ----

/// Unchanged from M1 in every way that matters to a handler: same type, same two
/// fields, same `nilo_resolve` declaration. Only the body of `authenticate`
/// below moved from a header to a sealed cookie.
pub const Operator = struct {
    pub const nilo_resolve = authenticate;

    name: Str,
    curator: bool,
};

fn authenticate(c: *nilo.Ctx, s: nilo.Session(Signed), arena: Allocator) !Operator {
    const signed = s.get() orelse
        return fail.unauthorized("sign in at POST /v1/sign-in first", .{});

    // The session's bytes are a fixed array inside a value that is about to go
    // away, so the name is copied into the request arena rather than pointed at
    // — and then stamped with the request's lifetime by `c.str`, which is what
    // makes the Debug staleness trap watch it. `Str.static` would have compiled
    // and quietly opted out of the trap; it is for literals in tests.
    const name = try arena.dupe(u8, nameOf(&signed));
    return .{ .name = c.str(name), .curator = signed.curator };
}

/// A resolved value built out of **another resolved value** rather than out of a
/// second copy of the auth code. Both are worked out once per request, whichever
/// route or middleware asks first — so the cookie is decrypted once even though
/// the prefix guard and the handler both want it.
pub const Curator = struct {
    pub const nilo_resolve = onlyCurators;

    name: Str,
};

fn onlyCurators(operator: Operator) !Curator {
    if (!operator.curator) return fail.forbidden(
        "only a curator can do that, and {s} is not one",
        .{operator.name.view()},
    );
    return .{ .name = operator.name };
}

/// A prefix guard. A resolved value alone is the wrong tool for securing a
/// prefix — only routes that name one get it, so a handler that forgets the
/// argument is simply not authenticated.
pub fn requireOperator(c: *nilo.Ctx, next: nilo.Next) !void {
    _ = try c.resolve(Operator);
    try next.run(c);
}

pub fn requireCurator(c: *nilo.Ctx, next: nilo.Next) !void {
    _ = try c.resolve(Curator);
    try next.run(c);
}

/// The same guard, with the two routes that cannot be behind it let through.
///
/// **This function is the shape of item 13 in `DX.md` and is the one piece of
/// arsip written to suit the framework rather than the API.** nilo has `use` and
/// `useOn(prefix, mw)`; it has nothing that says *this prefix except these
/// paths*. But signing in is under `/v1` like everything else and cannot require
/// a session to create one, so the exception has to be expressed somewhere, and
/// the only place left is a path comparison inside the middleware.
///
/// Two consequences worth naming, because they are what a second user pays too:
///
/// - the exception is a **string** compared against `c.path()`, in a framework
///   whose whole claim is that the compiler checks the contract. Rename the
///   route and the guard silently starts protecting a 404 while the real
///   sign-up goes unguarded — nothing fails to compile;
/// - `prefix` is a comptime argument because a `Middleware` is a bare
///   `*const fn (*Ctx, Next) anyerror!void` with nowhere to keep state, *and*
///   because a `Group` does not publish the prefix it was built with. `mount(g)`
///   cannot ask `g` where it is mounted, so the prefix travels beside it.
///
/// `open_routes` below is one list feeding both `mountOpen` and this, which is
/// the most that can be done from out here: adding a third open route cannot be
/// half-done, even though nothing stops it being mistyped.
pub fn guardOperator(comptime prefix: []const u8) nilo.Middleware {
    return struct {
        fn run(c: *nilo.Ctx, next: nilo.Next) anyerror!void {
            const here = c.path().view();
            inline for (open_routes) |open| {
                if (std.mem.eql(u8, here, prefix ++ open[0])) return next.run(c);
            }
            _ = try c.resolve(Operator);
            try next.run(c);
        }
    }.run;
}

// ---- signing up ----

const SignUp = struct {
    email: Str,
    name: Str,
    password: Str,
};

/// The `*Ctx` is here for `hashPassword` and `entropy`, not for writing the
/// answer — so the API description still describes this endpoint.
fn signUp(
    c: *nilo.Ctx,
    store: *Accounts,
    limits: *const Settings,
    s: nilo.Session(Signed),
    arena: Allocator,
    form: nilo.Bound(SignUp),
) !nilo.Status(201, accounts_mod.Profile) {
    // `c` where M2 passed an `arena`. That is the whole of what M3 changed in
    // this file: the store's methods take a **Scope** rather than an allocator,
    // because a query needs somewhere to put its rows *and* a lifetime to stamp
    // its `Str`s with, and a `*Ctx` is both.
    const first = (try store.count(c)) == 0;
    if (!limits.open_signup and !first)
        return fail.forbidden("this archive is not taking new accounts", .{});

    const incoming = form.value() orelse return form.fail();
    if (incoming.password.len() < 10) return fail.unprocessable(
        "a password wants at least 10 characters; that one has {d}",
        .{incoming.password.len()},
    );
    if (std.mem.indexOfScalar(u8, incoming.email.view(), '@') == null)
        return fail.unprocessable("\"email\" does not look like an address", .{});

    // `pw.huge_pages` rather than the request arena: 19 MiB through an arena
    // that is reset per request spends the one budget nilo treats as an
    // invariant, and the huge-page allocator is 11.0 ms a hash against 13.6
    // (ADR 0049).
    // `.view()`, because `hashPassword` takes a `[]const u8`. The worked example
    // in `guide/sessions.md`, `docs/reference.md` and `ctx.zig`'s own doc comment
    // all pass a `Str` straight in and do not compile. Item 11 in `DX.md`.
    const stored = try c.hashPassword(pw.huge_pages, incoming.password.view());

    // A v7 rather than a v4: sortable, so the first six bytes say when the
    // account was made and a listing comes back in order for free. The entropy
    // is an argument because a bottom-layer module has no Bulkhead to reach
    // through — inside a request that is `c.entropy` (ADR 0046).
    // The `@intCast` is not decoration: `nilo.nowMillis()` answers an `i64` and
    // `v7` takes a `u64`. The reference's own one-line example for this module
    // hands one straight to the other and does not compile. Item 11 in `DX.md`.
    const now: u64 = @intCast(nilo.nowMillis());
    const public = uuid.v7(try c.entropy(uuid.Uuid.v7_entropy), now);

    const made = try store.add(
        c,
        public,
        incoming.email.view(),
        incoming.name.view(),
        stored.text(),
        first, // whoever gets there first is the curator
    ) orelse return fail.conflict("that address already has an account", .{});
    _ = arena;

    try s.set(.{
        .account = made.id,
        .curator = made.curator,
        .name = packName(made.name.view()),
    });
    return .{ .value = accounts_mod.profileOf(made) };
}

// ---- signing in ----

const SignIn = struct {
    email: Str,
    password: Str,
};

fn signIn(
    c: *nilo.Ctx,
    store: *Accounts,
    s: nilo.Session(Signed),
    form: SignIn,
) !accounts_mod.Profile {
    const row = try store.find(c, form.email.view());

    // **`stored` is optional and null is the point.** A sign-in for an address
    // with no account has no hash to check, and returning early there answers in
    // a millisecond instead of thirty — which turns this form into a query for
    // which addresses are registered. Passing null does the work anyway and
    // answers false (ADR 0049).
    const ok = try c.verifyPassword(
        pw.huge_pages,
        if (row) |r| r.password.view() else null,
        form.password.view(),
    );
    if (!ok) return fail.unauthorized("that is not a sign-in", .{});

    const account = row.?;

    // The one moment the plaintext is in hand, so the only place a row written
    // at an older Cost can be written forward.
    if (try pw.needsRehash(account.password.view(), .default)) {
        const fresh = try c.hashPassword(pw.huge_pages, form.password.view());
        try store.rehash(c, account.id, fresh.text());
    }

    try s.set(.{
        .account = account.id,
        .curator = account.curator,
        .name = packName(account.name.view()),
    });
    return accounts_mod.profileOf(account);
}

fn signOut(s: nilo.Session(Signed)) !nilo.Status(204, void) {
    // Deletes the cookie in *this* browser. A sealed cookie somebody copied
    // still opens until it expires — there is no "sign out everywhere" in the
    // mechanism, and pretending otherwise would be the dangerous part.
    try s.clear();
    return .{};
}

fn whoami(operator: Operator) accounts_mod.Profile {
    // Deliberately built from the session alone: no store lookup, because the
    // whole point of putting the name in the cookie is not needing one.
    return .{
        .public = uuid.Uuid.nil,
        .email = "",
        .name = operator.name.view(),
        .curator = operator.curator,
    };
}

// ---- wiring ----

/// The routes no session can be required for, as data rather than as two calls,
/// so `guardOperator` above can skip exactly the set that `mountOpen` registers.
const open_routes = .{
    .{ "/sign-up", signUp },
    .{ "/sign-in", signIn },
};

/// Registered on the same group the guard sits on. Mounting order is irrelevant
/// — nilo resolves chains in `listen()`, so "register the open ones first" is not
/// a thing that works and it took a failing test to find that out.
pub fn mountOpen(g: anytype) !void {
    inline for (open_routes) |open| try g.post(open[0], open[1]);
}

pub fn mountSigned(g: anytype) !void {
    try g.post("/sign-out", signOut);
    try g.get("/whoami", whoami);
}

// ---- tests ----

const testing = std.testing;

test "a name longer than the session holds is cut rather than refused" {
    const long: Signed = .{ .account = 1, .name = packName("Sri Wahyuningsih Kusumaningrum Dewi") };
    try testing.expectEqual(@as(usize, 24), long.name.len);
    try testing.expectEqualStrings("Sri Wahyuningsih Kusuman", nameOf(&long));
}

test "a short name round-trips through the fixed array" {
    // A named local rather than an anonymous literal, because `nameOf` hands back
    // a slice into whatever it was given — see its doc comment.
    const wati: Signed = .{ .account = 1, .name = packName("Wati") };
    const nameless: Signed = .{ .account = 1 };
    try testing.expectEqualStrings("Wati", nameOf(&wati));
    try testing.expectEqualStrings("", nameOf(&nameless));
}

test "a session is a value, so a handler that reads one is an ordinary function" {
    // No request, no cookie, no server.
    const seen = whoami(.{ .name = .static("bu-sri"), .curator = true });
    try testing.expectEqualStrings("bu-sri", seen.name);
    try testing.expect(seen.curator);
}

test "a curator is worked out from an operator, not from a second header read" {
    try testing.expectError(error.Failed, onlyCurators(.{ .name = .static("wati"), .curator = false }));
    const c = try onlyCurators(.{ .name = .static("bu-sri"), .curator = true });
    try testing.expectEqualStrings("bu-sri", c.name.view());
}

test "the session struct fits a cookie, which is a thing the compiler checks" {
    // `Session(T)` refuses a `T` past about 4 KB at compile time, and refuses a
    // slice field outright. This asserts the shape rather than the refusal —
    // the refusal is in `wrong/`.
    try testing.expect(@sizeOf(Signed) <= 64);
    try testing.expectEqual(@as(usize, 24), @typeInfo(@FieldType(Signed, "name")).array.len);
}
