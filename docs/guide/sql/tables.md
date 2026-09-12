# A table is a struct

The first page of [Talking to a database](./README.md): the Row, and what
its fields may be. Everything the rest of the guide reads and writes is one of
these.

<!-- compiles -->
```zig
const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: nilo.Str,
    name: nilo.Str,
    age: i32,
    orders: i32,
    created_at: sql.Timestamp,
};
```

The table name is written out, never guessed. `User` → `users` looks clever
until `Category`, and every framework that guesses ends up shipping a list of
irregular nouns.

`.name = "app.users"` is a schema and a table, quoted as two identifiers and
introspected in that schema. A bare name is whatever `search_path` resolves
to, which is what it has always meant. One dot, with something on either side
— anything else is a compile error, because `a.b.c` names a relation nobody
created and Postgres would only say so at run time.

`.key` names the column that identifies a row, and defaults to `id` when
there is a field called that.

## Money

`sql.Decimal` reads a `numeric` column, and it holds **text**:

<!-- compiles: body -->
```zig
const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,        // numeric
};

const invoice = (try db.find(Invoice, c, 1)).?;
const total = invoice.total.text;                    // "1234.56"
_ = try db.insert(Invoice, c, .{ .total = sql.Decimal{ .text = "9.99" } });
```

There is no `.add` and no `.round`, which is the same line `sql.Timestamp`
holds: **a type here carries a value and knows how to write itself; it does
not calculate.** Decimal arithmetic is a library and a bigger one than it
looks — rounding modes alone are a standard. What this owes you is that the
digits which went in are the digits that come out, which a live test checks
with a value twenty-nine significant digits wide.

Comparisons are numeric, not textual: `.{ .total = .{ .gt = sql.Decimal{ .text = "50" } } }`
finds `100.00` and not `9.99`.

**In a JSON body it is a string**, `"1234.56"` rather than `1234.56`. A bare
number is exact on the wire and stops being exact in the consumer, where
`JSON.parse` answers a double — the `f64` the column type was chosen to avoid,
handed over silently on the far side of the network. A string arrives intact
([ADR 0050](../../adr/0050-a-numeric-is-digits-and-a-string-in-json.md)). It is
also the only form that can carry `nan` and `inf`, which Postgres allows and
JSON has no number syntax for.

Unlike `sql.Json(T)` it **streams**: in a `Borrowed` row the field is a plain
`[]const u8`, so `db.stream` still allocates nothing per row.

## Lists

An array column is a plain Zig slice, with nothing wrapped round it:

<!-- compiles -->
```zig
const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tags: []const nilo.Str,    // text[]
    scores: ?[]const i32,      // integer[], and the column may be null
    owners: []const sql.Uuid,  // uuid[]
};
```

Reading one is a Zig `for` and nothing else:

<!-- compiles: body -->
```zig
const ticket = (try db.find(Ticket, c, 1)).?;
for (ticket.tags) |tag| std.log.info("{s}", .{tag.view()});
```

`[]const u8` is text and was spoken for long before arrays were, so a list of
text is `[]const Str` or `[]const []const u8` and never `[]const u8`. Writing
one is the shape you would write anyway:

<!-- compiles: body -->
```zig
_ = try db.insert(Ticket, c, .{ .tags = &.{ "urgent", "billing" }, .scores = null });
```

Two things about arrays that Postgres allows and a Zig slice cannot hold:

- **A NULL among the elements.** Any Postgres array may have one, and there is
  no column definition that forbids it. Read into `[]const Str` that fails the
  request; read the column as `[]const ?nilo.Str` and the nulls come through.
- **More than one dimension.** A column declared `integer[]` will happily
  store `ARRAY[[1,2],[3,4]]`. A slice is one deep, so that fails the request
  too.

Both used to take the process down inside the driver
([ADR 0051](../../adr/0051-an-array-is-a-slice-and-a-slice-is-one-deep.md)).

`[]const sql.Uuid` is `uuid[]`, and it reads, writes and works as an `.in`
list — which is what stops an N+1 on a page that attaches children to its rows
([ADR 0145](../../adr/0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)).

An array is judged **exactly** at startup: an `int4[]` column reads into a
`[]const i32`, and not into a `[]const i64` the way a scalar `int4` reads into
an `i64`. And a Row that reads an array cannot be `db.stream`ed, for the same
reason a `Json` column cannot — see [Streaming](./reading.md#streaming-a-result-set-too-big-to-hold).

## A column type of your own

The types above are the ones this module chose to know about, and Postgres has
hundreds more — `interval`, `inet`, `money`, `tsvector`, everything an
extension installs. The list is not closed:

<!-- compiles: body -->
```zig
const Money = sql.AsText("money");

const Sale = struct {
    pub const nilo_table = .{ .name = "sales", .key = .id };

    id: i64,
    amount: Money,           // money
};

const sale = (try db.find(Sale, c, 1)).?;
const shown = sale.amount.text;    // "$1,234.56", as Postgres printed it
```

`sql.Interval` and `sql.Inet` are two of those written out for you, and
`sql.Decimal` is a third — there is no special case underneath any of them.

A type that wants **structure** rather than text writes the protocol itself.
Three declarations make anything a column type:

```zig
const Cents = struct {
    value: i64,

    pub const nilo_column = "numeric";

    pub fn nilo_read(text: []const u8, arena: std.mem.Allocator) !Cents {
        … parse "12.34" into 1234 …
    }

    pub fn nilo_write(self: Cents, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{d}.{d:0>2}", .{ … });
    }
};
```

It travels as the text Postgres prints — `"amount"::text` on the way out,
`$1::numeric` on the way in — which is the one representation every Postgres
type has, and it is why this module does not need to know what your type is
([ADR 0055](../../adr/0055-a-column-type-can-come-from-outside-this-module.md)).
The column is checked against the table at startup like any other, and the
type works everywhere a column type works: conditions, `.set`, `insert`, a
batch.

Two mistakes stop at compile time — one of `nilo_read`/`nilo_write` without
the other, and both without a `nilo_column`. One thing is still closed: an
**array** of one is not read, the same boundary `[]const sql.Decimal` has
always had.
