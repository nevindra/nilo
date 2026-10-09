# Routing

**A route is a method, a pattern and a function, and the most specific pattern wins whatever order the routes were registered in.**

**Reference:** [`App`](../reference/app.md#app), [`Group`](../reference/app.md#group) · **Design:** [Routing](../design/routing.md)

## Registering a route

```zig
try app.get("/users/:id", getUser);   // one segment, typed and converted
try app.get("/users/new", newForm);   // a literal always wins over :id
try app.get("/files/*", serveFile);   // the rest of the path, as c.param("*")
```

One method per call: `get`, `post`, `put`, `delete`, `patch`, `head`, `options`, or [`route(method, pattern, handler)`](../reference/app.md#app) for anything else.

## Route priority

**Registration order changes nothing: the most specific route wins.** `/users/new` beats `/users/:id` beats `/files/*` because it is more specific, not because of where it sits in your `main`. It is the same rule `use` and `get` already follow.

Registering the same path twice is refused rather than quietly ignored, because the second handler would never run and nothing about the running server would say so. Param names don't tell two routes apart: `/users/:id` and `/users/:name` answer the same requests, so they collide.

```
error: the route "GET /users/:name" answers the same requests as "/users/:id",
which is already registered — whichever came second would never run.
```

A pattern that can't work (no leading slash, a `:` with no name, a `*` that isn't last, the same param name twice) is a build error naming the route, not something you find out at startup.

See [ADR 012](../adr/012-the-most-specific-route-wins-and-duplicates-are-refused.md).

## Method not allowed (405)

**A path that exists under some other method answers 405, not 404**, because those are different problems and a 404 sends you looking for a registration bug that isn't there:

```
$ curl -i -X DELETE localhost:8787/users
HTTP/1.1 405 Method Not Allowed
Allow: GET, HEAD, POST

DELETE is not allowed here. This path answers: GET, HEAD, POST
```

`HEAD` is in there without anyone registering one, because the `GET` route already answers it. An `OPTIONS` nobody registered is answered with a 204 and the same `Allow` with `OPTIONS` added, that being the question the method exists to ask. `OPTIONS *` is the server-wide form of it and lists every method any route answers; it is never matched against a route, a root `/*` included. Register `app.options(...)` yourself and yours wins.

## Groups

**A group is one prefix and everything under it:** [`app.group(prefix)`](../reference/app.md#group).

```zig
const api = app.group("/api/v1");
try api.use(requireToken);              // only /api/v1/…
try api.get("/users/:id", getUser);     // → /api/v1/users/:id
try api.group("/admin").get("/stats", stats);
```

The prefix is compile-time text joined onto each pattern, so the route registered is the one literal you'd have typed, and it's what every error message quotes back. A group leaves nothing behind at runtime.

A group has the same methods an App does (`get`, `post`, `use`, `useOn`, `provide`, `static`, `group`), so anything you can register on the App you can register on a group.

**A prefix may carry a param**, which is what a multi-tenant path wants:

```zig
const orgs = app.group("/orgs/:org");
try orgs.use(requireMembership);        // /orgs/acme/… and /orgs/acme/anything
try orgs.get("/members", listMembers);  // → /orgs/:org/members
```

Middleware scoped to a group matches **whole segments**, and a `:name` segment in the prefix matches whatever is opposite it. So `requireMembership` runs for routes under the group *and* for a 404 under it, and `app.use("/api", …)` does not reach `/apiary`.

A `*` in a prefix is still refused: a catch-all matches the whole rest of the path, leaving nothing for the routes inside the group to match.

## Plugins

**A plugin is an ordinary function that takes a group.** There's no plugin type and nothing to register:

```zig
fn metrics(g: anytype) !void {
    try g.get("/metrics", scrape);
    try g.use(countRequests);
}

try metrics(app.group("/internal"));
```

Because it's handed the group rather than the App, the same function mounts at any prefix, or at two. `anytype` is the usual signature, because a group's type carries its prefix, so every prefix is a different type. To spell one out, the type is `nilo.Group("/internal")`.

**A group's `provide` is App-wide.** A service is found by its type, and a group does not scope that: a plugin that provides a `Cache` has provided it for every route, and a second plugin providing another `Cache` is refused at startup ([Two of the same type](./services.md#two-of-the-same-type)).

Passing the App itself works too, since it has the same methods: a plugin mounted at the root is `try metrics(&app)`.

**A group says where it is mounted**, which is what a plugin needs when its own routes have to know their absolute paths (a link in a response body, a redirect target):

```zig
fn metrics(g: anytype) !void {
    const here = @TypeOf(g).mounted_at;   // "/internal"
    …
}
```

An App answers `""`, which is what a plugin mounted at the root should read.
