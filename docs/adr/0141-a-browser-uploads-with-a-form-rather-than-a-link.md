# A browser uploads with a form rather than a link

`bucket.presign(c, key, seconds)` returns a SigV4 query URL, which covers GET
and PUT. A browser uploading straight to the object store uses neither: it
posts a multipart form to the bucket, and what it needs is a **POST policy** —
a JSON document, base64-encoded, signed with the same derived key, handed back
as a set of form fields.

nilo could not sign one, so every receipt, deal attachment and comment
attachment in a caller's product had to.

## Why it is here rather than in the application

Everything it needs was already inside the module.
[ADR 0069](0069-a-signing-key-changes-once-a-day.md) derives the signing key
and rotates it daily; `sign.signature(key, string)` is the HMAC; `Keyed.akid()`
and `Keyed.credentialScope()` already assemble the credential for the query
presign; `Stamp.iso()` already writes the date.

The whole of a POST policy is those pieces plus a JSON document and one more
base64. Writing it outside nilo means **the SigV4 key derivation exists in two
places that have to agree about a daily rotation**. They disagree at 00:00 UTC,
and the symptom is uploads failing with a 403 that says nothing.

Worth knowing: the AWS SDK for Go has no presigned-POST support either, only
`PresignPutObject`. The caller had already hand-rolled this once, in Go, and
left a comment saying so.

## The shape

```zig
const posted = try bucket.presignPost(c, key, .{ .seconds = 900 });
// posted.url        — the bucket, not the key: a POST policy posts to the bucket
// posted.fields     — name/value pairs, in the order they go into the form
// posted.expires_at — the true one
```

The fields go into the form **in the order they come back, with the file input
last**. S3 ignores whatever follows the file part, which is a rule of the
protocol rather than of this call, and the doc comment says so where somebody
building the form will read it.

`.content_type` pins what the browser may send. `.prefix = true` makes `key` a
`starts-with` condition rather than an exact match, which is what a browser
picking its own filename needs.

## `max_bytes` defaults to the bucket's and is clamped to it

This is the one decision in here that is not mechanical.

A `Bucket` already declares `max_bytes`, the largest object it deals in. A
browser POST is the one path that can put a bigger object there **without nilo
seeing a byte**, and an object over `max_bytes` is one `get` refuses for the
rest of its life. So the policy always carries a `content-length-range`, it
defaults to the bucket's ceiling, and a larger `.max_bytes` is clamped down to
it rather than honoured.

A form with no ceiling is not something this call hands out. A caller who wants
a bigger one raises `max_bytes`, which is the same lever they would pull to
read the object back.

The life is clamped the three ways `presign`'s already is: what was asked, what
`presign_max` allows, and what the credentials have left. That clamp was inline
in `presign` and is now `life(wanted, signing, now_s)`, called by both, because
two copies of it would eventually be one copy and one bug.

## What it costs

Against [ADR 0018](0018-the-trade-budget-has-three-axes.md)'s axes:

- **Allocations per request: none.** Signing touches no socket and is not on
  the request path. A handler that calls it pays two arena allocations, one for
  the text and one for the field list.
- **Text: 2,449 bytes** for an ordinary key on static credentials, **15,949**
  with a 900-byte STS token, both at the ceiling. `presign` already allocates
  about 9 KiB in the second case, so this is the same order rather than a new
  cost.
- **Stack: 366 bytes** of named buffers plus `session_token_max` — *less* than
  `presign`'s, deliberately, because the policy lives in the arena and a
  handler's stack is per connection for the life of it
  ([ADR 0063](0063-a-handlers-stack-is-per-connection.md)).
- **Binary size:** nothing in a program that does not call it.

Those are computed ceilings rather than a measurement, which is why there is no
`bench/result/` entry: nothing was run on a machine, and a number with no run
behind it does not go in that file.

## Escaping, and why it is not incidental

`"`, `\` and control bytes are escaped in the policy's JSON. S3 keys legally
hold all three, and a raw one is a `MalformedPOSTRequest` that names no byte.
That is the class of failure this module exists to keep out of a caller's
afternoon.

## How it is held

Two ways, matching ADR 0072's pattern.

**Offline**, in `s3/canned.zig`: the base64 policy decodes back to the exact
JSON, and the signature equals an `HmacSha256` written out longhand in the test
rather than by calling the same helper the code under test calls.

**Against a real MinIO**, in `s3/live.zig`: an actual multipart POST with a
credential-free client, which is the only thing that answers "would S3 accept
this document". The canned server never sees a POST.

That live test earned its place at once. It failed twice out of two under
`zig build` and passed both of its own binaries standalone: `test-s3` builds
Debug and ReleaseSafe and runs them **at the same time** against one server,
and both were writing and deleting the same key. The POST is the slow one — a
multipart body through a fresh connection with no pool — which is why no
existing live test had met this even though they all share credentials. The key
now carries `@tagName(builtin.mode)`.

## Consequences

- `presignPost`, `Post`, `Posted` and `Field` on the public surface, and
  `Policy`, `writePolicy`, `policySize` and `Stamp.expiration` inside
  `sign.zig`.
- `presign` and `presignPost` share one life clamp.
- No new refusal. Nothing about `presignPost` is a compile-time mistake Zig
  does not already name: `Post` is a concrete struct, so a mistyped field is a
  plain "no field named", and the two comptime options it leans on are already
  refused by `presign_over_seven_days` and `max_bytes_of_zero`.
- `LIST`, `COPY` and multipart upload are still not here. This closes the one
  gap in the module that was a hole rather than a line drawn on purpose.
