//! Pushing a job the queue was not told about. The row would be stored under
//! a name no worker of this queue matches, and sit in the table forever.

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
    pub const nilo_job = "send-again";
    pub const retry: job.Retry = .none;
    pub fn run(self: SendAgain, scope: *core.Run) !void {
        _ = self;
        _ = scope;
    }
};

const Jobs = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });

export fn refusal() void {
    var store: job.Memory = undefined;
    var jobs: Jobs = .open(undefined, &store, .{}, .{});
    var run: core.Run = undefined;
    _ = jobs.push(&run, SendAgain{}, .{}) catch {};
}
