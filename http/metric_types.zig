//! Metrics of your own, declared as fields of the service that counts them.
//!
//! ```zig
//! const Status = enum { pending, paid, refused };
//! const Shop = struct {
//!     orders_total: nilo.Counter(Status) = .{},
//!     checkout_seconds: nilo.Histogram(void, .{ .buckets = .{ 5_000, 50_000, 500_000 } }) = .{},
//!     queue_depth: nilo.Gauge(void) = .{},
//!
//!     pub const nilo_help = .{ .orders_total = "Orders, by status." };
//! };
//!
//! try app.provide(&shop);
//! fn checkout(shop: *Shop, …) !Receipt { shop.orders_total.inc(.paid); … }
//! ```
//!
//! **The service is the registry, and that is ADR 079 applied one level
//! down.** The route table is closed when `listen()` resolves it, so a route's
//! counter is an index. A service's metrics are closed when the program is
//! compiled: the fields are in the type, the labels are enums in the type, and
//! so the cell a call lands on is arithmetic on a value the caller already
//! wrote. There is no name per increment, no hash, no lock and no allocation,
//! and a label that is a constant folds to one address (ADR 079).
//!
//! A metric is **recognised by its field**: `app.provide(&shop)` asks the type
//! for fields carrying `nilo_metric` and keeps a table of them in the registry
//! entry, built at compile time. A service with none gets `null` there and
//! pays nothing; a program that never writes `nilo.Counter` links none of
//! this.
//!
//! **A label is an enum, never a string.** `Counter(Status)` has one cell a
//! variant, so the set of series is the set of values the type permits and a
//! label built from a request path is a compile error, which is the whole
//! defence against cardinality. A struct of enums is the product of them
//! (`.{ .method = .get, .outcome = .ok }`), the cell found by a mixed-radix sum
//! that is folded away for a constant.
//!
//! **Where each cell sits.** Every metric is `align(64)`, so two metrics of one
//! service never share a cache line and a hot counter does not slow a
//! neighbour. The cells of one labelled counter are packed beside each other:
//! one request touches one cell of one metric, and padding every cell would
//! make `Counter(Status)` three lines to hold three words. A histogram pads
//! each *row* instead, because a row is what one `observe` writes twice.
//!
//! **Recording is branch-free.** `observe` finds the bucket by comparing the
//! value against all the boundaries at once (`@Vector`) and counting the ones
//! below it, then does two `fetchAdd(.monotonic)`: the bucket and the sum. The
//! count is never stored; it is the cumulative `+Inf` at scrape, so a scrape
//! cannot read a count that disagrees with its own buckets.
//!
//! **Every cell prints, zeros included.** A series that first appears with its
//! first event loses that event to `rate()`, and a labelled metric's cells are
//! bounded by the enum, at most `max_cells` of them, so the page cannot grow
//! under a crawler the way an unbounded label would. (The route table prints
//! only the routes reached, for the opposite reason: its size is the
//! application's route count, with no ceiling, ADR 079.)
//!
//! Names are the field names, exactly. A counter ends `_total`, a histogram in
//! seconds ends `_seconds`, and `nilo_` is nilo's own (ADR 079). A module that
//! cannot import this file reaches the page through a `nilo_metrics` table
//! instead, and `setOf` below reads both.

const std = @import("std");
const naming = @import("names.zig");

/// Most cells (label combinations) one metric may have. **Unmeasured**: it is
/// the number past which an enum stops being a label and starts being a
/// dimension somebody should have thought about, and one metric of 256 cells
/// is 2 KB. Raising it needs a number (ADR 079).
pub const max_cells = 256;
/// Most boundaries a histogram may have; a vector of that many `u64` is two
/// AVX-512 registers or four AVX2 ones.
pub const max_buckets = 16;
/// Most series one page may carry from services. **Unmeasured**: a scrape
/// reads every one, so it bounds the page at some tens of kilobytes. `listen()`
/// refuses a program over it and names the biggest contributor (ADR 079).
pub const max_series = 1024;

const Cell = std.atomic.Value(u64);
const SignedCell = std.atomic.Value(i64);

/// What a family is, in Prometheus' own words.
pub const Kind = enum { counter, gauge, histogram };

/// What `observe` is given and what the page prints. `seconds` takes
/// microseconds and prints seconds through the integer printer
/// `writeSeconds` (no float formatter in the binary, ADR 079); `none`
/// prints the integers as they came.
pub const Unit = enum { seconds, none };

/// What a metric type says about itself, in its `nilo_metric` declaration.
pub const Info = struct {
    kind: Kind,
    unit: Unit,
    /// The label keys, in the order they print.
    keys: []const []const u8,
    cells: usize,
    /// Lines on the page, for the ceiling: a histogram row is every bucket,
    /// the `+Inf`, the sum and the count.
    series: usize,
};

/// One metric family a service holds, built when the service is provided.
pub const Family = struct {
    name: []const u8,
    kind: Kind,
    help: []const u8,
    keys: []const []const u8,
    series: usize,
    /// Write every sample of this family for the service at `owner`, each
    /// carrying `service="…"`. Does not write the `# HELP` / `# TYPE` lines:
    /// two services can hold one family, and the header is printed once.
    samples: *const fn (owner: *const anyopaque, w: *std.Io.Writer, service: []const u8) std.Io.Writer.Error!void,

    /// Whether two services holding this name agree on what it is. A family
    /// that is a counter with a `status` label in one and a gauge without in
    /// another cannot be one family on a page (Prometheus rejects the page).
    pub fn sameShape(a: Family, b: Family) bool {
        if (a.kind != b.kind or a.keys.len != b.keys.len) return false;
        for (a.keys, b.keys) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }
};

/// What a service type holds, in the registry entry. Static per type.
pub const Set = struct {
    families: []const Family,
};

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
/// ([ADR 079](../docs/adr/079-the-route-table-is-the-registry.md)).
/// A microsecond count is six decimal places of a second and nothing else, so
/// this is integer division and a trim.
pub fn writeSeconds(w: *std.Io.Writer, micros: u64) !void {
    const whole = micros / std.time.us_per_s;
    const frac = micros % std.time.us_per_s;
    if (frac == 0) return w.print("{d}", .{whole});

    var digits: [6]u8 = undefined;
    _ = std.fmt.bufPrint(&digits, "{d:0>6}", .{frac}) catch unreachable;
    var end: usize = digits.len;
    while (end > 1 and digits[end - 1] == '0') end -= 1;
    try w.print("{d}.{s}", .{ whole, digits[0..end] });
}

pub fn writeLabelValue(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(ch),
    };
}


// ---- labels ----

