//! Sessions: state the *client* holds, sealed so it cannot read or change it.
//!
//! ```zig
//! const Signed = struct { user: u32, admin: bool = false };
//!
//! fn signIn(s: zfast.Session(Signed), form: zfast.Form(Login)) !zfast.Redirect(303) {
//!     const id = try accounts.check(form) orelse return .to("/login?wrong");
//!     try s.set(.{ .user = id });
//!     return .to("/");
//! }
//!
//! fn me(s: zfast.Session(Signed)) !?Profile {
//!     const signed = s.get() orelse return null;   // null → 404
//!     return profiles.find(signed.user);
//! }
//! ```
//!
//! **Nothing is stored on the server.** The whole session is serialised,
//! encrypted and signed with `XChaCha20Poly1305`, and handed back as one
//! cookie. That is the reason to prefer this over an id pointing at a store
//! rather than a detail of how it is written: there is no table, no expiry
//! sweep, no lock, and nothing added to the 8,767 bytes an idle connection
//! holds ([ADR 0018](../docs/adr/0018-the-trade-budget-has-three-axes.md)).
//! A request that does not ask for a session runs the code it ran before.
//!
//! The cipher comes from `std.crypto`, so this costs no dependency and does
//! not reopen [ADR 0028](../docs/adr/0028-tls-is-terminated-in-front.md)'s
//! refusal of one-person crypto. The shape is jetzig's; it is the one design
//! in that framework zfast had no answer to.
//!
//! **What a session may hold is deliberately narrow**: a fixed-size struct of
//! numbers, bools, enums and `[N]u8` arrays. No slices, no pointers. Two
//! reasons, and neither is implementation convenience. A cookie has to be
//! self-contained, because there is no server-side row to point at. And a
//! browser drops a cookie over about 4 KB *silently* — so the size has to be
//! knowable while compiling, which is only true if every field is.
//!
//! **A session is not authentication.** It is where a signed-in user's id is
//! kept once something else has established it; what establishes it is the
//! application's, the same line
//! [ADR 0016](../docs/adr/0016-resolved-values-are-declared-by-their-type.md)
//! draws.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const cookie_mod = @import("cookie.zig");
const ctx_mod = @import("ctx.zig");
const fail = @import("fail.zig");
const names = @import("names.zig");

const Ctx = ctx_mod.Ctx;
const Cipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

/// How long the secret has to be. Not a number zfast picked — it is the
/// cipher's key length, and saying so here means it moves if the cipher ever
/// does.
pub const key_len = Cipher.key_length;

/// The secret a session is sealed with. The application supplies it; where it
/// comes from is the application's business, and it must be the same on every
/// instance behind a load balancer or a request will land on the machine that
/// cannot read its own cookies.
pub const Key = [key_len]u8;

comptime {
    // `Ctx._session_key` spells this out as `[32]u8`, because session.zig
    // needs `Ctx` and a field type cannot be imported from inside a function
    // body. This is what stops the two drifting apart in silence.
    if (key_len != 32) @compileError(
        "zfast: the session key is no longer 32 bytes; `Ctx._session_key` has to be changed to match.",
    );
}

/// The name of the cookie. One per application: a second `Session(T)` of a
/// different `T` would write over the first, and the shape check below is
/// what turns that from a silent misread into an ignored cookie.
pub const cookie_name = "session";

/// What a browser will actually keep. RFC 6265 asks for at least 4096 bytes
/// per cookie *including the name and the attributes*, and browsers hold
/// close to that and no more. Past it the cookie is dropped — with no error,
/// no warning and a session that simply never appears — so the margin here is
/// for `session=`, `; Path=/; Secure; HttpOnly; SameSite=Lax`, and room to
/// add an attribute later without turning a working app into a broken one.
pub const max_cookie_bytes = 3800;

/// The format the plaintext is in, so a future change to the layout can be
/// told from a cookie written before it.
const format_version: u8 = 1;

/// Where the sealed bytes start once the nonce is out of the way.
const overhead = Cipher.nonce_length + Cipher.tag_length;

pub const Error = error{
    /// The secret is not `key_len` bytes.
    SessionSecretWrongLength,
    /// A session was asked for and the application never set a secret.
    SessionSecretMissing,
};

