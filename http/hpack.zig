//! HPACK, the header compression HTTP/2 carries its headers in (RFC 7541),
//! and only the half a gRPC server needs
//! ([ADR 220](../docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).
//!
//! **The decoder is whole; the encoder never indexes.** A client decides what
//! goes into the table this side keeps, so reading has to understand every
//! representation RFC 7541 has, Huffman included. Writing is ours to choose,
//! and what is chosen is the one representation that leaves the client's
//! table alone: a literal, never indexed, never Huffman-coded. A response
//! header block is a few dozen bytes, so compressing it saves nothing worth a
//! table on the other side.
//!
//! **The table this side keeps is advertised at 0, and every client measured
//! honours it.** A decoder has to accept the default 4,096 bytes until the
//! client has read that setting, so the table exists, and it is allocated only
//! when a client inserts into it and handed back the moment the client shrinks
//! it to nothing. At idle a gRPC connection holds no table at all. Measured
//! against grpc-go, grpc-js, grpcio, tonic and the OpenTelemetry Collector
//! before this was written ([`bench/result/http.md`](../bench/result/http.md#what-a-grpc-client-puts-on-the-wire-and-what-a-stream-would-cost)).
//!
//! No IO and no Engine: every function takes bytes and an allocator, so
//! `zig test http/hpack.zig` runs the whole of it.

const std = @import("std");

/// One header, name and value, as HPACK carries it: a name is lowercase and
/// both are bytes rather than text. What a decoded field points at depends on
/// where it came from, and `Decoder.decode` says.
pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const Error = error{
    /// The block is not HPACK: an index past both tables, a string that runs
    /// off the end, a size update where one may not be, a Huffman string
    /// with the end-of-string symbol in it or padding that is not ones.
    /// Each of these is a `COMPRESSION_ERROR` for the whole connection,
    /// because the table on both sides may no longer agree.
    Compression,
    OutOfMemory,
};

/// The overhead RFC 7541 §4.1 charges each entry on top of its bytes, which is
/// what makes the table's size limit a count of entries as much as of bytes.
const entry_overhead = 32;

/// The size a table starts at, before anybody has said anything (RFC 9113
/// §6.5.2). Until the client acknowledges a smaller one it may use this much.
pub const default_table_size = 4096;

// ---- integers (§5.1) ----

/// Read an integer with an `n`-bit prefix from `block` at `pos.*`, and move
/// `pos` past it. Refused past 2^32, which no field of a header block needs
/// and which is where a hostile encoding would otherwise overflow.
pub fn readInt(block: []const u8, pos: *usize, comptime n: u4) Error!u32 {
    if (pos.* >= block.len) return error.Compression;
    const mask: u8 = (1 << n) - 1;
    var value: u64 = block[pos.*] & mask;
    pos.* += 1;
    if (value < mask) return @intCast(value);
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= block.len) return error.Compression;
        const b = block[pos.*];
        pos.* += 1;
        value += @as(u64, b & 0x7f) << shift;
        if (value > std.math.maxInt(u32)) return error.Compression;
        if (b & 0x80 == 0) return @intCast(value);
        shift += 7;
        if (shift > 28) return error.Compression;
    }
}

/// Write `value` with an `n`-bit prefix, the prefix's upper bits being `high`.
pub fn writeInt(w: *std.Io.Writer, high: u8, comptime n: u4, value: u32) std.Io.Writer.Error!void {
    const mask: u8 = (1 << n) - 1;
    if (value < mask) return w.writeByte(high | @as(u8, @intCast(value)));
    try w.writeByte(high | mask);
    var rest = value - mask;
    while (rest >= 0x80) : (rest >>= 7) try w.writeByte(@as(u8, @intCast(rest & 0x7f)) | 0x80);
    try w.writeByte(@intCast(rest));
}

// ---- Huffman (§5.2, Appendix B) ----

/// The code HPACK uses is canonical: the codes of one length are consecutive.
/// So decoding needs only each length's first code and count, and the symbols
/// in code order, rather than a tree. Built while compiling, and checked there, so a wrong table is
/// a build that fails rather than a header read wrong.
const Canonical = struct {
    first: [31]u32,
    count: [31]u16,
    offset: [31]u16,
    symbols: [256]u8,
};

const canonical: Canonical = blk: {
    @setEvalBranchQuota(200_000);
    var c: Canonical = .{
        .first = @splat(0),
        .count = @splat(0),
        .offset = @splat(0),
        .symbols = undefined,
    };
    var n: usize = 0;
    for (1..31) |len| {
        c.offset[len] = n;
        var first_seen = false;
        // Symbols of this length in the order of their codes.
        var last: u32 = 0;
        while (true) {
            var best: ?usize = null;
            for (0..256) |s| {
                if (lengths[s] != len) continue;
                if (first_seen and codes[s] <= last) continue;
                if (best == null or codes[s] < codes[best.?]) best = s;
            }
            const s = best orelse break;
            if (!first_seen) {
                c.first[len] = codes[s];
                first_seen = true;
            } else if (codes[s] != last + 1) @compileError("hpack: the Huffman table is not canonical");
            last = codes[s];
            c.symbols[n] = s;
            n += 1;
            c.count[len] += 1;
        }
    }
    if (n != 256) @compileError("hpack: the Huffman table does not cover every byte");
    break :blk c;
};

