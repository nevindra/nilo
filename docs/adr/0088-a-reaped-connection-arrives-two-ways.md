# 0088 — a reaped connection arrives two ways

**Status:** accepted
**Amends:** [ADR 0067](./0067-most-of-an-s3-client-is-not-s3.md)

## Context

`fetch/` retries a call once when the pooled connection it was handed turns out
to have been reaped by the peer. ADR 0067 argued that this is transport hygiene
rather than a retry policy, because nothing was answered and nothing reached
anybody, and bounded it to `error.HttpConnectionClosing`, the error `std.http`
raises when a response head ends after zero bytes.

That bound was written from one reading of what a reaped connection looks like,
and there are two.

If the peer's `close` lands before this end writes, the socket carries a FIN,
`receiveHead` reads nothing, and std says exactly that. If **this end writes
first**, the peer closes a socket with an unread request still sitting in its
receive queue, and a close with unread data is an RST rather than a FIN. Same
reaped connection, same nothing answered, and `receiveHead` reports
`error.ReadFailed` instead. The retry did not fire, and the caller got a failure
nobody caused.

Which of the two turns up is a race the client does not run. It depends on
whether the peer's reap beat this end's next request by a few microseconds.

**It was found as a flaky test, which is the part worth recording.** `a pooled
connection the peer already closed costs one retry, not a failure` in
`fetch/live.zig` failed about one `zig build test-all` run in three and passed
three times out of three under `zig build test-fetch`. Read as "the test is
flaky under load", which is what it looks like, the fix is to stabilise the
test. It was not flaky. It was a fair coin, and one side of the coin was a bug:
under `test-all` several test binaries open real sockets at once, and the extra
scheduling delay was enough for the client's second request to reach the socket
before the server let go of it.

Two runs settled that it was not something in `http/`, where five other changes
had just landed: twelve interleaved `test-all` runs failed 1 of 4 against a
clean `a1537a6` and 3 of 4 against the modified tree, and nothing under `fetch/`
imports `http/`. What differs between `test-fetch` and `test-all` is how many
sockets are being opened at once, not what is in the tree.

## Decision

The retry fires when **not one byte of a response came back**, which is the
condition ADR 0067 was really about, rather than when a particular error name
turns up. `Exchange.nothingCameBack` answers it:

- `error.HttpConnectionClosing`, unchanged, or
- `error.ReadFailed` where the connection's reader holds nothing buffered and
  the errno underneath was `ConnectionResetByPeer`.

Both pieces of that second line come from things std keeps and does not join
up. `Io.net.Stream.Reader` parks the real error in `err` on its way to the
generic `ReadFailed`, and how much of the head had arrived is whatever the
connection's reader still holds.

The asymmetry in std is deliberate rather than careless, and reading
`http.Reader.receiveHead` shows it: `EndOfStream` is split by how much of the
head arrived, giving `HttpConnectionClosing` at zero bytes and
`HttpRequestTruncated` past it, and `ReadFailed` gets no such split, because a
read can fail for reasons that have nothing to do with reaping. Making that
split is the caller's job, and this is the caller.

**The evidence is stronger in the new branch than in the one already trusted.**
A server that had read the request would have an empty receive queue and its
close would send a FIN. The RST is the kernel reporting that the request was
still sitting there unread.

Every other bound from ADR 0067 is untouched: only a replayable body, only
inside the same permit and the same deadline, and at most one attempt per
connection the pool could be holding.

## What was rejected

**Stabilising the test and leaving the client alone.** The obvious fix for a
test that fails under load. It would have made CI green while leaving a real
call, against a real service that reaps idle connections, failing on a coin
toss. The flake was the symptom, not the fault.

**Retrying on `ReadFailed` generally.** A reset partway through a head is the
same error with bytes buffered, and there the server did answer, so re-sending
would be a retry policy rather than transport hygiene. The buffered-length check
is what separates them.

**Retrying on `error.WriteFailed`.** A write to a socket the peer has already
dropped is a third spelling of the same race, and part of the request may have
reached the far side before it failed. Nothing here reproduces it, so nothing
here claims it.

**A `sleep` in the test to lose the race on purpose.** The first version of
`serveThenReset` did exactly that. A sleep long enough to lose the race on this
machine is a sleep that silently stops losing it on a slower one, and the test
would go on passing through the FIN branch while claiming to cover this one.
What it does instead is read **one byte** of the second request through a
one-byte buffer: the byte proves the request arrived, and the one-byte buffer is
what stops the read draining the rest of it into user space. That distinction is
not decoration. Written with the connection's ordinary 4 KB buffer, the test
passed with the branch it exists for switched off, because a receive queue read
into user space closes with a FIN like any other.

## What it costs

Nothing on any of ADR 0018's four axes. `nothingCameBack` runs only on an
attempt that already failed; the common path does not reach it. No allocation,
no per-connection memory, two field reads and two compares.

The one thing it spends is a small amount of trust: a caller whose request is
not idempotent and whose peer resets mid-flight after reading it will now see
that request sent twice, where before it saw an error. That window is narrower
than the one ADR 0067 already accepted for the FIN case, for the reason above.
