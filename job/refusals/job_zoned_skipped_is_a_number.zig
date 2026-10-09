//! A `skipped` that is not a `job.Skipped`, as `overlap` and `missed` are
//! held to their own types (ADR 161).

const job = @import("nilo_job");
const core = @import("nilo_core");

const Nightly = struct {
    pub const nilo_job = "nightly";
    pub const retry: job.Retry = .none;
    pub const schedule = job.cron("0 3 * * *").in("Asia/Jakarta");
    pub const overlap: job.Overlap = .skip;
    pub const missed: job.Missed = .drop;
    pub const skipped = 1;
    pub fn run(self: Nightly, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{Nightly}, .store = job.Memory });
}
