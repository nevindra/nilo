//! nilo answering the probe's one method the way the probe does: an empty
//! message and grpc-status 0 after 20 ms, so a client's calls overlap. Plain
//! HTTP/1.1 on 8788 and gRPC on 50051, where every client in `run.sh` dials.
//! `/calls` over HTTP/1.1 says how many were answered.

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;

var answered: std.atomic.Value(u64) = .init(0);
var bytes_in: std.atomic.Value(u64) = .init(0);

fn exportTraces(c: *nilo.Ctx) anyerror!void {
    const body = try c.body();
    _ = bytes_in.fetchAdd(body.view().len, .monotonic);
    try nilo.sleep(20);
    _ = answered.fetchAdd(1, .monotonic);
    try c.send(200, "application/grpc", "");
}

/// No sleep, for `bench/mem.py --grpc`: it opens connections one after the
/// other, and 20 ms each puts the first ones past the idle limit before the
/// last is open.
fn echo(c: *nilo.Ctx) anyerror!void {
    const body = try c.body();
    try c.send(200, "application/grpc", body.view());
}

/// HttpArena's `unary-grpc` method: `SumRequest{a, b}` in, `SumReply{result}`
/// out, both proto3 int32 varints decoded and encoded by hand, which is the
/// whole of the codec this method needs.
fn getSum(c: *nilo.Ctx) anyerror!void {
    const body = (try c.body()).view();
    var a: i32 = 0;
    var b: i32 = 0;
    var i: usize = 0;
    while (i < body.len) {
        const tag = body[i];
        i += 1;
        var v: u64 = 0;
        var shift: u6 = 0;
        while (i < body.len) : (shift += 7) {
            const byte = body[i];
            i += 1;
            v |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) break;
        }
        switch (tag) {
            0x08 => a = @truncate(@as(i64, @bitCast(v))),
            0x10 => b = @truncate(@as(i64, @bitCast(v))),
            else => {},
        }
    }
    var out: [11]u8 = undefined;
    var n: usize = 0;
    const sum = a +% b;
    if (sum != 0) {
        out[0] = 0x08;
        n = 1;
        var v: u64 = @bitCast(@as(i64, sum));
        while (v >= 0x80) : (v >>= 7) {
            out[n] = @as(u8, @truncate(v)) | 0x80;
            n += 1;
        }
        out[n] = @truncate(v);
        n += 1;
    }
    try c.send(200, "application/grpc", out[0..n]);
}

fn calls(c: *nilo.Ctx) anyerror!void {
    const text = try std.fmt.allocPrint(c.arena(), "{d} {d}\n", .{ answered.load(.monotonic), bytes_in.load(.monotonic) });
    try c.send(200, "text/plain", text);
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();
    try app.post("/opentelemetry.proto.collector.trace.v1.TraceService/Export", exportTraces);
    try app.post("/test.Echo/Say", echo);
    try app.post("/benchmark.BenchmarkService/GetSum", getSum);
    try app.get("/calls", calls);
    const threads: u8 = if (std.c.getenv("NILO_THREADS")) |t| std.fmt.parseInt(u8, std.mem.span(t), 10) catch 0 else 0;
    try app.listen(.{
        .threads = threads,
        .port = 8788,
        .also = &.{
            .{ .address = "127.0.0.1", .port = 50051 },
            // gRPC over TLS, `h2` by ALPN, with the suite's self-signed
            // certificate: run from the repository root.
            .{ .address = "127.0.0.1", .port = 50443, .tls = .{
                .cert = "http/testdata/tls/localhost.pem",
                .key = "http/testdata/tls/localhost-key.pem",
            } },
        },
    });
}
