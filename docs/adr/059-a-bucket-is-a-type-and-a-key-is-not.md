# A bucket is a type, and a key is not

**Status:** accepted
**Topic:** [s3](../design/s3.md)

`CLAUDE.md` says a module gets in *"only if it is expressible as a type the
caller already wrote, checked while compiling"*. An object-storage client looks
like it fails that on sight: there is no schema, no query, nothing the compiler
can hold. `nilo_pw` faced the same and got in through another door — argon2id is
a plain function, and what makes it nilo is the Gate in front of it
([ADR 044](./044-a-password-hash-is-gated-because-forgetting-is-silent.md)).

This module does not need that door. The shape it wants is already in the
repository, in [ADR 054](./054-a-second-database-is-a-second-type.md): a
second database is a second *type*, so two pools are two Services and which one
a statement takes is written in the handler's argument list. A bucket is that
exactly.

## What was decided

**`s3.Bucket(name, opts)` returns a type. Two buckets are two types, therefore
two Services, and a handler names the one it wants.**

```zig
const Avatars  = s3.Bucket("avatars",  .{ .max_bytes = 5 << 20, .sse = .aes256 });
const Invoices = s3.Bucket("invoices", .{ .max_bytes = 20 << 20, .style = .path });

var store    = try s3.open(gpa, .{ .endpoint = cfg.s3_endpoint,
                                       .region   = cfg.s3_region,
                                       .credentials = .{ .static = cfg.aws } });
var avatars  = try Avatars.open(&store);        // the declared name, "avatars"
try app.provide(&avatars);

fn getAvatar(id: Uuid, avatars: *Avatars, c: *nilo.Ctx) !s3.Object {
    return avatars.get(c, try key(c, id));
}
```

The type-keyed registry ([ADR 005](./005-services-via-a-runtime-registry.md))
resolves `*Avatars` with nothing new added to it, and a program that registers
two buckets of the same type is refused by the check that is already there.

## What is settled while compiling, and what is not

The split is not "as much as possible". It is: **whatever is a property of the
bucket rather than of the deployment.**

| comptime, on the type | runtime, on the client |
|---|---|
| bucket name, as the default and the type's identity | endpoint |
| addressing style (`virtual` / `path`) | region |
| `max_bytes` | credentials |
| `sse` | `max_in_flight`, drain threshold |
| `presign_max` | the bucket's name, when it is configuration (`openAs`) |

Endpoint and region are runtime because they come from the environment —
`nilo_config` exists so that development and production are one binary
([ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)),
and a comptime endpoint would undo that.

That looks like it gives up what putting the bucket in a type was for. It does
not, and the reason is worth stating because it was nearly got wrong here: the
win was never *comptime*, it was **not formatting a host per request**.
`Avatars.open(&store)` builds the host and the credential-scope prefix once and
holds them. **Zero allocations per request either way** — one at startup instead
of one at compile time.

**The name is a comptime default with a run-time override.** A program whose
bucket is configuration (photon reads `PHOTON_DURABLE_BUCKET`, one binary for
every deployment) declares the type for its identity and opens it under the name
it was given:

```zig
const Durable = s3.Bucket("durable", .{ .style = .path });

var durable = try Durable.openAs(&store, cfg.durable_bucket);   // error.BadBucketName
```

The type is still the Service: `*Durable` is what a handler names, two bucket
types are two Services whatever they were opened as, and `Durable.open(&store)`
still opens the declared name. `openAs` checks the name at run time by the same
predicate the compile-time check runs on the declared one (`badName`, one
function for both, so the two cannot drift), answers the named error
`BadBucketName` rather than panicking, and copies the name into the memory the
bucket already owns, so the config string need not outlive the call.
`Durable.nameProblem(name)` gives the reason in words for a program that wants
to say which setting is wrong while it reads its configuration. Every log line
and a POST policy say the name the bucket was opened under, not the declared
one: the S4 spike for photon had overwritten `prefix` after `open` to get a
configured bucket, and its log lines named the wrong bucket.

Path style also refuses, at both times, a name with a byte that would end or
change a URL path (`/`, `?`, `#`, space, a control byte), because a path-style
name is written into the URL unencoded and a name from configuration is data.
Letters of either case, digits, dot, dash and underscore are accepted, which is
what old buckets carry.

What comptime does buy is the half that cannot be bought any other way.

**Refusals.** Each of these is a compile error with a message nilo wrote, which
means a file in `refusals/` and a row in a fifth table, `s3_refusals`, beside
the four `build.zig` already carries (ADR 026):

- a bucket name that virtual-host addressing cannot carry — not 3–63
  characters, not lowercase, containing an underscore, shaped like an IP; or,
  by path, one that would change the URL (the same check refuses a run-time
  name with `error.BadBucketName`)
- a secret in a comptime option. `s3.Bucket("avatars", .{ .secret_access_key = "wJalr…" })`
  is a secret compiled into the binary, and it must not be possible to write
