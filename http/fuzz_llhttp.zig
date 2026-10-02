//! nilo's request parser against llhttp's, over the heads `zig build fuzz`
//! generates: `zig build fuzz-llhttp -Dllhttp -- [--iterations N] [--seed N]`.
//!
//! `fuzz.zig` checks the parser against a reference written the obvious
//! way, and that reference was written from the same reading of RFC 9112
//! as the parser. Where the two share a mistake it cannot see one: the
//! header name that is not a token, `Connection: keep-alive, close`, every
//! entry under "read differently from the RFC" in the roadmap passed it.
//! llhttp is Node's parser, a reading somebody else made and has defended
//! against smuggling reports for years, so a disagreement with it is a
//! question somebody has to answer in writing (ADR 231).
//!
//! **Only here.** llhttp is C, fetched by `-Dllhttp` and by nothing else,
//! and linked into this one program. Nothing that ships names it.
//!
//! What counts, in order of how much it matters:
//!
//! - **nilo accepts a head llhttp refuses.** A leniency, and a front end
//!   that refuses what nilo accepts is fine, but one that *repairs* it
//!   and forwards the repair is how two parsers frame one request twice.
//! - **Both accept it and frame it differently**: another length, chunked
//!   or not, kept alive or not, a head that ends elsewhere. That is
//!   smuggling itself, not the shape of it.
//! - **nilo refuses a head llhttp accepts.** Counted and shown, never a
//!   failure: stricter than Node is allowed, and usually the point.
//!
//! A difference that has been looked at and is nilo's choice is listed in
//! `decided`, with the reason, and is counted instead of failing the run.

const std = @import("std");
const http1 = @import("http1.zig");
const fuzz = @import("fuzz.zig");
const generator = @import("fuzz_main.zig");
const bulkhead = @import("bulkhead.zig");
const c = @import("llhttp");

pub const Kind = enum {
    nilo_accepts_what_llhttp_refuses,
    frames_differently,
    nilo_refuses_what_llhttp_accepts,

    fn fails(self: Kind) bool {
        return self != .nilo_refuses_what_llhttp_accepts;
    }
};

pub const Finding = struct {
    kind: Kind,
    /// llhttp's reason for a refusal, or the field the two framed
    /// differently. Static text either way, so findings can be counted by
    /// it.
    detail: []const u8,
    /// Why this one is nilo's on purpose, when it is (`decided`).
    why: ?[]const u8 = null,
};

/// Differences that were looked at and are nilo's on purpose. Matched on
/// the kind, a piece of the detail, and the input itself: llhttp's reason
/// names where it stopped, not what was there, so "Invalid char in url path"
/// is a high byte nilo takes on purpose or a control byte it must refuse,
/// and only `when` can tell them apart. Each says why, so that the day the
/// reason stops holding somebody can tell.
const Decided = struct {
    kind: Kind,
    detail: []const u8,
    when: *const fn (head: []const u8) bool,
    why: []const u8,
};
const decided = [_]Decided{
    .{
        .kind = .nilo_accepts_what_llhttp_refuses,
        .detail = "Invalid method",
        .when = methodIsToken,
        .why = "RFC 9110 §9.1: a method is any token, and one nobody routed is a 405 or a 404. " ++
            "llhttp knows a fixed list.",
    },
    .{
        .kind = .nilo_accepts_what_llhttp_refuses,
        .detail = "Expected space after method",
        .when = methodIsToken,
        .why = "The same list, met part way: llhttp matched `PUT` and stopped at the `.` of `PUT.`, " ++
            "which is a token.",
    },
    .{
        .kind = .nilo_accepts_what_llhttp_refuses,
        .detail = "Duplicate Content-Length",
        .when = always,
        .why = "RFC 9110 §8.6 lets a recipient take a repeat of the same length as the one length; " ++
            "two different ones are refused (http1.zig, `has_content_length`).",
    },
    .{
        .kind = .nilo_accepts_what_llhttp_refuses,
        .detail = "url",
        .when = targetHasHighByte,
        .why = "A byte past 0x7f cannot end a line or split a field, and nginx and Go route it as " ++
            "sent. A front end that encodes it sends `%XX`, which a path param decodes to the same bytes.",
    },
    .{
        .kind = .nilo_accepts_what_llhttp_refuses,
        .detail = "Unexpected char in url schema",
        .when = otherScheme,
        .why = "RFC 3986 §3.1 lets a scheme hold digits, `+`, `-` and `.`, and an absolute-URI need not " ++
            "go on with `//`; llhttp reads letters and `://`. A scheme nilo does not serve is routed as sent " ++
            "and finds no route.",
    },
    .{
        .kind = .frames_differently,
        .detail = "keep-alive",
        .when = saysCloseAndKeepAlive,
        .why = "RFC 9112 §9.6: `close` means the connection closes, whatever else is listed. " ++
            "llhttp keeps an HTTP/1.0 connection open when `keep-alive` is there too.",
    },
};

