//! The tests that need a socket to die under a transaction, and the proxy
//! that kills it.
//!
//! `Tx.fresh` empties the connection's server error before every statement,
//! so a unique violation followed by a broken pipe is reported as the broken
//! pipe rather than as `AlreadyExists` — the older statement's answer to a
//! question nobody asked twice. `Tx.revive` reads the same field the other
//! way round: a set `err` means the server answered *this* statement and the
//! socket was alive to carry the answer, so an aborted transaction can be let
//! out of pg.zig's `.fail` and rolled back rather than destroyed
//! ([ADR 043](../docs/adr/043-a-deadline-needs-a-connection-you-hold.md)).
//! The live half of that has a test in `live.zig`, which reads
//! `pg_pool_dirty` and watches it not move. The dead half needed a socket the
//! suite never opened, and this file opens it
//! ([ADR 043](../docs/adr/043-a-deadline-needs-a-connection-you-hold.md)).
//!
//! ## A proxy, in the test
//!
//! Between the pool and the Postgres that `DATABASE_URL` names sits a TCP
//! proxy of this file's own: port 0 on loopback, one accept loop, two pumps
//! per connection, every one of them a task on the same `std.Io.Threaded` the
//! pool dials through. The `Db` is opened against the proxy's port with
//! `size = 1`, so that *the* connection is unambiguous, and the test cuts it
//! by hand between two lines of its own. Asking Postgres to hang up instead —
//! `pg_terminate_backend` from a second connection — was the alternative, and
//! it is the wrong shape twice over: the death lands whenever the server gets
//! round to it rather than between the two statements the test is about, and
//! it lands as a FIN, which is the one spelling this file has to avoid.
//!
//! **The cut is a reset, not a close.** A socket closed the ordinary way
//! sends a FIN, and the client sits in `CLOSE_WAIT` with nothing wrong yet:
//! its next write goes out, the far end answers it with an RST, and what the
//! read after that sees is `EPIPE` — which `std.Io.Threaded` spells
//! `error.SocketUnconnected`, a name `translate` in `postgres.zig` does not
//! list. The caller would get `QueryFailed` and the log an `err` line saying
//! the driver refused the statement before it reached the database, and both
//! are false. An RST that arrives while the connection is `ESTABLISHED` puts
//! `ECONNRESET` on the very next write, which is `ConnectionResetByPeer` in
//! every spelling and `Disconnected` at the caller. `SO_LINGER` with a zero
//! timeout is how `close` is made to say RST. The timing does not even have
//! to be won: if the reset has not reached the client's socket by the time
//! the next write goes out, the write succeeds, the reset answers it, and
//! the read that follows meets `ECONNRESET` too. Only a FIN in front of the
//! reset changes the spelling, and no FIN is ever sent.
//!
//! **The pumps are cancelled before either socket is closed**, and the order
//! is load-bearing: a `close` on a descriptor another thread is blocked in
//! `readv` on does not wake that thread, and the socket it names stays open
//! underneath until the read returns — which it never would, so no RST would
//! ever go out. `Future.cancel` sends the signal that gets a task out of a
//! blocking syscall (ADR 056), and only once both pumps have returned does
//! the descriptor get closed.
//!
//! **Every wait here has a bound.** The accept loop and the pumps wait on
//! sockets and are cancelled, which is the bound. The wait for the proxy to
//! have seen a connection is five seconds of polling and then an error with
//! a name. The redial the pool makes after a cut goes through the same accept
//! loop, which is still running, so a connection thrown away is replaced on
//! the spot — and a proxy that accepts more than it has room for stops and
//! says so rather than leaving the dial waiting on an auth reply nobody will
//! send.
//!
//! **A transaction here ends with `commit`, never with `deinit` alone.** A
//! rollback that cannot reach the server logs at `err`, and Zig's test runner
//! counts one as a failed test with no way to expect it — the finding in
//! `docs/history.md` under *a behaviour whose only signal is a log*. `commit`
//! walks the same `revive` → `fresh` → statement path and returns the error
//! instead, and once it has failed `deinit` has nothing left to send.
//!
//! **A root of its own, hung off `test-sql`.** Not because it needs the
//! Engine — it does not, and that is the point of the Fitting layer's
//! entry condition holding one layer up — but because a proxy that wedges is
//! then a binary that wedges, with its own name in `ps`, rather than one test
//! in a hundred inside `live.zig`. `DATABASE_URL` unset skips every test
//! here, the way `live.zig` skips.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("nilo_core");
const sql = @import("nilo_sql");
const live_config = @import("live_config");

