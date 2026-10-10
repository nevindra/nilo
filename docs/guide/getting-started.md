# Getting started

**Start a Zig 0.17 project with nilo in four commands, add it to one you have, and restart the server on every save.**

**Reference:** [`App`](../reference/app.md#app), [`listen` options](../reference/app.md#listen-options), [root wiring](../reference/README.md#declarations-in-the-root-file) · **Design:** [nilo's design principles](../design/principles.md)

nilo needs **Zig 0.17**. Nothing else: no C library, no system package. **v0.8.0, the tag pinned below, is the first to build on Zig 0.17**; v0.7.0 and every tag before it build on Zig 0.16.0, so with 0.16 pin one of those and read this page at that tag.

## Start a project

**Copy `template/` out of the package, fetch nilo into it, and run `zig build dev`.** The template is a working server with two routes and a test, and `zig build dev` restarts it on every save:

```
mkdir hello && cd hello
curl -L https://github.com/nevindra/nilo/archive/d3ab2f33bbb8fc2281605c33a12fe3619c63f42d.tar.gz | tar -xz --strip-components=2 nilo-d3ab2f33bbb8fc2281605c33a12fe3619c63f42d/template
zig fetch --save 'git+https://github.com/nevindra/nilo?ref=v0.8.0#d3ab2f33bbb8fc2281605c33a12fe3619c63f42d'
zig build dev
```

```
$ curl localhost:8787/greet/wati
wati
```

The first command takes the template directory of that commit and nothing else. The second writes nilo into the `build.zig.zon` it brought, pinned to the commit the tag points at. **Keep the `#commit`.** The `?ref=` on its own is not a pin: nilo's tags are annotated, `zig fetch` does not resolve an annotated tag (checked again on 0.17.0), and what it gives you for `?ref=v0.8.0` alone is whatever `main` was that day. Two people installing a week apart would get two different versions, and neither asked for one. The commit for each tag is on [its release page](https://github.com/nevindra/nilo/releases).

`zig build test` runs the template's test, and `.name = .hello` in `build.zig.zon` and `"hello"` in `build.zig` are the two places to rename it (after changing the name, delete `.fingerprint` and Zig prints the one to use).

## Add it to a project you already have

**Two lines of `build.zig` and one `zig fetch --save` add nilo to an existing project.** Fetch it as above, then call `nilo.app` from your `build.zig`:

```zig
const std = @import("std");
const nilo = @import("nilo");

pub fn build(b: *std.Build) void {
    _ = nilo.app(b, .{ .name = "my-app", .root = b.path("src/main.zig") });
}
```

That reads `-Dtarget` and `-Doptimize`, fetches nilo with the same mode (see below), builds the executable with `nilo_http` imported, installs it, and adds the steps `run`, `dev` and `test`. `zig init` writes a library-and-executable scaffold around `src/root.zig`, which is not what a server wants; replace its `build.zig` with the five lines above and delete `src/root.zig`.

Options go in the struct: `.sql = true` imports `nilo_sql` and fetches its drivers, `.tls`, `.http2` and `.libdeflate` pass the matching [build flags](../reference/app.md#niloapp) to the dependency, and `.target` and `.optimize` replace the ones read from the command line. It returns the executable, the test artifact and the dependency, so a project can add to any of them:

```zig
const built = nilo.app(b, .{ .name = "my-app", .root = b.path("src/main.zig"), .sql = true });
built.exe.root_module.addImport("nilo_id", built.dependency.module("nilo_id"));
```

[Restarting on every save](#restarting-on-every-save), below, says what `dev` does and how to write it by hand.

### Without the helper

**`nilo.app` is a convenience and the dependency is a plain package.** A `build.zig` that does what it does by hand is the one below, and nothing in nilo requires the helper ([ADR 263](../adr/263-a-first-project-is-one-call-from-its-build-file.md)):

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nilo_http", .module = nilo.module("nilo_http") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the server").dependOn(&run.step);
}
```

### Fixing the `.sframe` link error

**On a Linux host whose glibc was built by GCC 16** (Arch and Fedora from mid-2026, and their derivatives), a native Debug build can stop at the link with:

```
error: fatal linker error: unhandled relocation type R_X86_64_PC64 at offset 0x1c
    note: in /usr/lib/…/crt1.o:.sframe
```

This is Zig 0.16's self-hosted linker meeting a section the system's `crt1.o` did not have before, and has nothing to do with nilo. There are two fixes, both verified:

- **`-Dtarget=x86_64-linux-gnu`** on the `zig build` line. Zig then links against the glibc it ships instead of the host's, the self-hosted linker is still used, and a Debug build is as fast as before. The binary still runs on the host.
- **`.use_llvm = true`** on the `addExecutable`, or a `-Dllvm` option that sets it, the way nilo's own `zig build examples -Dllvm` does. LLVM's linker handles the section, but a Debug build is slower.

Use the first while developing. The second is what a release build does anyway.

### Package and module names

**The package is `nilo`; the module is `nilo_http`.** The bare name belongs to the project, not to any one module: `nilo_sql`, `nilo_id` and `nilo_core` sit beside the server, and you add an import line for each one you use and nothing for the ones you don't ([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)). In your own code, alias it back:

```zig
const nilo = @import("nilo_http");
```

Pass the same `.optimize` through to the dependency. Building nilo in `Debug` under a `ReleaseFast` program works but is slow, and nilo says so at startup instead of leaving you to find out:

```
nilo was built in Debug and this program in ReleaseSafe, which is legal and
slow. Pass the mode through: b.dependency("nilo", .{ .target = target,
.optimize = optimize }) — in the test step too, which is the one that usually
gets missed.
```

**The test step is the one people usually miss**, which is why `nilo.testing.Client` prints the same warning, not only `listen()`. A suite that runs in both optimize modes fetches the dependency in the same place, and a ReleaseSafe suite running against a Debug nilo is testing a setup nobody deploys ([ADR 069](../adr/069-a-library-can-tell-what-mode-the-program-was-built-in.md)).

## The server in the template

```zig
const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;

fn hello() []const u8 {
    return "hello from nilo\n";
}

fn greet(name: nilo.Str) nilo.Str {
    return name;
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.use(nilo.logger.standard);

    try app.get("/", hello);
    try app.get("/greet/:name", greet);

    try app.listen(.{});
}
```

```
$ zig build run
$ curl localhost:8787/
hello from nilo
$ curl localhost:8787/greet/wati
wati
```

**Handlers are plain functions that don't know about HTTP, so a test can call them.** `hello` takes nothing and returns text. `greet` takes a `nilo.Str`, which is the first `:param` in the pattern: text that belongs to the request and is only valid while it runs.

## Restarting on every save

**`nilo-dev` rebuilds and restarts your server every time you save.** A Zig binary cannot swap its own code, so there is no hot reload. Instead, `nilo-dev` (shipped with the package) runs one `zig build --watch` and restarts your server whenever the binary it produces changes ([ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)). `nilo.app` writes the `dev` step for you. In a `build.zig` of your own, add these lines under the `run` step:

```zig
const dev = b.addRunArtifact(nilo.artifact("nilo-dev"));
dev.addArg("--zig");
dev.addFileArg(.zig_exe);
dev.addPassthruArgs(); // what follows `--` on the command line
// Where `install` puts the binary: a directory argument, because a file one
// would be an input, and this one is written by the build nilo-dev starts.
dev.addDirectoryArg2(
    .{ .relative = .{ .base = .install_bin, .sub_path = exe.out_filename } },
    .{ .make_absolute = true },
);
b.step("dev", "Rebuild and restart on every save").dependOn(&dev.step);
```

```
$ zig build dev
nilo-dev: building with `zig build install -fincremental` before starting anything
nilo-dev: watching with `zig build install --watch -fincremental`; serving zig-out/bin/my-app when it is written
nilo-dev: started zig-out/bin/my-app (pid 41022)
info: nilo listening on 127.0.0.1:8787 across 8 thread(s)
   ← save a file
nilo-dev: zig-out/bin/my-app changed; restarted (pid 41107, the old one drained in 100 ms)
```

### What triggers a restart

**The loop watches the build, not the repository.** `zig build --watch` reacts to the files the compiler read to make the binary: every `.zig` file the server imports (nilo's own included) and anything it `@embedFile`s. `nilo-dev` then restarts the server when that binary changes, and looks at nothing else. In a repository with a front end next to the server, a save under `web/` neither rebuilds nor restarts anything: the front end has its own dev server, and this loop is for the back end. Measured on `examples/spa`, whose `public/` is served from disk: a save to `public/app.js` left the loop untouched for the fifteen seconds it was watched, and a save to `main.zig` had the new server listening one to two seconds later ([`build.md`](../../bench/result/build.md#what-a-save-has-to-touch)).

Three edge cases:

- **A file served from disk is not watched, and does not need to be.** With `staticWith(.{ .reload = true })` the edit is served on the next request ([static files](./static-files.md#reloading-files-during-development)). Without `.reload`, or for a name that did not exist at startup, the server needs a restart and the loop will not do it. A file that reaches the binary through `@embedFile` is the opposite: it is watched, because saving it changes the binary.
- **A `.zig` file nothing imports yet is not watched either.** The build reads only what the root file reaches, so write the `@import` first and the next save is seen.
- **`build.zig` is not watched.** After a change there, press Ctrl-C and run `zig build dev` again.

A build step that reads the front end (an `installDirectory` of its assets, say) runs on a save there and copies what changed. The server is not restarted, because the binary did not change. `python3 bench/devloop.py` checks that all of this stays true, and it runs against any dev step given one file the build reads and one it does not.

**The first server always matches your current sources.** Before it watches anything, `nilo-dev` runs the build once to the end, so a binary left in `zig-out` by an earlier session, from sources you have changed since, is never started. It could otherwise seed a database with a schema you just removed. If that first build fails, the old binary is deleted and nothing starts until a save compiles ([ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)).

**A build that fails changes nothing.** The errors print, the old server keeps serving, and the next save that compiles restarts it. The old server gets SIGTERM and five seconds to finish what it was answering before it is killed. Ctrl-C stops everything.

`addPassthruArgs` is what passes anything after `--` to `nilo-dev`: `-D` options go to the `zig build` it keeps running (for example `-Dtarget=x86_64-linux-gnu` on a host with the [link error](#fixing-the-sframe-link-error)), a second `--` and what follows go to your server, and `--build <step>` picks a build step other than `install`.

**The build is incremental, so a save is served in under a second.** The compiler stays running and patches what it already built: on two cores, a save to `examples/hello` is answered by the new server 0.56 to 0.70 s later, where a full rebuild takes 3.6 to 4.5 s. It costs memory, 189 MB of resident compiler per binary the step builds, and it keeps `.zig-cache` from growing ([ADR 190](../adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)). On Zig 0.16 it needed `exe.use_llvm = true` and was off by default; 0.17 needs nothing.

`--no-incremental` rebuilds on every save instead, for a machine short of memory or a bug in incremental compilation:

```
$ zig build dev -- --no-incremental
```

**A rebuild writes a whole new binary into `.zig-cache`, and Zig never deletes the old one**: 27 MB a save for the smallest example, the size of your program for yours. So under `--no-incremental`, after each restart, `nilo-dev` deletes the cache directory of the build it just replaced, and only that one. Four saves in a row left the cache 0.0 MB larger. Undo is safe: going back to a version it deleted rebuilds it. A build of the same program for another target or mode keeps its cache entry, because the loop never served from it. `--keep-cache` keeps them all. The numbers behind both paragraphs are in [`bench/result/build.md`](../../bench/result/build.md#what-a-save-costs-on-zig-017). Files served by `staticWith(.{ .reload = true })` need none of this, because they are already read from disk per request ([static files](./static-files.md)).

## Logging setup: `std_options` and `debug_io`

**Two lines at the top of `main.zig` fix two different logging problems.** They are easy to confuse, and `listen()` warns at startup if either is missing, so you don't have to remember which is which.

```zig
pub const std_options = nilo.std_options;
```

This turns the Engine's debug output down to warnings. Without it, a debug build starts with `debug(zio): Spawning worker thread 1` and your own logs get buried. It also installs `nilo.logFn`, which writes every log line as one line with a time, in the format `listen(.{ .log = … })` asks for (text, or JSON for a collector) and with the id of the request a line was written in. To keep settings of your own, start from this one:

```zig
pub const std_options: std.Options = .{
    .log_level = .debug,
    .log_scope_levels = nilo.std_options.log_scope_levels,
    .logFn = nilo.logFn,
};
```

Leave `.logFn` out and `.format = .json` reaches stderr behind std's `info: ` prefix, which no collector parses; `listen()` says so at startup.

```zig
pub const std_options_debug_io = nilo.debug_io;
```

This stops `std.log` from blocking the event loop. Writing to stderr is a syscall, and many requests share one OS thread, so without this every log line stops every request on that thread. The symptom is a server that is just slow, which is why `listen()` warns instead of letting you find it under load.

There is an optional third line, worth having in production:

```zig
pub const panic = nilo.panic;
```

It makes a crash say which request caused it: `panic: integer overflow (while handling GET /boom/50)`. See [Deploying](./deploying.md#panics).

## The allocator

**The allocator passed to `App.init` is only for the App's own data**: the route table, the static files, the service registry. Requests do **not** allocate from it. Each gets its own arena, thrown away when the request ends.

Use `std.heap.smp_allocator` for a server: it is built for allocating from several threads at once. Use `std.testing.allocator` in tests, which also checks for leaks.

## Where to go next

- [Handlers](./handlers.md): the rule that decides what each argument means.
- [Routing](./routing.md): patterns, priority, and groups.
- The eleven examples in [`examples/`](../../examples/), each runnable with `zig build run-<name>`.
