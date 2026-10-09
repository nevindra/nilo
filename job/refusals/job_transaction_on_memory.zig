//! A job that asks for a transaction, on a queue in memory. A row in memory
//! has nothing to commit with, so the run would be handed a promise the store
//! cannot keep: the job's writes and its `done` committing together.

const job = @import("nilo_job");
const core = @import("nilo_core");

/// Any transaction type: the run asks for it by pointer, and a store with
/// none is what is refused.
const Tx = struct {
    pub fn commit(_: *Tx) !void {}
    pub fn rollback(_: *Tx) void {}
    pub fn deinit(_: *Tx) void {}
};

const Charge = struct {
    pub const nilo_job = "charge";
    pub const retry: job.Retry = .none;
    pub fn run(self: Charge, scope: *core.Run, tx: *Tx) !void {
        _ = self;
        _ = scope;
        _ = tx;
    }
};

const Jobs = job.Jobs(.{ .kinds = .{Charge}, .store = job.Memory });

export fn refusal() void {
    var store: job.Memory = undefined;
    _ = Jobs.open(undefined, &store, .{}, .{});
}
