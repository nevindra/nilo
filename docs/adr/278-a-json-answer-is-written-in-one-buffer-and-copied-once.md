# A JSON answer is written in a buffer the thread keeps and copied into the arena once

**Status:** accepted
**Topic:** [json](../design/json.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 148](./148-a-field-name-is-a-spelling-too.md).
**Found by:** profiling the arena's `json-h2c` profile through the rig (`gdb` sampling of the entry, `bench/result/http.md`) after it read 10.1 us of server CPU a request against the framework league leader's 4.5.

## Context

`sendJson` and a typed handler's answer wrote JSON into `Writer.Allocating.initCapacity(arena, json_hint)` and `json.write` put it there a field at a time. The profile's answers are 200 to 8,900 bytes, 3.7 KB on average. Two things were measured.

**The buffer.** An `Allocating` writer doubles when it fills, and the request arena does not grow a node in place: a node that cannot grow is replaced by one 1.5 times the size of the previous node plus the request. A 9 KB answer therefore walked the arena through nodes that passed 32 KiB, where `SmpAllocator` stops serving a size from its slabs and calls `mmap`; the arena of an HTTP/2 stream keeps 4 KiB between requests, so the node was given back with `munmap` at the end of every such request and asked for again at the next. Of the server's samples on that profile, `__mmap` and `__munmap` were 20%, and the page faults of the fresh pages came on top.

**The writer.** A field was a `writeAll` for its key, a `writeByte`, a `writeAll` and a `writeByte` for a string, a `printInt` for a number: about 45 writer calls an item, each with the writer's checks and a `memcpy` whose length it did not know (the runtime's, a call). The mix the board sends cost 47,900 instructions and 1,450 ns in process.

## Decision

**`jsonbuf.render(arena, value)` writes the answer into a 32 KiB buffer the thread keeps (a threadlocal in `.tbss`) and copies it into the arena once, at exactly its length.** `sendJson` and the typed answer path use it. The arena sees one allocation of the answer's size and none of the intermediate ones, so the 1.5 times growth of its node is applied once. An answer that outgrows the buffer is moved into the arena at twice the size and written on there, so a large answer pays what it paid before and the buffer never has to be large. A render that finds the buffer taken (a `jsonStringify` that renders another value) writes into the arena directly. The buffer is held by nothing that waits: a serialiser writes to memory, and `date.zig` is the precedent for a threadlocal that is right because nothing in between suspends.

**A scalar field is one reservation on the writer.** The brace or comma, the quoted key and the colon are one literal known while compiling and are copied with a length the compiler knows (moves, not a call); an integer of up to 64 bits is written as digit pairs straight into the buffer; a string that is printable ASCII with no quote and no backslash (checked 8, 16 or 32 bytes at a time, the last block overlapping the one before it) goes out between its quotes in one short copy; a bool and an enum value are a literal. Anything else, a string with an escape or a non-ASCII byte, an integer wider than 64 bits, a writer whose buffer cannot hold the reservation, takes the code that was there before, so the bytes are the ones `std.json` writes (ADR 148's contract) and a failing writer fails the same way.

**Cost, on the four axes.** Allocations per request: one for the answer, where there was one and then one for each doubling past 512 bytes (the budget test holds). Memory per idle connection: none, the buffer is per thread and a thread has 32 KiB of address space for it and the pages an answer touched; `park-check` is unchanged. Throughput: the mix of the board's answers is 586 ns and 21,000 instructions a request in process (1,450 ns and 47,900 before), and 10.4 to 7.7 to 8.5 us of server CPU a request on the rig (`bench/result/http.md`). Binary size: no code the linker keeps for a program that never sends JSON.

## What was rejected

**A size hint per route, so `initCapacity` is right the second time.** It needs state per route, and a route whose answers range from 200 to 8,900 bytes is wrong for most of its requests. The buffer that is always large enough has no state.

**Arena segments with a vectored write.** Measured and refused in `bench/result/http.md` ("A JSON answer in arena segments does not beat `Allocating`"): they cost the contiguous body compression, a held answer and HEAD need, and did not win below the arena's keep.

**A bigger `json_hint`.** Tried at 16 KiB: 12.9 us against 10.2 on the rig. Every request then asked the arena for a node bigger than the 4 KiB an HTTP/2 stream keeps.

**Escaping and validating in one pass for every string.** Non-ASCII text still costs `utf8ValidateSlice` and then `nextEscape`. The board's text is ASCII, nobody has needed it, and `docs/design/json.md` already records the validator as the open question.
