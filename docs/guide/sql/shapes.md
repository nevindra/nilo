# A Row with more in it

A list screen almost never shows one table. An invoice is listed with its customer's name, opened with its lines, and summed by customer on the dashboard. None of that needs `db.raw`: the Row you read into can say it, and the call you write stays `db.select`, `db.page` or `db.find`. It follows [reading](./reading.md).

A Row can say three more things about itself:

- **a parent**: a field whose type is a Row of another table, joined in the same statement;
- **children**: a field `[]const C` of rows that point back at this one, read by one more statement for every row at once;
- **a sum**: `nilo_aggregate`, which makes the Row one row per group.

All three go on a narrower Row, one with `pub const nilo_table = <TheTablesRow>`. The Row that describes the table stays the table's columns and nothing else, because that is what migrations read ([ADR 218](../../adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)).

## The tables

The links come from `.references`, which the tables already declare for their foreign keys:

<!-- compiles -->
```zig
const Customer = struct {
    pub const nilo_table = .{ .name = "customers", .key = .id };
    id: i64,
    name: Str,
    region: ?Str,
};

const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .key = .id };
    id: i64,
    full_name: Str,
};

const Invoice = struct {
    pub const nilo_table = .{
        .name = "invoices",
        .key = .id,
        .references = .{
            .customer_id = .{ Customer, .id },
            .owner_id = .{ Staff, .id },
            .approver_id = .{ Staff, .id },
        },
    };
    id: i64,
    customer_id: i64,
    owner_id: i64,
    approver_id: ?i64,
    total: i64,
    year: i32,
};

const InvoiceLine = struct {
    pub const nilo_table = .{
        .name = "invoice_lines",
        .key = .id,
        .references = .{ .invoice_id = .{ Invoice, .id } },
    };
    id: i64,
    invoice_id: i64,
    sku: Str,
    qty: i32,
};
```

## A parent

A field whose type is a Row of another table is the row a reference points at:

<!-- compiles -->
```zig
const CustomerName = struct {
    pub const nilo_table = Customer;
    name: Str,
};

const StaffName = struct {
    pub const nilo_table = Staff;
    full_name: Str,
};

const InvoiceCard = struct {
    pub const nilo_table = Invoice;
    pub const nilo_via = .{ .owner = .owner_id, .approver = .approver_id };
    id: i64,
    total: i64,
    customer: CustomerName,
    owner: StaffName,
    approver: ?StaffName,
};

fn invoices(db: *sql.Db, c: *nilo.Ctx, search: []const u8) !sql.Db.Page(InvoiceCard) {
    return db.page(InvoiceCard, c, .{
        .where = .{ .customer = .{ .name = .{ .icontains = search } } },
        .order = .{ .customer = .{ .name = .asc }, .id = .desc },
        .limit = 20,
    });
}
```

```sql
SELECT "invoices"."id" AS "id", "invoices"."total" AS "total",
       "customer"."name" AS "customer.name", "owner"."full_name" AS "owner.full_name",
       ("approver"."id" IS NOT NULL) AS "approver.#", "approver"."full_name" AS "approver.full_name",
       count(*) OVER () AS "#total"
FROM "invoices"
JOIN "customers" AS "customer" ON "customer"."id" = "invoices"."customer_id"
JOIN "staff" AS "owner" ON "owner"."id" = "invoices"."owner_id"
LEFT JOIN "staff" AS "approver" ON "approver"."id" = "invoices"."approver_id"
WHERE "customer"."name" ILIKE '%' || … || '%' ESCAPE '\'
ORDER BY "customer.name" ASC, "id" DESC LIMIT 20
```

**The join is read out of the schema.** One `.references` from `invoices` to `customers` is the join for `customer`. Two pointing at `staff` is a compile error until `nilo_via` says which column each field follows, because which one `staff` means is a question about meaning. `nilo_via` can also name a column that no `.references` covers, and then it joins to the other table's key.

**`?` means the parent can be missing, and the schema has to agree.** `approver_id` may be null, so `approver` has to be `?StaffName`, and it is a `LEFT JOIN`. `customer_id` is never null, so `customer: ?CustomerName` is refused as well: the `?` would be a branch nobody takes. A missing approver is `null`, not a `StaffName` full of nulls.

**A condition and an order reach into a parent through its field**, `.customer = .{ .name = … }`. They take the same operators a column of the table does. A parent can have parents of its own; nest them the same way.

A parent never changes how many rows come back, because a reference points at one row or none. So `.limit = 20` is still twenty invoices, and `db.count` over `InvoiceCard` joins only the parents its condition names.

## Children

A field `[]const C`, where `C` reads a table that points back here, is every row that points at this one:

