# Roadmap

Where nilo is heading: a few directions, each larger than one change, each saying what it is for, what it gathers up from [`todo.md`](./todo.md), and what would make it done. The concrete items, a defect, a decision, a caller awaited, a question, a measurement, live in the todo list; a direction here names them and does not repeat them. The principles every direction is held to are at the top of [`CLAUDE.md`](../CLAUDE.md#guiding-principles) and in [ADR 017](./adr/017-the-trade-budget-has-four-axes.md)'s four axes.

[How this file is written](#how-this-file-is-written) is at the bottom.

## A request is one thing, whatever framing carried it

**HTTP/1.1 and HTTP/2 become two framings of one request, and gRPC and Connect become envelopes over it, so one typed function can be a JSON route, a protobuf route and a gRPC method at once.** Today `Ctx` writes HTTP/1.1 bytes to the wire itself, and a gRPC call reaches the App by being rewritten as HTTP/1.1 text and parsed again ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md)). That translation was the right way to ship unary gRPC: it is cheap (the App's whole share of a 973 ns call is 229 ns, [`bench/result/http.md`](../bench/result/http.md#what-a-grpc-client-puts-on-the-wire-and-what-a-stream-would-cost)) and it kept HTTP/2 out of the App's core. It is the wrong foundation for what comes after, because one request and one answer has no room for a stream, for trailers a route sets, or for HTTP/2 on an ordinary route.

What the direction is, in the order it has to be built: a parsed head that does not say which framing it came from, and a response that `Ctx` hands to the framing rather than serialises itself; gRPC framing (length prefix, status in trailers) and Connect's moved above that, chosen by content type; the body door the todo list asks for, so a type with a `wire` table is read and written as `application/proto` by the typed layer; and `app.service(T)`, a struct of typed functions served as `/package.Service/Method`, the way a struct is a table in `nilo_sql`. After that, one port that answers both HTTP/1.1 and h2c, and HTTP/2 for ordinary routes over TLS with ALPN, which closes the gap [ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md) opened: a listener may face the internet with no proxy in front, and a browser reaching it gets HTTP/1.1 only.

It gathers up, from the todo list: the body door for a type nilo does not know, the gRPC listener's own port, HPACK's cost per call, and the guide's missing gRPC health service. It revises [ADR 027](./adr/027-tls-is-terminated-in-front.md) (HTTP/2 for browsers) and ADR 220 (the translation) in place, and starts a decision of its own for the seam.

**What would settle it:** the seam spiked on HTTP/1.1 alone and measured against the build before it on all four axes, with the HTTP/1.1 path unchanged on the two hard ones; the design is [the framing page](./design/framing.md), and a seam that costs the HTTP/1.1 path an allocation or a page of idle memory waits for a shape that does not.

## A stream is one shape

**A WebSocket, an event stream, a gRPC stream, a streamed upload and a compressed stream become one kind of handler: one that reads and writes in pieces, on a fiber that lives as long as the stream.** Each exists today in its own form or not at all: a WebSocket is a handler that does not return ([ADR 021](./adr/021-a-websocket-is-a-handler-that-does-not-return.md)), an event stream is written by hand, a gRPC call carries exactly one message, a multipart body is read whole, and a stream is never compressed. They share the one cost that matters, a fiber and its stack for the life of the stream ([ADR 062](./adr/062-where-a-connection-waits-is-what-it-costs.md)), so they should share the one shape that names it.

It depends on the direction above: a response that the framing writes in pieces, with trailers at the end, is what lets a gRPC server stream exist at all. It gathers up from the todo list: gRPC answering unary calls only, streamed multipart, and streams that are never compressed.

**What would settle it:** a caller with a streaming method, the per-stream figure for a stream held open measured the way `bench/mem.py --hold` measures an HTTP/1.1 one, and a design that makes the existing WebSocket and event stream handlers instances of it rather than a fourth form beside them.

## Defects are caught by a build step before a reader

**The audits keep finding the same kinds of defect, so each kind becomes a rule the build refuses rather than a finding the next audit repeats.** A decision written in several places that stopped agreeing (whether a field may be absent is decided in six), an error swallowed on a connection path, an `unreachable` a request can reach, and a code example in a header that no longer compiles: three of those four are spellable, and the first is a fix that closes its defects for good where a patch to each copy closes them until the next copy.

It gathers up, from the todo list: one rule, one function; a rule a build step holds against the patterns the audit kept finding; a mutation pass over the request path; and the public surface read back against the reference before 1.0 freezes it.

**What would settle it:** each of those entries closed, and the next audit of `http/` finding no defect of a kind a step could have refused.

## The toolkit grows by the jobs people have

**A module gets built because the job is common, and a module that dials somebody else's system is built when a deployment needs it, never ahead of one** ([ADR 017](./adr/017-the-trade-budget-has-four-axes.md), [ADR 038](./adr/038-a-module-sits-where-the-loop-puts-it.md)).

**`nilo_redis`: the same keyspace shape against somebody else's process.** A Service rather than a tool module, and deliberately not the one built first ([ADR 110](./adr/110-an-in-process-cache-and-a-redis-client-are-two-modules.md)). Two of the three usual reasons to reach for a Redis are already gone here, a session is sealed into a cookie and an allowance is a table in this process, and the first case of several instances having to agree, a queue shared by several servers, was answered by the database they already share ([ADR 160](./adr/160-a-queue-is-a-table-in-the-database-you-already-have.md)). **The two will not share an interface**: what can fail differs, and hiding that turns "the cache is down" into "the cache is cold". Both existing Zig clients are alpha and neither has pub/sub; ADR 110 records what each one does have.

**Anything else that dials, a `nilo_mail`, a second store.** Nothing structural is in the way. Each is a Fitting or a Service by one question: does it hold a connection to a named system, or is it given an address per call ([ADR 061](./adr/061-a-fitting-borrows-the-loop.md))? `nilo_s3` is the worked example of the second answer, and the most useful thing it leaves behind is that `nilo_fetch` turned out to be the right size: it needed one addition, `Exchange`, and no changes. **The bar is what a caller cannot already do**, and mail is the example of failing it: transactional mail is an HTTPS POST to a provider, which `nilo_fetch` sends today.

**What would settle it:** for `nilo_redis`, the deployment with more than one instance in it; for anything else, a caller, with the bar above applied first. This is still the most useful place for an outside contributor to look.

---

## How this file is written

**1. A direction is larger than one change.** Anything that fits in one change is an entry in [`todo.md`](./todo.md), and its rules are there. A direction says what it is for, which todo entries and ADRs it gathers up, what it depends on, and closes with `What would settle it:`.

**2. Nothing built and nothing decided is in here.** A direction that has landed leaves entirely, the way a todo entry does; what was learned goes to [`history.md`](./history.md) and the decision to an ADR.

**3. Order is dependency, not priority.** A direction that needs another says so; there are no dates, owners or tiers.

**4. A direction is held to the principles, not exempt from them.** Breaking a public API is allowed when the result is the cleaner design, and the four axes of [ADR 017](./adr/017-the-trade-budget-has-four-axes.md) are not: a direction that cannot fit them waits for the shape that does.
