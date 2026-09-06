//! Turning one piece of request text into the type a handler asked for.
//!
//! A path param, a query value and a form field all arrive as bytes and all
//! end up as a `u32`, a `Str`, a `bool` or an enum. They also all have to say
//! the same thing when the text does not fit, which is why this is one module
//! rather than three copies: `?page has to be a whole number, not "soon"` and
//! `"age" has to be a whole number, not "soon"` differ in the label and in
//! nothing else.
//!
//! A fifth kind arrives the same way and is not on that list: **a type that
//! says it can parse itself**, by declaring `nilo_parse` (ADR 0142). A `uuid`
//! is the one everybody has — `sql.Uuid` is a path param now instead of text
//! the handler parses by hand — and nilo's part of it is small on purpose. It
//! calls the function, and null is the same 400 a bad number gets.
//!
//! `label` is comptime, so the message is assembled while compiling and the
//! failure path formats one runtime value.
//!
//! Converting and *failing* are two jobs, and they are separated here.
//! `tryConvert` answers whether the text fits and says why it did not;
//! `convert` is the fail-fast wrapper almost everybody wants, which turns
//! that answer into the 400 the request is over with. A binding that hands
//! its failures back to the handler instead (`bound.zig`) needs the first
//! without the second, and the wording has to be the same either way — so
//! there is one place that writes the sentence and both go through it.

const std = @import("std");
const fail = @import("fail.zig");
const naming = @import("names.zig");
const str_mod = @import("nilo_core");

const Str = str_mod.Str;

/// Why one piece of request text could not become the type that was asked
/// for.
///
/// This is the whole vocabulary, and it stays that way on purpose. nilo's
/// job stops at "this did not convert to a `u32`"; whether the age is
/// plausible is the application's question, and a reason set that grew to
/// answer it would be a validation language wearing a smaller name.
pub const Reason = enum {
    /// Nothing arrived under this name, and the field has no default and is
    /// not a `?T`. Produced by whoever went looking rather than by
    /// `tryConvert`, which is only ever handed text that exists.
    missing,
    /// An int or a float that `std.fmt` would not read. One reason for both,
    /// because the sentence they deserve differs in the type rather than in
    /// what went wrong, and `sayWhy` has the type.
    not_a_number,
    not_true_or_false,
    not_a_choice,
    /// A type that parses itself said no. nilo does not know what the type
    /// wanted, so the sentence names the type and quotes what arrived —
    /// which is the whole of what it is entitled to say (ADR 0142).
    not_that_type,
    /// The value is the wrong kind of thing altogether — a list where an
    /// object was wanted. Only a JSON body can produce this: a path param, a
    /// query value and a form field all arrive as text, so there is no other
    /// kind for them to be.
    wrong_kind,
};

/// Which of the three places a value arrived from.
///
/// Re-exported as `bound.Slot`, which is the name to write; it lives here for
/// `Outcome`'s reason, since `bound.zig` imports this file and not the other
/// way round.
///
/// It used to settle only how a field is named in a message — `?page`,
/// `"email"` — and it now settles one thing about parsing as well: **an HTML
/// form spells a boolean differently from anywhere else.** A ticked checkbox
/// sends `on`, and a JSON body sending `on` is still wrong, so the difference
/// has to be carried rather than widened away.
pub const Slot = enum { body, form, query };

/// What became of one field of a struct being filled from a request.
///
/// Lives here rather than beside `Bound` so that the two places which fill a
/// struct — a form in `form.zig`, a JSON body in `ctx.zig` — can record an
/// outcome without either of them importing the binding that reads them
/// back. Sized and copied by value; nothing here is allocated.
pub const Outcome = struct {
    /// Null when the field arrived and converted.
    reason: ?Reason = null,
    /// The text that arrived, converted or not. Empty when the field was not
    /// sent, and when what arrived was not text — a JSON list has nothing to
    /// quote back.
    given: Str = Str.static(""),
    /// What arrived when it was not text, in the words the messages use —
    /// "a list", "an object". Only a JSON body ever fills this in.
    kind: []const u8 = "",
};