fn decidedWhy(f: Finding, head: []const u8) ?[]const u8 {
    for (decided) |d| {
        if (d.kind == f.kind and std.mem.indexOf(u8, f.detail, d.detail) != null and d.when(head)) return d.why;
    }
    return null;
}

fn always(_: []const u8) bool {
    return true;
}

/// The method and the target, split off the request line on its first two spaces.
fn requestLine(head: []const u8) struct { method: []const u8, target: []const u8 } {
    const line = head[0 .. std.mem.indexOfScalar(u8, head, '\n') orelse head.len];
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return .{ .method = line, .target = "" };
    const sp2 = std.mem.indexOfScalarPos(u8, line, sp1 + 1, ' ') orelse line.len;
    return .{ .method = line[0..sp1], .target = line[sp1 + 1 .. sp2] };
}

fn methodIsToken(head: []const u8) bool {
    return http1.headerNameOk(requestLine(head).method);
}

fn targetHasHighByte(head: []const u8) bool {
    for (requestLine(head).target) |b| if (b >= 0x80) return true;
    return false;
}

fn otherScheme(head: []const u8) bool {
    const target = requestLine(head).target;
    const colon = std.mem.indexOfScalar(u8, target, ':') orelse return false;
    const scheme = target[0..colon];
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    return !std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https");
}

fn saysCloseAndKeepAlive(head: []const u8) bool {
    var close = false;
    var keep = false;
    var it = http1.HeaderIterator.from(head);
    while (it.next()) |h| {
        if (!std.ascii.eqlIgnoreCase(h.name, "connection")) continue;
        var options = std.mem.splitScalar(u8, h.value, ',');
        while (options.next()) |raw| {
            const option = std.mem.trim(u8, raw, " \t");
            if (std.ascii.eqlIgnoreCase(option, "close")) close = true;
            if (std.ascii.eqlIgnoreCase(option, "keep-alive")) keep = true;
        }
    }
    return close and keep;
}

// ---- llhttp's reading of one head ----

const Theirs = struct {
    /// llhttp's reason, when it refused.
    refused: ?[]const u8 = null,
    /// Whether it read the bytes nilo called a head as exactly one head.
    ended: bool = false,
    method: []const u8 = "",
    url: []const u8 = "",
    major: u8 = 0,
    minor: u8 = 0,
    content_length: ?u64 = null,
    chunked: bool = false,
    keep_alive: bool = false,
    upgrade: bool = false,
};

/// Where the callbacks put what they are handed. The head is fed in one
/// call, so a span arrives in one piece or in consecutive ones.
const Spans = struct {
    method: []const u8 = "",
    url: []const u8 = "",
    done: bool = false,

    fn grow(span: []const u8, at: [*c]const u8, len: usize) []const u8 {
        if (span.len == 0) return at[0..len];
        return span.ptr[0 .. span.len + len];
    }
};

fn spansOf(p: [*c]c.llhttp_t) *Spans {
    return @ptrCast(@alignCast(p.*.data));
}

