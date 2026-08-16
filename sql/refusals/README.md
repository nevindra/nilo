# sql/refusals

The same idea as [`refusals/`](../../refusals/README.md), for the SQL module.
Read that one for how to add a file and what a failure means; the only
differences are here.

**They import `zfast_sql`, not `zfast`.** Each one is a query written wrong on
purpose against a Row declared in the same file, so a reader can see the
mistake and the thing it contradicts without opening anything else.

**They hang off `zig build test-sql`, not `zig build test`**, and the table is
`sql_refusals` in `build.zig` rather than `refusals`. The framework's loop does
not pay for a module it does not import ([ADR 0039](../../docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)).

`zig build refusals-sql` runs only these.

## Why this module has so many of them

Every comptime check in `sql/` answers a question a database would otherwise
answer at run time, on somebody else's schedule. `agee` instead of `age` is a
compile error here and a 500 at three in the morning everywhere else — but only
while the message stays the one that names the near miss. That wording is the
feature, so it is the thing held down.
