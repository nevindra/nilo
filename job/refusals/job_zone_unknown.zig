//! A zone name that is not one the IANA database has. A typo here would
//! otherwise be a schedule read in the wrong zone or in none, so the name is
//! checked while compiling and the Refusal says what a zone looks like
//! (ADR 161).

const job = @import("nilo_job");

export fn refusal() void {
    _ = comptime job.cron("0 3 * * *").in("Asia/Jakart");
}
