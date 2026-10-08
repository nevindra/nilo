//! Sessions: state the *client* holds, sealed so it cannot read or change it.
//!
//! ```zig
//! const Signed = struct { user: u32, admin: bool = false };
//!
//! fn signIn(s: nilo.Session(Signed), form: nilo.Form(Login)) !nilo.Redirect(303) {
//!     const id = try accounts.check(form) orelse return .to("/login?wrong");
//!     try s.set(.{ .user = id });
//!     return .to("/");
//! }
//!
//! fn me(s: nilo.Session(Signed)) !?Profile {
//!     const signed = s.get() orelse return null;   // null → 404
//!     return profiles.find(signed.user);
//! }
//! ```
//!
//! **Nothing is stored on the server.** The whole session is serialised,
//! encrypted and signed with `XChaCha20Poly1305`, and handed back as one
//! cookie. That is the reason to prefer this over an id pointing at a store
//! rather than a detail of how it is written: there is no table, no expiry
//! sweep, no lock, and nothing added to the 4,669 bytes an idle connection
//! holds ([ADR 017](../docs/adr/017-the-trade-budget-has-four-axes.md)).
//! A request that does not ask for a session runs the code it ran before.
//!
//! **No sweep is not no expiry.** The seal carries the moment it stops
//! opening, and `open` refuses it after that
//! ([ADR 033](../docs/adr/033-a-session-is-sealed-into-the-cookie.md)).
//! It has to be inside the seal: the cookie's own `Max-Age` is advice to a
//! browser, and a copy of the cookie taken off the wire does not take advice.
//! `Options.max_age` sets both, and `default_max_age` is the ceiling when
//! nobody sets either.
//!
//! The cipher comes from `std.crypto`, so this costs no dependency and does
//! not reopen [ADR 027](../docs/adr/027-tls-is-terminated-in-front.md)'s
//! refusal of one-person crypto. The shape is jetzig's; it is the one design
//! in that framework nilo had no answer to.
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
//! [ADR 015](../docs/adr/015-resolved-values-are-declared-by-their-type.md)
//! draws.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const cookie_mod = @import("cookie.zig");
const ctx_mod = @import("ctx.zig");
const fail = @import("fail.zig");
const naming = @import("names.zig");
const core = @import("nilo_core");

const Ctx = ctx_mod.Ctx;
const Cipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

/// How long the secret has to be. Not a number nilo picked — it is the
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
        "nilo: the session key is no longer 32 bytes; `Ctx._session_key` has to be changed to match.",
    );
}

/// The name of the cookie. One per application: a second `Session(T)` of a
/// different `T` would write over the first, and the shape check below is
/// what turns that from a silent misread into an ignored cookie.
///
/// **`__Host-session` whenever the cookie's attributes allow it**, which the
/// defaults do: `Secure`, `Path=/` and no `Domain`. A browser keeps a
/// `__Host-` cookie only from this host over HTTPS, so a page on a sibling
/// subdomain cannot plant one; a plain `session` it could, with
/// `Domain=example.com; Path=/account`, and the browser sent that one first
/// under `/account`, so the victim worked inside the attacker's account.
/// `cookie_name` is what a session with a `domain`, another `path` or
/// `secure = false` is written as, and what 0.6.0 and earlier wrote.
pub const host_cookie_name = "__Host-session";
pub const cookie_name = "session";

/// The name a session with these attributes is written under.
pub fn nameFor(secure: bool, path: []const u8, domain: []const u8) []const u8 {
    if (secure and domain.len == 0 and std.mem.eql(u8, path, "/")) return host_cookie_name;
    return cookie_name;
}

/// What a browser will actually keep. RFC 6265 asks for at least 4096 bytes
/// per cookie *including the name and the attributes*, and browsers hold
/// close to that and no more. Past it the cookie is dropped — with no error,
/// no warning and a session that simply never appears — so the margin here is
/// for `session=`, `; Path=/; Secure; HttpOnly; SameSite=Lax`, and room to
/// add an attribute later without turning a working app into a broken one.
pub const max_cookie_bytes = 3800;

/// The format the plaintext is in, so a future change to the layout can be
/// told from a cookie written before it.
///
/// **2 since the seal carries its own expiry** (ADR 033). The size check in
/// `open` would already refuse a version-1 cookie, because the plaintext grew
/// by eight bytes — this is the guard that says *why* rather than the one that
/// happens to catch it.
const format_version: u8 = 2;

