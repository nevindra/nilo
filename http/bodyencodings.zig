//! A route that reads a `Content-Encoding` itself (ADR 283).
//!
//! ```zig
//! try app.with(nilo.bodyEncodings(.{"snappy"})).post("/api/v1/write", remoteWrite);
//!
//! fn remoteWrite(c: *nilo.Ctx) !void {
//!     const packed_bytes = (try c.body()).view(); // as they arrived
//!     const coding = c.header("content-encoding"); // "snappy", or null for identity
//!     // ... the handler decodes, and caps what it decodes to ...
//! }
//! ```
//!
//! nilo decodes `gzip` and refuses every other `Content-Encoding` with a 415
//! (ADR 089), and that is right as the default: handing compressed bytes to a
//! JSON parser was the bug the refusal fixed. What it left without an answer
//! is the receiver whose protocol *is* a coding nilo does not read. Prometheus
//! remote-write sends a protobuf body under snappy's block format and no
//! client setting avoids it; an OTLP route may want zstd; a gateway forwarding
//! a body untouched wants every coding there is. nilo implements none of
//! them. The route says it reads them, and gets the bytes.
//!
//! ## What the route gets
//!
//! A body under a coding named here reaches `c.body()` (and `c.bodyStream()`)
//! exactly as it arrived, still compressed, and the coding is in
//! `c.header("content-encoding")`. `max_body` (or the route's `maxBody`) is
//! applied to those compressed bytes, so a 413 is on the wire length. What the
//! bytes inflate to is the handler's to bound, as it is the one that knows
//! the format; a decoder that trusts a length the sender wrote is the
//! decompression bomb nilo's own gzip path checks for.
//!
//! Naming `"gzip"` here passes gzip through undecoded too, for a route that
//! forwards or stores the bytes. A route that does not name it still gets
//! gzip inflated, as every route does.
//!
//! **A typed body is not handed these bytes.** `c.json`, `c.form` and a typed
//! `body: T` on a route whose body arrived under a coding it passed through
//! answer a 415 saying the route reads that body as data and was sent a
//! compressed one: those readers parse what they are given, and the
//! compressed bytes are not it. `c.body()` is the reader for these bytes.
//!
//! ## What is refused
//!
//! A coding the route does not name is a 415 from this middleware, carrying
//! `Accept-Encoding` with what the route reads (RFC 9110 §15.5.16 and
//! §12.5.3). Every route without this middleware is refused as it always was,
//! by the same bytes, before anything else runs.
//!
//! ## What it costs
//!
//! Nothing on a request that is not under such a coding, and nothing on an
//! App that never uses the middleware. An App that does use it re-reads the
//! head of a request that would have been a 415 anyway, once, and asks the
//! matched route's chain whether it passed the coding (`serve.zig`); the
//! request that does not trip the refusal never learns the feature exists
//! (ADR 017, ADR 283).

const std = @import("std");

const Ctx = @import("ctx.zig").Ctx;
const fail = @import("fail.zig");
const mw = @import("middleware.zig");

/// The middleware. `names` is a tuple or slice of `Content-Encoding` values
/// the route reads itself, known while compiling, matched ignoring case
/// against the whole header value: `"snappy"`, or `"gzip, snappy"` for a body
/// stacked under two.
///
/// What comes back is an `mw.Limited` with no limit of its own, so `with`,
/// `use` and `useOn` take it where they take `maxBody`, and the App learns
/// which functions in a chain read a coding (ADR 283).
pub fn with(comptime names: anytype) mw.Limited {
    const list = comptime listOf(names);
    return .{
        .run = passing(list),
        .limit = .{ .value = 0 },
        .encodings = list,
    };
}

fn listOf(comptime names: anytype) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (names) |name| {
            const value: []const u8 = name;
            if (value.len == 0) @compileError(
                "nilo: bodyEncodings was handed an empty Content-Encoding.\n" ++
                    "  Name the coding the route reads, as `nilo.bodyEncodings(.{\"snappy\"})`.",
            );
            if (std.ascii.eqlIgnoreCase(value, "identity")) @compileError(
                "nilo: bodyEncodings was handed \"identity\", which every route already reads.\n" ++
                    "  Name only the codings nilo does not decode: `nilo.bodyEncodings(.{\"snappy\"})`.",
            );
            if (std.mem.trim(u8, value, " \t").len != value.len) @compileError(
                "nilo: bodyEncodings was handed \"" ++ value ++ "\", which starts or ends in a space.\n" ++
                    "  A Content-Encoding is compared as it was sent, without the space around it.",
            );
            out = out ++ &[_][]const u8{value};
        }
        if (out.len == 0) @compileError(
            "nilo: bodyEncodings was handed no Content-Encoding, so the route would read none.\n" ++
                "  Name the codings it reads, as `nilo.bodyEncodings(.{\"snappy\"})`, or leave the middleware off.",
        );
        return out;
    }
}

