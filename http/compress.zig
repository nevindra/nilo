//! Response compression: a body gzipped per request, on a compressor
//! borrowed from a pool sized to the thread count (ADR 211).
//!
//! ```zig
//! try app.compress(.{});                                   // gzip, bodies of 1 KB and up
//! try app.compress(.{ .level = .best, .min_bytes = 512, .max_bytes = 4 << 20 });
//! ```
//!
//! Once it is on, every `send` (and so every `sendJson`, `sendText` and
//! typed handler returning a value) gzips a body that is text, is at least
//! `min_bytes` long, and is going to a client whose `Accept-Encoding` says
//! gzip is welcome. The answer carries `Content-Encoding: gzip` and `Vary:
//! Accept-Encoding`, and its `Content-Length` is the compressed size. A
//! client that said nothing, or said `gzip;q=0`, gets the body as it is and
//! no `Content-Encoding` at all. A static file is not this: it was gzipped
//! once when the App was built (ADR 009). A stream and an event stream are
//! not this either, and deliberately; the ADR says why.
//!
//! **Where the compressor lives is the whole design, and three places were
//! rejected before this one.** A deflate compressor is `~224 KB` of lookup
//! table and token buffer plus a 64 KB window. One per *connection* would
//! multiply the 4,669 bytes an idle connection holds by sixty. One per
//! *request*, allocated, breaks the budget of one allocation a request
//! (ADR 017). And one on the *handler's stack*, the obvious shape and
//! the one `Compress.init` writes, is the worst of the three: the standard
//! library builds its token buffer as a 96 KB temporary before copying it
//! into place, and a fiber keeps its stack at the high-water mark it ever
//! reached, for the life of the connection (ADR 062). Measured from the
//! assembly: **99,048 bytes of stack** for one call to `Compress.init`,
//! which on four thousand keep-alive connections is four hundred megabytes
//! of resident memory for a feature that was meant to save bandwidth.
//!
//! So the compressors sit in a pool on the heap, one per executor thread,
//! taken at `resolveChains` and never touched by a fiber's stack. A request
//! borrows one, gzips its whole body into the request arena, hands the
//! compressor back, and *then* writes the answer. **The borrow spans no
//! wait**: nothing between taking a slot and returning it can park the
//! fiber, so with one slot per thread the pool is never empty on a server.
//! The fallback for an empty pool exists for an App driven with no
//! server under it, and it is the uncompressed body, not an error.
//!
//! Handing a compressor back does not make it reusable: `finish` puts its
//! writer into the failing state, and the standard library's only way out
//! is `init`, which is the 99 KB temporary above. `reset` below does what
//! `init` does, field by field, into memory that is already there:
//! 40 bytes of stack, measured the same way. It depends on the fields
//! `std.compress.flate.Compress` has in the Zig this toolkit is pinned to,
//! and `test "a compressor reset in place produces what a fresh one does"`
//! holds it there byte for byte.
//!
//! **That compressor is the standard library's unless the build asked for
//! libdeflate** with `.libdeflate = true` (ADR 248). Everything above holds
//! for both; what changes is what a slot is. libdeflate's compressor is one
//! allocation that keeps nothing between bodies, so it needs no `reset`,
//! gzips in a quarter to a third of the time, and writes 2.6 KB of stack
//! where the standard library's path writes 7.5 KB. Its compressors live in
//! one mapping of their own, kept off transparent huge pages, because a
//! compressor allocates 668 KB and a small body touches a third of it.
//! `Pool` is `PoolOf(backend)`, and a program only ever analyses the
//! backend it chose.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("nilo_build");
const flate = std.compress.flate;
const http1 = @import("http1.zig");
const bulkhead = @import("bulkhead.zig");

pub const Options = struct {
    /// Bodies shorter than this go out as they are. Compressing a hundred
    /// bytes makes them longer, and the round trip is what a small answer
    /// costs; one kilobyte is where gzip starts paying for its header.
    min_bytes: usize = 1024,
    /// How hard to look for a match. `.default` is zlib's level 6 and what
    /// nginx and Go ship; `.fastest` is level 1 and roughly twice as quick
    /// for bodies a fifth larger; `.best` is level 9 and rarely worth its
    /// time on a body under a megabyte. In a libdeflate build the three are
    /// its levels 1, 6 and 7 (`Level.libdeflateLevel` says why not 9).
    level: Level = .default,
    /// Bodies longer than this go out as they are. **What it bounds is how
    /// long one answer holds its thread**: deflate runs whole, inside `send`,
    /// with no point where the fiber parks, so every other fiber on that
    /// executor thread waits while it does. Measured at about 150 MB/s on
    /// `.default` and 240 MB/s on `.fastest` (`zig build bench-compress`,
    /// `bench/result/http.md`), so a megabyte holds the thread for about 7 ms
    /// and a 20 MB export for 130 ms, half of what `block_warning_ms` calls a
    /// blocked handler. A libdeflate build is about 2.4 ms a megabyte at
    /// `.default` and keeps the same default (ADR 248). A megabyte is where
    /// an answer stops being a page of JSON and starts being a download, and
    /// a download is better compressed ahead of time or not at all. Zero
    /// takes the limit off (ADR 211).
    max_bytes: usize = 1024 * 1024,
};

pub const Level = enum {
    fastest,
    default,
    best,

    fn flateOptions(self: Level) flate.Compress.Options {
        return switch (self) {
            .fastest => .fastest,
            .default => .default,
            .best => .best,
        };
    }

    /// libdeflate's level for each name (ADR 248). `.best` is 7 and not 9:
    /// on a megabyte libdeflate 9 takes 17.7 ms, longer than the standard
    /// library's own `.best`, and 7 is smaller than that in 4.2 ms, which
    /// keeps `max_bytes` meaning what it was sized to mean.
    pub fn libdeflateLevel(self: Level) c_int {
        return switch (self) {
            .fastest => 1,
            .default => 6,
            .best => 7,
        };
    }
};

/// Which deflate this build gzips with (ADR 248). The standard library's
/// unless the build passed `.libdeflate = true`, and the same answer for
/// a response and for a static file gzipped at load.
pub const Backend = enum { std, libdeflate };

pub const backend: Backend = if (build_options.libdeflate) .libdeflate else .std;

/// Whether libdeflate is in this program at all. True in a build that
/// chose it, and in this repository's own http test root whichever was
/// chosen, so the tests below hold both backends in one run.
pub const libdeflate_linked = build_options.libdeflate_linked;

