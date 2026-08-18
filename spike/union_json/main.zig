//! What a tagged union in a response costs today, and what it would cost on
//! nilo's generated writer.
//!
//! Today `covers()` refuses a union outright (http/json.zig:64, and the assert
//! at :304), and `covers` is answered for the *whole* value — so one union
//! field anywhere in a response sends the entire struct to `std.json`,
//! including the strings, which is the part the generated writer exists for.
//!
//! Path A: what nilo sends today.       std.json, externally tagged.
//! Path B: generated writer, ext-tagged. isolates "union support".
//! Path C: generated writer, int-tagged. the feature being proposed.
//! Path D: control. the same payload with the union hand-flattened into a
//!         plain struct, on the generated writer — the ceiling B and C are
//!         chasing, and it says how much of the win is the union at all.

const std = @import("std");
const print = std.debug.print;

// ---- the payload: Photon's alert rule, its `Condition` shape ----

const MetricAgg = enum { avg, sum, min, max, p50, p90, p95, p99, count, rate, last };
const Cmp = enum { gt, gte, lt, lte };
const Severity = enum { info, warning, critical };

const MetricCondition = struct {
    metric_name: []const u8,
    agg: MetricAgg,
    cmp: Cmp,
    threshold: f64,
    window_seconds: u32,
};

const LogCondition = struct {
    query: []const u8,
    severity: Severity,
    count_over: u32,
    window_seconds: u32,
};

const Condition = union(enum) {
    metrics: MetricCondition,
    logs: LogCondition,
};

const Rule = struct {
    id: u64,
    name: []const u8,
    description: []const u8,
    enabled: bool,
    severity: Severity,
    condition: Condition,
    cooldown_seconds: u32,
};

// The same rule with the union flattened by hand — path D's payload. This is
// what somebody writes today to stay on the fast path, and what the +300 lines
// of boilerplate in the Photon note is buying.
const FlatRule = struct {
    id: u64,
    name: []const u8,
    description: []const u8,
    enabled: bool,
    severity: Severity,
    signal: []const u8,
    metric_name: []const u8,
    agg: MetricAgg,
    cmp: Cmp,
    threshold: f64,
    window_seconds: u32,
    cooldown_seconds: u32,
};

const rule: Rule = .{
    .id = 4413,
    .name = "cpu saturation on the ingest tier",
    .description = "Fires when the ingest nodes hold above 90% utilisation " ++
        "for five minutes, which is where the WAL starts falling behind.",
    .enabled = true,
    .severity = .critical,
    .condition = .{ .metrics = .{
        .metric_name = "system.cpu.utilization",
        .agg = .avg,
        .cmp = .gt,
        .threshold = 0.9,
        .window_seconds = 300,
    } },
    .cooldown_seconds = 900,
};

const flat_rule: FlatRule = .{
    .id = 4413,
    .name = rule.name,
    .description = rule.description,
    .enabled = true,
    .severity = .critical,
    .signal = "metrics",
    .metric_name = "system.cpu.utilization",
    .agg = .avg,
    .cmp = .gt,
    .threshold = 0.9,
    .window_seconds = 300,
    .cooldown_seconds = 900,
};

const Small = struct {
    id: u32,
    condition: Condition,
};

const small: Small = .{
    .id = 7,
    .condition = .{ .logs = .{
        .query = "error",
        .severity = .critical,
        .count_over = 5,
        .window_seconds = 60,
    } },
};

// ---- nilo's generated writer, copied verbatim from http/json.zig ----

fn writeString(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var at: usize = 0;
    while (nextEscape(text, at)) |i| {
        try w.writeAll(text[at..i]);
        const c = text[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.print("\\u{x:0>4}", .{c}),
        }
        at = i + 1;
    }
    try w.writeAll(text[at..]);
    try w.writeByte('"');
}

const lanes = 32;
const Chunk = @Vector(lanes, u8);

fn nextEscape(text: []const u8, from: usize) ?usize {
    const quote: Chunk = @splat('"');
    const backslash: Chunk = @splat('\\');
    const space: Chunk = @splat(0x20);
    var i = from;
    while (i + lanes <= text.len) : (i += lanes) {
        const block: Chunk = text[i..][0..lanes].*;
        const hits = (block == quote) | (block == backslash) | (block < space);
        const bits: u32 = @bitCast(hits);
        if (bits != 0) return i + @ctz(bits);
    }
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '"' or c == '\\' or c < 0x20) return i;
    }
    return null;
}

