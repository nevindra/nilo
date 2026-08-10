# The most specific route wins, and a duplicate is refused

## The problem

The router returned the first pattern that matched, in registration order. Two things followed, and both were the kind of bug that costs an afternoon.

`/users/:id` registered before `/users/new` meant `/users/new` never ran. Nothing said so: the route existed, the server started, and requests went to the wrong handler. This is the same trap ADR 0009 already removed from middleware — where `use` after `get` silently failed to apply — left standing in the router.

And registering the same path twice was accepted without a word. In an app whose routes are split across files, two `app.get("/users/:id", …)` calls are easy to end up with and impossible to notice.

## The decision

**Matching picks the most specific route, not the first one.** Specificity is two bits per segment — a literal beats a param beats a `*` — packed most-significant-first, so an earlier segment outranks every later one. `max_segments` is 16, which fits a `u32` exactly. The score is computed once when the route is registered.

**A second route of the same shape is refused** with `error.DuplicateRoute`, from the `app.get` call that made it, naming the pattern already there. Param names are not part of the shape: `/users/:id` and `/users/:name` answer the same requests, so they collide.

Order of registration now decides nothing at all, which is what `use` and `get` already promised each other.

## What it costs

Measured, because this repository does not guess about these. `zig build profile`, best of eight runs on the same machine within minutes of each other:

| | before | after |
|---|---|---|
| match the route | **39ns** | **52ns** |
| share of one request | ~6.5% | ~9% |

**+13ns, about 2% of a 600ns request.** ADR 0001 sets the bar at 10% and says DX wins below it, so this is a trade that ADR already made; it is written down here so nobody has to rediscover the size of it.

Where it goes: the scan can no longer stop at the first hit, since a better match might be further down. Two things keep that from being as bad as it sounds. A route made only of literals cannot be outranked — and `add` now refuses a second one of the same shape, so there is at most one — which means every static route still stops the scan exactly where it used to. And once something is captured, a route that cannot outrank it is skipped on an integer compare without its segments being looked at, so the common case of one matching route is still filled in a single pass.

The remainder is a handful of extra branches per route and a `Route` grown by three fields. One attempt at winning it back is worth recording: putting the catch-all case into the segment loop as a third branch cost about 30% of route matching on its own, and hoisting it out — the loop now sees the same two cases it saw before catch-alls existed — got that part back. Deciding the winner first and capturing afterwards was also tried, and was worse: a `Match` has room for eight params and runs to a few hundred bytes, so a second walk over three short segments is cheaper than moving one around.

The linear scan itself is what plan.md has been flagging as unresolved since stage 1. When it is replaced with a real structure, specificity ordering is a property that structure has to carry, not a cost added on top of it.

## Why not sort at listen()

Sorting the route list by specificity would preserve first-match-wins and cost nothing per request. It was rejected because it makes the list's order a thing you cannot read: a debugger, a dump, or a future `app.routes()` would show an order nobody wrote. Deciding on a number at match time keeps the registration list as the user typed it.

## Consequences

- `/users/new` and `/users/:id` both work, in either order.
- `/files/*` can sit under `/files/readme` without swallowing it.
- Two identical routes stop `main` at the second one instead of producing a server with a handler that never runs.
- A pattern that cannot work at all — no leading slash, a `:` with no name, a `*` that is not last, a param name used twice — is caught while compiling, by `validatePattern`, since `App` has the pattern at compile time. What used to be `std.debug.assert` and an `unreachable` at startup is now a build error naming the route.