const libdeflate = if (libdeflate_linked) @import("libdeflate.zig") else struct {};

/// The compressors, one per executor thread, for this build's backend.
pub const Pool = PoolOf(backend);

/// A pool of compressors for one backend. Generic so that a test can hold
/// either; a program only ever names `Pool`, and the other backend's code
/// is never analysed, which is what takes `std.flate`'s compressor out of a
/// libdeflate build (ADR 248).
pub fn PoolOf(comptime which: Backend) type {
    if (which == .libdeflate and !libdeflate_linked)
        @compileError("libdeflate is not linked into this build: pass `.libdeflate = true` to the nilo dependency (ADR 248)");
    return struct {
        const Self = @This();

        /// `std.atomic.cache_line` on a line of its own: the flag is written
        /// by whoever borrows or gives back, and the next flag is somebody
        /// else's.
        const Flag = struct {
            free: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(true),
        };

        slots: []Slot,
        /// Whether each slot is free, one flag a slot and each on a cache line
        /// of its own. A word of bits would be one borrow and one give-back
        /// from every executor on the same line, and `borrow` is a
        /// `cmpxchg` on a flag, so nothing waits (ADR 211).
        free: []Flag,
        options: Options,
        /// libdeflate's compressors, all in one mapping kept off huge
        /// pages; nothing for the standard library's, which live in `slots`.
        mapping: Mapping,

        const Mapping = if (which == .libdeflate) []align(std.heap.page_size_min) u8 else void;

        /// One compressor. For the standard library it and its window,
        /// `~288 KB` on the heap and never on a stack; for libdeflate a
        /// pointer into `mapping`.
        pub const Slot = if (which == .libdeflate) struct {
            compressor: *libdeflate.Compressor,
        } else struct {
            state: flate.Compress,
            window: [flate.max_window_len]u8,
            /// The vtable `Compress.init` gave the writer, kept because `finish`
            /// replaces it with the failing one and `reset` has to put it back.
            vtable: *const std.Io.Writer.VTable,
        };

        /// `count` compressors, built here, on the thread that is building
        /// the App, whose stack is the process's and not a connection's.
        pub fn init(gpa: std.mem.Allocator, count: usize, options: Options) !Self {
            const slots = try gpa.alloc(Slot, count);
            errdefer gpa.free(slots);
            const free = try gpa.alloc(Flag, count);
            errdefer gpa.free(free);
            for (free) |*flag| flag.* = .{};

            const mapping: Mapping = switch (which) {
                .std => {
                    // `init` writes the gzip header into its output and asserts
                    // there is room for it. This output is thrown away.
                    var scratch: [16]u8 = undefined;
                    for (slots) |*slot| {
                        var discard: std.Io.Writer = .fixed(&scratch);
                        slot.state = try flate.Compress.init(&discard, &slot.window, .gzip, options.level.flateOptions());
                        slot.vtable = slot.state.writer.vtable;
                    }
                },
                .libdeflate => try placeCompressors(slots, options.level.libdeflateLevel()),
            };
            return .{
                .slots = slots,
                .free = free,
                .options = options,
                .mapping = mapping,
            };
        }

        /// Every compressor in one mapping of its own, each starting on a
        /// page, so no two threads' compressors share one.
        ///
        /// **The mapping is kept off transparent huge pages**, and that is
        /// the whole memory argument for libdeflate. A compressor allocates
        /// 668 KB and a small body writes 229 KB of it; the rest is never
        /// touched and never resident. Under THP `always`, which is a common
        /// default, one write into a 2 MB-aligned stretch of a large
        /// anonymous mapping makes the whole 2 MB resident, and sixteen
        /// compressors in one allocation become 10.7 MB rather than 3.7.
        /// The advice has to come before the first write, so it is given
        /// before any compressor is built. Linux only: the other systems nilo
        /// runs on have no transparent huge pages to refuse. A refusal is
        /// ignored, because a kernel that refuses it, built without them, has
        /// none to give.
        fn placeCompressors(slots: []Slot, level: c_int) !Mapping {
            const page = std.heap.page_size_min;
            const stride = std.mem.alignForward(usize, libdeflate.footprint(level), page);
            const mapping = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(page), @max(stride * slots.len, page));
            errdefer std.heap.page_allocator.free(mapping);
            if (builtin.os.tag == .linux) {
                std.posix.madvise(mapping.ptr, mapping.len, std.posix.MADV.NOHUGEPAGE) catch {};
            }
            for (slots, 0..) |*slot, i| {
                slot.compressor = libdeflate.placeAt(level, mapping[i * stride ..][0..stride]) orelse return error.OutOfMemory;
            }
            return mapping;
        }

        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            if (which == .libdeflate) std.heap.page_allocator.free(self.mapping);
            gpa.free(self.free);
            gpa.free(self.slots);
            self.* = undefined;
        }

        pub fn len(self: *const Self) usize {
            return self.slots.len;
        }

        /// A free compressor, or null when every one is out. Never waits.
        ///
        /// **A caller that says who it is gets its own slot back.** `hint` is
        /// the executor thread's index, and the scan starts at the slot with
        /// that index and wraps, so on a server with a slot a thread the
        /// thread that gzipped last time gzips on the same compressor, whose
        /// 229 KB of tables are still in its core's caches. Starting every scan
        /// at slot 0, as this did, handed slot 0 to whichever core got there
        /// first, and the compressor's working set crossed between cores on
        /// nearly every request (ADR 211). Without a hint (an App driven with
        /// no server, a thread the engine did not start) the scan starts at 0.
        fn borrow(self: *const Self, hint: ?usize) ?*Slot {
            const n = self.slots.len;
            if (n == 0) return null;
            const start = if (hint) |h| h % n else 0;
            for (0..n) |step| {
                const i = if (start + step >= n) start + step - n else start + step;
                const flag = &self.free[i].free;
                // A read first: a taken flag is somebody else's line to write.
                if (!flag.load(.monotonic)) continue;
                if (flag.cmpxchgStrong(true, false, .acquire, .monotonic) == null) return &self.slots[i];
            }
            return null;
        }

        fn giveBack(self: *const Self, slot: *Slot) void {
            const i = (@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot);
            self.free[i].free.store(true, .release);
        }

        /// Whether an answer of this shape is one the pool would compress at
        /// all, before anybody reads what the client said: long enough, a
        /// status that carries a body, a type that is text. The cheap half of
        /// the decision, in the order cheapest first; `Ctx.send` asks it before
        /// reading `Accept-Encoding` off the head.
        pub fn eligible(self: *const Self, status: u16, content_type: []const u8, body_len: usize) bool {
            if (body_len < self.options.min_bytes) return false;
            if (self.options.max_bytes != 0 and body_len > self.options.max_bytes) return false;
            if (http1.bodyless(status)) return false;
            // A range is an offset into one representation, and `Content-Range`
            // names the plain bytes; the unsatisfiable answer carries the plain
            // length (ADR 211).
            if (status == 206 or status == 416) return false;
            return compressible(content_type);
        }

        /// Gzip `body` into `arena`, or null when it is not worth it: no
        /// compressor free, or the result no smaller than what went in.
        ///
        /// Half the input plus a little is where text lands, so the output is
        /// usually one arena allocation that is never grown; when it is grown
        /// the arena resizes its last allocation in place. libdeflate starts
        /// from the same half (`libdeflate.gzip` says how it goes past it).
        pub fn gzip(self: *const Self, arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
            return self.gzipAt(arena, body, bulkhead.executorIndex());
        }

        /// `gzip` for a caller that knows which executor thread it is on:
        /// the thread's own compressor if it is free, another if not. `gzip`
        /// asks the engine; this is the form a test or a benchmark that
        /// starts its own threads uses.
        pub fn gzipAt(self: *const Self, arena: std.mem.Allocator, body: []const u8, hint: ?usize) ?[]const u8 {
            const slot = self.borrow(hint) orelse return null;
            defer self.giveBack(slot);

            if (which == .libdeflate) {
                const squeezed = (libdeflate.gzip(slot.compressor, arena, body) catch return null) orelse return null;
                return squeezed.bytes();
            }
            var out = std.Io.Writer.Allocating.initCapacity(arena, body.len / 2 + 64) catch return null;
            reset(slot, &out.writer, self.options.level.flateOptions()) catch return null;
            slot.state.writer.writeAll(body) catch return null;
            slot.state.finish() catch return null;

            const squeezed = out.written();
            if (squeezed.len >= body.len) return null;
            return squeezed;
        }
    };
}

