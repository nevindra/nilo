//! One reading of a Config, and every reason it could not be filled.
//!
//! ```zig
//! const read = config.fromEnv(Config, environ);
//! const settings = read.value() orelse {
//!     try read.report(stderr);
//!     std.process.exit(2);
//! };
//! ```
//!
//! **Every bad setting is named at once, and that is the whole feature**
//! (ADR 0043). A reader that stopped at the first one costs an operator a
//! restart per mistake: fix `DATABASE_URL`, run again, discover `PORT`, run
//! again. The shape is [ADR 0036](../docs/adr/0036-a-binding-hands-its-failures-to-the-handler.md)'s
//! — `value() orelse` and a list of failures — pointed at startup instead of
//! at a handler, and it is the same shape on purpose: a person who has read
//! one has read the other.
//!
//! **Nothing is allocated, here or anywhere below.** `T`'s field count is
//! settled while compiling, so a whole reading is one fixed array in the
//! value the caller already holds. The environment is read where it lies:
//! `getPosix` hands back a slice of the block the operating system gave the
//! process, so a Config of `[]const u8` fields points into memory that
//! outlives every use of it and no copy is made
//! ([ADR 0018](../docs/adr/0018-the-trade-budget-has-three-axes.md) — this
//! module spends nothing on any of the four axes, being over before the
//! socket opens).
//!
//! **It is not a validation language.** The reasons are the four
//! `convert.zig` can produce. Whether the port is one this machine may bind
//! is the program's own question.

const std = @import("std");
const convert = @import("convert.zig");
const source_mod = @import("source.zig");

pub const Reason = convert.Reason;

/// What became of one field. Filled while reading, sized while compiling.
pub const Outcome = struct {
    /// Null when the field was filled — from the environment, from its
    /// default, or with `null` because it is a `?T` nothing was set for.
    reason: ?Reason = null,
    /// The text that was set, converted or not. Empty when nothing was set
    /// under this name at all.
    given: []const u8 = "",
};

/// One setting that could not be read.
pub const Failure = struct {
    /// The field, spelled the way the struct spells it.
    field: []const u8,
    /// The environment variable it was looked for under, prefix and all.
    name: []const u8,
    reason: Reason,
    /// The text that was set, or empty when nothing was.
    given: []const u8,
    /// What it would have taken, in the words the messages use — "text",
    /// "a whole number", "one of debug, info, warn".
    expected: []const u8,

    /// Write nilo's own sentence for this failure.
    ///
    /// Here rather than in the caller so that a program printing its own
    /// banner around the list does not have to reproduce the wording.
    pub fn say(self: Failure, w: *std.Io.Writer) !void {
        switch (self.reason) {
            .missing => try w.print("{s} is not set", .{self.name}),
            // One shape for the other three, because they differ in what
            // was expected and in nothing else — which is exactly what
            // `expected` holds.
            else => try w.print(
                "{s} has to be {s}, not \"{s}\"",
                .{ self.name, self.expected, self.given },
            ),
        }
    }
};

/// Everything about a Config that is settled while compiling: which
/// environment variable each field is read from, and what it would have
/// taken. Built once per `(T, prefix)` rather than per reading.
pub fn Table(comptime T: type, comptime prefix: []const u8) type {
    checkPrefix(prefix);
    const fields = @typeInfo(T).@"struct".fields;

    return struct {
        pub const entries = blk: {
            var t: [fields.len]Entry = undefined;
            for (fields, 0..) |f, i| t[i] = .{
                .field = f.name,
                .name = envName(prefix, f.name),
                .expected = convert.expectedOf(f.type),
            };
            const frozen = t;
            break :blk frozen;
        };
    };
}

pub const Entry = struct {
    field: []const u8,
    name: []const u8,
    expected: []const u8,
};

