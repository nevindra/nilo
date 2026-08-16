//! A binding that hands its failures back, instead of ending the request.
//!
//! ```zig
//! fn signUp(b: nilo.Bound(nilo.Form(SignUp))) !Redirect(303) {
//!     const form = b.value() orelse return b.fail();
//!     return db.create(form.email, form.age);
//! }
//! ```
//!
//! `Form(T)` and a JSON body are otherwise all-or-nothing: one field that
//! will not convert is a 400 out of a fail function and the request is over,
//! with nothing saying *which* field. For a framework whose claim is that
//! the signature is the contract, not being able to name the field that
//! broke the contract is the gap that contradicts the most. A 422 naming the
//! fields is what a REST client expects, and showing a form again with one
//! box marked needs the same thing.
//!
//! Two rules hold this in shape.
//!
//! **Nothing is allocated per failed field.** `T`'s field count is settled
//! while compiling, so every outcome lives in one fixed array inside the
//! value the handler already received — on the fiber's stack, where the
//! allocation budget cannot see it (ADR 0018).
//!
//! **It is not a validation language.** The reasons are exactly the ones
//! `convert.zig` can already produce. nilo's job stops at "this did not
//! convert to a `u32`"; whether the age is plausible stays the
//! application's, and a reason set that grew to answer that would be a
//! validator wearing a smaller name.
//!
//! What is *not* a per-field failure stays a hard 400: a body that is not a
//! form at all, text that is not JSON at all, and a field the endpoint has
//! never heard of. None of those leave a binding to hand back, and the
//! sentence each already gets says more than "some field was wrong" would.

const std = @import("std");
const convert = @import("convert.zig");
const ctx_mod = @import("ctx.zig");
const fail_mod = @import("fail.zig");
const form_mod = @import("form.zig");
const naming = @import("names.zig");
const str_mod = @import("str.zig");

const Str = str_mod.Str;
const Upload = form_mod.Upload;

pub const Reason = convert.Reason;

/// The declaration a `Bound(W)` carries, so the compile-time engine can tell
/// it from the thing it wraps.
pub const marker = "nilo_bound";

/// Which of the three places a binding was read from.
///
/// It settles two things and nothing else: what a field is called in a
/// message — `?page`, `"email"` — and how "it was not sent" is worded. Those
/// differ between the slots today, and a binding that reworded them would be
/// a second dialect inside one application.
pub const Slot = enum { body, form, query };

/// What became of one field. The engine fills an array of these, sized while
/// compiling; nothing here is allocated.
///
/// Declared next to `Reason` rather than here, so that the two places which
/// fill a struct from a request can record outcomes without importing this
/// file.
pub const Outcome = convert.Outcome;

/// One field that did not bind.
pub const Failure = struct {
    /// The field's name, spelled the way the struct spells it.
    field: []const u8,
    reason: Reason,
    /// The text that arrived, or empty when there was none to quote.
    given: Str,
    /// What arrived when it was not text; empty otherwise.
    kind: []const u8,
    /// What this field would have taken, in the words the messages use —
    /// "text", "a whole number", "one of newest, oldest".
    expected: []const u8,

    _say: *const fn (Failure, *std.Io.Writer) anyerror!void,

    /// Write nilo's own sentence for this failure.
    ///
    /// Here so that a handler assembling a body of its own does not have to
    /// reproduce the wording — and so that it cannot drift from the wording
    /// the endpoint next door produces from the same mistake.
    pub fn say(self: Failure, w: *std.Io.Writer) !void {
        return self._say(self, w);
    }
};

