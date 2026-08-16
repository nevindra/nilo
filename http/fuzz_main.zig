//! `zig build fuzz` — generate requests, throw them at the parser, and
//! check the properties in `fuzz.zig` over every one.
//!
//! This exists because the coverage-guided fuzzer does not work: `zig
//! build test --fuzz` fails to compile in Zig 0.16.0, inside std's own
//! test runner, for any project at all. The properties are written as
//! `std.testing.fuzz` targets so that they become coverage-guided the day
//! that is fixed; this is what runs in the meantime, and it drives the
//! same `checkOne`, so the two cannot drift.
//!
//! What it generates is not random bytes, mostly. Random bytes are a bad
//! way to test an HTTP parser: essentially none of them are a request, so
//! the run spends its time re-checking that nonsense is refused. Three
//! quarters of the inputs here are built to be nearly valid — a real
//! request line, real header names, real framing — and then damaged in one
//! place. Bugs in a parser live at "nearly valid", not at "random".
//!
//! ```
//! zig build fuzz                                  # 50,000 inputs, random seed
//! zig build fuzz -- --iterations 2000000          # longer
//! zig build fuzz -- --seed 0x4a1f...              # the seed a failure printed
//! ```
//!
//! A failure prints the seed, the iteration, and the input as a line that
//! can be pasted straight into the corpus in `fuzz.zig` — which is where a
//! bug this finds is supposed to end up, so that it is checked forever
//! after by `zig build test` without anyone having to run this again.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const fuzz = @import("fuzz.zig");

const default_iterations: usize = 50_000;

/// Zig 0.16 hands the command line to `main` instead of having it fetched.
/// `Init.Minimal` is the smaller of the two shapes it offers, and the
/// arguments are all this wants.
pub fn main(init: std.process.Init.Minimal) !void {
    var iterations = default_iterations;
    // Zig 0.16's `std.time` is constants and nothing else, and the Engine
    // keeps the only clock in the building — the same reason the logger
    // asks it for one. A different run wants different inputs; the seed is
    // printed, so "different" never means "unrepeatable".
    var seed: u64 = bulkhead.monotonicNanos();

    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip(); // the program's own name
    while (args.next()) |arg| {
        const which: enum { iterations, seed } =
            if (std.mem.eql(u8, arg, "--iterations"))
                .iterations
            else if (std.mem.eql(u8, arg, "--seed"))
                .seed
            else
                return usage();
        const value = args.next() orelse return usage();
        switch (which) {
            .iterations => iterations = std.fmt.parseInt(usize, value, 0) catch return usage(),
            .seed => seed = std.fmt.parseInt(u64, value, 0) catch return usage(),
        }
    }

    std.debug.print("fuzzing the request parser: {d} inputs, seed 0x{x}\n", .{ iterations, seed });

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buf: [1024]u8 = undefined;

    var n: usize = 0;
    while (n < iterations) : (n += 1) {
        const input = generate(random, &buf);
        fuzz.checkOne(input) catch |err| {
            std.debug.print(
                "\nFAILED on input {d} of {d} with {t}.\n" ++
                    "Reproduce with: zig build fuzz -- --seed 0x{x}\n" ++
                    "Then paste the line above into the corpus in src/fuzz.zig.\n",
                .{ n, iterations, err, seed },
            );
            std.process.exit(1);
        };
    }

    std.debug.print("{d} inputs, every property held\n", .{iterations});
}

fn usage() void {
    std.debug.print(
        \\usage: zig build fuzz -- [--iterations N] [--seed N]
        \\
    , .{});
    std.process.exit(2);
}

// ---- generating something worth checking ----

