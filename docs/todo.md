# To do

Every concrete item still open, each small enough to be one change, in one list ranked by how much it matters. Where the framework as a whole is heading is [`roadmap.md`](./roadmap.md): an entry that serves one of its directions says so on a `Direction:` line, and the roadmap lists it from there. Once something is built its entry leaves this file: what shipped is in [`CHANGELOG.md`](../CHANGELOG.md), what was measured and learned on the way is in [`history.md`](./history.md), and the decisions that are binding are in [`adr/`](./adr/). What nilo has decided *not* to do, and the questions that have been answered so they are not asked again, are in [`decided.md`](./decided.md). The risks that have no mechanism under them yet are in [`risks.md`](./risks.md#open).

What this document is measured against is [ADR 014](./adr/014-what-nilo-borrows-and-from-whom.md): **the signature is the whole contract**, on a server whose memory you can put a number on. A feature that does not serve one of those two is not automatically refused, but it has to say what it is for.

[How this file is written](#how-this-file-is-written) is at the bottom, and it is the part to read before adding to it.

## How to read this

**One list in four tiers, by how much an entry costs the people who use nilo or the project's own development, never by who has asked for it and never by what kind of finding it is.** A narrow defect a probe reproduced is not above a trap every user meets because it is easier to prove. A caller is evidence, but not the only evidence and not a reason to wait: an entry whose cost is on the record is ranked by the cost, and nothing here sits still because nobody has written in about it.

| Tier | What is in it |
|---|---|
| [**P0**](#p0-blocks-the-next-release) | blocks the next release: a crash or a panic a request can reach, memory read after it is freed, data lost, a wrong answer with no error, or something handed to a stranger |
| [**P1**](#p1-a-large-cost-and-a-real-one) | a cost that is large and real, to users or to the project: a trap that compiles and gives a wrong answer to the users of a common feature, a shipped feature that does not do its job, an outage a common action causes in production, a cost on a hard axis, a design many later things will be built on ([principle 5](../CLAUDE.md#guiding-principles)), or a suspicion one probe settles that would be P0 if true. Its bold claim says who meets it and what happens to them |
| [**P2**](#p2-a-real-cost-and-a-smaller-one) | a real cost, and a smaller one: fewer users meet it, a way round it is on record, or it is below P1's line. It is work that is meant to be done. **Every defect the code was checked for is at least here**, however small, because a defect taken off the list is found again by the next audit |
| [**P3**](#p3-what-may-cost-users-kept-in-view) | not work put off for later: something important that may cost users and has no evidence yet that it does, kept so it is not forgotten. Its closing line names the sign that would raise it. A feature somebody might like and a number nobody would act on are not P3 |

**A small thing nobody needs now is not on the list at all**, in any tier. It is deleted rather than deferred: git keeps the text, [`bench/result/`](../bench/result/) keeps any number behind it, and when it is needed it is written again with the evidence that made it needed. A defect is never one of these.

Inside a tier, entries sit under their module, because **two modules touch no file in common** ([ADR 038](./adr/038-a-module-sits-where-the-loop-puts-it.md)): two entries under different modules can be worked at the same time, by two people or by one person on two days. Every entry closes with what it needs: `Needs:` when the shape of the work is known and something is missing (the fix, a decision, a design, somebody else's commit), `What would settle it:` when the entry is a question or a number. **A box** means a benchmark machine rather than the shared two-core vCPU most of the numbers so far were taken on; **an afternoon** is a run on the machine at hand.

**Where the defects came from.** Most were found by audits that read a module's code against its design page and checked every finding in the code: `http/` at `39896d2`, `sql/` at `cb45ea9`, and `cache/`, `job/` and `s3/` at `1738286`. The `nilo_sql` entries on statements that work and are refused were reproduced by a probe that fails at `462d84d`, in Debug and ReleaseSafe, against Postgres 18 where Postgres is named; elsewhere **reproduced** marks an entry that was also run. **A fix lands with a probe**: a test that fails on the code before it, in both modes, written first and kept. A claim an ADR makes that the code does not keep is corrected in that ADR with the fix, not before.

**An entry waiting on somebody else's repository is the line to distrust.** This repository has been wrong about a blocker seven times, and each time the code it was waiting for already did the thing ([history](./history.md)): the latest was the pg.zig pin, whose two commits had reached lalinsky's `master` while the pull request that asked for them sat open. Nothing downstream ever re-tests a blocker, so each such entry names the pin it was last checked at, and is re-tested before it is repeated.

**Ranked at 0.7.0.** The tiers were last set against the code and the numbers at that version, by what each entry costs ([ADR 255](./adr/255-the-todo-list-is-ranked-by-evidence-and-the-roadmap-is-written-from-it.md)), and [rule 9](#how-this-file-is-written) says when they are set again.

---

## P0: blocks the next release

Nothing is open at this tier.

---

## P1: a large cost, and a real one

Nothing is open at this tier.

---

## P2: a real cost, and a smaller one

### Every module

**The public surface has not been read back against the reference, except for `nilo_fetch`'s.** 1.0 freezes what a dependent may write, and nothing yet checks that every `pub` in a module is on its page in `docs/reference/`, or that every name on a page is still `pub`. Found by reading, a name that should not be public is a break before 1.0 and a promise after it.

**Needs:** the read-back, one module at a time, and a decision on each name the code and the page disagree about: document it, or take it out of the surface.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

### `nilo_config`

**Settings that are not scalars: a list, and a group switched on by presence.** A field is text, a number, a `bool`, an enum or any of those in `?`, and the port of a service with real deployment rules found what that leaves out: a comma-separated list (`PROMOTED_ATTRIBUTES=a,b`); a group of settings that turns on when one variable is present (`DURABLE_ENDPOINT` set means `DURABLE_BUCKET` and `DURABLE_REGION` are now required, inheriting what the file set); and two spellings of `bool` in one program. The first two would be a list type and a "set by presence" section in `Read(T)`. The third is not proposed: `bool` is `true` or `false` and nothing else, and the module keeps its four `Reason`s ([the reference](./reference/config.md#failure)). The program reads its rules by hand today, about sixty lines tested case by case, and says what it gains from the module only for the scalars.

**Needs:** the shape drawn from two programs and not from one: the port's rules, and a second program's written out, which can be one of the examples here.

### `nilo_pw`

**The Cost floor only weighs memory.** `Cost.floor_memory_kib` refuses anything under 7 MiB, which is OWASP's weakest published configuration. But that configuration is 7 MiB *and five passes*, and `.{ .memory_kib = 7 * 1024, .passes = 1 }` is a quarter of the work and compiles. A floor on `memory_kib * passes` would catch it, and would also refuse this repository's own test Cost, which is how the suite affords two optimize modes ([ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

**Needs:** a way of being cheap in a test suite that is not also a way of being cheap in production.

### `nilo_fetch`

**An `https://` call cannot go through an egress proxy, because `std.http.Client` cannot start TLS inside its tunnel.** `Settings.proxy` carries `http://` calls and refuses an `https://` one with `error.TlsThroughProxy` ([ADR 267](./adr/267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md)), and a network whose only way out is a proxy is mostly a network of HTTPS. Reading `std.http.Client.connect` and `connectProxied` at 0.17.0: the tunnel is a `CONNECT` on a connection created with the proxy's protocol, not the target's, so the request that follows is sent as text to a server expecting a handshake, and `Connection.Tls.create`, the one piece that would wrap the tunnel, is private. This is a reading, not a run: the fetch tests have no TLS server.

**Needs:** a `CONNECT` proxy and a TLS server in the test suite to run it against (the proxy half is a few lines of the canned server); then either the fix upstream in std (a report, with the two functions above named), or `nilo_fetch` building the tunnel and the TLS client itself with `std.crypto.tls.Client` and handing std a connection it can read, which is a fork of the client and is weighed against ADR 017's size axis before it is written.

### `nilo_job`

**A schedule is UTC.** `0 3 * * *` is three in the morning in Greenwich, and a program in Jakarta writes `0 20 * * *` with a comment. A time zone is a table of rules that changes twice a year and a dependency to carry it. A zone with daylight saving also has an hour each year that never happens and one that happens twice, so `0 2 * * *` in `Europe/Berlin` needs an answer to both; Vixie cron runs a skipped tick right after the jump and a repeated one once. Go embeds the whole database with `time/tzdata` (about 450 KB), and Rust's `chrono-tz` compiles it in with a filter for the zones a program names.

**Needs:** tzdata without a dependency: the rules for the zones a program names, embedded while compiling, priced on the binary axis; and the skipped and repeated hour answered by a declaration a kind in such a zone must make, the way `overlap` and `missed` are ([ADR 161](./adr/161-a-schedule-is-a-type-that-makes-the-caller-choose.md)).

**Direction:** [A queue needs no second system](./roadmap.md#a-queue-needs-no-second-system)

**A job whose work is a write to the same database cannot commit the write and its `done` together, so a crash between the two does the work again.** Delivery is at least once, and `done` is its own statement after `run` returns (`job/table.zig:227`). A run that inserts a row and loses its process before `done` is claimed again when its lease passes and inserts the row a second time; the reference's answer is a `run` safe to call twice, which for a write means a unique key of the caller's own on every table a job touches. river closes it for this case with `JobCompleteTx`: the row is marked done inside the transaction that does the work, so both commit or neither does. The fence it needs is already here: `done` matches `state = 'running' AND attempts = ?` (`:221`), so a worker whose lease lapsed would find its `done` matching nothing and roll back rather than commit a second copy. What it costs is a pool connection held for the whole of `run`.

**Needs:** a `run` that asks for a `*Db.Tx` given one, with the row's `done` written in it before the commit and a `done` that matches nothing rolling it back; a Refusal on `job.Memory`; a failed `run` rolled back and then retried as now; the connection held for the length of `run` stated in [ADR 160](./adr/160-a-queue-is-a-table-in-the-database-you-already-have.md); and a live test in which a lease lapses mid-run and the late transaction commits nothing.

**Direction:** [A queue needs no second system](./roadmap.md#a-queue-needs-no-second-system)

**A kind cannot say how many of it run at once, so a job that calls a rate-limited service either takes every worker or waits inside one.** `workers` bounds the whole queue (`job.Settings`), and the reference's answer for a limit per kind is a `nilo.Gate` inside `run`, which waits while holding its worker: four rows of a kind gated to one leave three workers parked on the Gate and the other kinds unserved. river gives each queue its own `MaxWorkers`, and asynq weights its queues. The claim already names the kinds it takes (`kind IN (…)`, [ADR 215](./adr/215-a-worker-claims-only-what-it-can-run.md)), so a kind at its limit can be left out of the claim rather than taken and parked.

**Needs:** `pub const max_running` on a kind, held per process by leaving a full kind out of the claim; on SQLite, where the kinds are one parameter each and their count is fixed while compiling, a full kind sent as a name no row has; and whether a limit across instances is wanted, which is a count inside the claim and costs every claim.

**Direction:** [A queue needs no second system](./roadmap.md#a-queue-needs-no-second-system)

**`within` remembers a push in one process, so the same push sent to two instances inside the window runs twice.** `.within` takes any value with `putIfAbsent` and `del` (`job/job.zig:481`), and the only one that exists is a `cache.Space`, which is per instance. `unique` still holds across instances while the first row is queued or running, because it is an index in the table; the window after it finishes is the part that does not, and a rolling deploy is two instances. river keeps that window in the table (`UniqueOpts.ByPeriod`), and asynq in Redis.

**Needs:** `sql.Replays` ([ADR 268](./adr/268-an-answer-kept-for-a-retry-is-a-row-when-instances-share-a-database.md)) has the two calls `within` asks for, `putIfAbsentFor` and `del`, but takes the Scope first (`takes_scope`) and can fail, which `job/job.zig`'s window does not allow for; so either `.within` learns that shape the way `Idempotent` did and a failed claim runs the push (a window is a convenience, not a promise), or the unique key is kept past `done` in `nilo_jobs` for a kind that asks. Whichever is chosen, `job/` still names no `nilo_sql`.

**Direction:** [A second instance changes no answer](./roadmap.md#a-second-instance-changes-no-answer)

### `nilo_sql`

**The SQLite half has no live test against contention.** The Wire's own tests run one process, so the case the reader and writer split exists for has a design and no test: two writers meeting, `busy_timeout` expiring, `Locked` coming back.

**Needs:** a harness — a build step that stands up a second writer, which here is a second process on the same file rather than a socket.

**A `Date` read through `db.raw` or a composed statement checks only that the value is four bytes wide.** A typed read knows its column is a `date` from the schema, but `tx.raw(Row, "SELECT n FROM t")` with `n int4` into a `Date` field reads the integer as a count of days since 2000, and says nothing. Checking the column's type OID (1082) would refuse it, and would also refuse a domain over `date`, which reaches the client under its own OID.

**Needs:** the OID checked with domains resolved to their base type, or the gap written into `db.raw`'s reference as the caller's to hold.

**The plan check calls a column certainly NULL where it cannot be, and misses one that always is.** Postgres keeps `Left` for a `LEFT JOIN` through a `NOT NULL REFERENCES` key and under a filter that is not strict, such as `coalesce(o.name, '') <> ''`, and `plan.zig` refuses both, where [ADR 233](./adr/233-a-raw-statement-is-held-against-its-row-the-first-time-it-runs.md) promises only what is certain; an `Anti` join, `LEFT JOIN … WHERE o.id IS NULL`, outputs NULL on every row and is not flagged.

**Needs:** the wording made "may", or those cases recognised, and `Anti` handled.

**Migration steps and their words disagree with what runs.** ADR 240 calls five seconds the longest a migration can stall a table; `lock_timeout` bounds each acquisition, so a version over ten tables can hold the first for the sum of the rest. On SQLite a `Locked` version names `.lock_timeout_ms` and 5000 ms (`migrate.zig:2436`), where `busy_timeout_ms` is what applied. `expect` is called one query (`migrate.zig:26`, ADR 123) and is `ensureLedger`'s four round trips and a lock before it. `Kind.data`'s comment (`migrate.zig:574`) places a backfill between two steps `generate` never writes as a pair. An `ADD COLUMN` with an enum's `CHECK` reads every row under `ACCESS EXCLUSIVE` and its `why` does not say so (`migrate.zig:1001`).

**Needs:** each sentence made true, and the enum check's `why` saying what it reads.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**`reset` and `squash` are missing from the migrations, and they are the debt that forward-only creates.** `generate`, `check`, `status`, `migrate` and `verify` ship ([ADR 123](./adr/123-a-migration-is-a-diff-against-a-snapshot.md)); `push` and `pull` — the SQLite and the rescue cases — are the other two that do not. There is no `down`, so a developer whose laptop database is in a state no version describes has nothing to type, and a project three years in has four hundred version files every CI run reads. Skipping them does not remove that pain, it moves it onto somebody's laptop and into somebody's build. `squash` is the harder half: it has to leave the ledger of every database that already ran the old versions alone, which means writing a new first version that is only ever applied to a database that has applied nothing.

**Needs:** what `squash` writes into the ledger of a database that is already past it. Rewriting rows is out — that is the thing `verify` exists to catch.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**Nothing reports how the pool is doing.** `app.metrics` counts requests, statuses and durations ([ADR 079](./adr/079-the-route-table-is-the-registry.md)); a `Db` counts nothing. Connections in use, how long a caller waited for one, statements run, and how many the pool threw away are the questions an operator asks first when a service slows down, and the last of them is already reachable — `postgres.dirtyConnections()` parses it out of pg.zig's own metrics text and is marked test-facing because nothing else reveals it.

**Needs:** a shape that does not become a second metrics registry. `app.metrics` is the shape and a `Db` is a Service, which knows nothing about an App — so where the numbers meet is the question, not how to count them.

**A Row over an attached SQLite database has nowhere to `ATTACH` it.** A schema in `nilo_table` means an attached database there ([ADR 055](./adr/055-the-second-dialect-is-the-test-of-the-seam.md)), and `ATTACH` is per connection — but the Wire holds a writer and a pool of readers, opens them itself, and `db.exec("ATTACH …")` reaches the writer alone. The introspection then asks a reader that has never heard the name, which is how the test for the schema-qualified `sqlite_master` found this: it attaches on every `conns[i].handle` by hand, and a program cannot.

**Needs:** a statement list run on every connection at open — which is also where a `PRAGMA` of the caller's own would go.

**A case-folding unique made before `text_pattern_ops` keeps the index `istarts_with` cannot read.** The migrator compares a unique `ignoring_case` and not its operator class, so an existing database never gets the new index and its prefix search still scans on Postgres.

**Needs:** the operator class in the snapshot's index and a step that rebuilds it, or a `db check` finding that names it.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**On SQLite, only a unique can serve `istarts_with`.** A `.unique` with `.ignoring_case` is a `NOCASE` index, and a plain `.index` is a `BINARY` one, which a folding `LIKE` cannot read a range off; a prefix search over a column that is not unique reads every row ([sql.md §21](../bench/result/sql.md#21-where-a-prefix-pattern-is-built)).

**Needs:** an `.index` entry that ignores case, `COLLATE NOCASE` on SQLite and `lower(…)` on Postgres, and what the diff does with one that changes.

**A transaction that loses a serialization or deadlock race is retried by hand.** Both come back as `error.RolledBack`, and `live.zig` shows the loop every caller writes around it. A runner that takes the transaction's body and a bound is the shape the rest of the module would expect.

**Needs:** whether the body is a function or a struct with a `run`, and where the bound lives.

**A limit that comes from a request has no type that bounds it.** Every handler writes `@min(q.limit, 100)`, and a handler that forgets hands the database whatever the request said: a negative limit is refused now, a large one is not. A `sql.Limit(100)` a query struct could hold would carry the bound into the type and be refused past it with a 400.

**Needs:** which module it belongs in, since the 400 is `nilo_http`'s and the statement is this one's.

**A table cannot be renamed, and a foreign key has no `ON UPDATE`.** A renamed table is a drop and a create, which loses its rows; `.was` on `nilo_table` is the word columns already have. Only `ON DELETE` is expressible.

**Needs:** `.was` on `nilo_table` read by the diff as a rename, and `ON UPDATE` beside `ON DELETE`, the rename first because its failure is data.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**The SQLite rebuild is a recipe in a Problem rather than a step.** A column type or a key SQLite cannot `ALTER` is answered with four statements to run by hand, and a list of what to make again after them. The diff knows everything the rebuild needs: create, copy, drop, rename, then indexes, triggers and views.

**Needs:** how a generated rebuild is shown in the plan, since it is the one step that copies every row.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**`expect` compares the ledger's head only, and the startup check reads columns only.** A version missing from the middle of the ledger, from a twin run by hand, is not noticed, and neither is a ledger row no version in the chain describes. A table whose indexes, uniques, foreign keys or defaults differ from its Row passes the startup check, which is how the `addMissingColumns` defect above went unseen.

**Needs:** what each costs at boot, since both read the catalogue once more.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**Migrations write more statements, and take more locks, than the change needs.** Two column changes on one table are two `ALTER TABLE`s (`migrate.zig:1084`, `ddl.zig:494`), so `int4` to `int8` on two columns rewrites the table and rebuilds its indexes twice, and a `SET NOT NULL` beside them scans it again, all under `ACCESS EXCLUSIVE`; Postgres takes them as one statement with commas. `createMissing` sends its DDL on every boot (`migrate.zig:2057`): `CREATE INDEX IF NOT EXISTS` takes its table's SHARE lock before it finds the index there, and `CREATE OR REPLACE` takes a trigger's or view's lock, in one transaction with no `lock_timeout`, so each boot queues behind running writes and holds new ones behind it.

**Needs:** a table's column steps joined into one statement where Postgres allows it, and whether `createMissing` reads the catalog first or is bounded like a version.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**`.min` and `.max` over an enum answer differently on the two databases.** Postgres orders an enum by its declaration and SQLite by its text, so the same grouped Row names a different label on each, with no error.

**Needs:** a refusal on SQLite, or the SQLite column ordered by the enum's position.

**Case folding outside ASCII differs between the two databases.** SQLite's `LIKE` and `NOCASE` fold ASCII only (`dialect.zig:1110`, `:1199`); Postgres's `ILIKE` and `lower()` fold Unicode (`:613`). `.ieq = "ÉLISE@x.id"` matches `élise@x.id` on Postgres and not on SQLite, and a `NOCASE` unique keeps both. ADR 055 asks for a difference like this to be refused or written down, and the reference says only that SQLite folds ASCII.

**Needs:** whether the SQLite half is refused for non-ASCII text or the difference is written on both pages.

**`Tx` repeats `Db` body by body.** Twenty-eight of `Tx`'s methods (`db.zig:2563` to `:2923`, about 360 lines) copy `Db`'s, differing in `self.db`, `&self.inner` for `null`, and `"tx."` for `"db."`. Opening a result and telling the watcher on failure is written out six times (`:1009`, `:1606`, `:3231`, `:3363`, `:3425`, `:3579`). `raw`, `rawOne` and `rawExactlyOne` repeat their scalar and Row branches on both types (`:1664` to `:1820`, `:2756` to `:2866`), and the four `rawPage` bodies are near copies (`:1850`, `:2871`). One private body per operation taking `tx: ?*W.Tx` and the call's name removes about 350 lines, and halves the instantiations each call site costs.

**Needs:** a yes.

**`ddl.zig` writes most statements twice, once while compiling and once at run time.** `addColumn` and `columnClause`, `writeLiteral` and `valueList`, `writeCheckIdent` and `checkName`, `createTrigger` and `triggerStatement`, `createView` and `viewStatement`, `createExtension` and `createExtensionIfMissing` are pairs, and `addColumn` already disagrees with `columnClause`. The desired side is comptime whole, so only a drop or rename, whose name comes from the snapshot, needs the run-time writer. About 150 lines.

**Needs:** a yes.

**Helpers are copied between files.** A backticked name list is written seven times (`shape.zig:673`, `where.zig:1498`, `table.zig:1293`, `row.zig:220`, `:950`, `:1266`, `statement.zig:568`); an unordered set comparison three (`statement.zig:1507`, `db.zig:395`, `table.zig:202`); `columnTuple` is `tupleOf` (`statement.zig:1520`, `db.zig:415`); `writtenValue` is `fieldValue` (`statement.zig:2147`, `where.zig:1676`); `relation` is `relationOf` (`statement.zig:122`, `where.zig:1490`); `snapshot.sameSchema` is `table.sameSchema`; the SQL literal escape is in `ddl.zig:770` and `migrations.zig:670`; and an optional is unwrapped by an inline `switch` 33 times across ten files. Inside `migrate.zig`, `findUnique`, `findIndex`, `findReference` and `findNamed`, and the six `carried*` and `renamed*` functions, are one generic each. In `shape.zig`, `parentLink` and `backLink`, and `throughColumn` and `throughOf`, resolve the same path twice, and the second pair is where the `.through` defect above came from. A direction with its `NULLS` is written in three places (`shape.zig:1331`, `:1531`, `statement.zig:2125`). About 400 lines in all, with name helpers in `row.zig` and type helpers in `types.zig`, which every file already imports.

**Needs:** a yes.

**Whether `describe` pays five round trips on every raw call behind a pooler.** `DEALLOCATE nilo_describe` is sent after the `ROLLBACK` (`postgres.zig:1476`), in a transaction of its own, which pgbouncer in transaction mode may route to another server connection. The statement is left behind on the first, the next describe there fails on `42P05`, and `vetRaw` (`db.zig:770`) keeps trying. ADR 233 says it costs a round trip only while the statement beside it is failing too.

**What would settle it:** a run behind pgbouncer in transaction mode, or the `DEALLOCATE` sent before the `ROLLBACK`.

### `nilo_http`

**The test `Client` accepts a request head of any size.** Its reader is `Reader.fixed` over the whole request, and `readHead` refuses a head only once it fills the buffer, so a test sending a large cookie or many headers passes where a server answers 431. Its cookie jar also keeps a cookie deleted by `Expires` alone and ignores the `__Host-` and `__Secure-` rules a browser applies.

**Needs:** the test reader given the server's read-buffer size, and the jar honouring a past `Expires` and the two prefixes.

**One rule, one function: the audit's largest source of defects is a decision written in several places that stopped agreeing.** Whether a field may be absent is now one comptime rule (`http/field.zig`), and a number described in a query and not in JSON is still open. Path prefixes are matched three ways (`middleware.underPrefix`, `static.underPrefix`, the router) and disagree on `//` and on a param, which is how `useOn` came to skip a `*` route until the chain was resolved per request for one. A JSON string is written by `json.zig` and again by `writeFailureBody`, and only one checks UTF-8. `If-None-Match`, `If-Range` and `Range` are answered in `serve.zig`, `sendfile.zig` and through `Versioned`. `fieldList` exists twice with different output. Each is a fix that closes its defects for good, where a patch to each copy closes them until the next copy.

**Needs:** the shape of each shared piece decided — one prefix matcher the router's split defines, one JSON string writer, one conditional-request ladder — and the order, which the defects suggest: the prefix matcher next.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

**A gRPC stop test fails when the machine is busy, so a red gate can be a false one.** `a server stop that lands in a burst of calls ends the connection promptly` (`http/grpc_live.zig`) asserts the stop took under 2.5 s against handlers that sleep 4 s. It failed once in a `test-all -Dsql` on the shared two-core vCPU, while the gate's other compilations ran beside it, and the same test binary then passed three runs out of three on the idle machine. A bound measured on wall time is a bound on the scheduler as much as on the stop.

**Needs:** an assertion that does not race the scheduler: the stop observed as the connection closing before any `Hang` handler returns, rather than a wall-clock figure, or a margin derived from the handlers' 4 s that a loaded machine cannot reach.

**A WebSocket over TLS has no test of its own for a second frame that arrived with the first.** `Wake.wait` answers `.readable` while the record layer holds ciphertext or decrypted bytes ([`bench/result/http.md`](../bench/result/http.md#what-offering-h2-to-a-browser-costs)), which a WebSocket's `park` waits in too, so the stall the HTTP/2 connection over TLS showed (one in a thousand) is closed for it by the same line. The test that holds it is HTTP/2's, `grpc_tls_live.zig`; `tls_live.zig` has no WebSocket test, so a change to how `park` waits could lose it unseen.

**What would settle it:** a live test in `tls_live.zig` sending two WebSocket frames in one TLS write and timing the second.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**A message's `bytes` field is text in its JSON, where protobuf's JSON mapping makes it base64.** A message read or written as JSON is nilo's JSON ([ADR 256](./adr/256-a-body-is-read-as-what-its-type-says.md)), so a `[]const u8` declared `.bytes` in its `wire` table goes out as the bytes themselves and is read back the same way. A Connect client speaking JSON sends and expects base64 there, and the two would disagree without either refusing. Field names and 64-bit integers do not have the problem: a Connect client reads both of nilo's spellings.

**What would settle it:** a decision between writing a `.bytes` field as base64 in a message's JSON, with the document saying so, and refusing JSON for a message that has one; either held by a test with a Connect client's bytes.

**A module header's code example is not compiled, so one can rot.** A `//!` block in `http/*.zig` and the other modules shows a call in a fenced `zig` block, and `zig build snippets` reads only Markdown pages (ADR 068): the header of `middleware.zig` and ADR 008 both showed `std.time.Timer`, which Zig 0.16 removed, for as long as nobody compiled them. About sixty headers carry such a block, and many use `…` or a type the shared world does not declare.

**Needs:** `Snippets.read` in `build.zig` reading a `.zig` file's `//!` lines as the page it is (the `<!-- compiles -->` mark and the fence are the same), a row in `pages` for each header whose example is rewritten to compile, and `unlisted` looking in `http/` for a mark nothing reads; and the choice of how many of the sixty are worth the rewrite.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

**Nothing tells a handler its client has gone.** `error.Canceled` comes from a shutdown or from one of the deadlines the Engine sets; a client closing its connection in the middle of a handler produces neither, so the work runs to the end and the response is written into a socket nobody is reading. The other half of this — cutting a slow handler off — is `nilo.deadline(ms)` ([ADR 105](./adr/105-a-route-can-say-how-long-it-has.md)). This half is not simply unbuilt: **the obvious implementation is wrong.** A read-side EOF is not "the client left" — a client that sent `Connection: close` and then `shutdown(SHUT_WR)` produces exactly that and is still waiting for its response, so answering "peer gone" from it would abandon correct requests. Gin gets the disconnect from `net/http` for nothing; Fiber does not have it either.

**Needs:** two named signals rather than one flag — "the client half-closed and is waiting" and "the socket is gone". What is already real is a write that fails, and a handler sees that today.

**A rule a build step holds against the patterns the audit kept finding.** Three of the four kinds of defect are spellable: `catch {}` and `else => {}` that swallow `error.Canceled` or `EndOfStream` on a connection path (the stop that waits, the upload that looks complete, the middleware's empty 200); `unreachable`, `std.debug.assert` and `catch unreachable` on a path a request reaches (`Room.print`, `Ctx.send`, `sayerFor`, `idempotentBegin`), each a remote panic in ReleaseSafe and undefined behaviour in ReleaseFast; and a module header's code example that no longer compiles. The fourth kind, a comment or ADR claiming what the code does not do, a dozen of them, has no mechanism but probes. A step that refuses the three in `http/` unless the line carries a marked reason makes the next one a build failure rather than an audit finding.

**Needs:** the decision on how a justified case is marked (a comment tag, or a list in `build.zig` the way `layers` is), and whether the step starts as a report over today's tree or as a refusal with the existing cases listed.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

**A mutation pass over the request path.** The `nilo_sql` audit found what reading could not by changing one comparison or deleting one check and seeing which change no test noticed (`57c8bbb`); `http/` has not had one. `http1.zig`, `router.zig`, `middleware.zig` and `serve.zig` are where a survivor costs most, and the fuzzers and the llhttp differential ([ADR 231](./adr/231-a-second-parser-reads-what-the-first-one-reads.md)) cover the parser's bytes, not the dispatch's decisions.

**Needs:** the run, one file at a time because a run is the whole `zig build test`, and a test for each mutation that survives.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

**A tagged union cannot be a handler's body argument (feedback from the photon port).** photon's alert rule condition is one of several shapes picked by a field (`{"signal": "metrics", ...}`). Inside a struct it reads, answers named 400s and gets a `oneOf` with a `discriminator` in the API description; as the whole body, `fn create(cond: Condition)` is refused with "nilo does not recognise", so the handler takes a `*Ctx` and calls `c.json(Condition)`, and the description loses the body. The 400s for a top-level union already match the nested ones (`describeBadBody` hands it to `describeTagged`); the typed argument and its schema are what is missing.

**Needs:** the rule that makes a union value argument the body (the one struct a route takes today, widened to an internally tagged union), its description through the `oneOf` and `discriminator` the nested case already renders (ADR 016), and a refusal for a union nilo cannot tell apart while reading (no tag field).

**A TLS listener that reloads its certificate without a restart.** `listen(.{ .tls = … })` reads the two files once ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md)), and a certificate that renews every sixty days is a restart every sixty days. The shape that costs nothing per connection is a second `CertKeyPair` swapped in under the acceptors on a signal or a file's mtime, with the old one freed once the last handshake that took it is over, which is a count the Engine does not keep yet.

**Needs:** the swap built behind a signal, with the count of handshakes still holding the old pair, and its cost on the idle axis stated. Until then `certbot --deploy-hook 'systemctl restart …'` is the answer.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**A gRPC listener answers unary calls only.** A call with a second message is refused as `INTERNAL` ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md)). Server, client and bidirectional streaming are the shape that holds a fiber and its stack for the whole call, and the shape a unary call goes through (one request handed over whole, one answer collected whole) has no place for a second message; a streaming method would be a handler that reads and writes messages on the stream, much as a WebSocket handler does its frames.

**Needs:** the shape the roadmap's stream direction designs, and the per-stream figure for a stream held open measured the way `bench/mem.py --hold` measures an HTTP/1.1 one.

**Direction:** [A stream is one shape](./roadmap.md#a-stream-is-one-shape)

**A gRPC listener has no health service, and the guide does not say how to write one.** Kubernetes' gRPC probe and most load balancers call `grpc.health.v1.Health/Check`, which is an ordinary route under [ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md) and nothing documents; server reflection, which `grpcurl` wants, is not on record either way.

**Needs:** a guide section showing `grpc.health.v1.Health/Check` as an ordinary route, and a decision on server reflection.

**Multipart, streamed: an upload holds the whole body in the arena, so a route raised to `maxBody(50 << 20)` holds up to 50 MB for each upload in flight.** `Form(T)` reads a multipart body whole, bounded only by `max_body` ([ADR 030](./adr/030-a-form-is-the-body-read-by-another-rule.md)), which is right for a form with a photo in it and wrong for a 2 GB video. Every Go and Rust framework compared bounds the memory instead (read in each one's source): Go's `ReadForm`, and so Gin and Echo, keeps a file in memory up to 32 MB and writes the rest to a temp file, Fiber through fasthttp at 16 MB; actix-multipart's and Rocket's `TempFile` stream a file to disk as it arrives, actix under two budgets, a total and a memory one (50 MiB and 2 MiB); axum hands each field to the handler as a stream; poem spools every upload to disk however small. actix declares a limit per field on the type (`#[multipart(limit = "2 KiB")]`) and Rocket per extension (`file/jpg`). The streaming version wants a parser that resumes across reads; an `Upload` that is bytes in the arena up to a threshold and a file past it; `saveTo` a rename where it can be, because Rocket's `persist_to` fails across filesystems and falls back to a copy; a limit per field declared on the field; and every limit counted on the bytes that arrive, not on `Content-Length`, since poem's `SizeLimit` reads only the header and refuses a chunked body. It inherits nothing from `sendfile`, because sending is a descriptor handed to the kernel and receiving is a parser holding its place.

**What would settle it:** a design held to ADR 017's axes, saying the arena's high-water mark per upload and where the parser's state sits while the fiber parks ([ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md)), with the threshold and the temp directory as options. Until then the answer is `c.bodyStream()`, which holds nothing and makes the framing the handler's problem, or `bucket.presignPost` ([ADR 112](./adr/112-a-browser-uploads-with-a-form-rather-than-a-link.md)), which keeps the bytes off the server.

**Direction:** [A stream is one shape](./roadmap.md#a-stream-is-one-shape)

**Should a JSON body be refused when the request says it is something else?** `Ctx.json` parses whatever `Content-Type` came, while `Form(T)` refuses the wrong one, so a cross-site `<form enctype="text/plain">` can deliver valid JSON with no preflight, which matters to an app with a cookie sent cross-site and no `nilo.csrf`. A 415 is safer and breaks a client that sends JSON unlabelled.

**What would settle it:** a decision between a 415 for a present non-JSON type and an absent one allowed, or the gap written into the CSRF guide as the reason `nilo.csrf` exists.

**A call that cannot wait could run on the connection's fiber, and a prototype doubled a gRPC server's calls a second at 256 connections and took its worst call from 0.9 to 1.1 s down to 0.12 to 0.15.** In a scratch build a call whose stream has ended (a gRPC call is deferred until its message has) ran at once on the connection's fiber, with a turn-stamp guard that sends the connection's later calls to fibers once one parked: `nilo-grpc` at 256 connections 2.43M and 2.49M requests a second against 1.23M and 1.30M with the fiber reuse, p99 13 ms against 46 to 50, worst call 28 to 34 ms against 177 to 214; at 1,024 connections 1.40M and 1.87M against 0.95M and 1.08M, p99 70 to 76 ms against 507 to 519; a routed `GET` at `-m 10` 5% less CPU than the reuse; `-m 1` unchanged ([`http.md`](../bench/result/http.md#what-running-a-call-on-the-connections-fiber-would-buy-on-http2-and-what-the-head-built-for-the-app-costs)). It is not shippable as built: a call that parks stops the connection reading for as long as it parks, which ADR 260 refuses, a connection holds 60 bytes more idle, and the prototype stopped the existing suite at a test that expects a call to be running while its message is incomplete. The same run shows that the tail of the entry above is the cost of running calls long after their frames were parsed, not only zio's queue.

**What would settle it:** a decision on how a route is known not to wait (a typed handler whose service arguments do not wait, declared by the types of `nilo_sql`, `nilo_fetch`, `nilo_s3` and `cache`, with the guard as the net and a flag on the route), the revision of ADR 260's refusal that follows, the 60 bytes given back by an idle release of the connection's stack, and the same runs against it. It touches `typed.zig`, so it waits for that file to be free.

**What a stop does to the calls a reused HTTP/2 fiber has queued has no test that fails without it.** A fiber that finishes a call takes the next one waiting ([ADR 260](./adr/260-a-request-on-http2-runs-from-its-headers.md)), and three things keep that safe at a stop: a yield hands its cancel back instead of swallowing it (zio's `yield` consumes a pending cancel, shown by a standalone zio program and not by a test here), the calls still queued when a stop is requested are turned away rather than run, and a spawn that fails at a stop answers every queued call. The test "a server stop that lands in a burst of calls ends the connection promptly" in `http/grpc_live.zig` passes with all three taken out, because the window is microseconds wide, and the fallback for `InvalidPlacement` (a work-stealing configuration) is not run by any test, because the suite cannot build one ([`http.md`](../bench/result/http.md#a-fiber-that-finishes-a-call-takes-the-next-one-waiting)). The change was reviewed once; the review of the fixes it asked for was not finished.

**What would settle it:** a test that places the stop: a handler that blocks on a flag until `app.shutdown()` has been requested, so the calls behind it are known to be queued when the stop lands, seen to fail with each of the three taken out; and a second review of `h2conn.zig`'s `runner`, `finishNext`, `rendezvous` and `spawnRunner`.

**The `-Dhttp2` build parked 64 bytes under a page boundary when it was last read, and which commit gave the `-Dtls` build its page back is not known.** The `-Dtls` plain listener held a second page (4,109 bytes a connection) at `514e8c1` and holds one at `1e583bc`, 4,692 bytes, with `park-check` pinning every build at one page ([`http.md`](../bench/result/http.md#a-tls-builds-plain-listener-holds-one-page), [ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md)). Nobody has bisected what moved it, so nothing says it will stay moved, and the depths (2,505 default, 2,729 with `-Dhttp2`, against a boundary at 2,793) were read before that change. The pooling question sits beside it: arguments under zio's 384-byte pool size would take 115 bytes more off an HTTP/1.1 connection and cost an h2c one about 390, and why is not known.

**What would settle it:** the stack depth at the release printed again in the `park-check` program for each of the four builds, and the commit between `514e8c1` and `1e583bc` that moved the `-Dtls` one found by bisecting `park-check -Dtls`; `gdb` on an h2c connection's task allocation under the pooled arguments. A day.

**Direction:** [Every byte an idle connection holds is on the record](./roadmap.md#every-byte-an-idle-connection-holds-is-on-the-record)

**An idle HTTP/1.1 connection that has no fiber costs about 700 to 770 bytes in a prototype, where one with a fiber costs 4,678, and nothing about it is decided.** A connection past the idle peek ends its fiber and is a 512-byte record behind a poll; a reader fiber spawns it a fiber again when its socket is readable. 1,000 connections read 1,479 bytes, 10,000 read 892 and 843, and a busy connection and a wake after 300 ms of think time both measure level with the fiber build ([`http.md`](../bench/result/http.md#a-prototype-an-idle-http11-connection-with-no-fiber)); the first request after a quiet spell is 5 to 13 µs slower at the median. It reads that low only because the prototype sets zio's stack pool to shrink every second (at the default 60 s it reads 4,919 once the pool has decayed, 9,351 before), leaves out TLS, HTTP/2, the idle deadline and the shutdown of parked connections, and changes the Waker's table ([ADR 001](./adr/001-zio-as-the-engine-behind-the-bulkhead.md), [ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md), [ADR 017](./adr/017-the-trade-budget-has-four-axes.md)). It would close the TLS connection's second page for a plain request/response connection and leave a WebSocket and a held stream exactly as ADR 062 describes them.

**What would settle it:** a decision on the design in [`spike/fiberless-idle/`](../spike/fiberless-idle/README.md) (its `design-note.md`); then a prototype with the idle deadline, the shutdown list, a reactor per executor and a TLS connection whose state is on the heap, read with `bench/mem.py --tls` and `bench/release.py`, and `zig build test-all` passing on it.

**Direction:** [Every byte an idle connection holds is on the record](./roadmap.md#every-byte-an-idle-connection-holds-is-on-the-record)

**22% of `std.flate`'s CPU on a 4 KB body is a buffer rebuilt after every block, and it has not been filed upstream.** `toks.* = .empty` in `writeBlock` rebuilds the 96 KB token buffer from its constant after every block, where assigning the fields one by one gives byte-identical output 18% to 44% faster ([`http.md`](../bench/result/http.md#which-deflate-is-fastest-and-whether-brotli-or-zstd-would-beat-it)). ADR 211 refuses a fork of `Compress.zig`.

**Needs:** the issue filed against zig, `lib/std/compress/flate/Compress.zig` lines 987 and 1055. Last checked at 0.17.0, where both lines are unchanged.

**The HttpArena entry still gzips with `std.flate`, so its `json-comp` profile pays for the compressor `-Dlibdeflate` replaced.** The copy the board runs pins `224a507`, on Zig 0.16 and zio 0.18.0, and builds without the flag ([ADR 248](./adr/248-gzip-is-libdeflate-when-a-build-asks-for-it.md)). Its last reading, on 2026-09-23, is 270k req/s at 4,096 and at 16,384 connections, 1,346 bytes a response ([the board's result file](https://github.com/MDA2AV/HttpArena/blob/5809ff76adb98e1f822445734c62ad20ae3e7b9b/site/data/results/nilo.json)). On the profile's own bodies libdeflate 6 is 2.5 to 4 times faster than `std.flate` 6 and 2% smaller ([`http.md`](../bench/result/http.md#libdeflate-against-stdflate-on-a-quiet-zen-5-and-what-it-keeps-resident)), and the model there puts the profile's score near 1.95 times the entry's, a figure never checked against the board.

**Needs:** the entry moved to a commit built with `-Dlibdeflate`, which also moves its Dockerfile to Zig 0.17, and `json-comp` run locally against the pin it replaces, interleaved, before the pull request; the reading goes to `bench/result/http.md`.

**Whether zio 0.19 lowers the CPU nilo spends a request on HttpArena's fixed-rate profiles has not been measured.** Those profiles hold the rate and score the CPU it took, and the entry's last reading, on zio 0.18.0, is 33.7 µs a request on `latency-10k` (19th of 101 entries, the lowest at 24.1), 31.2 µs on `latency-1m` (15th of 48, the lowest at 22.5) and 78.0 µs on `8gbit` (29th of 83, the lowest at 43.6); `baseline` spent 66.4 cores for 2.96M req/s, about 22.4 µs a request ([the board's result files](https://github.com/MDA2AV/HttpArena/tree/5809ff76adb98e1f822445734c62ad20ae3e7b9b/site/data/results)). At 10k req/s the request work is nearly nothing, so `latency-10k`'s figure is the standing cost of a running server. zio 0.19.0's release notes say idle executors park sooner and the event loop takes fewer syscalls and atomics, and main now builds zio 0.19 with `.pinned` scheduling ([ADR 199](./adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md)); what either did to these four figures is unknown, and so is what is left once they are counted.

**What would settle it:** the entry at main and at `224a507` built the same way and run interleaved through `latency-10k`, `latency-1m` and `baseline` on one machine, CPU a request read from the cgroup as the board reads it; then, if a gap to the lowest entries is left, a profile of the idle server naming where its CPU goes.

**The TLS pin is a fork, `nevindra/tls.zig`, until two commits reach upstream's `main`.** It is upstream's `main`, the Zig 0.17 line, plus two commits: one signs an RSA key through its CRT form, 13.7 ms of handshake CPU down to 2.6 ([the run](../bench/result/http.md#what-an-rsa-certificate-costs-a-handshake)), and one adds the server's `offload` option, which runs the signature off the executor ([ADR 217](./adr/217-a-handshakes-signature-is-computed-off-the-executor.md)). The first was merged into `zig-0.16.x` as #59 and not into `main`. Once both merge into `main`, the pin moves to upstream's commit and the fork is not used again.

**Needs:** [ianic/tls.zig#61](https://github.com/ianic/tls.zig/pull/61) and [#62](https://github.com/ianic/tls.zig/pull/62) merged. Last checked at `1d1dda2`.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**The pg.zig pin is a fork, `nevindra/pg.zig`, until its Zig 0.17 port reaches lalinsky's.** lalinsky's `master` builds its tls.zig on 0.17 and nothing else of it: the driver still reads `@typeInfo` the 0.16 way, its metrics.zig pin reads `b.args`, and xsync calls a `mutexLock` that 0.17 made cancelable. The fork is that `master` plus one commit, and points at a fork of xsync with one commit of its own. `test-sql` passes on it, the live Postgres tests included.

**Needs:** [lalinsky/pg.zig#23](https://github.com/lalinsky/pg.zig/pull/23) and [lalinsky/xsync.zig#1](https://github.com/lalinsky/xsync.zig/pull/1) merged. Last checked at `c205ebd`.

**Should a 500 from a fail function carry its message to the client?** `fail.internal("…")` sends what it is given (`http/fail.zig:186`, `http/serve.zig:1350`), as Go's `http.Error` does, while an unnamed error that reaches the mapping table becomes `internal server error`. A message written for the operator, `fail.internal("db: {s}", .{@errorName(e)})`, then reaches whoever asked. The guide now says so; what is open is whether the safer default is a 500 that never says what broke, with the message logged instead.

**What would settle it:** a decision, in ADR 004, between sending the message and logging it for a 500.

**`allowance` keeps its table in the process and has no seam for a shared one**, so N instances admit N times the limit ([ADR 092](./adr/092-an-allowance-is-a-table-sized-while-compiling.md), [ADR 110](./adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)). express-rate-limit and the Go limiters take a Redis store. A table sized while compiling is right for one process; what is missing is where a second store would plug in.

**Needs:** a store the table can be swapped for, designed against `nilo_redis` once it exists and a Postgres counter before then, with its cost per request on the routes that ask.

**Direction:** [A second instance changes no answer](./roadmap.md#a-second-instance-changes-no-answer)

**A Room belongs to one process and has no hook a bridge could use, so a chat served from two instances is two chats.** The toolkit direction in the roadmap names this case as what would show `nilo_redis`. What `http/` owes it is the hook: a `say` that a bridge also sees, and a `deliver` it can call with a message that arrived from elsewhere, at one null check per `say` when nothing is bridged. socket.io's Redis adapter and a gorilla hub over pub/sub are what a migrant has used.

**Needs:** the hook, designed together with the first bridge (Postgres `LISTEN/NOTIFY` or `nilo_redis`, whichever the roadmap's measurement picks).

**Direction:** [A second instance changes no answer](./roadmap.md#a-second-instance-changes-no-answer)

**A failure is one sentence, so a client cannot mark the field that failed.** `nilo_failure(status, message)` is the only hook a failure shape has (`http/failurebody.zig`), and `Bound.fail()` joins every field that failed into one sentence in the 240-byte slot, ending in "and N more" (`http/bound.zig`). A form that wants to outline `email` parses English. [ADR 024](./adr/024-every-failure-answers-as-json.md) refused RFC 7807 (now 9457) `application/problem+json` partly because there was "nothing to put in the fields nilo actually knows"; since [ADR 034](./adr/034-a-binding-hands-its-failures-to-the-handler.md) nilo knows, for every field, its name, what was wrong and what would have worked. A plain `Form(T)` or JSON argument still reports the first field only.

**Needs:** ADR 024 edited: a failure shape that can take the list of fields, copied into the arena on the failure path only, a content type of its own, and every field reported from a plain argument as well as from `Bound`, with the bytes it adds to the failure slot stated.

**Direction:** [A failure is a type](./roadmap.md#a-failure-is-a-type)

**An error from code that does not know about HTTP cannot be given a status once, for the whole App.** `fail.statusFor` is a closed `switch` (`http/fail.zig:213`): `NotFound` is a 404, a dozen parse errors are 400s, and any other error is a 500. A service layer returning `error.EmailTaken` either imports `nilo_http` to call `fail.conflict`, or every handler that calls it repeats the same `catch`. echo's `HTTPErrorHandler`, Fastify's `setErrorHandler` and Nest's exception filters are where Go and Node put that mapping, once. A middleware that catches what `next.run(c)` returns can do it today, and no page says so.

**Needs:** a table the App is given (`app.errors(.{ .{ error.EmailTaken, 409, "that email is taken" } })`, or the shape a design finds better), read before the built-in one, the document naming the statuses a handler's error set shares with it; and a probe of whether an inferred error set can be read at registration on Zig 0.17, which decides whether the document can name them.

**Direction:** [A failure is a type](./roadmap.md#a-failure-is-a-type)

**A handler answers one body type, so a second status with a different shape is a sentence the document never sees.** `Status(code, T)` and `Response(T)` carry one `T`; a 409 with `{"current_version": 7}`, or a 201 beside a 200, is a `fail.*` string or a `*Ctx` route. `decided.md` accepts that "the API description names one failure" and names what reopens it: a shape that states a failure in the type. A `union(enum)` return whose arms are each a `Status(code, T)` is that shape, and Fastify's `response: { 200: A, 409: B }` is what a migrant expects of it.

**Needs:** the union return designed, the document writing one response per arm, and the decided entry taken out when it lands.

**Direction:** [A failure is a type](./roadmap.md#a-failure-is-a-type)

**A JSON body could be read 2.2 to 2.8 times faster by a reader written for its type, with no `std.json.Scanner` under it, and nothing about it is decided.** A prototype that goes from the body's bytes straight to the caller's struct read a plain object in 45 ns where the shipped reader takes 125, and a tagged one in 58 where it takes 150; a whole request with a 13-byte body went from 380 to 300 ns, because the body is about 85 ns of it. Its differential run of 800,000 reads against `std.json` found no input one accepted and the other refused. It costs 3.2 to 3.5 KB in a program that reads JSON and a second JSON grammar that has to agree with std's for ever, which is the cost `jsonmark.zig`'s header names ([`spike/json-reader/`](../spike/json-reader/README.md), [ADR 084](./adr/084-a-number-in-a-request-is-not-a-zig-literal.md)).

**What would settle it:** a decision on the prototype in `spike/json-reader/`; then the three tests it fails on the current tree (two tagged-union refusals and a message's allocation count, named in its README) passing, the differential test made a build step on `test`, the 400 sentences of `ctx.zig` run against it, `use_first` and `use_last` rebuilt, and the compile time of the examples measured before and after.

**The figures of the second HTTP optimisation round were measured with two other benchmarks on the same machine.** The fiber reuse on HTTP/2, the idle connection's 512 bytes, the tagged union read once and the TLS page margin were each timed under a shared lock and pinned to their own cores, but beside builds and tests that shared the L3; the first round's figures were measured again serially before they went on the record, and these were not ([`http.md`](../bench/result/http.md#a-fiber-that-finishes-a-call-takes-the-next-one-waiting), [`http.md`](../bench/result/http.md#a-tagged-union-is-read-once-when-its-tag-comes-first)). The idle bytes are counts, not timings, and do not depend on it.

**What would settle it:** the `h2load -m 10` rows, the gRPC rows at 32 to 1,024 connections and the tagged-union profile rows run again on a quiet machine, before (`514e8c1`) against after, interleaved, each binary from one path.

**The metrics page takes one number a name: no labels, no histogram of the application's own, no process series, and counters nilo keeps already go unpublished.** `app.expose(name, .counter, &n)` or `.gauge` (`http/app.zig:1255`). "Orders by status" is three names, a business latency cannot be written at all, resident memory and open descriptors are missing, and the cache's hit counts, the watchdog's catches and the tracer's drops are numbers nobody scrapes. prom-client and the Go client give all of it.

**What would settle it:** a design for a labelled family whose labels are an enum, so the series are closed while compiling the way routes are ([ADR 079](./adr/079-the-route-table-is-the-registry.md)), and a histogram whose buckets are fixed at registration, each with its cost per increment.

**Signing in with an identity provider is put together by hand, and the steps it needs are the ones that fail silently.** [ADR 111](./adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md) stops at verifying the ID token. Discovery, `state`, PKCE, the code exchange and the `nonce` are the caller's, and leaving any one out still signs the user in. Every part is here (`nilo_fetch`, `jwt.Verifier`, `Session(T)`, `c.entropy`), so what is missing is the order, and ADR 111's own reason for owning verification, that being wrong is silent, holds for the order too. `golang.org/x/oauth2` with go-oidc and passport are the habit.

**What would settle it:** a decision on extending ADR 111 to the code flow, and if so a start route and a callback argument whose state lives in a short-lived sealed cookie.

**The multipart parser is the one parser of untrusted bytes that no fuzzer reaches.** `zig build fuzz` sends request heads and `--frames` sends HTTP/2 frames, and neither builds a multipart body (`http/fuzz.zig` names none). `parseMultipart` (`http/form.zig:615`) is slicing by hand over the body, where a slip is a panic a request reaches in ReleaseSafe and undefined behaviour in ReleaseFast, and the one defect found in it so far, a search for a blank line to the end of the body once per part, was found by the audit at `39896d2` rather than by a run.

**Needs:** a `--forms` mode generating multipart bodies (a boundary inside a file, bare LF, a part never closed, quoted and unquoted parameters, `filename*`, part counts either side of `max_parts`) that checks each is a `Fields` whose slices lie inside the body or a 400, never a panic.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

**Nobody who writes Go or Node services has yet built a service with nilo from the getting-started page, so the traps this direction closed are closed on paper.** `Path(T)`, typed middleware, the one log sink, `Bearer(T)`, the deadline that reaches the toolkit, `nilo.app` and the startup warnings each have tests, and each test was written by the people who built it. The direction's own closing condition is a reader who did not: every mistake they make is either a compile error or a refusal at `listen()` naming the fix, or it is the next entry here.

**What would settle it:** a person who has written Go or Node services and not nilo builds `examples/rest` again from `docs/guide/getting-started.md` with a database, a login middleware and a container, and their mistakes are written down, each either refused in a sentence or filed.

**Direction:** [A developer from Go or Node meets no silent trap in the first week](./roadmap.md#a-developer-from-go-or-node-meets-no-silent-trap-in-the-first-week)

---

## P3: what may cost users, kept in view

### `nilo_cache`

**The shard lock spins on a write and never backs off.** `while (l.held.swap(true, .acquire))` (`store.zig:371`) bounces the line between waiting cores, and a holder preempted by the OS leaves the waiters burning their timeslice; the module's own soak tests run more threads than cores. The refusal path also takes the lock only to bump an atomic counter (`store.zig:1107`). Not measured.

**Needs:** test-and-test-and-set with a yield after some spins, the refusal's lock dropped, and both measured under contention.

### `nilo_jwt`

**Only 2048, 3072 and 4096 bits of RSA, and only P-256 of EC.** A key size with no branch is `error.KeySizeNotSupported` and a curve with none is `error.CurveNotSupported`, rather than a best effort. ES384 is the same twenty lines over `EcdsaP384Sha384`; ES512 wants P-521, which std does not carry; Ed25519 (`EdDSA`) is a different key type again.

**Needs:** an issuer that publishes one, which none in the comparison does.

**A service that calls an API asking for a JWT it signed itself has nothing here to sign one with.** [ADR 111](./adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md) refuses signing because a server issuing its own sessions has `Session(T)`, and that holds for every client of its own, bearer ones included (the P2 entry on a session as a bearer token). It does not hold when the verifier is somebody else: a Google service account's assertion and a GitHub App's token are RS256, APNs and Sign in with Apple's `client_secret` are ES256, a LiveKit access token is HS256. Signing alone widens nothing `verify` checks, as long as `verify` keeps refusing `HS256`. ES256 and HS256 are std's `EcdsaP256Sha256` and `HmacSha256`; RS256 is not, because std 0.17 carries RSA verification only, so it would be private-key arithmetic this module says it does not write.

**What would settle it:** a program that calls such an API, brought with which algorithm it asks for; ES256 or HS256 first, and RS256 only with a reason to own the RSA it needs.

**Direction:** [The toolkit grows by the jobs people have](./roadmap.md#the-toolkit-grows-by-the-jobs-people-have)

**Whether a token with no `aud` can be checked by the claim that does name the application.** `audience = .unchecked` is what a Cognito access token (`client_id`), a Clerk session token and a Keycloak token for a user with no client role (`azp`) need, and the check then moves to the caller's own `Claims`. A by-name claim check inside `nilo_jwt` would parse the payload into a `std.json.Value` tree on every verify, an allocation on the request path ([ADR 017](./adr/017-the-trade-budget-has-four-axes.md)).

**What would settle it:** a measured allocation count for a registered-claims struct with one extra optional field, or a caller who forgot the comparison in their `Claims` and shipped it.

### `nilo_fetch`

**`nilo_fetch` speaks HTTP/1.1 only, so a service that answers gRPC cannot call one.** The server half of HTTP/2 is built ([ADR 259](./adr/259-http2-is-a-framing-of-every-request.md)); a client connection carrying many calls is on the record nowhere. grpc-go and connect-go do both halves.

**What would settle it:** a caller of a gRPC service, and the idle bytes of an outbound HTTP/2 connection measured before it ships.

**Whether a `Target` should stop calling a service that is failing, rather than wait out its timeout on every call.** A `Target`'s `max_in_flight` is a bulkhead: it bounds how many calls wait on a sick service, but each still waits its whole `timeout_ms`, and the handler behind it holds its fiber and its stack meanwhile ([ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md)). A breaker answers at once while the service is down; sony/gobreaker and failsafe-go are what a Go migrant used. A retry budget takes away much of the reason for one, because it stops the load multiplying, so this stays open until the budget has met an outage.

**What would settle it:** a service behind a `Target` timing out for a minute under load, with the retry budget built, measured for the fibers and bytes the waiting calls hold; and if that number is the problem, a breaker per `Target`, opt-in, its state in the type's value, answering `error.CircuitOpen` and shown by `nilo_ready`.

**A streamed call cannot be made through a `Target`, and when one can, a `.stream` body under a `.retry` has to be a compile error.** `Exchange.begin` takes a client and a URL, so a target's standing headers, its gate and its `.retry` do not reach a streamed call ([ADR 061](./adr/061-a-fitting-borrows-the-loop.md)). [ADR 271](./adr/271-a-retry-is-the-callers-numbers-and-nilos-mechanism.md) decided that a reader is spent by the first try and so is never retried, and the Refusal that says it has nothing to refuse until a call can carry both: today the guard is that `nilo_s3` routes none of its reader-taking calls through the retry loop, held by a test.

**Needs:** a caller who streams from a service that has standing headers; then the call on `Target`, with the Refusal beside it (a file in `fetch/refusals/` and a row in its table), written together.

**Direction:** [A call to another service survives that service's bad minute](./roadmap.md#a-call-to-another-service-survives-that-services-bad-minute)

**A route's deadline does not bound the wait for a `nilo_fetch` permit, nor the credential source's `fetch_timeout_ms`.** A call's own timeout and its dial take the shorter of their bound and the route's (ADR 105), but `client.gate.wait` queues before either, so a saturated client holds a request past its deadline.

**What would settle it:** a test with a client whose permits are all taken, under a route deadline shorter than the queue's wait.

**`nilo_fetch` lays out a unix socket's `Connection` by hand, because `std.http.Client.connectUnix` does not compile at 0.17.0.** It names `std.posix.SocketError`, which is gone, and a pool API that has moved, and the `Plain.create` that a connection is built through is private; lazy analysis hides all of it until something calls it. So `Exchange.dialUnix` dials `std.Io.net.UnixAddress` and builds the `Connection` the way `Plain` does, behind a `@compileError` that fires on any Zig but 0.17 ([ADR 272](./adr/272-a-call-names-the-socket-it-goes-over.md)). A std that changes the layout without changing the version would free the wrong bytes; the tests free under the testing allocator, which is what would notice.

**Needs:** `connectUnix` fixed upstream (its `ConnectUnixError` and its call into the pool), or a std release where it builds; then `dialUnix` and its version pin go. Last checked at 0.17.0.

**`nilo_fetch` has no WebSocket client, so a service that consumes a feed (prices, a chat platform's gateway) brings a library of its own.** The frame code is in `http/websocket.zig`, which `nilo_fetch` may not import ([ADR 038](./adr/038-a-module-sits-where-the-loop-puts-it.md)); a second copy is the thing to avoid, and the framing moving to `nilo_core` as something two layers need is the shape that keeps one ([ADR 057](./adr/057-percent-is-needed-by-two-layers.md)). What the others settled: a limit on a message counted in **decoded** bytes (coder/websocket 32 KiB, tungstenite 64 MiB, undici 128 MiB; gorilla's counts frame bytes and has no default, which leaves a compressed message unbounded), a ping answered without the caller (tungstenite queues the pong, awc leaves it to the caller), and a close that waits a bounded time for the other side's (coder/websocket, 5 s).

**Needs:** a caller with a feed to read, and the frame code's home decided before the client is written.

**Direction:** [The toolkit grows by the jobs people have](./roadmap.md#the-toolkit-grows-by-the-jobs-people-have)

**`nilo_fetch` cannot present a client certificate, so it cannot call a service that requires mutual TLS.** `std.crypto.tls.Client` at 0.17.0 has no answer to a `CertificateRequest`; tls.zig, which the listener already uses behind `-Dtls`, takes a key pair on its client. Moving the client to it is the same fork of `std.http.Client`'s connection that the egress-proxy entry weighs, so the two are one decision. reqwest shows the trap to keep out: which `Identity` constructors compile depends on the TLS backend a feature picked. Go's `GetClientCertificate` is the shape for a certificate that rotates.

**Needs:** a caller behind a mesh that requires it, and the client's TLS library settled together with the egress-proxy entry.

### `nilo_job`

**A bulk enqueue may slow every claim, because the claim sorts the whole due backlog.** `ORDER BY priority, run_at LIMIT 1` over `(state, run_at)` sorts every due row; probing each priority on an index of `(state, priority, run_at)` would not, and [ADR 214](./adr/214-a-job-says-how-urgent-it-is.md)'s finding that the wide index is slower was for that one ordering, not for one `ORDER BY run_at LIMIT 1` a priority. The `nilo_job` audit at `1738286` ran both once in a scratch container and wrote nothing down, and `SKIP LOCKED` is refused inside a `UNION ALL`, so the shape is up to three statements or a CTE a priority.

**What would settle it:** both shapes on Postgres at a backlog of 1, 50k and 200k due rows beside 300k done ones, into [`job.md`](../bench/result/job.md), and ADR 214 edited in place with the result. An afternoon.

**A row another process pushed waits up to `poll_ms` for a worker, a second by default, because nothing tells the workers it arrived.** `push` wakes a worker in its own process only, so a web process pushing to a separate worker process reaches it on the next poll, and lowering `poll_ms` buys the latency with one claim per worker per interval on an idle queue (`job.Settings`). river listens on Postgres `LISTEN/NOTIFY` and polls as a fallback. The roadmap already wants a `LISTEN/NOTIFY` listener measured for the Room bridge, and one held connection serving both is the shape to price.

**What would settle it:** a deployment whose web and worker processes are split and whose users wait on a job, and the cost of one held `LISTEN` connection measured beside the poll.

**Direction:** [A queue needs no second system](./roadmap.md#a-queue-needs-no-second-system)

### `nilo_s3`

**A file over 5 GiB, or one sent over a connection that drops, cannot be uploaded from a browser straight to the bucket.** `presignPost` is one POST, which S3 caps at 5 GiB and which starts again from nothing when it fails, and `putMultipart` streams through this process. Uppy's S3 multipart plugin and the AWS SDKs hand the browser a presigned `UploadPart` URL a part, so a large upload resumes from its last part and never touches the server. The server's half is four calls: create the upload, presign a part, list the parts, complete. A presigned part carries no size condition, so the bound has to be checked at completion, from the parts' sizes, before the object exists.

**What would settle it:** a caller whose users upload video or archives from a browser, with the completion-time check designed first.

**A large object is uploaded one part at a time.** `putMultipart` holds one `part_bytes` buffer and one stream share for its whole life ([`s3.md`](./reference/s3.md#bucket-calls)), so it moves at one connection's speed, where the AWS SDK's upload manager sends five parts at once by default. Parts in flight cost a buffer each, 8 MiB times their count. Whether one connection is the bound on a real uplink is not measured.

**What would settle it:** `putMultipart` timed against S3 from a host with more uplink than one connection reaches, with one, two and four parts in flight, into [`s3.md`](../bench/result/s3.md).

### `nilo_sql`

**Whether one request can pay for re-dialling the whole pool after Postgres restarts.** Each connection found hung up is released as failed (`postgres.zig:456`, `giveBack` at `:1519`), and pg.zig dials its replacement inside `release`, synchronously and with cancellation held off. One request can pay the pool's size in TCP, TLS and authentication, and its deadline cannot cut it short.

**What would settle it:** a live test that restarts Postgres under a pool of ten and times the first request after.

**Nobody knows why the arena's `async-db` profile reads 66k req/s with neither the server nor Postgres busy.** It runs at 874% of sixty-four CPUs, 3.9 ms a query for a 0.1 ms scan. Decoding is 116 µs of nilo's 284 µs a request and none of the wait ([`sql.md` §12](../bench/result/sql.md#12-the-arenas-query-at-one-connection)); the suspect is pg.zig's one pool mutex taken twice a request by 1,024 fibers on 64 threads, which two threads cannot convoy. The arena's rerun with stealing off (ADR 199) read 59.7k with the p99 at 245–362 ms from 50, which is what a fiber queued on a mutex that no other thread can now run looks like, and does not yet name the lock ([`http.md`](../bench/result/http.md#the-arenas-two-readings-and-what-changed-between-them)).

**What would settle it:** `bench-sql-server`'s three `/async-db*` routes under `wrk -c1024`, pool 256 then 32, Postgres on `--network host`, on a box.

**What `nilo_sql` costs a dependent's build has no number at all.** Every query is settled while compiling, and ADR 017 has no axis for compile time. Each call site's anonymous literal instantiates its statement, `valuesOf` and `fill`, `Tx` doubles them, and several eval quotas grow with the square of the schema (`table.zig:456`, `:2151`).

**What would settle it:** `bench/result/build.md` extended: a schema of 10, 50 and 100 tables with one and ten call sites a table, cold and after one edit. An afternoon.

**Every SQLite program chooses whether a statement hops or runs in the fiber, with no number to choose by** ([ADR 064](./adr/064-a-file-has-no-socket-to-wait-on.md)). A hop and a cached read both cost a few microseconds, so `.in_fiber` is plausibly faster for a lookup service and fatal for one that scans.

**What would settle it:** both, unloaded and behind the pool ([`sql.md` §2](../bench/result/sql.md) is why both); `bench-sql` has the unloaded `.in_fiber` half, and `bench/sql_server.zig` on a SQLite `Db` is the rest, on a box.

**A route's deadline bounds a `nilo_sql` call up to its first answer, not the rows read after, and Postgres finishes a statement the client gave up on.** The armed bound covers acquiring, `BEGIN`, sending and the first response (ADR 105); rows pulled from a `db.stream` afterwards are not bounded, and no cancel request is sent, so a slow statement keeps its server backend busy after the request has answered 504. And a shutdown that lands in the few instructions between a fired bound's `finish()` and the drain in `armed` is drained with it, because zio's `AutoCancel.check` spends its count and not the pending error it accounts for (`sql/db.zig`).

**What would settle it:** a cancel request sent on a timed-out statement, measured against what it costs a pool connection, a stream's reads bounded by the same deadline, and `AutoCancel.check` clearing the error it accounts for upstream, so the drain can go.

### `nilo_http`

**A gRPC call's latency under load has a spread of 3 to 4 times its median, and one cause is in zio's run queue, which nilo does not own.** At 1,024 connections with 100 streams each the median is 71 ms (what Little's law gives for 102,400 in flight at 1.1M req/s) and p99 430 to 550 ms, with a worst call of 0.84 to 1.07 s against tonic's 1.07 s in the same harness; the 1.4 s and 3.8 s of the first record do not reproduce. zio's ring of 256 tasks moves its oldest half to an overflow queue refilled 64 a tick, so a task's wait follows where it landed and not its age; a ring of 16,384 made p50 110 and p99 115 ms, and cost 25 to 30% of throughput at 1,024 connections ([`http.md`](../bench/result/http.md#where-a-grpc-calls-worst-latency-comes-from)).

**What would settle it:** zio offering a run queue with bounded unfairness (the ring size as an option would do), and a measurement of whether the throughput it costs is worth the tail on a workload with a latency target.

**Whether one acceptor per executor is past the knee on a machine with many threads is not measured there** ([ADR 200](./adr/200-every-executor-accepts.md)). dusty measured 12 and 24 accept loops losing 20–40% on one request per connection against 5, on 24 threads; at 8 threads on the 9700X log2's 3 gained 2–4% there and lost 5–6% at ten requests per connection ([`http.md`](../bench/result/http.md#how-many-acceptors-eight-threads-want)).

**What would settle it:** the same sweep, acceptors at threads, 2×log2 and log2, on 24 threads or more, with one and ten requests per connection, on a box.

**Whether the 32-lane scans hold on aarch64 is not measured.** `scan.lanes` and `json.zig`'s escape scan are 32 lanes, which on aarch64 is two NEON registers, and every head-parsing and JSON figure is from one x86-64 box.

**What would settle it:** `zig build run` and `bench/bench.sh` on the M1 Pro that has already run the cache and the build. An afternoon.

**What a connection inside a request holds now that `read_buffer` is 16 KiB is arithmetic, not a reading.** The idle figure is unchanged by construction (ADR 062 gives the pages back), and the active one is two pages more on paper ([ADR 196](./adr/196-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md)).

**What would settle it:** `bench/mem.py --hold` against `bench-stream-server`, the one server that holds connections mid-request, at 8 and at 16. An afternoon.

**Direction:** [Every byte an idle connection holds is on the record](./roadmap.md#every-byte-an-idle-connection-holds-is-on-the-record)

**A client whose first key share is not X25519 is refused rather than asked again, because the TLS listener has no HelloRetryRequest.** With it, so is a session ticket, which is what the session resumption entry needs to turn a full handshake per reconnection into a resumption.

**Needs:** the same repository. Last checked at `e04ae44`.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**A HEADERS frame on an HTTP/2 stream the connection has already forgotten ends the connection.** A stream at or below the highest id seen and no longer in the table is answered with a connection `PROTOCOL_ERROR` (`h2conn.zig`, `onHeaders`). RFC 9113 §5.1 allows that for a stream closed long ago, but a client's trailers in flight when the server answered early and forgot the stream would take every other stream on the connection down with it. With the dynamic table at 0 the block costs nothing to decode and ignore, which a stream reset but still running already does (stage 6.1).

**What would settle it:** a client seen sending trailers after an early answer. Neither h2spec over TLS (142 of 146, the four constant failures) nor Chromium loading a page of nineteen subresources tripped it.

**Client certificates on a TLS listener.** The library has `client_auth` with a CA bundle and `.require`/`.request`; nothing in `Options.tls` names it, and nothing on `Ctx` would say who the client was. The second half is the design question: a verified subject is request data, so it wants to be a typed argument the way `Session(T)` is, not a header. **The modes are where the others leave a trap**: Go has five (`RequestClientCert` and `RequireAnyClientCert` hand the handler a chain nobody verified, and only `r.TLS.VerifiedChains` is to be believed), rustls has two (`WebPkiClientVerifier`, with `allow_unauthenticated()` turning "require" into "request"), fiber has one (`CertClientFile` forces require-and-verify), and actix reaches the certificate through an `on_connect` downcast to one TLS crate's type at one version. The shape that fits here is the two modes rustls has, a subject that exists only once verified, and nothing that names the library.

**Needs:** the service mesh that wants it, and the answer to what a handler is handed. The client half is the `nilo_fetch` entry on presenting a certificate.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**Session resumption on a TLS listener.** Every connection is a full handshake, about 300 µs of CPU on the machine in [`http.md`](../bench/result/http.md), and a client that reconnects per request pays it per request. The library has no session tickets; when it does, the option is a key to encrypt them with and a lifetime, and the number to re-measure is that one.

**Needs:** the library first (the HelloRetryRequest entry), then a deployment whose clients reconnect and cannot sit behind a proxy.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**A stream is never compressed, and neither is an event stream; and gzip is the only coding.** `app.compress` gzips a whole body on a compressor borrowed for the CPU it takes and handed back before the socket is written, which is what keeps one compressor per thread enough ([ADR 211](./adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)). A stream has no whole body and would hold its compressor across every write, so its shape is a second pool larger than the thread count and chunked framing. **That an event stream must stay out because it must never be buffered is not what the others found**: actix (since actix-http 3.18.12), async-compression under tower-http, gzhttp, Caddy and nginx all compress a stream and flush the compressor with a sync flush whenever the producer stops writing (nginx's `Z_SYNC_FLUSH` on a buffer marked `flush`, actix's flush when the source is pending), which puts each event on the wire whole. What they disagree on is the default: tower-http skips `text/event-stream`, the other four compress it. Each also has a way for one response to opt out (an explicit `Content-Encoding: identity`, gzhttp's `No-Gzip-Compression` header), drops `Accept-Ranges` and `Content-Length`, and weakens or suffixes a strong `ETag`. Brotli and zstd were measured and refused ([`decided.md`](./decided.md)); a faster `std.flate` is the entry waiting on zig.

**Needs:** a caller streaming something text and large enough that the bandwidth matters; then the per-stream compressor's bytes measured, since it is held for the stream's life, and a flush at every `Stream.flush` and every event.

**Direction:** [A stream is one shape](./roadmap.md#a-stream-is-one-shape)

**An answer larger than `arena_keep` costs a request about 54 KB of backing allocation and a quarter of its time, measured in-process only.** `sendJson` starts at `json_hint` and grows, and a 17 KB answer used 54 KB of arena at the default 16 KiB keep, so every request asked the backing allocator again ([`http.md`](../bench/result/http.md#a-json-answer-in-arena-segments-does-not-beat-allocating)). Writing into segments is not the fix: it measured equal to `Allocating` once the arena kept enough. A per-route size hint, the length of the route's last answer, or a larger keep would be.

**What would settle it:** a 17 KB route in `bench/main.zig` through wrk at a keep of 16 KiB and 64 KiB, and with a last-length hint, allocations a request and p99.

**A gRPC connection's message budget is not an option.** The budget is `max_body`, or the largest limit a route raised to with `nilo.maxBody` (at least 64 KiB), and a call is charged its compressed bytes, its inflated copy and the copy its route reads it into, so a Collector sending 4 MB batches gets about two running at a time per connection at `max_body` 16 MiB and the rest wait ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md#what-the-budget-does-to-an-opentelemetry-collector)). Waiting replaced the refusal and made a small budget slow rather than lossy; a budget sized from the caller's batches is what would let more run at once.

**Needs:** a caller whose throughput per connection is held back by how many calls run at once, rather than by its own work, with the batch size and consumer count that show it.

**Request bodies sent as `Content-Encoding: zstd` are a 415.** Only `gzip` is decoded ([the guide](./guide/requests.md#reading-the-body-yourself)), and an OpenTelemetry exporter can send `zstd` as well. Decoding it needs a C library nilo does not carry, and the shape that is already on record is the `-Dlibdeflate` one ([ADR 248](./adr/248-gzip-is-libdeflate-when-a-build-asks-for-it.md)): a build flag, the library compiled `ReleaseFast` from its release tarball so a build without the flag fetches and links none of it, the same `max_body` check against the announced size before a byte is decoded, and the binary cost written into ADR 017's running total. Whether the compiled library is also exported as a module applications can import (one list of libzstd's files to maintain instead of one in every consumer's `build.zig`) is part of that decision. This is the request side only; zstd for responses was measured and refused ([`decided.md`](./decided.md)).

**Needs:** a decision to decode zstd request bodies, and a caller sending them that cannot be told to send gzip; then the flag's cost in stripped `ReleaseFast` bytes and the allocation the decoded body takes, measured the way ADR 248 measured libdeflate.

**A ClientHello split across two records is refused by the TLS listener rather than reassembled** ([tls.zig#36](https://github.com/ianic/tls.zig/issues/36)). Every client ADR 212 tried sends it whole; the one that does not, or a middlebox that fragments, gets a failed handshake rather than a slow one.

**Needs:** [ianic/tls.zig](https://github.com/ianic/tls.zig), `handshake_server.zig`. Last checked at `e04ae44` on `zig-0.16.x`.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**Whether a pre-fork worker mode is worth what it costs is not known.** A parent that forks N workers sharing one listening socket, and starts again one that dies, would shrink a panic to a share of the connections and give the listener takeover `decided.md` asks for. It also makes every Room, cache, allowance and idempotency table one worker's, which is the multi-instance problem inside one host, and multiplies every pool.

**What would settle it:** a prototype, its memory per worker and its restart time measured, set against what the multi-instance direction does to the same tables.

**Direction:** [A second instance changes no answer](./roadmap.md#a-second-instance-changes-no-answer)

**A handler that holds its thread for less than the watchdog's 250 ms is never reported, though every connection dealt to that thread waits behind it** ([ADR 013](./adr/013-handlers-must-not-block-the-thread.md), [ADR 199](./adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md)). Go preempts a goroutine and steals work across threads; a fiber here does neither, which is the design, so the gap is that nothing shows it. The watchdog already measures each stretch.

**What would settle it:** the longest stretch per request kept as a histogram on the metrics page, run against [ADR 017](./adr/017-the-trade-budget-has-four-axes.md)'s 10% line.

**`cors.reading`, `csrf.reading` and `maxBody(&limit)` still point at a container-level `var`.** A typed middleware can take a service now (ADR 008), so a run-time origin list could be a `*const Origins` that `listen()` checks is provided, which would make the `reading` forms redundant; `maxBody` stays a `Limited`, because the gRPC collector reads its limit from the registration (ADR 156).

**Needs:** a decision on whether a deployment fact is a `nilo.Late` value or a service, made once for all three, since ADR 264 chose `Late` for the allowance and the CSP.

**A held `nilo.Late` value, and a `Path(T)` read by a resolver a bare middleware calls through `c.resolve`, are checked at the first request rather than at `listen()`.** A zero count on an allowance or an empty CSP answers 500 until fixed, and a route without the param answers 500 naming the resolver. A typed middleware's needs are held at `listen()` already; a bare one gives `listen()` nothing to read, and no middleware has a hook there.

**Needs:** a hook a middleware can give `listen()`, or a decision that the three cases are enough to leave to the first request.

**A security scheme or a path parameter's type that a resolver or a middleware needs does not reach the API description.** A route whose handler takes `Bearer(T)` is described with `bearerAuth`, and one whose resolver takes it is not; a resolver's `Path(T)` field types do not refine the parameter's schema, which stays text unless the handler's own argument types it.

**What would settle it:** the document read from the same comptime needs `listen()` checks, so a scheme a resolver or a typed middleware requires is on every operation it covers.

**The `RateLimit` and `RateLimit-Policy` fields follow an IETF draft (draft-ietf-httpapi-ratelimit-headers), not an RFC.** A change to the draft's syntax changes `announce` in `http/allowance.zig` and ADR 264.

**What would settle it:** the draft published as an RFC, and the fields checked against it.

**No CI job runs on Linux aarch64 or on Windows**, so the platforms table in the deploying guide calls both untested; CI runs `zig build test` on Linux x86-64 and macOS.

**What would settle it:** a job on an aarch64 runner running `zig build test`, and a decision on whether Windows is supported at all.

**A project started from `template/` is copied out of a release tarball, where Go and Node start from a template repository.** `docs/guide/getting-started.md` fetches `template/` with one `curl | tar` line pinned to a release, and every copy shares one `.fingerprint` until it is renamed (ADR 263).

**Needs:** a decision on a separate `nilo-template` repository generated from `template/` at each release.

## How this file is written

Nine rules. They are why the file has the shape it has, and adding to it means matching them.

**1. Nothing built is in here.** The moment something ships, its entry leaves entirely: no strikethrough, no "**Built**", no account of how it went. What was measured goes to [`history.md`](./history.md), what a reader has to change goes to [`CHANGELOG.md`](../CHANGELOG.md), and the decision goes to an ADR. A gap only *partly* closed keeps one sentence scoping what is left, never a paragraph about the half that landed. **The test is that this file reads top to bottom as work outstanding.**

**2. Nothing decided is in here either.** An answer that is the answer, a question closed so it is not re-derived, a feature refused with its reason, goes to [`decided.md`](./decided.md), and a risk with no mechanism under it yet goes to [`risks.md`](./risks.md#open). This file is what is still open.

**3. An entry is in one tier, by what it costs, and under its module.** The tiers are the table in [How to read this](#how-to-read-this). An entry is ranked by who meets it and what it does to them or to the project, and never by whether somebody has asked or by how it was found. Before an entry is added, ask whether it is needed now: if it is not, and it is neither a defect nor something important that may cost users, it is not added. A module with nothing in a tier has no heading there, because an empty heading says nothing; a tier with nothing in it keeps its heading and says so, because an empty P0 is news.

**4. An entry opens with the whole claim, in bold**, and closes with one line: `Needs:` when the shape of the work is known, `What would settle it:` when the entry is a question or a number. An entry waiting on somebody else's repository names it, and the pin it was last checked at, on that line. Somebody who reads only the bold lines has to come away with the right idea of what is outstanding, and somebody who reads only the closing lines has to know what to bring. Neither is optional and neither is prose.

**5. An entry that serves a roadmap direction says so on one more line**, after its closing one: `**Direction:**` and a link to the direction's heading in [`roadmap.md`](./roadmap.md). `zig build docs-index` writes each direction's list of entries from these lines, and `zig build docs-check` refuses a link to no direction and a list out of step, so an entry that leaves this file leaves the roadmap too. Most entries serve no direction, and that is fine: the roadmap is where the framework is going, not everything that is open.

**6. An entry is at most a screen.** Longer than that means it is an ADR, with an entry here pointing at it. A body of work several entries serve is a direction in the roadmap; the entries stay here.

**7. No checkboxes, no dates, no owners.** A box implies a plan and this is not one. The tier is the only order this file has, and inside a module the entries are in no order at all.

**8. A number carries a link to where it was measured.** [`bench/result/`](../bench/result/) is the record. A figure with no run behind it decays into a claim, and a claim in a roadmap gets planned against, which is worse than a wrong number in a changelog.

**9. The whole list is ranked again at each release.** Cutting one bumps the version in `build.zig.zon`, and `docs-check` refuses this file until its `Ranked at` line names the new one, so the ranking is redone against the numbers `bench/release.py` has just produced. Every entry is read against the tiers again: a P3 whose closing line has come true moves up, an entry the numbers have overtaken moves down, and one that is no longer needed is deleted, unless it is a defect. A P3 that a release has left exactly where it was is given a reason to stay or deleted; a refusal with its reason goes to `decided.md` instead (rule 2).

Adding a module means a heading for it under whichever tiers have entries for it, and nothing else: there is no index to keep in step.
