//! The world every checked snippet in [the SQL guide](../guide/sql.md) is
//! compiled against (ADR 0083).
//!
//! A prelude of its own rather than the shared
//! [`types.zig`](./types.zig), because this is the page that *teaches*
//! tables. Its `User` has an `age`, an `orders` counter and a `created_at`
//! that the sign-in example next door has no use for, and it needs an
//! `Order`, an `Item`, a `Product` and four more besides — seven types of
//! noise in front of a snippet about a cookie. A page whose types are the
//! subject gets to own them.
//!
//! **`User` is deliberately not here.** The guide declares it in the first
//! marked block on the page, and every block below it — statements included
//! — is compiled with that declaration in front. Showing the struct once and
//! then checking the page against the struct it showed is the whole point;
//! a copy here would be a second `User` to keep in step, which is exactly
//! the thing this step exists to stop. The same goes for `Invoice`,
//! `Ticket`, `Sale` and `Money`.
//!
//! [`sql_values.zig`](./sql_values.zig) is the other half: the request in
//! flight that a snippet of loose statements needs.

const std = @import("std");

pub const nilo = @import("nilo_http");
pub const sql = @import("nilo_sql");

pub const Str = nilo.Str;

/// What a user buys, and the other side of every transaction example.
pub const Order = struct {
    pub const nilo_table = .{ .name = "orders", .key = .id };

    id: i64,
    user_id: i64,
    total: i64,
    status: Str,
};

/// A line of stock, for the batch and row-lock examples.
pub const Item = struct {
    pub const nilo_table = .{ .name = "items", .key = .id };

    id: i64,
    sku: Str,
    qty: i32,
};

/// The read-only half of the two-database example.
pub const Product = struct {
    pub const nilo_table = .{ .name = "products", .key = .id };

    id: i64,
    name: Str,
};

/// A word with a unique index on it, which is what the savepoint example is
/// about: one of these failing must not take the rest of the batch with it.
pub const Tag = struct {
    pub const nilo_table = .{ .name = "tags", .key = .id };

    id: i64,
    name: Str,
};

/// The queue `SELECT … FOR UPDATE SKIP LOCKED` pulls a batch out of.
pub const Job = struct {
    pub const nilo_table = .{ .name = "jobs", .key = .id };

    id: i64,
    state: enum { pending, running, done },
};

/// The slow query a deadline is put on.
pub const Report = struct {
    pub const nilo_table = .{ .name = "reports", .key = .id };

    id: i64,
    month: i32,
};

/// A `PATCH` body, for the example that changes a row and answers with it.
pub const Rename = struct {
    name: Str,
};

/// A pure join table, for the `.key` conflict target: its key is the two
/// columns and there is no `id` at all, which is the shape ADR 0186 is about.
pub const UserTag = struct {
    pub const nilo_table = .{ .name = "user_tags", .key = .{ .user_id, .tag } };

    user_id: i64,
    tag: Str,
};

/// The two sides of the `.exists` example. They are here rather than being
/// `User` and `Order` because an `.exists` reads its join out of a
/// `.references`, and the guide's own `User` is declared on the page (see the
/// header) — so nothing in this file may point at it.
pub const Partner = struct {
    pub const nilo_table = .{ .name = "partners", .key = .id };

    id: i64,
    name: Str,
};

pub const PartnerCapability = struct {
    pub const nilo_table = .{
        .name = "partner_capabilities",
        .key = .{ .partner_id, .capability },
        .references = .{ .partner_id = .{ Partner, .id } },
    };

    partner_id: i64,
    capability: Str,
};