/// A Config filled as far as the environment allowed, and why each field
/// that is not filled is not.
///
/// One type per `T` rather than per `(T, prefix)`: the names a prefix
/// settles are comptime text either way, so the reading carries a pointer to
/// them instead of baking them into the type. That is what lets a caller
/// write `Read(Config)` without repeating the prefix they read it with.
pub fn Read(comptime T: type) type {
    // Here rather than in `fill`, because a return type is analysed before
    // the body that would have checked it — `fill(u32, …)` would otherwise
    // stop inside `@typeInfo` with a message about a union field, which is
    // exactly the kind of failure ADR 0027 exists to stop being acceptable.
    checkConfig(T);
    const fields = @typeInfo(T).@"struct".fields;

    return struct {
        const Self = @This();

        /// The struct the caller actually asked for.
        pub const Value = T;
        pub const Outcomes = [fields.len]Outcome;

        _value: T,
        _outcomes: Outcomes,
        _entries: *const [fields.len]Entry,

        pub fn from(filled: T, outcomes: Outcomes, entries: *const [fields.len]Entry) Self {
            return .{ ._value = filled, ._outcomes = outcomes, ._entries = entries };
        }

        /// The Config, or null when any setting could not be read.
        ///
        /// Optional on purpose, and for the reason
        /// [ADR 0036](../docs/adr/0036-a-binding-hands-its-failures-to-the-handler.md)
        /// gives: a field that did not convert holds nothing worth reading,
        /// and there is deliberately no way to reach past this into a
        /// half-filled struct. A program that forgot to check would
        /// otherwise be serving on a port nobody set.
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

        /// How many settings could not be read.
        pub fn failedCount(self: Self) usize {
            var n: usize = 0;
            for (self._outcomes) |o| {
                if (o.reason != null) n += 1;
            }
            return n;
        }

        /// The text that was set for one field, whether or not it
        /// converted. Empty when nothing was set under its name.
        ///
        /// The field name is checked while compiling, so a typo here is a
        /// Refusal rather than an empty string that looks like an answer.
        pub fn given(self: Self, comptime field: []const u8) []const u8 {
            return self._outcomes[comptime indexOf(field)].given;
        }

        /// The environment variable one field is read from, prefix and all.
        pub fn nameOf(self: Self, comptime field: []const u8) []const u8 {
            return self._entries[comptime indexOf(field)].name;
        }

        fn indexOf(comptime field: []const u8) usize {
            comptime {
                for (fields, 0..) |f, i| {
                    if (std.mem.eql(u8, f.name, field)) return i;
                }
                @compileError("nilo: the Config `" ++ @typeName(T) ++
                    "` has no field `" ++ field ++ "`.");
            }
        }

        /// Walk the settings that could not be read, in the order the struct
        /// declares them.
        pub fn failures(self: *const Self) Failures {
            return .{ .read = self };
        }

        pub const Failures = struct {
            read: *const Self,
            at: usize = 0,

            pub fn next(self: *Failures) ?Failure {
                while (self.at < fields.len) {
                    const i = self.at;
                    self.at += 1;
                    const reason = self.read._outcomes[i].reason orelse continue;
                    const entry = self.read._entries[i];
                    return .{
                        .field = entry.field,
                        .name = entry.name,
                        .reason = reason,
                        .given = self.read._outcomes[i].given,
                        .expected = entry.expected,
                    };
                }
                return null;
            }
        };

        /// Write every failure, one per line, under a line saying how many
        /// there are. Writes nothing at all when there are none, so it is
        /// safe to call unconditionally.
        ///
        /// This is what a `main` prints before it exits, and the reason the
        /// count is on its own line is that the list is the part somebody
        /// scrolls back to: a run that fixed one of three mistakes should
        /// say three, then two, without the reader counting lines.
        pub fn report(self: Self, w: *std.Io.Writer) !void {
            const n = self.failedCount();
            if (n == 0) return;
            try w.print("{d} setting{s} could not be read from the environment:\n", .{
                n,
                if (n == 1) "" else "s",
            });
            var it = self.failures();
            while (it.next()) |f| {
                try w.writeAll("  ");
                try f.say(w);
                try w.writeAll("\n");
            }
        }
    };
}