/// How long a session is good for when `Options.max_age` does not say.
///
/// **`Max-Age` is advice to a browser and the seal is the only thing that
/// binds** (ADR 033). A session cookie — `max_age = null` — asks the browser
/// to forget it when the window closes, and a browser will; a copy of the
/// cookie taken off the wire or out of a backup will not, and before the seal
/// carried an expiry that copy opened forever.
///
/// So there is a ceiling whether or not anybody set one, and 24 hours is it:
/// long enough that nobody working a normal day is signed out under them,
/// short enough that a leaked cookie is a problem with an end. It is a
/// **ceiling on a copy rather than a target** — an application that wants a
/// session to last a month says `.max_age = 30 * 24 * 60 * 60`, and gets it
/// in the cookie and in the seal from one number.
pub const default_max_age: i64 = 24 * 60 * 60;

/// Where the sealed bytes start once the nonce is out of the way.
const overhead = Cipher.nonce_length + Cipher.tag_length;

/// How many fallback secrets a session may still be opened under.
///
/// **Each one is one more decryption for every cookie the current secret does
/// not open** (ADR 225): a cookie sealed before the rotation, and a forged or
/// stale one of the right length. A refused decryption measured 270ns, so
/// three bound a forged cookie at about 1.1µs. An old secret needs to stay a
/// fallback for one `max_age` and no longer, so needing a fourth means
/// rotating faster than a session lasts, and the answer to that is a shorter
/// `max_age`.
pub const max_fallbacks = 3;

pub const Error = error{
    /// The secret, or one of the fallbacks, is not `key_len` bytes.
    SessionSecretWrongLength,
    /// Fallback secrets were given with no secret to seal under.
    SessionSecretMissing,
    /// A fallback secret is the current one, or another fallback.
    SessionSecretRepeated,
    /// More than `max_fallbacks` fallback secrets.
    SessionSecretsTooMany,
};

// ---- what a session may hold ----

/// The plaintext size of `T`: a version byte, the shape fingerprint, the
/// expiry, and the fields. Settled while compiling, which is what makes the
/// cookie ceiling checkable at all.
///
/// The expiry is eight bytes of the 3,800 a cookie has (ADR 033) — seconds
/// rather than milliseconds because a session measured to the millisecond is
/// a session nobody asked for, and seconds is what `Max-Age` counts anyway.
pub fn plainSize(comptime T: type) usize {
    return 1 + 4 + 8 + sizeOf(T);
}

/// Where the fields start, once the header is out of the way. Named because
/// three functions index past it and three copies of `13` is how a format
/// drifts.
const header_size = 1 + 4 + 8;

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
            // `inline`: the field types are `type`s, which do not
            // exist at runtime, so an ordinary loop over them is a compile
            // error rather than slow code.
            inline for (s.field_types) |f_type| total += sizeOf(f_type);
            break :blk total;
        },
        else => unsupported(T, "not something a session can carry"),
    };
}

fn unsupported(comptime T: type, comptime why: []const u8) noreturn {
    @compileError(
        "nilo: `" ++ naming.of(T) ++ "` cannot be part of a session, because it is " ++ why ++ ".\n" ++
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
                for (s.field_names, s.field_types) |f_name, f_type| {
                    hasher.update(f_name);
                    hasher.update(":");
                    describe(f_type, hasher);
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
                for (e.field_values) |f_value| hasher.update(std.fmt.comptimePrint("{d};", .{f_value}));
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
            const Bits = @Int(.unsigned, f.bits);
            std.mem.writeInt(Bits, out[at..][0 .. f.bits / 8], @bitCast(value), .little);
            at += f.bits / 8;
        },
        .@"enum" => |e| at += encode(e.tag_type, @backingInt(value), out[at..]),
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
            inline for (s.field_names, s.field_types) |f_name, f_type| at += encode(f_type, @field(value, f_name), out[at..]);
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
            const Bits = @Int(.unsigned, f.bits);
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
            inline for (s.field_names, s.field_types) |f_name, f_type| {
                const got = try decode(f_type, in[at..]);
                @field(v, f_name) = got.value;
                at += got.used;
            }
            return .{ .value = v, .used = at };
        },
        else => comptime unsupported(T, "not something a session can carry"),
    }
}

// ---- sealing ----

