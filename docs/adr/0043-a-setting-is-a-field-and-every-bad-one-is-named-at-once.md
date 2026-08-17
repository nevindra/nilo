# A setting is a field, and every bad one is named at once

A service reads its port, its database URL and its log level before it opens a
socket. nilo had nothing for that, so the answer was `getPosix` and
`std.fmt.parseInt` per setting, with a sentence written by hand at each one —
and, because that is what `try` does, a program that stops at the first mistake.
Fix `DATABASE_URL`, run again, discover `PORT`, run again. Four restarts to
learn four things the process knew on the first one.

The shape nilo already has for this is in
[ADR 0036](./0036-a-binding-hands-its-failures-to-the-handler.md): a binding
that hands its failures back instead of ending the request, so a handler can
name every field that broke rather than the first. Startup is that problem with
the audience changed — an operator at a terminal instead of a REST client — and
nothing about the argument depends on there being a request.

[ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md) made the
bottom layer a place a second module can go, and this is the second one.

## What was decided

**A Config is a struct of your own, and the field is the setting.**

```zig
const Settings = struct {
    port: u16 = 8080,
    database_url: []const u8,
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,
};

const read = config.fromEnv(Settings, init.minimal.environ);
const settings = read.value() orelse {
    try read.report(stderr);
    std.process.exit(2);
};
```

The field name upper-cased is the variable — `database_url` is read from
`DATABASE_URL` — a default is what "not set" means, and a `?T` is a setting that
may be absent. That is
[ADR 0012](./0012-the-query-string-is-a-struct-of-your-own.md)'s sentence about
a query string with two words changed, and the repetition is the point: a person
who has read a `Query(T)` has already read this.

**Every bad setting is named at once, and that is the feature.** Not the
reading, which is forty lines. `value()` is optional the way ADR 0036's is, so
there is no way to reach past a failure into a half-filled struct and serve on a
port nobody set:

```
3 settings could not be read from the environment:
  PORT has to be a whole number, not "soon"
  DATABASE_URL is not set
  LOG_LEVEL has to be one of debug, info, warn, not "verbose"
```

**It reads `[]const u8`, not `Str`, and the module imports nothing at all.**
This is the decision the rest of them hang off, and it is argued below.

**It does not parse a file, and that is a refusal rather than a gap.** `Fixed`
is the seam: a program that wants TOML picks its own parser and hands the pairs
over. What this module owns is the half no parser does — a struct of your own,
filled or refused, with the failures collected.

> **Amended by [ADR 0064](./0064-a-dotenv-is-text-somebody-else-read.md).** The
> refusal is now *it does not **open** a file*, and `config.Dotenv` reads a
> `.env` out of text the caller supplies. Both arguments this ADR actually makes
> below — zig-toml's 2,000 lines that every importer would fetch, zig-yaml's 322
> skipped conformance cases — are about depending on somebody else's parser, and
> neither one reaches a fifty-line `NAME=value` scanner that needs no dependency.
> What was defended is intact: no allocation, no `std.fs`, and tests that run
> under a plain `zig test`. It was the summary that was too wide, not the
> reasoning.

**Four reasons, and it stays four.** `missing`, `not_a_number`,
`not_true_or_false`, `not_a_choice`. Whether the port is one this machine may
bind is the program's own question, and a reason set that grew to answer it
would be a validation language wearing a smaller name — the same sentence
ADR 0036 wrote about `Bound`, and it binds here for the same reason.

## Why not the alternatives

**Import `nilo_core` and share `http/convert.zig`'s pure half.** This is the
one ADR 0041 expected. It named `convert.zig` "the interesting refusal", said
*it is what a configuration module would reuse*, and deferred the decision until
there was a second caller to design against rather than a guess.

The second caller now exists and the answer is no, for a reason the guess could
not have contained. ADR 0042 made a property the **entry condition** for this
layer: *a module in the bottom layer runs under plain `zig test` or it is in the
wrong layer.* Sharing the converter means naming `nilo_core` for `Str`, and a
file that names a module cannot be run by a `zig test` that supplies none. The
two halves of ADR 0042's own table cannot both hold for any module that actually
uses the permission — see below.

The drift argument does not transfer either, and it is worth saying why rather
than trading it away silently. `http/convert.zig` keeps one copy of its
sentences because *a handler shows a field's failure next to a 400 from the
endpoint beside it*, and two spellings of one mistake is what somebody files a
bug about. A config report is written to stderr, once, before the socket opens,
by a process that is about to exit. It is never beside anything.

What it costs is forty lines of `tryConvert` in two places. What it buys is the
property the layer is defined by.

**`Str` for the text.** A `Str` is text that belongs to a request and goes stale
when it ends; the trap that enforces it is the module's whole reason for
existing. Settings are read once and held for the life of the process, so every
`Str` here would be a `Str.static` — a lifetime annotation on text that has no
lifetime question. `getPosix` hands back a slice of the block the operating
system gave the process, which outlives every use of it, and `[]const u8` says
exactly that and nothing more.

