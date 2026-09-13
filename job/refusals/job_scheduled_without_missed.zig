//! A schedule that does not say what happens to a tick the process was down
//! for. Dropping it and catching up are both right for somebody, so neither
//! is the default (ADR 0199).

const job = @import("nilo_job");
const core = @import("nilo_core");

const Nightly = struct {
    pub const nilo_job = "nightly";
    pub const retry: job.Retry = .none;
    pub const schedule = job.cron("0 3 * * *");
    pub const overlap: job.Overlap = .skip;
    pub fn run(self: Nightly, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{Nightly}, .store = job.Memory });
}
