//! A payload carrying a pointer to a row somebody read. The payload is
//! written as JSON at `push` and read back on a worker, possibly in another
//! process, where the address means nothing.

const job = @import("nilo_job");
const core = @import("nilo_core");

const User = struct { id: u64 };

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;
    user: *const User,
    pub fn run(self: SendWelcome, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });
}
