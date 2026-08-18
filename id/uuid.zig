//! A UUID: sixteen bytes, the way they are written, and the two layouts
//! anybody uses (ADR 0042).
//!
//! `nilo_sql` has read a `uuid` column since 0.2.0 and could not make one, so
//! a service that wanted a key either asked Postgres for it and waited for
//! the answer to come back, or wrote sixteen bytes by hand. Both halves
//! belong to the same type, and this is where that type lives now — below the
//! module with an opinion about which column it goes in rather than inside
//! it, which is the whole of what ADR 0042 decides.
//!
//! **`v4` and `v7` are given their randomness rather than fetching it.** In
//! Zig 0.16 entropy is IO: `std.crypto.random` is gone and `std.Io.randomSecure`
//! wants an `Io`. nilo reaches it through the Bulkhead precisely because a
//! syscall made straight from a fiber stops every request sharing that thread
//! (ADR 0002, ADR 0014), and a module in the bottom layer has no Bulkhead to
//! reach through. So what is here is the *format* — where the version bits
//! go, which six bytes hold the millisecond — and the source stays with
//! whoever has one. ADR 0042 records what that costs and what the seam would
//! be; it is not built here.
//!
//! **Nothing else is imported, not even `nilo_core`**, and that is a fact
//! about the value rather than about restraint: sixteen bytes and the
//! thirty-six characters they are written as both fit in an array, so nothing
//! here needs an allocator, and something that needs no allocator needs no
//! Scope. It is what keeps `zig test id/id.zig` true.
//!
//! The line `sql/types.zig` holds applies here as well — **a type carries a
//! value and knows how to write itself; it does not calculate.** There is no
//! arithmetic on a UUID, no comparison past the bytes, and no notion of "the
//! next" one.

const std = @import("std");

