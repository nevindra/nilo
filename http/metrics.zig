//! Metrics — how many requests, at what statuses, how long.
//!
//! ```zig
//! try app.metrics(.{});                       // a Prometheus page at /metrics
//! try app.metrics(.{ .path = "/internal/metrics" });
//! try app.expose("orders_placed", .counter, &orders);   // a number of your own
//! ```
//!
//! **The route table is the registry, and that is the whole design.** Every
//! metrics library this could have been modelled on keys its counters by label
//! strings and hashes one per request, which is where the allocation and the
//! cardinality both come from: `/users/1` and `/users/2` become two series, and
//! a crawler makes a million. nilo does not have to. The set of routes is closed
//! by the time `listen()` resolves them and the router has already numbered it,
//! so a counter is an **array index the request is holding anyway** — no hash, no
//! map, no keys, and `/users/1` and `/users/2` land on `/users/:id` for free
//! (ADR 0100).
//!
//! What that buys is the axis this framework will not spend: a request that is
//! counted allocates nothing. The table is one allocation when the routes are
//! resolved, and the work per request is a clock read, a walk of at most a
//! handful of bucket boundaries, and four `fetchAdd`s on counters that sit next
//! to each other on purpose.
//!
//! **There is no dynamic registry, and that is a decision rather than a gap.**
//! A counter named at runtime means string keys, a hash per increment and a lock
//! or a shard table, and none of that fits. What replaces it is `app.expose`:
//! you declare the atomic, you increment it, and nilo publishes it. The naming
//! is paid once at startup and the reading once per scrape — never on the path
//! of a request that is not the scrape (ADR 0100).

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const naming = @import("names.zig");
const bulkhead = @import("bulkhead.zig");

/// The latency boundaries a server gets without asking, in microseconds.
///
/// They span the two answers a nilo server actually gives: something out of
/// memory, which lands in the first bucket, and something behind a database or
/// an outbound call, which lands in the middle. The top one is there so that a
/// request which went wrong is visibly separate from one that was merely slow.
pub const default_buckets: []const u64 = &.{
    100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 1_000_000,
};

pub const Options = struct {
    /// Where the page is served. An ordinary route, so a middleware in front
    /// of it applies — which is how it gets whatever protection it needs
    /// (`useOn("/internal", auth)`), because nilo does not put one there.
    path: []const u8 = "/metrics",
    /// Latency bucket boundaries in microseconds, climbing.
    ///
    /// The same boundaries for every route, on purpose: a histogram is worth
    /// having because two routes can be compared on it, and per-route
    /// boundaries would make that a conversion rather than a comparison. A
    /// server whose routes really do live at different scales is better served
    /// by a longer list than by two lists.
    buckets: []const u64 = default_buckets,
};

/// What a number registered with `app.expose` is, in the sense Prometheus
/// means: a `counter` only climbs, a `gauge` goes both ways.
pub const Kind = enum { counter, gauge };

/// The one type a number several threads write to can be. Named here so that
/// `app.expose` and the message refusing anything else agree about it.
pub const Counter = std.atomic.Value(u64);

/// One number the application owns and nilo publishes.
pub const Exposed = struct {
    name: []const u8,
    kind: Kind,
    value: *const Counter,
};

/// What a slot is counting, in Prometheus' own words.
pub const Label = struct {
    method: []const u8,
    route: []const u8,
};

/// The slots that are not routes. They come **first**, so that a route's slot
/// is its router index plus a constant and a `Record` that never got as far as
/// matching is already pointing at the right one.
pub const unparsed = 0;
pub const unmatched = 1;
pub const method_not_allowed = 2;
pub const static_file = 3;
pub const fixed_slots = 4;

/// Split out rather than merged into one "not a route" bucket, because the
/// merged version answers nothing: a spike of 4xx against a single unnamed
/// slot could be a broken client, a scanner, a deploy that dropped a route or
/// a form posting to a GET, and those are four different afternoons.
const fixed_labels = [fixed_slots]Label{
    .{ .method = "", .route = "<unparsed>" },
    .{ .method = "", .route = "<unmatched>" },
    .{ .method = "", .route = "<method not allowed>" },
    .{ .method = "", .route = "<static file>" },
};

/// `none`, then one per hundred. `none` is a request that ended without an
/// answer on the wire — a client that walked off mid-response — and it is a
/// class rather than a skipped count so that the five classes still add up to
/// the number of requests.
const class_names = [_][]const u8{ "none", "1xx", "2xx", "3xx", "4xx", "5xx" };
const class_count = class_names.len;

