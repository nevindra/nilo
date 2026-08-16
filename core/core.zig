//! nilo_core — what every layer of nilo agrees about (ADR 0041).
//!
//! Three things live here. Text that belongs to a piece of work, the Scope
//! that hands out the memory it lives in, and what time it is. Each is used
//! by two layers, which is the rule for a fourth: **a file earns its place
//! by being needed by two layers, not by having nowhere else to live.** The
//! moment this is where things go because they fit nowhere, the layering has
//! stopped meaning anything and only the directory is left.
//!
//! **Nothing here needs the event loop**, names an Engine, or knows that
//! HTTP exists. That is what lets `zig test core/core.zig` run the whole of
//! it in a second without the module graph, and what lets a program with no
//! server in it link this and nothing else.
//!
//! That sentence used to read *nothing here does IO*, and the clock is why
//! it does not (ADR 0045): reading it is a syscall by the letter and a read
//! from a mapped page in practice, so there is nothing for a fiber to wait
//! on. **Needing the loop is the question the layering has always actually
//! been asking**, and it is the one to keep asking of a fourth.

const str_mod = @import("str.zig");
const scope_mod = @import("scope.zig");
const clock_mod = @import("clock.zig");

pub const Str = str_mod.Str;
pub const Lifetime = str_mod.Lifetime;
pub const stamp = str_mod.stamp;
pub const trap_enabled = str_mod.trap_enabled;

pub const Run = scope_mod.Run;
pub const checkScope = scope_mod.check;

pub const nowMicros = clock_mod.nowMicros;
pub const nowMillis = clock_mod.nowMillis;

test {
    _ = @import("str.zig");
    _ = @import("scope.zig");
    _ = @import("clock.zig");
}