/// One axis of a label: an enum and the key it prints under.
const Axis = struct {
    key: []const u8,
    /// The struct field it is read from; empty when the label is the enum.
    field: []const u8,
    E: type,
};

fn isIdent(comptime s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |ch, i| {
        const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_' or
            (i > 0 and ch >= '0' and ch <= '9');
        if (!ok) return false;
    }
    return true;
}

fn isUpper(ch: u8) bool {
    return ch >= 'A' and ch <= 'Z';
}

fn isLowerOrDigit(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9');
}

/// `Status` as `status`, `HttpMethod` as `http_method`, `HTTPMethod` as
/// `http_method`: a break before a capital that follows a lower-case letter or
/// that ends an acronym.
fn snake(comptime short: []const u8) []const u8 {
    comptime {
        var out: [short.len * 2]u8 = undefined;
        var n: usize = 0;
        for (short, 0..) |ch, i| {
            if (isUpper(ch)) {
                const after_word = i > 0 and isLowerOrDigit(short[i - 1]);
                const ends_acronym = i > 0 and isUpper(short[i - 1]) and
                    i + 1 < short.len and isLowerOrDigit(short[i + 1]);
                if (after_word or ends_acronym) {
                    out[n] = '_';
                    n += 1;
                }
                out[n] = ch + ('a' - 'A');
            } else {
                out[n] = ch;
            }
            n += 1;
        }
        const final = out[0..n].*;
        return &final;
    }
}

/// The last name in a type's path: `shop.Status` is `Status`.
fn shortName(comptime full: []const u8) []const u8 {
    comptime {
        var start: usize = 0;
        for (full, 0..) |ch, i| {
            if (ch == '.') start = i + 1;
            if (ch == '(') break;
        }
        return full[start..];
    }
}

fn axesOf(comptime L: type, comptime who: []const u8, comptime histogram: bool) []const Axis {
    comptime {
        if (L == void) return &.{};
        const bad = " takes a label that is `void`, an exhaustive enum, or a struct of exhaustive enums";
        switch (@typeInfo(L)) {
            .@"enum" => |e| {
                if (e.mode != .exhaustive) @compileError(
                    "nilo: " ++ who ++ " was given the label " ++ naming.of(L) ++
                        ", which is not exhaustive.\n  Every value of a label becomes a series, so " ++
                        "it has to be an enum with no `_` in it: the set of series is then the set " ++
                        "of names in the type.",
                );
                const key = snake(shortName(@typeName(L)));
                checkKey(who, L, key, histogram);
                return &[_]Axis{.{ .key = key, .field = "", .E = L }};
            },
            .@"struct" => |s| {
                if (s.field_names.len == 0) @compileError(
                    "nilo: " ++ who ++ " was given the label " ++ naming.of(L) ++
                        ", which has no fields, so there would be no series.\n  Use `void` for a " ++
                        "metric with one series.",
                );
                var axes: [s.field_names.len]Axis = undefined;
                for (s.field_names, s.field_types, 0..) |f_name, f_type, i| {
                    if (@typeInfo(f_type) != .@"enum" or @typeInfo(f_type).@"enum".mode != .exhaustive) @compileError(
                        "nilo: " ++ who ++ " was given the label " ++ naming.of(L) ++ ", and its field `" ++
                            f_name ++ "` is a " ++ naming.of(f_type) ++ ".\n  " ++ who ++
                            bad ++ ": each field is one label key, and each value of it one series.",
                    );
                    checkKey(who, L, f_name, histogram);
                    axes[i] = .{ .key = f_name, .field = f_name, .E = f_type };
                }
                const final = axes;
                return &final;
            },
            else => @compileError(
                "nilo: " ++ who ++ " was given the label " ++ naming.of(L) ++ ", which is not " ++
                    "`void`, an exhaustive enum or a struct of exhaustive enums.\n  A label is a type " ++
                    "with a closed set of values, because every value is a series: a string would " ++
                    "make one per request path.",
            ),
        }
    }
}

fn checkKey(comptime who: []const u8, comptime L: type, comptime key: []const u8, comptime histogram: bool) void {
    comptime {
        if (!isIdent(key) or std.mem.startsWith(u8, key, "__")) @compileError(
            "nilo: " ++ who ++ " was given the label " ++ naming.of(L) ++ ", whose key `" ++ key ++
                "` is not a name Prometheus accepts for a label.\n  A key is letters, digits and `_`, " ++
                "and does not start with a digit or `__`: name the enum with a plain identifier.",
        );
        if (std.mem.eql(u8, key, "service") or (histogram and std.mem.eql(u8, key, "le"))) @compileError(
            "nilo: " ++ who ++ " was given the label " ++ naming.of(L) ++ ", whose key `" ++ key ++
                "` is one nilo writes itself.\n  `service` names the service holding the metric" ++
                (if (histogram) ", and `le` the bucket" else "") ++ ". Rename the enum or the field.",
        );
    }
}

/// What a label type is made of: how many cells, which one a value picks, and
/// what each prints.
fn Layout(comptime L: type, comptime who: []const u8, comptime histogram: bool) type {
    const axes = comptime axesOf(L, who, histogram);
    const count = comptime blk: {
        var n: u64 = 1;
        for (axes) |ax| {
            n *= @typeInfo(ax.E).@"enum".field_names.len;
            if (n > max_cells) @compileError(
                "nilo: " ++ who ++ "(" ++ naming.of(L) ++ ") would have more than " ++
                    std.fmt.comptimePrint("{d}", .{max_cells}) ++
                    " cells, and a metric holds at most that many.\n  Every value of every label " ++
                    "is a series Prometheus stores and a scrape reads, so a label that wide is a " ++
                    "dimension to drop or to bucket into a smaller enum (ADR 079).",
            );
        }
        if (n == 0) @compileError(
            "nilo: " ++ who ++ "(" ++ naming.of(L) ++ ") has a label with no values, so it would " ++
                "have no series.",
        );
        break :blk n;
    };
    const key_list = comptime blk: {
        var keys: [axes.len][]const u8 = undefined;
        for (axes, 0..) |ax, i| keys[i] = ax.key;
        const final = keys;
        break :blk &final;
    };

    return struct {
        pub const cells: usize = count;
        pub const keys: []const []const u8 = key_list;

        /// Position of `v` among its enum's names, which is not its integer
        /// value for an enum with explicit values.
        inline fn ordinal(comptime E: type, v: E) usize {
            const info = @typeInfo(E).@"enum";
            const dense = comptime for (info.field_values, 0..) |value, i| {
                if (value != i) break false;
            } else true;
            if (comptime dense) return @intCast(@intFromEnum(v));
            switch (v) {
                inline else => |only| return comptime for (info.field_names, 0..) |name, i| {
                    if (std.mem.eql(u8, name, @tagName(only))) break i;
                } else unreachable,
            }
        }

        /// The cell a label picks. Mixed radix over the axes, so a constant
        /// label is a constant and the call is one address.
        pub inline fn index(label: L) usize {
            var i: usize = 0;
            inline for (axes) |ax| {
                const part = if (comptime @typeInfo(L) == .@"enum") label else @field(label, ax.field);
                i = i * @typeInfo(ax.E).@"enum".field_names.len + ordinal(ax.E, part);
            }
            return i;
        }

        /// `,status="paid"` for each axis of cell `cell`, with a leading comma
        /// because `service="…"` always comes first.
        pub fn writeLabels(w: *std.Io.Writer, cell: usize) std.Io.Writer.Error!void {
            var position: [axes.len]usize = undefined;
            var rest = cell;
            inline for (0..axes.len) |r| {
                const k = axes.len - 1 - r;
                const n = @typeInfo(axes[k].E).@"enum".field_names.len;
                position[k] = rest % n;
                rest /= n;
            }
            inline for (axes, 0..) |ax, k| {
                try w.writeAll(",");
                try w.writeAll(ax.key);
                try w.writeAll("=\"");
                try writeLabelValue(w, @typeInfo(ax.E).@"enum".field_names[position[k]]);
                try w.writeByte('"');
            }
        }
    };
}