/// `value` as a cookie value: version, shape, expiry, fields, encrypted under
/// a fresh random nonce, then base64.
///
/// `expires_at` is **seconds since the epoch, absolute** rather than a
/// duration, and that is what keeps this function pure: the clock is read by
/// `Session.setWith`, one layer up, so every arm of the expiry rule can be run
/// from a test that names its own times instead of one that waits
/// ([ADR 032](../docs/adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)).
/// An expiry check that could only be seen to pass would be exactly the guard
/// that ADR is about.
///
/// The buffer is the caller's, so this allocates nothing. `Sealed(T)` is the
/// exact array to hand it.
pub fn seal(comptime T: type, value: T, expires_at: i64, key: Key, out: []u8) ![]const u8 {
    var plain: [plainSize(T)]u8 = undefined;
    plain[0] = format_version;
    std.mem.writeInt(u32, plain[1..5], comptime fingerprint(T), .little);
    // Inside the seal, so it is covered by the tag: an expiry a client could
    // edit is not an expiry. This is the whole reason it does not live in the
    // cookie's own `Max-Age`, which is the client's to ignore.
    std.mem.writeInt(i64, plain[5..13], expires_at, .little);
    _ = encode(T, value, plain[header_size..]);

    var raw: [plainSize(T) + overhead]u8 = undefined;
    const nonce = raw[0..Cipher.nonce_length];
    // A random nonce rather than a counter: there is nowhere to keep a
    // counter. XChaCha20's nonce is 192 bits precisely so that random is
    // safe — the birthday bound is out of reach of any number of sessions a
    // server will ever write.
    //
    // Through the Bulkhead rather than `std.crypto.random`, because this is
    // a syscall and a syscall made straight from a fiber stops every request
    // sharing its thread (ADR 001, ADR 013).
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
    return openAt(T, text, key, nowSeconds());
}

/// `open`, against a time the caller names rather than the clock.
///
/// **The pure half, and it is here so the expiry can be seen to fail.** A
/// check that can only be exercised by waiting a day is a check that will only
/// ever be seen to pass, which is the shape
/// [ADR 032](../docs/adr/032-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
/// exists to refuse. Every arm below is reached by a test naming two numbers.
///
/// It is also what a test of an application's own can use to stand a session
/// at any age it likes without moving the machine's clock.
pub fn openAt(comptime T: type, text: []const u8, key: Key, now: i64) ?T {
    return openAmong(T, text, key, &.{}, now);
}

/// `openAt`, trying the fallback secrets after the current one (ADR 225).
///
/// **The current secret first, and the fallbacks only when it fails**, so a
/// cookie sealed since the rotation, which is nearly every cookie, costs what
/// it cost before there were fallback secrets. There is no key id in the cookie
/// to pick one by: adding one would change the format, and a format change
/// signs everybody out, which is the thing rotating is meant not to do.
///
/// The cookie is decoded once and each key is one decryption. A cookie that
/// decrypts is then held to the version, the shape and the expiry exactly as
/// one under the current secret is: a fallback changes which key opens
/// a cookie, never how long it lives.
fn openAmong(comptime T: type, text: []const u8, key: Key, fallbacks: []const Key, now: i64) ?T {
    const sealed_len = std.base64.standard.Decoder.calcSizeForSlice(text) catch return null;
    if (sealed_len != plainSize(T) + overhead) return null;

    var raw: [plainSize(T) + overhead]u8 = undefined;
    std.base64.standard.Decoder.decode(&raw, text) catch return null;

    var plain: [plainSize(T)]u8 = undefined;
    const nonce = raw[0..Cipher.nonce_length];
    const body = raw[Cipher.nonce_length..][0..plain.len];
    const tag = raw[Cipher.nonce_length + plain.len ..][0..Cipher.tag_length];
    opened: {
        Cipher.decrypt(&plain, body, tag.*, "", nonce.*, key) catch {
            for (fallbacks) |fallback| {
                Cipher.decrypt(&plain, body, tag.*, "", nonce.*, fallback) catch continue;
                break :opened;
            }
            return null;
        };
    }

    if (plain[0] != format_version) return null;
    if (std.mem.readInt(u32, plain[1..5], .little) != comptime fingerprint(T)) return null;
    // Read after the tag has been verified, so this is a number the server
    // wrote rather than one a client chose. An expired session is `null` for
    // the reason every other failure here is: the application has one thing to
    // do about all of them, and "nearly signed in" is not a state worth
    // offering it.
    if (std.mem.readInt(i64, plain[5..13], .little) <= now) return null;

    const got = decode(T, plain[header_size..]) catch return null;
    return got.value;
}

