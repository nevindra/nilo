//! The commands, so that a project's migration tool is a `main` of ten lines
//! ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
//!
//! ```zig
//! pub fn main() !u8 {
//!     // … gpa, io, and a started Db …
//!     const Tool = sql.cli.Tool(Db, .{ .tables = &.{ User, Org } });
//!     return Tool.run(gpa, io, out, try sql.cli.parse(args), &db, manifest.versions);
//! }
//! ```
//!
//! **The wording is shipped rather than left to each caller**, and that is the
//! reason this file exists at all. Everything under it is already callable:
//! `migrations.generate` returns an `Outcome`, `migrate.drift` returns a list.
//! What a person actually meets is the sentence that comes back when a
//! migration is destructive, or when the database is three versions behind, and
//! a sentence written once here is a sentence written well. This repository
//! holds 195 error messages in place with a build step for the same reason.
//!
//! ## Where the line is
//!
//! Argument parsing, dispatch and every sentence are here. What is *not* here
//! is opening the database, reading the environment and building the
//! allocator — those belong to the caller, who is the only one who knows their
//! connection string and their `Db` type. So this takes a `Db` that is already
//! started, and hands back an exit code rather than calling `std.process.exit`.
//!
//! ## Exit codes
//!
//! `0` did what was asked. `1` the caller has something to do — a check that
//! found a difference, a version held back, drift against the ledger. `2` the
//! command line was wrong. A CI job branches on those without reading a word.

const std = @import("std");

const core = @import("nilo_core");
const migrate = @import("migrate.zig");
const migrations = @import("migrations.zig");

const Io = std.Io;
const Version = migrate.Version;

pub const ok: u8 = 0;
pub const acted: u8 = 1;
pub const misused: u8 = 2;

pub const Command = enum {
    /// Diff the types against the snapshot and write the next version.
    generate,
    /// The same diff, written nowhere. What CI runs.
    check,
    /// Which versions the database has and has not got.
    status,
    /// Apply what is missing.
    migrate,
    /// Has an applied version been edited since?
    verify,
    help,
};

pub const Request = struct {
    command: Command,
    /// `--name`, for `generate`.
    name: []const u8 = "",
    /// `--drop orders.note,extension:pgcrypto`: the losses this version may
    /// make, by name, comma-separated. Nothing that loses data is written
    /// unless it is named here (`migrations.Options.drop`).
    drop: []const u8 = "",
    /// `--drop` with no names after it. It drops nothing, and the refusal
    /// says so beside the names it wanted.
    drop_bare: bool = false,
    /// `--dir`, which almost nobody sets.
    dir: []const u8 = "migrations",
    /// `--sql`, for `status`: print the statements rather than a summary.
    sql_only: bool = false,
    /// `--baseline`, for `generate`: forget the snapshot, derive version 1 from
    /// nothing and rewrite it where it stands. What porting a schema needs, and
    /// the only thing here that writes over a file that is already there.
    baseline: bool = false,
};

pub const ParseError = error{
    NoCommand,
    UnknownCommand,
    UnknownFlag,
    MissingValue,
    /// `generate` with no `--name`. A version called `0007_.zig` helps nobody
    /// six months later, which is why this is refused rather than defaulted.
    NoName,
    /// `--drop` twice. The names go in one, comma-separated.
    DropTwice,
};

/// Read `argv[1..]`. The program name is not passed in.
pub fn parse(args: []const []const u8) ParseError!Request {
    if (args.len == 0) return ParseError.NoCommand;

    const command = std.meta.stringToEnum(Command, args[0]) orelse
        return ParseError.UnknownCommand;

    var req: Request = .{ .command = command };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--drop")) {
            if (req.drop.len > 0 or req.drop_bare) return ParseError.DropTwice;
            // A flag after it, or nothing, is a `--drop` that names nothing:
            // kept rather than refused here, so `generate` can answer with
            // the names this version wants.
            if (i + 1 == args.len or std.mem.startsWith(u8, args[i + 1], "--")) {
                req.drop_bare = true;
            } else {
                i += 1;
                req.drop = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--sql")) {
            req.sql_only = true;
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            req.baseline = true;
        } else if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "--dir")) {
            i += 1;
            if (i == args.len) return ParseError.MissingValue;
            if (std.mem.eql(u8, arg, "--name")) req.name = args[i] else req.dir = args[i];
        } else {
            return ParseError.UnknownFlag;
        }
    }

    if (command == .generate and req.name.len == 0) return ParseError.NoName;
    return req;
}

/// What to say when `parse` refused, and what to exit with.
pub fn explain(w: *std.Io.Writer, err: ParseError) !u8 {
    switch (err) {
        ParseError.NoCommand => try w.writeAll("db: no command.\n\n"),
        ParseError.UnknownCommand => try w.writeAll("db: no such command.\n\n"),
        ParseError.UnknownFlag => try w.writeAll("db: no such flag.\n\n"),
        ParseError.MissingValue => try w.writeAll("db: that flag takes a value.\n\n"),
        ParseError.NoName => try w.writeAll(
            "db: `generate` needs `--name`. A version called `0007_.zig` helps " ++
                "nobody six months from now.\n\n",
        ),
        ParseError.DropTwice => try w.writeAll(
            "db: `--drop` once, with every name in it comma-separated: " ++
                "`--drop orders.note,extension:pgcrypto`.\n\n",
        ),
    }
    try usage(w);
    return misused;
}