/// The end-of-string symbol, 30 ones. It may only appear as padding.
const eos_len = 30;

/// Up to two symbols decode with one table lookup when their codes come to
/// this many bits or fewer. Every byte a header name or an ordinary value is
/// made of has a code of 5 to 8 bits, so two of the commonest fit, and one of
/// anything up to 12 bits; the rest walk `canonical`.
///
/// Twelve because it was measured against its neighbours on h2load's five
/// strings: 165ns for the decoder this replaced, one symbol a lookup at 9
/// bits; two a lookup, 133 at 10 bits, 97 at 11, 82 at 12 and 77 at 13, where
/// each bit doubles the table
/// ([`bench/result/http.md`](../bench/result/http.md#two-huffman-symbols-a-lookup)).
const fast_bits = 12;

const Fast = extern struct {
    first: u8,
    second: u8,
    /// The first symbol's bits; 0 when the code starting here is longer than
    /// `fast_bits`.
    len: u8,
    /// Both symbols' bits; 0 when only the first fits.
    both: u8,
};

/// Indexed by the next `fast_bits` bits of input: 4,096 entries, four bytes
/// each, built while compiling from the same tables `canonical` is. A pair is
/// read off the single-symbol answer for what the first symbol leaves.
const fast: [1 << fast_bits]Fast = blk: {
    @setEvalBranchQuota(100_000);
    var one: [1 << fast_bits]Fast = @splat(.{ .first = 0, .second = 0, .len = 0, .both = 0 });
    for (0..256) |s| {
        const len: u32 = lengths[s];
        if (len > fast_bits) continue;
        const first = codes[s] << (fast_bits - len);
        for (0..(1 << (fast_bits - len))) |i| one[first + i] = .{ .first = s, .second = 0, .len = len, .both = 0 };
    }
    var t = one;
    for (&t, 0..) |*e, i| {
        if (e.len == 0) continue;
        // What follows the first code, its low bits zero: a second code that
        // ends within the real bits is read correctly whatever they are.
        const after = one[(i << e.len) & ((1 << fast_bits) - 1)];
        if (after.len == 0 or e.len + after.len > fast_bits) continue;
        e.second = after.first;
        e.both = e.len + after.len;
    }
    break :blk t;
};

/// Decode a Huffman string into `out`. Padding is at most seven bits and all
/// ones, and the end-of-string symbol inside a string is an error (§5.2).
///
/// Up to 64 bits of input are held at the top of a word, refilled a word at a
/// time, and one or two symbols are taken off the top of them a lookup. A bit
/// at a time was 563ns for the 89-byte header block h2load sends, 37% of a
/// whole call (ADR 220); one symbol a lookup took that to 165ns of Huffman in
/// it, and two to 82.
pub fn huffmanDecode(in: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) Error!void {
    // Every symbol is at least five bits, so this is the most it can be.
    try out.ensureUnusedCapacity(gpa, in.len * 8 / 5 + 1);
    // Written through the slice rather than appended one at a time; each
    // write is counted, so the reservation above still holds.
    const buf = out.allocatedSlice();
    var n = out.items.len;
    defer out.items.len = n;
    // Input not yet decoded, at the top of `acc`; the bits below are zeros.
    var acc: u64 = 0;
    var bits: u32 = 0;
    var next: usize = 0;
    while (true) {
        if (next + 8 <= in.len) {
            // A whole word, of which as many bytes as fit below what is held.
            acc |= std.mem.readInt(u64, in[next..][0..8], .big) >> @intCast(bits);
            const take = (63 - bits) / 8;
            next += take;
            bits += take * 8;
        } else while (bits <= 56 and next < in.len) : (next += 1) {
            acc |= @as(u64, in[next]) << @intCast(56 - bits);
            bits += 8;
        }
        if (bits == 0) return;

        // Past the end of the input the bits are zeros. A code that reaches
        // into them is longer than what is left, which is how the end is
        // told apart from a symbol below.
        const hit = fast[@intCast(acc >> (64 - fast_bits))];
        if (hit.both != 0 and hit.both <= bits) {
            buf[n] = hit.first;
            buf[n + 1] = hit.second;
            n += 2;
            acc <<= @intCast(hit.both);
            bits -= hit.both;
            continue;
        }
        if (hit.len != 0) {
            if (hit.len > bits) return padding(acc, bits);
            buf[n] = hit.first;
            n += 1;
            acc <<= @intCast(hit.len);
            bits -= hit.len;
            continue;
        }

        // Longer than the table: the canonical walk, from the first length
        // it does not cover. The refill above leaves fewer than 30 bits only
        // at the end of the input, and there they are padding or an error.
        var len: u32 = fast_bits + 1;
        while (true) : (len += 1) {
            if (len > bits) return padding(acc, bits);
            const code: u32 = @intCast(acc >> @intCast(64 - len));
            const rel = code -% canonical.first[len];
            if (canonical.count[len] != 0 and code >= canonical.first[len] and rel < canonical.count[len]) {
                buf[n] = canonical.symbols[canonical.offset[len] + rel];
                n += 1;
                acc <<= @intCast(len);
                bits -= len;
                break;
            }
            // Thirty bits that are no byte's code: the end-of-string symbol,
            // or nothing at all.
            if (len == eos_len) return error.Compression;
        }
    }
}