fn onMethod(p: [*c]c.llhttp_t, at: [*c]const u8, len: usize) callconv(.c) c_int {
    const s = spansOf(p);
    s.method = Spans.grow(s.method, at, len);
    return 0;
}

fn onUrl(p: [*c]c.llhttp_t, at: [*c]const u8, len: usize) callconv(.c) c_int {
    const s = spansOf(p);
    s.url = Spans.grow(s.url, at, len);
    return 0;
}

/// Stops the parser where the head ends: what comes after is a body, and
/// the question here is only what the head said.
fn onHeadersComplete(p: [*c]c.llhttp_t) callconv(.c) c_int {
    spansOf(p).done = true;
    return c.HPE_PAUSED;
}

/// llhttp's reading of `head`, handed over with every bare LF made a CRLF.
///
/// RFC 9112 §2.2 lets a recipient take a bare LF for a line ending, and
/// nilo does. llhttp's leniency for it stops at the request line, so
/// without this every such head is a refusal, and a thousand of those hide
/// the findings that are not about line endings. A bare CR is left alone:
/// that one is a question.
fn theirs(head: []const u8) Theirs {
    var crlf: [2048]u8 = undefined;
    var n: usize = 0;
    for (head, 0..) |b, i| {
        if (b == '\n' and (i == 0 or head[i - 1] != '\r')) {
            crlf[n] = '\r';
            n += 1;
        }
        crlf[n] = b;
        n += 1;
    }
    return theirsExactly(crlf[0..n]);
}

fn theirsExactly(head: []const u8) Theirs {
    var settings: c.llhttp_settings_t = undefined;
    c.llhttp_settings_init(&settings);
    settings.on_method = onMethod;
    settings.on_url = onUrl;
    settings.on_headers_complete = onHeadersComplete;

    var parser: c.llhttp_t = undefined;
    c.llhttp_init(&parser, c.HTTP_REQUEST, &settings);

    var spans: Spans = .{};
    parser.data = &spans;

    const rc = c.llhttp_execute(&parser, head.ptr, head.len);
    if (rc == c.HPE_OK) return .{}; // still inside the head
    if (rc != c.HPE_PAUSED or !spans.done) {
        return .{ .refused = std.mem.span(c.llhttp_get_error_reason(&parser)) };
    }
    const flags = parser.flags;
    return .{
        // Past the whole head, or it ended early: the offset into the copy
        // is only ever compared with the copy's length.
        .ended = @intFromPtr(c.llhttp_get_error_pos(&parser)) - @intFromPtr(head.ptr) == head.len,
        .method = spans.method,
        .url = spans.url,
        .major = parser.http_major,
        .minor = parser.http_minor,
        .content_length = if (flags & c.F_CONTENT_LENGTH != 0) parser.content_length else null,
        .chunked = flags & c.F_CHUNKED != 0,
        .keep_alive = c.llhttp_should_keep_alive(&parser) != 0,
        .upgrade = parser.upgrade != 0,
    };
}

// ---- the comparison ----