pub fn usage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Migrations for this project. The schema is the Rows; these move a
        \\database to match them.
        \\
        \\  generate --name <snake_case> [--drop <what>,…] [--baseline]
        \\        Diff the Rows against migrations/snapshot.zon and write the
        \\        next version. Needs no database. Anything that loses data is
        \\        written only once `--drop` names it: `orders` for a table,
        \\        `orders.note` for a column or a type that may not fit, and
        \\        `extension:pgcrypto`. Without the names it says which.
        \\
        \\        `--baseline` ignores the snapshot, derives version 1 from
        \\        nothing and rewrites it in place. It keeps everything outside
        \\        the file's generated block, so the steps you wrote by hand
        \\        survive. Refused once there is a version 2, which is a diff
        \\        against what version 1 left behind.
        \\
        \\        Every run also writes the `.sql` twin beside each version: the
        \\        same statements, wrapped in BEGIN/COMMIT, with the ledger row
        \\        on the end. `psql -f` applies one, so a database nobody can
        \\        point a Zig toolchain at still reaches head. They are outputs;
        \\        nilo never reads one back.
        \\
        \\  check
        \\        The same diff, written nowhere. Exits 1 when the Rows and the
        \\        migrations disagree, or when a `.sql` twin no longer says what
        \\        the version beside it says. Needs no database, which is what
        \\        CI wants.
        \\
        \\  status [--sql]
        \\        Which versions this database has, and which are waiting.
        \\        `--sql` prints the statements the waiting ones would run.
        \\
        \\  migrate
        \\        Apply what is waiting. One transaction per version, behind an
        \\        advisory lock, so several of these at once is safe.
        \\
        \\  verify
        \\        Has a version been edited since it ran? Exits 1 if so.
        \\
        \\Every command takes --dir <path>, which defaults to `migrations`.
        \\There is no `down`. `generate` is forward-only by design.
        \\
    );
}

