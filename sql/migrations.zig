//! The `migrations/` directory: reading it, and writing the next version into
//! it ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
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

/// The most a version file may be, for `--baseline`, which is the one thing
/// here that reads one back. A ported schema of sixty tables is a few hundred
/// kilobytes of `CREATE TABLE`.
pub const max_version = 8 * 1024 * 1024;

/// The two lines around the steps `generate` wrote
/// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
///
/// `--baseline` replaces what is between them and keeps every byte outside, so
/// a port can re-derive version 1 forty times without losing the hand-written
/// half of the file. They are matched as whole lines, and a file that has lost
/// one is refused rather than rewritten: the alternative is throwing somebody's
/// work away and reporting success.
pub const generated_begin = "// nilo:generated begin";
pub const generated_end = "// nilo:generated end";

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
    /// `--baseline` in a directory that holds a version it is not re-deriving.
    /// Version 2 is a diff against what version 1 left behind, so a re-derived
    /// version 1 makes version 2 describe a schema that never existed.
    BaselineHasOthers,
    /// `--baseline --name initial` where version 1 on disk is called something
    /// else. Writing the new name would leave both files in the directory, and
    /// the next `read` refuses a directory with two version 1s.
    BaselineRenames,
    /// A version file being rewritten in place that has no `generated_begin`
    /// and `generated_end` around its steps, so nothing can tell which half of
    /// it `generate` wrote.
    NoGeneratedBlock,
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
    /// Which shape the snapshot turned out to be in. `.upgraded` means an
    /// older nilo wrote it and this one read it anyway, which is worth saying
    /// once on screen because the file is still the old one until the next
    /// `generate` rewrites it.
    origin: snapshot.Origin = .current,
    /// Every version file, by number ascending.
    entries: []const Entry,

    /// The highest version on disk, or zero.
    pub fn head(self: State) u32 {
        return if (self.entries.len == 0) 0 else self.entries[self.entries.len - 1].number;
    }
};

/// What `readWith` is allowed to do, for the two callers that want less than
/// everything.
pub const Read = struct {
    /// Read `snapshot.zon` as well as the version files.
    ///
    /// **`--baseline` sets this false**, and that is a fix rather than an
    /// optimisation: it derives from nothing, and the file it would otherwise
    /// parse is exactly the one a shape change has just invalidated. Reading
    /// it first made the one command that exists to get out of that state the
    /// one command that could not run
    /// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
    snapshot: bool = true,
    /// Where `std.zon` writes the line, the column and the offending text of a
    /// parse failure. Worth passing wherever a person will read the result.
    diag: ?*std.zon.parse.Diagnostics = null,
};

/// Read the directory. Everything is allocated out of `gpa`, which is an arena
/// in every caller worth having.
pub fn read(gpa: std.mem.Allocator, io: Io, dir: Dir, comptime D: type) !State {
    return readWith(gpa, io, dir, D, .{});
}

