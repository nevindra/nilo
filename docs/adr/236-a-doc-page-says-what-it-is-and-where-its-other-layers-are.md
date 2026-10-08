# A doc page says what it is and where its other layers are

**Status:** accepted
**Topic:** [docs-tooling](../design/docs-tooling.md)
**Extends:** [ADR 185](./185-the-reference-is-a-folder-one-page-a-module.md) (the reference's list of every heading), [ADR 221](./221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md) (the shape of a design page)
**Applies:** [ADR 068](./068-the-guide-is-the-source-of-its-own-snippets.md) (a rule held by a build step, not a paragraph)

## Context

Every topic in nilo is written up to three times: the guide says how to do it, the reference says what each name takes, and a design page says why it works that way. The pages were written to be read from the top, and the two readers who actually arrive do not read that way. A person scans the headings for the thing they came for. An agent pulls the outline of every page, picks a section, greps for a symbol and reads the forty lines around it. Measured at `d14780e` on 2026-09-26, both kinds of reader lost their way in the same places:

- **Headings were conclusions, not topics.** "The value comes back as it was sent", "Two things must not travel in", "The rule in force": each makes sense after the section is read, and none is what a reader searches for.
- **Prose was hard-wrapped at about 80 columns**, 76% of prose lines in the guide and the reference, so a phrase split across two lines was invisible to grep.
- **The layers linked one way.** The design pages linked the guide 42 times and the reference 57, while the guide linked a design page 0 times and the reference 21 times, and 27 of the 38 guide pages never linked the reference at all. The guide cited ADRs directly 302 times, skipping the design page that summarises them.
- **Reference sections ran long with nothing inside them**: `nilo_job` 145 lines, `nilo_s3` 136, `Db` 166, each a single heading, so the outline could not say where `bucket.list` was.
- **The reference's list of every heading was kept by hand** and had lost four headings (`nilo.csrf`, `Rooms`, and two in streaming).
- **Nothing joined the three folders.** Each had its own index and none named the other two for a given topic.
- The pages carried 1,597 em dashes.

## Decision

**Every page of `docs/guide/`, `docs/design/` and `docs/reference/`, and the map at `docs/README.md`, opens with the same five lines:** a `# ` title, a blank line, one bold sentence saying what the page is about, a blank line, and a line starting `**Guide:**`, `**Reference:**` or `**Design:**` that links the same topic in the other two layers. A layer with no page for the topic writes `none` there, so the line is always present.

**`docs/README.md` is the map.** Each guide page is one row, in the order the guide teaches, with its module and the reference and design pages that go with it. Design topics with no guide page of their own have rows of their own. Every page of the three folders is linked from it.

**A heading names what its section covers, in the words a reader would search for.** A guide heading is the task ("Setting a cookie", "Route priority"). A reference heading is the symbol (`Db`, `Bucket.list`), and a section longer than about sixty lines is divided by symbol. A design page's sections are `Overview`, `Rules`, `Decisions` and `Open questions`. What a heading used to conclude becomes the section's first sentence, in bold.

**Prose is one paragraph a line, with no em dash**, outside code fences and inline code. A code block, a quoted error message and a `<!-- compiles -->` mark are never rewritten for style, because they are nilo's real output or a program the build compiles.

**The reference's list of every heading is generated.** `zig build docs-index` writes it from the pages' `##` to `####` headings, in the order the list already has them, with a new page added at the end.

**`zig build docs-check`, on `test`, holds all of the above**: it refuses a page without the five-line head, a paragraph carried onto a second line, an em dash in prose, a relative link to a file that does not exist, an anchor named on one of these pages that no heading there produces (from any Markdown file in the repository, ADRs and the changelog included), a page the map does not link, and a list of every heading that differs from what `docs-index` would write. An anchor into the todo list, the roadmap, `decided.md`, `history.md` and `risks.md` is held the same way, and so are the roadmap's lists of todo entries, which `docs-index` also writes ([ADR 255](./255-the-todo-list-is-ranked-by-evidence-and-the-roadmap-is-written-from-it.md)). Anchors are GitHub's (lowercase, punctuation dropped, a repeated heading numbered `-1`, `-2` counting the title), because the reference and the design pages are read on GitHub ([ADR 219](./219-the-guide-is-published-once-a-release.md)).

## What was rejected

- **Renaming files so the three folders share names.** They are cut differently on purpose: the guide by task, the reference by module ([ADR 185](./185-the-reference-is-a-folder-one-page-a-module.md)), the design pages by topic. A map joins them without breaking every link into them.
- **Keeping the old headings and adding a symbol index for agents.** The person scanning headings was lost in the same place as the agent, and an index beside unreadable headings fixes one reader of two.
- **An `llms.txt` at the root.** An agent reading this repository reads `docs/README.md` first; the published site holds only the guide ([ADR 219](./219-the-guide-is-published-once-a-release.md)). Left for when the site carries more than the guide.
- **Checking that a heading is plain.** Whether "The value comes back as it was sent" is a conclusion is judgement, not a scan; review holds it, with this ADR's examples as the rule.
- **MkDocs' anchors.** They differ from GitHub's for a repeated heading (`_1` rather than `-1`), and every page but the guide is read on GitHub.

## What it costs

Nothing a user builds: `docs-check` reads the documentation and adds nothing to any artifact. It does not cache, so it is paid on every `zig build test`: 0.36 seconds on a Ryzen 7 9700X, against 0.05 for a cached `layering`.

The wrap check is a heuristic. A paragraph that opens in bold is not checked, and a line ending in a colon or two spaces may continue, because a list or a code block often follows one. It found no false refusal on the 92 pages it was written against.

## Consequences

The 91 existing pages were rewritten to this shape in one change, with every fact, number, ADR citation and code block kept, and the map written. 366 headings were renamed and every link to them was rewritten. At the end the guide linked a design page 49 times and the reference 214 times, the reference linked a design page 35 times, and no em dash was left in prose.

A new page is one change with its head, a row or link in the map, and, for a reference page, `zig build docs-index`. `CONTRIBUTING.md` and `CLAUDE.md` say so.