/// The commands, bound to one project's database and schema.
///
/// `Db` is `sql.Db`, `sql.Sqlite(…)` or a named one, already started. `schema`
/// is the `sql.Schema` — every Row whose table this tool owns, and the
/// extensions, functions and views beside them — the same value `db.checking`
/// and `createMissing` are given, which is what keeps the three from drifting
/// apart (ADR 181).
pub fn Tool(comptime Db: type, comptime schema: migrate.Schema) type {
    return struct {
        const D = Db.Dialect;

        /// Run one request. `versions` comes from the generated manifest, and
        /// may be empty for the two commands that touch no database.
        ///
        /// `db` is optional because `generate` and `check` do not need one, and
        /// requiring it would mean a CI job that never reaches a database still
        /// has to hold a connection string.
        pub fn run(
            gpa: std.mem.Allocator,
            io: Io,
            w: *std.Io.Writer,
            req: Request,
            db: ?*Db,
            versions: []const Version,
        ) !u8 {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();

            return switch (req.command) {
                .help => blk: {
                    try usage(w);
                    break :blk ok;
                },
                .generate => try doGenerate(a, io, w, req, versions),
                .check => try doCheck(a, io, w, req, versions),
                .status => try doStatus(gpa, io, w, req, try needs(w, db), versions),
                .migrate => try doMigrate(gpa, w, try needs(w, db), versions),
                .verify => try doVerify(gpa, w, try needs(w, db), versions),
            };
        }

        const NoDatabase = error{NoDatabase};

        fn needs(w: *std.Io.Writer, db: ?*Db) !*Db {
            return db orelse {
                try w.writeAll(
                    "db: this command needs a database, and none was opened. " ++
                        "`generate` and `check` are the two that do not.\n",
                );
                return NoDatabase.NoDatabase;
            };
        }

        const desired = migrate.desiredOf(D, schema);

        /// `createDirPath` rather than one `createDir`, so that `--dir
        /// db/versions` works on a repository that has neither.
        fn openDir(io: Io, path: []const u8, make: bool) !std.Io.Dir {
            const cwd = std.Io.Dir.cwd();
            if (make) try cwd.createDirPath(io, path);
            return cwd.openDir(io, path, .{ .iterate = true });
        }

        fn doGenerate(
            a: std.mem.Allocator,
            io: Io,
            w: *std.Io.Writer,
            req: Request,
            versions: []const Version,
        ) !u8 {
            var dir = try openDir(io, req.dir, true);
            defer dir.close(io);

            const out = migrations.generate(a, io, dir, D, desired, .{
                .name = req.name,
                .drop = try dropList(a, req.drop),
                .baseline = req.baseline,
                .versions = versions,
            }) catch |err| switch (err) {
                migrations.Error.BaselineHasOthers,
                migrations.Error.BaselineRenames,
                migrations.Error.NoGeneratedBlock,
                => return try baselineRefused(a, io, dir, w, req, err),
                error.ParseZon => return try snapshotRefused(a, io, dir, w, req),
                else => return err,
            };

            try olderSnapshot(a, io, dir, w, req);
            if (out.isEmpty()) {
                try w.writeAll("Nothing to do: the Rows and the snapshot already agree.\n");
                try writeTwins(w, req, out);
                return ok;
            }
            if (out.file) |file| {
                try w.print("{s} {s}/{s}, {d} step(s):\n\n", .{
                    if (out.rewrote) "Rewrote" else "Wrote",
                    req.dir,
                    file,
                    out.plan.steps.len,
                });
                try writeSteps(w, out.plan.steps);
                if (out.rewrote) {
                    try w.writeAll(
                        "\nThe generated block is new; everything else in the file is as " ++
                            "you left it. `migrations/snapshot.zon` moved with it, and both " ++
                            "belong in the same commit.\n",
                    );
                } else {
                    try w.writeAll(
                        "\nRead it before you commit it. `migrations/snapshot.zon` moved " ++
                            "with it, and both belong in the same commit.\n",
                    );
                }
                try writeTwins(w, req, out);
                return ok;
            }
            try writeHeld(w, out, req);
            return acted;
        }

        /// The three ways `--baseline` refuses, each naming the file it is
        /// about. The directory is read a second time for that: an error value
        /// carries nothing, and "there is a version 2" is not a sentence
        /// anybody can act on without its number.
        fn baselineRefused(
            a: std.mem.Allocator,
            io: Io,
            dir: std.Io.Dir,
            w: *std.Io.Writer,
            req: Request,
            err: anyerror,
        ) !u8 {
            const state = try migrations.read(a, io, dir, D);
            try writeBaselineRefusal(w, err, req, state.entries);
            return acted;
        }

        /// A snapshot that parsed in neither shape, as a sentence with
        /// `std.zon`'s own line and column under it.
        ///
        /// The directory is read a second time to get them: an error value
        /// carries nothing, and the alternative is the forty-line stack trace
        /// that reached a user once (ADR 181).
        fn snapshotRefused(
            a: std.mem.Allocator,
            io: Io,
            dir: std.Io.Dir,
            w: *std.Io.Writer,
            req: Request,
        ) !u8 {
            var diag: std.zon.parse.Diagnostics = .{};
            defer diag.deinit(a);
            _ = migrations.readWith(a, io, dir, D, .{ .diag = &diag }) catch {};

            try writeSnapshotRefusal(w, req, &diag);
            return acted;
        }

        /// One line when the snapshot was written by an older nilo. Said once
        /// rather than refused, because the next `generate` rewrites it.
        fn olderSnapshot(
            a: std.mem.Allocator,
            io: Io,
            dir: std.Io.Dir,
            w: *std.Io.Writer,
            req: Request,
        ) !void {
            const state = migrations.read(a, io, dir, D) catch return;
            if (state.origin != .upgraded) return;
            try writeOlderSnapshot(w, req);
        }

        fn doCheck(
            a: std.mem.Allocator,
            io: Io,
            w: *std.Io.Writer,
            req: Request,
            versions: []const Version,
        ) !u8 {
            var dir = openDir(io, req.dir, false) catch |err| switch (err) {
                error.FileNotFound => {
                    try w.print(
                        "There is no {s}/ directory. `db generate --name initial` " ++
                            "makes the first one.\n",
                        .{req.dir},
                    );
                    return acted;
                },
                else => return err,
            };
            defer dir.close(io);

            const change = migrations.check(a, io, dir, D, desired) catch |err| switch (err) {
                error.ParseZon => return try snapshotRefused(a, io, dir, w, req),
                else => return err,
            };
            try olderSnapshot(a, io, dir, w, req);
            if (change.isEmpty()) {
                // The other half of "up to date": a `.sql` twin that no longer
                // says what its `.zig` says is a file somebody applies by hand
                // six months later, and nothing else would ever look at it.
                const state = try migrations.read(a, io, dir, D);
                const stale = try migrations.staleSql(a, io, dir, D, versions, state.entries);
                if (stale.len > 0) {
                    try writeStale(w, req, stale);
                    return acted;
                }
                try w.writeAll("Up to date: every Row is in the migrations.\n");
                return ok;
            }

            try w.print(
                "The Rows and the migrations disagree. {d} step(s) have not been " ++
                    "generated:\n\n",
                .{change.steps.len},
            );
            try writeSteps(w, change.steps);
            try writeProblems(w, change.problems);
            try w.writeAll("\n`db generate --name <what you changed>` writes them.\n");
            return acted;
        }

        fn doStatus(
            gpa: std.mem.Allocator,
            io: Io,
            w: *std.Io.Writer,
            req: Request,
            db: *Db,
            versions: []const Version,
        ) !u8 {
            var tick: core.Run = .init(gpa);
            defer tick.deinit();
            _ = io;

            const chain = try migrate.chainOf(tick.arena(), versions);
            try migrate.ensureLedger(db, &tick);
            const at = try migrate.headVersion(db, &tick);

            if (versions.len == 0) {
                try w.writeAll("No migrations. The manifest is empty.\n");
                return ok;
            }

            var waiting: usize = 0;
            var edited: usize = 0;
            for (chain.versions, chain.hashes) |v, hash| {
                const row = try db.find(migrate.Applied, &tick, v.number);
                const applied = row != null;
                if (!applied) waiting += 1;
                // The row already carries the hash, so saying `edited` here
                // costs nothing over saying `applied`. It is worth saying:
                // `status` is the command people run first, and a version
                // whose file no longer matches what ran is the one thing it
                // would otherwise report as fine.
                const moved = if (row) |r| !std.mem.eql(u8, r.hash, hash) else false;
                if (moved) edited += 1;
                // `{d:0>4}` on a signed integer puts the sign *after* the
                // padding — version 3 prints as `00+3`. A version number is
                // never negative, so it is widened to unsigned before it is
                // formatted, here and everywhere else it is padded.
                const number: u64 = @intCast(v.number);
                if (req.sql_only) {
                    if (applied) continue;
                    try w.print("-- {d:0>4} {s}\n", .{ number, v.name });
                    for (v.steps) |s| try w.print("{s};\n", .{s.sql});
                    try w.writeAll("\n");
                } else {
                    try w.print("{s} {d:0>4}  {s}\n", .{
                        if (moved) "edited " else if (applied) "applied" else "waiting",
                        number,
                        v.name,
                    });
                }
            }

            if (req.sql_only) return if (waiting == 0) ok else acted;

            try w.print("\nDatabase at {d}, manifest head {d}.\n", .{ at, chain.head() });
            if (edited > 0) try w.print(
                "{d} applied version(s) no longer match their file. `db verify` says which.\n",
                .{edited},
            );
            if (waiting == 0) {
                if (edited == 0) try w.writeAll("Nothing waiting.\n");
                return if (edited == 0) ok else acted;
            }
            try w.print("{d} waiting. `db migrate` runs them.\n", .{waiting});
            return acted;
        }

        fn doMigrate(
            gpa: std.mem.Allocator,
            w: *std.Io.Writer,
            db: *Db,
            versions: []const Version,
        ) !u8 {
            var tick: core.Run = .init(gpa);
            defer tick.deinit();

            const chain = try migrate.chainOf(tick.arena(), versions);
            try migrate.ensureLedger(db, &tick);

            const moved = try migrate.drift(db, &tick, chain);
            if (moved.len > 0) {
                try writeDrift(w, moved);
                try w.writeAll("\nNothing was applied. Sort that out first.\n");
                return acted;
            }

            const before = try migrate.headVersion(db, &tick);
            const ran = try migrate.applyPending(db, &tick, chain);
            if (ran == 0) {
                try w.print("Nothing to do: the database is at {d}.\n", .{before});
                return ok;
            }
            try w.print(
                "Applied {d} version(s). The database is at {d}.\n",
                .{ ran, try migrate.headVersion(db, &tick) },
            );
            return ok;
        }

        fn doVerify(
            gpa: std.mem.Allocator,
            w: *std.Io.Writer,
            db: *Db,
            versions: []const Version,
        ) !u8 {
            var tick: core.Run = .init(gpa);
            defer tick.deinit();

            const chain = try migrate.chainOf(tick.arena(), versions);
            const moved = try migrate.drift(db, &tick, chain);
            if (moved.len == 0) {
                try w.print("{d} version(s), and every one is what it was when it ran.\n", .{
                    chain.len(),
                });
                return ok;
            }
            try writeDrift(w, moved);
            return acted;
        }
    };
}