/// What `flate.Compress.init` does, into a compressor that is already there.
///
/// Field for field the same as `init` in the pinned standard library, with
/// one difference: the writer's vtable is the one `init` gave this slot
/// rather than a fresh literal, because the functions in it are private to
/// `Compress.zig`. `chain` is left as it is, as `init` leaves it undefined.
fn reset(slot: *PoolOf(.std).Slot, output: *std.Io.Writer, opts: flate.Compress.Options) std.Io.Writer.Error!void {
    const c = &slot.state;
    try output.writeAll(flate.Container.gzip.header());
    c.writer = .{ .buffer = &slot.window, .vtable = slot.vtable, .end = 0 };
    c.history_len = 0;
    c.history_end_unhashed = false;
    c.bit_writer.output = output;
    c.bit_writer.buffered = 0;
    c.bit_writer.buffered_n = 0;
    c.buffered_tokens.pos = 0;
    c.buffered_tokens.n = 0;
    @memset(&c.buffered_tokens.lit_freqs, 0);
    @memset(&c.buffered_tokens.dist_freqs, 0);
    @memset(&c.lookup.head, .{ .value = std.math.maxInt(u15), .is_null = true });
    c.lookup.chain_pos = std.math.maxInt(u15);
    c.container = .gzip;
    c.opts = opts;
    c.hasher = .init(.gzip);
}

/// Gzip `bytes` once, outside any request, into memory from `gpa` that the
/// caller owns: what a static file is given at load (ADR 009). Null when
/// the result is not smaller. Through this build's backend, so a
/// libdeflate build does not keep the standard library's compressor for
/// this alone (ADR 248).
///
/// The standard library's path keeps its 64 KB window on the heap for the
/// length of the call; libdeflate's compressor is placed in an allocation
/// of its own and freed before returning. Either way nothing outlives the
/// call but the result, sized to fit.
pub fn gzipOnce(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!?[]const u8 {
    switch (backend) {
        .libdeflate => {
            const level = Level.default.libdeflateLevel();
            const memory = try gpa.alloc(u8, libdeflate.footprint(level));
            defer gpa.free(memory);
            const c = libdeflate.placeAt(level, memory) orelse return error.OutOfMemory;
            const squeezed = (try libdeflate.gzip(c, gpa, bytes)) orelse return null;
            // Held for the life of the set, so it gives back its slack.
            return try gpa.realloc(squeezed.allocation, squeezed.len);
        },
        .std => {
            // `Compress.init` asserts its output has somewhere to write, and an
            // `Allocating` starts with a buffer of nothing at all. Half the input
            // is roughly where text lands, so this is also the size that usually
            // means the output is never grown.
            var out: std.Io.Writer.Allocating = try .initCapacity(gpa, bytes.len / 2 + 64);
            errdefer out.deinit();

            const window = try gpa.alloc(u8, flate.max_window_len);
            defer gpa.free(window);

            var compressor = flate.Compress.init(&out.writer, window, .gzip, .default) catch return error.OutOfMemory;
            compressor.writer.writeAll(bytes) catch return error.OutOfMemory;
            compressor.finish() catch return error.OutOfMemory;

            // A file that does not shrink is a file served as it is. Keeping the
            // copy would cost memory to send more bytes than the original.
            if (out.written().len >= bytes.len) {
                out.deinit();
                return null;
            }
            return try out.toOwnedSlice();
        },
    }
}

/// Whether a `Cache-Control` value carries the `no-transform` directive,
/// which forbids a proxy and so an origin acting for one from changing the
/// body's coding (RFC 9111 section 5.2.2.6). A directive is a whole token:
/// `x-no-transform` is somebody else's.
pub fn forbidsTransform(cache_control: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, cache_control, ',');
    while (it.next()) |raw| {
        const directive = std.mem.trim(u8, raw, " \t");
        // `no-transform` takes no argument, but a stray `=` is not a reason
        // to compress what was asked to be left alone.
        const name = if (std.mem.indexOfScalar(u8, directive, '=')) |eq| directive[0..eq] else directive;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, name, " \t"), "no-transform")) return true;
    }
    return false;
}