/// Seconds since the epoch — what an expiry is counted in.
///
/// `nilo_core`'s clock, which is a read from a page the kernel keeps mapped
/// and needs no event loop (ADR 041). Read once per request that carries a
/// session cookie, and not at all by one that does not.
fn nowSeconds() i64 {
    return @divFloor(core.nowMillis(), std.time.ms_per_s);
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

/// The fallback secrets, checked and copied into `into`, asked at `listen()`
/// beside `checkSecret` (ADR 225).
///
/// Each is refused for the reason the current one would be, and two more
/// things are refused because they are a rotation that did not happen: a
/// fallback that is the current secret, and one listed twice. Both would
/// work, and both would leave somebody believing an old secret had stopped
/// sealing when it had not, or paying a decryption for nothing.
///
/// It takes the current key as optional because fallback secrets with none to
/// seal under are refused too: they would open cookies nothing can seal any
/// more, which is a rotation with its first half missing.
pub fn checkFallbacks(
    current: ?Key,
    fallbacks: []const []const u8,
    into: *[max_fallbacks]Key,
) Error![]const Key {
    if (fallbacks.len == 0) return &.{};
    const key = current orelse return error.SessionSecretMissing;
    if (fallbacks.len > max_fallbacks) return error.SessionSecretsTooMany;
    for (fallbacks, 0..) |secret, i| {
        into[i] = try checkSecret(secret);
        if (std.mem.eql(u8, &into[i], &key)) return error.SessionSecretRepeated;
        for (into[0..i]) |earlier| {
            if (std.mem.eql(u8, &into[i], &earlier)) return error.SessionSecretRepeated;
        }
    }
    return into[0..fallbacks.len];
}

// ---- the handler-facing type ----

/// The session, asked for by writing it in a handler's argument list.
///
/// A resolved value like any other
/// ([ADR 015](../docs/adr/015-resolved-values-are-declared-by-their-type.md)),
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
            "nilo: the `Session(" ++ naming.of(T) ++ ")` is not a struct.\n" ++
                "  A session is a struct of your own, one field per thing you want to remember:\n" ++
                "      const Signed = struct { user: u32, admin: bool = false };",
        );
        if (@typeInfo(T).@"struct".field_names.len == 0) @compileError(
            "nilo: the `Session(" ++ naming.of(T) ++ ")` has no fields, so it would remember " ++
                "nothing.",
        );
        _ = sizeOf(T);
        if (cookieSize(T) > max_cookie_bytes) @compileError(std.fmt.comptimePrint(
            "nilo: a `Session(" ++ naming.of(T) ++ ")` would be {d} bytes in the cookie, and the " ++
                "most that fits is {d}.\n" ++
                "  A browser drops a cookie this big without saying so, which would look like a " ++
                "session that never works rather than one that is too large.\n" ++
                "  Keep an id in the session and look the rest up.",
            .{ cookieSize(T), max_cookie_bytes },
        ));
    }

    return struct {
        const Self = @This();

        pub const nilo_resolve = read;

        /// Who the caller is, so a `Cached` route may not take it: its
        /// answer would be served to the next caller (`cached.readsTheCaller`).
        pub const nilo_reads_caller = true;

        /// What a nilo compile error calls this type, which is the name the
        /// reader's own import line gives it (ADR 074).
        pub const nilo_type_name = "nilo.Session(" ++ naming.of(T) ++ ")";

        /// What arrived, if anything readable did.
        value: ?T,

        /// Held so `set` and `clear` have somewhere to write. Underscored
        /// like every other field a caller has no business touching.
        ///
        /// Optional, and defaulted, so that a handler taking a session is
        /// still an ordinary function a test can call (ADR 002):
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
            // The prefixed name first, so a planted `session` never wins over
            // one this host set. The plain name only where the program said
            // it writes one: read always, it is a session a sibling subdomain
            // can plant for a visitor who has no prefixed one to lose to.
            const plain = if (c._session_plain) c.cookie(cookie_name) else null;
            const text = c.cookie(host_cookie_name) orelse plain orelse
                return .{ .value = null, ._c = c };
            return .{
                .value = openAmong(T, text.view(), key.*, c._session_fallbacks.*, nowSeconds()),
                ._c = c,
            };
        }

        /// What the client sent, or null if it sent nothing nilo could read.
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
                    "nilo.testing.Client.",
                .{},
            );
            const key = c._session_key orelse return fail.internal(
                "a handler set a Session and no secret was set. Pass one to listen(): " ++
                    "`.session_secret = my_secret` — {d} bytes, the same on every instance.",
                .{key_len},
            );
            // One number fills both halves: the browser is asked to forget the
            // cookie at `max_age`, and the seal stops opening at the same
            // moment whether the browser obliged or not (ADR 033).
            const lives_for = options.max_age orelse default_max_age;
            var buf: Sealed(T) = undefined;
            const text = try seal(T, value, nowSeconds() + lives_for, key.*, &buf);
            const name = nameFor(options.secure, options.path, options.domain);
            // A cookie this server will not read back is a sign-in that
            // works once and never again, so it is refused where it is made.
            if (name.ptr == cookie_name.ptr and !c._session_plain) return fail.internal(
                "a Session set with a domain, a path other than / or secure = false is written " ++
                    "as `session`, which a browser refuses under the `__Host-` prefix, and this " ++
                    "server does not read that name. Pass `.session_plain_name = true` to listen().",
                .{},
            );
            try c.setCookie(.{
                .name = name,
                .value = text,
                .path = options.path,
                .domain = options.domain,
                .max_age = options.max_age,
                .secure = options.secure,
                .http_only = true,
                .same_site = options.same_site,
            });
            // A session moving to the prefixed name leaves the plain one it
            // came in under behind, and a stale copy is one more cookie to
            // open on every request until it expires. Only when one came in,
            // so a session that has always been prefixed sends one header.
            if (name.ptr == host_cookie_name.ptr and c.cookie(cookie_name) != null) {
                try c.clearCookie(.{ .name = cookie_name });
            }
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
            // Both names: signing out has to reach a session written before
            // the prefix as well as one written after it.
            if (options.domain.len == 0 and std.mem.eql(u8, options.path, "/")) {
                try c.clearCookie(.{ .name = host_cookie_name });
            }
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
    /// How long the session lives, in seconds — **in the cookie and inside
    /// the seal** (ADR 033). Set it to keep somebody signed in past the
    /// browser closing.
    ///
    /// Null is a session cookie: the browser is asked to forget it at the end
    /// of the window, and the seal stops opening after `default_max_age`. Null
    /// does not mean "forever" and never safely could — `Max-Age` is advice a
    /// copy of the cookie does not take.
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

