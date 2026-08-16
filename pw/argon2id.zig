//! Argon2id, and the PHC string it is stored as.
//!
//! Everything here is a pure function of its arguments. The salt is one of
//! them for the reason `nilo_id` takes entropy as one (ADR 0042): entropy
//! comes from the operating system, and a module in this layer has no
//! Bulkhead to ask through. So is the allocator, because one hash asks for
//! **19 MiB** and a number that size is not something a framework hides
//! (ADR 0048).
//!
//! ## The Io that is not one
//!
//! `std.crypto.pwhash.argon2` in Zig 0.16 takes a `std.Io`, which is exactly
//! what a module with no event loop does not have. It is used for two things:
//! `io.random` for the salt, which this module does not go through because
//! the salt arrives as an argument, and lane parallelism when `p > 1`.
//!
//! `std.Io.Threaded.init_single_threaded` is the answer, and it is a real one
//! rather than a dodge: a comptime constant, 864 bytes, copied onto the stack
//! per call. `.allocator = .failing`, `.async_limit = .nothing`,
//! `.have_signal_handler = false` — it spawns nothing and installs nothing,
//! and `group.async` on it runs each lane inline. Measured against a real
//! `std.Io.Threaded` at p = 1, 2, 4 and 8, it agrees byte for byte; the test
//! at the bottom of this file is that comparison for the two that matter.
//!
//! That is what lets `verify` read a hash somebody else's library wrote at
//! `p = 8` — sequentially, and correctly — without this module ever holding a
//! runtime.

const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;
const phc = std.crypto.pwhash.phc_format;

/// Bytes of salt the caller brings. Sixteen is what RFC 9106 recommends and
/// twice what it requires.
pub const salt_len = 16;

/// Bytes of hash stored. Thirty-two, which is what everybody else writes and
/// therefore what a hash of nilo's can be migrated off to.
pub const hash_len = 32;

/// How much work one hash is: memory, passes, lanes.
///
/// A struct rather than three arguments because it is chosen once for an
/// application and then never mentioned again, and because a floor can be
/// checked against one thing (ADR 0048).
pub const Cost = struct {
    /// Kibibytes of memory. The axis that costs an attacker with a GPU.
    memory_kib: u32,
    /// Passes over that memory.
    passes: u32,
    /// Lanes. nilo writes 1 and reads whatever it is given.
    lanes: u24 = 1,

    /// OWASP's first recommendation, and what `hash` uses when it is not told
    /// otherwise: 19 MiB, two passes, one lane. Measured at **13.3 ms** on a
    /// 16-core desktop (ADR 0048).
    pub const default: Cost = .{ .memory_kib = 19 * 1024, .passes = 2 };

    /// The weakest configuration OWASP still publishes — 7 MiB and five
    /// passes — and therefore the floor below which this module refuses to
    /// compile. Weakening the cost to make a test suite fast is the mistake
    /// this is here to stop, because it is invisible afterwards.
    pub const floor_memory_kib = 7 * 1024;

    fn params(comptime self: Cost) argon2.Params {
        return .{ .t = self.passes, .m = self.memory_kib, .p = self.lanes };
    }
};

/// What one hash will ask the allocator for, so a caller can size a pool or
/// simply know the number. Argon2 allocates one block list and nothing else.
pub fn bytesFor(comptime cost: Cost) usize {
    const sync_points = 4;
    const p = @as(u32, cost.lanes);
    const memory = @max(
        cost.memory_kib / (sync_points * p) * (sync_points * p),
        2 * sync_points * p,
    );
    return @as(usize, memory) * 1024;
}

/// The longest PHC string any allowed Cost can produce, worked out by asking
/// the encoder about the widest one rather than guessing at it: every
/// parameter at its maximum, and a salt and digest at the longest this module
/// will ever write.
pub const max_text = phc.calcSize(Encoded{
    .alg_id = "argon2id",
    .alg_version = 19,
    .m = std.math.maxInt(u32),
    .t = std.math.maxInt(u32),
    .p = std.math.maxInt(u24),
    .salt = phc.BinValue(64).fromSlice(&([_]u8{0} ** salt_len)) catch unreachable,
    .hash = phc.BinValue(64).fromSlice(&([_]u8{0} ** hash_len)) catch unreachable,
});

