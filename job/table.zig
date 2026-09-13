//! The queue as a table in the database the program already has
//! ([ADR 0198](../docs/adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md)).
//!
//! `Table(Db)` takes the `nilo_sql` Db *type* and calls `insert`, `update`,
//! `select` and `rawOne` on it — the same nine questions `contract.zig`
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
//!             WHERE (state = 'queued' AND run_at <= $1) OR (state = 'running' AND lease_until <= $1)
//!             ORDER BY run_at LIMIT 1 FOR UPDATE SKIP LOCKED)
//! RETURNING …
//! ```
//!
//! `FOR UPDATE SKIP LOCKED` is what lets several instances share the table:
//! a row one of them is claiming is skipped by the rest rather than waited
//! for. SQLite has no such clause and needs none — it has one writer, so the
//! same statement without it is already serial
//! ([ADR 0074](../docs/adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)).
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

        /// The table. Add it to `db.checking(&.{ … })` and to the migration
        /// beside the program's own rows; nothing here creates it.
        pub const Row = struct {
            pub const nilo_table = .{
                .name = "nilo_jobs",
                .key = .id,
                .unique = .{.{ .kind, .unique_key }},
                .index = .{.{ .state, .run_at }},
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
            const now = at.run_at;
            const values = .{
                .kind = kind,
                .payload = payload,
                .state = contract.State.queued,
                .run_at = at.run_at,
                .lease_until = @as(i64, 0),
                .attempts = @as(i32, 0),
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

        const claim_sql =
            "UPDATE \"nilo_jobs\" SET \"state\" = 'running', \"lease_until\" = " ++ D.placeholder(2) ++
            ", \"attempts\" = \"attempts\" + 1 WHERE \"id\" = (SELECT \"id\" FROM \"nilo_jobs\" WHERE " ++
            "(\"state\" = 'queued' AND \"run_at\" <= " ++ D.placeholder(1) ++ ") OR " ++
            "(\"state\" = 'running' AND \"lease_until\" <= " ++ D.placeholder(1) ++ ") " ++
            "ORDER BY \"run_at\" LIMIT 1" ++ (if (on_postgres) " FOR UPDATE SKIP LOCKED" else "") ++ ") " ++
            "RETURNING \"id\", \"kind\", \"payload\", \"state\", \"run_at\", \"lease_until\", \"attempts\", " ++
            "\"unique_key\", \"last_error\", \"created_at\", \"finished_at\"";

        pub fn claim(self: *Self, scope: anytype, now: i64, lease_until: i64) !?contract.Claimed {
            const row = try self.db.rawOne(Row, scope, claim_sql, .{ now, lease_until }) orelse return null;
            return .{
                .id = @intCast(row.id),
                .kind = row.kind,
                .payload = row.payload,
                .attempts = @intCast(row.attempts),
                .run_at = row.run_at,
            };
        }

        pub fn done(self: *Self, scope: anytype, id: contract.Id) !void {
            _ = try self.db.update(Row, scope, .{
                .set = .{ .state = contract.State.done, .lease_until = @as(i64, 0), .unique_key = null, .finished_at = nowMicros() },
                .where = .{ .id = @as(i64, @intCast(id)) },
            });
        }

        pub fn retry(self: *Self, scope: anytype, id: contract.Id, run_at: i64, err: []const u8) !void {
            _ = try self.db.update(Row, scope, .{
                .set = .{ .state = contract.State.queued, .lease_until = @as(i64, 0), .run_at = run_at, .last_error = err },
                .where = .{ .id = @as(i64, @intCast(id)) },
            });
        }

        pub fn dead(self: *Self, scope: anytype, id: contract.Id, err: []const u8) !void {
            _ = try self.db.update(Row, scope, .{
                .set = .{ .state = contract.State.dead, .lease_until = @as(i64, 0), .unique_key = null, .last_error = err, .finished_at = nowMicros() },
                .where = .{ .id = @as(i64, @intCast(id)) },
            });
        }

        pub fn release(self: *Self, scope: anytype, id: contract.Id) !void {
            _ = try self.db.update(Row, scope, .{
                .set = .{ .state = contract.State.queued, .lease_until = @as(i64, 0), .attempts = .{ .minus = 1 } },
                .where = .{ .id = @as(i64, @intCast(id)), .state = contract.State.running },
            });
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

        pub fn retryDead(self: *Self, scope: anytype, id: contract.Id, now: i64) !bool {
            const n = try self.db.update(Row, scope, .{
                .set = .{ .state = contract.State.queued, .run_at = now, .attempts = @as(i32, 0), .last_error = null, .finished_at = null },
                .where = .{ .id = @as(i64, @intCast(id)), .state = contract.State.dead },
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

        const nowMicros = core.nowMicros;
    };
}
