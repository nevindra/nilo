const std = @import("std");

/// The directories a module is rooted in. Two modules ship, so two
/// directories do, and `.paths` in `build.zig.zon` is the one place that has
/// to remember — a dependent whose `.paths` is missing one gets a package
/// without that module and finds out at their own build (ADR 0039).
///
/// Checked here rather than in a test, because a check that runs on every
/// `zig build` cannot be the thing somebody forgot to run.
const shipped_roots = [_][]const u8{ "src", "sql" };

comptime {
    const manifest = @embedFile("build.zig.zon");
    @setEvalBranchQuota(8 * manifest.len + 1_000);
    for (shipped_roots) |root| {
        const quoted = "\"" ++ root ++ "\"";
        if (std.mem.indexOf(u8, manifest, quoted) == null) @compileError(
            "zfast: a module is rooted in `" ++ root ++
                "/` and build.zig.zon's `.paths` does not list it.\n" ++
                "  A dependent would fetch a package with that module missing.",
        );
    }
}

const examples = [_]Example{
    .{ .name = "hello", .about = "The smallest thing that serves" },
    .{ .name = "rest", .about = "Typed handlers, a service, fail functions, middleware" },
    .{ .name = "orders", .about = "Nested resources, nested bodies, a state machine, an upsert" },
    .{ .name = "forms", .about = "An HTML form, a session cookie, an upload and a redirect" },
    .{ .name = "spa", .about = "A single-page app's files plus a JSON API" },
    .{ .name = "stream", .about = "A streamed report and a stream of events" },
    .{ .name = "chat", .about = "A WebSocket, from the handshake to the last frame" },
};

const Example = struct { name: []const u8, about: []const u8 };

/// The same, for `sql/refusals/`. A separate list because they hang off
/// `test-sql` rather than `test` — the framework's loop does not pay for a
/// module it does not import (ADR 0039).
const sql_refusals = [_]Refusal{
    .{
        .name = "any_empty",
        .says = "`.any` is empty.",
    },
    .{
        .name = "any_not_a_list",
        .says = "`.any` holds a list of conditions and this one is a single condition.",
    },
    .{
        .name = "borrowed_column_not_in_base",
        .says = "borrowed_column_not_in_base.UserCard reads `emial`, which borrowed_column_not_in_base.User does not have.",
    },
    .{
        .name = "borrowed_column_wrong_type",
        .says = "borrowed_column_wrong_type.UserCard reads `age` as []const u8, and borrowed_column_wrong_type.User reads it as i32.",
    },
    .{
        .name = "borrowed_from_a_non_row",
        .says = "borrowed_from_a_non_row.UserCard's zfast_table names borrowed_from_a_non_row.Settings, which is not a Row.",
    },
    .{
        .name = "compared_with_null",
        .says = "`gt` was given null on column `deleted_at`.",
    },
    .{
        .name = "condition_on_unknown_column",
        .says = "condition_on_unknown_column.User has no column `agee`, asked for in a condition.",
    },
    .{
        .name = "delete_without_condition",
        .says = "a delete on delete_without_condition.User with no condition.",
    },
    .{
        .name = "key_not_a_column",
        .says = "key_not_a_column.User's key names the column `user_id`, which is not one of its columns.",
    },
    .{
        .name = "negative_limit",
        .says = "`.limit` is -1.",
    },
    .{
        .name = "no_id_and_no_key",
        .says = "no_id_and_no_key.Membership has no column `id`, so its zfast_table has to say which column identifies a row.",
    },
    .{
        .name = "not_a_row",
        .says = "not_a_row.User is not a Row — it has no `zfast_table`.",
    },
    .{
        .name = "order_on_unknown_column",
        .says = "order_on_unknown_column.User has no column `creted_at`, asked for in `.order`.",
    },
    .{
        .name = "reserved_column_any",
        .says = "reserved_column_any.Answer has a column named `any`, which is the word a condition uses for OR.",
    },
    .{
        .name = "table_unknown_option",
        .says = "table_unknown_option.User's zfast_table sets `.primary`, which is not part of it.",
    },
    .{
        .name = "table_without_name",
        .says = "table_without_name.User's zfast_table does not say `.name`.",
    },
    .{
        .name = "unknown_select_option",
        .says = "a select on unknown_select_option.User was given `.limti`, which is not one of its options.",
    },
};