/// Whether an `Accept-Encoding` header says gzip is welcome.
///
/// Not `indexOf("gzip")`, because `gzip;q=0` contains the word and means the
/// exact opposite: it is how a client that cannot decompress says so, and
/// answering it with a gzipped body is a broken page rather than a slow one.
/// `*` is honoured too, with an explicit `gzip` entry outranking it either
/// way, which is what RFC 9110 section 12.5.3 says to do.
pub fn acceptsGzip(header: ?[]const u8) bool {
    return quality(header orelse return false, "gzip") > 0;
}

/// A content coding a held or precompressed file can be answered in
/// (ADR 273). Identity is the file as it was read.
pub const Coding = enum { identity, gzip, br };

/// Which of the codings a file has the client prefers, by `q`.
///
/// Higher `q` wins, `br` wins a tie (a browser sending `gzip, deflate, br`
/// gave both the same weight and brotli is the smaller), and a coding at
/// `q=0`, or one the client did not name and no `*` covers, is never chosen:
/// `br;q=0` is how a client that cannot decode it says so. A client that sent
/// no header, or named neither coding the file has, gets the identity form
/// (RFC 9110 section 12.5.3). Pure and allocation-free, so the static path
/// calls it per request at no cost on the allocation budget.
pub fn negotiate(header: ?[]const u8, have_br: bool, have_gzip: bool) Coding {
    const value = header orelse return .identity;
    const q_br: u16 = if (have_br) quality(value, "br") else 0;
    const q_gzip: u16 = if (have_gzip) quality(value, "gzip") else 0;
    if (q_br == 0 and q_gzip == 0) return .identity;
    return if (q_br >= q_gzip) .br else .gzip;
}

/// The weight an `Accept-Encoding` value gives the coding `name`, in
/// thousandths: 0 for refused or not mentioned, 1000 for `q=1` or no `q`.
/// A named entry outranks `*` whichever comes first.
fn quality(value: []const u8, name: []const u8) u16 {
    var star: u16 = 0;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;

        const semi = std.mem.indexOfScalar(u8, entry, ';');
        const coding = std.mem.trimEnd(u8, entry[0 .. semi orelse entry.len], " \t");
        const weight: u16 = if (semi) |i| qualityOf(entry[i + 1 ..]) else 1000;

        if (std.ascii.eqlIgnoreCase(coding, name)) return weight;
        if (std.mem.eql(u8, coding, "*")) star = weight;
    }
    return star;
}

/// The `q` in the parameters after a `;`, in thousandths. A missing or
/// malformed one is read as 1000, "wanted": the cost of being wrong that way
/// is a coding the client asked for by listing it at all.
fn qualityOf(params: []const u8) u16 {
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |raw| {
        const param = std.mem.trim(u8, raw, " \t");
        if (param.len < 2) continue;
        if (param[0] != 'q' and param[0] != 'Q') continue;
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        if (std.mem.trim(u8, param[1..eq], " \t").len != 0) continue;

        return thousandths(std.mem.trim(u8, param[eq + 1 ..], " \t"));
    }
    return 1000;
}

/// A `qvalue` (RFC 9110 section 12.4.2) in thousandths: `0`, `0.` and
/// `0.xxx`, or `1` and `1.000`. Read by hand rather than through
/// `parseFloat`, which is 7 KB of machine code to compare three digits.
/// Anything else, a fourth digit or `1.5` or `zero`, is 1000.
fn thousandths(q: []const u8) u16 {
    if (q.len == 0 or (q[0] != '0' and q[0] != '1')) return 1000;
    const whole: u16 = q[0] - '0';
    if (q.len == 1) return whole * 1000;
    if (q[1] != '.' or q.len > 5) return 1000;
    var frac: u16 = 0;
    var scale: u16 = 100;
    for (q[2..]) |digit| {
        if (digit < '0' or digit > '9') return 1000;
        frac += (digit - '0') * scale;
        scale /= 10;
    }
    return if (whole == 1) 1000 else frac;
}

/// Whether a body of this type is worth gzipping.
///
/// An allowlist rather than a blocklist. Getting it wrong in the permissive
/// direction means spending the work on a JPEG to save nothing; in the
/// strict direction it means a CSS file goes out uncompressed, which is
/// merely the behaviour of every previous version. So the list names what
/// is known to be text.
pub fn compressible(content_type: []const u8) bool {
    // `text/anything` is text, including the ones nobody has thought of.
    if (std.mem.startsWith(u8, content_type, "text/")) return true;

    // A structured type ending in `+json` or `+xml` (`image/svg+xml`,
    // `application/manifest+json`) is text however it starts.
    const base = content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len];
    const trimmed = std.mem.trimEnd(u8, base, " ");
    if (std.mem.endsWith(u8, trimmed, "+json")) return true;
    if (std.mem.endsWith(u8, trimmed, "+xml")) return true;

    for ([_][]const u8{
        "application/json",
        "application/javascript",
        "application/xml",
        "application/wasm",
        "application/x-ndjson",
        "image/x-icon",
        "font/ttf",
        "font/otf",
    }) |known| {
        if (std.mem.eql(u8, trimmed, known)) return true;
    }
    return false;
}

// ---- tests ----

const testing = std.testing;