fn passing(comptime list: []const []const u8) mw.Middleware {
    const names_gzip = comptime blk: {
        for (list) |name| {
            if (std.ascii.eqlIgnoreCase(name, "gzip") or std.ascii.eqlIgnoreCase(name, "x-gzip")) break :blk true;
        }
        break :blk false;
    };

    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            // Whether the coding is one this chain reads was settled by
            // `serve` before the chain started, against every
            // `bodyEncodings` in it together, so a coding another layer
            // named is not refused here. All that is left is to tell the
            // readers to hand the bytes over as they came.
            switch (c._request.content_encoding) {
                .identity => {},
                .gzip => if (names_gzip) c.readBodyAsSent(),
                .other => c.readBodyAsSent(),
            }
            return next.run(c);
        }
    }.run;
}

/// Whether any function in `chain` is a `bodyEncodings` that names `coding`;
/// what `serve` asks, once, about a request whose refusal the parser held
/// back (ADR 283).
pub fn chainReads(chain: []const mw.Middleware, passes: []const mw.Limited, coding: []const u8) bool {
    for (chain) |m| {
        for (passes) |l| {
            if (l.run != m) continue;
            for (l.encodings) |name| if (std.ascii.eqlIgnoreCase(coding, name)) return true;
            break;
        }
    }
    return false;
}

/// Whether `chain` has a `bodyEncodings` in it at all.
pub fn chainHasAny(chain: []const mw.Middleware, passes: []const mw.Limited) bool {
    for (chain) |m| for (passes) |l| {
        if (l.run == m and l.encodings.len > 0) return true;
    };
    return false;
}

/// The `Accept-Encoding` a 415 from this chain carries: `identity` and `gzip`
/// every route reads, then every coding a `bodyEncodings` in `chain` named,
/// once each (RFC 9110 §12.5.3, §15.5.16). Built in `arena` for the one
/// request that is refused, and not otherwise.
pub fn accepted(arena: std.mem.Allocator, chain: []const mw.Middleware, passes: []const mw.Limited) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("identity, gzip");
    for (chain, 0..) |m, i| {
        for (passes) |l| {
            if (l.run != m) continue;
            names: for (l.encodings) |name| {
                if (std.ascii.eqlIgnoreCase(name, "gzip") or std.ascii.eqlIgnoreCase(name, "x-gzip")) continue;
                // Once each, whichever layer said it first.
                for (chain[0..i]) |earlier| for (passes) |e| {
                    if (e.run != earlier) continue;
                    for (e.encodings) |seen| if (std.ascii.eqlIgnoreCase(seen, name)) continue :names;
                };
                try out.writer.print(", {s}", .{name});
            }
            break;
        }
    }
    return out.written();
}

// ---- tests ----

const testing = std.testing;
const App = @import("app.zig").App;
const nilo_testing = @import("testing.zig");
const maxbody = @import("maxbody.zig");

/// What a handler on a route that reads its own coding sees: the coding
/// named in the head, a colon, and the bytes, so a test checks both at once.
fn showBody(c: *Ctx) anyerror!void {
    const coding = if (c.header("content-encoding")) |s| s.view() else "-";
    const bytes = (try c.body()).view();
    try c.sendText(200, try std.fmt.allocPrint(c._arena, "{s}:{s}", .{ coding, bytes }));
}

fn plainEcho(c: *Ctx) anyerror!void {
    try c.sendText(200, (try c.body()).view());
}

fn streamLength(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var buf: [32]u8 = undefined;
    var total: usize = 0;
    while (try incoming.read(&buf)) |part| total += part.len;
    try c.sendText(200, try std.fmt.allocPrint(c._arena, "{d}", .{total}));
}

const Sample = struct { name: []const u8 };

fn typedSample(s: Sample) ![]const u8 {
    return s.name;
}

