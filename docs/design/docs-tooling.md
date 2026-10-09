# Documentation tooling

**Every claim in the documentation is checked by a build step, or it is not trusted, and that includes the documentation about the documentation.**

**Guide:** [Restarting on every save](../guide/getting-started.md#restarting-on-every-save) · **Reference:** none

What a change has to include is the fourth item in `CONTRIBUTING.md` ([`../../CONTRIBUTING.md#4-its-documentation`](../../CONTRIBUTING.md#4-its-documentation)). The code is `build.zig` (`Snippets`, `AdrCheck`, `DocsCheck`, `testBackend`), `dev/main.zig` (`nilo-dev`), `.github/workflows/ci.yml` and `docs.yml`, `mkdocs.yml` and `docs/site/hooks.py`.

## Overview

```
docs/guide/*.md, README.md, docs/reference/*.md
  a "compiles" mark        \  extracted at build time, put behind a page's
  a "compiles: body" mark  /  own prelude, compiled: zig build snippets

docs/adr/NNN-slug.md  ---adr-check--->  every citation, every Topic line,
  (the rule in force)                   every docs/design/ link, resolved

docs/design/<slug>.md  <--- topic page joins the ADRs of one topic

docs/README.md (the map) --docs-check--> every page's five-line head,
  one row a guide page                   one paragraph a line, links and
                                         anchors resolved, the reference's
                                         heading list as docs-index writes it

zig build test-all (Debug + ReleaseSafe, testBackend picks the backend)
  |
  v
git tag  --docs.yml, mkdocs.yml-->  the guide, versioned, published once
                                     (reference/ADRs/bench stay on GitHub)

save a .zig file --zig build --watch--> binary changes --> nilo-dev restarts
```

## Rules

1. **A `zig` block with `<!-- compiles -->` above it is a program, and the page is its only copy.** `build.zig` extracts it, puts a prelude in front (`docs/snippets/types.zig`, or the page's own) and `zig build snippets` compiles it; `zig build test` depends on that step. Keeping complete programs in a `docs/snippets/` folder was rejected: it checks a copy, and the page can drift away from it while the build stays green. [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md)
2. **`<!-- compiles: body -->` marks a run of statements.** It gets the running example's values (`c`, `db`, `form`) as well as its types, so a page can show a struct once and then write ordinary statements against it. A name the block declares itself is dropped from the prelude instead of clashing, and a local the block never reads is discarded the same way `export fn` pulls a function in, so no stray `_ = x;` shows up on the published page. [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md)
3. **A page about its own types may declare its own prelude**, listed in `build.zig`'s `Snippets.pages` as `Page{ .path, .types, .values }`, instead of carrying seven unrelated types borrowed from the sign-in example. [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md)
4. **The list of checked pages is written out, not discovered by walking the folders.** Every page with a marked block is named in `Snippets.pages`. A page with none has no row, because a row that checks nothing costs a read for no reason. [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md), [ADR 185](../adr/185-the-reference-is-a-folder-one-page-a-module.md)
5. **The reference is a folder with one page per module, because one page cannot describe the server.** A module in the bottom layers gets one page named after it. The server's reference is split into seven pages the same way the guide splits it (`app`, `handlers`, `ctx`, `streaming`, `middleware`, `testing`), and every heading kept its anchor by moving whole. `README.md` lists every heading once, which replaces searching the old single page. [ADR 185](../adr/185-the-reference-is-a-folder-one-page-a-module.md)
6. **The `ReleaseSafe` test builds use Zig's self-hosted backend on x86_64, and only where it was measured to work.** `testBackend` returns `false` there and `null` (Zig's own default) everywhere else. A test binary is compiled once and run once, and LLVM's passes were 94% of a 27.6-second compile that bought nothing this repository needs. [ADR 138](../adr/138-a-test-does-not-need-the-optimiser.md)
7. **This makes the gate very close to the LLVM one, not identical, and that is written down.** A use-after-return is undefined behaviour, and whether it is caught depends on stack layout, which a different backend can change. The trade is a gate that runs on every `zig build test` instead of one a contributor is tempted to skip. Every `bench-*` target stays on LLVM, because a throughput number from a non-optimising backend is meaningless. [ADR 138](../adr/138-a-test-does-not-need-the-optimiser.md)
8. **`nilo-dev` restarts when the binary changes, not when a source file changes.** It runs one `zig build <step> --watch` and checks that step's output file every 250 ms, so the sources that matter are exactly the ones the build reads. There is no second list of files to fall out of step with `build.zig`. [ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)
9. **When a build fails, the last binary that compiled keeps running, except at the very first start.** The old binary is removed only when the first build (before watching begins) fails, because running an old binary against sources that have moved on has a real cost (an old schema seeding a database), and that only matters before anything has run correctly. [ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)
10. **After each restart, every older build is deleted, matched by the new binary's bytes, not by age.** One save leaves one new directory in `.zig-cache`, and the tool removes every other directory holding a copy of that binary's name. That keeps the loop's disk use flat without relying on Zig's cache eviction, which does not exist. `nilo-dev` imports only `std` and ships as its own artifact, so no server links any of this. [ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)
11. **The guide is the only part of the documentation published as a versioned site, once per minor release, never from `main`.** On a tag, `docs.yml` builds `docs/guide/` with Material for MkDocs and mike. The reference, the ADRs and the benchmark results stay on GitHub, and `docs/site/hooks.py` rewrites every guide link into them to point at the tag the site was built from. [ADR 219](../adr/219-the-guide-is-published-once-a-release.md)
12. **`mkdocs.yml` builds in strict mode with heading anchors checked, and CI's `docs` job runs it on every push.** A link to a renamed heading fails there, not on release day, and a new guide page without a line in `nav:` fails the job. [ADR 219](../adr/219-the-guide-is-published-once-a-release.md)
13. **An ADR states the rule that holds now; a changed decision is edited in place.** The Decision section is rewritten to what holds now, the replaced position moves under "What was rejected" with the evidence that changed it, and a new number is only for a new decision. An ADR's head may refer to another only with `Applies`, `Extends`, `Carries out`, `Closes` or `Found by`. A word meaning "this supersedes that" is rejected, because that would be a revision written as a new file. [ADR 221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md)
14. **Every ADR names its topic, and a topic with a page in `docs/design/` names it as a link to that page.** The page is where a reader starts (an overview, each rule with the ADR that decided it, and what is still open); the ADRs keep the full reasoning. A page must link every ADR of its topic, so adding an ADR to a topic that has a page means updating that page's Decisions table in the same change. [ADR 221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md)
15. **`zig build adr-check` enforces all of the above, and runs on `test`.** It rejects a file not named `NNN-slug.md`, two ADRs with the same number, a missing `**Status:**` or `**Topic:**` line, a topic written as a plain slug once its page exists, and a `docs/design/` page with a relative link that points at nothing. Across every text file in the repository, it rejects a four-digit ADR number anywhere but `renumbered.md`, and a three-digit one with no file behind it. [ADR 221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md)
16. **Every page of the guide, the reference and the design pages opens with the same five lines**: a title, one bold sentence saying what the page is, and a line linking the same topic in the other two layers. `docs/README.md` is the map that joins the three folders, one row per guide page. [ADR 236](../adr/236-a-doc-page-says-what-it-is-and-where-its-other-layers-are.md)
17. **A heading names what its section covers, and prose is one paragraph a line with no em dash.** A guide heading is a task, a reference heading a symbol, and a design page's sections are Overview, Rules, Decisions and Open questions; what a heading used to conclude is the section's bold first sentence. [ADR 236](../adr/236-a-doc-page-says-what-it-is-and-where-its-other-layers-are.md)
18. **`zig build docs-check` enforces 16, 17 and 19, and runs on `test`.** It also refuses a relative link to nothing, an anchor on one of these pages that no heading produces (named from any Markdown file in the repository), a page the map does not link, and a reference heading list that differs from what `zig build docs-index` writes. [ADR 236](../adr/236-a-doc-page-says-what-it-is-and-where-its-other-layers-are.md)
19. **The todo list is one list ranked P0 to P3 by what an entry costs users or the project, a small thing nobody needs now is not on it, and the roadmap's list under each direction is written from the entries that name it.** An entry serving a direction carries a `**Direction:**` line, `zig build docs-index` writes each direction's list between its `gathered` markers, and `docs-check` refuses a stale list, a direction with no markers, an anchor into the todo list, the roadmap, `decided.md`, `history.md` or `risks.md` that no heading produces, and a todo list whose `Ranked at` line is behind the version in `build.zig.zon`, so a release cannot be cut without ranking it again. [ADR 255](../adr/255-the-todo-list-is-ranked-by-evidence-and-the-roadmap-is-written-from-it.md)

## Decisions

| ADR | What it decides |
|---|---|
| [068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md) | A marked `zig` block in the guide, README or reference is a program the build compiles, and the page is its only copy |
| [138](../adr/138-a-test-does-not-need-the-optimiser.md) | `ReleaseSafe` test binaries build on Zig's self-hosted backend where it was measured to work |
| [185](../adr/185-the-reference-is-a-folder-one-page-a-module.md) | The reference is a folder: one page per module, and seven for the server, split the way the guide splits it |
| [190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md) | `nilo-dev` restarts a running example when a `--watch` build writes a new binary, and cleans up the cache it leaves |
| [219](../adr/219-the-guide-is-published-once-a-release.md) | The guide is built into a versioned site and published on a tag; everything else stays on GitHub |
| [221](../adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md) | An ADR is edited in place to state the rule that holds now; a topic page gathers the ADRs of one topic; `adr-check` enforces the shape of both |
| [236](../adr/236-a-doc-page-says-what-it-is-and-where-its-other-layers-are.md) | Every doc page opens with what it is and links its other layers; `docs/README.md` maps them; headings name topics; `docs-check` enforces it |
| [255](../adr/255-the-todo-list-is-ranked-by-evidence-and-the-roadmap-is-written-from-it.md) | The todo list is ranked P0 to P3 by what an entry costs, never by who asked or how it was found; what is not needed now is deleted; the roadmap places its directions by their entries' tiers and its lists of entries are generated; the ranking is redone at each release |
| [263](../adr/263-a-first-project-is-one-call-from-its-build-file.md) | `nilo.app` writes a dependent's whole `build.zig` and `template/` is the project to copy; `template-check` builds the template on `test` |

Related topics: `adr-check`, `docs-check` and `zig build snippets` all follow the pattern of the refusals build step, [ADR 026](../adr/026-the-rule-about-error-messages-is-held-by-a-build-step.md) (testing); the four axes every "What it costs" section is measured against, this topic's included, are [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles); the module layering that has its own build step next to `adr-check` is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) (layering); the file reload that pairs with `nilo-dev`'s restart is [ADR 098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md) (static-files).

## Open questions

- **Checking snippets in `///` doc comments.** `http/ctx.zig` had one of the three broken lines ADR 068 found. That line is fixed, but a doc comment has no fence and would need its own extractor. Left open in [ADR 068](../adr/068-the-guide-is-the-source-of-its-own-snippets.md).
- **Waiting for Zig's aarch64 self-hosted backend to become the default.** `testBackend` will pick it up with no change here once it does. Until then aarch64 runs both test modes through LLVM, as recorded in [ADR 138](../adr/138-a-test-does-not-need-the-optimiser.md).