/// `name{service="shop",status="paid"`, ready for `,le="…"` or `}`.
fn writeHead(w: *std.Io.Writer, name: []const u8, suffix: []const u8, service: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(name);
    try w.writeAll(suffix);
    try w.writeAll("{service=\"");
    try writeLabelValue(w, service);
    try w.writeByte('"');
}

// ---- Counter and Gauge ----

/// A number that only goes up, one cell per value of `L`.
///
/// `L` is `void` for one series, an exhaustive enum, or a struct of them. For
/// `void` the label is left out: `orders.inc()`; otherwise it is the first
/// argument: `orders.inc(.paid)`. **The signature is chosen while compiling**
/// rather than taking `{}` for the void case, because `inc({})` reads as noise
/// at the call site of the commonest kind of metric.
///
/// Holds a `u64` and is atomic: handlers run on many threads and a plain
/// integer counted from all of them loses increments without saying so. The
/// field's name is the metric's, and must end `_total` (ADR 079).
pub fn Counter(comptime L: type) type {
    const lay = Layout(L, "nilo.Counter", false);
    return struct {
        const Self = @This();

        /// 64 so no other metric shares the line.
        cells: [lay.cells]Cell align(64) = @splat(Cell.init(0)),

        pub const nilo_type_name = "nilo.Counter(" ++ naming.of(L) ++ ")";
        pub const nilo_metric: Info = .{
            .kind = .counter,
            .unit = .none,
            .keys = lay.keys,
            .cells = lay.cells,
            .series = lay.cells,
        };

        /// Add one. `inc()` for a `void` label, `inc(label)` otherwise.
        pub const inc = if (L == void) struct {
            fn f(self: *Self) void {
                _ = self.cells[0].fetchAdd(1, .monotonic);
            }
        }.f else struct {
            fn f(self: *Self, label: L) void {
                _ = self.cells[lay.index(label)].fetchAdd(1, .monotonic);
            }
        }.f;

        /// Add `n`. `add(n)` for a `void` label, `add(label, n)` otherwise.
        pub const add = if (L == void) struct {
            fn f(self: *Self, n: u64) void {
                _ = self.cells[0].fetchAdd(n, .monotonic);
            }
        }.f else struct {
            fn f(self: *Self, label: L, n: u64) void {
                _ = self.cells[lay.index(label)].fetchAdd(n, .monotonic);
            }
        }.f;

        /// What the counter holds now. For a test and for code that wants to
        /// act on its own count; the page reads it the same way.
        pub const get = if (L == void) struct {
            fn f(self: *const Self) u64 {
                return self.cells[0].load(.monotonic);
            }
        }.f else struct {
            fn f(self: *const Self, label: L) u64 {
                return self.cells[lay.index(label)].load(.monotonic);
            }
        }.f;

        pub fn writeSamples(self: *const Self, w: *std.Io.Writer, name: []const u8, service: []const u8) std.Io.Writer.Error!void {
            for (&self.cells, 0..) |*c, i| {
                try writeHead(w, name, "", service);
                try lay.writeLabels(w, i);
                try w.print("}} {d}\n", .{c.load(.monotonic)});
            }
        }
    };
}

/// A number that goes up and down, one cell per value of `L`.
///
/// **Signed (`i64`).** A gauge is read as a difference more often than as a
/// total (`inc` on the way in, `dec` on the way out, from different threads),
/// and one read a moment after a `dec` has landed and before its `inc` is
/// visible must show a negative rather than wrap to 1.8e19, which no dashboard
/// recovers from. The price is half the range, which a gauge does not need.
///
/// `set(n)`, `inc()`, `dec()`; with a label, the label comes first (see
/// `Counter` for why the signature differs).
pub fn Gauge(comptime L: type) type {
    const lay = Layout(L, "nilo.Gauge", false);
    return struct {
        const Self = @This();

        cells: [lay.cells]SignedCell align(64) = @splat(SignedCell.init(0)),

        pub const nilo_type_name = "nilo.Gauge(" ++ naming.of(L) ++ ")";
        pub const nilo_metric: Info = .{
            .kind = .gauge,
            .unit = .none,
            .keys = lay.keys,
            .cells = lay.cells,
            .series = lay.cells,
        };

        pub const set = if (L == void) struct {
            fn f(self: *Self, n: i64) void {
                self.cells[0].store(n, .monotonic);
            }
        }.f else struct {
            fn f(self: *Self, label: L, n: i64) void {
                self.cells[lay.index(label)].store(n, .monotonic);
            }
        }.f;

        pub const inc = if (L == void) struct {
            fn f(self: *Self) void {
                _ = self.cells[0].fetchAdd(1, .monotonic);
            }
        }.f else struct {
            fn f(self: *Self, label: L) void {
                _ = self.cells[lay.index(label)].fetchAdd(1, .monotonic);
            }
        }.f;

        pub const dec = if (L == void) struct {
            fn f(self: *Self) void {
                _ = self.cells[0].fetchSub(1, .monotonic);
            }
        }.f else struct {
            fn f(self: *Self, label: L) void {
                _ = self.cells[lay.index(label)].fetchSub(1, .monotonic);
            }
        }.f;

        pub const get = if (L == void) struct {
            fn f(self: *const Self) i64 {
                return self.cells[0].load(.monotonic);
            }
        }.f else struct {
            fn f(self: *const Self, label: L) i64 {
                return self.cells[lay.index(label)].load(.monotonic);
            }
        }.f;

        pub fn writeSamples(self: *const Self, w: *std.Io.Writer, name: []const u8, service: []const u8) std.Io.Writer.Error!void {
            for (&self.cells, 0..) |*c, i| {
                try writeHead(w, name, "", service);
                try lay.writeLabels(w, i);
                try w.print("}} {d}\n", .{c.load(.monotonic)});
            }
        }
    };
}

