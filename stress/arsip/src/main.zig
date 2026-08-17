//! arsip — a document archive, built to find out what nilo is like to use.
//!
//! ```
//! # a first run needs one setting and nothing else
//! export ARSIP_SESSION_SECRET=$(head -c 24 /dev/urandom | base64)   # 32 bytes
//! zig build run
//!
//! # whoever signs up first is the curator
//! curl -c jar -X POST localhost:8801/v1/sign-up \
//!      -d '{"email":"wati@example.dev","name":"Wati","password":"kopi-tubruk"}'
//! curl -b jar localhost:8801/v1/whoami
//!
//! # the cookie is the whole session — nothing is kept on the server
//! curl -b jar -X PUT localhost:8801/v1/folders/kantor -d '{"name":"Kantor"}'
//! curl localhost:8801/v1/folders                       # 401 without the jar
//!
//! curl -b jar -X POST localhost:8801/v1/folders/kantor/docs -d '{
//!   "title": "Laporan Q3",
//!   "kind": "invoice",
//!   "meta":  {"author":"wati","type":"invoice","pages":12},
//!   "sections": [{"heading":"Ringkasan","lines":["Naik 12%"]}]
//! }'
//! curl -b jar 'localhost:8801/v1/docs?kind=invoice&sort=title'
//! curl -b jar localhost:8801/v1/docs/1        # `public` is a v7, sortable
//!
//! curl -b jar -X POST localhost:8801/v1/sign-out
//! curl -b jar localhost:8801/v1/whoami                 # 401 again
//!
//! # and what a wrong password says, at the same cost as a wrong address
//! curl -X POST localhost:8801/v1/sign-in -d '{"email":"wati@example.dev","password":"salah"}'
//! curl -X POST localhost:8801/v1/sign-in -d '{"email":"nobody@example.dev","password":"salah"}'
//!
//! curl localhost:8801/openapi.json | jq '.components.schemas | keys'
//! ```

const std = @import("std");
const nilo = @import("nilo_http");
const config = @import("nilo_config");

const auth = @import("auth.zig");
const handlers = @import("handlers.zig");
const settings_mod = @import("settings.zig");
const Archive = @import("archive.zig").Archive;
const accounts_mod = @import("accounts.zig");
const Accounts = accounts_mod.Accounts;
const Settings = settings_mod.Settings;

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

fn health() struct { status: []const u8, milestone: u8 } {
    return .{ .status = "ok", .milestone = 2 };
}

