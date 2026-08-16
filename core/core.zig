//! nilo_core — what every layer of nilo agrees about (ADR 0041).
//!
//! Two things live here. Text that belongs to a piece of work, and the
//! Scope that hands out the memory it lives in. The App uses both on every
//! request; `nilo_sql` uses both on every row it reads. That is the rule
//! for a third: **a file earns its place by being needed by two layers,
//! not by having nowhere else to live.** The moment this is where things go
//! because they fit nowhere, the layering has stopped meaning anything and
//! only the directory is left.
//!
//! Nothing here does IO, names an Engine, or knows that HTTP exists. That
//! is what lets `zig test core/core.zig` run the whole of it in a second
//! without the module graph, and what lets a program with no server in it
//! link this and nothing else.

const str_mod = @import("str.zig");
const scope_mod = @import("scope.zig");

pub const Str = str_mod.Str;
pub const Lifetime = str_mod.Lifetime;
pub const stamp = str_mod.stamp;
pub const trap_enabled = str_mod.trap_enabled;

pub const Run = scope_mod.Run;
pub const checkScope = scope_mod.check;

test {
    _ = @import("str.zig");
    _ = @import("scope.zig");
}