/// Status codes counted exactly, for the whole process rather than per route.
///
/// Per route this would be four kilobytes each — five hundred `u64`s of which
/// a route uses three — against the hundred and twenty-eight bytes a route
/// costs now. So the exact code is a property of the service and the class is a
/// property of the route, which is also how the two questions are actually
/// asked: *what is this server returning* and *is this route erroring*.
const first_code = 100;
const code_count = 500;

/// What Prometheus asks for, and it is picky: a scrape of anything else is
/// rejected without being parsed.
pub const content_type = "text/plain; version=0.0.4; charset=utf-8";

/// Every counter in the process, and the labels to print them under.
///
/// Held by value on the App and handed to the readout handler as an ordinary
/// service, which is why nothing was added to `Ctx` for this: a request that
/// is not the scrape never looks at it.
pub const Table = struct {
    /// The application's own literal, so nothing is copied.
    boundaries: []const u64 = default_buckets,
    /// `fixed_slots` entries, then one per route in the router's own order.
    labels: []Label = &.{},
    /// `labels.len * stride()` counters, flat.
    ///
    /// Flat rather than a slice of structs so that a route's counters are
    /// contiguous: the three a request touches are one cache line, and the
    /// route beside it in the table is not on it.
    counters: []Counter = &.{},
    /// 100 through 599, for the whole process.
    codes: []Counter = &.{},
    /// What `app.expose` collected. Points at the App's list.
    exposed: []const Exposed = &.{},
    /// Requests being served right now. The App counts this already, to know
    /// what a stop has to wait for; reading it costs nothing new.
    in_flight: ?*const std.atomic.Value(u32) = null,

    /// Counters per slot: one per status class, one per bucket plus the
    /// overflow, and the sum of the durations.
    pub fn stride(self: *const Table) usize {
        return class_count + self.boundaries.len + 2;
    }

    /// Give the table its memory, sized from the routes. Called when the
    /// chains are resolved, which is the moment the route count stops moving.
    pub fn size(self: *Table, gpa: std.mem.Allocator, routes: usize) !void {
        self.free(gpa);

        const n = fixed_slots + routes;
        const labels = try gpa.alloc(Label, n);
        errdefer gpa.free(labels);
        @memcpy(labels[0..fixed_slots], &fixed_labels);

        const counters = try gpa.alloc(Counter, n * self.stride());
        errdefer gpa.free(counters);
        @memset(counters, .init(0));

        const codes = try gpa.alloc(Counter, code_count);
        @memset(codes, .init(0));

        self.labels = labels;
        self.counters = counters;
        self.codes = codes;
    }

    /// The label of route `i`, filled in by the App once the table is sized.
    pub fn nameRoute(self: *Table, i: usize, method: []const u8, route: []const u8) void {
        self.labels[fixed_slots + i] = .{ .method = method, .route = route };
    }

    pub fn free(self: *Table, gpa: std.mem.Allocator) void {
        if (self.labels.len > 0) gpa.free(self.labels);
        if (self.counters.len > 0) gpa.free(self.counters);
        if (self.codes.len > 0) gpa.free(self.codes);
        self.labels = &.{};
        self.counters = &.{};
        self.codes = &.{};
    }

    /// One request, counted. Everything on the request path ends up here.
    ///
    /// `.monotonic` throughout: these are counters nobody orders anything
    /// against, and a scrape that reads the histogram and the sum a request
    /// apart is a scrape Prometheus already tolerates.
    pub fn observe(self: *Table, slot: usize, status: u16, took_us: u64) void {
        if (self.counters.len == 0) return; // sized only once the routes are
        const base = slot * self.stride();
        _ = self.counters[base + classOf(status)].fetchAdd(1, .monotonic);
        _ = self.counters[base + class_count + self.bucketOf(took_us)].fetchAdd(1, .monotonic);
        _ = self.counters[base + self.stride() - 1].fetchAdd(took_us, .monotonic);
        if (status >= first_code and status < first_code + code_count) {
            _ = self.codes[status - first_code].fetchAdd(1, .monotonic);
        }
    }

    fn bucketOf(self: *const Table, took_us: u64) usize {
        for (self.boundaries, 0..) |edge, i| {
            if (took_us <= edge) return i;
        }
        return self.boundaries.len;
    }

    /// How many requests slot `i` has answered, over every class.
    fn countOf(self: *const Table, i: usize) u64 {
        const base = i * self.stride();
        var total: u64 = 0;
        for (self.counters[base..][0..class_count]) |*c| total += c.load(.monotonic);
        return total;
    }

    /// The whole page.
    ///
    /// **A slot nobody has reached prints nothing.** The table is sized by the
    /// route count, so a five-hundred-route application would otherwise scrape
    /// most of a megabyte of zeroes every fifteen seconds for the sake of
    /// series that carry no observation. A route appears the first time it
    /// answers.
    pub fn write(self: *const Table, w: *std.Io.Writer) !void {
        try w.writeAll(
            \\# HELP nilo_requests_total Requests answered, by route and status class.
            \\# TYPE nilo_requests_total counter
            \\
        );
        for (self.labels, 0..) |label, i| {
            if (self.countOf(i) == 0) continue;
            const base = i * self.stride();
            for (self.counters[base..][0..class_count], class_names) |*c, class| {
                const n = c.load(.monotonic);
                if (n == 0) continue;
                try w.writeAll("nilo_requests_total{");
                try writeRouteLabels(w, label);
                try w.print(",status=\"{s}\"}} {d}\n", .{ class, n });
            }
        }

        try w.writeAll(
            \\# HELP nilo_request_duration_seconds How long a request took, end to end.
            \\# TYPE nilo_request_duration_seconds histogram
            \\
        );
        for (self.labels, 0..) |label, i| {
            const count = self.countOf(i);
            if (count == 0) continue;
            const base = i * self.stride() + class_count;

            // Prometheus buckets are cumulative — `le="500"` counts everything
            // at or below 500, not only what fell between 100 and 500 — so the
            // running total is what goes out rather than the counter itself.
            var running: u64 = 0;
            for (self.counters[base..][0..self.boundaries.len], self.boundaries) |*c, edge| {
                running += c.load(.monotonic);
                try w.writeAll("nilo_request_duration_seconds_bucket{");
                try writeRouteLabels(w, label);
                try w.writeAll(",le=\"");
                try writeSeconds(w, edge);
                try w.print("\"}} {d}\n", .{running});
            }
            running += self.counters[base + self.boundaries.len].load(.monotonic);
            try w.writeAll("nilo_request_duration_seconds_bucket{");
            try writeRouteLabels(w, label);
            try w.print(",le=\"+Inf\"}} {d}\n", .{running});

            const total_us = self.counters[i * self.stride() + self.stride() - 1].load(.monotonic);
            try w.writeAll("nilo_request_duration_seconds_sum{");
            try writeRouteLabels(w, label);
            try w.writeAll("} ");
            try writeSeconds(w, total_us);
            try w.writeByte('\n');
            try w.writeAll("nilo_request_duration_seconds_count{");
            try writeRouteLabels(w, label);
            try w.print("}} {d}\n", .{running});
        }

        try w.writeAll(
            \\# HELP nilo_responses_total Responses sent, by exact status code.
            \\# TYPE nilo_responses_total counter
            \\
        );
        for (self.codes, 0..) |*c, i| {
            const n = c.load(.monotonic);
            if (n == 0) continue;
            try w.print("nilo_responses_total{{code=\"{d}\"}} {d}\n", .{ i + first_code, n });
        }

        if (self.in_flight) |gauge| {
            try w.writeAll(
                \\# HELP nilo_requests_in_flight Requests being served right now.
                \\# TYPE nilo_requests_in_flight gauge
                \\
            );
            try w.print("nilo_requests_in_flight {d}\n", .{gauge.load(.monotonic)});
        }

        for (self.exposed) |e| {
            try w.print("# TYPE {s} {s}\n{s} {d}\n", .{
                e.name,
                @tagName(e.kind),
                e.name,
                e.value.load(.monotonic),
            });
        }
    }
};