/// The bytes a client would read: `gzipped` inflated.
fn inflated(gpa: std.mem.Allocator, gzipped: []const u8) ![]u8 {
    var in = std.Io.Reader.fixed(gzipped);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&in, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try inflate.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

/// A JSON body comfortably over the default threshold, and repetitive enough
/// that gzip halves it several times over.
const long_json = "{\"items\":[" ++ (repeat("{\"id\":1,\"name\":\"Alpha Widget\",\"category\":\"electronics\",\"price\":328,\"quantity\":15,\"active\":true},", 40)) ++ "{}],\"count\":40}";

/// Every backend this test build has: both in this repository's own suite,
/// whose http test root links libdeflate whatever the flag says (ADR 248).
const backends: []const Backend = if (libdeflate_linked) &.{ .std, .libdeflate } else &.{.std};

test "a compressor reset in place produces what a fresh one does" {
    const gpa = testing.allocator;
    const body = long_json;

    var pool = try PoolOf(.std).init(gpa, 1, .{});
    defer pool.deinit(gpa);

    // Through the standard library's own `init`, as the reference. With
    // room to start in: `init` asserts its output has somewhere to write.
    var fresh_out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer fresh_out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var fresh = try flate.Compress.init(&fresh_out.writer, window, .gzip, .default);
    try fresh.writer.writeAll(body);
    try fresh.finish();

    // Through `reset`, twice, so the second use sees whatever the first left
    // behind, which is what every request after the first does.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const once = pool.gzip(arena.allocator(), body).?;
    const twice = pool.gzip(arena.allocator(), body).?;

    try testing.expectEqualSlices(u8, fresh_out.written(), once);
    try testing.expectEqualSlices(u8, fresh_out.written(), twice);

    const back = try inflated(gpa, twice);
    defer gpa.free(back);
    try testing.expectEqualStrings(body, back);
}

test "the pool hands out every slot once and takes each back" {
    const gpa = testing.allocator;
    inline for (backends) |which| {
        var pool = try PoolOf(which).init(gpa, 3, .{});
        defer pool.deinit(gpa);

        const a = pool.borrow(null).?;
        const b = pool.borrow(null).?;
        const c = pool.borrow(null).?;
        try testing.expect(a != b and b != c and a != c);
        try testing.expect(pool.borrow(null) == null);

        pool.giveBack(b);
        try testing.expect(pool.borrow(null).? == b);
        try testing.expect(pool.borrow(null) == null);

        pool.giveBack(a);
        pool.giveBack(b);
        pool.giveBack(c);
        var taken: usize = 0;
        while (pool.borrow(null)) |_| taken += 1;
        try testing.expectEqual(@as(usize, 3), taken);
    }
}

test "a thread asking with its own index gets its own slot back, and the next one when it is taken" {
    const gpa = testing.allocator;
    inline for (backends) |which| {
        var pool = try PoolOf(which).init(gpa, 4, .{});
        defer pool.deinit(gpa);

        // Its own, every time it asks and gives back.
        for (0..3) |_| {
            const mine = pool.borrow(2).?;
            try testing.expect(mine == &pool.slots[2]);
            pool.giveBack(mine);
        }

        // Taken: the scan goes on to the next index and wraps past the end.
        const held = pool.borrow(3).?;
        try testing.expect(held == &pool.slots[3]);
        const wrapped = pool.borrow(3).?;
        try testing.expect(wrapped == &pool.slots[0]);
        const next = pool.borrow(3).?;
        try testing.expect(next == &pool.slots[1]);

        // An index past the end is a remainder, not a crash, and it still
        // finds the one slot left before saying the pool is empty.
        const last = pool.borrow(1_000_003).?;
        try testing.expect(last == &pool.slots[2]);
        try testing.expect(pool.borrow(0) == null);
        try testing.expect(pool.borrow(null) == null);
    }
}

test "no slot is ever handed to two borrowers at once under contention" {
    const gpa = testing.allocator;
    // Eight threads on a pool of five, so some always find it empty and the
    // rest race for the same flags, half of them with a hint and half without.
    var pool = try PoolOf(.std).init(gpa, 5, .{ .level = .fastest });
    defer pool.deinit(gpa);

    const Shared = struct {
        pool: *PoolOf(.std),
        holders: [5]std.atomic.Value(u32) = @splat(.init(0)),
        violations: std.atomic.Value(u32) = .init(0),
        borrowed: std.atomic.Value(u32) = .init(0),

        fn run(self: *@This(), id: usize) void {
            for (0..20_000) |i| {
                const hint: ?usize = if (id % 2 == 0) id else null;
                const slot = self.pool.borrow(hint) orelse continue;
                const index = (@intFromPtr(slot) - @intFromPtr(self.pool.slots.ptr)) / @sizeOf(@TypeOf(slot.*));
                if (self.holders[index].fetchAdd(1, .acq_rel) != 0) _ = self.violations.fetchAdd(1, .monotonic);
                _ = self.borrowed.fetchAdd(1, .monotonic);
                if (i % 64 == 0) std.atomic.spinLoopHint();
                _ = self.holders[index].fetchSub(1, .acq_rel);
                self.pool.giveBack(slot);
            }
        }
    };
    var shared: Shared = .{ .pool = &pool };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, Shared.run, .{ &shared, id });
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u32, 0), shared.violations.load(.monotonic));
    try testing.expect(shared.borrowed.load(.monotonic) > 0);
    // And everything came back.
    var taken: usize = 0;
    while (pool.borrow(null)) |_| taken += 1;
    try testing.expectEqual(@as(usize, 5), taken);
}

test "off an executor the pool still gzips, and a hint that does not fit still finds a slot" {
    const gpa = testing.allocator;
    inline for (backends) |which| {
        var pool = try PoolOf(which).init(gpa, 2, .{});
        defer pool.deinit(gpa);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        // No engine under this test, so `gzip` has no index and scans from 0.
        try testing.expect(bulkhead.executorIndex() == null);
        const plain = pool.gzip(arena.allocator(), long_json).?;
        const hinted = pool.gzipAt(arena.allocator(), long_json, 99).?;
        try testing.expectEqualSlices(u8, plain, hinted);
        const back = try inflated(gpa, hinted);
        defer gpa.free(back);
        try testing.expectEqualStrings(long_json, back);

        // Every slot back afterwards, whichever was used.
        try testing.expect(pool.borrow(null) != null);
        try testing.expect(pool.borrow(null) != null);
        try testing.expect(pool.borrow(null) == null);
    }
}

test "a pool with every compressor out sends the body as it is" {
    const gpa = testing.allocator;
    inline for (backends) |which| {
        var pool = try PoolOf(which).init(gpa, 1, .{});
        defer pool.deinit(gpa);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        const held = pool.borrow(null).?;
        try testing.expect(pool.gzip(arena.allocator(), long_json) == null);
        pool.giveBack(held);
        try testing.expect(pool.gzip(arena.allocator(), long_json) != null);
    }
}

test "a body that does not shrink goes out as it is" {
    const gpa = testing.allocator;
    inline for (backends) |which| {
        var pool = try PoolOf(which).init(gpa, 1, .{});
        defer pool.deinit(gpa);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        // Random bytes have nothing for deflate to find, and the gzip framing
        // makes the result longer than the input.
        var noise: [2048]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(7);
        prng.random().bytes(&noise);
        try testing.expect(pool.gzip(arena.allocator(), &noise) == null);
    }
}