/// A stored password hash: the PHC string, held inline.
///
/// By value and not a slice, for the reason `Uuid.text()` answers a `[36]u8`
/// — there is nothing to free, nothing to outlive the request, and it goes
/// straight into an insert. It is the format everybody else writes
/// (`$argon2id$v=19$m=19456,t=2,p=1$…`), which is the only reason to have a
/// format at all: a hash nobody else can read is a hash nobody can migrate
/// off.
pub const Hash = struct {
    _text: [max_text]u8,
    _len: u16,

    /// The PHC string. Points into this Hash, so a caller holding the text
    /// has to hold the Hash.
    pub fn text(self: *const Hash) []const u8 {
        return self._text[0..self._len];
    }
};

/// The field order `std.crypto.pwhash.phc_format` reads and writes. It is
/// argon2's own `PhcFormatHasher.HashResult`, which is private, so this is
/// the one piece of that file this module keeps a copy of.
const Encoded = struct {
    alg_id: []const u8,
    alg_version: ?u32,
    m: u32,
    t: u32,
    p: u24,
    salt: phc.BinValue(64),
    hash: phc.BinValue(64),
};

pub const Error = error{
    /// The stored string is not a PHC-encoded argon2id hash.
    NotAHash,
    /// The machine could not find 19 MiB.
    OutOfMemory,
};

/// An `Io` that never runs anything concurrently, on the stack of whoever
/// asked. See this file's header for why this is sound rather than lucky.
inline fn loneIo(t: *std.Io.Threaded) std.Io {
    t.* = .init_single_threaded;
    return t.io();
}

/// Hash a password at the default Cost.
///
/// The error set is one member wide on purpose: `NotAHash` is something only
/// a *stored* string can be, so a caller that hashes has one thing to handle
/// and no impossible arm to write.
pub fn hash(
    gpa: std.mem.Allocator,
    password: []const u8,
    salt: [salt_len]u8,
) error{OutOfMemory}!Hash {
    return hashWith(.default, gpa, password, salt);
}

/// The same, at a Cost of the caller's own. A Cost below the floor is a
/// Refusal rather than a weak hash nobody notices.
pub fn hashWith(
    comptime cost: Cost,
    gpa: std.mem.Allocator,
    password: []const u8,
    salt: [salt_len]u8,
) error{OutOfMemory}!Hash {
    comptime checkCost(cost);

    var threaded: std.Io.Threaded = undefined;
    const io = loneIo(&threaded);

    var digest: [hash_len]u8 = undefined;
    argon2.kdf(gpa, &digest, password, &salt, comptime cost.params(), .argon2id, io) catch |err|
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            // Every other member of the set is a parameter `checkCost` has
            // already refused — a Cost too small, no passes, no lanes, more
            // lanes than memory — or a cancellation this Io cannot produce.
            // The salt and the digest are this module's own constants and
            // both are inside argon2's bounds. What is left is a password of
            // more than 4 GiB, which is not a password; `max_body` bounds a
            // request's at one MiB.
            else => unreachable,
        };

    var out: Hash = .{ ._text = undefined, ._len = 0 };
    const written = phc.serialize(Encoded{
        .alg_id = "argon2id",
        .alg_version = 19,
        .m = cost.memory_kib,
        .t = cost.passes,
        .p = cost.lanes,
        .salt = phc.BinValue(64).fromSlice(&salt) catch unreachable,
        .hash = phc.BinValue(64).fromSlice(&digest) catch unreachable,
    }, &out._text) catch unreachable;
    out._len = @intCast(written.len);
    return out;
}

/// Whether `password` is the one `stored` was made from.
///
/// **`stored` is optional, and null is the whole point.** A sign-in where no
/// such account exists has no hash to check, and returning early there is
/// what turns a login form into a list of which addresses are registered: the
/// answer comes back in a millisecond instead of thirteen. Passing null does
/// the work anyway, against a hash of nothing, and answers false (ADR 0048).
/// There is no way to write the fast wrong version.
pub fn verify(gpa: std.mem.Allocator, stored: ?[]const u8, password: []const u8) Error!bool {
    return verifyWith(.default, gpa, stored, password);
}