/// `none` for anything that is not a status, then one per hundred.
fn classOf(status: u16) usize {
    if (status < first_code or status >= 600) return 0;
    return status / 100;
}

/// Microseconds as the seconds Prometheus wants. Every tool downstream —
/// Grafana's own histogram panels included — assumes base units, so a page in
/// microseconds would be a page every dashboard reads off by a million.
///
/// **Written out by hand rather than divided into an `f64`, and the reason is
/// the binary.** `{d}` on a float links Zig's shortest-round-trip formatter,
/// and the first version of this file did exactly that: two stripped
/// `ReleaseFast` builds of `bench/main.zig` put the whole feature at 37,112
/// bytes with it and **17,416 without**, so more than half the cost of metrics
/// was a float printer, for a handful of decimal points on a page that is
/// scraped every fifteen seconds
/// ([ADR 0100](../docs/adr/0100-the-route-table-is-the-registry.md)).
/// A microsecond count is six decimal places of a second and nothing else, so
/// this is integer division and a trim.
fn writeSeconds(w: *std.Io.Writer, micros: u64) !void {
    const whole = micros / std.time.us_per_s;
    const frac = micros % std.time.us_per_s;
    if (frac == 0) return w.print("{d}", .{whole});

    var digits: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&digits, "{d:0>6}", .{frac}) catch unreachable;
    var end: usize = digits.len;
    while (end > 1 and digits[end - 1] == '0') end -= 1;
    try w.print("{d}.{s}", .{ whole, digits[0..end] });
}

