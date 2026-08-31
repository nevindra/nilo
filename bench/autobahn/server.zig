//! The server the Autobahn suite is run against.
//!
//! [ADR 0033](../../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
//! is the whole reason this file exists. Every framing test under `http/` was
//! written from RFC 6455 by the person who wrote the framing, so the close-code
//! and UTF-8 rules ([ADR 0052](../../docs/adr/0052-a-message-is-copied-once-and-framed-once.md))
//! had only ever been seen to pass. `wstest` is the suite every implementation
//! of that RFC is measured by, and it is written by somebody who has never read
//! this code.
//!
//! ```
//! zig build autobahn-server -Doptimize=ReleaseFast
//! bash bench/autobahn/run.sh
//! ```
//!
//! `run.sh` starts this, drives the suite at it from a container, and prints
//! the cases that are not `OK`. [`README.md`](README.md) says how to read the
//! result, and [`bench/result/http.md`](../result/http.md) is where a run that
//! changed a decision gets written down.
//!
//! ## One route and nothing beside it
//!
//! Unlike `bench/ws_server.zig` there are no controls here, because nothing is
//! being measured: a conformance run answers yes or no about 517 cases and the
//! number beside them is meaningless. What matters is that the loop is the
//! ordinary one out of the guide, so a case that fails is nilo's and not the
//! harness's.
//!
//! `max_message` is 16 MiB rather than the framework's 16 KiB, and that is
//! reading the suite rather than being generous: cases 9.1–9.6 send messages up
//! to 16 MiB, and a server that refuses them with a 1009 is *correct* and still
//! recorded as a failure, because Autobahn is asking whether the frame was
//! reassembled. The ceiling is the harness's, not a recommendation.
//!
//! `idle_ms` is 0, which is not the framework's 30,000. A ping nobody asked for
//! arriving in the middle of case 2.x is a frame the suite did not expect, and
//! the keepalive is not what is under test here.

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// Big enough for case 9.6.6, which is one 16 MiB text message. See the header.
const max_message = 16 * 1024 * 1024;

/// The loop out of the guide, unchanged. `receive` returns the message whole,
/// `send` puts it back with the same opcode, and everything between those two
/// lines — masking, fragment reassembly, control frames arriving in the middle
/// of a message, the close handshake — is what the suite is actually reading.
fn echo(socket: *nilo.Socket) !void {
    while (try socket.receive()) |message| {
        try socket.send(message.kind, message.data);
    }
}

fn conformance(c: *nilo.Ctx) !void {
    return c.upgradeWith(echo, {}, .{ .idle_ms = 0, .max_message = max_message });
}

fn portFrom(init: std.process.Init) u16 {
    const text = init.minimal.environ.getPosix("PORT") orelse return 9001;
    return std.fmt.parseInt(u16, text, 10) catch 9001;
}

pub fn main(init: std.process.Init) !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    // `wstest` connects to the URL in `fuzzingclient.json` exactly as written,
    // once per case, so one route at the root is the whole surface.
    try app.get("/", conformance);

    try app.listen(.{ .port = portFrom(init) });
}