/// One entry per file in `refusals/`: a program written wrong on purpose, and
/// the first line of the error it has to stop with. `says` leaves out the
/// `zfast: ` prefix because the build step adds it — see the loop in `build`.
const refusals = [_]Refusal{
    .{
        .name = "argument_not_recognised",
        .says = "argument 1 of the handler for route \"/users/:id\" is a [4]u8, which zfast does not recognise.",
    },
    .{
        .name = "bound_field_cannot_convert",
        .says = "the field `tags: []const u8` of the `Bound(Form(bound_field_cannot_convert.SignUp))` on route \"/sign-up\" is not something a form value can become.",
    },
    .{
        .name = "bound_form_and_form",
        .says = "the handler for route \"/sign-up\" asks for the form twice — argument 1 and argument 2.",
    },
    .{
        .name = "bound_given_unknown_field",
        .says = "`bound_given_unknown_field.SignUp` has no field `e_mail`.",
    },
    .{
        .name = "bound_not_a_struct",
        .says = "`Bound(u32)` — a binding is read into a struct.",
    },
    .{
        .name = "bound_of_a_bound",
        .says = "`Bound(Bound(…))` — a binding is already a binding.",
    },
    .{
        .name = "colon_mid_segment",
        .says = "the segment \"id:id\" of route \"/users/id:id\" has a `:` in the middle of it, so it is matched as literal text.",
    },
    .{
        .name = "cors_credentials_with_any_origin",
        .says = "cors credentials cannot be combined with origin \"*\" — browsers reject it.",
    },
    .{
        .name = "filebody_as_an_argument",
        .says = "argument 1 of the handler for route \"/invoices\" is a `zfast.FileBody`, which is what a handler answers *with* rather than something it is given.",
    },
    .{
        .name = "form_and_body",
        .says = "the handler for route \"/sign-up\" asks for both a request body (argument 1, a form_and_body.Profile) and a form (argument 2) — and a request only has one body.",
    },
    .{
        .name = "form_field_cannot_convert",
        .says = "the field `tags: []const u8` of the `Form(form_field_cannot_convert.SignUp)` on route \"/sign-up\" is not something a form value can become.",
    },
    .{
        .name = "form_not_a_struct",
        .says = "the `Form(u32)` on route \"/sign-up\" is not a struct.",
    },
    .{
        .name = "form_with_no_fields",
        .says = "the `Form(form_with_no_fields.Empty)` on route \"/sign-up\" has no fields, so it would read nothing.",
    },
    .{
        .name = "group_no_slash",
        .says = "the group prefix \"api\" does not start with a slash.",
    },
    .{
        .name = "group_pattern_empty",
        .says = "a route pattern inside the group \"/api\" cannot be empty.",
    },
    .{
        .name = "group_pattern_no_slash",
        .says = "the route pattern \"users\" inside the group \"/api\" does not start with a slash.",
    },
    .{
        .name = "group_prefix_has_wildcard",
        .says = "the group prefix \"/files/*\" has a `*` in it, and a catch-all cannot be a prefix.",
    },
    .{
        .name = "group_trailing_slash",
        .says = "the group prefix \"/api/\" ends with a slash.",
    },
    .{
        .name = "handler_is_generic",
        .says = "the handler for route \"/users/:id\" is still generic (it has an `anytype` or `comptime` argument).",
    },
    .{
        .name = "handler_is_varargs",
        .says = "the handler for route \"/\" uses C varargs, which cannot be matched.",
    },
    .{
        .name = "handler_not_a_function",
        .says = "the handler for route \"/\" has to be a function, not comptime_int.",
    },
    .{
        .name = "param_is_a_many_pointer",
        .says = "argument 1 of the handler for route \"/greet/:name\" is a [*]const u8, which cannot be matched.",
    },
    .{
        .name = "param_is_a_slice",
        .says = "argument 1 of the handler for route \"/greet/:name\" is a []const u8.",
    },
    .{
        .name = "param_is_optional",
        .says = "argument 1 of the handler for route \"/users/:id\" is a ?u32.",
    },
    .{
        .name = "param_name_twice",
        .says = "the route pattern \"/users/:id/pets/:id\" uses the param name `:id` twice.",
    },
    .{
        .name = "param_with_no_name",
        .says = "the route pattern \"/users/:\" has a `:` with no name after it.",
    },
    .{
        .name = "patch_as_an_argument",
        .says = "argument 2 of the handler for route \"/users/:id\" is a `Patch(…)`, which is a field of a request body rather than an argument of its own.",
    },
    .{
        .name = "pattern_empty",
        .says = "a route pattern cannot be empty.",
    },
    .{
        .name = "pattern_no_slash",
        .says = "the route pattern \"users\" does not start with a slash.",
    },
    .{
        .name = "provide_a_slice",
        .says = "app.provide() wants a pointer to a single value, not []provide_a_slice.Db.",
    },
    .{
        .name = "provide_not_a_pointer",
        .says = "app.provide() wants a pointer to a service, not provide_not_a_pointer.Db.",
    },
    .{
        .name = "query_field_cannot_convert",
        .says = "the field `tags: []const u8` of the `Query(query_field_cannot_convert.Search)` on route \"/users\" is not something a query value can become.",
    },
    .{
        .name = "query_not_a_struct",
        .says = "argument 1 of the handler for route \"/users\" is a `Query(u32)`, but u32 is not a struct.",
    },
    .{
        .name = "query_with_no_fields",
        .says = "the `Query(query_with_no_fields.Search)` on route \"/users\" has no fields, so it would read nothing.",
    },
    .{
        .name = "redirect_not_a_redirect",
        .says = "`Redirect(200)` is not a redirect.",
    },
    .{
        .name = "resolver_argument_not_allowed",
        .says = "argument 1 of the resolver on `resolver_argument_not_allowed.Caller` is a u32, which a resolver cannot be given.",
    },
    .{
        .name = "resolver_is_generic",
        .says = "argument 1 of the resolver on `resolver_is_generic.Caller` has no type.",
    },
    .{
        .name = "resolver_is_not_a_function",
        .says = "`resolver_is_not_a_function.Caller.zfast_resolve` is a comptime_int, not a function.",
    },
    .{
        .name = "resolver_loop",
        .says = "the resolved value `resolver_loop.Caller` is worked out from itself — resolver_loop.Caller → resolver_loop.Tenant → resolver_loop.Caller",
    },
    .{
        .name = "resolver_returns_wrong_type",
        .says = "the resolver on `resolver_returns_wrong_type.Caller` returns zfast.Str, not resolver_returns_wrong_type.Caller.",
    },
    .{
        .name = "response_headers_not_a_list",
        .says = "Response headers have to be written out where they are set — .of(&.{.{ .name = \"Location\", .value = where }}) — and this is a []zfast.Header.",
    },
    .{
        .name = "session_field_is_a_slice",
        .says = "`[]const u8` cannot be part of a session, because it is not something a session can carry.",
    },
    .{
        .name = "session_not_a_struct",
        .says = "the `Session(u32)` is not a struct.",
    },
    .{
        .name = "session_too_big_for_a_cookie",
        .says = "a `Session(session_too_big_for_a_cookie.Signed)` would be 5528 bytes in the cookie, and the most that fits is 3800.",
    },
    .{
        .name = "session_with_no_fields",
        .says = "the `Session(session_with_no_fields.Empty)` has no fields, so it would remember nothing.",
    },
    .{
        .name = "too_few_pattern_params",
        .says = "argument 1 of the handler for route \"/users\" is a u32, so zfast reads it as a path param — but the route has no path params at all.",
    },
    .{
        .name = "too_many_params",
        .says = "the route pattern \"/:a/:b/:c/:d/:e/:f/:g/:h/:i\" captures 9 params, and the most zfast holds is 8.",
    },
    .{
        .name = "too_many_response_headers",
        .says = "a Response can carry 8 headers and this one was given 9.",
    },
    .{
        .name = "too_many_segments",
        .says = "the route pattern \"/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q\" has 17 segments, and the most zfast matches is 16.",
    },
    .{
        .name = "two_bodies",
        .says = "the handler for route \"/orders\" takes two structs by value — argument 1 is a two_bodies.Store and argument 2 is a two_bodies.NewOrder — and a request only has one body.",
    },
    .{
        .name = "two_forms",
        .says = "the handler for route \"/sign-up\" asks for the form twice — argument 1 and argument 2.",
    },
    .{
        .name = "two_queries",
        .says = "the handler for route \"/users\" asks for the query string twice — argument 1 and argument 2.",
    },
    .{
        .name = "unused_pattern_params",
        .says = "route \"/users/:user/pets/:pet\" has 2 path params (:user, :pet), but its handler only takes 1.",
    },
    .{
        .name = "upload_as_an_argument",
        .says = "argument 1 of the handler for route \"/avatars\" is a `zfast.Upload`, which is a field of a form rather than an argument of its own.",
    },
    .{
        .name = "wildcard_in_segment",
        .says = "the segment \"img*\" of route \"/files/img*\" mixes `*` with other text.",
    },
    .{
        .name = "wildcard_not_last",
        .says = "the route pattern \"/files/*/raw\" has a `*` that is not the last segment.",
    },
};