/// The two labels every route series carries.
///
/// Escaped even though a route pattern is the application's own literal and
/// `validatePattern` has already refused most of what could go wrong: a label
/// value that closed its own quote would not corrupt one series, it would make
/// the whole page unparseable, and the cost is a walk of a short literal once
/// per scrape.
fn writeRouteLabels(w: *std.Io.Writer, label: Label) !void {
    try w.writeAll("method=\"");
    try writeLabelValue(w, label.method);
    try w.writeAll("\",route=\"");
    try writeLabelValue(w, label.route);
    try w.writeByte('"');
}

fn writeLabelValue(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(ch),
    };
}

/// One request in flight, from the point the connection had one to the point
/// it was answered.
///
/// A struct rather than two calls because `serveRequest` leaves by a dozen
/// different `return`s and the recording has to survive all of them: the clock
/// is read at the top, the slot is filled in wherever the route was decided,
/// and a `defer` finishes it. On a server that never called `app.metrics` the
/// whole thing is a null pointer, a few stores to a local, and no clock read.
pub const Record = struct {
    table: ?*Table,
    started: u64,
    /// Until something matches, this request is one that never parsed.
    slot: usize = unparsed,

    pub fn begin(table: ?*Table) Record {
        return .{
            .table = table,
            .started = if (table == null) 0 else bulkhead.monotonicNanos(),
        };
    }

    pub fn at(self: *Record, slot: usize) void {
        self.slot = slot;
    }

    pub fn finish(self: *const Record, status: u16) void {
        const table = self.table orelse return;
        const took = (bulkhead.monotonicNanos() -| self.started) / std.time.ns_per_us;
        table.observe(self.slot, status, took);
    }
};

/// The page itself. An ordinary handler asking for an ordinary service, which
/// is what keeps the whole feature out of `Ctx`.
pub fn readout(table: *const Table, c: *Ctx) anyerror!void {
    // Sized for a middling route table. Overshooting costs nothing — the arena
    // is emptied when the request ends — and this is the one request in the
    // process that is allowed to allocate freely.
    var out: std.Io.Writer.Allocating = try .initCapacity(c.arena(), 8 * 1024);
    try table.write(&out.writer);
    try c.send(200, content_type, out.written());
}

/// Everything that can be wrong with the options, said while compiling.
pub fn check(comptime options: Options) void {
    comptime {
        if (options.buckets.len == 0) @compileError(
            "nilo: app.metrics was given no latency buckets, so nothing would be timed.\n" ++
                "  Leave `.buckets` out for the default, or name the boundaries in " ++
                "microseconds: `.buckets = &.{ 1_000, 10_000, 100_000 }`.",
        );

        var previous: u64 = 0;
        for (options.buckets, 0..) |edge, i| {
            if (i == 0 and edge == 0) @compileError(
                "nilo: app.metrics was given a latency bucket of 0µs, and a boundary has to be " ++
                    "above zero.\n  A bucket counts every request at or below its boundary, and " ++
                    "no request takes less than no time.",
            );
            if (i > 0 and edge <= previous) @compileError(
                "nilo: app.metrics was given the latency bucket " ++ num(edge) ++ "µs after " ++
                    num(previous) ++ "µs, and the boundaries have to climb.\n" ++
                    "  Each one counts every request at or below it, so a list that goes " ++
                    "backwards leaves the later bucket counting nothing the earlier one did not.",
            );
            previous = edge;
        }

        for (options.path) |ch| {
            if (ch == ':' or ch == '*') @compileError(
                "nilo: the metrics path \"" ++ options.path ++ "\" has a `" ++ [_]u8{ch} ++
                    "` in it, which makes it a pattern rather than one address.\n" ++
                    "  It is a page something scrapes on a timer, so it is a plain path: " ++
                    "`.path = \"/metrics\"`.",
            );
        }
    }
}

