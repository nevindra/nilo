//! The world every checked snippet in the documentation is compiled against
//! (ADR 0083).
//!
//! `zig build snippets` finds each fenced `zig` block in the guide, the
//! reference and the README that carries a `<!-- compiles -->` line above it,
//! puts this file in front of it, and compiles the result. So this is the
//! documentation's *running example*, written once and in one place: a
//! `User`, an `Account`, a sign-in form, a document with a generated key.
//!
//! **Nothing here is a stand-in for a nilo type.** The `Ctx`, the `Db` and
//! the `Form` are the real ones, which is the whole point — a snippet that
//! calls one of them wrongly does not compile, and that is what this catches.
//!
//! [`values.zig`](./values.zig) is the other half: the request in flight that
//! a snippet of loose statements needs. It goes in front of those and not in
//! front of a snippet declaring functions, because a parameter named `c`
//! cannot shadow a declaration named `c`.
//!
//! A snippet's own `const x = @import(…)` lines are dropped on the way in —
//! the page should show them, and here they would collide with these.

const std = @import("std");

pub const nilo = @import("nilo_http");
pub const sql = @import("nilo_sql");
pub const id = @import("nilo_id");
pub const pw = @import("nilo_pw");
pub const config = @import("nilo_config");
pub const fetch = @import("nilo_fetch");
pub const s3 = @import("nilo_s3");
pub const cache = @import("nilo_cache");
pub const jwt = @import("nilo_jwt");
pub const job = @import("nilo_job");

pub const Str = nilo.Str;
pub const Redirect = nilo.Redirect;
pub const Session = nilo.Session;
pub const Db = sql.Db;

/// The table the README and the reference sign somebody up into.
pub const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: Str,
    password: Str,
};

/// The same table under the name the sessions guide calls it by.
pub const Account = User;

/// What that guide's session actually holds — a user's id, not the row.
pub const Signed = struct { user: u32, admin: bool = false };

/// What the cache page keeps: a flat value, because a cache entry outlives the
/// request that wrote it and so may hold no pointer (ADR 0138).
pub const Cart = struct {
    owner: u64,
    items: u16,
    total_cents: u64,
};

/// The Space the reference and the guide read and write.
pub const Carts = cache.Space("cart", Cart, .{ .ttl_s = 300 });

/// A row whose key is generated rather than counted, for `nilo_id`.
pub const Doc = struct {
    pub const nilo_table = .{ .name = "documents", .key = .id };

    id: sql.Uuid,
    title: Str,
};

pub const SignIn = struct {
    email: Str,
    password: Str,
};

/// The job the jobs guide pushes at sign-up: what its first block declares,
/// so every block after it compiles against the real thing. `Db` here is
/// Postgres, and `job.Table` over it is the queue.
pub const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .{
        .times = 5,
        .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000 } },
    };

    user_id: i64,
    email: Str,

    // `database` where the page says `db`: a parameter may not shadow the
    // `db` values.zig declares for the body snippets that follow this.
    pub fn run(self: SendWelcome, scope: *nilo.Run, database: *Db) !void {
        const user = try database.find(User, scope, self.user_id) orelse return;
        try sendMail(scope, user.email, "Welcome");
    }
};

/// The mail the guide's job sends — the caller's own, so a stub.
pub fn sendMail(scope: *nilo.Run, to: Str, subject: []const u8) !void {
    _ = scope;
    _ = to;
    _ = subject;
}

/// And the one that runs at three in the morning, with the two choices
/// ADR 0199 makes the caller make.
pub const Nightly = struct {
    pub const nilo_job = "nightly-report";
    pub const retry: job.Retry = .none;
    pub const schedule = job.cron("0 3 * * *");
    pub const overlap: job.Overlap = .skip;
    pub const missed: job.Missed = .drop;

    pub fn run(self: Nightly, scope: *nilo.Run, database: *Db) !void {
        _ = self;
        _ = scope;
        _ = database;
    }
};

/// The queue the jobs guide opens, provides and spawns.
pub const Jobs = job.Jobs(.{
    .kinds = .{ SendWelcome, Nightly },
    .store = job.Table(Db),
    .deps = struct { db: *Db },
});