// ---- what a session may hold ----

/// The plaintext size of `T`: a version byte, the shape fingerprint, and the
/// fields. Settled while compiling, which is what makes the cookie ceiling
/// checkable at all.
pub fn plainSize(comptime T: type) usize {
    return 1 + 4 + sizeOf(T);
}

/// How long the cookie value will be once sealed and base64'd.
pub fn cookieSize(comptime T: type) usize {
    return std.base64.standard.Encoder.calcSize(plainSize(T) + overhead);
}

/// Every field of `T`, laid out end to end with no padding.
///
/// Not `@sizeOf`. A struct's in-memory layout has padding in it and is the
/// compiler's to change; a cookie written by one build has to be readable by
/// the next. So the size is the sum of the parts, and `encode` writes them in
/// declaration order, little-endian.
fn sizeOf(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| blk: {
            if (i.bits % 8 != 0) unsupported(T, "an integer whose width is not a whole number of bytes");
            break :blk i.bits / 8;
        },
        .float => |f| switch (f.bits) {
            32, 64 => f.bits / 8,
            else => unsupported(T, "a float that is not f32 or f64"),
        },
        .@"enum" => |e| sizeOf(e.tag_type),
        .optional => |o| 1 + sizeOf(o.child),
        .array => |a| blk: {
            if (a.child != u8) unsupported(T, "an array of something other than u8");
            break :blk a.len;
        },
        .@"struct" => |s| blk: {
            var total: usize = 0;
            // `inline`: a `StructField` carries a `type`, which does not
            // exist at runtime, so an ordinary loop over them is a compile
            // error rather than slow code.
            inline for (s.fields) |f| total += sizeOf(f.type);
            break :blk total;
        },
        else => unsupported(T, "not something a session can carry"),
    };
}

fn unsupported(comptime T: type, comptime why: []const u8) noreturn {
    @compileError(
        "zfast: `" ++ names.of(T) ++ "` cannot be part of a session, because it is " ++ why ++ ".\n" ++
            "  A session travels in a cookie and there is no row on the server to point at, so it " ++
            "has to be self-contained and of a size known while compiling.\n" ++
            "  What it can hold: integers, floats, bools, enums, `[N]u8` arrays, optionals of " ++
            "those, and structs of those.\n" ++
            "  For text, give it a bound — `name: [32]u8` — or keep an id in the session and look " ++
            "the rest up.",
    );
}

/// A number standing for the *shape* of `T` — its field names, in order, with
/// their types.
///
/// This is what stops the worst failure this design has. Add a field to your
/// session struct and deploy, and every cookie already out there was written
/// to the old shape; decrypted against the new one it is not corrupt, it is
/// *plausible*, and somebody is silently signed in as the wrong user. The
/// fingerprint goes inside the sealed bytes, so a cookie whose shape does not
/// match this build is treated as no cookie at all: the person signs in
/// again, which is the correct answer and the boring one.
fn fingerprint(comptime T: type) u32 {
    comptime {
        var hasher = std.hash.Fnv1a_32.init();
        describe(T, &hasher);
        return hasher.final();
    }
}

fn describe(comptime T: type, hasher: anytype) void {
    comptime {
        switch (@typeInfo(T)) {
            .@"struct" => |s| {
                hasher.update("{");
                for (s.fields) |f| {
                    hasher.update(f.name);
                    hasher.update(":");
                    describe(f.type, hasher);
                    hasher.update(",");
                }
                hasher.update("}");
            },
            .optional => |o| {
                hasher.update("?");
                describe(o.child, hasher);
            },
            .array => |a| {
                hasher.update(std.fmt.comptimePrint("[{d}]u8", .{a.len}));
            },
            .@"enum" => |e| {
                // The tag values, not the names: renaming a variant is a
                // rename, but reordering one changes what the number means.
                hasher.update("enum(");
                describe(e.tag_type, hasher);
                for (e.fields) |f| hasher.update(std.fmt.comptimePrint("{d};", .{f.value}));
                hasher.update(")");
            },
            else => hasher.update(@typeName(T)),
        }
    }
}

// ---- the bytes ----