/// Everything that can be wrong with an exposed number, said while compiling.
pub fn checkExposed(comptime name: []const u8, comptime P: type) void {
    comptime {
        if (P != *Counter and P != *const Counter) @compileError(
            "nilo: app.expose(\"" ++ name ++ "\", …) was given a " ++ naming.of(P) ++
                ", and a number that handlers on several threads count on has to be an " ++
                "atomic one.\n  Declare it `var " ++ name ++
                ": std.atomic.Value(u64) = .init(0);` and pass `&" ++ name ++ "`.",
        );

        // A name nilo already prints would put two `# TYPE` lines under one
        // family, and Prometheus rejects the **whole page** rather than the
        // one line — so an application would lose every metric it had over a
        // name it chose in passing.
        if (std.mem.startsWith(u8, name, "nilo_")) @compileError(
            "nilo: the exposed metric \"" ++ name ++ "\" starts with `nilo_`, which is what " ++
                "nilo's own metrics are called.\n  Two families under one name make the whole " ++
                "page unparseable, not just that line. Name it after your application: " ++
                "\"" ++ name["nilo_".len..] ++ "\".",
        );

        if (name.len == 0) @compileError(
            "nilo: app.expose was given an empty name, and the page it goes on is read by " ++
                "name.\n  Name it after what it counts: `app.expose(\"orders_placed\", " ++
                ".counter, &orders)`.",
        );

        for (name, 0..) |ch, i| {
            const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_' or
                ch == ':' or (i > 0 and ch >= '0' and ch <= '9');
            if (!ok) @compileError(
                "nilo: the exposed metric \"" ++ name ++ "\" has a `" ++ [_]u8{ch} ++
                    "` in it, and Prometheus would refuse the whole page rather than that one " ++
                    "line.\n  A name is letters, digits, `_` and `:`, and does not start with a " ++
                    "digit: `orders_placed`.",
            );
        }
    }
}

fn num(comptime n: u64) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

// ---- tests ----

const testing = std.testing;

/// A table sized for `routes` routes, with the default boundaries.
fn tableFor(routes: usize) !Table {
    var t = Table{};
    try t.size(testing.allocator, routes);
    for (0..routes) |i| t.nameRoute(i, "GET", "/r");
    return t;
}

test "a request lands in its route's slot, its class and its bucket" {
    var t = try tableFor(2);
    defer t.free(testing.allocator);

    t.observe(fixed_slots + 1, 200, 250);
    t.observe(fixed_slots + 1, 200, 250);
    t.observe(fixed_slots + 1, 404, 3);

    const base = (fixed_slots + 1) * t.stride();
    // Two 2xx, one 4xx, and nothing anywhere else.
    try testing.expectEqual(@as(u64, 2), t.counters[base + 2].load(.monotonic));
    try testing.expectEqual(@as(u64, 1), t.counters[base + 4].load(.monotonic));
    try testing.expectEqual(@as(u64, 3), t.countOf(fixed_slots + 1));
    try testing.expectEqual(@as(u64, 0), t.countOf(fixed_slots));

    // 3µs is the first bucket (≤100), 250µs the second (≤500).
    try testing.expectEqual(@as(u64, 1), t.counters[base + class_count].load(.monotonic));
    try testing.expectEqual(@as(u64, 2), t.counters[base + class_count + 1].load(.monotonic));
    // And the durations were summed.
    try testing.expectEqual(@as(u64, 503), t.counters[base + t.stride() - 1].load(.monotonic));
}

test "a request slower than every boundary lands in the overflow bucket" {
    var t = try tableFor(1);
    defer t.free(testing.allocator);

    t.observe(fixed_slots, 200, 2_000_000);
    const base = fixed_slots * t.stride() + class_count;
    try testing.expectEqual(
        @as(u64, 1),
        t.counters[base + t.boundaries.len].load(.monotonic),
    );
}

test "a request that ended with nothing on the wire is still counted" {
    var t = try tableFor(1);
    defer t.free(testing.allocator);

    // Status 0 is what `Ctx` carries when a client walked off before the
    // answer. Counting it as a class of its own is what keeps the classes
    // adding up to the number of requests.
    t.observe(fixed_slots, 0, 10);
    try testing.expectEqual(@as(u64, 1), t.countOf(fixed_slots));
    try testing.expectEqual(
        @as(u64, 1),
        t.counters[fixed_slots * t.stride()].load(.monotonic),
    );
}