const testing = std.testing;

/// Named after the optimize mode for the reason `live.zig`'s tables are:
/// `zig build test-sql` runs the Debug and ReleaseSafe binaries at once,
/// against one database, and they must not drop each other's table.
const mode_suffix = switch (builtin.mode) {
    .Debug => "debug",
    .ReleaseSafe => "releasesafe",
    .ReleaseFast => "releasefast",
    .ReleaseSmall => "releasesmall",
};

const table = "nilo_severed_" ++ mode_suffix;

/// One row, already there, so that inserting it again is a unique violation.
const Seat = struct {
    pub const nilo_table = .{ .name = table, .key = .id };

    id: i64,
    label: []const u8,
};

/// A byte pump from one socket to another, until the source ends.
///
/// A task of the `Io`, one per direction per connection. It ends three ways:
/// the source hits EOF or an error, and the destination is told this
/// direction is finished with a `shutdown(.send)` so the far side sees the
/// close the way it would without a proxy in between; or it is cancelled,
/// which is the cut, and then it touches nothing — the socket it would have
/// shut down is about to be reset by the thread that cancelled it, and a FIN
/// sent first would turn the reset into the `EPIPE` the header is about.
fn pump(io: std.Io, from: std.Io.net.Stream, to: std.Io.net.Stream) void {
    var chunk: [8 << 10]u8 = undefined;
    var out_buf: [8 << 10]u8 = undefined;
    var reader = from.reader(io, &.{});
    var writer = to.writer(io, &out_buf);
    while (true) {
        var data: [1][]u8 = .{&chunk};
        const n = reader.interface.readVec(&data) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => {
                if (reader.err) |why| if (why == error.Canceled) return;
                break;
            },
        };
        writer.interface.writeAll(chunk[0..n]) catch return;
        writer.interface.flush() catch return;
    }
    to.shutdown(io, .send) catch {};
}

