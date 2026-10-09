const std = @import("std");

/// The directories a module is rooted in. One per shipped module (ADR 038),
/// and `.paths` in `build.zig.zon` is the one place that has to remember — a
/// dependent whose `.paths` is missing one gets a package without that module
/// and finds out at their own build (ADR 036).
///
/// Checked here rather than in a test, because a check that runs on every
/// `zig build` cannot be the thing somebody forgot to run.
///
/// **Adding a module means adding a row here as well as to `.paths`.** Core
/// shipped for a whole session with neither, and nothing noticed, because a
/// list that does not name a directory cannot check it.
///
/// `template` is not a module either: it is the project `nilo.app` is
/// shown on, copied out of the package by a first project (ADR 263).
///
/// `dev` is not a module — nothing imports it — but a dependent builds
/// `nilo.artifact("nilo-dev")` from it, so it ships the same way (ADR 190).
const shipped_roots = [_][]const u8{ "core", "id", "config", "pw", "cache", "jwt", "proto", "fetch", "job", "http", "sql", "s3", "dev", "template" };

comptime {
    const manifest = @embedFile("build.zig.zon");
    // Derived from the list rather than written as a constant: the ninth
    // module made the old `8 *` too small, and a quota that has to be raised
    // by hand every time a module lands is a quota that fails the build for
    // the wrong reason.
    @setEvalBranchQuota(2 * shipped_roots.len * manifest.len + 1_000);
    for (shipped_roots) |root| {
        const quoted = "\"" ++ root ++ "\"";
        if (std.mem.indexOf(u8, manifest, quoted) == null) @compileError(
            "nilo: a module is rooted in `" ++ root ++
                "/` and build.zig.zon's `.paths` does not list it.\n" ++
                "  A dependent would fetch a package with that module missing.",
        );
    }
}

/// What each module below the App is allowed to name, and the whole of it
/// (ADR 038). A module imports downward only, and until now that was a
/// sentence in a document — the same shape of rule
/// [ADR 026](docs/adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md)
/// took away from documents and gave to a build step, for the same reason.
///
/// The lists are short and that is the point: what a row grows by is the
/// argument somebody has to make out loud.
///
/// **`in_tests` is allowed, not verified.** A module's tests may reach one
/// layer up, because an `@import` referenced only from a `test` block is
/// never analysed in a build that is not a test build (ADR 038). Telling
/// those apart needs a parser rather than a scan, so this file lists the
/// exception instead of proving it — which still beats a rule that nothing
/// checks at all, and which is why the lists live here where they can be
/// read rather than inside the step.
const layers = [_]Layer{
    .{ .root = "core", .may_import = &.{} },
    .{ .root = "id", .may_import = &.{} },
    // A tool module may name Core and this one does not, which is the whole
    // of why it can be read into `[]const u8` rather than a `Str` (ADR
    // 039). Settings are read once before the socket opens and held for
    // the life of the process; the lifetime a `Str` carries would have
    // nothing to say about them, and naming `nilo_core` to get one would
    // cost the property that decides the layer — `zig test
    // config/config.zig`, with no module graph at all.
    .{ .root = "config", .may_import = &.{} },
    // The third tool module, and it names nothing either (ADR 044). What it
    // wanted from a layer above was entropy, a thread to hold and a count of
    // how many hashes are already running — and all three are arguments or
    // the caller's, which is what keeps `zig test pw/pw.zig` the whole of its
    // suite. `http/password.zig` is the half that has a Bulkhead.
    .{ .root = "pw", .may_import = &.{} },
    // The fourth, and it names nothing either (ADR 109). What it wanted from
    // a layer above was a clock and a lock, and it has neither: the clock is
    // `clock_gettime` written a second time rather than `nilo_core`'s, and
    // the lock spins because `std.Io.Mutex` needs an `Io` this layer does not
    // have. Both of those are the layer deciding the design rather than the
    // other way round, which is why the row is empty.
    .{ .root = "cache", .may_import = &.{} },
    .{ .root = "jwt", .may_import = &.{} },
    // The sixth, and it names nothing either (ADR 245): protobuf is bytes in
    // and bytes out, the allocator is the caller's and a message is a struct
    // the caller declared. `zig test proto/proto.zig` is the whole suite.
    .{ .root = "proto", .may_import = &.{} },
    // The first Fitting (ADR 061): it borrows the loop and owns no
    // destination. That is what puts it below a Service and above a tool
    // module — `zig test fetch/fetch.zig` needs `nilo_core` and so needs the
    // module graph, which a tool module may not, and it holds no connection to
    // any named system, which a Service does.
    .{
        .root = "fetch",
        // `net_config` is generated by this file and holds one bool: whether
        // `smoke-tls` may reach the internet. Named here rather than in
        // `in_tests` because it is not a layer and the import is not upward —
        // the same place `sql` puts `live_config`, for the same reason.
        .may_import = &.{ "nilo_core", "net_config" },
        // `fetch/deadline.zig` names the server, because the one thing it
        // tests is a deadline the Engine has to fire and only a running
        // server has one (ADR 056, ADR 061). Same exception `sql` carries,
        // and the same weakness: the step cannot see that it is test-only.
        .in_tests = &.{"nilo_http"},
    },
    // The second Fitting (ADR 160): a queue borrows the loop to wait on and
    // owns no destination — the store it runs on is handed to it as a type,
    // which is why `job/table.zig` sits on a `nilo_sql` Db and this row still
    // names no `nilo_sql`. `job/live.zig` is the test root that does, for the
    // reason `fetch/deadline.zig` names `nilo_http`: the one thing it tests
    // is the table, and only a database has one. The Space a status is kept
    // in is duck-typed the same way, so `nilo_cache` is here for the same
    // root and no other file.
    .{
        .root = "job",
        .may_import = &.{"nilo_core"},
        .in_tests = &.{ "nilo_sql", "nilo_cache", "live_config" },
    },
    .{
        .root = "sql",
        // Two drivers, two rows in this list, and both are third-party rather
        // than sideways: a Wire names a driver and nothing above it
        // (ADR 036, ADR 064).
        .may_import = &.{ "nilo_core", "nilo_id", "pg", "zqlite", "live_config" },
        .in_tests = &.{"nilo_http"},
    },
    // A Service that dials, and **the first module to name a Fitting**
    // (ADR 063). That is downward rather than sideways — a Fitting borrows
    // the loop and owns no destination, a Service holds one — and it is the
    // import ADR 061 was built to make legal, which is why this row is one
    // line rather than an argument.
    //
    // No `pg`-shaped dependency to be lazy about: what would have been an
    // HTTP client and a TLS stack is `std`'s, reached through `nilo_fetch`,
    // so this module's dependency count is zero (ADR 058).
    .{ .root = "s3", .may_import = &.{ "nilo_core", "nilo_fetch", "s3_config" } },
};

/// The one layering rule `http/` can hold, and the account of why it is only
/// one.
///
/// Every row in `layers` above is a module with a boundary around it. Inside
/// `http/` there is no such stack: `app`, `ctx`, `router`, `typed`, `serve`,
/// `wiring` and twelve more form **one strongly connected component** — each
/// reaches each, and Zig's lazy analysis lets them. Writing a tier table over
/// that would be writing down a hierarchy that is not there.
///
/// What *is* there is a boundary at its edge. Twenty-five files under `http/`
/// name nothing in the core, which is what lets them be read on their own and
/// several of them be run with a plain `zig test http/<file>.zig`. This step
/// refuses the import that would pull one of them in, because that import is
/// how the core got to seventeen in the first place.
///
/// **Test blocks are exempt and this step can see it**, unlike the `in_tests`
/// lists above: an import below the file's first `test` is a test's, and a
/// scan can find that line. `static.zig` reaches for `app.zig` there and is
/// not refused.
///
/// A file leaves this list by having nothing in the core name it and by
/// naming nothing in the core. That is the whole of the work, and the list
/// getting shorter is the point of writing it down.
const http_core = [_][]const u8{
    "app",      "bound",      "bytebody", "ctx",        "filebody", "form",
    "metrics",  "middleware", "openapi",  "password",   "pathparams", "resolve",
    "router",   "sendfile",   "serve",    "session",    "testing",    "typed",
    "typedmw",  "wiring",
};

/// Files that sit **above** the core rather than below it, and so may name it.
///
/// The middleware modules and the roots. A middleware is handed a `Ctx`
/// and a `Next`, so naming `ctx.zig` and `middleware.zig` is downward for it;
/// nothing in the core names any of them back, which is why they are not in
/// the component.
const http_above_core = [_][]const u8{
    "logger",    "cors",        "csrf",      "secure", "allowance", "deadline",
    "maxbody",   "http",        "behaviour", "live",   "profile",   "fuzz",
    "fuzz_main", "fuzz_llhttp", "test_root", "wide",   "h2test",
};

const Layer = struct {
    root: []const u8,
    may_import: []const []const u8,
    in_tests: []const []const u8 = &.{},
};

const examples = [_]Example{
    .{ .name = "hello", .about = "The smallest thing that serves" },
    .{ .name = "rest", .about = "Typed handlers, a service, fail functions, middleware" },
    .{ .name = "orders", .about = "Nested resources, nested bodies, a state machine, an upsert" },
    .{ .name = "forms", .about = "An HTML form, a session cookie, an upload and a redirect" },
    .{ .name = "spa", .about = "A single-page app's files plus a JSON API" },
    .{
        .name = "embedded",
        .about = "A single-page app carried inside the binary, listed from its build output",
        .embeds = "examples/embedded/dist",
    },
    .{ .name = "stream", .about = "A streamed report and a stream of events" },
    .{ .name = "chat", .about = "A WebSocket, from the handshake to the last frame" },
    .{ .name = "scheduled", .about = "Work that is not a request, and a shutdown that reaches it" },
    .{
        .name = "outbound",
        .about = "Calling somebody else's API from inside a request",
        .needs_fetch = true,
    },
    .{
        .name = "sqlite",
        .about = "Two Rows on one SQLite file: tables made at boot, a paged join, a report, a transaction",
        .needs_sql = true,
    },
};

/// `needs_fetch` rather than handing every example `nilo_fetch`: an example is
/// the shortest honest statement of what a program has to import, and a list
/// of modules six of the seven never name is not that.
const Example = struct {
    name: []const u8,
    about: []const u8,
    needs_fetch: bool = false,
    /// Names `nilo_sql`, so it is built and tested only when that module is
    /// (`-Dsql`, on for this repository), and its tests hang off `test-sql`
    /// rather than `test` for the reason the module's own do (ADR 066).
    needs_sql: bool = false,
    /// A directory (relative to the build root) listed into a `frontend`
    /// module with `embedDir`, which is how a program carries its front end.
    embeds: []const u8 = "",
};

