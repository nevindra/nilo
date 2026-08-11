# Getting started

zfast needs **Zig 0.16**. Nothing else — no C library, no system package.

## Add it to your project

Starting from an empty directory, `zig init` first — `zig fetch --save` writes
into `build.zig.zon` and fails with `no build.zig file found` if there isn't one
yet:

```
zig init
zig fetch --save git+https://github.com/nevindra/zfast
```

That writes zfast into your `build.zig.zon`. Then hand the module to whatever
imports it, in `build.zig`:

```zig
const zfast = b.dependency("zfast", .{ .target = target, .optimize = optimize });

const exe = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfast", .module = zfast.module("zfast") }},
    }),
});
b.installArtifact(exe);
```

Pass the same `.optimize` through to the dependency. Building zfast in `Debug`
under a `ReleaseFast` program is legal and slow, and nothing warns about it.

## A server that answers

```zig
const std = @import("std");
const zfast = @import("zfast");

pub const std_options = zfast.std_options;
pub const std_options_debug_io = zfast.debug_io;

fn hello() []const u8 {
    return "hello from zfast\n";
}

fn greet(name: zfast.Str) zfast.Str {
    return name;
}

pub fn main() !void {
    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.use(zfast.logger.standard);

    try app.get("/", hello);
    try app.get("/greet/:name", greet);

    try app.listen(.{});
}
```

```
$ zig build run
$ curl localhost:8787/
hello from zfast
$ curl localhost:8787/greet/wati
wati
```

`hello` takes nothing and returns text. `greet` takes a `zfast.Str`, which is
the first `:param` in the pattern — text that belongs to the request and is only
valid while it runs. Neither function knows what HTTP is, which is the point:
both are callable from a test.

## The two lines at the top

They are easy to write the wrong way round, and each fixes a different symptom.
`listen()` says so at startup if either is missing, so you don't have to
remember which.

```zig
pub const std_options = zfast.std_options;
```

Turns the Engine's debug chatter down to warnings. Without it a debug build opens
with `debug(zio): Spawning worker thread 1` and buries your own logs. To keep
settings of your own, start from this one:

```zig
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = zfast.std_options.log_scope_levels,
};
```

```zig
pub const std_options_debug_io = zfast.debug_io;
```

Keeps `std.log` from blocking the event loop. Writing to stderr is a syscall, and
many requests share one OS thread — so without this every log line stops every
request on that thread. The symptom is a server that is merely slow, which is why
`listen()` warns rather than letting you find it under load.

There is an optional third line, worth having in production:

```zig
pub const panic = zfast.panic;
```

It makes a crash say which request caused it — `panic: integer overflow (while
handling GET /boom/50)`. See [Deploying](./deploying.md#panics).

## The allocator

`App.init` takes one, and it is used for the App's own furniture: the route
table, the static files, the service registry. Requests do **not** allocate from
it — each gets an arena of its own that is thrown away when it ends.

`std.heap.smp_allocator` is the one to use for a server: it is built for
allocation from several threads at once. Use `std.testing.allocator` in tests,
which also checks for leaks.

## Where to go next

- [Handlers](./handlers.md) — the rule that decides what each argument means.
- [Routing](./routing.md) — patterns, precedence, and grouping.
- The five examples in [`examples/`](../../examples/), each runnable with
  `zig build run-<name>`.