fn encode(comptime T: type, value: T, out: []u8) usize {
    var at: usize = 0;
    switch (@typeInfo(T)) {
        .bool => {
            out[at] = @intFromBool(value);
            at += 1;
        },
        .int => |i| {
            std.mem.writeInt(T, out[at..][0 .. i.bits / 8], value, .little);
            at += i.bits / 8;
        },
        .float => |f| {
            const Bits = std.meta.Int(.unsigned, f.bits);
            std.mem.writeInt(Bits, out[at..][0 .. f.bits / 8], @bitCast(value), .little);
            at += f.bits / 8;
        },
        .@"enum" => |e| at += encode(e.tag_type, @intFromEnum(value), out[at..]),
        .optional => |o| {
            out[at] = if (value == null) 0 else 1;
            at += 1;
            // The payload slot is written either way, so the size never
            // depends on the data — that is what `plainSize` is promising.
            at += encode(o.child, value orelse std.mem.zeroes(o.child), out[at..]);
        },
        .array => |a| {
            @memcpy(out[at..][0..a.len], &value);
            at += a.len;
        },
        .@"struct" => |s| {
            inline for (s.fields) |f| at += encode(f.type, @field(value, f.name), out[at..]);
        },
        else => comptime unsupported(T, "not something a session can carry"),
    }
    return at;
}

/// The one thing that can be wrong in bytes that decrypted cleanly.
const Unreadable = error{BadValue};

fn Decoded(comptime T: type) type {
    return struct { value: T, used: usize };
}

fn decode(comptime T: type, in: []const u8) Unreadable!Decoded(T) {
    var at: usize = 0;
    switch (@typeInfo(T)) {
        .bool => {
            const v = in[at] != 0;
            return .{ .value = v, .used = 1 };
        },
        .int => |i| {
            const v = std.mem.readInt(T, in[0 .. i.bits / 8], .little);
            return .{ .value = v, .used = i.bits / 8 };
        },
        .float => |f| {
            const Bits = std.meta.Int(.unsigned, f.bits);
            const bits = std.mem.readInt(Bits, in[0 .. f.bits / 8], .little);
            return .{ .value = @bitCast(bits), .used = f.bits / 8 };
        },
        .@"enum" => |e| {
            const got = try decode(e.tag_type, in);
            // An out-of-range tag cannot come through a valid seal of this
            // shape, but it can come through a *different* shape whose
            // fingerprint happened to collide, so it is checked rather than
            // assumed. The whole session is refused rather than the field
            // being patched to something plausible.
            const v = std.enums.fromInt(T, got.value) orelse return error.BadValue;
            return .{ .value = v, .used = got.used };
        },
        .optional => |o| {
            const present = in[at] != 0;
            at += 1;
            const got = try decode(o.child, in[at..]);
            at += got.used;
            return .{ .value = if (present) got.value else null, .used = at };
        },
        .array => |a| {
            var v: T = undefined;
            @memcpy(&v, in[0..a.len]);
            return .{ .value = v, .used = a.len };
        },
        .@"struct" => |s| {
            var v: T = undefined;
            inline for (s.fields) |f| {
                const got = try decode(f.type, in[at..]);
                @field(v, f.name) = got.value;
                at += got.used;
            }
            return .{ .value = v, .used = at };
        },
        else => comptime unsupported(T, "not something a session can carry"),
    }
}

// ---- sealing ----

/// `value` as a cookie value: version, shape, fields, encrypted under a fresh
/// random nonce, then base64.
///
/// The buffer is the caller's, so this allocates nothing. `Sealed(T)` is the
/// exact array to hand it.
pub fn seal(comptime T: type, value: T, key: Key, out: []u8) ![]const u8 {
    var plain: [plainSize(T)]u8 = undefined;
    plain[0] = format_version;
    std.mem.writeInt(u32, plain[1..5], comptime fingerprint(T), .little);
    _ = encode(T, value, plain[5..]);

    var raw: [plainSize(T) + overhead]u8 = undefined;
    const nonce = raw[0..Cipher.nonce_length];
    // A random nonce rather than a counter: there is nowhere to keep a
    // counter. XChaCha20's nonce is 192 bits precisely so that random is
    // safe — the birthday bound is out of reach of any number of sessions a
    // server will ever write.
    //
    // Through the Bulkhead rather than `std.crypto.random`, because this is
    // a syscall and a syscall made straight from a fiber stops every request
    // sharing its thread (ADR 0002, ADR 0014).
    try bulkhead.randomSecure(nonce);

    const body = raw[Cipher.nonce_length..][0..plain.len];
    const tag = raw[Cipher.nonce_length + plain.len ..][0..Cipher.tag_length];
    Cipher.encrypt(body, tag, &plain, "", nonce.*, key);

    return std.base64.standard.Encoder.encode(out, &raw);
}