test "every level of every backend gzips what the standard library inflates back, twice over on one slot" {
    const gpa = testing.allocator;
    inline for (backends) |which| {
        for ([_]Level{ .fastest, .default, .best }) |level| {
            var pool = try PoolOf(which).init(gpa, 1, .{ .level = level });
            defer pool.deinit(gpa);
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();

            // A second body after the first, so what the first left in the
            // compressor is what the second meets.
            for ([_][]const u8{ long_json, long_json[0 .. long_json.len / 2] }) |body| {
                const squeezed = pool.gzip(arena.allocator(), body).?;
                try testing.expect(squeezed.len < body.len / 2);
                const back = try inflated(gpa, squeezed);
                defer gpa.free(back);
                try testing.expectEqualStrings(body, back);
            }
        }
    }
}

test "a body gzip shrinks by less than half still goes out gzipped, in either backend" {
    const gpa = testing.allocator;
    // Text in a 32-letter alphabet, drawn at random: five bits a byte, so
    // gzip lands near 63% and past the half both backends start from, which
    // is the path where libdeflate has to try again with more room.
    var text: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    const letters = "abcdefghijklmnopqrstuvwxyz234567";
    for (&text) |*ch| ch.* = letters[prng.random().uintLessThan(usize, letters.len)];

    inline for (backends) |which| {
        var pool = try PoolOf(which).init(gpa, 1, .{});
        defer pool.deinit(gpa);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        const squeezed = pool.gzip(arena.allocator(), &text).?;
        try testing.expect(squeezed.len > text.len / 2 + 64);
        try testing.expect(squeezed.len < text.len);
        const back = try inflated(gpa, squeezed);
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, &text, back);
    }
}

test "libdeflate hands back the whole allocation it wrote into, on either side of half" {
    if (!libdeflate_linked) return error.SkipZigTest;
    const gpa = testing.allocator;
    const level = Level.default.libdeflateLevel();
    const memory = try gpa.alloc(u8, libdeflate.footprint(level));
    defer gpa.free(memory);
    const c = libdeflate.placeAt(level, memory).?;

    // The testing allocator fails the test on a free of the wrong length
    // and on anything left behind, so freeing what came back is the check.
    var text: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(13);
    for (&text) |*ch| ch.* = "abcdefghijklmnopqrstuvwxyz234567"[prng.random().uintLessThan(usize, 32)];
    for ([_][]const u8{ long_json, &text }) |body| {
        const squeezed = (try libdeflate.gzip(c, gpa, body)).?;
        defer gpa.free(squeezed.allocation);
        const back = try inflated(gpa, squeezed.bytes());
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, body, back);
    }
    var noise: [2048]u8 = undefined;
    prng.random().bytes(&noise);
    try testing.expect((try libdeflate.gzip(c, gpa, &noise)) == null);
}

test "libdeflate's compressors are a page apart in one mapping that is kept off huge pages" {
    if (!libdeflate_linked) return error.SkipZigTest;
    const gpa = testing.allocator;
    var pool = try PoolOf(.libdeflate).init(gpa, 4, .{});
    defer pool.deinit(gpa);

    const page = std.heap.page_size_min;
    const start = @intFromPtr(pool.mapping.ptr);
    var pages: [4]usize = undefined;
    for (pool.slots, &pages) |slot, *p| {
        const at = @intFromPtr(slot.compressor);
        try testing.expect(at >= start and at < start + pool.mapping.len);
        p.* = (at - start) / page;
    }
    for (pages[1..], pages[0 .. pages.len - 1]) |later, earlier| try testing.expect(later > earlier);

    // The kernel's own word for it: the area holding the mapping carries
    // `nh`, "no huge pages", in its VmFlags. Asked only of a kernel that
    // takes the advice: one built without transparent huge pages answers
    // `EINVAL`, and so does qemu's user-mode emulation, and either way there
    // is nothing for the pool to refuse.
    if (builtin.os.tag != .linux) return;
    {
        const probe = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(page), page);
        defer std.heap.page_allocator.free(probe);
        std.posix.madvise(probe.ptr, probe.len, std.posix.MADV.NOHUGEPAGE) catch return error.SkipZigTest;
    }
    // Read to its end with a streaming reader: a file in /proc reports a
    // size of 0, and a positional read believes it.
    const file = try std.Io.Dir.cwd().openFile(testing.io, "/proc/self/smaps", .{});
    defer file.close(testing.io);
    var buf: [4096]u8 = undefined;
    var reader = file.readerStreaming(testing.io, &buf);
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    _ = try reader.interface.streamRemaining(&text.writer);
    const smaps = text.written();
    var lines = std.mem.splitScalar(u8, smaps, '\n');
    var inside = false;
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, '-')) |dash| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            if (dash < space) {
                const from = std.fmt.parseInt(usize, line[0..dash], 16) catch continue;
                const to = std.fmt.parseInt(usize, line[dash + 1 .. space], 16) catch continue;
                inside = start >= from and start < to;
                continue;
            }
        }
        if (inside and std.mem.startsWith(u8, line, "VmFlags:")) {
            try testing.expect(std.mem.indexOf(u8, line, " nh") != null);
            return;
        }
    }
    return error.TestMappingNotFound;
}

// Below the first test block on purpose: a file outside the App's core may
// name it only from its tests (see `http_core` in build.zig).
const App = @import("app.zig").App;
const Ctx = @import("ctx.zig").Ctx;
const nilo_testing = @import("testing.zig");

fn sendLongJson(c: *Ctx) anyerror!void {
    try c.send(200, "application/json", long_json);
}

fn sendShortJson(c: *Ctx) anyerror!void {
    try c.send(200, "application/json", "{\"ok\":true}");
}

fn sendLongPng(c: *Ctx) anyerror!void {
    try c.send(200, "image/png", long_json);
}

fn sendOwnGzip(c: *Ctx) anyerror!void {
    try c.setStaticHeader("Content-Encoding", "gzip");
    try c.send(200, "application/json", long_json);
}

test "a JSON answer over the threshold goes out gzipped to a client that takes it" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/items", sendLongJson);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    const answer = try client.send(&app, "GET /items HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip, br\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("gzip", answer.header("Content-Encoding").?);
    try testing.expectEqualStrings("Accept-Encoding", answer.header("Vary").?);
    try testing.expectEqualStrings("application/json", answer.header("Content-Type").?);
    try testing.expect(answer.body.len < long_json.len / 4);

    // The length on the wire is the compressed one, and what it frames
    // inflates to exactly what the handler sent.
    var length_buf: [16]u8 = undefined;
    const length = try std.fmt.bufPrint(&length_buf, "{d}", .{answer.body.len});
    try testing.expectEqualStrings(length, answer.header("Content-Length").?);
    const back = try inflated(gpa, answer.body);
    defer gpa.free(back);
    try testing.expectEqualStrings(long_json, back);
}

