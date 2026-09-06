# A stream that knows its length says so

`Ctx.stream` set `chunked` from the request's minor version and there was
nothing beside it. So a handler moving bytes out of something that had already
counted them sent them with no `Content-Length`:

```zig
const object = try bucket.stream(c, key);   // object.len is known here
var body = try c.stream(200, object.content_type);
```

`nilo_s3`'s `bucket.stream` reports `len` before the first byte arrives, and a
handler proxying an upstream response has the length it was given. Both threw
it away.

What that costs is not framing overhead. A browser downloading a chunked
response shows no progress — there is nothing to draw a bar against — and a
`Range` against it cannot be answered at all, which is exactly the request a
large download makes when it resumes. The file paths never had this problem:
`sendFile` and `FileBody` both send a length
([ADR 0037](0037-a-file-too-big-to-hold-is-opened-not-read.md)).

## The question that was open

The roadmap held this on *a design*, and named the design it was waiting for:

> what happens when the count and the promise disagree.

[ADR 0097](0097-a-frame-that-lies-about-its-length-is-not-sent.md) is the same
question one layer down, about a WebSocket frame, and its answer is the one to
copy: refuse to send what lies about its length.

The two directions of disagreement are not symmetrical, and that is the whole
of the decision.

**Writing past the promise is refused**, before a byte of the overrun goes out.
A client reading a `Content-Length` stops at it, so everything after it is read
as the beginning of the next response on that connection — a response-splitting
bug rather than a lost tail. The refusal arrives as `error.WriteFailed` out of
the writer, which is the same error a client walking away produces, and one
`std.log.err` naming both numbers.

**Finishing short cannot be refused**, because the head has already gone. There
is no correcting a promise that is on the wire. What is left is to stop the
client waiting for bytes that are not coming and to stop the next response
being read as those bytes: the connection closes, and the log says how many
were promised and how many arrived. `endAbandonedStream` does the same for a
handler that returned without calling `finish`.

## What it does now

```zig
var body = try c.streamWith(200, object.content_type, .{ .length = object.len });
```

The head carries `Content-Length` and no `Transfer-Encoding`, and the pieces go
out unframed. `Open` grew `promised` and `written`; `drain` counts.

An assert in `writeStreamHead` holds the other half: never both headers. A
response carrying a length *and* a chunked encoding is one a proxy is entitled
to read either way, which is how a request smuggles.

A HEAD is not a short body. The head says what a GET would have said, nothing
follows it, and nothing about that closes a connection.

**HTTP/1.0 gets keep-alive back.** Without a length, an HTTP/1.0 stream can
only end by closing the connection, so `_force_close` was set. With one, the
promise says where the body stops, and the connection survives.

## What it costs

**Nothing for a stream that does not use it.** `promised` is null, the counting
branch is not taken, and the chunked path is byte-for-byte what it was.

**For one that does**: one `u64` add per drain, and one comparison. No
allocation, and `Open` grows by 16 bytes on the `Ctx` — which lives on the
fiber's stack and is unwound before the connection waits for its next request
([ADR 0071](0071-where-a-connection-waits-is-what-it-costs.md)), so this is not
memory an idle connection holds.

It also *removes* work on the path that uses it: no chunk header and no
trailing CRLF per piece, and no terminator at the end.

## What was rejected

**Padding a short body to the promised length.** It makes the framing correct
and the content wrong, which is worse: the client gets a file it believes is
complete.

**Letting the overrun through and logging it.** The bytes past the promise are
read as the next response. There is no version of this that is only a log line.

**Working the length out ourselves by buffering the whole body first.** That is
`send`, and it is already there. The point of a stream is that the body does
not have to exist in memory at once
([ADR 0020](0020-a-response-can-be-written-in-pieces.md)).

**A trailer.** HTTP/1.1 can put a length in a trailer after a chunked body, and
almost nothing reads trailers. It would answer neither of the two things this
is for: a progress bar needs the number before the bytes, and a `Range` needs
it before the request.