/// The declaration a type parses itself with (ADR 0142):
///
/// ```zig
/// pub fn nilo_parse(text: []const u8) ?Uuid { … }
/// ```
///
/// Null means "that is not one of these", and nilo turns it into the same 400
/// a bad number gets.
///
/// **Named rather than sniffed for.** Reaching for any type with a `parse`
/// method would promote somebody's existing struct into a path param without
/// asking, and change what a program that already compiles means. A
/// declaration nobody writes by accident is what keeps that from happening —
/// the same reason `nilo_resolve` and `nilo_form` are spelled the way they
/// are.
pub const parse_marker = "nilo_parse";

/// Whether `T` says it can turn request text into itself.
///
/// **Reading the marker is what checks it**, which is the rule
/// `openapi.schemaWithin` already follows for `nilo_openapi` (ADR 0085): a
/// `nilo_parse` of the wrong shape is refused here, where the type is named,
/// rather than surfacing as a message from three frames down inside
/// `tryConvert` about a line of nilo's (ADR 0015).
pub fn parsesItself(comptime T: type) bool {
    comptime {
        const says = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, parse_marker),
            else => false,
        };
        if (says) checkParse(T);
        return says;
    }
}

/// Everything that has to be true of a `nilo_parse` before nilo will call it.
fn checkParse(comptime T: type) void {
    comptime {
        const F = @TypeOf(@field(T, parse_marker));
        const info = switch (@typeInfo(F)) {
            .@"fn" => |f| f,
            else => wrongParse(T, "is a " ++ naming.of(F) ++ ", not a function"),
        };
        if (info.is_generic or info.is_var_args) wrongParse(
            T,
            "is still generic, so nilo cannot tell what it takes",
        );
        if (info.params.len != 1) wrongParse(
            T,
            std.fmt.comptimePrint("takes {d} arguments rather than one", .{info.params.len}),
        );
        if (info.params[0].type != []const u8) wrongParse(
            T,
            "takes a " ++ naming.of(info.params[0].type.?) ++ " rather than the text that arrived",
        );
        if (info.return_type != ?T) wrongParse(
            T,
            "answers " ++ naming.of(info.return_type.?) ++ " rather than `?" ++ naming.of(T) ++ "`",
        );
    }
}

fn wrongParse(comptime T: type, comptime wrong: []const u8) noreturn {
    @compileError(
        "nilo: `" ++ naming.of(T) ++ "`'s `" ++ parse_marker ++ "` " ++ wrong ++ ".\n" ++
            "  A type that turns request text into itself declares `pub fn " ++ parse_marker ++
            "(text: []const u8) ?" ++ naming.of(T) ++ "`, answering null for text that is not one.",
    );
}

/// Whether request text can become a `T` at all — a `Str`, a number, a
/// `bool`, an enum, or any of those wrapped in `?`.
///
/// Asked while compiling, by whoever is about to promise a **field** can be
/// filled from a request. Answering here rather than at each call site is
/// what keeps `Query(T)` and `Form(T)` agreeing on what a field may be.
///
/// A type that parses itself is deliberately not on this list, and the gap is
/// where it stops rather than what it is: `nilo_parse` makes a type a path
/// param (ADR 0142), and a path param does not come through here — `roleOf`
/// gates it and `paramValue` calls `convert` straight. Widening this would
/// also let one into a `Query(T)`, a `Form(T)` and a JSON body, and the last
/// of those is a different question — `std.json` fills a body, not this file.
pub fn convertible(comptime T: type) bool {
    const Inner = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    if (Inner == Str) return true;
    return switch (@typeInfo(Inner)) {
        .int, .float, .bool, .@"enum" => true,
        else => false,
    };
}

