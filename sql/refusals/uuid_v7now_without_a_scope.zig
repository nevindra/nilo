//! `id.v7Now` handed something that cannot produce randomness. The clock is
//! the module's and the entropy is the caller's, because entropy is IO and
//! nothing in the bottom layer owns an event loop (ADR 0042, ADR 0176).
//!
//! **It is filed here rather than under `refusals/` because `nilo_id` has no
//! table of its own**, and `sql.Uuid` is `nilo_id`'s `Uuid` — the same
//! declaration, reached through an import line `sql.zig` documents. The
//! framework's refusals are built against `nilo_http` alone, which cannot name
//! this call at all.

const sql = @import("nilo_sql");

export fn refusal() void {
    _ = sql.Uuid.v7Now(@as(u32, 7)) catch undefined;
}