/// The same, for `sql/refusals/`. A separate list because they hang off
/// `test-sql` rather than `test` — the framework's loop does not pay for a
/// module it does not import (ADR 036).
const sql_refusals = [_]Refusal{
    // The three ways to misuse the table `nilo.Idempotent` keeps answers in
    // when instances share a database (ADR 268).
    .{
        .name = "replays_over_something_that_is_not_a_db",
        .says = "`sql.Replays(u32, …)` was given something that is not a `nilo_sql` Db.",
    },
    .{
        .name = "replays_without_a_name",
        .says = "`sql.Replays` needs a `name`.",
    },
    .{
        .name = "replays_that_keep_nothing",
        .says = "the `sql.Replays` \"orders\" has a `max_bytes` of 0, so no answer could be kept in it.",
    },
    .{
        .name = "a_second_database_with_no_name",
        .says = "`sql.Named(\"\")` has no name, so it is `sql.Db` with extra steps.",
    },
    // The three the SQLite Wire adds. All three are things the *dialect*
    // cannot do rather than things this module declines to write, which is why
    // each message says what SQLite does instead of what nilo wants
    // (ADR 064, ADR 065).
    .{
        .name = "sqlite_wire_without_threading",
        .says = "a sqlite Wire has to say where its statements run.",
    },
    .{
        .name = "sqlite_deadline",
        .says = "tx.deadline is not available on the sqlite dialect.",
    },
    .{
        .name = "sqlite_weaker_isolation",
        .says = "the sqlite dialect has no .read_committed isolation level.",
    },
    // `nilo_id`'s, and it is here because that module has no table of its own:
    // `sql.Uuid` is the same declaration, and the framework's refusals are built
    // against `nilo_http` alone (ADR 143).
    .{
        .name = "uuid_v7now_without_a_scope",
        .says = "`id.v7Now` needs somewhere to get randomness from, and u32 has no `entropy`.",
    },
    .{
        .name = "any_empty",
        .says = "`.any` is empty.",
    },
    .{
        .name = "insert_nothing",
        .says = "an insert into insert_nothing.User with no columns.",
    },
    .{
        .name = "one_with_limit",
        .says = "`db.one` on one_with_limit.User was given a `.limit`.",
    },
    .{
        .name = "returning_one_on_a_column_not_unique",
        .says = "`updateReturningOne` on returning_one_on_a_column_not_unique.User has a condition that can match more than one row.",
    },
    .{
        .name = "given_in_a_set_on_a_column_that_may_be_null",
        .says = "`.set = .{ .nickname = sql.given(…) }` on given_in_a_set_on_a_column_that_may_be_null.User, whose `nickname` is ?[]const u8.",
    },
    .{
        .name = "set_now_on_a_column_that_is_not_a_timestamp",
        .says = "`.set = .{ .seen_at = .now }` on set_now_on_a_column_that_is_not_a_timestamp.User, whose `seen_at` is i64.",
    },
    .{
        .name = "upsert_on_a_column_no_unique_covers",
        .says = "an upsert on upsert_on_a_column_no_unique_covers.User conflicts on .{ .email }, and neither its key nor any `.unique` in its marker is over those columns.",
    },
    .{
        .name = "upsert_on_a_unique_that_folds_case",
        .says = "an upsert on upsert_on_a_unique_that_folds_case.User conflicts on .{ .email }, and the unique over it, `users_email_key`, ignores case.",
    },
    .{
        .name = "violated_not_a_unique",
        .says = "`sql.violated` asks about violated_not_a_unique.User's .{ .handle }, and neither its key nor any `.unique` is over those columns.",
    },
    .{
        .name = "returning_one_with_a_range_on_the_key",
        .says = "`deleteReturningOne` on returning_one_with_a_range_on_the_key.Session has a condition that can match more than one row.",
    },
    .{
        .name = "find_with_a_condition",
        .says = "`db.find` on find_with_a_condition.User was given a struct where its key goes.",
    },
    .{
        .name = "optional_in_a_condition",
        .says = "the condition on `handle` was given a ?[]const u8.",
    },
    .{
        .name = "not_in_a_list_that_holds_null",
        .says = "`.tag = .{ .not_in = … }` on not_in_a_list_that_holds_null.Ticket was given a list that holds null.",
    },
    .{
        .name = "in_a_literal_list_that_holds_null",
        .says = "`.tag = .{ .in = … }` on in_a_literal_list_that_holds_null.Ticket was given a list that holds null.",
    },
    .{
        .name = "given_beside_a_condition_in_an_exists",
        .says = "an entry of `.exists` over given_beside_a_condition_in_an_exists.Capability holds a `sql.given` beside another condition.",
    },
    .{
        .name = "across_given_beside_a_condition",
        .says = "an entry of `.across` holds a `sql.given` beside another condition.",
    },
    .{
        .name = "across_with_a_negated_operator",
        .says = "an entry of `.across` sets `.not_icontains`, which is a negation.",
    },
    .{
        .name = "given_on_a_null_safe_operator",
        .says = "the condition on `deleted_at` (as `not_distinct_from`) was given a `sql.given`.",
    },
    .{
        .name = "shape_parent_named_like_a_schema_table",
        .says = "shape_parent_named_like_a_schema_table.OrderCard's parent `orders` would be joined under the name of the table the statement reads.",
    },
    .{
        .name = "shape_max_over_a_bool",
        .says = "shape_max_over_a_bool.ByCustomer reads `.any_shipped`, the max of `shipped`, which is a bool.",
    },
    .{
        .name = "children_max_over_a_uuid",
        .says = "children_max_over_a_uuid.EpicCard reads `.newest`, the max of `public`, which is a Uuid.",
    },
    .{
        .name = "list_column_of_a_timestamp",
        .says = "list_column_of_a_timestamp.Slot reads `opens` as []const Timestamp, a list of Timestamp, which the driver cannot decode as an array element.",
    },
    .{
        .name = "across_on_one_column",
        .says = "`.across` names one column.",
    },
    .{
        .name = "across_columns_of_two_types",
        .says = "`.across` on across_columns_of_two_types.Sku names `code`, which is []const u8, and `weight`, which is i32.",
    },
    .{
        .name = "across_on_unknown_column",
        .says = "across_on_unknown_column.Sku has no column `trade_mark`, asked for in an `.across`.",
    },
    // A field beside the columns: on the Row, in no statement (ADR 178).
    .{
        .name = "beside_in_a_where",
        .says = "beside_in_a_where.Comment carries `attachments` beside its columns, and a" ++
            " condition asks for it as one.",
    },
    .{
        .name = "beside_written",
        .says = "beside_written.Comment carries `attachments` beside its columns, and an" ++
            " insert asks for it as one.",
    },
    .{
        .name = "beside_names_no_field",
        .says = "beside_names_no_field.Comment's nilo_beside names `attachment`, which is" ++
            " not one of its fields.",
    },
    .{
        .name = "beside_without_a_default",
        .says = "beside_without_a_default.Comment carries `attachments` beside its columns," ++
            " and the field has no default.",
    },
    .{
        .name = "beside_as_the_key",
        .says = "beside_as_the_key.Comment's key names `token`, which it carries beside" ++
            " its columns.",
    },
    .{
        .name = "given_inside_an_any",
        .says = "an alternative of `.any` holds a `sql.given`.",
    },
    .{
        .name = "given_on_a_delete",
        .says = "the condition on a delete on given_on_a_delete.Partner holds a `sql.given`.",
    },
    .{
        .name = "given_on_a_value_that_is_always_there",
        .says = "`sql.given` was handed a []const u8, which is not an optional.",
    },
    .{
        .name = "insert_unknown_column",
        .says = "insert_unknown_column.User has no column `emial`, asked for in an insert.",
    },
    .{
        .name = "set_on_unknown_column",
        .says = "set_on_unknown_column.User has no column `aeg`, asked for in `.set`.",
    },
    .{
        .name = "update_empty_set",
        .says = "`.set` on update_empty_set.User is empty.",
    },
    .{
        .name = "page_that_locks_its_rows",
        .says = "`db.page` on page_that_locks_its_rows.Order was given a `.lock`.",
    },
    .{
        .name = "page_without_a_limit",
        .says = "`db.page` on page_without_a_limit.Order was given no `.limit`.",
    },
    .{
        .name = "page_without_an_order",
        .says = "`db.page` on page_without_an_order.Order was given no `.order`.",
    },
    .{
        .name = "upsert_key_is_also_a_column",
        .says = "an upsert on upsert_key_is_also_a_column.ApiKey was given `.key` as its conflict target, and upsert_key_is_also_a_column.ApiKey has a column of that name.",
    },
    .{
        .name = "upsert_nothing_to_set",
        .says = "`db.insertOrUpdate` on upsert_nothing_to_set.User has nothing to set.",
    },
    .{
        .name = "upsert_target_not_a_column",
        .says = "upsert_target_not_a_column.User has no column `emial`, asked for in an upsert.",
    },
    .{
        .name = "upsert_target_not_a_name",
        .says = "an upsert on upsert_target_not_a_name.User was given a *const [5:0]u8 as its conflict target.",
    },
    .{
        .name = "upsert_target_not_written",
        .says = "`db.insertOrUpdate` on upsert_target_not_written.User conflicts on .{ .id }, and the values written do not carry `id`.",
    },
    .{
        .name = "update_without_condition",
        .says = "an update on update_without_condition.User with no condition.",
    },
    .{
        .name = "update_without_set",
        .says = "an update on update_without_set.User with no `.set`.",
    },
    .{
        .name = "any_not_a_list",
        .says = "`.any` holds a list of conditions and this one is a single condition.",
    },
    .{
        .name = "row_column_no_dialect_can_decode",
        .says = "row_column_no_dialect_can_decode.User reads `address` as row_column_no_dialect_can_decode.Address, which no Dialect can decode.",
    },
    // A number neither database stores, refused by name (ADR 055).
    // A cursor that would skip or repeat rows, and a feed with no ceiling
    // (ADR 150).
    .{
        .name = "after_over_an_order_that_runs_both_ways",
        .says = "`db.feed` on after_over_an_order_that_runs_both_ways.Post reads after a cursor over an order that runs both ways.",
    },
    .{
        .name = "after_without_the_key",
        .says = "`db.feed` on after_without_the_key.Post reads after a cursor, and its `.order` does not end in `id`.",
    },
    .{
        .name = "after_over_a_column_that_may_be_null",
        .says = "`db.feed` on after_over_a_column_that_may_be_null.Task reads after a cursor over `due`, which may be null.",
    },
    .{
        .name = "after_on_a_page",
        .says = "`db.page` on after_on_a_page.Post was given an `.after`.",
    },
    .{
        .name = "feed_without_a_limit",
        .says = "`db.feed` on feed_without_a_limit.Post was given no `.limit`.",
    },
    .{
        .name = "row_column_read_as_a_u64",
        .says = "row_column_read_as_a_u64.Counter reads `hits` as u64, which holds numbers neither database stores: both keep an integer in a signed 64 bits.",
    },
    .{
        .name = "list_column_of_an_unsigned",
        .says = "list_column_of_an_unsigned.Grid reads `cells` as []const u16, and Postgres decodes an array element only as the width it stores.",
    },
    .{
        .name = "raw_read_as_an_f16",
        .says = "a raw statement is read as f16, and a float column holds 32 or 64 bits.",
    },
    .{
        .name = "streamed_json",
        .says = "streamed_json.Account reads `settings` as a Json column, and a streamed row cannot hold one.",
    },
    .{
        .name = "table_name_with_two_dots",
        .says = "table_name_with_two_dots.User names the table `db.app.users`, which is not a schema and a table.",
    },
    .{
        .name = "streamed_list",
        .says = "streamed_list.Ticket reads `tags` as a list column, and a streamed row cannot hold one.",
    },
    .{
        .name = "raw_named_struct_of_values",
        .says = "`db.raw` was given `uuid.Uuid` in a struct with named fields, and nilo converts a parameter by position.",
    },
    .{
        .name = "composed_text_naming_a_placeholder",
        .says = "`Composed.text` was handed \"SELECT 1 WHERE id = $1\", which names a placeholder as text.",
    },
    .{
        .name = "raw_select_list_short",
        .says = "the statement handed to `db.raw` selects 2 columns, and raw_select_list_short.Person has 3 fields.",
    },
    .{
        .name = "raw_scalar_with_two_columns",
        .says = "the statement handed to `db.raw` selects 2 columns, and []const u8 is one value.",
    },
    .{
        .name = "raw_column_in_another_fields_place",
        .says = "column 1 of the statement handed to `db.raw` is named `owner_id`, and field 1 of raw_column_in_another_fields_place.Person is `id`.",
    },
    // The values against the `$n` the text names, and the one column a
    // paged statement has to carry past its Row (ADR 204, ADR 205).
    .{
        .name = "raw_with_fewer_values_than_placeholders",
        .says = "the statement handed to `db.raw` names $2 and was given 1 value.",
    },
    .{
        .name = "raw_with_a_gap_in_its_placeholders",
        .says = "the statement handed to `db.raw` names $3 and never uses $2.",
    },
    .{
        .name = "raw_page_without_a_total",
        .says = "the statement handed to `db.rawPage` selects 2 columns, and raw_page_without_a_total.Line has 2 fields and wants one more.",
    },
    // A page past its last row is asked again with its offset at 0, so the
    // offset has to be a value of its own (ADR 205).
    .{
        .name = "raw_page_offset_not_a_placeholder",
        .says = "the statement handed to `db.rawPage` has an `OFFSET` that is not one placeholder.",
    },
    .{
        .name = "raw_page_offset_written_out",
        .says = "the statement handed to `db.rawPage` writes `OFFSET 40`.",
    },
    .{
        .name = "raw_page_offset_shared",
        .says = "the statement handed to `db.rawPage` uses its offset, $1, somewhere besides `OFFSET`.",
    },
    .{
        .name = "raw_page_limit_with_a_comma",
        .says = "the statement handed to `db.rawPage` writes `LIMIT a, b`.",
    },
    .{
        .name = "raw_page_values_named",
        .says = "`db.rawPage` was given its values in a struct with named fields.",
    },
    .{
        .name = "raw_page_offset_not_a_number",
        .says = "a page's `LIMIT` or `OFFSET` was given a []const u8.",
    },
    // The two shapes a `::text` cannot be hiding in, and the only two this
    // refuses (ADR 138). Both name the *column* type rather than the Zig one:
    // `@typeName` of an `AsText` is `types.AsText("numeric"[0..7])`, and a
    // check whose text ends in a compiler rendering detail breaks when the
    // rendering does.
    .{
        .name = "raw_text_column_not_cast",
        .says = "column 2 of the statement handed to `db.raw` is `total`, and field 2 of raw_text_column_not_cast.Invoice is a `numeric` column read as text.",
    },
    .{
        .name = "raw_text_column_behind_distinct",
        .says = "column 1 of the statement handed to `db.raw` is `total`, and field 1 of raw_text_column_behind_distinct.Invoice is a `numeric` column read as text.",
    },
    .{
        .name = "raw_star_over_a_text_column",
        .says = "the statement handed to `db.raw` selects `*`, and field 2 of raw_star_over_a_text_column.Invoice is a `numeric` column read as text.",
    },
    // A Row that owns no table, refused by everything that has to name one
    // (ADR 125). The second is the near miss: one word is allowed, so a
    // different one is a typo rather than a Row nobody has implemented yet.
    .{
        .name = "select_on_a_projection",
        .says = "select_on_a_projection.Timeline is a projection, so it has no table to read.",
    },
    .{
        .name = "table_marker_is_an_unknown_word",
        .says = "table_marker_is_an_unknown_word.Rollup's nilo_table is `.view`, which is not a word it takes.",
    },
    .{
        .name = "half_a_column_type",
        .says = "half_a_column_type.Money is being used as a column type and has `nilo_write` without `nilo_read`.",
    },
    .{
        .name = "a_column_type_with_no_column",
        .says = "a_column_type_with_no_column.Span reads and writes itself as text and has not said which column it is.",
    },
    .{
        .name = "row_lock_outside_a_transaction",
        .says = "`db.select` on row_lock_outside_a_transaction.User was given a `.lock`, and there is no transaction to hold it.",
    },
    .{
        .name = "batch_update_without_key",
        .says = "a batch update of batch_update_without_key.User does not carry `id`.",
    },
    .{
        .name = "batch_update_nothing_to_set",
        .says = "a batch update of batch_update_nothing_to_set.User has nothing to set.",
    },
    .{
        .name = "batch_of_a_list_column",
        .says = "a batch insert into batch_of_a_list_column.Ticket cannot send `tags`, which it reads as []const []const u8.",
    },
    .{
        .name = "batch_of_an_unnamed_enum",
        .says = "a batch insert into batch_of_an_unnamed_enum.Staff cannot send `role`, which it reads as batch_of_an_unnamed_enum.Role.",
    },
    // The dialect is judged before the column is, and the verb is the
    // caller's: this used to say "a batch insert" from both and blame `i64`.
    .{
        .name = "sqlite_batch_insert",
        .says = "a batch insert into sqlite_batch_insert.User is not available on the sqlite dialect.",
    },
    .{
        .name = "sqlite_batch_update",
        .says = "a batch update of sqlite_batch_update.User is not available on the sqlite dialect.",
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
        .says = "borrowed_from_a_non_row.UserCard's nilo_table names borrowed_from_a_non_row.Settings, which is not a Row.",
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
        .says = "no_id_and_no_key.Membership has no column `id`, so its nilo_table has to say which column identifies a row.",
    },
    .{
        .name = "not_a_row",
        .says = "not_a_row.User is not a Row — it has no `nilo_table`.",
    },
    .{
        .name = "not_a_scope",
        .says = "db.select needs a Scope and *mem.Allocator is not one.",
    },
    .{
        .name = "order_on_unknown_column",
        .says = "order_on_unknown_column.User has no column `creted_at`, asked for in `.order`.",
    },
    // `nilo_children`: a count is an i64, and an entry takes what one
    // statement for every parent can honour (ADR 218).
    .{
        .name = "children_count_read_as_a_usize",
        .says = "children_count_read_as_a_usize.RabCard reads `.line_count`, a count, as usize.",
    },
    // `nilo_through`: a column of another table read flat (item 83).
    .{
        .name = "through_read_as_never_null",
        .says = "through_read_as_never_null.DealLine reads `.approver_name` through a reference as []const u8," ++
            " and the column is []const u8 behind a reference that may be null.",
    },
    .{
        .name = "through_a_column_with_no_reference",
        .says = "through_a_column_with_no_reference.DealLine's `.owner_name` goes through `owner_id`, and" ++
            " through_a_column_with_no_reference.Deal declares no `.references` of that one column to a Row.",
    },
    // What a row the path does not reach reads (item 109).
    .{
        .name = "through_join_left",
        .says = "through_join_left.ItemLine's nilo_through `.kind_tracks` says `.join = .left`.",
    },
    .{
        .name = "through_inner_where_nothing_is_missing",
        .says = "through_inner_where_nothing_is_missing.ItemLine's nilo_through `.owner_name` says" ++
            " `.join = .inner`, and no reference on its path may be null.",
    },
    .{
        .name = "through_otherwise_read_as_optional",
        .says = "through_otherwise_read_as_optional.ItemLine reads `.kind_tracks` through a reference as" ++
            " ?bool, and its `.otherwise` stands in for every null.",
    },
    .{
        .name = "through_otherwise_where_nothing_is_missing",
        .says = "through_otherwise_where_nothing_is_missing.ItemLine's nilo_through `.owner_name` says" ++
            " `.otherwise`, and the column is []const u8, so it is never null.",
    },
    .{
        .name = "through_inner_under_a_missing_parent",
        .says = "through_inner_under_a_missing_parent.TaskLine reads `.item.kind_tracks` with `.join = .inner`," ++
            " inside a parent that may be missing.",
    },
    .{
        .name = "children_max_read_as_not_optional",
        .says = "children_max_read_as_not_optional.EpicCard reads `.latest_target`, the max of `target_date` over the rows pointing back, as Date.",
    },
    .{
        .name = "children_max_naming_only_a_column",
        .says = "children_max_naming_only_a_column.EpicCard's nilo_children `.latest_target` gives `.max` a @EnumLiteral().",
    },
    .{
        .name = "children_entry_with_a_limit",
        .says = "children_entry_with_a_limit.RabCard's nilo_children gives `.lines` a `.limit`, which it does not take.",
    },
    // An aggregate's `.where`: it narrows a computation, it makes the answer
    // nullable, and it takes only what a literal can say (ADR 218).
    .{
        .name = "aggregate_filter_with_nothing_to_compute",
        .says = "aggregate_filter_with_nothing_to_compute.ByCustomer's nilo_aggregate gives `.foreign` a `.where` and nothing to compute.",
    },
    .{
        .name = "aggregate_filter_read_as_never_null",
        .says = "aggregate_filter_read_as_never_null.ByCustomer reads `.idr` as i64, and it reads only the rows its `.where` matches, and sum over a group where none does is null.",
    },
    .{
        .name = "aggregate_filter_word_of_another_enum",
        .says = "aggregate_filter_word_of_another_enum.Tally's `.open` `.where` gives" ++
            " aggregate_filter_word_of_another_enum.State.category a" ++
            " aggregate_filter_word_of_another_enum.Stage, and the column holds one of" ++
            " aggregate_filter_word_of_another_enum.Category's words.",
    },
    .{
        .name = "aggregate_filter_with_a_pattern",
        .says = "aggregate_filter_with_a_pattern.ByCustomer's `.rupiah` `.where` tests `currency` with `.starts_with`, which is not one it writes.",
    },
    .{
        .name = "order_on_a_grouped_row_by_a_column_it_does_not_carry",
        .says = "`.order` on order_on_a_grouped_row_by_a_column_it_does_not_carry.ByCustomer names `year`, a column of its table that the Row does not carry, and the Row is grouped.",
    },
    // An `ORDER BY` chosen per request from a closed set (ADR 165). The
    // keys are checked where they are declared, and an ordering carries the
    // Row it was checked against.
    .{
        .name = "ordering_key_on_unknown_column",
        .says = "ordering_key_on_unknown_column.Ticket has no column `creted_at`, asked for in the ordering key `created`.",
    },
    .{
        .name = "ordering_for_another_row",
        .says = "`db.select` on ordering_for_another_row.Person was given an ordering declared for ordering_for_another_row.Ticket.",
    },
    .{
        .name = "ordering_expression_on_a_typed_select",
        .says = "`db.select` on ordering_expression_on_a_typed_select.Ticket was given an ordering whose key `title` is an expression, and a statement nilo writes orders by columns.",
    },
    .{
        .name = "raw_page_ordered_without_a_total",
        .says = "the statement handed to `db.rawPageOrdered` selects 2 columns, and raw_page_ordered_without_a_total.Card has 2 fields and wants one more.",
    },
    .{
        .name = "raw_ordered_without_a_hole",
        .says = "the statement handed to `db.rawOrdered` has no `{order}` in it, so there is nowhere to write the ordering.",
    },
    .{
        .name = "reserved_column_any",
        .says = "reserved_column_any.Answer has a column named `any`, which is the word a condition uses for OR.",
    },
    .{
        .name = "table_unknown_option",
        .says = "table_unknown_option.User's nilo_table sets `.primary`, which is not part of it.",
    },
    .{
        .name = "table_without_name",
        .says = "table_without_name.User's nilo_table does not say `.name`.",
    },
    .{
        .name = "unknown_select_option",
        .says = "a select on unknown_select_option.User was given `.limti`, which is not one of its options.",
    },

    // The twelve `sql/table.zig` adds (ADR 123). Every one of them is a
    // schema that would compile, create a table, and be wrong about it later:
    // a key nothing can identify a row by, a unique over a column that has no
    // case, two sides of a foreign key holding different types. A migration
    // tool that found these at `ALTER` time would find them after the deploy.
    .{
        .name = "table_key_is_optional",
        .says = "table_key_is_optional.User's key `id` is optional.",
    },
    .{
        .name = "table_column_has_no_sql_type",
        .says = "the postgres dialect has no column type for" ++
            " table_column_has_no_sql_type.User.place, which it reads as" ++
            " table_column_has_no_sql_type.Point.",
    },
    .{
        .name = "table_ignoring_case_on_a_number",
        .says = "table_ignoring_case_on_a_number.User's unique on `age` asks to ignore" ++
            " case, and the column is i64.",
    },
    .{
        .name = "table_unique_column_as_text",
        .says = "table_unique_column_as_text.User's `.unique` names a column as" ++
            " *const [5:0]u8.",
    },
    .{
        .name = "table_unique_over_no_columns",
        .says = "table_unique_over_no_columns.User has an empty entry in `.unique`.",
    },
    .{
        .name = "table_references_not_a_row",
        .says = "table_references_not_a_row.User's `.references.org_id` points at" ++
            " table_references_not_a_row.Org, which is not a Row.",
    },
    .{
        .name = "table_reference_type_mismatch",
        .says = "table_reference_type_mismatch.User.org_id is []const u8 and points at" ++
            " table_reference_type_mismatch.Org.id, which is i64.",
    },
    .{
        .name = "table_set_null_on_a_required_column",
        .says = "table_set_null_on_a_required_column.User.org_id is set to null on" ++
            " delete, and it is i64.",
    },
    .{
        .name = "table_on_delete_unknown",
        .says = "table_on_delete_unknown.User's `.references.org_id` says `.set_default`" ++
            " happens on delete.",
    },
    .{
        .name = "table_was_written_as_a_column",
        .says = "table_was_written_as_a_column.User's `.was.email` is `.handle`.",
    },
    .{
        .name = "table_was_a_column_that_is_still_there",
        .says = "table_was_a_column_that_is_still_there.User says `email` was called" ++
            " `handle`, and it reads a column called `handle` as well.",
    },
    .{
        .name = "table_references_in_a_ring",
        .says = "these tables point at each other in a ring, so none of them can be" ++
            " created first:",
    },
    // The five the words that cross tables add (ADR 181). Four of them are a
    // foreign key that lines up in the Row and not with the table it points
    // at, which is the mistake the type check exists to catch — and the fifth
    // is the check itself, refusing the name it was given nowhere to resolve.
    .{
        .name = "table_references_a_table_nobody_declares",
        .says = "table_references_a_table_nobody_declares.User's `.references.org_id`" ++
            " points at the table `orgs`, and no Row in this list names it.",
    },
    .{
        .name = "table_references_by_name_type_mismatch",
        .says = "table_references_by_name_type_mismatch.User.org_id is []const u8 and" ++
            " points at table_references_by_name_type_mismatch.Org.id, which is i64.",
    },
    .{
        .name = "table_references_uneven_columns",
        .says = "table_references_uneven_columns.Card's `.references.board` points 2" ++
            " column(s) at 1 of `boards`.",
    },
    .{
        .name = "table_references_long_form_without_to",
        .says = "table_references_long_form_without_to.Card's `.references.board` says" ++
            " no table.",
    },
    .{
        .name = "table_references_unknown_word",
        .says = "table_references_unknown_word.Card's `.references` sets `.on_dlete`," ++
            " which is not part of an entry.",
    },
    // The fifteen the words inside one Row add (ADR 181): a default, an enum
    // column's CHECK, a partial and ordered index, and a constraint that can
    // be named. Every one of them is a schema that would compile and then be
    // wrong about itself — a default the column's own CHECK refuses, two
    // indexes whose names collide at the second CREATE, a name Postgres cuts
    // at 63 and nothing reads the NOTICE for.
    .{
        .name = "table_unique_name_as_a_column",
        .says = "table_unique_name_as_a_column.User's `.unique` is named" ++
            " `.one_per_board`.",
    },
    .{
        .name = "table_constraint_name_too_long",
        .says = "the name nilo derives for table_constraint_name_too_long.Sku's" ++
            " `.unique` over `product_type_id`, `platform_id`, `acquisition_id`," ++
            " `product_id`, `term_id` is" ++
            " `skus_product_type_id_platform_id_acquisition_id_product_id_term_id_key`," ++
            " which is 70 bytes, and 63 is all Postgres keeps.",
    },
    .{
        .name = "table_name_given_too_long",
        .says = "table_name_given_too_long.Sku's `.unique` is named" ++
            " `skus_are_unique_per_product_and_per_term_and_per_platform_and_per_region`," ++
            " which is 72 bytes, and 63 is all Postgres keeps.",
    },
    // The second kind of word (ADR 181): a `.check` and a `.trigger`, whose
    // body the database reads and the compiler does not. What is checked here
    // is the shape around the body — that it is text, that there is some, and
    // that the name it goes in under fits.
    .{
        .name = "table_check_written_as_a_tuple",
        .says = "table_check_written_as_a_tuple.Ledger's `.check` is a list.",
    },
    .{
        .name = "table_check_body_is_not_text",
        .says = "table_check_body_is_not_text.Ledger's" ++
            " `.check.ledgers_amount_is_positive` is a comptime_int.",
    },
    .{
        .name = "table_check_body_is_empty",
        .says = "table_check_body_is_empty.Ledger's `.check.ledgers_amount_is_positive`" ++
            " is empty.",
    },
    .{
        .name = "table_check_name_too_long",
        .says = "table_check_name_too_long.Ledger's check is named" ++
            " `ledgers_amount_is_positive_and_the_currency_is_one_we_actually_settle_in`," ++
            " which is 72 bytes, and 63 is all Postgres keeps.",
    },
    .{
        .name = "table_check_written_as_a_struct",
        .says = "table_check_written_as_a_struct.Ledger's" ++
            " `.check.ledgers_amount_is_positive` is written as a struct.",
    },
    .{
        .name = "table_check_words_of_not_a_column",
        .says = "table_check_words_of_not_a_column.Ticket has no column `levell`, asked" ++
            " for in `.check`.",
    },
    .{
        .name = "table_check_words_of_a_column_with_none",
        .says = "table_check_words_of_a_column_with_none.Ticket's" ++
            " `.check.tickets_title_is_known` names the words of `title`, and that" ++
            " column has none.",
    },
    .{
        .name = "table_check_words_of_one_column_twice",
        .says = "table_check_words_of_one_column_twice.Ticket names the check over" ++
            " `level`'s words twice, as `tickets_level_is_known` and as" ++
            " `tickets_level_is_one_of_two`.",
    },
    .{
        .name = "table_trigger_written_as_one_string",
        .says = "table_trigger_written_as_one_string.Ledger's `.trigger.ledgers_touch`" ++
            " is not two halves.",
    },
    .{
        .name = "table_trigger_unknown_word",
        .says = "table_trigger_unknown_word.Ledger's `.trigger.ledgers_touch` sets" ++
            " `.on`, which is not part of an entry.",
    },
    .{
        .name = "table_trigger_half_is_empty",
        .says = "table_trigger_half_is_empty.Ledger's `.trigger.ledgers_touch.run` is empty.",
    },
    .{
        .name = "schema_extensions_on_sqlite",
        .says = "`.extensions` names \"pgcrypto\", and sqlite has no extensions to create." ++
            " Leave the list out of this schema.",
    },
    .{
        .name = "schema_functions_on_sqlite",
        .says = "`.functions` names \"touch\", and sqlite has no `CREATE FUNCTION`." ++
            " Leave the list out of this schema.",
    },
    .{
        .name = "schema_function_is_not_or_replace",
        .says = "`.functions` entry \"set_updated_at\" has to begin `CREATE OR REPLACE FUNCTION" ++
            " set_updated_at`, so that applying it twice is applying it once. It begins" ++
            " `CREATE FUNCTION set_updated_at() RETURNS…`.",
    },
    .{
        .name = "schema_function_named_in_mixed_case",
        .says = "`.functions` entry \"setUpdatedAt\" names the function without quotes, and Postgres" ++
            " keeps it as `setupdatedat`. nilo drops a function by the name in the entry, in quotes," ++
            " so that drop would find nothing. Write the name in lower case, or quote it in the body:" ++
            " `CREATE OR REPLACE FUNCTION \"setUpdatedAt\"`.",
    },
    .{
        .name = "schema_two_tables_one_index_name",
        .says = "`orders` and `invoices` both have an index named `by_created_at`.",
    },
    .{
        .name = "schema_view_begins_with_create",
        .says = "`.views` entry \"names\" begins `CREATE`, and nilo writes the `CREATE VIEW" ++
            " \"names\" AS` itself — the entry is the SELECT.",
    },
    .{
        .name = "table_two_constraints_one_name",
        .says = "table_two_constraints_one_name.Outbox names two constraints" ++
            " `outbox_sent_at_idx`.",
    },
    .{
        .name = "table_unknown_word_in_an_entry",
        .says = "table_unknown_word_in_an_entry.User's `.unique` sets `.ignorng_case`," ++
            " which is not part of an entry.",
    },
    .{
        .name = "table_direction_on_a_unique",
        .says = "table_direction_on_a_unique.User's `.unique` reads `created_at` in a" ++
            " direction.",
    },
    .{
        .name = "table_direction_that_is_not_one",
        .says = "table_direction_that_is_not_one.User's `.index` reads `created_at` in" ++
            " a direction that is not one.",
    },
    .{
        .name = "table_default_now_on_a_number",
        .says = "table_default_now_on_a_number.User's `.default.age` is `.now` and the" ++
            " column is i64.",
    },
    .{
        .name = "table_default_unknown_word",
        .says = "table_default_unknown_word.User's `.default.token` is `.gen_uuid`," ++
            " which is not a word `.default` takes.",
    },
    // The two that name a Zig type stop before the compiler's rendering of it:
    // `*const [3:0]u8` is a detail that changes when the rendering does, and a
    // check whose text ends in one breaks for no reason anybody cares about.
    .{
        .name = "table_default_of_another_type",
        .says = "`.default` gives table_default_of_another_type.User.age a" ++
            " *const [2:0]u8, and the column is i64.",
    },
    .{
        .name = "table_default_not_one_of_the_words",
        .says = "`.default` gives table_default_not_one_of_the_words.Task.priority" ++
            " `.blocker`, which is not one of" ++
            " table_default_not_one_of_the_words.Priority's words.",
    },
    .{
        .name = "table_default_word_written_as_text",
        .says = "`.default` gives table_default_word_written_as_text.Task.priority" ++
            " text, and the column holds one of" ++
            " table_default_word_written_as_text.Priority's words.",
    },
    .{
        .name = "insert_leaves_out_a_column",
        .says = "an insert into insert_leaves_out_a_column.User leaves out `age`, `created_at`," ++
            " and nothing fills them in.",
    },
    .{
        .name = "insert_leaves_out_an_unread_column",
        .says = "an insert into insert_leaves_out_an_unread_column.Deal leaves out `created_at`," ++
            " and nothing fills it in.",
    },
    // `.unread`: a column of the table the Row that names it does not read
    // (item 102).
    .{
        .name = "unread_names_a_column_it_reads",
        .says = "unread_names_a_column_it_reads.Deal's `.unread` names `created_at`, which unread_names_a_column_it_reads.Deal reads.",
    },
    .{
        .name = "unread_key",
        .says = "unread_key.Deal's key is `code`, which its `.unread` declares.",
    },
    .{
        .name = "insert_many_leaves_out_a_column",
        .says = "a batch insert into insert_many_leaves_out_a_column.Bill leaves out `reduction`," ++
            " and nothing fills it in.",
    },
    .{
        .name = "table_filled_and_default",
        .says = "table_filled_and_default.User's `.created_at` is in both `.default` and `.filled`.",
    },
    .{
        .name = "table_filled_on_a_generated_key",
        .says = "table_filled_on_a_generated_key.User's `.filled` names `.id`, the key a sequence fills.",
    },
    .{
        .name = "table_filled_written_as_text",
        .says = "table_filled_written_as_text.User's `.filled` is a *const [10:0]u8.",
    },
    .{
        .name = "table_filled_not_a_column",
        .says = "table_filled_not_a_column.User has no column `creatd_at`, asked for in `.filled`.",
    },
    .{
        .name = "table_default_on_a_generated_key",
        .says = "table_default_on_a_generated_key.User's `.default.id` is on the key," ++
            " and the database fills that in itself.",
    },
    .{
        .name = "table_index_where_unknown_term",
        .says = "table_index_where_unknown_term.Task's `.index` tests `weight` with" ++
            " something that is not one of the four terms.",
    },
    .{
        .name = "table_index_where_of_another_type",
        .says = "`.index`'s `.where` gives table_index_where_of_another_type.Task.weight" ++
            " a *const [5:0]u8, and the column is i64.",
    },
    // A key spanning several columns. Every one of these is a statement that
    // would have compiled, run, and answered with the wrong row — which is why
    // the composite key arrived with four Refusals rather than one.
    .{
        .name = "find_missing_a_key_column",
        .says = "`db.find` on find_missing_a_key_column.Seat does not say `.tenant_id`," ++
            " which is part of its key `tenant_id`, `id`.",
    },
    .{
        .name = "find_with_a_positional_key",
        .says = "`db.find` on find_with_a_positional_key.Seat was given a tuple where" ++
            " its key goes.",
    },
    .{
        .name = "find_on_a_column_that_is_not_the_key",
        .says = "`db.find` on find_on_a_column_that_is_not_the_key.Seat was given" ++
            " `.label`, which is a column but not part of its key `tenant_id`, `id`.",
    },
    .{
        .name = "key_names_a_column_twice",
        .says = "key_names_a_column_twice.Seat's `.key` names `id` twice.",
    },
    // Arithmetic in a `.set`. The nullable one is the reason the other two
    // exist: it is the only one of the three that would otherwise run.
    .{
        .name = "set_arithmetic_on_a_nullable_column",
        .says = "`.set = .{ .views = .{ .plus = … } }` on" ++
            " set_arithmetic_on_a_nullable_column.Post, whose `views` is ?i64.",
    },
    .{
        .name = "set_arithmetic_on_a_text_column",
        .says = "`.set = .{ .title = .{ .plus = … } }` on" ++
            " set_arithmetic_on_a_text_column.Post, whose `title` is []const u8.",
    },
    .{
        .name = "set_with_two_operators",
        .says = "`.set` on column `views` of set_with_two_operators.Post was given" ++
            " more than one operator.",
    },
    // The pattern operators. The first two are about what a pattern can match;
    // the third is a Dialect refusing rather than folding case when it was
    // asked not to.
    .{
        .name = "pattern_on_a_number_column",
        .says = "`.age = .{ .contains = … }` on pattern_on_a_number_column.User," ++
            " whose `age` is i32.",
    },
    // The database's clock as a word: each goes in the column type it is a
    // value of (ADR 181).
    .{
        .name = "today_on_a_timestamp",
        .says = "`.set = .{ .seen_at = .today }` on today_on_a_timestamp.Card, whose `seen_at` is Timestamp.",
    },
    .{
        .name = "today_on_a_timestamp_read_as_text",
        .says = "`.set = .{ .seen_at = .today }` on today_on_a_timestamp_read_as_text.Card, whose `seen_at` is a `timestamptz` column read as text.",
    },
    // Moved by an offset: `.now` takes a unit both databases count alike.
    .{
        .name = "now_moved_by_a_bare_number",
        .says = "`.seen_at = .{ .gt = .{ .now = … } }` moves `.now` by a comptime_int.",
    },
    .{
        .name = "now_moved_by_months",
        .says = "`.seen_at = .{ .gt = .{ .now = … } }` moves `.now` by `.months`, which is not a unit it takes.",
    },
    .{
        .name = "ieq_on_a_number_column",
        .says = "`.age = .{ .ieq = … }` on ieq_on_a_number_column.User," ++
            " whose `age` is i32.",
    },
    .{
        .name = "pattern_given_something_that_is_not_text",
        .says = "`.email = .{ .contains = … }` was given a i32.",
    },
    .{
        .name = "sqlite_decimal_compared",
        .says = "`.total = .{ .gt = … }` on sqlite_decimal_compared.Invoice's `total` would run as text on the sqlite dialect.",
    },
    .{
        .name = "sqlite_decimal_ordered",
        .says = "`.order.total` on sqlite_decimal_ordered.Invoice's `total` would run as text on the sqlite dialect.",
    },
    .{
        .name = "sqlite_decimal_ordering_key",
        .says = "the ordering key `total` on sqlite_decimal_ordering_key.Invoice's `total` would run as text on the sqlite dialect.",
    },
    .{
        .name = "sqlite_decimal_cursor",
        .says = "`.after.total` on sqlite_decimal_cursor.Invoice's `total` would run as text on the sqlite dialect.",
    },
    .{
        .name = "sqlite_decimal_summed",
        .says = "`sum` (field `.billed`) on sqlite_decimal_summed.Billed's `amount` would run as text on the sqlite dialect.",
    },
    .{
        .name = "sqlite_case_sensitive_pattern",
        .says = "the sqlite dialect has no `contains`, asked for on column `email`.",
    },
    .{
        .name = "sqlite_like",
        .says = "the sqlite dialect has no `like`, asked for on column `email`.",
    },
    // `.exists`. The first two are the two ways a schema can fail to say how
    // two tables are joined, and they are different mistakes: nothing said, and
    // said twice (ADR 218).
    .{
        .name = "exists_without_a_reference",
        .says = "`.exists` names exists_without_a_reference.Capability, which declares" ++
            " no `.references` to exists_without_a_reference.Partner's table `partners`.",
    },
    // With no `.where`, an `.exists` asks whether any row points back, and
    // only when the key is the inner Row's (item 107).
    .{
        .name = "exists_without_a_where_over_its_own_key",
        .says = "an entry of `.not_exists` over exists_without_a_where_over_its_own_key.Department says no" ++
            " `.where`, and the key is exists_without_a_where_over_its_own_key.Staff's own `department_id`.",
    },
    .{
        .name = "exists_with_an_empty_where",
        .says = "an entry of `.exists` over exists_with_an_empty_where.Capability has an empty `.where`.",
    },
    .{
        .name = "exists_with_two_references",
        .says = "`.exists` names exists_with_two_references.Record, which points at" ++
            " exists_with_two_references.Staff's table from more than one column:" ++
            " `created_by`, `updated_by`.",
    },
    // The reference read from the outer Row's side, and the two words that
    // tell the directions apart (ADR 175).
    .{
        .name = "exists_with_two_references_back",
        .says = "`.exists` names exists_with_two_references_back.Region, which" ++
            " exists_with_two_references_back.Staff points at from more than one column:" ++
            " `home_region`, `work_region`.",
    },
    .{
        .name = "exists_in_both_directions",
        .says = "`.exists` names exists_in_both_directions.Department, and the two tables" ++
            " point at each other: exists_in_both_directions.Department at" ++
            " exists_in_both_directions.Staff's table from `head_id`, and" ++
            " exists_in_both_directions.Staff at exists_in_both_directions.Department's" ++
            " from `department_id`.",
    },
    .{
        .name = "exists_via_beside_on",
        .says = "an entry of `.exists` says both `.on` and `.via`.",
    },
    .{
        .name = "exists_via_on_unknown_column",
        .says = "exists_via_on_unknown_column.Staff has no column `dept_id`, asked for in" ++
            " `.exists`'s `.via`.",
    },
    .{
        .name = "exists_not_a_list",
        .says = "`.exists` holds a list of tests and this one is a single test.",
    },
    .{
        .name = "exists_over_the_same_table",
        .says = "`.exists` names exists_over_the_same_table.Partner, which reads the" ++
            " same table as exists_over_the_same_table.Partner.",
    },
    .{
        .name = "reserved_column_exists",
        .says = "reserved_column_exists.Flag has a column named `exists`, which is the" ++
            " word a condition uses for a matching row in another table.",
    },
    // A Row that carries its parent, its children or a sum (ADR 218).
    .{
        .name = "shape_parent_on_a_table",
        .says = "shape_parent_on_a_table.Invoice carries a parent, children or an aggregate, and" ++
            " is not a narrower Row.",
    },
    .{
        .name = "shape_parent_with_no_reference",
        .says = "shape_parent_with_no_reference.LineCard reads `staff` as a parent, and" ++
            " shape_parent_with_no_reference.Line declares no `.references` to" ++
            " shape_parent_with_no_reference.Staff's table `staff`.",
    },
    .{
        .name = "shape_parent_two_references",
        .says = "shape_parent_two_references.OrderCard reads `staff` as a parent, and" ++
            " shape_parent_two_references.Order points at" ++
            " shape_parent_two_references.Staff's table from more than one column:" ++
            " `owner_id`, `approver_id`.",
    },
    .{
        .name = "shape_parent_may_be_missing",
        .says = "shape_parent_may_be_missing.OrderCard reads `approver` as" ++
            " shape_parent_may_be_missing.StaffName, and `approver_id` may be null.",
    },
    .{
        .name = "shape_parent_never_missing",
        .says = "shape_parent_never_missing.OrderCard reads `customer` as" ++
            " ?shape_parent_never_missing.CustomerName, and `customer_id` is never null.",
    },
    .{
        .name = "shape_parent_named_like_the_table",
        .says = "shape_parent_named_like_the_table.OrderCard's parent `orders` would be joined" ++
            " under the name of the table the statement reads.",
    },
    .{
        .name = "shape_via_on_a_column",
        .says = "shape_via_on_a_column.OrderCard's nilo_via names `total`, which is not a parent" ++
            " or a list of children.",
    },
    .{
        .name = "shape_children_key_not_read",
        .says = "shape_children_key_not_read.OrderLines reads `lines` as children, and does not" ++
            " read `id`, which is what each child points at.",
    },
    .{
        .name = "shape_children_optional",
        .says = "shape_children_optional.OrderLines reads `lines` as an optional list of" ++
            " children.",
    },
    .{
        .name = "shape_children_of_children",
        .says = "shape_children_of_children.OrderLines's children `lines` are" ++
            " shape_children_of_children.LineNotes, which has children of its own.",
    },
    .{
        .name = "shape_children_streamed",
        .says = "`db.stream` on shape_children_streamed.OrderLines, which reads `lines` as" ++
            " children.",
    },
    .{
        .name = "shape_aggregate_wrong_type",
        .says = "shape_aggregate_wrong_type.ByCustomer reads `.revenue`, the sum of `total`, as" ++
            " i32.",
    },
    .{
        .name = "shape_aggregate_can_be_null",
        .says = "shape_aggregate_can_be_null.Totals reads `.revenue` as i64, and a Row grouped" ++
            " by nothing answers even when no row matched, and sum over no rows is null.",
    },
    .{
        .name = "shape_aggregate_unknown_word",
        .says = "shape_aggregate_unknown_word.ByCustomer's nilo_aggregate asks `.revenue` for" ++
            " `.total`, which is not one it computes.",
    },
    .{
        .name = "shape_aggregate_unknown_field",
        .says = "shape_aggregate_unknown_field.ByCustomer's nilo_aggregate names `revenu`, which" ++
            " is not one of its fields.",
    },
    .{
        .name = "shape_tally_listed",
        .says = "`db.select` on shape_tally_listed.Totals, whose every field is an aggregate.",
    },
    .{
        .name = "shape_tally_condition_on_aggregate",
        .says = "the condition on shape_tally_condition_on_aggregate.Totals names an aggregate," ++
            " and the Row is grouped by nothing.",
    },
    .{
        .name = "shape_exactly_one_not_grouped",
        .says = "`db.exactlyOne` on shape_exactly_one_not_grouped.OrderCard, which is not" ++
            " grouped by nothing.",
    },
    .{
        .name = "shape_aggregate_inside_any",
        .says = "`.revenue` is an aggregate of shape_aggregate_inside_any.ByCustomer, named" ++
            " inside `.any`.",
    },
    .{
        .name = "shape_grouped_find",
        .says = "`db.find` on shape_grouped_find.ByCustomer, which is grouped.",
    },
    .{
        .name = "shape_locked",
        .says = "`db.select` on shape_locked.OrderCard was given a `.lock`.",
    },
    .{
        .name = "shape_written",
        .says = "a delete through shape_written.OrderCard, which carries a parent, children or" ++
            " an aggregate.",
    },
    .{
        .name = "shape_raw",
        .says = "`db.raw` into shape_raw.OrderCard, which reads `customer` as a parent.",
    },
    .{
        .name = "shape_order_through_a_column",
        .says = "the ordering key `odd` on shape_order_through_a_column.OrderCard goes through" ++
            " `total`, which is not a parent.",
    },
    .{
        .name = "shape_grouped_children",
        .says = "shape_grouped_children.ByCustomer is grouped and reads `lines` as children.",
    },
    // The probes of the P1 suspicions: an ordering with no term or too many,
    // a null compared with a column that is never null (ADR 040), and `.now`
    // on a `timestamp` that a session's zone would shift (ADR 067).
    .{
        .name = "ordering_by_with_no_terms",
        .says = "sql.Ordering(ordering_by_with_no_terms.Ticket).by was given no terms.",
    },
    .{
        .name = "ordering_by_with_more_terms_than_keys",
        .says = "sql.Ordering(ordering_by_with_more_terms_than_keys.Ticket).by was given 2 terms and the ordering has 1 key.",
    },
    .{
        .name = "null_on_a_column_that_is_never_null",
        .says = "the condition `.age = null` on null_on_a_column_that_is_never_null.User compares `age` with null, and `age` is never null.",
    },
    .{
        .name = "not_null_on_a_column_that_is_never_null",
        .says = "the condition `.age = .{ .ne = null }` on not_null_on_a_column_that_is_never_null.User compares `age` with null, and `age` is never null.",
    },
    .{
        .name = "now_on_a_timestamp_without_a_zone",
        .says = "`.set = .{ .seen_at = .now }` on now_on_a_timestamp_without_a_zone.Card, whose `seen_at` is a `timestamp` column read as text.",
    },
};

/// The same, for `s3/refusals/`. The fifth table, hung off `test-s3`.
///
/// What is checked here is what ADR 059 said comptime was *for*: not the
/// endpoint or the credentials, which come from a Config at run time, but the
/// four things a bucket's own type can be wrong about — and the one that is
/// not a mistake so much as a leak, a credential written where it would be
/// compiled into the binary.
const s3_refusals = [_]Refusal{
    .{
        .name = "bucket_name_too_short",
        .says = "`ab` is 2 characters, and an S3 bucket name is 3 to 63.",
    },
    .{
        .name = "bucket_name_with_an_underscore",
        .says = "`my_avatars` has an underscore in it, and a host name cannot.",
    },
    .{
        .name = "bucket_name_with_a_capital",
        .says = "`Avatars` has a capital letter in it, and a bucket addressed as" ++
            " `Avatars.s3.amazonaws.com` cannot.",
    },
    .{
        .name = "bucket_name_like_an_address",
        .says = "`192.168.1.1` is shaped like an IP address, and S3 refuses a bucket" ++
            " named that way.",
    },
    .{
        .name = "bucket_name_with_a_slash_by_path",
        .says = "`tenants/a` has a character in it that a URL path cannot carry as a bucket name" ++
            " (letters, digits, dot, dash and underscore only).",
    },
    .{
        .name = "a_secret_in_a_bucket_option",
        .says = "`secret_access_key` is a credential, and a bucket's type is not where one goes.",
    },
    .{
        .name = "presign_over_seven_days",
        .says = "s3.Bucket(\"links\") has a `presign_max` of 1209600 seconds, and SigV4" ++
            " refuses anything over seven days (604800).",
    },
    .{
        .name = "max_bytes_of_zero",
        .says = "s3.Bucket(\"avatars\") has a `max_bytes` of zero, so every get would be" ++
            " refused before it was made.",
    },
    .{
        .name = "an_option_that_does_not_exist",
        .says = "s3.Bucket has no option called `maxBytes`.",
    },
    .{
        .name = "put_without_a_content_type",
        .says = "bucket.put needs `.content_type` on the thing being stored.",
    },
    .{
        .name = "a_streamed_put_with_no_length",
        .says = "bucket.putStream needs `.len` on what it reads from.",
    },
    .{
        .name = "a_multipart_put_without_a_content_type",
        .says = "bucket.putMultipart needs `.content_type` on what it reads from.",
    },
    .{
        .name = "a_compose_without_a_content_type",
        .says = "bucket.compose needs `.content_type` for the joined object.",
    },
    .{
        .name = "a_session_token_larger_than_sign_can_carry",
        .says = "s3.Bucket(\"sts\") has a `session_token_max` of 4096 bytes, and a presigned URL has room for a token of 2048 (`sign.token_max`).",
    },
};

/// The same, for `config/refusals/`. A separate list for the same reason the
/// SQL one is separate: a module's refusals belong beside the module rather
/// than in one table every module edits (ADR 038).
const config_refusals = [_]Refusal{
    .{
        .name = "config_not_a_struct",
        .says = "a Config is read into a struct, and u32 is not one.",
    },
    .{
        .name = "config_with_no_fields",
        .says = "the Config `config_with_no_fields.Empty` has no fields, so it would read nothing.",
    },
    .{
        .name = "config_field_cannot_convert",
        .says = "the field `tags: []const []const u8` of the Config `config_field_cannot_convert.Settings` is not something an environment variable can become.",
    },
    .{
        .name = "config_unknown_field",
        .says = "the Config `config_unknown_field.Settings` has no field `prot`.",
    },
    .{
        .name = "config_not_a_source",
        .says = "a Config is read from a source, and comptime_int cannot be one.",
    },
    .{
        .name = "config_source_has_no_get",
        .says = "a Config is read from a source and config_source_has_no_get.NotASource is not one.",
    },
    .{
        .name = "config_layered_not_a_tuple",
        .says = "a layered source takes a tuple of sources, and source.Fixed is not one.",
    },
    .{
        .name = "config_layered_with_no_layers",
        .says = "a layered source with no layers would read nothing.",
    },
    .{
        .name = "config_layered_not_a_source",
        .says = "layer 2 of a layered source is comptime_int, and that cannot be a source.",
    },
};

/// The same, for `pw/refusals/`. They hang off `test-pw` for the reason the
/// Config ones hang off `test-config`: a module in the bottom layer keeps its
/// own (ADR 044).
const pw_refusals = [_]Refusal{
    .{
        .name = "pw_cost_below_the_floor",
        .says = "a password Cost of 64 KiB of memory is below the floor of 7168 KiB.",
    },
    .{
        .name = "pw_cost_with_no_passes",
        .says = "a password Cost with no passes is not a hash.",
    },
    .{
        .name = "pw_cost_more_lanes_than_memory",
        .says = "a password Cost of 2048 lanes needs at least 16384 KiB of memory, and it has 8192.",
    },
    .{
        .name = "pw_token_from_a_uuid",
        .says = "a Token is made from 32 bytes of entropy and was given 16.",
    },
};