// ---- Histogram ----

const Config = struct {
    edges: []const u64,
    unit: Unit,
};

/// Read `.{ .buckets = …, .unit = … }`, said while compiling.
fn configOf(comptime opts: anytype) Config {
    comptime {
        const who = "nilo.Histogram";
        const O = @TypeOf(opts);
        if (@typeInfo(O) != .@"struct") @compileError(
            "nilo: " ++ who ++ " was given options that are not a struct.\n  Write " ++
                "`nilo.Histogram(void, .{ .buckets = .{ 5_000, 50_000, 500_000 } })`.",
        );
        for (@typeInfo(O).@"struct".field_names) |f_name| {
            if (!std.mem.eql(u8, f_name, "buckets") and !std.mem.eql(u8, f_name, "unit")) @compileError(
                "nilo: " ++ who ++ " was given an option `" ++ f_name ++ "`, and it takes `.buckets` " ++
                    "and `.unit`.",
            );
        }
        if (!@hasField(O, "buckets")) @compileError(
            "nilo: " ++ who ++ " was given no `.buckets`, so it would count nothing.\n  Name the " ++
                "boundaries, climbing: `.buckets = .{ 5_000, 50_000, 500_000 }` (microseconds for " ++
                "the default `.unit = .seconds`).",
        );

        var unit: Unit = .seconds;
        if (@hasField(O, "unit")) {
            const wanted = @tagName(opts.unit);
            if (std.mem.eql(u8, wanted, "seconds")) {
                unit = .seconds;
            } else if (std.mem.eql(u8, wanted, "none")) {
                unit = .none;
            } else @compileError(
                "nilo: " ++ who ++ " was given the unit `." ++ wanted ++ "`, and it knows `.seconds` " ++
                    "(microseconds in, seconds out) and `.none` (integers as given).",
            );
        }

        const n = opts.buckets.len;
        if (n == 0) @compileError(
            "nilo: " ++ who ++ " was given no buckets, so it would count nothing.\n  Name the " ++
                "boundaries, climbing: `.buckets = .{ 5_000, 50_000, 500_000 }`.",
        );
        if (n > max_buckets) @compileError(
            "nilo: " ++ who ++ " was given " ++ std.fmt.comptimePrint("{d}", .{n}) ++
                " buckets, and a histogram holds at most " ++
                std.fmt.comptimePrint("{d}", .{max_buckets}) ++ ".\n  Each one is a series per label " ++
                "value and a comparison per `observe`; fewer, wider boundaries answer the same " ++
                "questions.",
        );

        var edges: [n]u64 = undefined;
        for (0..n) |i| {
            const e = opts.buckets[i];
            if (@typeInfo(@TypeOf(e)) != .int and @typeInfo(@TypeOf(e)) != .comptime_int) @compileError(
                "nilo: " ++ who ++ " was given a bucket that is a " ++ naming.of(@TypeOf(e)) ++
                    ", and boundaries are integers.\n  A float would need a float printer in the " ++
                    "binary (ADR 079): use microseconds with the default `.unit = .seconds`, " ++
                    "or whole numbers with `.unit = .none`.",
            );
            if (e < 0 or e > std.math.maxInt(u64)) @compileError(
                "nilo: " ++ who ++ " was given the bucket " ++ std.fmt.comptimePrint("{d}", .{e}) ++
                    ", which does not fit an unsigned 64-bit boundary.",
            );
            edges[i] = e;
            if (i == 0 and e == 0) @compileError(
                "nilo: " ++ who ++ " was given a bucket of 0, and the first boundary has to be " ++
                    "above zero.\n  A bucket counts every value at or below its boundary.",
            );
            if (i > 0 and e <= edges[i - 1]) @compileError(
                "nilo: " ++ who ++ " was given the bucket " ++ std.fmt.comptimePrint("{d}", .{e}) ++
                    " after " ++ std.fmt.comptimePrint("{d}", .{edges[i - 1]}) ++
                    ", and the boundaries have to climb.\n  Each one counts every value at or below " ++
                    "it, so a list that goes backwards leaves the later bucket counting nothing " ++
                    "the earlier one did not.",
            );
        }
        const final = edges;
        return .{ .edges = &final, .unit = unit };
    }
}