/// The same, telling it what a hash of yours costs.
///
/// **The Cost is what the no-account path is timed against**, and that is the
/// whole of what this argument is for: `verify` does the work of a hash when
/// there is nothing to check, and work at 19 MiB against a deployment that
/// stores 46 MiB hashes is a stopwatch away from being the same early return
/// the optional exists to make impossible. Pass the Cost you hash with
/// (ADR 0049).
///
/// A stored hash is checked at the parameters *it* carries either way — that
/// is what makes an old hash still readable after the Cost goes up.
pub fn verifyWith(
    comptime cost: Cost,
    gpa: std.mem.Allocator,
    stored: ?[]const u8,
    password: []const u8,
) Error!bool {
    const encoded = stored orelse {
        _ = try decoy(cost, gpa);
        return false;
    };

    const parsed = try parse(encoded);

    const expected = parsed.hash.constSlice();
    if (expected.len < 4 or expected.len > 64) return error.NotAHash;

    var threaded: std.Io.Threaded = undefined;
    const io = loneIo(&threaded);

    var digest: [64]u8 = undefined;
    const got = digest[0..expected.len];
    argon2.kdf(
        gpa,
        got,
        password,
        parsed.salt.constSlice(),
        .{ .t = parsed.t, .m = parsed.m, .p = parsed.p },
        .argon2id,
        io,
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // A stored hash whose parameters argon2 will not accept — a salt
        // under 8 bytes, a `m` too small for its `p`. It is not a hash this
        // module can check, which is the same answer as malformed.
        else => error.NotAHash,
    };

    return sameBytes(got, expected);
}

/// Whether two digests of equal length are the same, in time that does not
/// depend on where they first differ.
///
/// `std.crypto.timing_safe.eql` wants a length settled while compiling and a
/// stored digest's is not — it is whatever the string said, between 4 and 64.
/// So the loop is here, and it has no early exit on purpose: `std.mem.eql`
/// returns at the first differing byte, which tells whoever is guessing how
/// many leading bytes they have right.
fn sameBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var differing: u8 = 0;
    for (a, b) |x, y| differing |= x ^ y;
    return differing == 0;
}

/// Whether a stored hash is weaker than one made now would be, so that the
/// one moment the plaintext is in hand — the sign-in that just succeeded —
/// is the moment it gets written again at the Cost in force.
///
/// ```zig
/// if (!try pw.verify(gpa, stored, form.password)) return nilo.fail(401, "…");
/// if (try pw.needsRehash(stored.?, .default)) {
///     const fresh = try c.hashPassword(pw.huge_pages, form.password);
///     _ = try db.update(User, c, .{
///         .set = .{ .password = fresh.text() },
///         .where = .{ .id = user.id },
///     });
/// }
/// ```
///
/// Weaker means *less work or less to guess against*: fewer kibibytes, fewer
/// passes, a shorter salt or a shorter digest. Lanes are not in it — a hash
/// somebody else's library made at `p = 4` is the same work as one at `p = 1`,
/// and rewriting every row for it would be churn rather than an upgrade.
///
/// A string that is not an argon2id hash answers `NotAHash` rather than
/// true, for the reason `verify` does: a hash the module cannot read is the
/// database's problem, and re-hashing on the strength of it would write the
/// password back over a row nobody has explained yet.
pub fn needsRehash(stored: []const u8, comptime cost: Cost) Error!bool {
    comptime checkCost(cost);

    const parsed = try parse(stored);
    return parsed.m < cost.memory_kib or
        parsed.t < cost.passes or
        parsed.salt.constSlice().len < salt_len or
        parsed.hash.constSlice().len < hash_len;
}

/// The PHC string, read and checked as far as this module can check it
/// without doing the work. Shared by `verifyWith` and `needsRehash` so that
/// what counts as a hash is one answer rather than two.
fn parse(stored: []const u8) Error!Encoded {
    const parsed = phc.deserialize(Encoded, stored) catch return error.NotAHash;
    if (!std.mem.eql(u8, parsed.alg_id, "argon2id")) return error.NotAHash;
    if (parsed.alg_version) |v| {
        if (v != 19) return error.NotAHash;
    }
    if (parsed.t < 1 or parsed.p < 1 or parsed.m < 8) return error.NotAHash;
    return parsed;
}