/// The same, for `proto/refusals/`, hanging off `test-proto` for the reason
/// the others hang off theirs: a module in the bottom layer keeps its own
/// (ADR 245). One file a comptime check in `proto/schema.zig`, each a message
/// type written wrong in the way somebody will write it.
const proto_refusals = [_]Refusal{
    .{
        .name = "proto_message_without_wire",
        .says = "`proto_message_without_wire.Msg` is used as a message but declares no field numbers. Add `pub const wire = .{ .field_name = 1, ... };` to it.",
    },
    .{
        .name = "proto_field_without_number",
        .says = "`proto_field_without_number.Msg.name` has no field number. Add it to `proto_field_without_number.Msg.wire`, like `.name = 1`.",
    },
    .{
        .name = "proto_wire_names_a_missing_field",
        .says = "`proto_wire_names_a_missing_field.Msg.wire` numbers `nmae`, and `proto_wire_names_a_missing_field.Msg` has no field of that name.",
    },
    .{
        .name = "proto_number_twice",
        .says = "`proto_number_twice.Msg` gives field number 1 to both `id` and `name`. A number names one field.",
    },
    .{
        .name = "proto_number_zero",
        .says = "`proto_number_zero.Msg.id` has field number 0, and a field number is between 1 and 536,870,911.",
    },
    .{
        .name = "proto_number_too_big",
        .says = "`proto_number_too_big.Msg.id` has field number 536870912, and a field number is between 1 and 536,870,911.",
    },
    .{
        .name = "proto_number_reserved",
        .says = "`proto_number_reserved.Msg.id` uses 19500, and 19,000 to 19,999 are reserved by protobuf itself.",
    },
    .{
        .name = "proto_entry_is_not_a_number",
        .says = "`proto_entry_is_not_a_number.Msg.wire.id` must be a field number (`.id = 1`) or a number and an encoding (`.id = .{ 1, .fixed64 }`).",
    },
    .{
        .name = "proto_unknown_encoding",
        .says = "`proto_unknown_encoding.Msg.wire.id` says `.sint`, which is not an encoding. They are .fixed64, .fixed32, .sfixed64, .sfixed32, .sint64, .sint32, .bytes and .string, and `.unpacked` for a repeated number.",
    },
    .{
        .name = "proto_two_encodings",
        .says = "`proto_two_encodings.Msg.wire.id` names two encodings. A field travels one way.",
    },
    .{
        .name = "proto_encoding_the_type_cannot_take",
        .says = "`proto_encoding_the_type_cannot_take.Msg.id` is a u32: its encoding is `.fixed32`, or none for uint32.",
    },
    .{
        .name = "proto_bool_with_an_encoding",
        .says = "`proto_bool_with_an_encoding.Msg.on` is a bool, which travels as a varint and takes no encoding.",
    },
    .{
        .name = "proto_not_a_protobuf_type",
        .says = "`proto_not_a_protobuf_type.Msg.port` has type `u16`, which is not a protobuf type. A field is a bool, an integer (i32, i64, u32 or u64), a float, a `[]const u8`, an `enum(i32)`, a struct with a `wire` table, a slice of any of those, or a `?union(enum)` with a `wire` table for a oneof.",
    },
    .{
        .name = "proto_mutable_bytes",
        .says = "`proto_mutable_bytes.Msg.name` is `[]u8`; a decoded string borrows the input, so write `[]const u8`.",
    },
    .{
        .name = "proto_enum_tag_is_not_i32",
        .says = "`proto_enum_tag_is_not_i32.Msg.kind` is an enum whose tag is not i32, and a protobuf enum is an int32. Declare it `enum(i32)`.",
    },
    .{
        .name = "proto_optional_slice",
        .says = "`proto_optional_slice.Msg.ids` is an optional slice, and a repeated field is never absent, only empty. Drop the `?`.",
    },
    .{
        .name = "proto_slice_of_optionals",
        .says = "`proto_slice_of_optionals.Msg.ids` is a slice of optionals, and a repeated field has no holes. Drop the `?`.",
    },
    .{
        .name = "proto_unpacked_on_a_scalar",
        .says = "`proto_unpacked_on_a_scalar.Msg.id` says `.unpacked`, which is for a repeated number, and this field is not repeated.",
    },
    .{
        .name = "proto_unpacked_on_text",
        .says = "`proto_unpacked_on_text.Msg.tags` says `.unpacked`, which is for a repeated number; repeated text is never packed.",
    },
    .{
        .name = "proto_message_with_an_encoding",
        .says = "`proto_message_with_an_encoding.Msg.inner` is a message, which takes no encoding.",
    },
    .{
        .name = "proto_oneof_is_not_optional",
        .says = "make `proto_oneof_is_not_optional.Msg.choice` optional (`?proto_oneof_is_not_optional.Choice`): a oneof that is not on the wire is none of its members.",
    },
    .{
        .name = "proto_oneof_number_in_the_message",
        .says = "`proto_oneof_number_in_the_message.Msg.choice` is a oneof, so its numbers belong on its members in `proto_oneof_number_in_the_message.Choice.wire`, not in `proto_oneof_number_in_the_message.Msg.wire`.",
    },
    .{
        .name = "proto_oneof_member_without_a_number",
        .says = "oneof member `proto_oneof_member_without_a_number.Choice.b` has no field number. Add it to `proto_oneof_member_without_a_number.Choice.wire`, like `.b = 1`.",
    },
    .{
        .name = "proto_oneof_table_names_a_missing_member",
        .says = "`proto_oneof_table_names_a_missing_member.Choice.wire` numbers `c`, and the union has no member of that name.",
    },
    .{
        .name = "proto_oneof_member_is_repeated",
        .says = "oneof member `proto_oneof_member_is_repeated.Choice.a` is repeated, and protobuf does not allow a repeated field in a oneof.",
    },
    .{
        .name = "proto_union_as_a_message",
        .says = "`proto_union_as_a_message.Choice` is a union with a `wire` table, and a union is only a oneof: put it in a message as `?proto_union_as_a_message.Choice`.",
    },
};

/// The same, for `cache/refusals/`, hanging off `test-cache` for the reason
/// the Config and Password ones hang off theirs: a module in the bottom layer
/// keeps its own (ADR 109).
const cache_refusals = [_]Refusal{
    .{
        .name = "cache_value_holds_a_pointer",
        .says = "a cached Cart cannot keep `Cart.name`, which is a pointer.",
    },
    .{
        .name = "cache_value_nested_pointer",
        .says = "a cached Cart cannot keep `Cart.first.label`, which is a pointer.",
    },
    .{
        .name = "cache_value_over_the_ceiling",
        .says = "a cached Page is 131080 bytes, and a cache entry holds at most 65535.",
    },
    .{
        .name = "cache_space_with_no_name",
        .says = "a cache Space needs a name.",
    },
    .{
        .name = "cache_bytes_space_with_no_room",
        .says = "the cache Space \"page\" holds bytes and its `max_bytes` is 0.",
    },
    .{
        .name = "cache_incr_on_a_struct",
        .says = "the cache Space \"cart\" holds Cart, and `incr` adds to an integer.",
    },
};

/// The same, for `job/refusals/`, hanging off `test-job` (ADR 160, ADR 161).
/// Every one of these answers a question a queue would otherwise answer at
/// three in the morning: a row nobody can run, a schedule with a policy
/// nobody chose, a payload that cannot be read back.
const job_refusals = [_]Refusal{
    .{
        .name = "job_without_a_name",
        .says = "the job SendWelcome has no `nilo_job`, so it has no name to be stored under.",
    },
    .{
        .name = "job_named_twice",
        .says = "the jobs SendWelcome and SendAgain are both named \"send-welcome\".",
    },
    .{
        .name = "job_payload_holds_a_pointer",
        .says = "the job SendWelcome cannot carry `SendWelcome.user`, which is a pointer.",
    },
    .{
        .name = "job_priority_is_a_number",
        .says = "the job Backfill's `priority` is comptime_int rather than a `job.Priority`.",
    },
    .{
        .name = "job_without_retry",
        .says = "the job SendWelcome says nothing about `retry`, and a job that fails has to say what happens next.",
    },
    .{
        .name = "job_run_takes_a_ctx",
        .says = "the job SendWelcome's `run` takes *job_run_takes_a_ctx.Ctx second, and it takes a `*nilo.Run`.",
    },
    .{
        .name = "job_run_asks_for_a_dep_nobody_gave",
        .says = "the job SendWelcome's `run` asks for a *job_run_asks_for_a_dep_nobody_gave.Mailer, and `job.Jobs`'s `.deps` has no such thing.",
    },
    .{
        .name = "job_pushed_but_not_listed",
        .says = "`jobs.push` was handed a SendAgain, and this queue has no such job.",
    },
    .{
        .name = "job_scheduled_without_overlap",
        .says = "the scheduled job Nightly does not say what happens when a tick arrives while the last one is still running.",
    },
    .{
        .name = "job_scheduled_without_missed",
        .says = "the scheduled job Nightly does not say what happens to a tick that was missed while the process was down.",
    },
    .{
        .name = "job_cron_out_of_range",
        .says = "the schedule \"0 25 * * *\" has 25 in its hour field, and that field runs from 0 to 23.",
    },
    .{
        .name = "job_cron_date_never_comes",
        .says = "the schedule \"0 0 31 2 *\" never fires, because no month it names has a day it names.",
    },
    .{
        .name = "job_push_empty_unique",
        .says = "`jobs.push` was given an empty `.unique`, and a key that is empty is a value that went missing.",
    },
    .{
        .name = "job_push_in_on_memory",
        .says = "`jobs.pushIn` was called on a queue over Memory, which cannot join a transaction.",
    },
    .{
        .name = "job_scheduled_field_without_default",
        .says = "the scheduled job Nightly has a field `day` with no default, and nobody pushes a scheduled job.",
    },
    // A failure the kind says is final (ADR 179).
    .{
        .name = "job_every_zero",
        .says = "`job.every(0)` is a schedule with no gap between its ticks, and a worker given one never rests.",
    },
    .{
        .name = "job_every_too_long",
        .says = "`job.every(1000000000000000)` is a period of more than a hundred years, which is a mistake in the unit.",
    },
    .{
        .name = "job_backoff_from_zero",
        .says = "the job SendWelcome's exponential `backoff` starts at `from_ms = 0`, and doubling zero is zero.",
    },
    .{
        .name = "job_final_not_an_error_set",
        .says = "the job SendWelcome's `final` is not an error set.",
    },
    .{
        .name = "job_final_with_no_retry",
        .says = "the job SendWelcome declares `final`, and its `retry` is `.none`.",
    },
    // A job that pushes the next one: `.deps` as a function of the queue
    // type (ADR 160). The second fires at `open` rather than at
    // `job.Jobs(…)`, because that is when the queue type exists to check
    // a `run` against.
    .{
        .name = "job_deps_fn_of_the_wrong_shape",
        .says = "`job.Jobs`'s `.deps` is a function, and it does not have the shape `fn (comptime Jobs: type) type`.",
    },
    .{
        .name = "job_deps_fn_without_what_run_asks",
        .says = "the job SendWelcome's `run` asks for a *job_deps_fn_without_what_run_asks.Mailer, and `job.Jobs`'s `.deps` has no such thing.",
    },
    // The tick a `run` may ask for is a value (ADR 160).
    .{
        .name = "job_run_takes_the_tick_by_pointer",
        .says = "the job SendWelcome's `run` takes a `*job.Tick` at position 2, and a tick is asked for by value.",
    },
};

/// The same, for `fetch/refusals/`, hanging off `test-fetch` (ADR 061). The
/// eighth table, and the first this module has had: until the ordinary call
/// took a struct of the caller's own, nothing here was checked while
/// compiling. Each one is a mistake that would otherwise reach the wire —
/// a body sent as one JSON string, a query with nothing to name its params.
const fetch_refusals = [_]Refusal{
    .{
        .name = "fetch_query_not_a_struct",
        .says = "fetch.withQuery was handed a comptime_int for its params, and a query is a struct with one field per param.",
    },
    .{
        .name = "fetch_query_field_cannot_be_encoded",
        .says = "the query field `when` is a fetch_query_field_cannot_be_encoded.When, and a query value is an int, a bool, text, or an optional of one.",
    },
    .{
        .name = "fetch_form_field_cannot_be_encoded",
        .says = "the form field `when` is a fetch_form_field_cannot_be_encoded.When, and a form value is an int, a bool, text, or an optional of one.",
    },
    .{
        .name = "fetch_form_body_is_text",
        .says = "fetch.postForm was handed a *const [29:0]u8 for its params, and a form is a struct with one field per param.",
    },
    .{
        .name = "fetch_json_body_is_text",
        .says = "fetch.postJson was handed text, and would send it as one JSON string. A body already encoded goes through post, put, patch or send.",
    },
    // A WebSocket is a call that does not end (ADR 281): the two mistakes
    // that would otherwise reach the wire, or a line of `fetch.zig` the caller
    // never wrote.
    .{
        .name = "fetch_ws_json_message_is_text",
        .says = "fetch.WebSocket.sendJson was handed text, and would send it as one JSON string. A message already encoded goes through sendText.",
    },
    .{
        .name = "fetch_ws_open_without_a_scope",
        .says = "fetch.WebSocket.open needs a Scope and *mem.Allocator is not one.",
    },
    // A target is a type, and a path is a template (ADR 061): what the
    // template and its arguments can be got wrong about while compiling.
    .{
        .name = "fetch_target_path_not_absolute",
        .says = "the path `v1/charges` does not begin with `/`, and a target's path hangs off its base.",
    },
    .{
        .name = "fetch_target_path_brace_unclosed",
        .says = "the path `/v1/charges/{id` opens a `{` it never closes.",
    },
    .{
        .name = "fetch_target_path_brace_unopened",
        .says = "the path `/v1/charges/id}` closes a `}` it never opened.",
    },
    .{
        .name = "fetch_target_args_not_a_struct",
        .says = "the path `/v1/charges/{}` was given a comptime_int for its arguments, and they are a tuple for `{}` or a struct for `{name}`.",
    },
    .{
        .name = "fetch_target_path_mixes_shapes",
        .says = "the path `/v1/{}/refunds/{id}` mixes `{}` and `{name}`, and a template fills its segments one way.",
    },
    .{
        .name = "fetch_target_tuple_for_named_segment",
        .says = "the path `/v1/charges/{id}` names its segments and was given a tuple. Name the fields, `.{ .id = … }`.",
    },
    .{
        .name = "fetch_target_segments_mismatch",
        .says = "the path `/v1/charges/{}/refunds/{}` has 2 segments to fill and was given 1 argument.",
    },
    .{
        .name = "fetch_target_struct_for_positional_segment",
        .says = "the path `/v1/charges/{}` fills its segments by position and was given a struct. Pass a tuple, `.{ … }`, or name the segment `{field}`.",
    },
    .{
        .name = "fetch_target_names_missing_field",
        .says = "the path `/v1/charges/{id}` names a segment `id`, and the struct it was given has no field `id`.",
    },
    .{
        .name = "fetch_target_segment_cannot_be_encoded",
        .says = "segment 1 of the path `/v1/reports/{}` is a fetch_target_segment_cannot_be_encoded.When, and a segment is an int, a bool or text.",
    },
    .{
        .name = "fetch_target_name_empty",
        .says = "fetch.Target was given an empty name, and the name is what the health route and a log line call it.",
    },
    .{
        .name = "fetch_target_ready_not_absolute",
        .says = "fetch.Target(\"api\") has a ready path `status` that does not begin with `/`, and it hangs off the base like any other.",
    },
    .{
        .name = "fetch_target_retry_never_tries",
        .says = "fetch.Target(\"api\")'s `.retry` is refused: `times` is 0, which is no retry at all; take `.retry` out.",
    },
    .{
        .name = "fetch_target_retry_backoff_from_zero",
        .says = "fetch.Target(\"api\")'s `.retry` is refused: the exponential backoff starts at `from_ms = 0`, and doubling zero is zero.",
    },
    .{
        .name = "fetch_target_retry_status_not_an_error",
        .says = "fetch.Target(\"api\")'s `.retry` is refused: `statuses` names a status that is not an error (400 to 599).",
    },
    .{
        .name = "fetch_target_retry_key_not_a_header",
        .says = "fetch.Target(\"api\")'s `.retry` is refused: `mint_key` is not a header name.",
    },
};

