# The todo list is ranked by what an entry costs, and the roadmap is written from it

**Status:** accepted
**Topic:** [docs-tooling](../design/docs-tooling.md)
**Extends:** [ADR 236](./236-a-doc-page-says-what-it-is-and-where-its-other-layers-are.md) (which files `docs-check` holds an anchor into, and the second list `docs-index` writes)
**Applies:** [ADR 068](./068-the-guide-is-the-source-of-its-own-snippets.md) (a rule held by a build step, not a paragraph)

## Context

`docs/todo.md` held 141 entries in six sections, one for each thing an entry could be waiting for: a fix (13), a decision (41), a caller (31), an argument (19), a number (30) and somebody else's commit (7). The sections said what each entry needed and nothing about which mattered. Only four modules had ever been ranked, inside their own headings, and nothing compared an entry in one section with an entry in another.

- **The largest single cost of a gRPC call sat under "Known, waiting for a caller".** Decoding a call's header block is 28% of a unary call ([`bench/result/http.md`](../../bench/result/http.md#a-call-handed-to-the-app-as-it-was-read)), measured and linked, and its closing line asked for a caller who had noticed. A framework is fast enough that nobody writes in about 250 ns, so the caller does not come, and a cost on the record waited on a complaint it would never get.
- **"Waiting for a caller" is the blocker this repository already distrusts.** [`history.md`](../history.md#claims-that-decay) records seven blockers on somebody else that were not blockers, and the cure written there, re-test the blocker, has nothing to run against when the blocker is the absence of a person.
- **A number decided nothing by sitting in a table.** Thirty measurements were one table in no order, so the run that could show a hard axis had moved (an idle connection 512 bytes larger since v0.3.0, with no ADR stating it) sat beside one that could tune a cache's ways.
- **The roadmap named its entries in prose.** Each direction ended "It gathers up, from the todo list:" and a list of subjects with no links, so an entry that shipped or moved left the roadmap naming it, and nothing noticed. `docs-check` checked anchors into the guide, the reference and the design pages only, so even the five links into the todo list's section headings were held by nobody.
- **The roadmap had no order but dependency**, so it could not say what was being built now, and one of its four directions, "the toolkit grows by the jobs people have", said when a module would not be built rather than which one would.

## Decision

**The todo list is one list in four tiers, by how much an entry costs the people who use nilo or the project's own development, never by who has asked for it and never by what kind of finding it is.** P0 blocks the next release (a crash or a panic a request can reach, memory read after it is freed, data lost, a wrong answer with no error, something handed to a stranger). P1 is a cost that is large and real: a trap that compiles and gives a wrong answer to the users of a common feature, a shipped feature that does not do its job, an outage a common action causes in production, a cost on a hard axis, a design many later things will be built on, or a suspicion one probe settles that would be P0 if true; its bold claim says who meets it and what happens to them. P2 is a real cost and a smaller one, work that is meant to be done, and every defect the code was checked for is at least P2. P3 is not work put off: it is something important that may cost users with no evidence yet that it does, and its closing line names the sign that would raise it. A caller is evidence, but not the only evidence and not a reason to wait.

**A small thing nobody needs now is not on the list.** It is deleted, not deferred: git keeps the text and `bench/result/` keeps any number behind it, and it is written again when the evidence that it is needed arrives. A defect is never deleted this way.

**What an entry is waiting for moves from its section to its closing line.** `Needs:` when the shape of the work is known, `What would settle it:` for a question or a number, and an entry waiting on another repository names the pin it was last checked at there. Inside a tier entries sit under their module, which keeps what made the module headings worth having: two entries under different modules touch no file in common ([ADR 038](./038-a-module-sits-where-the-loop-puts-it.md)).

**An entry that serves a roadmap direction says so on a `**Direction:**` line, and the roadmap's list of entries is written from those lines.** `zig build docs-index` fills each direction's list between two `gathered` markers, with the entry's tier, module and bold claim; `zig build docs-check` refuses a list out of step, a direction with no markers, and a `Direction:` line that links no direction. The link is one way, entry to direction, so an entry that leaves the todo list leaves the roadmap at the next `docs-index` and fails `test` until then.

**The roadmap groups its directions by when**: **Now** for the direction being built, **Alongside** for work no stage depends on and that is picked up between stages, **Next** and **Later**. It opens with a paragraph on where the framework and the toolkit are going, and makes no promise of 1.0.

**The list is ranked again at each release, and a build step holds it.** The todo list carries `**Ranked at X.**`, and `docs-check` refuses it once `build.zig.zon` names another version, which cutting a release does. The ranking is redone against the numbers `bench/release.py` has just produced; an entry no longer needed is deleted unless it is a defect, and a P3 a release has left exactly where it was is given a reason to stay or deleted. **A direction's place in the roadmap follows its entries' tiers**: one with a P1 entry is in **Now** or **Next**, **Next** is ordered by P1 entries and then P2, and one with nothing above P3 is in **Later**.

**An anchor into `todo.md`, `roadmap.md`, `decided.md`, `history.md` and `risks.md` is checked as one into a page is.** Their heads and prose are not a page's and are not held to ADR 236's five lines.

## What was rejected

- **Ranking by the kind of evidence an entry had, which is what this ADR first decided.** P1 was "wrong and loud", "a gap in the gate" or "a suspicion one probe settles", and P2 included "a gap every user of a feature meets". Read back at 0.7.0, the four P1 entries were a looser OpenAPI document, a test client that accepted any head, an untested SQLite contention path and a refactor, while path params matched by position (two ids swapped with no error), a middleware that fails open and a JSON log format that is not JSON sat in P2, and two probes that would each be P0 if true (a `sql.violated` that answers wrongly) sat in P2 beside them. The tiers measured how a finding was proved, not what it did to anybody. P3 had become a place to put work for later: 50 entries, most waiting for a caller nobody expected, which is the backlog this ADR's first version set out to stop. The re-rank under the rule above put 9 entries in P1, 76 in P2 and 25 in P3, and deleted 62.
- **A heading per todo entry, so the roadmap could link each one.** It gives every entry an anchor for free and puts about 140 headings into one file's outline, which then says no more than the bold lines already do. A `Direction:` line and a generated list hold the same link with one source and no new headings.
- **Keeping the sections and adding a priority inside each.** The sections are what hid the HPACK row: a P1 under "waiting for a caller" still reads as waiting. What an entry needs is still on the record, on its closing line, where it does not decide where the entry sits.
- **The roadmap listing its entries by hand, with links.** A link to an entry that has shipped is caught only if somebody runs a check on it, and a hand-kept list is the reference's heading list again, which lost four headings before `docs-index` wrote it ([ADR 236](./236-a-doc-page-says-what-it-is-and-where-its-other-layers-are.md)).
- **Re-ranking as a line in `docs/releasing.md` alone.** A step in a checklist is a paragraph nobody runs. Tying it to the version bump costs one comparison in `docs-check` and makes skipping it a failed release commit.

## What it costs

Nothing a dependent builds: `docs-check` and `docs-index` are this repository's steps. The steps read five more files and walk the todo list once, which does not show beside the walk of every Markdown file in the repository they already make. Ranking by cost is judgment at the margins of each tier, more than ranking by the kind of evidence was, which is why a P1's bold claim has to say who meets it and what happens to them; the rankings so far were one person's, and [rule 9 of the todo list](../todo.md#how-this-file-is-written) is where a wrong rank is corrected.

## Consequences

- The first ranking put 16 entries in P1, 69 in P2 and 54 in P3, and none in P0; two entries that were decisions with their reasons already written (a v7 counter, HS256) moved to `decided.md`. The roadmap gained three directions from clusters of entries that had none: an idle connection's bytes, a migration history kept for years, and a listener with nothing in front of it.
- Closing lines that waited for a caller where the cost was already measured were rewritten as the work they need, the HPACK row's among them.
- Links into the old section headings, from the guide, two ADRs, a design page and `CONTRIBUTING.md`, now point at the file, and `docs-check` would have refused them otherwise.
