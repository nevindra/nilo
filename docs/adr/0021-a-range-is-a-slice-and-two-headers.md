# A range is a slice and two headers, and everything else is ignoring the header safely

Range requests sat on the v2 list next to streaming, WebSocket and large bodies, under a heading saying they were all blocked on the same decision about memory. They were not. A file is already in memory (ADR 0010), so serving part of one is `bytes[start..last+1]` and a `Content-Range`. There was never anything to decide.

What there *is* to get right is the header, and the useful surprise is how little of it is arithmetic.

## Ignoring it is always a correct answer

RFC 9110 §14.2 says a server may ignore `Range` entirely and answer 200. That is not a loophole to lean on lazily — it is the design:

> **Anything that cannot be understood is ignored, and the whole file goes out.** Nothing in `range.zig` returns an error, because there is no failure mode that a 200 is not a correct answer to.

`bytes=abc-def`, `bytes=0x10-`, `bytes=99-10`, `items=0-99`, a `Range` with no `=` at all: 200, whole file. A client that typed a range wrong gets what it asked for the first time, rather than a 416 sending somebody to read a spec.

The one case worth a 416 is different in kind: `bytes=1000-` on a 26-byte file is not a malformed request, it is a client with the wrong idea of how big the file is, and `Content-Range: bytes */26` is the only way to tell it so.

## What is deliberately not implemented

**More than one range in a header.** It is legal, and it wants a `multipart/byteranges` body: a boundary string, a nested head per part, and a body format that exists nowhere else in zfast. A browser scrubbing a video sends one range. A download resuming sends one range. `curl -r` sends one range. So a request for several is ignored and the whole file goes out — correct, and it costs no code.

**`sendfile`, and files too big to hold.** Still not here, and still a contradiction of ADR 0010 rather than an extension of it. Serving a range from memory is what makes this feature four lines; serving one from disk is a different design and wants its own argument.

**Dates in `If-Range`.** The header may carry an ETag or a last-modified date. zfast has no last-modified date to compare against — files are hashed at load, not stamped — so a date never matches, and a client sending one gets the whole file. That is the safe direction: the failure mode of *not* honouring a range is a bigger download, and the failure mode of honouring one wrongly is a corrupt file.

## `If-Range` is the one that matters for correctness

A client resuming a download asks for byte 900 of a file it started reading yesterday. If the file has changed, byte 900 of the new one is not the byte it wanted, and the client will staple two halves of two different files together and notice nothing.

So `If-Range` is honoured against the same ETag `If-None-Match` uses: matching means the range is served, and anything else — a stale ETag, a date, a value that makes no sense — means the whole file. The two headers reusing one comparison is not a coincidence; they are asking the same question for opposite reasons.

## Consequences

- `Accept-Ranges: bytes` goes out on **every** static response, including the 304 and the 416, because it is how a client learns it may ask at all.
- 206 and 416 join the statuses whose whole first line is assembled at compile time, so a partial response starts with one `writeAll` like every other.
- A `HEAD` with a `Range` answers 206 with the part's `Content-Length` and no body. That falls out of `Ctx.send` already knowing what a HEAD is, and needed nothing here.
- The parser is its own file with its own tests rather than four lines inside `serveStaticFile`. It has more edge cases than lines of arithmetic, and every one of them is a way to serve the wrong bytes silently.
- Nothing about the request path changed for a request without a `Range` header: one `c.header` lookup that returns null, and the same 200 as before.