const methods = [_][]const u8{ "GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "get", "", "VERYLONGMETHODNAME", "GET\t" };
const targets = [_][]const u8{ "/", "/users/42", "/a/b/c", "*", "http://x/y", "/%2e%2e/", "/x?a=1&b=2", "", "/" ** 40 };
const versions = [_][]const u8{ "HTTP/1.1", "HTTP/1.0", "HTTP/1.2", "HTTP/2.0", "http/1.1", "HTTP/1.1 ", "" };
const header_names = [_][]const u8{
    "Host",             "Content-Length", "Transfer-Encoding", "Connection",
    "content-length",   "TRANSFER-ENCODING", "Upgrade",        "X-Forwarded-For",
    "Accept-Encoding",  "Cookie",         "",                  "Content-Length ",
    " Content-Length",  "Content_Length",
};
const header_values = [_][]const u8{
    "0",       "5",              "-1",      "+7",        "007",
    "18446744073709551615",      "chunked", "identity, chunked",
    "close",   "keep-alive",     "Upgrade", "keep-alive, Upgrade",
    "",        " ",              "\tgzip",  "gzip;q=0",  "5, 6",
    "localhost:8787",
};

/// The bytes that break framing, which is where the interesting damage is.
const delicious = [_]u8{ '\r', '\n', ':', ' ', '\t', ';', ',', '0', 0x00, 0xff, '/', '.' };

fn generate(random: std.Random, buf: []u8) []const u8 {
    return switch (random.weightedIndex(u16, &.{ 45, 30, 15, 10 })) {
        // A well-formed request, which is the baseline the rest damages.
        0 => build(random, buf, .{}),
        // The same, with one byte changed, removed or inserted.
        1 => damage(random, build(random, buf, .{}), buf),
        // Deliberately odd framing: no blank line, a body that lies, a
        // chunked stream with sizes that are not sizes.
        2 => build(random, buf, .{ .weird_framing = true }),
        // Random bytes, still worth a slice of the budget: they are the
        // only inputs that reach the parser without a newline in them.
        else => noise(random, buf),
    };
}

const Shape = struct { weird_framing: bool = false };

fn build(random: std.Random, buf: []u8, shape: Shape) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const crlf: []const u8 = if (random.boolean()) "\r\n" else "\n";

    w.print("{s} {s} {s}{s}", .{
        pick(random, &methods),
        pick(random, &targets),
        pick(random, &versions),
        crlf,
    }) catch return w.buffered();

    const header_count = random.uintLessThan(u8, 8);
    for (0..header_count) |_| {
        const name = pick(random, &header_names);
        const value = pick(random, &header_values);
        const separator: []const u8 = if (shape.weird_framing and random.boolean()) "" else ":";
        w.print("{s}{s} {s}{s}", .{ name, separator, value, crlf }) catch return w.buffered();
    }

    // The blank line, unless the point is that there isn't one.
    if (!shape.weird_framing or random.boolean()) {
        w.writeAll(crlf) catch return w.buffered();
    }

    // Something after the head, since a body is what a wrong head length
    // would run into.
    switch (random.uintLessThan(u8, 4)) {
        0 => {},
        1 => w.writeAll("hello") catch {},
        2 => w.print("5{s}hello{s}0{s}{s}", .{ crlf, crlf, crlf, crlf }) catch {},
        else => {
            // A chunked stream whose sizes come from the attacker.
            const size_text = [_][]const u8{ "0", "5", "ffffffffffffffff", "-1", "5;ext", " 5", "", "x" };
            w.print("{s}{s}hello{s}0{s}{s}", .{
                pick(random, &size_text), crlf, crlf, crlf, crlf,
            }) catch {};
        },
    }

    return w.buffered();
}

/// One change in one place. Enough to matter, small enough that the input
/// stays near the boundary the parser cares about.
fn damage(random: std.Random, made: []const u8, buf: []u8) []const u8 {
    if (made.len == 0) return made;
    const at = random.uintLessThan(usize, made.len);
    return switch (random.uintLessThan(u8, 4)) {
        // Replace a byte with one that means something to a parser.
        0 => blk: {
            buf[at] = delicious[random.uintLessThan(usize, delicious.len)];
            break :blk buf[0..made.len];
        },
        // Flip a bit, which is how a header name stops being one.
        1 => blk: {
            buf[at] ^= @as(u8, 1) << random.int(u3);
            break :blk buf[0..made.len];
        },
        // Cut it short, wherever it happens to be — mid-header, mid-CRLF.
        2 => buf[0..at],
        // Insert a byte, moving everything after it.
        else => blk: {
            if (made.len + 1 > buf.len) break :blk buf[0..made.len];
            std.mem.copyBackwards(u8, buf[at + 1 .. made.len + 1], buf[at..made.len]);
            buf[at] = delicious[random.uintLessThan(usize, delicious.len)];
            break :blk buf[0 .. made.len + 1];
        },
    };
}

fn noise(random: std.Random, buf: []u8) []const u8 {
    const len = random.uintLessThan(usize, @min(buf.len, 256));
    // Mostly bytes a text protocol might see, so that a newline turns up
    // often enough to reach the line-splitting code at all.
    for (buf[0..len]) |*b| {
        b.* = if (random.boolean())
            delicious[random.uintLessThan(usize, delicious.len)]
        else
            random.int(u8);
    }
    return buf[0..len];
}

fn pick(random: std.Random, comptime list: []const []const u8) []const u8 {
    return list[random.uintLessThan(usize, list.len)];
}
