//! The queue as a table in the database the program already has
//! ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
//!
//! `Table(Db)` takes the `nilo_sql` Db *type* and calls `insert`, `update`,
//! `select` and `rawOne` on it, the same questions `contract.zig`
//! lists, answered in SQL. `job/` never imports `nilo_sql`: the Db arrives
//! as a parameter, which is what keeps this module a Fitting and lets
//! `zig build layering` say so.
//!
//! **One statement claims a row**, and it is the statement every
//! database-backed queue since 9.5 has used:
//!
//! ```sql
//! UPDATE nilo_jobs SET state = 'running', lease_until = $2, attempts = attempts + 1
//! WHERE id = (SELECT id FROM nilo_jobs
//!             WHERE kind = ANY($3)
//!               AND ((state = 'queued' AND run_at <= $1) OR (state = 'running' AND lease_until <= $1))
//!             ORDER BY priority, run_at LIMIT 1 FOR UPDATE SKIP LOCKED)
//! RETURNING …
//! ```
//!
//! `FOR UPDATE SKIP LOCKED` is what lets several instances share the table:
//! a row one of them is claiming is skipped by the rest rather than waited
//! for. SQLite has no such clause and needs none — it has one writer, so the
//! same statement without it is already serial
//! ([ADR 065](../docs/adr/065-one-writer-is-not-a-setting-it-is-the-database.md)).
//! The second arm of the `WHERE` is the lease: a worker that died holding a
//! row gives it up when `lease_until` passes, to whoever asks next.
//!
//! **`unique` is a unique index, not a check.** `(kind, unique_key)` is
//! unique, and a finished row has its `unique_key` set to NULL — NULLs do not
//! collide — so "at most one queued or running" is the database's promise
//! rather than a read followed by a write that two instances could
//! interleave. `insertOrIgnore` answers null when the row is already there.
//!
//! What this costs a program is one table, one index for the claim and one
//! for the key, and one query per worker per `poll_ms` while idle.
//! `bench/result/job.md` has what a claim costs on each database.

const std = @import("std");
const core = @import("nilo_core");
const contract = @import("contract.zig");