/// Turn one piece of request text into the type the handler asked for,
/// without failing: null when it worked and `out` holds the value, a Reason
/// when it did not.
///
/// The reason comes back through the return value and the value through a
/// pointer, rather than the other way round, because that is what makes a
/// struct's worth of outcomes one `[N]?Reason` array. A union carrying each
/// field's own type would need a different shape per field, which is exactly
/// what a binding cannot hold.
pub fn tryConvert(comptime P: type, comptime slot: Slot, s: Str, out: *P) ?Reason {
    if (P == Str) {
        out.* = s;
        return null;
    }

    const text = s.view();
    // Before the switch, because a type that parses itself may be an enum as
    // readily as a struct, and what a type says about itself wins over what
    // its kind would otherwise have meant (ADR 0142).
    if (comptime parsesItself(P)) {
        out.* = P.nilo_parse(text) orelse return .not_that_type;
        return null;
    }
    switch (@typeInfo(P)) {
        // The shape is checked before the value, because `std.fmt` reads Zig
        // source rather than request text and takes three spellings nobody
        // typed on purpose. See `spelledAsNumber`.
        .int => |i| {
            if (!spelledAsNumber(text, i.signedness == .signed, false)) return .not_a_number;
            out.* = std.fmt.parseInt(P, text, 10) catch return .not_a_number;
        },
        .float => {
            if (!spelledAsNumber(text, true, true)) return .not_a_number;
            out.* = std.fmt.parseFloat(P, text) catch return .not_a_number;
        },
        .bool => out.* = boolFrom(text, slot) orelse return .not_true_or_false,
        .@"enum" => out.* = std.meta.stringToEnum(P, text) orelse return .not_a_choice,
        else => comptime unreachable,
    }
    return null;
}

/// Which Reason a `P` can fail with. Settled by the type alone — text that
/// will not become a `u32` is always `.not_a_number` — which is also why
/// `sayWhy` does not need to be told the reason to word it.
pub fn reasonFor(comptime P: type) Reason {
    if (comptime parsesItself(P)) return .not_that_type;
    return switch (@typeInfo(P)) {
        .int, .float => .not_a_number,
        .bool => .not_true_or_false,
        .@"enum" => .not_a_choice,
        else => comptime unreachable,
    };
}

/// Write the sentence that text which would not convert deserves.
///
/// The one place this wording lives. `convert` prints through here on its
/// way to a 400, and a binding that hands its failures to the handler prints
/// through here too, so the two cannot word the same mistake differently —
/// which is a real risk, because they are read side by side in the same
/// application.
pub fn sayWhy(
    comptime P: type,
    comptime slot: Slot,
    arrived: Str,
    comptime label: []const u8,
    w: *std.Io.Writer,
) !void {
    const text = arrived.view();
    // The type is the only thing that knows what it takes, so the sentence
    // names it and stops there. `names.of` is what puts the reader's own
    // import line in front of the name rather than a file of nilo's
    // (ADR 0122).
    if (comptime parsesItself(P)) {
        return w.print(label ++ " has to be a " ++ naming.of(P) ++ ", not \"{s}\"", .{text});
    }
    switch (@typeInfo(P)) {
        .int => try w.print(label ++ " has to be a whole number, not \"{s}\"", .{text}),
        .float => try w.print(label ++ " has to be a number, not \"{s}\"", .{text}),
        // A form is offered `on` as well, because that is what its own
        // checkboxes send and somebody hand-writing the field should be told
        // the same list the browser is held to.
        .bool => try w.print(
            label ++ (if (slot == .form) " has to be true, false or on, not \"{s}\"" else " has to be true or false, not \"{s}\""),
            .{text},
        ),
        .@"enum" => try w.print(
            label ++ " is not one of the known choices ({s}): \"{s}\"",
            .{ comptime enumChoices(P), text },
        ),
        // A `Str` is the one type that cannot fail to convert, so there is
        // no sentence here for it and asking for one is a bug in nilo
        // rather than in anybody's application.
        else => @compileError(
            "nilo: " ++ naming.of(P) ++ " has no conversion failure to describe.",
        ),
    }
}

/// Turn one piece of request text into the type the handler asked for.
/// `label` is how it is named back to the client — `:id` for a path param,
/// `?page` for a query one, `"email"` for a form field — so the same message
/// serves all three.
pub fn convert(comptime P: type, comptime slot: Slot, s: Str, comptime label: []const u8) !P {
    // Text is text. Answered before anything below, because nothing below
    // has a sentence to write about a `Str` and asking it for one is a
    // compile error by design.
    if (P == Str) return s;

    var out: P = undefined;
    if (tryConvert(P, slot, s, &out) == null) return out;

    // Worded into a stack buffer and handed on as one `{s}`, rather than
    // formatted straight into the Failure, so that `sayWhy` stays the only
    // place the sentence exists. This is the failure path — the request is
    // over either way — and 240 bytes of a stack that is two pages is not a
    // trade worth thinking about. Nothing is allocated, which is the part
    // that matters (ADR 0025).
    var buf: [fail.max_message]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    sayWhy(P, slot, s, label, &w) catch {};
    return fail.badRequest("{s}", .{buf[0..w.end]});
}

