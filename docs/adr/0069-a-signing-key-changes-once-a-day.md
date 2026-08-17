# A signing key changes once a day, and credentials change on somebody else's schedule

Two facts about SigV4 point in opposite directions, and the design falls out of
taking both seriously.

**The signing key is derived, and it barely moves.**

```
kDate    = HMAC("AWS4" + secret, "20260817")
kRegion  = HMAC(kDate,   region)
kService = HMAC(kRegion, "s3")
kSigning = HMAC(kService,"aws4_request")
```

Four HMAC-SHA256, and the inputs are the secret, the date, the region and the
service. Region and service are settled at `open()`
([ADR 0068](./0068-a-bucket-is-a-type-and-a-key-is-not.md)); the date changes
once a day. **So the derived key changes once a day**, and signing a request
after that is one HMAC over the string-to-sign, not five.

**The credentials themselves change on a schedule nobody here controls.** In
production on AWS, static keys are the exception: EC2, ECS and EKS hand out
temporary credentials through IMDS or IRSA, and they expire — typically in six
hours. A client that reads them once at startup runs perfectly all morning and
then answers 403 to everything, with nothing in the program able to say why.

## What was decided

**nilo owns the cache, the expiry and the derived key. The program owns
fetching.**

That is the split, and it is where it is because the hard part of credential
handling is not getting them — that is deployment-specific and short — but
caching them, noticing expiry, and doing both safely from several threads. That
part is generic, and pushing it out means every user writes it once, badly.

```zig
// the ordinary case: one line, nothing to think about
var store = try s3.open(io, gpa, .{
    .credentials = .{ .static = .{
        .access_key_id     = cfg.aws_access_key_id,
        .secret_access_key = cfg.aws_secret_access_key,
    } },
});

// on EKS or EC2: write how to fetch, and nothing else
fn fromIrsa(gpa: Allocator, io: std.Io) !s3.Credentials {
    return .{ .access_key_id = …, .secret_access_key = …,
              .session_token = …, .expires_at = … };
}
var store = try s3.open(io, gpa, .{ .credentials = .{ .fetch = &fromIrsa } });
```

`fetch` is called once at `open()` and again when the credentials are within a
margin of `expires_at`. **Lazily, on the request that notices** — there is no
background task. That is not an accident of implementation: ADR 0060 refused
automatic read-replica routing partly because it needed *"three background
tasks this module does not have, and getting the last one wrong is silent"*, and
this design needs none. The unlucky request pays the fetch; everything
concurrent with it keeps using the old key, which is still valid, because the
margin is why the refresh happens early.

`.static` is the same mechanism with `expires_at` null: fetched once, never
refetched.

## What is held, and what it costs to read

The cache holds the derived key rather than the credentials, keyed by the date
and a generation counter that the fetch bumps. The fast path reads it under a
shared `std.Io.RwLock`; a refresh takes it exclusively, once every six hours or
once a day.

**Do not be clever about that lock.** A seqlock or a generation-and-copy would
remove an uncontended `tryLock` pair — roughly 30 ns — from an operation whose
floor is a network round trip of 5–50 ms. That is **0.00015%**, and
[ADR 0001](./0001-dx-wins-below-the-10-percent-threshold.md) puts the bar at
ten per cent. The correct lock, held briefly, is the answer; the number is
written here so that nobody re-derives the temptation.

The saving that *is* real is the derived key itself: **four HMAC-SHA256 per
request removed**, on every S3 call the process ever makes. That is one of the
numbers this design owes `bench/RESULTS.md`, measured twice — once unloaded and
once at the gate — because
[a pool connection is a serial queue](../../CLAUDE.md) and per-operation savings
read differently under load.

## The payload hash, which is the other CPU decision

SigV4 also wants `x-amz-content-sha256`, and there the cheap answer is right
almost everywhere.

| | 10 MB | 100 MB |
|---|---|---|
| SHA-256 with SHA-NI (~2 GB/s) | ~5 ms | ~50 ms |
| without (~500 MB/s) | ~20 ms | ~200 ms |

That is CPU on a fiber, and
[ADR 0014](./0014-handlers-must-not-block-the-thread.md) is about exactly this:
a handler that holds its thread stops every request sharing it. Two hundred
milliseconds is near `block_warning_ms`'s default of 250 without crossing it —
the shape ADR 0048 found the hard way, where argon2 turned out to be 13 ms
rather than 100 and the detector therefore never fired.