/// A binding of `W` that collects its failures rather than failing.
///
/// `W` says which slot this is and what it is read into: `Bound(Form(T))`,
/// `Bound(Query(T))`, or `Bound(T)` for a JSON body.
pub fn Bound(comptime W: type) type {
    const slot = comptime slotOf(W);
    const T = comptime valueOf(W, slot);
    const fields = @typeInfo(T).@"struct".fields;

    return struct {
        const Self = @This();

        pub const nilo_bound = W;
        pub const nilo_bound_slot = slot;
        /// The struct the handler actually asked for.
        pub const Value = T;
        /// What the engine fills in and hands to `from`.
        pub const Outcomes = [fields.len]Outcome;

        /// Everything about a field that is settled while compiling. Built
        /// once per `T` rather than per request, so iterating failures reads
        /// a table instead of walking the type again.
        const Entry = struct {
            name: []const u8,
            expected: []const u8,
            say: *const fn (Failure, *std.Io.Writer) anyerror!void,
        };

        const table = blk: {
            var t: [fields.len]Entry = undefined;
            for (fields, 0..) |f, i| t[i] = .{
                .name = f.name,
                .expected = expectedFor(f.type),
                .say = sayerFor(slot, f.type, f.name),
            };
            const frozen = t;
            break :blk frozen;
        };

        _value: T,
        _outcomes: Outcomes,

        /// Built by the compile-time engine, which has just filled `T` as
        /// far as it could and recorded why each field it could not fill
        /// did not fill.
        pub fn from(filled: T, outcomes: Outcomes) Self {
            return .{ ._value = filled, ._outcomes = outcomes };
        }

        /// The binding, or null when any field failed.
        ///
        /// Optional on purpose. A field that did not bind holds nothing
        /// worth reading, and there is deliberately no way to reach past
        /// that into a half-filled struct — a handler that forgot to check
        /// would otherwise be reading a zero somebody never sent. What a
        /// form showing itself again actually wants is the text the person
        /// typed, and that is `given`.
        pub fn value(self: Self) ?T {
            if (self.failed()) return null;
            return self._value;
        }

        pub fn failed(self: Self) bool {
            for (self._outcomes) |o| {
                if (o.reason != null) return true;
            }
            return false;
        }

        /// How many fields did not bind.
        pub fn failedCount(self: Self) usize {
            var n: usize = 0;
            for (self._outcomes) |o| {
                if (o.reason != null) n += 1;
            }
            return n;
        }

        /// The text that arrived under `name`, whether or not it converted —
        /// what a form putting itself back on the page writes into the box.
        ///
        /// Empty when the field was not sent at all, and when what arrived
        /// was not text. The name is checked while compiling, so a typo here
        /// is a compile error rather than an empty box nobody notices.
        pub fn given(self: Self, comptime name: []const u8) Str {
            return self._outcomes[comptime indexOf(name)].given;
        }

        /// Why each field that did not bind did not bind, in the order the
        /// struct declares them.
        pub fn failures(self: *const Self) Failures {
            return .{ ._outcomes = &self._outcomes };
        }

        pub const Failures = struct {
            _outcomes: *const Outcomes,
            _at: usize = 0,

            pub fn next(self: *Failures) ?Failure {
                while (self._at < fields.len) {
                    const i = self._at;
                    self._at += 1;
                    const o = self._outcomes[i];
                    const reason = o.reason orelse continue;
                    return .{
                        .field = table[i].name,
                        .reason = reason,
                        .given = o.given,
                        .kind = o.kind,
                        .expected = table[i].expected,
                        ._say = table[i].say,
                    };
                }
                return null;
            }
        };

        /// Stop the request with a 422 naming every field that did not bind.
        ///
        /// The shortcut for the handler that has nothing more interesting to
        /// say than "these are wrong". The body is the one every failure
        /// answers with (ADR 0025) — this only fills in the sentence, into
        /// the fixed buffer that already exists, so the failure path still
        /// allocates nothing. A 422 rather than a 400 because the request
        /// was understood and its contents were not.
        pub fn fail(self: Self) fail_mod.Error {
            var buf: [fail_mod.max_message]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);

            // Counted only when there is more than one. A single failure
            // reads exactly as it did before any of this existed, which is
            // the most common case and the one already worth reading.
            const n = self.failedCount();
            if (n > 1) w.print("{d} fields did not fit: ", .{n}) catch {};

            var it = self.failures();
            var first = true;
            while (it.next()) |f| {
                if (!first) w.writeAll("; ") catch break;
                first = false;
                f.say(&w) catch break;
            }

            return fail_mod.status(422, "{s}", .{buf[0..w.end]});
        }

        fn indexOf(comptime name: []const u8) usize {
            comptime {
                for (fields, 0..) |f, i| {
                    if (std.mem.eql(u8, f.name, name)) return i;
                }
                @compileError(
                    "nilo: `" ++ naming.of(T) ++ "` has no field `" ++ name ++ "`.\n" ++
                        "  A binding only knows the fields of the struct it was read into: " ++
                        fieldList(T) ++ ".",
                );
            }
        }
    };
}

// ---- what the slot decides ----

fn slotOf(comptime W: type) Slot {
    comptime {
        if (@typeInfo(W) != .@"struct") @compileError(
            "nilo: `Bound(" ++ naming.of(W) ++ ")` — a binding is read into a struct.\n" ++
                "  Write `Bound(Form(T))`, `Bound(Query(T))`, or `Bound(T)` for a JSON body, " ++
                "where `T` is a struct of your own with one field per field of the request.",
        );
        if (@hasDecl(W, marker)) @compileError(
            "nilo: `Bound(Bound(…))` — a binding is already a binding.\n" ++
                "  Drop the outer one: `Bound(" ++ naming.of(W.nilo_bound) ++ ")`.",
        );
        if (@hasDecl(W, form_mod.marker)) return .form;
        if (@hasDecl(W, "nilo_query")) return .query;
        return .body;
    }
}

