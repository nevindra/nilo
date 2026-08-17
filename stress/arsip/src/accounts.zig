//! Who is allowed in.
//!
//! **This file does no hashing**, and that is the design rather than an
//! omission. `nilo_pw` is 19 MiB and 13 ms a call, which is *under*
//! `block_warning_ms` — so a handler calling the module straight holds its
//! thread on every sign-in and nothing in the log ever says so. The `Ctx`
//! methods park the fiber on the blocking pool and hold one of
//! `password_hashes_at_once` permits instead
//! ([ADR 0048](../../../docs/adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)).
//!
//! So the split is: `auth.zig` hashes, through the `Ctx`; this stores the PHC
//! string it produced. What lands here is text, and text is a thing a store
//! knows how to own — which is also what keeps the store callable from a test
//! with no server, no request and no 19 MiB.

const std = @import("std");
const nilo = @import("nilo_http");
const uuid = @import("nilo_id");

const Allocator = std.mem.Allocator;
const Text = []const u8;

/// What a row holds. The PHC string is a field like any other: nothing here
/// knows it is a hash, which is the property that makes a hash made elsewhere
/// verify here.
pub const Account = struct {
    id: u32,
    /// The one an API client sees. A `u32` is a row number and says how many
    /// accounts there are; a v7 says nothing and sorts by when it was made.
    public: uuid.Uuid,
    email: Text,
    name: Text,
    curator: bool,
    /// `$argon2id$v=19$m=19456,t=2,p=1$…`
    password: Text,
};

/// What goes out. The hash is not in it, and that is enforced by the type rather
/// than by remembering to leave a field out of a serialiser.
pub const Profile = struct {
    public: uuid.Uuid,
    email: Text,
    name: Text,
    curator: bool,
};

pub fn profileOf(account: Account) Profile {
    return .{
        .public = account.public,
        .email = account.email,
        .name = account.name,
        .curator = account.curator,
    };
}

const Row = struct {
    memory: std.heap.ArenaAllocator,
    value: Account,
};

pub const Accounts = struct {
    gpa: Allocator,
    lock: nilo.Mutex = .init,
    rows: std.ArrayList(*Row) = .empty,
    next_id: u32 = 1,

    pub fn init(gpa: Allocator) Accounts {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Accounts) void {
        for (self.rows.items) |row| {
            row.memory.deinit();
            self.gpa.destroy(row);
        }
        self.rows.deinit(self.gpa);
    }

    /// `password` is the PHC string somebody else produced. An email already in
    /// use is `null` rather than an error: whether that is a 409 or a
    /// deliberately vague answer is the handler's decision, not the store's.
    ///
    /// `into` is where the returned copy comes from, and it is the *caller's*
    /// allocator for the same reason it is in `find` and `byId`: inside a request
    /// that is the arena, which is reset when the request ends and needs no
    /// `free`. Written the obvious way — copying out onto `self.gpa` — this leaked
    /// three allocations per sign-up, and the store's own tests did not catch it
    /// because they free by hand. The wire tests did, on the first run.
    pub fn add(
        self: *Accounts,
        into: Allocator,
        public: uuid.Uuid,
        email: Text,
        name: Text,
        password: Text,
        curator: bool,
    ) !?Account {
        try self.lock.lock();
        defer self.lock.unlock();

        if (self.rowFor(email) != null) return null;

        const row = try self.gpa.create(Row);
        row.* = .{ .memory = .init(self.gpa), .value = undefined };
        errdefer {
            row.memory.deinit();
            self.gpa.destroy(row);
        }

        const mine = row.memory.allocator();
        row.value = .{
            .id = self.next_id,
            .public = public,
            .email = try lowered(mine, email),
            .name = try mine.dupe(u8, name),
            .curator = curator,
            .password = try mine.dupe(u8, password),
        };

        try self.rows.append(self.gpa, row);
        self.next_id += 1;
        return try copyOut(into, row.value);
    }

    /// The hash comes back with it, because the caller is about to verify a
    /// password against it. `null` means no such account, and passing that
    /// straight to `c.verifyPassword` is the point — see `auth.zig`.
    pub fn find(self: *Accounts, into: Allocator, email: Text) !?Account {
        try self.lock.lock();
        defer self.lock.unlock();
        const row = self.rowFor(email) orelse return null;
        return try copyOut(into, row.value);
    }

    pub fn byId(self: *Accounts, into: Allocator, id: u32) !?Account {
        try self.lock.lock();
        defer self.lock.unlock();
        for (self.rows.items) |row| {
            if (row.value.id == id) return try copyOut(into, row.value);
        }
        return null;
    }

    pub fn count(self: *Accounts) !usize {
        try self.lock.lock();
        defer self.lock.unlock();
        return self.rows.items.len;
    }

    /// Written forward when a sign-in succeeds and the Cost has gone up since —
    /// the one moment the plaintext is in hand.
    pub fn rehash(self: *Accounts, id: u32, password: Text) !void {
        try self.lock.lock();
        defer self.lock.unlock();

        for (self.rows.items) |row| {
            if (row.value.id != id) continue;
            // The new string is allocated before the old one is forgotten, so a
            // failure leaves the row able to verify what it could before.
            row.value.password = try row.memory.allocator().dupe(u8, password);
            return;
        }
    }

    fn rowFor(self: *Accounts, email: Text) ?*Row {
        for (self.rows.items) |row| {
            if (std.ascii.eqlIgnoreCase(row.value.email, email)) return row;
        }
        return null;
    }
};

