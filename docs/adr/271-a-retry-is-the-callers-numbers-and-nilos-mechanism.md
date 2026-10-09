# A retry is the caller's numbers and nilo's mechanism

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)
**Extends:** [ADR 061](./061-a-fitting-borrows-the-loop.md), the Target and its Options; [ADR 057](./057-percent-is-needed-by-two-layers.md), another file admitted to Core by being needed by two layers; [ADR 058](./058-most-of-an-s3-client-is-not-s3.md), what `Throttled` and `Unavailable` do.

## Context

`nilo_fetch` refused a retry policy in its header, the guide and the reference, on the ground that how many times, how long between and what counts as failure are facts about somebody else's service. No ADR held the refusal. That holds for the numbers. What the refusal left to every caller was the mechanism, and the guide's answer was three lines: a loop, a sleep and a `switch` on the errors worth another try. Those lines are where the traps are:

- A POST sent again charges twice unless it carries an `Idempotency-Key`.
- A sleep with no jitter sends every caller back at the same instant.
- `Retry-After` is read and capped by hand, or not at all.
- A loop with no budget turns a service's bad minute into three times its load, which is the thundering herd the refusal named as its reason.

tower's retry budget (retries up to a fraction of recent calls, 20% by default, with a floor), the AWS SDKs' retry quota, go-retryablehttp's reading of `Retry-After` and Stripe's clients putting a key on a POST before they retry it agree on the shape. `nilo_s3` had no retry at all, so its `Throttled` reached every caller where an AWS SDK tries three times, and `nilo_job` had the same arithmetic without the jitter (`Backoff`, which it owned, and `nilo_fetch` may not import).

## Decision

**A `Target` may declare `.retry`, and the numbers are the caller's while everything that makes retrying safe is nilo's.**

```zig
const Stripe = fetch.Target("stripe", .{
    .retry = .{ .times = 3, .mint_key = "Idempotency-Key" },
});
```

**The caller's, because they are facts about the service:** `times`; the `backoff` (`core.Backoff`, with `.jitter`); the `statuses` that mean "later" (429, 502, 503, 504 unless said otherwise; a 500 is left out, being as often a bug that will answer the same again); `retry_after_max_ms`; the `budget` (`percent`, `min_per_sec`, `window_s`); and `mint_key`, the header the service takes an idempotency key under. A `.retry` whose numbers cannot work (`times = 0`, a backoff from zero, a status that is not an error, a window of no seconds, a `mint_key` that is not a header name) is a Refusal naming the field, and `Retry.problem` is the one function that says so, run while compiling for a Target and at `open` for an `s3.Store`.

**The mechanism's, because it is the same for everybody and the traps are in it:**