/// `text`, gzipped by std.
fn gzipped(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&out.writer, &window, .gzip, .default);
    try compress.writer.writeAll(text);
    try compress.finish();
    return gpa.dupe(u8, out.written());
}

test "a route that names a coding gets the bytes as they arrived and the coding they arrived under" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(.{"snappy"})).post("/api/v1/write", showBody);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    // Not text on purpose: snappy's bytes are not, and nothing here may
    // read them as though they were.
    const answer = try client.send(&app, "POST /api/v1/write HTTP/1.1\r\nHost: t\r\nContent-Encoding: snappy\r\n" ++
        "Content-Length: 6\r\n\r\n\x04\x0cabcd");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("snappy:\x04\x0cabcd", answer.body);

    // Case is not part of a coding's name, and a chunked body is the same.
    const chunked = try client.send(&app, "POST /api/v1/write HTTP/1.1\r\nHost: t\r\nContent-Encoding: Snappy\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), chunked.status);
    try testing.expectEqualStrings("Snappy:abc", chunked.body);

    // And a body under no coding is read as it always was.
    const plain = try client.post(&app, "/api/v1/write", "hi");
    try testing.expectEqual(@as(u16, 200), plain.status);
    try testing.expectEqualStrings("-:hi", plain.body);
}

test "a coding the route did not name is a 415 that says which ones it reads" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(.{"snappy"})).post("/api/v1/write", showBody);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const refused = try client.send(&app, "POST /api/v1/write HTTP/1.1\r\nHost: t\r\nContent-Encoding: br\r\n" ++
        "Content-Length: 3\r\n\r\nabc");
    try testing.expectEqual(@as(u16, 415), refused.status);
    try testing.expectEqualStrings("identity, gzip, snappy", refused.header("Accept-Encoding").?);

    // The connection is good for the next request: the body was discarded
    // rather than left in the stream.
    const next = try client.send(&app, "POST /api/v1/write HTTP/1.1\r\nHost: t\r\nContent-Encoding: snappy\r\n" ++
        "Content-Length: 2\r\n\r\nok");
    try testing.expectEqual(@as(u16, 200), next.status);
}

test "every other route is refused exactly as it is in an App that names no coding at all" {
    var plain = App.init(testing.allocator);
    defer plain.deinit();
    try plain.post("/things", plainEcho);

    var mixed = App.init(testing.allocator);
    defer mixed.deinit();
    try mixed.post("/things", plainEcho);
    try mixed.with(with(.{"snappy"})).post("/api/v1/write", showBody);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const raw = "POST /things HTTP/1.1\r\nHost: t\r\nContent-Encoding: snappy\r\nContent-Length: 3\r\n\r\nabc";
    // An answer points into the client's one buffer, which the next request
    // writes over, so the first is kept.
    const without = try testing.allocator.dupe(u8, (try client.send(&plain, raw)).raw);
    defer testing.allocator.free(without);
    const beside = try client.send(&mixed, raw);
    try testing.expectEqual(@as(u16, 415), beside.status);
    try testing.expect(std.mem.startsWith(u8, without, "HTTP/1.1 415"));
    try testing.expectEqualStrings(without, beside.raw);

    // A path that matches nothing is refused the same way, and a coding on a
    // request with no body is left alone, as it is without the feature.
    const nowhere = try client.send(&mixed, "POST /nowhere HTTP/1.1\r\nHost: t\r\nContent-Encoding: snappy\r\nContent-Length: 3\r\n\r\nabc");
    try testing.expectEqual(@as(u16, 415), nowhere.status);
    const bodyless = try client.send(&mixed, "GET /nowhere HTTP/1.1\r\nHost: t\r\nContent-Encoding: snappy\r\n\r\n");
    try testing.expectEqual(@as(u16, 404), bodyless.status);
}

test "the limit is applied to the bytes that arrived, compressed" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_body = 8;
    try app.with(with(.{"snappy"})).post("/small", showBody);
    try app.with(maxbody.with(64)).with(with(.{"snappy"})).post("/wide", showBody);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const twelve = "Content-Encoding: snappy\r\nContent-Length: 12\r\n\r\ntwelve bytes";
    const over = try client.send(&app, "POST /small HTTP/1.1\r\nHost: t\r\n" ++ twelve);
    try testing.expectEqual(@as(u16, 413), over.status);
    const wide = try client.send(&app, "POST /wide HTTP/1.1\r\nHost: t\r\n" ++ twelve);
    try testing.expectEqual(@as(u16, 200), wide.status);

    const chunked = try client.send(&app, "POST /small HTTP/1.1\r\nHost: t\r\nContent-Encoding: snappy\r\n" ++
        "Transfer-Encoding: chunked\r\n\r\n9\r\nnine byte\r\n0\r\n\r\n");
    try testing.expectEqual(@as(u16, 413), chunked.status);
}