/// A TCP proxy on loopback, in front of the Postgres the URL names.
///
/// Port 0, and the kernel's answer read back, for the reasons on
/// `fetch/live.zig`'s `open`. Every connection accepted is dialled through
/// to the real server and pumped both ways; the test cuts one by index.
const Proxy = struct {
    io: std.Io,
    server: std.Io.net.Server,
    port: u16,
    /// The real server, as the URL names it: a host name or an IP literal,
    /// and the port, defaulted the way pg.zig defaults it.
    host_buf: [std.Io.net.HostName.max_len]u8,
    host_len: usize,
    upstream_port: u16,
    /// Every connection accepted so far, in the order they arrived. Filled
    /// in by the accept loop on its own thread, and read by the test on its
    /// own, so `count` is the flag and a link is published before it.
    links: [max_links]Link,
    count: std.atomic.Value(usize),
    /// Set when the accept loop stopped for a reason the test should hear
    /// about, rather than because it was cancelled.
    trouble: std.atomic.Value(bool),

    /// The pool is one connection, replaced once per test after the cut,
    /// and a third is a surprise worth stopping on.
    const max_links = 4;

    const Link = struct {
        client: std.Io.net.Stream,
        upstream: std.Io.net.Stream,
        up: std.Io.Future(void),
        down: std.Io.Future(void),
        closed: bool = false,
    };

    fn open(io: std.Io, uri: std.Uri) !Proxy {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try address.listen(io, .{});
        errdefer server.socket.close(io);

        var self: Proxy = .{
            .io = io,
            .server = server,
            .port = server.socket.address.getPort(),
            .host_buf = undefined,
            .host_len = 0,
            .upstream_port = uri.port orelse 5432,
            .links = undefined,
            .count = .init(0),
            .trouble = .init(false),
        };

        // Decoded into a buffer of its own first: `toRaw` may answer a slice
        // of the buffer it was handed or of the original text, and a copy
        // onto itself is the one thing `@memcpy` refuses.
        var decoded: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = if (uri.host) |component| try component.toRaw(&decoded) else "127.0.0.1";
        if (host.len > self.host_buf.len) return error.NameTooLong;
        @memcpy(self.host_buf[0..host.len], host);
        self.host_len = host.len;
        return self;
    }

    fn upstreamHost(self: *const Proxy) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    /// A connection to the real server, dialled the way pg.zig dials: an IP
    /// literal as itself, anything else as a name to look up.
    fn dial(self: *Proxy) !std.Io.net.Stream {
        const name = self.upstreamHost();
        if (std.Io.net.IpAddress.parse(name, self.upstream_port)) |address| {
            return address.connect(self.io, .{ .mode = .stream });
        } else |_| {}
        const host_name: std.Io.net.HostName = try .init(name);
        return host_name.connect(self.io, self.upstream_port, .{ .mode = .stream });
    }

    /// The accept loop. A task of the `Io`, started with `io.concurrent` for
    /// the reason `fetch/live.zig` gives: `io.async` may run this on the
    /// calling thread, and the caller is about to dial the port this is
    /// meant to be listening on (ADR 056).
    ///
    /// It returns when cancelled, which is how `close` stops it, or when
    /// something went wrong that the test should hear about — and then it
    /// closes the connection it could not serve, so that the pool's dial
    /// fails loudly rather than waiting for an auth reply that never comes.
    fn serve(self: *Proxy) void {
        while (true) {
            const client = self.server.accept(self.io) catch return;
            const n = self.count.load(.acquire);
            if (n == max_links) return self.giveUp(client, null);
            const upstream = self.dial() catch return self.giveUp(client, null);

            const link = &self.links[n];
            link.* = .{ .client = client, .upstream = upstream, .up = undefined, .down = undefined };
            link.up = self.io.concurrent(pump, .{ self.io, client, upstream }) catch
                return self.giveUp(client, upstream);
            link.down = self.io.concurrent(pump, .{ self.io, upstream, client }) catch {
                link.up.cancel(self.io);
                return self.giveUp(client, upstream);
            };
            self.count.store(n + 1, .release);
        }
    }

    fn giveUp(self: *Proxy, client: std.Io.net.Stream, upstream: ?std.Io.net.Stream) void {
        client.close(self.io);
        if (upstream) |u| u.close(self.io);
        self.trouble.store(true, .release);
    }

    /// Wait until `n` connections have been accepted and wired through, or
    /// give up with a name. Five seconds against a dial that takes
    /// milliseconds: the failure this bounds is a proxy that never answered,
    /// and a test for a dead socket that itself never finishes is a test
    /// nobody can read the result of.
    fn linked(self: *Proxy, n: usize) !void {
        for (0..5_000) |_| {
            if (self.count.load(.acquire) >= n) return;
            if (self.trouble.load(.acquire)) return error.TheProxyCouldNotReachPostgres;
            try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
        }
        return error.TheProxyNeverSawTheConnection;
    }

    /// Kill connection `index` from the client's point of view: both pumps
    /// stopped, then the client-facing socket reset rather than closed, then
    /// the server-facing one closed so the backend gives up its transaction.
    ///
    /// The header says why the order and the reset are the whole of it.
    fn cut(self: *Proxy, index: usize) void {
        const link = &self.links[index];
        if (link.closed) return;
        link.up.cancel(self.io);
        link.down.cancel(self.io);

        // `SO_LINGER` on with no time to linger: the kernel sends RST on
        // `close` instead of FIN, whatever is or is not in the send queue.
        const linger: std.posix.linger = .{ .onoff = 1, .linger = 0 };
        std.posix.setsockopt(
            link.client.socket.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.LINGER,
            std.mem.asBytes(&linger),
        ) catch {};

        link.client.close(self.io);
        link.upstream.close(self.io);
        link.closed = true;
    }

    /// Stop the accept loop, then every pump, then close what is left. The
    /// loop first, so that no link appears while the rest are being closed.
    fn close(self: *Proxy, serving: *std.Io.Future(void)) void {
        serving.cancel(self.io);
        for (self.links[0..self.count.load(.acquire)]) |*link| {
            if (link.closed) continue;
            link.up.cancel(self.io);
            link.down.cancel(self.io);
            link.client.close(self.io);
            link.upstream.close(self.io);
            link.closed = true;
        }
        self.server.deinit(self.io);
    }
};