fn valueOf(comptime W: type, comptime slot: Slot) type {
    return switch (slot) {
        .form => W.nilo_form,
        .query => W.nilo_query,
        .body => W,
    };
}

/// A field's type reached through the `?` that says it may be absent.
fn innerOf(comptime F: type) type {
    return switch (@typeInfo(F)) {
        .optional => |o| o.child,
        else => F,
    };
}

/// Whether a field of this type has a conversion that can fail at all. A
/// `Str` is text already and an `Upload` is bytes; either can only ever be
/// missing, so neither has a "did not fit" sentence and asking `convert` for
/// one is a compile error by design.
fn canFail(comptime F: type) bool {
    const Inner = innerOf(F);
    if (Inner == Str or Inner == Upload) return false;
    // A nested object or a list has no text conversion either: what goes
    // wrong with one of those is its kind, which is a different sentence.
    return convert.convertible(Inner);
}

/// What a field would have taken, in the words the messages already use.
fn expectedFor(comptime F: type) []const u8 {
    // `expectedOf` would call an Upload "an object", which is true of the
    // struct and useless to somebody who has to put a file in it.
    if (innerOf(F) == Upload) return "a file";
    return ctx_mod.expectedOf(F);
}

/// What a field is called when a message points at it. The three slots name
/// their fields differently today and a binding does not get to change that.
fn labelFor(comptime slot: Slot, comptime name: []const u8) []const u8 {
    return switch (slot) {
        .query => "?" ++ name,
        .form, .body => "\"" ++ name ++ "\"",
    };
}

/// The sentence for a field that never arrived. Worded here rather than in
/// `convert.zig` because it is the one failure whose wording belongs to the
/// slot: a form says what it is missing, a query string says what it
/// requires.
fn sayMissing(
    comptime slot: Slot,
    comptime F: type,
    comptime name: []const u8,
    w: *std.Io.Writer,
) !void {
    const said = comptime switch (slot) {
        .form => if (innerOf(F) == Upload)
            "the form is missing the file \"" ++ name ++ "\""
        else
            "the form is missing \"" ++ name ++ "\" (" ++ ctx_mod.expectedOf(F) ++ ")",
        .body => "the request body is missing \"" ++ name ++ "\" (" ++ ctx_mod.expectedOf(F) ++ ")",
        .query => "?" ++ name ++ " is required",
    };
    try w.writeAll(said);
}

/// The function that writes one field's sentence, generated while compiling
/// so that iterating failures at run time needs no type information.
fn sayerFor(
    comptime slot: Slot,
    comptime F: type,
    comptime name: []const u8,
) *const fn (Failure, *std.Io.Writer) anyerror!void {
    return struct {
        fn say(f: Failure, w: *std.Io.Writer) anyerror!void {
            switch (f.reason) {
                .missing => try sayMissing(slot, F, name, w),
                // Only a JSON body reaches this: a value that is the wrong
                // kind of thing rather than text that would not convert.
                .wrong_kind => try w.print(
                    labelFor(slot, name) ++ " has to be " ++ comptime expectedFor(F) ++ ", not {s}",
                    .{f.kind},
                ),
                else => if (comptime canFail(F))
                    try convert.sayWhy(innerOf(F), f.given, labelFor(slot, name), w)
                else
                    unreachable,
            }
        }
    }.say;
}

/// The field names of `T`, for the message a bad `given("…")` stops with.
fn fieldList(comptime T: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ f.name;
        }
        return out;
    }
}

// ---- tests ----

const testing = std.testing;
const bulkhead = @import("bulkhead.zig");

const SignUp = struct {
    email: Str,
    age: u32,
    newsletter: bool = false,
};

const Bare = Bound(form_mod.Form(SignUp));

/// A binding where every field converted.
fn allGood() Bare {
    return .from(
        .{ .email = Str.static("wati@example.com"), .age = 31, .newsletter = true },
        .{
            .{ .given = Str.static("wati@example.com") },
            .{ .given = Str.static("31") },
            .{ .given = Str.static("true") },
        },
    );
}

/// A binding where the age would not convert and the email never arrived.
fn twoWrong() Bare {
    var value: SignUp = undefined;
    value.newsletter = true;
    return .from(value, .{
        .{ .reason = .missing },
        .{ .reason = .not_a_number, .given = Str.static("soon") },
        .{ .given = Str.static("true") },
    });
}

test "a binding that bound hands back its value" {
    const b = allGood();
    try testing.expect(!b.failed());
    try testing.expectEqual(@as(usize, 0), b.failedCount());

    const v = b.value().?;
    try testing.expectEqualStrings("wati@example.com", v.email.view());
    try testing.expectEqual(@as(u32, 31), v.age);
    try testing.expectEqual(true, v.newsletter);
}

