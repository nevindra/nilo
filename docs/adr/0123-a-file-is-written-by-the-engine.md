# A file is written by the Engine

An `Upload` handed a handler three things — the bytes, the type the client
claimed, and the name the client's machine had for the file — and no way to put
any of it on a disk. Every upload handler in every application therefore ended
in the same four lines of `std.fs`, and both halves of those four lines are
easy to get wrong.

**`Upload.saveTo(dir, name)` writes it, through one new Bulkhead operation.**

```zig
fn newAvatar(uploads: *nilo.Dir, incoming: nilo.Form(Avatar)) !nilo.Status(201, void) {
    var buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "{d}.png", .{account});
    try incoming.value.file.saveTo(uploads.*, name);
    return .{};
}
```

## The two things the four lines get wrong

**`std.fs` blocks the thread, not the fiber.** A 2 MB write through
`std.fs.File` is a syscall on the executor thread, and every other connection
that thread is serving waits for the disk with it. That is what `nilo.blocking`
exists for and it is not needed here, which is the finding below.

**`filename` is the client's and `name` is yours.** A browser sends whatever
the machine it came from called the file; a stranger sends `../../etc/cron.d/x`,
a NUL the kernel truncates the name at, or a drive letter. `saveTo` refuses
those with `error.NameNotAllowed`, by the same `filebody.checkName` that guards
`sendFile` on the way out, so the mistake of passing `u.filename` straight in
fails rather than resolving.

## The blocker that had already gone

The roadmap said this needed a design, on the premise that `bulkhead.Dir` can
only open and that adding a write meant deciding what a two-megabyte write does
to the fiber that issues it.

The pinned zio answers all of it: `Dir.createFile`, `File.stdWriter`,
`Dir.createFileAtomic`, and an `fs.zig` that routes a descriptor the loop cannot
poll to its own thread pool — so a file write parks the fiber and the executor
goes on serving the other connections it holds. Nothing had to be designed and
nothing had to hop to `nilo.blocking`.

That is the fourth time here that a conclusion of "blocked on somebody else"
was still being planned against after it had stopped being true
([ADR 0063](./0063-a-handlers-stack-is-per-connection.md) is the one that made
it a rule). Nothing downstream re-tests a blocker, so the blocker has to be
re-read.

## Why the write is atomic

The bytes go to a randomly named file beside the destination and one rename
puts them in place. The alternative — open the name, truncate it, write — is
one syscall cheaper and leaves the file **visibly truncated for the length of
the write**, which matters here more than it does in most programs: the
directory an application uploads into is usually the directory it serves out of.
A second request reading that name through `sendFile`, while the first is still
writing, would get a 0-byte avatar and a `Content-Length` promising more. A
write that fails halfway leaves the same wreckage permanently.

`zio.AtomicFile.deinit` removes the temporary file on every path out, including
cancellation, so a failed write leaves the old file exactly as it was.

## Why one Bulkhead operation rather than three

The first version wrapped `Dir.createFile` and `File.writer` and let `saveTo`
drive them, mirroring `openFile`/`reader` on the read side. It was replaced by
a single `Dir.writeFileAtomic(name, bytes)`.

`http/bulkhead.zig`'s header is the entire contract nilo asks of an Engine, and
that is a file where a line costs more than it looks like it costs — a `File`
open for writing is a second lifetime every engine has to get right, for the
sake of a caller that already holds every byte it means to write. There is no
such caller. The read side has one, because `sendFile` streams a file it has
not read.

## What it costs

**Allocations per request: none.** `u.bytes` is the body's own memory and
`writeAll` takes it as it is. The writer is given a `[0]u8` buffer, which is
also why nothing lands on the connection's stack: a buffer here would be
per-connection memory for the life of the connection
([ADR 0063](./0063-a-handlers-stack-is-per-connection.md)), and it would buy
fewer, larger writes on a path that makes exactly one write.

**Throughput and p99: nothing.** No route that does not call `saveTo` reaches
any of this.

**Binary size: nothing unconditional.** `saveTo` and `Dir.writeFileAtomic` are
reachable only from a handler that calls them. Built stripped at `ReleaseFast`,
the benchmark server — which calls neither — is **911,792 bytes with this and
911,792 without it**, the two builds taken back to back with only these three
files stashed between them.

**What it does not do** is set the mode, the owner or the times, decide the
name, or fsync. The first three are the caller's; the fourth is a durability
question with a cost — an fsync of the file plus one of the directory — that
belongs to a caller who has said they want it, not to every avatar.