/// `true` and `false` everywhere, and `on` in a form as well.
///
/// **A ticked HTML checkbox sends `on`, and an unticked one sends nothing at
/// all.** The absent half already worked, because a field that did not arrive
/// takes its default and that is what "unticked" means; only the present half
/// was a 400 the first time somebody ticked the box.
///
/// Widening this for every slot was the shape rejected: `on` is not a JSON
/// boolean, and a body that sends one is a client with a bug that should hear
/// about it. The slot is what keeps one wrong answer from being traded for
/// another. `off` is deliberately *not* here — no browser sends it, and
/// guessing at what a hand-written client might mean is how a parser starts
/// accepting things nobody specified.
fn boolFrom(text: []const u8, comptime slot: Slot) ?bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    if (slot == .form and std.mem.eql(u8, text, "on")) return true;
    return null;
}

/// Whether text is spelled the way a number is spelled outside a Zig source
/// file: digits, a leading `-` where the type has one, and for a real number a
/// fractional part and an exponent.
///
/// **`std.fmt` reads Zig's own literal grammar, and this is the one place a
/// stranger's text reaches it.** `parseInt` takes a leading sign and Zig's
/// digit separators, so `/users/+7` was user 7 and `?page=1_0` was page ten;
/// `parseFloat` takes those plus `inf`, `nan` and hex floats, so `?ratio=nan`
/// was a `f64` that loses every comparison it is ever in. None of the four is a
/// thing a client types by accident, and each of them is two clients disagreeing
/// about what was asked for — the same shape as a body framed twice, which
/// [ADR 0090](../docs/adr/0090-a-body-framed-twice-is-refused.md) refused one
/// layer up. `http1.digitsOnly` and `range.zig`'s copy are that rule for a
/// header; this is it for the one place a *user's* number arrives.
///
/// Checked before `std.fmt` rather than instead of it, because the shape says
/// nothing about whether the value fits in a `u8`.
///
/// A leading zero is allowed, for `digitsOnly`'s reason: `05` is legal in every
/// grammar that has digits, everybody reads it as 5, and refusing it turns a
/// request nobody disagrees about into a 400. A `+` in an *exponent* is allowed
/// for the same reason — `1e+3` is how every JSON writer spells it — while a
/// leading one is not, since nothing produces `+7`.
fn spelledAsNumber(text: []const u8, signed: bool, real: bool) bool {
    var rest = text;
    if (signed and rest.len > 0 and rest[0] == '-') rest = rest[1..];

    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
    if (i == 0) return false;
    if (i == rest.len) return true;
    if (!real) return false;

    if (rest[i] == '.') {
        i += 1;
        const from = i;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i == from) return false;
        if (i == rest.len) return true;
    }

    if (rest[i] != 'e' and rest[i] != 'E') return false;
    i += 1;
    if (i < rest.len and (rest[i] == '+' or rest[i] == '-')) i += 1;
    const from = i;
    while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
    return i > from and i == rest.len;
}

/// The names an enum's values answer to, for the message that says what was
/// expected. Built once at compile time.
pub fn enumChoices(comptime E: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ f.name;
        }
        return out;
    }
}

const testing = std.testing;
const bulkhead = @import("bulkhead.zig");

fn given(bytes: []const u8) Str {
    return Str.static(bytes);
}

/// A type of the reader's own that parses itself, standing in for `sql.Uuid`.
/// `http/` may not import `nilo_id`, and the protocol is a declaration read by
/// name precisely so that it need not (ADR 0042, ADR 0142).
const Sku = struct {
    letters: [3]u8,

    pub fn nilo_parse(text: []const u8) ?Sku {
        if (text.len != 3) return null;
        for (text) |ch| if (!std.ascii.isUpper(ch)) return null;
        return .{ .letters = text[0..3].* };
    }
};

