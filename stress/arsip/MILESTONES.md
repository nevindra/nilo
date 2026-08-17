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
| 2 | Identity | `nilo_config`, `nilo_pw`, `nilo_id` | What does adopting three tool modules cost when the guide points them at the reference? |
| 3 | Postgres | `nilo_sql` | What breaks when the same types have to be a table as well as a body? |
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
Nothing on the list had to be dropped. Five findings, of which the one worth
acting on is the pair of byte-identical schemas a `Meta_Str`/`Meta_Text` split
puts in every generated client.

## M2 — Identity

`nilo_config` reads the settings out of the environment into a struct. `nilo_pw`
hashes the password; `nilo_id` gives every document a v7. A session cookie
carries the signed-in user, a middleware resolves it, and a group refuses
without one.

Three tool modules land at once because they arrive together in real life, and
because the reference is all there is for two of them — whether that is enough
is the finding.

## M3 — Postgres

Against the Postgres already running on this machine. The in-memory store from
M1 goes; the same structs become tables. Migrations, a transaction that has to
hold, pagination that has to match the query struct from M1, and the Scope seam
— a Service reaching request-lifetime memory without ever naming a `Ctx`.

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