**Ship a TOML parser.** [sam701/zig-toml](https://github.com/sam701/zig-toml) is
~2,000 lines, arena-backed with a `Parsed(T)` that owns everything, already on
0.16's `std.Io`, and maintained. Writing one here means weeks to reach where
somebody else already is, on a problem that is not this repository's. Depending
on it means every project importing `nilo_config` fetches it, which is the
property [ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
spent a lazy dependency to protect.

**Ship a YAML parser.** [kubkon/zig-yaml](https://github.com/kubkon/zig-yaml) is
the measurement that settles this: 322 of the ~400 cases in the official YAML
test suite are on its skip list, and it is written by a Zig core contributor.
The failure mode of a partial YAML parser is also the wrong one — it misreads
real files quietly rather than refusing them.

**Return an error and let the caller ask why.** `error.BadConfig` with the
detail behind a second call is the shape most libraries have, and it is the one
that costs a restart per mistake unless the caller writes the loop themselves.
ADR 0036 already refused it for a handler.

**A vtable for the source.** An interface with a pointer and a function table
would let this take a source it has never heard of. Refused for
[ADR 0041](./0041-a-module-sits-where-the-loop-puts-it.md)'s reason about a
Scope: the comptime check refuses an unsuitable type in a sentence and generates
the code a direct call generates. Nothing here is on a hot path, so this one is
consistency rather than speed — but a second way of spelling the same idea in
one repository is its own cost.

**A marker for a name that is not the field's own** — `pub const nilo_env = .{
.database_url = "PGURL" }`, the way `nilo_table` names a table. Not built, and
listed in the roadmap. Every Config that has needed one so far has been able to
rename the field instead, and a marker added before somebody cannot is a
guess at what they will want.

## The tension ADR 0042 left, and which way this resolves it

ADR 0042's table says a tool module **may import `nilo_core`**, and its text
says a module in the bottom layer **runs under plain `zig test`** or it is in
the wrong layer. `nilo_id` imports nothing, so it satisfies both and never
asked the question.

They cannot both hold for a module that uses the permission. `zig test
config/config.zig` supplies no modules; a file naming `nilo_core` fails to
compile under it. So the permission and the entry condition are the same
sentence pointing opposite ways, and one of them has to give.

**The entry condition wins, and the permission is what it always was: a
permission.** A tool module *may* name `nilo_core` and pays for it with the
property that decides its layer — which makes naming Core a thing to argue for
rather than a default. `nilo_config` does not, and `zig test config/config.zig`
runs all 32 of its tests with no `build.zig` in the process.

That is not an amendment to ADR 0042 so much as the first reading of it under
load. It is written here because the next tool module will face it, and the
answer should not have to be worked out twice.

**`convert.zig` stays where it is, and the roadmap entry stays open.** It was
waiting for this module and this module is not it. What changes is that the
entry stops being a guess: the caller that would move it now has to be one in
the App or Service layer, because a bottom-layer caller cannot reach `nilo_core`
without giving up more than the sharing is worth. `percent.zig` — named in the
same paragraph, for signing a URL — is still the likelier one.

## What it costs

Put against the four axes
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | **none**, and none anywhere: a Config is read before the socket opens, into one fixed array sized while compiling, out of the environment block where it lies. Nothing in this module calls an allocator. |
| Memory per idle connection | **none.** Nothing here is per-connection. |
| Throughput and p99 | **none.** No framework path changed; no file in `http/` was touched. |
| Binary size | **zero** for a project that does not import `nilo_config`, and **3,392 bytes** for one that does. |

Both halves measured rather than assumed, stripped `ReleaseFast`, by the method
`docs/history.md` settled on:

| | Before | After |
|---|---|---|
| `example-hello` | 885,504 | 885,504 |
| `example-rest` | 1,031,744 | 1,031,744 |
| `nilo-hello` | 890,384 | 890,384 |

Byte for byte, and the same three numbers ADR 0041 and ADR 0042 recorded — the
third independent reading of one property, which is what makes it a property
rather than three coincidences. Nothing in `build.zig` hands `nilo_config` to
any artifact, so there is nothing for a linker to drop.

The 3,392 bytes are the other direction, measured on two programs identical
except that one reads its settings through this module and reports its failures
through it: 231,832 against 235,224. The Config is two fields and `report` is
reachable, which is the realistic case rather than the flattering one — a
program that never calls `report` pays less, and the number is quoted with it
included so that nobody discovers it later. It grows with the field count, not
with the number of readings: the table a `Read(T)` walks is one entry per field,
built once while compiling.

The Refusals cost **284ms** of `zig build test`, measured warm: 30–38ms each
except `config_unknown_field` at 149ms, whose `@compileError` is reached through
a generic function rather than from the type itself. That is well under the
~270ms each [ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md)
records for the framework's own, and the reason is worth keeping: these stop
while analysing a module that imports nothing, so there is no Engine in front of
the failure.

## Consequences

- **A Config is a Service like any other.** `app.provide(&settings)` and a
  handler asks for it by type. Nothing in this module knows that, which is the
  point — it links no server.
- **`CONTEXT.md` gains Config and setting**, and `Service`'s entry already lists
  config among the things a Service is.
- **The tool-module count is two, and the second one imports nothing either.**
  ADR 0042 called `nilo_id`'s zero imports a property of that module; two in a
  row makes it the shape to expect and Core-naming the exception.
- **`.env` is the obvious next ask and is not built.** It is a file format, so
  it is on the far side of the refusal above — but it is also fifty lines and
  the seam already exists, which makes it the first thing to reconsider if
  enough people write the same fifty lines. The roadmap holds it as an open
  question rather than a queued item.

  > **Settled by [ADR 0064](./0064-a-dotenv-is-text-somebody-else-read.md).**
  > `config.Dotenv` takes the text and `config.layered` puts sources in the
  > order they win. This bullet turned out to be asking the wrong question: the
  > choice was never `.env` against the refusal, it was where the refusal's line
  > actually sat.
- **Nothing here can read a secret out of anywhere but the environment.** A
  Config field is text the process was started with, so a value in a vault, a
  file mounted by an orchestrator or a KMS call is out — those need IO, which
  is the seam ADR 0042 already recorded as standing in front of this whole
  layer.