/// What is left at the top of `acc` at the end of a Huffman string: shorter
/// than a byte and every bit set, or the string is refused.
fn padding(acc: u64, bits: u32) Error!void {
    if (bits > 7) return error.Compression;
    if (bits == 0) return;
    const ones = (@as(u64, 1) << @intCast(bits)) - 1;
    if (acc >> @intCast(64 - bits) != ones) return error.Compression;
}

// ---- the static table (Appendix A) ----

/// Appendix A: the 61 fields every HPACK encoder may name by number.
pub const static_table = [61]Field{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

/// The index of the first static entry named `name`, or null. What the
/// encoder uses so that a name it writes costs one byte rather than its
/// length; the value is always written out.
pub fn staticNameIndex(name: []const u8) ?u32 {
    for (static_table, 1..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    }
    return null;
}

// ---- the decoder (§3, §6) ----

/// The half of HPACK that reads a client's headers, and the table the client
/// writes into.
///
/// **One per connection, and empty at idle.** The table is a list of copies
/// the Decoder owns, allocated from `gpa` when the client inserts and freed
/// when an entry is evicted, so a table the client has shrunk to 0 holds
/// nothing at all, not even the list's capacity.
pub const Decoder = struct {
    gpa: std.mem.Allocator,
    /// The most the client may set the table to: `default_table_size` until
    /// it has acknowledged ours, then what was advertised.
    allowed: u32 = default_table_size,
    /// What the client last set it to, which is at most `allowed`.
    capacity: u32 = default_table_size,
    /// What the entries weigh by §4.1's count.
    size: u32 = 0,
    /// Newest last. Each entry's bytes are the name then the value.
    entries: std.ArrayList(Entry) = .empty,
    /// Set when the limit went below what the client had set: RFC 7541 §4.2
    /// has it say so at the start of its next block.
    owed_update: bool = false,

    const Entry = struct {
        bytes: []u8,
        name_len: u32,

        fn field(e: Entry) Field {
            return .{ .name = e.bytes[0..e.name_len], .value = e.bytes[e.name_len..] };
        }

        fn weight(e: Entry) u32 {
            return @as(u32, @intCast(e.bytes.len)) + entry_overhead;
        }
    };

    pub fn init(gpa: std.mem.Allocator) Decoder {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Decoder) void {
        for (self.entries.items) |e| self.gpa.free(e.bytes);
        self.entries.deinit(self.gpa);
        self.* = undefined;
    }

    /// The client has acknowledged a table of `max`. If it had set a larger
    /// one, the next block must open by making it fit.
    pub fn allow(self: *Decoder, max: u32) void {
        self.allowed = max;
        if (self.capacity > max) self.owed_update = true;
    }

    /// What the table holds right now, in bytes of the process rather than
    /// §4.1's count: what a connection is paying for it.
    pub fn resident(self: *const Decoder) usize {
        var n: usize = self.entries.capacity * @sizeOf(Entry);
        for (self.entries.items) |e| n += e.bytes.len;
        return n;
    }

    fn evictTo(self: *Decoder, limit: u32) void {
        var drop: usize = 0;
        while (self.size > limit and drop < self.entries.items.len) : (drop += 1) {
            const e = self.entries.items[drop];
            self.size -= e.weight();
            self.gpa.free(e.bytes);
        }
        if (drop == 0) return;
        const rest = self.entries.items.len - drop;
        std.mem.copyForwards(Entry, self.entries.items[0..rest], self.entries.items[drop..]);
        self.entries.shrinkRetainingCapacity(rest);
        // A table emptied is a table that costs nothing, list included.
        if (rest == 0) self.entries.clearAndFree(self.gpa);
    }

    fn insert(self: *Decoder, f: Field) Error!void {
        const weight: u32 = @intCast(f.name.len + f.value.len + entry_overhead);
        // An entry larger than the table empties it and is not kept (§4.4),
        // which is how a client that ignores a table of 0 costs nothing.
        if (weight > self.capacity) {
            self.evictTo(0);
            return;
        }
        // Copied before anything is evicted: a literal whose name is indexed
        // points into this table, and the entry it points at may be one of
        // the ones about to go (§4.4 allows exactly that reference).
        const bytes = try self.gpa.alloc(u8, f.name.len + f.value.len);
        errdefer self.gpa.free(bytes);
        @memcpy(bytes[0..f.name.len], f.name);
        @memcpy(bytes[f.name.len..], f.value);
        self.evictTo(self.capacity - weight);
        try self.entries.append(self.gpa, .{ .bytes = bytes, .name_len = @intCast(f.name.len) });
        self.size += weight;
    }

    /// A field by index, and whether it is the static table's, which lives
    /// forever, or the client's, which may be evicted before a request is
    /// done with it and so has to be copied out.
    fn lookup(self: *const Decoder, index: u32) Error!struct { field: Field, static: bool } {
        if (index == 0) return error.Compression;
        if (index <= static_table.len) return .{ .field = static_table[index - 1], .static = true };
        const d = index - static_table.len - 1;
        if (d >= self.entries.items.len) return error.Compression;
        return .{ .field = self.entries.items[self.entries.items.len - 1 - d].field(), .static = false };
    }

    /// What `decode` found, besides the fields.
    pub const Decoded = struct {
        /// The fields came to more than `max_list` by §4.1's count, and the
        /// ones past it were dropped. The block was still read to the end,
        /// because the table has to stay in step with the client's.
        over_limit: bool = false,
    };

    /// Read one whole header block, appending its fields to `out`.
    ///
    /// **Where a field's bytes live**: a literal that was not Huffman-coded
    /// points into `block`; everything else is copied into `arena`. So
    /// `block` has to live as long as the fields do, which for a request is
    /// its arena, where the caller already put it.
    pub fn decode(
        self: *Decoder,
        block: []const u8,
        arena: std.mem.Allocator,
        out: *std.ArrayList(Field),
        max_list: usize,
    ) Error!Decoded {
        var result: Decoded = .{};
        var listed: usize = 0;
        var pos: usize = 0;
        var first = true;
        while (pos < block.len) {
            const b = block[pos];
            if (b & 0xe0 == 0x20) {
                // A size update: only before the first field (§4.2).
                if (!first) return error.Compression;
                const size = try readInt(block, &pos, 5);
                if (size > self.allowed) return error.Compression;
                self.capacity = size;
                self.evictTo(size);
                self.owed_update = false;
                continue;
            }
            if (first and self.owed_update) return error.Compression;
            first = false;

            // A field that points into the client's table is counted before
            // anything is copied, and copied only if it is kept. Copying first
            // was a bomb: one byte on the wire names an entry of up to the
            // table's size, so a block of references to one 4 KB entry cost
            // four thousand times its length in arena before the limit was
            // looked at.
            var field: Field = undefined;
            var in_table = false;
            var incremental = false;
            if (b & 0x80 != 0) {
                const found = try self.lookup(try readInt(block, &pos, 7));
                field = found.field;
                in_table = !found.static;
            } else {
                // With incremental indexing the index has six bits; without
                // it, and never-indexed, four (§6.2).
                incremental = b & 0xc0 == 0x40;
                const index = if (incremental) try readInt(block, &pos, 6) else try readInt(block, &pos, 4);
                const name = if (index == 0) try readString(block, &pos, arena) else name: {
                    const found = try self.lookup(index);
                    in_table = !found.static;
                    break :name found.field.name;
                };
                field = .{ .name = name, .value = try readString(block, &pos, arena) };
            }

            listed += field.name.len + field.value.len + entry_overhead;
            const kept = listed <= max_list;
            if (!kept) result.over_limit = true;
            // Before the insert below, which may evict the entry these bytes
            // are in. What goes into the table is copied by `insert` itself.
            if (kept and in_table) field = .{
                .name = try arena.dupe(u8, field.name),
                .value = if (b & 0x80 != 0) try arena.dupe(u8, field.value) else field.value,
            };
            if (incremental) try self.insert(field);
            if (kept) try out.append(arena, field);
        }
        if (first and self.owed_update) return error.Compression;
        return result;
    }
};

/// One string literal (§5.2): a Huffman flag, a length, and the bytes.
fn readString(block: []const u8, pos: *usize, arena: std.mem.Allocator) Error![]const u8 {
    if (pos.* >= block.len) return error.Compression;
    const huffman = block[pos.*] & 0x80 != 0;
    const len = try readInt(block, pos, 7);
    if (len > block.len - pos.*) return error.Compression;
    const raw = block[pos.*..][0..len];
    pos.* += len;
    if (!huffman) return raw;
    var out: std.ArrayList(u8) = .empty;
    try huffmanDecode(raw, &out, arena);
    return out.items;
}

// ---- the encoder ----

/// A field from the static table in full: one byte for `:status: 200`.
pub fn writeIndexed(w: *std.Io.Writer, index: u32) std.Io.Writer.Error!void {
    try writeInt(w, 0x80, 7, index);
}

/// A literal that is never indexed and never Huffman-coded, its name taken
/// from the static table when it is there (§6.2.2). The one representation
/// this side writes, and why the client's table never grows on our account.
pub fn writeLiteral(w: *std.Io.Writer, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
    if (staticNameIndex(name)) |i| {
        try writeInt(w, 0x00, 4, i);
    } else {
        try w.writeByte(0x00);
        try writeInt(w, 0x00, 7, @intCast(name.len));
        try w.writeAll(name);
    }
    try writeInt(w, 0x00, 7, @intCast(value.len));
    try w.writeAll(value);
}

/// A header list as one block: `:status 200` from the static table, every
/// other field as `writeLiteral` writes it.
pub fn encodeBlock(a: std.mem.Allocator, fields: []const Field) ![]const u8 {
    var w: std.Io.Writer.Allocating = try .initCapacity(a, 64);
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, ":status") and std.mem.eql(u8, f.value, "200")) {
            try writeIndexed(&w.writer, 8);
        } else try writeLiteral(&w.writer, f.name, f.value);
    }
    return w.written();
}

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

