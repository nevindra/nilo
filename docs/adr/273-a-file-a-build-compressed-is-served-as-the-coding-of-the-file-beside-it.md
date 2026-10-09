# A file a build compressed is served as the coding of the file beside it

**Status:** accepted
**Topic:** [static-files](../design/static-files.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 211](./211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md) (nothing compresses per request)
**Extends:** [ADR 009](./009-static-files-are-held-in-memory-or-opened.md) (a held file keeps its bytes and its tags; a spilled file is described by its descriptor), [ADR 020](./020-a-range-is-a-slice-and-two-headers.md) (a range is an offset into the plain bytes)

## Context

A front end's build writes `app.js.br` and `app.js.gz` beside `app.js`, and `app.static` served neither as a coding of `app.js`: it listed both as files nobody links to and gzipped `app.js` again at startup, with an encoder 17% weaker than the one that wrote the sibling. Brotli was refused for responses because of what its encoder costs (decided.md: it cannot be pooled, allocates 1.4 MB a body and adds 913 KB). A file compressed at build time costs no encoder at all: its price is its bytes in memory. Caddy (`precompressed`), nginx (`gzip_static`), tower-http (`precompressed_br`) and actix-files (`try_compressed`) serve them; the details they had to fix later are the specification here: `Vary` on the plain answer too (tower-http, and actix-files only on the compressed one), a tag for each encoding (Caddy once shared one), and lengths counted on the bytes that go out.

## Decision

**A `X.br` or `X.gz` in a tree, where `X` is also in the tree and is a type `compressible` accepts, is a form of `X`, not a file.** It is read at load beside `X` (or, for a spilled `X`, left on the disk beside it), served to a client that prefers it, and **its own URL is a 404**. `Options.precompressed` is on by default and `EmbedOptions` has it too.

- **Choice.** `compress.negotiate` takes the highest `q` among the codings the file has: `br` beats `gzip` on a tie (a browser's `gzip, deflate, br` weighs both at 1 and brotli is the smaller), `br;q=0` and an unnamed coding without a covering `*` are never chosen, a named entry outranks `*`, and a client sending nothing gets the plain file. `acceptsGzip` is `quality("gzip") > 0`.
- **A `.gz` sibling replaces the gzip copy nilo would make**, so the gzip is not made twice. A `.br` alone leaves that copy in place, for a client that takes gzip and not brotli (Chrome sends no `br` over plain HTTP). `compress = false` turns off the copy and not the siblings.
- **`Vary: Accept-Encoding` is on every answer for a file that has more than one form**: the plain one, the 304, the 416, a range, a HEAD. A file with one form (a PNG, a tiny file) carries none, as before, because it varies on nothing. Setting it on a directory's every file would fragment a cache's PNGs by a header they do not depend on.
- **Every form has its own ETag.** A held form's is the hash of its bytes, like the gzip copy's. A spilled form's is its own modification time and size with the coding after them (`"1a2b-ff-br"`), so the plain file's and the sibling's cannot be equal even if they share a nanosecond and a length. A 304 compares against the form that would have gone out.
- **`Content-Length` is the compressed length, and `Range` is still an offset into the plain bytes** (ADR 020, unchanged). A request with `Range` gets the plain file whatever it accepts, as it does for nilo's own copy: a byte range of `Content-Encoding: br` is something curl and a media element do not resume or seek in, and the plain `206` is always a correct answer. The issue's wording ("Range counted on the compressed bytes") is not taken.
- **A spilled file takes its siblings from the disk by the same rule.** Opened with `O_NOFOLLOW` at a path the walk wrote down, described from its own descriptor (ADR 098), and if it has gone since the walk the plain file answers instead of a 404.
- **A sibling is held to the file it sits beside, because a stale one is the failure the others leave to the operator.** A `.gz` carries the CRC-32 and the length of what it compressed, and is used only if both match the plain file's bytes. Brotli has no trailer, so a `.br` is held to the modification time alone. A `.gz` is judged by its trailer and not by its age (a `.gz` written before its file is used when it is the file's; [ADR 277](./277-a-static-directory-can-follow-the-disk-and-a-response-finishes-on-the-tree-it-began-on.md) needs this, since a deploy in either order must not strand it). A sibling that is a `.br` older than the file, not smaller than the file, or a `.gz` that is not a gzip of it is **ignored, still not served under its own name**, and said in one `warn` line naming the first three and a count. In an embedded tree there is no modification time and a `.br` is unchecked.
- **The first sibling's bytes count against `max_total_bytes`** like the gzip copy, and the load line reports them as their own clause.

### Whether it is on by default

On. Caddy, nginx, tower-http and actix-files are opt-in because they trust the sibling, and a stale `.br` served to every browser for a script that has since changed is a failure with no error anywhere. Here the `.gz` is verified exactly and the `.br` by mtime, so the cost of being on is a warning line for a build that left old siblings, and the benefit is that the front end already shipping them is served right with no line of configuration. The change for a tree that was served some other way is the 404 on the sibling's own name, which `.precompressed = false` undoes.

## What was rejected

**Off by default, as the four others have it.** It would be a flag the front-end developer has to know to look for, and the thing it protects against is checked here.

**Serving the sibling under its own name too, as nginx does.** `app.js.gz` would be a second listed file with a second copy of the same bytes (or a shared pointer with an ownership flag in every free path), and a content type of `application/octet-stream` for a coding of JavaScript. One copy and a 404 is the shape that holds the bytes once; a tree that publishes `notes.txt.gz` to be downloaded sets the option false. A type that is not worth compressing (`photo.png` and `photo.png.gz`) is not paired and both are served.

**`Vary` on every answer of a directory.** Costs a cache its PNGs for nothing.

**A range counted on the compressed bytes.** Rejected above, and it would need a second ETag rule for `If-Range` that ADR 073 does not have.

**A decoder to verify a `.br`.** std has none, and a vendored one is a dependency for a check the mtime makes most of the time.

**Making a brotli copy at startup for a tree that has none.** The encoder is the cost decided.md refuses; this feature is only for a file somebody else compressed.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | none. The negotiation is a scan of a borrowed header, `Vary` and `Content-Encoding` are static strings, and a spilled file's tag is written on the stack; `serving a file the build compressed allocates nothing` in `behaviour.zig` holds it with middleware in front |
| Memory per idle connection | none; nothing is per connection, and `serveSpilledFile` gains one optional descriptor in a frame that was already a request's |
| Memory held | the bytes of each sibling. A six-file front end of 1,421,488 plain bytes holds 1,760,919 today (nilo's gzip copy 339,431), 2,034,416 with both siblings (+273,497, +15.5%), and 1,700,900 with only `.br` and `compress = false` (-60,019): [`bench/result/http.md`](../../bench/result/http.md#a-file-a-build-compressed-is-held-beside-the-file) |
| Throughput and p99 | none measured on the request path; startup does no gzip for a file with a `.gz` |
| Binary size | `negotiate`, the pairing and a second form in the held and spilled arms: code only and no dependency; not measured on its own |