/// The URL the pool is given: the real one with its authority pointed at
/// the proxy. User, password, database and query string travel untouched,
/// which is what lets `sslmode` and the rest mean what they meant.
fn rewritten(uri: std.Uri, port: u16, buf: []u8) ![]const u8 {
    var through = uri;
    through.host = std.Uri.Component{ .raw = "127.0.0.1" };
    through.port = port;
    var w: std.Io.Writer = .fixed(buf);
    try through.format(&w);
    return w.buffered();
}

/// A loop, a proxy on it, and a `Db` of one connection dialled through the
/// proxy — or null when `DATABASE_URL` is unset, which skips.
///
/// Heap-allocated because the accept loop holds a pointer to the proxy and
/// the pool holds the loop; neither may move once started.
const Harness = struct {
    threaded: std.Io.Threaded,
    proxy: Proxy,
    serving: std.Io.Future(void),
    db: sql.Db,
    run: core.Run,
    url_buf: [1024]u8,
    url: []const u8,

    fn open() !?*Harness {
        const url = live_config.database_url orelse return null;
        const uri = try std.Uri.parse(url);
        // A proxy over TCP has nothing to stand in front of when the URL
        // names a unix socket, which pg.zig reads as a host beginning `/`.
        if (uri.host) |component| {
            var decoded: [std.Io.net.HostName.max_len]u8 = undefined;
            const host = try component.toRaw(&decoded);
            if (host.len > 0 and host[0] == '/') return null;
        }

        const gpa = testing.allocator;
        const h = try gpa.create(Harness);
        errdefer gpa.destroy(h);
        h.threaded = .init(gpa, .{});
        errdefer h.threaded.deinit();
        const io = h.threaded.io();

        h.proxy = try Proxy.open(io, uri);
        errdefer h.proxy.server.deinit(io);
        h.serving = try io.concurrent(Proxy.serve, .{&h.proxy});
        errdefer h.serving.cancel(io);

        h.url = try rewritten(uri, h.proxy.port, &h.url_buf);
        h.run = .init(gpa);
        errdefer h.run.deinit();

        // One connection, dialled here: `size = 1` is what makes "the
        // connection the transaction holds" a thing the proxy can point at,
        // and `connect_on_init = size` is the constraint every test on
        // `std.Io.Threaded` is under — the reconnector cannot park here.
        h.db = .init(gpa, h.url, .{ .size = 1, .connect_on_init = 1, .unchecked = true });
        try h.db.nilo_start(io, .off);
        errdefer {
            h.db.nilo_stop();
            h.db.deinit();
        }
        try h.proxy.linked(1);

        _ = try h.db.exec(&h.run, "DROP TABLE IF EXISTS \"" ++ table ++ "\"", .{});
        _ = try h.db.exec(&h.run, "CREATE TABLE \"" ++ table ++ "\" (\"id\" bigint PRIMARY KEY, \"label\" text NOT NULL)", .{});
        _ = try h.db.exec(&h.run, "INSERT INTO \"" ++ table ++ "\" (\"id\", \"label\") VALUES (1, 'taken')", .{});
        return h;
    }

    fn close(h: *Harness) void {
        const gpa = testing.allocator;
        // On the replacement connection, which is half of what is being
        // checked: the pool came back through the proxy.
        _ = h.db.exec(&h.run, "DROP TABLE IF EXISTS \"" ++ table ++ "\"", .{}) catch {};
        h.db.nilo_stop();
        h.db.deinit();
        h.proxy.close(&h.serving);
        h.run.deinit();
        h.threaded.deinit();
        gpa.destroy(h);
    }
};