/// `--drop`'s value as the list `migrations.Options.drop` takes: split on
/// commas, trimmed, empties left out.
fn dropList(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |piece| {
        const name = std.mem.trim(u8, piece, " ");
        if (name.len > 0) try out.append(a, name);
    }
    return out.items;
}

/// Why `generate` wrote nothing, and the command that would write it.
///
/// **The command is printed whole**, names and all, because the names are
/// what the person has to read before they type them: a field renamed without
/// `.was` shows up here as a column dropped, beside the one that was meant.
fn writeHeld(w: *std.Io.Writer, out: migrations.Outcome, req: Request) !void {
    const change = out.plan;
    if (change.problems.len > 0) {
        try w.writeAll("Nothing written. The diff will not write these:\n\n");
        try writeProblems(w, change.problems);
        return;
    }

    if (out.stray.len > 0) {
        try w.writeAll("Nothing written. `--drop` names something this version does not drop:\n\n");
        for (out.stray) |name| try w.print("  {s}\n", .{name});
        try w.writeAll("\nWhat it drops is:\n\n");
        var any = false;
        for (change.steps) |s| {
            if (!s.destructive) continue;
            try w.print("  {s}\n", .{s.target});
            any = true;
        }
        if (!any) try w.writeAll("  nothing\n");
        try w.writeAll("\nA name that matches nothing is usually a typo for the one that was meant.\n");
        return;
    }

    if (req.drop_bare) try w.writeAll(
        "`--drop` names what it drops, and on its own it names nothing.\n\n",
    );
    try w.writeAll(
        "Nothing written. Some of this loses data that nothing brings back:\n\n",
    );
    for (change.steps) |s| {
        if (!s.destructive) continue;
        try w.print("  {s}  {s}\n", .{ s.target, s.why });
        try writeIndented(w, s.sql);
    }
    try w.print(
        "\nThe rest of the version is fine. When you have read the above, name each " ++
            "one to write it:\n\n  db generate --name {s} --drop ",
        .{req.name},
    );
    for (out.unnamed, 0..) |name, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(name);
    }
    try w.print(
        "\n\nA column you meant to rename is one of these too: give the field " ++
            "`.was` instead, and it is a rename. The generated file in {s}/ says " ++
            "which names you gave.\n",
        .{req.dir},
    );
}

