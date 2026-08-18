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
