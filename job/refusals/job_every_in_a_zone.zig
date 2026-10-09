//! A time zone on an interval. `every(ms)` is elapsed time, which no wall
//! clock changes the length of, so a zone means nothing to it; a person who
//! wrote one wanted a time of day, which is `job.cron` (ADR 161).

const job = @import("nilo_job");

export fn refusal() void {
    _ = comptime job.every(600_000).in("Asia/Jakarta");
}
