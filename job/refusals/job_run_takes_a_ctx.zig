//! A `run` that takes a `*Ctx`. There is no request when a job runs, so a
//! fail function inside it would have nothing to write into; the Scope a job
//! is handed is a `nilo.Run`, and the signature says so.

const job = @import("nilo_job");

const Ctx = struct {};

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;
    user: u64,
    pub fn run(self: SendWelcome, c: *Ctx) !void {
        _ = self;
        _ = c;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory });
}
