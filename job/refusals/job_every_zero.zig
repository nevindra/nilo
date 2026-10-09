//! A schedule with no gap between its ticks. The next tick would be due the
//! moment this one is claimed, so a worker would never rest and the queue
//! would never be empty; the period is read while compiling so the mistake
//! is a build error and not a core at full load (ADR 161).

const job = @import("nilo_job");

export fn refusal() void {
    _ = job.every(0);
}