/// A distribution, one row per value of `L`: how many observations fell at or
/// below each boundary, and their sum.
///
/// `.buckets` is up to sixteen integers, strictly climbing, the first above
/// zero. `.unit = .seconds` (the default) takes microseconds and prints
/// seconds, and the field's name must then end `_seconds`; `.unit = .none`
/// prints integers as given (bytes, items) and has no suffix to hold. With a
/// `void` label, `observe(v)`; otherwise `observe(label, v)`.
///
/// **Boundaries are the metric's own, not shared**, unlike the route
/// histogram's: a checkout and a body size live at different scales, and
/// there is no second route to compare them with (ADR 079).
///
/// A row is `buckets + 2` words and `align(64)`: the buckets, the overflow
/// (what `+Inf` adds), and the sum. Count is derived at scrape.
pub fn Histogram(comptime L: type, comptime opts: anytype) type {
    const cfg = comptime configOf(opts);
    const lay = Layout(L, "nilo.Histogram", true);
    const n = cfg.edges.len;
    return struct {
        const Self = @This();
        const Row = struct {
            /// `n` buckets, the overflow, then the sum.
            slots: [n + 2]Cell align(64) = @splat(Cell.init(0)),
        };

        rows: [lay.cells]Row align(64) = @splat(Row{}),

        pub const nilo_type_name = "nilo.Histogram(" ++ naming.of(L) ++ ", …)";
        pub const nilo_metric: Info = .{
            .kind = .histogram,
            .unit = cfg.unit,
            .keys = lay.keys,
            .cells = lay.cells,
            .series = lay.cells * (n + 3),
        };

        /// Which bucket `v` falls in: the number of boundaries below it, so a
        /// value on a boundary is in that boundary's bucket (`le` is "at or
        /// below"). A compare of all boundaries at once and a count of the
        /// ones that came out true; no loop and no branch.
        inline fn bucketOf(v: u64) usize {
            const edges: @Vector(n, u64) = cfg.edges[0..n].*;
            const below = edges < @as(@Vector(n, u64), @splat(v));
            const bits: @Int(.unsigned, n) = @bitCast(below);
            return @popCount(bits);
        }

        inline fn record(self: *Self, cell: usize, v: u64) void {
            const row = &self.rows[cell];
            _ = row.slots[bucketOf(v)].fetchAdd(1, .monotonic);
            _ = row.slots[n + 1].fetchAdd(v, .monotonic);
        }

        /// Record one observation. `observe(v)` for a `void` label,
        /// `observe(label, v)` otherwise; `v` in microseconds for `.seconds`.
        pub const observe = if (L == void) struct {
            fn f(self: *Self, v: u64) void {
                self.record(0, v);
            }
        }.f else struct {
            fn f(self: *Self, label: L, v: u64) void {
                self.record(lay.index(label), v);
            }
        }.f;

        /// How many observations a row holds: the sum of its buckets.
        pub fn countOf(self: *const Self, cell: usize) u64 {
            var total: u64 = 0;
            for (self.rows[cell].slots[0 .. n + 1]) |*c| total += c.load(.monotonic);
            return total;
        }

        fn writeValue(w: *std.Io.Writer, v: u64) std.Io.Writer.Error!void {
            if (cfg.unit == .seconds) return writeSeconds(w, v);
            try w.print("{d}", .{v});
        }

        pub fn writeSamples(self: *const Self, w: *std.Io.Writer, name: []const u8, service: []const u8) std.Io.Writer.Error!void {
            for (&self.rows, 0..) |*row, i| {
                // Cumulative, because `le="500"` counts everything at or below
                // 500 and `+Inf` is the count.
                var running: u64 = 0;
                inline for (cfg.edges, 0..) |edge, b| {
                    running += row.slots[b].load(.monotonic);
                    try writeHead(w, name, "_bucket", service);
                    try lay.writeLabels(w, i);
                    try w.writeAll(",le=\"");
                    try writeValue(w, edge);
                    try w.print("\"}} {d}\n", .{running});
                }
                running += row.slots[n].load(.monotonic);
                try writeHead(w, name, "_bucket", service);
                try lay.writeLabels(w, i);
                try w.print(",le=\"+Inf\"}} {d}\n", .{running});

                try writeHead(w, name, "_sum", service);
                try lay.writeLabels(w, i);
                try w.writeAll("} ");
                try writeValue(w, row.slots[n + 1].load(.monotonic));
                try w.writeByte('\n');

                try writeHead(w, name, "_count", service);
                try lay.writeLabels(w, i);
                try w.print("}} {d}\n", .{running});
            }
        }
    };
}

// ---- finding a service's metrics ----

/// Whether a field's type is one of the three above.
fn isMetric(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .@"struct" => @hasDecl(F, "nilo_metric") and @TypeOf(F.nilo_metric) == Info,
        else => false,
    };
}

/// A metric name nilo can print: Prometheus' alphabet, and not nilo's own.
fn checkFieldName(comptime T: type, comptime name: []const u8) void {
    comptime {
        if (std.mem.startsWith(u8, name, "nilo_")) @compileError(
            "nilo: " ++ naming.of(T) ++ "." ++ name ++ " starts with `nilo_`, which is what nilo's " ++
                "own metrics are called.\n  Two families under one name make the whole page " ++
                "unparseable, not just that line. Name it after your application: `" ++
                name["nilo_".len..] ++ "`.",
        );
        checkName(naming.of(T) ++ "." ++ name, name);
    }
}

fn checkName(comptime where: []const u8, comptime name: []const u8) void {
    comptime {
        for (name, 0..) |ch, i| {
            const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_' or
                ch == ':' or (i > 0 and ch >= '0' and ch <= '9');
            if (!ok) @compileError(
                "nilo: the metric name " ++ where ++ " has a `" ++ [_]u8{ch} ++
                    "` in it, and Prometheus would refuse the whole page rather than that one " ++
                    "line.\n  A name is letters, digits, `_` and `:`, and does not start with a digit.",
            );
        }
    }
}

fn helpOf(comptime T: type, comptime name: []const u8) []const u8 {
    comptime {
        if (!@hasDecl(T, "nilo_help")) return "";
        const H = @TypeOf(T.nilo_help);
        if (@typeInfo(H) != .@"struct") @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_help is not a struct of strings.\n  " ++
                "`pub const nilo_help = .{ .orders_total = \"Orders, by status.\" };`",
        );
        if (!@hasField(H, name)) return "";
        return @field(T.nilo_help, name);
    }
}

/// `nilo_help` names a field that holds no metric: a typo that would leave a
/// metric without its sentence and say nothing.
fn checkHelp(comptime T: type) void {
    comptime {
        if (!@hasDecl(T, "nilo_help")) return;
        const H = @TypeOf(T.nilo_help);
        if (@typeInfo(H) != .@"struct") @compileError(
            "nilo: " ++ naming.of(T) ++ ".nilo_help is not a struct of strings.\n  " ++
                "`pub const nilo_help = .{ .orders_total = \"Orders, by status.\" };`",
        );
        for (@typeInfo(H).@"struct".field_names) |key| {
            const found = for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |f_name, f_type| {
                if (std.mem.eql(u8, f_name, key) and isMetric(f_type)) break true;
            } else false;
            if (!found) @compileError(
                "nilo: " ++ naming.of(T) ++ ".nilo_help has `" ++ key ++ "`, and " ++ naming.of(T) ++
                    " has no metric field of that name.\n  The help is looked up by the field's name; " ++
                    "check the spelling against the `nilo.Counter`, `nilo.Gauge` or `nilo.Histogram` field.",
            );
        }
    }
}

fn FieldSamples(comptime T: type, comptime field: []const u8) type {
    return struct {
        fn write(owner: *const anyopaque, w: *std.Io.Writer, service: []const u8) std.Io.Writer.Error!void {
            const self: *const T = @ptrCast(@alignCast(owner));
            try @field(self, field).writeSamples(w, field, service);
        }
    };
}

/// The shape every `nilo_metrics` row must have, said once.
fn rowShape(comptime T: type) []const u8 {
    return "\n  pub const nilo_metrics = .{\n    .{ \"nilo_" ++ "x_total\", .counter, \"What it counts.\", xOf },\n  };\n" ++
        "  fn xOf(self: *const " ++ naming.of(T) ++ ") u64 { … }   // or ?u64, null prints nothing";
}

