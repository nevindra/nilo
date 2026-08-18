# Settings

`nilo_config` reads a struct of your own out of the environment, before
anything opens. It is a module of its own: no event loop, no allocator, and it
opens no file
([ADR 0043](../adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).

<!-- compiles -->
```zig
const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,                                   // a default is "not set"
    database_url: []const u8,                           // no default: required
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,                                // may be absent
};
```

The field name upper-cased is the variable: `database_url` is read from
`DATABASE_URL`. A field is text, a number, a `bool`, an enum, or any of those
wrapped in `?` — anything else is a compile error naming the field.

**Every bad setting is named at once**, which is the whole point of reading them
into a struct rather than one at a time:

```
3 settings could not be read from the environment:
  PORT has to be a whole number, not "soon"
  DATABASE_URL is not set
  LOG_LEVEL has to be one of debug, info, warn, not "verbose"
```

## The whole of a real `main`

Two things here need an `std.Io`, and the loop that will supply one does not
exist yet — `listen()` is further down the same function. **The `Io` you need is
already an argument to `main`.** That is `std.process.Init`, it is Zig's rather
than nilo's, and it is what makes both of these three lines instead of thirty:

<!-- compiles -->
```zig
const std = @import("std");
const nilo = @import("nilo_http");
const config = @import("nilo_config");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;

    // A `.env` is text somebody else read (ADR 0064), so the program opens
    // the file. Missing is not an error — that is production.
    const text = std.Io.Dir.cwd().readFileAlloc(io, ".env", gpa, .limited(64 * 1024)) catch "";
    defer if (text.len > 0) gpa.free(text);
    const file = config.Dotenv{ .text = text };

    // A set variable wins; the file is the floor.
    const read = config.from(Settings, config.layered(.{
        config.Env{ .environ = init.minimal.environ },
        file,
    }));

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stderr().writer(io, &buf);
    const w = &out.interface;

    try file.report(w);                  // writes nothing when the file is clean
    const settings = read.value() orelse {
        try read.report(w);
        try w.flush();
        std.process.exit(2);
    };
    try w.flush();

    var app = nilo.App.init(gpa);
    defer app.deinit();
    try app.provide(&settings);          // an ordinary struct is an ordinary service

    try app.listen(.{ .port = settings.port });
}
```

Four things in there are worth saying out loud, because each was rediscovered
the hard way by an application written against this page before it existed:

- **`main` takes `std.process.Init`.** That is where `io` comes from, and where
  `environ` comes from. Standing up a `std.Io.Threaded` of your own for the
  length of one 98-byte read works and is nine lines you do not need.
- **The text has to outlive the settings.** A `[]const u8` field points into it,
  exactly as it points into the environment block. Free it after the server
  stops, or never.
- **`report` takes a `*std.Io.Writer`**, and stderr's is
  `std.Io.File.stderr().writer(io, &buf)` — the `.interface` field is the
  writer, and it has to be flushed. A fixed buffer works too
  (`std.Io.Writer.fixed(&buf)` and `std.debug.print`) but it puts a ceiling on a
  report whose length is however many settings are wrong.
- **`file.report` is a separate call from `read.report`.** They answer different
  questions: one is lines in the file that are not settings at all, the other is
  settings that would not convert. A clean file writes nothing.

## What a `.env` may hold

`Dotenv` takes text rather than a path, which is what keeps the module free of
IO ([ADR 0064](../adr/0064-a-dotenv-is-text-somebody-else-read.md)).

It reads `NAME=value`, blank lines, `#` comments on their own line, `'` and `"`
quoting, an optional `export ` prefix, and CRLF. It **refuses** escapes,
multi-line values, `${OTHER}` interpolation, and a comment after a value — so
`PASSWORD=abc#123` arrives intact, and `PORT=8080 # the port` says

```
PORT has to be a whole number, not "8080 # the port"
```

rather than guessing which half you meant. **A report never quotes a value**,
because a `.env` is where a password lives.

## Where the settings then live

A Config is an ordinary struct, so it is an ordinary service:

```zig
try app.provide(&settings);

fn health(cfg: *const Settings) []const u8 {
    return if (cfg.log_level == .debug) "loud" else "ok";
}
```

`*const Settings` in a handler's arguments is the whole wiring. See
[Services](./services.md) for what else that slot takes, and
[the reference](../reference.md#nilo_config) for the rest of the API.