test "a client that did not ask for gzip gets the body as it is and no Content-Encoding" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/items", sendLongJson);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    // No header at all: what wrk sends, and what the benchmark arena's
    // rule for this profile names: "the server must not set
    // Content-Encoding".
    const silent = try client.get(&app, "/items");
    try testing.expectEqual(@as(u16, 200), silent.status);
    try testing.expect(silent.header("Content-Encoding") == null);
    try testing.expectEqualStrings(long_json, silent.body);
    // Still `Vary`: this answer would have differed for a client that asked.
    try testing.expectEqualStrings("Accept-Encoding", silent.header("Vary").?);

    // Said no in the one way that contains the word.
    const refused = try client.send(&app, "GET /items HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip;q=0, br\r\n\r\n");
    try testing.expect(refused.header("Content-Encoding") == null);
    try testing.expectEqualStrings(long_json, refused.body);
}

test "a body under min_bytes, a type that is not text, and a body already encoded are left alone" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/short", sendShortJson);
    try app.get("/png", sendLongPng);
    try app.get("/own", sendOwnGzip);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try client.setHeader("Accept-Encoding", "gzip");

    const short = try client.get(&app, "/short");
    try testing.expect(short.header("Content-Encoding") == null);
    // Under the threshold there is one representation, so nothing varies.
    try testing.expect(short.header("Vary") == null);
    try testing.expectEqualStrings("{\"ok\":true}", short.body);

    const png = try client.get(&app, "/png");
    try testing.expect(png.header("Content-Encoding") == null);
    try testing.expect(png.header("Vary") == null);
    try testing.expectEqualStrings(long_json, png.body);

    // The handler's own header stands, and the bytes are the handler's.
    const own = try client.get(&app, "/own");
    try testing.expectEqualStrings("gzip", own.header("Content-Encoding").?);
    try testing.expectEqualStrings(long_json, own.body);
}

test "the threshold and the level are the caller's" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{ .min_bytes = 8, .level = .fastest });
    try app.get("/short", sendShortJson);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try client.setHeader("Accept-Encoding", "gzip");

    // Eleven bytes of JSON do not shrink under gzip's own 18 bytes of
    // framing, so even asked for at 8 it goes out as it is, with `Vary`
    // because it was eligible.
    const short = try client.get(&app, "/short");
    try testing.expect(short.header("Content-Encoding") == null);
    try testing.expectEqualStrings("Accept-Encoding", short.header("Vary").?);
    try testing.expectEqualStrings("{\"ok\":true}", short.body);
}

test "a HEAD carries the length the GET would have" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/items", sendLongJson);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    const got = try client.send(&app, "GET /items HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    const asked = try client.send(&app, "HEAD /items HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), asked.status);
    try testing.expectEqualStrings("gzip", asked.header("Content-Encoding").?);
    try testing.expectEqualStrings(got.header("Content-Length").?, asked.header("Content-Length").?);
    try testing.expectEqualStrings("", asked.body);
}

test "compression is switched on once" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.compress(.{});
    try testing.expectError(error.CompressionAlreadyEnabled, app.compress(.{ .level = .best }));
}

test "Accept-Encoding is read, not searched for the word gzip" {
    // The plain cases.
    try testing.expect(acceptsGzip("gzip"));
    try testing.expect(acceptsGzip("gzip, deflate, br"));
    try testing.expect(acceptsGzip("deflate, gzip"));
    try testing.expect(acceptsGzip("GZIP"));
    try testing.expect(acceptsGzip("gzip;q=1.0"));
    try testing.expect(acceptsGzip("gzip ; q=0.5"));

    // `q=0` is how a client says it cannot, and it contains the word.
    try testing.expect(!acceptsGzip("gzip;q=0"));
    try testing.expect(!acceptsGzip("gzip;q=0.0"));
    try testing.expect(!acceptsGzip("gzip;q=0.000"));
    try testing.expect(!acceptsGzip("gzip;q=0."));
    try testing.expect(!acceptsGzip("deflate, gzip;q=0"));

    // Not zero, including the ones that start with one.
    try testing.expect(acceptsGzip("gzip;q=0.001"));
    try testing.expect(acceptsGzip("gzip;q=0.5"));
    try testing.expect(acceptsGzip("gzip;q=1"));
    try testing.expect(acceptsGzip("gzip;q=00"));
    try testing.expect(acceptsGzip("gzip;q="));
    try testing.expect(acceptsGzip("gzip;q=zero"));

    // A wildcard, and a named entry outranking it either way.
    try testing.expect(acceptsGzip("*"));
    try testing.expect(!acceptsGzip("*;q=0"));
    try testing.expect(!acceptsGzip("*, gzip;q=0"));
    try testing.expect(acceptsGzip("*;q=0, gzip"));

    // Nothing, and things that are not gzip.
    try testing.expect(!acceptsGzip(null));
    try testing.expect(!acceptsGzip(""));
    try testing.expect(!acceptsGzip("identity"));
    try testing.expect(!acceptsGzip("deflate, br"));

    // Names that contain it without being it.
    try testing.expect(!acceptsGzip("gzip-x"));
    try testing.expect(!acceptsGzip("x-gzip"));
}

test "negotiating a coding takes the client's highest q, brotli on a tie, and never a refused one" {
    const both = struct {
        fn pick(h: ?[]const u8) Coding {
            return negotiate(h, true, true);
        }
    }.pick;
    try testing.expectEqual(Coding.br, both("gzip, deflate, br"));
    try testing.expectEqual(Coding.br, both("br, gzip"));
    try testing.expectEqual(Coding.gzip, both("gzip, deflate"));
    try testing.expectEqual(Coding.gzip, both("br;q=0.5, gzip;q=0.9"));
    try testing.expectEqual(Coding.br, both("br;q=0.9, gzip;q=0.5"));
    try testing.expectEqual(Coding.gzip, both("br;q=0, gzip"));
    try testing.expectEqual(Coding.gzip, both("gzip, br;q=0.000"));
    try testing.expectEqual(Coding.identity, both("br;q=0, gzip;q=0"));
    try testing.expectEqual(Coding.identity, both("identity"));
    try testing.expectEqual(Coding.identity, both(null));
    try testing.expectEqual(Coding.br, both("*"));
    try testing.expectEqual(Coding.gzip, both("*, br;q=0"));
    try testing.expectEqual(Coding.identity, both("*;q=0"));
    // Only what the file has can be chosen.
    try testing.expectEqual(Coding.gzip, negotiate("br, gzip", false, true));
    try testing.expectEqual(Coding.br, negotiate("br, gzip", true, false));
    try testing.expectEqual(Coding.identity, negotiate("br", false, true));
}