/// Every line of the SQL, indented — not just the first.
///
/// A `CREATE TABLE` is six lines, and printing it with one `{s}` puts five of
/// them hard against column zero, where they read as five separate steps.
/// What `generate` says about the `.sql` twins it wrote, or did not
/// ([ADR 123](../docs/adr/123-a-migration-is-a-diff-against-a-snapshot.md)).
fn writeTwins(w: *std.Io.Writer, req: Request, out: migrations.Outcome) !void {
    if (out.twins_deferred) {
        try w.print(
            "\nThe `.sql` twins are not written: this binary holds the version file " ++
                "it had before, and the steps you wrote by hand in it are Zig nobody " ++
                "has compiled yet. Build, then run `db check` — it says which twins " ++
                "are waiting, and `db generate` writes them.\n",
            .{},
        );
        return;
    }
    if (out.twins == 0) return;
    try w.print(
        "\n{d} `.sql` twin(s) under {s}/ written or brought back into line. They are " ++
            "outputs: `psql -f` applies one, ledger row and all, and nothing here ever " ++
            "reads one back.\n",
        .{ out.twins, req.dir },
    );
}

/// The twins `check` found missing or out of date, by name, because the fix is
/// one command and the list is what says it is needed.
fn writeStale(w: *std.Io.Writer, req: Request, stale: []const []const u8) !void {
    try w.print(
        "Every Row is in the migrations, and {d} `.sql` twin(s) do not match the " ++
            "version beside them:\n\n",
        .{stale.len},
    );
    for (stale) |file| try w.print("  {s}/{s}\n", .{ req.dir, file });
    try w.writeAll(
        "\nA twin is what a database with no Zig toolchain is applied from, so one " ++
            "that has gone stale is worse than one that is missing. " ++
            "`db generate --name <what you changed>` writes them, and so does the " ++
            "next `db generate` of any kind.\n",
    );
}

fn writeIndented(w: *std.Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try w.print("    {s}\n", .{line});
}

fn writeSteps(w: *std.Io.Writer, steps: []const migrate.Step) !void {
    for (steps) |s| {
        try w.print("  {t}  {s}\n", .{ s.kind, s.why });
        try writeIndented(w, s.sql);
        if (s.needs_backfill) try w.writeAll(backfillHint(s.kind));
    }
}

/// What a step flagged `needs_backfill` wants, by kind: the fix is different
/// for each, and the one it used to give for all of them — a data step in
/// front — cannot fill a column that does not exist yet.
fn backfillHint(kind: migrate.Kind) []const u8 {
    return switch (kind) {
        .add_column => "    ^ this fails on a table that already has rows: nothing can fill a " ++
            "column before it exists. Give the field a `.default` in the marker, or " ++
            "ship it optional first and make it required in a later version, after a " ++
            "`.kind = .data` step has filled it.\n",
        .change_null => "    ^ this fails while any row holds a null. A `.kind = .data` step " ++
            "in `before` that fills them goes first.\n",
        else => "    ^ this fails on a table that already has rows breaking it. A " ++
            "`.kind = .data` step in `before` that moves those rows goes first.\n",
    };
}

fn writeProblems(w: *std.Io.Writer, problems: []const migrate.Problem) !void {
    for (problems) |p| {
        if (p.column.len > 0) {
            try w.print("  {s}.{s}\n", .{ p.table, p.column });
        } else {
            try w.print("  {s}\n", .{p.table});
        }
        try w.print("    {s}\n", .{p.text});
    }
}