/// Fill a `T` from anything that answers `get(name) ?[]const u8`.
///
/// The source is a comptime shape rather than an interface with a function
/// table, for the reason [ADR 0041](../docs/adr/0041-a-module-sits-where-the-loop-puts-it.md)
/// gives about a Scope: the check refuses an unsuitable type in a sentence
/// and generates the code a direct call generates.
pub fn fill(comptime T: type, comptime prefix: []const u8, source: anytype) Read(T) {
    source_mod.check(@TypeOf(source));
    const entries = &Table(T, prefix).entries;
    const fields = @typeInfo(T).@"struct".fields;

    var filled: T = undefined;
    var outcomes: Read(T).Outcomes = @splat(.{});

    inline for (fields, 0..) |f, i| {
        const P = comptime convert.unwrap(f.type);

        if (source.get(entries[i].name)) |text| {
            // Kept before the conversion is tried, and kept whether or not it
            // works: what `report` quotes back is what was set, not what it
            // would have become.
            outcomes[i].given = text;
            var out: P = undefined;
            if (convert.tryConvert(P, text, &out)) |reason| {
                outcomes[i].reason = reason;
                // The default goes in anyway, the way `http/form.zig` does
                // it. `value()` refuses the whole struct either way, so this
                // is not a value anybody can read — it is one field fewer
                // left `undefined` in a struct that gets copied out by value.
                if (f.defaultValue()) |default| @field(filled, f.name) = default;
            } else {
                @field(filled, f.name) = out;
            }
        } else if (f.defaultValue()) |default| {
            // A default is checked before `?T` so that `?u8 = 5` answers 5
            // rather than null. Both mean "nothing was set"; only one of
            // them says what to do about it.
            @field(filled, f.name) = default;
        } else if (@typeInfo(f.type) == .optional) {
            @field(filled, f.name) = null;
        } else {
            outcomes[i].reason = .missing;
        }
    }

    return .from(filled, outcomes, entries);
}