/// The value back out of a cookie, or null.
///
/// **Every way this can fail is the same answer: null.** Tampered, truncated,
/// written under a different secret, written by a build with a different
/// shape of `T` — none of these is an error the application can do anything
/// about, and all of them mean the same thing to it: this request has no
/// session. Turning them into distinct errors would only invite a handler to
/// treat one of them as "nearly signed in".
pub fn open(comptime T: type, text: []const u8, key: Key) ?T {
    const sealed_len = std.base64.standard.Decoder.calcSizeForSlice(text) catch return null;
    if (sealed_len != plainSize(T) + overhead) return null;

    var raw: [plainSize(T) + overhead]u8 = undefined;
    std.base64.standard.Decoder.decode(&raw, text) catch return null;

    var plain: [plainSize(T)]u8 = undefined;
    const nonce = raw[0..Cipher.nonce_length];
    const body = raw[Cipher.nonce_length..][0..plain.len];
    const tag = raw[Cipher.nonce_length + plain.len ..][0..Cipher.tag_length];
    Cipher.decrypt(&plain, body, tag.*, "", nonce.*, key) catch return null;

    if (plain[0] != format_version) return null;
    if (std.mem.readInt(u32, plain[1..5], .little) != comptime fingerprint(T)) return null;

    const got = decode(T, plain[5..]) catch return null;
    return got.value;
}

/// A buffer big enough for the cookie value of a `T`. Handed to `seal`.
pub fn Sealed(comptime T: type) type {
    return [cookieSize(T)]u8;
}

/// Whether a secret is usable, asked at `listen()` so that a wrong one is a
/// startup error rather than every request failing at once.
pub fn checkSecret(secret: []const u8) Error!Key {
    if (secret.len != key_len) return error.SessionSecretWrongLength;
    var key: Key = undefined;
    @memcpy(&key, secret);
    return key;
}

// ---- the handler-facing type ----