/// An expiry far enough out that a test about something else never trips over
/// it: 2100-01-01. The tests that are about the expiry name their own times
/// (`openAt`), which is the point of that function existing.
const far_future: i64 = 4_102_444_800;

const Signed = struct {
    user: u32,
    admin: bool = false,
};

test "what is sealed comes back" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7, .admin = true }, far_future, key_a, &buf);

    const back = open(Signed, text, key_a).?;
    try testing.expectEqual(@as(u32, 7), back.user);
    try testing.expect(back.admin);
}

test "a session stops opening the moment its expiry passes" {
    const signed_at: i64 = 1_800_000_000;
    const good_for: i64 = 60 * 60;

    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7 }, signed_at + good_for, key_a, &buf);

    // The whole hour it was given, right up to the last second of it.
    try testing.expectEqual(@as(u32, 7), openAt(Signed, text, key_a, signed_at).?.user);
    try testing.expectEqual(
        @as(u32, 7),
        openAt(Signed, text, key_a, signed_at + good_for - 1).?.user,
    );

    // And nothing after it. **This is the arm that could not be reached
    // before**: an expiry only a wall clock could pass is a guard that would
    // never be seen to fail (ADR 032).
    try testing.expect(openAt(Signed, text, key_a, signed_at + good_for) == null);
    try testing.expect(openAt(Signed, text, key_a, signed_at + good_for + 1) == null);
    try testing.expect(openAt(Signed, text, key_a, signed_at + 10 * good_for) == null);
}

test "an expiry is inside the seal, so editing the cookie cannot move it" {
    const now: i64 = 1_800_000_000;
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7 }, now - 1, key_a, &buf);

    // Expired. Every single-byte edit of the cookie is either the same
    // expired session or nothing at all — never a live one, because the
    // expiry is covered by the tag rather than sitting beside it.
    try testing.expect(openAt(Signed, text, key_a, now) == null);
    for (0..text.len) |i| {
        var tampered: Sealed(Signed) = undefined;
        @memcpy(&tampered, text);
        tampered[i] = if (tampered[i] == 'A') 'B' else 'A';
        try testing.expect(openAt(Signed, &tampered, key_a, now) == null);
    }
}

test "a cookie written before the expiry existed is ignored, not misread" {
    // Version 1's plaintext was `[version][fingerprint][fields]` with no
    // expiry, so it is eight bytes shorter. A cookie in somebody's browser
    // across the upgrade has to come back as "no session" rather than as a
    // session whose first eight field bytes are read as a date.
    const v1_plain_size = 1 + 4 + @sizeOf(u32) + 1;
    try testing.expectEqual(v1_plain_size + 8, plainSize(Signed));

    var raw: [v1_plain_size + overhead]u8 = undefined;
    var plain: [v1_plain_size]u8 = undefined;
    plain[0] = 1;
    std.mem.writeInt(u32, plain[1..5], comptime fingerprint(Signed), .little);
    _ = encode(Signed, .{ .user = 7 }, plain[5..]);

    const nonce = raw[0..Cipher.nonce_length];
    @memset(nonce, 0);
    const body = raw[Cipher.nonce_length..][0..plain.len];
    const tag = raw[Cipher.nonce_length + plain.len ..][0..Cipher.tag_length];
    Cipher.encrypt(body, tag, &plain, "", nonce.*, key_a);

    var text: [std.base64.standard.Encoder.calcSize(raw.len)]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&text, &raw);

    // Refused on its length before the cipher is even asked, which is why the
    // forged tag above does not matter.
    try testing.expect(open(Signed, encoded, key_a) == null);
}