/// One entry per file in `refusals/`: a program written wrong on purpose, and
/// the first line of the error it has to stop with. `says` leaves out the
/// `nilo: ` prefix because the build step adds it — see the loop in `build`.
const refusals = [_]Refusal{
    // The three shapes `app.before` will not run (ADR 180).
    .{
        .name = "bearer_not_a_struct",
        .says = "the `Bearer(u32)` is not a struct.",
    },
    .{
        .name = "bearer_too_big_for_a_header",
        .says = "a `Bearer(bearer_too_big_for_a_header.Signed)` would be 11000 bytes in the Authorization header, and the most that fits is 8000.",
    },
    .{
        .name = "before_not_a_function",
        .says = "app.before() takes a function, not bool.",
    },
    .{
        .name = "before_without_a_run",
        .says = "app.before() was given a function whose first parameter is *before_without_a_run.Db, and it has to be `*nilo.Run`.",
    },
    .{
        .name = "before_returns_a_value",
        .says = "app.before() was given a function that answers with usize, and there is nobody to hand the value to.",
    },
    // The four ways to ask for an answer nilo cannot keep (ADR 155).
    .{
        .name = "idempotent_not_a_bytes_space",
        .says = "the `Idempotent(u32, …)` on route \"/orders\" names u32 as where answers are kept, and it is not a Space.",
    },
    .{
        .name = "idempotent_twice",
        .says = "the handler for route \"/orders\" asks for the Idempotency-Key twice — argument 1 and argument 2.",
    },
    .{
        .name = "idempotent_handler_writes_its_own_response",
        .says = "the handler for route \"/orders\" takes an `Idempotent(…)` and returns nothing, so there is no answer to keep.",
    },
    .{
        .name = "idempotent_handler_returns_a_file",
        .says = "the handler for route \"/receipts\" takes an `Idempotent(…)` and returns a nilo.FileBody, which is not an answer nilo can keep.",
    },
    // A store the instances share must be one `Idempotent` can release a
    // claim on, and `Cached` does not take one (ADR 268).
    .{
        .name = "idempotent_store_with_no_del",
        .says = "the `Idempotent(idempotent_store_with_no_del.Shared, …)` on route \"/orders\" names idempotent_store_with_no_del.Shared as where answers are kept, and it has no `del`, so it is not a Space that holds bytes.",
    },
    .{
        .name = "cached_over_a_store_that_takes_a_scope",
        .says = "the `Cached(cached_over_a_store_that_takes_a_scope.Shared, …)` on route \"/pages\" names cached_over_a_store_that_takes_a_scope.Shared as where answers are kept, and it is a store that takes the request's scope, the way `sql.Replays` does for `Idempotent`.",
    },
    // The nine ways to ask for an answer served again that nilo cannot
    // serve (ADR 188).
    .{
        .name = "cached_not_a_bytes_space",
        .says = "the `Cached(u32, …)` on route \"/pages\" names u32 as where answers are kept, and it is not a Space.",
    },
    .{
        .name = "cached_for_no_time",
        .says = "the `Cached(cached_for_no_time.Pages, …)` on route \"/pages\" has a `ttl_s` of 0, and an answer kept for no time is a handler that runs every time.",
    },
    .{
        .name = "cached_by_no_header",
        .says = "the `Cached(cached_by_no_header.Pages, …)` on route \"/pages\" keys its answers on a header and names none.",
    },
    .{
        .name = "cached_by_a_credential",
        .says = "the `Cached(cached_by_a_credential.Pages, …)` on route \"/pages\" keys its answers on the `Cookie` header, and a credential is not a key.",
    },
    .{
        .name = "cached_beside_the_caller",
        .says = "the handler for route \"/me\" takes a `Cached(…)` (argument 1) and a nilo.Session(cached_beside_the_caller.Signed) (argument 2), which says who the caller is.",
    },
    .{
        .name = "cached_on_a_post",
        .says = "the route \"POST /orders\" takes a `Cached(…)`, and a POST is not an answer to keep.",
    },
    .{
        .name = "cached_handler_writes_its_own_response",
        .says = "the handler for route \"/pages\" takes a `Cached(…)` and returns nothing, so there is no answer to keep.",
    },
    .{
        .name = "cached_twice",
        .says = "the handler for route \"/pages\" asks to be cached twice — argument 1 and argument 2.",
    },
    .{
        .name = "cached_and_idempotent",
        .says = "the handler for route \"/orders\" takes both an `Idempotent(…)` (argument 1) and a `Cached(…)` (argument 2), and an answer is kept under one key.",
    },
    // A readiness hook of the wrong shape (ADR 154).
    .{
        .name = "middleware_first_argument_not_ctx",
        .says = "the first argument of the middleware fn (*middleware_first_argument_not_ctx.Keys, *nilo.Ctx, nilo.Next) has to be a `*Ctx`.",
    },
    .{
        .name = "middleware_held_as_a_pointer",
        .says = "a typed middleware has to be a function known while compiling, and this one is held in a variable.",
    },
    .{
        .name = "middleware_returns_a_value",
        .says = "the middleware fn (*nilo.Ctx, nilo.Next, *middleware_returns_a_value.Keys) returns a u32.",
    },
    .{
        .name = "middleware_second_argument_not_next",
        .says = "the second argument of the middleware fn (*nilo.Ctx, *middleware_second_argument_not_next.Keys) has to be a `Next`.",
    },
    .{
        .name = "middleware_takes_a_body",
        .says = "argument 3 of the middleware taking (middleware_takes_a_body.Login) is a middleware_takes_a_body.Login, which a middleware cannot be given.",
    },
    .{
        .name = "middleware_takes_a_query",
        .says = "argument 3 of the middleware taking (nilo.Query(middleware_takes_a_query.Page)) is a nilo.Query(middleware_takes_a_query.Page), which a middleware cannot be given.",
    },
    .{
        .name = "ready_hook_wrong_arity",
        .says = "ready_hook_wrong_arity.Mailer.nilo_ready takes 1 parameters, and it has to take 2.",
    },
    .{
        .name = "check_hook_wrong_arity",
        .says = "check_hook_wrong_arity.Ledger.nilo_check takes 1 parameters, and it has to take 2.",
    },
    // The two ways to name a Basic realm wrong (ADR 153).
    .{
        .name = "authorization_realm_empty",
        .says = "`Authorization(.{ .basic = \"\" })` names no realm.",
    },
    .{
        .name = "authorization_realm_not_quotable",
        .says = "the realm \"say \"hi\"\" of an `Authorization(.{ .basic = … })` has a character in it that a WWW-Authenticate header cannot carry.",
    },
    .{
        .name = "allowance_above_what_a_slot_holds",
        .says = "an allowance above 1023 requests a window leaves too few bits for the fingerprint that tells two addresses apart.",
    },
    .{
        .name = "allowance_keyed_by_something_that_is_not_a_key",
        .says = "the first argument to allowance.keyed is what a request is counted against, and it has to be a function of one `*nilo.Ctx` returning an optional key.",
    },
    .{
        .name = "on_listener_names_none",
        .says = "`onListener` names no listener, so no listener would answer the route. Name at least one: `app.onListener(&.{1})`.",
    },
    .{
        .name = "on_listener_past_thirty_one",
        .says = "a route can be bound to listeners 0 to 31, and `onListener` was given a larger number.",
    },
    .{
        .name = "allowance_with_an_option_it_does_not_have",
        .says = "the options of this call have no field `perwindow`.",
    },
    .{
        .name = "allowance_name_too_long_for_its_header",
        .says = "an allowance's `.name` is sent as the name of its RateLimit policy, and can be at most 24 characters: the line it is part of is built in 64 bytes of the Ctx so that no allocation is made.",
    },
    .{
        .name = "allowance_keyed_above_what_a_slot_holds",
        .says = "a keyed allowance above 16,777,215 requests a window is more than a slot's counters hold.",
    },
    .{
        .name = "late_address_of_the_wrong_type",
        .says = "this option takes a `u32` or the address of one, and was handed `*u16`.",
    },
    .{
        .name = "allowance_of_no_requests",
        .says = "an allowance of 0 requests is not a limit, it is a closed door.",
    },
    .{
        .name = "allowance_prefix_longer_than_an_address",
        .says = "an IPv6 address is 128 bits, so `.ipv6_prefix` cannot ask for more than 128 of them.",
    },
    .{
        .name = "allowance_slots_not_a_power_of_two",
        .says = "an allowance's `.slots` is a power of two, and at least 64, because the table is indexed by a hash and shared four ways to a bucket.",
    },
    .{
        .name = "allowance_with_no_window",
        .says = "an allowance needs a window to count inside — `.window_s = 60`.",
    },
    .{
        .name = "argument_not_recognised",
        .says = "argument 1 of the handler for route \"/users/:id\" is a [4]u8, which nilo does not recognise.",
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
        .name = "braces_where_a_colon_goes",
        .says = "the segment \"{id}\" of route \"/users/{id}\" is written with braces, and nilo matches it as literal text.",
    },
    .{
        .name = "colon_mid_segment",
        .says = "the segment \"id:id\" of route \"/users/id:id\" has a `:` in the middle of it, so it is matched as literal text.",
    },
    .{
        .name = "cors_any_origin_beside_a_named_one",
        .says = "cors was given \"*\" alongside 1 named origin(s), and \"*\" already allows every one of them.",
    },
    .{
        .name = "cors_credentials_with_any_origin",
        .says = "cors credentials cannot be combined with origin \"*\" — browsers reject it.",
    },
    .{
        .name = "cors_no_origins_at_all",
        .says = "cors was given no origins at all, so every cross-origin request would be refused.",
    },
    .{
        .name = "cors_origin_with_a_capital_letter",
        .says = "the cors origin \"https://Example.com\" has a capital letter in it, and a browser sends its origin lowercased.",
    },
    .{
        .name = "cors_origin_null",
        .says = "cors was told to trust the origin \"null\", which is what a sandboxed frame or a `file:` page sends, and any site can make one.",
    },
    .{
        .name = "cors_origin_with_a_path",
        .says = "the cors origin \"https://example.com/\" is not an origin, so no request would ever match it.",
    },
    .{
        .name = "cors_reading_with_origins_named_too",
        .says = "cors.reading takes its origins from the Origins you hand it, so the `.origins` field has nothing to do.",
    },
    .{
        .name = "csrf_empty_origin",
        .says = "csrf was given an empty origin, which matches nothing.",
    },
    .{
        .name = "csrf_origin_with_a_path",
        .says = "the csrf origin \"https://app.example.com/\" is not an origin, so no request would ever match it.",
    },
    .{
        .name = "csrf_trusting_any_origin",
        .says = "csrf was told to trust \"*\", which is every page on the web, and that is the same as not installing it.",
    },
    .{
        .name = "secure_empty_csp",
        .says = "secure was given an empty csp, which sends a header that allows everything.",
    },
    .{
        .name = "secure_csp_with_a_newline",
        .says = "the secure csp holds a control byte, which would end the header line early.",
    },
    .{
        .name = "secure_hsts_preload_without_subdomains",
        .says = "secure hsts asks for preload without what the preload list requires, so the request to be listed is refused.",
    },
    .{
        .name = "deadline_of_no_time",
        .says = "a deadline of 0 milliseconds is not a limit, it is a request that has already run out.",
    },
    .{
        .name = "maxbody_of_no_bytes",
        .says = "a body limit of 0 bytes is not a limit, it is a route that refuses every body.",
    },
    .{
        .name = "maxbody_read_from_a_u32",
        .says = "maxBody takes a number of bytes or the address of a usize that holds one, and was handed *u32.",
    },
    // The five ways of writing the pair a type that writes its own answer
    // carries (ADR 157).
    .{
        .name = "ownbody_content_type_without_write",
        .says = "the handler for route \"/invoices/:id\" returns ownbody_content_type_without_write.Invoice, which names a `nilo_content_type` and has no `nilo_write`.",
    },
    .{
        .name = "decode_without_content_type",
        .says = "the request body on route \"/readings\" is a decode_without_content_type.Reading, which has a `nilo_decode` and no `nilo_content_type`.",
    },
    .{
        .name = "decode_wrong_signature",
        .says = "decode_wrong_signature.Reading's `nilo_decode` is not `fn (body: []const u8, arena: std.mem.Allocator) !decode_wrong_signature.Reading`.",
    },
    .{
        .name = "message_with_its_own_decode",
        .says = "the request body on route \"/sum\" is a message_with_its_own_decode.Sum, which has both a `wire` table and a `nilo_decode`, so it says two things about how its bytes are read.",
    },
    .{
        .name = "decode_and_parse",
        .says = "argument 1 of the handler for route \"/readings\" is a decode_and_parse.Reading, which carries both `nilo_parse` and `nilo_decode`, so it could be a path param or the request body.",
    },
    .{
        .name = "bound_message",
        .says = "the handler for route \"/sum\" binds a bound_message.Sum with `Bound(…)`, which reads a JSON body field by field — and this type's body is read whole, as protobuf or by its own `nilo_decode`.",
    },
    .{
        .name = "message_answering_json",
        .says = "the handler for route \"/sum\" reads a protobuf message (message_answering_json.Sum) and answers with a message_answering_json.Total, which is not one.",
    },
    .{
        .name = "rpc_not_a_struct",
        .says = "`app.rpc` was given u32, which is not a struct.",
    },
    .{
        .name = "rpc_without_name",
        .says = "rpc_without_name.Greeter is given to `app.rpc` and does not say which service it is.",
    },
    .{
        .name = "rpc_bad_name",
        .says = "rpc_bad_name.Greeter's `nilo_service` is \"hello/Greeter\", which is not a service's full name.",
    },
    .{
        .name = "rpc_name_not_text",
        .says = "rpc_name_not_text.Greeter's `nilo_service` has to be text, the service's full name: `pub const nilo_service = \"package.Service\";`.",
    },
    .{
        .name = "rpc_method_without_message",
        .says = "rpc_method_without_message.Greeter.ping is a `pub fn` of an RPC service, so it is served as \"POST /hello.Greeter/Ping\", and it neither reads nor answers a message.",
    },
    .{
        .name = "rpc_methods_collide",
        .says = "rpc_methods_collide.Greeter.sayHello and rpc_methods_collide.Greeter.SayHello are both served as \"POST /hello.Greeter/SayHello\": a method's name is its function's with the first letter upper-cased.",
    },
    .{
        .name = "rpc_no_methods",
        .says = "rpc_no_methods.Greeter is given to `app.rpc` and has no `pub fn`, so it serves nothing.",
    },
    .{
        .name = "ownbody_write_without_content_type",
        .says = "the handler for route \"/invoices/:id\" returns ownbody_write_without_content_type.Invoice, which has a `nilo_write` and no `nilo_content_type`.",
    },
    .{
        .name = "ownbody_content_type_empty",
        .says = "ownbody_content_type_empty.Invoice's `nilo_content_type` is empty, so its answer would go out with no label.",
    },
    .{
        .name = "ownbody_content_type_with_a_newline",
        .says = "ownbody_content_type_with_a_newline.Invoice's `nilo_content_type` has a control character in it, which would end the header line early.",
    },
    .{
        .name = "ownbody_write_wrong_signature",
        .says = "ownbody_write_wrong_signature.Invoice's `nilo_write` is not `fn (self: ownbody_write_wrong_signature.Invoice, w: *std.Io.Writer) !void`.",
    },
    .{
        .name = "failures_not_a_struct",
        .says = "`app.failures` was given failures_not_a_struct.Kind, and the shape of a failure body is a struct.",
    },
    .{
        .name = "failures_without_from",
        .says = "failures_without_from.ApiError has no `nilo_failure`, so nilo cannot fill it from a status and a message.",
    },
    .{
        .name = "failures_from_wrong_signature",
        .says = "failures_from_wrong_signature.ApiError's `nilo_failure` is not `fn (status: u16, message: []const u8) failures_from_wrong_signature.ApiError`.",
    },
    .{
        .name = "bytes_as_an_argument",
        .says = "argument 1 of the handler for route \"/bundles\" is a `nilo.Bytes`, which is what a handler answers *with* rather than something it is given.",
    },
    .{
        .name = "filebody_as_an_argument",
        .says = "argument 1 of the handler for route \"/invoices\" is a `nilo.FileBody`, which is what a handler answers *with* rather than something it is given.",
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
        .name = "form_list_of_optional_cannot_convert",
        .says = "the field `tags: []const ?nilo.Str` of the `Form(form_list_of_optional_cannot_convert.Tags)` on route \"/tags\" is a list of something a form value cannot become.",
    },
    .{
        .name = "verified_of_the_claims",
        .says = "`nilo.Verified(verified_of_the_claims.Claims)` names verified_of_the_claims.Claims, which is not a `jwt.Verifier`.",
    },
    .{
        .name = "verified_of_a_pointer",
        .says = "`nilo.Verified(*verified_of_a_pointer.Google)` names a pointer, and the argument names the Verifier's type.",
    },
    .{
        .name = "verified_as_an_answer",
        .says = "the handler for route \"/me\" returns nilo.Verified(verified_as_an_answer.Google), which is what a handler is *given* rather than what it answers with.",
    },
    .{
        .name = "text_bounds_reversed",
        .says = "`Text(.{ .min = 72, .max = 10 })` has its bounds the wrong way round: nothing is at least 72 and at most 10 characters.",
    },
    .{
        .name = "text_with_no_shape",
        .says = "`Text(.{})` asks nothing of the text, so it is a `Str` with a longer name.",
    },
    .{
        .name = "text_check_with_no_sentence",
        .says = "`Text(.{ .check = … })` has a check and no sentence, so text it refuses would get a 400 that cannot say why.",
    },
    .{
        .name = "text_default_outside_its_shape",
        .says = "`nilo.Text(.{ .max = 3 }).of(\"wati\")` does not fit its own shape.",
    },
    .{
        .name = "check_of_the_wrong_shape",
        .says = "`check_of_the_wrong_shape.SignUp`'s `nilo_check` takes 1 arguments rather than the value and its rules.",
    },
    .{
        .name = "versioned_as_an_argument",
        .says = "argument 1 of the handler for route \"/orders\" is a `nilo.Versioned(u32)`, which is what a handler answers *with* rather than something it is given.",
    },
    .{
        .name = "versioned_of_void",
        .says = "the handler for route \"/orders\" returns nilo.Versioned(void), and there is no body for a client to hold a version of.",
    },
    .{
        .name = "versioned_of_an_optional",
        .says = "the handler for route \"/orders/:id\" returns nilo.Versioned(?versioned_of_an_optional.Order), and the `?` would have to mean two things: a 404, and a body the client already holds.",
    },
    .{
        .name = "versioned_inside_a_status",
        .says = "the handler for route \"/orders\" returns nilo.Status(201,nilo.Versioned(versioned_inside_a_status.Order)), and a versioned answer is a 200 or a 304 by itself.",
    },
    .{
        .name = "versioned_under_a_cached",
        .says = "the handler for route \"/orders\" returns nilo.Versioned([]const versioned_under_a_cached.Order) under a `nilo.Cached`, and a kept answer is sent again as it was kept.",
    },
    // A `?` around a wrapper rather than inside it (ADR 203). Three files
    // because the way out differs: a `Status` or `Response` takes the `?`
    // on its body, and a redirect or a versioned answer has nothing for it
    // to be about.
    .{
        .name = "optional_outside_a_status",
        .says = "the handler for route \"/payments/:id\" returns ?nilo.Status(201,optional_outside_a_status.Receipt), and the `?` has to go inside the wrapper.",
    },
    .{
        .name = "optional_outside_a_redirect",
        .says = "the handler for route \"/open/:id\" returns ?nilo.Redirect(303), and a redirect has no body for the `?` to be about.",
    },
    .{
        .name = "optional_outside_a_versioned",
        .says = "the handler for route \"/orders/:id\" returns ?nilo.Versioned(optional_outside_a_versioned.Order), and a thing that is not there has no version.",
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
        .name = "json_marker_field_not_recognised",
        .says = "`json_marker_field_not_recognised.Condition`'s `nilo_json` has a field `tagged`, which is not something it can say.",
    },
    .{
        .name = "json_document_without_a_value",
        .says = "`json_document_without_a_value.Settings` says it is a `json_document_without_a_value.Payload` (`nilo_json_of`) and has no `value: json_document_without_a_value.Payload` to be written as.",
    },
    .{
        .name = "json_marker_is_not_a_struct",
        .says = "`json_marker_is_not_a_struct.Condition`'s `nilo_json` is a comptime_int, and it says how this type's JSON is spelled, so it is written as a struct.",
    },
    .{
        .name = "json_marker_says_nothing",
        .says = "`json_marker_says_nothing.Condition`'s `nilo_json` is empty, so it says nothing about this type's JSON and nothing changes.",
    },
    .{
        .name = "json_unknown_fields_refuse_written_out",
        .says = "`json_unknown_fields_refuse_written_out.Settings` says `.unknown_fields = .refuse`, which is what every type already does with a key it has no field for, so it would change nothing.",
    },
    .{
        .name = "json_unknown_fields_on_an_enum",
        .says = "`json_unknown_fields_on_an_enum.Severity` says `.unknown_fields`, and it is an enum, which is read from one string and has no keys to skip.",
    },
    .{
        .name = "json_unknown_fields_on_a_union",
        .says = "`json_unknown_fields_on_a_union.Condition` says `.unknown_fields`, and it is a union, whose keys are the ones its variant's struct has.",
    },
    .{
        .name = "json_unknown_fields_says_something_else",
        .says = "`json_unknown_fields_says_something_else.Settings` says `.unknown_fields = .warn`, which is not something it can do with a key it has no field for.",
    },
    // The status of a body that is JSON and not the type's shape (ADR 251).
    .{
        .name = "json_misfit_400_written_out",
        .says = "`json_misfit_400_written_out.Search` says `.misfit = 400`, which is what every type already answers for a body that is JSON and not its shape, so it would change nothing.",
    },
    .{
        .name = "json_misfit_another_status",
        .says = "`json_misfit_another_status.Search` says `.misfit = 409`, and a body that is JSON and not this type's shape is a 400 or a 422, nothing else.",
    },
    .{
        .name = "json_misfit_not_a_number",
        .says = "`json_misfit_not_a_number.Search`'s `misfit` is a @EnumLiteral(), and it is the status a body that is JSON and not this type's shape is refused with, which is written as a number.",
    },
    .{
        .name = "json_misfit_on_an_enum",
        .says = "`json_misfit_on_an_enum.Severity` says `.misfit`, and it is an enum, which is read from one string and is never a body of its own.",
    },
    .{
        .name = "json_misfit_on_an_untagged_union",
        .says = "`json_misfit_on_an_untagged_union.Condition` says `.misfit`, and it is a union with no `.tag`, which `std.json` reads by itself, so nilo cannot tell JSON of the wrong shape from anything else it refuses.",
    },
    .{
        .name = "json_reader_for_a_renamed_union",
        .says = "`json_reader_for_a_renamed_union.Channel` hands nilo's JSON reader a `nilo_json` that only renames, and it is a union.",
    },
    .{
        .name = "json_reader_with_no_marker",
        .says = "`json_reader_with_no_marker.Condition` asks for nilo's JSON reader and has no `nilo_json`, so there is nothing for the reader to do differently from `std.json`.",
    },
    .{
        .name = "json_rename_all_collides_on_an_enum",
        .says = "`json_rename_all_collides_on_an_enum.Severity` asks for `.rename_all = .lowercase`, and its values `not_found` and `notfound` both come out as \"notfound\".",
    },
    .{
        .name = "json_rename_all_collides_on_a_struct",
        .says = "`json_rename_all_collides_on_a_struct.Contact` asks for `.rename_all = .lowercase`, and its fields `full_name` and `fullname` both come out as \"fullname\".",
    },
    // A whole number inside a range (ADR 167): the range has to be one, and
    // the default has to be inside it.
    .{
        .name = "within_bounds_reversed",
        .says = "`Within(200, 1)` has its bounds the wrong way round: nothing is at least 200 and at most 1.",
    },
    .{
        .name = "within_default_outside_its_range",
        .says = "`Within(1, 200).of(500)` is outside its own range.",
    },
    .{
        .name = "within_bound_not_a_number",
        .says = "`Within` takes numbers for its bounds: a bound has to be a number.",
    },
    .{
        .name = "within_bound_not_finite",
        .says = "`Within` has a bound that is not a finite number.",
    },
    .{
        .name = "within_real_default_outside_its_range",
        .says = "`Within(0, 1).of(1.5)` is outside its own range.",
    },
    // A list with a length (ADR 266).
    .{
        .name = "many_bounds_reversed",
        .says = "`Many(nilo.Str, .{ .min = 5, .max = 1 })` has its bounds the wrong way round: nothing is at least 5 and at most 1 items.",
    },
    .{
        .name = "many_with_no_bound",
        .says = "`Many(nilo.Str, .{})` asks nothing of the count, so it is a `[]const nilo.Str` with a longer name.",
    },
    .{
        .name = "many_of_bytes",
        .says = "`Many(u8, …)` is a list of bytes, and bytes are text in a request.",
    },
    .{
        .name = "many_default_outside_its_bound",
        .says = "`nilo.Many(u32, .{ .min = 1, .max = 3 }).of(…)` is given 0 items, which is outside its own bound.",
    },
    .{
        .name = "many_in_a_query",
        .says = "the field `tags: nilo.Many(u32, .{ .max = 3 })` of the `Query(many_in_a_query.Search)` on route \"/users\" is a list with a length, which a query string does not carry.",
    },
    // One field spelled on its own (ADR 168): the entry has to name a field,
    // has to change it, and must not land it on another field's spelling.
    .{
        .name = "json_rename_of_a_field_it_does_not_have",
        .says = "`json_rename_of_a_field_it_does_not_have.Summary` renames a field `estimated_cost` it does not have.",
    },
    .{
        .name = "json_rename_lands_on_another_field",
        .says = "`json_rename_lands_on_another_field.Summary` spells its fields `amount_minor` and `due_at` both as \"dueAt\" — one of them by a `.rename` entry.",
    },
    .{
        .name = "json_rename_to_its_own_name",
        .says = "`json_rename_to_its_own_name.Summary` renames `amount` to \"amount\", which is what it is already called, so it would change nothing.",
    },
    .{
        .name = "json_rename_all_collides_on_a_union",
        .says = "`json_rename_all_collides_on_a_union.Channel` asks for `.rename_all = .UPPERCASE`, and its variants `web_hook` and `webhook` both come out as \"WEBHOOK\".",
    },
    .{
        .name = "body_field_that_parses_itself_without_a_reader",
        .says = "the request body on route \"/lines\" holds a `body_field_that_parses_itself_without_a_reader.Sku`, which parses itself from text (`nilo_parse`) and has not told `std.json` so.",
    },
    .{
        .name = "json_rename_all_on_a_form",
        .says = "the form on route \"/contacts\" is read into `json_rename_all_on_a_form.NewContact`, which renames or skips its fields — and `nilo_json` is a statement about JSON (ADR 148).",
    },
    .{
        .name = "json_skip_without_a_default_on_a_body",
        .says = "`json_skip_without_a_default_on_a_body.Account` skips `password_hash` (`.skip` in its `nilo_json`) and is read from a request body, where a skipped field is never read and has nothing to hold.",
    },
    .{
        .name = "json_skip_of_a_field_it_does_not_have",
        .says = "`json_skip_of_a_field_it_does_not_have.Account` skips a field `password_hash` it does not have.",
    },
    .{
        .name = "json_rename_all_on_a_shape_that_falls_back",
        .says = "`json_rename_all_on_a_shape_that_falls_back.Contact` renames or skips its fields, and this value goes to `std.json`, which does not read the marker (ADR 148).",
    },
    .{
        .name = "json_rename_all_is_already_zig",
        .says = "`json_rename_all_is_already_zig.Severity` asks for `.rename_all = .snake_case`, which is what a Zig field name already is, so it would change nothing.",
    },
    .{
        .name = "json_rename_all_unknown_case",
        .says = "`json_rename_all_unknown_case.Severity` asks for `.rename_all = .Titlecase`, which is not a case nilo writes.",
    },
    .{
        .name = "json_tag_collides_with_a_field",
        .says = "`json_tag_collides_with_a_field.Condition`'s `.tag` is \"kind\" and its variant `metrics` already has a field called `kind`, so that key would be written twice and a reader would pick one of them.",
    },
    .{
        .name = "json_tag_is_empty",
        .says = "`json_tag_is_empty.Condition`'s `.tag` is the empty string, so the variant's name would go under a key with no name.",
    },
    .{
        .name = "json_tag_on_a_struct",
        .says = "`json_tag_on_a_struct.Condition` says `.tag = \"signal\"`, which puts the name of the live variant into the JSON — and this is a struct, which has no variants.",
    },
    .{
        .name = "json_tag_on_an_untagged_union",
        .says = "`json_tag_on_an_untagged_union.Condition` says `.tag = \"signal\"` and is an untagged union, so nothing in it knows which variant is live and there is no name to write.",
    },
    .{
        .name = "json_variant_carries_no_fields",
        .says = "`json_variant_carries_no_fields.Condition`'s variant `metrics` carries a f64, and an internally tagged union writes the variant's fields beside the tag — so the variant has to have fields.",
    },
    .{
        .name = "metrics_buckets_out_of_order",
        .says = "app.metrics was given the latency bucket 100µs after 1000µs, and the boundaries have to climb.",
    },
    .{
        .name = "metrics_exposed_is_not_atomic",
        .says = "app.expose(\"hits\", …) was given a *u64, and a number that handlers on several threads count on has to be an atomic one.",
    },
    .{
        .name = "metrics_exposed_name_is_nilos",
        .says = "the exposed metric \"nilo_requests_total\" starts with `nilo_`, which is what nilo's own metrics are called.",
    },
    .{
        .name = "metrics_no_buckets_at_all",
        .says = "app.metrics was given no latency buckets, so nothing would be timed.",
    },
    .{
        .name = "metrics_path_is_a_pattern",
        .says = "the metrics path \"/metrics/:name\" has a `:` in it, which makes it a pattern rather than one address.",
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
        .name = "parse_marker_is_generic",
        .says = "`parse_marker_is_generic.Sku`'s `nilo_parse` is still generic, so nilo cannot tell what it takes.",
    },
    .{
        .name = "parse_marker_not_a_function",
        .says = "`parse_marker_not_a_function.Sku`'s `nilo_parse` is a comptime_int, not a function.",
    },
    .{
        .name = "parse_marker_wrong_argument",
        .says = "`parse_marker_wrong_argument.Sku`'s `nilo_parse` takes a u32 rather than the text that arrived.",
    },
    .{
        .name = "parse_marker_wrong_arity",
        .says = "`parse_marker_wrong_arity.Sku`'s `nilo_parse` takes 2 arguments rather than one.",
    },
    .{
        .name = "parse_marker_wrong_return",
        .says = "`parse_marker_wrong_return.Sku`'s `nilo_parse` answers parse_marker_wrong_return.Sku rather than `?parse_marker_wrong_return.Sku`.",
    },
    .{
        .name = "path_field_unknown",
        .says = "the field `ident: u32` of the `nilo.Path(path_field_unknown.Params)` on route \"/orgs/:org/members/:id\" names no path param of route \"/orgs/:org/members/:id\", which has :org, :id.",
    },
    .{
        .name = "path_field_not_a_param_type",
        .says = "the field `id: path_field_not_a_param_type.Inner` of the `nilo.Path(path_field_not_a_param_type.Params)` on route \"/members/:id\" is not something a path param can become.",
    },
    .{
        .name = "path_mixed_with_positional",
        .says = "the handler for route \"/members/:id\" reads a path param by position and also asks for nilo.Path(path_mixed_with_positional.Params) (argument 2).",
    },
    .{
        .name = "path_not_a_struct",
        .says = "the `nilo.Path(u32)` on route \"/members/:id\" is read into u32, which is not a struct.",
    },
    .{
        .name = "path_optional_field",
        .says = "the field `id: ?u32` of the `nilo.Path(path_optional_field.Params)` on route \"/members/:id\" is optional.",
    },
    .{
        .name = "path_param_without_field",
        .says = "the route \"/orgs/:org/members/:id\" has the path param :id, and the `nilo.Path(path_param_without_field.Params)` on route \"/orgs/:org/members/:id\" has no field `id` for it.",
    },
    .{
        .name = "path_params_none_read",
        .says = "route \"/orgs/:org/members/:id\" has 2 path params (:org, :id), but its handler reads none of them; read them by name: nilo.Path(struct { org: nilo.Str, id: nilo.Str })",
    },
    .{
        .name = "path_twice",
        .says = "the handler for route \"/orgs/:org/members/:id\" asks for the path params twice, argument 1 and argument 2.",
    },
    .{
        .name = "positional_path_params",
        .says = "route \"/orgs/:org/members/:id\" has 2 path params (:org, :id); read them by name: nilo.Path(struct { org: u32, id: u32 })",
    },
    .{
        .name = "resolver_path_unknown_field",
        .says = "the field `team: u32` of the `nilo.Path(resolver_path_unknown_field.TeamParams)` of the resolver `resolver_path_unknown_field.InTeam` names no path param of route \"/orgs/:org\", which has :org.",
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
        .name = "openapi_marker_has_no_type",
        .says = "openapi_marker_has_no_type.Uuid's `nilo_openapi` has no `type`, so it does not say what this value looks like in JSON. Write `pub const nilo_openapi = .{ .type = \"string\" };`, with `type` one of \"string\", \"integer\", \"number\" or \"boolean\", and an optional `format`.",
    },
    .{
        .name = "query_field_cannot_convert",
        .says = "the field `tags: []const u8` of the `Query(query_field_cannot_convert.Search)` on route \"/users\" is not something a query value can become.",
    },
    // A query field that *is* a list, refused on its element rather than on
    // its shape (ADR 132). The message above is still the one a `[]const u8`
    // gets, because text is not a list.
    .{
        .name = "query_list_of_something_else",
        .says = "the field `actors: []const query_list_of_something_else.Actor` of the `Query(query_list_of_something_else.Search)` on route \"/users\" is a list of query_list_of_something_else.Actor, which a query value cannot become.",
    },
    // The three ways to ask for a header wrong (ADR 131).
    .{
        .name = "header_with_no_name",
        .says = "argument 1 of the handler for route \"/thing\" is a `FromHeader(\"\", …)`, which names no header.",
    },
    .{
        .name = "header_name_not_a_token",
        .says = "argument 1 of the handler for route \"/thing\" asks for the header \"X Staff Id\", which is not a header name.",
    },
    .{
        .name = "header_value_cannot_convert",
        .says = "argument 1 of the handler for route \"/thing\" asks for the header \"X-Staff-Id\" as a header_value_cannot_convert.Actor, which request text cannot become.",
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
        .says = "`resolver_is_not_a_function.Caller.nilo_resolve` is a comptime_int, not a function.",
    },
    .{
        .name = "resolver_loop",
        .says = "the resolved value `resolver_loop.Caller` is worked out from itself — resolver_loop.Caller → resolver_loop.Tenant → resolver_loop.Caller",
    },
    .{
        .name = "resolver_returns_wrong_type",
        .says = "the resolver on `resolver_returns_wrong_type.Caller` returns nilo.Str, not resolver_returns_wrong_type.Caller.",
    },
    .{
        .name = "response_headers_not_a_list",
        .says = "Response headers have to be written out where they are set — .of(&.{.{ .name = \"Location\", .value = where }}) — and this is a []nilo.Header.",
    },
    .{
        .name = "route_name_that_is_not_a_word",
        .says = "the route name \"add partner-capability\" is not something a client generator can turn into a method.",
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
        .says = "a `Session(session_too_big_for_a_cookie.Signed)` would be 5540 bytes in the cookie, and the most that fits is 3800.",
    },
    .{
        .name = "session_with_no_fields",
        .says = "the `Session(session_with_no_fields.Empty)` has no fields, so it would remember nothing.",
    },
    .{
        .name = "start_hook_wrong_arity",
        .says = "start_hook_wrong_arity.Mailer.nilo_start takes 4 parameters, and it has to take 2 or 3.",
    },
    .{
        .name = "stop_hook_wrong_arity",
        .says = "stop_hook_wrong_arity.Mailer.nilo_stop takes 2 parameters, and it has to take 1.",
    },
    .{
        .name = "stop_hook_that_can_fail",
        .says = "stop_hook_that_can_fail.Mailer.nilo_stop returns something other than `void`, and a stop hook has to return `void`.",
    },
    .{
        .name = "stop_hook_taking_a_copy",
        .says = "stop_hook_taking_a_copy.Mailer.nilo_stop takes stop_hook_taking_a_copy.Mailer, and it has to take `*stop_hook_taking_a_copy.Mailer`.",
    },
    .{
        .name = "stop_hook_that_is_not_a_function",
        .says = "stop_hook_that_is_not_a_function.Mailer.nilo_stop is not a function, and it has to be one.",
    },
    .{
        .name = "too_few_pattern_params",
        .says = "argument 1 of the handler for route \"/users\" is a u32, so nilo reads it as a path param — but the route has no path params at all.",
    },
    .{
        .name = "too_many_params",
        .says = "the route pattern \"/:a/:b/:c/:d/:e/:f/:g/:h/:i\" captures 9 params, and the most nilo holds is 8.",
    },
    .{
        .name = "too_many_response_headers",
        .says = "a Response can carry 8 headers and this one was given 9.",
    },
    .{
        .name = "too_many_segments",
        .says = "the route pattern \"/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q\" has 17 segments, and the most nilo matches is 16.",
    },
    .{
        .name = "two_bodies",
        .says = "the handler for route \"/orders\" takes two structs by value — argument 1 is a two_bodies.Store and argument 2 is a two_bodies.NewOrder — and a request only has one body.",
    },
    .{
        .name = "two_bodies_on_a_route_with_a_param",
        .says = "the handler for route \"/orders/:sku\" takes two structs by value — argument 1 is a two_bodies_on_a_route_with_a_param.Sku and argument 2 is a two_bodies_on_a_route_with_a_param.NewOrder — and a request only has one body.",
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
        .says = "route \"/users/:user/pets/:pet\" has 2 path params (:user, :pet); read them by name: nilo.Path(struct { user: u32, pet: nilo.Str })",
    },
    .{
        .name = "upload_as_an_argument",
        .says = "argument 1 of the handler for route \"/avatars\" is a `nilo.Upload`, which is a field of a form rather than an argument of its own.",
    },
    .{
        .name = "url_for_a_catch_all",
        .says = "\"/assets/*\" has a `*` catch-all, and a URL cannot be built for one.",
    },
    .{
        .name = "url_param_with_no_value",
        .says = "\"/users/:id/posts/:slug\" has a param `:slug` and nothing was given for it.",
    },
    .{
        .name = "url_value_a_path_cannot_carry",
        .says = "`:id` in \"/users/:id\" was given a url_value_a_path_cannot_carry.User, which is not something a path segment can carry.",
    },
    .{
        .name = "url_value_with_no_param",
        .says = "\"/users/:id\" has no param called `:slug`, so the value given for it would go nowhere.",
    },
    .{
        .name = "wildcard_in_segment",
        .says = "the segment \"img*\" of route \"/files/img*\" mixes `*` with other text.",
    },
    .{
        .name = "ws_loop_not_a_function",
        .says = "a WebSocket route runs a function on the socket, and comptime_int is not one",
    },
    .{
        .name = "ws_loop_not_a_socket",
        .says = "a WebSocket loop's first argument is *nilo.Socket, not *nilo.Ctx",
    },
    .{
        .name = "ws_loop_wrong_arity",
        .says = "a WebSocket loop takes *Socket and nothing else, because upgrade was given no state; this one takes 2 arguments",
    },
    .{
        .name = "ws_state_mismatch",
        .says = "upgrade was given state of type u32, and the loop's second argument is nilo.Str",
    },
    .{
        .name = "ws_state_is_ctx",
        .says = "the state is a *nilo.Ctx, and the request it points at is over by the time the loop runs; take what the loop needs out of the Ctx before upgrade",
    },
    .{
        .name = "ws_state_holds_ctx",
        .says = "field `c` of the state is a *nilo.Ctx, and the request it points at is over by the time the loop runs; take what the loop needs out of the Ctx before upgrade",
    },
    .{
        .name = "events_from_no_rooms",
        .says = "eventsFrom was given no rooms, so the stream could only ever send keep-alive comments; it takes a *nilo.Room or rooms.named(key), or a tuple of them like .{ lobby, mine }",
    },
    .{
        .name = "events_from_not_a_room",
        .says = "eventsFrom was given a tuple holding *events_from_not_a_room.Inbox; it takes a *nilo.Room or rooms.named(key), or a tuple of them like .{ lobby, mine }",
    },
    .{
        .name = "ws_state_too_big",
        .says = "a WebSocket loop may carry 128 bytes of state and ws_state_too_big.Seat is 184; put it in the request arena and carry a pointer to it",
    },
    .{
        .name = "wildcard_not_last",
        .says = "the route pattern \"/files/*/raw\" has a `*` that is not the last segment.",
    },
    // The floor on a password Cost, reached through the door with no request
    // behind it (ADR 044). The message is `nilo_pw`'s; what this row holds
    // is that `nilo.verifyPasswordWith` still gets there.
    .{
        .name = "password_checked_off_the_loop_below_the_floor",
        .says = "a password Cost of 64 KiB of memory is below the floor of 7168 KiB.",
    },
};

const Refusal = struct { name: []const u8, says: []const u8 };

