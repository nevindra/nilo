//! The `migrations/` directory: reading it, and writing the next version into
//! it ([ADR 0153](../docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
//!
//! `migrate.zig` is values. This is the half that touches a disk, and it is a
//! file of its own for that reason: nothing above it opens anything, so a
//! program that only *applies* migrations at boot links none of this.
//!
//! ## What is in the directory
//!
//! ```
//! migrations/
//!   0001_create_users.zig   one version: number, name, steps
//!   0007_split_name.zig
//!   manifest.zig            the list, and `head` as a constant
//!   snapshot.zon            what the last generate believed the schema was
//! ```
//!
//! **One Zig file per version rather than one `.sql` file per statement.**
//! Every statement this module sends is prepared, and a prepared statement is
//! one statement, so a `.sql` file holding three of them would have to be split
//! before it could run — and splitting on `;` is wrong for real SQL, where a
//! semicolon can sit inside a string literal or a `$$…$$` body. The failure
//! that produces is the worst shape available, because `sqlite3_exec` takes
//! several statements happily and the Postgres extended protocol does not: a
//! leaky splitter passes on a laptop and fails in production. Here the boundary
//! is an array element and nothing is parsed. The ADR carries the rest of the
//! argument, including what it costs.
//!
//! ## Nothing here needs a database
//!
//! `read`, `check` and `generate` open files and nothing else. That is the
//! whole point of the snapshot: the two halves of a diff are the caller's types,
//! which are in the binary, and `snapshot.zon`, which is in git. So the pair CI
//! runs needs no server, no shadow database and no `DATABASE_URL`.
//!
//! It does need an `Io`, because `std.Io.Dir` takes one. `std.Io.Threaded` is
//! std's own and is what a command-line tool passes; there is no zio anywhere
//! in this file.

const std = @import("std");

const ddl = @import("ddl.zig");
const migrate = @import("migrate.zig");
const snapshot = @import("snapshot.zig");
const table_mod = @import("table.zig");

const Io = std.Io;
const Dir = std.Io.Dir;
const Plan = migrate.Plan;
const Step = migrate.Step;
const Table = migrate.Table;
const Version = migrate.Version;

/// The name every generated file assumes the SQL module is imported under.
///
/// Hard-coded rather than an option, because it is the name this repository's
/// documentation uses everywhere and a generated file that guessed differently
/// would not compile in the project that asked for it. A build that calls the
/// module something else can pass `Options.module`.
pub const default_module = "nilo_sql";

pub const snapshot_file = "snapshot.zon";
pub const manifest_file = "manifest.zig";

/// The most a snapshot may be. A schema is text; a hundred tables is tens of
/// kilobytes, and anything past this is a file somebody else wrote.
pub const max_snapshot = 8 * 1024 * 1024;

pub const Error = error{
    /// A version name with something other than `a-z`, `0-9` or `_` in it. The
    /// name becomes a path and a Zig identifier, so it is checked before it is
    /// either.
    BadName,
    /// A file called `NNNN_….zig` whose `NNNN` is not four digits.
    BadVersionFile,
    /// Two version files with the same number, which is what two branches that
    /// both generated look like after a bad merge.
    DuplicateVersion,
};

// -- what the directory holds --------------------------------------------

/// One `NNNN_name.zig`.
pub const Entry = struct {
    number: u32,
    /// Without the number and without the extension: `split_name`.
    name: []const u8,
    /// The whole file name, which is what the manifest `@import`s.
    file: []const u8,
};

/// The directory as it is right now.
pub const State = struct {
    /// What the last `generate` believed the schema was, or an empty snapshot
    /// when there is no file.
    before: snapshot.Doc,
    /// Whether `snapshot.zon` was actually there. A directory with version
    /// files and no snapshot is a broken checkout rather than a fresh start,
    /// and `generate` says so rather than writing every table again.
    had_snapshot: bool,
    /// Every version file, by number ascending.
    entries: []const Entry,

    /// The highest version on disk, or zero.
    pub fn head(self: State) u32 {
        return if (self.entries.len == 0) 0 else self.entries[self.entries.len - 1].number;
    }
};

