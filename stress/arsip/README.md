# arsip

A document archive, built to stress-test what nilo is like to use.

It is **not** a ninth example. The examples are curated — each one shows a
feature at its best angle, and they are built by the repository's own
`build.zig`, which means they can reach any file in it. arsip cannot: it
consumes nilo as a package, from outside, so it only sees what a dependent
sees. That is the whole reason it exists out here.

```
cd stress/arsip
zig build run          # the server, on :8801
zig build test         # its tests, Debug and ReleaseSafe
```

- [`MILESTONES.md`](./MILESTONES.md) — the plan, one module at a time.
- [`DX.md`](./DX.md) — what fought back, and what it would take to fix.

Nothing here is built or run by the root `zig build`, and nothing in the
repository imports it. It is a consumer, and a consumer the library knows about
is not testing anything.