/// `database_url` under the prefix `NILO_` is `NILO_DATABASE_URL`.
///
/// Upper-case and nothing else — no camelCase splitting, no `-` for `_`.
/// A rule with one step is a rule somebody can predict without reading this
/// file, and the field name is already the shape an environment variable
/// wants. What it cannot spell is a name that is not the field's own, and
/// that is a known gap rather than a decision (ADR 0043).
fn envName(comptime prefix: []const u8, comptime field: []const u8) []const u8 {
    comptime {
        var upper: [field.len]u8 = undefined;
        for (field, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
        const frozen = upper;
        return prefix ++ &frozen;
    }
}

/// Refuse a Config that could never be read, while compiling.
fn checkConfig(comptime T: type) void {
    comptime {
        if (@typeInfo(T) != .@"struct") @compileError(
            "nilo: a Config is read into a struct, and " ++ @typeName(T) ++ " is not one.",
        );

        const fields = @typeInfo(T).@"struct".fields;
        if (fields.len == 0) @compileError(
            "nilo: the Config `" ++ @typeName(T) ++
                "` has no fields, so it would read nothing.",
        );

        for (fields) |f| {
            if (!convert.convertible(f.type)) @compileError(
                "nilo: the field `" ++ f.name ++ ": " ++ @typeName(f.type) ++
                    "` of the Config `" ++ @typeName(T) ++
                    "` is not something an environment variable can become.\n" ++
                    "  A setting is text, a number, a bool, an enum, or any of those wrapped in `?`.",
            );
        }
    }
}

/// A prefix that no environment variable name could carry is a mistake at
/// the call rather than a lookup that silently answers nothing.
fn checkPrefix(comptime prefix: []const u8) void {
    comptime {
        for (prefix) |c| {
            if (c == '=' or c == 0) @compileError(
                "nilo: the Config prefix \"" ++ prefix ++ "\" has a `" ++ [_]u8{c} ++
                    "` in it, which no environment variable name may hold.",
            );
        }
    }
}

const testing = std.testing;

/// A source of fixed pairs — what the tests below read from, and what a
/// program that has parsed a file of its own hands over.
const Fixed = source_mod.Fixed;

const Settings = struct {
    port: u16 = 8080,
    database_url: []const u8,
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,
};

fn read(pairs: []const Fixed.Pair) Read(Settings) {
    return fill(Settings, "", Fixed{ .pairs = pairs });
}

test "a Config that is fully set is the struct that was asked for" {
    const r = read(&.{
        .{ "PORT", "9000" },
        .{ "DATABASE_URL", "postgres://localhost/app" },
        .{ "LOG_LEVEL", "warn" },
        .{ "WORKERS", "4" },
    });

    const settings = r.value().?;
    try testing.expectEqual(@as(u16, 9000), settings.port);
    try testing.expectEqualStrings("postgres://localhost/app", settings.database_url);
    try testing.expectEqual(.warn, settings.log_level);
    try testing.expectEqual(@as(?u8, 4), settings.workers);
}

test "a field name becomes the environment variable in upper case" {
    const r = read(&.{.{ "DATABASE_URL", "postgres://" }});
    try testing.expectEqualStrings("DATABASE_URL", r.nameOf("database_url"));
    try testing.expectEqualStrings("PORT", r.nameOf("port"));
}

test "a prefix goes in front of every name" {
    const r = fill(Settings, "NILO_", Fixed{ .pairs = &.{
        .{ "NILO_DATABASE_URL", "postgres://" },
    } });
    try testing.expectEqualStrings("NILO_DATABASE_URL", r.nameOf("database_url"));
    try testing.expect(!r.failed());
    // The unprefixed name is not read, which is the point of asking for one.
    const bare = fill(Settings, "NILO_", Fixed{ .pairs = &.{
        .{ "DATABASE_URL", "postgres://" },
    } });
    try testing.expect(bare.failed());
}

test "what is not set falls back to the default" {
    const r = read(&.{.{ "DATABASE_URL", "postgres://" }});
    const settings = r.value().?;
    try testing.expectEqual(@as(u16, 8080), settings.port);
    try testing.expectEqual(.info, settings.log_level);
    try testing.expectEqual(@as(?u8, null), settings.workers);
}

test "a setting with no default and no ? is missing when nothing is set" {
    const r = read(&.{.{ "PORT", "9000" }});
    try testing.expect(r.failed());
    try testing.expectEqual(@as(usize, 1), r.failedCount());
    try testing.expectEqual(@as(?Settings, null), r.value());

    var it = r.failures();
    const f = it.next().?;
    try testing.expectEqualStrings("database_url", f.field);
    try testing.expectEqualStrings("DATABASE_URL", f.name);
    try testing.expectEqual(Reason.missing, f.reason);
    try testing.expectEqualStrings("", f.given);
    try testing.expectEqual(@as(?Failure, null), it.next());
}

test "an optional with no default is null rather than missing" {
    const r = read(&.{.{ "DATABASE_URL", "postgres://" }});
    try testing.expect(!r.failed());
    try testing.expectEqual(@as(?u8, null), r.value().?.workers);
}

test "a default beats the ? when both could answer" {
    // `?u8 = 5` not being set means 5, not null: both say "nothing was
    // set", and only the default says what to do about it.
    const WithDefault = struct { workers: ?u8 = 5 };
    const r = fill(WithDefault, "", Fixed{ .pairs = &.{} });
    try testing.expectEqual(@as(?u8, 5), r.value().?.workers);
}

test "every bad setting is named at once, not just the first" {
    // The whole feature. Three mistakes, one run.
    const r = read(&.{
        .{ "PORT", "soon" },
        .{ "LOG_LEVEL", "verbose" },
    });

    try testing.expect(r.failed());
    try testing.expectEqual(@as(usize, 3), r.failedCount());

    var it = r.failures();
    const port = it.next().?;
    try testing.expectEqualStrings("PORT", port.name);
    try testing.expectEqual(Reason.not_a_number, port.reason);
    try testing.expectEqualStrings("soon", port.given);

    const url = it.next().?;
    try testing.expectEqualStrings("DATABASE_URL", url.name);
    try testing.expectEqual(Reason.missing, url.reason);

    const level = it.next().?;
    try testing.expectEqualStrings("LOG_LEVEL", level.name);
    try testing.expectEqual(Reason.not_a_choice, level.reason);
    try testing.expectEqualStrings("verbose", level.given);

    try testing.expectEqual(@as(?Failure, null), it.next());
}

test "failures are walked in the order the struct declares them" {
    const r = read(&.{ .{ "PORT", "soon" }, .{ "LOG_LEVEL", "verbose" } });
    var it = r.failures();
    try testing.expectEqualStrings("port", it.next().?.field);
    try testing.expectEqualStrings("database_url", it.next().?.field);
    try testing.expectEqualStrings("log_level", it.next().?.field);
}

test "the text that arrived is kept whether or not it converted" {
    const r = read(&.{
        .{ "PORT", "soon" },
        .{ "DATABASE_URL", "postgres://" },
    });
    try testing.expectEqualStrings("soon", r.given("port"));
    try testing.expectEqualStrings("postgres://", r.given("database_url"));
    // Nothing was set under this one at all.
    try testing.expectEqualStrings("", r.given("workers"));
}

test "the report names every setting and how many there are" {
    const r = read(&.{ .{ "PORT", "soon" }, .{ "LOG_LEVEL", "verbose" } });

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);

    try testing.expectEqualStrings(
        \\3 settings could not be read from the environment:
        \\  PORT has to be a whole number, not "soon"
        \\  DATABASE_URL is not set
        \\  LOG_LEVEL has to be one of debug, info, warn, not "verbose"
        \\
    , buf[0..w.end]);
}