test "gzip is inflated on such a route unless the route names it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(.{"snappy"})).post("/inflates", showBody);
    try app.with(with(.{"gzip"})).post("/forwards", showBody);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const packed_bytes = try gzipped(testing.allocator, "hello hello hello");
    defer testing.allocator.free(packed_bytes);
    const head = "Host: t\r\nContent-Encoding: gzip\r\n";

    const inflated_request = try std.fmt.allocPrint(testing.allocator, "POST /inflates HTTP/1.1\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ head, packed_bytes.len, packed_bytes });
    defer testing.allocator.free(inflated_request);
    const inflated = try client.send(&app, inflated_request);
    try testing.expectEqual(@as(u16, 200), inflated.status);
    try testing.expectEqualStrings("gzip:hello hello hello", inflated.body);

    const forwarded_request = try std.fmt.allocPrint(testing.allocator, "POST /forwards HTTP/1.1\r\n{s}Content-Length: {d}\r\n\r\n{s}", .{ head, packed_bytes.len, packed_bytes });
    defer testing.allocator.free(forwarded_request);
    const forwarded = try client.send(&app, forwarded_request);
    try testing.expectEqual(@as(u16, 200), forwarded.status);
    try testing.expect(std.mem.startsWith(u8, forwarded.body, "gzip:\x1f\x8b"));
    try testing.expectEqual(packed_bytes.len + "gzip:".len, forwarded.body.len);
}

test "a body read as a stream is handed over undecoded on a route that names its coding" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(.{"zstd"})).post("/ingest", streamLength);
    try app.post("/plain", streamLength);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const got = try client.send(&app, "POST /ingest HTTP/1.1\r\nHost: t\r\nContent-Encoding: zstd\r\nContent-Length: 40\r\n\r\n" ++
        "0123456789012345678901234567890123456789");
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqualStrings("40", got.body);
}

test "a reader that parses the body is not handed bytes the route reads itself" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(.{"snappy"})).post("/typed", typedSample);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const compressed = try client.send(&app, "POST /typed HTTP/1.1\r\nHost: t\r\nContent-Encoding: snappy\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"name\":\"wati\"}");
    try testing.expectEqual(@as(u16, 415), compressed.status);

    // The same route reads the same body when it was not sent compressed.
    const plain = try client.send(&app, "POST /typed HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"name\":\"wati\"}");
    try testing.expectEqual(@as(u16, 200), plain.status);
    try testing.expectEqualStrings("wati", plain.body);
}

test "a handler that does not ask for the coding is never handed a body under one" {
    // `with` can be forgotten on a route, or the path can reach a route the
    // chain was not meant for: `body()` is the last place the bytes stop.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(.{"snappy"})).post("/api/v1/write", showBody);
    try app.post("/other", plainEcho);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const refused = try client.send(&app, "POST /other HTTP/1.1\r\nHost: t\r\nContent-Encoding: snappy\r\nContent-Length: 3\r\n\r\nabc");
    try testing.expectEqual(@as(u16, 415), refused.status);
}

/// A type that decodes its own body: the one reader that is meant to be
/// handed bytes in a coding the route reads (`nilo_decode`, ADR 283).
const Packed = struct {
    size: usize,

    pub const nilo_content_type = "application/x-protobuf";

    pub fn nilo_decode(body: []const u8, _: std.mem.Allocator) !Packed {
        return .{ .size = body.len };
    }
};

fn sizeOfPacked(p: Packed) !usize {
    return p.size;
}

test "a type that decodes its own body is handed the bytes in the coding the route reads" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.with(with(.{"snappy"})).post("/write", sizeOfPacked);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const got = try client.send(&app, "POST /write HTTP/1.1\r\nHost: t\r\nContent-Encoding: snappy\r\n" ++
        "Content-Type: application/x-protobuf\r\nContent-Length: 5\r\n\r\n\x01\x02\x03\x04\x05");
    try testing.expectEqual(@as(u16, 200), got.status);
    try testing.expectEqualStrings("5", got.body);
}
