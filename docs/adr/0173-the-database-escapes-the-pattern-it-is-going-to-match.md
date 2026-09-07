# The database escapes the pattern it is going to match

`.email = .{ .like = text }` binds the caller's text unchanged. Nothing is
smuggled — it is a bound parameter — and it is still the wrong answer: a user
typing `%` matches far more than they should, and one typing `_` matches a
character they should not. No error, no log line, and it only shows up on the
input nobody tried.

Every caller ends up writing the same escape, and most of them do not.

## Why it stayed open for a cycle

The roadmap named the fix — `contains`, `starts_with` and `ends_with`, which
build the pattern *and* escape it — and then named the blocker:

> that means an allocation per condition in a module whose whole claim is that
> a statement costs none

That is true of building the pattern **on this side**. It is not true of the
feature, and the difference is where the work happens.

```sql
"name" ILIKE '%' || replace(replace(replace($1, '\', '\\'), '%', '\%'), '_', '\_') || '%' ESCAPE '\'
```

The pattern is assembled and escaped **inside the statement**. What binds is the
caller's own text, unchanged, so this costs exactly what an `=` on the same
column costs: nothing. `replace`, `||` and `ESCAPE` are all standard, so both
Dialects write the same shape.

**The blocker was a sentence about one mechanism**, which is precisely the
failure mode [ADR 0063](./0063-a-handlers-stack-is-per-connection.md) already
recorded: *a requirement written as one mechanism reads as a blocker; written as
what it has to catch, it reads as a choice.* Written as *the `%` in the
caller's text has to match itself*, the answer is three `replace` calls and no
allocation at all.

## The order of the three is load-bearing

The escape character is doubled **first**. Doubling `\` after putting one in
front of `%` would turn that escape into a literal backslash and let the `%`
through — which is the original bug, arrived at through the fix. There is a
test that asserts the order of the two substrings in the generated SQL, and a
live test that searches for `a\b` and gets one row.

## Twelve names out of three rows

Three shapes, `i` in front to fold case, `not_` in front to negate. The
spelling is the one `like`/`ilike`/`not_like` already set.

The negations are not padding. [ADR 0058](./0058-a-set-operation-over-one-table-is-a-condition.md)'s
argument that `EXCEPT` needs no mechanism rests on **every leaf having a
negation**, and an operator family arriving without its own would quietly break
a decision that is on the record. There is a test that walks all twelve names.

Both halves of a pattern comparison are checked: the column has to hold text,
because Postgres would otherwise cast a number to text and compare the digits it
happens to print; and the value has to be text, because there is nothing else to
build a pattern out of.

## SQLite refuses the case-sensitive half

Its `LIKE` folds ASCII case, and cannot be told not to by a statement —
`PRAGMA case_sensitive_like` is a property of the connection. So honouring
`contains` there would make the answer depend on how the database was opened
rather than on what the query says.

`icontains` is that database's plain `LIKE`, and `contains` is a Refusal naming
the dialect. The message names the operator that works, because the fix is one
letter. That is the seam refusing rather than lying, which is the standard
[ADR 0061](./0061-the-second-dialect-is-the-test-of-the-seam.md) set for
`insertMany` and `.lock`.

## A gap this found and did not close

`.ilike` writes the word `ILIKE` on **both** Dialects, because the operator
table in `where.zig` predates the second one and spells its own SQL. SQLite has
no `ILIKE`, so that is a runtime syntax error from a statement that compiled.
It is left alone here rather than changed under cover of another feature — the
new family goes through `dialect.pattern` precisely so it does not inherit the
problem — and it is written down in the roadmap as its own entry.

## Against ADR 0018's four axes

- **Allocations per request: zero**, which is the entire point of the design
  and the reason it is not the design the roadmap assumed.
- **Memory per idle connection: zero.**
- **Throughput and p99:** three `replace` calls per matching row, run by the
  database on a parameter rather than on a column. Unmeasured, and it is the
  database's cost rather than nilo's. A leading `%` already rules out the index
  on `contains`; `starts_with` loses it to the bound parameter rather than to
  the `replace`, since Postgres cannot prove a prefix it has not seen.
- **Binary size: zero for a program that writes none of the twelve.**

## Consequences

- A `Dialect` owes one more declaration, `pattern`, which returns `null` for a
  combination it cannot spell.
- The roadmap entry moves from *Waiting on: a design* to gone, and its lesson —
  that the allocation was an assumption about one implementation — goes to
  `docs/history.md`.
