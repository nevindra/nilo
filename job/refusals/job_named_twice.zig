//! Two jobs under one name. A row says which job runs it by name, so this
//! would be one name with two bodies and the worker picking whichever came
//! first in the list.

const job = @import("nilo_job");
const core = @import("nilo_core");

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;
    pub fn run(self: SendWelcome, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

const SendAgain = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;
    pub fn run(self: SendAgain, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{ SendWelcome, SendAgain }, .store = job.Memory });
}
