# A byte that is not text is not a string

A `[]const u8` holding `\xff` went out as `"\xff"` — inside quotes, escaped for
nothing, and not valid JSON. Whoever asked for it could not parse the response.

`json.zig`'s header makes one promise: **the output is byte-for-byte what
`std.json` would have written.** This was the last place where that was untrue.
`std.json` asks `utf8ValidateSlice` before it writes a string and falls back to
an array of byte values when the answer is no; nilo asked nothing and wrote the
bytes.

**nilo now asks the same question, with the same function, and writes the same
array.**

```zig
{ .name = "\xff" }   // was {"name":"<ff>"}   now {"name":[255]}
```

## Why matching `std.json` is the whole decision

Three answers were on the table and only one of them is small.

**Refusing the type is not available.** `[]const u8` is the ordinary spelling of
text in Zig, and a handler returning a name out of a database has no way to
promise it is UTF-8.

**Refusing the value at run time** — a 500 on a body that is not text — is a
server deciding that a row with a stray byte in it may not be served at all.
That is a bigger claim than this layer is entitled to make, and it turns a
cosmetic problem into an outage.

**Writing what `std.json` writes** costs one question per string and keeps the
contract that makes this file's tests possible: `expectSame` runs both writers
over the same value and compares the bytes, so a case nobody thought of is
caught by the comparison rather than by somebody's judgement. Adding
`"\xff"` to those tests was the fix's own proof.

The document still says `string` for such a field, which is what `std.json`
leaves unsaid too. A type that is `[]const u8` is text as far as a schema is
concerned; a *value* that is not text is a run-time fact no schema describes.

## What it costs, and the case that costs the most

`std.unicode.utf8ValidateSlice` has a vector fast path that clears 32 bytes of
ASCII at a time and stops at the first byte over `0x7f`; the rest is walked a
byte at a time by the decoder. So the cost is not a function of the string's
length. **It is a function of where the first non-ASCII byte falls.**

Measured on this machine, `-OReleaseFast`, pinned to one core, best of 25
rounds of 200,000 calls, `std.unicode.utf8ValidateSlice` alone:

| what | bytes | ns |
|---|---:|---:|
| the primary metric's payload, ASCII | 365 | **10** |
| a short field value, ASCII | 9 | 5 |
| one `é` halfway through | 1,024 | 278 |
| one `é` near the front | 1,024 | 704 |
| every character non-ASCII | 1,024 | 2,404 |

Against the 126ns the whole write of that payload costs
([`bench/result/http.md`](../../bench/result/http.md)), the ASCII row is **+8%**
of the write and it is the row almost every response is.

**The best-of-five version of this table was wrong by 3–4× and it was wrong in
the direction that would have changed the decision.** It read 38ns for the
ASCII payload and 6,585ns for the non-ASCII one — an ASCII cost of 30% of the
write rather than 8%, which is the difference between "ship it" and "this needs
a vectorised validator first". Twenty-five rounds and three interleaved runs put
the last two within 1% of each other. The box had three of the author's own
builds on it during the first attempt, which is the whole explanation.

**The non-ASCII rows are the finding worth writing down.** A response whose text
is Japanese, Arabic or emoji-heavy pays the scalar decoder for everything after
its first non-ASCII byte, and at a kilobyte that is 19× the whole rest of the
write. `std.json` has always paid it, so nilo is not slower than the thing it
replaces — but nilo is *eight times faster* than `std.json` on ASCII and would
be much closer to it on CJK text, which is a different claim from the one this
file's header makes.

That is now a roadmap entry with a number behind it: a vectorised UTF-8
validator is the lever, and nobody has needed it yet. Shipping this without one
is the trade this ADR makes, and it is made in favour of being correct today
rather than fast on a payload nobody here has.

## Where the check lives

At the two call sites in `writeValue` that hand a run of bytes to a string
writer — a `Str` and a `[]const u8` — and not inside `writeString`.

`writeString` is also what the logger escapes with, and what a non-exhaustive
enum's `@tagName` goes through. A tag name is a Zig identifier and can never
fail the question; a log line is not a JSON document being handed to a parser
that will reject it. Putting the check where the *value* is decided keeps the
cost off both.