/// Read the directory. Everything is allocated out of `gpa`, which is an arena
/// in every caller worth having.
pub fn read(gpa: std.mem.Allocator, io: Io, dir: Dir, comptime D: type) !State {
    var entries: std.ArrayList(Entry) = .empty;

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        if (std.mem.eql(u8, e.name, manifest_file)) continue;
        if (!std.mem.endsWith(u8, e.name, ".zig")) continue;
        try entries.append(gpa, try entryOf(gpa, e.name));
    }

    std.mem.sort(Entry, entries.items, {}, lessByNumber);
    for (entries.items[0..entries.items.len -| 1], 1..) |e, i| {
        if (e.number == entries.items[i].number) return Error.DuplicateVersion;
    }

    const text = dir.readFileAllocOptions(
        io,
        snapshot_file,
        gpa,
        .limited(max_snapshot),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{
            .before = snapshot.empty(D),
            .had_snapshot = false,
            .entries = entries.items,
        },
        else => return err,
    };

    return .{
        .before = try snapshot.parse(gpa, text, null),
        .had_snapshot = true,
        .entries = entries.items,
    };
}

fn lessByNumber(_: void, a: Entry, b: Entry) bool {
    return a.number < b.number;
}

/// `0007_split_name.zig` into its three parts.
fn entryOf(gpa: std.mem.Allocator, file: []const u8) !Entry {
    const stem = file[0 .. file.len - ".zig".len];
    const underscore = std.mem.indexOfScalar(u8, stem, '_') orelse return Error.BadVersionFile;
    if (underscore != 4) return Error.BadVersionFile;

    const number = std.fmt.parseInt(u32, stem[0..4], 10) catch return Error.BadVersionFile;
    const name = stem[underscore + 1 ..];
    try checkName(name);

    return .{
        .number = number,
        .name = try gpa.dupe(u8, name),
        .file = try gpa.dupe(u8, file),
    };
}

/// A version name is a path segment and a piece of a Zig identifier, so it is
/// held to what is safe in both. Refusing early beats a file name that cannot
/// be imported.
pub fn checkName(name: []const u8) !void {
    if (name.len == 0) return Error.BadName;
    for (name) |ch| switch (ch) {
        'a'...'z', '0'...'9', '_' => {},
        else => return Error.BadName,
    };
}

// -- writing the next one -------------------------------------------------

pub const Options = struct {
    /// What to call it, in `snake_case`. Becomes part of the file name.
    name: []const u8,
    /// Write steps that lose data. **Without it `generate` refuses**, and the
    /// `Outcome` says which steps were the reason, so the ask is made at the
    /// command line by somebody who has read them.
    allow_destructive: bool = false,
    /// What the generated files call the SQL module in their `@import`.
    module: []const u8 = default_module,
};

/// What `generate` did, and why it did not do more.
pub const Outcome = struct {
    /// The diff, whether or not anything was written. `steps` is what would
    /// run and `problems` is what the diff refused to write.
    plan: Plan,
    /// The file that was written, or null when nothing was.
    file: ?[]const u8 = null,
    /// Its number, or zero.
    number: u32 = 0,

    /// The schema and the types already agree.
    pub fn isEmpty(self: Outcome) bool {
        return self.plan.isEmpty();
    }

    /// There was something to write and it was not written: either the diff
    /// reported a problem, or it is destructive and nobody said so.
    pub fn wasHeld(self: Outcome) bool {
        return self.file == null and !self.plan.isEmpty();
    }
};

/// The question CI asks: is there anything in the types the migrations have not
/// got? An empty plan is a green build.
///
/// No database, no network. Just the directory and the caller's own types.
pub fn check(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    comptime D: type,
    desired: []const Table,
) !Plan {
    const state = try read(gpa, io, dir, D);
    return migrate.plan(gpa, D, desired, state.before);
}

