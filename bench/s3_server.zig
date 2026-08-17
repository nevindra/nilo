//! What an object store costs a *server*, with the controls that say how much
//! of it is the object store.
//!
//! The whole difficulty of benchmarking an S3 client is that almost none of
//! what you measure is the client. A route that reads a megabyte out of MinIO
//! and answers with it spends its time in three places — this language's HTTP
//! server, the round trip, and moving a megabyte — and the S3 client is the
//! smallest of the three. Compare two languages on that route alone and the
//! number is mostly a comparison of their HTTP servers.
//!
//! So seven routes, and **four of them exist to be subtracted**:
//!
//! - `/health` — a constant `[]const u8`, no `Ctx`, no store. The floor, and
//!   the same route `bench/sql_server.zig` and `bench/fetch_server.zig` use.
//! - `/warm/1k`, `/warm/1m` — the same bytes `/o/1k` and `/o/1m` answer with,
//!   out of the request arena, with no object store anywhere near them. **The
//!   control the comparison is built on**: `/o/1k` minus `/warm/1k` is what a
//!   client costs, and `/warm/1k` on its own is what the HTTP server costs.
//! - `/presign` — the signer, and nothing else. No socket, no permit, no
//!   round trip. The one route where the number is *entirely* SigV4, which is
//!   the part of this module that is actually nilo's code (ADR 0069).
//! - `/o/1k`, `/o/64k`, `/o/1m` — one `bucket.get` each, bounded, held whole.
//!   Three sizes because the interesting question is where the cost stops
//!   being per-call and starts being per-byte.
//!
//! Those seven are the contract `bench/compare-s3/drive.py` holds every
//! candidate to, byte for byte. Two more are nilo's own and are not compared,
//! because they have no counterpart that would be answering the same question:
//!
//! - `/stream/1m` — the same megabyte piped from the store to the client
//!   without ever being held whole. Chunked, so its framing differs from
//!   `/o/1m` and it is not in the comparison; what it prices is the arena.
//! - `/head/1k` — a HEAD to the store, so there is one route whose cost is a
//!   round trip with no body attached to it.
//!
//! ```
//! docker run -d --name nilo-s3-minio -p 9100:9000 \
//!   -e MINIO_ROOT_USER=niloadmin -e MINIO_ROOT_PASSWORD=nilosecret123 \
//!   quay.io/minio/minio server /data
//! python3 bench/s3_setup.py                 # the bucket and the three objects
//!
//! zig build -Doptimize=ReleaseFast bench-s3-server
//! S3_ENDPOINT=http://127.0.0.1:9100 S3_ACCESS_KEY=niloadmin \
//!   S3_SECRET_KEY=nilosecret123 ./zig-out/bin/nilo-bench-s3-server
//!
//! ./bench/bench.sh http://127.0.0.1:8792/o/1k
//! python3 bench/mem.py --port 8792 --path /o/1k
//! ```
//!
//! The whole thing, against Go, Rust and Bun, is
//! `python3 bench/compare-s3/drive.py`, and what it found is in
//! [`bench/result/s3.md`](result/s3.md).

const std = @import("std");
const nilo = @import("nilo_http");
const s3 = @import("nilo_s3");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// **The bucket is compiled in, and that is the design rather than a shortcut**
/// (ADR 0068). `S3_BUCKET` would make this a runtime string and every URL a
/// concatenation; a name known here is a `host` and a `prefix` built once in
/// `open` and never again.
const bucket_name = "nilo-test";

/// Path style, because `127.0.0.1` cannot carry a bucket as a DNS label and
/// because MinIO wants it either way.
///
/// `max_bytes` is 2 MB so `/o/1m` fits with room to spare — a ceiling exactly
/// on the object would make the benchmark a test of the ceiling. `key_max` is
/// 128 rather than the default 512 because it sizes a stack buffer in every
/// call, and by [ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)
/// a byte of handler stack is a byte on every idle connection.
const Files = s3.Bucket(bucket_name, .{
    .style = .path,
    .max_bytes = 2 << 20,
    .key_max = 128,
});

const one_k = "bench/1k.bin";
const sixty_four_k = "bench/64k.bin";
const one_m = "bench/1m.bin";

/// What `bench/s3_setup.py` wrote, which is what every candidate has to answer
/// with. A byte here that disagrees with that script is a benchmark comparing
/// two different payloads and reporting it as a win.
const filler = 'x';

const octets = "application/octet-stream";

// ------------------------------------------------------------------ the floor

/// No `Ctx`, no service, no allocation.
fn health() []const u8 {
    return "alive\n";
}

/// The same 1,024 bytes `/o/1k` answers with, out of the same arena, with no
/// object store involved at all.
///
/// **This is the control that makes the cross-language table mean something.**
/// Bun's HTTP server and nilo's are not the same speed, and neither are Go's
/// and Rust's; without this route a comparison of four S3 clients is mostly a
/// comparison of four HTTP servers wearing an S3 client as a hat.
fn warm1k(c: *nilo.Ctx) !void {
    const bytes = try c.arena().alloc(u8, 1 << 10);
    @memset(bytes, filler);
    return c.send(200, octets, bytes);
}

