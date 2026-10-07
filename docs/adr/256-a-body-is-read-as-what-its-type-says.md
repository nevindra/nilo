# A body is read as what its type says, and a message answers in the spelling it was asked in

**Status:** accepted
**Topic:** [framing](../design/framing.md)
**Extends:** [ADR 157](./157-a-type-can-write-its-own-answer.md) (its mirror on the way in: `nilo_decode` beside `nilo_content_type`), [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md) (a gRPC method whose argument is a message is read without the handler calling `proto.decode`), [ADR 245](./245-protobuf-is-read-from-the-struct-that-declares-it.md) (`nilo_http` reads a `wire` table on a route, not only in `otlp.zig`)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 016](./016-the-api-description-comes-from-the-signatures.md) (the document is read off the signature)

## Context

A request body was JSON, a form, or bytes a handler read itself with `c.body()`. ADR 157 gave the way out a third answer, a type that writes its own bytes under its own label, and left the way in without one, so a route receiving protobuf, MsgPack or a vendor's binary took a `*Ctx`, decoded by hand, and the API description could not say what it read. gRPC was the sharpest case: every method in the guide opened with `proto.decode(Request, c.arena(), (try c.body()).view())` and closed with `c.send(200, "application/grpc", try proto.encode(…))`, two lines of plumbing around the one line that was the method.

The roadmap's first direction asks for more than a door ([framing](../design/framing.md#how-the-direction-is-built), stage 4): one typed function that is a JSON route, a protobuf route and a gRPC method at once. Connect's unary protocol already has the rule that makes that possible. A request says what it is in with `Content-Type`, `application/json` or `application/proto`, and the answer goes back in the same one.

## Decision

**A struct with a `wire` table is a message, and the request's `Content-Type` says which spelling of it was sent.** `application/proto`, `application/protobuf`, `application/x-protobuf`, `application/grpc` and `application/grpc+proto` are read by `nilo_proto` (ADR 245). Anything else, no content type included, is read by nilo's JSON reader exactly as any other struct is whatever its label, every check of ADR 148, 166, 193 and 251 included: `curl -d` says `application/x-www-form-urlencoded` and a `fetch` of a string `text/plain`, and both keep working against a route whose argument became a message. A message that does not decode is a 400 naming the type and what was wrong with the bytes, in words rather than an error name.

**The answer goes back in the spelling the request came in.** A handler returning a message answers protobuf to a request that sent protobuf, under `application/proto`, or `application/grpc` to a gRPC call; and JSON to everything else, which includes a GET with no body. It is decided by the request's own `Content-Type` at the point of answering, not by which argument was read, so a gRPC method whose argument is empty still answers protobuf. A route whose body is a message has to answer a message or nothing, and anything else is refused at the route: a protobuf client cannot read JSON.

**Any other type that knows its own bytes declares `nilo_content_type` and `nilo_decode`**, the mirror of ADR 157's pair:

```zig
const Reading = struct {
    sensor: u16,
    value: f32,

    pub const nilo_content_type = "application/x-reading";

    pub fn nilo_decode(body: []const u8, arena: std.mem.Allocator) !Reading {
        _ = arena;
        if (body.len != 6) return error.WrongLength;
        return .{ .sensor = std.mem.readInt(u16, body[0..2], .big), .value = @bitCast(std.mem.readInt(u32, body[2..6], .big)) };
    }
};

fn record(store: *Store, r: Reading) !void { … }
```

It is the body whatever kind it is, and it is read only when the request's media type is its own, compared without case and without parameters; otherwise a 415 says what it reads and what arrived. An error `nilo_decode` returns is a 400 naming it, and a fail function it calls answers with its own status and sentence. The bytes it is handed live as long as the request, so the value may borrow them.

**What is refused at the route**, each with a file in `refusals/`: `nilo_decode` without `nilo_content_type`; a `nilo_decode` with any other signature; a type with both a `wire` table and `nilo_decode`, which says two things about one body; a type with both `nilo_decode` and `nilo_parse`, which could be the body or a path param; `Bound(T)` around either kind, since protobuf has no field that fails on its own; and a route reading a message and answering something that is not one.

