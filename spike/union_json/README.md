# union_json

What a tagged union in a response costs, and what it would cost on nilo's
generated writer. The run behind
[ADR 0085](../../docs/adr/0085-a-type-says-how-its-json-is-spelled.md) and the
entry in [`bench/result/http.md`](../../bench/result/http.md).

```
zig run main.zig -O ReleaseFast
```

No build file and no dependency: it copies `writeString` and `nextEscape` out of
[`http/json.zig`](../../http/json.zig) verbatim, so it needs nothing but `std`.
That is also its one weakness — it is a *copy*, so a change to the escaper here
does not change it there, and the numbers below are about the shape of the
writer rather than about the exact bytes the framework ships today.

## What it puts against what

The payload is Photon's alert rule with its `Condition` union live: 374 bytes,
one long string, one float, two enums.

| | |
|---|---|
| **A** | `std.json`, externally tagged. What nilo sent before ADR 0085 |
| **B** | generated writer, externally tagged. The same bytes, so it isolates covering unions at all |
| **C** | generated writer, internally tagged. The feature |
| **D** | **the control.** The same payload with the union flattened into a plain struct by hand, on the generated writer |
| **E**, **F** | a 104-byte payload through A and C, because a win that only shows up on long strings is a win about strings |

**D is the row that matters most.** It is what somebody writes today to stay on
the fast path, and it is the ceiling B and C are chasing. C landing on it says
the union support is free; C landing above it would have said the encoding costs
something.

Five interleaved pairs of 200,000 iterations per run, because one run each is
how this repository has published a win it did not earn
([CLAUDE.md](../../CLAUDE.md)). Interleaved rather than grouped, so a thermal
drift moves every row together instead of moving the first one.

## What it said

Across six runs: **A 248–317ns, B 86–93, C 88–95, D 88–94**, and E 81–88 against
F 24–25. So 2.8× to 3.2× on the large payload and 3.4× to 3.5× on the small one.

It is a band rather than a figure because `std.json`'s own row moves by 28%
between runs while the other three sit inside 8ns of each other. Quoting the
best pair would have claimed 3.6×.