/// The session, asked for by writing it in a handler's argument list.
///
/// A resolved value like any other
/// ([ADR 0016](../docs/adr/0016-resolved-values-are-declared-by-their-type.md)),
/// so the cookie is read and decrypted once per request however many things
/// ask for it — a middleware guarding a prefix and the handler behind it do
/// not pay twice.
///
/// Reading and writing are separate calls on purpose. A resolved value is
/// handed to the handler by value, so a mutated copy would go nowhere and
/// look like it had worked; `set` is a line in a diff instead, next to the
/// `c.setCookie` it turns into.
pub fn Session(comptime T: type) type {
    // Checked here rather than at first use, so the message names the type
    // the person wrote rather than a field eight frames down.
    comptime {
        if (@typeInfo(T) != .@"struct") @compileError(
            "zfast: the `Session(" ++ names.of(T) ++ ")` is not a struct.\n" ++
                "  A session is a struct of your own, one field per thing you want to remember:\n" ++
                "      const Signed = struct { user: u32, admin: bool = false };",
        );
        if (@typeInfo(T).@"struct".fields.len == 0) @compileError(
            "zfast: the `Session(" ++ names.of(T) ++ ")` has no fields, so it would remember " ++
                "nothing.",
        );
        _ = sizeOf(T);
        if (cookieSize(T) > max_cookie_bytes) @compileError(std.fmt.comptimePrint(
            "zfast: a `Session(" ++ names.of(T) ++ ")` would be {d} bytes in the cookie, and the " ++
                "most that fits is {d}.\n" ++
                "  A browser drops a cookie this big without saying so, which would look like a " ++
                "session that never works rather than one that is too large.\n" ++
                "  Keep an id in the session and look the rest up.",
            .{ cookieSize(T), max_cookie_bytes },
        ));
    }

    return struct {
        const Self = @This();

        pub const zfast_resolve = read;

        /// What arrived, if anything readable did.
        value: ?T,

        /// Held so `set` and `clear` have somewhere to write. Underscored
        /// like every other field a caller has no business touching.
        ///
        /// Optional, and defaulted, so that a handler taking a session is
        /// still an ordinary function a test can call (ADR 0003):
        ///
        /// ```zig
        /// try testing.expect((try me(.{ .value = .{ .user = 7 } })) != null);
        /// ```
        ///
        /// A test that means to check what was *written* drives the App with
        /// the test client instead, which is the only thing that can observe
        /// a `Set-Cookie` anyway.
        _c: ?*Ctx = null,

        fn read(c: *Ctx) !Self {
            const key = c._session_key orelse return fail.internal(
                "a handler asked for a Session and no secret was set. Pass one to listen(): " ++
                    "`.session_secret = my_secret` — {d} bytes, the same on every instance.",
                .{key_len},
            );
            const text = c.cookie(cookie_name) orelse return .{ .value = null, ._c = c };
            return .{ .value = open(T, text.view(), key.*), ._c = c };
        }

        /// What the client sent, or null if it sent nothing zfast could read.
        pub fn get(self: Self) ?T {
            return self.value;
        }

        /// Replace the session. Takes effect on this response, as one
        /// `Set-Cookie`.
        pub fn set(self: Self, value: T) !void {
            return self.setWith(value, .{});
        }

        /// The same, with the cookie's attributes your own — a `max_age` so
        /// the session outlives the browser being closed, usually.
        pub fn setWith(self: Self, value: T, options: Options) !void {
            const c = self._c orelse return fail.internal(
                "a Session was set outside a request, so there is no response to put the cookie " ++
                    "on. A test that means to check what was written drives the App with " ++
                    "zfast.testing.Client.",
                .{},
            );
            const key = c._session_key orelse return fail.internal(
                "a handler set a Session and no secret was set. Pass one to listen(): " ++
                    "`.session_secret = my_secret` — {d} bytes, the same on every instance.",
                .{key_len},
            );
            var buf: Sealed(T) = undefined;
            const text = try seal(T, value, key.*, &buf);
            try c.setCookie(.{
                .name = cookie_name,
                .value = text,
                .path = options.path,
                .domain = options.domain,
                .max_age = options.max_age,
                .secure = options.secure,
                .http_only = true,
                .same_site = options.same_site,
            });
        }

        /// Sign out. The cookie is deleted rather than emptied, because an
        /// empty one still round-trips and still has to be decrypted.
        pub fn clear(self: Self) !void {
            return self.clearWith(.{});
        }

        pub fn clearWith(self: Self, options: Clearing) !void {
            const c = self._c orelse return fail.internal(
                "a Session was cleared outside a request, so there is no response to put the " ++
                    "deletion on.",
                .{},
            );
            try c.clearCookie(.{
                .name = cookie_name,
                .path = options.path,
                .domain = options.domain,
            });
        }
    };
}

/// The cookie attributes a session may choose. Deliberately fewer than
/// `Cookie` has: `http_only` is not here because a session a script can read
/// is a session an injected script can send somewhere, and `name` is not here
/// because there is one session.
pub const Options = struct {
    path: []const u8 = "/",
    domain: []const u8 = "",
    /// Null is a session cookie — gone when the browser closes, which is what
    /// a sign-in usually wants. Set it to keep somebody signed in.
    max_age: ?i64 = null,
    secure: bool = true,
    same_site: cookie_mod.SameSite = .lax,
};

pub const Clearing = struct {
    path: []const u8 = "/",
    domain: []const u8 = "",
};

// ---- tests ----

const testing = std.testing;

const key_a: Key = @splat(0xA5);
const key_b: Key = @splat(0x5A);

const Signed = struct {
    user: u32,
    admin: bool = false,
};

test "what is sealed comes back" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7, .admin = true }, key_a, &buf);

    const back = open(Signed, text, key_a).?;
    try testing.expectEqual(@as(u32, 7), back.user);
    try testing.expect(back.admin);
}

