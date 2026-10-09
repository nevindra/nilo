//! An exponential backoff that starts at nothing. Doubling zero is zero, so
//! every wait is no wait at all: the `fixed_ms = 0` that was meant, written
//! in a shape that looks like a growing one, and a downstream outage then
//! has every failed row retried at the same instant (ADR 161).

const job = @import("nilo_job");
const core = @import("nilo_core");

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 0, .to_ms = 60_000 } } };
    user: u64,
    pub fn run(self: SendWelcome, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });
}