/// `tag` is null for path B (externally tagged, what std.json writes) and the
/// key name for path C (internally tagged, the proposal).
fn writeValue(
    comptime T: type,
    comptime tag: ?[]const u8,
    w: *std.Io.Writer,
    value: T,
) std.Io.Writer.Error!void {
    if (T == []const u8 or T == []u8) return writeString(w, value);

    switch (@typeInfo(T)) {
        .bool => return w.writeAll(if (value) "true" else "false"),
        .int, .comptime_int => return w.printInt(value, 10, .lower, .{}),
        .float, .comptime_float => return std.json.Stringify.value(value, .{}, w),
        .@"enum" => return writeString(w, @tagName(value)),
        .optional => return if (value) |payload|
            writeValue(@TypeOf(payload), null, w, payload)
        else
            w.writeAll("null"),

        .array, .pointer => {
            try w.writeByte('[');
            for (value, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(@TypeOf(item), null, w, item);
            }
            return w.writeByte(']');
        },

        .@"union" => |u| {
            switch (value) {
                inline else => |payload, active| {
                    const arm = @tagName(active);
                    const Payload = @TypeOf(payload);
                    if (tag) |key| {
                        // Internally tagged: the discriminator is the first
                        // key of the payload's own object, so the arm's
                        // fields are written flat beside it.
                        // The arm's name is a Zig identifier, so it never
                        // needs escaping — the discriminator is one comptime
                        // literal, exactly as a field name is at json.zig:104.
                        try w.writeAll(comptime "{\"" ++ key ++ "\":\"" ++ arm ++ "\"");
                        const s = @typeInfo(Payload).@"struct";
                        inline for (s.fields) |f| {
                            try w.writeAll(comptime ",\"" ++ f.name ++ "\":");
                            try writeValue(f.type, null, w, @field(payload, f.name));
                        }
                        return w.writeByte('}');
                    }
                    // Externally tagged: one object, one key, the arm's name.
                    try w.writeAll("{\"" ++ arm ++ "\":");
                    try writeValue(Payload, null, w, payload);
                    return w.writeByte('}');
                },
            }
            comptime std.debug.assert(u.tag_type != null);
        },

        .@"struct" => |s| {
            if (s.fields.len == 0) return w.writeAll("{}");
            inline for (s.fields, 0..) |f, i| {
                try w.writeAll(comptime (if (i == 0) "{\"" else ",\"") ++ f.name ++ "\":");
                try writeValue(f.type, tag, w, @field(value, f.name));
            }
            return w.writeByte('}');
        },

        else => comptime unreachable,
    }
}

// ---- the run ----

fn nanos() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Path = enum {
    a_std_json,
    b_generated_ext,
    c_generated_int,
    d_control_flat,
    small_std_json,
    small_generated_int,
};

fn once(path: Path, buf: []u8) !usize {
    var w = std.Io.Writer.fixed(buf);
    switch (path) {
        .a_std_json => try std.json.Stringify.value(rule, .{}, &w),
        .b_generated_ext => try writeValue(Rule, null, &w, rule),
        .c_generated_int => try writeValue(Rule, "signal", &w, rule),
        .d_control_flat => try writeValue(FlatRule, null, &w, flat_rule),
        .small_std_json => try std.json.Stringify.value(small, .{}, &w),
        .small_generated_int => try writeValue(Small, "signal", &w, small),
    }
    return w.end;
}

fn time(path: Path, iterations: usize, buf: []u8) !u64 {
    // Warm.
    for (0..1000) |_| std.mem.doNotOptimizeAway(try once(path, buf));

    const start = nanos();
    for (0..iterations) |_| std.mem.doNotOptimizeAway(try once(path, buf));
    return (nanos() - start) / iterations;
}

pub fn main() !void {
    var buf: [4096]u8 = undefined;

    // What each path actually writes, so the comparison is not between two
    // things producing different amounts of output.
    inline for (.{
        .{ Path.a_std_json, "A  std.json, ext-tagged  " },
        .{ Path.b_generated_ext, "B  generated, ext-tagged " },
        .{ Path.c_generated_int, "C  generated, int-tagged " },
        .{ Path.d_control_flat, "D  control, flattened    " },
        .{ Path.small_std_json, "E  small, std.json       " },
        .{ Path.small_generated_int, "F  small, generated int  " },
    }) |row| {
        const n = try once(row[0], &buf);
        print("{s} {d:>4} bytes  {s}\n", .{ row[1], n, buf[0..n] });
    }
    print("\n", .{});

    const iterations = 200_000;
    const pairs = 5;

    // Interleaved, five times each, because a single run of each is how this
    // repository has published a win it did not earn (CLAUDE.md).
    var totals = [_]u64{0} ** 6;
    var best = [_]u64{std.math.maxInt(u64)} ** 6;
    var worst = [_]u64{0} ** 6;

    for (0..pairs) |_| {
        inline for (.{
            Path.a_std_json,
            Path.b_generated_ext,
            Path.c_generated_int,
            Path.d_control_flat,
            Path.small_std_json,
            Path.small_generated_int,
        }, 0..) |p, i| {
            const ns = try time(p, iterations, &buf);
            totals[i] += ns;
            best[i] = @min(best[i], ns);
            worst[i] = @max(worst[i], ns);
        }
    }

    const names = [_][]const u8{
        "A  std.json, ext-tagged  (what nilo sends today)",
        "B  generated, ext-tagged (same bytes, fast writer)",
        "C  generated, int-tagged (the proposal)",
        "D  control, flattened    (the hand-written ceiling)",
        "E  small payload, std.json  (what nilo sends today)",
        "F  small payload, generated (the proposal)",
    };
    print("{d} runs of {d} iterations, interleaved\n\n", .{ pairs, iterations });
    for (names, 0..) |name, i| {
        const mean = totals[i] / pairs;
        print("{s}  {d:>5} ns  (best {d}, worst {d})\n", .{ name, mean, best[i], worst[i] });
    }

    const a = totals[0] / pairs;
    print("\nB is {d:.2}x A\nC is {d:.2}x A\nD is {d:.2}x A\nF is {d:.2}x E\n", .{
        @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(totals[1] / pairs)),
        @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(totals[2] / pairs)),
        @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(totals[3] / pairs)),
        @as(f64, @floatFromInt(totals[4] / pairs)) / @as(f64, @floatFromInt(totals[5] / pairs)),
    });
}