/// Diff the types against the snapshot and write the result as the next
/// version, then rewrite the manifest and the snapshot.
///
/// **Three files change or none do.** The version file is written first, then
/// the manifest that names it, then the snapshot that says the schema has moved
/// — so a run that dies halfway leaves a directory whose snapshot is still
/// behind, which is the state the next `generate` handles correctly. The other
/// order would leave a snapshot claiming a version that is not there.
pub fn generate(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    comptime D: type,
    desired: []const Table,
    opts: Options,
) !Outcome {
    try checkName(opts.name);

    const state = try read(gpa, io, dir, D);
    const change = try migrate.plan(gpa, D, desired, state.before);

    if (change.isEmpty()) return .{ .plan = change };
    if (change.problems.len > 0) return .{ .plan = change };
    if (change.destructive() and !opts.allow_destructive) return .{ .plan = change };

    const number = state.head() + 1;
    const file = try std.fmt.allocPrint(gpa, "{d:0>4}_{s}.zig", .{ number, opts.name });

    try dir.writeFile(io, .{
        .sub_path = file,
        .data = try renderVersion(gpa, number, opts.name, change.steps, opts),
    });

    const with_new = try gpa.alloc(Entry, state.entries.len + 1);
    @memcpy(with_new[0..state.entries.len], state.entries);
    with_new[state.entries.len] = .{ .number = number, .name = opts.name, .file = file };

    try dir.writeFile(io, .{
        .sub_path = manifest_file,
        .data = try renderManifest(gpa, with_new, opts),
    });

    const doc = try migrate.snapshotOf(gpa, D, number, desired);
    try dir.writeFile(io, .{
        .sub_path = snapshot_file,
        .data = try snapshot.render(gpa, doc),
    });

    return .{ .plan = change, .file = file, .number = number };
}

// -- what a generated file looks like -------------------------------------

/// One version, as the text of its file. Caller frees.
pub fn renderVersion(
    gpa: std.mem.Allocator,
    number: u32,
    name: []const u8,
    steps: []const Step,
    opts: Options,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        \\// Written by `db generate` from the Rows in this repository, and committed.
        \\//
        \\// Read it like code, because it is exactly what will run: these steps, in
        \\// this order, inside one transaction. A step you write yourself goes in the
        \\// same list with `.kind = .data`, and `generate` never produces one of
        \\// those, so it will not be taken away again.
        \\//
        \\// Editing this after it has been applied changes the version's hash, and
        \\// `migrate.drift` reports it against every database that has run it.
        \\
        \\const migrate = @import("{s}").migrate;
        \\
        \\pub const version: migrate.Version = .{{
        \\    .number = {d},
        \\    .name = "{s}",
        \\    .steps = &.{{
        \\
    , .{ opts.module, number, name });

    for (steps) |s| {
        try w.print("        .{{\n            .kind = .{t},\n", .{s.kind});
        try w.writeAll("            .why = \"");
        try writeEscaped(w, s.why);
        try w.writeAll("\",\n");
        if (s.destructive) try w.writeAll("            .destructive = true,\n");
        if (s.needs_backfill) try w.writeAll("            .needs_backfill = true,\n");
        try w.writeAll("            .sql =\n");
        var lines = std.mem.splitScalar(u8, s.sql, '\n');
        while (lines.next()) |line| try w.print("            \\\\{s}\n", .{line});
        try w.writeAll("            ,\n        },\n");
    }

    try w.writeAll("    },\n};\n");
    return aw.toOwnedSlice();
}

/// The manifest, as the text of its file. Caller frees.
pub fn renderManifest(gpa: std.mem.Allocator, entries: []const Entry, opts: Options) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    const head: i64 = if (entries.len == 0) 0 else entries[entries.len - 1].number;

    try w.print(
        \\// Written by `db generate`, and committed.
        \\//
        \\// The version list this binary is built with. `head` is a constant, so
        \\// `migrate.expect(&db, scope, manifest.head)` before `listen()` costs one
        \\// query and refuses to serve a database the migrations have not reached.
        \\
        \\const std = @import("std");
        \\const migrate = @import("{s}").migrate;
        \\
        \\/// The highest version in the list below.
        \\pub const head: i64 = {d};
        \\
        \\pub const versions: []const migrate.Version = &.{{
        \\
    , .{ opts.module, head });

    for (entries) |e| try w.print("    @import(\"{s}\").version,\n", .{e.file});

    try w.writeAll(
        \\};
        \\
        \\/// The list with every chained hash worked out. One call at boot, and what
        \\/// `migrate.applyPending` and `migrate.drift` both take.
        \\pub fn chain(gpa: std.mem.Allocator) !migrate.Chain {
        \\    return migrate.chainOf(gpa, versions);
        \\}
        \\
    );
    return aw.toOwnedSlice();
}

/// A `why` into a Zig string literal.
///
/// Only two bytes can break out of one, and a generated `why` holds neither —
/// it is a column name and a sentence. Escaped anyway, because the day one of
/// them carries a quote is the day the generated file stops compiling and
/// nobody knows why.
fn writeEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(ch),
    };
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;
const Pg = @import("dialect.zig").Postgres;
const core = @import("nilo_core");
const types = @import("types.zig");

const Org = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };
    id: i64,
    name: []const u8,
};

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.{ .columns = .{.email}, .ignoring_case = true }},
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };

    id: i64,
    org_id: i64,
    email: core.Str,
    created_at: types.Timestamp,
};