- `presign_max` above seven days, which SigV4 refuses at 604,800 seconds
- `max_bytes` of zero
- `session_token_max` above `sign.token_max` (2,048 bytes), the token the
  presign buffer is sized for; a longer one reached a `catch unreachable` in
  `presign`

**A constant `SignedHeaders`.** This is the one that decided the API surface
rather than merely decorating it. SigV4 signs a sorted list of header names and
sends that list in the signature. If the set of headers a request may carry is
fixed at compile time, the list is a **constant** and signing does not sort
anything per request. Arbitrary `x-amz-meta-*` would turn it into a per-request
sort, which is the shape
[ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md) spent
itself avoiding for SQL.

So the header set is fixed: `content-type`, `content-disposition`,
`cache-control`, `host`, `x-amz-date`, `x-amz-content-sha256`, and
`x-amz-server-side-encryption` when the bucket asks for it. **Arbitrary object
metadata is refused**, and there is a second reason it is a good refusal: a
`\r\n` in a metadata value is header injection into the request nilo is signing,
and a fixed set makes that unwriteable. A fixed set of *names* does not fix the
*values*, though: a `content_disposition` built from a user's filename, or an
etag handed to `getIf`, reached std's client unchecked, which only asserts
against CRLF, so a safe build panicked and `ReleaseFast` split the request. A
value with a byte under 0x20 other than tab, or 0x7f, is `error.Rejected` before
anything is signed.

**A key is not a type, and that is deliberate.** A comptime key template —
`s3.Key(struct { user: Uuid, size: Size })` producing `users/{uuid}/{size}.png`
— is the most nilo-looking idea in this whole design and it is refused. It is a
template DSL, and `README.md` refuses templates on the grounds that the
comptime-checked shape is a compiler of its own. A key is a string the
application decides; nilo's job is to encode it correctly, once, per RFC 3986
with `/` left alone ([ADR 057](./057-percent-is-needed-by-two-layers.md)).

**The one key nilo refuses is the empty one**, because it does not name a different object but a different operation: the URL is the bucket's root, so `get("")` was a listing returned as an object, `delete("")` DeleteBucket, `put("")` CreateBucket and `presign("")` a signed listing for a browser. Every object call, `presign`, `presignPut` and a `presignPost` without `.prefix` answer `error.Rejected`; `list` and a prefix policy, where `""` means "any key", take it.

## What the API is, and why each piece is that shape

**`Object` out, a shape check in.**

```zig
pub const Object = struct { bytes: Str, content_type: Str, etag: Str, len: u64 };
```

`bytes` is a `Str` even though an object is usually not text, and that is not a
stretch: `http/form.zig` already says of `Upload.bytes` that it is *"doing
lifetime duty rather than claiming the contents are text"*. An S3 object body
lives in the request arena and goes stale with the request, which is the whole
of what a `Str` means.

`put` takes anything with `.bytes` and `.content_type`, checked while compiling,
in the shape `core/scope.zig` uses — *"a shape checked while compiling, not an
interface with a function table"*. So the ordinary job composes with no
ceremony and without `s3/` naming `nilo_http`, which the layering forbids:

```zig
fn save(form: Form(NewAvatar), avatars: *Avatars, c: *nilo.Ctx) !Redirect(303) {
    try avatars.put(c, key, form.value.image);   // nilo.Upload, straight through
    return .to("/me");
}
```

**Bounded and streamed, both, and a length on the streamed `put`.** A streamed
`get` pipes S3's body to the response writer and allocates nothing. A streamed
`put` takes a length as an ordinary argument — `put(scope, key, len, reader)` —
because S3 requires one: plain `Content-Length`, or `aws-chunked` with
`x-amz-decoded-content-length`, both of which mean the size is known before the
first byte. Upload of unknown size is only possible through multipart upload,
which is refused for v1. **Putting the length in the signature makes "I do not
know the size" a compile error instead of a 411 from AWS in production.**

**Range, because it fixes a hole rather than adding a feature.** Without it a
500 MB object can only be streamed. With it a bounded `get` can pull bytes
0–1 MB of one into the arena. It is one request header out, one response header
in, no allocation and no new machinery, and the vocabulary is already decided by
[ADR 020](./020-a-range-is-a-slice-and-two-headers.md). `s3` declares its own
two-field `Range`; duck typing earns its place for a three-field `Upload` the
caller already holds, not for two integers.

**`getIf` returns a union, not an error.** `Object` carries an `ETag`, and an
ETag a caller cannot use is half a feature — the argument
[ADR 043](./043-a-deadline-needs-a-connection-you-hold.md) made for
`TimedOut`. A 304 is a **success**, so it may not be an error
([ADR 023](./023-a-failure-mode-belongs-in-the-return-type.md)):

```zig
switch (try avatars.getIf(c, key, .{ .none_match = tag })) {
    .unmodified => …,
    .object => |o| …,
}
```

