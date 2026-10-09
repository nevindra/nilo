//! A zone spelled in the wrong case. IANA names are case sensitive, as they
//! are on every system that has them, and the Refusal offers the spelling
//! that does exist instead of leaving the person to look it up (ADR 161).

const job = @import("nilo_job");

export fn refusal() void {
    _ = comptime job.cron("0 3 * * *").in("asia/jakarta");
}
