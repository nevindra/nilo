# Cutting a release

What happens between `## Unreleased` and a tag. Read it when you cut one; the rest of the time [`CHANGELOG.md`](../CHANGELOG.md) is all anybody needs.

**`CHANGELOG.md` holds one release, the untagged one.** Work lands under `## Unreleased`. Cutting a release renames that heading to the version and bumps it in five other places:

- `.version` in `build.zig.zon`
- the badge and the `?ref=` in `README.md`
- the `?ref=` in `docs/guide/getting-started.md`
- the "needs Zig" line in `docs/todo.md`, and its `Ranked at` line, once the list has been ranked again against the release's numbers ([its rule 9](./todo.md#how-this-file-is-written)) and the roadmap's order read again ([its rule 6](./roadmap.md#how-this-file-is-written)); `docs-check` refuses the commit until it says the new version
- the comment in `stress/arsip/build.zig.zon`

The version follows the size of the change: a fix or any small change is a patch, minor is for new features, major for breaks.

**Read the numbers before tagging.** Run **Release numbers** by hand (`gh workflow run release-numbers.yml -f ref=<the release commit>`), which measures that commit against the last tag on every module ([ADR 242](./adr/242-a-release-is-measured-against-the-one-before-it.md)). A change outside the spread is either the cost a feature already wrote into its ADR and ADR 017's running total, or something to look at before the tag exists. Publishing the release runs it again and attaches `numbers-vX.Y.Z.json` and `.md` to the release page; the table then goes into [`bench/result/releases.md`](../bench/result/releases.md) under its version, in the next commit.

**The two `?ref=` lines carry the tag's commit after a `#`.** A `?ref=` alone is not a pin: the tags are annotated and Zig 0.16's fetcher hands back `main` for one (`docs/history.md`, under "Claims that decay"). The commit exists only once the tag does, so either write the lines with the commit `git rev-parse vX.Y.Z^{commit}` will answer *after* tagging, or tag first and amend.

**The release page is written for the person upgrading, not copied from the section**: `gh release create vX.Y.Z --verify-tag --notes-file …`. It opens with what the release is and the `zig fetch` line, then **Read this before you deploy**: first the changes that compile and then behave differently, grouped by who meets them (an app with sessions, Postgres on another machine, SQLite migrations, a handler that catches a failed statement), each with what to do; then what the compiler will refuse, briefly, since it names the fix itself; then what a caller who wrote their own store, Wire or Space has to add. After that a short **What is new**, and one link to `CHANGELOG.md` at the tag for every entry. A long Breaking list pasted onto the page tells an upgrader everything and nothing; the CHANGELOG is the record, the page is the guide. Every link on it is a blob URL pinned to the tag, because a relative link does not resolve on a release page.

**Tagging then empties the section.** What stays in `CHANGELOG.md` is one line under `## Released` pointing at the page, and any README link into the section becomes a link to that page. The whole section stays readable in the tag's own `CHANGELOG.md`, which is what the page links to. The file is then the next release again, and never grows past one.

**Pushing the tag also publishes the guide.** `.github/workflows/docs.yml` builds `docs/guide/` into the `X.Y` copy of the site and moves `latest` only when the tag is the newest ([ADR 219](./adr/219-the-guide-is-published-once-a-release.md)).
