//! A `run` asking for a service the queue was never given. A worker has no
//! registry to look in — the `deps` struct is the whole of what a `run` may
//! ask for — so this is caught here rather than as a null at three in the
//! morning.

const job = @import("nilo_job");
const core = @import("nilo_core");

const Mailer = struct {};

const SendWelcome = struct {
    pub const nilo_job = "send-welcome";
    pub const retry: job.Retry = .none;
    user: u64,
    pub fn run(self: SendWelcome, scope: *core.Run, mail: *Mailer) !void {
        _ = self;
        _ = scope;
        _ = mail;
    }
};

export fn refusal() void {
    _ = job.Jobs(.{ .kinds = .{SendWelcome}, .store = job.Memory, .deps = struct {} });
}
