# The HTTP/1.1 wire protocol

**nilo never reads a request in a way another server could read differently: an ambiguous request is rejected, and a header nilo supports gets exactly the answer RFC 9112 defines.**

**Guide:** [Requests](../guide/requests.md), [Forms](../guide/forms.md) · **Reference:** [Reading](../reference/ctx.md#reading), [`listen` options](../reference/app.md#listen-options)

The code is `http/http1.zig` (`parseHead`, `parseRequestLine`, `finish`, `Encoding`), `http/ctx.zig` (`aboutToReadBody`, the gzip inflate inside `body`), `http/static.zig` (`etagMatchesStrong`) and `http/bulkhead.zig` (`read_buffer`).

## Overview

```
  bytes off the socket
        │
        ▼
  parseRequestLine ──► absolute-form? split authority, route the rest
        │
        ▼
  applyHeaderAt, one header at a time ──► Expect, If-Range, filename*
        │                                  answered as asked, or refused
        ▼
  finish (the blank line)
        │
        ├─► Content-Length / Transfer-Encoding disagree, repeat, or          } error.BadHeader,
        │   frame both ways ─────────────────────────────────────────────── } already a 400
        ├─► HTTP/1.1 with no Host, or two of them ────────────────────────── }
        └─► Content-Encoding other than identity or gzip on a body ──────── 415
        │
        ▼
  Ctx.body() ──► gzip? inflate once into the arena, bounded by max_body
```

Each check runs at the first point that has all the information it needs, not where the header was read, because whether there is a body to reject, or which host was asked for, depends on several headers arriving in whatever order the client sent them.

## Rules

1. **A request that other servers in the chain might read differently is rejected instead of guessed at.** Rejected: a `Content-Length` that is not `1*DIGIT`, a repeated `Content-Length` with a different value, `Content-Length` together with chunked framing, a `Transfer-Encoding` whose last coding is not `chunked` (a 400) or has another coding in front of a final `chunked` (a 501), an HTTP/1.0 request that carries `Transfer-Encoding` (answered, then closed), a folded header line, and a chunk line that ends in anything but CRLF or has a control byte in its extension. Guessing which reading a front end already chose is how one request turns into two (request smuggling). Also rejected: a control byte anywhere in the head, a CR that does not end its line, and a method or header name that is not a token. Those checks look at every byte rather than five headers, and cost 1.5 to 4.5% of throughput end to end (ADR 231 found them). [ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md)
2. **An HTTP/1.1 request needs exactly one `Host`, and its value has to be a host.** None, or two, is a 400; a repeat is rejected even when both copies are the same; so is a value that is a path or carries userinfo (`evil.com/reset?x=`, `a@b`). HTTP/1.0 is left alone, because `Host` was only required from 1.1. [ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md)
3. **An absolute-form target carries its own authority, and that authority is the Host.** RFC 9112 says a server that receives `GET http://example.com/x HTTP/1.1` must ignore any `Host` header and use the target's authority. A request in this form with no `Host` line is therefore not the 400 that rule 2 would otherwise give, because the first line already says which host it wants. [ADR 095](../adr/095-a-target-is-read-in-the-form-it-arrived-in.md)
4. **A target is read in the form it arrived in.** Origin-form is routed as a path, as always. Absolute-form is split into an authority and an origin-form path before routing. Asterisk-form (`OPTIONS *`) is answered as a server-wide OPTIONS and authority-form (`CONNECT`) is a 404, and **neither reaches the router**, because it splits on `/` and would match both against a catch-all. A target in none of the four forms, or one that is not origin-form and has no method it is defined for (`admin:1/x`, `ftp://x/y`, `GET *`), is a 400. [ADR 095](../adr/095-a-target-is-read-in-the-form-it-arrived-in.md)
5. **Userinfo in an absolute-form target is rejected**, because `http://real.example.com@evil.example.net/` points at `evil.example.net` while every human reading it sees the first name. Also rejected: an authority that is not a valid host (it would become the Host), and `http:` without `//`, which has no host at all (RFC 9110 §4.2.1). An empty path with a query (`http://example.com?a=1`) is rejected too, since serving it would mean allocating to insert the missing `/` or silently dropping the query. A target with no path and no query is served as `/`. [ADR 095](../adr/095-a-target-is-read-in-the-form-it-arrived-in.md)
6. **`Expect: 100-continue` is answered when nilo commits to reading the body, not when the header is parsed.** A request rejected before that point (a body too large, a 404, a 405, a handler that never reads the body) gets its final status and the client never sends the body. Nothing is sent for HTTP/1.0, for a request already answered, or for `Content-Length: 0`. [ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md)
7. **`If-Range` uses the strong comparison, never the `If-None-Match` one.** `etagMatchesStrong` rejects a `W/` tag and `*`, and treats an empty ETag as matching nothing. A resumed download appends bytes to a prefix it already has, and "close enough" is the one answer that corrupts it. [ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md)
8. **A multipart part that names its file only with `filename*` is a 400 naming the part, not a text field with the wrong value.** nilo still does not decode RFC 6266's encoded form; it just stops binding the part wrongly without a word. [ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md)
9. **A body with `Content-Encoding: gzip` is decompressed once into the request arena; any coding other than gzip or `identity` is a 415 naming the header.** The length declared in the gzip trailer sizes one exact allocation, and it is checked against `max_body` before anything is decompressed, so a small compressed body cannot grow past the limit an uncompressed one has. [ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md)
10. **`Content-Encoding` on a request without a body is ignored.** Rejecting it would turn an ordinary GET into a 415 over a header that has no effect, the opposite of what rule 1 is for. [ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md)
11. **`c.bodyStream()` decodes nothing and rejects every coding with its own 415.** A stream hands out bytes as they arrive, with nowhere to keep the decoder's history. [ADR 089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md)
12. **`read_buffer` defaults to 16 KiB, and it is both the connection's read buffer and the size limit for a request head.** A head that does not fit is a 431. A server that wants the old size passes `.read_buffer = 8 * 1024`. [ADR 196](../adr/196-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md)
13. **A second parser reads the heads the fuzzer generates, and every difference with it must be explained in writing.** `zig build fuzz-llhttp -Dllhttp` gives each head to nilo and to llhttp. If nilo accepts what llhttp rejects, or the two frame a head differently, the run fails unless the case is listed in `decided` with the RFC section behind it. llhttp is linked only into that program and is fetched only with the flag. [ADR 231](../adr/231-a-second-parser-reads-what-the-first-one-reads.md)
14. **The request line is read leniently where the RFC says so and strictly everywhere else.** One empty line before the request line is skipped (RFC 9112 §2.2); a second is a 400. A version spelled `HTTP/d.d` that nilo does not speak is a static 505, and one not spelled that way is a 400. Every status line's reason phrase comes from one table in `http1.zig` (`statusPhrase`), so a `fail.status(502, …)` goes out as `502 Bad Gateway` and the static answers in `serve.zig` are built from it. [ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md)


## Decisions

| ADR | What it decides |
|---|---|
| [070](../adr/070-a-request-nobody-else-would-answer-is-refused.md) | Which framing ambiguities (`Content-Length`, `Transfer-Encoding`, `Host`) and which bytes (controls, a bare CR, a name or method that is not a token) are rejected instead of guessed at |
| [073](../adr/073-a-header-is-answered-as-asked-or-refused.md) | `Expect: 100-continue`, `If-Range`, `filename*` and `Connection` each get the answer RFC 9110 defines |
| [089](../adr/089-a-body-under-an-encoding-other-than-gzip-is-refused.md) | Which `Content-Encoding` nilo decodes, and how gzip is decompressed without a pool |
| [095](../adr/095-a-target-is-read-in-the-form-it-arrived-in.md) | The four request-target forms, which one supplies the Host, and that a target in none of them is a 400 |
| [196](../adr/196-a-head-is-mostly-cookies-and-sixteen-kilobytes-of-them.md) | The default size of `read_buffer`, and the head size limit that follows from it |
| [231](../adr/231-a-second-parser-reads-what-the-first-one-reads.md) | `zig build fuzz-llhttp -Dllhttp`: nilo's parser checked against llhttp's, and where the intended differences are written down |

Related topics: TLS is terminated in front of nilo, not by it, which is exactly why a second parser reading the same bytes creates a smuggling risk at all: [ADR 027](../adr/027-tls-is-terminated-in-front.md). The head is parsed in place, which is why the buffer is the head's size limit instead of a separate setting: [ADR 085](../adr/085-every-header-without-handing-out-the-head.md). A fiber's stack is held at its high-water mark, which turns a field on `Request` into a per-connection cost: [ADR 062](../adr/062-where-a-connection-waits-is-what-it-costs.md). Reading a trusted `X-Forwarded-Host` before the authority is [ADR 090](../adr/090-a-request-can-be-read-past-the-parts-a-handler-names.md). The arena limit a compressed body is checked against before decompression is [ADR 083](../adr/083-a-body-is-taken-as-it-arrives.md).

## Open questions

- **How much a connection holds mid-request with the 16 KiB `read_buffer`** is calculated (two more pages than before), not measured. An entry in `docs/todo.md` names the run: `bench/mem.py --hold` against `bench-stream-server` at 8 and at 16.
- **RFC 6266's `filename*` stays rejected instead of decoded**, as recorded in [ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md). `core/percent.zig` could decode it; it waits for a client that sends only the encoded form rather than alongside a plain `filename`.