test "the cookie value is something a cookie may hold" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 1 }, key_a, &buf);

    // Base64's alphabet is inside RFC 6265's `cookie-octet`, but that is the
    // sort of thing that is true until somebody changes the encoding.
    try cookie_mod.check(.{ .name = cookie_name, .value = text });
}

test "a different secret does not open it" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7 }, key_a, &buf);
    try testing.expect(open(Signed, text, key_b) == null);
}

test "a changed byte does not open it" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7 }, key_a, &buf);

    // Every position, not a chosen one: this is the property the tag exists
    // for, and testing one byte would pass with half a cipher.
    for (0..text.len) |i| {
        var broken: Sealed(Signed) = undefined;
        @memcpy(&broken, text);
        // Base64 is 4-bytes-to-3, so flipping to a character outside the
        // alphabet would be caught by the decoder rather than by the tag.
        // Rotating within the alphabet is the harder test.
        broken[i] = if (broken[i] == 'A') 'B' else 'A';
        try testing.expect(open(Signed, &broken, key_a) == null);
    }
}

test "rubbish does not open it" {
    try testing.expect(open(Signed, "", key_a) == null);
    try testing.expect(open(Signed, "not base64 at all!!", key_a) == null);
    try testing.expect(open(Signed, "AAAA", key_a) == null);
    // The right length, the wrong contents.
    var zeros: Sealed(Signed) = @splat('A');
    try testing.expect(open(Signed, &zeros, key_a) == null);
}

test "a session written to a different shape is ignored rather than misread" {
    // The failure this exists to stop: add a field, deploy, and every cookie
    // already out there decodes as something plausible and wrong.
    const Before = struct { user: u32 };
    const After = struct { user: u32, tenant: u32 };

    var buf: Sealed(Before) = undefined;
    const text = try seal(Before, .{ .user = 7 }, key_a, &buf);

    try testing.expect(open(After, text, key_a) == null);
    // And the same shape by another name still reads, because the name is
    // not part of what a cookie means.
    const AlsoBefore = struct { user: u32 };
    try testing.expectEqual(@as(u32, 7), open(AlsoBefore, text, key_a).?.user);
}

test "reordering two fields of the same type is a different shape" {
    // The case a size check alone would miss: both are 8 bytes, and reading
    // one as the other silently swaps two ids.
    const One = struct { user: u32, tenant: u32 };
    const Other = struct { tenant: u32, user: u32 };

    var buf: Sealed(One) = undefined;
    const text = try seal(One, .{ .user = 7, .tenant = 9 }, key_a, &buf);
    try testing.expect(open(Other, text, key_a) == null);
}

test "every kind of field a session may hold survives the round trip" {
    const Role = enum(u8) { guest, member, admin };
    const Everything = struct {
        n8: u8,
        n64: i64,
        f: f64,
        yes: bool,
        role: Role,
        name: [16]u8,
        maybe: ?u32,
        nothing: ?u32,
        nested: struct { a: u16, b: bool },
    };

    const sent = Everything{
        .n8 = 200,
        .n64 = -1234567890,
        .f = 3.5,
        .yes = true,
        .role = .admin,
        .name = "nevindra\x00\x00\x00\x00\x00\x00\x00\x00".*,
        .maybe = 42,
        .nothing = null,
        .nested = .{ .a = 513, .b = false },
    };

    var buf: Sealed(Everything) = undefined;
    const back = open(Everything, try seal(Everything, sent, key_a, &buf), key_a).?;

    try testing.expectEqual(sent.n8, back.n8);
    try testing.expectEqual(sent.n64, back.n64);
    try testing.expectEqual(sent.f, back.f);
    try testing.expectEqual(sent.yes, back.yes);
    try testing.expectEqual(sent.role, back.role);
    try testing.expectEqualStrings(&sent.name, &back.name);
    try testing.expectEqual(sent.maybe, back.maybe);
    try testing.expectEqual(sent.nothing, back.nothing);
    try testing.expectEqual(sent.nested.a, back.nested.a);
    try testing.expectEqual(sent.nested.b, back.nested.b);
}

