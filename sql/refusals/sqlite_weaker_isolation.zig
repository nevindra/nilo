//! An isolation level SQLite does not have.
//!
//! SQLite gives every transaction a snapshot and serialises the writers, which
//! is `.serializable`. There is no weaker level to ask for — so
//! `.read_committed` is not a setting it lacks, it is a description of
//! something it never does.
//!
//! Refused while compiling rather than ignored, and that is the whole reason
//! `wire.Begin` is comptime: a transaction that asked for `read_committed` and
//! silently got something stronger is a correctness difference nobody would
//! ever see, in either direction.

const sql = @import("nilo_sql");

const Wire = sql.sqlite.Wire(.{ .threading = .in_fiber });

export fn refusal() void {
    var w: Wire = undefined;
    const arena: std.mem.Allocator = undefined;
    _ = w.begin(arena, .{ .isolation = .read_committed }) catch {};
}

const std = @import("std");
