//! Turning `.lanes` up to use the cores that are sitting there, without
//! turning `.memory_kib` up with it. Argon2id gives every lane four segments
//! of two blocks, so sixteen lanes cost 128 KiB before any hashing happens —
//! and a Cost that cannot be computed is one argon2 refuses at run time, in
//! the middle of a sign-in, rather than here.

const pw = @import("nilo_pw");

export fn refusal() void {
    const crowded: pw.Cost = .{ .memory_kib = 8 * 1024, .passes = 2, .lanes = 2048 };
    _ = pw.hashWith(crowded, undefined, "hunter2", @splat(0)) catch {};
}
