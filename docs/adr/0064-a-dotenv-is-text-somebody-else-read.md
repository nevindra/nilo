# A `.env` is text somebody else read

[ADR 0043](./0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)
refused file formats and listed `.env` as the one to reconsider: *it is a file
format, so it is on the far side of the refusal — but it is also fifty lines and
the seam already exists.* The roadmap held it as an open question rather than a
queued item, and this is the answer.

The refusal was never really about formats. Read the argument it actually made
and it is about **dependencies**: `sam701/zig-toml` is ~2,000 lines that every
importer of `nilo_config` would fetch, and `kubkon/zig-yaml` skips 322 of the
~400 cases in the official suite. Neither sentence says anything about a file
whose whole grammar is `NAME=value`, needs no dependency at all, and exists to
hold exactly what this module already reads.

So the line moves to where it was always doing the work.

## What was decided

**`nilo_config` does not open a file. That is the refusal, and it replaces
"does not parse a file".**

`Dotenv` takes text, not a path:

```zig
const text = std.fs.cwd().readFileAlloc(arena, ".env", 64 * 1024) catch "";
const file = config.Dotenv{ .text = text };

const read = config.from(Settings, config.layered(.{
    config.Env{ .environ = init.minimal.environ },  // a set variable wins
    file,                                           // the file is the floor
}));

try file.report(stderr);   // writes nothing when the file is clean
const settings = read.value() orelse {
    try read.report(stderr);
    std.process.exit(2);
};
```

Four things follow from taking text, and each of them is a property ADR 0042 or
0043 already bought:

- **It allocates nothing**, because it holds the caller's slice and hands back
  slices into it. `Fixed` and `Env` already work this way and carry the same
  contract: the text has to outlive the Config.
- **It imports nothing** — no `std.fs`, no allocator, no error set about a file
  that was not there.
- **`zig test config/dotenv.zig` runs every line of it** against string
  literals. That is the entry condition for the bottom layer (ADR 0042), and a
  module that opened files would need a fixture on disk to test the parser,
  which is the tell that it had moved layers.
- **Where the text came from stays the program's business.** `readFileAlloc`,
  `@embedFile`, a Kubernetes ConfigMap already in memory, a decrypted blob.
  None of that is this module's to know.

**Sources go in an order, and the first one with the name answers.**
`config.layered(.{ a, b })` is a comptime tuple, `inline for`, no allocation and
no merged map. A `.env` that could not be overridden by a real environment
variable would be the wrong shape — the file is what a machine has when nobody
said otherwise, and a set variable is somebody saying otherwise.

**A line that is not a setting is reported, not skipped.** This is the half that
justifies the module owning the grammar at all rather than shipping an example.
A `.env` with `DATABASE_URL postgres://localhost` on line 7 — no `=`, the typo
everybody makes once — read by a lenient parser becomes `DATABASE_URL is not
set` about a file that plainly sets it, and the fifteen minutes that follows is
precisely the failure ADR 0043 exists to stop. So `Dotenv` carries the four
verbs `Read` already has:

```
2 lines are not settings:
  line 2 has no `=`, so it sets nothing
  line 3 sets "MY KEY", which is not a name an environment variable may carry
```

`failed()`, `failedCount()`, `failures()`, `report(w)` — the same names doing
the same jobs, so a person who has read one has read the other. `report` writes
nothing when there is nothing wrong, which is what lets the canonical `main`
call it without a branch.

**The grammar is small, and what it refuses is the decision.** `NAME=value`,
blank lines, `#` comments on their own line, `'` and `"` quoting, an optional
`export ` prefix, and CRLF. No escapes, no multi-line values, no `${OTHER}`
interpolation, and **no comment after a value**.

That last one keeps `PASSWORD=abc#123` intact, and it pays for itself twice:
`PORT=8080 # the port` becomes

```
PORT has to be a whole number, not "8080 # the port"
```

which tells somebody exactly what happened, from machinery that already existed,
without this file guessing where a comment started. **A strict rule that reports
itself beats a lenient one that guesses.**

**Four reasons a line is not a setting, and they are all about shape.**
`no_equals`, `empty_name`, `bad_name`, `unbalanced_quote`. Whether the value is
any good is `convert.Reason`'s question — `PORT=soon` parses perfectly here and
fails there, and that split is what keeps this file from growing a second
opinion about types. It is ADR 0043's "four, and it stays four" one level down.

**A report never quotes a value.** The one place this departs from
`Read.report`, and it is deliberate: a `.env` is where a password lives, and a
startup message is what reaches a log aggregator. The line number is what
somebody needs to find the line. A name is quoted only where the name is what
went wrong.

## Why not the alternatives

**`config.fromDotenvFile(T, ".env", gpa)` — open the file here.** The obvious
API, and it costs every property above. It brings `std.fs`, an allocator, an
owned buffer, and a decision this module has no business making (is a missing
`.env` an error?). It also puts a fixture on disk into the test suite, which
breaks the entry condition ADR 0042 set for this layer. All of that to save
three lines in `main`, in a program that has an allocator open anyway.