test "an absent optional carries no information about what was there" {
    // The payload slot is written whatever the tag says, so two sessions
    // differing only in a null do not differ in length — a length that moved
    // with the data would leak it through the cookie.
    const Holder = struct { maybe: ?u64 };
    var a: Sealed(Holder) = undefined;
    var b: Sealed(Holder) = undefined;
    const with = try seal(Holder, .{ .maybe = 12345 }, key_a, &a);
    const without = try seal(Holder, .{ .maybe = null }, key_a, &b);
    try testing.expectEqual(with.len, without.len);
}

test "the size is worked out at compile time and matches what is written" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 1 }, key_a, &buf);
    try testing.expectEqual(cookieSize(Signed), text.len);

    // 1 version + 4 shape + 4 user + 1 admin
    try testing.expectEqual(@as(usize, 10), plainSize(Signed));
    try testing.expectEqual(@as(usize, 5), sizeOf(Signed));
}

test "a secret has to be the cipher's key length" {
    try testing.expectError(error.SessionSecretWrongLength, checkSecret("too short"));
    try testing.expectError(error.SessionSecretWrongLength, checkSecret("x" ** (key_len + 1)));
    const key = try checkSecret("x" ** key_len);
    try testing.expectEqual(@as(u8, 'x'), key[0]);
}

test "two seals of the same value differ, because the nonce does" {
    var a: Sealed(Signed) = undefined;
    var b: Sealed(Signed) = undefined;
    const first = try seal(Signed, .{ .user = 7 }, key_a, &a);
    const second = try seal(Signed, .{ .user = 7 }, key_a, &b);
    try testing.expect(!std.mem.eql(u8, first, second));
    // And both still open.
    try testing.expectEqual(@as(u32, 7), open(Signed, first, key_a).?.user);
    try testing.expectEqual(@as(u32, 7), open(Signed, second, key_a).?.user);
}

// ---- through a real request ----
//
// The tests above are about the bytes. These are about the wiring: that a
// handler asking for a `Session(T)` gets one, that `set` reaches the response
// as a `Set-Cookie`, and that the cookie a browser sends back arrives as the
// value that was put in it. A round trip through the App is the only thing
// that proves the resolver, the Ctx field and the cookie writer agree.

const App = @import("app.zig").App;
const zfast_testing = @import("testing.zig");

const Signed2 = struct { user: u32, admin: bool = false };

fn signInHandler(s: Session(Signed2)) !void {
    try s.set(.{ .user = 7, .admin = true });
}

fn whoHandler(s: Session(Signed2)) !?Signed2 {
    return s.get();
}

fn signOutHandler(s: Session(Signed2)) !void {
    try s.clear();
}

/// An App wired the way `listen()` would wire it, without listening. Setting
/// the key directly is what a test does instead of passing
/// `.session_secret`; `tryListen` is the thing that checks its length, and
/// that is tested separately.
fn appWithSession(gpa: std.mem.Allocator) App {
    var app = App.init(gpa);
    app.session_key = key_a;
    return app;
}

test "a handler sets a session and it leaves as a Set-Cookie" {
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", signInHandler);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.post(&app, "/sign-in", "");
    try testing.expectEqual(@as(u16, 200), answer.status);

    const header = answer.setCookie(cookie_name).?;
    // The safe attributes, without the handler having asked for them.
    try testing.expect(std.mem.indexOf(u8, header, "HttpOnly") != null);
    try testing.expect(std.mem.indexOf(u8, header, "Secure") != null);
    try testing.expect(std.mem.indexOf(u8, header, "SameSite=Lax") != null);
}

test "the cookie a browser sends back arrives as the value that was put in it" {
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", signInHandler);
    try app.get("/who", whoHandler);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    // Take the cookie off the first response the way a browser would: the
    // pair, and none of the attributes.
    const header = (try client.post(&app, "/sign-in", "")).setCookie(cookie_name).?;
    const pair = header[0 .. std.mem.indexOfScalar(u8, header, ';') orelse header.len];

    var request: [4096]u8 = undefined;
    const answer = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "GET /who HTTP/1.1\r\nHost: test\r\nCookie: {s}\r\n\r\n",
        .{pair},
    ));

    try testing.expectEqual(@as(u16, 200), answer.status);
    var body: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"user\":7,\"admin\":true}", try answer.text(&body));
}