pub fn Table(comptime Db: type) type {
    if (!@hasDecl(Db, "Dialect")) @compileError(
        "nilo: `job.Table(" ++ @typeName(Db) ++ ")` was given something that is not a `nilo_sql` Db.\n" ++
            "  `job.Table(sql.Db)`, or `job.Table(sql.Sqlite(.{ … }))`, or a `sql.Named(…)`.",
    );
    const D = Db.Dialect;
    const on_postgres = std.mem.eql(u8, D.name, "postgres");

    return struct {
        const Self = @This();

        db: *Db,

        /// The table. Add it to `db.checking(.{ .tables = &.{ … } })` and to the migration
        /// beside the program's own rows; nothing here creates it.
        pub const Row = struct {
            pub const nilo_table = .{
                .name = "nilo_jobs",
                .key = .id,
                .unique = .{.{ .kind, .unique_key }},
                .index = .{.{ .state, .run_at }},
                // `priority` may not be null, and a column that may not be
                // null and has no default is the one ALTER that fails on a
                // table with rows in it (sql/ddl.zig). It also has to survive
                // a rolling deploy: an older binary's INSERT does not name
                // the column, and a sibling binary's — ADR 215's own case —
                // never will. The default answers both.
                .default = .{ .priority = @as(i16, @backingInt(contract.Priority.normal)) },
            };

            id: i64,
            kind: []const u8,
            payload: []const u8,
            state: contract.State,
            /// Microseconds since the epoch, the unit `nilo.nowMicros` answers
            /// in. An integer rather than a `Timestamp` so this module needs
            /// nothing from `nilo_sql` to name it.
            run_at: i64,
            /// When a running row may be taken by somebody else. Zero when it
            /// is not running.
            lease_until: i64,
            attempts: i32,
            /// Which due row a worker takes first, as the number behind
            /// `contract.Priority`: `high` is 0, so the claim's ORDER BY is
            /// ascending on both columns. The index above does not carry it.
            /// `(state, run_at)` bounds the scan to the due rows and a top-N
            /// sort picks one; widened to `(state, priority, run_at)` it
            /// stopped bounding anything and measured slower on every queue
            /// tried (ADR 214, bench/result/job.md).
            ///
            /// The integer and not the enum: an enum column is stored as its
            /// *name*, and `ORDER BY` on text sorts 'high' before 'low'
            /// before 'normal', which is neither the order asked for nor an
            /// order at all. A state has no order and is stored as a word; a
            /// priority is only an order.
            priority: i16,
            unique_key: ?[]const u8,
            last_error: ?[]const u8,
            created_at: i64,
            finished_at: ?i64,
        };

        pub fn open(db: *Db) Self {
            return .{ .db = db };
        }

        /// Whether the database is reachable, in the Db's own words. What
        /// `Jobs.nilo_ready` passes on.
        pub fn ready(self: *Self) ?[]const u8 {
            _ = self;
            return null;
        }

        // -- the contract ------------------------------------------------------

        pub fn push(self: *Self, scope: anytype, kind: []const u8, payload: []const u8, at: contract.Enqueue) !?contract.Id {
            return insertOn(self.db, scope, kind, payload, at);
        }

        /// The same row, inside a transaction the caller holds.
        pub fn pushIn(self: *Self, tx: *Db.Tx, scope: anytype, kind: []const u8, payload: []const u8, at: contract.Enqueue) !?contract.Id {
            _ = self;
            return insertOn(tx, scope, kind, payload, at);
        }

        fn insertOn(on: anytype, scope: anytype, kind: []const u8, payload: []const u8, at: contract.Enqueue) !?contract.Id {
            // An empty key is a real value in the unique index, so it would
            // fold every push that lost its key into the first. Refused
            // before storage, as `job.Memory` does.
            if (at.unique) |u| if (u.len == 0) return error.EmptyUniqueKey;
            const now = at.now orelse nowMicros();
            const values = .{
                .kind = kind,
                .payload = payload,
                .state = contract.State.queued,
                .run_at = at.run_at,
                .lease_until = @as(i64, 0),
                .attempts = @as(i32, 0),
                .priority = @backingInt(at.priority),
                .unique_key = at.unique,
                .last_error = @as(?[]const u8, null),
                .created_at = now,
                .finished_at = @as(?i64, null),
            };
            if (at.unique == null) {
                const row = try on.insert(Row, scope, values);
                return @intCast(row.id);
            }
            const row = try on.insertOrIgnore(Row, scope, values, .{ .kind, .unique_key }) orelse return null;
            return @intCast(row.id);
        }

        /// The claim, narrowed to the kinds this program can run.
        ///
        /// A worker used to claim the most urgent due row whatever its kind,
        /// and hand a kind it did not know back to the queue. That reads as
        /// courtesy and behaves as a spin: the row goes back `queued` with the
        /// `run_at` it already had, so the same worker takes it again on the
        /// next turn of the loop, forever, and each claim bumps `attempts` —
        /// so a row nobody can run is eventually declared dead by the binary
        /// least able to judge it. Narrowing the claim leaves it untouched for
        /// the binary that does know it.
        ///
        /// The kinds are **bound**, not spelled into the statement. The list
        /// is comptime either way, so the statement still has one shape per
        /// program; binding is what lets a kind be named anything a program
        /// already named one — `email:welcome`, `reports/nightly` — instead of
        /// making this change rename rows that are queued under the old name,
        /// which is the very loss ADR 215 is about. Postgres takes the list
        /// as one array; SQLite has no `ANY`, so it takes a run of
        /// placeholders as long as the list.
        fn claimSql(comptime kinds: []const []const u8) []const u8 {
            comptime {
                var narrow: []const u8 = "\"kind\" = ANY(" ++ D.placeholder(3) ++ ")";
                if (!on_postgres) {
                    narrow = "\"kind\" IN (";
                    for (kinds, 0..) |_, i| narrow = narrow ++ (if (i == 0) "" else ", ") ++ D.placeholder(3 + i);
                    narrow = narrow ++ ")";
                }
                return "UPDATE \"nilo_jobs\" SET \"state\" = 'running', \"lease_until\" = " ++ D.placeholder(2) ++
                    ", \"attempts\" = \"attempts\" + 1 WHERE \"id\" = (SELECT \"id\" FROM \"nilo_jobs\" WHERE " ++
                    narrow ++ " AND (" ++
                    "(\"state\" = 'queued' AND \"run_at\" <= " ++ D.placeholder(1) ++ ") OR " ++
                    "(\"state\" = 'running' AND \"lease_until\" <= " ++ D.placeholder(1) ++ ")) " ++
                    "ORDER BY \"priority\", \"run_at\" LIMIT 1" ++ (if (on_postgres) " FOR UPDATE SKIP LOCKED" else "") ++ ") " ++
                    "RETURNING \"id\", \"kind\", \"payload\", \"state\", \"run_at\", \"lease_until\", \"attempts\", " ++
                    "\"priority\", \"unique_key\", \"last_error\", \"created_at\", \"finished_at\"";
            }
        }

        /// `now`, `lease_until`, then the kinds: one array on Postgres, one
        /// parameter each on SQLite.
        fn ClaimArgs(comptime n: usize) type {
            return if (on_postgres) struct { i64, i64, []const []const u8 } else @Tuple(&([_]type{ i64, i64 } ++ @as([n]type, @splat([]const u8))));
        }

        pub fn claim(self: *Self, scope: anytype, comptime kinds: []const []const u8, now: i64, lease_until: i64) !?contract.Claimed {
            if (kinds.len == 0) return null;
            var args: ClaimArgs(kinds.len) = undefined;
            args[0] = now;
            args[1] = lease_until;
            if (comptime on_postgres) {
                args[2] = kinds;
            } else {
                inline for (kinds, 0..) |k, i| args[2 + i] = k;
            }
            const row = try self.db.rawOne(Row, scope, comptime claimSql(kinds), args) orelse return null;
            return .{
                .id = @intCast(row.id),
                .kind = row.kind,
                .payload = row.payload,
                .attempts = @intCast(row.attempts),
                .run_at = row.run_at,
            };
        }

        /// The four calls a worker makes about the row it holds are **fenced
        /// on the claim**: `state = 'running' AND attempts = ?`, with the
        /// number the claim handed back. A worker whose lease lapsed finds the
        /// row claimed again at a higher number, and its late answer then
        /// matches nothing rather than freeing, requeuing or killing a row a
        /// second worker holds. `false` is that: no row was changed
        /// (ADR 160, `contract.zig`).
        pub fn done(self: *Self, scope: anytype, id: contract.Id, attempts: u32, now: i64) !bool {
            return doneOn(self.db, scope, id, attempts, now);
        }

        fn doneOn(on: anytype, scope: anytype, id: contract.Id, attempts: u32, now: i64) !bool {
            const n = try on.update(Row, scope, .{
                .set = .{ .state = contract.State.done, .lease_until = @as(i64, 0), .unique_key = null, .finished_at = now },
                .where = fence(id, attempts),
            });
            return n == 1;
        }

        // -- transactional completion (ADR 160) ---------------------------------

        /// The Db this table sits on, for a `Jobs` that has to tell a `run`'s
        /// `*Db` from its `*Db.Tx` without naming `nilo_sql`.
        pub const Database = Db;

        /// The transaction type a `run` asks for by pointer to be given one.
        pub const Tx = Db.Tx;

        /// Whether every write in the program goes through one connection,
        /// which is SQLite: a transaction that writes then holds all of them
        /// for as long as it is open, so a `Jobs` asks the kind to say how
        /// long that may be.
        pub const single_writer = !on_postgres;

        /// How many connections the Db holds, for the check that a queue
        /// does not start with as many workers as connections. SQLite's pool
        /// is at least two (one writer and a reader, `sql/sqlite.zig`), so
        /// the number is what the pool will really hold and not the
        /// option as written.
        pub fn poolSize(self: *Self) u32 {
            return if (on_postgres) self.db.opts.size else @max(self.db.opts.size, 2);
        }

        /// Begin the transaction a transactional run works in. The Db's own
        /// `begin` with its defaults: read committed on Postgres, and
        /// `BEGIN IMMEDIATE` on SQLite, which takes the writer at once and so
        /// never fails later on an upgrade from reader to writer.
        pub fn begin(self: *Self, scope: anytype) !Db.Tx {
            return self.db.begin(scope, .{});
        }

        /// `done`, inside the transaction the run wrote in, so the run's
        /// writes and the row's `done` commit together or not at all. The
        /// fence is the same one: `false` means the lease lapsed and a second
        /// worker holds the row now, and the caller rolls back rather than
        /// commit a copy of work another claim is doing.
        pub fn doneIn(self: *Self, tx: *Db.Tx, scope: anytype, id: contract.Id, attempts: u32, now: i64) !bool {
            _ = self;
            return doneOn(tx, scope, id, attempts, now);
        }

        pub fn retry(self: *Self, scope: anytype, id: contract.Id, attempts: u32, run_at: i64, err: []const u8) !bool {
            const n = try self.db.update(Row, scope, .{
                .set = .{ .state = contract.State.queued, .lease_until = @as(i64, 0), .run_at = run_at, .last_error = err },
                .where = fence(id, attempts),
            });
            return n == 1;
        }

        pub fn dead(self: *Self, scope: anytype, id: contract.Id, attempts: u32, err: []const u8, now: i64) !bool {
            const n = try self.db.update(Row, scope, .{
                .set = .{ .state = contract.State.dead, .lease_until = @as(i64, 0), .unique_key = null, .last_error = err, .finished_at = now },
                .where = fence(id, attempts),
            });
            return n == 1;
        }

        /// The running row's `unique_key` goes to NULL and the row stays
        /// running, the way a finished row's does, so the key is free for
        /// the next tick of a schedule that queues over a run (ADR 161).
        pub fn unkey(self: *Self, scope: anytype, id: contract.Id, attempts: u32) !bool {
            const n = try self.db.update(Row, scope, .{
                .set = .{ .unique_key = null },
                .where = fence(id, attempts),
            });
            return n == 1;
        }

        pub fn release(self: *Self, scope: anytype, id: contract.Id, attempts: u32) !bool {
            const n = try self.db.update(Row, scope, .{
                .set = .{ .state = contract.State.queued, .lease_until = @as(i64, 0), .attempts = .{ .minus = 1 } },
                .where = fence(id, attempts),
            });
            return n == 1;
        }

        fn fence(id: contract.Id, attempts: u32) struct { id: i64, state: contract.State, attempts: i32 } {
            return .{ .id = @intCast(id), .state = contract.State.running, .attempts = @intCast(attempts) };
        }

        pub fn stats(self: *Self, scope: anytype) !contract.Stats {
            return .{
                .queued = @intCast(try self.db.count(Row, scope, .{ .where = .{ .state = contract.State.queued } })),
                .running = @intCast(try self.db.count(Row, scope, .{ .where = .{ .state = contract.State.running } })),
                .dead = @intCast(try self.db.count(Row, scope, .{ .where = .{ .state = contract.State.dead } })),
            };
        }

        /// The hundred newest dead rows.
        pub fn deadOnes(self: *Self, scope: anytype) ![]contract.Dead {
            const rows = try self.db.select(Row, scope, .{
                .where = .{ .state = contract.State.dead },
                .order = .{ .id = .desc },
                .limit = 100,
            });
            const out = try scope.arena().alloc(contract.Dead, rows.len);
            for (rows, out) |r, *o| o.* = .{
                .id = @intCast(r.id),
                .kind = r.kind,
                .attempts = @intCast(r.attempts),
                .err = r.last_error orelse "",
            };
            return out;
        }

        /// Queue a dead row again from its first attempt: `false` when no dead
        /// row has that id, and `error.Scheduled` when its kind is one of
        /// `scheduled_kinds`, because a dead tick's successor is already
        /// queued and reviving it would run the kind on two chains. **Call
        /// `Jobs.retryDead`, which knows the kinds**; a caller driving this
        /// directly passes them.
        ///
        /// The kind is read before the revive and not in the same statement,
        /// which is sound because a row's kind never changes and the revive
        /// still requires `state = 'dead'`, so two callers reviving the same
        /// row see one `true`. With no scheduled kind there is no read.
        ///
        /// **The revived row has no unique key.** It was set to NULL when the
        /// row died, and restoring it would need a column to keep it in, a
        /// migration for every `Table` user for a rare manual operation, so a
        /// newer row pushed under the same key can run beside it
        /// (`docs/decided.md`).
        pub fn retryDead(self: *Self, scope: anytype, id: contract.Id, now: i64, comptime scheduled_kinds: []const []const u8) !bool {
            if (comptime scheduled_kinds.len > 0) {
                const rows = try self.db.select(Row, scope, .{
                    .where = .{ .id = @as(i64, @intCast(id)), .state = contract.State.dead },
                    .limit = 1,
                });
                if (rows.len == 0) return false;
                inline for (scheduled_kinds) |k| {
                    if (std.mem.eql(u8, rows[0].kind, k)) return error.Scheduled;
                }
            }
            const n = try self.db.update(Row, scope, .{
                .set = .{ .state = contract.State.queued, .run_at = now, .attempts = @as(i32, 0), .last_error = null, .finished_at = null },
                .where = .{ .id = @as(i64, @intCast(id)), .state = contract.State.dead },
            });
            return n == 1;
        }

        /// Delete a `queued` row before it runs: `true` when one went, and
        /// `false` when the row is running, finished or absent — one
        /// statement, so a worker that claims it in the same instant is
        /// the one that wins, and the row is then its to finish
        /// ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
        pub fn cancel(self: *Self, scope: anytype, id: contract.Id) !bool {
            const n = try self.db.delete(Row, scope, .{
                .where = .{ .id = @as(i64, @intCast(id)), .state = contract.State.queued },
            });
            return n == 1;
        }

        /// Delete rows that finished before `before`. Not called by a `Jobs`;
        /// a program that wants the table to stay small runs this from a
        /// scheduled job of its own, which is the same loop everything else
        /// runs in.
        pub fn sweep(self: *Self, scope: anytype, before: i64) !usize {
            return self.db.delete(Row, scope, .{
                .where = .{ .state = contract.State.done, .finished_at = .{ .lt = before } },
            });
        }

        /// Delete rows that went dead before `before`: how many went. **Not
        /// part of `sweep`**, because a dead row is the evidence of a failure
        /// and a program that swept it by accident has lost the record; this
        /// one is asked for by name, from the same scheduled job. Dead rows
        /// are counted by `stats` and listed by `deadOnes` until it runs.
        /// `job.Memory` has the same method on the same moment
        /// ([ADR 160](../docs/adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)).
        pub fn sweepDead(self: *Self, scope: anytype, before: i64) !usize {
            return self.db.delete(Row, scope, .{
                .where = .{ .state = contract.State.dead, .finished_at = .{ .lt = before } },
            });
        }

        const nowMicros = core.nowMicros;
    };
}