/// The mirror of `refusals/`: programs from the documentation that have to
/// **succeed**.
///
/// Three published one-liners did not compile at the same time — a `Str`
/// where a `[]const u8` goes, an `i64` where a `u64` goes, a namespace called
/// as a function — and each was the first thing somebody types on reaching
/// that page. The sign-in example was worse: four mistakes in five lines,
/// including a `db.acquire()` that has never existed. Prose cannot hold this,
/// and a directory of copies of the snippets would drift from the snippets
/// (ADR 068).
///
/// So the guide *is* the source. A `zig` block with `<!-- compiles -->` above
/// it — invisible where the page is read — is extracted while `build.zig`
/// runs, put behind `docs/snippets/types.zig`, and compiled. A block of loose
/// statements says `<!-- compiles: body -->` and gets `values.zig` and a
/// function around it as well.
const Snippets = struct {
    /// The pages scanned. Deliberately a list rather than a walk of `docs/`:
    /// what is checked should be a decision somebody made.
    ///
    /// **These cache, and the refusals do not.** A compilation that succeeds
    /// leaves something behind, so a warm run of all 54 is ~30ms each and
    /// only a page that changed is re-analysed. That is the opposite of
    /// `refusals/` (ADR 026) and it is why this can afford to grow — and it
    /// did: marking the SQL guide more than tripled the table.
    const pages = [_]Page{
        .{ .path = "README.md" },
        // The reference is a folder, one page a module and seven for the
        // server, and only the pages that carry a marked block are rows
        // here: a page with none would cost a read and check nothing.
        .{ .path = "docs/reference/app.md" },
        .{ .path = "docs/reference/handlers.md" },
        .{ .path = "docs/reference/core.md" },
        .{ .path = "docs/reference/middleware.md" },
        .{ .path = "docs/reference/sql.md" },
        .{ .path = "docs/reference/s3.md" },
        .{ .path = "docs/reference/id.md" },
        .{ .path = "docs/reference/pw.md" },
        .{ .path = "docs/reference/cache.md" },
        .{ .path = "docs/reference/jwt.md" },
        .{ .path = "docs/reference/proto.md" },
        .{ .path = "docs/reference/fetch.md" },
        .{ .path = "docs/reference/streaming.md" },
        .{ .path = "docs/guide/sessions.md" },
        .{ .path = "docs/guide/errors.md" },
        .{ .path = "docs/guide/static-files.md" },
        .{ .path = "docs/guide/config.md" },
        .{ .path = "docs/guide/forms.md" },
        // These three were carrying `<!-- compiles -->` marks that nothing
        // read, which is worse than an unmarked block: an unmarked block
        // claims nothing, and a marked one claims a build step checked it.
        // Five blocks across the three, two of them written the same day this
        // list was found to be short.
        .{ .path = "docs/guide/metrics.md" },
        .{ .path = "docs/guide/tracing.md" },
        .{ .path = "docs/guide/middleware.md" },
        .{ .path = "docs/guide/requests.md" },
        .{ .path = "docs/guide/responses.md" },
        .{ .path = "docs/guide/grpc.md" },
        .{ .path = "docs/guide/streaming.md" },
        .{ .path = "docs/guide/websocket.md" },
        // One page per module in the bottom layers, each against the shared
        // world: its `Carts`, its `client` and `run`, its `Doc`.
        .{ .path = "docs/guide/id.md" },
        .{ .path = "docs/guide/jwt.md" },
        .{ .path = "docs/guide/proto.md" },
        .{ .path = "docs/guide/services.md" },
        .{ .path = "docs/guide/cache.md" },
        .{ .path = "docs/guide/idempotency.md" },
        .{ .path = "docs/guide/deploying.md" },
        .{ .path = "docs/guide/fetch.md" },
        .{ .path = "docs/guide/s3.md" },
        .{ .path = "docs/guide/jobs.md" },
        .{ .path = "docs/guide/background.md" },
        // Marked on 13 September and read by nothing until the roadmap's own
        // standing risk about exactly this was checked against the tree.
        .{ .path = "docs/guide/openapi.md" },
        // The SQL guide is a folder, and its front page and every page after
        // the first read the `User` its tables page declares — so each one
        // carries that page's declarations in front of its own, which is
        // what let the guide keep showing the struct once when it was split.
        .{ .path = "docs/guide/sql/tables.md", .types = sql_types, .values = sql_values },
        .{ .path = "docs/guide/sql/reading.md", .types = sql_types, .values = sql_values, .carries = &.{"docs/guide/sql/tables.md"} },
        .{ .path = "docs/guide/sql/README.md", .types = sql_types, .values = sql_values, .carries = &.{ "docs/guide/sql/tables.md", "docs/guide/sql/reading.md" } },
        .{ .path = "docs/guide/sql/shapes.md", .types = sql_types, .values = sql_values, .carries = &.{"docs/guide/sql/tables.md"} },
        .{ .path = "docs/guide/sql/writing.md", .types = sql_types, .values = sql_values, .carries = &.{"docs/guide/sql/tables.md"} },
        .{ .path = "docs/guide/sql/transactions.md", .types = sql_types, .values = sql_values, .carries = &.{"docs/guide/sql/tables.md"} },
        .{ .path = "docs/guide/sql/raw.md", .types = sql_types, .values = sql_values, .carries = &.{"docs/guide/sql/tables.md"} },
        .{ .path = "docs/guide/sql/sqlite.md", .types = sql_types, .values = sql_values, .carries = &.{"docs/guide/sql/tables.md"} },
        .{ .path = "docs/guide/sql/migrations.md", .types = sql_types, .values = sql_values, .carries = &.{"docs/guide/sql/tables.md"} },
        .{ .path = "docs/guide/sql/running.md", .types = sql_types, .values = sql_values, .carries = &.{"docs/guide/sql/tables.md"} },
    };

    const sql_types = "docs/snippets/sql_types.zig";
    const sql_values = "docs/snippets/sql_values.zig";

    /// A page, and the world its snippets are compiled against.
    ///
    /// The default world is the running example every other page shares. The
    /// SQL guide has one of its own because it is the page that *teaches*
    /// tables: its `User` has an `age` and a `created_at` the sign-in
    /// example has no use for, and it introduces an `Order`, an `Item` and a
    /// `Product` that would be seven types of noise in front of a snippet
    /// about a cookie. A page whose types are the subject gets to own them.
    const Page = struct {
        path: []const u8,
        types: []const u8 = "docs/snippets/types.zig",
        values: []const u8 = "docs/snippets/values.zig",
        /// Pages whose marked declarations this one is read after, as if
        /// they were above it on the same page. Their blocks are not
        /// compiled again here — they have their own row for that — only
        /// carried, so a page in a folder can name a type the page before it
        /// showed.
        carries: []const []const u8 = &.{},
    };

    const opens = "<!-- compiles";
    const fence = "```";

    const Block = struct {
        name: []const u8,
        source: []const u8,
    };

    /// Every marked block in every page, ready to compile.
    fn collect(b: *std.Build) []const Block {
        var found: std.ArrayList(Block) = .empty;

        for (pages) |page| {
            const text = read(b, page.path);
            const types = read(b, page.types);
            const values = read(b, page.values);

            // What the marked declaration blocks on this page have declared
            // so far. A page is read top to bottom, so a block naming a type
            // the block above it introduced is right rather than incomplete —
            // and it is what lets the guide show the struct once.
            var declared: std.ArrayList(u8) = .empty;

            // The half of that a block of *statements* can also have: the
            // declarations which introduced no function of their own. A
            // function the page declared cannot be pasted in front of the
            // values, because its `c` parameter and the file-scope `c` the
            // statements need cannot both exist — but the `const User =
            // struct { … }` above it can, and that is the one the statements
            // are usually about.
            var shapes: std.ArrayList(u8) = .empty;

            // What the pages this one carries declared, read the same way
            // and compiled nowhere: only the declarations are kept.
            for (page.carries) |carried| {
                var above = std.mem.splitScalar(u8, read(b, carried), '\n');
                while (above.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (!std.mem.startsWith(u8, trimmed, opens)) continue;
                    if (std.mem.indexOf(u8, trimmed, "body") != null) continue;
                    _ = above.next() orelse break;
                    var block: std.ArrayList(u8) = .empty;
                    while (above.next()) |inside| {
                        if (std.mem.startsWith(u8, std.mem.trim(u8, inside, " \t\r"), fence)) break;
                        if (imports(inside)) continue;
                        block.appendSlice(b.allocator, inside) catch @panic("OOM");
                        block.append(b.allocator, '\n') catch @panic("OOM");
                    }
                    declared.appendSlice(b.allocator, block.items) catch @panic("OOM");
                    declared.append(b.allocator, '\n') catch @panic("OOM");
                    if (!declaresFn(block.items)) {
                        shapes.appendSlice(b.allocator, block.items) catch @panic("OOM");
                        shapes.append(b.allocator, '\n') catch @panic("OOM");
                    }
                }
            }

            var lines = std.mem.splitScalar(u8, text, '\n');
            var at: usize = 0;
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (!std.mem.startsWith(u8, trimmed, opens)) continue;
                const is_body = std.mem.indexOf(u8, trimmed, "body") != null;

                // The fence is the next line, and anything else is a marker
                // written above the wrong thing.
                const fenced = lines.next() orelse break;
                if (!std.mem.startsWith(u8, std.mem.trim(u8, fenced, " \t\r"), fence ++ "zig"))
                    @panic("a `<!-- compiles -->` marker is not above a ```zig block");

                var block: std.ArrayList(u8) = .empty;
                while (lines.next()) |inside| {
                    if (std.mem.startsWith(u8, std.mem.trim(u8, inside, " \t\r"), fence)) break;
                    // A page should show the import a snippet needs, and the
                    // prelude has already made that name. Keeping both is two
                    // declarations of `id` in one file.
                    if (imports(inside)) continue;
                    block.appendSlice(b.allocator, inside) catch @panic("OOM");
                    block.append(b.allocator, '\n') catch @panic("OOM");
                }

                at += 1;
                found.append(b.allocator, .{
                    .name = b.fmt("{s}_{d}", .{ slug(b, page.path), at }),
                    // A block of statements deliberately does *not* get the
                    // declarations above it: a `fn signIn(c: *nilo.Ctx, …)`
                    // and the `c` such a block says cannot both exist, and
                    // the statements are the ones that need `c`.
                    .source = if (is_body)
                        b.fmt("{s}\n{s}\n{s}\n{s}\n", .{
                            types,
                            shapes.items,
                            without(b, values, block.items),
                            wrapped(b, block.items),
                        })
                    else
                        b.fmt("{s}\n{s}\n{s}\n{s}\n", .{
                            types,
                            declared.items,
                            block.items,
                            forcing(b, block.items),
                        }),
                }) catch @panic("OOM");

                if (!is_body) {
                    declared.appendSlice(b.allocator, block.items) catch @panic("OOM");
                    declared.append(b.allocator, '\n') catch @panic("OOM");
                    if (!declaresFn(block.items)) {
                        shapes.appendSlice(b.allocator, block.items) catch @panic("OOM");
                        shapes.append(b.allocator, '\n') catch @panic("OOM");
                    }
                }
            }
        }

        return found.items;
    }

    /// A page or a prelude, read once per call and small enough not to care.
    ///
    /// **Declared as an input of the configuration.** Zig 0.17 keeps the
    /// result of configuring and does not run `build.zig` again when nothing
    /// it was told about changed; a file read here is not told about unless
    /// it is said, and a snippet edited in a page would otherwise be compiled
    /// as it was.
    fn read(b: *std.Build, path: []const u8) []const u8 {
        b.dependOnFileContents(b.path(path));
        var root = b.root.openDir(b.graph.io, ".", .{}) catch
            @panic("cannot open the build root");
        defer root.close(b.graph.io);
        return root.readFileAlloc(
            b.graph.io,
            path,
            b.allocator,
            .limited(4 << 20),
        ) catch @panic("cannot read a documentation page or its prelude");
    }

    /// Every page under `docs/` and the README that carries a mark at the
    /// start of a line and is not in `pages` — which is a mark nothing reads,
    /// and from the page it looks exactly like one a build step checked.
    ///
    /// The list stays a list, for the reason its comment gives; what this
    /// adds is that a mark cannot be written where the list does not reach.
    /// `docs/guide/openapi.md` carried one for two days before anybody
    /// noticed, found by reading the roadmap's own entry about this against
    /// the tree rather than by anything failing. A mark quoted in prose —
    /// an ADR saying what the mark is — has text in front of it on the line
    /// and is not one.
    fn unlisted(b: *std.Build) []const []const u8 {
        var found: std.ArrayList([]const u8) = .empty;
        var candidates: std.ArrayList([]const u8) = .empty;
        candidates.append(b.allocator, "README.md") catch @panic("OOM");

        // The walk is the configuration's input, and a directory is declared
        // one level at a time: a page added under any folder of `docs/` is a
        // marked page nothing reads, which is what this exists to find.
        b.dependOnDirectoryContents(b.path("docs"));
        var docs = b.root.openDir(b.graph.io, "docs", .{ .iterate = true }) catch
            @panic("cannot open docs/");
        defer docs.close(b.graph.io);
        var walker = docs.walk(b.allocator) catch @panic("OOM");
        defer walker.deinit();
        while (walker.next(b.graph.io) catch @panic("cannot walk docs/")) |entry| {
            if (entry.kind == .directory) b.dependOnDirectoryContents(b.path(b.fmt("docs/{s}", .{entry.path})));
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
            candidates.append(b.allocator, b.fmt("docs/{s}", .{entry.path})) catch @panic("OOM");
        }

        for (candidates.items) |path| {
            var listed = false;
            for (pages) |page| {
                if (std.mem.eql(u8, page.path, path)) listed = true;
            }
            if (listed) continue;
            var lines = std.mem.splitScalar(u8, read(b, path), '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), opens)) {
                    found.append(b.allocator, path) catch @panic("OOM");
                    break;
                }
            }
        }
        return found.items;
    }

    /// Whether this block introduces a function of its own — which is what
    /// keeps it out of `shapes`. Column 0 is the whole test: a `pub fn` that
    /// is indented is a method inside a struct, and a method's parameters
    /// shadow nothing.
    fn declaresFn(block: []const u8) bool {
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "fn ")) return true;
            if (std.mem.startsWith(u8, line, "pub fn ")) return true;
        }
        return false;
    }

    /// Whether this line is a snippet naming a module the prelude has named.
    fn imports(line: []const u8) bool {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        return std.mem.startsWith(u8, trimmed, "const ") and
            std.mem.indexOf(u8, trimmed, "@import(") != null;
    }

    /// A run of statements, as something the compiler will look at. `export`
    /// is what makes it look: an unreferenced private function is never
    /// analysed, so a snippet inside one would be checked for syntax and
    /// nothing else.
    fn wrapped(b: *std.Build, block: []const u8) []const u8 {
        return b.fmt(
            "export fn snippet() void {{ statements() catch {{}}; }}\n" ++
                "fn statements() anyerror!void {{\n{s}\n{s}\n}}\n",
            .{ block, discarding(b, block) },
        );
    }

    /// `_ = &x;` for every name a block of statements introduced.
    ///
    /// Zig refuses to compile a local nobody reads, and a snippet is written
    /// to be read by a person rather than to use what it names: `const all =
    /// try db.select(…);` is the line the page is teaching, and the page
    /// should not have to carry a discard beside it to keep this step happy.
    /// A published snippet with `_ = all;` in it is this file leaking into
    /// the documentation, which is the one thing ADR 068 was careful not to
    /// do. Taking the address rather than the value also settles a `var`
    /// nothing mutates, which is the same complaint under another name.
    ///
    /// Column 0 only: a name introduced inside a `for` or an `if` is out of
    /// scope by the time these run.
    fn discarding(b: *std.Build, block: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            const name = named(line, "const ") orelse named(line, "var ") orelse continue;
            out.appendSlice(b.allocator, b.fmt("    _ = &{s};\n", .{name})) catch @panic("OOM");
        }
        return out.items;
    }

    /// The values a snippet did not introduce for itself.
    ///
    /// `var tx = try db.begin(c, .{});` is the line five snippets in the
    /// transactions section open with, and `tx` is also the name the sixth
    /// one uses without opening anything. Both are how a person would write
    /// it, and a file-scope `tx` in front of the first five would make each
    /// of them a local shadowing a declaration, which Zig refuses. So the
    /// prelude carries every name and the ones the block declares itself are
    /// dropped on the way in.
    fn without(b: *std.Build, values: []const u8, block: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, values, '\n');
        while (lines.next()) |line| {
            if (named(line, "pub var ")) |name| {
                if (introduces(block, name)) continue;
            }
            out.appendSlice(b.allocator, line) catch @panic("OOM");
            out.append(b.allocator, '\n') catch @panic("OOM");
        }
        return out.items;
    }

    /// The name a line introduces, if it opens with `prefix` at column 0.
    fn named(line: []const u8, prefix: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, line, prefix)) return null;
        const after = line[prefix.len..];
        const end = std.mem.indexOfAny(u8, after, " :=") orelse return null;
        return if (end == 0) null else after[0..end];
    }

    /// Whether this block declares `name` at the top level of its own body.
    fn introduces(block: []const u8, name: []const u8) bool {
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            const found = named(line, "const ") orelse named(line, "var ") orelse continue;
            if (std.mem.eql(u8, found, name)) return true;
        }
        return false;
    }

    /// The same, for a block that declares functions: one exported function
    /// that takes the address of each, which is what drags their bodies in.
    fn forcing(b: *std.Build, block: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(b.allocator, "export fn snippet() void {\n") catch @panic("OOM");

        // Column 0 only, the way `declaresFn` reads it: an indented `pub fn`
        // is a method inside a struct, and `_ = &method;` at the top level
        // names nothing that exists.
        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            const after = if (std.mem.startsWith(u8, line, "pub fn "))
                line["pub fn ".len..]
            else if (std.mem.startsWith(u8, line, "fn "))
                line["fn ".len..]
            else
                continue;
            const open = std.mem.indexOfScalar(u8, after, '(') orelse continue;
            out.appendSlice(b.allocator, b.fmt("    _ = &{s};\n", .{after[0..open]})) catch @panic("OOM");
        }

        out.appendSlice(b.allocator, "}\n") catch @panic("OOM");
        return out.items;
    }

    /// `docs/guide/sessions.md` → `sessions`, which is what the object is
    /// called and therefore what a failure names. A page inside a folder of
    /// the guide keeps the folder — `docs/guide/sql/reading.md` →
    /// `sql_reading` — so two pages called `README.md` are two objects. The
    /// reference keeps its folder too — `docs/reference/cache.md` →
    /// `reference_cache` — because the guide has a `cache.md` as well, and a
    /// failure named `cache_1` would not say which page to open.
    fn slug(b: *std.Build, page: []const u8) []const u8 {
        const guide = "docs/guide/";
        const docs = "docs/";
        const within = if (std.mem.startsWith(u8, page, guide))
            page[guide.len..]
        else if (std.mem.startsWith(u8, page, docs))
            page[docs.len..]
        else
            std.fs.path.basename(page);
        const dot = std.mem.lastIndexOfScalar(u8, within, '.') orelse within.len;
        const name = b.allocator.dupe(u8, within[0..dot]) catch @panic("OOM");
        for (name) |*ch| {
            if (!std.ascii.isAlphanumeric(ch.*)) ch.* = '_';
        }
        return name;
    }
};

/// The suite runs in both modes, and `-Doptimize=` does not change that — a
/// lifetime bug passes in `Debug`, where the bytes a dangling pointer points at
/// happen to still be there, and segfaults in a release build, which is the
/// mode the README tells people to deploy in. Not a hypothetical:
/// `Response.headers` got away with a use-after-return for a whole stage
/// because nothing here ever built the tests any other way
/// ([ADR 018](docs/adr/018-a-response-owns-its-headers.md)).
///
/// What changed is *when* the second mode is paid for. Measured on Zig 0.16, a
/// warm suite is 0.8s in `Debug` and 7.8s in both, so both-modes-every-time was
/// charging 10× to the loop somebody sits in. `test` is now the loop and
/// `test-all` is the gate; CI runs `test-all` on every push, so the rule is
/// still held by something other than remembering.
/// An environment variable, as the default of a build option.
///
/// **This is an input of the configuration, and Zig 0.17 does not know it.** It
/// keeps the result of configuring and skips `build.zig` when the options, the
/// target and this file are what they were; a variable read behind its back
/// would leave `$DATABASE_URL` pointing at the database of the last run. So
/// reading one marks the configuration as not reusable (`poisonCache`), and
/// `build.zig` runs again on the next `zig build`. That costs the configuring,
/// not any compiling. It is only paid where the option was not given: `-D…`
/// is part of the key, and `orelse` does not reach this call when it is.
///
/// Only for the package being built. The variables name nilo's own test
/// services, which a dependent never runs, and reading them there would poison
/// the dependent's configuration for nothing.
fn environment(b: *std.Build, name: []const u8) ?[]const u8 {
    if (!b.isRoot()) return null;
    b.graph.poisonCache();
    return b.graph.environ_map.get(name);
}

const loop_mode: std.lang.Optimize = .debug;
const test_modes = [_]std.lang.Optimize{ .debug, .safe };

/// LLVM is what a `ReleaseSafe` test build costs, and none of it buys a test.
/// Measured on Zig 0.16 with `--time-report`: `fetch/deadline.zig` against the
/// whole module graph, zio included, is 27.614s, of which 25.977s is LLVM Emit.
/// That is 94.1%, and the `Debug` build of the same root has no such phase at
/// all. The self-hosted x86_64 backend compiles it in 1.6s with the same 48
/// tests green, which took `zig build test` from 30.6s to 9.8s after one edit
/// under `http/`, and `test-all` from 65.9s to 12.5s (ADR 138).
///
/// The safety checks ADR 018 is here for are inserted by Sema, so they survive
/// the swap. What does not survive is LLVM's stack layout, so this is a very
/// close gate rather than the identical one, and that trade is the ADR's
/// subject. Every `bench-*` target stays on LLVM: a throughput number measured
/// through a backend that does not optimise would be fiction.
///
/// **Only on x86_64, because that is the only place it was measured** (ADR
/// 138). The same `pw/pw.zig` that LLVM compiles in 290 MB took the
/// self-hosted aarch64 backend past 4 GB in seven seconds and past 15 GB before
/// it was killed, and `zig build test` at `-j8` is eight of those at once —
/// which on a 16 GB laptop is not a slow build but a dead machine, three times.
/// Elsewhere both modes get `null`, which is Zig's default and is LLVM on
/// aarch64 in both of them; nothing here forces a backend Zig would not pick.
fn testBackend(target: std.Build.ResolvedTarget, mode: std.lang.Optimize) ?bool {
    if (mode == loop_mode) return null;
    return if (target.result.cpu.arch == .x86_64) false else null;
}

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
fn stripMeasured(strip: ?bool, optimize: std.lang.Optimize) ?bool {
    if (strip) |asked| return asked;
    return if (optimize == .fast) true else null;
}

/// zio for one optimize mode, with its tasks pinned to the executor they
/// start on (ADR 199).
///
/// Every copy of zio in this file comes from here, because the scheduling
/// mode is a compile-time default and a copy fetched without it would work
/// steal: nothing fails, the server only spends more CPU a request, and a
/// gRPC call spawned `.local` falls back to round-robin. The default is
/// zio's build option rather than a `zio_options` declaration because the
/// root module is the application's, not nilo's; an application that
/// declares `zio_options` in its root still gets what it declared, which is
/// how zio means the two to combine (zio#704).
fn zioFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
) *std.Build.Dependency {
    return b.dependency("zio", .{ .target = target, .optimize = mode, .scheduling = .pinned });
}

/// A copy of Core for one optimize mode (ADR 038).
///
/// A module carries the mode it was created with, so every root that reaches
/// Core needs one of its own — the same reason zio is fetched once per mode
/// below. `createModule` and not `addModule`: only the top-level `nilo_core`
/// is a name somebody else's project may import.
fn coreFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("core/core.zig"),
        .target = target,
        .optimize = mode,
    });
}

/// A copy of `nilo_id` for one optimize mode, for the same reason (ADR 038).
///
/// It has to be *shared* with whatever else in that mode names a `Uuid`, not
/// merely built from the same file: two modules built from one root are two
/// different modules to Zig, so a second copy would make `id.Uuid` and
/// `sql.Uuid` two distinct types and `db.insert` would refuse a generated
/// key with a message about a type that looks identical to the one it wants.
fn idFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("id/id.zig"),
        .target = target,
        .optimize = mode,
    });
}

/// A copy of `nilo_config` for one optimize mode (ADR 039).
///
/// Unlike `idFor` this one has nothing to share with: a Config is a struct
/// of the caller's own and no other module names a type from here, so two
/// copies would only be wasteful rather than wrong. It is a function for the
/// same reason the others are — a module carries the mode it was created
/// with, so every root that reaches this needs one of its own.
fn configFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("config/config.zig"),
        .target = target,
        .optimize = mode,
    });
}

/// A copy of `nilo_pw` for one optimize mode (ADR 044).
///
/// Shared rather than merely built from the same file, for the reason `idFor`
/// is: `http/password.zig` names `pw.Hash` and so does a caller's own row, and
/// two modules built from one root are two types to Zig.
fn pwFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("pw/pw.zig"),
        .target = target,
        .optimize = mode,
    });
}

/// A copy of `nilo_cache` for one optimize mode (ADR 109).
///
/// Shared rather than merely built from the same file, for the reason `pwFor`
/// is: a `Space` is a type, and two modules built from one root are two types
/// to Zig — so a handler holding a `*Carts` from one would not match the
/// `Carts` a Store registered from the other.
fn cacheFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("cache/cache.zig"),
        .target = target,
        .optimize = mode,
    });
}

/// A copy of `nilo_jwt` for one optimize mode (ADR 111).
///
/// Self contained the way `pwFor` and `cacheFor` are: it names nothing, so
/// there is no shared type to keep the two modes agreeing about.
fn jwtFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("jwt/jwt.zig"),
        .target = target,
        .optimize = mode,
    });
}

/// A copy of `nilo_proto` for one optimize mode (ADR 245).
///
/// Self contained the way `pwFor` and `jwtFor` are: it names nothing, so
/// there is no shared type to keep the two modes agreeing about.
fn protoFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
) *std.Build.Module {
    // One per mode, because `nilo_http` names it for the trace exporter
    // (ADR 247) and a compilation that holds the server and a program's own
    // `nilo_proto` may hold only one module rooted at `proto/proto.zig`.
    for (proto_made.items) |made| {
        if (made.owner == b and made.mode == mode) return made.module;
    }
    const module = b.createModule(.{
        .root_source_file = b.path("proto/proto.zig"),
        .target = target,
        .optimize = mode,
    });
    remember(b, &proto_made, .{ .owner = b, .mode = mode, .module = module });
    return module;
}

/// The modules `protoFor` and `fetchFor` already made, so a second ask in the
/// same mode (and, for `nilo_fetch`, on the same Core) is the same module.
/// Zig refuses a compilation in which one file belongs to two modules, and
/// since `nilo_http` names both for tracing (ADR 247), every root that holds
/// the server beside one of them would otherwise hold two.
///
/// Keyed by the builder as well, and grown rather than fixed: the build
/// runner compiles this file once per process, so these lists are shared by
/// every instance of nilo in it, and a dependent that asks for nilo in two
/// optimize modes runs `build` twice into the same lists. A fixed array of 32
/// overflowed on the second instance (`index out of bounds` in `fetchFor`).
const Made = struct {
    owner: *std.Build,
    mode: std.lang.Optimize,
    core: ?*std.Build.Module = null,
    module: *std.Build.Module,
};
var proto_made: std.ArrayList(Made) = .empty;
var fetch_made: std.ArrayList(Made) = .empty;

fn remember(b: *std.Build, list: *std.ArrayList(Made), made: Made) void {
    list.append(b.allocator, made) catch @panic("OOM");
}

/// A copy of `nilo_fetch` for one optimize mode (ADR 061).
///
/// The first Fitting, and the first module down here that is not self
/// contained: it names `nilo_core` for `Limits` and for the Scope a body is
/// allocated from. So unlike `pwFor` this one takes an import, and the Core it
/// takes has to be the *same* Core as whatever else in that mode holds a
/// `Str` — two modules built from one root are two types to Zig, and a `Str`
/// that came back from a call would not be the `Str` a handler returns.
fn fetchFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
    core_mod: *std.Build.Module,
) *std.Build.Module {
    for (fetch_made.items) |made| {
        if (made.owner == b and made.mode == mode and made.core == core_mod) return made.module;
    }
    const module = b.createModule(.{
        .root_source_file = b.path("fetch/fetch.zig"),
        .target = target,
        .optimize = mode,
        .imports = &.{.{ .name = "nilo_core", .module = core_mod }},
    });
    remember(b, &fetch_made, .{ .owner = b, .mode = mode, .core = core_mod, .module = module });
    return module;
}

/// A copy of `nilo_job` for one optimize mode (ADR 160).
///
/// The second Fitting, and it takes its Core the way `fetchFor` does and for
/// the same reason: a job's payload may carry a `Str`, and the `Str` a job
/// parses back has to be the `Str` the handler that pushed it wrote.
fn jobFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
    core_mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("job/job.zig"),
        .target = target,
        .optimize = mode,
        .imports = &.{.{ .name = "nilo_core", .module = core_mod }},
    });
}

/// A copy of `nilo_s3` for one optimize mode (ADR 063).
///
/// The first module here that takes two imports, and the second has to be the
/// *same* `nilo_fetch` as anything else in that mode which holds an
/// `Exchange` — two modules built from one root are two types to Zig, the same
/// trap `idFor` documents.
fn s3For(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
    core_mod: *std.Build.Module,
    s3_config: ?*std.Build.Module,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("s3/s3.zig"),
        .target = target,
        .optimize = mode,
        .imports = &.{
            .{ .name = "nilo_core", .module = core_mod },
            .{ .name = "nilo_fetch", .module = fetchFor(b, target, mode, core_mod) },
        },
    });
    // Only a test build needs it: `s3/live.zig` is named from a `test` block,
    // and an import reached only from one is never analysed in a build that is
    // not a test build. Which is what lets the published module carry no
    // configuration at all.
    if (s3_config) |cfg| module.addImport("s3_config", cfg);
    return module;
}

/// `-Dtls`, and whether this is the repository building itself. Read by
/// `wireOptions` below, which every instance of the http module goes through.
var want_tls: bool = false;
/// `-Dtls_own` (ADR 274): the dependent writes the `tls` import itself.
var want_tls_own: bool = false;
var in_repo: bool = false;
/// `-Dhttp2` (ADR 259, ADR 220). No dependency behind it, unlike `-Dtls`: what
/// it keeps out of a build that did not ask is the code, the binary size ADR
/// 017 counts, rather than a fetch.
var want_http2: bool = false;

/// `-Dlibdeflate` (ADR 248): gzip through libdeflate rather than
/// `std.flate`, for a response and for a static file gzipped at load.
var want_libdeflate: bool = false;

/// What every instance of the http module is given so that
/// `http/engine/zio.zig` can ask `@import("nilo_build").tls` and, when the
/// answer is yes, `@import("tls")` (ADR 212), and `http/compress.zig` can
/// ask which deflate it gzips with (ADR 248).
///
/// `on` decides both. The library is reached through `lazyDependency`
/// **inside** the `if`, which is what makes the manifest's `.lazy = true`
/// mean anything: called unconditionally it would fetch for every dependent
/// whatever they asked for (ADR 066). An instance built with `on = false`
/// carries no import named `tls`, so a `@import("tls")` reached from it is a
/// compile error rather than a link, and the comptime `if` in the Engine is
/// what keeps it from being reached.
///
/// `-Dtls_own` swaps the library for a stub that names the line a dependent
/// writes to supply their own (ADR 274).
///
/// libdeflate is the same shape with one difference: `link_libdeflate` can
/// be true while `want_libdeflate` is not. That is this repository's own
/// http test root, which links the library whatever the flag says so that
/// `compress.zig`'s tests hold both backends in one run, while the App
/// under test keeps the backend a dependent gets by default.
fn wireOptions(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, mode: std.lang.Optimize, on: bool, http2: bool, link_libdeflate: bool) void {
    const opts = b.addOptions();
    opts.addOption(bool, "tls", on);
    // HTTP/2 rides the same options module, and gRPC rides HTTP/2. It has no
    // library to fetch, so there is nothing to wire beyond the flag (ADR 259).
    opts.addOption(bool, "http2", http2);
    const linked = link_libdeflate or want_libdeflate;
    opts.addOption(bool, "libdeflate", want_libdeflate);
    opts.addOption(bool, "libdeflate_linked", linked);
    module.addImport("nilo_build", opts.createModule());
    if (on and want_tls_own) {
        // The dependent brings the library (ADR 274). The pin is not asked
        // for, so it is not fetched; what stands in its place is a module
        // that fails to compile with the line to write, and the dependent's
        // `addImport("tls", …)` replaces it by name, which `addImport` does
        // when the name is taken.
        module.addImport("tls", b.createModule(.{
            .root_source_file = b.path("http/engine/tls_unset.zig"),
            .target = target,
            .optimize = mode,
        }));
    } else if (on) {
        if (b.lazyDependency("tls", .{ .target = target, .optimize = mode })) |dep| {
            module.addImport("tls", dep.module("tls"));
        }
    }
    if (linked) {
        if (libdeflateFor(b, target)) |lib| module.linkLibrary(lib);
    }
}

/// libdeflate's compressor as a static library, from the upstream release
/// tarball (ADR 248). Nothing of it but compression: no decompressor, no
/// zlib or raw-deflate wrapper beyond what gzip calls, and **not
/// `lib/utils.c`**, whose freestanding `memcpy` and `memset` are weak byte
/// loops that won the link for the whole program when it was in.
/// `http/libdeflate.zig` provides the four symbols the rest needs from it.
///
/// Always `ReleaseFast`, whatever the program is built as, the way
/// `bench-compress` is: a Debug deflate is a different program, and C at
/// `-O0` under the undefined-behaviour sanitizer is not the library that
/// was measured. `FREESTANDING` with `-fbuiltin` because nilo's plain build
/// links no libc: the macro keeps libdeflate from naming `malloc`, and the
/// builtins keep `memcpy` of a constant size a load rather than a call.
///
/// **No target feature is added for the AVX-512 CRC path.** On Zig 0.16
/// (LLVM 21) that path needed the target to gain `evex512`, because LLVM
/// refused it without and refused `-mevex512` as a flag. LLVM 22 removed the
/// feature: 512-bit vectors follow from `avx512f`, and the AVX-512 code is in
/// functions that switch the features on by attribute and are chosen at run
/// time from `cpuid`, so a baseline x86_64 build runs on any x86_64 and takes
/// the wide path where there is one.
fn libdeflateFor(b: *std.Build, target: std.Build.ResolvedTarget) ?*std.Build.Step.Compile {
    const dep = b.lazyDependency("libdeflate", .{}) orelse return null;
    const lib = b.addLibrary(.{
        .name = "nilo-libdeflate",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
        }),
    });
    const flags: []const []const u8 = &.{ "-std=c99", "-DFREESTANDING", "-ffreestanding", "-fbuiltin", "-DNDEBUG", "-fno-sanitize=all" };
    lib.root_module.addIncludePath(dep.path("."));
    lib.root_module.addCSourceFiles(.{
        .root = dep.path("lib"),
        .files = &.{
            "deflate_compress.c",
            "gzip_compress.c",
            "crc32.c",
            "x86/cpu_features.c",
            "arm/cpu_features.c",
        },
        .flags = flags,
    });
    return lib;
}

/// zqlite for one optimize mode, over a SQLite that is always `ReleaseFast`
/// (ADR 249).
///
/// zqlite's own `build.zig` takes one `optimize` for its Zig and for the
/// amalgamation both, so asking it for `ReleaseFast` would also take the
/// safety checks out of the wrapper in a `ReleaseSafe` program. Only its
/// files are taken: `src/zqlite.zig` is built here in the program's mode,
/// and `lib/sqlite3.c` once, with zqlite's own flags, whatever the mode. One
/// object then serves Debug and `ReleaseSafe` alike, and the `ReleaseSafe`
/// compile, the slow one (34 s and 1 GB on this machine against 20 s and
/// 700 MB), never runs. The undefined-behaviour sanitizer a Debug or
/// `ReleaseSafe` C compile carries is not a check on nilo's code.
fn zqliteFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
) ?*std.Build.Module {
    const dep = b.lazyDependency("zqlite", .{ .target = target, .optimize = .fast }) orelse return null;
    const lib = b.addLibrary(.{
        .name = "nilo-sqlite",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
        }),
    });
    lib.root_module.addIncludePath(dep.path("lib"));
    lib.root_module.addCSourceFile(.{ .file = dep.path("lib/sqlite3.c"), .flags = &.{"-std=c99"} });
    const c = b.addTranslateC(.{
        .root_source_file = dep.path("lib/sqlite3.h"),
        .target = target,
        .optimize = .fast,
    });
    const module = b.createModule(.{
        .root_source_file = dep.path("src/zqlite.zig"),
        .target = target,
        .optimize = mode,
        .imports = &.{.{ .name = "c", .module = c.createModule() }},
    });
    module.linkLibrary(lib);
    return module;
}

/// A copy of the server for one optimize mode, for a test root that needs a
/// running one.
///
/// The Core is passed in rather than made here, for the reason it is shared
/// everywhere else: two modules built from one root are two types to Zig, so a
/// `Str` from the framework and a `Str` from a Fitting have to come from the
/// same `nilo_core` or they are not the same type.
fn httpFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
    core_mod: *std.Build.Module,
) *std.Build.Module {
    return httpWith(b, target, mode, core_mod, want_tls);
}

/// `httpFor`, with TLS decided by the caller: a test root that needs a TLS
/// listener whatever the flag says, as this repository's own http suite
/// does. Only ever asked with `tls` true where `in_repo`, because it is
/// `wireOptions` that fetches the library and a dependent that did not
/// pass `.tls` must not (ADR 066).
fn httpWith(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mode: std.lang.Optimize,
    core_mod: *std.Build.Module,
    tls: bool,
) *std.Build.Module {
    const engine = zioFor(b, target, mode);
    const module = b.createModule(.{
        .root_source_file = b.path("http/http.zig"),
        .target = target,
        .optimize = mode,
        .imports = &.{
            .{ .name = "zio", .module = engine.module("zio") },
            .{ .name = "nilo_core", .module = core_mod },
            .{ .name = "nilo_proto", .module = protoFor(b, target, mode) },
            .{ .name = "nilo_fetch", .module = fetchFor(b, target, mode, core_mod) },
            .{ .name = "nilo_pw", .module = pwFor(b, target, mode) },
        },
    });
    wireOptions(b, module, target, mode, tls, want_http2, false);
    return module;
}

