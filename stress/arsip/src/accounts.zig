//! Who is allowed in — the same store as M2, over a file instead of a heap.
//!
//! **This file still does no hashing**, and that is unchanged from M2 and for
//! the same reason: `nilo_pw` is 19 MiB and 13 ms a call, which is *under*
//! `block_warning_ms`, so a handler calling the module straight holds its thread
//! and nothing in the log ever says so. `auth.zig` hashes through the `Ctx`; this
//! stores the PHC string it produced.
//!
//! What M3 changed is the sentence under that. M2's store was an
//! `ArrayList(*Row)` with an arena per row and a `nilo.Mutex` around it — about
//! ninety lines of memory management written by hand, all of it in service of
//! "hand the caller a copy that lives as long as their request". SQLite does that
//! part, so this file is now the four rules that are *about accounts* and nothing
//! else: emails are matched without regard to case, an address in use is a null,
//! the hash comes back with the row a sign-in is checking, and a rehash replaces
//! text in place.
//!
//! The visible cost at the call site is one word: every method took an
//! `Allocator` and now takes a **Scope** — a `*nilo.Ctx` inside a request, a
//! `*nilo.Run` anywhere else. That is the whole of what moved.

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
const uuid = @import("nilo_id");

const Allocator = std.mem.Allocator;

/// `.hop` rather than `.in_fiber`, and it is not a default — the compiler will
/// not let this line be written without an answer, because SQLite is a library
/// reading a file and there is no socket for the loop to park on
/// ([ADR 0073](../../../docs/adr/0073-a-file-has-no-socket-to-wait-on.md)).
///
/// The guide's advice is to take `.hop` unless you have measured otherwise: its
/// bad case is microseconds a statement, `.in_fiber`'s is a stalled thread. arsip
/// has not measured, so it takes the advice — and says so here rather than
/// leaving the next reader to wonder whether the choice meant anything.
///
/// The payload is `nilo` — the whole module — because `sql/` is not allowed to
/// import the server. That is the layering rule showing through into a caller's
/// source, which is unusual and is explained where it happens.
pub const Db = sql.Sqlite(.{ .threading = .{ .hop = nilo } });

/// A UUID as text, because **`sql.Uuid` does not compile against SQLite.**
///
/// This is the one place the guide's headline claim for the SQLite section —
/// "swap two lines and the rest of this page is unchanged", "the same Rows" —
/// did not hold. `public: sql.Uuid` is what a Postgres Row writes and what
/// `nilo_sql` documents; against `sql.Sqlite` it stops the build with a message
/// from **zqlite**, three layers down, pointing at a Zig issue:
///
/// ```
/// zig-pkg/zqlite-…/src/conn.zig:399:21: error: Pass a string slice, rather than
/// an array, to bind a text/blob. String arrays will be supported when
/// https://github.com/ziglang/zig/issues/15893… is fixed
/// ```
///
/// The cause is one line: `WireWrite` in `sql/db.zig` turns a `Uuid` into a
/// `[16]u8`, which pg.zig takes and zqlite refuses. Item 18 in `DX.md`.
///
/// So this is the documented escape hatch used for something that should not
/// have needed it — three declarations make anything a column type (ADR 0055).
/// Text rather than a blob, and that is the better shape here anyway: a
/// `sqlite3` shell shows the id, and `WHERE public = '…'` is typeable.
pub const PublicId = struct {
    value: uuid.Uuid,

    /// Free text to SQLite, which derives TEXT affinity from it — and the name
    /// Postgres would want, so the Row stays portable in the direction that
    /// still works.
    pub const nilo_column = "uuid";

    pub fn nilo_read(text: []const u8, arena: Allocator) !PublicId {
        _ = arena;
        return .{ .value = try uuid.Uuid.parse(text) };
    }

    pub fn nilo_write(self: PublicId, arena: Allocator) ![]const u8 {
        return arena.dupe(u8, &self.value.toText());
    }
};

/// A table is a struct, and this one is also half of a response.
///
/// Two fields are worth reading twice:
///
/// - **`public` had to stop being `sql.Uuid`** — see `PublicId` above. On
///   Postgres this field would be `sql.Uuid` and nothing else here would move.
/// - **`id: i64`, not `u32`.** A key is what the database says it is, and
///   arguing with that costs a cast at every boundary instead of one field.
pub const Account = struct {
    pub const nilo_table = .{ .name = "accounts", .key = .id };

    id: i64,
    public: PublicId,
    email: nilo.Str,
    name: nilo.Str,
    curator: bool,
    /// `$argon2id$v=19$m=19456,t=2,p=1$…`. Nothing in this file knows it is a
    /// hash, which is the property that makes a hash made elsewhere verify here.
    password: nilo.Str,
};

/// What goes out. The hash is not in it, and that is enforced by the type rather
/// than by remembering to leave a field out of a serialiser.
pub const Profile = struct {
    public: uuid.Uuid,
    email: []const u8,
    name: []const u8,
    curator: bool,
};