fn expectFields(got: []const Field, want: []const Field) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try testing.expectEqualStrings(w.name, g.name);
        try testing.expectEqualStrings(w.value, g.value);
    }
}

test "an integer with a five-bit prefix reads the way RFC 7541's examples write it" {
    // C.1.1, C.1.2, C.1.3: 10, 1337 and 42.
    var pos: usize = 0;
    try testing.expectEqual(@as(u32, 10), try readInt(&.{0x0a}, &pos, 5));
    pos = 0;
    try testing.expectEqual(@as(u32, 1337), try readInt(&.{ 0x1f, 0x9a, 0x0a }, &pos, 5));
    pos = 0;
    try testing.expectEqual(@as(u32, 42), try readInt(&.{0x2a}, &pos, 8));

    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeInt(&w, 0, 5, 1337);
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x9a, 0x0a }, w.buffered());
}

test "an integer past four bytes of continuation is refused rather than overflowed" {
    var pos: usize = 0;
    try testing.expectError(error.Compression, readInt(&.{ 0x1f, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, &pos, 5));
}

test "the requests of RFC 7541 C.3 decode, and the table ends where the RFC says" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(Field) = .empty;
    const first = hex("828684410f7777772e6578616d706c652e636f6d");
    _ = try d.decode(&first, arena, &out, 1 << 20);
    try expectFields(out.items, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "www.example.com" },
    });
    try testing.expectEqual(@as(u32, 57), d.size);

    out.clearRetainingCapacity();
    const second = hex("828684be58086e6f2d6361636865");
    _ = try d.decode(&second, arena, &out, 1 << 20);
    try expectFields(out.items, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "http" },
        .{ .name = ":path", .value = "/" },
        .{ .name = ":authority", .value = "www.example.com" },
        .{ .name = "cache-control", .value = "no-cache" },
    });
    try testing.expectEqual(@as(u32, 110), d.size);

    out.clearRetainingCapacity();
    const third = hex("828785bf400a637573746f6d2d6b65790c637573746f6d2d76616c7565");
    _ = try d.decode(&third, arena, &out, 1 << 20);
    try expectFields(out.items, &.{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":scheme", .value = "https" },
        .{ .name = ":path", .value = "/index.html" },
        .{ .name = ":authority", .value = "www.example.com" },
        .{ .name = "custom-key", .value = "custom-value" },
    });
    try testing.expectEqual(@as(u32, 164), d.size);
}