test "a type that parses itself becomes the value it made of the text" {
    const previous = bulkhead.setFallbackSlot(null);
    defer _ = bulkhead.setFallbackSlot(previous);

    var sku: Sku = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(Sku, .query, given("ABC"), &sku));
    try testing.expectEqualStrings("ABC", &sku.letters);
}

test "a type that parses itself answering null is the same 400 a bad number is" {
    const previous = bulkhead.setFallbackSlot(null);
    defer _ = bulkhead.setFallbackSlot(previous);

    var sku: Sku = undefined;
    // Too short, and the right length in the wrong alphabet. The type decides
    // both; nilo only reads the null.
    try testing.expectEqual(Reason.not_that_type, tryConvert(Sku, .query, given("AB"), &sku).?);
    try testing.expectEqual(Reason.not_that_type, tryConvert(Sku, .query, given("abc"), &sku).?);
    try testing.expectEqual(Reason.not_that_type, comptime reasonFor(Sku));
}

test "the sentence for a type that parses itself names the type and quotes the text" {
    var in_flight = fail.InFlight{};
    in_flight.startRequest("GET", "/x");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, convert(Sku, .query, given("abc"), ":sku"));
    try testing.expectEqualStrings(
        ":sku has to be a " ++ @typeName(Sku) ++ ", not \"abc\"",
        in_flight.failure.message(),
    );
    // Failing with the sentence and handing it back word it the same way,
    // exactly as every other reason does.
    try testing.expectEqualStrings(said(Sku, .query, "abc", ":sku"), in_flight.failure.message());
}

test "a marker on an enum wins over what the enum would have meant" {
    const previous = bulkhead.setFallbackSlot(null);
    defer _ = bulkhead.setFallbackSlot(previous);

    // The same three letters an enum value could have been named, read by the
    // type's own function instead. A type says what it is; its kind does not.
    const Grade = enum {
        a,
        b,

        pub fn nilo_parse(text: []const u8) ?@This() {
            if (std.mem.eql(u8, text, "top")) return .a;
            if (std.mem.eql(u8, text, "rest")) return .b;
            return null;
        }
    };

    var grade: Grade = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(Grade, .query, given("top"), &grade));
    try testing.expectEqual(Grade.a, grade);
    // The Zig field name is not the wire spelling any more, and that is the
    // marker doing exactly what it was asked to.
    try testing.expectEqual(Reason.not_that_type, tryConvert(Grade, .query, given("a"), &grade).?);
}

test "the types request text can become" {
    try testing.expect(convertible(Str));
    try testing.expect(convertible(u32));
    try testing.expect(convertible(f64));
    try testing.expect(convertible(bool));
    try testing.expect(convertible(enum { a, b }));
    try testing.expect(convertible(?u32));
    try testing.expect(convertible(?Str));

    try testing.expect(!convertible([]const u8));
    try testing.expect(!convertible(struct { a: u32 }));
    try testing.expect(!convertible([4]u8));
}

test "text that fits becomes the value" {
    try testing.expectEqual(@as(u32, 42), try convert(u32, .query, given("42"), "?page"));
    try testing.expectEqual(@as(f64, 1.5), try convert(f64, .query, given("1.5"), "?ratio"));
    try testing.expectEqual(true, try convert(bool, .query, given("true"), "?on"));
    try testing.expectEqualStrings("hi", (try convert(Str, .query, given("hi"), "?q")).view());

    const Sort = enum { newest, oldest };
    try testing.expectEqual(Sort.oldest, try convert(Sort, .query, given("oldest"), "?sort"));
}

