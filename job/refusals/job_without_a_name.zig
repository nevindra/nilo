//! A job with no `nilo_job`. The name is what a row is stored under, and it
//! is written out rather than taken from the type so that a rename does not
//! orphan every row already in the table.

const job = @import("nilo_job");
const core = @import("nilo_core");

const SendWelcome = struct {
    pub const retry: job.Retry = .none;
    user: u64,
    pub fn run(self: SendWelcome, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });
}
