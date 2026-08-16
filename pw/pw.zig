//! nilo_pw — hashing a password, and nothing that needs a loop (ADR 0048).
//!
//! A **tool module**, the third: one job, no event loop, and it imports
//! nothing at all — which is why `zig test pw/pw.zig` runs the whole of it
//! (ADR 0042).
//!
//! ```zig
//! const pw = @import("nilo_pw");
//!
//! const stored = try pw.hash(gpa, form.password, try c.entropy(pw.salt_len));
//! _ = try db.insert(User, conn, .{ .email = form.email, .password = stored.text() });
//! ```
//!
//! and back the other way, where the account may not exist:
//!
//! ```zig
//! const row = try db.find(User, conn, .{ .email = form.email });
//! if (!try pw.verify(gpa, if (row) |r| r.password else null, form.password))
//!     return nilo.fail(401, "that is not a sign-in");
//!
//! // the one moment the plaintext is in hand, and the Cost may have gone up
//! if (try pw.needsRehash(row.?.password, .default)) { … }
//! ```
//!
//! **`pw.huge_pages` is what to hand it for `gpa`.** The 19 MiB is asked for
//! in the 2 MiB pages argon2 walks it in rather than 4,864 of 4 KiB, which is
//! 13.6 ms a hash against 11.0 and nothing held between them (ADR 0049).
//!
//! **The salt and the allocator are arguments**, for the reason `nilo_id`
//! takes entropy and a millisecond as arguments (ADR 0042): both are things a
//! module in this layer cannot reach. Entropy comes through the Bulkhead so
//! the syscall parks the fiber (ADR 0046), and 19 MiB is not a number a
//! framework should be spending without saying so.
//!
//! **This is the pure half, and it is not the half a handler calls.** One
//! hash is 13 ms of CPU and 19 MiB, and both of those want the event loop's
//! opinion — the first because 13 ms of held thread is every other request on
//! that thread waiting, the second because there is a limit to how many may
//! be in flight at once. `Ctx.hashPassword` and `Ctx.verifyPassword` are that
//! half: they take the Gate, park the fiber and call in here. Calling these
//! functions from a handler directly is legal, compiles, works, and holds the
//! thread — which is the reason the Ctx methods exist and why ADR 0048 spends
//! most of its length on them.
//!
//! **What it will not do is store anything.** No user table, no sign-in, no
//! session — a hash is a value, and where it lives is the application's. The
//! session that follows a successful check is `Session(T)` and already built
//! (ADR 0035).

const argon2id = @import("argon2id.zig");
const pages = @import("pages.zig");

/// A stored password hash, in the PHC form everybody else writes.
pub const Hash = argon2id.Hash;

/// How much work one hash is. `.default` is OWASP's first recommendation.
pub const Cost = argon2id.Cost;

/// Bytes of salt a hash needs, and what to ask `Ctx.entropy` for.
pub const salt_len = argon2id.salt_len;

/// What one hash will ask the allocator for, at a given Cost.
pub const bytesFor = argon2id.bytesFor;

/// Why a stored hash could not be checked. Never "wrong password" — that is
/// an answer, not a failure.
pub const Error = argon2id.Error;

/// Hash a password at the default Cost.
pub const hash = argon2id.hash;

/// The same, at a Cost of the caller's own. Below the floor it is a Refusal.
pub const hashWith = argon2id.hashWith;

/// Whether a password is the one a stored hash was made from. `null` means
/// there was no account, and costs exactly what an account costs.
pub const verify = argon2id.verify;

/// The same, told what a hash of yours costs — which is what the no-account
/// path is timed against (ADR 0049).
pub const verifyWith = argon2id.verifyWith;

/// Whether a stored hash is weaker than one made now would be, for the sign-in
/// that just succeeded to write again at the Cost in force.
pub const needsRehash = argon2id.needsRehash;

/// The 19 MiB, asked for in the 2 MiB pages argon2 walks it in: -19% on one
/// hash, and nothing held between them (ADR 0049).
pub const huge_pages = pages.huge_pages;

test {
    _ = argon2id;
    _ = pages;
}