test "the cookie value is something a cookie may hold" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 1 }, far_future, key_a, &buf);

    // Base64's alphabet is inside RFC 6265's `cookie-octet`, but that is the
    // sort of thing that is true until somebody changes the encoding.
    try cookie_mod.check(.{ .name = cookie_name, .value = text });
}

test "a different secret does not open it" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7 }, far_future, key_a, &buf);
    try testing.expect(open(Signed, text, key_b) == null);
}

test "a changed byte does not open it" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7 }, far_future, key_a, &buf);

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
    const text = try seal(Before, .{ .user = 7 }, far_future, key_a, &buf);

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
    const text = try seal(One, .{ .user = 7, .tenant = 9 }, far_future, key_a, &buf);
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
    const back = open(Everything, try seal(Everything, sent, far_future, key_a, &buf), key_a).?;

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
    const with = try seal(Holder, .{ .maybe = 12345 }, far_future, key_a, &a);
    const without = try seal(Holder, .{ .maybe = null }, far_future, key_a, &b);
    try testing.expectEqual(with.len, without.len);
}

test "the size is worked out at compile time and matches what is written" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 1 }, far_future, key_a, &buf);
    try testing.expectEqual(cookieSize(Signed), text.len);

    // 1 version + 4 shape + 8 expiry + 4 user + 1 admin
    try testing.expectEqual(@as(usize, 18), plainSize(Signed));
    try testing.expectEqual(@as(usize, 5), sizeOf(Signed));
    // The header the fields sit behind, spelled out here as well so that
    // moving one of the three without the other is a failing test rather than
    // a cookie format that reads its own expiry out of a user id.
    try testing.expectEqual(@as(usize, 13), header_size);
    try testing.expectEqual(plainSize(Signed), header_size + sizeOf(Signed));
}

test "a secret has to be the cipher's key length" {
    try testing.expectError(error.SessionSecretWrongLength, checkSecret("too short"));
    try testing.expectError(error.SessionSecretWrongLength, checkSecret(&@as([(key_len + 1)]u8, @splat('x'))));
    const key = try checkSecret(&@as([key_len]u8, @splat('x')));
    try testing.expectEqual(@as(u8, 'x'), key[0]);
}

test "two seals of the same value differ, because the nonce does" {
    var a: Sealed(Signed) = undefined;
    var b: Sealed(Signed) = undefined;
    const first = try seal(Signed, .{ .user = 7 }, far_future, key_a, &a);
    const second = try seal(Signed, .{ .user = 7 }, far_future, key_a, &b);
    try testing.expect(!std.mem.eql(u8, first, second));
    // And both still open.
    try testing.expectEqual(@as(u32, 7), open(Signed, first, key_a).?.user);
    try testing.expectEqual(@as(u32, 7), open(Signed, second, key_a).?.user);
}

test "a cookie sealed under a fallback secret still opens, and one under a dropped secret does not" {
    const key_c: Key = @splat(0x3C);
    var buf: Sealed(Signed) = undefined;
    const before = try seal(Signed, .{ .user = 7 }, far_future, key_a, &buf);

    // Rotated from `key_a` to `key_b`, with `key_a` a fallback: the cookie out
    // there keeps working.
    try testing.expectEqual(@as(u32, 7), openAmong(Signed, before, key_b, &.{key_a}, 0).?.user);
    // Behind another fallback too, whatever the order.
    try testing.expectEqual(@as(u32, 7), openAmong(Signed, before, key_b, &.{ key_c, key_a }, 0).?.user);
    // And once `key_a` is dropped, it is no session, like any other secret
    // this server does not hold.
    try testing.expect(openAmong(Signed, before, key_b, &.{key_c}, 0) == null);
    try testing.expect(openAmong(Signed, before, key_b, &.{}, 0) == null);
}

test "a fallback secret opens a cookie until its own expiry and not a second after" {
    // A fallback changes which key opens a cookie and never how long it lives.
    // That is what makes one `max_age` the whole wait before a fallback secret
    // can be dropped: no cookie sealed under it outlives that.
    const signed_at: i64 = 1_800_000_000;
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7 }, signed_at + 60, key_a, &buf);

    try testing.expect(openAmong(Signed, text, key_b, &.{key_a}, signed_at + 59) != null);
    try testing.expect(openAmong(Signed, text, key_b, &.{key_a}, signed_at + 60) == null);
}

test "a cookie under the current secret opens without any fallback being tried" {
    // Not observable through the answer, which would be the same either
    // way, so observed through fallbacks that could not open anything:
    // the cookie opens under the current key and the list is never reached.
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7 }, far_future, key_b, &buf);
    try testing.expectEqual(@as(u32, 7), openAmong(Signed, text, key_b, &.{ key_a, key_a, key_a }, 0).?.user);
}