/// The three ways `--baseline` refuses, each naming the file it is about.
///
/// Free rather than inside `Tool` so that the wording is reachable without a
/// `Db`, which is how the rest of this file's sentences are held in place.
fn writeBaselineRefusal(
    w: *std.Io.Writer,
    err: anyerror,
    req: Request,
    entries: []const migrations.Entry,
) !void {
    switch (err) {
        migrations.Error.BaselineHasOthers => {
            try w.writeAll(
                "db: `--baseline` re-derives version 1, and it is not the only version " ++
                    "here:\n\n",
            );
            for (entries) |e| {
                if (e.number == 1) continue;
                try w.print("  {s}/{s}\n", .{ req.dir, e.file });
            }
            try w.writeAll(
                "\nEach of those is a diff against what the version before it left " ++
                    "behind, so a re-derived version 1 would leave them describing a " ++
                    "schema nothing ever had. Nothing was written. Delete the ones you " ++
                    "are re-deriving, or drop `--baseline` and let this write the next " ++
                    "version instead.\n",
            );
        },
        migrations.Error.BaselineRenames => {
            const was = if (entries.len > 0) entries[0].name else "";
            try w.print(
                "db: version 1 here is called `{s}`, and `--name {s}` would write a " ++
                    "second one beside it. Two files numbered 0001 is a directory " ++
                    "nothing can read. Nothing was written: pass `--name {s}`, or delete " ++
                    "{s}/0001_{s}.zig first if the new name is the one you want.\n",
                .{ was, req.name, was, req.dir, was },
            );
        },
        migrations.Error.NoGeneratedBlock => {
            try w.print(
                "db: {s}/0001_{s}.zig has no `{s}` line, so there is no telling which " ++
                    "half of it `db generate` wrote. Nothing was written, because the " ++
                    "other reading is that all of it is generated and acting on that " ++
                    "throws your steps away. Put the two marker lines back around the " ++
                    "generated steps, or move the file aside and let this write a new " ++
                    "one.\n",
                .{ req.dir, req.name, migrations.generated_begin },
            );
        },
        else => unreachable,
    }
}

/// A snapshot that parsed in neither shape, with `std.zon`'s own line and
/// column under it.
///
/// Free, like every other sentence here, so the wording is reachable without a
/// `Db` — and this one is the reason the rule matters. The version of this that
/// did not exist let a forty-line stack trace out of `db generate`, and the
/// test that should have caught it was calling `snapshot.parse` directly
/// ([ADR 181](../docs/adr/181-the-marker-has-two-kinds-of-word.md)).
fn writeSnapshotRefusal(
    w: *std.Io.Writer,
    req: Request,
    diag: *const std.zon.parse.Diagnostics,
) !void {
    try w.print("db: {s}/{s} is not a snapshot nilo can read.\n\n", .{
        req.dir, migrations.snapshot_file,
    });
    try w.print("{f}\n", .{diag});
    try w.writeAll(
        "Nothing was written. That file is the other half of every diff, so nothing " ++
            "can be generated or checked until it parses. If it was edited by hand, " ++
            "the line above is the one to look at. If this repository is still on " ++
            "version 1, `db generate --name <name> --baseline` derives it again from " ++
            "the Rows without reading it at all.\n",
    );
}

/// One line when the snapshot was written by an older nilo. Said rather than
/// refused, because the `generate` it is printed by rewrites it.
fn writeOlderSnapshot(w: *std.Io.Writer, req: Request) !void {
    try w.print(
        "{s}/{s} was written by an older nilo, and was read in the shape it is in. " ++
            "The next `db generate` writes it in the current one.\n\n",
        .{ req.dir, migrations.snapshot_file },
    );
}

fn writeDrift(w: *std.Io.Writer, moved: []const migrate.Drift) !void {
    try w.print(
        "{d} version(s) have been edited since they were applied here.\n" ++
            "A migration that has run is history, and the database cannot be " ++
            "un-run:\n\n",
        .{moved.len},
    );
    for (moved) |d| {
        const number: u64 = @intCast(d.version);
        try w.print("  {d:0>4} {s}\n", .{ number, d.name });
        try w.print("    ran as   {s}\n", .{d.recorded[0..16]});
        try w.print("    now says {s}\n", .{d.now[0..16]});
    }
    try w.writeAll(
        "\nThe hash is chained, so the first line is the one that was edited and " ++
            "the rest followed it. Put that version back, and write what you " ++
            "meant as a new one.\n",
    );
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "the command line reads into a request, and a bad one says which part" {
    const gen = try parse(&.{ "generate", "--name", "add_nickname" });
    try testing.expectEqual(Command.generate, gen.command);
    try testing.expectEqualStrings("add_nickname", gen.name);
    try testing.expectEqualStrings("", gen.drop);
    try testing.expect(!gen.drop_bare);
    try testing.expectEqualStrings("migrations", gen.dir);

    const dropped = try parse(&.{ "generate", "--name", "drop_note", "--drop", "orgs.note,orgs" });
    try testing.expectEqualStrings("orgs.note,orgs", dropped.drop);
    const bare = try parse(&.{ "generate", "--drop", "--name", "drop_note" });
    try testing.expect(bare.drop_bare);
    try testing.expectEqualStrings("drop_note", bare.name);
    try testing.expectError(
        ParseError.DropTwice,
        parse(&.{ "generate", "--name", "x", "--drop", "a", "--drop", "b" }),
    );

    const elsewhere = try parse(&.{ "check", "--dir", "db/versions" });
    try testing.expectEqualStrings("db/versions", elsewhere.dir);

    try testing.expectEqual(Command.status, (try parse(&.{ "status", "--sql" })).command);
    try testing.expect((try parse(&.{ "status", "--sql" })).sql_only);

    const rederived = try parse(&.{ "generate", "--name", "schema", "--baseline" });
    try testing.expect(rederived.baseline);
    try testing.expect(!gen.baseline);

    try testing.expectError(ParseError.NoCommand, parse(&.{}));
    try testing.expectError(ParseError.UnknownCommand, parse(&.{"rollback"}));
    try testing.expectError(ParseError.UnknownFlag, parse(&.{ "check", "--force" }));
    try testing.expectError(ParseError.MissingValue, parse(&.{ "generate", "--name" }));
    try testing.expectError(ParseError.NoName, parse(&.{"generate"}));
}

test "a `generate` with no name says why rather than picking one" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const code = try explain(&w, ParseError.NoName);
    try testing.expectEqual(misused, code);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "needs `--name`") != null);
    // And it prints the usage under it, so the next thing to type is on screen.
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "generate --name") != null);
}

