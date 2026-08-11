//! Responses written in pieces: a report too long to hold in memory, and a
//! stream of events a browser watches (ADR 0020).
//!
//! `zig build run-stream`, then:
//!
//! ```
//! curl localhost:8787/report.csv
//! curl -N localhost:8787/tokens      # -N, or curl buffers it for you
//! open http://localhost:8787/
//! ```

const std = @import("std");
const zfast = @import("zfast");

pub const std_options = zfast.std_options;
pub const std_options_debug_io = zfast.debug_io;

/// A report nobody wants to build in memory first. The rows go out as they
/// are produced, and the client can start reading before the last one exists.
///
/// A streaming handler asks for a `*Ctx` because the response is written
/// rather than returned. Everything else about it is an ordinary handler —
/// it can take services and typed arguments alongside.
fn report(c: *zfast.Ctx, meter: *Meter) !void {
    var body = try c.stream(200, "text/csv");
    try body.writeAll("reading,celsius\n");

    var reading: u32 = 1;
    while (reading <= 50_000) : (reading += 1) {
        try body.print("{d},{d}\n", .{ reading, meter.at(reading) });
    }

    // Required: it writes the marker saying where the body ends. Forget it
    // and zfast writes one for you, and says so in the log.
    try body.finish();
}

/// The shape an LLM front end has: tokens arriving one at a time, each one
/// wanted by the browser the moment it exists.
///
/// `live()` is what makes this deployable. Without it a `Ctrl-C` would wait
/// for every open stream to run out on its own.
fn tokens(c: *zfast.Ctx, pace: *Pace) !void {
    var events = try c.events();

    // How long the browser waits before reconnecting, if this drops.
    try events.retry(2000);

    var sent: u32 = 0;
    for (poem) |word| {
        if (!events.live()) break;
        sent += 1;
        try events.send(.{ .name = "token", .data = word });
        // Standing in for whatever is actually slow. `zfast.sleep` takes
        // milliseconds and parks this fiber; `std.Thread.sleep` would stop
        // every other request sharing its thread (ADR 0014).
        //
        // Zero under a test, where there is no Engine to park in and no
        // reason to wait — `pace` is a service so the test can say so.
        if (pace.millis > 0) try zfast.sleep(pace.millis);
    }

    // A last event with the shape of a result, so a client can tell
    // "finished" from "the connection dropped".
    try events.json("done", .{ .tokens = sent });
    try events.close();
}

const poem = [_][]const u8{
    "the",     "connection", "stays",   "open",   "and",
    "the",     "words",      "arrive",  "one",    "at",
    "a",       "time",       "because", "nobody", "knows",
    "how",     "long",       "this",    "is",     "going",
    "to",      "be",         "until",   "it",     "is",
    "finished",
};

/// A service, so the report has somewhere to get its numbers. Read-only, so
/// it needs no lock — see the rest example for the other case.
const Meter = struct {
    fn at(_: *Meter, reading: u32) i32 {
        return @intCast(15 + (reading * 7) % 20);
    }
};

/// How slowly the tokens arrive. A service rather than a constant so that a
/// test can turn it off: the point of the wait is to look right in a
/// browser, and a test is neither watching nor running inside a fiber.
const Pace = struct { millis: u64 };

fn page() []const u8 {
    return
        \\<!doctype html>
        \\<title>zfast streaming</title>
        \\<pre id="out" style="font: 16px/1.6 ui-monospace, monospace; padding: 2rem"></pre>
        \\<script>
        \\  const out = document.getElementById("out");
        \\  const events = new EventSource("/tokens");
        \\  events.addEventListener("token", e => { out.textContent += e.data + " " });
        \\  events.addEventListener("done", e => {
        \\    out.textContent += "\n\n(" + JSON.parse(e.data).tokens + " tokens)";
        \\    events.close();
        \\  });
        \\</script>
        \\
    ;
}

pub fn main() !void {
    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    var meter = Meter{};
    try app.provide(&meter);
    var pace = Pace{ .millis = 120 };
    try app.provide(&pace);

    try app.use(zfast.logger.standard);

    try app.get("/", page);
    try app.get("/report.csv", report);
    try app.get("/tokens", tokens);

    try app.listen(.{});
}

// ---- tests ----
//
// A streaming handler needs a request to write into, so these go through
// App the way every other zfast test does rather than calling the handler.

const testing = std.testing;

test "the report streams its rows, and every row arrives" {
    var app = zfast.App.init(testing.allocator);
    defer app.deinit();
    var meter = Meter{};
    try app.provide(&meter);
    try app.get("/report.csv", report);

    var client = try zfast.testing.Client.init(testing.allocator, .{ .response_bytes = 2 << 20 });
    defer client.deinit();

    const answer = try client.get(&app, "/report.csv");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expect(answer.chunked);

    // 50,000 rows through a 4 KB buffer is a lot of chunks, and what the
    // client sees is one CSV.
    const csv = try testing.allocator.alloc(u8, 2 << 20);
    defer testing.allocator.free(csv);
    const text = try answer.text(csv);
    try testing.expect(std.mem.startsWith(u8, text, "reading,celsius\n1,"));
    try testing.expectEqual(@as(usize, 50_001), std.mem.count(u8, text, "\n"));
}

test "the token stream is an event stream, and says when it is done" {
    var app = zfast.App.init(testing.allocator);
    defer app.deinit();
    var pace = Pace{ .millis = 0 };
    try app.provide(&pace);
    try app.get("/tokens", tokens);

    var client = try zfast.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/tokens");
    try testing.expectEqualStrings("text/event-stream", answer.header("Content-Type").?);

    var buf: [8192]u8 = undefined;
    const events = try answer.text(&buf);
    try testing.expect(std.mem.indexOf(u8, events, "event: token\ndata: the\n\n") != null);
    // The last event has the shape of a result, so a client can tell
    // "finished" from "the connection dropped".
    try testing.expect(std.mem.endsWith(u8, events, "event: done\ndata: {\"tokens\":26}\n\n"));
}