/// A directory to write into, and the `Io` every call needs.
const Sandbox = struct {
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    arena: std.heap.ArenaAllocator,

    fn init(gpa: std.mem.Allocator) !*Sandbox {
        const self = try gpa.create(Sandbox);
        self.* = .{
            .tmp = std.testing.tmpDir(.{ .iterate = true }),
            .threaded = .init(gpa, .{}),
            .arena = .init(gpa),
        };
        return self;
    }

    fn deinit(self: *Sandbox, gpa: std.mem.Allocator) void {
        self.arena.deinit();
        self.threaded.deinit();
        self.tmp.cleanup();
        gpa.destroy(self);
    }

    fn io(self: *Sandbox) Io {
        return self.threaded.io();
    }

    fn dir(self: *Sandbox) Dir {
        return self.tmp.dir;
    }

    fn a(self: *Sandbox) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn slurp(self: *Sandbox, name: []const u8) ![]u8 {
        return self.dir().readFileAlloc(self.io(), name, self.a(), .limited(max_snapshot));
    }
};

test "an empty directory generates every table, and says which file it wrote" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.tablesOf(Pg, &.{ User, Org });
    const out = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = "initial" });

    try testing.expectEqualStrings("0001_initial.zig", out.file.?);
    try testing.expectEqual(@as(u32, 1), out.number);
    try testing.expect(!out.wasHeld());

    // Two tables and a unique index. `orgs` first, because `users` points at it.
    try testing.expectEqual(@as(usize, 3), out.plan.steps.len);

    const text = try box.slurp("0001_initial.zig");
    try testing.expect(std.mem.indexOf(u8, text, "pub const version: migrate.Version") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".number = 1,") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\\\\CREATE TABLE \"orgs\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@import(\"nilo_sql\").migrate") != null);
}

test "the three files land together, and the snapshot moves with them" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.tablesOf(Pg, &.{ User, Org });
    _ = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = "initial" });

    const manifest = try box.slurp(manifest_file);
    try testing.expect(std.mem.indexOf(u8, manifest, "pub const head: i64 = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, "@import(\"0001_initial.zig\").version") != null);

    const snap = try box.slurp(snapshot_file);
    try testing.expect(std.mem.startsWith(u8, snap, "// Written by `db generate`"));
    try testing.expect(std.mem.indexOf(u8, snap, "\"users\"") != null);

    // And the state that comes back is the state that was written.
    const state = try read(box.a(), box.io(), box.dir(), Pg);
    try testing.expect(state.had_snapshot);
    try testing.expectEqual(@as(u32, 1), state.head());
    try testing.expectEqual(@as(usize, 1), state.entries.len);
    try testing.expectEqualStrings("initial", state.entries[0].name);
    try testing.expectEqual(@as(u32, 1), state.before.version);
}

