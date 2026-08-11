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

The path is relative to the working directory the server runs in, and a directory
that can't be opened stops `listen()` with that sentence in the error.

## Options

| | |
|---|---|
| `index` | served for a path ending in `/`. Default `"index.html"`; empty turns it off |
| `cache_control` | sent on every file. Default `"public, max-age=3600"` |
| `spa_fallback` | served for any path under the prefix that names no file. Empty (the default) turns it off |
| `max_file_bytes` | files bigger than this are refused **at load**, with their name in the error. Default 8 MB |
| `max_total_bytes` | the same for the whole tree. Default 64 MB |
| `dotfiles` | whether to load names starting with `.`. Off by default |

`spa_fallback` is what makes a browser reload on `/users/42` reach your
client-side router instead of a 404. Dotfiles are off because a `.env` or a
`.git` that found its way into the directory being published on the first request
is a bad way to learn it was there.

The size ceilings are real ones — the whole tree is going into RAM — and it is
better to hit them at startup than at 3am.

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

A request for several ranges at once is legal and wants a `multipart/byteranges`
body zfast doesn't assemble — so it gets the whole file too. Nothing sends them.

## The limits

A file that doesn't fit in memory can't be served. `sendfile` is not here, and it
contradicts holding files in memory rather than extending it.

The set is loaded once, at startup. There is no reload — changing a file means
restarting the process, which is what a deploy does anyway.

Static files are not middleware: the set holds state, so it is a terminal handler
that the middleware chain wraps like any other. Your logger sees them, and CORS
applies to them.