test "one bad setting is reported in the singular" {
    const r = read(&.{ .{ "DATABASE_URL", "postgres://" }, .{ "PORT", "soon" } });

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);

    try testing.expectEqualStrings(
        \\1 setting could not be read from the environment:
        \\  PORT has to be a whole number, not "soon"
        \\
    , buf[0..w.end]);
}

test "a reading with nothing wrong reports nothing at all" {
    const r = read(&.{.{ "DATABASE_URL", "postgres://" }});

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);
    try testing.expectEqual(@as(usize, 0), w.end);
}

test "a value set to the empty string is set, and fails on its own terms" {
    // `DATABASE_URL=` in a shell sets it. Text takes it; a number does not,
    // and says so as a conversion rather than as `missing` — which is the
    // difference between "you forgot this" and "this is empty".
    const r = read(&.{ .{ "DATABASE_URL", "" }, .{ "PORT", "" } });

    var it = r.failures();
    const port = it.next().?;
    try testing.expectEqual(Reason.not_a_number, port.reason);
    // `DATABASE_URL` is not among them: empty text is still text.
    try testing.expectEqual(@as(?Failure, null), it.next());

    // And an empty value on its own reads clean.
    const only_text = read(&.{.{ "DATABASE_URL", "" }});
    try testing.expectEqualStrings("", only_text.value().?.database_url);
}

test "a message with braces in it survives being reported" {
    const r = read(&.{ .{ "DATABASE_URL", "postgres://" }, .{ "PORT", "{d}" } });

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try r.report(&w);

    try testing.expectEqualStrings(
        \\1 setting could not be read from the environment:
        \\  PORT has to be a whole number, not "{d}"
        \\
    , buf[0..w.end]);
}