test "generating twice against the same types writes nothing the second time" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.tablesOf(Pg, &.{ User, Org });
    _ = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = "initial" });

    const again = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = "nothing" });
    try testing.expect(again.isEmpty());
    try testing.expect(!again.wasHeld());
    try testing.expectEqual(@as(?[]const u8, null), again.file);

    // Which is also what `check` answers, and it is the whole of a green CI run.
    const plan = try check(box.a(), box.io(), box.dir(), Pg, desired);
    try testing.expect(plan.isEmpty());
}

test "a second version follows the first, and the manifest names both" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    _ = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.tablesOf(Pg, &.{Org}),
        .{ .name = "orgs" },
    );

    const Grown = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        name: []const u8,
        note: ?[]const u8,
    };
    const out = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.tablesOf(Pg, &.{Grown}),
        .{ .name = "add_note" },
    );

    try testing.expectEqualStrings("0002_add_note.zig", out.file.?);
    try testing.expectEqual(@as(usize, 1), out.plan.steps.len);
    try testing.expectEqual(migrate.Kind.add_column, out.plan.steps[0].kind);

    const manifest = try box.slurp(manifest_file);
    try testing.expect(std.mem.indexOf(u8, manifest, "pub const head: i64 = 2;") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, "@import(\"0001_orgs.zig\")") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, "@import(\"0002_add_note.zig\")") != null);

    const state = try read(box.a(), box.io(), box.dir(), Pg);
    try testing.expectEqual(@as(usize, 2), state.entries.len);
    try testing.expectEqual(@as(u32, 1), state.entries[0].number);
    try testing.expectEqual(@as(u32, 2), state.entries[1].number);
}

test "a destructive step is not written until somebody asks for it by name" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const Wide = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        name: []const u8,
        note: ?[]const u8,
    };
    const Narrow = struct {
        pub const nilo_table = .{ .name = "orgs", .key = .id };
        id: i64,
        name: []const u8,
    };

    _ = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.tablesOf(Pg, &.{Wide}),
        .{ .name = "wide" },
    );

    const held = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.tablesOf(Pg, &.{Narrow}),
        .{ .name = "drop_note" },
    );

    // The plan is there to read. The file is not, and the snapshot has not
    // moved, so nothing about the repository says this happened.
    try testing.expect(held.wasHeld());
    try testing.expect(held.plan.destructive());
    try testing.expectEqual(@as(?[]const u8, null), held.file);
    try testing.expectError(error.FileNotFound, box.slurp("0002_drop_note.zig"));

    const asked = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.tablesOf(Pg, &.{Narrow}),
        .{ .name = "drop_note", .allow_destructive = true },
    );
    try testing.expectEqualStrings("0002_drop_note.zig", asked.file.?);

    // And the file says so where a reviewer will see it.
    const text = try box.slurp("0002_drop_note.zig");
    try testing.expect(std.mem.indexOf(u8, text, ".destructive = true,") != null);
}

test "a version name that is not safe as a path and an identifier is refused" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.tablesOf(Pg, &.{Org});
    for ([_][]const u8{ "", "../escape", "Add Note", "add-note", "add.note" }) |bad| {
        try testing.expectError(
            Error.BadName,
            generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = bad }),
        );
    }
}