/// `std.process.Init` rather than a bare `main`, because that is where the
/// environment block lives and `nilo_config` reads it where it lies rather than
/// copying it (ADR 0043).
pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;

    // A fixed buffer rather than stderr, because `report(w)` wants a
    // `*std.Io.Writer` and getting one for a file in Zig 0.16 needs an `Io` —
    // which is the one thing a program reading its settings *before* the event
    // loop has not got. So the report is rendered into memory and printed with
    // `std.debug.print`, which needs nothing. See item 11 in `DX.md`.
    var report_buf: [8192]u8 = undefined;

    // The settings, before anything else opens. A `.env` is text somebody else
    // read (ADR 0064) — the module opens no file, so this does. The text has to
    // outlive the Settings, which is why it comes off the long-lived allocator
    // and is never freed.
    const dotenv = readDotenv(gpa);
    const sources: settings_mod.Sources = .{
        .env = .{ .environ = init.minimal.environ },
        .file = .{ .text = dotenv },
    };

    // Bad lines in the file are a different question from settings that will not
    // convert, and are reported first because one explains the other. A report
    // never quotes a value, because a `.env` is where a password lives.
    {
        var w = std.Io.Writer.fixed(&report_buf);
        try sources.file.report(&w);
        if (w.end > 0) std.debug.print("{s}", .{report_buf[0..w.end]});
    }

    const read = sources.read();
    const settings = read.value() orelse {
        var w = std.Io.Writer.fixed(&report_buf);
        try read.report(&w);
        std.debug.print("arsip cannot start:\n{s}\n" ++
            "ARSIP_SESSION_SECRET wants 32 bytes. One way to get some:\n" ++
            "    export ARSIP_SESSION_SECRET=$(head -c 24 /dev/urandom | base64)\n", .{report_buf[0..w.end]});
        std.process.exit(2);
    };

    // Checked here rather than at `listen()` so the message can say which
    // setting: `listen()` knows it was handed the wrong number of bytes but not
    // what the operator would have to change.
    if (settings.session_secret.len != 32) {
        std.debug.print(
            "arsip cannot start: {s} has to be exactly 32 bytes, and that one is {d}\n",
            .{ settings_mod.prefix ++ "SESSION_SECRET", settings.session_secret.len },
        );
        std.process.exit(2);
    }

    var app = nilo.App.init(gpa);
    defer app.deinit();

    var archive: Archive = .init(gpa);
    defer archive.deinit();
    try app.provide(&archive);

    // M3. The accounts live in a file now, and this is the whole of "start the
    // database": no service to run beside the process, no URL, no credentials.
    //
    // The migration comes first and on a database of its own, because the pool
    // this one will use is opened by `listen()` and nothing before it — see
    // `accounts.migrateFile`, which is item 19 in `DX.md`.
    accounts_mod.migrateFile(gpa, settings.db_path) catch |err| {
        std.debug.print(
            "arsip cannot start: the accounts database at \"{s}\" could not be opened ({t})\n",
            .{ settings.db_path, err },
        );
        std.process.exit(2);
    };

    var db: accounts_mod.Db = .init(gpa, settings.db_path, .{ .size = settings.db_pool });
    defer db.deinit();

    // Compared against the table it names, once, during `listen()` rather than
    // at the first request that reached it.
    db.checking(&.{accounts_mod.Account});

    var accounts: Accounts = .{ .db = &db };
    try app.provide(&accounts);
    try app.provide(&db);

    // Two services of different shapes. `*const Settings` and `*Settings` are
    // different types and are looked up as such, so a read-only service says so
    // in the signature of every handler that takes one.
    try app.provide(@as(*const Settings, &settings));

    try app.use(nilo.logger.with(.{ .request_id = true }));

    try app.get("/health", health);

    // One constant, used twice: `group` needs the prefix and so does the guard,
    // which has to know what `/sign-up` is called from the outside. Item 13 in
    // `DX.md` is why the second one exists.
    const v1_prefix = "/v1";
    const v1 = app.group(v1_prefix);
    try auth.mountOpen(v1);
    try handlers.mount(v1_prefix, v1);

    app.docs(.{
        .title = "arsip",
        .version = "0.2.0",
        .description = "A document archive, and a stress test of nilo's DX.",
    });

    try app.listen(.{
        .port = settings.port,
        .session_secret = settings.session_secret,
    });
}

/// Absent is not an error: a `.env` is a convenience for a laptop, and a
/// deployment sets variables. Unreadable is not an error either, for the same
/// reason — what would be an error is a *malformed* one, and `report` says so.
///
/// **The `std.Io.Threaded` is the whole story of item 12 in `DX.md`.**
/// `nilo_config` is built to run before the event loop and opens no file, which
/// is right; but reading one in Zig 0.16 needs an `Io`, and the loop that will
/// supply one does not exist until `listen()`. So a program that wants a `.env`
/// stands up std's own threaded implementation for the length of one small read.
/// Nine lines instead of the one the reference shows.
fn readDotenv(gpa: std.mem.Allocator) []const u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    return std.Io.Dir.cwd().readFileAlloc(io, ".env", gpa, .limited(64 * 1024)) catch "";
}

test {
    _ = @import("accounts.zig");
    _ = @import("archive.zig");
    _ = @import("auth.zig");
    _ = @import("copy.zig");
    _ = @import("domain.zig");
    _ = @import("handlers.zig");
    _ = @import("intake.zig");
    _ = @import("settings.zig");
    _ = @import("wire.zig");
}