<!-- compiles -->
```zig
const LineBrief = struct {
    pub const nilo_table = InvoiceLine;
    sku: Str,
    qty: i32,
};

const InvoiceDetail = struct {
    pub const nilo_table = Invoice;
    id: i64,
    total: i64,
    customer: CustomerName,
    lines: []const LineBrief,
};

fn invoice(db: *sql.Db, c: *nilo.Ctx, id: i64) !?InvoiceDetail {
    return db.find(InvoiceDetail, c, id);
}
```

**Children are never joined.** Once the invoices are read, one more statement reads the lines of all of them at once, so a page of twenty invoices is two statements, not twenty-one:

```sql
SELECT "invoice_lines"."sku" AS "sku", "invoice_lines"."qty" AS "qty", "#k"."key" AS "#parent"
FROM unnest($1::int8[]) WITH ORDINALITY AS "#k"("value", "key")
JOIN "invoice_lines" ON "invoice_lines"."invoice_id" = "#k"."value"
ORDER BY "#k"."key", "invoice_lines"."id"
```

Each invoice gets its own lines, in the lines' key order, and an invoice with none gets an empty slice. `.limit` has already counted the invoices by then, so a page is twenty invoices however many lines they hold.

The Row has to read `id`, the column the lines point at, because that is how each line finds its invoice. Leaving it out is a compile error that says so.

**Two statements are two snapshots unless a transaction makes them one.** Outside a `Tx`, a line added between the two can show up under an invoice read before it existed. Inside one, `tx.select` and `tx.find` are the same calls and cannot see that.

Children go one level deep. A child can have parents, which are joined into the second statement, but it cannot have children of its own. `db.stream` refuses a Row with children, because a stream never holds the rows the children would be handed to.

### An order, a condition, and a count

`pub const nilo_children` says the rest, keyed by the field:

<!-- compiles -->
```zig
const InvoiceSummary = struct {
    pub const nilo_table = Invoice;
    pub const nilo_children = .{
        .lines = .{ .order = .{ .qty = .desc }, .where = .{ .qty = .{ .gt = 0 } } },
        .line_count = .{ .count = InvoiceLine },
        .bulk_lines = .{ .count = InvoiceLine, .where = .{ .qty = .{ .gte = 100 } } },
    };
    id: i64,
    lines: []const LineBrief,
    line_count: i64,
    bulk_lines: i64,
};

fn busiest(db: *sql.Db, c: *nilo.Ctx) ![]InvoiceSummary {
    return db.select(InvoiceSummary, c, .{
        .where = .{ .line_count = .{ .gt = 0 } },
        .order = .{ .line_count = .desc },
        .limit = 20,
    });
}

comptime {
    _ = sql.childrenFor(InvoiceSummary, "lines");
}
```

**A list takes `.order` and `.where`.** The order is columns of the child's table, and the child's key still comes last, so two lines with the same `qty` come back the same way every time. A key minted as a v7 id matches the order rows were made in, which is the order a user dragging lines around has just changed, so a list with a `position` column wants `.order = .{ .position = .asc }`.

**A count is an `i64` field that reads no child.** It is a subquery on each row, in the same statement:

```sql
(SELECT count(*) FROM "invoice_lines" AS "#c" WHERE "#c"."invoice_id" = "invoices"."id") AS "line_count"
```

So a badge that says *12 lines* costs one index lookup per invoice on the page, not every line read into memory to take `.len`. Put an index on the column that points back: Postgres does not make one for a foreign key. A count can be ordered by and named in `.where` like a column, and it can sit on a parent's Row too.

Both `.where`s here are written with their values in them, because they are part of the Row rather than of a request: a value, `null`, `.eq`, `.ne`, `.gt`, `.gte`, `.lt`, `.lte`, `.in` and `.not_in`. A filter that comes from the request goes in the read's own `.where`. A `.limit` on a list is refused, because one statement reads the children of every row and a limit there would cut across rows.

## A group

`nilo_aggregate` names the fields that are computed. Every other field is a key of the group:

<!-- compiles -->
```zig
const ByCustomer = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{
        .invoices = .count,
        .revenue = .{ .sum = .total },
        .largest = .{ .max = .total },
        .mean = .{ .avg = .total },
    };
    customer: CustomerName,
    invoices: i64,
    revenue: i64,
    largest: i64,
    mean: f64,
};

fn bestCustomers(db: *sql.Db, c: *nilo.Ctx, year: i32) ![]ByCustomer {
    return db.select(ByCustomer, c, .{
        .where = .{ .year = year, .revenue = .{ .gt = 1_000_000 } },
        .order = .{ .revenue = .desc },
        .limit = 10,
    });
}
```

