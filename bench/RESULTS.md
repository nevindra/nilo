# Benchmark results

Every run that changed a decision, and what it changed. Not the terminal, not a
commit body, not a sentence in a session — here, where somebody can re-run it.

The rule and the reasoning are in `CLAUDE.md`. The short version: a number with
no run behind it decays into a claim, and this repository has already published
two that were wrong ([ADR 0062](../docs/adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md),
[ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)). Each entry
says what was run, on what, at which commit, and which decision the numbers
moved. A run that changed nothing still earns an entry if somebody would
otherwise repeat it.

---

## `.env` as a source — binary size

**What it decided:** the binary-size row of
[ADR 0064](../docs/adr/0064-a-dotenv-is-text-somebody-else-read.md), and whether
`Dotenv` and `Layered` being `pub` in `config.zig` costs a project that never
names them.

- **Machine:** AMD Ryzen 7 9700X, 16 threads, Linux 7.0.0-29-generic
- **Zig:** 0.16.0
- **Parent commit:** `def3bbd`
- **Method:** two programs identical except for the feature, each reading a
  two-field Config with `report` reachable so nothing flattering is dropped.
  Built `-OReleaseFast -fstrip`, `nilo_config` handed over as a module. The
  baseline is built twice — once against a `git worktree` of `def3bbd` and once
  against the change — which is the method `docs/history.md` settled on for
  "moving declarations between modules cost nothing".

```
zig build-exe -OReleaseFast -fstrip --dep nilo_config \
  -Mroot=a.zig -Mnilo_config=<config/config.zig> --name a
```

| Program | Bytes |
|---|---|
| Reads a Config; `nilo_config` at `def3bbd` | 237,528 |
| The same source; `nilo_config` with this change | 237,528 |
| Plus `config.Dotenv` and `config.layered`, with `Dotenv.report` reachable | 243,976 |

**What moved:** the first two being byte for byte is what let ADR 0064 state
**zero** for a non-user rather than "negligible" — Zig does not analyse a `pub`
declaration nobody names, and this is the reading that shows it rather than
assuming it. The third gives the **6,448 bytes** the ADR quotes.

**Worth knowing next time:** the interesting number here was the one that did
*not* move. Measuring only the with-feature program would have produced 6,448
and no way to tell whether existing users were paying part of it.

## `.env` as a source — Refusal build time

**What it decided:** the Refusal-cost paragraph of ADR 0064, and it confirmed a
pattern ADR 0043 recorded rather than establishing a new one.

- Same machine, Zig and commit as above. Measured warm — built once, then timed
  on the second build.

| Refusal | Warm |
|---|---|
| `config_source_has_no_get` | 11ms |
| `config_layered_not_a_tuple` | 10ms |
| `config_layered_with_no_layers` | 10ms |
| `config_layered_not_a_source` | 111ms |

**What moved:** nothing was redesigned, but the ten-to-one spread is the finding.
ADR 0043 saw the same shape — `config_unknown_field` at 149ms against 30–38ms for
the rest — and gave the same cause: a `@compileError` reached *through a generic
function* costs an order of magnitude more than one reached from the type. Three
of these four stop at the type; `config_layered_not_a_source` walks into
`Layered`, and pays.

**Worth knowing next time:** if a Refusal ever needs to be made cheaper, the
lever is where the check sits, not what it says.
