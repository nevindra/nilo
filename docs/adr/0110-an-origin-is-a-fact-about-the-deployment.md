# An origin is a fact about the deployment

`cors.with` takes `comptime Options` and unrolls the compare over the literals,
which is what makes a named origin cost one `mem.eql` and no allocation
([ADR 0099](./0099-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)).

The consequence is that **the same binary cannot serve staging and
production**. The front end's address is not a property of the program; it is a
property of where the program was deployed, and every other deployment fact in
nilo — the port, the database URL, the session secret — arrives at run time
through `nilo_config`. An application that had two environments had two
answers: recompile per environment, or write the middleware itself.

**`cors.reading(&origins, .{ … })` is the same middleware reading its list from
somewhere the program fills before `listen()`.**

```zig
var origins: nilo.cors.Origins = .empty;

pub fn main() !void {
    var buf: [4][]const u8 = undefined;
    try origins.setSplit(&buf, settings.web_origins);   // "https://a.com,https://b.com"
    try app.use(nilo.cors.reading(&origins, .{ .credentials = true }));
    try app.listen(.{});
}
```

## What stays comptime, and why that is not a compromise

Everything except the list: the methods, the headers, the exposed headers, the
max age, whether credentials are allowed. None of those is a fact about the
deployment — a server that allows credentials in production and not in staging
is two different services — so they stay where they were, as constants that
never get formatted.

`with` is untouched. Its unrolled compare is the measured path, an application
that names its origins in code keeps it, and this adds a second entry point
rather than a runtime branch inside the first.

## Why a variable the caller owns

`Middleware` is a bare function pointer, `fn (*Ctx, Next) anyerror!void`. It
captures nothing, which is what lets a chain be an array resolved once at
`listen()` and walked with no indirection per layer. So state a middleware
reads has to be reachable statically, and there were three ways to do that:

- **A comptime pointer to the caller's variable.** What this is. The wiring
  cannot be forgotten, because the pointer is an argument; the failure mode is
  an empty list rather than a missing registration.
- **A Service, looked up with `c.service(*cors.Origins)`.** Idiomatic in every
  other part of nilo, and wrong here: `checkServices` reads the *routes'*
  argument lists, so it cannot see what a middleware needs. Forgetting
  `app.provide` would compile, start, and silently answer no CORS headers at
  all.
- **A global inside `cors.zig`.** One list for the whole process, so two
  Apps or two prefixes could not have different ones, and nothing would say so.

## The list is borrowed, and that is what keeps the budget

`Origins.set` does not copy. The entries point at the environment block, a
`.env`'s text, or a literal — the same rule `nilo_config` states for a
`[]const u8` field — and they have to outlive the server.

That contract is load-bearing rather than a convenience: because the text
outlives the request, the matched origin goes out through `setStaticHeader` and
**not** through `setHeader`, so a cross-origin request costs the same zero
allocations it costs under `with`. Copying it would have put an allocation on
the request path of every app that named an origin, which is the one axis
[ADR 0018](./0018-the-trade-budget-has-three-axes.md) treats as an invariant.

## What is refused, and where

`with` refuses four things while compiling: no origins at all, `*` beside a
name, `*` with credentials, and a capital letter. A list that arrives at run
time cannot be refused any earlier than the call that takes it, so `set` and
`setSplit` return errors for the same mistakes — at startup, where a program
can print them beside its other settings.

`"*"` is refused outright rather than handled. A runtime list names the
deployments this server answers; answering anybody is `cors.permissive`, which
needs no list and reads no header. That refusal is also what makes credentials
safe here without a second check: the combination browsers reject cannot be
built.

The one thing said while compiling is naming origins in both places at once —
`reading(&origins, .{ .origins = … })` — because the field would be ignored,
and an ignored list is one somebody edits and then wonders about.

## An empty list says so, once

A program that registers `reading` and never fills it refuses every
cross-origin request, and the browser's message names none of that. The first
cross-origin request that finds the list empty logs one warning naming the
call. Once, through an atomic flag, on a path that a matching request never
reaches — so a correctly configured server pays a single relaxed load on the
requests that were going to be refused anyway.

Not at startup: nothing in a middleware runs at startup, and a program that
fills its list after `use` and before `listen` would be told off for something
it was about to do.