```sql
SELECT "customer"."name" AS "customer.name", count(*) AS "invoices",
       sum("invoices"."total")::int8 AS "revenue", max("invoices"."total") AS "largest",
       avg("invoices"."total")::float8 AS "mean"
FROM "invoices" JOIN "customers" AS "customer" ON "customer"."id" = "invoices"."customer_id"
WHERE "invoices"."year" = $1
GROUP BY "customer"."name"
HAVING sum("invoices"."total") > $2
ORDER BY "revenue" DESC LIMIT 10
```

`year` is not a field of `ByCustomer`, and it is in the condition anyway. **A grouped Row's condition names the table's columns, not only the Row's**, because the rows being grouped are the table's. A term on a column or a parent's column is a `WHERE`, applied before grouping; a term on an aggregate field is a `HAVING`, applied after. Nothing at the call site says which is which, because the Row already does.

The words are `.count`, `.{ .count = .col }`, `.{ .count_distinct = .col }`, `.{ .sum = .col }`, `.{ .min = .col }`, `.{ .max = .col }` and `.{ .avg = .col }`. **What each field has to be is a rule, and a wrong type is a compile error that names the right one:**

| word | field |
|---|---|
| any count | `i64`, never null |
| `sum` | `i64` over whole numbers, `f64` over floating ones, the column's own type over a `Decimal` |
| `min`, `max` | the column's type |
| `avg` | `f64` |

A field is `?` exactly when the answer can be null: over a nullable column, where a group of nulls sums to null. `db.page` of a grouped Row counts groups, and so does `db.count`.

### An aggregate over some of the rows

An entry can carry a `.where`, which narrows only the rows that one aggregate reads. It is `FILTER (WHERE …)`, on both databases:

<!-- compiles -->
```zig
const RevenueByCustomer = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{
        .this_year = .{ .sum = .total, .where = .{ .year = 2026 } },
        .large = .{ .count = .id, .where = .{ .total = .{ .gte = 1_000_000 } } },
    };
    customer: CustomerName,
    this_year: ?i64,
    large: i64,
};

comptime {
    _ = sql.selectFor(RevenueByCustomer, @TypeOf(.{}));
}
```

```sql
sum("invoices"."total") FILTER (WHERE "invoices"."year" = 2026)::int8 AS "this_year",
count("invoices"."id") FILTER (WHERE "invoices"."total" >= 1000000) AS "large"
```

The values go into the statement as written, with the same words a children entry's `.where` takes, over the table's columns. **A column with a `.references` is also a way into the row it points at**, which is how a count by a state's category reads when the state is another table:

<!-- compiles -->
```zig
const RevenueByRegion = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{
        .west = .{ .sum = .total, .where = .{ .customer_id = .{ .region = "west" } } },
        .unapproved = .{ .count = .id, .where = .{ .approver_id = null } },
    };
    year: i32,
    west: ?i64,
    unapproved: i64,
};

comptime {
    _ = sql.selectFor(RevenueByRegion, @TypeOf(.{}));
}
```

```sql
sum("invoices"."total") FILTER (WHERE "#f.customer_id"."region" = 'west')::int8 AS "west"
… JOIN "customers" AS "#f.customer_id" ON "#f.customer_id"."id" = "invoices"."customer_id"
```

The table reached is joined once, however many aggregates read it, and a reference that may be null is a `LEFT JOIN`, so a row with none still counts for the rest. References chain: `.org_unit_id = .{ .customer_id = .{ .kind = .government } }` is two joins. **A filtered `sum`, `min`, `max` or `avg` is `?` whatever its column**, because a customer with no invoice this year has nothing to sum. A filtered count is zero there. To count the rows that match, name a column that is never null, the key usually: `.{ .count = .id, .where = … }`.

## A total

A grouped Row with no keys at all is one row over everything the condition matched. It is read with `db.exactlyOne`, which answers the Row itself rather than a list or a `?`:

<!-- compiles -->
```zig
const Totals = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{ .invoices = .count, .revenue = .{ .sum = .total } };
    invoices: i64,
    revenue: ?i64,
};

fn totals(db: *sql.Db, c: *nilo.Ctx, year: i32) !Totals {
    return db.exactlyOne(Totals, c, .{ .where = .{ .year = year } });
}
```

`revenue` is `?i64` here even though `total` is never null: a year with no invoices still answers one row, and the sum of no rows is null. `invoices` is zero then.

## What is still `raw`

A shaped Row is an answer, so it is read and never written: an insert, an update or a `.lock` through one is refused, and so is `db.raw` into one. `DISTINCT`, window functions, CTEs, a join through a condition rather than a reference, and an aggregate over an expression are still [past one table](./raw.md).
