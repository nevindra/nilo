//! A transactional job on SQLite that does not say how long it may run.
//! SQLite has one writer, so the transaction holds every write in the program
//! for the run, and that is a number the kind's author writes.

const job = @import("nilo_job");
const core = @import("nilo_core");

/// Stands in for `job.Table(Db)`, which the refusal programs cannot name: they
/// import `nilo_job` and `nilo_core` and no driver. It carries the
/// declarations `Jobs` reads and nothing a refusal reaches.
fn FakeStore(comptime writer: bool) type {
    return struct {
        pub const Database = struct {};
        pub const Tx = struct {
            pub fn commit(_: *@This()) !void {}
            pub fn rollback(_: *@This()) void {}
            pub fn deinit(_: *@This()) void {}
        };
        pub const single_writer = writer;
        pub fn begin(_: *@This(), _: anytype) !Tx {
            return .{};
        }
        pub fn doneIn(_: *@This(), _: *Tx, _: anytype, _: job.Id, _: u32, _: i64) !bool {
            return true;
        }
        pub fn push(_: *@This()) void {}
        pub fn claim(_: *@This()) void {}
        pub fn done(_: *@This()) void {}
        pub fn retry(_: *@This()) void {}
        pub fn dead(_: *@This()) void {}
        pub fn release(_: *@This()) void {}
        pub fn unkey(_: *@This()) void {}
        pub fn stats(_: *@This()) void {}
        pub fn deadOnes(_: *@This()) void {}
        pub fn retryDead(_: *@This()) void {}
    };
}

const Store = FakeStore(true);

const Charge = struct {
    pub const nilo_job = "charge";
    pub const retry: job.Retry = .none;
    pub fn run(self: Charge, scope: *core.Run, tx: *Store.Tx) !void {
        _ = self;
        _ = scope;
        _ = tx;
    }
};

const Jobs = job.Jobs(.{ .kinds = .{Charge}, .store = Store });

export fn refusal() void {
    var store: Store = undefined;
    _ = Jobs.open(undefined, &store, .{}, .{});
}
