# arsip — the plan

An application built to find out what nilo is like to use, one module at a
time. Each milestone adds one seam and ends with three things: code that runs,
a `curl` transcript that proves it, and whatever it cost written into
[`DX.md`](./DX.md).

**The order is not arbitrary.** Every milestone adds exactly one module to the
`imports` list in `build.zig`, so the friction of adopting a module is
attributable to that module rather than to the pile. The app is a document
archive because that domain reaches all eight without inventing a reason to:
documents have owners (passwords, ids), metadata (Postgres), bytes (an object
store), and somebody who wants telling about them (an outbound call, a socket).

| # | Milestone | Adds | The question it answers |
|---|---|---|---|
| 0 | Scaffold | `nilo_http` | Can a dependent outside the repository build at all? |
| 1 | The API | — | Does "the signature is the contract" hold when the domain stops being one flat struct? |
| 1b | The awkward corners | — | Forms, uploads, streamed bodies, blocking work, wildcards — everything a curated example skips |
| 2 | Identity | `nilo_config`, `nilo_pw`, `nilo_id` | What does adopting three tool modules cost when the guide points them at the reference? |
| 3 | A database that is a file | `nilo_sql` | What breaks when the same types have to be a table as well as a body? |
| 3b | The same code, a server | — | Whether "swap two lines" survives the swap, against a real Postgres |
| 4 | The bytes | `nilo_s3` | What happens to a `Str` that has to cross two Services in one request? |
| 5 | Outbound | `nilo_fetch` | Can a handler call somebody else's API on a deadline without owning the loop? |
| 6 | Live | — | A socket that outlives the request, and a page to watch it from. |
| 7 | The report | — | Both optimize modes, the memory number, and what should change in nilo. |

---

## M0 — Scaffold ✅

A `build.zig` written from `docs/guide/getting-started.md`, a health route, a
path param, and a test that calls a handler as an ordinary function.

The point is the vantage: arsip consumes nilo as a **path dependency**, so it
sees exactly what a dependent sees — the directories listed in nilo's
`.paths` — and nothing else in the repository. A file this app cannot reach is
a file `zig fetch` would not have shipped.

Done: `zig build`, `zig build run`, `zig build test` (Debug and ReleaseSafe).

## M1 — The API ✅

The domain, in memory, with no infrastructure anywhere: documents inside
folders, a body with a struct and a list inside it, query structs for filtering
and pagination, `PATCH` that can tell absent from null, a state machine that
answers 409, fail functions, a middleware and a resolved value, and the OpenAPI
document that falls out of it.

`examples/orders` already walks this ground. M1 goes past it deliberately —
enums in bodies, tagged unions, optional nested structs, a field name that is a
Zig keyword, a list of lists — because the claim under test is that the
compiler is the check, and a claim like that is only interesting where it might
break.

Done: 13 routes, 42 tests in both modes, `src/copy.zig` for the `Str` boundary.
Nothing on the list had to be dropped.

## M1b — The awkward corners ✅

M1 walked the JSON path, which is the path every framework's example walks. This
one goes at the surfaces a curated example is chosen to avoid, one route per
surface: a multipart form with a file in it, the bytes back out through a `*Ctx`,
a body too big to hold read in pieces, work that is not IO with and without
`nilo.blocking`, a wildcard, a `*const` service, a resolver built from another
resolver, and a body nine levels deep.

20 routes, 54 tests. The measurement worth keeping: with both worker threads
held by a handler that forgot `nilo.blocking`, an unrelated `/health` took
**3.635s**; with the same work wrapped, **0.0019s**. nilo warned about it on the
first request, with nobody else on the server.

## M2 — Identity ✅

`nilo_config` reads the settings out of the environment into a struct. `nilo_pw`
hashes the password; `nilo_id` gives every document a v7. A session cookie
carries the signed-in user, a middleware resolves it, and a group refuses
without one.

Three tool modules land at once because they arrive together in real life, and
because the reference is all there is for two of them — whether that is enough
is the finding.

**The claim under test was narrow and it held.** M1 authenticated on an
`X-Operator:` header. M2 replaced that with a sealed cookie and an argon2id
password behind it, and **`handlers.zig` and `intake.zig` did not change** — every
signature still says `Operator` or `Curator`, and the aliases at the top of
`handlers.zig` are there so that is checkable rather than claimed. What did change
is `authenticate`, which is the one function that ever knew.

23 routes, 40 tests in both modes. What the transcript proved, in the order it was
run:

- a bad `.env` line and a bad setting are two reports, and both name the problem
  without quoting the value: `line 2 has no \`=\`, so it sets nothing`,
  `ARSIP_LOG_LEVEL has to be one of debug, info, warn, not "loud"`;
- a 14-byte `ARSIP_SESSION_SECRET` is refused by arsip's own check, so the message
  can name the setting rather than the byte count;
- the first account is the curator; the second gets
  `only a curator can do that, and Budi is not one` from a resolver it never asked
  for;
- a wrong password and an address with no account answer the same sentence, and
  the two v7 ids sort in the order they were made (`01a01053…`, `01a01054…`);
- 2,000 bytes of PDF through a multipart form and back out byte-identical, with
  the row carrying `"filename":"q3.pdf"` and none of the bytes;
- 2.1 MB of NDJSON streamed in: `{"filed":40000,"skipped":1,"bytes":2228903}`.