/// The repository's own checks: the layering, the ADRs, the documentation and
/// what a dependent downloads. Each is a subcommand of the program in
/// `checks/` (its header says why they are programs and not steps), and each
/// step here is one Run of it from the repository root.
///
/// **They run every time they are asked for.** A Run step whose only result is
/// its exit code has side effects, so the build does not cache it, which is
/// what the old steps did too: a scan of the tree is cheaper than working out
/// which part of the tree it read. Their failure is the exit code, and the
/// messages are the program's stderr.
///
/// **Only in this repository.** `checks/` is not in `.paths`, so a dependent
/// has none of it, and every function here is called only where `in_repo`.
const Checks = struct {
    var program: ?*std.Build.Step.Compile = null;

    /// The program, built for the machine running the build whatever target
    /// was asked for.
    ///
    /// `ReleaseSafe` and not Debug, though it costs about 45 s to compile once
    /// (and again whenever `checks/` changes): the ADR scan alone took 4.5 s in
    /// Debug against 0.1 s here, every run of `zig build test`, and a gate that
    /// adds seven seconds to the loop is one somebody takes off it. The safety
    /// checks stay, because a scan that indexes past the end of a file should
    /// stop rather than pass.
    fn exe(b: *std.Build) *std.Build.Step.Compile {
        if (program) |built| return built;
        const made = b.addExecutable(.{
            .name = "nilo-checks",
            .root_module = b.createModule(.{
                .root_source_file = b.path("checks/main.zig"),
                .target = b.graph.host,
                .optimize = .safe,
            }),
        });
        program = made;
        return made;
    }

    /// One Run of the program in the repository root, named for what it
    /// checks. The caller adds the arguments that follow the subcommand.
    fn run(b: *std.Build, name: []const u8, command: []const u8) *std.Build.Step.Run {
        const run_step = b.addRunArtifact(exe(b));
        run_step.setName(name);
        run_step.setCwd(b.path("."));
        run_step.addArg(command);
        return run_step;
    }

    fn csv(b: *std.Build, names: []const []const u8) []const u8 {
        return std.mem.join(b.allocator, ",", names) catch @panic("OOM");
    }

    /// Refuses an import that is not in `layers`, then the one layering rule
    /// `http/` can hold (`http_core`, and the account of why it is only one).
    fn layering(b: *std.Build) *std.Build.Step {
        const named = b.step("layering", "Check that no module imports upward or sideways");
        const modules = run(b, "layering", "layering");
        for (layers) |layer| modules.addArg(b.fmt("{s}={s}={s}", .{
            layer.root, csv(b, layer.may_import), csv(b, layer.in_tests),
        }));
        named.dependOn(&modules.step);
        // The second half of the same question, one layer down: `http/` has no
        // module boundaries inside it, so what it can hold is the edge of its
        // core rather than a stack. `http_core` is the account.
        const core = run(b, "http-core", "http-core");
        core.addArgs(&.{ csv(b, &http_core), csv(b, &http_above_core) });
        named.dependOn(&core.step);
        return named;
    }

    /// Every ADR cited is one that exists, and none by its old number
    /// (ADR 221).
    fn adrs(b: *std.Build) *std.Build.Step {
        const named = b.step("adr-check", "Check the ADRs' shape and that every ADR cited exists");
        named.dependOn(&run(b, "adr-check", "adr-check").step);
        return named;
    }

    /// With `write`, the step that rewrites the lists the check compares.
    fn docs(b: *std.Build, write: bool) *std.Build.Step {
        const named = if (write)
            b.step("docs-index", "Rewrite the reference's list of every heading, and the roadmap's lists of todo entries")
        else
            b.step("docs-check", "Check each doc page's head, prose and links, the map, the reference's list of headings, and the roadmap's lists of todo entries");
        const command = if (write) "docs-index" else "docs-check";
        named.dependOn(&run(b, command, command).step);
        return named;
    }

    /// What a dependent that serves HTTP downloads (ADR 066). Off `test` on
    /// purpose, the way `smoke-tls` is: it needs the internet, and a gate that
    /// passes because a machine had no route is worse than no gate.
    fn fetch(b: *std.Build, network: bool) void {
        const named = b.step(
            "fetch-check",
            "Count what a dependent that serves HTTP downloads — needs -Dnetwork",
        );
        if (!network) {
            // The same shape `smoke-tls` uses: say it skipped rather than
            // report a pass nobody earned.
            notice(b, named, false, "fetch-check: skipped, because it downloads packages. `zig build fetch-check -Dnetwork` runs it.");
            return;
        }
        const check = run(b, "fetch-check", "fetch-check");
        check.addFileArg(.zig_exe);
        // The compiler's own cache root, where the program makes the cold
        // cache it counts downloads in.
        check.addDirectoryArg2(.cache_root, .{ .make_absolute = true });
        named.dependOn(&check.step);
    }

    /// `template/` builds and passes its own test against this working copy
    /// (ADR 263). On `test`, because it needs nothing `test` does not: zio
    /// is already in the global cache.
    fn template(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
        const named = b.step("template-check", "Build and test template/ against this working copy, the way a first project does");
        const check = run(b, "template-check", "template-check");
        check.addFileArg(.zig_exe);
        check.addDirectoryArg2(.cache_root, .{ .make_absolute = true });
        check.addArg(target.query.zigTriple(b.allocator) catch @panic("OOM"));
        // Its inputs are files the Run step does not hash, and the child
        // build keeps its own cache, so it runs when asked.
        check.has_side_effects = true;
        named.dependOn(&check.step);
        return named;
    }

    /// Say out loud that a step asserted nothing.
    ///
    /// **`error.SkipZigTest` is invisible through `zig build`.** The test runner
    /// counts a skip, `zig build` prints a run artifact's stdout only when it
    /// fails, so a step whose every test skipped exits 0 having checked nothing
    /// and looks exactly like one that passed. `smoke-tls` was that: three tests,
    /// no output, exit 0, on any machine without `-Dnetwork`.
    ///
    /// That is the shape of a gate that has quietly stopped being one, which is
    /// the failure this repository has had four times (`docs/history.md`). So the
    /// step says it, the way `fetch-check` already did. When `running` the real
    /// work runs and this prints nothing, and a dependent never prints, because
    /// it has no program to print with and no step of nilo's it could run.
    fn notice(b: *std.Build, to: *std.Build.Step, running: bool, message: []const u8) void {
        if (running or !in_repo) return;
        const said = run(b, "skip notice", "notice");
        said.addArg(message);
        to.dependOn(&said.step);
    }
};

/// A directory of files as the module `app.embedded` takes, for a dependent's
/// own `build.zig` (ADR 009).
///
/// ```zig
/// const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize });
/// const frontend = @import("nilo").embedDir(b, nilo.module("nilo_http"), "frontend/dist");
/// exe.root_module.addImport("frontend", frontend);
/// ```
///
/// and, in the program, `try app.embedded("/", &@import("frontend").files);`.
///
/// `dir` is relative to the build root, or absolute. It is walked every time
/// `zig build` configures, so a front end rebuilt with new hashed names is
/// picked up by the next build with nothing to regenerate, and each file is
/// copied beside a generated `embedded.zig` because `@embedFile` reaches only
/// files inside its own module's directory. The module exports `files`, an
/// array of `nilo_http.static.Embedded`.
///
/// **Which files**: regular files only, sorted by path so the cache key does
/// not follow directory order. A name with a `.` segment (`.env`, `.git/`) and
/// a symlink are left out, the two rules `app.static` walks by, so a tree
/// served from the binary is the tree served from a disk. There is no size
/// cap: the binary carries what the caller points this at. An empty or
/// missing directory stops the build, naming it, because a front end that was
/// not built yet is not a binary to ship.
pub fn embedDir(b: *std.Build, nilo_http: *std.Build.Module, dir: []const u8) *std.Build.Module {
    const io = b.graph.io;
    const absolute = std.fs.path.isAbsolute(dir);
    // The names in the tree are read now and decide the module's files, so
    // they are an input of the configuration: a front end rebuilt with new
    // hashed names must be seen by the next build, which Zig 0.17 would
    // otherwise answer from the configuration it kept. The files' *contents*
    // are copied by a step and tracked there. A directory is declared one
    // level at a time, so each one the walk meets is declared as it is met.
    const tree_path: std.Build.LazyPath = if (absolute) b.graph.cwdRelativePath(dir) else b.path(dir);
    b.dependOnDirectoryContents(tree_path);
    var tree = (if (absolute)
        std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true })
    else
        b.root.openDir(io, dir, .{ .iterate = true })) catch |err|
        std.process.fatal("nilo: embedDir cannot open \"{s}\" ({s})", .{ dir, @errorName(err) });
    defer tree.close(io);

    var paths: std.ArrayList([]const u8) = .empty;
    var walker = tree.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err|
        std.process.fatal("nilo: embedDir cannot walk \"{s}\" ({s})", .{ dir, @errorName(err) })) |entry|
    {
        if (entry.kind == .directory) b.dependOnDirectoryContents(tree_path.path(b, entry.path));
        if (entry.kind != .file) continue;
        var segments = std.mem.tokenizeAny(u8, entry.path, "/\\");
        const hidden = while (segments.next()) |segment| {
            if (segment[0] == '.') break true;
        } else false;
        if (hidden) continue;
        paths.append(b.allocator, b.dupe(entry.path)) catch @panic("OOM");
    }
    if (paths.items.len == 0) std.process.fatal(
        "nilo: embedDir found no files in \"{s}\"; build the front end before the program that carries it",
        .{dir},
    );
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lt);

    const copies = b.addWriteFiles();
    var source: std.Io.Writer.Allocating = .init(b.allocator);
    const w = &source.writer;
    w.print(
        "//! Generated by nilo's `embedDir` from \"{f}\". Do not edit.\n" ++
            "const Embedded = @import(\"nilo_http\").static.Embedded;\n\n" ++
            "pub const files = [_]Embedded{{\n",
        .{std.zig.fmtString(dir)},
    ) catch @panic("OOM");
    for (paths.items) |path| {
        // Forward slashes whatever the host spelled them with: the path is a
        // URL once `embed` has joined it to a prefix.
        const url_path = b.allocator.dupe(u8, path) catch @panic("OOM");
        std.mem.replaceScalar(u8, url_path, '\\', '/');
        w.print("    .{{ .path = \"{f}\", .bytes = @embedFile(\"tree/{f}\") }},\n", .{
            std.zig.fmtString(url_path), std.zig.fmtString(url_path),
        }) catch @panic("OOM");
        const from = b.fmt("{s}/{s}", .{ dir, path });
        const source_path: std.Build.LazyPath = if (absolute)
            b.graph.cwdRelativePath(from)
        else
            b.path(from);
        _ = copies.addCopyFile(source_path, b.fmt("tree/{s}", .{url_path}));
    }
    w.writeAll("};\n") catch @panic("OOM");

    return b.createModule(.{
        .root_source_file = copies.add("embedded.zig", source.written()),
        .imports = &.{.{ .name = "nilo_http", .module = nilo_http }},
    });
}

/// What `app` is asked for (ADR 263). Every field after `root` has a default,
/// so a field added later changes no project that is already written, which
/// is the property 1.0 freezes.
pub const AppOptions = struct {
    /// The executable's name, and what `zig build` installs it as.
    name: []const u8,
    /// The file with `pub fn main`.
    root: std.Build.LazyPath,
    /// Read from `-Dtarget` when left out, as `zig init` does.
    target: ?std.Build.ResolvedTarget = null,
    /// Read from `-Doptimize` when left out, and passed through unchanged to
    /// the dependency, the executable and the test (ADR 069).
    optimize: ?std.lang.Optimize = null,
    /// The build flags of the dependency (ADR 066, 212, 259, 248), each off
    /// until asked, so a project that sets none fetches zio and nothing else.
    sql: bool = false,
    tls: bool = false,
    http2: bool = false,
    libdeflate: bool = false,
    /// A TLS library of the project's own, in place of nilo's pin (ADR 274):
    /// a module from `b.dependency("tls", …)` whose API is the one
    /// `docs/reference/app.md` lists. Implies `tls`, and nilo's pin is not
    /// fetched.
    tls_module: ?*std.Build.Module = null,
};

/// What `app` made, for a project that wants to add to it.
pub const AppBuilt = struct {
    exe: *std.Build.Step.Compile,
    /// The test of the same root module, so `zig build test` runs the tests
    /// of `main.zig` and of everything it imports.
    tests: *std.Build.Step.Compile,
    /// The `nilo` dependency this was built against, to ask for a module the
    /// options did not wire (`dependency.module("nilo_id")`) without a second
    /// instance of it.
    dependency: *std.Build.Dependency,
};

