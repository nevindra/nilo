//! Turning the password Cost down so the test suite stops taking thirteen
//! milliseconds per sign-in. It works, the suite gets fast, and every hash
//! the application stores from then on is weaker than anything OWASP
//! publishes — while looking exactly like one that is not.

const pw = @import("nilo_pw");

export fn refusal() void {
    const cheap: pw.Cost = .{ .memory_kib = 64, .passes = 1 };
    _ = pw.hashWith(cheap, undefined, "hunter2", @splat(0)) catch {};
}