test "the histogram Prometheus reads is cumulative, and ends at the count" {
    var t = try tableFor(1);
    defer t.free(testing.allocator);
    t.nameRoute(0, "GET", "/users/:id");

    t.observe(fixed_slots, 200, 50); // ≤100
    t.observe(fixed_slots, 200, 300); // ≤500
    t.observe(fixed_slots, 500, 9_000_000); // slower than every boundary

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try t.write(&out.writer);
    const page = out.written();

    const route = "method=\"GET\",route=\"/users/:id\"";
    try expectLine(page, "nilo_request_duration_seconds_bucket{" ++ route ++ ",le=\"0.0001\"} 1");
    try expectLine(page, "nilo_request_duration_seconds_bucket{" ++ route ++ ",le=\"0.0005\"} 2");
    try expectLine(page, "nilo_request_duration_seconds_bucket{" ++ route ++ ",le=\"1\"} 2");
    try expectLine(page, "nilo_request_duration_seconds_bucket{" ++ route ++ ",le=\"+Inf\"} 3");
    try expectLine(page, "nilo_request_duration_seconds_count{" ++ route ++ "} 3");
    try expectLine(page, "nilo_requests_total{" ++ route ++ ",status=\"2xx\"} 2");
    try expectLine(page, "nilo_requests_total{" ++ route ++ ",status=\"5xx\"} 1");
    try expectLine(page, "nilo_responses_total{code=\"200\"} 2");
    try expectLine(page, "nilo_responses_total{code=\"500\"} 1");
}

test "a route nobody has reached prints nothing at all" {
    var t = try tableFor(2);
    defer t.free(testing.allocator);
    t.nameRoute(0, "GET", "/busy");
    t.nameRoute(1, "GET", "/quiet");
    t.observe(fixed_slots, 200, 5);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try t.write(&out.writer);

    try testing.expect(std.mem.indexOf(u8, out.written(), "/busy") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "/quiet") == null);
}

test "an exposed number goes out with the type Prometheus needs" {
    var t = try tableFor(0);
    defer t.free(testing.allocator);

    var orders: Counter = .init(41);
    _ = orders.fetchAdd(1, .monotonic);
    const exposed = [_]Exposed{.{ .name = "orders_placed", .kind = .counter, .value = &orders }};
    t.exposed = &exposed;

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try t.write(&out.writer);

    try expectLine(out.written(), "# TYPE orders_placed counter");
    try expectLine(out.written(), "orders_placed 42");
}

test "a route pattern cannot break out of its own label" {
    var t = try tableFor(1);
    defer t.free(testing.allocator);
    // `validatePattern` would refuse this, so the escaping is a second wall
    // rather than the only one — but a page that lost its quoting is a page
    // Prometheus drops whole, not one bad series.
    t.nameRoute(0, "GET", "/x\",route=\"/y");
    t.observe(fixed_slots, 200, 5);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try t.write(&out.writer);

    try expectLine(
        out.written(),
        "nilo_requests_total{method=\"GET\",route=\"/x\\\",route=\\\"/y\",status=\"2xx\"} 1",
    );
}

fn expectLine(page: []const u8, line: []const u8) !void {
    var it = std.mem.splitScalar(u8, page, '\n');
    while (it.next()) |candidate| {
        if (std.mem.eql(u8, candidate, line)) return;
    }
    std.debug.print("missing line:\n  {s}\nin page:\n{s}\n", .{ line, page });
    return error.LineNotFound;
}

test "a duration goes out in the seconds Prometheus reads, without a float in the binary" {
    var buf: [64]u8 = undefined;
    const say = struct {
        fn it(b: []u8, micros: u64) ![]const u8 {
            var w = std.Io.Writer.fixed(b);
            try writeSeconds(&w, micros);
            return b[0..w.end];
        }
    }.it;

    try testing.expectEqualStrings("0.0001", try say(&buf, 100));
    try testing.expectEqualStrings("0.0005", try say(&buf, 500));
    try testing.expectEqualStrings("0.005", try say(&buf, 5_000));
    try testing.expectEqualStrings("1", try say(&buf, 1_000_000));
    try testing.expectEqualStrings("0", try say(&buf, 0));
    try testing.expectEqualStrings("0.000001", try say(&buf, 1));
    try testing.expectEqualStrings("12.5", try say(&buf, 12_500_000));
}