test "the Huffman-coded requests of RFC 7541 C.4 decode to the same fields" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(Field) = .empty;
    const first = hex("828684418cf1e3c2e5f23a6ba0ab90f4ff");
    _ = try d.decode(&first, arena, &out, 1 << 20);
    try testing.expectEqualStrings("www.example.com", out.items[3].value);

    out.clearRetainingCapacity();
    const second = hex("828684be5886a8eb10649cbf");
    _ = try d.decode(&second, arena, &out, 1 << 20);
    try testing.expectEqualStrings("no-cache", out.items[4].value);

    out.clearRetainingCapacity();
    const third = hex("828785bf408825a849e95ba97d7f8925a849e95bb8e8b4bf");
    _ = try d.decode(&third, arena, &out, 1 << 20);
    try expectFields(out.items[4..], &.{.{ .name = "custom-key", .value = "custom-value" }});
    try testing.expectEqual(@as(u32, 164), d.size);
}

test "the responses of RFC 7541 C.6 evict in the order the RFC says, at a 256-byte table" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    d.allowed = 256;
    d.capacity = 256;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(Field) = .empty;
    const first = hex("488264025885aec3771a4b6196d07abe941054d444a8200595040b8166e082a62d1bff6e919d29ad171863c78f0b97c8e9ae82ae43d3");
    _ = try d.decode(&first, arena, &out, 1 << 20);
    try expectFields(out.items, &.{
        .{ .name = ":status", .value = "302" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:21 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
    });
    try testing.expectEqual(@as(u32, 222), d.size);

    out.clearRetainingCapacity();
    const second = hex("4883640effc1c0bf");
    _ = try d.decode(&second, arena, &out, 1 << 20);
    try testing.expectEqualStrings("307", out.items[0].value);
    try testing.expectEqual(@as(u32, 222), d.size);

    out.clearRetainingCapacity();
    const third = hex("88c16196d07abe941054d444a8200595040b8166e084a62d1bffc05a839bd9ab77ad94e7821dd7f2e6c7b335dfdfcd5b3960d5af27087f3672c1ab270fb5291f9587316065c003ed4ee5b1063d5007");
    _ = try d.decode(&third, arena, &out, 1 << 20);
    try expectFields(out.items, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "cache-control", .value = "private" },
        .{ .name = "date", .value = "Mon, 21 Oct 2013 20:13:22 GMT" },
        .{ .name = "location", .value = "https://www.example.com" },
        .{ .name = "content-encoding", .value = "gzip" },
        .{ .name = "set-cookie", .value = "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1" },
    });
    try testing.expectEqual(@as(u32, 215), d.size);
}

