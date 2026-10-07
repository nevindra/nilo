# To do

Every concrete item still open, each small enough to be one change, in one list ranked by how much it matters. Where the framework as a whole is heading is [`roadmap.md`](./roadmap.md): an entry that serves one of its directions says so on a `Direction:` line, and the roadmap lists it from there. Once something is built its entry leaves this file: what shipped is in [`CHANGELOG.md`](../CHANGELOG.md), what was measured and learned on the way is in [`history.md`](./history.md), and the decisions that are binding are in [`adr/`](./adr/). What nilo has decided *not* to do, and the questions that have been answered so they are not asked again, are in [`decided.md`](./decided.md). The risks that have no mechanism under them yet are in [`risks.md`](./risks.md#open).

What this document is measured against is [ADR 014](./adr/014-what-nilo-borrows-and-from-whom.md): **the signature is the whole contract**, on a server whose memory you can put a number on. A feature that does not serve one of those two is not automatically refused, but it has to say what it is for.

[How this file is written](#how-this-file-is-written) is at the bottom, and it is the part to read before adding to it.

## How to read this

**One list in four tiers, by the evidence that an entry matters, never by who has asked for it.** A caller is evidence, but not the only evidence and not a reason to wait: an entry whose cost is on the record is ranked by the cost, and nothing here sits still because nobody has written in about it.

| Tier | What is in it |
|---|---|
| [**P0**](#p0-blocks-the-next-release) | blocks the next release: a crash or a panic a request can reach, memory read after it is freed, data lost, a wrong answer with no error, or something handed to a stranger |
| [**P1**](#p1-belongs-in-the-next-release) | belongs in the next release: wrong and loud (something that works refused, a migration that fails, a refusal naming the wrong cause); a cost measured on a hard axis, or at least 10% of a path's time, throughput or p99, or a measured multiple against a framework compared; a gap in the gate; a suspicion that one probe settles and that would be P0 or P1 if true; or what the next stage of the roadmap's **Now** direction needs |
| [**P2**](#p2-evidence-it-matters) | evidence that it matters, below those lines: a cost measured under them, a gap every user of a feature meets, a comment or page that says what the code does not do, code to take out, or a number that would move a decision somebody makes today |
| [**P3**](#p3-no-evidence-yet) | no evidence yet that it matters. Its closing line says what would raise it; where that is a number, the run is an entry of its own, ranked by what the number could move |

Inside a tier, entries sit under their module, because **two modules touch no file in common** ([ADR 038](./adr/038-a-module-sits-where-the-loop-puts-it.md)): two entries under different modules can be worked at the same time, by two people or by one person on two days. Every entry closes with what it needs: `Needs:` when the shape of the work is known and something is missing (the fix, a decision, a design, somebody else's commit), `What would settle it:` when the entry is a question or a number. **A box** means a benchmark machine rather than the shared two-core vCPU most of the numbers so far were taken on; **an afternoon** is a run on the machine at hand.

**Where the defects came from.** Most were found by audits that read a module's code against its design page and checked every finding in the code: `http/` at `39896d2`, `sql/` at `cb45ea9`, and `cache/`, `job/` and `s3/` at `1738286`. The `nilo_sql` entries on statements that work and are refused were reproduced by a probe that fails at `462d84d`, in Debug and ReleaseSafe, against Postgres 18 where Postgres is named; elsewhere **reproduced** marks an entry that was also run. **A fix lands with a probe**: a test that fails on the code before it, in both modes, written first and kept. A claim an ADR makes that the code does not keep is corrected in that ADR with the fix, not before.

**An entry waiting on somebody else's repository is the line to distrust.** This repository has been wrong about a blocker seven times, and each time the code it was waiting for already did the thing ([history](./history.md)): the latest was the pg.zig pin, whose two commits had reached lalinsky's `master` while the pull request that asked for them sat open. Nothing downstream ever re-tests a blocker, so each such entry names the pin it was last checked at, and is re-tested before it is repeated.

**Ranked at 0.7.0.** The tiers were last set against the code and the numbers at that version, and [rule 9](#how-this-file-is-written) says when they are set again.

**0.7.0 needs Zig 0.16.** The latest stable release only, on one branch: the people this is aimed at download Zig, run `zig build`, and give up if it fails, and they are not going to go hunting for the right branch. Every new Zig release brings a few awkward weeks, made worse by zio following a branch-per-version pattern too.

---

## P0: blocks the next release

Nothing is open at this tier.

---

## P1: belongs in the next release

### `nilo_jwt`

**Whether a key ring may be built without an audience.** `audience` and `issuer` default to null, so a ring over Google's keys with no `audience` accepts an ID token minted for any other application signed by the same keys. The guide says so; [ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)'s rule is that a check forgetting costs silently is enforced rather than documented, and an audience is that check for a token.

**What would settle it:** the issuers in the comparison read for one whose tokens carry no audience, which is the case a required field would refuse; if none does, `audience` becomes required.

### `nilo_sql`

**The SQLite half has no live test against contention.** The Wire's own tests run one process, so the case the reader and writer split exists for has a design and no test: two writers meeting, `busy_timeout` expiring, `Locked` coming back.

**Needs:** a harness — a build step that stands up a second writer, which here is a second process on the same file rather than a socket.

**Whether two replicas applying migrations at once are safe under REPEATABLE READ.** `apply` begins with no isolation named, takes `pg_advisory_xact_lock` and then reads the ledger (`migrate.zig:1824`). Under a role whose default is REPEATABLE READ the snapshot is taken at the lock's `SELECT`, so the replica that waited does not see the other's ledger row and runs the version again; two `psql` sessions show it, and the suite has no way to set a role's default.

**What would settle it:** a live test with two pools on a role set to REPEATABLE READ, or `apply` naming READ COMMITTED, which makes the question moot.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**Whether `insertMany`'s `RETURNING` comes back in the order of its input.** It rests on how Postgres runs `INSERT … SELECT FROM unnest`, which it does not promise.

**What would settle it:** a Postgres statement that it does, or `WITH ORDINALITY` and an `ORDER BY` in the statement.

**Smaller suspicions, each needing a probe.** `Ordering.by` guards its length with `std.debug.assert`, which is out of bounds in ReleaseFast, and `nilo_parse` takes `?order=id,id`. `violated` guesses a constraint by `_pkey` and `_key`, which breaks once Postgres truncates a name at 63 bytes. `.x = null` on a column that cannot be null compiles to an `IS NULL` that is always false, the silent shape [ADR 040](./adr/040-a-condition-holds-a-value-not-a-maybe.md) refuses for `= NULL`. `.now` against an `AsText("timestamp")` column writes `now()`, a `timestamptz` that Postgres converts to the session's zone, so a session in Asia/Jakarta stores and compares seven hours off (`where.zig:1838`). Changing the type of a column an unchanged trigger names in `UPDATE OF` or `WHEN` is refused by Postgres, and `diffTriggers` remakes a trigger only when its hash moved (`migrate.zig:1066`). The introspection resolves a Row with no schema through `current_schema()` (`dialect.zig:750`), where a query resolves it through the whole `search_path`. The others (`Composed.text`, `Savepoint.release`, a stale `sql.problem`, `rawExplain` on SQLite) were checked on their own.

**What would settle it:** a probe each, kept as a test if it fails.

**Whether `expect` can boot under a role that may only read and write rows.** `expect` reaches `ensureLedger` (`migrate.zig:2601`), whose `CREATE TABLE IF NOT EXISTS` is checked against the schema's CREATE privilege, so an application role that is not the migration's owner may be refused at boot.

**What would settle it:** a live test under a role granted DML only.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

### `nilo_http`

**`?T` with no default means optional in a query and required in a body.** `Query(T)` reads an absent field as null and std.json refuses it, while `openapi.zig` says both follow the same rule. The guides always write `= null`, which is why nobody has met it.

**Needs:** one rule, and the description following it.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

**The OpenAPI document is looser than the server.** An unsigned integer gets `minimum: 0` and no `maximum`, although a `u8` refuses 256 with a 400, and a field with a default is marked not required in a response schema, although the writer always sends it, so a generated client null-checks every one.

**Needs:** `maximum` taken from the type, and `required` in a response schema meaning "always written".

**The test `Client` accepts a request head of any size.** Its reader is `Reader.fixed` over the whole request, and `readHead` refuses a head only once it fills the buffer, so a test sending a large cookie or many headers passes where a server answers 431. Its cookie jar also keeps a cookie deleted by `Expires` alone and ignores the `__Host-` and `__Secure-` rules a browser applies.

**Needs:** the test reader given the server's read-buffer size, and the jar honouring a past `Expires` and the two prefixes.

**One rule, one function: the audit's largest source of defects is a decision written in several places that stopped agreeing.** Whether a field may be absent is decided in six (`form.fill`, `form.fillCollecting`, `typed.queryValue`, `typed.queryValueCollecting`, `ctx.collectBadBody`, `ctx.describeObject`) and has drifted three times: `Patch` under `Bound`, `?T` in a query and a body, a number described in a query and not in JSON. Path prefixes are matched three ways (`middleware.underPrefix`, `static.underPrefix`, the router) and disagree on `//` and on a param, which is how `useOn` came to skip a `*` route until the chain was resolved per request for one. A JSON string is written by `json.zig` and again by `writeFailureBody`, and only one checks UTF-8. `If-None-Match`, `If-Range` and `Range` are answered in `serve.zig`, `sendfile.zig` and through `Versioned`. `fieldList` exists twice with different output. Each is a fix that closes its defects for good, where a patch to each copy closes them until the next copy.

**Needs:** the shape of each shared piece decided — a comptime `FieldRule` that the six callers ask, one prefix matcher the router's split defines, one JSON string writer, one conditional-request ladder — and the order, which the defects suggest: the field rule and the prefix matcher first.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

**Does a WebSocket over TLS park with a whole frame already decrypted-able in the record layer's buffer?** `websocket.zig`'s `park` checks only the cleartext buffer before `Wake.wait`, which polls the socket; tls.zig can pull two records in one socket read and decrypts one a call, so the second frame could wait on a socket the kernel has already emptied, until the client sends again or the idle ping fires. Read from the code, not run, and `tls_live.zig` has no WebSocket test.

**What would settle it:** a live test sending two frames in one TLS write and timing the second; if it stalls, `Wake.wait` returns `.readable` while the raw buffer holds a whole record.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**An idle connection grew 512 bytes between v0.2.0 and v0.3.0, and no ADR states it.** 4,674 to 5,186 on the benchmark server, unchanged since, while ADR 017 and the principles page still quote 4,669 ([`releases.md`](../bench/result/releases.md)). A hard axis moved, so either a feature owes its line in ADR 017 or the bytes are a leak of frame depth ([ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md)).

**What would settle it:** `bench/release.py --only http` bisecting the commits between the two tags, then the park depth on either side of the step. An afternoon.

**Direction:** [Every byte an idle connection holds is on the record](./roadmap.md#every-byte-an-idle-connection-holds-is-on-the-record)

**Either every `bodyStream` example costs 64 KiB on every idle connection, or ADR 062 is wrong about it.** [ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md) marks `var buf: [64 * 1024]u8` as 64 KiB on every connection for ever, and [the memory page](./design/memory.md) says the pages below `waitForRequest` are given back at idle, which would make that true only of a WebSocket. Every `bodyStream` example (`body.zig`, `ctx.zig`, `guide/requests.md`, `examples/stream`) teaches the stack buffer.

**What would settle it:** `bench/mem.py --hold` against a route that streams its body through a 64 KiB stack buffer, read while the connection is idle. An afternoon.

**Direction:** [Every byte an idle connection holds is on the record](./roadmap.md#every-byte-an-idle-connection-holds-is-on-the-record)

**The worst gRPC call is 1.4 s at 256 connections and 3.8 s at 1,024, where tonic's is about 1.1 s on the same four cores** ([`http.md`](../bench/result/http.md#a-grpc-listener-built)). h2load gives mean and maximum and no percentiles, so where the tail comes from is not known.

**What would settle it:** `ghz` or another client with a latency histogram against `spike/grpc/server`, before and after a spawn homed on the calling executor. An afternoon.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

---

## P2: evidence it matters

### Every module

**The public surface has not been read back against the reference.** 1.0 freezes what a dependent may write, and nothing yet checks that every `pub` in a module is on its page in `docs/reference/`, or that every name on a page is still `pub`. Found by reading, a name that should not be public is a break before 1.0 and a promise after it.

**Needs:** the read-back, one module at a time, and a decision on each name the code and the page disagree about: document it, or take it out of the surface.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

**Some ADRs only correct an older one.** [ADR 221](./adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md) makes a revision an edit to the ADR it revises, and the ADRs numbered before that rule still include corrections filed under a number of their own, so the rule in force is read in two files.

**Needs:** which ADRs are corrections rather than decisions, each folded into the one it corrects with its reasoning moved under "What was rejected", and the numbers kept as pointers so no link breaks.

### `nilo_config`

**Settings that are not scalars: a list, and a group switched on by presence.** A field is text, a number, a `bool`, an enum or any of those in `?`, and the port of a service with real deployment rules found what that leaves out: a comma-separated list (`PROMOTED_ATTRIBUTES=a,b`); a group of settings that turns on when one variable is present (`DURABLE_ENDPOINT` set means `DURABLE_BUCKET` and `DURABLE_REGION` are now required, inheriting what the file set); and two spellings of `bool` in one program. The first two would be a list type and a "set by presence" section in `Read(T)`. The third is not proposed: `bool` is `true` or `false` and nothing else, and the module keeps its four `Reason`s ([the reference](./reference/config.md#failure)). The program reads its rules by hand today, about sixty lines tested case by case, and says what it gains from the module only for the scalars.

**Needs:** the shape drawn from two programs and not from one: the port's rules, and a second program's written out, which can be one of the examples here.

### `nilo_pw`

**The Cost floor only weighs memory.** `Cost.floor_memory_kib` refuses anything under 7 MiB, which is OWASP's weakest published configuration. But that configuration is 7 MiB *and five passes*, and `.{ .memory_kib = 7 * 1024, .passes = 1 }` is a quarter of the work and compiles. A floor on `memory_kib * passes` would catch it, and would also refuse this repository's own test Cost, which is how the suite affords two optimize modes ([ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

**Needs:** a way of being cheap in a test suite that is not also a way of being cheap in production.

### `nilo_cache`

**The shard lock spins on a write and never backs off.** `while (l.held.swap(true, .acquire))` (`store.zig:371`) bounces the line between waiting cores, and a holder preempted by the OS leaves the waiters burning their timeslice; the module's own soak tests run more threads than cores. The refusal path also takes the lock only to bump an atomic counter (`store.zig:1107`). Not measured.

**Needs:** test-and-test-and-set with a yield after some spins, the refusal's lock dropped, and both measured under contention.

**Small things that say the wrong thing.** `open` answers `error.TooSmall` when a shard would exceed 4 GiB (`store.zig:890`); `flat.zig:44`, `space.zig:107` and the `cache_value_over_the_ceiling` refusal still say a bucket's four ways are a cache line, where it is eight; `registerSpace` is documented as not thread-safe while the guide calls `Space.open` from handlers, so two at once race on `n_spaces`.

**Needs:** each corrected, the refusal's `.says` with its text, and `registerSpace` made safe to call twice for one name.

**Counting a read costs 4.2% on eight threads and 7.0% on one.** The increment has to be atomic now that a read holds no lock, and there is no cheaper exact version: per-thread counter lanes were built with a thread-local and with a lane hashed off the stack address, and measured 1.5% better on eight threads and 3% worse on one ([`bench/result/cache.md`](../bench/result/cache.md)). quick_cache's answer is to put its counters behind a cargo feature that is off by default. Doing the same here is a build flag and a documented default, not a measurement.

**Needs:** whether `Stats` may be absent.

### `nilo_fetch`

**A plain call costs 4,139 bytes on every idle connection**, still the largest per-connection figure in the framework. It is fiber stack rather than buffers, at the depth `std.http.Client` drives it to. [`bench/result/fetch.md`](../bench/result/fetch.md) ranks the levers: moving the buffers into the arena costs +4,096 bytes since the stack release, shrinking them is worth nothing because a stack buffer no byte touches is never a resident page ([ADR 186](./adr/186-the-transfer-buffer-serves-nothing-here.md)), and what is left is the frame `std.http.Client` waits in.

**Needs:** the frame `std.http.Client` waits in measured frame by frame, which says whether anything short of a client of nilo's own can move it.

**Direction:** [Every byte an idle connection holds is on the record](./roadmap.md#every-byte-an-idle-connection-holds-is-on-the-record)

**What an outbound call costs through TLS is read off buffer sizes, not measured.** 59,151 bytes per HTTPS connection is std's number read out of its buffer sizes, 3.6× plain HTTP if it holds.

**What would settle it:** the measurement beside `zig build smoke-tls -Dnetwork`, which already reaches a real endpoint. An afternoon.

**Direction:** [Every byte an idle connection holds is on the record](./roadmap.md#every-byte-an-idle-connection-holds-is-on-the-record)

### `nilo_job`

**Inputs nothing refuses.** `every(0)` makes a worker busy-loop and `every` of a huge period overflows; `Backoff.exponential` with `from_ms = 0` stays at zero and has no jitter, so a downstream outage retries every row at the same instant; one `Canceled` propagated from a child future sets `stopping` for every worker (`job.zig:846`); dead rows are never purged from `Memory`, which fills up and answers `QueueFull`.

**Needs:** `every(0)` and `from_ms = 0` refused at compile time with a refusal file each, a jitter option, a cancelled child told apart from shutdown, and a purge for `Memory`'s dead rows.

**A schedule is UTC.** `0 3 * * *` is three in the morning in Greenwich, and a program in Jakarta writes `0 20 * * *` with a comment. A time zone is a table of rules that changes twice a year and a dependency to carry it.

**Needs:** tzdata without a dependency: the rules for the zones a program names, embedded while compiling, priced on the binary axis.

**A bulk enqueue may slow every claim, because the claim sorts the whole due backlog.** `ORDER BY priority, run_at LIMIT 1` over `(state, run_at)` sorts every due row; probing each priority on an index of `(state, priority, run_at)` would not, and [ADR 214](./adr/214-a-job-says-how-urgent-it-is.md)'s finding that the wide index is slower was for that one ordering, not for one `ORDER BY run_at LIMIT 1` a priority. The `nilo_job` audit at `1738286` ran both once in a scratch container and wrote nothing down, and `SKIP LOCKED` is refused inside a `UNION ALL`, so the shape is up to three statements or a CTE a priority.

**What would settle it:** both shapes on Postgres at a backlog of 1, 50k and 200k due rows beside 300k done ones, into [`job.md`](../bench/result/job.md), and ADR 214 edited in place with the result. An afternoon.

### `nilo_s3`

**A streamed object cannot be read from an offset.** `stream` has no range and `getRange` is bounded by `max_bytes`, so the guide's `.length = reading.len` "lets it resume with a `Range`" has no way to serve one for an object over `max_bytes`, and `getRange` returns no total size. `getRange` with `from > to` gets the whole object back as a 200 that is not checked for 206 (`bucket.zig:266`); `stream` and `head` report `len = 0` when `content-length` is missing (`:373`, `:541`).

**Needs:** a range on `stream` with `Reading.total` from `content-range`, a reversed range refused, 206 required, and a missing length made `Failed`.

**Failures that say nothing or the wrong thing.** `head` logs nothing on failure (`bucket.zig:538`), so a wrong region or a skewed clock is silent; `NoSuchBucket` maps to `NotFound` like a missing key; `blame` says "could not be reached" for `SessionTokenTooLong`; `presign` with `seconds = 0` is accepted.

**Needs:** `head` logging the status and `x-amz-bucket-region`, `NoSuchBucket` told apart, credential errors named, and a zero life refused.

**`canned.zig` checks less than S3 does.** `check()` verifies only the headers the client listed in `SignedHeaders`, so a sent `x-amz-*` header left unsigned still passes, where S3 refuses it; its `Seen` copies into fixed buffers with no bound; two comments refer to `finishGet`, which is now `bounded`; `code.zig`'s header still says `LIST` is not in v1.

**Needs:** every `x-amz-*` header on the wire required in `SignedHeaders`, the harness bounded, and the stale text corrected.

### `nilo_sql`

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

**An index on a big live Postgres table cannot be built without blocking its writes.** Every version is one transaction, and Postgres refuses `CREATE INDEX CONCURRENTLY` inside one, so a generated `create_index` on an existing table takes a lock that makes every write to it wait until the build finishes. On a table of a few thousand rows that is milliseconds; on one of fifty million it is an outage. The step's `why` says so today, and that is a warning rather than a way out. The way out is a step that runs outside its version's transaction and is recorded in the ledger on its own, because a `CONCURRENTLY` build that fails halfway leaves an invalid index behind that has to be dropped before the next attempt.

**Needs:** a decision on how a step outside the transaction is recorded when the version around it fails. A table that size to test it on is one the test generates.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**Nothing reports how the pool is doing.** `app.metrics` counts requests, statuses and durations ([ADR 079](./adr/079-the-route-table-is-the-registry.md)); a `Db` counts nothing. Connections in use, how long a caller waited for one, statements run, and how many the pool threw away are the questions an operator asks first when a service slows down, and the last of them is already reachable — `postgres.dirtyConnections()` parses it out of pg.zig's own metrics text and is marked test-facing because nothing else reveals it.

**Needs:** a shape that does not become a second metrics registry. `app.metrics` is the shape and a `Db` is a Service, which knows nothing about an App — so where the numbers meet is the question, not how to count them.

**A Row over an attached SQLite database has nowhere to `ATTACH` it.** A schema in `nilo_table` means an attached database there ([ADR 055](./adr/055-the-second-dialect-is-the-test-of-the-seam.md)), and `ATTACH` is per connection — but the Wire holds a writer and a pool of readers, opens them itself, and `db.exec("ATTACH …")` reaches the writer alone. The introspection then asks a reader that has never heard the name, which is how the test for the schema-qualified `sqlite_master` found this: it attaches on every `conns[i].handle` by hand, and a program cannot.

**Needs:** a statement list run on every connection at open — which is also where a `PRAGMA` of the caller's own would go.

**A pool-wide `statement_timeout` rides in the startup packet, and nothing upstream blocks it any more.** It is the only way a plain `db.select` gets a deadline without a second round trip ([ADR 043](./adr/043-a-deadline-needs-a-connection-you-hold.md)). The pin has sent `startup_parameters` since lalinsky's `2907296`, and a URL's `options=` already rides on it ([ADR 239](./adr/239-a-live-test-skips-on-a-laptop-and-fails-on-ci.md)), so what is left is `Db.Opts.statement_timeout_ms` handed to the same map, for a program that sets its ceiling in code rather than in the URL.

**Needs:** a live test that a statement past the number comes back `error.TimedOut` on a connection nobody set anything on, and that a reconnect sends it again.

**A case-folding unique made before `text_pattern_ops` keeps the index `istarts_with` cannot read.** The migrator compares a unique `ignoring_case` and not its operator class, so an existing database never gets the new index and its prefix search still scans on Postgres.

**Needs:** the operator class in the snapshot's index and a step that rebuilds it, or a `db check` finding that names it.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**`db generate` reuses a version number when the snapshot is ahead of the newest file.** `db check` reports it through `migrations.audit`, and `generate` still refuses only a snapshot behind.

**Needs:** `generate` refusing a snapshot ahead too, with the tests that build unusual snapshots checked.

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

**A Problem from the diff has no way out but editing `snapshot.zon` by hand.** While one stands, `generate` writes nothing, and the step it suggests does not move the snapshot, so the same Problem comes back (`migrations.zig:394`, `migrate.zig:1704`). The common case is a new column with a foreign key to an existing table, which both dialects refuse here and `addMissingColumns` does; a new column is all NULL, so `ADD COLUMN` then `ADD CONSTRAINT … NOT VALID` cannot fail on old rows. The Problem's sentence that SQLite needs a rebuild is wrong for a new column, which `ADD COLUMN … REFERENCES` takes.

**Needs:** the new column's key written by the diff, and a way for an accepted Problem to be recorded in the snapshot.

**Direction:** [A migration history a project can keep for years](./roadmap.md#a-migration-history-a-project-can-keep-for-years)

**Case folding outside ASCII differs between the two databases.** SQLite's `LIKE` and `NOCASE` fold ASCII only (`dialect.zig:1110`, `:1199`); Postgres's `ILIKE` and `lower()` fold Unicode (`:613`). `.ieq = "ÉLISE@x.id"` matches `élise@x.id` on Postgres and not on SQLite, and a `NOCASE` unique keeps both. ADR 055 asks for a difference like this to be refused or written down, and the reference says only that SQLite folds ASCII.

**Needs:** whether the SQLite half is refused for non-ASCII text or the difference is written on both pages.

**`Tx` repeats `Db` body by body.** Twenty-eight of `Tx`'s methods (`db.zig:2563` to `:2923`, about 360 lines) copy `Db`'s, differing in `self.db`, `&self.inner` for `null`, and `"tx."` for `"db."`. Opening a result and telling the watcher on failure is written out six times (`:1009`, `:1606`, `:3231`, `:3363`, `:3425`, `:3579`). `raw`, `rawOne` and `rawExactlyOne` repeat their scalar and Row branches on both types (`:1664` to `:1820`, `:2756` to `:2866`), and the four `rawPage` bodies are near copies (`:1850`, `:2871`). One private body per operation taking `tx: ?*W.Tx` and the call's name removes about 350 lines, and halves the instantiations each call site costs.

**Needs:** a yes.

**`ddl.zig` writes most statements twice, once while compiling and once at run time.** `addColumn` and `columnClause`, `writeLiteral` and `valueList`, `writeCheckIdent` and `checkName`, `createTrigger` and `triggerStatement`, `createView` and `viewStatement`, `createExtension` and `createExtensionIfMissing` are pairs, and `addColumn` already disagrees with `columnClause`. The desired side is comptime whole, so only a drop or rename, whose name comes from the snapshot, needs the run-time writer. About 150 lines.

**Needs:** a yes.

**Helpers are copied between files.** A backticked name list is written seven times (`shape.zig:673`, `where.zig:1498`, `table.zig:1293`, `row.zig:220`, `:950`, `:1266`, `statement.zig:568`); an unordered set comparison three (`statement.zig:1507`, `db.zig:395`, `table.zig:202`); `columnTuple` is `tupleOf` (`statement.zig:1520`, `db.zig:415`); `writtenValue` is `fieldValue` (`statement.zig:2147`, `where.zig:1676`); `relation` is `relationOf` (`statement.zig:122`, `where.zig:1490`); `snapshot.sameSchema` is `table.sameSchema`; the SQL literal escape is in `ddl.zig:770` and `migrations.zig:670`; and an optional is unwrapped by an inline `switch` 33 times across ten files. Inside `migrate.zig`, `findUnique`, `findIndex`, `findReference` and `findNamed`, and the six `carried*` and `renamed*` functions, are one generic each. In `shape.zig`, `parentLink` and `backLink`, and `throughColumn` and `throughOf`, resolve the same path twice, and the second pair is where the `.through` defect above came from. A direction with its `NULLS` is written in three places (`shape.zig:1331`, `:1531`, `statement.zig:2125`). About 400 lines in all, with name helpers in `row.zig` and type helpers in `types.zig`, which every file already imports.

**Needs:** a yes.

**Declarations that nothing uses.** `table.columnList` (`table.zig:2077`), `ddl.dropTable` (`ddl.zig:280`), `Tx.w` (`db.zig:2344`), `strList` (`db.zig:5100`, covered by `mappedList`), `ListForm.expanded` and `.unsupported` (`dialect.zig:61`), `Unique.sameAs` and `Index.sameAs` (`table.zig:179`, `:234`), and `sql.table_marker`, a string no Zig program can use as a declaration name. Used only by tests: `where.each` and `where.paramCount` (whose comment says a Wire binds this way, and `valuesOf` does), `Plan.needsBackfill`, `Chain.headHash`, `Outcome.wasHeld`, and `sqlite.labelsOf`, which exists because `assertWire` asks for it. `Dialect.nulls` answers an optional that is never null in either dialect, so `noNullsOrder` and its four call sites cannot be reached. The top-level `…For` constants can be `on(Postgres)`'s, with the two `on()` lacks added.

**Needs:** a yes, and the names that are public decided with the read-back of the public surface.

**Whether a failed statement's Problem can be overwritten before it is recorded.** `told` runs before the deferred `drain` (`db.zig:3243` against `:3252`, and the same in `fillScalar`, `only` and `rawTotalBehind`), and a drain can suspend: Postgres reads up to a megabyte off the socket, and `pool.release` may dial. Another fiber on the same thread can then overwrite `recent`, and `sql.violated` answers false for a unique that was hit. ADR 117 rests on there being no suspension point there.

**What would settle it:** a probe with two fibers on one executor, or `told` moved after the drain, which makes the question moot.

**Whether SQLite's `Problem` can carry the previous statement's message.** `intsFit` and `floatsKept` fail before SQLite is called (`sqlite.zig:783`), and `said` then reads `lastError()` (`:909`), which after a reset holds the last statement's error. An INSERT refused on `users.email` followed on the writer by an oversized `u64` would make `sql.violated(c, User, .{.email})` true.

**What would settle it:** a probe of that pair, or `said` reading `errmsg` only for an error that came from SQLite.

**Whether `describe` pays five round trips on every raw call behind a pooler.** `DEALLOCATE nilo_describe` is sent after the `ROLLBACK` (`postgres.zig:1476`), in a transaction of its own, which pgbouncer in transaction mode may route to another server connection. The statement is left behind on the first, the next describe there fails on `42P05`, and `vetRaw` (`db.zig:770`) keeps trying. ADR 233 says it costs a round trip only while the statement beside it is failing too.

**What would settle it:** a run behind pgbouncer in transaction mode, or the `DEALLOCATE` sent before the `ROLLBACK`.

**Whether one request can pay for re-dialling the whole pool after Postgres restarts.** Each connection found hung up is released as failed (`postgres.zig:456`, `giveBack` at `:1519`), and pg.zig dials its replacement inside `release`, synchronously and with cancellation held off. One request can pay the pool's size in TCP, TLS and authentication, and its deadline cannot cut it short.

**What would settle it:** a live test that restarts Postgres under a pool of ten and times the first request after.

**Nobody knows why the arena's `async-db` profile reads 66k req/s with neither the server nor Postgres busy.** It runs at 874% of sixty-four CPUs, 3.9 ms a query for a 0.1 ms scan. Decoding is 116 µs of nilo's 284 µs a request and none of the wait ([`sql.md` §12](../bench/result/sql.md#12-the-arenas-query-at-one-connection)); the suspect is pg.zig's one pool mutex taken twice a request by 1,024 fibers on 64 threads, which two threads cannot convoy. The arena's rerun with stealing off (ADR 199) read 59.7k with the p99 at 245–362 ms from 50, which is what a fiber queued on a mutex that no other thread can now run looks like, and does not yet name the lock ([`http.md`](../bench/result/http.md#the-arenas-two-readings-and-what-changed-between-them)).

**What would settle it:** `bench-sql-server`'s three `/async-db*` routes under `wrk -c1024`, pool 256 then 32, Postgres on `--network host`, on a box.

**What `nilo_sql` costs a dependent's build has no number at all.** Every query is settled while compiling, and ADR 017 has no axis for compile time. Each call site's anonymous literal instantiates its statement, `valuesOf` and `fill`, `Tx` doubles them, and several eval quotas grow with the square of the schema (`table.zig:456`, `:2151`).

**What would settle it:** `bench/result/build.md` extended: a schema of 10, 50 and 100 tables with one and ten call sites a table, cold and after one edit. An afternoon.

**Every SQLite program chooses whether a statement hops or runs in the fiber, with no number to choose by** ([ADR 064](./adr/064-a-file-has-no-socket-to-wait-on.md)). A hop and a cached read both cost a few microseconds, so `.in_fiber` is plausibly faster for a lookup service and fatal for one that scans.

**What would settle it:** both, unloaded and behind the pool ([`sql.md` §2](../bench/result/sql.md) is why both); `bench-sql` has the unloaded `.in_fiber` half, and `bench/sql_server.zig` on a SQLite `Db` is the rest, on a box.

### `nilo_http`

**`Ctx.header` reads the head again for every name it is asked, about 40 ns a time inside a request.** It splits the head into lines and trims each one until a name matches: 27 ns in a loop of its own for the third line of a short head, and about 40 inside a request, where a message read as JSON pays it to learn its spelling and is 52 to 58 ns slower than the same route as a plain struct ([`bench/result/http.md`](../bench/result/http.md#a-body-read-as-what-its-type-says)). A form pays the same read for its `Content-Type`, and every `c.header` call in a handler pays one. Classing the header in the head parser closed the message's gap to 1 to 4% and was refused for putting 1.6 KB on every program's request path ([ADR 256](./adr/256-a-body-is-read-as-what-its-type-says.md)); the read itself is the thing to make cheaper.

**What would settle it:** a lookup measured against `Ctx.header` on the message row and a form's in `zig build profile`, held to no size on the request path, and kept only where it is faster on both.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

**A message's `bytes` field is text in its JSON, where protobuf's JSON mapping makes it base64.** A message read or written as JSON is nilo's JSON ([ADR 256](./adr/256-a-body-is-read-as-what-its-type-says.md)), so a `[]const u8` declared `.bytes` in its `wire` table goes out as the bytes themselves and is read back the same way. A Connect client speaking JSON sends and expects base64 there, and the two would disagree without either refusing. Field names and 64-bit integers do not have the problem: a Connect client reads both of nilo's spellings.

**What would settle it:** a decision between writing a `.bytes` field as base64 in a message's JSON, with the document saying so, and refusing JSON for a message that has one; either held by a test with a Connect client's bytes.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

**Whether a gRPC listener should keep an HPACK table, to stop decoding the same strings every call.** With the table advertised at 0 every field arrives as a literal and its Huffman is decoded afresh, 123 to 125 ns of a 767 to 773 ns call in process, 16% of it, after the decoder went to two symbols a lookup ([`bench/result/http.md`](../bench/result/http.md#two-huffman-symbols-a-lookup)). What is left only a table of the client's own takes away, and that is idle memory, the hard axis: at the default 4,096 bytes a decoder keeps what the client inserts, up to the whole table per connection for a Collector that indexes a fresh `grpc-timeout` every call ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).

**What would settle it:** the resident bytes per idle connection at a table of 4,096 and of a few hundred, measured against the Collector and a library called by hand, beside what each saves of a call; a table ships only if ADR 017's idle figure for a gRPC connection is restated with it.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

**Several comments and pages describe code that is no longer there.** `bulkhead.zig`'s header lists a six-parameter `serve` (it has eight) under `src/engine/` (it is `http/engine/`), and leaves out `Peer`'s fields, `spawnLocal`, `Wake.rawIdle` and `Binding`, which a second Engine has to provide; `proxies.zig` says a `Forwarded` header is walked, and nothing reads it; the `accept` comment in `zio.zig` says a failure raises the stop flag; `middleware.zig`'s header and [ADR 008](./adr/008-middleware-is-an-onion-of-ctx-functions.md) use `std.time.Timer`, which Zig 0.16 removed; a link in `ctx.zig` says ADR 155 and points at 156.

**Needs:** each corrected, and the module headers' code examples brought under `zig build snippets` so the next one cannot rot.

**Direction:** [Defects are caught by a build step before a reader](./roadmap.md#defects-are-caught-by-a-build-step-before-a-reader)

**Nothing tells a handler its client has gone.** `error.Canceled` comes from a shutdown or from one of the deadlines the Engine sets; a client closing its connection in the middle of a handler produces neither, so the work runs to the end and the response is written into a socket nobody is reading. The other half of this — cutting a slow handler off — is `nilo.deadline(ms)` ([ADR 105](./adr/105-a-route-can-say-how-long-it-has.md)). This half is not simply unbuilt: **the obvious implementation is wrong.** A read-side EOF is not "the client left" — a client that sent `Connection: close` and then `shutdown(SHUT_WR)` produces exactly that and is still waiting for its response, so answering "peer gone" from it would abandon correct requests. Gin gets the disconnect from `net/http` for nothing; Fiber does not have it either.

**Needs:** two named signals rather than one flag — "the client half-closed and is waiting" and "the socket is gone". What is already real is a write that fails, and a handler sees that today.

**A rule a build step holds against the patterns the audit kept finding.** Three of the four kinds of defect are spellable: `catch {}` and `else => {}` that swallow `error.Canceled` or `EndOfStream` on a connection path (the stop that waits, the upload that looks complete, the middleware's empty 200); `unreachable`, `std.debug.assert` and `catch unreachable` on a path a request reaches (`Room.print`, `Ctx.send`, `sayerFor`, `idempotentBegin`), each a remote panic in ReleaseSafe and undefined behaviour in ReleaseFast; and a module header's code example that no longer compiles (`std.time.Timer` in `middleware.zig` and ADR 008). The fourth kind, a comment or ADR claiming what the code does not do, a dozen of them, has no mechanism but probes. A step that refuses the three in `http/` unless the line carries a marked reason makes the next one a build failure rather than an audit finding.

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

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

**A number inside a map or a `std.json.Value` field is still read by `std.json`'s grammar.** `"1_0"` there is 10, where [ADR 084](./adr/084-a-number-in-a-request-is-not-a-zig-literal.md) refuses it everywhere else in a body, because a type with its own `jsonParse` is handed to `std.json.innerParse` unchanged. The write half is closed: a float that is not finite is `null` on every path out ([ADR 096](./adr/096-a-byte-that-is-not-text-is-not-a-string.md)).

**Needs:** the map and `Value` paths read through the number rule every other field is, with a test sending `"1_0"` to each.

**Multipart, streamed.** `Form(T)` reads a multipart body whole, bounded by `max_body` ([ADR 030](./adr/030-a-form-is-the-body-read-by-another-rule.md)), which is right for a form with a photo in it and wrong for a 2 GB video. The streaming version wants a parser that resumes across reads and an `Upload` that is a reader rather than bytes; it inherits nothing from `sendfile`, because sending is a descriptor handed to the kernel and receiving is a parser holding its place.

**What would settle it:** somebody designing it. Until then the answer is `c.bodyStream()`, which holds nothing and makes the framing the handler's problem.

**Direction:** [A stream is one shape](./roadmap.md#a-stream-is-one-shape)

**Should a JSON body be refused when the request says it is something else?** `Ctx.json` parses whatever `Content-Type` came, while `Form(T)` refuses the wrong one, so a cross-site `<form enctype="text/plain">` can deliver valid JSON with no preflight, which matters to an app with a cookie sent cross-site and no `nilo.csrf`. A 415 is safer and breaks a client that sends JSON unlabelled.

**What would settle it:** a decision between a 415 for a present non-JSON type and an absent one allowed, or the gap written into the CSRF guide as the reason `nilo.csrf` exists.

**Whether a connection should start on the executor whose acceptor took it is not measured.** `spawnInto(.local)`, which a gRPC call already does, bought 2.7x there ([`http.md`](../bench/result/http.md#what-placing-a-grpc-call-on-its-own-executor-buys)). Against round-robin it removes the last per-connection cross-thread hop, and it leaves the spread across threads to whichever acceptor the kernel wakes ([ADR 200](./adr/200-every-executor-accepts.md)).

**What would settle it:** gcannon's short-lived and keep-alive shapes, `.local` against round-robin, interleaved, with the connections each executor ends up holding. An afternoon.

**Whether one acceptor per executor is past the knee on a machine with many threads is not measured there** ([ADR 200](./adr/200-every-executor-accepts.md)). dusty measured 12 and 24 accept loops losing 20–40% on one request per connection against 5, on 24 threads; at 8 threads on the 9700X log2's 3 gained 2–4% there and lost 5–6% at ten requests per connection ([`http.md`](../bench/result/http.md#how-many-acceptors-eight-threads-want)).

**What would settle it:** the same sweep, acceptors at threads, 2×log2 and log2, on 24 threads or more, with one and ten requests per connection, on a box.

**What reading an internally tagged union costs is not measured, and `jsonmark.zig`'s header says it costs nothing per request.** Each tagged value is passed over four times (`skipValue`, the discriminator scan, `parseFromSliceLeaky`, `refuseUnknown`), two of them building a `std.json.Scanner`; the header's claim is true only on the write side.

**What would settle it:** an array of a thousand tagged values, against the same array untagged; `http.md` has the write side (248–317 → 88–95 ns across six runs) and nothing for the read. An afternoon.

**Whether the 32-lane scans hold on aarch64 is not measured.** `scan.lanes` and `json.zig`'s escape scan are 32 lanes, which on aarch64 is two NEON registers, and every head-parsing and JSON figure is from one x86-64 box.

**What would settle it:** `zig build run` and `bench/bench.sh` on the M1 Pro that has already run the cache and the build. An afternoon.

**What a connection inside a request holds now that `read_buffer` is 16 KiB is arithmetic, not a reading.** The idle figure is unchanged by construction (ADR 062 gives the pages back), and the active one is two pages more on paper ([ADR 196](./adr/196-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md)).

**What would settle it:** `bench/mem.py --hold` against `bench-stream-server`, the one server that holds connections mid-request, at 8 and at 16. An afternoon.

**Direction:** [Every byte an idle connection holds is on the record](./roadmap.md#every-byte-an-idle-connection-holds-is-on-the-record)

**How far under a page boundary a plain connection parks is not known, so every change to the connection loop is one page per idle connection away from going unnoticed.** 2,618 bytes live on the plain build and 2,890 on the `-Dtls` build, one page against two, with the difference being the inliner's and not TLS's ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md), the section on the page).

**What would settle it:** the park-depth instrumentation ADR 212 describes (the live stack at `releaseIdleStack`, printed once per connection), run on `main` and after each candidate: `noinline` on `waitForRequest`'s wait, a smaller `Peer` on the frame, the handler's frame measured on its own. An afternoon with the instrumentation, which is four lines.

**Direction:** [Every byte an idle connection holds is on the record](./roadmap.md#every-byte-an-idle-connection-holds-is-on-the-record)

**22% of `std.flate`'s CPU on a 4 KB body is a buffer rebuilt after every block, and it has not been filed upstream.** `toks.* = .empty` in `writeBlock` rebuilds the 96 KB token buffer from its constant after every block, where assigning the fields one by one gives byte-identical output 18% to 44% faster ([`http.md`](../bench/result/http.md#which-deflate-is-fastest-and-whether-brotli-or-zstd-would-beat-it)). ADR 211 refuses a fork of `Compress.zig`.

**Needs:** the issue filed against zig, `lib/std/compress/flate/Compress.zig` lines 987 and 1055. Last checked at 0.16.0.

**`zig build dev -- --incremental` cannot run without LLVM.** `-fincremental` with the self-hosted backend and the new ELF linker rebuilds `examples/hello` in 0.12 s and leaves `.zig-cache` flat, and its output dies at exec with `undefined symbol: main` whenever libc is linked, which every nilo server is; the old ELF linker spins on the first update instead ([ADR 190](./adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md), [`build.md`](../bench/result/build.md#what-a-restart-on-save-costs-per-save)). `zig build-exe main.zig -lc -fincremental` on a five-line program reproduces it.

**Needs:** zig. Last checked at 0.16.0; re-test with `zig build dev-hello -- --incremental` and no `-Dllvm` on each release.

**A client whose first key share is not X25519 is refused rather than asked again, because the TLS listener has no HelloRetryRequest.** With it, so is a session ticket, which is what the session resumption entry needs to turn a full handshake per reconnection into a resumption.

**Needs:** the same repository. Last checked at `e04ae44`.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**The TLS pin is a fork, `nevindra/tls.zig`, until two commits reach upstream.** It is upstream's `zig-0.16.x` plus two commits: one signs an RSA key through its CRT form, 13.7 ms of handshake CPU down to 2.6 ([the run](../bench/result/http.md#what-an-rsa-certificate-costs-a-handshake)), and one adds the server's `offload` option, which runs the signature off the executor ([ADR 217](./adr/217-a-handshakes-signature-is-computed-off-the-executor.md)). The first is offered upstream and the second is not yet. Once both merge, the pin moves to upstream's commit and the fork is not used again.

**Needs:** [ianic/tls.zig#59](https://github.com/ianic/tls.zig/pull/59) merged, and the second commit offered. Last checked at `73290ca`.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

---

**The pipe of a request on HTTP/2 costs 30 to 85 ns a request in process and 70 to 139 bytes an idle connection, which is over the stage's bar of one wait.** A unary gRPC call is 912 to 918 ns against 850 to 860 collected, a 13 byte JSON `POST` 897 to 906 against 811 to 827, and an HTTP/2 connection after one `GET` 9,560 against 9,429 bytes ([`bench/result/http.md`](../bench/result/http.md#what-a-request-on-http2-costs-when-its-body-is-a-pipe)). Through `h2load` with a real wait on every request the spreads overlap, so the bar is missed in process and not seen through a server. What it is made of is not isolated: a `Stream` that grew from 392 to 616 bytes with its `Inbox` and is rebuilt for each recycle, a monitor taken at every step, and a request that starts twice where it is deferred until its stream has ended. An `Inbox` per connection rather than per stream, a start that does not happen twice, and a pipe that takes no lock where nothing else touches it are the three to try.

**What would settle it:** the three changes measured one at a time on the message rows of `zig build profile -Dhttp2` and on `mem.py --h2`, each against `ab11878`'s figures on the record.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

## P3: no evidence yet

### `nilo_core`

**A per-thread entropy pool, if a number ever justifies one.** `c.entropy` reaches the operating system on every call: 56ns on a kernel serving `getrandom` from a vDSO and roughly twenty times that on one that does not ([ADR 042](./adr/042-entropy-belongs-to-the-loop.md)). A CSPRNG seeded once per thread would remove it, and costs stored state, a fork hazard and a seeding moment.

**Needs:** a workload where it shows.

**A limiting allocator shared across requests.** An allocator that counts live bytes and the peak with atomics and refuses with `OutOfMemory` past a limit, reserving with a compare-and-swap so a refused request never disturbs a neighbour's smaller one, would give a process-wide cap on bounded work such as decompressing a body or building a response, perhaps with a per-request child ("this request may use 64 MiB of the process's 512"). A port of a log search found it at about 100 lines with nothing specific to that program, and it lives there for now. Nothing in `core/` or `http/` is one today; the per-request arena is bounded by `max_body` and `arena_keep`, which is a different number.

**Needs:** a second caller that wants an aggregate cap across concurrent requests, and the cost on the allocation axis stated first ([ADR 017](./adr/017-the-trade-budget-has-four-axes.md)): a feature that adds an allocation to a path that did not ask for it does not ship.

**Where `convert` belongs.** Turning text into a type is what a Core wants, but `convert.zig` reaches the Bulkhead to say a request failed. Either its failures come back as a value the caller turns into a 400, or it stays in the App layer and Core gets a smaller converter under the same rules. Two candidates have already come and gone: `nilo_config` is not a second caller, because sharing means naming `nilo_core` and giving up a plain `zig test` ([ADR 039](./adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)); `percent.zig` went to Core without answering this, because neither direction of percent coding can fail ([ADR 057](./adr/057-percent-is-needed-by-two-layers.md)).

**What would settle it:** a caller in the App or Service layer. One below cannot afford to reach for it, which is what both false starts proved.

### `nilo_config`

**A name that is not the field's own.** `database_url` reads `DATABASE_URL` and there is no way to say otherwise, so a platform that already owns a name — `PGURL`, or `PORT` meaning something else in the same container — has to be met by renaming the field. A marker in the reader's own struct is the shape the rest of nilo uses (`nilo_table`, `nilo_resolve`), and the work is one comptime lookup.

**Needs:** a caller who cannot rename the field.

**A prefix is per reading, not per Config.** `fromWith(T, .{ .prefix = … })` has to be written at each call, so two places reading one Config can disagree about it. Making the prefix part of the type would fix that and cost `Read(T)` its one-type-per-`T` property.

**Needs:** a caller who has actually disagreed with themselves.

### `nilo_pw`

**A password longer than a page costs what it is.** Argon2 hashes the whole input, so a client posting a megabyte gets a megabyte hashed. `max_body` bounds it at one megabyte by default and the Gate bounds how many at once, so it is not an opening. But everybody else truncates at 72 bytes or pre-hashes with SHA-512, and nilo does neither.

**Needs:** which of the two.

**Whether a memory-bound deployment gets bcrypt.** It is in `std`, it costs zero heap against argon2id's 19 MiB, and it is 2.6× slower for the trouble ([ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md) has the numbers). The trade is real for a small machine holding many connections.

**What would settle it:** somebody on one.

**Whether a second factor belongs here.** TOTP (RFC 6238) is HMAC-SHA1 over a counter derived from the clock, a base32 secret, and a window; forty lines, and the trap is quiet: a code accepted twice inside its own thirty-second window is a replay, and a verifier that forgets to record the last counter it accepted passes every test. The same argument that put `pw.Token` here applies ([ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)). Against it is that the audience is narrower, and that the enrolment half (a QR code, a provisioning URI) is a page rather than a function.

**What would settle it:** an application that is asked for a second factor.

### `nilo_cache`

**A value of `[]const u8` is the only shape that is not flat.** A struct with a `[]const u8` field in it is refused by name, and the caller encodes it. The shape that would fix it — writing the slices' bytes after the fixed part and pointing them back into the caller's buffer on the way out — is known and is maybe 120 lines of comptime.

**Needs:** a caller for whom JSON into a bytes Space is not enough.

**Where the 60% between nilo and quick_cache on eight threads goes is not known.** The levers named so far are each a few percent ([`cache.md`](../bench/result/cache.md)).

**What would settle it:** `perf` on both binaries, not another guess, on a box.

**Whether a bucket should have sixteen ways rather than eight is not measured.** Two cache lines touched, against better retention at load.

**What would settle it:** the retention curve and the read cost, both swept across ways, on a box where the read cost is not mostly memory latency.

### `nilo_jwt`

**Only 2048, 3072 and 4096 bits of RSA, and only P-256 of EC.** A key size with no branch is `error.KeySizeNotSupported` and a curve with none is `error.CurveNotSupported`, rather than a best effort. ES384 is the same twenty lines over `EcdsaP384Sha384`; ES512 wants P-521, which std does not carry; Ed25519 (`EdDSA`) is a different key type again.

**Needs:** an issuer that publishes one, which none in the comparison does.

**Whether nilo signs a token for a client that cannot hold a cookie.** [ADR 111](./adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md) refuses signing because a server issuing its own sessions has `Session(T)`, and that holds for a browser. The client it does not obviously hold for is a native mobile application talking to the same API, where a bearer token is the convention and a cookie jar is a thing the developer has to go and find. HS256 sign and verify is forty lines; a signer here would have to be a type that cannot be handed an RSA public key as its secret, which is a Refusal rather than a runtime check.

**What would settle it:** a client that genuinely cannot hold a cookie, brought with the reason, since "the convention is a bearer token" is not one.

**Whether a sign-in endpoint should cache a verification or just do it is not measured.** An RSA exponentiation at 2048 bits is not small.

**What would settle it:** one verify of each kind, and a row in `bench/result/` for it. An afternoon.

### `nilo_fetch`

**An `Exchange` cannot be begun on a target.** `Exchange.begin` takes the client and a URL, and a target's `url(c, path, args)` is the URL — so the streamed call reaches the base and the template, and not the standing headers or the target's own gate. The shape is a `begin` on the target that takes a path and hands the Exchange the `Standing` the whole-body calls already pass ([ADR 061](./adr/061-a-fitting-borrows-the-loop.md)).

**Needs:** a caller who streams from a service that has standing headers, since a signed request sets its own and an unsigned download has none.

**A certificate bundle is loaded per client, not per process.** `std.http.Client` rescans the system roots the first time it makes an HTTPS request. One client per program is the shape the docs push, so this has not bitten, but two would pay twice and nothing says so at the call site.

**Needs:** a caller who genuinely wants two clients.

**Whether retries belong anywhere.** How many times, how long between, and what counts as a failure are facts about somebody else's service. A caller who knows them can write three lines. A default that guesses them turns one outage into a thundering herd.

**What would settle it:** a shape that takes the policy as a type rather than a number, which is the same test every other feature here has had to pass.

**The second arena allocation a whole-body call makes may not show up for anybody.** It is the header block kept before the body reads over it ([ADR 187](./adr/187-a-head-that-outlives-its-body.md)), a bump and a `memcpy` inside the noise of a round trip; head and body in one buffer is the shape if it does show.

**What would settle it:** a caller for whom it shows.

### `nilo_job`

**`stats` is three numbers for the whole queue.** What an operator wants on a dashboard is how old the oldest `queued` row is (the lag) and the counts by kind, so that a thousand queued thumbnails and one queued invoice do not read as the same number. One more query, run only when asked.

**Needs:** a dashboard.

**`job.Memory` scans its slots.** 3–6 µs a claim over a few thousand fixed slots under a spin lock. Fine for a test and for the small program it is for; a heap would be 200 ns and an allocation-free heap somebody writes.

**Needs:** a memory queue big enough to notice.

**A worker started under `app.start(io)` and never `listen()`ed is a worker nobody stops.** `serveOn(io)` for a worker process returns when cancelled, and cancelling it is the caller's — there is no signal handler here, because the one in `http/` belongs to the server. A worker binary writes the four lines that catch SIGTERM and cancel the future.

**Needs:** a caller who has written those four lines twice.

**Whether a job has a result.** `status(id)` says `done` and not what came of it: the URL of the export, how many rows the import took, the thumbnail's key. Today every "is it ready?" route builds a table of its own to hold that. A `pub const Result = T` on the kind, a `result` column written as JSON when `run` returns one, and `jobs.result(scope, id)` to read it is the shape; the cost is a column that is null on most rows.

**What would settle it:** a caller whose second table exists only to answer that route.

**Whether a job may say how many of it run at once.** "At most two calls to the payment provider in flight" is a `nilo.Gate` inside `run` today, which works and is invisible to the queue: a third row is claimed, waits at the gate, and holds a worker while it does. A per-kind ceiling the claim respected would leave the worker free.

**What would settle it:** a caller with a provider that rate-limits harder than their workers count.

**Whether a claim should take ten rows rather than one is not measured.** A Postgres claim is 1.2 ms across a Docker port ([`job.md`](../bench/result/job.md)), and the price of ten is ten rows held by a worker that may die.

**What would settle it:** `bench-job` extended to several workers, on a box.

**Whether `LISTEN/NOTIFY` is worth a pool connection held open is not known.** A push wakes a worker in the same process ([ADR 160](./adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)), so `poll_ms` is only the latency of a row a *second* binary pushed.

**What would settle it:** who is running two processes on one queue, and what they wait.

**Whether sixteen workers on one SQLite file cost the lock is not measured.** A single claimer handing rows over a channel takes fifteen of them off it, and ADR 160 chose the wake without measuring the lock.

**What would settle it:** a queue on one SQLite file with more workers than cores, on a box.

### `nilo_s3`

**`COPY`.** Where S3 stops being bytes at a key and starts being a document format, and it carries its own trap for whoever adds it: S3 can answer a copy with **200 and an error in the body**, so a client that checks the status is wrong.

**Needs:** a caller who wants it enough to hold the XML.

**Whether payloads are hashed waits on what a request costs through TLS, which is not measured.** The plaintext numbers carry a SHA-256 over every body that the HTTPS ones would not, and neither corrects the other on paper.

**What would settle it:** the same runs against a MinIO with a certificate. An afternoon.

**Whether caller-set `x-amz-meta-*` headers cost enough to refuse is not priced.** SigV4 signs a sorted header list: a fixed set makes it a constant, and letting a caller add one puts a sort in every request.

**What would settle it:** the sort, priced, brought by a caller who wants the feature.

### `nilo_sql`

**Children are one level deep, and only through a reference of one column.** A Row's `[]const C` field is read by one statement for every parent, keyed by each parent's position in a list of one value apiece ([ADR 218](./adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)); a child with children of its own is refused, and so is a reference of several columns. The second is the list carrying a row of values per parent (`unnest` takes several arrays, `json_each` a list of lists), and the first is the same pass run once more per level over the children just read.

**Needs:** a caller with a screen that nests three deep, or a table keyed by a tenant and an id that has children.

**There is no upsert of many rows.** `insertMany` is one statement over `unnest` on Postgres and an upsert is one row; `unnest` plus `ON CONFLICT` is the same statement with the upsert's tail.

**Needs:** the call's name beside `insertMany`, and whether it answers the rows it wrote.

**`.now` is a default and a `.set`, not an insert value.** An insert that wants the database's clock needs a migration default or a bound `Timestamp.now()`, which is the application's clock.

**Needs:** whether `.now` may stand in an insert's value struct, and what the field's type says when it does.

**Two reads copy more than they need.** A `[]const Uuid` column costs one allocation an element and a copy, where the sixteen bytes could be read straight out of the array payload into one list, and a Postgres row larger than the connection's buffer is placed in the arena by pg.zig and then kept again column by column.

**Needs:** a number from a list screen of uuids, and a caller with rows that size.

**A read pays two small costs it could skip.** A count over children used in `.where` is written twice, in `WHERE` and in the select list, and Postgres runs the identical subplans twice; a `LATERAL` join computes it once ([sql.md §26](../bench/result/sql.md#26-small-costs-a-read-pays)). A grouped Row reaching one table through `nilo_through` and through an aggregate's filter joins it twice under two aliases.

**Needs:** the `LATERAL` form for Postgres and what SQLite writes instead, and one join shared by a through and a filter that reach the same table.

**Files import each other in two rings.** `types` and `wire` import each other, and `ordering`, `shape`, `statement`, `table` and `where` form one ring: `table` reaches `where` for three clock helpers, `ordering` reaches `statement` for `Direction` and `Tie`, and `shape` and `statement` share seventeen names. `assertDialect` (`dialect.zig:1573`) does not check `has_extensions`, `has_functions`, `view_repeatable_head` or `script_stop_on_error`, which `migrate.zig` and `migrations.zig` read, and `migrate.zig:908` compares `D.name` with `"sqlite"` where a capability belongs.

**Needs:** whether the rings are worth breaking, and the four capabilities added to `assertDialect`.

**Whether a statement under `.hop` should step a batch of rows a hop is not measured.** `next()` hops once per row (`sqlite.zig:938`), and [`sql.md` §15](../bench/result/sql.md#15-a-statement-under-hop-with-a-thread-of-its-own) measured a `find`, an insert and a slow query, never a scan.

**What would settle it:** a scan of ten thousand rows under `.hop` against `.in_fiber`, then against a batch of 64 a hop. An afternoon.

**What the write half of the ten-way comparison costs under contention is not measured.** `live.zig` proves `.update_nowait` and `.update_skip_locked` do what they say, and nothing says what either costs, or where `FOR UPDATE SKIP LOCKED` stops scaling as a queue.

**What would settle it:** the harness, which exists, on a box where the generator, the database and ten candidates are not sharing eight cores.

**A fiber that queues for the SQLite writer it already holds is told it might be, not that it is.** The wait is bounded ([ADR 107](./adr/107-a-wait-for-a-connection-has-a-bound.md)) and ends in a `TimedOut` naming the likely cause; telling that apart from an honestly busy database needs to know which fiber holds the writer.

**Needs:** `std.Io` handing a Service a fiber identity, or a design that gets one without it. Last checked at 0.16.0.

### `nilo_http`

**A HEADERS frame on an HTTP/2 stream the connection has already forgotten ends the connection.** A stream at or below the highest id seen and no longer in the table is answered with a connection `PROTOCOL_ERROR` (`h2conn.zig`, `onHeaders`). RFC 9113 §5.1 allows that for a stream closed long ago, but a client's trailers in flight when the server answered early and forgot the stream would take every other stream on the connection down with it. With the dynamic table at 0 the block costs nothing to decode and ignore, which a stream reset but still running already does (stage 6.1).

**What would settle it:** a client seen sending trailers after an early answer, or h2spec or a browser in stage 7 tripping it.

**Client certificates on a TLS listener.** The library has `client_auth` with a CA bundle and `.require`/`.request`; nothing in `Options.tls` names it, and nothing on `Ctx` would say who the client was. The second half is the design question: a verified subject is request data, so it wants to be a typed argument the way `Session(T)` is, not a header.

**Needs:** the service mesh that wants it, and the answer to what a handler is handed.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**Session resumption on a TLS listener.** Every connection is a full handshake, about 300 µs of CPU on the machine in [`http.md`](../bench/result/http.md), and a client that reconnects per request pays it per request. The library has no session tickets; when it does, the option is a key to encrypt them with and a lifetime, and the number to re-measure is that one.

**Needs:** the library first (the HelloRetryRequest entry), then a deployment whose clients reconnect and cannot sit behind a proxy.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**More than one certificate on a listener, chosen by SNI.** One `CertKeyPair` per listener today. Two names on one certificate is the answer for most of the cases; the one it does not cover is two tenants whose certificates cannot share a file.

**Needs:** that deployment.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**An extra listener that asked the kernel for a port cannot say which one it got.** `boundPort()` answers for `port`, the first listener, and an entry in `also` with `.port = 0` binds fine and reports nothing ([ADR 213](./adr/213-a-server-answers-on-more-than-one-address.md)). It costs the tests something already: they give a second listener a unix path rather than a port, because a path is knowable and a kernel-chosen port is not. The shape is `boundPorts()` returning the lot, or `boundPort(n)`.

**Needs:** somebody who binds more than one listener to port 0 outside a test, or a test here that cannot be written with a path.

**A stream is never compressed, and neither is an event stream; and gzip is the only coding.** `app.compress` gzips a whole body on a compressor borrowed for the CPU it takes and handed back before the socket is written, which is what keeps one compressor per thread enough ([ADR 211](./adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)). A stream has no whole body and would hold its compressor across every write, so its shape is a second pool larger than the thread count and chunked framing; an event stream must never be buffered and stays out on principle. Brotli and zstd were measured and refused ([`decided.md`](./decided.md)); a faster `std.flate` is the entry waiting on zig.

**Needs:** a caller streaming something text and large enough that the bandwidth matters.

**Direction:** [A stream is one shape](./roadmap.md#a-stream-is-one-shape)

**A `testing.Conversation` does not share a `testing.Client`'s cookie jar.** A test that signs in over HTTP and then opens a socket copies the cookie across with `setHeader` by hand ([ADR 091](./adr/091-a-websocket-route-can-be-driven-from-a-test.md)).

**Needs:** a second test that has had to copy it.

**A gRPC connection's message budget is not an option.** The budget is `max_body`, or the largest limit a route raised to with `nilo.maxBody` (at least 64 KiB), and a call is charged its compressed bytes, its inflated copy and the copy its route reads it into, so a Collector sending 4 MB batches gets about two running at a time per connection at `max_body` 16 MiB and the rest wait ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md#what-the-budget-does-to-an-opentelemetry-collector)). Waiting replaced the refusal and made a small budget slow rather than lossy; a budget sized from the caller's batches is what would let more run at once.

**Needs:** a caller whose throughput per connection is held back by how many calls run at once, rather than by its own work, with the batch size and consumer count that show it.

**Request bodies sent as `Content-Encoding: zstd` are a 415.** Only `gzip` is decoded ([the guide](./guide/requests.md#reading-the-body-yourself)), and an OpenTelemetry exporter can send `zstd` as well. Decoding it needs a C library nilo does not carry, and the shape that is already on record is the `-Dlibdeflate` one ([ADR 248](./adr/248-gzip-is-libdeflate-when-a-build-asks-for-it.md)): a build flag, the library compiled `ReleaseFast` from its release tarball so a build without the flag fetches and links none of it, the same `max_body` check against the announced size before a byte is decoded, and the binary cost written into ADR 017's running total. Whether the compiled library is also exported as a module applications can import (one list of libzstd's files to maintain instead of one in every consumer's `build.zig`) is part of that decision. This is the request side only; zstd for responses was measured and refused ([`decided.md`](./decided.md)).

**Needs:** a decision to decode zstd request bodies, and a caller sending them that cannot be told to send gzip; then the flag's cost in stripped `ReleaseFast` bytes and the allocation the decoded body takes, measured the way ADR 248 measured libdeflate.

**`nilo.blocking.forEach`: fan-out that counts against the pool's limit.** A blocking call that splits CPU-bound work across threads of its own escapes the pool's ceiling ([the guide](./guide/services.md#a-blocking-call-that-fans-out)). The shape that would keep it inside is `nilo.blocking.forEach(n, ctx, work)` running `work(i)` on pool workers under the same limit, so a burst of searches cannot take more than the pool allows. `nilo.blocking` is a function today and would have to become something that can carry a declaration, and a task that waits for its own children on the pool it runs on can deadlock it once every worker is a waiting parent, which is the part the design has to answer.

**Needs:** a second caller that fans out inside a blocking call, and a measurement of how many threads a burst of such calls takes at the pool's ceiling against what the caller's own per-call cap leaves.

**What `permessage-deflate` would cost per connection is not weighed**, against the 4,669 bytes an idle one holds.

**What would settle it:** a compressor per connection, weighed. An afternoon.

**Whether `app.metrics`' shared atomics and `Stop.in_flight`'s two read-modify-writes cost anything on many cores is not known.** Four interleaved pairs put the metrics inside the noise on two cores, which is the weakest place to look for cache-line contention, and whether response bytes and sockets should be counted too waits on the same number. Per-thread lanes for `Stop.in_flight` measured −1.1% on the same two cores with the sign changing, and the arithmetic caps the gain at 1–2% of sixteen cores ([`http.md`](../bench/result/http.md#what-the-two-atomics-a-request-always-makes-cost-on-two-cores)).

**What would settle it:** the same pair on eight cores, both counters at once, on a box. The fix is already named for both: shard per executor, pad to 64 bytes, sum at scrape or at drain.

**Whether `keep_bytes = 64 KiB` a thread is the right size is not known.** Every WebSocket figure is a 64-byte payload that never leaves the first page; a 60 KiB message at a thousand a second is where `scratch.zig` starts refusing spares.

**What would settle it:** the interpretation of `bench/compare/wsload/` with `-payload`, whose run exists. An afternoon.

**What kernel TLS would buy a TLS listener is not measured.** The library has a `Ktls` mode in which the kernel does the record layer after the handshake, so the 33 KB of buffers go away and every read and write is one syscall shorter. The buffers already cost nothing at idle ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md)), so the win is the page and the half microsecond a request, if it is a win.

**What would settle it:** `bench-tls-server` with `Ktls` against without, `bench/mem.py --tls` and `wrk` over `https://`, on a Linux kernel with `tls` loaded.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**0.05–0.1% of short-lived connections log "handler … failed after answering: WriteFailed", and whose fault it is is not known.** It is a response, or a WebSocket's 101, written to a socket the client had already reset, under a client (`gcannon -r 10`) that resets only after reading its tenth answer: 403 in 879K connections on HTTP, 934 in 794K on WebSocket, 163 in 435K on the one-acceptor build, so older than ADR 200. gcannon's own `read` error count is the same order and not the same number ([`http.md`](../bench/result/http.md#a-reset-between-frames-is-a-client-that-has-gone)). If it is the client's, the line is still ADR 022's misreport on a reset rather than a timeout.

**What would settle it:** `tcpdump` on one such connection, both sides, or gcannon with `--json` for the per-error breakdown against the server's count. An afternoon.

**A ClientHello split across two records is refused by the TLS listener rather than reassembled** ([tls.zig#36](https://github.com/ianic/tls.zig/issues/36)). Every client ADR 212 tried sends it whole; the one that does not, or a middlebox that fragments, gets a failed handshake rather than a slow one.

**Needs:** [ianic/tls.zig](https://github.com/ianic/tls.zig), `handshake_server.zig`. Last checked at `e04ae44` on `zig-0.16.x`.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**Plain HTTP sent to a TLS port is held as a 12 KB record that never finishes rather than refused on sight.** A record's length is read before its content type is checked, and the header deadline is what ends it, which is why `header_timeout_ms` bounds the handshake ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md)).

**Needs:** the same repository, `record.zig`. Last checked at `e04ae44`.

**Direction:** [A listener can face the internet with nothing in front](./roadmap.md#a-listener-can-face-the-internet-with-nothing-in-front)

**Every request on HTTP/2 spawns a fiber, where HTTP/1.1 runs it on the connection's.** A unary gRPC call is 767 to 773 ns in process against a routed HTTP/1.1 `GET`'s 410, and a routed `GET` over HTTP/2 is 963 to 971 ns ([`bench/result/http.md`](../bench/result/http.md#what-any-request-on-http2-costs)); the Engine's spawn is not in the profile, and a real server held 947k to 1,016k requests a second under `h2load` all the same. Now every request can arrive on HTTP/2 ([ADR 259](./adr/259-http2-is-a-framing-of-every-request.md)), a browser's small `GET`s pay it too. A finished call's fiber taking the connection's next stream, rather than ending, would pay the spawn once per burst.

**What would settle it:** the spawn's share of a `GET` over HTTP/2 measured through the Engine (not inline, as `zig build profile` does), and the same row with a fiber kept for the next stream.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

**A file on HTTP/2 over plain TCP has no `sendfile`.** Its pieces are read into frames ([ADR 260](./adr/260-a-request-on-http2-runs-from-its-headers.md)); a frame header written and its payload sent from the file would take the copy out for h2c, which is a proxy's upstream and not where a browser meets a static-heavy site.

**What would settle it:** a deployment that serves files to a proxy over h2c, and the cost on record: a 64 MiB file over h2c is 3.2 GB/s against HTTP/1.1 `sendfile`'s 6.7 to 7.3 on loopback, one stream, with the file read 64 KiB at a time ([`bench/result/http.md`](../bench/result/http.md#what-a-request-on-http2-costs-when-its-answer-is-a-pipe)).

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

**Priorities on HTTP/2 are ignored.** Answers ready at once are written in stream order; a browser says which matter first with RFC 9218's `priority` field, and nginx and h2o follow it, so a page whose images are ready before its CSS paints later than it would.

**What would settle it:** a page load in Chromium over HTTP/2 after stage 7 with and without RFC 9218's urgency honoured, its largest contentful paint on record.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

**A Connect client's `Connect-Timeout-Ms` is not read.** A gRPC call's `grpc-timeout` becomes the request's deadline ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md)); a Connect call names its own the same way in milliseconds, and nilo answers it with the route's deadline or none, so a client that gave up is still worked for. Its failures already go out in Connect's shape ([ADR 257](./adr/257-a-connect-client-is-told-its-failure-in-connect-words.md)), `deadline_exceeded` included once a deadline fires.

**What would settle it:** a Connect client that sets a timeout against a message route, or a decision to read the header where a message route reads its `Content-Type`, with the cost on a route that has none measured.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

**A Connect GET is a 405.** Connect lets a side-effect-free unary call be a GET with the message in the query (`?message=…&encoding=json`, base64 for protobuf), so a browser or CDN can cache it; a message route registered with `app.post` answers it as any route answers a verb it was not registered for. A method registered with `app.get` reads a message from the query's fields, not from `message=`.

**What would settle it:** a caller whose Connect client is set to use GET, or a design for reading `message=` that does not put a branch on every GET.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

**A handed-over event stream on HTTP/2 weighs 6.2 KB or 12 KB at 10,000 streams, depending on how fast they were opened.** [`http.md`](../bench/result/http.md#what-an-event-stream-handed-to-the-http2-connection-costs) measured the same server, streams and client twice: opened 1,000 at a time, 6,190 to 6,253 bytes a stream; in one step from 1,000 to 10,000, 11,976 to 12,153. A parked stream and an HTTP/1.1 one do not move with it. What a stream holds that a test can count is about 3.4 KB (the `Stream` 680 bytes, its arena 1,428, the lists, the pipe and the state), and the arena and the `Stream` are 2.1 KB of it that the hand-over could give back.

**What would settle it:** the same 10,000 with the handler fibers on the connection's thread, and the allocator's own count at both readings.

**Direction:** [A request is one thing, whatever framing carried it](./roadmap.md#a-request-is-one-thing-whatever-framing-carried-it)

---

## How this file is written

Nine rules. They are why the file has the shape it has, and adding to it means matching them.

**1. Nothing built is in here.** The moment something ships, its entry leaves entirely: no strikethrough, no "**Built**", no account of how it went. What was measured goes to [`history.md`](./history.md), what a reader has to change goes to [`CHANGELOG.md`](../CHANGELOG.md), and the decision goes to an ADR. A gap only *partly* closed keeps one sentence scoping what is left, never a paragraph about the half that landed. **The test is that this file reads top to bottom as work outstanding.**

**2. Nothing decided is in here either.** An answer that is the answer, a question closed so it is not re-derived, a feature refused with its reason, goes to [`decided.md`](./decided.md), and a risk with no mechanism under it yet goes to [`risks.md`](./risks.md#open). This file is what is still open.

**3. An entry is in one tier, by the evidence that it matters, and under its module.** The tiers are the table in [How to read this](#how-to-read-this). An entry is ranked by what it costs, measured or reproduced, and never by whether somebody has asked: an entry nobody can show matters yet is P3, not gone and not waiting. A module with nothing in a tier has no heading there, because an empty heading says nothing; a tier with nothing in it keeps its heading and says so, because an empty P0 is news.

**4. An entry opens with the whole claim, in bold**, and closes with one line: `Needs:` when the shape of the work is known, `What would settle it:` when the entry is a question or a number. An entry waiting on somebody else's repository names it, and the pin it was last checked at, on that line. Somebody who reads only the bold lines has to come away with the right idea of what is outstanding, and somebody who reads only the closing lines has to know what to bring. Neither is optional and neither is prose.

**5. An entry that serves a roadmap direction says so on one more line**, after its closing one: `**Direction:**` and a link to the direction's heading in [`roadmap.md`](./roadmap.md). `zig build docs-index` writes each direction's list of entries from these lines, and `zig build docs-check` refuses a link to no direction and a list out of step, so an entry that leaves this file leaves the roadmap too. Most entries serve no direction, and that is fine: the roadmap is where the framework is going, not everything that is open.

**6. An entry is at most a screen.** Longer than that means it is an ADR, with an entry here pointing at it. A body of work several entries serve is a direction in the roadmap; the entries stay here.

**7. No checkboxes, no dates, no owners.** A box implies a plan and this is not one. The tier is the only order this file has, and inside a module the entries are in no order at all.

**8. A number carries a link to where it was measured.** [`bench/result/`](../bench/result/) is the record. A figure with no run behind it decays into a claim, and a claim in a roadmap gets planned against, which is worse than a wrong number in a changelog.

**9. The whole list is ranked again at each release.** Cutting one bumps the version in `build.zig.zon`, and `docs-check` refuses this file until its `Ranked at` line names the new one, so the ranking is redone against the numbers `bench/release.py` has just produced. Every entry is read against the tiers again: a P3 whose closing line has come true moves up, an entry the numbers have overtaken moves down, and a P3 that a release has left exactly where it was is given a reason to stay or moved to `decided.md` with the reason it is not coming.

Adding a module means a heading for it under whichever tiers have entries for it, and nothing else: there is no index to keep in step.