test "a number in a request is not spelled the way a Zig literal is" {
    const previous = bulkhead.setFallbackSlot(null);
    defer _ = bulkhead.setFallbackSlot(previous);

    var n: u32 = 0;
    // What `std.fmt.parseInt` used to take: a sign nobody sends, and Zig's own
    // digit separator. `/users/+7` was user 7 and `?page=1_0` was page ten.
    try testing.expectEqual(Reason.not_a_number, tryConvert(u32, .query, given("+7"), &n).?);
    try testing.expectEqual(Reason.not_a_number, tryConvert(u32, .query, given("1_0"), &n).?);
    try testing.expectEqual(Reason.not_a_number, tryConvert(u32, .query, given(""), &n).?);
    try testing.expectEqual(Reason.not_a_number, tryConvert(u32, .query, given("-"), &n).?);
    try testing.expectEqual(Reason.not_a_number, tryConvert(u32, .query, given("7 "), &n).?);

    // A signed field keeps its sign, and a leading zero stays legal for
    // `digitsOnly`'s reason.
    var i: i32 = 0;
    try testing.expectEqual(@as(?Reason, null), tryConvert(i32, .query, given("-7"), &i));
    try testing.expectEqual(@as(i32, -7), i);
    try testing.expectEqual(Reason.not_a_number, tryConvert(i32, .query, given("+7"), &i).?);
    try testing.expectEqual(@as(?Reason, null), tryConvert(u32, .query, given("05"), &n));
    try testing.expectEqual(@as(u32, 5), n);

    // An unsigned field never had one.
    try testing.expectEqual(Reason.not_a_number, tryConvert(u32, .query, given("-7"), &n).?);
}

test "a float in a request is not inf, nan or a hex literal" {
    const previous = bulkhead.setFallbackSlot(null);
    defer _ = bulkhead.setFallbackSlot(previous);

    var f: f64 = 0;
    // `parseFloat` reads all four, and a `nan` that arrived in a query string
    // is a value that loses every comparison a handler puts it in.
    for ([_][]const u8{ "nan", "inf", "-inf", "0x1p3", "1_0", "+1.5", "1.", ".5", "1e", "1e+" }) |bad| {
        try testing.expectEqual(Reason.not_a_number, tryConvert(f64, .query, given(bad), &f).?);
    }

    for ([_][]const u8{ "1.5", "-1.5", "0", "05", "1e3", "1e+3", "1E-3", "1.5e2" }) |good| {
        try testing.expectEqual(@as(?Reason, null), tryConvert(f64, .query, given(good), &f));
    }
    try testing.expectEqual(@as(f64, 150), f);
}

test "text that does not fit fails with the label in it" {
    var in_flight = fail.InFlight{};
    in_flight.startRequest("GET", "/x");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, convert(u32, .query, given("soon"), "?page"));
    try testing.expectEqualStrings(
        "?page has to be a whole number, not \"soon\"",
        in_flight.failure.message(),
    );

    const Sort = enum { newest, oldest };
    try testing.expectError(error.Failed, convert(Sort, .query, given("sideways"), "\"sort\""));
    try testing.expectEqualStrings(
        "\"sort\" is not one of the known choices (newest, oldest): \"sideways\"",
        in_flight.failure.message(),
    );
}

test "text that does not fit says why, and leaves failing to the caller" {
    // No Failure in the slot at all: `tryConvert` must not need one, which
    // is the whole point of splitting it out of `convert`.
    const previous = bulkhead.setFallbackSlot(null);
    defer _ = bulkhead.setFallbackSlot(previous);

    var n: u32 = undefined;
    try testing.expectEqual(Reason.not_a_number, tryConvert(u32, .query, given("soon"), &n).?);
    try testing.expectEqual(@as(?Reason, null), tryConvert(u32, .query, given("42"), &n));
    try testing.expectEqual(@as(u32, 42), n);

    var b: bool = undefined;
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, .query, given("yes"), &b).?);

    const Sort = enum { newest, oldest };
    var sort: Sort = undefined;
    try testing.expectEqual(Reason.not_a_choice, tryConvert(Sort, .query, given("sideways"), &sort).?);

    // A Str is text already, so there is nothing that can fail.
    var s: Str = undefined;
    try testing.expectEqual(@as(?Reason, null), tryConvert(Str, .query, given("anything"), &s));
}

