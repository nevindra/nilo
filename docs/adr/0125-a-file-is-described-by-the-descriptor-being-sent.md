# A file is described by the descriptor being sent

A static file over `max_file_bytes` is not read at load. The directory walk
records its name, its size, its modification time and an ETag made of those
last two, and a request opens the file and hands the descriptor to
`sendfile.send` (ADR 0037).

Everything in the head therefore came from the walk, and the bytes came from
the disk. Those are two different moments, and between them the file is free to
move: a rebuilt asset, a `docker cp`, an editor writing over it.

Shrinking was caught. Fewer bytes arrive than the head promised, the write
fails short, and the connection closes rather than letting the client read the
next response as the tail of this body.

**Growing was not.** The first recorded-length bytes went out under the old
ETag: a complete, correct-looking response carrying a prefix of a file that had
moved on. Nothing in it is malformed, so nothing downstream notices. And the
other half is worse, because it lasts: a client that kept the old ETag was
answered 304, so a cache in front went on serving the old bytes for a file that
had changed.

The comment in `static.zig` said why it worked this way, and the reasoning was
sound as far as it went:

> The size is the one the walk recorded rather than a fresh `stat`, because the
> ETag is made of that number.

A fresh `stat` beside a remembered ETag would indeed hand a client a length
from one file and a tag from another. What the comment missed is that this is
an argument against re-statting *one* of the two numbers, not against
re-statting at all.

## What it does now

**A spilled file's head is written from one look at the descriptor whose bytes
are about to go out.** `serveSpilledFile` opens the file, stats the open
descriptor, and builds both the `Content-Length` and the ETag from that one
answer. They cannot disagree, because they came from the same `statx` of the
same descriptor at the same moment.

Three things follow.

**The Bulkhead's `File.size` becomes `File.stat`**, returning a length and a
modification time. The Engine contract is still five calls — this replaces one
rather than adding a sixth — and the kernel was already answering both in the
one `statx` the old call made.

**`static.spilledEtag` writes into a caller's buffer**, and `etagForSpilled`
calls it. The load path and the request path are one function, so the tag a
walk wrote and the tag a request writes for an unchanged file are the same
bytes by construction rather than by two format strings agreeing. Writing into
the caller's frame is also what keeps the allocation budget at zero
(ADR 0018): 43 bytes of stack in `serveSpilledFile`, no arena.

**`.reload` gets a name, and it is not a watcher.** The roadmap wanted a watch
option re-reading a directory that changed, and once the spilled path describes
what it is about to send, "hold nothing in memory" already *is* reload. So
`static.Options.reload` sets the spill threshold to zero and nothing else. No
fiber, no swap of a Set under live readers, no lifetime hazard, and no second
code path to keep in step with the first.

## What it costs

**One extra `stat` on the spilled path, and nothing anywhere else.** A held
file — nearly every file a web tree has — is untouched. A spilled file is over
eight megabytes by default, already pays an `openat` and a multi-megabyte
`sendfile`, and now pays one more submitted operation. Allocations per request
are unchanged at zero, memory per idle connection is unchanged, and the binary
grows by a few hundred bytes.

That number is reasoned rather than measured, and it is stated that way. What
would be worth measuring is a directory of spilled files served under load; the
axis it would move is throughput on a path where the transfer dominates by
three orders of magnitude.

**`Spilled.size` and `Spilled.mtime_ns` stop being what a response promises.**
They are the record of the walk, and what the suite holds the two ETag writers
to. Anything reading them as the current state of the file is reading them
wrong, and the field comments now say so.

**`.reload` does not notice a file that did not exist at startup.** The list of
names comes from the walk, so editing a file works and adding one still needs a
restart. Fixing that means either re-walking and swapping a Set under live
readers, or resolving a request-carried string into a filename — and the second
is the traversal ADR 0037 exists to refuse. Neither is worth it for a
development convenience.

## What was rejected

**Re-stat for the length and keep the recorded ETag.** What the old comment
correctly refuses: a length from now and a tag from then.

**Drop the ETag when the stat disagrees with the walk.** Correct, and it leaves
a changed file with no validator at all — so every subsequent request re-sends
the whole body. The tag is a pure function of the stat; deriving it is cheaper
than giving it up.

**A background fiber re-walking the directory.** This is what "a watch option"
sounds like, and it is where the cost is. A Set is read by requests in flight,
so swapping one means an epoch or a refcount, which is per-request atomics on
the static path — for a development feature. `.reload` gets the same result by
not holding anything.