pub fn profileOf(account: Account) Profile {
    return .{
        // `.value`, because the column type had to be a wrapper. On Postgres
        // this line is `account.public` and the wrapper does not exist.
        .public = account.public.value,
        .email = account.email.view(),
        .name = account.name.view(),
        .curator = account.curator,
    };
}

/// The table, written out.
///
/// **Nothing in nilo runs this**, and that is a decision rather than a gap: a Row
/// cannot declare an index or a constraint, because one that could would be a
/// migration file in disguise (`docs/reference.md`, Rows). So the schema lives
/// here as text, `db.checking` compares it against the struct at startup, and the
/// two are kept in step by hand.
///
/// `email_lower` exists because SQLite's `UNIQUE` is case-sensitive over TEXT
/// unless the column says `COLLATE NOCASE`, and "two accounts for the same
/// address in different case" is the bug that gets found in production.
/// The `NOT NULL` on `id` is not decoration and was not there first. SQLite's
/// `INTEGER PRIMARY KEY` is an alias for the rowid, and `pragma_table_info`
/// reports it as **nullable** unless the column says otherwise — a quirk of the
/// database rather than of nilo. `db.checking` caught it at startup, before a
/// single request:
///
/// ```
/// error: nilo_sql: nilo: accounts.Account.id is not optional, but accounts.id may be null
/// error: nilo found 1 disagreement(s) between a Row and its table, listed above.
/// ```
///
/// Worth knowing that **the whole 40-test suite passed with the wrong schema**,
/// because nothing in it calls `listen()` and `listen()` is what runs the check.
/// See item 2 in `DX.md`.
pub const schema =
    \\CREATE TABLE IF NOT EXISTS accounts (
    \\  id       INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    \\  public   TEXT    NOT NULL,
    \\  email    TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    \\  name     TEXT    NOT NULL,
    \\  curator  INTEGER NOT NULL,
    \\  password TEXT    NOT NULL
    \\)
;

pub const Accounts = struct {
    db: *Db,

    /// A table that is not there is a migration that has not run, and there is
    /// no migration runner — so this is it. Called once, before `listen()`,
    /// through a `nilo.Run` because there is no request to borrow a Scope from.
    /// **`Account` is passed as the Row of a `CREATE TABLE`, which returns no
    /// rows at all.** That is not a clever trick, it is the only door: `db.raw`
    /// is the one way to send a statement nilo did not write, and its first
    /// argument is a Row — checked for a `nilo_table` while compiling, with a
    /// message that assumes you are selecting something. A `struct {}` is
    /// refused. There is no `db.exec`, so a statement that answers with nothing
    /// has to name a shape anyway. See item 17 in `DX.md`.
    pub fn migrate(self: Accounts, scope: anytype) !void {
        _ = try self.db.raw(Account, scope, schema, .{});
    }

    /// An email already in use is `null` rather than an error: whether that is a
    /// 409 or a deliberately vague answer is the handler's decision, not the
    /// store's. What makes it a null here is a *unique violation coming back as
    /// a named error* rather than as a string to match on.
    pub fn add(
        self: Accounts,
        scope: anytype,
        public: uuid.Uuid,
        email: []const u8,
        name: []const u8,
        password: []const u8,
        curator: bool,
    ) !?Account {
        return self.db.insert(Account, scope, .{
            .public = PublicId{ .value = public },
            .email = email,
            .name = name,
            .curator = curator,
            .password = password,
        }) catch |err| switch (err) {
            error.AlreadyExists => null,
            else => err,
        };
    }

    /// The hash comes back with it, because the caller is about to verify a
    /// password against it. `null` means no such account, and passing that
    /// straight to `c.verifyPassword` is the point — see `auth.zig`.
    ///
    /// No `lower()` anywhere: the column is `COLLATE NOCASE`, so the database
    /// matches the way the constraint does. Two rules that have to agree are
    /// better as one rule.
    pub fn find(self: Accounts, scope: anytype, email: []const u8) !?Account {
        return self.db.one(Account, scope, .{ .where = .{ .email = email } });
    }

    pub fn byId(self: Accounts, scope: anytype, id: i64) !?Account {
        return self.db.find(Account, scope, id);
    }

    pub fn count(self: Accounts, scope: anytype) !usize {
        return self.db.count(Account, scope, .{});
    }

    /// Written forward when a sign-in succeeds and the Cost has gone up since —
    /// the one moment the plaintext is in hand.
    pub fn rehash(self: Accounts, scope: anytype, id: i64, password: []const u8) !void {
        _ = try self.db.update(Account, scope, .{
            .set = .{ .password = password },
            .where = .{ .id = id },
        });
    }
};