fn TableSamples(comptime T: type, comptime name: []const u8, comptime reader: anytype) type {
    return struct {
        fn write(owner: *const anyopaque, w: *std.Io.Writer, service: []const u8) std.Io.Writer.Error!void {
            const self: *const T = @ptrCast(@alignCast(owner));
            const got: ?u64 = reader(self);
            const value = got orelse return;
            try writeHead(w, name, "", service);
            try w.print("}} {d}\n", .{value});
        }
    };
}

const row_fields = 4;

/// The families of `T`: its metric fields, then the rows of its
/// `nilo_metrics`. A comptime array, built once per service type.
fn buildFamilies(comptime T: type, comptime total: usize) [total]Family {
    comptime {
        var out: [total]Family = undefined;
        var n: usize = 0;

        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types) |f_name, f_type| {
            if (!isMetric(f_type)) continue;
            const m: Info = f_type.nilo_metric;
            checkFieldName(T, f_name);
            switch (m.kind) {
                .counter => if (!std.mem.endsWith(u8, f_name, "_total")) @compileError(
                    "nilo: " ++ naming.of(T) ++ "." ++ f_name ++ " is a counter, and a counter's name " ++
                        "ends `_total`.\n  Prometheus tooling reads the suffix to know it only climbs: " ++
                        "name it `" ++ f_name ++ "_total`.",
                ),
                .histogram => if (m.unit == .seconds and !std.mem.endsWith(u8, f_name, "_seconds")) @compileError(
                    "nilo: " ++ naming.of(T) ++ "." ++ f_name ++ " is a histogram in seconds, and its " ++
                        "name ends `_seconds`.\n  Rename it `" ++ f_name ++ "_seconds`, or give " ++
                        "`.unit = .none` if it is not a duration (bytes, items).",
                ),
                .gauge => {},
            }
            out[n] = .{
                .name = f_name,
                .kind = m.kind,
                .help = helpOf(T, f_name),
                .keys = m.keys,
                .series = m.series,
                .samples = &FieldSamples(T, f_name).write,
            };
            n += 1;
        }

        if (@hasDecl(T, "nilo_metrics")) {
            const rows = T.nilo_metrics;
            const R = @TypeOf(rows);
            if (@typeInfo(R) != .@"struct") @compileError(
                "nilo: " ++ naming.of(T) ++ ".nilo_metrics is not a tuple of rows." ++ rowShape(T),
            );
            for (0..rows.len) |ri| {
                const row = rows[ri];
                const Row = @TypeOf(row);
                const at = naming.of(T) ++ ".nilo_metrics row " ++ std.fmt.comptimePrint("{d}", .{ri + 1});
                if (@typeInfo(Row) != .@"struct" or row.len != row_fields) @compileError(
                    "nilo: " ++ at ++ " is not a name, a kind, a help and a reader." ++ rowShape(T),
                );
                const name = asText(row[0], at ++ "'s name");
                const help = asText(row[2], at ++ "'s help");
                if (@TypeOf(row[1]) != @TypeOf(.enum_literal)) @compileError(
                    "nilo: " ++ at ++ " has a kind that is not `.counter` or `.gauge`." ++ rowShape(T),
                );
                const kind_name = @tagName(row[1]);
                const kind: Kind = if (std.mem.eql(u8, kind_name, "counter"))
                    .counter
                else if (std.mem.eql(u8, kind_name, "gauge"))
                    .gauge
                else
                    @compileError("nilo: " ++ at ++ " has the kind `." ++ kind_name ++
                        "`, and a table row is `.counter` or `.gauge`." ++ rowShape(T));
                checkName(at, name);
                if (name.len == 0) @compileError("nilo: " ++ at ++ " has no name." ++ rowShape(T));
                if (kind == .counter and !std.mem.endsWith(u8, name, "_total")) @compileError(
                    "nilo: " ++ at ++ " is the counter \"" ++ name ++ "\", and a counter's name ends " ++
                        "`_total`.",
                );
                checkReader(T, at, row[3]);
                out[n] = .{
                    .name = name,
                    .kind = kind,
                    .help = help,
                    .keys = &.{},
                    .series = 1,
                    .samples = &TableSamples(T, name, row[3]).write,
                };
                n += 1;
            }
        }
        return out;
    }
}

fn asText(comptime v: anytype, comptime what: []const u8) []const u8 {
    comptime {
        const V = @TypeOf(v);
        const ok = switch (@typeInfo(V)) {
            .pointer => |p| switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => p.child == u8,
            },
            else => false,
        };
        if (!ok) @compileError("nilo: " ++ what ++ " is a " ++ naming.of(V) ++ ", and it has to be a string.");
        return v;
    }
}

/// A row's reader: `fn (*const T) u64`, or `?u64` for a service that has
/// nothing to say yet.
fn checkReader(comptime T: type, comptime at: []const u8, comptime reader: anytype) void {
    comptime {
        const shape = "\n  The reader is `fn (self: *const " ++ naming.of(T) ++ ") u64`, or `?u64` when " ++
            "there is nothing to report and the sample should be left out.";
        const R = @TypeOf(reader);
        const info = switch (@typeInfo(R)) {
            .@"fn" => |f| f,
            .pointer => |p| if (@typeInfo(p.child) == .@"fn") @typeInfo(p.child).@"fn" else @compileError(
                "nilo: " ++ at ++ " has a reader that is not a function." ++ shape,
            ),
            else => @compileError("nilo: " ++ at ++ " has a reader that is not a function." ++ shape),
        };
        if (info.param_types.len != 1) @compileError(
            "nilo: " ++ at ++ "'s reader takes " ++ std.fmt.comptimePrint("{d}", .{info.param_types.len}) ++
                " parameters, and it has to take 1." ++ shape,
        );
        if (info.param_types[0] != *const T) @compileError(
            "nilo: " ++ at ++ "'s reader takes " ++ naming.of(info.param_types[0] orelse anyopaque) ++
                ", and it has to take `*const " ++ naming.of(T) ++ "`." ++ shape,
        );
        if (info.return_type != u64 and info.return_type != ?u64) @compileError(
            "nilo: " ++ at ++ "'s reader returns something other than `u64` or `?u64`." ++ shape,
        );
    }
}

fn countFamilies(comptime T: type) usize {
    comptime {
        if (@typeInfo(T) != .@"struct") return 0;
        var n: usize = 0;
        for (@typeInfo(T).@"struct".field_types) |f_type| {
            if (isMetric(f_type)) n += 1;
        }
        if (@hasDecl(T, "nilo_metrics")) n += T.nilo_metrics.len;
        return n;
    }
}