test "a table the client shrinks to 0 holds nothing, not even the list" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(Field) = .empty;

    // A client that inserts before it has read our setting.
    _ = try d.decode(&hex("400a637573746f6d2d6b65790c637573746f6d2d76616c7565"), arena_state.allocator(), &out, 1 << 20);
    try testing.expect(d.resident() > 0);

    // It acknowledges 0, and opens its next block with an update to 0.
    d.allow(0);
    _ = try d.decode(&hex("2082"), arena_state.allocator(), &out, 1 << 20);
    try testing.expectEqual(@as(usize, 0), d.resident());
    try testing.expectEqual(@as(u32, 0), d.size);

    // And an insertion into a table of 0 is legal and keeps nothing (§4.4).
    _ = try d.decode(&hex("400a637573746f6d2d6b65790c637573746f6d2d76616c7565"), arena_state.allocator(), &out, 1 << 20);
    try testing.expectEqual(@as(usize, 0), d.resident());
    try testing.expectEqualStrings("custom-value", out.items[out.items.len - 1].value);
}

test "a client that owes a size update and opens with a field is refused" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(Field) = .empty;
    d.allow(0);
    try testing.expectError(error.Compression, d.decode(&.{0x82}, arena_state.allocator(), &out, 1 << 20));
}

test "a size update above what was allowed, or after the first field, is refused" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(Field) = .empty;
    // 4097 > 4096.
    try testing.expectError(error.Compression, d.decode(&.{ 0x3f, 0xe2, 0x1f }, arena_state.allocator(), &out, 1 << 20));
    try testing.expectError(error.Compression, d.decode(&.{ 0x82, 0x20 }, arena_state.allocator(), &out, 1 << 20));
}

test "an index past both tables, and a string that runs off the end, are refused" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(Field) = .empty;
    try testing.expectError(error.Compression, d.decode(&.{0xbe}, arena_state.allocator(), &out, 1 << 20));
    try testing.expectError(error.Compression, d.decode(&.{ 0x00, 0x05, 'a' }, arena_state.allocator(), &out, 1 << 20));
    try testing.expectError(error.Compression, d.decode(&.{0x80}, arena_state.allocator(), &out, 1 << 20));
}

test "a Huffman string padded with zeros, or longer than seven bits of padding, is refused" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    // 'a' is 00011 (5 bits); padded with 000 rather than 111.
    try testing.expectError(error.Compression, huffmanDecode(&.{0x18}, &out, testing.allocator));
    out.clearRetainingCapacity();
    try huffmanDecode(&.{0x1f}, &out, testing.allocator);
    try testing.expectEqualStrings("a", out.items);
    out.clearRetainingCapacity();
    // Eight bits of ones after 'a': a whole byte of padding.
    try testing.expectError(error.Compression, huffmanDecode(&.{ 0x1f, 0xff }, &out, testing.allocator));
    out.clearRetainingCapacity();
    // Thirty ones is the end-of-string symbol, which may not be in a string.
    try testing.expectError(error.Compression, huffmanDecode(&.{ 0xff, 0xff, 0xff, 0xff }, &out, testing.allocator));
}

test "every byte survives a trip through the Huffman code" {
    // Encoded here by the table itself, so this checks the decoder against
    // the table rather than against a second copy of it.
    var bits: std.ArrayList(u8) = .empty;
    defer bits.deinit(testing.allocator);
    var acc: u64 = 0;
    var n: u6 = 0;
    for (0..256) |s| {
        acc = (acc << lengths[s]) | codes[s];
        n += lengths[s];
        while (n >= 8) {
            n -= 8;
            try bits.append(testing.allocator, @intCast((acc >> n) & 0xff));
        }
    }
    if (n > 0) try bits.append(testing.allocator, @intCast(((acc << (8 - n)) | ((@as(u64, 1) << (8 - n)) - 1)) & 0xff));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try huffmanDecode(bits.items, &out, testing.allocator);
    try testing.expectEqual(@as(usize, 256), out.items.len);
    for (out.items, 0..) |b, i| try testing.expectEqual(@as(u8, @intCast(i)), b);
}

test "every pair of bytes survives a trip through the Huffman code" {
    // The two-symbol lookups, and each pair at both ends of a string: the
    // padding after it is 0 to 7 bits, and a pair that ends on it must not
    // be read past.
    var bits: std.ArrayList(u8) = .empty;
    defer bits.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for (0..256) |a| for (0..256) |b| {
        bits.clearRetainingCapacity();
        var acc: u64 = (@as(u64, codes[a]) << lengths[b]) | codes[b];
        var n: u6 = @as(u6, lengths[a]) + lengths[b];
        while (n >= 8) {
            n -= 8;
            try bits.append(testing.allocator, @intCast((acc >> n) & 0xff));
        }
        acc &= (@as(u64, 1) << n) - 1;
        if (n > 0) try bits.append(testing.allocator, @intCast(((acc << (8 - n)) | ((@as(u64, 1) << (8 - n)) - 1)) & 0xff));
        out.clearRetainingCapacity();
        try huffmanDecode(bits.items, &out, testing.allocator);
        try testing.expectEqualSlices(u8, &.{ @intCast(a), @intCast(b) }, out.items);
    };
}