**So: `UNSIGNED-PAYLOAD` when the endpoint is `https://`, a real SHA-256 when it
is `http://`.** The decision falls out of the endpoint scheme and there is
nothing to configure. Over TLS the hash buys integrity that TLS already
provides; over plaintext — a development SeaweedFS, which
[ADR 0068](./0068-a-bucket-is-a-type-and-a-key-is-not.md)'s runtime endpoint
makes reachable — it is the only integrity there is, and that path never carries
production load. A streamed `put` is always `UNSIGNED-PAYLOAD`, because hashing
what has not been read yet means reading it twice.

## Presigning, where credential expiry stops being invisible

A presigned URL signed with temporary credentials **dies when the credentials
do**, not when `X-Amz-Expires` says. Ask for seven days on an IRSA token with
six hours left and you get six hours, and nothing in an ordinary API would tell
you.

`presign` therefore returns `Presigned { url: Str, expires_at }` with the life
clamped to `min(requested, credential life)`. The number a caller stores in a
database or puts in an email is the number that is true. `presign_max` above
seven days is refused while compiling, because SigV4 refuses `X-Amz-Expires`
above 604,800 seconds and finding that out from AWS is worse than finding it out
from the compiler.

## Why not the alternatives

**Static credentials handed over at `open()`, and nothing else.** Shortest, and
closest to `Db` taking a URL. Refused because an expiring session token turns
every call into a 403 that no part of the program can attribute — a silent
failure, in a repository that spends its refusals on those.

**A raw provider callback, with no caching in nilo.** Pushes policy out, which
is usually right here. It pushes out the wrong half: the caller then has to
cache, check expiry and lock, and a caller who gets the locking wrong gets a
data race on a secret. What is left in `.fetch` after nilo keeps the cache is
short enough to be obviously correct.

**A built-in IMDS/IRSA provider chain**, as every AWS SDK has. The most
convenient thing possible, and it puts an HTTP client for `169.254.169.254`, an
STS response parser, and a refresher inside a module whose subject is object
storage — a piece of AWS surface to maintain forever, and the background task
ADR 0060 refused. A program that wants it writes `fromIrsa` and owns it.

**Caching credentials rather than the derived key.** One field simpler and it
throws away the four HMACs, which is the only per-request saving available in
signing at all.

**Always hashing the payload.** End-to-end integrity independent of TLS, and S3
rejects a mismatch. Refused at 5–200 ms of fiber CPU per `put` on the path that
carries production load, for a guarantee TLS already makes there.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes.

| Axis | Cost |
|---|---|
| Allocations per request | **None.** The derived key is 32 bytes held on the client; the string-to-sign is built in a stack buffer. A refresh allocates whatever `fetch` allocates, once per credential lifetime, not per request. |
| Memory per idle connection | **None.** One derived key and one credential record per client, not per connection and not per request. |
| Throughput and p99 | One HMAC-SHA256 and one shared `RwLock` per request, against a network floor — and **four HMACs removed** from what the naive version would cost. Zero CPU for the payload hash on every `https://` endpoint. To be measured, unloaded and at the gate. |
| Binary size | HMAC-SHA256 and SHA-256 out of `std.crypto`, which `std.crypto.tls.Client` already links for any program that reaches an `https://` endpoint. To be measured as part of the module's stripped `ReleaseFast` delta rather than separately. |

## Consequences

- **A program on EKS writes one function and gets correct rotation.** A program
  with static keys writes one struct literal. Neither writes a lock.
- **The refresh is lazy, so one request per credential lifetime is slower**, by
  whatever `fetch` costs. On IMDS that is a link-local round trip of about a
  millisecond, paid roughly four times a day.
- **A `fetch` that throws fails the request that called it**, and the previous
  key stays in place if it is still valid. A credential source that is down does
  not take the process with it until the old key actually expires.
- **The clock is the one the rest of the process uses.** SigV4 rejects a request
  whose `X-Amz-Date` is more than fifteen minutes from the server's, so a
  container with a drifting clock returns `Rejected` for everything —
  and the log says `RequestTimeTooSkewed` with the drift in it
  ([ADR 0068](./0068-a-bucket-is-a-type-and-a-key-is-not.md)) rather than
  leaving somebody to guess.
- **`.static` and `.fetch` are one mechanism with two entry points**, so nothing
  in the signing path has to know which was used. If a third source ever earns
  its place, it is a third tag and no new machinery.