The measurement worth keeping is the watchdog one, re-run at M2's scale. A handler
that holds its thread: **`/health` took 811 ms** behind it, and nilo said so —
`held its thread for 1136ms. Every other request being served on that thread waited
the whole time.` The same work through `nilo.blocking`: **0.0007–0.001 s**. The log
line for that `/health` says `83µs`, which is the useful detail — the request
itself was never slow, so nothing but the watchdog could have told you.

Two bugs found were arsip's own and both are worth remembering. A store method
copying its result onto `self.gpa` instead of the caller's arena leaked three
allocations a sign-up, and only the wire tests caught it — the store's own tests
freed by hand. And `nameOf(signed: Signed) []const u8` returns a slice into a
by-value parameter, which dangles: it came back `Sri  ahyuni ????|@?` in Debug.
Both are Zig rather than nilo, and both are the second-order price of "a session
may hold no slice".

Five new items in [`DX.md`](./DX.md), one of them the worst found so far: a type
with its own `jsonStringify` gets an OpenAPI schema that **contradicts what the
server sends**, which breaks every generated client that reads a `nilo_id` value.

## M3 — A database that is a file ✅

SQLite rather than Postgres, and **one store rather than both**: the accounts
move to a table and the archive stays in memory. One seam, so the friction is
attributable — which is the same reason the module list grows one line a
milestone.

`sql.Sqlite` is the reason this can be small. There is nothing to run beside the
process, so `zig build run` still works with one setting set, and persistence
costs a path with a default.

**What held.** The claim under test was the SQLite section's headline — *swap two
lines and the rest of the page is unchanged* — and for the query surface it is
true. `db.insert`, `db.one`, `db.find`, `db.count`, `db.update` are the calls the
Postgres half of the guide describes, and every one of them worked first time
against a file. `sql.Uuid` **is** `nilo_id`'s `Uuid`, not a second type, so a
column and a generated key are one value.

The store lost about ninety lines. M2's `Accounts` was an `ArrayList(*Row)` with
an arena per row and a `nilo.Mutex`, all of it in service of handing back a copy
that lives as long as the caller's request. What is left is the four rules that
are about accounts.

**What it cost at the call site: one word.** Every method took an `Allocator` and
now takes a Scope. `auth.zig` changed in five places and `handlers.zig` not at
all.

**What did not hold.** `public: sql.Uuid` does not compile against SQLite — the
error is zqlite's, three layers down, about a Zig issue. arsip writes its own
column type instead. Item 18 in [`DX.md`](./DX.md), and the sharpest finding of
the milestone after 16.

40 tests in both modes. What the transcript proved:

- two accounts through a real socket, the second not a curator, both with v7 ids
  that sort in the order they were made;
- **`kill` and start again, and `wati@example.dev` signs in with the same
  password and comes back with the same `public`** — the argon2id hash verified
  off the disk. The cookie issued before the restart still worked too, which is
  the sealed session doing what ADR 0035 says: no server state to lose;
- `WATI@EXAMPLE.DEV` is a 409, because the lookup and the `UNIQUE` are one rule
  (`COLLATE NOCASE`) rather than two that have to agree;
- an ordinary `sqlite3` client reads the file while nilo holds it open, and finds
  the id as text, the bool as 0/1, and the PHC string intact.

**The number.** Adopting `nilo_sql` with the SQLite Wire cost arsip
**1,223,696 bytes**, stripped `ReleaseFast` — 1,741,896 at M2 against 2,965,592
at M3, both built here rather than quoted, the M2 side from `git archive 735af19`
into a scratch directory. Of that, 524,840 is SQLite itself: `zig build size-sql`
reproduces the published figure **exactly**, which is the second published number
this project has checked from outside and the first that was right. The remaining
~699 KB is the rest of `nilo_sql` — row filling, the statement machinery, the
schema check, both dialects — which arsip did not have before.

**What was not measured, and why not.** Anything about SQLite's speed. Every
write path in this app goes through argon2id first, which is ~400 ms in a Debug
build and gated by `password_hashes_at_once` — four concurrent sign-ups took
~2.1 s each and six concurrent sign-ins ~0.4 s, all of it the hash. The database
is invisible next to that. A number would have been about `nilo_pw`, so there is
none.

## M3b — The same code, a server

The line at the top of `accounts.zig` swapped for `sql.Db` and a Postgres URL, and
nothing else touched. The question is narrow and worth its own milestone because
M3 already found where it fails: `sql.Uuid` goes back to being the right type, the
DDL has to move to a migration somebody else runs, and `insertMany` becomes
available. Whether that is *two lines* or *a day* is the finding.

## M4 — The bytes

`nilo_s3` against a real object store. Upload a document body straight through
to an object, serve it back with range requests, delete it when the row goes.
The seam under test is a `Str` that has to survive being handed from one Service
to another inside one request, which is where the lifetime rule stops being
theory.

## M5 — Outbound

`nilo_fetch` from inside a handler: notify a webhook when a document lands, and
import a document from a URL somebody gave us. Both bounded by `core.Limits`,
because an outbound call with no clock on it is the thing that takes a server
down.

## M6 — Live

A WebSocket feed of documents as they land, server-sent events for one upload's
progress, and a small static page to watch both from — served out of memory
with ETags.

## M7 — The report

Both optimize modes green. Memory per idle connection measured with
`bench/mem.py`, against the framework's published floor. The end-to-end script
that drives every milestone in one run. And `DX.md` turned into proposals: what
should change in nilo, in the shape `CONTRIBUTING.md` asks for.