/// The metrics a service type holds, or null for the ordinary service that
/// holds none: a comptime-known null, so a program that provides only those
/// links nothing of the printing.
pub fn setOf(comptime T: type) ?*const Set {
    comptime {
        const total = countFamilies(T);
        if (total == 0) {
            // A `nilo_help` on a type with no metric at all is a typo too.
            if (@typeInfo(T) == .@"struct") checkHelp(T);
            return null;
        }
        checkHelp(T);
        const S = struct {
            const families: [total]Family = buildFamilies(T, total);
            const set: Set = .{ .families = &families };
        };
        return &S.set;
    }
}

// ---- tests ----

const testing = std.testing;

fn render(value: anytype, name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try value.writeSamples(&out.writer, name, "shop");
    return out.toOwnedSlice();
}

const Status = enum { pending, paid, refused };
const HttpMethod = enum { get, post };
const Outcome = enum { ok, failed };

test "a label enum's key is its name in snake case" {
    try testing.expectEqualStrings("status", comptime snake("Status"));
    try testing.expectEqualStrings("http_method", comptime snake("HttpMethod"));
    try testing.expectEqualStrings("http_method", comptime snake("HTTPMethod"));
    try testing.expectEqualStrings("a1_b", comptime snake("A1B"));
    try testing.expectEqualStrings("Status", comptime shortName("metric_types.Status"));
    try testing.expectEqualStrings("Status", comptime shortName("a.b.Status"));
}

test "every value of an enum label picks its own cell, and no two share one" {
    const lay = Layout(Status, "nilo.Counter", false);
    try testing.expectEqual(@as(usize, 3), lay.cells);
    try testing.expectEqual(@as(usize, 0), lay.index(.pending));
    try testing.expectEqual(@as(usize, 1), lay.index(.paid));
    try testing.expectEqual(@as(usize, 2), lay.index(.refused));
}

test "an enum with explicit values is indexed by position, not by value" {
    const Sparse = enum(u8) { low = 10, mid = 200, high = 7 };
    const lay = Layout(Sparse, "nilo.Counter", false);
    try testing.expectEqual(@as(usize, 3), lay.cells);
    try testing.expectEqual(@as(usize, 0), lay.index(.low));
    try testing.expectEqual(@as(usize, 1), lay.index(.mid));
    try testing.expectEqual(@as(usize, 2), lay.index(.high));
}

test "a struct of enums is the product of them, in a mixed radix" {
    const Pair = struct { method: HttpMethod, outcome: Outcome };
    const lay = Layout(Pair, "nilo.Counter", false);
    try testing.expectEqual(@as(usize, 4), lay.cells);
    var seen: [4]bool = @splat(false);
    inline for (.{ HttpMethod.get, HttpMethod.post }) |m| {
        inline for (.{ Outcome.ok, Outcome.failed }) |o| {
            const i = lay.index(.{ .method = m, .outcome = o });
            try testing.expect(!seen[i]);
            seen[i] = true;
        }
    }
    try testing.expectEqual(@as(usize, 0), lay.index(.{ .method = .get, .outcome = .ok }));
    try testing.expectEqual(@as(usize, 3), lay.index(.{ .method = .post, .outcome = .failed }));
}

test "every cell of a counter prints at zero, with the service and its labels" {
    var c: Counter(Status) = .{};
    const page = try render(&c, "orders_total");
    defer testing.allocator.free(page);
    try testing.expectEqualStrings(
        "orders_total{service=\"shop\",status=\"pending\"} 0\n" ++
            "orders_total{service=\"shop\",status=\"paid\"} 0\n" ++
            "orders_total{service=\"shop\",status=\"refused\"} 0\n",
        page,
    );
}

test "a counter counts per label, and a void label leaves the argument out" {
    var by: Counter(Status) = .{};
    by.inc(.paid);
    by.inc(.paid);
    by.add(.refused, 5);
    try testing.expectEqual(@as(u64, 2), by.get(.paid));
    try testing.expectEqual(@as(u64, 5), by.get(.refused));
    try testing.expectEqual(@as(u64, 0), by.get(.pending));

    var one: Counter(void) = .{};
    one.inc();
    one.add(9);
    try testing.expectEqual(@as(u64, 10), one.get());
    const page = try render(&one, "hits_total");
    defer testing.allocator.free(page);
    try testing.expectEqualStrings("hits_total{service=\"shop\"} 10\n", page);
}

test "a gauge goes down, and below zero rather than around" {
    var g: Gauge(Outcome) = .{};
    g.set(.ok, 7);
    g.dec(.ok);
    g.dec(.failed);
    try testing.expectEqual(@as(i64, 6), g.get(.ok));
    try testing.expectEqual(@as(i64, -1), g.get(.failed));
    const page = try render(&g, "queue_depth");
    defer testing.allocator.free(page);
    try testing.expectEqualStrings(
        "queue_depth{service=\"shop\",outcome=\"ok\"} 6\nqueue_depth{service=\"shop\",outcome=\"failed\"} -1\n",
        page,
    );
}

test "a histogram is cumulative, ends at the count, and sums in seconds" {
    var h: Histogram(void, .{ .buckets = .{ 5_000, 50_000, 500_000 } }) = .{};
    h.observe(1_000); // <= 5ms
    h.observe(5_000); // on the boundary: still the first bucket
    h.observe(40_000); // <= 50ms
    h.observe(9_000_000); // past every boundary
    const page = try render(&h, "checkout_seconds");
    defer testing.allocator.free(page);
    try testing.expectEqualStrings(
        "checkout_seconds_bucket{service=\"shop\",le=\"0.005\"} 2\n" ++
            "checkout_seconds_bucket{service=\"shop\",le=\"0.05\"} 3\n" ++
            "checkout_seconds_bucket{service=\"shop\",le=\"0.5\"} 3\n" ++
            "checkout_seconds_bucket{service=\"shop\",le=\"+Inf\"} 4\n" ++
            "checkout_seconds_sum{service=\"shop\"} 9.046\n" ++
            "checkout_seconds_count{service=\"shop\"} 4\n",
        page,
    );
}