/// The one row that is already there, offered again.
fn clash(h: *Harness, tx: *sql.Db.Tx) !Seat {
    return tx.insert(Seat, &h.run, .{ .id = @as(i64, 1), .label = "clash" });
}

test "a unique violation followed by a dead socket is reported as the dead socket, not the violation" {
    const h = (try Harness.open()) orelse return error.SkipZigTest;
    defer h.close();

    const dirty_before = try sql.postgres.dirtyConnections();

    var tx = try h.db.begin(&h.run, .{});
    defer tx.deinit();
    // `id` is the key and row 1 is there: the server answers, the
    // connection's `err` holds `23505`, and pg.zig's state is `.fail`.
    try testing.expectError(error.AlreadyExists, clash(h, &tx));

    h.proxy.cut(0);

    // The sentence the roadmap carried: a second statement after the socket
    // died. Before `fresh` this read the `23505` still on the connection and
    // said `AlreadyExists` for an UPDATE nothing had refused. The transaction
    // is aborted, so `revive` lets the statement out to be answered `25P02`,
    // and what it meets is the cut socket: `Disconnected` is the truth.
    try testing.expectError(
        error.Disconnected,
        tx.exec(&h.run, "UPDATE \"" ++ table ++ "\" SET \"label\" = 'again' WHERE \"id\" = 1", .{}),
    );

    // The dead half of an aborted transaction: aborted at the server *and*
    // the socket gone. The commit sends no COMMIT — the transaction is
    // aborted, so it is rolled back instead — and the ROLLBACK cannot reach
    // the server, which is what `Disconnected` says. The pool throws the
    // connection away: `pg_pool_dirty` moves by one, where the live-aborted
    // case in `live.zig` holds it still.
    try testing.expectError(error.Disconnected, tx.commit());
    try testing.expectEqual(dirty_before + 1, try sql.postgres.dirtyConnections());

    // Replaced on the spot, through the proxy, and the next statement runs
    // on the replacement.
    try h.proxy.linked(2);
    try testing.expectEqual(
        @as(usize, 1),
        try h.db.exec(&h.run, "UPDATE \"" ++ table ++ "\" SET \"label\" = 'after' WHERE \"id\" = 1", .{}),
    );
}

test "a commit on an aborted transaction whose socket has since died reaches the socket and says so" {
    const h = (try Harness.open()) orelse return error.SkipZigTest;
    defer h.close();

    const dirty_before = try sql.postgres.dirtyConnections();

    var tx = try h.db.begin(&h.run, .{});
    defer tx.deinit();
    try testing.expectError(error.AlreadyExists, clash(h, &tx));

    h.proxy.cut(0);

    // The one path where a stale `err` and a real transport failure meet.
    // `fresh` reads the `23505` as an aborted transaction and empties `err`,
    // so the commit rolls back rather than committing, and the ROLLBACK is
    // the first thing to touch the socket since the reset: `ECONNRESET` on
    // the write, `Disconnected` at the caller. Without `fresh` the same write
    // failure would have been reported as the `AlreadyExists` still sitting
    // on the connection — which is the bug, verbatim.
    try testing.expectError(error.Disconnected, tx.commit());
    try testing.expectEqual(dirty_before + 1, try sql.postgres.dirtyConnections());

    try h.proxy.linked(2);
    try testing.expectEqual(
        @as(usize, 1),
        try h.db.exec(&h.run, "UPDATE \"" ++ table ++ "\" SET \"label\" = 'after' WHERE \"id\" = 1", .{}),
    );
}