test "the rendered version is what a person would have written by hand" {
    const gpa = testing.allocator;
    const steps: []const Step = &.{
        .{
            .kind = .add_column,
            .why = "User.nickname",
            .sql = "ALTER TABLE \"users\" ADD COLUMN \"nickname\" text",
            .needs_backfill = true,
        },
    };

    const text = try renderVersion(gpa, 7, "add_nickname", steps, .{ .name = "add_nickname" });
    defer gpa.free(text);

    try testing.expectEqualStrings(
        \\// Written by `db generate` from the Rows in this repository, and committed.
        \\//
        \\// Read it like code, because it is exactly what will run: these steps, in
        \\// this order, inside one transaction. A step you write yourself goes in the
        \\// same list with `.kind = .data`, and `generate` never produces one of
        \\// those, so it will not be taken away again.
        \\//
        \\// Editing this after it has been applied changes the version's hash, and
        \\// `migrate.drift` reports it against every database that has run it.
        \\
        \\const migrate = @import("nilo_sql").migrate;
        \\
        \\pub const version: migrate.Version = .{
        \\    .number = 7,
        \\    .name = "add_nickname",
        \\    .steps = &.{
        \\        .{
        \\            .kind = .add_column,
        \\            .why = "User.nickname",
        \\            .needs_backfill = true,
        \\            .sql =
        \\            \\ALTER TABLE "users" ADD COLUMN "nickname" text
        \\            ,
        \\        },
        \\    },
        \\};
        \\
    , text);
}

test "a statement of several lines keeps its shape in the file" {
    const gpa = testing.allocator;
    const steps: []const Step = &.{
        .{
            .kind = .create_table,
            .why = "create orgs",
            .sql = "CREATE TABLE \"orgs\" (\n  \"id\" int8 PRIMARY KEY,\n  \"name\" text NOT NULL\n)",
        },
    };

    const text = try renderVersion(gpa, 1, "orgs", steps, .{ .name = "orgs" });
    defer gpa.free(text);

    // Every line of it is its own `\\` line, so the file reads as SQL rather
    // than as one long escaped string.
    try testing.expect(std.mem.indexOf(u8, text, "            \\\\CREATE TABLE \"orgs\" (\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "            \\\\  \"id\" int8 PRIMARY KEY,\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "            \\\\)\n            ,\n") != null);
}

test "a manifest with nothing in it still says what its head is" {
    const gpa = testing.allocator;
    const text = try renderManifest(gpa, &.{}, .{ .name = "unused" });
    defer gpa.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "pub const head: i64 = 0;") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pub const versions: []const migrate.Version = &.{\n};") != null);
}

test "the manifest's version list is already the slice every call wants" {
    const gpa = testing.allocator;
    const text = try renderManifest(gpa, &.{.{ .number = 1, .name = "initial", .file = "0001_initial.zig" }}, .{ .name = "unused" });
    defer gpa.free(text);

    // An array here would make every caller write `&manifest.versions`, which
    // is a papercut the first real dependent hit within a minute of building.
    try testing.expect(std.mem.indexOf(u8, text, "pub const versions: []const migrate.Version = &.{") != null);
    try testing.expect(std.mem.indexOf(u8, text, "migrate.chainOf(gpa, versions)") != null);
}

test "a file name is read back into the three parts the manifest needs" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const e = try entryOf(arena.allocator(), "0042_split_name.zig");
    try testing.expectEqual(@as(u32, 42), e.number);
    try testing.expectEqualStrings("split_name", e.name);
    try testing.expectEqualStrings("0042_split_name.zig", e.file);

    for ([_][]const u8{ "42_short.zig", "00042_long.zig", "nonumber.zig", "0001_Bad.zig" }) |bad| {
        try testing.expect(std.meta.isError(entryOf(arena.allocator(), bad)));
    }
}

test "two branches that both generated version 2 are a merge that does not build" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    // What a bad merge leaves behind: both files kept, both numbered 2.
    try box.dir().writeFile(box.io(), .{ .sub_path = "0001_a.zig", .data = "" });
    try box.dir().writeFile(box.io(), .{ .sub_path = "0002_theirs.zig", .data = "" });
    try box.dir().writeFile(box.io(), .{ .sub_path = "0002_ours.zig", .data = "" });

    try testing.expectError(Error.DuplicateVersion, read(box.a(), box.io(), box.dir(), Pg));
}
