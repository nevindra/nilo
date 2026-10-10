# gRPC

**A gRPC method is an ordinary route: a build with HTTP/2 in it turns each unary call into a `POST` and the route's answer back into a gRPC response.**

**Reference:** [`listen` options (`also`, `tls`)](../reference/app.md#listen-options) · **Design:** none; the decision is [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)

`app.rpc(T)` serves a struct's functions as a service's methods, or `app.post("/package.Service/Method", handler)` registers one, and a handler whose argument is the request message and whose return type is the reply is the whole of it. Middleware, fail functions, deadlines, counters and the log all see a call as the request it became.

It is for callers you do not choose: a service whose contract is a `.proto` file, an OpenTelemetry Collector exporting OTLP, a Kubernetes plugin, an Envoy filter. It supports unary calls only, and it has to be built in ([ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).

## Turning it on

**Build with `.http2 = true`, and the port HTTP/1.1 is on speaks gRPC too.** In your `build.zig`, ask the dependency for it:

```zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .http2 = true });
```

Then register the methods and listen as you would for HTTP/1.1:

<!-- compiles -->
```zig
fn serve(app: *nilo.App) !void {
    try app.post("/demo.Echo/Say", say);
    try app.listen(.{ .port = 8080 });
}

fn say(c: *nilo.Ctx) !void {
    const message = try c.body();
    try c.send(200, "application/grpc", message.view());
}
```

Port 8080 answers both. A connection that opens with HTTP/2's 24-byte preface is HTTP/2 with prior knowledge (h2c), which is what every gRPC client sends to a plain address, and anything else is HTTP/1.1, decided at the first byte that differs, so a short request is never waited on. An HTTP/1.1 request to `/demo.Echo/Say` is an ordinary `POST`, and an HTTP/1.1 connection costs what it did before ([ADR 259](../adr/259-http2-is-a-framing-of-every-request.md)). A port for gRPC alone is an `also` listener like any other, and there is no option to set on it.

A build that did not pass `.http2 = true` contains none of the HTTP/2 code: a program that never asks for it pays nothing in binary.

## Writing a method

**A service is a struct of yours, and its `pub fn`s are the methods.** `nilo_service` is the service's full name from the `.proto`, and each method is served at `/helloworld.Greeter/SayHello`, the function's name with its first letter upper-cased. **The message is a struct of yours with its field numbers on it** ([Protobuf messages](./proto.md)), and a function that takes one and returns one is a method:

<!-- compiles -->
```zig
const HelloRequest = struct {
    pub const wire = .{ .name = 1 };
    name: []const u8 = "",
};

const HelloReply = struct {
    pub const wire = .{ .message = 1 };
    message: []const u8 = "",
};

const Greeter = struct {
    pub const nilo_service = "helloworld.Greeter";

    pub fn sayHello(arena: std.mem.Allocator, in: HelloRequest) !HelloReply {
        return .{ .message = try std.fmt.allocPrint(arena, "hello, {s}", .{in.name}) };
    }
};

fn mountGreeter(app: *nilo.App) !void {
    try app.rpc(Greeter);
}
```

Each method is an ordinary route, the one `app.post("/helloworld.Greeter/SayHello", Greeter.sayHello)` would register, so it takes services and middleware as any route does. A `pub fn` that neither reads nor answers a message is a compile error, since it would otherwise be served; a helper stays private. `app.with(requireLogin).rpc(Greeter)` puts middleware in front of a whole service ([ADR 258](../adr/258-a-struct-of-typed-functions-is-an-rpc-service.md)).

The call's message is read from the body with gRPC's five-byte prefix removed, and gunzipped if the client sent `grpc-encoding: gzip`, which the Collector does on every call; the reply is written as protobuf and framed on the way out. Bytes that are not a `HelloRequest` are `INVALID_ARGUMENT` with a sentence saying what was wrong. The same function on the HTTP/1.1 listener answers JSON to a client that sends JSON ([ADR 256](../adr/256-a-body-is-read-as-what-its-type-says.md)).

**A handler that wants the bytes takes a `*Ctx`**: `c.body()` is the message and `c.send(200, "application/grpc", bytes)` the answer, which is how a type generator such as [zig-protobuf](https://github.com/Arwalk/zig-protobuf) is used, since nilo reads and writes bytes and never looks inside them.

A call's metadata arrives as request headers, so `c.header("x-tenant")` reads it, and a header the route sets with `c.setHeader` goes back as metadata. Metadata that goes after the message is a trailer, set with `c.setTrailer` ([trailers](./responses.md#trailers)).

## Errors and gRPC status codes

**A route that fails the ordinary way is answered with the matching gRPC status**, and the failure's message as `grpc-message`. The code comes from the error first: `error.AlreadyExists` is `ALREADY_EXISTS` (6) and `error.RolledBack` is `ABORTED` (10), whatever HTTP status the error maps to. Any other error takes the code from its HTTP status, as this table says:

| the route failed with | the client sees |
|---|---|
| 400, 415, 422 | `INVALID_ARGUMENT` (3) |
| 401 | `UNAUTHENTICATED` (16) |
| 403 | `PERMISSION_DENIED` (7) |
| 404 | `NOT_FOUND` (5) |
| 405, 501 | `UNIMPLEMENTED` (12) |
| 408, 504 | `DEADLINE_EXCEEDED` (4) |
| 409 | `ABORTED` (10) |
| 412, any other 4xx | `FAILED_PRECONDITION` (9) |
| 413, 429 | `RESOURCE_EXHAUSTED` (8) |
| 499 | `CANCELLED` (1) |
| 503 | `UNAVAILABLE` (14) |
| 500 | `INTERNAL` (13) |
| any other 5xx | `UNKNOWN` (2) |

So `return fail.notFound("no order {d}", .{id})` becomes `NOT_FOUND` with that message, and the handler does not need to know gRPC is involved. For a code no error names, answer with the code yourself, as a trailer: `try c.setTrailer("grpc-status", "5")`. A `grpc-status` trailer the route set wins over the one nilo would have chosen.

**A Connect client that calls the same method is told the same code, by name.** A request carrying `Connect-Protocol-Version: 1` that fails is answered `{"code":"already_exists","message":"…"}` from this table, with the message the failure carried, in place of nilo's usual shape; any other request keeps that ([Errors](./errors.md#a-connect-clients-failure)).

**`grpc-status` and `grpc-message` are trailers, so `c.setHeader` refuses them** with a sentence that points at `setTrailer`. gRPC sends them after the message, and a header would put them before it.

A path no route answers is `UNIMPLEMENTED`, and a message larger than its route's limit is `RESOURCE_EXHAUSTED`: `max_body`, or what the route said with [`nilo.maxBody`](../reference/middleware.md#nilomaxbody), raised or lowered, as on any route. A connection's messages together are held to `max_body`, or the largest limit a route raised to. A request whose `content-type` is not `application/grpc` or `application/grpc+` and a subtype (`application/grpc-web` is another protocol) is not a gRPC call: it is an ordinary HTTP/2 request, answered as one by its route, and one that is not well-formed HTTP/2 (a pseudo-header twice, unknown or after a regular field, or no `:scheme`) has its stream reset with `PROTOCOL_ERROR`.

The same connection serves any other request, a `GET` or a `POST` with a JSON body, through the router, middleware and handler as HTTP/1.1 does. **A handler runs when the headers are in**, as it does on HTTP/1.1, and what the client sends after them is read through `c.body()` or `c.bodyStream()` the same way: `c.body()` waits for the whole of it, `c.bodyStream()` reads it in pieces and the client sends no faster than the handler reads, and `Expect: 100-continue` is answered when the handler first reads a body that has not arrived. **A handler writes its answer in pieces too**: `c.stream()`, `c.events()` and `c.sendFile` (a file is read into frames, a range request included, and a `HEAD` is its head with no `DATA`) work as they do on HTTP/1.1, the client's windows deciding how fast, and a client that stops reading is reset at the write deadline and its handler's next write fails. A connection takes turns between its streams, so a small answer is not held behind a large one. What a handler cannot do on HTTP/2 yet is refused by name with a 500 that says so: `c.eventsFrom` and `c.upgrade` (a WebSocket is HTTP/1.1). `CONNECT` is answered 501.

## Deadlines

**A client's `grpc-timeout` becomes the request's deadline**, the same one `nilo.deadline(ms)` gives a route ([deadlines](./deploying.md#deadlines)), counted from when the call's headers arrived and not from when its message was whole. Every wait nilo owns is cut short by it, and `c.overdue()` tells a loop of your own when time is up. A route that fails after the client's time is up is answered `DEADLINE_EXCEEDED` whatever it failed with, because that is what happened as far as the client can tell. `limits.request_deadline_ms` does not extend a deadline a call brought with it; a route's own `nilo.deadline` replaces it.

## gRPC over TLS

**An ordinary TLS listener serves it**, in a build that also passed `.tls = true` ([TLS without a proxy](./deploying.md#tls-without-a-proxy)): the handshake offers `h2` and `http/1.1`, a gRPC client offers `h2`, and the call arrives as it does on a plain port. The option `.grpc` that used to make a TLS listener offer `h2` alone is gone ([ADR 259](../adr/259-http2-is-a-framing-of-every-request.md)), so a program that set it deletes the line.

## What it does not do

- **Streaming calls.** One message in, one out. A call that sends a second message is answered `INTERNAL`.
- **`Upgrade: h2c`.** Ignored: a request carrying it is served as HTTP/1.1, which RFC 9113 allows. A client that wants HTTP/2 on a plain port speaks it with prior knowledge, as every gRPC client and `curl --http2-prior-knowledge` do.
- **Many large gzip calls side by side on one connection.** The inflated copy of a gzip message is held to the room the connection has, which is `max_body` less what the other calls on it hold, and a call that does not fit waits, holding only its compressed bytes, until the calls ahead of it finish. A call alone on its connection has all of it, and a waiting call whose `grpc-timeout` passes is answered `DEADLINE_EXCEEDED` without running. **A Collector sending batches of a few MB on one connection gets one or a few running at a time**, the rest waiting rather than retried; raise `max_body` for more side by side ([the arithmetic](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md#what-the-budget-does-to-an-opentelemetry-collector)).
- **Compressed answers.** A client's gzip is read; the answer goes back uncompressed.

## What it costs

**An idle gRPC connection costs under a page more than an HTTP/1.1 one, about 5.8 KB**, and the HTTP/1.1 listeners of the same build cost what they did without it. A call in flight is a fiber, 4,547 bytes plus the stack the route touches, and a connection holds at most 100 calls at once, which it tells the client when it connects. From the second call on a connection onward, a call allocates nothing on the heap.

On four cores a unary call runs at about 770,000 a second, against grpc-go's 590,000 and tonic's 900,000, and its slowest call at 1,024 connections, 0.87 to 1.06 s, is tonic's 1.07 s ([where the tail comes from](../../bench/result/http.md#where-a-grpc-calls-worst-latency-comes-from)). The difference comes from where the call's fiber is scheduled, not from HTTP/2, and it is written up with the rest of the numbers in [`bench/result/http.md`](../../bench/result/http.md#a-grpc-listener-built).
