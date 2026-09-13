//! A scheduled job with a field nobody will fill in. The clock pushes a
//! scheduled job with nothing in hand, so every field needs a default or the
//! payload cannot be read back.

const job = @import("nilo_job");
const core = @import("nilo_core");

const Nightly = struct {
    pub const nilo_job = "nightly";
    pub const retry: job.Retry = .none;
    pub const schedule = job.cron("0 3 * * *");
    pub const overlap: job.Overlap = .skip;
    pub const missed: job.Missed = .drop;
    day: u8,
    pub fn run(self: Nightly, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{Nightly}, .store = job.Memory });
}