test "headers past the list limit are dropped and said so, and the table still moves" {
    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(Field) = .empty;
    const block = hex("828684410f7777772e6578616d706c652e636f6d");
    const got = try d.decode(&block, arena_state.allocator(), &out, 100);
    try testing.expect(got.over_limit);
    try testing.expect(out.items.len < 4);
    try testing.expectEqual(@as(u32, 57), d.size);
}

/// One 4,000-byte entry inserted into the client's table, then `refs` copies
/// of a reference to it, each a byte or three on the wire.
fn tableBomb(gpa: std.mem.Allocator, reference: []const u8, refs: usize) ![]u8 {
    var block: std.ArrayList(u8) = .empty;
    errdefer block.deinit(gpa);
    // Literal with incremental indexing, new name `x`, a 4,000-byte value:
    // 4,000 is 127 in the 7-bit prefix and 3,873 after it.
    try block.appendSlice(gpa, &.{ 0x40, 0x01, 'x', 0x7f, 0xa1, 0x1e });
    try block.appendNTimes(gpa, 'v', 4000);
    for (0..refs) |_| try block.appendSlice(gpa, reference);
    return block.toOwnedSlice(gpa);
}

test "a block of references to one large entry costs the list limit, not the references" {
    // Indexed field 62 (`0xbe`), and a literal never indexed whose name is
    // index 62 with an empty value (`0x0f 0x2f 0x00`): both used to copy the
    // entry into the arena before the limit was counted, 277 MB from 60 KB.
    for ([_][]const u8{ &.{0xbe}, &.{ 0x0f, 0x2f, 0x00 } }) |reference| {
        var d = Decoder.init(testing.allocator);
        defer d.deinit();
        const block = try tableBomb(testing.allocator, reference, 20_000);
        defer testing.allocator.free(block);

        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var out: std.ArrayList(Field) = .empty;
        const max_list = 16 * 1024;
        const got = try d.decode(block, arena_state.allocator(), &out, max_list);

        try testing.expect(got.over_limit);
        // What is left is the kept fields and the list growing to hold them:
        // 22 KB and 83 KB, where copying before counting took 80 MB.
        try testing.expect(arena_state.queryCapacity() < 256 * 1024);
    }
}

test "a literal named by the entry its own insert evicts keeps that name" {
    // `abc: 1` goes in, then a literal indexed by name 62 (that entry) whose
    // value is large enough that inserting it evicts the entry its name is
    // in. The name has to be copied before the eviction, kept or not.
    for ([_]usize{ 1024 * 1024, 0 }) |max_list| {
        var d = Decoder.init(testing.allocator);
        defer d.deinit();
        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(testing.allocator);
        try block.appendSlice(testing.allocator, &.{ 0x40, 0x03, 'a', 'b', 'c', 0x01, '1' });
        // Incremental, name index 62 (`0x7e`), value of 4,030 bytes: 127 in
        // the prefix and 3,903 after it.
        try block.appendSlice(testing.allocator, &.{ 0x7e, 0x7f, 0xbf, 0x1e });
        try block.appendNTimes(testing.allocator, 'z', 4030);

        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        var out: std.ArrayList(Field) = .empty;
        _ = try d.decode(block.items, arena_state.allocator(), &out, max_list);

        try testing.expectEqual(@as(usize, 1), d.entries.items.len);
        try testing.expectEqualStrings("abc", d.entries.items[0].field().name);
        if (max_list != 0) try testing.expectEqualStrings("abc", out.items[1].name);
    }
}

test "what the encoder writes, this decoder reads, and it inserts nothing" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeIndexed(&w, 8);
    try writeLiteral(&w, "content-type", "application/grpc");
    try writeLiteral(&w, "grpc-status", "0");

    var d = Decoder.init(testing.allocator);
    defer d.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(Field) = .empty;
    _ = try d.decode(w.buffered(), arena_state.allocator(), &out, 1 << 20);
    try expectFields(out.items, &.{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "application/grpc" },
        .{ .name = "grpc-status", .value = "0" },
    });
    try testing.expectEqual(@as(u32, 0), d.size);
}

// ---- tables, extracted from RFC 7541's appendices ----