test "a histogram with no unit prints its integers as they came" {
    var h: Histogram(Outcome, .{ .unit = .none, .buckets = .{ 1024, 65536 } }) = .{};
    h.observe(.ok, 100);
    h.observe(.ok, 70_000);
    h.observe(.failed, 2_000);
    const page = try render(&h, "body_bytes");
    defer testing.allocator.free(page);
    try testing.expectEqualStrings(
        "body_bytes_bucket{service=\"shop\",outcome=\"ok\",le=\"1024\"} 1\n" ++
            "body_bytes_bucket{service=\"shop\",outcome=\"ok\",le=\"65536\"} 1\n" ++
            "body_bytes_bucket{service=\"shop\",outcome=\"ok\",le=\"+Inf\"} 2\n" ++
            "body_bytes_sum{service=\"shop\",outcome=\"ok\"} 70100\n" ++
            "body_bytes_count{service=\"shop\",outcome=\"ok\"} 2\n" ++
            "body_bytes_bucket{service=\"shop\",outcome=\"failed\",le=\"1024\"} 0\n" ++
            "body_bytes_bucket{service=\"shop\",outcome=\"failed\",le=\"65536\"} 1\n" ++
            "body_bytes_bucket{service=\"shop\",outcome=\"failed\",le=\"+Inf\"} 1\n" ++
            "body_bytes_sum{service=\"shop\",outcome=\"failed\"} 2000\n" ++
            "body_bytes_count{service=\"shop\",outcome=\"failed\"} 1\n",
        page,
    );
}

test "the bucket of a value is the number of boundaries below it" {
    const H = Histogram(void, .{ .buckets = .{ 10, 20, 30 } });
    try testing.expectEqual(@as(usize, 0), H.bucketOf(0));
    try testing.expectEqual(@as(usize, 0), H.bucketOf(10));
    try testing.expectEqual(@as(usize, 1), H.bucketOf(11));
    try testing.expectEqual(@as(usize, 2), H.bucketOf(30));
    try testing.expectEqual(@as(usize, 3), H.bucketOf(31));
    try testing.expectEqual(@as(usize, 3), H.bucketOf(std.math.maxInt(u64)));
}

test "sixteen buckets work, and so does one" {
    const Wide = Histogram(void, .{ .buckets = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } });
    try testing.expectEqual(@as(usize, 16), Wide.bucketOf(99));
    try testing.expectEqual(@as(usize, 7), Wide.bucketOf(8));
    const One = Histogram(void, .{ .buckets = .{100} });
    try testing.expectEqual(@as(usize, 0), One.bucketOf(100));
    try testing.expectEqual(@as(usize, 1), One.bucketOf(101));
}

test "every metric sits on a line of its own, and a row on one of its own" {
    try testing.expect(@alignOf(Counter(Status)) >= 64);
    try testing.expect(@alignOf(Gauge(void)) >= 64);
    const H = Histogram(Status, .{ .buckets = .{ 1, 2, 3 } });
    try testing.expect(@alignOf(H) >= 64);
    try testing.expectEqual(@as(usize, 0), @sizeOf(H.Row) % 64);
    try testing.expectEqual(@as(usize, 3 * @sizeOf(H.Row)), @sizeOf(H));
}

test "two threads counting the same cell lose nothing" {
    var c: Counter(Status) = .{};
    var h: Histogram(void, .{ .buckets = .{ 10, 100 } }) = .{};
    const work = struct {
        fn run(counter: *Counter(Status), hist: *@TypeOf(h)) void {
            for (0..20_000) |i| {
                counter.inc(.paid);
                hist.observe(i % 200);
            }
        }
    }.run;
    const a = try std.Thread.spawn(.{}, work, .{ &c, &h });
    const b = try std.Thread.spawn(.{}, work, .{ &c, &h });
    a.join();
    b.join();
    try testing.expectEqual(@as(u64, 40_000), c.get(.paid));
    try testing.expectEqual(@as(u64, 40_000), h.countOf(0));
}

const Shop = struct {
    orders_total: Counter(Status) = .{},
    checkout_seconds: Histogram(void, .{ .buckets = .{ 5_000, 50_000 } }) = .{},
    queue_depth: Gauge(void) = .{},
    not_a_metric: u32 = 0,

    pub const nilo_help = .{ .orders_total = "Orders, by \"status\"\nnewest first." };
};

test "a service's metric fields become families, in field order, with their help" {
    const set = comptime setOf(Shop).?;
    try testing.expectEqual(@as(usize, 3), set.families.len);
    try testing.expectEqualStrings("orders_total", set.families[0].name);
    try testing.expectEqual(Kind.counter, set.families[0].kind);
    try testing.expectEqualStrings("status", set.families[0].keys[0]);
    try testing.expectEqualStrings("Orders, by \"status\"\nnewest first.", set.families[0].help);
    try testing.expectEqual(Kind.histogram, set.families[1].kind);
    try testing.expectEqual(@as(usize, 5), set.families[1].series);
    try testing.expectEqualStrings("", set.families[2].help);

    var shop: Shop = .{};
    shop.orders_total.inc(.paid);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try set.families[0].samples(&shop, &out.writer, "Shop");
    try testing.expect(std.mem.indexOf(u8, out.written(), "orders_total{service=\"Shop\",status=\"paid\"} 1\n") != null);
}

test "a service with no metric in it has no set at all" {
    const Plain = struct { n: u32 = 0 };
    try testing.expect(comptime setOf(Plain) == null);
    try testing.expect(comptime setOf(u32) == null);
}

/// What a module that cannot import this file declares.
const Cache = struct {
    hits: u64 = 0,
    memo: bool = true,
    pub const nilo_metrics = .{
        .{ "nilo_cache_hits_total", .counter, "Lookups that found a value.", hitsOf },
        .{ "nilo_cache_bytes", .gauge, "Bytes held.", bytesOf },
    };
    fn hitsOf(self: *const Cache) u64 {
        return self.hits;
    }
    fn bytesOf(self: *const Cache) ?u64 {
        return if (self.memo) 4096 else null;
    }
};

test "a nilo_metrics table becomes families too, and a reader may say it has nothing" {
    const set = comptime setOf(Cache).?;
    try testing.expectEqual(@as(usize, 2), set.families.len);
    try testing.expectEqualStrings("nilo_cache_hits_total", set.families[0].name);
    try testing.expectEqual(Kind.gauge, set.families[1].kind);

    var c: Cache = .{ .hits = 3 };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try set.families[0].samples(&c, &out.writer, "Store");
    try set.families[1].samples(&c, &out.writer, "Store");
    try testing.expectEqualStrings("nilo_cache_hits_total{service=\"Store\"} 3\nnilo_cache_bytes{service=\"Store\"} 4096\n", out.written());

    c.memo = false;
    out.clearRetainingCapacity();
    try set.families[1].samples(&c, &out.writer, "Store");
    try testing.expectEqualStrings("", out.written());
}

test "two families agree on a shape when kind and label keys match" {
    const set = comptime setOf(Shop).?;
    try testing.expect(set.families[0].sameShape(set.families[0]));
    try testing.expect(!set.families[0].sameShape(set.families[2]));
    try testing.expect(!set.families[2].sameShape(set.families[1]));
}