test "one field that did not bind withholds the whole struct" {
    const b = twoWrong();
    try testing.expect(b.failed());
    try testing.expectEqual(@as(usize, 2), b.failedCount());
    // The half-filled struct is not reachable, which is the point: a handler
    // that forgot to check cannot read a zero nobody sent.
    try testing.expectEqual(@as(?SignUp, null), b.value());
}

test "the failures come back in the order the struct declares them" {
    const b = twoWrong();
    var it = b.failures();

    const first = it.next().?;
    try testing.expectEqualStrings("email", first.field);
    try testing.expectEqual(Reason.missing, first.reason);
    try testing.expectEqualStrings("text", first.expected);

    const second = it.next().?;
    try testing.expectEqualStrings("age", second.field);
    try testing.expectEqual(Reason.not_a_number, second.reason);
    try testing.expectEqualStrings("soon", second.given.view());
    try testing.expectEqualStrings("a whole number", second.expected);

    // `newsletter` bound, so it is not a failure.
    try testing.expectEqual(@as(?Failure, null), it.next());
}

/// `fail` returns a bare error value so it can be used as `orelse b.fail()`;
/// tests wrap that into an error union first, exactly as `fail.zig` does.
fn asUnion(e: fail_mod.Error) fail_mod.Error!void {
    return e;
}

fn saidBy(f: Failure) []const u8 {
    const buf = struct {
        var bytes: [fail_mod.max_message]u8 = undefined;
    };
    var w = std.Io.Writer.fixed(&buf.bytes);
    f.say(&w) catch unreachable;
    return buf.bytes[0..w.end];
}

test "a failure writes nilo's own sentence, in the words of its slot" {
    const b = twoWrong();
    var it = b.failures();

    try testing.expectEqualStrings(
        "the form is missing \"email\" (text)",
        saidBy(it.next().?),
    );
    try testing.expectEqualStrings(
        "\"age\" has to be a whole number, not \"soon\"",
        saidBy(it.next().?),
    );
}

test "the same field says a different thing out of a query string" {
    const Page = struct { page: u32 };
    const b = Bound(struct {
        pub const nilo_query = Page;
        value: Page,
    }).from(.{ .page = 0 }, .{.{ .reason = .not_a_number, .given = Str.static("soon") }});

    var it = b.failures();
    try testing.expectEqualStrings("?page has to be a whole number, not \"soon\"", saidBy(it.next().?));
}

test "a JSON body names the field the way the body parser already does" {
    const Profile = struct { name: Str, address: struct { street: Str } };
    const b = Bound(Profile).from(undefined, .{
        .{ .reason = .missing },
        .{ .reason = .wrong_kind, .kind = "a list" },
    });

    var it = b.failures();
    try testing.expectEqualStrings(
        "the request body is missing \"name\" (text)",
        saidBy(it.next().?),
    );
    try testing.expectEqualStrings(
        "\"address\" has to be an object, not a list",
        saidBy(it.next().?),
    );
}

test "one failure fails with the sentence it would have failed with anyway" {
    var in_flight = fail_mod.InFlight{};
    in_flight.startRequest("POST", "/sign-up");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    const b = Bare.from(undefined, .{
        .{},
        .{ .reason = .not_a_number, .given = Str.static("soon") },
        .{},
    });

    try testing.expectError(error.Failed, asUnion(b.fail()));
    try testing.expectEqual(@as(u16, 422), in_flight.failure.status);
    try testing.expectEqualStrings(
        "\"age\" has to be a whole number, not \"soon\"",
        in_flight.failure.message(),
    );
}

test "more than one failure is counted, and every one is named" {
    var in_flight = fail_mod.InFlight{};
    in_flight.startRequest("POST", "/sign-up");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, asUnion(twoWrong().fail()));
    try testing.expectEqual(@as(u16, 422), in_flight.failure.status);
    try testing.expectEqualStrings(
        "2 fields did not fit: the form is missing \"email\" (text); " ++
            "\"age\" has to be a whole number, not \"soon\"",
        in_flight.failure.message(),
    );
}

test "the text that arrived is readable whether or not it converted" {
    const b = twoWrong();
    // What a form putting itself back on the page writes into each box: the
    // one that failed shows what was typed, the one that worked shows itself.
    try testing.expectEqualStrings("soon", b.given("age").view());
    try testing.expectEqualStrings("true", b.given("newsletter").view());
    // Never sent, so there is nothing to put back.
    try testing.expectEqualStrings("", b.given("email").view());
}

test "a binding of a form is still a binding of the struct inside it" {
    const Wrapped = Bound(form_mod.Form(SignUp));
    try testing.expectEqual(Slot.form, Wrapped.nilo_bound_slot);
    try testing.expectEqual(SignUp, Wrapped.Value);

    // And a plain struct is the JSON body.
    try testing.expectEqual(Slot.body, Bound(SignUp).nilo_bound_slot);
}
