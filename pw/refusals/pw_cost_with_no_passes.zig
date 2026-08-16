//! Reading `.passes` as "extra passes" and setting it to zero to mean one.
//! Argon2id counts it from one, so this is a hash that goes over its memory
//! no times at all.

const pw = @import("nilo_pw");

export fn refusal() void {
    const none: pw.Cost = .{ .memory_kib = 19 * 1024, .passes = 0 };
    _ = pw.hashWith(none, undefined, "hunter2", @splat(0)) catch {};
}