**What the document says.** A message is filed under both `application/json` and `application/proto` with one schema, its fields, on the request and on the answer: the schema says what the data is and the media type how it is spelled, which is how OpenAPI files one schema under several types. A type with `nilo_decode` is filed under its label, described by its `nilo_openapi` or by `{}` with a note, ADR 157's discipline.

**What nilo's JSON is not, for a message.** It is nilo's JSON, the one every other struct is read and written in, not protobuf's canonical JSON mapping: field names are the Zig field names, a 64-bit integer is a number and a `bytes` field is text. A Connect client reading JSON accepts the proto field names and numbers for 64-bit integers, so a message whose names match its `.proto` and that has no `bytes` field reads the same either way; a `bytes` field in JSON does not, and is in [`todo.md`](../todo.md).

## What it costs

Measured in [`bench/result/http.md`](../../bench/result/http.md#a-body-read-as-what-its-type-says).

- **Throughput:** a message read as protobuf is 282 to 284 ns a request in process, 21% faster than the same message as JSON was; read as JSON it is 52 to 58 ns slower than it was, 15%, which is the read of its `Content-Type` from the head. Only a route with a message in its signature pays it, and a route written by hand to take both spellings pays the same read. Everything else runs the code it ran before.
- **Allocations per request:** a protobuf body decodes in place, strings borrowing the body, and the answer is sized and written once: three for the measured message, where the same message as JSON is four. The request path's budget test does not move.
- **Memory per idle connection:** nothing; `bench/mem.py` reads the same figures before and after.
- **Binary size:** nothing on the request path. +64 bytes in a program that serves its API document, which is the document's content types kept as lists decided while compiling.

**Where the content type is read is the decision under all of that.** It is read by a handler with a message in its signature, the first time it needs it, and kept on that handler's wrapper's stack for the answer; for every other handler the slot is a zero-sized `void` and there is no code. Two faster places were built and turned down, below.

## What was rejected

**`nilo_read` as the name.** It is the column protocol's (ADR 049), with the same shape, and a type can be both a column and a body that are read differently: Postgres' text for one and a wire format for the other.

**A 415 for a label that is neither spelling**, which is Connect's rule and was this ADR's first. It refuses exactly the clients that do not name what they send, `curl -d` and a `fetch` of a string, which a plain struct's route reads, while a protobuf client always names protobuf; a route whose argument gained a `wire` table would have stopped answering them.

**A message read as protobuf only.** It is simpler, and it loses the one property the direction exists for: the same function answering a browser's `fetch` in JSON and a service's client in protobuf. It also loses Connect's JSON half, which is how most people call a Connect API by hand.

**Choosing the answer's spelling by `Accept`.** ADR 157 refused negotiation by `Accept` because `fetch()` and `curl` send `*/*`; the request's `Content-Type` already says what the client speaks, and gRPC and Connect both answer in it.

**Classing the `Content-Type` in the head parser**, into two bits of a byte `http1.Request` already had. It was the fastest place: a message read as JSON within 1 to 4% of a plain struct, where what ships is 15%. It is also code on the request path of every program, message or none, 1.6 KB of request parsing once the classing function was cut from 4 KB to 969 bytes, and ADR 017 has the request path's size stay absent for a feature rather than small. The gap it closed is a read of the head that `Ctx.header` makes slowly for every caller, and that is the thing to make faster.

**A byte on the `Ctx`** to keep the spelling between the body and the answer. It sat in padding the `Ctx` had, and still cost `serve.serveRequest` 81 bytes to initialise on every request of every program. The handler's wrapper keeps it instead, where only a handler with a message has one.

**protobuf's canonical JSON mapping for a message.** Lower camel case names, 64-bit integers as strings and `bytes` as base64 would make a message's JSON differ from every other struct's in nilo, and the document from what a reader of the Zig type expects. The one place it is wrong to differ, a `bytes` field, is the open entry above.