/// The work `verify` does when there is no account: a hash of a fixed
/// password at the Cost the caller hashes with, so the two paths cost the
/// same.
///
/// The salt is a constant rather than entropy, which is the one place that is
/// safe: nothing is stored, nothing is compared, and the only property wanted
/// is that it takes as long.
fn decoy(comptime cost: Cost, gpa: std.mem.Allocator) Error!Hash {
    return hashWith(cost, gpa, "nilo has no account under that name", @splat(0x5a));
}

fn checkCost(comptime cost: Cost) void {
    if (cost.memory_kib < Cost.floor_memory_kib) @compileError(std.fmt.comptimePrint(
        "nilo: a password Cost of {d} KiB of memory is below the floor of {d} KiB.\n" ++
            "  That is weaker than the weakest configuration OWASP publishes, and a\n" ++
            "  hash made with it looks exactly like one that is not.\n" ++
            "  Make the test suite fast some other way.",
        .{ cost.memory_kib, Cost.floor_memory_kib },
    ));
    if (cost.passes < 1) @compileError(
        "nilo: a password Cost with no passes is not a hash.\n" ++
            "  `.passes` counts the times argon2id goes over its memory, and it has to be at least 1.",
    );
    if (cost.lanes < 1) @compileError(
        "nilo: a password Cost with no lanes cannot be computed.\n" ++
            "  `.lanes` is argon2id's parallelism and it has to be at least 1. nilo writes 1.",
    );
    // The last parameter argon2 checks for itself, and the one that decides
    // whether the `unreachable` in `hashWith` is sound: a lane needs eight
    // kibibytes to divide its memory into segments, so `.lanes` above
    // `.memory_kib / 8` is a hash that cannot be computed. Refused here, at
    // the one moment somebody is reading the Cost they wrote.
    if (cost.memory_kib / 8 < cost.lanes) @compileError(std.fmt.comptimePrint(
        "nilo: a password Cost of {d} lanes needs at least {d} KiB of memory, and it has {d}.\n" ++
            "  argon2id divides its memory into four segments per lane and each one has to\n" ++
            "  hold two blocks, so a lane costs 8 KiB before it hashes anything.\n" ++
            "  Raise `.memory_kib` or lower `.lanes`; nilo writes 1 lane.",
        .{ cost.lanes, @as(u64, cost.lanes) * 8, cost.memory_kib },
    ));
}

const testing = std.testing;

test "a password verifies against its own hash and nothing else" {
    const gpa = testing.allocator;
    const h = try hashWith(.{ .memory_kib = 8 * 1024, .passes = 1 }, gpa, "hunter2", @splat(1));

    try testing.expect(try verify(gpa, h.text(), "hunter2"));
    try testing.expect(!try verify(gpa, h.text(), "hunter3"));
    try testing.expect(!try verify(gpa, h.text(), ""));
}

test "the stored form is the PHC string everybody else writes" {
    const gpa = testing.allocator;
    const h = try hashWith(.{ .memory_kib = 8 * 1024, .passes = 1 }, gpa, "hunter2", @splat(1));

    try testing.expect(std.mem.startsWith(u8, h.text(), "$argon2id$v=19$m=8192,t=1,p=1$"));
    // Salt and digest, base64 without padding, in that order.
    var parts = std.mem.splitScalar(u8, h.text(), '$');
    _ = parts.next();
    _ = parts.next();
    _ = parts.next();
    _ = parts.next();
    try testing.expectEqual(@as(usize, 22), parts.next().?.len);
    try testing.expectEqual(@as(usize, 43), parts.next().?.len);
    try testing.expectEqual(@as(?[]const u8, null), parts.next());
}

test "two hashes of one password differ, because the salt does" {
    const gpa = testing.allocator;
    const cost: Cost = .{ .memory_kib = 8 * 1024, .passes = 1 };
    const a = try hashWith(cost, gpa, "hunter2", @splat(1));
    const b = try hashWith(cost, gpa, "hunter2", @splat(2));

    try testing.expect(!std.mem.eql(u8, a.text(), b.text()));
    // And both still verify, which is what a salt is for.
    try testing.expect(try verify(gpa, a.text(), "hunter2"));
    try testing.expect(try verify(gpa, b.text(), "hunter2"));
}

