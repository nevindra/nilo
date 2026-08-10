# Services are matched through a runtime registry, checked at startup

Typed handlers ask for services by the type of their arguments (ADR 0003). The question is: where does that list of services live?

The most Zig-like answer is to make `App` generic over the set of service types, so that a service you forgot to register stops compilation:

```zig
var app = zfast.App(.{ *Db, *Config }).init(gpa, .{ &db, &cfg });
```

That was rejected. The audience is Go and Node people, who over there just write `app := fiber.New()`. Making them name every service type twice — once in `App`'s parameter, once when filling it in — and turning `App` into a different type depending on its contents is a large DX price for one fairly rare class of mistake. The documentation ends up forking too.

So the registry is a **runtime** one, keyed by type name from `@typeName`:

```zig
var app = zfast.App.init(gpa);
try app.provide(&db);
try app.get("/users/:id", getUser);   // getUser asks for *Db
```

What that loses — the compile-time check — is given back another way. The compile-time engine is already reading each handler's argument list, so it collects which services were asked for, along with their route. `listen()` checks that list before the socket ever opens:

```
error: the handler for route "/users/:id" needs service *main.Db, which
was never registered — call app.provide() before app.listen()
```

A wrong type is still caught, just a few milliseconds later: when the process starts, rather than on the first request that happens to hit that route at three in the morning.

## Consequences

- Registration order is free. Services may be registered before or after routes, as long as it all happens before `listen()`.
- Fetching a service means a linear scan over a handful of entries, comparing type-name pointers. That costs a few nanoseconds on requests that actually use a service — well under the 10% threshold in ADR 0001, and it can be swapped for a compile-time index later if measurement says otherwise, without changing user code.
- Two services of the same type are rejected at registration rather than quietly overwriting one another. Telling them apart still means named wrappers, as ADR 0003 says.
- A service registered as `*const` and asked for as `*` is caught by `listen()` too, rather than becoming a const pointer quietly mutated.
- Tests do not need to start a server to check the assembly: `app.missingService()` returns the first unmet requirement as plain data.
