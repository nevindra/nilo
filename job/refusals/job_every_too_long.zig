//! A period that is a mistake in the unit. `every` takes milliseconds, so a
//! number this size is seconds or microseconds written where milliseconds
//! go, and a worker would hold a tick it can never reach, or overflow the
//! clock arithmetic trying (ADR 161).

const job = @import("nilo_job");

export fn refusal() void {
    _ = job.every(1_000_000_000_000_000);
}
