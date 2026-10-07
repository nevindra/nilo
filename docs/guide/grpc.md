# gRPC

**A gRPC method is an ordinary route: a listener that speaks gRPC turns each unary call into a `POST` and the route's answer back into a gRPC response.**

**Reference:** [`listen` options (`grpc`, `also`)](../reference/app.md#listen-options) · **Design:** none; the decision is [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)

`app.rpc(T)` serves a struct's functions as a service's methods, or `app.post("/package.Service/Method", handler)` registers one, and a handler whose argument is the request message and whose return type is the reply is the whole of it. Middleware, fail functions, deadlines, counters and the log all see a call as the request it became.

It is for callers you do not choose: a service whose contract is a `.proto` file, an OpenTelemetry Collector exporting OTLP, a Kubernetes plugin, an Envoy filter. It supports unary calls only, and it has to be built in ([ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).

## Turning it on

**Build with `.http2 = true` and give gRPC a listener of its own.** In your `build.zig`, ask the dependency for it:

```zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .http2 = true });
```

Then add a listener next to the one that serves HTTP/1.1:

<!-- compiles -->
```zig
fn serve(app: *nilo.App) !void {
    try app.post("/demo.Echo/Say", say);
    try app.listen(.{
        .port = 8080,
        .also = &.{.{ .port = 50051, .grpc = true }},
    });
}

fn say(c: *nilo.Ctx) !void {
    const message = try c.body();
    try c.send(200, "application/grpc", message.view());
}
```

Port 50051 speaks HTTP/2 with prior knowledge (h2c), which is what every gRPC client sends to a plain address. Port 8080 stays HTTP/1.1 exactly as before, and a request there to `/demo.Echo/Say` is an ordinary `POST`. A server that should speak only gRPC puts `.grpc = true` on `listen()`'s own options instead.

A build that did not pass `.http2 = true` rejects the listener at `listen()` with a message naming the flag, and contains none of the HTTP/2 code: a program that never asks for it pays 8 to 112 bytes of binary.

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
| 409 | `ABORTED` (10) |
| 412, any other 4xx | `FAILED_PRECONDITION` (9) |
| 413, 429 | `RESOURCE_EXHAUSTED` (8) |
| 503 | `UNAVAILABLE` (14) |
| 500 | `INTERNAL` (13) |

So `return fail.notFound("no order {d}", .{id})` becomes `NOT_FOUND` with that message, and the handler does not need to know gRPC is involved. For a code no error names, answer with the code yourself, as a trailer: `try c.setTrailer("grpc-status", "5")`. A `grpc-status` trailer the route set wins over the one nilo would have chosen.

**A Connect client that calls the same method is told the same code, by name.** A request carrying `Connect-Protocol-Version: 1` that fails is answered `{"code":"already_exists","message":"…"}` from this table, with the message the failure carried, in place of nilo's usual shape; any other request keeps that ([Errors](./errors.md#a-connect-clients-failure)).

**`grpc-status` and `grpc-message` are trailers, so `c.setHeader` refuses them** with a sentence that points at `setTrailer`. gRPC sends them after the message, and a header would put them before it.

A path no route answers is `UNIMPLEMENTED`, and a message larger than its route's limit is `RESOURCE_EXHAUSTED`: `max_body`, or what the route said with [`nilo.maxBody`](../reference/middleware.md#nilomaxbody), raised or lowered, as on any route. A connection's messages together are held to `max_body`, or the largest limit a route raised to. A request whose `content-type` is not `application/grpc` or `application/grpc+` and a subtype (`application/grpc-web` is another protocol) is a 415, and one that is not well-formed HTTP/2 (a pseudo-header twice, unknown or after a regular field, or no `:scheme`) has its stream reset with `PROTOCOL_ERROR`.

## Deadlines

**A client's `grpc-timeout` becomes the request's deadline**, the same one `nilo.deadline(ms)` gives a route ([deadlines](./deploying.md#deadlines)), counted from when the call's headers arrived and not from when its message was whole. Every wait nilo owns is cut short by it, and `c.overdue()` tells a loop of your own when time is up. A route that fails after the client's time is up is answered `DEADLINE_EXCEEDED` whatever it failed with, because that is what happened as far as the client can tell. `limits.request_deadline_ms` does not extend a deadline a call brought with it; a route's own `nilo.deadline` replaces it.

## gRPC over TLS

**A listener with both `.tls` and `.grpc` offers only `h2` by ALPN**, in a build that also passed `.tls = true` ([TLS without a proxy](./deploying.md#tls-without-a-proxy)). A client that offers only `http/1.1` fails the handshake there, and a TLS listener without `.grpc` still offers only `http/1.1`.

## What it does not do

- **Streaming calls.** One message in, one out. A call that sends a second message is answered `INTERNAL`.
- **HTTP/2 for anything but gRPC.** A browser, or `curl --http2` to a plain route, still reaches nilo as HTTP/1.1; for HTTP/2 there, put a proxy in front.
- **gRPC and HTTP/1.1 on one port.** A connection to a gRPC listener that does not open with HTTP/2's preface gets a 505, and an HTTP/1.1 listener rejects the preface as a request line it cannot read.
- **Many large gzip calls side by side on one connection.** The inflated copy of a gzip message is held to the room the connection has, which is `max_body` less what the other calls on it hold, and a call that does not fit waits, holding only its compressed bytes, until the calls ahead of it finish. A call alone on its connection has all of it, and a waiting call whose `grpc-timeout` passes is answered `DEADLINE_EXCEEDED` without running. **A Collector sending batches of a few MB on one connection gets one or a few running at a time**, the rest waiting rather than retried; raise `max_body` for more side by side ([the arithmetic](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md#what-the-budget-does-to-an-opentelemetry-collector)).
- **Compressed answers.** A client's gzip is read; the answer goes back uncompressed.

## What it costs

**An idle gRPC connection costs under a page more than an HTTP/1.1 one, about 5.8 KB**, and the HTTP/1.1 listeners of the same build cost what they did without it. A call in flight is a fiber, 4,547 bytes plus the stack the route touches, and a connection holds at most 100 calls at once, which it tells the client when it connects. From the second call on a connection onward, a call allocates nothing on the heap.

On four cores a unary call runs at about 770,000 a second, against grpc-go's 590,000 and tonic's 900,000, and the slowest call is slower than either's. The difference comes from where the call's fiber is scheduled, not from HTTP/2, and it is written up with the rest of the numbers in [`bench/result/http.md`](../../bench/result/http.md#a-grpc-listener-built).