test "every byte of a cookie under a fallback secret is still covered by its tag" {
    var buf: Sealed(Signed) = undefined;
    const text = try seal(Signed, .{ .user = 7 }, far_future, key_a, &buf);
    for (0..text.len) |i| {
        var broken: Sealed(Signed) = undefined;
        @memcpy(&broken, text);
        broken[i] = if (broken[i] == 'A') 'B' else 'A';
        try testing.expect(openAmong(Signed, &broken, key_b, &.{key_a}, 0) == null);
    }
}

test "fallback secrets are checked the way the current one is, and a rotation that did not happen is refused" {
    var into: [max_fallbacks]Key = undefined;
    const a = &@as([key_len]u8, @splat('a'));
    const b = &@as([key_len]u8, @splat('b'));
    const c = &@as([key_len]u8, @splat('c'));
    const d = &@as([key_len]u8, @splat('d'));
    const current: Key = (&@as([key_len]u8, @splat('n'))).*;

    // No fallbacks is nothing to check, with or without a current key.
    try testing.expectEqual(@as(usize, 0), (try checkFallbacks(null, &.{}, &into)).len);

    const kept = try checkFallbacks(current, &.{ a, b, c }, &into);
    try testing.expectEqual(@as(usize, 3), kept.len);
    try testing.expectEqualStrings(b, &kept[1]);

    try testing.expectError(error.SessionSecretMissing, checkFallbacks(null, &.{a}, &into));
    try testing.expectError(error.SessionSecretsTooMany, checkFallbacks(current, &.{ a, b, c, d }, &into));
    try testing.expectError(error.SessionSecretWrongLength, checkFallbacks(current, &.{ a, "short" }, &into));
    try testing.expectError(error.SessionSecretRepeated, checkFallbacks(current, &.{&@as([key_len]u8, @splat('n'))}, &into));
    try testing.expectError(error.SessionSecretRepeated, checkFallbacks(current, &.{ a, b, a }, &into));
}

// ---- through a real request ----
//
// The tests above are about the bytes. These are about the wiring: that a
// handler asking for a `Session(T)` gets one, that `set` reaches the response
// as a `Set-Cookie`, and that the cookie a browser sends back arrives as the
// value that was put in it. A round trip through the App is the only thing
// that proves the resolver, the Ctx field and the cookie writer agree.

const App = @import("app.zig").App;
const nilo_testing = @import("testing.zig");

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

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.post(&app, "/sign-in", "");
    try testing.expectEqual(@as(u16, 200), answer.status);

    const header = answer.setCookie(host_cookie_name).?;
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

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    // Take the cookie off the first response the way a browser would: the
    // pair, and none of the attributes.
    const header = (try client.post(&app, "/sign-in", "")).setCookie(host_cookie_name).?;
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

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectEqual(@as(u16, 404), (try client.get(&app, "/who")).status);
}

test "a cookie sealed under another secret is no session rather than an error" {
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.get("/who", whoHandler);

    var buf: Sealed(Signed2) = undefined;
    const forged = try seal(Signed2, .{ .user = 1, .admin = true }, far_future, key_b, &buf);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
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

test "after a rotation, the old cookie is still signed in and the new one is sealed under the new secret" {
    // The whole feature, through the App: `key_a` was the secret, `key_b` is
    // now, and `key_a` is its fallback.
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.session_key = key_b;
    app.session_fallbacks = &.{key_a};
    try app.post("/sign-in", signInHandler);
    try app.get("/who", whoHandler);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    var buf: Sealed(Signed2) = undefined;
    const old = try seal(Signed2, .{ .user = 3 }, far_future, key_a, &buf);
    var request: [4096]u8 = undefined;
    const answer = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "GET /who HTTP/1.1\r\nHost: test\r\nCookie: {s}={s}\r\n\r\n",
        .{ host_cookie_name, old },
    ));
    try testing.expectEqual(@as(u16, 200), answer.status);
    var body: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"user\":3,\"admin\":false}", try answer.text(&body));

    // A fallback secret opens and never seals: what `set` writes now opens
    // under `key_b` alone and not under `key_a`.
    const header = (try client.post(&app, "/sign-in", "")).setCookie(host_cookie_name).?;
    const value = header[host_cookie_name.len + 1 .. std.mem.indexOfScalar(u8, header, ';') orelse header.len];
    try testing.expectEqual(@as(u32, 7), open(Signed2, value, key_b).?.user);
    try testing.expect(open(Signed2, value, key_a) == null);
}