/// The same, for a caller that does not want the snapshot or does want the
/// diagnostics.
pub fn readWith(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    comptime D: type,
    opts: Read,
) !State {
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

    const nothing: State = .{
        .before = snapshot.empty(D),
        .had_snapshot = false,
        .entries = entries.items,
    };
    if (!opts.snapshot) return nothing;

    const text = dir.readFileAllocOptions(
        io,
        snapshot_file,
        gpa,
        .limited(max_snapshot),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return nothing,
        else => return err,
    };

    var origin: snapshot.Origin = .current;
    return .{
        .before = try snapshot.parseWith(gpa, text, opts.diag, &origin),
        .had_snapshot = true,
        .origin = origin,
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
    /// The steps that lose data which may be written, each by its target:
    /// `orders` for a table, `orders.note` for a column, `extension:pgcrypto`.
    /// **A destructive step not named here holds the whole version back**,
    /// and so does a name that matches no step, and the `Outcome` lists both,
    /// so the ask is made at the command line by somebody who has read them.
    ///
    /// Names rather than a switch, because a switch also covers the drop
    /// nobody read: a field renamed without `.was` is a dropped column in the
    /// same list as the one that was meant.
    drop: []const []const u8 = &.{},
    /// What the generated files call the SQL module in their `@import`.
    module: []const u8 = default_module,
    /// Forget the snapshot and derive version 1 from nothing, rewriting the
    /// file that is already there.
    ///
    /// **Porting a schema is one version written forty times**, not forty
    /// versions. Without this the loop is a shell script that deletes the
    /// snapshot, deletes the version file and resets the manifest by hand,
    /// which is what the nodeflux port wrote and what
    /// [ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)
    /// is about. Everything outside the version file's generated block is kept.
    baseline: bool = false,
    /// The versions this binary was built with, from the generated manifest.
    ///
    /// **Only the `.sql` twins read it**, and it is what makes them possible at
    /// all: a version's hash is chained onto the one before it, and the file
    /// being written is the one version not yet compiled into anything. Empty
    /// means no twin is written, which is what a library caller with no
    /// manifest to hand gets
    /// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
    versions: []const Version = &.{},
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
    /// The file was already there and its generated block was replaced. Only
    /// `--baseline` does this, and it is worth saying out loud because the
    /// word on screen is the difference between "wrote" and "kept your half".
    rewrote: bool = false,
    /// How many `.sql` twins were written or brought back into line.
    twins: usize = 0,
    /// The twins could not be written, because this binary holds a version file
    /// it did not compile: `--baseline` replaced a generated block, and the
    /// hand-written steps either side of it are in the new `.zig` and not in
    /// anything running. One rebuild and one more `db generate` or `db check`
    /// closes it, and `check` refuses until then
    /// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
    twins_deferred: bool = false,
    /// The destructive steps' targets `Options.drop` did not name. Any at
    /// all and nothing was written.
    unnamed: []const []const u8 = &.{},
    /// The names in `Options.drop` no destructive step has. Any at all and
    /// nothing was written: it is usually a typo for the drop that was meant.
    stray: []const []const u8 = &.{},

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
    desired: migrate.Desired,
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
    desired: migrate.Desired,
    opts: Options,
) !Outcome {
    try checkName(opts.name);

    // **The snapshot is not read at all under `--baseline`**, and reading it
    // first was the whole of the bug: the one command that gets a repository
    // out of a snapshot it can no longer parse was the one command that
    // stopped on it (ADR 181).
    const state = try readWith(gpa, io, dir, D, .{ .snapshot = !opts.baseline });
    if (opts.baseline) return baseline(gpa, io, dir, D, desired, opts, state);

    const change = try migrate.plan(gpa, D, desired, state.before);

    // **The twins are refreshed whether or not there is a new version**, which
    // is what makes `check`'s "any `db generate` writes them" true. A schema
    // that has not moved is exactly when a stale `.sql` is easiest to leave
    // behind: nothing else in this command has anything to do.
    const unnamed = try change.unnamed(gpa, opts.drop);
    const stray: []const []const u8 = if (change.isEmpty()) &.{} else try change.stray(gpa, opts.drop);
    if (change.isEmpty() or change.problems.len > 0 or unnamed.len > 0 or stray.len > 0) {
        return .{
            .plan = change,
            .unnamed = unnamed,
            .stray = stray,
            .twins = try writeSql(gpa, io, dir, D, opts.versions, state.entries),
        };
    }

    const number = state.head() + 1;
    const file = try std.fmt.allocPrint(gpa, "{d:0>4}_{s}.zig", .{ number, opts.name });

    try dir.writeFile(io, .{
        .sub_path = file,
        .data = try renderVersion(gpa, number, opts.name, change.steps, opts),
    });

    const with_new = try gpa.alloc(Entry, state.entries.len + 1);
    @memcpy(with_new[0..state.entries.len], state.entries);
    with_new[state.entries.len] = .{ .number = number, .name = opts.name, .file = file };

    try writeManifestAndSnapshot(gpa, io, dir, D, desired, opts, with_new, number);

    // **The version just written is the one version no binary has compiled**,
    // and its twin is still exact: `renderVersion` writes `before` and `after`
    // empty, so its steps are the ones in hand. Everything before it comes out
    // of the manifest this binary was built with.
    const all = try withNew(gpa, opts.versions, number, opts.name, change.steps);
    const twins = if (all) |list|
        try writeSql(gpa, io, dir, D, list, with_new)
    else
        0;
    return .{
        .plan = change,
        .file = file,
        .number = number,
        .twins = twins,
        .twins_deferred = all == null and opts.versions.len > 0,
    };
}

/// The compiled versions plus the one `generate` has just written, or null when
/// the two do not line up.
///
/// They fail to line up when the binary is behind the directory — somebody
/// generated, did not rebuild, and generated again. Chaining a hash onto a
/// parent that is not the real parent would put a wrong hash in a file people
/// apply by hand, so the honest answer is to write no twin and say so.
fn withNew(
    gpa: std.mem.Allocator,
    versions: []const Version,
    number: u32,
    name: []const u8,
    steps: []const Step,
) !?[]const Version {
    if (versions.len != number - 1) return null;
    if (versions.len > 0 and versions[versions.len - 1].number != @as(i64, number) - 1) return null;

    const out = try gpa.alloc(Version, versions.len + 1);
    @memcpy(out[0..versions.len], versions);
    out[versions.len] = .{ .number = number, .name = name, .steps = steps };
    return out;
}

/// `--baseline`: diff against nothing and rewrite version 1 where it stands.
///
/// **The snapshot is not read at all**, which is the whole point — a port is
/// the same version derived again and again, and the snapshot is exactly what
/// makes the second run say "nothing to do". What it will not do is touch a
/// directory that has moved past version 1: everything after the first is a
/// diff against what the first left behind, so re-deriving the first quietly
/// turns the rest into a description of a schema that never existed.
fn baseline(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    comptime D: type,
    desired: migrate.Desired,
    opts: Options,
    state: State,
) !Outcome {
    var here: ?Entry = null;
    for (state.entries) |e| {
        if (e.number != 1) return Error.BaselineHasOthers;
        here = e;
    }
    if (here) |e| {
        if (!std.mem.eql(u8, e.name, opts.name)) return Error.BaselineRenames;
    }

    const change = try migrate.plan(gpa, D, desired, snapshot.empty(D));
    if (change.isEmpty()) return .{ .plan = change };
    if (change.problems.len > 0) return .{ .plan = change };
    // A diff against nothing is every `CREATE TABLE` and no `DROP`, so this
    // cannot fire today. It is here so that the day the baseline diff learns to
    // write something destructive, `--drop` still guards it.
    const unnamed = try change.unnamed(gpa, opts.drop);
    const stray = try change.stray(gpa, opts.drop);
    if (unnamed.len > 0 or stray.len > 0) return .{ .plan = change, .unnamed = unnamed, .stray = stray };

    const file = try std.fmt.allocPrint(gpa, "0001_{s}.zig", .{opts.name});
    const rewrote = here != null;

    const text = if (rewrote) blk: {
        const old = try dir.readFileAlloc(io, file, gpa, .limited(max_version));
        break :blk try spliceGenerated(gpa, old, change.steps);
    } else try renderVersion(gpa, 1, opts.name, change.steps, opts);

    try dir.writeFile(io, .{ .sub_path = file, .data = text });

    const only: []const Entry = &.{.{ .number = 1, .name = opts.name, .file = file }};
    try writeManifestAndSnapshot(gpa, io, dir, D, desired, opts, only, 1);

    // A rewrite keeps whatever is in `before` and `after`, and those are Zig
    // this binary cannot read and did not compile — so the version's real steps
    // are not in hand and its twin would be a file that says the wrong thing.
    // A first derivation has neither half, so that one is exact.
    const twins = if (rewrote) 0 else try writeSql(
        gpa,
        io,
        dir,
        D,
        &.{.{ .number = 1, .name = opts.name, .steps = change.steps }},
        only,
    );
    return .{
        .plan = change,
        .file = file,
        .number = 1,
        .rewrote = rewrote,
        .twins = twins,
        .twins_deferred = rewrote,
    };
}

/// The two files that follow a version file, in the order that survives a run
/// that dies halfway: the manifest that names the version, then the snapshot
/// that says the schema has moved.
fn writeManifestAndSnapshot(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    comptime D: type,
    desired: migrate.Desired,
    opts: Options,
    entries: []const Entry,
    version: u32,
) !void {
    try dir.writeFile(io, .{
        .sub_path = manifest_file,
        .data = try renderManifest(gpa, entries, opts),
    });

    const doc = try migrate.snapshotOf(gpa, D, version, desired);
    try dir.writeFile(io, .{
        .sub_path = snapshot_file,
        .data = try snapshot.render(gpa, doc),
    });
}

// -- the twin a database gets without a compiler --------------------------

/// The `.sql` beside `NNNN_name.zig`, as text. Caller frees.
///
/// **An output and never an input**
/// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
/// Authoring stays Zig, for every reason ADR 123 gives; what does not have to
/// be Zig is *applying* a version, and today it is — `status --sql` opens a
/// database to work out which versions are waiting, so somebody with `psql` and
/// no toolchain cannot get the statements at all.
///
/// Three things go in that `status --sql` leaves out, and each of them is what
/// makes the file usable on its own: the ledger table, created if it is not
/// there, so a fresh database takes version 1; `BEGIN`/`COMMIT`, so a version
/// that fails halfway leaves nothing; and the ledger row, so a database brought
/// to head by hand satisfies `db.expecting(manifest.head)` on the next boot
/// rather than refusing to serve.
pub fn renderSql(
    gpa: std.mem.Allocator,
    comptime D: type,
    version: Version,
    name: []const u8,
    hash: []const u8,
    source: []const u8,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.print(
        \\-- Written by `db generate` from {s}, and committed.
        \\--
        \\-- The same steps that file runs, for a database no Zig toolchain can
        \\-- reach: `psql -f`, a CI job with no compiler, somebody on a jump host.
        \\-- nilo reads the `.zig` and never this; `db check` fails when the two
        \\-- have come apart, so they cannot quietly disagree.
        \\--
        \\-- It carries its own ledger row, so a database brought to head this way
        \\-- is a database `db.expecting(manifest.head)` will serve.
        \\
        \\
    , .{source});
    // What `migrate.apply` does through `wire.Begin.rebuilding`: with foreign
    // keys on, the DROP in a table rebuild deletes the old table's rows first
    // and every `ON DELETE CASCADE` pointing at it fires.
    if (comptime !D.can_alter_column) try w.writeAll(
        \\-- Foreign keys off for the version, as `db migrate` runs it: dropping a
        \\-- table to rebuild it would otherwise delete the rows pointing at it.
        \\-- The check before COMMIT prints any row left pointing at nothing, and
        \\-- a script cannot stop on it, so read what it prints.
        \\PRAGMA foreign_keys = OFF;
        \\
        \\
    );
    try w.writeAll("BEGIN;\n\n");

    try w.print("{s};\n\n", .{comptime ddl.createIfMissing(D, migrate.Applied)});

    for (version.steps) |step| {
        var lines = std.mem.splitScalar(u8, step.why, '\n');
        while (lines.next()) |line| try w.print("-- {s}\n", .{line});
        if (step.destructive) try w.writeAll("-- This one loses data that nothing brings back.\n");
        if (step.needs_backfill) try w.writeAll(
            "-- This one can fail on a table that already has rows.\n",
        );
        try w.print("{s};\n\n", .{step.sql});
    }

    const ledger = comptime D.qualify(null, @import("row.zig").tableOf(migrate.Applied));
    try w.print("INSERT INTO {s} (", .{ledger});
    inline for (@typeInfo(migrate.Applied).@"struct".fields, 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(comptime D.quote(f.name));
    }
    try w.print(")\nVALUES ({d}, '", .{version.number});
    try writeSqlLiteral(w, name);
    try w.writeAll("', '");
    try writeSqlLiteral(w, hash);
    // Zero milliseconds, because nobody timed it. The column is what an
    // operator reads when they ask which migration is the slow one, and a
    // number invented here would be a worse answer than none.
    try w.print("', {s}, 0);\n\n", .{D.now_default});
    if (comptime !D.can_alter_column) try w.writeAll("PRAGMA foreign_key_check;\n\n");
    try w.writeAll("COMMIT;\n");
    if (comptime !D.can_alter_column) try w.writeAll("\nPRAGMA foreign_keys = ON;\n");
    return aw.toOwnedSlice();
}

/// One piece of text inside a SQL literal, with a quote doubled — the same rule
/// `ddl.zig` applies to a word out of a snapshot.
fn writeSqlLiteral(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        if (ch == '\'') try w.writeAll("'");
        try w.writeByte(ch);
    }
}