/// Sixteen bytes, in the order they are written down — which is also the
/// order Postgres stores them, so `nilo_sql` reading a `uuid` column is a
/// copy rather than a conversion.
///
/// Two layouts, and the choice between them is not taste:
///
/// - **v4** is 122 random bits. Use it when the only thing wanted is that two
///   of them are never the same — a token, an idempotency key.
/// - **v7** puts the millisecond first, so a set of them sorts the way they
///   were made. Use it for a primary key: a B-tree index on random values
///   writes into every page it has, and one on v7 writes into the last.
pub const Uuid = struct {
    bytes: [byte_len]u8,

    /// How many bytes a UUID holds. Named because `nilo_sql` checks the
    /// length of what a column handed back against it, and a literal sixteen
    /// in two modules is a literal sixteen that can disagree.
    pub const byte_len = 16;

    /// How many characters the hyphenated form takes: thirty-two hex digits
    /// and four hyphens.
    pub const text_len = 36;

    /// How many random bytes each layout is made from, so a caller sizes its
    /// buffer by name rather than by counting bits. A v4 is random all the
    /// way through; a v7's first six bytes are the clock.
    pub const v4_entropy = 16;
    pub const v7_entropy = 10;

    /// All sixteen zero. The one UUID that means *none*, for a column that
    /// is not nullable and still has to say so.
    pub const nil: Uuid = .{ .bytes = [_]u8{0} ** byte_len };

    pub fn isNil(self: Uuid) bool {
        return self.eql(nil);
    }

    pub fn eql(a: Uuid, b: Uuid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    /// A random one, from randomness the caller brought. Version 4: 122 of
    /// the 128 bits are `entropy`, and the other six say what this is.
    ///
    /// **`entropy` has to be unguessable, and this cannot check that.** A
    /// v4 made from a seeded `std.Random.DefaultPrng` is fine in a test and
    /// is a session token anybody can predict in production. Where a server
    /// gets the real thing is the gap ADR 0042 records.
    pub fn v4(entropy: [v4_entropy]u8) Uuid {
        const out: Uuid = .{ .bytes = entropy };
        return out.marked(4);
    }

    /// A sortable one: `ms` big-endian in the first six bytes, then 74 bits
    /// of `entropy`.
    ///
    /// Sortable *across* milliseconds and not within one — two made in the
    /// same millisecond come out in random order relative to each other. RFC
    /// 9562 allows a counter there and this has none, which is a decision
    /// rather than an omission (ADR 0042): a counter is a threadlocal or an
    /// atomic, it buys ordering inside a millisecond that nobody asked for,
    /// and having no state is what lets this be called from any fiber
    /// without a lock.
    ///
    /// Only the low 48 bits of `ms` are kept, because that is the whole of
    /// the field. Unix milliseconds run out of them in the year 10889.
    pub fn v7(entropy: [v7_entropy]u8, ms: u64) Uuid {
        var out: Uuid = .{ .bytes = undefined };
        std.mem.writeInt(u48, out.bytes[0..6], @truncate(ms), .big);
        @memcpy(out.bytes[6..], &entropy);
        return out.marked(7);
    }

    /// Which version this claims to be. `4` and `7` are the two written
    /// here; anything read out of a database or parsed from text may say
    /// something else, and it is reported rather than judged.
    pub fn version(self: Uuid) u4 {
        return @truncate(self.bytes[6] >> 4);
    }

    /// The millisecond a v7 carries, or null for anything that is not one.
    /// Null rather than a number, because the same six bytes in a v4 are
    /// random and answering with them would be a plausible wrong time —
    /// the worst kind to hand back.
    pub fn millis(self: Uuid) ?u64 {
        if (self.version() != 7) return null;
        return std.mem.readInt(u48, self.bytes[0..6], .big);
    }

    /// The hyphenated form, lowercase: 8-4-4-4-12, which is the only
    /// spelling anything on the other side of an API expects.
    ///
    /// By value rather than into an allocator, which is the other reason
    /// this module needs no Scope. Thirty-six bytes on the stack is cheaper
    /// than any arena could be, and it works in a CLI, in a test and in a
    /// handler without any of them agreeing about memory first.
    pub fn toText(self: Uuid) [text_len]u8 {
        const hex = "0123456789abcdef";
        var out: [text_len]u8 = undefined;
        var at: usize = 0;
        for (self.bytes, 0..) |b, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                out[at] = '-';
                at += 1;
            }
            out[at] = hex[b >> 4];
            out[at + 1] = hex[b & 0x0f];
            at += 2;
        }
        return out;
    }

    pub fn writeText(self: Uuid, w: *std.Io.Writer) !void {
        try w.writeAll(&self.toText());
    }

    /// Text back into sixteen bytes. Hyphens are skipped wherever they are
    /// rather than required in the four places they belong: what arrives
    /// over an API is somebody else's spelling, and thirty-two hex digits
    /// are unambiguous with or without them.
    pub fn parse(text: []const u8) !Uuid {
        var out: Uuid = .{ .bytes = undefined };
        var at: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '-') continue;
            if (at >= 32) return error.InvalidUuid;
            const nibble = std.fmt.charToDigit(text[i], 16) catch return error.InvalidUuid;
            if (at % 2 == 0) {
                out.bytes[at / 2] = nibble << 4;
            } else {
                out.bytes[at / 2] |= nibble;
            }
            at += 1;
        }
        if (at != 32) return error.InvalidUuid;
        return out;
    }

    pub fn jsonStringify(self: Uuid, jw: anytype) !void {
        const text = self.toText();
        try jw.write(&text);
    }

    /// What the line above sends, said in a form that needs no import.
    ///
    /// `jsonStringify` is the whole reason `nilo_http` needs no knowledge of
    /// this module ([ADR 0046](../docs/adr/0046-randomness-is-an-argument.md)):
    /// a `Uuid` in a response comes out as text and the HTTP module never
    /// learns the type exists. The API description had the other half of that
    /// and it was wrong — it reflected `bytes: [16]u8` and told every
    /// generated client to expect an object, while the server sent 36
    /// characters. This is the sentence that reconciles them
    /// ([ADR 0076](../docs/adr/0076-a-type-that-writes-its-own-json-says-so.md)),
    /// and it is plain data on purpose: a tool module imports nothing, so it
    /// cannot name a `Schema` to say this any other way.
    pub const nilo_openapi = .{ .type = "string", .format = "uuid" };

    /// The six bits every layout sets the same way: four saying which
    /// version this is, two saying it follows RFC 9562 at all. Shared
    /// because a generator that sets one and forgets the other produces
    /// something that looks right in hex and is not a UUID.
    fn marked(self: Uuid, comptime v: u4) Uuid {
        var out = self;
        out.bytes[6] = (out.bytes[6] & 0x0f) | (@as(u8, v) << 4);
        out.bytes[8] = (out.bytes[8] & 0x3f) | 0x80;
        return out;
    }
};

// -- tests ---------------------------------------------------------------

const testing = std.testing;