test "a ticked checkbox binds to a bool, and only out of a form" {
    const previous = bulkhead.setFallbackSlot(null);
    defer _ = bulkhead.setFallbackSlot(previous);

    var b: bool = undefined;

    // The whole bug: `on` is what a browser sends for a ticked box.
    try testing.expectEqual(@as(?Reason, null), tryConvert(bool, .form, given("on"), &b));
    try testing.expectEqual(true, b);

    // And nowhere else, because `on` is not a JSON boolean and a client
    // sending one has a bug worth hearing about.
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, .body, given("on"), &b).?);
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, .query, given("on"), &b).?);

    // `true` and `false` still work in every slot, so nothing was traded away.
    inline for (.{ Slot.body, Slot.form, Slot.query }) |slot| {
        try testing.expectEqual(@as(?Reason, null), tryConvert(bool, slot, given("true"), &b));
        try testing.expectEqual(true, b);
        try testing.expectEqual(@as(?Reason, null), tryConvert(bool, slot, given("false"), &b));
        try testing.expectEqual(false, b);
    }

    // `off` is not accepted anywhere: no browser sends it, and a value nobody
    // specified is not one to guess at. An unticked box sends nothing at all,
    // which is a default rather than a conversion.
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, .form, given("off"), &b).?);
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, .form, given("ON"), &b).?);
    try testing.expectEqual(Reason.not_true_or_false, tryConvert(bool, .form, given("1"), &b).?);
}

test "a form says which three words it takes, and the other slots say two" {
    try testing.expectEqualStrings(
        "\"news\" has to be true, false or on, not \"maybe\"",
        said(bool, .form, "maybe", "\"news\""),
    );
    try testing.expectEqualStrings(
        "?on has to be true or false, not \"maybe\"",
        said(bool, .query, "maybe", "?on"),
    );
}

test "the reason a type fails with is settled by the type" {
    try testing.expectEqual(Reason.not_a_number, comptime reasonFor(u32));
    try testing.expectEqual(Reason.not_a_number, comptime reasonFor(f64));
    try testing.expectEqual(Reason.not_true_or_false, comptime reasonFor(bool));
    try testing.expectEqual(Reason.not_a_choice, comptime reasonFor(enum { a, b }));
}

/// What `sayWhy` writes, for comparing against what `convert` failed with.
fn said(
    comptime P: type,
    comptime slot: Slot,
    text: []const u8,
    comptime label: []const u8,
) []const u8 {
    const buf = struct {
        var bytes: [fail.max_message]u8 = undefined;
    };
    var w = std.Io.Writer.fixed(&buf.bytes);
    sayWhy(P, slot, given(text), label, &w) catch unreachable;
    return buf.bytes[0..w.end];
}

test "the sentence is the same whether it is failed with or handed back" {
    var in_flight = fail.InFlight{};
    in_flight.startRequest("GET", "/x");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    // The drift this guards against is not hypothetical: a handler shows a
    // field's failure next to a 400 from the endpoint beside it, and two
    // wordings for one mistake is the thing somebody files a bug about.
    const Sort = enum { newest, oldest };

    try testing.expectError(error.Failed, convert(u32, .query, given("soon"), "?page"));
    try testing.expectEqualStrings(said(u32, .query, "soon", "?page"), in_flight.failure.message());

    try testing.expectError(error.Failed, convert(f64, .query, given("soon"), "?ratio"));
    try testing.expectEqualStrings(said(f64, .query, "soon", "?ratio"), in_flight.failure.message());

    try testing.expectError(error.Failed, convert(bool, .query, given("yes"), "?on"));
    try testing.expectEqualStrings(said(bool, .query, "yes", "?on"), in_flight.failure.message());

    try testing.expectError(error.Failed, convert(Sort, .query, given("sideways"), "\"sort\""));
    try testing.expectEqualStrings(said(Sort, .query, "sideways", "\"sort\""), in_flight.failure.message());
}

test "a message with braces in it survives being handed on" {
    // `convert` now prints the sentence through a `{s}`, so text that looks
    // like a format string reaches the client as itself.
    var in_flight = fail.InFlight{};
    in_flight.startRequest("GET", "/x");
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, convert(u32, .query, given("{d}"), "?page"));
    try testing.expectEqualStrings(
        "?page has to be a whole number, not \"{d}\"",
        in_flight.failure.message(),
    );
}

test "the choices an enum offers are listed in order" {
    try testing.expectEqualStrings("red, green, blue", comptime enumChoices(enum { red, green, blue }));
}
