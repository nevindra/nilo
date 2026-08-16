# Static files are held in memory, not read from disk

Static file serving is the last of the three built-in middlewares in the v1 scope. It looked like the smallest of the three and turned out to be the only one that needed a decision rather than just work.

## Why "just call std.fs" is not available

Reading a file with the standard library blocks the OS thread it runs on. Under zio that thread is running many fibers, so a single handler waiting on a disk read stops every other connection sharing it. The project measures itself on **p99 as well as throughput** (docs/history.md), specifically so that stalling the tail does not get to look like a win. A blocking read on the request path would wreck exactly the number the metric exists to protect, under exactly the load it exists to measure.

So the real choice was never "disk or memory". It was:

**A.** Add file IO to the Bulkhead contract, so the Engine does it without blocking.
**B.** Read the files before the socket opens, and serve from memory.

## Why B

The Bulkhead is a promise about what any future Engine has to provide. Today that promise is small: listen and accept, a per-fiber slot, a clock, a lock. File IO is a different order of obligation — open, stat, read, seek, errors, cancellation — and it would be owed by every replacement Engine forever, including whatever gets written the week zio stops following Zig's release branch. That is the risk the Bulkhead exists to contain (ADR 0002), and paying it down for static files specifically is a bad trade.

What is being bought with that obligation is also smaller than it looks. Option A pays off for files too large to hold in memory — video, big downloads — and serving those properly needs range requests, conditional ranges, and ideally `sendfile`, all of which are v2 regardless. Option A would buy the ability to stream a 2GB file badly.

Meanwhile B is not a compromise on the common case, it is better at it:

- **Faster.** No syscall, no page cache round trip, no stat. The bytes are already where the response is being assembled from.
- **Path traversal is not possible.** Not "is defended against" — not possible. `GET /../../etc/passwd` is not a path that gets resolved against a directory; it is a name looked up in a fixed list, and it is not in the list. There is no normalisation step to get wrong, which is the step everyone gets wrong.
- **ETags are free.** Each file's hash is computed once at load, so conditional requests are a string compare. Doing this per request against disk would mean hashing on every hit or caching mtimes and getting invalidation wrong.

Zig 0.16 makes the decision easier to live with, too: loading goes through `std.Io.Threaded`, a throwaway blocking I/O instance created and destroyed inside `static.load`. Nothing from it survives into the request path. If a future Engine ever does want to supply file IO, `std.Io` is already the shape the seam would take.

## What was built

`app.static("/", "public")` walks the directory once, before `listen()`, and keeps every file with its content type, a strong ETag, and its `Cache-Control`. Lookup is a binary search over URLs sorted at load.

Choices inside that worth naming:

- **Routes win over files.** An explicit `app.get("/index.html", …)` beats a file of the same name — the surprising direction would be a file silently shadowing code somebody wrote on purpose.
- **Dotfiles are skipped by default.** A `.env` or a `.git/` that found its way into the published directory is not something to discover from an access log.
- **`spa_fallback` is opt-in.** With it, any unmatched path under the prefix serves `index.html`, which is what a browser reload on `/users/42` needs. Without it, an unmatched path is a 404. Turning that on by default would make every typo'd asset URL return an HTML page with a 200, and the failure would show up as a JavaScript parse error somewhere unrelated.
- **Ceilings are checked at load, with the file's name in the error.** Everything is going into RAM; that limit should be hit at startup, not at three in the morning.
- **Static files are terminal handlers, not a middleware.** They need state, and a `Middleware` is a bare function pointer with nowhere to keep any. Making them a handler means the ordinary middleware chain wraps them, so CORS covers an asset served cross-origin and the logger sees it, with no special case anywhere.

## Consequences

- A file that does not fit in memory cannot be served. Said plainly in the README, with the memory the tree occupies logged at startup so the ceiling is visible rather than theoretical.
- Assets cannot be changed without restarting. For a build-output directory that is how deployment works anyway; for local development it is a real annoyance and worth a watch-and-reload option in v2.
- Range requests, `sendfile`, and per-request disk reads are v2, and would arrive as an addition rather than a rewrite: the same `find`, a different way of getting at the bytes.
- The Bulkhead gains nothing. That was the point.

## Amended in 0.1.0

**A file too big to hold is now opened rather than refused** — [ADR 0037](./0037-a-file-too-big-to-hold-is-opened-not-read.md). This decision is not reversed, and the sentence above it turned out to be the accurate prediction: it arrived as an addition rather than a rewrite, the same `find` with a different way of getting at the bytes.

What changed is the price of option A. The obligation this ADR would not put on the Bulkhead — "open, stat, read, seek, errors, cancellation, owed by every replacement Engine forever" — stopped being nilo's to define once `sendFile` was a slot in the `std.Io.Writer` vtable and zio filled it in. The Bulkhead grew four names, all of them `std.Io`-shaped, which is the seam this ADR named in advance.

Two of the three things option B bought are unchanged and were never up for trade. Path traversal is still not possible, because a spilled file carries the path the directory walk produced and the string handed to `openat` still never comes from a request. The memory is still a number, because a spilled file holds no bytes. The third — ETags for free — is the one that gave: above the threshold a tag is the file's modification time and size rather than a hash of its contents, since hashing gigabytes at load is the cost this ADR was avoiding in the first place.

`max_file_bytes` kept its name and changed its meaning, from the ceiling this document wanted hit at startup to the line at which a file stops being held. `error.StaticFileTooLarge` is gone with the ceiling.
