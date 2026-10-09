# Static files

**A directory is read once, at `listen()`, and every later request is answered from that read, never from the filesystem again, except for files too large to keep in memory.**

**Guide:** [Static files](../guide/static-files.md) · **Reference:** [Static options](../reference/app.md#static-options), [`compress` options](../reference/app.md#compress-options), [`FileBody`](../reference/handlers.md#handler-returns)

The code is `http/static.zig` (the walk, the Set, the fallback), `http/serve.zig` (`serveSpilledFile`), `http/range.zig`, `http/accept.zig`, `http/compress.zig` and `http/filebody.zig`.

## Overview

```
listen()                                            request
────────                                            ───────
app.static(prefix, dir) ──► walk once ──► Set        GET prefix/name ──► Set.find
  held file:   bytes, ETag, gzip copy                     │
  spilled file (over max_file_bytes): name, size, mtime   ├─ held  ──► slice, maybe gzip (211), maybe a Range (020)
app.embedded(prefix, files) ──► same Set,                 ├─ spilled ──► open, stat the descriptor, sendfile (098)
  bytes borrowed from the binary, owns_bytes = false       └─ miss  ──► fallbackFor(path, Asked) (087)
                                                                  a navigation → spa_fallback
                                                                  otherwise → 404 naming the path
```

## Rules

1. **A directory is read once, at `listen()`, into memory the App owns**, and a lookup is a binary search over URLs sorted at load time. A file larger than `max_file_bytes` is kept only as its name, size and modification time, and is opened again on every request for it. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
2. **Path traversal is impossible, not just defended against.** The set of URLs a directory serves is fixed before the socket opens, so the name a request carries can only be looked up in a list; it cannot add an entry. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
3. **A route wins over a file with the same name, dotfiles are skipped by default, and a static set is a final handler**, not middleware, wrapped by the normal middleware chain like any other handler. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
4. **`app.embedded` serves the same kind of `Set`, without reading from disk.** The bytes are borrowed from the binary through `@embedFile` (`Set.owns_bytes` is false), and `max_file_bytes`, `max_total_bytes`, `dotfiles` and `.reload` do not apply, because there is no disk behind any of them. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
5. **A `Range` header that cannot be understood is ignored, and the whole file is sent**, because RFC 9110 makes that a correct answer in every case. The exceptions are a range past the end of the file and the suffix `bytes=-0` (which asks for nothing): both answer `416` with `Content-Range: bytes */<total>`. [ADR 020](../adr/020-a-range-is-a-slice-and-two-headers.md)
6. **`If-Range` is compared against the same ETag `If-None-Match` uses**, and anything else (a stale tag, a date, a nonsense value) sends the whole file. Ignoring a range only costs a bigger download; honouring one wrongly produces a corrupt file. [ADR 020](../adr/020-a-range-is-a-slice-and-two-headers.md)
7. **The fallback answers page navigations, never a missing asset or an API typo.** A request is a navigation when it is a `GET` or `HEAD` that sent `Sec-Fetch-Mode: navigate`, or, when it sent no such header, an `Accept` that lists `text/html` by name; `*/*` alone is not one and the path is never read. Anything else under the prefix is a 404 naming the path, so no catch-all route is needed to keep an unknown `/api/` path from being the page, and a path a route spells keeps its 405. `spa_fallback_for` defaults to `.navigations`; `.any_path` exists only to keep the behaviour from before `0.2.0`. There is no list of prefixes that never fall back. [ADR 087](../adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md)
8. **Every static set is checked for a real file before any set's fallback is used**, so a single-page app mounted at `/` cannot answer another set's asset with its own `index.html`. [ADR 087](../adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md)
9. **A large (spilled) file's headers come from one `stat` of the descriptor about to be sent, not from what the startup walk remembered.** So its `Content-Length` and ETag come from the same moment and can never disagree with each other or with the bytes that follow. [ADR 098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md)
10. **`.reload` just sets the spill threshold to zero.** Every file is opened, `stat`ed and read on each request, so an edit shows up without a restart, and no Set is ever swapped under a reader. A file created after startup still needs a restart. [ADR 098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md)
11. **A `try` call returns the error without logging.** `app.static`/`app.staticWith` log a missing directory in one line, because the process is about to stop. `app.tryStatic`/`app.tryStaticWith` return `error.StaticDirNotFound` with no log line, because the caller has said it will decide what to do. A problem inside a directory that does exist is still logged by both, since the error name alone cannot say which file. [ADR 207](../adr/207-a-try-call-hands-back-the-error-and-says-nothing.md)
12. **`app.compress` gzips a suitable response per request, using a compressor borrowed from a pool with one per executor thread**, and returns it before writing to the socket. Nothing between borrowing and returning can park the fiber, so the pool is never empty on a running server. [ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)
13. **The compressor is reset in place, not re-initialised.** `compress.reset` sets the same fields as the standard library's `init`, using 40 bytes of stack instead of `init`'s 99,048, because a fiber keeps whatever stack it touched for the life of the connection. [ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)
14. **What the handler said about the representation stands, and a body is capped.** A 206, a 416, a `Content-Range` and `Cache-Control: no-transform` are never compressed; a strong `ETag` is weakened on an answer that is; a body over `max_bytes` (1 MiB, about 7 ms of the thread) goes out as it is, because deflate runs whole with no point where the fiber parks. [ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)
15. **Streams and event streams are never compressed, and gzip is the only encoding offered.** Neither has a whole body that could be gzipped into the arena without holding the compressor across a write, which the borrowing rule forbids. [ADR 211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)
16. **A build can gzip with libdeflate instead.** `.libdeflate = true` moves the pool and the gzip at load onto libdeflate, in a quarter to a third of the time and a page less stack; its compressors sit in one mapping kept off huge pages, and `.best` is its level 7, so `max_bytes` still bounds what it was sized to. The API and which bodies go out gzipped are the same in both builds. [ADR 248](../adr/248-gzip-is-libdeflate-when-a-build-asks-for-it.md)
17. **One set can carry two `Cache-Control` policies.** `cache_rules` matches a file's path in the tree by prefix and suffix, first match wins, and the result is written into the header each file already carries while the Set is built, so a request does no matching and allocates nothing. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
18. **A directory is listed into an embed set by `embedDir` in nilo's `build.zig`**, walked when the build is configured: regular files, no `.` segment, no symlink, no size cap, and an empty directory stops the build. It is a build function and not a module, so `layering` has nothing to say about it. [ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)
19. **A `X.br` or `X.gz` beside a compressible `X` is a form of `X`, held once, and not a file.** The client's highest `q` picks it, `br` on a tie; the plain answer, the 304 and the 416 of a file with more than one form carry `Vary: Accept-Encoding`; each form has its own ETag; a `Range` gets the plain bytes; a `.gz` is checked by its CRC-32 against the file and a sibling older than the file or not smaller is ignored with a warning; and a spilled file takes its siblings from the disk. `precompressed = false` serves them as ordinary files. [ADR 273](../adr/273-a-file-a-build-compressed-is-served-as-the-coding-of-the-file-beside-it.md)

## Decisions

| ADR | What it decides |
|---|---|
| [009](../adr/009-static-files-are-held-in-memory-or-opened.md) | A directory is held in memory, or opened per request above a size threshold; `app.embedded` is the same Set without the disk read, listed from a directory by `embedDir`; `cache_rules` give files their own header |
| [020](../adr/020-a-range-is-a-slice-and-two-headers.md) | What `Range` and `If-Range` mean for a file in memory or on disk |
| [087](../adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md) | When `spa_fallback` answers (a request that says it is a navigation), and when a miss is a 404 instead |
| [098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md) | A spilled file's `Content-Length` and ETag come from one `stat` of the descriptor being sent |
| [207](../adr/207-a-try-call-hands-back-the-error-and-says-nothing.md) | The `try` version of a static call returns the error without logging |
| [211](../adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md) | Gzip on a per-thread compressor pool, and why streams are left out |
| [248](../adr/248-gzip-is-libdeflate-when-a-build-asks-for-it.md) | The same gzip on libdeflate, in a build that asks; one mapping kept off huge pages; `.best` is level 7 |
| [273](../adr/273-a-file-a-build-compressed-is-served-as-the-coding-of-the-file-beside-it.md) | A `.br` or `.gz` beside a file is its coding, chosen by q, with its own ETag and `Vary` on every answer; checked against the file, on by default |

Related topics: keeping file IO out of the Bulkhead's own contract, and using `std.Io.Writer`'s `sendFile` instead, is [ADR 001](../adr/001-zio-as-the-engine-behind-the-bulkhead.md) (engine); a fiber keeping whatever stack it touched, which is why the compressor is reset instead of rebuilt, is [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md) (memory); rejecting a request body in an encoding nilo does not support is [ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md) (http1-protocol); `FileBody` following the status-in-the-type pattern like a redirect does is [ADR 031](../adr/031-a-redirect-puts-its-status-in-the-type.md) (responses); the four-axis budget every cost above is measured against is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles).

## Open questions

- **Streams and event streams stay uncompressed, and brotli is not offered by nilo's own encoder** (a `.br` the build wrote is served, ADR 273). In [the todo list](../todo.md), waiting for someone streaming something large enough for bandwidth to matter, or a reason for brotli strong enough to justify the C dependency it brings.
- **`.reload` does not notice a file created after the server started**, only edits to files the startup walk found. Recorded in [`docs/decided.md`](../decided.md) as a deliberate gap: rescanning on a miss would let a name in a request decide when the disk is scanned, which is exactly the kind of traversal `static` exists to prevent.
