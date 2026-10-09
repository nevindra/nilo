//! A schedule moved to a second zone. Which of the two it meant is not
//! something to guess, so the zone is said once (ADR 161).

const job = @import("nilo_job");

export fn refusal() void {
    _ = comptime job.cron("0 3 * * *").in("Asia/Jakarta").in("Europe/Berlin");
}