/// `0007_name.zig` becomes `0007_name.sql`.
pub fn sqlTwin(gpa: std.mem.Allocator, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.sql", .{file[0 .. file.len - ".zig".len]});
}

/// Write the twin for every version this binary holds, and say how many files
/// changed.
///
/// Every version rather than the new one: a twin is regenerated whenever the
/// `.zig` beside it is, and the cheapest way to hold that is to write them all
/// and compare. Sixty versions of a ported schema is a few hundred kilobytes,
/// once, at the command line.
pub fn writeSql(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    comptime D: type,
    versions: []const Version,
    entries: []const Entry,
) !usize {
    const chain = try migrate.chainOf(gpa, versions);
    var written: usize = 0;
    for (chain.versions, chain.hashes) |v, hash| {
        const entry = entryFor(entries, v.number) orelse continue;
        const twin = try sqlTwin(gpa, entry.file);
        const text = try renderSql(gpa, D, v, entry.name, hash, entry.file);
        if (try sameOnDisk(gpa, io, dir, twin, text)) continue;
        try dir.writeFile(io, .{ .sub_path = twin, .data = text });
        written += 1;
    }
    return written;
}

/// The twins that are missing or no longer say what their version says, by file
/// name. What `check` reports, so that a stale `.sql` is a red build rather
/// than something somebody applies by hand six months later.
pub fn staleSql(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    comptime D: type,
    versions: []const Version,
    entries: []const Entry,
) ![]const []const u8 {
    const chain = try migrate.chainOf(gpa, versions);
    var out: std.ArrayList([]const u8) = .empty;
    for (chain.versions, chain.hashes) |v, hash| {
        const entry = entryFor(entries, v.number) orelse continue;
        const twin = try sqlTwin(gpa, entry.file);
        const text = try renderSql(gpa, D, v, entry.name, hash, entry.file);
        if (try sameOnDisk(gpa, io, dir, twin, text)) continue;
        try out.append(gpa, twin);
    }
    return out.toOwnedSlice(gpa);
}