test "the usage says there is no down, because that is the question it gets" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try usage(&w);

    try testing.expect(std.mem.indexOf(u8, w.buffered(), "There is no `down`") != null);
    // Every command is in it.
    inline for (@typeInfo(Command).@"enum".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "help")) continue;
        try testing.expect(std.mem.indexOf(u8, w.buffered(), "  " ++ f.name) != null);
    }
}

test "a step that needs a backfill says so where somebody will read it" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeSteps(&w, &.{
        .{
            .kind = .add_column,
            .why = "User.tenant_id",
            .sql = "ALTER TABLE \"users\" ADD COLUMN \"tenant_id\" int8 NOT NULL",
            .needs_backfill = true,
        },
    });

    try testing.expect(std.mem.indexOf(u8, w.buffered(), "add_column  User.tenant_id") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "already has rows") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), ".kind = .data") != null);
}

test "a CREATE TABLE stays one step on the screen, however many lines it is" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeSteps(&w, &.{
        .{
            .kind = .create_table,
            .why = "create users",
            .sql = "CREATE TABLE \"users\" (\n  \"id\" int8 PRIMARY KEY,\n  \"email\" text NOT NULL\n)",
        },
    });

    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "\n    CREATE TABLE \"users\" (\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n      \"id\" int8 PRIMARY KEY,\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n    )\n") != null);
    // Nothing landed at column zero, where it would read as a step of its own.
    try testing.expect(std.mem.indexOf(u8, text, "\n\"") == null);
}

test "drift is reported as history that cannot be un-run" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeDrift(&w, &.{
        .{
            .version = 3,
            .name = "add_note",
            .recorded = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .now = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        },
    });

    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "0003 add_note") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ran as   aaaaaaaaaaaaaaaa") != null);
    try testing.expect(std.mem.indexOf(u8, text, "now says bbbbbbbbbbbbbbbb") != null);
    // And what to do, which is not "edit it back and hope".
    try testing.expect(std.mem.indexOf(u8, text, "write what you meant as a new one") != null);
}

test "a refused baseline names the versions it would have made nonsense of" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeBaselineRefusal(
        &w,
        migrations.Error.BaselineHasOthers,
        .{ .command = .generate, .name = "schema", .baseline = true },
        &.{
            .{ .number = 1, .name = "schema", .file = "0001_schema.zig" },
            .{ .number = 2, .name = "add_note", .file = "0002_add_note.zig" },
        },
    );

    const text = w.buffered();
    // The one it would rewrite is not in the list; the ones that would be left
    // wrong are, with the path to each.
    try testing.expect(std.mem.indexOf(u8, text, "  migrations/0002_add_note.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0001_schema.zig") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Nothing was written") != null);
}

test "a refused rename says both names, because the fix is one of them" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeBaselineRefusal(
        &w,
        migrations.Error.BaselineRenames,
        .{ .command = .generate, .name = "initial", .baseline = true },
        &.{.{ .number = 1, .name = "schema", .file = "0001_schema.zig" }},
    );

    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "called `schema`") != null);
    try testing.expect(std.mem.indexOf(u8, text, "`--name initial`") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pass `--name schema`") != null);
}

test "a version file with no markers is refused with the line it is missing" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeBaselineRefusal(
        &w,
        migrations.Error.NoGeneratedBlock,
        .{ .command = .generate, .name = "schema", .dir = "db/versions", .baseline = true },
        &.{.{ .number = 1, .name = "schema", .file = "0001_schema.zig" }},
    );

    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "db/versions/0001_schema.zig") != null);
    // The exact line to put back, not a description of it.
    try testing.expect(std.mem.indexOf(u8, text, migrations.generated_begin) != null);
}

test "a snapshot nilo cannot read is a sentence with the line under it, not a trace" {
    const gpa = testing.allocator;
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(gpa);
    const broken: [:0]const u8 = ".{ .dialect = \"postgres\", .tabels = .{} }";
    try testing.expectError(
        error.ParseZon,
        migrate.snapshot.parse(gpa, broken, &diag),
    );

    try writeSnapshotRefusal(&w, .{ .command = .generate, .name = "x" }, &diag);
    const text = w.buffered();

    // `std.zon`'s own line, column and offending word, which is a better
    // sentence than anything this file would write about a file somebody
    // edited — and it is what a `null` diagnostics threw away.
    try testing.expect(std.mem.indexOf(u8, text, "tabels") != null);
    try testing.expect(std.mem.indexOf(u8, text, "migrations/snapshot.zon") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Nothing was written") != null);
    // And the way out for the case that has one.
    try testing.expect(std.mem.indexOf(u8, text, "--baseline") != null);
}

test "a snapshot an older nilo wrote is mentioned once, not refused" {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeOlderSnapshot(&w, .{ .command = .check, .dir = "db/versions" });
    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "db/versions/snapshot.zon") != null);
    try testing.expect(std.mem.indexOf(u8, text, "older nilo") != null);
    try testing.expect(std.mem.indexOf(u8, text, "`db generate`") != null);
}

