# leaf_json

What a response holding a `sql.Uuid` costs, before and after
[ADR 0182](../../docs/adr/0182-a-leaf-that-says-what-it-is-can-be-carried.md).
The run behind that ADR and the entry in
[`bench/result/http.md`](../../bench/result/http.md).

```
zig run -O ReleaseFast --dep nilo_json_writer -Mroot=spike/leaf_json/main.zig \
  -O ReleaseFast --dep nilo_core -Mnilo_json_writer=http/json.zig \
  -O ReleaseFast -Mnilo_core=core/core.zig
```

Run from the repository root, not from this directory.

**`-O ReleaseFast` before every `-M`, and that is not decoration.** Given once
it applies to the root module only, so `http/json.zig` builds in Debug and the
first reading of this had 1,989ns against 1,423ns — a ratio that survived and
absolutes eight times the truth.

Unlike [`union_json/`](../union_json/) this **imports** `http/json.zig` rather
than copying it, which is what the module flags above buy. So the numbers are
about the exact bytes the framework ships, and a change to the writer changes
them. It also asserts the two paths produce identical output before it times
either — this file's whole contract is that the generated writer is
byte-for-byte `std.json`, and a benchmark comparing two different outputs is
worth nothing.

## What it puts against what

One contact row out of the reporting port's partner list: 305 bytes, three
uuids, four strings, a bool and an integer.

| | what it isolates |
|---|---|
| **A** `std.json` on the whole value | what nilo sent before. `covers` refused any type with `jsonStringify`, and it is answered for the *whole* value — so one uuid sent every string beside it to `std.json` too |
| **B** the generated writer, leaf handed to `std.json` | after |
| **C** the same struct with the uuids already text | the control. The ceiling B is chasing, and it says how much of B's remaining cost is the leaf itself |

C is the row that stops the headline being over-read: the gap between B and C
is three `jsonStringify` calls, and no amount of work on the writer closes it.
The type is `nilo_id`'s and `http/` never learns it exists (ADR 0046).

`Uuid` here is a four-byte stand-in carrying the same two declarations the real
one does — `jsonStringify` and `nilo_openapi` — because the contract between the
modules *is* those two declarations and nothing else. `http/` may not import
`sql/`, and a spike that reached around the layering would be measuring
something the framework cannot do.
