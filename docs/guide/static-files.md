# Static files

```zig
try app.static("/", "public");

try app.staticWith("/assets", "dist", .{
    .cache_control = "public, max-age=31536000, immutable",
    .spa_fallback = "index.html",
});
```

The directory is read into memory when the server starts, so nothing touches the
disk while requests are being served
([ADR 0010](../adr/0010-static-files-are-held-in-memory.md)). Each file gets an
ETag at load, so a repeat visit is a 304 with no body. Path traversal isn't
possible, because there is no path to resolve — just a name looked up in a fixed
list.

A file over `max_file_bytes` is the one exception, and it is a spill rather than
a refusal: it stays in the list with its size and the path the walk produced,
and a request opens it and sends it from the disk
([below](#files-too-big-to-hold)). Both of the properties above survive that.

The path is relative to the working directory the server runs in, and a directory
that can't be opened stops `listen()` with that sentence in the error.

## Options

| | |
|---|---|
| `index` | served for a path ending in `/`. Default `"index.html"`; empty turns it off |
| `cache_control` | sent on every file. Default `"public, max-age=3600"` |
| `spa_fallback` | served for any path under the prefix that names no file. Empty (the default) turns it off |
| `max_file_bytes` | the line between a file held in memory and one opened per request. Default 8 MB |
| `max_total_bytes` | the ceiling on what one tree may hold in memory, gzipped copies included. Default 64 MB |
| `dotfiles` | whether to load names starting with `.`. Off by default |
| `compress` | gzip every file worth gzipping, once, at load. On by default |
| `compress_min_bytes` | files smaller than this are served as they are. Default 1 KB |

`spa_fallback` is what makes a browser reload on `/users/42` reach your
client-side router instead of a 404. Dotfiles are off because a `.env` or a
`.git` that found its way into the directory being published on the first request
is a bad way to learn it was there.

`max_total_bytes` is a real ceiling — the held part of the tree is going into
RAM — and it is better to hit it at startup than at 3am. `max_file_bytes` is not
a ceiling but a line: a file over it is served from the disk rather than
refused, and holds nothing to be counted against the total
([below](#files-too-big-to-hold)).

## Compression

Every file worth compressing is gzipped **once, while the App is being built**,
and a client that says `Accept-Encoding: gzip` gets the copy that was already
made. Nothing is compressed per request, so serving a compressed asset costs a
slice and a header — measured at zero allocations, held by a test.

That holds with middleware in front of it, which is worth saying because it did
not always: the chain an asset runs through is worked out at `listen()`, per
file, the same as a route's. A logger, a CORS, or anything scoped to a prefix
above or below the asset adds nothing to the request.

That timing is the whole design, not an optimisation on top of it. A gzip
compressor needs a 64 KB window: one per connection would take an idle
connection from 4,669 bytes to roughly fifteen times that, and one per request would
put an allocation on the path where the budget is one
([ADR 0018](../adr/0018-the-trade-budget-has-three-axes.md)). A file that never
changes escapes both, because it can be compressed before the socket is open.

What it costs instead is memory that stays: the compressed copy sits beside the
original for the life of the process, and is charged against `max_total_bytes`
like everything else. The startup line says how much it came to:

```
nilo: loaded 34 static file(s) (2411903 bytes held, 383204 of them gzipped
       copies) from "dist" onto "/assets"
```

A file is skipped when it is under `compress_min_bytes`, when its type is already
compressed — a PNG, a woff2, an MP4 — when gzip did not actually make it
smaller, or when it is over `max_file_bytes` and so was never read to be
compressed at all. **A response body is never compressed**, only files; an
endpoint returning JSON goes out as it is.

Three details that are easy to get wrong, and are not:

- **`Vary: Accept-Encoding`** goes out whenever a file has two representations,
  including on the response carrying the plain one. Without it a shared cache
  stores whichever answer it saw first and hands it to everyone after.
- **The two representations have different ETags.** An ETag names a
  representation, not a file, so handing both the same one would let a cache
  answer a client that can't read gzip with the gzipped copy — the tag matched,
  after all.
- **`gzip;q=0` means no.** It contains the word `gzip` and means the opposite,
  which is how a client that can't decompress says so.

## Range requests

A video being scrubbed and a download being resumed both ask for a range, and
both get one:

```
$ curl -i -r 0-20 localhost:8787/video.mp4
HTTP/1.1 206 Partial Content
Content-Length: 21
Accept-Ranges: bytes
Content-Range: bytes 0-20/739
```

`bytes=3-7`, `bytes=20-` and `bytes=-30` all work, and `Accept-Ranges: bytes`
goes out on every file response so a client knows it may ask.

The rule for everything else is that **a `Range` that can't be understood is
ignored and the whole file goes out**
([ADR 0021](../adr/0021-a-range-is-a-slice-and-two-headers.md)). That is a
correct answer to every request, so `bytes=abc-def` or `bytes=99-10` gets a 200
rather than an error. The one case worth refusing is a range starting past the
end of the file: that's a client with the wrong idea about the size, and a `416`
with `Content-Range: bytes */739` is the only way to say so.

`If-Range` is honoured against the ETag, which is the one that matters for
correctness: resuming a download of a file that has since changed would staple
two halves of two different files together, so a stale ETag gets the whole file
instead.

A request that asks for a range gets the **uncompressed** file, whatever it said
about `Accept-Encoding`. A range is an offset into a representation, and the
gzipped copy has different offsets — so answering one from the other would hand
back the wrong bytes without saying so.

A request for several ranges at once is legal and wants a `multipart/byteranges`
body nilo doesn't assemble — so it gets the whole file too. Nothing sends them.

## Files too big to hold

A file over `max_file_bytes` is left where it is. It keeps its place in the list
with its size, its modification time and the path the directory walk produced,
and the request that asks for it opens the file and sends it from the disk
([ADR 0037](../adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)). A
directory with a video in it serves rather than failing to load.

Below the line nothing has changed: read at load, hashed, gzipped if it is worth
it, answered from a slice. Three things change above it.

- **There is no gzipped copy, and there never will be.** Compression happens
  once, while the App is being built, and a file that is never read has no
  "once" to be compressed in. A file that size is a video, an archive or an
  installer, and all three are compressed already.
- **The ETag is the modification time and the size**, `"<mtime>-<size>"` in hex,
  rather than a hash of the contents. It is strong, and it is what nginx has
  served by default for twenty years. Hashing would mean reading the whole file
  at startup, and the weak tag that is the other alternative would make
  `If-Range` unusable for exactly the large downloads that get resumed.
- **One file descriptor is held for as long as the response takes.** One per
  request in flight, which `max_connections` already bounds — the number an
  operator was already multiplying.

Two things do not change, and they are the pair that holding everything in
memory bought. Path traversal is still not possible: the name handed to the
kernel is the one the walk wrote down before the socket opened, never one a
request carried. And the memory is still a number — a file over the line holds
no bytes at all, so `max_total_bytes` counts what is held and nothing else.

Ranges, `If-Range`, `If-None-Match` and `HEAD` are answered exactly as they are
for a file in memory, by the same code rather than by a second copy of it.

The startup line counts the spilled files separately from the bytes, because
they are not in that number:

```
nilo: loaded 12 static file(s) (48211 bytes held, 9022 of them gzipped copies)
       from "public" onto "/", 2 of them over 8388608 bytes and opened per
       request rather than held
```

A handler can answer with a file the same way — see
[Responses](./responses.md#files).

## The limits

The set is loaded once, at startup. There is no reload — changing a file means
restarting the process, which is what a deploy does anyway.

For a file over the line, that is a stronger instruction than it used to be. Its
length and its ETag were recorded at load and its bytes are read per request, so
editing one underneath a running server splits what used to be one consistent
copy. Shrinking it is caught: fewer bytes arrive than the head promised, so the
connection is closed rather than letting the client read the next response as
the rest of this body. Growing it is not — the first recorded-length bytes go
out under the old ETag, which is a complete, correct-looking response carrying a
prefix of a file that has moved on.

Static files are not middleware: the set holds state, so it is a terminal handler
that the middleware chain wraps like any other. Your logger sees them, and CORS
applies to them.
