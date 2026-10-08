# A struct of typed functions is an RPC service

**Status:** accepted
**Topic:** [framing](../design/framing.md)
**Extends:** [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md) (a method is a route, and now also a `pub fn` of a struct given to `app.rpc`)
**Applies:** [ADR 256](./256-a-body-is-read-as-what-its-type-says.md) (each method reads and answers a message in the spelling it was asked in), [ADR 257](./257-a-connect-client-is-told-its-failure-in-connect-words.md) (its failures reach a Connect client in Connect's words), [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes)

## Context

After ADR 256 a gRPC method is a typed function, and a service of five methods is five lines of `app.post("/helloworld.Greeter/SayHello", sayHello)`, each repeating the service's name and spelling the method's by hand. The path is not the program's to choose: gRPC and Connect both call `/<package>.<Service>/<Method>`, from the `.proto` file, and a typo in one of the five is a method that answers `UNIMPLEMENTED` with nothing in the program wrong to look at. `nilo_sql` had the same shape of problem with tables, and answered it by making a struct the table.

## Decision

**`app.rpc(T)` serves a struct as a service: `pub const nilo_service` is its full name, and every `pub fn` is a method.**

```zig
const Greeter = struct {
    pub const nilo_service = "helloworld.Greeter";

    pub fn sayHello(arena: std.mem.Allocator, in: HelloRequest) !HelloReply {
        return .{ .message = try std.fmt.allocPrint(arena, "Hello, {s}", .{in.name}) };
    }
};

try app.rpc(Greeter);
```

**A method's name is its function's with the first letter upper-cased**, which is how protobuf spells one, so `sayHello` is `POST /helloworld.Greeter/SayHello` and a Zig function keeps Zig's case. Each method is registered by `post` as it would have been by hand: an ordinary typed route, its message read and answered by ADR 256, its failures told to a Connect client by ADR 257, its services and middleware as on any route, and its entry in the API document under the same derived name. `group.rpc(T)` is the same under a group's prefix and middleware; a gRPC client calls from the root, so its group has none.

**What is refused while compiling**, each with a file in `refusals/`: a `T` that is not a struct; no `nilo_service`, one that is not text, or one that is not dotted names of letters, digits and `_`; a `pub fn` that neither reads nor answers a message, which is a helper left public and would otherwise be served; two functions that become one method once upper-cased (`sayHello` and `SayHello`); and a struct with no `pub fn`.

**Not `app.service`.** A Service in nilo is a long-lived thing `app.provide` registers and a handler asks for by type (`CONTEXT.md`), and `app.service(Greeter)` would read as providing `Greeter`. The decl keeps protobuf's word, because its value is the protobuf service's full name.

## What it costs

Nothing on any axis for a program that does not call it, and nothing that program would not have paid with the same routes written by hand: the table of methods is worked out while compiling and handed to `post` one by one. `example-hello` and `example-rest` are byte-identical before and after.

## What was rejected

**`app.service(T)`**, the name the roadmap first gave it. Above.

**A method's name as its function's, unchanged.** `/helloworld.Greeter/sayHello` is not the method a `.proto` file declares, and a gRPC client generated from that file would never reach it; `pub fn SayHello` would reach it and read wrong beside every other Zig function.

**The method's name in a table beside the struct** (`pub const nilo_methods = .{ .sayHello = "SayHello" }`). A second place to keep in step with the functions, for the one case the upper-casing does not cover, a `.proto` method whose name is not its Zig name with one letter changed; a route written with `app.post` covers that case already.

**Every `pub fn` served whatever its signature.** A helper made `pub` for a test would become a public endpoint without a word; a method of an RPC service reads or answers a message, and anything else is said at the route.

**The full name read from the type's own name** (`Greeter` as `Greeter`, no package). The package is most of what keeps two services apart, and a Zig type's name has none.