fn lowered(gpa: Allocator, text: Text) !Text {
    const out = try gpa.alloc(u8, text.len);
    for (out, text) |*dst, ch| dst.* = std.ascii.toLower(ch);
    return out;
}

fn copyOut(gpa: Allocator, account: Account) !Account {
    return .{
        .id = account.id,
        .public = account.public,
        .email = try gpa.dupe(u8, account.email),
        .name = try gpa.dupe(u8, account.name),
        .curator = account.curator,
        .password = try gpa.dupe(u8, account.password),
    };
}

// ---- tests ----

const testing = std.testing;

/// A v4 out of a seeded PRNG. Fine here and a session token anybody can predict
/// in production — the reference says so, and nothing in `nilo_id` can tell the
/// difference, because the randomness is an argument (ADR 0046).
fn testId(seed: u64) uuid.Uuid {
    var prng: std.Random.DefaultPrng = .init(seed);
    var bytes: [uuid.Uuid.v4_entropy]u8 = undefined;
    prng.random().bytes(&bytes);
    return uuid.v4(bytes);
}

test "an email is matched without regard to case, and stored lowered" {
    var store: Accounts = .init(testing.allocator);
    defer store.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const made = (try store.add(arena, testId(1), "Wati@Example.Dev", "Wati", "$argon2id$fake", false)).?;
    try testing.expectEqualStrings("wati@example.dev", made.email);

    const found = (try store.find(arena, "WATI@EXAMPLE.DEV")).?;
    try testing.expectEqual(made.id, found.id);
}

test "an email already in use is a null rather than a second account" {
    var store: Accounts = .init(testing.allocator);
    defer store.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    _ = (try store.add(arena, testId(1), "wati@example.dev", "Wati", "$a", false)).?;
    try testing.expectEqual(
        @as(?Account, null),
        try store.add(arena, testId(2), "wati@example.dev", "Someone", "$b", false),
    );
    try testing.expectEqual(@as(usize, 1), try store.count());
}

test "a profile has no room for the hash" {
    const account: Account = .{
        .id = 1,
        .public = testId(3),
        .email = "wati@example.dev",
        .name = "Wati",
        .curator = true,
        .password = "$argon2id$secret",
    };
    const profile = profileOf(account);
    try testing.expectEqualStrings("Wati", profile.name);
    try testing.expect(!@hasField(Profile, "password"));
}

test "a rehash replaces the stored string and keeps the row" {
    var store: Accounts = .init(testing.allocator);
    defer store.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const made = (try store.add(arena, testId(1), "wati@example.dev", "Wati", "$weak", false)).?;

    try store.rehash(made.id, "$strong");
    const after = (try store.find(arena, "wati@example.dev")).?;
    try testing.expectEqualStrings("$strong", after.password);
    try testing.expectEqual(made.id, after.id);
}
