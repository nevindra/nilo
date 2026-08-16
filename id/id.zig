//! nilo_id — identifiers, and nothing that needs a loop (ADR 0042).
//!
//! The first **tool module**: one in the bottom layer that is not the
//! vocabulary. `nilo_core` is what every layer agrees about; this is a job
//! that happens to need no event loop, which is the only question that
//! decides where a module goes (ADR 0041).
//!
//! ```zig
//! const id = @import("nilo_id");
//!
//! var random: [id.Uuid.v7_entropy]u8 = undefined;
//! try fillFromSomewhereUnguessable(&random);
//!
//! const key = id.v7(random, now_in_milliseconds);   // sortable, for a key
//! ```
//!
//! A `Uuid` from here is the same type `nilo_sql` reads a `uuid` column into
//! — the Service imports this module rather than declaring a second Uuid of
//! its own, which is what ADR 0042 decides. So a generated key goes straight
//! into an insert:
//!
//! ```zig
//! _ = try db.insert(User, c, .{ .id = key, .email = form.email });
//! ```
//!
//! **The randomness and the millisecond are arguments.** Both are IO in Zig
//! 0.16 and neither is something a module down here can reach: nilo gets
//! entropy through the Bulkhead so that the syscall parks the fiber instead
//! of stopping the thread (ADR 0002, ADR 0014), and a module in this layer
//! has no Bulkhead. What that costs a handler, and what the seam would look
//! like, is written down in ADR 0042 rather than guessed at here.
//!
//! **This module imports nothing at all**, and that is checked rather than
//! promised: `zig build layering` refuses an import here that is not `std`,
//! `builtin`, or a file beside it.

const uuid = @import("uuid.zig");

pub const Uuid = uuid.Uuid;

/// A random identifier — version 4, from 122 bits the caller brought.
pub const v4 = Uuid.v4;

/// A sortable identifier — version 7, the millisecond first. What a primary
/// key wants, because an index on it writes into the last page rather than
/// into every page it has.
pub const v7 = Uuid.v7;

test {
    _ = uuid;
}