test "clearing sends a deletion the browser will act on" {
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.post("/sign-out", signOutHandler);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.post(&app, "/sign-out", "");
    // Both names, so a session written before the prefix is signed out too;
    // the prefixed one carries `Secure`, without which a browser ignores it.
    const plain = answer.setCookie(cookie_name).?;
    try testing.expect(std.mem.indexOf(u8, plain, "Max-Age=0") != null);
    const prefixed = answer.setCookie(host_cookie_name).?;
    try testing.expect(std.mem.indexOf(u8, prefixed, "Max-Age=0") != null);
    try testing.expect(std.mem.indexOf(u8, prefixed, "Secure") != null);
}

test "a session planted under the plain name by a sibling subdomain does not win over this host's" {
    // A page on another subdomain sets `session=<its own valid session>`
    // with `Domain=example.com; Path=/account`, and the browser sends it
    // first there. This host's own is `__Host-session`, which no other host
    // can set, and it is the one read.
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.get("/who", whoHandler);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    var planted_buf: Sealed(Signed2) = undefined;
    const planted = try seal(Signed2, .{ .user = 666 }, far_future, key_a, &planted_buf);
    var own_buf: Sealed(Signed2) = undefined;
    const own = try seal(Signed2, .{ .user = 7 }, far_future, key_a, &own_buf);

    var request: [4096]u8 = undefined;
    const answer = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "GET /who HTTP/1.1\r\nHost: test\r\nCookie: {s}={s}; {s}={s}\r\n\r\n",
        .{ cookie_name, planted, host_cookie_name, own },
    ));
    var body: [256]u8 = undefined;
    try testing.expectEqualStrings("{\"user\":7,\"admin\":false}", try answer.text(&body));
}

test "a session planted under the plain name opens nothing for a visitor who has no prefixed one" {
    // The visitor who is signed out, or never signed in, carries no
    // `__Host-session` for the planted cookie to lose to, so reading the
    // plain name at all is what let a sibling subdomain sign them in as
    // somebody else.
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    try app.get("/who", whoHandler);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    var planted_buf: Sealed(Signed2) = undefined;
    const planted = try seal(Signed2, .{ .user = 666 }, far_future, key_a, &planted_buf);
    var request: [4096]u8 = undefined;
    const answer = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "GET /who HTTP/1.1\r\nHost: test\r\nCookie: {s}={s}\r\n\r\n",
        .{ cookie_name, planted },
    ));
    try testing.expectEqual(@as(u16, 404), answer.status);
}

test "a session written before the prefix still opens, and the next set moves it" {
    var app = appWithSession(testing.allocator);
    defer app.deinit();
    // What a program upgrading from 0.6.0 turns on until its old cookies
    // have expired.
    app.session_plain_name = true;
    try app.post("/sign-in", signInHandler);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    var buf: Sealed(Signed2) = undefined;
    const old = try seal(Signed2, .{ .user = 3 }, far_future, key_a, &buf);
    var request: [4096]u8 = undefined;
    const answer = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "POST /sign-in HTTP/1.1\r\nHost: test\r\nCookie: {s}={s}\r\nContent-Length: 0\r\n\r\n",
        .{ cookie_name, old },
    ));
    try testing.expect(answer.setCookie(host_cookie_name) != null);
    try testing.expect(std.mem.indexOf(u8, answer.setCookie(cookie_name).?, "Max-Age=0") != null);
}

test "a session with a domain, another path or no Secure keeps the plain name" {
    // `__Host-` is refused by a browser on any of the three, so the prefix
    // is only used where it will be kept.
    try testing.expectEqualStrings(host_cookie_name, nameFor(true, "/", ""));
    try testing.expectEqualStrings(cookie_name, nameFor(true, "/", "example.com"));
    try testing.expectEqualStrings(cookie_name, nameFor(true, "/app", ""));
    try testing.expectEqualStrings(cookie_name, nameFor(false, "/", ""));
}

test "asking for a session with no secret set fails with a message, not a wrong answer" {
    // The one case that must not quietly work. A default key would be a key
    // every reader of this repository has.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", whoHandler);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectEqual(@as(u16, 500), (try client.get(&app, "/who")).status);
}

test "a handler taking a session is still an ordinary function" {
    // ADR 002's promise, held for this argument type too: no request, no
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

    var client = try nilo_testing.Client.init(testing.allocator, .{ .response_bytes = 64 * 1024 });
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
    const text = try seal(Secretive, .{ .user = 7, .salary = 123456789 }, far_future, key_a, &buf);

    var plain: [8]u8 = undefined;
    std.mem.writeInt(u64, &plain, 123456789, .little);
    try testing.expect(std.mem.indexOf(u8, text, &plain) == null);
}