fn entryFor(entries: []const Entry, number: i64) ?Entry {
    for (entries) |e| {
        if (e.number == number) return e;
    }
    return null;
}

fn sameOnDisk(
    gpa: std.mem.Allocator,
    io: Io,
    dir: Dir,
    file: []const u8,
    text: []const u8,
) !bool {
    const old = dir.readFileAlloc(io, file, gpa, .limited(max_version)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return std.mem.eql(u8, old, text);
}

// -- what a generated file looks like -------------------------------------

/// One version, as the text of its file. Caller frees.
///
/// **The half a person edits is at the top and the generated half is at the
/// bottom**, which is the other way round from how it reads. A ported schema
/// puts four thousand lines of `CREATE TABLE` in this file, and a `version`
/// under them is a `version` nobody ever sees.
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
        \\// this order, inside one transaction.
        \\//
        \\// The generated block at the bottom belongs to `db generate`, and
        \\// `--baseline` replaces it. Everything above it is yours and is kept, so a
        \\// step of your own goes in `before` or `after` and survives the next run.
        \\//
        \\// Editing this after it has been applied changes the version's hash, and
        \\// `migrate.drift` reports it against every database that has run it.
        \\
        \\const migrate = @import("{s}").migrate;
        \\
        \\/// Steps of your own that have to run *before* the generated ones: the
        \\/// extension a generated column's type comes from, a function a default
        \\/// calls. Nothing generated ever lands here.
        \\pub const before: []const migrate.Step = &.{{}};
        \\
        \\/// And the ones that run after: a backfill, a seed row, a `create_hypertable`.
        \\pub const after: []const migrate.Step = &.{{}};
        \\
        \\pub const version: migrate.Version = .{{
        \\    .number = {d},
        \\    .name = "{s}",
        \\    .steps = before ++ generated ++ after,
        \\}};
        \\
        \\
    , .{ opts.module, number, name });

    try writeDropped(w, steps);
    try writeGenerated(w, steps);
    return aw.toOwnedSlice();
}

