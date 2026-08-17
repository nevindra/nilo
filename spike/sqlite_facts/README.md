# What SQLite actually does, before a Wire is written against it

[ADR 0074](../../docs/adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)
was written from SQLite's documentation and said so:

> Both SQLite behaviours above are stated from its documentation and are to be
> confirmed by a twelve-line program before this ADR is cited as evidence.

This is that program, run against zqlite 0.0.1 / SQLite 3.53.0 — the library
[ADR 0073](../../docs/adr/0073-a-file-has-no-socket-to-wait-on.md) chose, so
what it reports is what nilo would ship with rather than SQLite in the
abstract.

```
./run.sh
```

## What held

All five behavioural claims. Nothing in the design changes because of them,
which is the boring outcome and the one worth having on record:

| | claim | result |
|---|---|---|
| 1 | `:memory:` twice is two private databases | held |
| 2 | `file:…?mode=memory&cache=shared` is one | held |
| 3 | `PRAGMA journal_mode = WAL` in memory answers `memory`, it does not fail | held |
| 4 | the same statement on a file answers `wal` | held |
| 5 | a shared in-memory database is gone once its last connection closes | held |
| 6 | a read-only connection reads, and refuses a write | held |

Check 3 is the one the test story rests on, and it is worth saying out loud
that it **passes by returning the wrong thing quietly**: a suite that ran
entirely in memory would report a WAL configuration it never used, and nothing
anywhere would say so.

One expectation was wrong, and it was the write-up's rather than the ADR's: the
error a read-only connection raises is `ReadOnly`, not `ReadOnlyDirectory`.
That name is what the Wire maps, so getting it wrong would have turned a
deliberate refusal into a `QueryFailed` with the reason discarded.

## The one that was found by a test failing

Check 6c was added after the fact, and it is the most useful line in this
directory:

| | claim | result |
|---|---|---|
| 6b | a read-only connection to a **file** refuses a write | refuses, `error.ReadOnly` |
| 6c | a read-only connection to a **shared in-memory** database refuses a write | **writes** |

SQLite's URI `mode=` parameter takes precedence over the flags handed to
`sqlite3_open_v2`, so `mode=memory` hands back a writable connection whatever
`SQLITE_OPEN_READONLY` said.

That matters because ADR 0074 routes `db.raw` by its first keyword and calls
the read-only reader the backstop under that guess. **In memory there is no
backstop.** The Wire's own test asserted the refusal against an in-memory
database, failed, and that is how this was found — a reminder that the
in-memory shortcut is not merely a faster version of the real thing.

## What did not hold, and changed the ADR

**ADR 0074 said a pool connection holds "roughly 2 MB of page cache … held for
the life of the pool". That is the ceiling, not the cost.** `cache_size`
defaults to `-2000` — 2,000 KiB — and SQLite grows the cache as pages are
touched, never past it.

| 1 writer + 8 readers, 50k rows (2.9 MB) | total | per connection |
|---|---|---|
| opened, idle | 252 KiB | **28 KiB** |
| after every reader has scanned the whole table | 16,892 KiB | **1,876 KiB** |

Both are real and they are two different deployments. A service doing
primary-key lookups never leaves the first row; one running reports over a
table larger than the cache converges on the second.

## What that memory buys, in reads

The follow-up question the numbers above raise: if the ceiling costs 1.8 MiB a
connection when it is reached, what does lowering it cost? Reads are a counter,
so this is measurable here where a timing would not be.

**5,000 primary-key lookups over 200 hot rows** — the shape
[`bench/result/sql.md`](../../bench/result/sql.md) measures:

| cache | `pread64` |
|---|---|
| −2000 KiB | 10 |
| −512 KiB | 10 |
| −128 KiB | 10 |
| −32 KiB | 10 |
| −8 KiB | **15,005** |

**Three full scans of the 2.9 MB table**, which is larger than any cache here:

| cache | `pread64` |
|---|---|
| −2000 KiB | 2,261 |
| −512 KiB | 2,265 |
| −128 KiB | 2,265 |
| −32 KiB | 2,265 |

**The 2 MiB default buys nothing at either shape.** A hot working set fits in
32 KiB and reads the same ten pages whatever the ceiling; a scan larger than the
cache re-reads regardless, so 62× the memory is worth four reads out of 2,265.
Between 32 and 8 KiB the point-lookup case falls off a cliff — three reads per
lookup — which is the working set no longer fitting.

**This is not an argument for a small default**, and the reason is the limit of
the measurement rather than caution: the cliff sits wherever the *working set*
sits, and this one is 200 rows on a machine whose OS page cache holds the whole
file. A service with a hot set of a hundred megabytes has its cliff somewhere
this run cannot see. What the numbers do settle is that the memory worry was
overstated — a point-lookup service pays 28 KiB a connection, not 2 MiB — and
that lowering the ceiling for a scan-heavy service is close to free.

## What is not here

- **No timing.** Two shared cores; the counters are the honest half.
- **A database larger than RAM**, which is where SQLite's own page cache stops
  being a duplicate of the operating system's and starts being the only one.
- **Contention.** One process throughout. What `busy_timeout` does when two
  writers meet is the case ADR 0074's reader/writer split exists for, and it
  needs the Wire before it can be staged.