The compiler makes the second case unforgettable, which a nullable return would
not.

**`Presigned` carries its own expiry.** Presigning touches no socket at all —
it is HMAC and hex — so it needs neither the loop nor a permit at the gate. But
a URL signed with temporary credentials **dies when they do**, not when
`X-Amz-Expires` says. Handing back a bare string would mean promising seven days
and delivering six hours with nothing in the program able to tell. So the
effective life is clamped to `min(requested, credential life)` and returned:
`Presigned { url: Str, expires_at }`. A caller storing that URL in a database or
mailing it has the number that is true.

## The failures a handler can tell apart

Following `sql/wire.zig`: a short list, each member earning its place because a
handler would do something different, and **default 500 unless stated**.

`NotFound` · `TooLarge` · `Throttled` · `Unavailable` · `TimedOut` ·
`Rejected` · `Failed`

**Exactly one carries a default status: `NotFound` → 404**, mirroring
`AlreadyExists` → 409 as the one whose meaning does not change with the request
around it. `Throttled → 503` was considered and refused for the reason
`sql` refused a default on `Locked`: for `GET /avatar/:id`, S3 shedding load may
well mean a default image and a 200.

`Rejected` is deliberately **not** 403. Telling a client they are not allowed,
when the truth is that the server's credentials are wrong, is a lie in the one
place a lie costs the most debugging.

**The `<Code>` is logged and does not reach the client** (ADR 024), and reading
it needs no XML parser — a scan for `<Code>…</Code>` is twenty lines. That is
also the whole reason `LIST` is not in v1: it is the one operation whose success
path is XML, and a list result is a type AWS wrote rather than one the caller
did. `COPY` goes with it, and carries its own trap for whoever adds it — S3 can
answer a copy with **200 and an error in the body**. `LIST` came back later, as
one bounded page and no more, when a caller brought the case
([ADR 058](./058-most-of-an-s3-client-is-not-s3.md)); `COPY` came back the same
way, as `copy` and `compose`, reading its body for the 200 that is not one.

One thing is worth the five extra lines: `RequestTimeTooSkewed` is the one 403
that is not the program's fault, and S3's error body carries the server's time.
Scanning for it too turns *"403"* into *"your clock is 23 minutes behind S3"*,
and this repository holds that error messages are a feature.

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes:
**nothing this ADR decides costs anything on any of them**, and the run-time
name costs this much. Allocations: `open` and `openAs` make the one allocation
`open` always made, none per request, and a refused name allocates nothing (held
by a test with a counting allocator). Bytes: 16 more in the `Bucket` value (the
name slice) and the name's own 3 to 63 bytes in the allocation that already
held the host and prefix; a `Reading` is the same size, because the bucket it
points to replaces the Store it used to point to. Throughput: nothing on the
request path reads the name except a log line and `presignPost`. Binary: 160
bytes more in the stripped `ReleaseFast` `size-s3` program (1,843,128 to
1,843,288). Host and credential scope are built once at `open()`;
`SignedHeaders` is a constant; the refusals run at compile time and are absent
from the binary; `Range`, `getIf` and `Presigned` are headers and a struct. The costs of this module are
`std.http.Client`'s and are stated in
[ADR 058](./058-most-of-an-s3-client-is-not-s3.md).

## Consequences

- **A bucket's name moved from comptime-only to "comptime default, run-time
  override".** Rejected: keeping it comptime-only. It forced one binary per
  deployment, or the field overwrite the photon spike used, which left the log
  lines naming the declared bucket. Also rejected: a `Bucket` with no declared
  name, which would give up the compile-time refusal and the name that makes
  the type self-describing for nothing a default does not already give.
- **Two buckets in one program are two types**, so a handler cannot reach the
  wrong one, and a bucket added later is a new type rather than a new string
  argument threaded through call sites.
- **A fifth refusals table.** `build.zig` gains `s3_refusals` and a
  `refusals-s3` step. CLAUDE.md's warning applies with more force at five than
  it did at four: adding a row to one table while running another is a check
  that silently never ran.
- **`COPY` and multipart upload go to the roadmap with their reasons
  attached**, not as gaps. The reason for both is the same sentence: they
  are where S3 stops being bytes at a key and starts being a document format.
  `LIST` went with them, and all three have since shipped, one caller each:
  `list` as one page, `putMultipart`, and `copy` with `compose`
  ([ADR 058](./058-most-of-an-s3-client-is-not-s3.md)).
- **Arbitrary object metadata is refused on a performance argument**, which
  means the argument can be revisited with a measurement rather than an
  opinion. Whoever wants it should bring the number for a per-request
  `SignedHeaders` sort.
- **A key is the application's business.** nilo encodes it and never invents,
  normalises or validates one — which also means a key built from user input is
  the caller's path-traversal problem, exactly as `Upload.filename` already is.