test "the types worth gzipping are named, and the rest are not" {
    try testing.expect(compressible("text/html"));
    try testing.expect(compressible("text/plain; charset=utf-8"));
    try testing.expect(compressible("application/json"));
    try testing.expect(compressible("application/json; charset=utf-8"));
    try testing.expect(compressible("image/svg+xml"));
    try testing.expect(compressible("application/manifest+json"));
    try testing.expect(compressible("application/javascript"));
    try testing.expect(!compressible("image/png"));
    try testing.expect(!compressible("application/octet-stream"));
    try testing.expect(!compressible("font/woff2"));
    try testing.expect(!compressible("video/mp4"));
}

fn sendPartial(c: *Ctx) anyerror!void {
    try c.setStaticHeader("Content-Range", "bytes 0-99/1000");
    try c.send(206, "application/json", long_json);
}

fn sendUnsatisfiable(c: *Ctx) anyerror!void {
    try c.setStaticHeader("Content-Range", "bytes */1000");
    try c.send(416, "application/json", long_json);
}

fn sendWithContentRange(c: *Ctx) anyerror!void {
    try c.setStaticHeader("Content-Range", "bytes 0-99/1000");
    try c.send(200, "application/json", long_json);
}

fn sendNoTransform(c: *Ctx) anyerror!void {
    try c.setStaticHeader("Cache-Control", "public, max-age=60, No-Transform");
    try c.send(200, "application/json", long_json);
}

fn sendNoTransformLookalike(c: *Ctx) anyerror!void {
    try c.setStaticHeader("Cache-Control", "max-age=60, x-no-transform");
    try c.send(200, "application/json", long_json);
}

fn sendStrongTag(c: *Ctx) anyerror!void {
    try c.setStaticHeader("ETag", "\"v1\"");
    try c.send(200, "application/json", long_json);
}

fn sendWeakTag(c: *Ctx) anyerror!void {
    try c.setStaticHeader("ETag", "W/\"v1\"");
    try c.send(200, "application/json", long_json);
}

test "a partial answer, an unsatisfiable range and a Content-Range are never gzipped, whatever the client accepts" {
    // A range is an offset into one representation, and the gzipped bytes
    // are another one, so a 206 gzipped here would be the wrong bytes at the
    // offsets it names (ADR 211).
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/part", sendPartial);
    try app.get("/nope", sendUnsatisfiable);
    try app.get("/ranged", sendWithContentRange);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try client.setHeader("Accept-Encoding", "gzip");

    for ([_][]const u8{ "/part", "/nope", "/ranged" }) |path| {
        const answer = try client.get(&app, path);
        try testing.expect(answer.header("Content-Encoding") == null);
        try testing.expectEqualStrings(long_json, answer.body);
    }
}

test "Cache-Control: no-transform keeps a body as the handler wrote it, and a lookalike token does not" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/kept", sendNoTransform);
    try app.get("/lookalike", sendNoTransformLookalike);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try client.setHeader("Accept-Encoding", "gzip");

    const kept = try client.get(&app, "/kept");
    try testing.expect(kept.header("Content-Encoding") == null);
    try testing.expectEqualStrings(long_json, kept.body);

    const lookalike = try client.get(&app, "/lookalike");
    try testing.expectEqualStrings("gzip", lookalike.header("Content-Encoding").?);
}

test "a strong ETag is weakened when the body goes out gzipped, and left alone when it does not" {
    // A strong tag promises byte-for-byte identity, and the plain and the
    // gzipped body are two different byte strings (RFC 9110 section 8.8.1).
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/strong", sendStrongTag);
    try app.get("/weak", sendWeakTag);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    const gzipped = try client.send(&app, "GET /strong HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expectEqualStrings("gzip", gzipped.header("Content-Encoding").?);
    try testing.expectEqualStrings("W/\"v1\"", gzipped.header("ETag").?);

    const plain = try client.send(&app, "GET /strong HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(plain.header("Content-Encoding") == null);
    try testing.expectEqualStrings("\"v1\"", plain.header("ETag").?);

    const weak = try client.send(&app, "GET /weak HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expectEqualStrings("gzip", weak.header("Content-Encoding").?);
    try testing.expectEqualStrings("W/\"v1\"", weak.header("ETag").?);
}

test "a body over max_bytes goes out as it is, and one at max_bytes is still gzipped" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{ .max_bytes = long_json.len });
    try app.get("/at", sendLongJson);
    try app.get("/over", sendLongPlusOne);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try client.setHeader("Accept-Encoding", "gzip");

    const at = try client.get(&app, "/at");
    try testing.expectEqualStrings("gzip", at.header("Content-Encoding").?);

    const over = try client.get(&app, "/over");
    try testing.expect(over.header("Content-Encoding") == null);
    // The same for every client, so nothing varies.
    try testing.expect(over.header("Vary") == null);
    try testing.expectEqual(long_json.len + 1, over.body.len);
}

fn sendLongPlusOne(c: *Ctx) anyerror!void {
    try c.send(200, "application/json", long_json ++ " ");
}

test "a max_bytes of zero puts no upper limit on what is compressed" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{ .max_bytes = 0 });
    try app.get("/over", sendLongPlusOne);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try client.setHeader("Accept-Encoding", "gzip");

    const answer = try client.get(&app, "/over");
    try testing.expectEqualStrings("gzip", answer.header("Content-Encoding").?);
}

/// `s` written `n` times over, at compile time: what `s ** n` said before
/// Zig 0.17 took the operator away.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    // A comptime-known constant, so that `&built` is a pointer into the
    // binary and the call is as good at runtime as `**` was.
    const built = comptime blk: {
        @setEvalBranchQuota(10 * n + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        break :blk final;
    };
    return &built;
}
