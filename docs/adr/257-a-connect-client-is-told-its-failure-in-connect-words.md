# A Connect client is told its failure in Connect's words

**Status:** accepted
**Topic:** [framing](../design/framing.md)
**Extends:** [ADR 024](./024-every-failure-answers-as-json.md) (a Connect call's failure takes Connect's shape over the App's own), [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md) (the code a failed call answers with is one table, read by the gRPC listener and by this)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 256](./256-a-body-is-read-as-what-its-type-says.md) (a message answers in the spelling it was asked in)

## Context

ADR 256 made one typed function a JSON route, a protobuf route and a gRPC method, and a Connect client's unary call is already one of those: a POST to `/package.Service/Method` whose body is the message in JSON or protobuf, answered in the same. What it could not read was a failure. A Connect client expects `{"code":"not_found","message":"…"}`, the code one of gRPC's seventeen by name, and nilo answered `{"error":"…","status":404}`. The protocol has a way out for that, a code made up from the HTTP status when the body is not an error it can read, so the client did not break; it lost the sentence and every code the status cannot carry, `already_exists` and `aborted` among them, which are the two that tell a client whether to try again.

A Connect client says what it is: every call carries `Connect-Protocol-Version: 1`.

## Decision

**A request carrying `Connect-Protocol-Version: 1` that fails is answered with Connect's error body**, `{"code":"<name>","message":"<sentence>"}` as `application/json`. The sentence is the one nilo would have sent: a fail function's, or what the mapping table says for an error (ADR 004). The code is chosen as the gRPC listener chooses it, the error first (`error.AlreadyExists` is `already_exists`, `error.RolledBack` is `aborted`) and the status otherwise (404 `not_found`, 401 `unauthenticated`, 503 `unavailable`, and the rest of ADR 220's table), so a method failing the same way reads the same to a client of either protocol. The table is `http/code.zig`, gRPC's numbers, Connect's names and the one list of errors that name a code, which the listener and this both read.

**Every other request keeps the shape it had**, nilo's or the one `app.failures(T)` named. A Connect call is answered in Connect's shape over an App's own, because its client reads nothing else. The five answers written before there is a request to route (a malformed head, a head too long or too slow, a body under a coding nilo cannot read, a request shed) keep nilo's constants as ADR 024 says, and a Connect client reads their status.

**The status is the one nilo chose.** Connect's table would answer `failed_precondition` with a 400 where nilo's 412 said it; a Connect client reads the code from the body and the status only when there is no body to read, and the logger, the counters and every middleware have already seen nilo's.

**Only in a program with a message route.** The first route whose handler reads or answers a message (ADR 256) hands the App Connect's shape, and until then the pointer is null and none of it is linked. A Connect client calls methods, and a method's argument is a message; a program with none has no Connect client. Once it has one, a path no route answers, asked by a Connect client, is a `not_found` in the same shape, which a route-level answer could not have given.

## What it costs

Measured in [`bench/result/http.md`](../../bench/result/http.md#a-connect-client-told-its-failure).

- **Throughput:** nothing on a request that succeeds. A failure in a program with a message route reads the head once more for the version header, the scan ADR 256 reads `Content-Type` with; a program without one does a null check.
- **Allocations per request:** none. The body is written into the fixed buffer every failure body is written into.
- **Memory per idle connection:** nothing.
- **Binary size:** +96 bytes in every default program stripped (`example-hello`, `example-rest`), +128 with `-Dgrpc`: the choice on the failure path, a null check and a call, the same kind of cost `app.failures` paid (ADR 024). A program with a message route pays about 1.7 KB more by symbol, the header scan and the writer.

## What was rejected

**Connect's shape for every failure, header or not.** A browser's `fetch` against a message route reads ADR 024's shape, and the same route would have answered it two ways depending on nothing it sent.

**The handler's wrapper answering a Connect failure itself**, which would have cost every program nothing. It answers before the error reaches the chain, so a middleware that rolls back or counts on an error would see a success, and a path no route answers would still go out in nilo's shape.

**The header read in every program.** About 1.7 KB of scan, table and writer linked into programs that cannot have a Connect client, where the pointer set at registration links it only into those that can.

**The error handed to the shape**, a third argument to the `Write` every App's shape has. It kept the error live across the call and cost `sendFailure` 182 bytes of spilled registers; handed to the choice instead, which returns a writer already knowing the code the error names, it is 84 and `Write` is unchanged.

**`app.connect()`, an opt-in.** One more call to know about, for what the signature of a route already says.

**Connect's HTTP status table.** Above: the status is what everything but the client has already read.