test "a version number is padded without its sign getting in the way" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeDrift(&w, &.{
        .{ .version = 3, .name = "three", .recorded = "a" ** 32, .now = "b" ** 32 },
        .{ .version = 12, .name = "twelve", .recorded = "c" ** 32, .now = "d" ** 32 },
    });

    // `{d:0>4}` on an `i64` writes `00+3`, because the sign goes after the
    // padding rather than in front of it. Every padded number here is widened
    // to unsigned first, and this is what says so.
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "0003 three") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "0012 twelve") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "+") == null);
}

test "a stale twin is named on screen, because the fix is one command and the list says which" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeStale(&w, .{ .command = .check }, &.{ "0001_initial.sql", "0004_orgs.sql" });
    const said = w.buffered();

    try testing.expect(std.mem.indexOf(u8, said, "migrations/0001_initial.sql") != null);
    try testing.expect(std.mem.indexOf(u8, said, "migrations/0004_orgs.sql") != null);
    // What a twin is for, said where somebody is reading about one going wrong.
    try testing.expect(std.mem.indexOf(u8, said, "no Zig toolchain") != null);
}

test "a twin that could not be written says what to do, rather than saying nothing" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try writeTwins(&w, .{ .command = .generate }, .{
        .plan = .{ .steps = &.{}, .problems = &.{} },
        .twins_deferred = true,
    });
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "db check") != null);

    // And nothing at all when there was nothing to write, which is the ordinary
    // run of a repository whose twins are already right.
    var quiet: [256]u8 = undefined;
    var q = std.Io.Writer.fixed(&quiet);
    try writeTwins(&q, .{ .command = .generate }, .{
        .plan = .{ .steps = &.{}, .problems = &.{} },
    });
    try testing.expectEqual(@as(usize, 0), q.buffered().len);
}

test "a held version names every loss, and prints the command that writes it" {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const steps = [_]migrate.Step{
        .{ .kind = .add_column, .why = "add orgs.label", .sql = "ALTER TABLE \"orgs\" ADD COLUMN \"label\" text" },
        .{
            .kind = .drop_column,
            .why = "drop orgs.name, which no field reads",
            .sql = "ALTER TABLE \"orgs\" DROP COLUMN \"name\"",
            .destructive = true,
            .target = "orgs.name",
        },
        .{
            .kind = .drop_table,
            .why = "drop notes, which no Row describes",
            .sql = "DROP TABLE \"notes\"",
            .destructive = true,
            .target = "notes",
        },
    };
    try writeHeld(&w, .{
        .plan = .{ .steps = &steps, .problems = &.{} },
        .unnamed = &.{ "orgs.name", "notes" },
    }, .{ .command = .generate, .name = "tidy", .drop_bare = true });

    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "on its own it names nothing") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  orgs.name  drop orgs.name") != null);
    try testing.expect(std.mem.indexOf(u8, text, "db generate --name tidy --drop orgs.name,notes\n") != null);
    // The step that loses nothing is not in the list of what does.
    try testing.expect(std.mem.indexOf(u8, text, "add orgs.label") == null);
    // And the case this exists for: a rename that was written as a drop.
    try testing.expect(std.mem.indexOf(u8, text, "`.was`") != null);
}

test "a name --drop gave that matches nothing is refused beside the names that would" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    const steps = [_]migrate.Step{.{
        .kind = .drop_column,
        .why = "drop orgs.note",
        .sql = "ALTER TABLE \"orgs\" DROP COLUMN \"note\"",
        .destructive = true,
        .target = "orgs.note",
    }};
    try writeHeld(&w, .{
        .plan = .{ .steps = &steps, .problems = &.{} },
        .stray = &.{"orgs.notes"},
    }, .{ .command = .generate, .name = "tidy", .drop = "orgs.notes" });

    const text = w.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "does not drop:\n\n  orgs.notes\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "What it drops is:\n\n  orgs.note\n") != null);
}

test "a backfill hint says the fix for its kind, not one fix for all of them" {
    // An added column cannot be filled by a step in front of it, because it
    // is not there yet. That was the advice once, for every kind.
    try testing.expect(std.mem.indexOf(u8, backfillHint(.add_column), "`.default`") != null);
    try testing.expect(std.mem.indexOf(u8, backfillHint(.add_column), "optional first") != null);
    try testing.expect(std.mem.indexOf(u8, backfillHint(.change_null), "in `before`") != null);
    try testing.expect(std.mem.indexOf(u8, backfillHint(.create_check), "in `before`") != null);
}

test "--drop's names are split on commas, with the spaces and empties left out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try dropList(arena.allocator(), " orgs.note, ,extension:pgcrypto,");
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("orgs.note", list[0]);
    try testing.expectEqualStrings("extension:pgcrypto", list[1]);
}