test "no account is checked anyway, and answers false" {
    // The point is that it does the work rather than returning early. What is
    // asserted here is the answer; the timing is what ADR 0048 records.
    const cheap: Cost = .{ .memory_kib = 8 * 1024, .passes = 1 };
    try testing.expect(!try verifyWith(cheap, testing.allocator, null, "hunter2"));
}

test "the work done for an account that is not there is the work a Cost is" {
    // The claim `verifyWith` exists to keep, checked by the one thing about a
    // hash that can be observed without timing it: argon2 asks for `m` KiB
    // and nothing else, so the size of that allocation says which Cost ran.
    // Before ADR 0049 the no-account path was always `.default` — 19 MiB of
    // work against a deployment storing 8 MiB hashes, which is a stopwatch
    // away from the early return the optional exists to prevent.
    const cost: Cost = .{ .memory_kib = 8 * 1024, .passes = 1 };

    var counted: usize = 0;
    var counting = Counting{ .child = testing.allocator, .largest = &counted };
    try testing.expect(!try verifyWith(cost, counting.allocator(), null, "hunter2"));
    try testing.expectEqual(bytesFor(cost), counted);

    // And it is the same allocation a real one of that Cost makes.
    var against: usize = 0;
    var counting_real = Counting{ .child = testing.allocator, .largest = &against };
    const h = try hashWith(cost, testing.allocator, "hunter2", @splat(1));
    try testing.expect(try verifyWith(cost, counting_real.allocator(), h.text(), "hunter2"));
    try testing.expectEqual(counted, against);
}

test "a hash made at a lower Cost is one to write again" {
    const gpa = testing.allocator;
    const cheap: Cost = .{ .memory_kib = 8 * 1024, .passes = 1 };
    const dearer: Cost = .{ .memory_kib = 16 * 1024, .passes = 2 };

    const old = try hashWith(cheap, gpa, "hunter2", @splat(1));
    try testing.expect(try needsRehash(old.text(), dearer));
    // Against its own Cost it is current, which is the answer that stops a
    // sign-in rewriting a row it has no reason to.
    try testing.expect(!try needsRehash(old.text(), cheap));

    // Memory and passes are read apart: more of one does not excuse less of
    // the other.
    try testing.expect(try needsRehash(old.text(), .{ .memory_kib = 8 * 1024, .passes = 2 }));
    try testing.expect(try needsRehash(old.text(), .{ .memory_kib = 9 * 1024, .passes = 1 }));

    // A string that is not a hash is the database's problem, not a reason to
    // write a password back over it.
    try testing.expectError(error.NotAHash, needsRehash("$2b$10$abcdefghijklmnopqrstuv", cheap));
}

test "a hash somebody else made with a short salt is one to write again" {
    // Sixteen bytes of salt is what this module writes; a library that wrote
    // eight left less to guess against, and the parameters in the string are
    // where that shows.
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = loneIo(&threaded);

    const params = argon2.Params{ .t = 1, .m = 8 * 1024, .p = 1 };
    var digest: [hash_len]u8 = undefined;
    const short_salt: [8]u8 = @splat(3);
    try argon2.kdf(gpa, &digest, "hunter2", &short_salt, params, .argon2id, io);

    var buf: [max_text]u8 = undefined;
    const encoded = try phc.serialize(Encoded{
        .alg_id = "argon2id",
        .alg_version = 19,
        .m = params.m,
        .t = params.t,
        .p = params.p,
        .salt = try phc.BinValue(64).fromSlice(&short_salt),
        .hash = try phc.BinValue(64).fromSlice(&digest),
    }, &buf);

    const same_work: Cost = .{ .memory_kib = 8 * 1024, .passes = 1 };
    try testing.expect(try needsRehash(encoded, same_work));
    // It still verifies, which is the point of reading it at all.
    try testing.expect(try verifyWith(same_work, gpa, encoded, "hunter2"));
}