**Ship the `.env` reading as an example instead of a module.** Tempting, because
the grammar is fifty lines. It fails on the half that is not the grammar: an
example does not carry the bad-line report, and an example copied into a project
is exactly where "skip the line quietly" gets written. The reporting is the
feature; the parsing is the part anybody could do.

**Let a malformed line be skipped.** What every `.env` library does. Refused for
ADR 0043's own argument: a module whose entire reason for existing is that it
names every bad setting at once cannot silently drop the line that explains why
one of them looks unset.

**Report a bad line as a Config failure, in one list.** Considered and refused —
they answer different questions and neither can answer the other's. "Line 2 is
not a setting" is about the file; "DATABASE_URL is not set" is about the Config,
and stays true even if the name was never in the file. Merging them would mean
the source knowing what a Config is, which inverts the dependency that makes
`Fixed`, `Env`, `Map` and `Dotenv` interchangeable. A program prints both, in
that order, and the two-line `main` above is the whole cost.

**Last-wins for a duplicate name**, which is what node's `dotenv` does. Refused
for `Fixed`'s rule: the first pair with a name wins, so a caller can put
overrides in front of defaults. One rule in one module beats matching another
ecosystem's.

**A trailing `#` comment.** The ambiguity has no good resolution —
`PASSWORD=abc#123` is a real value and `PORT=8080 # the port` is a real comment,
and no rule tells them apart without quoting rules that need escapes, which need
a lexer. Refusing is one sentence in the doc and one legible error at runtime.

**Merge the layers into a map at startup.** An allocation, a hash, and a copy of
every value, to save a string comparison that happens a dozen times in the life
of the process. `Fixed`'s doc comment already argued this and the answer did not
change for having two layers.

**A vtable so layers could be a slice.** Same answer ADR 0043 gave for the
source shape, and ADR 0041 gave for a Scope: a comptime check refuses an
unsuitable type in a sentence and generates the code a direct call generates.
The tuple is written at one call site and never grows at runtime.

## What it costs

Put against the four axes
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | **none**, and none anywhere. Nothing in this module calls an allocator; a `.env` is scanned in place, before the socket opens. |
| Memory per idle connection | **none.** Nothing here is per-connection. |
| Throughput and p99 | **none.** No framework path changed; no file in `http/` was touched. |
| Binary size | **zero** for a program that reads a Config and never names `Dotenv` or `layered`, and **6,448 bytes** for one that does. |

Both halves measured rather than assumed, stripped `ReleaseFast`, by ADR 0043's
own method — two programs identical except for the feature, with `report`
reachable in each so the figure is the realistic one rather than the flattering
one.

| | Bytes |
|---|---|
| Reads a Config, against a `git worktree` of the parent commit | 237,528 |
| The same program, against this commit | 237,528 |
| The same program, plus a `.env` layered under the environment | 243,976 |

The first two are byte for byte, which is the claim worth checking rather than
assuming: `Dotenv` and `Layered` are `pub` in `config.zig`, and Zig analyses a
`pub` declaration nobody names not at all. A project that keeps reading its
settings out of the environment pays for this ADR exactly nothing.

The 6,448 bytes are the parser, the four sentences, and the report — for a
program whose whole job is to read two settings, so the proportion flatters
nothing. It does not grow with the size of the `.env`, which is scanned in
place.

The four new Refusals cost **142ms** of `zig build test`, measured warm:
10–11ms each except `config_layered_not_a_source` at 111ms. That is the shape
ADR 0043 recorded for `config_unknown_field` at 149ms and for the same reason —
its `@compileError` is reached through a generic function rather than from the
type itself. The other three stop at the type, which is why they are an order of
magnitude cheaper, and all four stay far under the ~270ms each
[ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md)
records for the framework's own: they analyse a module that imports nothing, so
there is no Engine in front of the failure.

## Consequences

- **ADR 0043's "it does not parse a file" is superseded.** The refusal is now
  *it does not open one*. Everything else in that ADR stands, including both of
  the parser arguments — which is the point: the sentence that moved was never
  carrying them.
- **`checkSource` moved from `read.zig` to `source.zig`**, because "what is a
  source" belongs where the sources are and `Layered` needs it too. It gained a
  `isSource` predicate beside it for the per-layer check.
- **The config Refusals go from 5 to 9.** Three are `layered`'s three ways to
  be written wrong — the tuple forgotten, the tuple empty, a layer that is not a
  source. The fourth closes a gap that predates this change: `checkSource`'s
  missing-`get` branch had no program of its own, because `config_not_a_source`
  hands over a `comptime_int` and fails the container check first.
- **`CONTEXT.md` stops listing "dotenv" among the words to avoid.** It is a type
  now. What it still avoids is *configuration file*, because the module does not
  have one — the program does.
- **The roadmap's open question closes and leaves entirely.** What stays open in
  that module's list is the prefix being per-reading, `config.Env` being POSIX
  only, and whether a Config can mark a setting secret — the last of which this
  change makes slightly more interesting, since `Dotenv.report` now demonstrates
  a value never being printed.
- **Nothing here reads a secret from anywhere but text already in memory.** A
  vault, a KMS call or a file an orchestrator mounts still needs IO, and that
  seam is still where ADR 0042 put it: in front of this whole layer.
