//! `pushIn` on a queue in memory. A row in memory has nothing to commit with,
//! so a transaction handed to it would be a promise the store cannot keep.

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

const Jobs = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });

const Tx = struct {};

export fn refusal() void {
    var store: job.Memory = undefined;
    var jobs: Jobs = .open(undefined, &store, .{}, .{});
    var run: core.Run = undefined;
    var tx: Tx = .{};
    _ = jobs.pushIn(&tx, &run, SendWelcome{}, .{}) catch {};
}