test "a stored string that is not a hash says so rather than answering false" {
    const gpa = testing.allocator;
    // False would be indistinguishable from a wrong password, and the two
    // want different answers: one is the user's mistake, the other is the
    // database's.
    try testing.expectError(error.NotAHash, verify(gpa, "", "hunter2"));
    try testing.expectError(error.NotAHash, verify(gpa, "hunter2", "hunter2"));
    try testing.expectError(error.NotAHash, verify(gpa, "$argon2id$", "hunter2"));
    // bcrypt's, which is the one somebody actually arrives with.
    try testing.expectError(
        error.NotAHash,
        verify(gpa, "$2b$10$abcdefghijklmnopqrstuv", "hunter2"),
    );
    // argon2i and argon2d are neither of them argon2id.
    const other = "$argon2i$v=19$m=8192,t=1,p=1$AQEBAQEBAQEBAQEBAQEBAQ$" ++
        "cHnLQZQKgLmVQGKlLGkKKGxLbGxLbGxLbGxLbGxLbGw";
    try testing.expectError(error.NotAHash, verify(gpa, other, "hunter2"));
}

test "a hash made at another parallelism is still readable" {
    // The property the lone Io buys, and the reason it is not a dodge: a hash
    // that arrived from a library defaulting to p=4 verifies here, run one
    // lane after another (ADR 0048).
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = loneIo(&threaded);

    const params = argon2.Params{ .t = 1, .m = 8 * 1024, .p = 4 };
    var digest: [hash_len]u8 = undefined;
    const salt: [salt_len]u8 = @splat(3);
    try argon2.kdf(gpa, &digest, "hunter2", &salt, params, .argon2id, io);

    var buf: [max_text]u8 = undefined;
    const encoded = try phc.serialize(Encoded{
        .alg_id = "argon2id",
        .alg_version = 19,
        .m = params.m,
        .t = params.t,
        .p = params.p,
        .salt = try phc.BinValue(64).fromSlice(&salt),
        .hash = try phc.BinValue(64).fromSlice(&digest),
    }, &buf);

    try testing.expect(try verify(gpa, encoded, "hunter2"));
    try testing.expect(!try verify(gpa, encoded, "hunter3"));
}

test "the lone Io agrees with a real one" {
    // The claim the whole module rests on, checked rather than asserted in a
    // comment. A real `std.Io.Threaded` runs the lanes on threads; the one
    // this module holds runs them inline.
    const gpa = testing.allocator;

    var real: std.Io.Threaded = .init(gpa, .{});
    defer real.deinit();

    for ([_]u24{ 1, 4 }) |lanes| {
        const params = argon2.Params{ .t = 1, .m = 8 * 1024, .p = lanes };
        const salt: [salt_len]u8 = @splat(7);

        var want: [hash_len]u8 = undefined;
        try argon2.kdf(gpa, &want, "hunter2", &salt, params, .argon2id, real.io());

        var threaded: std.Io.Threaded = undefined;
        var got: [hash_len]u8 = undefined;
        try argon2.kdf(gpa, &got, "hunter2", &salt, params, .argon2id, loneIo(&threaded));

        try testing.expectEqualSlices(u8, &want, &got);
    }
}

test "what one hash asks the allocator for is known before it is asked" {
    // The number ADR 0048 spends its argument on, and `bytesFor` is where a
    // caller reads it rather than working it out from the parameters.
    try testing.expectEqual(@as(usize, 19_922_944), bytesFor(.default));
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024), bytesFor(.{
        .memory_kib = 8 * 1024,
        .passes = 1,
    }));

    // And it is what argon2 actually takes, not a guess at it.
    var counted: usize = 0;
    var counting = Counting{ .child = testing.allocator, .largest = &counted };
    const cost: Cost = .{ .memory_kib = 8 * 1024, .passes = 1 };
    _ = try hashWith(cost, counting.allocator(), "hunter2", @splat(1));
    try testing.expectEqual(bytesFor(cost), counted);
}

/// Records the largest single allocation, for the test above.
const Counting = struct {
    child: std.mem.Allocator,
    largest: *usize,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, a, ra) orelse return null;
        self.largest.* = @max(self.largest.*, len);
        return p;
    }
    fn resize(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, a, new, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, new: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(buf, a, new, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, a, ra);
    }
};

test "the stored form fits whatever the parameters were" {
    // `max_text` is worked out from the encoder, so this is the check that
    // the arithmetic covers the widest string a Cost can produce rather than
    // the one the default happens to.
    const gpa = testing.allocator;
    const h = try hashWith(.{ .memory_kib = 8 * 1024, .passes = 1 }, gpa, "hunter2", @splat(1));
    try testing.expect(h.text().len <= max_text);
    try testing.expect(h.text().len < 100);
}
