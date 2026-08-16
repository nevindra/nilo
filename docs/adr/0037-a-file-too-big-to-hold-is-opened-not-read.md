# A file too big to hold is opened, not read

[ADR 0010](./0010-static-files-are-held-in-memory.md) refused to serve files from disk, and named the thing that would change its mind: an Engine that supplies file IO through a seam shaped like `std.Io`. That has happened. This is the argument the roadmap said had to come before any code.

## What 0010 actually refused

Not disk. The two options it weighed were **A**, add file IO to the Bulkhead contract, and **B**, read the files before the socket opens. It chose B, and the reason was the size of A's bill:

> File IO is a different order of obligation — open, stat, read, seek, errors, cancellation — and it would be owed by every replacement Engine forever.

That sentence was true when it was written. It is not true now, and the reason is not that the obligation shrank — it is that it stopped being nilo's to define.

`sendFile` is a slot in the `std.Io.Writer` vtable. `std.Io.File.Reader` is a standard type. zio 0.17 — the version nilo already pins — fills both in: `zio.fs.Dir.openFile` opens through the event loop, `zio.fs.File.stdReader` hands back the standard reader, and `Stream.Writer` carries `.sendFile`, which is an io_uring splice chain on Linux, `sendfile` on kqueue and IOCP, and a buffer-lending loop everywhere else.

So the Bulkhead does not grow "file IO". It grows four names — open a directory, open a file in it, its size, close it — and everything after that is the standard library's vocabulary, reached through a `*std.Io.Writer` that the HTTP layer already holds. An Engine that replaces zio owes what any Zig program owes: a `std.Io`. ADR 0010 wrote the seam's shape down in advance and it fits.

## What was refused with it, and was not worth it

The bill was never only the Bulkhead's. 0010 argued that A "would buy the ability to stream a 2GB file badly", because doing it properly wanted range requests and conditional ranges. Both shipped — [ADR 0021](./0021-a-range-is-a-slice-and-two-headers.md) — and both were written against bytes in memory. That work is not wasted: a range is an offset and a length whether the bytes are in RAM or behind an fd, and the only line that changes is the one that turns a `Part` into something to send.

What was left standing, and stays standing, is the pair of things B bought for free:

- **Path traversal is not possible.** Still not "defended against". The set of URLs is fixed before the socket opens, and a spilled file carries the relative path the directory walk produced. The string handed to `openat` never came from a request. There is still no normalisation step to get wrong.
- **The memory is a number.** A spilled file holds no bytes at all. It costs one file descriptor while it is being sent, and `max_connections` already bounds how many of those there can be at once, so the fd count is the same number an operator was already multiplying.

## The threshold is the one that was already there

`max_file_bytes` refused a large file at load. It now spills one instead.

Below the line nothing changes — held in memory, hashed at load, gzipped if it is worth it, served from a slice, the same bytes and the same benchmark. Above it the file stays in the list with its size and its relative path, and a request opens it. One knob keeps its name and changes what it means, which is better than a second knob that has to be explained against the first.

`error.StaticFileTooLarge` leaves `LoadError`. It existed to hit a ceiling at startup rather than at three in the morning, and there is no longer a ceiling there to hit. `max_total_bytes` still counts, and counts held bytes only, because that is what it was ever measuring.

## Two kinds of ETag, both strong

A held file keeps its content hash. A spilled file gets `"<mtime>-<size>"`.

Hashing is not available above the threshold for the obvious reason: computing a strong tag for a 4 GB file means reading 4 GB, and doing it at load means a server that takes a minute to start on a directory of videos. Doing it per request is worse.

The alternative on offer is a weak validator, and it is the wrong one. RFC 9110 says an `If-Range` carrying a weak validator must be ignored, so a weak tag would send the whole file to every client resuming a download — and resuming is what large files are *for*. 0021 already chose the safe direction when it could not compare a date; here the safe direction is available without giving anything up, because mtime and size together are a strong validator in practice and have been the default in nginx for twenty years. Two different contents sharing a size and an mtime to the nanosecond is the risk being taken, and it is the risk every static server on the internet is already taking.

This is the first last-modified time nilo has ever read. 0021 noted their absence as the reason an `If-Range` carrying a date never matches. That does not change: a date in `If-Range` is still not compared, because the tag is what the client was given and the tag is what it should send back.

## A spilled file is never gzipped

Compression here has one shape, and 0018 is why: nothing compresses per request, so a file is gzipped once while the App is being built or not at all. A file that is not being held cannot be compressed once, and compressing it per request is the trade that was already refused for handler responses.

In practice the threshold sorts this out on its own. A file over 8 MB is a video, an archive, an installer or a disk image, and all four are compressed already.

## The handler side, which was the larger hole

The static tree was the visible half. The other half is that a handler had no way to serve a file at all — no `http.ServeFile`, no `res.sendFile`. An invoice behind an authorisation check is an ordinary endpoint in the kind of application nilo says it is for, and it was not writable.

That is a return type, not a `Ctx` call, for the reason [ADR 0032](./0032-a-redirect-puts-its-status-in-the-type.md) gave for redirects: the signature is the whole contract, and an answer written by a side effect is an answer the generated document cannot see. So:

```zig
fn invoice(files: *Files, id: u32) !?nilo.FileBody {
    const name = try files.nameOf(id) orelse return null;
    return .{ .dir = files.dir, .name = name, .content_type = "application/pdf" };
}
```

`?` means what it means everywhere else — a 404, and a document that says the endpoint answers 404 (ADR 0024).

The `dir` is not decoration. A handler serves out of a directory something opened on purpose and held as a Service, and the name is checked before it is used: no `..` segment, not absolute, no NUL. This is the step 0010 said everyone gets wrong, and the way not to get it wrong is to never resolve a path — to open a name relative to a descriptor that was chosen at startup. A symlink inside that directory is followed, because refusing them breaks ordinary deployments and no static server on the internet refuses them by default.

The document describes the body as `application/octet-stream` with `format: binary`. The real content type is a field the handler fills in at runtime, so naming it in the document would be a guess, and this document does not guess — the same reason `Response(T)` reports its status as "default" rather than claiming 200.

## What has to be right

- **A short send closes the connection.** The length went out in the head, from `stat`. If the file is truncated underneath the transfer, the bytes that arrive are fewer than the bytes that were promised, and a client that is told otherwise will staple the next response onto the end of this one. Keep-alive is dropped rather than the framing being trusted.
- **The transfer is the server waiting, not the handler running.** Wrapped in `watchdog.waiting` exactly as `Ctx.send` is, or a client taking a large file slowly is reported as a held thread (ADR 0034).
- **A missing file is a 404.** Open failing with `FileNotFound` is the one open error with an answer better than 500 — the list said the file was there and the disk disagrees, which from the client's side is indistinguishable from asking for something that does not exist.

## Consequences

- A file that does not fit in memory can be served. The README stops saying otherwise, and `sendfile` comes off the roadmap.
- A handler can answer with a file, and the generated document says so.
- The Bulkhead grows four names. That is the cost, it is paid once, and every one of them is `std.Io`-shaped so an Engine that has a `std.Io` already has them.
- Startup gets faster on a tree with large files in it, because they are no longer read.
- A spilled file is a second code path through the response layer, and the range and conditional logic is shared with the held one rather than copied. Two copies of `If-Range` handling is how the corrupt-download bug 0021 exists to prevent gets back in.
