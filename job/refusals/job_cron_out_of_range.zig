//! An hour that does not exist. A schedule read at run time would accept this
//! and never fire; one read while compiling says which field and what the
//! field allows.

const job = @import("nilo_job");

export fn refusal() void {
    _ = job.cron("0 25 * * *");
}
