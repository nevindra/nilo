# A static directory can follow the disk, and a response finishes on the tree it began on

**Status:** accepted
**Topic:** [static-files](../design/static-files.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 013](./013-handlers-must-not-block-the-thread.md) (nothing on the request path waits for the disk), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) (nothing is per connection)
**Extends:** [ADR 009](./009-static-files-are-held-in-memory-or-opened.md) (a directory is read once; now it may be read again), [ADR 273](./273-a-file-a-build-compressed-is-served-as-the-coding-of-the-file-beside-it.md) (a `.gz` is held to its trailer and not to its age)

## Context

A held static file is a copy taken at `listen()`. Replace the file and the server goes on serving the old bytes until it is restarted, which is what ADR 009 decided and what a container image wants. HttpArena's rule for a framework's static profiles is the other thing: the cache must be the framework's own, "replace a file and the next response must carry the new bytes", and its validator replaces a file and its `.br` and `.gz` twins with same-length random bytes, from the host, under a read-only bind mount, and fails the entry if the old ones are still served two seconds later.

The only mode that passes that today is `.reload`, which holds nothing: an `open`, a `stat` and a read per request, and no compressed form. On the board's static-h2 profile (20 files, 256 connections, `-m 32`, `Accept-Encoding: br;q=1, gzip;q=0.8`, TLS) the entry spent 44.3 µs of server CPU a request against the framework league's leader at 9.3 ([the run](../../bench/result/http.md#a-static-directory-that-follows-the-disk)). The same files held and stale are 22.8 µs, so the held copy is worth half the request, and what is missing is only the means for it to learn that the disk changed.

## Decision

**`staticWith(.{ .follow = true })` keeps the directory in memory and in step with the disk. It is off by default.** A change to a file, to the `.br` or `.gz` beside it, a file added, a file removed or a directory made under the tree is served by the next response after it is noticed: within tens of milliseconds where the operating system says so, and within `follow_poll_ms` (default 1,000) where it does not.

### One thread, and a directory replaced as a whole

A follower owns one OS thread per followed directory, started with the server and stopped with it. It is not an executor thread and holds nothing a connection needs, so it adds nothing to a request and nothing to an idle connection. It never calls the Engine: it reads with a blocking `std.Io.Threaded` of its own, exactly as `load` did before the socket was open, and the Bulkhead's contract is unchanged (ADR 001, ADR 009's rejected "file IO in the Bulkhead").

- **Noticing.** On Linux an `inotify` descriptor watches the directory and every directory under it for a file closed after a write, renamed in or out, made, removed or touched, and for a directory made, moved or gone (which makes the thread arm its watches again, and a queue overflow does the same). Everywhere else, and as the backstop on Linux for a filesystem that raises no events (NFS, FUSE), the thread walks the tree every `follow_poll_ms` and `stat`s each file. `kqueue` is not used: it watches a descriptor, so following a directory means holding one for every file in it, which costs more than the walk it would save at the sizes a static tree has.
- **Deciding.** Both paths end in the same question: is the tree what the live generation was read from? The answer is one number, `Set.fingerprint`, the sum of a hash of every listed file's path, size, modification time and inode, so a walk and a `stat` per file is enough and no file is read to find out. A rename gives a new inode, a write in place a new modification time, an addition or a removal a term more or fewer.
- **Waiting for it to hold still.** When the number differs the thread looks again after 60 ms and until two looks agree (at most a second), so a copy or a build in progress is read once it is written and not at every size on the way. A file still being written after a second is read as it is and again when it settles.
- **Reading.** The same `static.load` the server started with, so every rule of ADR 009, 087 and 273 holds for the new generation without being written twice: the sort, the ETags, the siblings and their checks, `max_total_bytes`, the single-page fallback, the spill threshold, the dotfile and symlink rules. A tree that cannot be read (a directory gone, a file over the total) logs one `warn` and **the generation already held goes on being served**; the tree it failed on is not read again until it changes.
- **Swapping.** The new generation is published with one atomic store. Requests read the live generation through that pointer; nothing is edited in place, so a request sees one tree: a file, its tags, its forms, its middleware chain and the list of URLs all from the same read, never a `.br` of one write beside a file of another.

### What a change does, file by file

A change reads the whole tree again, because what a file is depends on its neighbours (ADR 273's pairing). A reload costs what a start costs, on the thread that is not serving: reading every held file, hashing it and compressing the ones without a `.gz`. On the 20-file, 1.7 MB board directory that is milliseconds; a tree of tens of megabytes wants `follow_poll_ms` raised and is the case for keeping the unchanged files between generations, which this does not do (see below).

- **A `.gz` is held to its trailer and not to its age.** ADR 273 ignored a form older than its file; for a `.gz` that rule only refuses a correct one, since the CRC-32 and the length in its last eight bytes already say whether it is a gzip of these bytes. A `.gz` written before its file, which a copy in either order or `cp -p` produces, is used when it is the file's and ignored when it is not, and never serves stale bytes either way. A `.br` has no trailer, so it keeps the rule: **a `.br` older than its file is ignored**, and a deploy that writes the file before its forms (every build tool, `rsync` and `cp -r` in name order) loses nothing. A `.br` written before its file is ignored until it is written again, which is the stale-form failure turned the safe way.
- **The board's order is covered both ways.** The validator replaces the file, then the `.br`, then the `.gz` with random bytes: the new file, the new `.br` (accepted, its modification time is the later one) and a `.gz` that is not a gzip of the file (ignored, one warning), so a client that prefers `br` gets the new bytes and one that prefers `gzip` gets the file. The restore puts all three back with their old modification times, and the three are the originals again.
- **Added and removed files** are in or out of the next generation's list; a removed file is a 404 and a new directory is watched from the next arming.
- **`reload` and `follow` together** is a followed tree whose files are all spilled: the bytes are always the disk's, and the list of names follows it too.

### A response finishes on the generation it began on

A request on another thread may be writing a body while the thread that follows the disk replaces the tree, and an HTTP/2 stream writes its body after the handler has returned, for as long as the client's window takes. So each generation counts the responses reading from it (`Lease`), and **a generation is freed when its count is zero and not before**, by the follower thread on its own schedule, never by a request.

- **The count is taken with a check** (`Follower.enter`): read which generation is live, add one to its count, read which is live again, and start over if it changed. The follower publishes the new generation first and only then reads the old one's count, so a request is either counted before it can see anything of the old generation (which then waits for it) or sees the new one (and reads nothing of the old). That needs sequentially consistent operations, and a generation's header (the count) to outlive the generation: headers are kept and reused, and a count is never reset, only added to and taken from. `follow.zig`'s header says it in full.
- **Where it is released.** HTTP/1.1 writes before the handler returns, so `serve.handleRequest` takes the count when the file is found and gives it back on every way out of the request. HTTP/2 writes a body of 16 KiB or more from where it lies (`Collected.wholeKept`), so `Ctx.putWhole` hands the stream a count of its own when the body was left in place (`Framing.pin`), and the stream gives it back when it is let go of, in `Stream.recycle` and `Stream.destroy`. A body that was copied into the arena needs none.
- **What this costs a request:** two atomic read-modify-writes on a word in the generation, and nothing allocated. A directory that does not follow takes the path it always took (a null check of `Set.follower`).

### Whether it should be the default

**No: an option, and the answer is argued here because it is the one most likely to be asked again.** For: the board and every cache in front of a file server (nginx `open_file_cache` revalidates, Caddy `stat`s each request) treat following the disk as what a cache is. Against, and it decides: (1) ADR 009's contract, "a directory is read once at `listen()`", is what lets a deployment reason that the set of URLs it serves is the set it shipped, and a process that ships its files in an image gets nothing from a thread, a descriptor and a tree that can change under it; (2) a tree that changes in place is half a deploy at the moment it is read (a new `index.html` before the hashed bundle it names), and a restart is the atomic version of that, so following is a thing to choose knowing it; (3) `inotify` instances are a per-user resource (`fs.inotify.max_user_instances`, 128 on many systems), and a test suite that builds an App per test would meet that limit in a place nobody looked; (4) the binary grows (below) for every program that serves a directory. **A program whose files are replaced while it runs says `.follow = true` once**, and the cost is paid by that program alone.

## What was rejected

**A `stat` per request** (what `.reload` does, and what nginx does at its `open_file_cache_valid` interval): a syscall on the request path for a change that happens a few times a day, and 22.8 against 44.3 µs a request on the board's profile is the price of the open, the stat and the read. A `stat` every second per file, on a thread of its own, is the polling backstop here and costs a request nothing.

**Reloading on a miss.** A request for a name that is not in the list would walk the disk, so a string from the request decides when the disk is read (`decided.md`, and ADR 009's traversal argument).

**Editing the live tree in place**, one file's bytes at a time. It is the smaller change and a reader can then see a `.br` from one write beside a file from another, a URL list that is half old and an ETag that names bytes the body no longer is, and none of those has an error anywhere. A whole generation is one pointer.

**An epoch or a quiescent state per executor** to know when the old tree is free. A fiber that is parked in a write holds bytes across any point an executor could call quiet, and an HTTP/2 stream holds them after the handler returned, so the only fact that says a generation is unreferenced is the count of what references it.

**A watcher on the event loop** (a fiber waiting on the `inotify` descriptor). It would add an Engine contract (a wait on a descriptor nilo does not own) for an operation a thread does without one, and a reload's reading and gzipping would then need a thread of its own anyway, because `load` blocks.

**Keeping the unchanged files between generations**, so a reload reads only what changed. It is the right cost model for a large tree and needs a count on each file's bytes shared between generations. It is not needed to pass the board (a change costs milliseconds on 1.7 MB) and nothing here makes it harder; it is on `docs/todo.md` for the first tree where a reload is felt.

**Following a directory that is replaced whole** (`mv new static`, or a symlink swapped). The watches are on the directory that was opened; the walk each `follow_poll_ms` is by path and finds the new one, and `inotify` is armed again for it at the next change. A deploy that swaps the directory is served within `follow_poll_ms`, not immediately.

**On by default.** Argued above.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none. `serving a file of a directory that follows the disk allocates nothing, middleware included` in `behaviour.zig` holds it; the lease is a word in the generation |
| Memory per idle connection | none: nothing is per connection. `python3 bench/mem.py --h2` on the arena entry, 1,000 to 5,000 idle h2c connections: 8,687 bytes marginal with and without the option. `park-check` is unchanged (one page). An HTTP/2 `Stream` is 8 bytes larger (the lease), and only streams in flight are `Stream`s |
| Memory held | one generation more than the tree for as long as a response is still reading the old one, which is the size of what changed to the size of the tree; the thread's stack is 16 MiB of address space and a few hundred KiB resident once it has compressed something |
| Throughput and p99 | static-h2, 256 connections: 22.8 to 23.4 µs a request followed against 22.7 to 23.2 µs held and never replaced, so the lease is inside the noise; against `.reload` 44.3 to 52.6. At 1,024 connections 28.3 to 28.9 against 51.7 to 53.9. [The run](../../bench/result/http.md#a-static-directory-that-follows-the-disk) |
| Binary size | +25.4 KB stripped `ReleaseFast` on the arena entry (2,572,688 to 2,598,720 bytes), for every program that serves a directory, because the option is a run-time value and the linker cannot tell it is never set |
| A thread | one per followed directory, while the server runs |