/// What, if anything, the two parsers disagree about in `bytes`. Null when
/// nilo finds no complete head, because then there is nothing it acted on.
pub fn compare(bytes: []const u8) ?Finding {
    const end = http1.findEndOfHead(bytes, 0) orelse return null;
    const head = bytes[0..end];

    var ours: http1.Request = .{};
    const refused: ?anyerror = if (http1.parseHead(head, &ours)) |_| null else |err| err;
    const t = theirs(head);

    if (refused) |err| {
        if (t.refused != null or !t.ended) return null; // refused by both
        return .{ .kind = .nilo_refuses_what_llhttp_accepts, .detail = @errorName(err) };
    }
    if (t.refused) |reason| return .{ .kind = .nilo_accepts_what_llhttp_refuses, .detail = reason };

    const differs: ?[]const u8 = if (!t.ended)
        "where the head ends"
    else if (!std.mem.eql(u8, t.method, ours.method))
        "method"
        // An absolute-form target is split into authority and path by nilo,
        // and handed over whole by llhttp; the path is compared, the split is
        // `fuzz.zig`'s to check.
    else if (ours.authority.len == 0 and !std.mem.eql(u8, t.url, ours.target))
        "target"
    else if (t.major != 1 or t.minor != ours.minor_version)
        "version"
    else if ((t.content_length != null) != ours.has_content_length or
        (t.content_length != null and t.content_length.? != ours.content_length))
        "content length"
    else if (t.chunked != ours.chunked)
        "chunked"
    else if (t.keep_alive != ours.keep_alive)
        "keep-alive"
        // nilo's `upgrade` is looser on purpose (http1.zig): the only wrong
        // answer is llhttp seeing an upgrade that nilo does not.
    else if (t.upgrade and !ours.upgrade)
        "upgrade"
    else
        null;

    return .{ .kind = .frames_differently, .detail = differs orelse return null };
}

// ---- the driver ----

const Tally = struct {
    finding: Finding,
    count: usize = 0,
    first: [1024]u8 = undefined,
    first_len: usize = 0,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var iterations: usize = 200_000;
    var seed: u64 = bulkhead.monotonicNanos();

    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip();
    while (args.next()) |arg| {
        const value = args.next() orelse return usage();
        if (std.mem.eql(u8, arg, "--iterations")) {
            iterations = std.fmt.parseInt(usize, value, 0) catch return usage();
        } else if (std.mem.eql(u8, arg, "--seed")) {
            seed = std.fmt.parseInt(u64, value, 0) catch return usage();
        } else return usage();
    }

    std.debug.print("nilo against llhttp {d}.{d}.{d}: {d} inputs, seed 0x{x}\n", .{
        c.LLHTTP_VERSION_MAJOR, c.LLHTTP_VERSION_MINOR, c.LLHTTP_VERSION_PATCH, iterations, seed,
    });

    var prng = std.Random.DefaultPrng.init(seed);
    var buf: [1024]u8 = undefined;
    var tallies: [64]Tally = undefined;
    var kinds: usize = 0;
    var compared: usize = 0;

    for (0..iterations) |_| {
        const input = generator.generate(prng.random(), &buf);
        const end = http1.findEndOfHead(input, 0) orelse continue;
        compared += 1;
        var f = compare(input) orelse continue;
        f.why = decidedWhy(f, input[0..end]);
        const slot = for (tallies[0..kinds]) |*t| {
            if (t.finding.kind == f.kind and std.mem.eql(u8, t.finding.detail, f.detail) and
                (t.finding.why == null) == (f.why == null)) break t;
        } else blk: {
            if (kinds == tallies.len) continue;
            tallies[kinds] = .{ .finding = f };
            @memcpy(tallies[kinds].first[0..input.len], input);
            tallies[kinds].first_len = input.len;
            kinds += 1;
            break :blk &tallies[kinds - 1];
        };
        slot.count += 1;
    }

    var failing: usize = 0;
    for (tallies[0..kinds]) |*t| {
        const why = t.finding.why;
        const fails = t.finding.kind.fails() and why == null;
        if (fails) failing += 1;
        std.debug.print("\n{s} {t}: {s} ({d} inputs)\n", .{
            if (fails) "FAIL" else "    ", t.finding.kind, t.finding.detail, t.count,
        });
        if (why) |w| std.debug.print("    decided: {s}\n", .{w});
        fuzz.dump(t.first[0..t.first_len]);
    }

    std.debug.print("\n{d} of {d} inputs had a complete head; {d} kinds of difference, {d} not decided\n", .{
        compared, iterations, kinds, failing,
    });
    if (failing > 0) std.process.exit(1);
}

fn usage() void {
    std.debug.print("usage: zig build fuzz-llhttp -Dllhttp -- [--iterations N] [--seed N]\n", .{});
    std.process.exit(2);
}
