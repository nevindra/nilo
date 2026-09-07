# The document is a build artefact, not a thing you curl

nilo generates an OpenAPI document from handler signatures, and a port that had
been generating one from Go types said nilo's is the better document: named
operations, enum values, `format: "uuid"`, and header parameters since
[ADR 0163](./0163-a-header-a-handler-can-be-given.md).

It could only be got at one way — `GET /openapi.json`, from a server that is
listening.

That is a fine way to read it and a bad way to **produce** it. Their chain is

```
handler types → openapi.yaml → generated client → the frontend compiles
```

and `openapi.yaml` is a checked-in file. It is how a typed client is generated,
and its diff in review is how somebody sees a breaking change before it ships.
Producing that file by booting a server means `listen`, and `listen` runs
`db.checking` — so **a file describing a set of types ends up requiring a
migrated database**. That is not a build step anybody wants in CI.

Everything needed was already there: `openapi.write` is public, and `App`
collects `operations` as each route is registered, before anything resolves
chains or opens a socket.

## What it does now

```zig
try app.writeOpenApi(&out.interface);
```

after the routes are registered and before `listen`. No port, no database, no
network. The title and version come from `app.docs(.{ … })` when it was called
and from `Info`'s defaults when it was not, so a program that serves no document
can still write one.

**`buildDocs` now goes through the same call**, which is the part worth insisting
on: a checked-in file and a running server that describe two different APIs is
precisely the failure the checked-in file exists to prevent, and two call sites
building the same document from the same operations is how that starts. One
door, and a test asserting the served bytes contain the written ones.

## The alternatives that were rejected

**A `zig build openapi` step in nilo.** The step belongs to the project, whose
`main` knows its own routes; nilo cannot register them. What nilo owes is the
door.

**Taking `Info` as an argument.** It reads better in isolation and puts the title
in two places for any project that also serves the document. Borrowing
`docs_options` when it is there means the file and the served copy cannot
disagree about what the API is called.

**Making it `pub` on `openapi.zig` alone and letting callers pass
`app.operations`.** That is the version that already existed, in effect, and it
requires reaching into a private field. The operations list is `App`'s.

## What the first caller found

It worked unmodified — 30 KB, 32 operations, no database, no port, no network —
and turned up two things worth writing down.

**`App.provide` is not needed to write the document.** They nearly built a
stand-in `*sql.Db` to get registration to type-check, and did not have to:
`provide` is for the request path, and writing the document needs only the
operations, which are collected as each route is registered. That is what makes
the build step's binary genuinely clean — it never touches `nilo_sql` at all.

**One route list, called by both.** They moved registration into a `routes.zig`
that `main.zig` and the document step each call, for the reason `buildDocs` was
put through `writeOpenApi` rather than beside it: two lists is how a checked-in
contract starts describing a server that no longer exists, and the context
somebody forgets to register in one of them disappears with no error and no
failing test. **A build artefact and the running thing have to come off one
source, at every level** — inside nilo that is one call, and in a project it is
one route list.

## Consequences

- One public method, ten lines, and one call site moved onto it.
- Nothing measured moves: it runs before `listen` or not at all.
- A project can now check its API description into git and diff it in review,
  which is the workflow this was reported from and the one nilo could not
  support.
