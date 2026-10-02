# Outbound calls

**`nilo_fetch` is a Fitting: it uses the event loop and owns no destination, adding the rules an outbound call needs on top of `std.http.Client` without any of the state a Service keeps.**

**Guide:** [Calling somebody else's API](../guide/fetch.md) · **Reference:** [`nilo_fetch`](../reference/fetch.md)

The code is `fetch/fetch.zig` (`Client`, `Exchange`, `withQuery`), `fetch/target.zig` (`Target`), `fetch/testing.zig` (`Canned`) and `fetch/deadline.zig`.

## Overview

```
   Fitting layer: borrows Io, owns no destination, no credentials (ADR 061)
                                │
        fetch.Client: one connection pool, one cert bundle, per program
                                │
        fetch.Target(name, opts): a type per outbound service
        (max_in_flight, timeout_ms, ready path; base URL and
        credential given to open(), not compiled in)
                                │
              ┌─────────────────┴──────────────────┐
              ▼                                     ▼
   client.get/post/postJson/withQuery       Exchange.begin / take / end
   one Response, body read whole            headers read first, body on demand
              │                                     │
   X-Request-Id forwarded (158)              discard() skips the drain (184)
   redirects: .refuse / .follow / .expose (183)      head.keep(c) survives it (187)
   the body decides the framing, not the method (174)
   a bodiless answer ends at its own head (176)
```

## Rules

1. **A Fitting uses the loop and owns no destination.** `nilo_fetch` imports `nilo_core` and nothing above it, and takes a Scope on every call instead of holding a `Ctx`. Its tests run under `std.Io.Threaded` with no Engine, which is the entry condition for this layer, just as a plain `zig test` is for a tool module. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md)
2. **Each destination is a type.** `fetch.Target(name, .{ .max_in_flight, .timeout_ms, .stall_ms, .max_body, .ready })` returns a type, so two services are two types and a handler names the one it wants. The base URL and the credential are passed to `open`, because they belong to the deployment, not the type. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md)
3. **The normal calls send JSON and a query, never a bare string as the body.** `postJson`, `putJson`, `patchJson` and `sendJson` write the value with `std.json.Stringify.valueAlloc`. Passing a `[]const u8` to one does not compile, because it would go out as a quoted JSON string. `withQuery(c, base, .{ … })` builds the query string in one arena allocation of the right size. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md)
4. **A target's own limit is taken before the client's and released after it.** `max_in_flight` on the type is a semaphore for that service alone, so a slow third party queues behind its own limit instead of using up the permits every other target shares. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md)
5. **The request id is sent with the call.** Every `get`, `post`, `put`, `delete` and `send` made with a `*Ctx` sends `X-Request-Id` with the id the incoming request already has. A `Run` has no request, so it sends nothing: a Scope is asked for `requestId` only if it declares one. `Settings.forward_request_id = false` turns this off. On an App that traces, the call is also a client span and sends `traceparent` naming it, through the same kind of optional Scope declaration (`traceBegin`, `traceEnd`); `forward_request_id` does not touch that. [ADR 158](../adr/158-a-request-id-goes-out-with-the-call.md), [ADR 247](../adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)
6. **Whether a body is sent decides the framing, not the HTTP method.** A body given to a method std does not frame one for (a DELETE) is still sent: std writes the head and the length is filled in afterwards. A method std expects a body for, sent without one, goes out as `content-length: 0`. [ADR 174](../adr/174-the-body-decides-not-the-method.md)
7. **An answer that has no body ends at its head.** The answer to a HEAD, a 1xx, a 204 and a 304 are marked fully read as soon as the head arrives, whatever `content-length` or `transfer-encoding` says. So a connection that got a 204 without a length goes back to the pool instead of hanging until the other end closes it. [ADR 176](../adr/176-an-answer-with-no-body-ends-at-its-head.md)
8. **A header std manages is sent only once.** If `Begin.headers` contains a name std has its own slot for (`host`, `authorization`, `user-agent`, `content-type`, `connection`, `accept-encoding`), std leaves its own out and the caller's line is sent as written, not twice. The explicit fields on `Begin` still win when both are given. [ADR 182](../adr/182-a-header-std-owns-goes-out-once.md)
9. **Following a redirect is an explicit choice.** `Begin.redirects` defaults to `.refuse`: a 3xx with a `Location` returns `error.RedirectRefused`. `.follow = &buf` follows up to three redirects and sets `head.redirected` to where it ended. `.expose` returns the 3xx itself, for a signed request that must not be redirected silently. [ADR 183](../adr/183-a-redirect-is-a-decision-with-a-name.md)
10. **A caller that will not read the body can say so with `discard`.** `ex.discard()` marks the connection to be closed without weighing `max_drain` against the announced length; the permit is still returned. [ADR 184](../adr/184-a-caller-that-knows-says-discard.md)
11. **The transfer buffer does nothing on the direct read path, and the docs say so.** `Begin.transfer_buffer` only matters when the caller reads buffered data from `ex.reader`. `take`, `readInto`, `pipe` and `stream` never fill it, and one socket read is the same size with or without it. `Settings.read_buffer_size` (default 8 KiB, std's own default) is what actually sets the size of a read. [ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md)
12. **A head stays readable after its body only if it is kept.** `head.keep(c)` copies the header block, the content type and a followed redirect's URL into the Scope, once, for the calls that ask. A whole-body call (`get`, `postJson`, …) makes the same copy automatically before reading the body over it, so `res.header("etag")` and `res.header("retry-after")` still work after the body is read. [ADR 187](../adr/187-a-head-that-outlives-its-body.md)
13. **A `.stream` body goes on a connection no pool held**, because a reader cannot be sent twice and so cannot take the replay that protects a slice body from a connection the server closed while it idled. It costs a handshake per call and nothing until the first one. [ADR 058](../adr/058-most-of-an-s3-client-is-not-s3.md)
14. **An answer sent before the body was finished is the answer.** A failed write is not retried, but the head the server already sent is read once, under the call's own deadline; a refusal (4xx, 5xx) is returned and the connection is not reused, while a 2xx or nothing readable stays `WriteFailed`. [ADR 058](../adr/058-most-of-an-s3-client-is-not-s3.md)

## Decisions

| ADR | What it decides |
|---|---|
| [061](../adr/061-a-fitting-borrows-the-loop.md) | The Fitting layer, `Client`, `Target`, `withQuery`, the JSON calls |
| [158](../adr/158-a-request-id-goes-out-with-the-call.md) | `X-Request-Id` is sent on every call made with a `*Ctx` |
| [174](../adr/174-the-body-decides-not-the-method.md) | Whether a body is present, not the method, decides how a request is framed |
| [176](../adr/176-an-answer-with-no-body-ends-at-its-head.md) | The four RFC 9112 cases that end at the header block whatever the length says |
| [182](../adr/182-a-header-std-owns-goes-out-once.md) | A caller's own line for a header std manages replaces std's |
| [183](../adr/183-a-redirect-is-a-decision-with-a-name.md) | `.refuse` / `.follow` / `.expose`, and `head.redirected` |
| [184](../adr/184-a-caller-that-knows-says-discard.md) | `Exchange.discard()` for a body the caller knows it will not read |
| [186](../adr/186-the-transfer-buffer-serves-nothing-here.md) | What `transfer_buffer` and `read_buffer_size` each actually do |
| [187](../adr/187-a-head-that-outlives-its-body.md) | `head.keep(c)` and `Response.headers`, copied once so they outlive the body |

Related topics: the layering rule that makes a Fitting its own layer, never a sibling of a Service, is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md) and [ADR 057](../adr/057-percent-is-needed-by-two-layers.md) (layering); what an outbound call costs the connection waiting on it is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); setting a deadline on a call is [ADR 056](../adr/056-the-way-out-was-open-the-clock-was-not.md) (deadlines); `Target` is a type in the same way a Bucket is in [ADR 059](../adr/059-a-bucket-is-a-type-and-a-key-is-not.md) (s3); passing the base URL and credential to `open` instead of compiling them in follows the setting versus deployment split in [ADR 039](../adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md) (config); `nilo_ready`'s default (started means ready) is [ADR 154](../adr/154-a-health-route-asks-the-services.md) (lifecycle).

## Open questions

- **Starting an `Exchange` from a `Target`.** Wanted but not built: a streamed call through a target would need the target's standing headers and limit to reach `Exchange.begin`, which today takes a client and a URL directly. [ADR 061](../adr/061-a-fitting-borrows-the-loop.md) leaves it waiting for someone who streams from a service with standing headers, and it is listed on [the todo list](../todo.md).
- **Whether a larger `read_buffer_size` reduces syscalls for a caller reading many large bodies at once.** The field now exists for exactly this measurement; [ADR 186](../adr/186-the-transfer-buffer-serves-nothing-here.md) notes it could not be measured before the field existed.
