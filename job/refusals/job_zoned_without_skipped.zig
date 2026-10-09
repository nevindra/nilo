//! A fixed time in a zone whose clocks go forward through it. 02:00 in Berlin
//! does not exist one night a year; running it late and not running it are
//! both right for somebody, so neither is the default (ADR 161).

const job = @import("nilo_job");
const core = @import("nilo_core");

const Nightly = struct {
    pub const nilo_job = "nightly";
    pub const retry: job.Retry = .none;
    pub const schedule = job.cron("0 2 * * *").in("Europe/Berlin");
    pub const overlap: job.Overlap = .skip;
    pub const missed: job.Missed = .drop;
    pub const repeated: job.Repeated = .first;
    pub fn run(self: Nightly, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{Nightly}, .store = job.Memory });
}