/// A whole project in one call from a dependent's `build.zig` (ADR 263):
/// the executable with `nilo_http` imported (and `nilo_sql` when asked for),
/// installed, and the steps `run`, `dev` and `test`.
///
/// ```zig
/// const nilo = @import("nilo");
/// pub fn build(b: *std.Build) void {
///     _ = nilo.app(b, .{ .name = "hello", .root = b.path("src/main.zig") });
/// }
/// ```
///
/// `dev` is the restart on every save of ADR 190, wired as `dev-<example>`
/// is in this file. Nothing here reads the repository, so it is the same
/// function in a dependent and in this checkout.
pub fn app(b: *std.Build, options: AppOptions) AppBuilt {
    const target = options.target orelse b.standardTargetOptions(.{});
    const optimize = options.optimize orelse b.standardOptimizeOption(.{});

    const dependency = b.dependency("nilo", .{
        .target = target,
        .optimize = optimize,
        .sql = options.sql,
        .tls = options.tls or options.tls_module != null,
        .tls_own = options.tls_module != null,
        .http2 = options.http2,
        .libdeflate = options.libdeflate,
    });
    if (options.tls_module) |own| dependency.module("nilo_http").addImport("tls", own);

    const root = b.createModule(.{
        .root_source_file = options.root,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nilo_http", .module = dependency.module("nilo_http") }},
    });
    if (options.sql) root.addImport("nilo_sql", dependency.module("nilo_sql"));

    const exe = b.addExecutable(.{ .name = options.name, .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the server").dependOn(&run.step);

    // The runner executes on the machine running the build, whatever the
    // server is built for, so it comes from a second instance of the
    // dependency asked for the host. Nothing of that instance is fetched or
    // built beyond `nilo-dev`, which imports `std` alone.
    const host = b.dependency("nilo", .{ .target = b.graph.host, .optimize = .safe });
    const dev = b.addRunArtifact(host.artifact("nilo-dev"));
    dev.addArg("--zig");
    dev.addFileArg(.zig_exe);
    dev.addPassthruArgs();
    // A directory argument, because a file one would be an input the step
    // hashes and this one is written by the build `nilo-dev` itself starts.
    dev.addDirectoryArg2(
        .{ .relative = .{ .base = .install_bin, .sub_path = exe.out_filename } },
        .{ .make_absolute = true },
    );
    b.step("dev", "Rebuild and restart on every save").dependOn(&dev.step);

    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);

    return .{ .exe = exe, .tests = tests, .dependency = dependency };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Leave debug info out: halves a release build, costs nothing measurable at runtime, and leaves a panic without file and line");

    // Whether the database drivers are wanted, and it defaults to **who is
    // asking** rather than to a fixed answer (ADR 066).
    //
    // `b.lazyDependency` does not mean "fetch this if somebody imports it". It
    // means *request* this: it answers null on the pass that finds the package
    // missing, enqueues the download and re-runs the build. Called at the top
    // of `build()` it therefore runs for every dependent whatever they import,
    // and `.lazy = true` in the manifest buys nothing — which is how an app
    // that serves HTTP and names no SQL came to download 11.1 MB of Postgres
    // and SQLite driver before it compiled a line.
    //
    // So the call has to sit behind something only a project that wants the
    // module sets. `b.pkg_hash` is empty for the package being built and is
    // the dependency's own hash when somebody else is building it, which makes
    // the honest default expressible: this repository builds all of itself,
    // and a dependent gets the drivers when it asks for them with
    // `b.dependency("nilo", .{ .sql = true })`.
    const want_sql = b.option(
        bool,
        "sql",
        "Build nilo_sql and fetch its drivers — on for this repository, off for a dependent until it asks (see ADR 066)",
    ) orelse (b.pkg_hash.len == 0);

    const zio = zioFor(b, target, optimize);

    // Whether the published module speaks TLS (ADR 212). Off until asked,
    // for everybody: the library it needs is fetched and linked only behind
    // this flag, the same way the drivers sit behind `-Dsql`, and the two
    // measured binaries stay what ADR 017 publishes. What is always on is
    // the *test* of it: this repository's own suite builds its `http` test
    // root with TLS in it whatever the flag says, so the feature is held by
    // `zig build test` rather than by whoever remembers to pass `-Dtls`.
    want_tls = b.option(
        bool,
        "tls",
        "Build the TLS listener into nilo_http and fetch the library it needs (ADR 212). Off until a dependent passes `.tls = true`",
    ) orelse false;
    want_tls_own = b.option(
        bool,
        "tls_own",
        "Leave the `tls` import to the dependent, who writes `nilo.module(\"nilo_http\").addImport(\"tls\", their_module)`, and fetch nothing for it (ADR 274). Needs `.tls = true`",
    ) orelse false;
    if (want_tls_own and !want_tls) std.process.fatal(
        "nilo: `.tls_own = true` is a way of supplying the TLS library, so it needs `.tls = true` as well (ADR 274).",
        .{},
    );
    in_repo = b.pkg_hash.len == 0;
    want_http2 = b.option(
        bool,
        "http2",
        "Build HTTP/2 into nilo_http, which gRPC rides (ADR 259, ADR 220). Off until a dependent passes `.http2 = true`",
    ) orelse false;
    // The flag's old name is declared only to be refused: an undeclared
    // option is reported at the end of configuration as "invalid option",
    // which says nothing about what to pass instead.
    if (b.option(bool, "grpc", "Renamed: pass `-Dhttp2` (ADR 259)") != null) std.process.fatal(
        "nilo: `-Dgrpc` is `-Dhttp2` now: HTTP/2 serves every request and gRPC rides it (ADR 259). " ++
            "Pass `.http2 = true` to `b.dependency(\"nilo\", …)`.",
        .{},
    );
    // Whether gzip is libdeflate's (ADR 248). Off until asked, the way TLS
    // is: the C is fetched and compiled only behind this flag, and a build
    // without it gzips with `std.flate` exactly as before. What is always
    // on, in this repository, is the test of it: the http test root links
    // the library whatever the flag says, as it builds TLS in.
    want_libdeflate = b.option(
        bool,
        "libdeflate",
        "Gzip responses and static files with libdeflate instead of std.flate, and fetch it (ADR 248). Off until a dependent passes `.libdeflate = true`",
    ) orelse false;

    // The bottom layer: what every other one agrees about, and nothing else
    // (ADR 038). It names no Engine and does no IO, which is why it is the
    // one module here that needs no import of its own — and why
    // `zig test core/core.zig` runs the whole of it without this file.
    const nilo_core = b.addModule("nilo_core", .{
        .root_source_file = b.path("core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The bottom layer's second module, and the first that is not the
    // vocabulary (ADR 038). It needs no event loop, so it sits beside
    // `nilo_core` rather than above it — and it imports nothing at all, which
    // `zig build layering` checks rather than trusts.
    const nilo_id = b.addModule("nilo_id", .{
        .root_source_file = b.path("id/id.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The second tool module: a Config out of the environment (ADR 039).
    // It imports nothing at all, which is what `zig build layering` checks
    // and what makes `zig test config/config.zig` the whole of its suite.
    //
    // Nothing else in this file names it. A project that serves HTTP and
    // reads no settings from here links none of it, which is the same
    // property ADR 037 bought for the SQL module pointed at a module with
    // no dependency to be lazy about.
    const nilo_config = b.addModule("nilo_config", .{
        .root_source_file = b.path("config/config.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The third tool module: argon2id as a pure function (ADR 044). It
    // imports nothing at all, which `zig build layering` checks.
    //
    // Unlike `nilo_config`, `nilo_http` below does name this one — because
    // the Gate and the blocking call are the half a handler must not be
    // trusted to remember. What a project that never signs anybody in pays
    // for that is a linker question rather than a build one: nothing
    // references `http/password.zig` unless a handler calls it, so argon2 and
    // blake2b are never analysed. The measured cost is in ADR 044.
    const nilo_pw = b.addModule("nilo_pw", .{
        .root_source_file = b.path("pw/pw.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The fourth tool module: a cache that never leaves the process
    // (ADR 109). It imports nothing at all, which `zig build layering`
    // checks, and `nilo_http` does not name it — a program with no cache in
    // it links no ring, no table and no spin lock. A project that wants one
    // writes `@import("nilo_cache")`.
    const nilo_cache = b.addModule("nilo_cache", .{
        .root_source_file = b.path("cache/cache.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The fifth tool module: checking somebody else's signed token
    // (ADR 111). It imports nothing at all, which `zig build layering`
    // checks, and `nilo_http` does not name it — a program that signs nobody
    // in with Google links no RSA. A project that wants one writes
    // `@import("nilo_jwt")`. The fetch of the key set is not in here: that is
    // an HTTPS GET, which `nilo_fetch` already sends.
    const nilo_jwt = b.addModule("nilo_jwt", .{
        .root_source_file = b.path("jwt/jwt.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The sixth tool module: protobuf from plain structs (ADR 245). It
    // imports nothing at all, which `zig build layering` checks. A gRPC
    // method is an ordinary route (ADR 220) and the codec for its message is
    // the caller's choice to import. `nilo_http` names it in one file,
    // `http/otlp.zig`, reached only from inside `app.trace` (ADR 247), so a
    // program that neither speaks protobuf nor traces links none of it.
    const nilo_proto = b.addModule("nilo_proto", .{
        .root_source_file = b.path("proto/proto.zig"),
        .target = target,
        .optimize = optimize,
    });
    remember(b, &proto_made, .{ .owner = b, .mode = optimize, .module = nilo_proto });

    // The first Fitting: it borrows the loop and owns no destination
    // (ADR 061). A program that calls nobody else's API links no HTTP client,
    // no TLS and no certificate bundle, which is the same property ADR 037
    // bought for the database and ADR 044 for password hashing. A project
    // that wants one writes `@import("nilo_fetch")`. `nilo_http` names it in
    // one file, `http/otlp.zig`, reached only from inside `app.trace` (ADR
    // 247), and lazy analysis keeps it out of every program that does not
    // trace; `bench/result/size.md` has the measurement.
    const nilo_fetch = b.addModule("nilo_fetch", .{
        .root_source_file = b.path("fetch/fetch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nilo_core", .module = nilo_core }},
    });
    remember(b, &fetch_made, .{ .owner = b, .mode = optimize, .core = nilo_core, .module = nilo_fetch });

    // The second Fitting: a queue, and a schedule (ADR 160, ADR 161).
    // Registered rather than bound, like `nilo_fetch`: `nilo_http` never
    // names it, so a program with no queue in it links no worker loop, no
    // cron parser and no table. The store is a type parameter, which is how
    // `job.Table(sql.Db)` works without this module importing `nilo_sql`.
    const nilo_job = b.addModule("nilo_job", .{
        .root_source_file = b.path("job/job.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nilo_core", .module = nilo_core }},
    });

    // The object store: a Service that dials, and the first module to import a
    // Fitting (ADR 063). Registered rather than bound, like `nilo_fetch` —
    // nothing inside this repository imports it, and that is the point of the
    // module rather than an omission.
    //
    // **No lazy dependency, because there is no dependency.** `nilo_sql` had
    // to hide pg.zig behind `.lazy = true` so that an HTTP-only project would
    // not fetch it (ADR 037); here the HTTP client and the TLS underneath it
    // are `std`'s, so a project that never imports this fetches, builds and
    // links nothing extra at all.
    const nilo_s3 = b.addModule("nilo_s3", .{
        .root_source_file = b.path("s3/s3.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nilo_core", .module = nilo_core },
            .{ .name = "nilo_fetch", .module = nilo_fetch },
        },
    });

    // The server, under the name it is imported by. Everything else here —
    // the benchmark server, every example — depends on this exactly the way
    // somebody else's project would.
    //
    // **No module is called `nilo`, and that is the decision rather than an
    // oversight** (ADR 038). The word names the project: the `nilo: ` prefix
    // every Refusal carries, and the `nilo_table` / `nilo_resolve` /
    // `nilo_start` markers that sit in a reader's own structs. A module
    // holding the bare name would make it mean two things, which is the one
    // thing `CONTEXT.md` exists to prevent. An umbrella module re-exporting
    // the others would bring the name back and cost every project the bytes
    // of every module, which is the property ADR 037 bought.
    const nilo_http = b.addModule("nilo_http", .{
        .root_source_file = b.path("http/http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zio", .module = zio.module("zio") },
            .{ .name = "nilo_core", .module = nilo_core },
            .{ .name = "nilo_proto", .module = nilo_proto },
            .{ .name = "nilo_fetch", .module = nilo_fetch },
            .{ .name = "nilo_pw", .module = nilo_pw },
        },
    });
    wireOptions(b, nilo_http, target, optimize, want_tls, want_http2, false);

    // The SQL module: a second module beside the library rather than inside
    // it (ADR 036). It lives in `sql/` rather than under `src/` so that the
    // convention about adding an `_ = @import(…)` line to `src/nilo.zig`
    // cannot pull it into every build by being followed.
    //
    // What it imports is `nilo_core` and **not** `nilo`: a Service sits
    // beside the App rather than on top of it (ADR 038), and everything
    // this module ever wanted from a `Ctx` was `arena()` and `str()`, which
    // is what a Scope is. The tests at the bottom of `sql/db.zig` and
    // `sql/live.zig` do drive a whole request through a real App, and they
    // still say `@import("nilo_http")` — an import named only from a `test` block
    // is not analysed in a build that is not a test build, so the module
    // published here links no server. `under_test` below is where that name
    // is supplied.
    // **The module exists either way, and what changes is its root file**
    // (ADR 066). A dependent that did not ask for SQL and imports it anyway
    // gets `sql/unbuilt.zig`, which is a `@compileError` in nilo's own words
    // naming the one line that fixes it. The alternative — leaving the module
    // out of the graph — makes `dep.module("nilo_sql")` a panic from inside
    // `std.Build` about a name it could not find, which is somebody else's
    // sentence about our decision.
    const nilo_sql = b.addModule("nilo_sql", .{
        .root_source_file = b.path(if (want_sql) "sql/sql.zig" else "sql/unbuilt.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nilo_core", .module = nilo_core },
            .{ .name = "nilo_id", .module = nilo_id },
        },
    });

    // The driver, reached lazily and **behind `want_sql`**, which is what
    // makes the laziness real: see the comment on the option above, and
    // ADR 066. `lazyDependency` answers null on the pass that discovers it is
    // missing and the build re-runs itself after the download, which is why
    // this is an `if` rather than an `orelse unreachable`. Everything above
    // `sql/postgres.zig` names the Wire, not pg.zig (ADR 036).
    if (want_sql) {
        if (b.lazyDependency("pg", .{ .target = target, .optimize = optimize })) |pg| {
            nilo_sql.addImport("pg", pg.module("pg"));
        }

        // The other driver, the same way. It compiles the SQLite amalgamation,
        // so the module links libc — and **that is a cost a Postgres-only
        // program pays too**, because both Wires live in one module
        // (ADR 064). What it must not cost is the megabyte of C:
        // `sql/sqlite.zig` is only analysed when something names it, so a
        // program that does not should link none of it. That is an A/B rather
        // than an argument, and `zig build size-sql` is where the number comes
        // from.
        if (zqliteFor(b, target, optimize)) |zqlite| {
            nilo_sql.addImport("zqlite", zqlite);
            nilo_sql.link_libc = true;
        }
    }

    // The benchmark target: a routed GET with a path param returning ~1KB
    // of JSON, which is the primary metric in docs/history.md.
    const bench = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = stripMeasured(strip, optimize),
        .imports = &.{.{ .name = "nilo_http", .module = nilo_http }},
    });

    const exe = b.addExecutable(.{ .name = "nilo-hello", .root_module = bench });
    b.installArtifact(exe);
    b.step("run", "Run the benchmark server").dependOn(&b.addRunArtifact(exe).step);

    // Where the time inside one request goes. Not a test: a number that
    // moves with the weather has no business failing a build.
    const profile = b.addExecutable(.{
        .name = "nilo-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("http/profile.zig"),
            .target = target,
            .optimize = .fast,
            .strip = stripMeasured(strip, .fast),
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "nilo_core", .module = coreFor(b, target, .fast) },
                // A message route is timed, and its body is read by
                // `nilo_proto` (ADR 256).
                .{ .name = "nilo_proto", .module = protoFor(b, target, .fast) },
            },
        }),
    });
    // The App's files ask `nilo_build` which deflate to gzip with and
    // whether gRPC is in (ADR 248, ADR 220), so the profile is wired the way
    // every other instance of them is.
    wireOptions(b, profile.root_module, target, .fast, want_tls, want_http2, false);
    const run_profile = b.addRunArtifact(profile);
    // `zig build profile -- --routes <file>` times matching on a route table
    // of the caller's, one `METHOD /pattern` a line.
    run_profile.addPassthruArgs();
    b.step("profile", "Time the pieces of one request").dependOn(&run_profile.step);

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
        .name = "nilo-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("http/fuzz_main.zig"),
            .target = target,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "nilo_core", .module = coreFor(b, target, .safe) },
            },
        }),
    });
    // gRPC in whatever the flags say, because `--frames` is the gRPC
    // listener, and without it a call has nowhere to go (ADR 220).
    wireOptions(b, fuzzer.root_module, target, .safe, false, true, false);
    const run_fuzzer = b.addRunArtifact(fuzzer);
    run_fuzzer.addPassthruArgs();
    b.step("fuzz", "Throw generated requests at the parser, or with --frames connections at the gRPC listener").dependOn(&run_fuzzer.step);

    // The same generated requests, read by nilo and by llhttp, Node's
    // parser, and every disagreement reported (ADR 231). Behind a flag of
    // its own and not `.lazy` alone, for the reason on `want_sql`: llhttp
    // is C, and `lazyDependency` asked for unconditionally would fetch it
    // for every dependent. Without the flag the step is there and says what
    // it needs.
    const fuzz_llhttp = b.step("fuzz-llhttp", "Throw generated requests at nilo's parser and llhttp's, and report where they disagree (-Dllhttp)");
    if (b.option(bool, "llhttp", "Fetch llhttp, Node's HTTP parser, for `fuzz-llhttp` (ADR 231)") orelse false) {
        if (b.lazyDependency("llhttp", .{})) |dep| {
            const header = b.addTranslateC(.{
                .root_source_file = dep.path("include/llhttp.h"),
                .target = target,
                .optimize = .safe,
            });
            const llhttp = header.createModule();
            llhttp.addCSourceFiles(.{
                .root = dep.path("src"),
                .files = &.{ "llhttp.c", "api.c", "http.c" },
                .flags = &.{"-std=c99"},
            });
            llhttp.addIncludePath(dep.path("include"));
            llhttp.link_libc = true;

            const differ = b.addExecutable(.{
                .name = "nilo-fuzz-llhttp",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("http/fuzz_llhttp.zig"),
                    .target = target,
                    .optimize = .safe,
                    .imports = &.{
                        .{ .name = "zio", .module = zio.module("zio") },
                        .{ .name = "nilo_core", .module = coreFor(b, target, .safe) },
                        .{ .name = "llhttp", .module = llhttp },
                    },
                }),
            });
            const run_differ = b.addRunArtifact(differ);
            run_differ.addPassthruArgs();
            fuzz_llhttp.dependOn(&run_differ.step);
        }
    } else {
        fuzz_llhttp.dependOn(&b.addFail("fuzz-llhttp needs llhttp, which is fetched only when asked for: zig build fuzz-llhttp -Dllhttp").step);
    }

    // `test` is the loop: Debug, plus the refusals, which are cheap. `test-all`
    // is everything `test` does and the same suite again in ReleaseSafe. Both
    // exist because the second mode catches a class of bug the first cannot,
    // and CI runs `test-all` so that staying fast locally does not mean
    // shipping without it.
    const test_step = b.step("test", "Run the tests in Debug — the fast loop");
    const test_all_step = b.step("test-all", "Run the tests in Debug and ReleaseSafe — what CI runs");
    test_all_step.dependOn(test_step);

    // The profile is compiled on every run and not run: a measuring tool
    // nothing builds stopped compiling twice before anybody reached for it
    // (it lost `nilo_build` with ADR 248, and `Stream.init` with ADR 253).
    // The fuzzer is the same case: it lost `nilo_build` when `framing.zig`
    // started asking it whether gRPC is in, and nothing noticed.
    //
    // Checked, not built: a Compile step whose binary nobody asks for is
    // passed `-fno-emit-bin`, so it is the same analysis with the same
    // module, mode and options, and none of LLVM. Building them was 22s and
    // 27s of LLVM on every `zig build test`, beside a suite compilation that
    // is the run's longest (bench/result/build.md).
    test_step.dependOn(&b.addExecutable(.{ .name = "nilo-profile", .root_module = profile.root_module }).step);
    test_step.dependOn(&b.addExecutable(.{ .name = "nilo-fuzz", .root_module = fuzzer.root_module }).step);

    // Core, on its own, in both modes (ADR 038). It hangs off `test` rather
    // than beside it because it is the fastest thing in this file — no
    // Engine to build, no module graph to walk — and because the claim it
    // holds is one a change to the layering would break silently otherwise:
    // that the bottom layer compiles and passes with nothing above it.
    //
    // `zig test core/core.zig` is the same run without this file at all, and
    // that it works is the property, not a convenience.
    const test_core_step = b.step("test-core", "Run Core's tests — no Engine, no module graph");
    for (test_modes) |mode| {
        const tests = b.addTest(.{ .root_module = coreFor(b, target, mode), .use_llvm = testBackend(target, mode) });
        test_core_step.dependOn(&b.addRunArtifact(tests).step);
    }
    test_step.dependOn(test_core_step);

    // The same for `nilo_id`, and for the same reason rather than by
    // analogy: a module in the bottom layer that cannot be tested without
    // the module graph is a module in the wrong layer (ADR 038).
    // `zig test id/id.zig` is this without `build.zig` at all.
    const test_id_step = b.step("test-id", "Run nilo_id's tests — no Engine, no module graph");
    for (test_modes) |mode| {
        const tests = b.addTest(.{ .root_module = idFor(b, target, mode), .use_llvm = testBackend(target, mode) });
        test_id_step.dependOn(&b.addRunArtifact(tests).step);
    }
    test_step.dependOn(test_id_step);

    // And the same again for `nilo_config` (ADR 039). `zig test
    // config/config.zig` is this without `build.zig` at all, and a change
    // that stops that working has broken the layering rather than the test.
    const test_config_step = b.step(
        "test-config",
        "Run nilo_config's tests — no Engine, no module graph",
    );
    for (test_modes) |mode| {
        const tests = b.addTest(.{ .root_module = configFor(b, target, mode), .use_llvm = testBackend(target, mode) });
        test_config_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // This module's Refusals, held the way every other module's are (ADR
    // 026). They hang off `test-config` rather than `test-sql`'s pattern of
    // sitting outside the loop, because this module is in the bottom layer
    // and its checks are the ones a Config gets wrong at the moment somebody
    // writes it — a field that is a list, a name that is a typo.
    //
    // Measured warm on Zig 0.16 when the table held five (it holds nine now),
    // they were **284ms** of `zig build test`: 30–38ms each except `config_unknown_field` at 149ms, which is the one
    // whose `@compileError` is reached through a generic function rather than
    // from the type itself. That is well under the ~270ms each ADR 026
    // records for the framework's own, and the reason is worth knowing rather
    // than rounding away: these stop while analysing a module that imports
    // nothing, so there is no Engine in front of the failure.
    const refusals_config_step = b.step(
        "refusals-config",
        "Check that each Config mistake stops in nilo's own words",
    );
    for (config_refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("config/refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "nilo_config", .module = nilo_config }},
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: nilo: {s}", .{refusal.says}) };
        refusals_config_step.dependOn(&refused.step);
    }
    test_config_step.dependOn(refusals_config_step);
    test_step.dependOn(test_config_step);

    // And the same again for `nilo_pw` (ADR 044). `zig test pw/pw.zig` is
    // this without `build.zig` at all — the entry condition for the layer,
    // and a change that stops it working has broken the layering rather than
    // the test.
    const test_pw_step = b.step(
        "test-pw",
        "Run nilo_pw's tests — no Engine, no module graph",
    );
    for (test_modes) |mode| {
        const tests = b.addTest(.{ .root_module = pwFor(b, target, mode), .use_llvm = testBackend(target, mode) });
        test_pw_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const refusals_pw_step = b.step(
        "refusals-pw",
        "Check that each password Cost and Token mistake stops in nilo's own words",
    );
    for (pw_refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("pw/refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "nilo_pw", .module = nilo_pw }},
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: nilo: {s}", .{refusal.says}) };
        refusals_pw_step.dependOn(&refused.step);
    }
    test_pw_step.dependOn(refusals_pw_step);
    test_step.dependOn(test_pw_step);

    // And the fourth (ADR 109). `zig test cache/cache.zig` is this without
    // `build.zig` at all — the entry condition for the layer, and the reason
    // a program that is not a server can take this module on its own.
    const test_cache_step = b.step(
        "test-cache",
        "Run nilo_cache's tests — no Engine, no module graph",
    );
    for (test_modes) |mode| {
        const tests = b.addTest(.{ .root_module = cacheFor(b, target, mode), .use_llvm = testBackend(target, mode) });
        test_cache_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const refusals_cache_step = b.step(
        "refusals-cache",
        "Check that each cached-value mistake stops in nilo's own words",
    );
    for (cache_refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("cache/refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "nilo_cache", .module = nilo_cache }},
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: nilo: {s}", .{refusal.says}) };
        refusals_cache_step.dependOn(&refused.step);
    }
    test_cache_step.dependOn(refusals_cache_step);
    test_step.dependOn(test_cache_step);

    // And the fifth (ADR 111). `zig test jwt/jwt.zig` is this without
    // `build.zig` at all: the module names nothing, and a token check needs
    // no socket and no clock — the key set arrives as bytes and the time
    // arrives as a number.
    const test_jwt_step = b.step(
        "test-jwt",
        "Run nilo_jwt's tests — no Engine, no module graph",
    );
    for (test_modes) |mode| {
        const tests = b.addTest(.{ .root_module = jwtFor(b, target, mode), .use_llvm = testBackend(target, mode) });
        test_jwt_step.dependOn(&b.addRunArtifact(tests).step);
    }
    test_step.dependOn(test_jwt_step);

    // And the sixth (ADR 245). `zig test proto/proto.zig` is this without
    // `build.zig` at all: bytes in, a struct out, and the allocator an argument.
    // Both modes matter more here than anywhere: the decoder indexes slices it
    // sized itself, and a miscount is a write past the end that Debug and
    // ReleaseSafe catch and ReleaseFast does not.
    const test_proto_step = b.step(
        "test-proto",
        "Run nilo_proto's tests: no Engine, no module graph",
    );
    for (test_modes) |mode| {
        const tests = b.addTest(.{ .root_module = protoFor(b, target, mode), .use_llvm = testBackend(target, mode) });
        test_proto_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // The ninth Refusals table, held the way the other eight are.
    const refusals_proto_step = b.step(
        "refusals-proto",
        "Check that each message-type mistake stops in nilo's own words",
    );
    for (proto_refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("proto/refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "nilo_proto", .module = nilo_proto }},
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: nilo: {s}", .{refusal.says}) };
        refusals_proto_step.dependOn(&refused.step);
    }
    test_proto_step.dependOn(refusals_proto_step);
    test_step.dependOn(test_proto_step);

    // The Fitting layer's entry condition, as something that runs (ADR 061).
    // A Tool module proves its layer under a plain `zig test`; a Fitting
    // borrows the loop, so it proves its own under `std.Io.Threaded` — std's,
    // not the Engine's. `zig test fetch/fetch.zig` needs the module graph only
    // for `nilo_core`, and nothing here has ever heard of zio.
    const test_fetch_step = b.step(
        "test-fetch",
        "Run nilo_fetch's tests — a real socket, and no Engine",
    );
    for (test_modes) |mode| {
        const tests = b.addTest(.{
            .root_module = fetchFor(b, target, mode, coreFor(b, target, mode)),
            .use_llvm = testBackend(target, mode),
        });
        test_fetch_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // The eighth Refusals table, held the way the other seven are, and the
    // same warning as every one before it: a row added here while another
    // step is running is a check that silently never ran.
    const refusals_fetch_step = b.step(
        "refusals-fetch",
        "Check that each outbound-call mistake stops in nilo's own words",
    );
    for (fetch_refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("fetch/refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "nilo_fetch", .module = nilo_fetch },
                .{ .name = "nilo_core", .module = nilo_core },
            },
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: nilo: {s}", .{refusal.says}) };
        refusals_fetch_step.dependOn(&refused.step);
    }
    test_fetch_step.dependOn(refusals_fetch_step);
    test_step.dependOn(test_fetch_step);

    // The deadline, watched firing. It needs the Engine, so it is a root of
    // its own rather than a line in `fetch/fetch.zig`'s test block — putting
    // it there would make `zig test fetch/fetch.zig` need a server and cost
    // the Fitting layer its entry condition (ADR 061).
    //
    // **This is the first test here that opens a real port.** The harness the
    // standing risks have wanted for `sendfile` and the WebSocket is this
    // shape.
    const test_fetch_engine_step = b.step(
        "test-fetch-engine",
        "Watch an outbound deadline actually fire, against a real server",
    );
    for (test_modes) |mode| {
        const mode_core = coreFor(b, target, mode);
        const root = b.createModule(.{
            .root_source_file = b.path("fetch/deadline.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "nilo_core", .module = mode_core },
                .{ .name = "nilo_http", .module = httpFor(b, target, mode, mode_core) },
                // By name rather than as `fetch.zig`, and the instance the
                // server holds: `nilo_http` names `nilo_fetch` for the trace
                // exporter (ADR 247), and a file may belong to one module.
                .{ .name = "nilo_fetch", .module = fetchFor(b, target, mode, mode_core) },
            },
        });
        const tests = b.addTest(.{ .root_module = root, .use_llvm = testBackend(target, mode) });
        test_fetch_engine_step.dependOn(&b.addRunArtifact(tests).step);

        // The other root of this step: an `https://` call through a
        // `CONNECT` proxy, which needs a TLS server and so the listener
        // (ADR 267). Its own root, for the reason `deadline.zig` is one.
        // The listener has TLS in it whatever the flag says, so only here.
        if (in_repo) {
            const tunnel_root = b.createModule(.{
                .root_source_file = b.path("fetch/tunnel.zig"),
                .target = target,
                .optimize = mode,
                .imports = &.{
                    .{ .name = "nilo_core", .module = mode_core },
                    .{ .name = "nilo_http", .module = httpWith(b, target, mode, mode_core, true) },
                    .{ .name = "nilo_fetch", .module = fetchFor(b, target, mode, mode_core) },
                },
            });
            const tunnel_tests = b.addTest(.{ .root_module = tunnel_root, .use_llvm = testBackend(target, mode) });
            test_fetch_engine_step.dependOn(&b.addRunArtifact(tunnel_tests).step);
        }
    }
    test_step.dependOn(test_fetch_engine_step);

    // The second Fitting, proved the same way as the first: the worker loop
    // runs under `std.Io.Threaded`, with `job.Memory` as its store and no
    // Engine anywhere (ADR 160). The half that needs a database is
    // `test-job-sql`, below with the SQL module's own steps.
    const test_job_step = b.step(
        "test-job",
        "Run nilo_job's tests — the worker loop on std.Io.Threaded, no Engine",
    );
    for (test_modes) |mode| {
        const tests = b.addTest(.{
            .root_module = jobFor(b, target, mode, coreFor(b, target, mode)),
            .use_llvm = testBackend(target, mode),
        });
        test_job_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const refusals_job_step = b.step(
        "refusals-job",
        "Check that each job mistake stops in nilo's own words",
    );
    for (job_refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("job/refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "nilo_job", .module = nilo_job },
                .{ .name = "nilo_core", .module = nilo_core },
            },
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: nilo: {s}", .{refusal.says}) };
        refusals_job_step.dependOn(&refused.step);
    }
    test_job_step.dependOn(refusals_job_step);
    test_step.dependOn(test_job_step);

    // The object store. It sits a layer above the Fitting and is tested the
    // same way: a real socket at both ends on `std.Io.Threaded`, with no
    // Engine anywhere. What is different is that the server on the other end
    // **checks the signature** — `s3/canned.zig` rebuilds the canonical
    // request from the bytes that arrived and answers 403 when it disagrees,
    // which is the only arrangement in which a signature test means anything
    // (ADR 063).
    //
    // On `test` rather than beside `test-sql`, because there is no container
    // in the way: every test that needs a real MinIO skips when `S3_ENDPOINT`
    // is unset.
    // Where the live half of those tests connects, or null for "there is no
    // object store, skip them". Build options rather than variables read
    // inside the test, for the reason `live_config` gives below: a test binary
    // that reads the environment behaves differently depending on who ran it.
    // The variables are still honoured — read here, where reading them is a
    // build input.
    const s3_endpoint = b.option(
        []const u8,
        "s3-endpoint",
        "Object store for nilo_s3's live tests (default: $S3_ENDPOINT, else they skip)",
    ) orelse environment(b, "S3_ENDPOINT");

    const s3_config = b.addOptions();
    s3_config.addOption(?[]const u8, "endpoint", s3_endpoint);
    const s3_access_key = b.option([]const u8, "s3-access-key", "Access key id for the live tests") orelse
        environment(b, "S3_ACCESS_KEY");
    const s3_secret_key = b.option([]const u8, "s3-secret-key", "Secret access key for the live tests") orelse
        environment(b, "S3_SECRET_KEY");
    s3_config.addOption(?[]const u8, "access_key", s3_access_key);
    s3_config.addOption(?[]const u8, "secret_key", s3_secret_key);
    s3_config.addOption(
        []const u8,
        "region",
        b.option([]const u8, "s3-region", "Region for the live tests") orelse
            environment(b, "S3_REGION") orelse "us-east-1",
    );
    // Not optional, and it cannot be: a bucket is a *type*, so which one the
    // live tests use is settled while compiling. That is the design being
    // tested rather than a limitation of it.
    s3_config.addOption(
        []const u8,
        "bucket",
        b.option([]const u8, "s3-bucket", "Bucket for the live tests") orelse
            environment(b, "S3_BUCKET") orelse "nilo-test",
    );

    // The suite is its own step so that `test` can run it without the
    // live-store rule below: the macOS job sets `$CI`, runs `test`, and has no
    // object store, which is the case ADR 239 leaves alone for `test-sql` by
    // keeping it off `test`. `test-s3` and `test-all` carry the rule.
    const s3_suite_step = b.step(
        "test-s3-suite",
        "nilo_s3's tests without the rule that CI must have an object store",
    );
    const test_s3_step = b.step(
        "test-s3",
        "Run nilo_s3's tests — a fake S3 that checks signatures, and no Engine",
    );
    test_s3_step.dependOn(s3_suite_step);
    test_all_step.dependOn(test_s3_step);
    for (test_modes) |mode| {
        const tests = b.addTest(.{
            .root_module = s3For(b, target, mode, coreFor(b, target, mode), s3_config.createModule()),
            .use_llvm = testBackend(target, mode),
        });
        s3_suite_step.dependOn(&b.addRunArtifact(tests).step);
    }
    test_step.dependOn(s3_suite_step);

    // The fifth Refusals table, and CLAUDE.md's warning applies with more
    // force at five than it did at four: adding a row to one table while
    // running another is a check that silently never ran.
    const refusals_s3_step = b.step(
        "refusals-s3",
        "Check that each bucket mistake stops in nilo's own words",
    );
    for (s3_refusals) |refusal| {
        const mode_core = coreFor(b, target, .debug);
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("s3/refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "nilo_s3", .module = s3For(b, target, .debug, mode_core, null) },
                .{ .name = "nilo_core", .module = mode_core },
            },
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: nilo: {s}", .{refusal.says}) };
        refusals_s3_step.dependOn(&refused.step);
    }
    s3_suite_step.dependOn(refusals_s3_step);

    // **On CI a missing endpoint or key fails `test-s3` rather than skipping
    // its eleven live tests**, the rule ADR 239 made for `test-sql` and in the
    // same shape: `$CI` is what runners set, so it holds without a flag
    // anybody has to remember, and `-Ds3-required=false` is the way out for a
    // runner with no object store on purpose. `s3/live.zig` skips unless it
    // has all three values, so all three are asked for here.
    const s3_required = b.option(
        bool,
        "s3-required",
        "Fail test-s3 when no object store is given (default: on where $CI is set)",
    ) orelse (environment(b, "CI") != null);
    if (s3_required and (s3_endpoint == null or s3_access_key == null or s3_secret_key == null))
        test_s3_step.dependOn(&b.addFail(
            "test-s3 needs an object store here: $CI is set and one of $S3_ENDPOINT, " ++
                "$S3_ACCESS_KEY and $S3_SECRET_KEY (or -Ds3-endpoint=, -Ds3-access-key=, " ++
                "-Ds3-secret-key=) is missing, so every live test would skip. Set them, " ++
                "or pass -Ds3-required=false to skip them on purpose",
        ).step);

    // TLS and a real endpoint, which nothing else here touches.
    //
    // **Deliberately not on `test` or `test-all`.** It needs a route to the
    // internet, and a gate that goes green because a machine had none is worse
    // than no gate. Without `-Dnetwork` every test in it skips and says so;
    // with it, three run. `bench/result/fetch.md` records what it found the
    // first time, which was that every body came back gzipped.
    const network = b.option(
        bool,
        "network",
        "Let smoke-tls and fetch-check reach the internet (default: false, and their tests skip)",
    ) orelse false;
    const net_config = b.addOptions();
    net_config.addOption(bool, "enabled", network);

    const smoke_tls_step = b.step(
        "smoke-tls",
        "Call a real HTTPS endpoint — needs -Dnetwork, and is not part of `test`",
    );
    Checks.notice(
        b,
        smoke_tls_step,
        network,
        "smoke-tls: skipped, because it calls a real HTTPS endpoint. " ++
            "`zig build smoke-tls -Dnetwork` runs it.",
    );
    for (test_modes) |mode| {
        const mode_core = coreFor(b, target, mode);
        const root = b.createModule(.{
            .root_source_file = b.path("fetch/tls.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "nilo_core", .module = mode_core },
                .{ .name = "net_config", .module = net_config.createModule() },
            },
        });
        const tests = b.addTest(.{ .root_module = root, .use_llvm = testBackend(target, mode) });
        smoke_tls_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // What a dependent downloads, held by something other than a sentence in
    // four files (ADR 066). Not on `test` for the reason `smoke-tls` is not:
    // it needs a route to the internet, and a gate that goes green because a
    // machine had none is worse than no gate.
    if (in_repo) Checks.fetch(b, network);

    // A dependent that asks for nilo in two optimize modes, configured. The
    // module memo is shared by every instance in a configurer process, and a
    // fixed one overflowed on the second; `bench/two-modes/` says the rest.
    const two_modes = b.addRunFile(.zig_exe);
    two_modes.addArgs(&.{ "build", "-l", "--build-file" });
    two_modes.addFileArg(b.path("bench/two-modes/build.zig"));
    two_modes.expectExitCode(0);
    // Its input is nilo's `build.zig`, which the Run step does not hash, so
    // it runs every time; configuring both instances takes well under a second.
    two_modes.has_side_effects = true;
    const two_modes_step = b.step("two-modes", "Configure a dependent that asks for nilo in Debug and in ReleaseSafe");
    two_modes_step.dependOn(&two_modes.step);
    test_step.dependOn(two_modes_step);

    // A dependent that supplies its own TLS library, and one that says it
    // will and does not (ADR 274). The first compiles with a real tls.zig
    // the dependent fetched itself; the second must stop at the stub's
    // message. Both compile (an object, never linked), so the second holds
    // the message the way a Refusal does: a different one, or none, fails.
    const tls_triple = b.fmt("{s}-{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag), @tagName(target.result.abi) });
    const tls_own_step = b.step("tls-own", "A dependent supplies its own tls.zig and one forgets to");
    for ([_]struct { dir: []const u8, fails: bool }{
        .{ .dir = "tls-own", .fails = false },
        .{ .dir = "tls-own-missing", .fails = true },
    }) |case| {
        const run = b.addRunFile(.zig_exe);
        run.addArgs(&.{ "build", "--build-file" });
        run.addFileArg(b.path(b.fmt("bench/{s}/build.zig", .{case.dir})));
        run.addArg(b.fmt("-Dtarget={s}", .{tls_triple}));
        if (case.fails) {
            run.expectExitCode(1);
            run.expectStdErrMatch("error: nilo: `.tls_own = true` leaves the `tls` import to you");
        } else {
            run.expectExitCode(0);
        }
        // Its inputs are nilo's own sources, which the Run step does not hash.
        run.has_side_effects = true;
        tls_own_step.dependOn(&run.step);
    }
    test_step.dependOn(tls_own_step);

    // The checks that read the repository rather than build it. Only here: a
    // dependent has none of `checks/` (it is not in `.paths`), and no step of
    // nilo's to run them from.
    if (in_repo) {
        // The layering, held by something other than a paragraph (ADR 038).
        test_step.dependOn(Checks.layering(b));

        // Every ADR cited is one that exists, and none by its old number
        // (ADR 221).
        test_step.dependOn(Checks.adrs(b));

        // The project a first project is copied from builds (ADR 263).
        test_step.dependOn(Checks.template(b, target));

        // Every doc page opens the same way, reads as one paragraph a line, and
        // links only what exists; the map and the reference's heading list keep
        // up with the pages (ADR 236).
        test_step.dependOn(Checks.docs(b, false));
        _ = Checks.docs(b, true);
    }

    // The SQL module keeps its own step, and `test` does not depend on it
    // (ADR 036). Not for speed: it has a tier that cannot run without a
    // database at all, and mixing a step that needs Postgres into the one
    // run every thirty seconds is the wrong place for it. What is here is
    // the half that needs nothing — generated SQL and the schema comparison
    // are both pure functions, the same reason `App.handleRequest` is tested
    // against in-memory buffers.
    const test_sql_step = b.step("test-sql", "Run the SQL module's tests — no database needed");
    test_all_step.dependOn(test_sql_step);

    // The queue's table, against a real one (ADR 160). SQLite in memory
    // always; Postgres when `DATABASE_URL` says where, the way `sql/live.zig`
    // does. Hung off `test-sql` rather than `test`, because it builds the
    // drivers `test` deliberately does not (ADR 066).
    const test_job_sql_step = b.step(
        "test-job-sql",
        "Run nilo_job's table against SQLite, and Postgres if reachable",
    );
    test_sql_step.dependOn(test_job_sql_step);

    // The SQL module's Refusals, held the same way the framework's are (ADR
    // 026) and hung off `test-sql` rather than `test`. Every comptime check
    // in `sql/` answers a question a database would otherwise answer at run
    // time, so the wording of these is the whole point of doing it early.
    const refusals_sql_step = b.step(
        "refusals-sql",
        "Check that each SQL mistake stops in nilo's own words",
    );
    for (sql_refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("sql/refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .debug,
            // `nilo_http` as well as the module under test, because some of
            // these mistakes are only reachable through a call that takes a
            // Scope — `db.select` and friends — and a Scope is a `Ctx` or a
            // `Run`. A refusal that had to fake one would be testing the
            // fake.
            .imports = &.{
                .{ .name = "nilo_sql", .module = nilo_sql },
                .{ .name = "nilo_http", .module = nilo_http },
            },
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: nilo: {s}", .{refusal.says}) };
        refusals_sql_step.dependOn(&refused.step);
    }
    test_sql_step.dependOn(refusals_sql_step);

    // Where the live tests connect, or null for "there is no database, skip
    // them". A build option rather than an environment variable read inside
    // the test, because `zig build` is the layer that already knows how to
    // carry configuration into a compilation — and because a test binary
    // that reads the environment behaves differently depending on who ran
    // it, which is the opposite of what a test is for. `DATABASE_URL` is
    // still honoured, read here where reading it is a build input.
    const database_url = b.option(
        []const u8,
        "database-url",
        "Postgres for the SQL module's live tests (default: $DATABASE_URL, else they skip)",
    ) orelse environment(b, "DATABASE_URL");

    // **On CI a missing URL fails `test-sql` rather than skipping every live
    // test.** A skip prints nothing a run is read for, so losing the variable
    // from the workflow turned 124 tests green without running them. `CI` is
    // what GitHub Actions and every other runner set, so the rule holds
    // without a flag anybody has to remember; `-Ddatabase-required=false`
    // is the way out for a runner with no Postgres on purpose.
    const database_required = b.option(
        bool,
        "database-required",
        "Fail test-sql when no database URL is given (default: on where $CI is set)",
    ) orelse (environment(b, "CI") != null);
    if (database_required and database_url == null) test_sql_step.dependOn(&b.addFail(
        "test-sql needs a database here: $CI is set and neither $DATABASE_URL nor " ++
            "-Ddatabase-url= names one, so every live test would skip. Set one, or " ++
            "pass -Ddatabase-required=false to skip them on purpose",
    ).step);

    // **A live test waits on a leaked transaction for ten seconds, not for
    // ever.** A transaction a test forgets to end keeps its locks on the
    // server, and the next statement to want one, the next test's fixture
    // `DROP TABLE` most often, waited at no CPU until somebody killed the
    // run. Postgres ends an idle transaction's session past
    // `idle_in_transaction_session_timeout`, and fails a wait past
    // `lock_timeout`; both ride on every connection a live test dials, as
    // `options=` in the URL, unless the URL already sets its own.
    const live_url: ?[]const u8 = if (database_url) |url|
        if (std.mem.indexOf(u8, url, "options=") != null) url else b.fmt("{s}{s}{s}", .{
            url,
            if (std.mem.indexOfScalar(u8, url, '?') == null) "?" else "&",
            "options=-c%20lock_timeout%3D10s%20-c%20idle_in_transaction_session_timeout%3D10s",
        })
    else
        null;

    const live_config = b.addOptions();
    live_config.addOption(?[]const u8, "database_url", live_url);

    // What a per-connection statement cache is worth, which ADR 017's 10%
    // needed a number for before anything was built (ADR 051). Its own step
    // rather than part of `profile`, because it needs a database and that
    // one deliberately needs nothing.
    //
    // It names pg.zig, which is allowed outside the module: `sql/wire.zig`
    // says so, and what is being measured *is* the driver.
    const bench_core = coreFor(b, target, .fast);
    const bench_engine = zioFor(b, target, .fast);
    const bench_http = b.createModule(.{
        .root_source_file = b.path("http/http.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "zio", .module = bench_engine.module("zio") },
            .{ .name = "nilo_core", .module = bench_core },
            .{ .name = "nilo_proto", .module = protoFor(b, target, .fast) },
            .{ .name = "nilo_fetch", .module = fetchFor(b, target, .fast, bench_core) },
        },
    });
    wireOptions(b, bench_http, target, .fast, want_tls, want_http2, false);
    const bench_nilo_sql = b.createModule(.{
        .root_source_file = b.path("sql/sql.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "nilo_core", .module = bench_core },
            .{ .name = "nilo_id", .module = idFor(b, target, .fast) },
            .{ .name = "nilo_http", .module = bench_http },
        },
    });
    // One options module shared by both, rather than `addOptions` twice: two
    // calls make two modules with the same root file, which Zig refuses.
    const bench_live_config = live_config.createModule();
    bench_nilo_sql.addImport("live_config", bench_live_config);

    // What a cache operation costs, and what an entry costs to hold
    // (ADR 109). No Engine and no server: the module needs neither, so
    // neither is in the way of the number.
    const bench_cache = b.addExecutable(.{
        .name = "nilo-bench-cache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/cache_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nilo_cache", .module = nilo_cache }},
        }),
    });
    {
        const run = b.addRunArtifact(bench_cache);
        run.addPassthruArgs();
        b.step("bench-cache", "Time a cache operation, and weigh an entry")
            .dependOn(&run.step);
    }

    // What reading and writing a protobuf message costs, against a decoder
    // written by hand for the same fields (ADR 245). No Engine and no server.
    const bench_proto = b.addExecutable(.{
        .name = "nilo-bench-proto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/proto_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nilo_proto", .module = nilo_proto }},
        }),
    });
    {
        const run = b.addRunArtifact(bench_proto);
        run.addPassthruArgs();
        b.step("bench-proto", "Time protobuf decode and encode, against a decoder written by hand")
            .dependOn(&run.step);
    }

    // What writing a float as JSON costs, `std.json`'s way against
    // `http/jsonfloat.zig`'s (ADR 096). No Engine, no server.
    const bench_json_float = b.addExecutable(.{
        .name = "nilo-bench-json-float",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/json_float.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "jsonfloat",
                .module = b.createModule(.{ .root_source_file = b.path("http/jsonfloat.zig"), .target = target, .optimize = optimize }),
            }},
        }),
    });
    {
        const run = b.addRunArtifact(bench_json_float);
        b.step("bench-json-float", "Time writing a float as JSON, std.json's spelling against serde_json's")
            .dependOn(&run.step);
    }

    // Whether a JSON answer in arena segments beats `Allocating` (a
    // measurement; `bench/json_segments.zig` says what). The real writer
    // is the module, so what is timed is `json.write` into each.
    const bench_json_segments = b.addExecutable(.{
        .name = "nilo-bench-json-segments",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/json_segments.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "json",
                .module = b.createModule(.{
                    .root_source_file = b.path("http/json.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "nilo_core", .module = nilo_core }},
                }),
            }},
        }),
    });
    {
        const run = b.addRunArtifact(bench_json_segments);
        run.addPassthruArgs();
        b.step("bench-json-segments", "Time a JSON answer in arena segments against Allocating, instructions and allocations a request")
            .dependOn(&run.step);
    }

    // What `json.write` costs on the arena's json-h2c answer (a
    // measurement; `bench/json_listing.zig` says what).
    const bench_json_listing = b.addExecutable(.{
        .name = "nilo-bench-json-listing",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/json_listing.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "json",
                .module = b.createModule(.{
                    .root_source_file = b.path("http/json.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "nilo_core", .module = nilo_core }},
                }),
            }},
        }),
    });
    {
        const run = b.addRunArtifact(bench_json_listing);
        run.addPassthruArgs();
        b.step("bench-json-listing", "Time json.write on the json-h2c answer, ns and instructions a request")
            .dependOn(&run.step);
    }

    // **What fraction of lookups the cache answers, which is the number the
    // other one cannot see** (ADR 109). `bench-cache` draws its keys
    // uniformly at random, and under uniform random every eviction policy
    // scores the same — so a cache with no policy at all measured perfect
    // there for a year. This one draws them the way traffic does and puts the
    // score against the best a cache that size could reach.
    const bench_cache_hitrate = b.addExecutable(.{
        .name = "nilo-bench-cache-hitrate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/cache_hitrate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nilo_cache", .module = nilo_cache }},
        }),
    });
    {
        const run = b.addRunArtifact(bench_cache_hitrate);
        run.addPassthruArgs();
        b.step("bench-cache-hitrate", "What fraction of lookups the cache answers, against the best it could")
            .dependOn(&run.step);
    }

    // What gzipping an answer costs, per level, on the bodies the benchmark
    // arena asks for (ADR 211). `ReleaseFast` whatever was asked, because
    // a Debug deflate is a different program.
    const bench_compress = b.addExecutable(.{
        .name = "nilo-bench-compress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/compress_bench.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
        }),
    });
    b.step("bench-compress", "Time gzipping a JSON answer at each level, and weigh the result")
        .dependOn(&b.addRunArtifact(bench_compress).step);

    // The pool as `listen()` builds it, for what its compressors keep
    // resident once every thread has gzipped (ADR 248). Installed rather
    // than run: `bench/compress_rss.py` starts it and reads its smaps.
    const bench_compress_server = b.addExecutable(.{
        .name = "nilo-bench-compress-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/compress_server.zig"),
            .target = target,
            .optimize = .fast,
            .strip = stripMeasured(strip, .fast),
            .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
        }),
    });
    b.step("bench-compress-server", "A server gzipping every answer on sixteen threads, for what the pool keeps resident")
        .dependOn(&b.addInstallArtifact(bench_compress_server, .{}).step);

    // The stack one `Pool.gzip` writes, in the mode asked for rather than
    // `ReleaseFast`, because what each mode costs a fiber is the question
    // (ADR 062, ADR 248).
    const bench_compress_stack = b.addExecutable(.{
        .name = "nilo-bench-compress-stack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/compress_stack.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nilo_http", .module = httpFor(b, target, optimize, coreFor(b, target, optimize)) }},
        }),
    });
    b.step("bench-compress-stack", "The stack one gzip writes below its caller, per backend, in the mode asked for")
        .dependOn(&b.addRunArtifact(bench_compress_stack).step);

    const bench_sql_module = b.createModule(.{
        .root_source_file = b.path("bench/sql.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{
            .{ .name = "nilo_http", .module = bench_http },
            .{ .name = "nilo_sql", .module = bench_nilo_sql },
        },
    });
    // Behind `want_sql` like the published module's, and for the same reason:
    // this file runs top to bottom in a *dependent's* build too, so a
    // `lazyDependency` call that a benchmark nobody outside this repository
    // will ever run still bills them for the download (ADR 066).
    if (want_sql) {
        if (b.lazyDependency("pg", .{ .target = target, .optimize = .fast })) |pg| {
            bench_sql_module.addImport("pg", pg.module("pg"));
            bench_nilo_sql.addImport("pg", pg.module("pg"));
        }
        // The benchmark copy of the module needs both drivers for the same
        // reason the published one does: `sql/sql.zig` names them both, and
        // which one a program *uses* is the thing `size-sql` exists to weigh.
        if (zqliteFor(b, target, .fast)) |zqlite| {
            bench_nilo_sql.addImport("zqlite", zqlite);
            bench_nilo_sql.link_libc = true;
            // And the root module too, because `bench/sql.zig` names
            // `sql.Sqlite` — the executable is the thing that links the C.
            bench_sql_module.link_libc = true;
        }
    }
    bench_sql_module.addImport("live_config", bench_live_config);
    const bench_sql = b.addExecutable(.{ .name = "nilo-bench-sql", .root_module = bench_sql_module });
    b.step("bench-sql", "Time a statement parsed every call against one prepared once")
        .dependOn(&b.addRunArtifact(bench_sql).step);

    // What a claim costs on each store, which is what `poll_ms` rests on
    // (ADR 160). The same benchmark copy of the SQL module, so the drivers
    // are built once for both.
    const bench_job_module = b.createModule(.{
        .root_source_file = b.path("bench/job.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{
            .{ .name = "nilo_core", .module = bench_core },
            .{ .name = "nilo_sql", .module = bench_nilo_sql },
            .{ .name = "nilo_job", .module = jobFor(b, target, .fast, bench_core) },
            .{ .name = "live_config", .module = bench_live_config },
        },
    });
    if (want_sql) bench_job_module.link_libc = true;
    const bench_job = b.addExecutable(.{ .name = "nilo-bench-job", .root_module = bench_job_module });
    b.step("bench-job", "Time a claim on each store: memory, SQLite, and Postgres if reachable")
        .dependOn(&b.addRunArtifact(bench_job).step);

    // The same question under load, which is the one that decides whether a
    // Postgres wait costs a fiber or a thread (ADR 053). Installed rather
    // than run: it wants a load generator pointed at it, not a stopwatch.
    const bench_sql_server_module = b.createModule(.{
        .root_source_file = b.path("bench/sql_server.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{
            .{ .name = "nilo_http", .module = bench_http },
            .{ .name = "nilo_sql", .module = bench_nilo_sql },
        },
    });
    const bench_sql_server = b.addExecutable(.{
        .name = "nilo-bench-sql-server",
        .root_module = bench_sql_server_module,
    });
    b.step("bench-sql-server", "A server whose every request reads Postgres, for a load generator")
        .dependOn(&b.addInstallArtifact(bench_sql_server, .{}).step);

    // The fourth axis, for the module that added a megabyte of C to it
    // (ADR 064). Two programs that differ by one line — which database the
    // one route reads — so the difference between their stripped sizes is
    // what SQLite costs, and `pg_only`'s size against an HTTP-only binary is
    // the claim that a program which never names SQLite links none of it.
    //
    // Installed rather than run: nothing here is meant to serve anything.
    // `ls -l zig-out/bin/nilo-size-*` is the measurement.
    const size_sql_step = b.step(
        "size-sql",
        "Build the two programs whose stripped sizes price the SQLite Wire",
    );
    for ([_][]const u8{ "pg_only", "sqlite_only" }) |which| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("bench/size/{s}.zig", .{which})),
            .target = target,
            .optimize = .fast,
            // Always stripped, whatever `-Dstrip` says: an A/B carrying debug
            // info measures the debug info.
            .strip = true,
            .imports = &.{
                .{ .name = "nilo_http", .module = bench_http },
                .{ .name = "nilo_sql", .module = bench_nilo_sql },
            },
        });
        const exe_size = b.addExecutable(.{
            .name = b.fmt("nilo-size-{s}", .{which}),
            .root_module = module,
        });
        size_sql_step.dependOn(&b.addInstallArtifact(exe_size, .{}).step);
    }

    // The same axis for the object store, which had none until this step
    // existed: ADR 017's running total now carries a `nilo_s3` row because
    // these two programs can be built and subtracted.
    //
    // Two programs that differ by where one route's bytes come from, so the
    // difference between their stripped sizes is what adding object storage
    // costs. **The delta is deliberately the whole of it** — SigV4 and the
    // bucket, plus `nilo_fetch`, plus `std.http.Client`, plus TLS and the
    // certificate bundle — because that is the question an operator asks, and
    // `bench/result/fetch.md` is what splits the layers inside it.
    //
    // `ls -l zig-out/bin/nilo-size-s3-*` is the measurement.
    const size_s3_step = b.step(
        "size-s3",
        "Build the two programs whose stripped sizes price nilo_s3",
    );
    for ([_][]const u8{ "s3_none", "s3_get" }) |which| {
        const wants_s3 = std.mem.eql(u8, which, "s3_get");
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("bench/size/{s}.zig", .{which})),
            .target = target,
            .optimize = .fast,
            // Always stripped, whatever `-Dstrip` says, for the reason
            // `size-sql` gives: an A/B carrying debug info measures the
            // debug info.
            .strip = true,
            .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
        });
        // Named only by the half that stores something. A control that
        // imports the module and never calls it would be measuring the
        // linker rather than the claim.
        if (wants_s3) module.addImport(
            "nilo_s3",
            s3For(b, target, .fast, bench_core, null),
        );
        const exe_size = b.addExecutable(.{
            .name = b.fmt("nilo-size-{s}", .{which}),
            .root_module = module,
        });
        size_s3_step.dependOn(&b.addInstallArtifact(exe_size, .{}).step);
    }

    // The same axis for tracing (ADR 247): `s3_none` with `app.trace` added,
    // so the difference against `nilo-size-s3_none` is what a program that
    // traces pays, and `s3_none` itself, built before and after, is what one
    // that does not pays. `ls -l zig-out/bin/nilo-size-*` is the measurement.
    const size_trace_step = b.step(
        "size-trace",
        "Build the program whose stripped size, against size-s3's control, prices app.trace",
    );
    {
        const module = b.createModule(.{
            .root_source_file = b.path("bench/size/trace_on.zig"),
            .target = target,
            .optimize = .fast,
            .strip = true,
            .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
        });
        const exe_size = b.addExecutable(.{ .name = "nilo-size-trace_on", .root_module = module });
        size_trace_step.dependOn(&b.addInstallArtifact(exe_size, .{}).step);
    }

    // What a Fitting costs, against a `std.http.Client` doing the same call
    // with none of the policy round it (ADR 061). Installed rather than run,
    // for the reason above — and the number it exists for is memory per idle
    // connection, which `bench/mem.py` reads while it sits there.
    //
    // It carries its own upstream on a thread, so it needs nothing installed.
    const bench_fetch_server_module = b.createModule(.{
        .root_source_file = b.path("bench/fetch_server.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{
            .{ .name = "nilo_http", .module = bench_http },
            .{ .name = "nilo_core", .module = bench_core },
            .{ .name = "nilo_fetch", .module = fetchFor(b, target, .fast, bench_core) },
        },
    });
    const bench_fetch_server = b.addExecutable(.{
        .name = "nilo-bench-fetch-server",
        .root_module = bench_fetch_server_module,
    });
    b.step("bench-fetch-server", "A server that calls out per request, with three controls beside it")
        .dependOn(&b.addInstallArtifact(bench_fetch_server, .{}).step);

    // What an object store costs a server, with the four controls that say how
    // much of the number is the object store (ADR 063). Installed rather than
    // run, for the reason the two above give — and it is the nilo side of
    // `bench/compare-s3/drive.py`, which holds Go, Rust and Bun to the same
    // seven routes.
    //
    // No `s3_config`: the endpoint and the keys are read from the environment
    // at startup, which is right for a benchmark and wrong for a test. The
    // bucket is compiled in, because it is a type (ADR 059).
    const bench_s3_server_module = b.createModule(.{
        .root_source_file = b.path("bench/s3_server.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{
            .{ .name = "nilo_http", .module = bench_http },
            .{ .name = "nilo_s3", .module = s3For(b, target, .fast, bench_core, null) },
        },
    });
    const bench_s3_server = b.addExecutable(.{
        .name = "nilo-bench-s3-server",
        .root_module = bench_s3_server_module,
    });
    b.step("bench-s3-server", "A server reading an object store per request, with its controls")
        .dependOn(&b.addInstallArtifact(bench_s3_server, .{}).step);

    // What a WebSocket costs while nobody is typing. Installed rather than
    // run for the same reason: `bench/ws_idle.py` starts it, holds thousands
    // of sockets open against it and reads `VmRSS`.
    const bench_ws_server_module = b.createModule(.{
        .root_source_file = b.path("bench/ws_server.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
    });
    const bench_ws_server = b.addExecutable(.{
        .name = "nilo-bench-ws-server",
        .root_module = bench_ws_server_module,
    });
    b.step("bench-ws-server", "A server of idle WebSockets, for measuring what one costs")
        .dependOn(&b.addInstallArtifact(bench_ws_server, .{}).step);

    // What an open stream costs, which is the one row of ADR 017's third axis
    // nobody has taken since v1. Installed rather than run: `bench/mem.py
    // --hold` starts it, holds thousands of streams open against it and reads
    // `VmRSS`, the same arrangement `bench-ws-server` has.
    const bench_stream_server_module = b.createModule(.{
        .root_source_file = b.path("bench/stream_server.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
    });
    const bench_stream_server = b.addExecutable(.{
        .name = "nilo-bench-stream-server",
        .root_module = bench_stream_server_module,
    });
    b.step("bench-stream-server", "A server of held-open streams, for what one costs")
        .dependOn(&b.addInstallArtifact(bench_stream_server, .{}).step);

    // What a body costs while it is arriving, on both halves of the axis: what
    // the growth costs a body that turns up normally, and what one that never
    // finishes holds. Installed rather than run, the same as the two above:
    // `bench/slowloris.py` drives the second half and `wrk` the first.
    const bench_body_server_module = b.createModule(.{
        .root_source_file = b.path("bench/body_server.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
    });
    const bench_body_server = b.addExecutable(.{
        .name = "nilo-bench-body-server",
        .root_module = bench_body_server_module,
    });
    b.step("bench-body-server", "A server reading request bodies, for what one holds while it arrives")
        .dependOn(&b.addInstallArtifact(bench_body_server, .{}).step);

    // Which executor a keep-alive connection lives on, and for how long:
    // `bench/keepalive.py` is the client (ADR 199).
    const bench_keepalive_server_module = b.createModule(.{
        .root_source_file = b.path("bench/keepalive_server.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
    });
    const bench_keepalive_server = b.addExecutable(.{
        .name = "nilo-bench-keepalive-server",
        .root_module = bench_keepalive_server_module,
    });
    b.step("bench-keepalive-server", "A server naming the thread that answered, for which executor a connection lives on")
        .dependOn(&b.addInstallArtifact(bench_keepalive_server, .{}).step);

    // Whether a plain idle connection holds one page of fiber stack, or two,
    // which is the line between 4,669 bytes and 8,765 on every connection a
    // server holds. Held by a step on `test` so a change to the connection
    // loop cannot cross it unseen (ADR 062, ADR 212). Built `ReleaseFast` with
    // the flags of this build, because Debug frames are not the frames being
    // guarded and `-Dtls` and `-Dhttp2` move the depth. Every build is pinned
    // at one page.
    //
    // **Linux on x86-64 only, host and target both.** The program reads
    // `/proc/self/smaps` and the boundary is an x86-64 frame size. Anywhere
    // else the step is still there, named "skipped", runs nothing and
    // succeeds, so `zig build test` is green on macOS, Windows and a
    // cross-compile without the check having said anything about them.
    const park_check_step = b.step("park-check", "Fail if a plain idle connection holds a second page of stack it should not (Linux x86-64 only)");
    const park_here = b.graph.host.result.os.tag == .linux and b.graph.host.result.cpu.arch == .x86_64 and
        target.result.os.tag == .linux and target.result.cpu.arch == .x86_64;
    if (park_here) {
        const park_check = b.addExecutable(.{
            .name = "nilo-park-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/park_check.zig"),
                .target = target,
                .optimize = .fast,
                .strip = stripMeasured(strip, .fast),
                .imports = &.{
                    .{ .name = "nilo_http", .module = bench_http },
                },
            }),
        });
        park_check_step.dependOn(&b.addRunArtifact(park_check).step);
    } else {
        Checks.notice(b, park_check_step, false, "park-check: skipped, because it needs a Linux x86-64 host and target.");
    }
    test_step.dependOn(park_check_step);

    // The benchmark target over TLS, so the plain one has a control on the
    // axes ADR 212 spends: `bench/mem.py --tls` for the idle connection, and
    // `wrk` over `https://` for the request. Only under `-Dtls`, because a
    // step that fetches a lazy dependency is a step that has to be asked for
    // (ADR 066); without the flag the step is absent rather than failing.
    if (want_tls) {
        const bench_tls_server_module = b.createModule(.{
            .root_source_file = b.path("bench/tls_server.zig"),
            .target = target,
            .optimize = .fast,
            .strip = stripMeasured(strip, .fast),
            .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
        });
        const bench_tls_server = b.addExecutable(.{
            .name = "nilo-bench-tls-server",
            .root_module = bench_tls_server_module,
        });
        b.step("bench-tls-server", "The benchmark server over TLS, for what the encryption costs a request and an idle connection")
            .dependOn(&b.addInstallArtifact(bench_tls_server, .{}).step);

        // A page with a dozen subresources over TLS, for what a browser
        // gets from `h2` against `http/1.1`; `bench/page_load.mjs` drives it
        // (stage 7 of framing, ADR 259).
        const bench_page_server_module = b.createModule(.{
            .root_source_file = b.path("bench/page_server.zig"),
            .target = target,
            .optimize = .fast,
            .strip = stripMeasured(strip, .fast),
            .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
        });
        const bench_page_server = b.addExecutable(.{
            .name = "nilo-bench-page-server",
            .root_module = bench_page_server_module,
        });
        b.step("bench-page-server", "A page with a dozen subresources over TLS, for what a browser gets from h2 against http/1.1")
            .dependOn(&b.addInstallArtifact(bench_page_server, .{}).step);

        // Both directions loaded at once, which is the one thing the server
        // above does not do: a 10 KB body in and the same 10 KB out, with
        // TLS a switch rather than a second binary so the plain run is the
        // same machine code. The row ADR 212 left open.
        const bench_echo_server_module = b.createModule(.{
            .root_source_file = b.path("bench/echo_server.zig"),
            .target = target,
            .optimize = .fast,
            .strip = stripMeasured(strip, .fast),
            .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
        });
        const bench_echo_server = b.addExecutable(.{
            .name = "nilo-bench-echo-server",
            .root_module = bench_echo_server_module,
        });
        b.step("bench-echo-server", "A 10 KB body echoed over TLS and in plain, for what the record layer costs both directions at once")
            .dependOn(&b.addInstallArtifact(bench_echo_server, .{}).step);
    }

    // The server `wstest` is driven at, which is a conformance run rather than
    // a measurement and is here because `bench/` is where a harness needing
    // something external already lives. Installed rather than run, because the
    // thing that runs it is a container: `bash bench/autobahn/run.sh`, the same
    // arrangement `bench/compare-s3/drive.py` has with MinIO.
    const autobahn_server_module = b.createModule(.{
        .root_source_file = b.path("bench/autobahn/server.zig"),
        .target = target,
        .optimize = .fast,
        .strip = stripMeasured(strip, .fast),
        .imports = &.{.{ .name = "nilo_http", .module = bench_http }},
    });
    const autobahn_server = b.addExecutable(.{
        .name = "nilo-autobahn-server",
        .root_module = autobahn_server_module,
    });
    b.step("autobahn-server", "The echo server the Autobahn suite is run against")
        .dependOn(&b.addInstallArtifact(autobahn_server, .{}).step);

    // Each mode needs its own copy of everything the module imports, down to
    // zio: a module carries the optimize mode it was created with, and this
    // module's tests drive a whole request through `nilo.testing.Client`.
    for (test_modes) |mode| {
        const engine = zioFor(b, target, mode);

        // **One Core per mode, shared by both modules below**, and it has to
        // be shared rather than merely identical. Two modules built from the
        // same root file are two different modules to Zig, so a second copy
        // would make `nilo_core.Str` and `nilo.Str` two distinct types — and
        // `db.zig` decides what to copy out of the read buffer by asking
        // `F == core.Str`, which would then quietly answer false for every
        // Row a test declares. Nothing would fail to compile; the text would
        // just stop being kept.
        const core_mod = coreFor(b, target, mode);

        const framework = b.createModule(.{
            .root_source_file = b.path("http/http.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "zio", .module = engine.module("zio") },
                .{ .name = "nilo_core", .module = core_mod },
                .{ .name = "nilo_proto", .module = protoFor(b, target, mode) },
                .{ .name = "nilo_fetch", .module = fetchFor(b, target, mode, core_mod) },
            },
        });
        wireOptions(b, framework, target, mode, want_tls, want_http2, false);

        // The test build is the one place this module names an App, and it
        // gets both: `nilo_core` for the module itself, `nilo` for the tests
        // at the bottom of `db.zig` and `live.zig` (ADR 038).
        const under_test = b.createModule(.{
            .root_source_file = b.path("sql/sql.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "nilo_core", .module = core_mod },
                .{ .name = "nilo_id", .module = idFor(b, target, mode) },
                .{ .name = "nilo_http", .module = framework },
            },
        });
        // The third and last pair, behind `want_sql` for the reason the other
        // two are (ADR 066). This one was the expensive one: a dependent runs
        // this loop while configuring their own build, so *nilo's own test
        // suite* was what charged them the second copy of both drivers.
        if (want_sql) {
            if (b.lazyDependency("pg", .{ .target = target, .optimize = mode })) |pg| {
                under_test.addImport("pg", pg.module("pg"));
            }
            if (zqliteFor(b, target, mode)) |zqlite| {
                under_test.addImport("zqlite", zqlite);
                under_test.link_libc = true;
            }
        }
        under_test.addOptions("live_config", live_config);
        const sql_tests = b.addTest(.{ .root_module = under_test, .use_llvm = testBackend(target, mode) });
        test_sql_step.dependOn(&b.addRunArtifact(sql_tests).step);

        // The pool's own deadline, watched firing. A root of its own for the
        // reason `fetch/deadline.zig` is one: only the Engine can cancel a
        // fiber, so this is the one test here that needs a running server —
        // and putting it in `sql/sql.zig`'s test block would make
        // `zig build test-sql` need one too (ADR 107).
        //
        // Hung off `test-sql` rather than `test`, because `test` deliberately
        // does not build this module or fetch its drivers (ADR 066).
        const deadline_root = b.createModule(.{
            .root_source_file = b.path("sql/deadline.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "nilo_core", .module = core_mod },
                .{ .name = "nilo_http", .module = framework },
                .{ .name = "nilo_sql", .module = under_test },
                .{ .name = "live_config", .module = under_test.import_table.get("live_config").? },
            },
        });
        const deadline_tests = b.addTest(.{ .root_module = deadline_root, .use_llvm = testBackend(target, mode) });
        test_sql_step.dependOn(&b.addRunArtifact(deadline_tests).step);

        // A transaction whose socket dies under it, through a proxy the test
        // stands up between the pool and Postgres (ADR 043). No Engine: it
        // runs on `std.Io.Threaded` the way `live.zig` does. A root of its
        // own so that a proxy that wedges is a binary that wedges, with a
        // name of its own in `ps`, rather than one test among a hundred —
        // and hung off `test-sql` for the reason `deadline.zig` is. Skips
        // when `DATABASE_URL` reaches nothing.
        const severed_root = b.createModule(.{
            .root_source_file = b.path("sql/severed.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "nilo_core", .module = core_mod },
                .{ .name = "nilo_sql", .module = under_test },
            },
        });
        // The same `live_config` the Db under test was given, for the reason
        // `job/live.zig` shares it below: one options module, one URL.
        severed_root.addImport("live_config", under_test.import_table.get("live_config").?);
        const severed_tests = b.addTest(.{ .root_module = severed_root, .use_llvm = testBackend(target, mode) });
        test_sql_step.dependOn(&b.addRunArtifact(severed_tests).step);

        // `job/live.zig`: the one root that names `nilo_sql` and `nilo_job`
        // together. The same Core as the Db under test, so a `Str` in a
        // payload is the `Str` a Row reads.
        const job_live_root = b.createModule(.{
            .root_source_file = b.path("job/live.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "nilo_core", .module = core_mod },
                .{ .name = "nilo_sql", .module = under_test },
                .{ .name = "nilo_job", .module = jobFor(b, target, mode, core_mod) },
                .{ .name = "nilo_cache", .module = cacheFor(b, target, mode) },
            },
        });
        // The same `live_config` module the Db under test was given, rather
        // than a second one made from the same options: two modules rooted in
        // one file is a compile error, and it is the same URL either way.
        job_live_root.addImport("live_config", under_test.import_table.get("live_config").?);
        const job_live_tests = b.addTest(.{ .root_module = job_live_root, .use_llvm = testBackend(target, mode) });
        test_job_sql_step.dependOn(&b.addRunArtifact(job_live_tests).step);

        // The examples that name `nilo_sql`, tested against the same Db under
        // test: the one place an example's `db.checking` and `createMissing`
        // are booted together, which is the shape a first boot got wrong
        // (ADR 180).
        for (examples) |example| {
            if (!example.needs_sql) continue;
            const example_root = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{example.name})),
                .target = target,
                .optimize = mode,
                .imports = &.{
                    .{ .name = "nilo_http", .module = framework },
                    .{ .name = "nilo_sql", .module = under_test },
                },
            });
            const example_tests = b.addTest(.{ .root_module = example_root, .use_llvm = testBackend(target, mode) });
            test_sql_step.dependOn(&b.addRunArtifact(example_tests).step);
        }
    }

    for (test_modes) |mode| {
        const step = if (mode == loop_mode) test_step else test_all_step;
        // Each mode needs its own copy of everything, down to zio: a module
        // carries the optimize mode it was created with.
        const engine = zioFor(b, target, mode);

        // The library's tests run under a root of their own so there is one
        // place to say what a test build's root actually is: the compiler's
        // test runner, not this file. That matters because a test that logs
        // reaches stderr, and the build runner answers stderr from a test
        // process with a red `failed command` block above a summary saying
        // every step passed — see `src/test_root.zig`.
        // One Core per mode here too, for the reason spelled out above the
        // SQL module's copy: a second one would be a second set of types.
        const core_mod = coreFor(b, target, mode);
        // And one `nilo_pw` per mode, shared by both roots below for the
        // reason Core is: `Ctx.hashPassword` answers a `pw.Hash`, and a second
        // copy would make that a different type from the one an example names.
        const pw_mod = pwFor(b, target, mode);

        const lib_tests = b.createModule(.{
            .root_source_file = b.path("http/test_root.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "zio", .module = engine.module("zio") },
                .{ .name = "nilo_core", .module = core_mod },
                .{ .name = "nilo_proto", .module = protoFor(b, target, mode) },
                .{ .name = "nilo_fetch", .module = fetchFor(b, target, mode, core_mod) },
                .{ .name = "nilo_pw", .module = pw_mod },
            },
        });
        // TLS is in the http test root whether or not `-Dtls` was passed,
        // because a feature only tested when somebody remembers a flag is a
        // feature that is not tested (ADR 032). In-repo only: a dependent
        // running its own tests against nilo is not made to fetch the
        // library for a listener it never asked for.
        wireOptions(b, lib_tests, target, mode, want_tls or in_repo, want_http2 or in_repo, in_repo);

        const library = b.createModule(.{
            .root_source_file = b.path("http/http.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{
                .{ .name = "zio", .module = engine.module("zio") },
                .{ .name = "nilo_core", .module = core_mod },
                .{ .name = "nilo_proto", .module = protoFor(b, target, mode) },
                .{ .name = "nilo_fetch", .module = fetchFor(b, target, mode, core_mod) },
                .{ .name = "nilo_pw", .module = pw_mod },
            },
        });
        wireOptions(b, library, target, mode, want_tls, want_http2, false);

        const bench_tests = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "nilo_http", .module = library }},
        });

        for ([_]*std.Build.Module{ lib_tests, bench_tests }) |module| {
            const tests = b.addTest(.{ .root_module = module, .use_llvm = testBackend(target, mode) });
            const ran = b.addRunArtifact(tests);
            step.dependOn(&ran.step);
            // The suite alone, for `-fincremental --watch`: a save recompiles
            // it in under a second where a fresh compile is 33 s of Sema, and
            // `test` is too many compile steps to keep a resident compiler
            // each (ADR 138).
            if (mode == loop_mode and module == lib_tests) {
                b.step("test-http", "Run the framework's own suite in Debug, and nothing else").dependOn(&ran.step);
            }
        }

        // The examples carry the tests the README promises are possible, so
        // they run with everything else rather than being decoration. The
        // one that names `nilo_sql` runs under `test-sql`, above.
        for (examples) |example| {
            if (example.needs_sql) continue;
            // `embedDir` reads its directory while configuring, and
            // `examples/` is not in `.paths`: a dependent has no such
            // directory, and configuring its graph must not open one.
            if (example.embeds.len > 0 and !in_repo) continue;
            const module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{example.name})),
                .target = target,
                .optimize = mode,
                .imports = &.{.{ .name = "nilo_http", .module = library }},
            });
            if (example.needs_fetch) {
                module.addImport("nilo_fetch", fetchFor(b, target, mode, core_mod));
            }
            if (example.embeds.len > 0) module.addImport("frontend", embedDir(b, library, example.embeds));
            const tests = b.addTest(.{ .root_module = module, .use_llvm = testBackend(target, mode) });
            step.dependOn(&b.addRunArtifact(tests).step);
        }
    }

    // ADR 014 says a mistake stops in nilo's own words. Nothing held that
    // rule until this step: each file in `refusals/` is a program somebody
    // wrote wrong, and each has to fail to compile with the message named
    // above. Note what the loop does with `.says` — it supplies the `nilo: `
    // prefix itself, so a check that stops somewhere inside the standard
    // library cannot be written down as passing, only fixed or deleted
    // ([ADR 026](docs/adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md)).
    //
    // **They do not cache, and they are the slow part of `zig build test`.**
    // The compiler keeps nothing from a compilation that failed, so every
    // refusal is re-analysed every run: measured warm on Zig 0.16.0, all 46
    // are ~12.8s of a ~17s `zig build test`, at roughly 270ms each.
    //
    // A note here once said the opposite — that Zig 0.16 had started caching
    // them and all 39 were 0.5s. That was measured wrong and is corrected in
    // [ADR 026](docs/adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md);
    // the original entry's number, about 9 seconds, was right all along.
    //
    // They stay on `test` at that price, which is the trade the ADR argues:
    // enforcement that has to be asked for is a sentence in a document again.
    // If the loop somebody sits in gets too slow to sit in, the move is to
    // take them off `test` and leave them on `test-all` — not to stop
    // checking.
    // Named for the framework rather than for all of them, because it only
    // runs the framework's 109. The other five tables hang off their own
    // module's test step (ADR 026) and have their own `refusals-*` steps —
    // and a name that over-promised sent one reader to run this, watch it
    // pass, and believe a `sql/refusals/` file had been checked.
    const refusals_step = b.step(
        "refusals",
        "Check the framework's 118 compile errors — see refusals-sql, -s3, -config, -pw, -cache, -proto for the rest",
    );
    for (refusals) |refusal| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("refusals/{s}.zig", .{refusal.name})),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "nilo_http", .module = nilo_http }},
        });
        const refused = b.addObject(.{ .name = refusal.name, .root_module = module });
        refused.expect_errors = .{ .contains = b.fmt("error: nilo: {s}", .{refusal.says}) };
        refusals_step.dependOn(&refused.step);
    }
    // One refusal holds only in a build without `-Dhttp2`, because with the
    // flag the same program is correct: asking the App for gRPC where there
    // is no framing to collect a call into (ADR 220).
    if (!want_http2) {
        const module = b.createModule(.{
            .root_source_file = b.path("refusals/grpc_without_the_build_flag.zig"),
            .target = target,
            .optimize = .debug,
            .imports = &.{.{ .name = "nilo_http", .module = nilo_http }},
        });
        const refused = b.addObject(.{ .name = "grpc_without_the_build_flag", .root_module = module });
        refused.expect_errors = .{ .contains = "error: nilo: the App answers gRPC only in a build with `.http2 = true` (`-Dhttp2`)." };
        refusals_step.dependOn(&refused.step);
    }
    test_step.dependOn(refusals_step);

    // And the mirror of it: the documentation's own snippets, which have to
    // compile (ADR 068). Only built when `nilo_sql` is — the running example
    // has a database in it, and `-Dsql=false` is a project that has not asked
    // for one.
    //
    // And only in this repository. `Snippets.collect` reads `docs/` at
    // configure time, with `readFileAlloc` rather than `b.path`, so unlike
    // the refusals above it runs whether or not anybody asks for the step —
    // and `docs/` is not in the manifest's `.paths`, so a dependent has none.
    // Behind `want_sql` alone, the first project to pass `.sql = true` against
    // a *fetched* nilo panicked in `zig build` before compiling a line, and
    // it went unfound until 0.4.0 was cut because the one dependent building
    // against nilo was a path dependency with the working tree's `docs/` next
    // door.
    // `b.pkg_hash` is the same test `want_sql`'s default makes: empty for the
    // package being built, the hash when somebody else is building it.
    const snippets_step = b.step(
        "snippets",
        "Compile the snippets the documentation publishes",
    );
    if (want_sql and b.pkg_hash.len == 0) {
        // Written into the cache rather than into the tree: the snippet's
        // one copy is the one in the page.
        // A marked page the list does not name is the step lying by
        // omission, and it stops here rather than passing silently.
        const unlisted = Snippets.unlisted(b);
        if (unlisted.len != 0) {
            for (unlisted) |path| std.debug.print(
                "nilo: {s} carries a `<!-- compiles -->` mark and is not in `pages` in build.zig, " ++
                    "so nothing compiles it\n",
                .{path},
            );
            @panic("a documentation page is marked and never checked — add it to `pages`");
        }

        const written = b.addWriteFiles();
        for (Snippets.collect(b)) |snippet| {
            const module = b.createModule(.{
                .root_source_file = written.add(
                    b.fmt("{s}.zig", .{snippet.name}),
                    snippet.source,
                ),
                .target = target,
                .optimize = .debug,
                .imports = &.{
                    .{ .name = "nilo_http", .module = nilo_http },
                    .{ .name = "nilo_sql", .module = nilo_sql },
                    .{ .name = "nilo_id", .module = nilo_id },
                    .{ .name = "nilo_pw", .module = nilo_pw },
                    .{ .name = "nilo_config", .module = nilo_config },
                    .{ .name = "nilo_fetch", .module = nilo_fetch },
                    .{ .name = "nilo_s3", .module = nilo_s3 },
                    .{ .name = "nilo_cache", .module = nilo_cache },
                    .{ .name = "nilo_jwt", .module = nilo_jwt },
                    .{ .name = "nilo_proto", .module = nilo_proto },
                    .{ .name = "nilo_job", .module = nilo_job },
                },
            });
            const compiled = b.addObject(.{ .name = snippet.name, .root_module = module });
            snippets_step.dependOn(&compiled.step);
        }
    }
    test_step.dependOn(snippets_step);

    // The server restarted on every save (ADR 190). Installed so a
    // dependent can `nilo.artifact("nilo-dev")`; it imports `std` and
    // nothing of nilo's, and no server links it. Its tests are the argument
    // parser's and run standalone — `zig test dev/main.zig` — for the reason
    // a tool module's do: there is no module graph to need.
    const dev_module = b.createModule(.{
        .root_source_file = b.path("dev/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dev_tool = b.addExecutable(.{ .name = "nilo-dev", .root_module = dev_module });
    b.installArtifact(dev_tool);
    const test_dev_step = b.step("test-dev", "Run nilo-dev's tests — the restart-on-save runner, no module graph");
    for (test_modes) |mode| {
        const dev_under_test = b.createModule(.{
            .root_source_file = b.path("dev/main.zig"),
            .target = target,
            .optimize = mode,
        });
        const dev_tests = b.addTest(.{ .root_module = dev_under_test, .use_llvm = testBackend(target, mode) });
        test_dev_step.dependOn(&b.addRunArtifact(dev_tests).step);
    }
    test_step.dependOn(test_dev_step);

    // Every example is built by `zig build examples`, so one that stops
    // compiling is a failed build rather than a surprise for the first
    // person who copies it.
    const examples_step = b.step("examples", "Build every example");
    // LLVM for the examples, off by default: the self-hosted backend is the
    // faster build. On Zig 0.16.0 it was what `-fincremental` needed for a
    // binary that runs when libc is linked (ADR 190); 0.17.0 does not need
    // it, and it stays for a host whose link fails without it (CLAUDE.md).
    const examples_llvm = b.option(bool, "llvm", "Build the examples with LLVM") orelse false;
    for (examples) |example| {
        // An example that names `nilo_sql` is a program that asked for the
        // module, and `-Dsql=false` is a project that has not.
        if (example.needs_sql and !want_sql) continue;
        // The same reason as the test loop's: an embedding example is read
        // at configure time, and a dependent was never shipped one.
        if (example.embeds.len > 0 and !in_repo) continue;
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            // Deliberately not `stripMeasured`: an example is run by a person,
            // and the first thing they need from a crash is where it was.
            .strip = strip,
            .imports = &.{.{ .name = "nilo_http", .module = nilo_http }},
        });
        if (example.needs_fetch) {
            module.addImport("nilo_fetch", fetchFor(b, target, optimize, nilo_core));
        }
        if (example.embeds.len > 0) module.addImport("frontend", embedDir(b, nilo_http, example.embeds));
        if (example.needs_sql) {
            module.addImport("nilo_sql", nilo_sql);
        }
        const built = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{example.name}),
            .root_module = module,
            .use_llvm = if (examples_llvm) true else null,
        });
        const installed = b.addInstallArtifact(built, .{});
        examples_step.dependOn(&installed.step);
        // One example on its own, which is what the dev loop below rebuilds:
        // nine resident compilers at 180 MB each is not a loop anybody sits in.
        b.step(b.fmt("example-{s}", .{example.name}), b.fmt("Build the {s} example", .{example.name})).dependOn(&installed.step);

        const run = b.addRunArtifact(built);
        // Run from the example's own directory: the static one reads its
        // files from a path relative to the working directory.
        run.setCwd(b.path(b.fmt("examples/{s}", .{example.name})));
        b.step(b.fmt("run-{s}", .{example.name}), example.about).dependOn(&run.step);

        // The same, restarted on every save: `nilo-dev` keeps one
        // `zig build example-<name> --watch` running and starts the example
        // again whenever that build writes it (ADR 190). The path is
        // absolute because the runner's working directory is the example's.
        // Incremental unless `-- --no-incremental` is passed: on the
        // self-hosted backend since Zig 0.17, and the default since (ADR 190).
        const dev = b.addRunArtifact(dev_tool);
        dev.setCwd(b.path(b.fmt("examples/{s}", .{example.name})));
        dev.addArg("--zig");
        dev.addFileArg(.zig_exe);
        dev.addArgs(&.{ "--build", b.fmt("example-{s}", .{example.name}) });
        dev.addPassthruArgs();
        // Where `install` will put the binary, which is a path the Maker
        // knows and this file does not: a prefix is chosen after configuring.
        // A directory argument rather than a file one, because a file
        // argument is an input the step hashes, and this one is written by
        // the build that `nilo-dev` itself starts.
        dev.addDirectoryArg2(
            .{ .relative = .{ .base = .install_bin, .sub_path = built.out_filename } },
            .{ .make_absolute = true },
        );
        b.step(b.fmt("dev-{s}", .{example.name}), b.fmt("{s} — restarted on every save", .{example.about})).dependOn(&dev.step);
    }
}