fn warm1m(c: *nilo.Ctx) !void {
    const bytes = try c.arena().alloc(u8, 1 << 20);
    @memset(bytes, filler);
    return c.send(200, octets, bytes);
}

// ------------------------------------------------------------------ the store

fn get1k(files: *Files, c: *nilo.Ctx) !void {
    const got = try files.get(c, one_k);
    return c.send(200, octets, got.bytes.view());
}

fn get64k(files: *Files, c: *nilo.Ctx) !void {
    const got = try files.get(c, sixty_four_k);
    return c.send(200, octets, got.bytes.view());
}

fn get1m(files: *Files, c: *nilo.Ctx) !void {
    const got = try files.get(c, one_m);
    return c.send(200, octets, got.bytes.view());
}

/// The signer with everything else taken away: no socket, no permit, no
/// deadline, no round trip.
///
/// A derived key changes once a day and is cached for the day (ADR 0069), so
/// what this measures per request is one SHA-256 over the canonical request,
/// one HMAC over the string to sign, and the hex. Every SDK in the comparison
/// has a presign of its own, every one of them caches the same way or does
/// not, and the URL each returns can be fetched — which makes this the one
/// route where correctness and cost are checked by the same call.
fn presign(files: *Files, c: *nilo.Ctx) !nilo.Str {
    const link = try files.presign(c, one_k, 900);
    return link.url;
}

// ------------------------------------------ nilo's own, outside the contract

/// The megabyte, from the store to the client, never held whole.
///
/// `/o/1m` puts a megabyte in the request arena; this puts 64 KB on the stack
/// and moves the object through it. By ADR 0063 that trade is the wrong way
/// round for an idle connection — arena is per request, stack is per
/// connection at the high-water mark — and the point of having both routes is
/// that `bench/mem.py` can price it rather than argue about it.
///
/// Chunked, because a stream has no length to announce, so its wire bytes
/// differ from `/o/1m`'s and the driver leaves it out of the comparison.
fn stream1m(files: *Files, c: *nilo.Ctx) !void {
    var transfer: [64 << 10]u8 = undefined;
    var reading: Files.Reading = .idle;
    defer reading.close();

    try files.stream(c, one_m, &reading, &transfer);

    var body = try c.stream(200, octets);
    _ = try reading.pipe(&body.writer);
    try body.finish();
}

/// One round trip with no body on the way back — the control that separates
/// what a request to the store costs from what its answer costs.
fn head1k(files: *Files, c: *nilo.Ctx) !void {
    const meta = try files.head(c, one_k);
    // `send` puts these bytes on the wire before it returns, so the buffer is
    // still alive when they are read. A `c.str` of it would not be: `str`
    // stamps a lifetime on a slice rather than copying it, and this frame is
    // gone by the time the response is written.
    var out: [24]u8 = undefined;
    return c.send(200, "text/plain", std.fmt.bufPrint(&out, "{d}\n", .{meta.len}) catch unreachable);
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;

    const endpoint = init.minimal.environ.getPosix("S3_ENDPOINT") orelse {
        std.debug.print(
            "bench-s3-server needs an object store.\n" ++
                "  docker run -d --name nilo-s3-minio -p 9100:9000 \\\n" ++
                "    -e MINIO_ROOT_USER=niloadmin -e MINIO_ROOT_PASSWORD=nilosecret123 \\\n" ++
                "    quay.io/minio/minio server /data\n" ++
                "  python3 bench/s3_setup.py\n" ++
                "  S3_ENDPOINT=http://127.0.0.1:9100 S3_ACCESS_KEY=niloadmin \\\n" ++
                "    S3_SECRET_KEY=nilosecret123 ./zig-out/bin/nilo-bench-s3-server\n" ++
                "\nThe bucket is compiled in as \"" ++ bucket_name ++ "\": it is a type.\n",
            .{},
        );
        return;
    };

    var store = try s3.open(gpa, .{
        .endpoint = endpoint,
        .region = init.minimal.environ.getPosix("S3_REGION") orelse "us-east-1",
        .credentials = .{ .static = .{
            .access_key_id = init.minimal.environ.getPosix("S3_ACCESS_KEY") orelse "niloadmin",
            .secret_access_key = init.minimal.environ.getPosix("S3_SECRET_KEY") orelse "nilosecret123",
        } },
        // Sized so the gate is not what runs out first. The question this
        // server asks is what a call costs, and a permit queue of 64 would cap
        // the answer at 64 in flight however cheap the call was — the same
        // reasoning `bench/sql_server.zig` gives for its pool size.
        .max_in_flight = 4096,
    });
    defer store.deinit();

    var files = try Files.open(&store);
    defer files.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&files);

    try app.get("/health", health);
    try app.get("/warm/1k", warm1k);
    try app.get("/warm/1m", warm1m);
    try app.get("/o/1k", get1k);
    try app.get("/o/64k", get64k);
    try app.get("/o/1m", get1m);
    try app.get("/presign", presign);
    try app.get("/stream/1m", stream1m);
    try app.get("/head/1k", head1k);

    // 8792, one past `bench/fetch_server.zig`, for the reason that file gives:
    // a load generator pointed at a port somebody else is holding measures
    // somebody else's routes and reports the difference as non-2xx.
    //
    // No logger. A line per request would measure the logger.
    try app.listen(.{ .port = 8792 });
}