/// Randomness a test can repeat. Not what a server uses, and the difference
/// is the point of `v4` taking its entropy rather than fetching it.
fn seeded(comptime n: usize, seed: u64) [n]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    var out: [n]u8 = undefined;
    prng.random().bytes(&out);
    return out;
}

test "a Uuid writes itself hyphenated and lowercase" {
    const u = Uuid{ .bytes = .{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    } };
    try testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", &u.toText());
}

test "a Uuid read back from its own text is the same sixteen bytes" {
    const text = "550e8400-e29b-41d4-a716-446655440000";
    const u = try Uuid.parse(text);
    try testing.expectEqualStrings(text, &u.toText());
}

test "text that is not a uuid is refused rather than half-read" {
    try testing.expectError(error.InvalidUuid, Uuid.parse("550e8400"));
    try testing.expectError(error.InvalidUuid, Uuid.parse("zzzzzzzz-e29b-41d4-a716-446655440000"));
    try testing.expectError(error.InvalidUuid, Uuid.parse("550e8400-e29b-41d4-a716-4466554400001"));
}

test "a v4 says which version it is, and says it follows the standard" {
    const u = Uuid.v4(seeded(Uuid.v4_entropy, 1));
    try testing.expectEqual(@as(u4, 4), u.version());
    try testing.expectEqual(@as(u8, 0x80), u.bytes[8] & 0xc0);
}

test "a v7 says which version it is, and says it follows the standard" {
    const u = Uuid.v7(seeded(Uuid.v7_entropy, 1), 1_786_872_600_000);
    try testing.expectEqual(@as(u4, 7), u.version());
    try testing.expectEqual(@as(u8, 0x80), u.bytes[8] & 0xc0);
}

test "a v4 keeps every bit of its entropy that the version does not claim" {
    const raw = seeded(Uuid.v4_entropy, 7);
    const u = Uuid.v4(raw);
    // The six bits that say what it is are the only ones that moved.
    try testing.expectEqualSlices(u8, raw[0..6], u.bytes[0..6]);
    try testing.expectEqual(raw[6] & 0x0f, u.bytes[6] & 0x0f);
    try testing.expectEqual(raw[7], u.bytes[7]);
    try testing.expectEqual(raw[8] & 0x3f, u.bytes[8] & 0x3f);
    try testing.expectEqualSlices(u8, raw[9..], u.bytes[9..]);
}

test "a v7 carries the millisecond it was given" {
    const ms: u64 = 1_786_872_600_000;
    try testing.expectEqual(ms, Uuid.v7(seeded(Uuid.v7_entropy, 2), ms).millis().?);
}

test "a v4 does not answer with a time it does not have" {
    try testing.expectEqual(@as(?u64, null), Uuid.v4(seeded(Uuid.v4_entropy, 3)).millis());
}

test "two v7s a millisecond apart sort the way they were made" {
    const random = seeded(Uuid.v7_entropy, 4);
    const earlier = Uuid.v7(random, 1_786_872_600_000);
    const later = Uuid.v7(random, 1_786_872_600_001);

    // As bytes, which is how a database orders the column...
    try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, &earlier.bytes, &later.bytes));
    // ...and as text, which is how everything else does.
    try testing.expectEqual(std.math.Order.lt, std.mem.order(u8, &earlier.toText(), &later.toText()));
}

test "the whole of a v7's time survives the round trip through text" {
    const ms: u64 = 281_474_976_710_655; // the last millisecond the field holds
    const u = try Uuid.parse(&Uuid.v7(seeded(Uuid.v7_entropy, 5), ms).toText());
    try testing.expectEqual(ms, u.millis().?);
}

test "two made from different entropy are not the same one twice" {
    const a = Uuid.v4(seeded(Uuid.v4_entropy, 8));
    const b = Uuid.v4(seeded(Uuid.v4_entropy, 9));
    try testing.expect(!a.eql(b));
    try testing.expect(a.eql(a));
}

test "the nil uuid is sixteen zeroes and knows it" {
    try testing.expect(Uuid.nil.isNil());
    try testing.expect(!Uuid.v4(seeded(Uuid.v4_entropy, 10)).isNil());
    try testing.expectEqualStrings("00000000-0000-0000-0000-000000000000", &Uuid.nil.toText());
}

test "a Uuid leaves a JSON body as its text rather than as sixteen numbers" {
    const u = try Uuid.parse("550e8400-e29b-41d4-a716-446655440000");
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try std.json.Stringify.value(u, .{}, &w);
    try testing.expectEqualStrings("\"550e8400-e29b-41d4-a716-446655440000\"", w.buffered());
}
