# The Autobahn suite

`wstest` is what every implementation of RFC 6455 is measured by. Until this
directory existed, nilo's WebSocket had never been run against it: every framing
test under `http/` was written from the RFC by whoever wrote the framing, which
by [ADR 0033](../../docs/adr/0033-a-guard-is-not-a-guard-until-it-has-been-seen-to-fail.md)
makes the close-code and UTF-8 rules guards only ever seen to pass.

```
bash bench/autobahn/run.sh
CASES='6.*' bash bench/autobahn/run.sh     # one family, when chasing a fix
```

It builds the server, starts it, drives the suite at it from the container the
suite ships in, and prints what is not `OK`. The last run and what it said is in
[`bench/result/http.md`](../result/http.md).

## What is here

| file | what it is |
|---|---|
| `server.zig` | an echo server, one route, the loop out of the guide |
| `fuzzingclient.json` | the spec: every case except `permessage-deflate` |
| `run.sh` | build, start, drive, summarise |
| `summarize.py` | `index.json` in the twenty lines worth reading |
| `reports/` | what `wstest` wrote. Not committed |

## Why it is a script and not a build step

It needs Docker. That puts it where `zig build smoke-tls -Dnetwork` is — off
`zig build test`, because a suite that cannot run without something the machine
may not have is a suite that reports a missing dependency as a failure.

`run.sh` exits non-zero when anything is `FAILED` or `UNIMPLEMENTED`, so it can
be branched on without reading its output.

## Reading the verdicts

`OK` and `INFORMATIONAL` need nothing. The two that do:

- **`FAILED`** is nilo's, always. Open `reports/nilo_case_<n>.html`, which has
  the frames both ends sent.
- **`NON-STRICT`** is behaviour the RFC allows and the suite would rather you
  did differently. It is a decision to record, not a bug to fix — but it is a
  decision, so it has to be recorded somewhere rather than shrugged at. The four
  standing ones are in `bench/result/http.md`.

## What the server is not

It is not a benchmark, despite living under `bench/`. It has one route, no
controls and no numbers, because a conformance run answers yes or no about 301
cases and anything measured beside them would be meaningless.

Its `max_message` is 16 MiB against the framework's 16 KiB, which is reading the
suite rather than being generous: cases 9.1–9.6 send messages up to 16 MiB, and
a server that refuses them with a 1009 is *correct* and still recorded as a
failure, because the case is asking whether the frame was reassembled. The
ceiling is the harness's, not a recommendation.