1. **Only a call that can be sent again is.** GET, HEAD, PUT, DELETE, OPTIONS, TRACE and QUERY (`std.http.Method.idempotent`) always. A POST or PATCH only when the call carries an `Idempotency-Key` (the call's headers or the target's standing ones, any case) or the type names `mint_key`, in which case the mechanism mints one key per call (16 random bytes as hex, from the loop's generator) and sends it on every try. A POST with neither is one try, as it was. `mint_key` is the caller's claim that the service honours the header.
2. **A budget with no off switch.** tower's shape: a retry is allowed while the retries spent in the last `window_s` seconds stay within `percent` of the calls made in it plus `min_per_sec` a second (20%, 10 and 10 by default). Every call's first try is a deposit and every retry a withdrawal. When most calls fail the service sees the calls it was given plus that fraction, where three tries each would have sent it three times as many. There is no `budget = null`, because a retry with no budget is the multiplication this exists to stop; a caller who wants the allowance wide says `percent = 1000`. The counts are a `Ledger` in the Target, behind a spin lock whose critical section is a handful of integer operations and waits on nothing.
3. **Jitter**, full by default (`core.Backoff`, below), drawn from `std.Io.random`, which is a per-executor generator and not a syscall under the Engine.
4. **`Retry-After` is a floor on the wait**, in seconds or as an HTTP date, **capped at `retry_after_max_ms`** (5 seconds by default): a service that says an hour is waited for the cap and tried once more. An unparseable value is ignored.
5. **The route's deadline bounds the whole sequence, not each try.** Before a wait, `core.timeLeftOf(c)` is asked: a wait that is not shorter than the time left is not taken, and nothing is spent from the budget for it. Each try then runs under the time left at that moment (`Begin.route_left_ms`, already wired), so a retry never outlives the deadline. The wait is `io.sleep` on the fiber the call already holds, and **it holds no permit**: the client's and the target's are taken per try and given back before the sleep.
6. **What is retried:** a status in `statuses`, and a transport failure before an answer (a refused or reset connection, a closed one, a name that did not resolve, this call's own `TimedOut` or `Stalled`). `error.Canceled` never is: a shutdown is not the service's bad minute. The last answer is returned as itself when the tries run out (a 503 is a `Response`, as it always was), and the last error otherwise.

**It composes with the stale-connection replay and does not replace it.** `Exchange.begin`'s replay onto a fresh connection (ADR 058) is transport hygiene inside one try: nothing was answered, nothing reached anybody, and it costs no wait, no budget and no `times`. A retry is a decision between tries: a new `Exchange`, the service having answered or the call having failed. A reaped socket under a retried call is replaced inside the try and the retry never sees it.

**`Backoff` moves to `nilo_core`.** `nilo_job` owned it and `nilo_fetch` needs the same arithmetic and the same jitter; the two are siblings and may not import each other. ADR 057's test is that a file earns its place in Core by being needed by two layers, and this is the second file after `percent` to pass it for a reason a module could not have settled alone. It needs no loop, names no Engine and holds no randomness: `Backoff.delayMs(failed, random)` takes 64 bits as an argument, the way `nilo_id` takes its entropy, and the caller that has an `Io` (a worker, a client) draws them. `job.Backoff` and `job.Jitter` are re-exports, so `.{ .fixed_ms = 50 }` and `.{ .exponential = .{ .from_ms, .to_ms } }` compile as they did; `job.Retry.delayMs(failed)` still answers the un-jittered ceiling, and `jitteredMs(failed, random)` is what a worker schedules by. `.exponential` gained `jitter` (`.none`, `.full`, `.equal`), and `nilo_job`'s default is `.none`, so a kind written before it waits what it always waited; the todo entry "A backoff has no jitter" is closed by the option existing, and a kind that wants the herd spread says `.jitter = .full`. A `.fixed_ms` takes no jitter, because it is a promise; `.exponential` with the same `from_ms` and `to_ms` is a fixed wait that does.

**`nilo_s3` is put through it with `Store.Options.retry`.** `get`, `getRange`, `getIf`, `put`, `head`, `list`, `delete` and `copy` (and the small-source branch of `putMultipart`, which is a `put`) go round when they fail with `Throttled` or `Unavailable`, each try signed afresh, under the Store's shared budget. Null, the default, is one try, as before. **Not retried:** `stream` and `putStream`, whose reader the first try spends, and every call of the multipart protocol (initiate, each part, complete, abort) except the small-source branch's single `put`. Only `times`, `backoff` and `budget` mean anything there: S3's answers arrive as the two errors, so `statuses` and `mint_key` are not read, and `Retry-After`, which S3 does not use, is not either.

**A `.stream` body under a `.retry`.** No call a Target makes takes a reader (`Exchange.begin` from a Target is still the open item in `docs/todo.md`), so the two cannot meet through `fetch.Target` today, and the Refusal that this ADR meant to hold (a `.stream` body on a retrying Target is a compile error) has nothing to refuse yet. The guard is structural: `s3` does not route its reader-taking calls through the loop, and the test that holds it sends a `putStream` to a Store that retries and counts one request. **The Refusal is owed by whoever adds a streamed call to `Target`**, and is on that todo entry.

## What it costs

All four axes ([ADR 017](./017-the-trade-budget-has-four-axes.md)), measured as `bench/result/fetch.md` describes.

- **Allocations per request: none on a Target that declares nothing**, and none on one that does when the first try answers: the `Tries` state is 24 bytes on the stack and the `Ledger` is in the Target, and a test holds the two to the same number of arena chunks and the same bytes. A retry adds what a call adds, again: the header block and the body of each failed try stay in the Scope's arena. A minted key adds two arena allocations per call (32 bytes and the merged header list) and only for a POST or PATCH that carries none.
- **Memory per idle connection: 0 on a Target that declares nothing.** A Target with `.retry` holds a `Ledger` of 264 bytes once per service, not per connection; `Exchange` is 992 bytes before and after, and the 32-byte key is arena. The stack a retrying call reaches was not re-measured: the loop adds one frame holding a `Tries` and a copy of the `Call`, and a call's stack goes back with the handler.
- **Throughput and p99: unchanged without `.retry`**, which is resolved while compiling (`opts.retry == null` takes the call straight to `once`). With it, the first try pays a lock and an unlock of the spin lock and one `deposit`.
- **Binary size:** a program that dials out through `nilo_fetch` and a Target with **no** `.retry`: **+48 bytes** (965,216 to 965,264, stripped `ReleaseFast`, `zig build-exe -OReleaseFast -fstrip`, the program in the run). With a `.retry` that mints keys on the Target it uses: **+10,512 bytes** over that (967,152 to 977,664; the sleep, the generator, the date parser and the ledger are the bulk). A program that names no `.retry` pays the 48. The same row counts the sized read of `Exchange.take` below (+1,888), which is not the retry's.

## What was rejected

- **A retry loop per caller, as the guide taught.** It is the thing this replaces: three lines that retried a POST, with no jitter, no budget and no `Retry-After`.
- **Retrying any method.** The double charge is the reason the loop is dangerous, and there is no way to know from outside whether a POST is safe to send again. A key is how a service says so, and without one nilo sends the call once.
- **Retries without a budget, or a budget that can be switched off.** Every caller who needs the herd stopped needs it in the minute when the herd is the problem, which is not the minute to have been told to configure it. The floor (`min_per_sec`) is what keeps a quiet service retryable, so the budget does not cost the case a switch would have served.
- **A global, client-level policy.** The numbers are facts about a service, and a client is shared by every service in the program; a target is the sentence "Stripe is this URL and gets this many tries" already ([ADR 061](./061-a-fitting-borrows-the-loop.md)). The budget is per target for the same reason: one service's bad minute must not spend the allowance of another.
- **A per-call `.retry`.** It would put the numbers at every call site, which is the repetition the type exists to remove, and make the budget's owner ambiguous.
- **Giving up when `Retry-After` is past the cap**, and returning the 429 to the caller. Arguably kinder to the service, and rejected for a smaller reason: the caller who set a cap has said how long they are willing to wait, a second try at the cap costs one budget unit, and the route's deadline already ends the sequence when the cap is longer than the request can afford. It is a one-line change if a service punishes an early return.
- **Holding the permit across the wait.** It would keep the Exchange machinery simple (retry inside `begin`, with the same permit and deadline, as the stale replay does) and would turn a service's bad minute into a queue for every other call through the same gate. The loop is outside the permit instead.
- **Retrying inside `Exchange.begin`.** An Exchange is one call held open, and its body is read by the caller; a retry belongs to a call whose body the module reads itself (`sendAs`, and `nilo_s3`'s round trips).
- **`Backoff` written twice, in `nilo_job` and `nilo_fetch`.** Two sets of arithmetic and two jitters that disagree eventually; ADR 057's argument for `percent`, unchanged.
- **Jitter on by default in `nilo_job`.** It would change the timing of every kind that exists, silently. `nilo_fetch`'s default backoff is jittered because nothing before it existed to change.
- **Retrying a 500 by default.** The AWS SDKs do and Stripe's clients do for a keyed POST; here a 500 is as often a deterministic bug as a hiccup, and `statuses` is one field for the service that means it.

## Open

- A circuit breaker (the roadmap's other entry under this direction) is still unbuilt, and is what stops a service that is *down* rather than slow from costing every call its timeout.
- `Retry-After` from S3-compatible stores (some send it on a 503) is not read by `nilo_s3`, because its errors carry no headers.
- The stack a retrying call reaches, and a retry sequence at the pool, were not measured under load.
