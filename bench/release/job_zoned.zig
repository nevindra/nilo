//! nilo_job: the next tick of a fixed-time schedule in a time zone, asked at a
//! moment just before the clocks go forward, which is the walk through the
//! zone's stretches that a UTC schedule does not make (ADR 161).
//!
//! `Schedule.next` and nothing else: the queue's own cost is the `job`
//! program's, and this one is what a zone adds to a tick. The moment is the
//! same every call, so the cost is one number and the difference over the
//! difference is exact. A ref before zones existed does not compile this, which
//! is that ref's "n/a" for this row.

const std = @import("std");
const job = @import("nilo_job");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

/// 02:00 in Berlin: a time the clocks skip one night a year, so the walk has
/// to look at the stretch before the gap and the one after it.
const schedule = job.cron("0 2 * * *").in("Europe/Berlin");

const Program = struct {
    /// 2026-03-28T12:00:00Z, the afternoon before the clocks go forward.
    after: i64,

    pub fn init(_: std.mem.Allocator) !Program {
        return .{ .after = 1_774_699_200 * std.time.us_per_s };
    }

    pub fn deinit(_: *Program) void {}

    pub fn op(self: *Program, _: std.mem.Allocator, _: usize) !void {
        harness.keep(schedule.nextWith(self.after, .{ .skipped = .run_late, .repeated = .both }));
    }
};