const Refusal = struct { name: []const u8, says: []const u8 };

/// The suite runs in both modes, and `-Doptimize=` does not change that — a
/// lifetime bug passes in `Debug`, where the bytes a dangling pointer points at
/// happen to still be there, and segfaults in a release build, which is the
/// mode the README tells people to deploy in. Not a hypothetical:
/// `Response.headers` got away with a use-after-return for a whole stage
/// because nothing here ever built the tests any other way
/// ([ADR 0019](docs/adr/0019-a-response-owns-its-headers.md)).
///
/// What changed is *when* the second mode is paid for. Measured on Zig 0.16, a
/// warm suite is 0.8s in `Debug` and 7.8s in both, so both-modes-every-time was
/// charging 10× to the loop somebody sits in. `test` is now the loop and
/// `test-all` is the gate; CI runs `test-all` on every push, so the rule is
/// still held by something other than remembering.
const loop_mode: std.builtin.OptimizeMode = .Debug;
const test_modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe };

/// Debug info is half of a release build. Measured on Zig 0.16, warm, one
/// source file changed: `-Doptimize=ReleaseFast` is 14.7s, and the same build
/// with debug info off is 7.3s. Linking is not in it either way — `build-obj`
/// and `build-exe` came out 30ms apart — and the whole frontend, every comptime
/// handler included, is 0.5s. The 7.4s is LLVM, twice: DWARF that never gets
/// generated, and metadata that no longer has to be carried through every
/// optimisation pass. Some of it is code that stops existing, because with
/// nothing to read, std's stack-trace machinery — a DWARF reader and an ELF
/// parser — is dead: `.text` goes from 787 KB to 498 KB.
///
/// At runtime it costs nothing measurable: 1,996,698 req/s against 1,988,414,
/// which is inside this machine's noise. What it costs is the file and the line
/// on every frame of a panic.
///
/// So the default is per-artifact rather than one switch for the repo. The two
/// binaries whose whole job is to be measured give up their debug info in the
/// mode they are measured in; the examples and the tests, which are things a
/// person runs and may have to debug, keep theirs. `-Dstrip` overrides either
/// way, and `-Dstrip=false` gets the old behaviour back everywhere.
///
/// The return is `?bool` and not `bool` on purpose. Zig already leaves debug
/// info out in `ReleaseSmall`, and an unconditional `false` would be this file
/// quietly switching that back on: measured, a warm `ReleaseSmall` went from
/// 3.7s to 6.9s while the `null` was missing. Only `ReleaseFast` is decided
/// here. Every other mode is left to say what it wants.
fn stripMeasured(strip: ?bool, optimize: std.builtin.OptimizeMode) ?bool {
    if (strip) |asked| return asked;
    return if (optimize == .ReleaseFast) true else null;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Leave debug info out: halves a release build, costs nothing measurable at runtime, and leaves a panic without file and line");

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    // The library itself, under the name it is imported by. Everything
    // else here — the benchmark server, every example — depends on this
    // exactly the way somebody else's project would.
    const zfast = b.addModule("zfast", .{
        .root_source_file = b.path("src/zfast.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zio", .module = zio.module("zio") },
        },
    });

    // The SQL module: a second module beside the library rather than inside
    // it (ADR 0039). The dependency runs one way — `sql` on `zfast`, never
    // back — which is what makes this feature cost a project that does not
    // import it exactly zero bytes. It lives in `sql/` rather than under
    // `src/` so that the convention about adding an `_ = @import(…)` line to
    // `src/zfast.zig` cannot pull it into every build by being followed.
    const zfast_sql = b.addModule("zfast_sql", .{
        .root_source_file = b.path("sql/sql.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zfast", .module = zfast },
        },
    });

    // The benchmark target: a routed GET with a path param returning ~1KB
    // of JSON, which is the primary metric in docs/history.md.
    const bench = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = stripMeasured(strip, optimize),
        .imports = &.{.{ .name = "zfast", .module = zfast }},
    });

    const exe = b.addExecutable(.{ .name = "zfast-hello", .root_module = bench });
    b.installArtifact(exe);
    b.step("run", "Run the benchmark server").dependOn(&b.addRunArtifact(exe).step);

    // Where the time inside one request goes. Not a test: a number that
    // moves with the weather has no business failing a build.
    const profile = b.addExecutable(.{
        .name = "zfast-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/profile.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .strip = stripMeasured(strip, .ReleaseFast),
            .imports = &.{.{ .name = "zio", .module = zio.module("zio") }},
        }),
    });
    b.step("profile", "Time the pieces of one request").dependOn(&b.addRunArtifact(profile).step);

    // Generated requests thrown at the parser, checking the properties in
    // `src/fuzz.zig`. Separate from `test` because it runs until it is bored
    // rather than until it is done, and the corpus half of the same
    // properties already runs on every `zig build test`.
    //
    // `ReleaseSafe` and not the caller's mode: the safety checks are the
    // point — an index out of bounds is the class of bug this is looking for
    // — and the speed is what makes a million inputs a coffee break rather
    // than an afternoon.
    const fuzzer = b.addExecutable(.{
        .name = "zfast-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_main.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "zio", .module = zio.module("zio") }},
        }),
    });
    const run_fuzzer = b.addRunArtifact(fuzzer);
    if (b.args) |args| run_fuzzer.addArgs(args);
    b.step("fuzz", "Throw generated requests at the parser").dependOn(&run_fuzzer.step);

    // `test` is the loop: Debug, plus the refusals, which are cheap. `test-all`
    // is everything `test` does and the same suite again in ReleaseSafe. Both
    // exist because the second mode catches a class of bug the first cannot,
    // and CI runs `test-all` so that staying fast locally does not mean
    // shipping without it.
    const test_step = b.step("test", "Run the tests in Debug — the fast loop");
    const test_all_step = b.step("test-all", "Run the tests in Debug and ReleaseSafe — what CI runs");
    test_all_step.dependOn(test_step);

    // The SQL module keeps its own step, and `test` does not depend on it
    // (ADR 0039). Not for speed: it has a tier that cannot run without a
    // database at all, and mixing a step that needs Postgres into the one
    // run every thirty seconds is the wrong place for it. What is here is
    // the half that needs nothing — generated SQL and the schema comparison
    // are both pure functions, the same reason `App.handleRequest` is tested
    // against in-memory buffers.
    const test_sql_step = b.step("test-sql", "Run the SQL module's tests — no database needed");
    test_all_step.dependOn(test_sql_step);

    // The SQL module's Refusals, held the same way the framework's are (ADR
    // 0027) and hung off `test-sql` rather than `test`. Every comptime check
    // in `sql/` answers a question a database would otherwise answer at run
    // time, so the wording of these is the whole point of doing it early.
    const refusals_sql_step = b.step(
        "refusals-sql",
        "Check that each SQL mistake stops in zfast's own words",
    );
    for (sql_refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("sql/refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zfast_sql", .module = zfast_sql }},
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: zfast: {s}", .{refusal.says}) };
        refusals_sql_step.dependOn(&refused.step);
    }
    test_sql_step.dependOn(refusals_sql_step);

    for (test_modes) |mode| {
        const sql_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("sql/sql.zig"),
                .target = target,
                .optimize = mode,
            }),
        });
        test_sql_step.dependOn(&b.addRunArtifact(sql_tests).step);
    }

    for (test_modes) |mode| {
        const step = if (mode == loop_mode) test_step else test_all_step;
        // Each mode needs its own copy of everything, down to zio: a module
        // carries the optimize mode it was created with.
        const engine = b.dependency("zio", .{ .target = target, .optimize = mode });

        // The library's tests run under a root of their own so there is one
        // place to say what a test build's root actually is: the compiler's
        // test runner, not this file. That matters because a test that logs
        // reaches stderr, and the build runner answers stderr from a test
        // process with a red `failed command` block above a summary saying
        // every step passed — see `src/test_root.zig`.
        const lib_tests = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "zio", .module = engine.module("zio") }},
        });

        const library = b.createModule(.{
            .root_source_file = b.path("src/zfast.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "zio", .module = engine.module("zio") }},
        });

        const bench_tests = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "zfast", .module = library }},
        });

        for ([_]*std.Build.Module{ lib_tests, bench_tests }) |module| {
            const tests = b.addTest(.{ .root_module = module });
            step.dependOn(&b.addRunArtifact(tests).step);
        }

        // The examples carry the tests the README promises are possible, so
        // they run with everything else rather than being decoration.
        for (examples) |example| {
            const module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{example.name})),
                .target = target,
                .optimize = mode,
                .imports = &.{.{ .name = "zfast", .module = library }},
            });
            const tests = b.addTest(.{ .root_module = module });
            step.dependOn(&b.addRunArtifact(tests).step);
        }
    }

    // ADR 0015 says a mistake stops in zfast's own words. Nothing held that
    // rule until this step: each file in `refusals/` is a program somebody
    // wrote wrong, and each has to fail to compile with the message named
    // above. Note what the loop does with `.says` — it supplies the `zfast: `
    // prefix itself, so a check that stops somewhere inside the standard
    // library cannot be written down as passing, only fixed or deleted
    // ([ADR 0027](docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).
    //
    // **They do not cache, and they are the slow part of `zig build test`.**
    // The compiler keeps nothing from a compilation that failed, so every
    // refusal is re-analysed every run: measured warm on Zig 0.16.0, all 46
    // are ~12.8s of a ~17s `zig build test`, at roughly 270ms each.
    //
    // A note here once said the opposite — that Zig 0.16 had started caching
    // them and all 39 were 0.5s. That was measured wrong and is corrected in
    // [ADR 0027](docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md);
    // the original entry's number, about 9 seconds, was right all along.
    //
    // They stay on `test` at that price, which is the trade the ADR argues:
    // enforcement that has to be asked for is a sentence in a document again.
    // If the loop somebody sits in gets too slow to sit in, the move is to
    // take them off `test` and leave them on `test-all` — not to stop
    // checking.
    const refusals_step = b.step("refusals", "Check that each mistake stops in zfast's own words");
    for (refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zfast", .module = zfast }},
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: zfast: {s}", .{refusal.says}) };
        refusals_step.dependOn(&refused.step);
    }
    test_step.dependOn(refusals_step);

    // Every example is built by `zig build examples`, so one that stops
    // compiling is a failed build rather than a surprise for the first
    // person who copies it.
    const examples_step = b.step("examples", "Build every example");
    for (examples) |example| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            // Deliberately not `stripMeasured`: an example is run by a person,
            // and the first thing they need from a crash is where it was.
            .strip = strip,
            .imports = &.{.{ .name = "zfast", .module = zfast }},
        });
        const built = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{example.name}),
            .root_module = module,
        });
        examples_step.dependOn(&b.addInstallArtifact(built, .{}).step);

        const run = b.addRunArtifact(built);
        // Run from the example's own directory: the static one reads its
        // files from a path relative to the working directory.
        run.setCwd(b.path(b.fmt("examples/{s}", .{example.name})));
        b.step(b.fmt("run-{s}", .{example.name}), example.about).dependOn(&run.step);
    }

}