test "no cookie is no session, and a handler says so with a 404" {
    // `?T` returning null is a 404 — the session being absent is not an
    // error, it is a person who has not signed in.
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.get("/who", whoHandler);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectEqual(@as(u16, 404), (try client.get(&app, "/who")).status);
}

test "a cookie sealed under another secret is no session rather than an error" {
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.get("/who", whoHandler);

    var buf: Sealed(Signed2) = undefined;
    const forged = try seal(Signed2, .{ .user = 1, .admin = true }, key_b, &buf);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    var request: [4096]u8 = undefined;
    const answer = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "GET /who HTTP/1.1\r\nHost: test\r\nCookie: {s}={s}\r\n\r\n",
        .{ cookie_name, forged },
    ));
    // Not a 500 and not an admin: a 404, exactly as if nothing was sent.
    try testing.expectEqual(@as(u16, 404), answer.status);
}

test "clearing sends a deletion the browser will act on" {
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.post("/sign-out", signOutHandler);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const header = (try client.post(&app, "/sign-out", "")).setCookie(cookie_name).?;
    try testing.expect(std.mem.indexOf(u8, header, "Max-Age=0") != null);
}

test "asking for a session with no secret set fails with a message, not a wrong answer" {
    // The one case that must not quietly work. A default key would be a key
    // every reader of this repository has.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", whoHandler);

    var client = try zfast_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectEqual(@as(u16, 500), (try client.get(&app, "/who")).status);
}

test "a handler taking a session is still an ordinary function" {
    // ADR 0003's promise, held for this argument type too: no request, no
    // cookie, no server — the handler is a function of what it was given.
    try testing.expectEqual(@as(u32, 7), (try whoHandler(.{ .value = .{ .user = 7 } })).?.user);
    try testing.expect(try whoHandler(.{ .value = null }) == null);
}

test "setting a session outside a request says so rather than doing nothing" {
    // The other half of the shape above. `_c` defaults to null so a read
    // handler is callable; a *write* with nowhere to write has to be an
    // error, or a test would watch it silently succeed and prove nothing.
    var in_flight = fail.InFlight{};
    in_flight.startRequest("POST", "/sign-in");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    const s: Session(Signed2) = .{ .value = null };
    try testing.expectError(error.Failed, s.set(.{ .user = 7 }));
    try testing.expectError(error.Failed, s.clear());
}

test "a session does not turn up in the API description as a request body" {
    // A resolved value is not request data, and the rule that decides what a
    // handler argument means is the same rule the document is written from —
    // so a `Session(T)` read as a body would document an endpoint that takes
    // JSON it never reads. Cheap to check, and the kind of thing that would
    // otherwise be found by somebody generating a client.
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.get("/who", whoHandler);
    app.docs(.{ .title = "test" });

    var client = try zfast_testing.Client.init(testing.allocator, .{ .response_bytes = 64 * 1024 });
    defer client.deinit();

    const answer = try client.get(&app, "/openapi.json");
    try testing.expectEqual(@as(u16, 200), answer.status);

    var body: [32 * 1024]u8 = undefined;
    const text = try answer.text(&body);
    try testing.expect(std.mem.indexOf(u8, text, "requestBody") == null);
}

test "a session is a resolved value, so it is worked out once per request" {
    // Not measured by counting decryptions here: that a resolved value is
    // memoised is `resolve.zig`'s test, and repeating it would be testing
    // that module twice. What this pins is the part that is this module's —
    // that `Session(T)` carries the marker at all. A plain struct would
    // silently be read as a request body instead, which is a very different
    // endpoint and still compiles.
    try testing.expect(@import("resolve.zig").isResolved(Session(Signed2)));
}

test "the session is not readable by whoever is holding it" {
    // The property that separates this from a signed-but-plain cookie: the
    // client can see that it has a session and not what is in it.
    const Secretive = struct { user: u32, salary: u64 };
    var buf: Sealed(Secretive) = undefined;
    const text = try seal(Secretive, .{ .user = 7, .salary = 123456789 }, key_a, &buf);

    var plain: [8]u8 = undefined;
    std.mem.writeInt(u64, &plain, 123456789, .little);
    try testing.expect(std.mem.indexOf(u8, text, &plain) == null);
}