/// Which losses were named at the command line, above the steps that make
/// them. The steps say `.destructive = true` one at a time; this is the line
/// a reviewer reads first.
fn writeDropped(w: *std.Io.Writer, steps: []const Step) !void {
    var any = false;
    for (steps, 0..) |s, i| {
        if (!s.destructive or s.target.len == 0) continue;
        const seen = for (steps[0..i]) |earlier| {
            if (earlier.destructive and std.mem.eql(u8, earlier.target, s.target)) break true;
        } else false;
        if (seen) continue;
        try w.writeAll(if (any) "," else "// Written with `--drop ");
        try w.writeAll(s.target);
        any = true;
    }
    if (!any) return;
    try w.writeAll(
        \\`. Each of those loses data
        \\// that nothing brings back, and somebody named it.
        \\
        \\
    );
}

/// Replace a version file's generated block and keep every byte outside it.
///
/// Whole-line matching on both markers, and `Error.NoGeneratedBlock` when
/// either is missing. **Refusing beats guessing**: the only other reading of a
/// file with no markers is "all of it is generated", and acting on that throws
/// away the hand-written steps this shape exists to hold.
pub fn spliceGenerated(gpa: std.mem.Allocator, old: []const u8, steps: []const Step) ![]u8 {
    const begin = lineWith(old, generated_begin) orelse return Error.NoGeneratedBlock;
    const after_begin = old[begin.end..];
    const end = lineWith(after_begin, generated_end) orelse return Error.NoGeneratedBlock;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(old[0..begin.start]);
    try writeGenerated(w, steps);
    try w.writeAll(after_begin[end.end..]);
    return aw.toOwnedSlice();
}

const Line = struct { start: usize, end: usize };

/// The line that *is* `marker`, ignoring what is around it. `end` is past the
/// newline, so the two halves either side of a line splice cleanly.
fn lineWith(text: []const u8, marker: []const u8) ?Line {
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const stop = nl orelse text.len;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, text[start..stop], "\r"), marker)) {
            return .{ .start = start, .end = if (nl) |n| n + 1 else text.len };
        }
        if (nl == null) break;
        start = stop + 1;
    }
    return null;
}

/// The block between the two markers, markers included.
fn writeGenerated(w: *std.Io.Writer, steps: []const Step) !void {
    try w.print(
        \\{s}
        \\// Everything to the closing line is `db generate`'s, and a run with
        \\// `--baseline` writes it again from the Rows. Nothing of yours belongs in
        \\// here: it will not be here next time. Do not move or edit either marker.
        \\const generated: []const migrate.Step = &.{{
        \\
    , .{generated_begin});

    for (steps) |s| {
        try w.print("    .{{\n        .kind = .{t},\n", .{s.kind});
        try w.writeAll("        .why = \"");
        try writeEscaped(w, s.why);
        try w.writeAll("\",\n");
        if (s.destructive) try w.writeAll("        .destructive = true,\n");
        if (s.needs_backfill) try w.writeAll("        .needs_backfill = true,\n");
        try w.writeAll("        .sql =\n");
        var lines = std.mem.splitScalar(u8, s.sql, '\n');
        while (lines.next()) |line| try w.print("        \\\\{s}\n", .{line});
        try w.writeAll("        ,\n    },\n");
    }

    try w.print("}};\n{s}\n", .{generated_end});
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
        \\// `db.expecting(manifest.head)` costs one query at boot and refuses to
        \\// serve a database the migrations have not reached.
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
const Lite = @import("dialect.zig").SQLite;
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

    /// What a person does to a generated file between two runs.
    fn overwrite(self: *Sandbox, name: []const u8, data: []const u8) !void {
        try self.dir().writeFile(self.io(), .{ .sub_path = name, .data = data });
    }
};

/// `orgs` with one more column, for the tests that move the schema.
const Noted = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };
    id: i64,
    name: []const u8,
    note: ?[]const u8,
};

test "an empty directory generates every table, and says which file it wrote" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.desiredOf(Pg, .{ .tables = &.{ User, Org } });
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

    const desired = comptime migrate.desiredOf(Pg, .{ .tables = &.{ User, Org } });
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

    const desired = comptime migrate.desiredOf(Pg, .{ .tables = &.{ User, Org } });
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
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} }),
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
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Grown} }),
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
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Wide} }),
        .{ .name = "wide" },
    );

    const held = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Narrow} }),
        .{ .name = "drop_note" },
    );

    // The plan is there to read. The file is not, and the snapshot has not
    // moved, so nothing about the repository says this happened.
    try testing.expect(held.wasHeld());
    try testing.expect(held.plan.destructive());
    try testing.expectEqual(@as(?[]const u8, null), held.file);
    try testing.expectError(error.FileNotFound, box.slurp("0002_drop_note.zig"));
    // And it says what to name, which is the whole of the fix.
    try testing.expectEqual(@as(usize, 1), held.unnamed.len);
    try testing.expectEqualStrings("orgs.note", held.unnamed[0]);

    // A name that matches nothing holds it back too: it is usually a typo for
    // the drop that was meant, and writing the rest would read as done.
    const typo = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Narrow} }),
        .{ .name = "drop_note", .drop = &.{ "orgs.note", "orgs.notes" } },
    );
    try testing.expect(typo.wasHeld());
    try testing.expectEqual(@as(usize, 1), typo.stray.len);
    try testing.expectEqualStrings("orgs.notes", typo.stray[0]);
    try testing.expectError(error.FileNotFound, box.slurp("0002_drop_note.zig"));

    const asked = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Narrow} }),
        .{ .name = "drop_note", .drop = &.{"orgs.note"} },
    );
    try testing.expectEqualStrings("0002_drop_note.zig", asked.file.?);

    // And the file says so where a reviewer will see it: on the step, and in
    // one line at the top naming what was dropped.
    const text = try box.slurp("0002_drop_note.zig");
    try testing.expect(std.mem.indexOf(u8, text, ".destructive = true,") != null);
    try testing.expect(std.mem.indexOf(u8, text, "// Written with `--drop orgs.note`.") != null);
}

test "a SQLite twin runs its version with foreign keys off and checks them before the commit" {
    const gpa = testing.allocator;
    const text = try renderSql(gpa, Lite, .{
        .number = 2,
        .name = "rebuild",
        .steps = &.{.{ .kind = .data, .why = "rebuild", .sql = "DROP TABLE \"old\"" }},
    }, "rebuild", "abc", "0002_rebuild.zig");
    defer gpa.free(text);

    const off = std.mem.indexOf(u8, text, "PRAGMA foreign_keys = OFF;").?;
    const begin = std.mem.indexOf(u8, text, "BEGIN;").?;
    const checked = std.mem.indexOf(u8, text, "PRAGMA foreign_key_check;").?;
    const commit = std.mem.indexOf(u8, text, "COMMIT;").?;
    const on = std.mem.indexOf(u8, text, "PRAGMA foreign_keys = ON;").?;
    // Off before the BEGIN, because SQLite ignores it inside a transaction.
    try testing.expect(off < begin and begin < checked and checked < commit and commit < on);

    // Postgres drops nothing a key points at, so its twin has none of it.
    const pg = try renderSql(gpa, Pg, .{ .number = 2, .name = "x", .steps = &.{} }, "x", "abc", "0002_x.zig");
    defer gpa.free(pg);
    try testing.expect(std.mem.indexOf(u8, pg, "PRAGMA") == null);
}

test "a version name that is not safe as a path and an identifier is refused" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} });
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
        \\// this order, inside one transaction.
        \\//
        \\// The generated block at the bottom belongs to `db generate`, and
        \\// `--baseline` replaces it. Everything above it is yours and is kept, so a
        \\// step of your own goes in `before` or `after` and survives the next run.
        \\//
        \\// Editing this after it has been applied changes the version's hash, and
        \\// `migrate.drift` reports it against every database that has run it.
        \\
        \\const migrate = @import("nilo_sql").migrate;
        \\
        \\/// Steps of your own that have to run *before* the generated ones: the
        \\/// extension a generated column's type comes from, a function a default
        \\/// calls. Nothing generated ever lands here.
        \\pub const before: []const migrate.Step = &.{};
        \\
        \\/// And the ones that run after: a backfill, a seed row, a `create_hypertable`.
        \\pub const after: []const migrate.Step = &.{};
        \\
        \\pub const version: migrate.Version = .{
        \\    .number = 7,
        \\    .name = "add_nickname",
        \\    .steps = before ++ generated ++ after,
        \\};
        \\
        \\// nilo:generated begin
        \\// Everything to the closing line is `db generate`'s, and a run with
        \\// `--baseline` writes it again from the Rows. Nothing of yours belongs in
        \\// here: it will not be here next time. Do not move or edit either marker.
        \\const generated: []const migrate.Step = &.{
        \\    .{
        \\        .kind = .add_column,
        \\        .why = "User.nickname",
        \\        .needs_backfill = true,
        \\        .sql =
        \\        \\ALTER TABLE "users" ADD COLUMN "nickname" text
        \\        ,
        \\    },
        \\};
        \\// nilo:generated end
        \\
    , text);
}

test "the shape the file is written in is a shape that compiles" {
    // The generated file is written into a directory and read back as text;
    // nothing in this suite ever hands one to the compiler. So the one thing in
    // it the compiler has to agree with — three slices concatenated into the
    // `.steps` of a `Version` — is written out here, where it does.
    const before: []const Step = &.{};
    const generated: []const Step = &.{
        .{ .kind = .create_table, .why = "create orgs", .sql = "CREATE TABLE \"orgs\" ()" },
    };
    const after: []const Step = &.{
        .{ .kind = .data, .why = "the first org", .sql = "INSERT INTO \"orgs\" DEFAULT VALUES" },
    };

    const v: Version = .{ .number = 1, .name = "schema", .steps = before ++ generated ++ after };
    try testing.expectEqual(@as(usize, 2), v.steps.len);
    try testing.expectEqual(migrate.Kind.create_table, v.steps[0].kind);
    try testing.expectEqual(migrate.Kind.data, v.steps[1].kind);
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
    try testing.expect(std.mem.indexOf(u8, text, "        \\\\CREATE TABLE \"orgs\" (\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "        \\\\  \"id\" int8 PRIMARY KEY,\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "        \\\\)\n        ,\n") != null);
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

// -- `--baseline` ---------------------------------------------------------

test "a baseline derives version 1 again and keeps the half somebody wrote" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const first = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} }),
        .{ .name = "schema", .baseline = true },
    );
    // An empty directory is the case where a baseline is just the first
    // generate, and it says so rather than claiming it kept anything.
    try testing.expectEqualStrings("0001_schema.zig", first.file.?);
    try testing.expect(!first.rewrote);

    // What the port does to the file it was handed: its own steps beside the
    // generated ones, outside the block.
    const mine =
        \\pub const after: []const migrate.Step = &.{
        \\    .{ .kind = .data, .why = "the first org", .sql = "INSERT INTO \"orgs\" ..." },
        \\};
    ;
    try box.overwrite("0001_schema.zig", try std.mem.replaceOwned(
        u8,
        box.a(),
        try box.slurp("0001_schema.zig"),
        "pub const after: []const migrate.Step = &.{};",
        mine,
    ));

    // A column arrives. The port does not want an `ALTER`; it wants the same
    // version derived again, which is the whole of what `--baseline` is.
    const out = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Noted} }),
        .{ .name = "schema", .baseline = true },
    );

    try testing.expectEqualStrings("0001_schema.zig", out.file.?);
    try testing.expectEqual(@as(u32, 1), out.number);
    try testing.expect(out.rewrote);
    try testing.expectEqual(@as(usize, 1), out.plan.steps.len);
    try testing.expectEqual(migrate.Kind.create_table, out.plan.steps[0].kind);

    const text = try box.slurp("0001_schema.zig");
    try testing.expect(std.mem.indexOf(u8, text, "the first org") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"note\" text") != null);
    // One block, not two: a splice that lost a marker would leave both.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, generated_begin));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, generated_end));

    // And the directory is still one version at head 1, with a snapshot that
    // matches it — so `check` right after a baseline is green.
    const state = try read(box.a(), box.io(), box.dir(), Pg);
    try testing.expectEqual(@as(usize, 1), state.entries.len);
    try testing.expectEqual(@as(u32, 1), state.before.version);
    try testing.expect((try check(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Noted} }),
    )).isEmpty());
}

/// A Row with a foreign key, because a foreign key is the whole of what the
/// older snapshot shape spelled differently.
const Member = struct {
    pub const nilo_table = .{
        .name = "members",
        .key = .id,
        .references = .{ .org_id = .{ Org, .id } },
    };

    id: i64,
    org_id: i64,
};

const MemberNoted = struct {
    pub const nilo_table = .{
        .name = "members",
        .key = .id,
        .references = .{ .org_id = .{ Org, .id } },
    };

    id: i64,
    org_id: i64,
    note: ?[]const u8,
};

/// The same two tables as v0.4.0 wrote them: `.column` and `.target` on the
/// reference, one name each rather than a list.
const older_snapshot =
    \\.{
    \\    .version = 1,
    \\    .dialect = "postgres",
    \\    .tables = .{
    \\        .{
    \\            .table = "orgs",
    \\            .keys = .{"id"},
    \\            .columns = .{
    \\                .{ .name = "id", .sql_type = "int8", .key = true, .generated = true },
    \\                .{ .name = "name", .sql_type = "text" },
    \\            },
    \\        },
    \\        .{
    \\            .table = "members",
    \\            .keys = .{"id"},
    \\            .columns = .{
    \\                .{ .name = "id", .sql_type = "int8", .key = true, .generated = true },
    \\                .{ .name = "org_id", .sql_type = "int8" },
    \\            },
    \\            .references = .{
    \\                .{
    \\                    .name = "members_org_id_fkey",
    \\                    .column = "org_id",
    \\                    .table = "orgs",
    \\                    .target = "id",
    \\                },
    \\            },
    \\        },
    \\    },
    \\}
    \\
;

test "a baseline does not read the snapshot it is there to replace" {
    // **The bug this is the regression test for.** `generate` read the
    // snapshot before it looked at `opts.baseline`, so the one command that
    // gets a repository out of a snapshot it can no longer parse was the one
    // command that stopped on it — and it stopped with forty lines of stack
    // trace, because nothing handed `std.zon` a `Diagnostics` either.
    //
    // It is tested here, through `generate`, rather than against
    // `snapshot.parse`. A test one layer under the bug is what let this ship:
    // `snapshot.zig` proved the parse refused an older file and stayed green
    // while no caller could act on the refusal
    // ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    try box.overwrite(snapshot_file, "this is not zon at all {{{\n");

    const out = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} }),
        .{ .name = "schema", .baseline = true },
    );
    try testing.expectEqualStrings("0001_schema.zig", out.file.?);

    // And the file it could not read is gone, replaced by one it wrote.
    const state = try read(box.a(), box.io(), box.dir(), Pg);
    try testing.expectEqual(@as(u32, 1), state.before.version);
    try testing.expectEqual(snapshot.Origin.current, state.origin);
}

test "an older snapshot is understood, so a generate against it is a diff and not a rewrite" {
    // Not a baseline: an ordinary `generate` in a repository whose snapshot a
    // previous release wrote. Every page says `db generate` is the answer to
    // "your snapshot is older", and that has to be true at any version,
    // because `--baseline` refuses to re-derive once there is a version 2.
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    try box.overwrite(snapshot_file, older_snapshot);
    try box.overwrite("0001_orgs_and_members.zig", "");

    const state = try read(box.a(), box.io(), box.dir(), Pg);
    try testing.expectEqual(snapshot.Origin.upgraded, state.origin);
    try testing.expectEqual(@as(u32, 1), state.before.version);

    // **The strong assertion**: against the Rows that file describes, the
    // upgraded document says there is nothing to do. A foreign key read into
    // the wrong shape would show up here as a reference that changed.
    try testing.expect((try check(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{ Member, Org } }),
    )).isEmpty());

    // So one new column is one step, rather than a `CREATE TABLE` for a table
    // that has been there since version 1.
    const out = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{ MemberNoted, Org } }),
        .{ .name = "add_note" },
    );
    try testing.expectEqualStrings("0002_add_note.zig", out.file.?);
    try testing.expectEqual(@as(usize, 1), out.plan.steps.len);
    try testing.expectEqual(migrate.Kind.add_column, out.plan.steps[0].kind);

    // And what it wrote is in the current shape, so the upgrade happens once
    // rather than on every run from here on.
    const after = try read(box.a(), box.io(), box.dir(), Pg);
    try testing.expectEqual(snapshot.Origin.current, after.origin);
}

test "a baseline in a directory that has moved past version 1 is refused" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    _ = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} }),
        .{ .name = "orgs" },
    );
    _ = try generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Noted} }),
        .{ .name = "add_note" },
    );

    // Version 2 is a diff against what version 1 left behind. Re-deriving
    // version 1 would leave version 2 describing a schema nothing ever had.
    try testing.expectError(Error.BaselineHasOthers, generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Noted} }),
        .{ .name = "orgs", .baseline = true },
    ));

    const manifest = try box.slurp(manifest_file);
    try testing.expect(std.mem.indexOf(u8, manifest, "pub const head: i64 = 2;") != null);
}

test "a baseline under another name is refused rather than leaving two version 1s" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} });
    _ = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = "schema", .baseline = true });

    try testing.expectError(Error.BaselineRenames, generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        desired,
        .{ .name = "initial", .baseline = true },
    ));

    // The rename is refused because writing it is not undoable: both files
    // would sit there, and `read` refuses a directory with two version 1s.
    try testing.expectError(error.FileNotFound, box.slurp("0001_initial.zig"));
}

test "a version file that lost its markers is refused, not overwritten" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} });
    _ = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = "schema", .baseline = true });

    const hand_written = "// all of this is mine now\npub const version = 1;\n";
    try box.overwrite("0001_schema.zig", hand_written);

    try testing.expectError(Error.NoGeneratedBlock, generate(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        comptime migrate.desiredOf(Pg, .{ .tables = &.{Noted} }),
        .{ .name = "schema", .baseline = true },
    ));

    // Nothing was written. The other reading of a file with no markers is
    // "all of it is generated", and acting on that throws the file away.
    try testing.expectEqualStrings(hand_written, try box.slurp("0001_schema.zig"));
}

test "the splice keeps every byte outside the two markers, and only those" {
    const gpa = testing.allocator;
    const old =
        \\const mine = 1;
        \\// nilo:generated begin
        \\const generated: []const migrate.Step = &.{
        \\    what was there before
        \\};
        \\// nilo:generated end
        \\const also_mine = 2;
        \\
    ;

    const text = try spliceGenerated(gpa, old, &.{
        .{ .kind = .data, .why = "new", .sql = "SELECT 1" },
    });
    defer gpa.free(text);

    try testing.expect(std.mem.startsWith(u8, text, "const mine = 1;\n"));
    try testing.expect(std.mem.endsWith(u8, text, "// nilo:generated end\nconst also_mine = 2;\n"));
    try testing.expect(std.mem.indexOf(u8, text, "what was there before") == null);
    try testing.expect(std.mem.indexOf(u8, text, "SELECT 1") != null);

    // Both markers have to be there, and in that order.
    try testing.expectError(Error.NoGeneratedBlock, spliceGenerated(gpa, "nothing\n", &.{}));
    try testing.expectError(
        Error.NoGeneratedBlock,
        spliceGenerated(gpa, "// nilo:generated begin\nand no end\n", &.{}),
    );
}

// -- the `.sql` twin (ADR 123) -------------------------------------------

test "a version written with no manifest to hand gets no twin, and says nothing about one" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.desiredOf(Pg, .{ .tables = &.{ User, Org } });
    const out = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = "initial" });

    // `versions` is empty, which is what a library caller with no generated
    // manifest has. Version 1's parent is `""` either way, so the twin is still
    // exact — `withNew` lets it through on `versions.len == number - 1`.
    try testing.expectEqual(@as(usize, 1), out.twins);
    try testing.expect(!out.twins_deferred);
    _ = try box.slurp("0001_initial.sql");
}

test "the twin is the version's statements, the ledger table and the ledger row" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} });
    _ = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = "initial" });

    const text = try box.slurp("0001_initial.sql");

    // Wrapped, so a version that fails halfway leaves nothing behind.
    try testing.expect(std.mem.indexOf(u8, text, "\nBEGIN;\n") != null);
    try testing.expect(std.mem.endsWith(u8, text, "COMMIT;\n"));

    // The ledger, made if it is not there, or a fresh database cannot take
    // version 1 at all.
    try testing.expect(std.mem.indexOf(
        u8,
        text,
        "CREATE TABLE IF NOT EXISTS \"nilo_migrations\"",
    ) != null);

    // The statement itself, with its `why` above it as a comment.
    try testing.expect(std.mem.indexOf(u8, text, "-- create orgs\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "CREATE TABLE \"orgs\" (") != null);

    // And the row that makes applying it by hand enough.
    var chained: [64]u8 = undefined;
    const hash = migrate.hashOf("", (try migrate.plan(
        box.a(),
        Pg,
        desired,
        snapshot.empty(Pg),
    )).steps, &chained);
    const row = try std.fmt.allocPrint(
        box.a(),
        "INSERT INTO \"nilo_migrations\" (\"version\", \"name\", \"hash\", " ++
            "\"applied_at\", \"ms\")\nVALUES (1, 'initial', '{s}', now(), 0);",
        .{hash},
    );
    try testing.expect(std.mem.indexOf(u8, text, row) != null);
}

test "a twin somebody edited is written again by the next generate, and named by check" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const desired = comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} });
    _ = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{ .name = "initial" });

    const version: Version = .{
        .number = 1,
        .name = "initial",
        .steps = (try migrate.plan(box.a(), Pg, desired, snapshot.empty(Pg))).steps,
    };
    const state = try read(box.a(), box.io(), box.dir(), Pg);

    // Nothing wrong with it yet.
    try testing.expectEqual(@as(usize, 0), (try staleSql(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        &.{version},
        state.entries,
    )).len);

    try box.overwrite("0001_initial.sql", "DROP TABLE \"orgs\";\n");
    const stale = try staleSql(box.a(), box.io(), box.dir(), Pg, &.{version}, state.entries);
    try testing.expectEqual(@as(usize, 1), stale.len);
    try testing.expectEqualStrings("0001_initial.sql", stale[0]);

    // And any `generate` puts it back, including one with nothing to generate —
    // which is exactly when a stale twin is easiest to leave behind.
    const again = try generate(box.a(), box.io(), box.dir(), Pg, desired, .{
        .name = "initial",
        .versions = &.{version},
    });
    try testing.expect(again.isEmpty());
    try testing.expectEqual(@as(usize, 1), again.twins);
    try testing.expectEqual(@as(usize, 0), (try staleSql(
        box.a(),
        box.io(),
        box.dir(),
        Pg,
        &.{version},
        state.entries,
    )).len);
}

test "a second version's twin is chained onto the first, so the hash is the one verify holds" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const first = comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} });
    _ = try generate(box.a(), box.io(), box.dir(), Pg, first, .{ .name = "initial" });

    const one: Version = .{
        .number = 1,
        .name = "initial",
        .steps = (try migrate.plan(box.a(), Pg, first, snapshot.empty(Pg))).steps,
    };

    const second = comptime migrate.desiredOf(Pg, .{ .tables = &.{Noted} });
    const out = try generate(box.a(), box.io(), box.dir(), Pg, second, .{
        .name = "orgs_get_a_note",
        .versions = &.{one},
    });
    try testing.expectEqual(@as(u32, 2), out.number);
    // Both twins: the one that was already right is compared and left alone,
    // and the new one is written.
    try testing.expectEqual(@as(usize, 1), out.twins);

    const chain = try migrate.chainOf(box.a(), &.{
        one,
        .{ .number = 2, .name = "orgs_get_a_note", .steps = out.plan.steps },
    });
    const text = try box.slurp("0002_orgs_get_a_note.sql");
    try testing.expect(std.mem.indexOf(u8, text, chain.hashes[1]) != null);
    // Not the unchained one, which is what a twin written in isolation would
    // have carried.
    var alone: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(
        u8,
        text,
        migrate.hashOf("", out.plan.steps, &alone),
    ) == null);
}

test "a binary behind the directory writes no twin rather than one with a wrong hash" {
    const gpa = testing.allocator;
    var box = try Sandbox.init(gpa);
    defer box.deinit(gpa);

    const first = comptime migrate.desiredOf(Pg, .{ .tables = &.{Org} });
    const one = try generate(box.a(), box.io(), box.dir(), Pg, first, .{ .name = "initial" });
    try testing.expectEqual(@as(u32, 1), one.number);

    // Version 2 generated by a binary that still holds no manifest at all: its
    // parent hash is unknown, so chaining would invent one.
    const second = comptime migrate.desiredOf(Pg, .{ .tables = &.{Noted} });
    const two = try generate(box.a(), box.io(), box.dir(), Pg, second, .{
        .name = "orgs_get_a_note",
        .versions = &.{},
    });
    try testing.expectEqual(@as(u32, 2), two.number);
    try testing.expectEqual(@as(usize, 0), two.twins);
    try testing.expect(two.twins_deferred == false);
    try testing.expectError(
        error.FileNotFound,
        box.dir().readFileAlloc(box.io(), "0002_orgs_get_a_note.sql", box.a(), .limited(1024)),
    );
}