/// Appendix B: each byte's code, right-aligned, and its length in bits.
const codes = [256]u32{
    0x1ff8,    0x7fffd8,  0xfffffe2,  0xfffffe3, 0xfffffe4, 0xfffffe5,  0xfffffe6,  0xfffffe7,
    0xfffffe8, 0xffffea,  0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb,  0xfffffec,
    0xfffffed, 0xfffffee, 0xfffffef,  0xffffff0, 0xffffff1, 0xffffff2,  0x3ffffffe, 0xffffff3,
    0xffffff4, 0xffffff5, 0xffffff6,  0xffffff7, 0xffffff8, 0xffffff9,  0xffffffa,  0xffffffb,
    0x14,      0x3f8,     0x3f9,      0xffa,     0x1ff9,    0x15,       0xf8,       0x7fa,
    0x3fa,     0x3fb,     0xf9,       0x7fb,     0xfa,      0x16,       0x17,       0x18,
    0x0,       0x1,       0x2,        0x19,      0x1a,      0x1b,       0x1c,       0x1d,
    0x1e,      0x1f,      0x5c,       0xfb,      0x7ffc,    0x20,       0xffb,      0x3fc,
    0x1ffa,    0x21,      0x5d,       0x5e,      0x5f,      0x60,       0x61,       0x62,
    0x63,      0x64,      0x65,       0x66,      0x67,      0x68,       0x69,       0x6a,
    0x6b,      0x6c,      0x6d,       0x6e,      0x6f,      0x70,       0x71,       0x72,
    0xfc,      0x73,      0xfd,       0x1ffb,    0x7fff0,   0x1ffc,     0x3ffc,     0x22,
    0x7ffd,    0x3,       0x23,       0x4,       0x24,      0x5,        0x25,       0x26,
    0x27,      0x6,       0x74,       0x75,      0x28,      0x29,       0x2a,       0x7,
    0x2b,      0x76,      0x2c,       0x8,       0x9,       0x2d,       0x77,       0x78,
    0x79,      0x7a,      0x7b,       0x7ffe,    0x7fc,     0x3ffd,     0x1ffd,     0xffffffc,
    0xfffe6,   0x3fffd2,  0xfffe7,    0xfffe8,   0x3fffd3,  0x3fffd4,   0x3fffd5,   0x7fffd9,
    0x3fffd6,  0x7fffda,  0x7fffdb,   0x7fffdc,  0x7fffdd,  0x7fffde,   0xffffeb,   0x7fffdf,
    0xffffec,  0xffffed,  0x3fffd7,   0x7fffe0,  0xffffee,  0x7fffe1,   0x7fffe2,   0x7fffe3,
    0x7fffe4,  0x1fffdc,  0x3fffd8,   0x7fffe5,  0x3fffd9,  0x7fffe6,   0x7fffe7,   0xffffef,
    0x3fffda,  0x1fffdd,  0xfffe9,    0x3fffdb,  0x3fffdc,  0x7fffe8,   0x7fffe9,   0x1fffde,
    0x7fffea,  0x3fffdd,  0x3fffde,   0xfffff0,  0x1fffdf,  0x3fffdf,   0x7fffeb,   0x7fffec,
    0x1fffe0,  0x1fffe1,  0x3fffe0,   0x1fffe2,  0x7fffed,  0x3fffe1,   0x7fffee,   0x7fffef,
    0xfffea,   0x3fffe2,  0x3fffe3,   0x3fffe4,  0x7ffff0,  0x3fffe5,   0x3fffe6,   0x7ffff1,
    0x3ffffe0, 0x3ffffe1, 0xfffeb,    0x7fff1,   0x3fffe7,  0x7ffff2,   0x3fffe8,   0x1ffffec,
    0x3ffffe2, 0x3ffffe3, 0x3ffffe4,  0x7ffffde, 0x7ffffdf, 0x3ffffe5,  0xfffff1,   0x1ffffed,
    0x7fff2,   0x1fffe3,  0x3ffffe6,  0x7ffffe0, 0x7ffffe1, 0x3ffffe7,  0x7ffffe2,  0xfffff2,
    0x1fffe4,  0x1fffe5,  0x3ffffe8,  0x3ffffe9, 0xffffffd, 0x7ffffe3,  0x7ffffe4,  0x7ffffe5,
    0xfffec,   0xfffff3,  0xfffed,    0x1fffe6,  0x3fffe9,  0x1fffe7,   0x1fffe8,   0x7ffff3,
    0x3fffea,  0x3fffeb,  0x1ffffee,  0x1ffffef, 0xfffff4,  0xfffff5,   0x3ffffea,  0x7ffff4,
    0x3ffffeb, 0x7ffffe6, 0x3ffffec,  0x3ffffed, 0x7ffffe7, 0x7ffffe8,  0x7ffffe9,  0x7ffffea,
    0x7ffffeb, 0xffffffe, 0x7ffffec,  0x7ffffed, 0x7ffffee, 0x7ffffef,  0x7fffff0,  0x3ffffee,
};

const lengths = [256]u5{
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6,  10, 10, 12, 13, 6,  8,  11, 10, 10, 8,  11, 8,  6,  6,  6,
    5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  7,  8,  15, 6,  12, 10,
    13, 6,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,
    7,  7,  7,  7,  7,  7,  7,  7,  8,  7,  8,  13, 19, 13, 14, 6,
    15, 5,  6,  5,  6,  5,  6,  6,  6,  5,  7,  7,  6,  6,  6,  5,
    6,  7,  6,  5,  5,  6,  7,  7,  7,  7,  7,  15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
};
