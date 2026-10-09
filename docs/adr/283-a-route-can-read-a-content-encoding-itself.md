# A route can read a Content-Encoding itself

**Status:** accepted
**Topic:** [http1-protocol](../design/http1-protocol.md)
**Extends:** [ADR 089](./089-a-body-under-an-encoding-other-than-gzip-is-refused.md)

## Context

[ADR 089](./089-a-body-under-an-encoding-other-than-gzip-is-refused.md) answers a 415 to any `Content-Encoding` but `identity` and `gzip`, while the head is read, before any route matches. It is right as the default: snappy, brotli and zstd bodies handed to a JSON parser were the bug it fixed. What it left without an answer is the receiver whose protocol is a coding nilo does not decode. Prometheus remote-write 1.0 sends a protobuf body in snappy's block format under `Content-Encoding: snappy`, every Prometheus server and agent speaks it and no client setting avoids it. An OTLP route may want zstd, and a gateway forwarding a body untouched wants every coding there is. Because the refusal precedes the route match, not even `c.bodyStream()` could reach the bytes. nilo is not going to implement snappy (ADR 017's binary size axis, and a codec is not what an HTTP framework is for): the handler can, if it is handed the bytes.

## Decision

**A route names the `Content-Encoding` values it reads itself, `app.with(nilo.bodyEncodings(.{"snappy"}))`, and gets a body under one of them exactly as it arrived.** `c.body()` and `c.bodyStream()` return the wire bytes, `c.header("content-encoding")` says which coding they are in, and `max_body` (or the route's `maxBody`) is applied to the compressed length. The handler decodes, and bounds what it decodes to, since it knows the format and nilo does not.

**The refusal is held back, not removed, and only for an App that uses the feature.** `finish` still refuses a body under `.other` at the blank line, so a request that was always a 415 is parsed as before. For an App with at least one `bodyEncodings` (`App.reads_codings`, set when it is registered), the first refusal in `serve` re-parses the head once with `Request.encoding_deferred` set, and the route is matched as ever. If the chain the request is about to run has no `bodyEncodings` naming the coding, the answer is `RESPONSE_415`, the same static bytes as before. If it has some and none names this coding, the answer is a 415 failure whose `Accept-Encoding` lists `identity, gzip` and every name in the chain. If one names it, the chain runs and the middleware tells the `Ctx` to hand bytes over as sent. A request that parses first time, which is every request that is not about to be a 415, takes none of this: the cost is on the path that was already an error.

**The names are compared whole, ignoring case.** `"gzip, snappy"` names a body stacked under two codings, and is not `"snappy"`. Several `bodyEncodings` in one chain read the union of what they name. `"identity"`, an empty name and an empty list are compile errors (three refusals).

**Naming `"gzip"` passes gzip through undecoded on that route**, for a route that stores or forwards it. A route that does not name it still gets gzip inflated, as every route does.

**A reader that parses is not handed these bytes.** `c.json`, `c.form` and a typed `body: T` answer a 415 for a body that arrived under a coding the route reads itself, through `Ctx.dataBody`, which every reader but `body()` calls. A type that carries `nilo_decode` is handed the bytes, because decoding its own body is what it declared. The check is at run time, not a compile error, because a route's chain is settled at `listen()` and a global `use(nilo.bodyEncodings(…))` reaches routes whose signature was written without knowing.

**`body()` refuses a coding nobody read.** A body under `.other` reaching `body()` on a route that did not pass it through is a 415, whatever put it there. That closes a gap on HTTP/2, where a body framed by its stream has no `Content-Length` for `finish` to test: `parseArrived` now refuses it, held back the same way, and `body()` is the last place the bytes stop.

**HTTP/2 and gRPC mean the same.** An HTTP/2 call reaches the App through `serve.serveRequest` and `parseArrived`, held to the rules of an HTTP/1.1 head, so the route modifier is read in the same place and means the same. gRPC's `grpc-encoding` is another header read by the gRPC side and is untouched; a message under it is not a `Content-Encoding` body.

**OpenAPI says nothing.** A request body's `Content-Encoding` is a header on the transfer and not part of the schema of what the body means (a Prometheus write is `application/x-protobuf` whatever its coding), and the document has no place that expects a coding to be declared.

## What was rejected

**A blanket raw flag**, `nilo.rawBody()`. It has less to write and more to get wrong: an unexpected encoding on the route would reach a decoder that assumed its own, and the first reader of the 415 would be a crash in the handler. Naming the codings keeps "a coding nobody planned for is a 415" true on the route, and it costs one comptime tuple.

**Doing the match before the head is parsed**, so the refusal could be decided with the route in hand. The router takes a method and path the parse produces, and doing it on every request adds work to the path that has none. Holding the refusal back adds work only on the request that would have been refused.

**Leaving the 415 in `finish` and letting a route pass through `c.body()` raw anyway**, by making the middleware set a bit read by the parser. The parser runs before the route is known, so the bit would have to be per App, and every route would then pass every coding.

**Adding the compile-time check for a typed body on a route that names a coding.** The chain is resolved at `listen()`, where a global `use` can add the middleware to a route written without it, so the compiler cannot see the pair. The run-time 415 is the check that holds.

**Decoding snappy or zstd in nilo**, so the route need not. A codec per coding is binary size on the axis ADR 017 holds, for formats the handler's author already has a library for, and it would be one more coding to answer for. If one is common enough to earn it, it is its own decision, and this one is the seam it would sit behind.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none on a request that is not under a coding nilo refuses, and the allocation-budget test in `http/behaviour.zig` passes unchanged. A request held back and then refused by a chain with some `bodyEncodings` allocates its `Accept-Encoding` once, in the arena |
| Memory per idle connection | unchanged: `Ctx` is 1,096 bytes before and after (`_body_as_sent` and `Request.encoding_deferred` land in padding, `@sizeOf` measured), and the new work is in a `noinline` function that is not on the connection loop's frame. `park-check` pins it |
| Throughput and p99 | one `bool` local in `serveRequest`, one enum compare in `body()` that the `gzip` test was already making. Not measured with a load generator: no instruction was added to a request that parses first time except a test of that `bool` after the route match, taken only when it is set |
| Binary size | one middleware function per distinct `bodyEncodings` list in a program that uses it, and in one that does not, the `reads_codings` test in `serve`. Unmeasured |