/// Create the table, on a database of its own, before the server exists.
///
/// **Ten lines where the guide implies two, and every one of them is
/// load-bearing — item 19 in `DX.md`.** `guide/sql.md` says a query needs only a
/// Scope and offers `nilo.Run` for "a migration script or a nightly job". A Run
/// is an arena and a lifetime; what it is not is a **connection**. The pool is
/// opened by `nilo_start(io)`, which `listen()` calls on every provided service
/// that declares one — so before `listen()` there is no pool, and every query
/// answers `error.Disconnected`.
///
/// Which leaves a migration needing an `std.Io` that only the running server has.
/// So this stands up std's own threaded implementation, opens a **second** `Db`
/// on the same file, creates the table and closes it again. That is the honest
/// shape rather than a workaround — a migration really is a phase before the
/// server, and doing it on the App's own `Db` would have meant two pools open on
/// one file. What is missing is anybody saying so: `error.Disconnected` at
/// startup does not lead a reader here.
pub fn migrateFile(gpa: Allocator, path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    // One connection: this opens the file, writes one statement and goes away.
    var db: Db = .init(gpa, path, .{ .size = 1 });
    defer db.deinit();
    try db.nilo_start(threaded.io());

    var run: nilo.Run = .init(gpa);
    defer run.deinit();

    const store: Accounts = .{ .db = &db };
    try store.migrate(&run);
}

// ---- tests ----
//
// A file database in a temporary directory rather than `:memory:`. The shared
// in-memory form would work and the guide says which one to write, but a file is
// what the read-only backstop needs to be real — on an in-memory database
// SQLite's URI `mode=` beats the flags a reader was opened with, so a `raw` that
// writes and looks like a read would quietly succeed there and fail in
// production. Tests that cannot fail the way production does are worse than no
// tests.

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

/// A database with no server anywhere near it.
///
/// The `std.Io.Threaded` is the part worth noticing: **it has to outlive every
/// query**, not just the migration, because it is what the pool was opened with.
/// A test that stood one up for `nilo_start` and dropped it would be reading
/// through a closed Io. So it is a field.
const Fixture = struct {
    dir: std.testing.TmpDir,
    path: [:0]const u8,
    threaded: std.Io.Threaded,
    db: Db,
    run: nilo.Run,

    fn init(gpa: Allocator) !*Fixture {
        // By pointer, because `db` holds no self-reference but `store()` hands
        // out `&self.db` and a Fixture returned by value would move.
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);

        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();

        const path = try std.fmt.allocPrintSentinel(
            gpa,
            ".zig-cache/tmp/{s}/accounts.db",
            .{dir.sub_path},
            0,
        );
        errdefer gpa.free(path);

        try migrateFile(gpa, path);

        self.* = .{
            .dir = dir,
            .path = path,
            .threaded = .init(gpa, .{}),
            .db = Db.init(gpa, path, .{ .size = 2 }),
            .run = .init(gpa),
        };
        try self.db.nilo_start(self.threaded.io());
        return self;
    }

    fn deinit(self: *Fixture, gpa: Allocator) void {
        self.run.deinit();
        self.db.deinit();
        self.threaded.deinit();
        gpa.free(self.path);
        self.dir.cleanup();
        gpa.destroy(self);
    }

    fn store(self: *Fixture) Accounts {
        return .{ .db = &self.db };
    }
};

test "an email is matched without regard to case, and the constraint agrees" {
    const gpa = testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const made = (try f.store().add(&f.run, testId(1), "Wati@Example.Dev", "Wati", "$argon2id$fake", false)).?;
    try testing.expectEqualStrings("Wati@Example.Dev", made.email.view());

    // The lookup and the UNIQUE are the same rule, so a second account for the
    // same address in different case is refused rather than created.
    const found = (try f.store().find(&f.run, "WATI@EXAMPLE.DEV")).?;
    try testing.expectEqual(made.id, found.id);

    const again = try f.store().add(&f.run, testId(2), "wati@example.dev", "Someone", "$b", false);
    try testing.expectEqual(@as(?Account, null), again);
    try testing.expectEqual(@as(usize, 1), try f.store().count(&f.run));
}

test "a profile has no room for the hash" {
    try testing.expect(!@hasField(Profile, "password"));
}

test "a rehash replaces the stored string and keeps the row" {
    const gpa = testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const made = (try f.store().add(&f.run, testId(1), "wati@example.dev", "Wati", "$weak", false)).?;
    try f.store().rehash(&f.run, made.id, "$strong");

    const after = (try f.store().byId(&f.run, made.id)).?;
    try testing.expectEqualStrings("$strong", after.password.view());
    try testing.expectEqual(made.id, after.id);
}

test "a uuid goes in as sixteen bytes and comes back the same value" {
    const gpa = testing.allocator;
    var f = try Fixture.init(gpa);
    defer f.deinit(gpa);

    const public = testId(7);
    const made = (try f.store().add(&f.run, public, "wati@example.dev", "Wati", "$a", true)).?;
    try testing.expectEqualSlices(u8, &public.bytes, &made.public.value.bytes);
    try testing.expect(made.curator);

    // And back off the disk, through `nilo_read`, rather than out of the value
    // the insert was handed.
    const again = (try f.store().byId(&f.run, made.id)).?;
    try testing.expectEqualSlices(u8, &public.bytes, &again.public.value.bytes);
}
