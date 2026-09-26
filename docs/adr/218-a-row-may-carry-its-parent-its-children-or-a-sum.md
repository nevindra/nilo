# A Row may carry its parent, its children, or a sum

**Status:** accepted
**Topic:** [sql-query](../design/sql-query.md)

## Context

[ADR 036](./036-the-shape-of-a-query-is-settled-while-compiling.md) drew the module's line in one sentence, *one table, conditions that filter rows*, and sent everything past it to `db.raw`. Two properties are what that line actually protects. **The column list does not change**, so the Row still describes the answer, the argument [ADR 052](./052-a-set-operation-over-one-table-is-a-condition.md) made about a set operation. **The row count does not change**, so `.limit = 20` still means twenty of the thing being listed; a join to a one-to-many multiplies the rows on one side and the pagination goes wrong in a way that shows up as *some rows never appear*.

`EXISTS` was the first thing shown to sit on this side of the line despite looking like a join: it is a yes or no per row of the table being read, so it touches neither property, and `EXISTS (SELECT 1 FROM … WHERE …)` is the same eight words on both Dialects, where a join is where they disagree most. Joins, nested rows and aggregates stayed past it, in one roadmap entry, on the grounds that each breaks one of the two.

That was true of joins and aggregates as a query builder spells them, and it was measured against a module nobody had used for a whole application yet. Two applications have been built on it since, and every statement either of them hands to `db.raw` was read and sorted:

| | raw statements | one table | a join to one row | an aggregate | a join to many | CTE, union, lateral, window |
|---|---|---|---|---|---|---|
| nodeflux-os `backend-zig` (Postgres) | 178 | 58 | 46 | 51 | 1 | 12 |
| geotax (SQLite) | 94 | 12 | 17 | 53 | 1 | 2 |

The "one table" column is statements a typed call could already have written and did not, usually because they sat beside a join and one style per file won. The rest is what the line costs in practice. **A join to one row and an aggregate are 63 and 104 statements**, far more than everything else past the line put together, and they are the two ordinary things every list screen needs: *show the customer's name beside the order*, *count and sum by customer*. Each one is a `SELECT` list typed twice, once as SQL and once as a Row, held together by the positional check of [ADR 051](./051-a-statement-that-is-a-constant-can-be-prepared-once.md) and nothing else. A column renamed in a migration is a runtime surprise in exactly the statements the module was built to make safe.

The other half of the evidence is what those statements look like. A join to many almost never appears as a join, because a join to many breaks pagination, the second property above. It appears as a `LATERAL` subquery with `json_agg`, a document parsed back per row, or as a second `db.raw` per parent in a loop, which is N+1.

The question was whether any of this can be said without the builder ADR 036 refused: a chain of calls, `.join(...)`, `.groupBy(...)`, `.having(...)`, carrying its state in its return type.

## Decision

**A narrower Row may say four more things about itself, and the call site does not change.** It is still `db.select`, `db.one`, `db.find`, `db.page`, `db.count`, `db.exists` and `db.stream` with `.where`, `.order`, `.limit` and `.offset`. There is no `.join`, no `.group_by` and no `.having` to write there, and no new option at all.

```zig
const CustomerName = struct {
    pub const nilo_table = Customer;
    name: Str,
};

const LineBrief = struct {
    pub const nilo_table = Line;
    sku: Str,
    qty: i32,
};

// A parent, and children.
const OrderCard = struct {
    pub const nilo_table = Order;
    id: i64,
    total: i64,
    customer: CustomerName,        // JOIN customers, through orders.customer_id
    approver: ?StaffName,          // LEFT JOIN, because approver_id may be null
    lines: []const LineBrief,      // a second statement, for every order at once
};

// A group.
const ByCustomer = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{ .orders = .count, .revenue = .{ .sum = .total } };
    customer: CustomerName,        // a key of the group
    orders: i64,
    revenue: i64,
};

const cards = try db.page(OrderCard, c, .{ .where = .{ .customer = .{ .name = "Acme" } }, .order = .{ .id = .desc }, .limit = 20 });
const best = try db.select(ByCustomer, c, .{ .where = .{ .revenue = .{ .gt = 1000 } }, .order = .{ .revenue = .desc } });
```

### A row over there is a condition: `.exists`

```zig
db.select(Partner, c, .{ .where = .{
    .name = .{ .icontains = search },
    .exists = .{
        .{ .in = PartnerCapability, .where = .{ .capability = cap } },
    },
} });
```

**A list rather than a single test, and not for symmetry with `.any`.** A struct cannot carry the same field twice, so a bare test could never become two, and a filter page narrowing on two capabilities is the ordinary case. The entries are ANDed, `.not_exists` is `NOT EXISTS`, and both nest inside `.any`.

**The correlation is read out of the schema, not written at the call site.** The join comes from the child Row's own `.references`: one reference from the inner table to the outer one is the join; none is refused, because a join guessed from a column name answers a question nobody asked; two or more is refused, naming both columns, because the schema has said it twice (`created_by` and `updated_by` both pointing at `staff`) and which one joins is a question about what the query *means*. `.on = .<column>` is the escape hatch, naming a column of the inner Row, for a Row over a view (which has no foreign keys, [ADR 050](./050-a-view-or-a-rowid-alias-is-not-a-nullable-column.md)) and for the two-reference case; a composite key there is refused, since one column cannot match two. The correlation can also run from the other side, an outer Row whose own column points at the table inside the subquery, named with `.via = .<column>` in place of `.on` (the two together are refused, one join has one key on one side); the rules for reading it, and for a schema that declares a reference on each side, are [ADR 175](./175-an-exists-reads-the-reference-from-either-side.md)'s.

`where.Param` carries an `of: ?type`, the Row a parameter's column belongs to, null outside a subquery; without it a value inside `.exists` would be typed against the outer Row, answering with a column that happens to share a name or refusing one that is really there. The walker's `State` carries the same fact, the table every column inside the subquery is qualified with and the Row its type comes from, together, because a qualifier out of step with the Row writes a column of one table and binds it as a column of another, and that compiles.

**This keeps both properties.** A reference points at one row or none, so the join cannot change how many rows there are on the outer side, and the column list the statement answers is unchanged, because `.exists` adds no column at all: it is a condition, not a shape.

### A parent is a field whose type is a Row

A field of a narrower Row whose type is another Row, or an optional of one, is the row a reference points at. It is joined in the same statement, under the field's name, and its columns are read into it. **Which reference it follows is read out of the schema**, with the same rules `.exists` uses above, and a column no `.references` covers is said with `pub const nilo_via = .{ .approver = .approver_staff_id };` (a marker on the Row, distinct from `.exists`'s `.via` on a `.where` entry, and named for the same idea: the far end of a join the schema does not already say).

**The field is optional exactly when the reference can be null**, and both directions are refused. A nullable reference is a `LEFT JOIN`, and a field that cannot hold null would be filled from a row that is not there. A reference that cannot be null makes the `?` a branch no caller will take. Parents nest; a join under a `LEFT JOIN` is itself a `LEFT JOIN`, so a missing parent stays missing all the way down. An optional parent answers one more column, `(alias.key IS NOT NULL)`, because its own columns cannot say whether it is there: a parent that exists may hold nothing but nulls.

**This keeps both properties too.** A reference points at one row or none, so the join cannot change how many rows there are, and the columns it adds belong to the field that asked for them. The Row still describes the answer; it describes it as a tree.

### Children are a slice field, read by a second statement

A field `[]const C`, where `C` is a Row whose table points back at this one, is the rows that point here. **They are never joined.** Once the parents are read, one more statement reads the children of every parent at once:

```sql
SELECT "lines"."sku" AS "sku", "lines"."qty" AS "qty", "#k"."key" AS "#parent"
FROM unnest($1::int8[]) WITH ORDINALITY AS "#k"("value", "key")
JOIN "lines" ON "lines"."order_id" = "#k"."value"
ORDER BY "#k"."key", "lines"."id"
```

SQLite spells the list `json_each(?1) AS "#k"`, which answers the same two columns. **The parents' keys go in as one list and come back as their positions**, sorted by position, so the reader walks the parents and the children in step and hands each parent a contiguous run of one list. No key is ever compared, hashed or collated on the way, which matters for a text key and for a `Uuid` whose two Dialects store it differently.

`.limit` has counted the parents by the time this runs, so a page is twenty orders whatever they hold, the second property kept by construction rather than by care. Within one parent the children are in their table's key order unless the Row says otherwise. The Row has to read the column the children point at, since that is what they are handed out by, and forgetting it is a Refusal that names the field to add.

**`pub const nilo_children` says what else a Row reads of the rows pointing back**, keyed by the field it describes:

```zig
const RabCard = struct {
    pub const nilo_table = Rab;
    pub const nilo_children = .{
        .lines = .{ .order = .{ .position = .asc }, .where = .{ .state = .{ .ne = .void } } },
        .line_count = .{ .count = Line },
        .open_work = .{ .count = WorkItem, .where = .{ .category = .{ .not_in = .{ .done, .cancelled } } } },
    };
    id: i64,
    lines: []const LineBrief,
    line_count: i64,
    open_work: i64,
};
```

- **A list takes `.order` and `.where`.** The order is columns of the child's table, carried by the child Row or not, after the parent's position and before the child's key, so two children the order ties still come back the same way every time: `ORDER BY "#k"."key", "lines"."position" ASC, "lines"."id"`. The condition is a `WHERE` on the children's statement. A key order is a v7 mint order and matches a `position` only until somebody reorders, which is why every child list in nodeflux-os needed one.
- **A count is a field of its own, `i64`, and reads no child.** `.{ .count = Line }` names the Row whose table points back, with the reference found the way a children field finds it and `nilo_via` keyed by the count's field when there are two. It is a subquery correlated with the row it sits on, in the same statement: `(SELECT count(*) FROM "lines" AS "#c" WHERE "#c"."rab_id" = "rabs"."id")`. The counted table is always read under `"#c"`, so a table that points at itself (a work item's sub-items) is two names. A count may be ordered by and named in a condition like a column, the subquery written in its place, and it may sit on a parent's Row, where it correlates with the parent's alias. A grouped Row refuses one, because a group is many rows.

Both `.where`s are the literal condition an aggregate's `.where` takes, below: the entry is part of the Row's declaration, so its values are the compiler's and there is nothing to bind. `.limit` on a list is refused, because the children of every parent are one statement, and a limit there would cut across parents rather than within one.

**It is one level, and only through a reference of one column.** A child may have parents of its own, joined into the children's statement, but not children of its own: a second level would be a third statement per level with nowhere principled to stop. `db.stream` refuses children, because a stream never holds the rows the children would be handed to.

**Two statements are two snapshots unless a transaction makes them one.** Outside a `Tx`, a child inserted between them can appear under a parent read before it existed. That is stated rather than prevented: `tx.select` is the same call and holds, and a read that cannot tolerate it is already in a transaction for other reasons.

### A grouped Row says what it sums

`pub const nilo_aggregate` names the fields that are computed, and how:

| word | reads | field type |
|---|---|---|
| `.count` | `count(*)` | `i64` |
| `.{ .count = .col }` | `count(col)` | `i64` |
| `.{ .count_distinct = .col }` | `count(DISTINCT col)` | `i64` |
| `.{ .sum = .col }` | `sum(col)` | `i64` over whole numbers, `f64` over floating ones, the column's own type over a text-carried number such as `Decimal` |
| `.{ .min = .col }`, `.{ .max = .col }` | `min(col)`, `max(col)` | the column's type |
| `.{ .avg = .col }` | `avg(col)` | `f64` |

**Every other field is a key of the group**, a parent's columns included, and they are the `GROUP BY` in declaration order. The Row is one row per group, and says so in its type, which is what makes `.limit` count groups honestly: the thing being listed *is* a group.

**The type is a rule rather than a guess, and it is checked.** Both databases answer `sum` over an `integer` column as something wider, and Postgres answers it as `numeric`, which is why the Postgres Dialect writes `sum(x)::int8` and `avg(x)::float8`. A field is optional exactly when the computation can be null: over a nullable column, and for `sum`, `min`, `max` and `avg` on a Row with no keys at all, which answers even when nothing matched. `count` is never null. Each direction is a Refusal with the type to write.

**An entry may carry a `.where`, which narrows only the rows that one aggregate reads**: `sum(…) FILTER (WHERE …)`, which both databases take (SQLite since 3.30). It is what "amounts are never summed across currencies" looks like, one number in rupiah beside a count of what it left out:

```zig
pub const nilo_aggregate = .{
    .idr = .{ .sum = .value_amount_minor, .where = .{ .value_currency = "IDR" } },
    .foreign = .{ .count = .id, .where = .{ .value_currency = .{ .ne = "IDR" } } },
};
```

The condition is the where walker's words narrowed to what a literal can say: a value is `=`, `null` is `IS NULL`, and an operator struct takes `.eq`, `.ne`, `.gt`, `.gte`, `.lt`, `.lte`, `.in` and `.not_in`, ANDed across fields and within one, over columns of the table the Row groups.

**A column with a `.references` of one column is also a way into the row it points at**, the table reached being joined once under an alias its path names:

```zig
.open = .{ .count = .id, .where = .{ .state_id = .{ .category = .{ .not_in = .{ .done, .cancelled } } } } },
.government = .{ .count = .id, .where = .{ .org_unit_id = .{ .customer_id = .{ .kind = .government } } } },
```

```sql
count("work_items"."id") FILTER (WHERE "#f.state_id"."category" NOT IN ('done', 'cancelled'))
… FROM "work_items" JOIN "work_item_states" AS "#f.state_id" ON "#f.state_id"."id" = "work_items"."state_id"
```

The join keeps both properties for the reason a parent's does: a reference points at one row or none. It is a `JOIN` when the reference cannot be null and a `LEFT JOIN` when it can, or when a hop above it is, so a row whose reference is null still counts for every other aggregate. A struct whose fields are columns rather than operators is the way in; one mixing the two is refused. Only an aggregate's `.where` follows a reference: the tables the port's `FILTER`s read were reached this way and were never keys of the group, so a parent field, which would have been one, could not say it. **The values are written into the statement**, checked against their column the way a column's `.default` is and quoted by the same function, because the entry is part of the Row's declaration and is the same for every statement: there is nothing to bind, the statement text stays one constant with one plan name, and the planner sees the value it is filtering on. A filtered `sum`, `min`, `max` or `avg` is optional whatever its column, because a group none of whose rows matches computes over nothing; a filtered count is `0` there and stays `i64`. Rows that match are counted by naming a column that is never null, `.{ .count = .id, .where = … }`, rather than by a second spelling of `.count`. The same call, filter included, is what a condition on the field compares in the `HAVING`.

**A condition goes where it belongs by what it names.** A term on a column of the table or of a parent is a `WHERE`, applied before grouping; a term on an aggregate field is a `HAVING`, applied after. One `.where` carries both, and nothing at the call site says which is which, because the Row already does. An aggregate inside `.any` is refused: an alternative cannot be half `WHERE` and half `HAVING`.

**A Row with no keys is exactly one row.** `db.select` of it would always hold one, and `db.one` would never say null, so it is read with a new call, `db.exactlyOne(Row, c, .{ .where = … })`, which answers the Row itself. A condition on its aggregates is refused, because it would turn "exactly one" into "maybe none".

### Every column is answered under the path to its field

A shaped statement names every column it answers: `"id"`, `"customer.name"`, `"approver.#"`, `"#total"`, `"#parent"`. `ORDER BY` of a bare name means the answer's column of that name in both databases, so `.order = .{ .customer = .{ .name = .asc } }` and `.order = .{ .revenue = .desc }` compile to `ORDER BY "customer.name" ASC` and `ORDER BY "revenue" DESC` with no second vocabulary. `sql.Ordering` takes the same names at run time, a parent's as a tuple, `.{ .customer, .name }`. **A column of the table the Row does not carry may be ordered by too**, on a Row that is not grouped, and it is written through the table rather than through the answer, `ORDER BY "orders"."created_at"`: a tiebreak is a fact about the rows and not something the response has to show, and without this it was a second full-width Row kept only to sort by. A grouped Row refuses one by name, because a column of the table has one value per row and none per group; the flat path takes the same column bare, since it reads one table. **A condition may name one on the same terms**, on any Row that borrows a table, flat or shaped: `.where = .{ .email = e }` on a Row carrying only `id` and `name`, written through the table and bound as the owner's column type, since the Row has no field to take one from. A field the Row carries beside its columns keeps its own refusal, because to whoever reads the Row that name means the field. Every column is also qualified by its relation, because two joined tables both have an `id`. The table the statement reads keeps its own name rather than an alias, which is what lets a nested `.exists` correlate with it exactly as before; a parent whose field name would collide with that relation is refused.

### Where each call stands

| | parent | children | a count of children | grouped | no keys |
|---|---|---|---|---|---|
| `select`, `one`, `page` | yes | yes | yes | yes | refused, `exactlyOne` |
| `find` | yes | yes | yes | refused: a group has no key | refused |
| `count`, `exists` | yes, joining only the parents the condition names | yes | yes | yes, counting groups | refused |
| `stream` | yes | refused | yes | yes | refused |
| `exactlyOne` | | | | | yes |
| `.lock` | refused | refused | refused | refused | refused |
| writes, `raw`, `composed` | refused | refused | refused | refused | refused |

Every call has its `tx.*` twin. A grouped `db.count` counts groups, by wrapping the grouped statement: `SELECT count(*) FROM (…) AS "#groups"`. A `.lock` is refused because it would lock a row of every table joined, which is not what anyone holding one order meant. A write through a shaped Row is refused because an answer is not written back. `exists` and `not_exists` join `any` as reserved column names, so a Row with a column carrying one of those names is refused by name, the same trade `any` made.

## What was rejected

**`.where` held to the Row's own columns while `.order` was not.** That is how it stood between items 86 and 96: a narrower Row could sort by a column it did not carry and not be narrowed by one, so staff creation looked a person up by email through a Row that then had to carry `email` for no reader. Nothing on record chose the difference. A condition is about the table's rows as much as a tiebreak is, and the only thing the walker lacked was a type to bind the value as, which the owner has.

**A `.join`, `.group_by` or `.having` option, or a chain of calls.** It is ADR 036's rejection and it stands for the same reason: a chain carries its state in its return type, and what a reader gets when it does not fit is a tower of generics rather than a sentence. It would also split the answer's description across the call site and the Row. Here the Row is still the whole description, so a list and a detail endpoint reading the same Row read the same shape.

**A Row that describes the whole query**, with `pub const nilo_query = .{ .join = …, .group_by = … }`. It moves the builder into a declaration rather than removing it. Every clause it could hold is one this design derives from a field's type, and deriving it is what makes a mismatch between the SQL and the struct unrepresentable rather than checked.

**Inferred result types**, the way Prisma's `include` and Drizzle's `with` work: the answer's type is computed from the call, so the caller never writes it. That is the most convenient shape in a language with structural types and the least readable one in Zig: the type a handler returns is then something nobody wrote down, its compile errors name a generated struct, and the OpenAPI document of [ADR 016](./016-the-api-description-comes-from-the-signatures.md) describes a type that is not in the source. A Row written out is a line more and is the contract.

**Children as a `LATERAL` join with `json_agg`**, what nodeflux-os writes by hand. One round trip instead of two, and it costs a JSON document built by the database and parsed back per parent into the arena, with its own type story for every column inside it, on Postgres only. SQLite has `json_group_array` and no `LATERAL`, so the two Dialects would have answered with different statements of different shapes. Two plain statements are the same on both and read with the same code as every other row.

**Children matched by key rather than by position.** A hash map from key to parent costs an allocation per parent and a comparison per child, and makes a `Uuid` key, text on SQLite and bytes on Postgres, two code paths. The ordinal is the parent's position, which the reader already has.

**A fourth marker word on the Row for `.exists`'s correlation**, `.related = …`. The case would be real and the check would run while compiling, and it still loses, because `.references` already carries the fact and two words for one fact is where drift starts.

**A test in `.exists` against the same table.** Both sides would be written as the same relation, so every column in the subquery is ambiguous, and telling them apart needs an alias. That is `db.raw`, and it is a Refusal that says so.

**An `.exists` with an empty `.where`.** It would ask only whether any row over there is joined to this one, which the join column already answers without a subquery.

**Children in their table's key order and nothing else**, the position this ADR first took. Every child list the port reads is ordered by a `position`, and a v7 key matches it only until somebody drags a line up; the workaround was a raw statement batched by hand with `= ANY($1)`, which is the N+1 fix done again per screen. `nilo_children` took its place.

**A count of children as the length of the list.** It reads every child to print one number: a SKU Product's whole catalogue for a badge. **A count as a `LEFT JOIN` onto a grouped subquery** answers the same number in one statement and counts every parent's children, those on the page and those not, before `.limit` has a say; the correlated subquery asks one index lookup per row the page shows. **A count as a word in `nilo_aggregate`** would have made the Row grouped, which it is not: each row is one row of its table.

**A reference followed by a subquery**, `FILTER (WHERE EXISTS (SELECT 1 FROM "work_item_states" …))`. It needs no join and changes nothing outside the one call, and it is a lookup per row per aggregate, where the dashboards it replaces read whole tables into four or eight totals; a join is one pass, shared by every aggregate that reaches the same table.

**An aggregate's or a child list's `.where` bound as parameters, in the walker's full grammar.** The values are in a declaration, so they are the compiler's; binding them would thread a second set of paths through every shaped statement, number the `SELECT` list's placeholders ahead of the caller's, and buy patterns and `.any` that no filter in the port uses. A literal takes the thirty-three `FILTER`s the port wrote, and a filter needing more is the statement's own `.where` or `db.raw`.

## What is still refused

A join to a table that no reference or `nilo_via` connects; a join with a condition in its `ON`; a self-join through the same field twice (two fields do it, under two names); children of children; children through a reference of several columns; a limit on children per parent; `DISTINCT`; window functions other than the page total; CTEs, unions and set operations; an aggregate over an expression rather than a column; an aggregate's `.where` with a pattern, `.any` or `.exists` in it, or through a reference of several columns; a `nilo_children` entry's `.where` through a reference; a sum or any aggregate but a count over children. Each is `db.raw`, which is unchanged, and each is written down so the next person to want one starts from which property it would have to keep.

## What it costs

Put against the four axes ([ADR 017](./017-the-trade-budget-has-four-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | none added to a path that did not ask. `.exists` is comptime string concatenation, its values out of the same parameter tuple. A flat Row is read by the same code it was, `readRow`'s loop generalised by kind, and `db.zig`'s allocation tests pass unchanged. A parent adds nothing, its columns read into the Row that was going to be allocated anyway. **Children cost, per statement, one array of keys and one array of run ends, each one word per parent, plus the list the children are read into**, which doubles as it grows because how many will arrive is not known; on SQLite the key list is one JSON text, one allocation. A grouped Row allocates what a flat Row of the same width does. An aggregate's `.where`, a child list's `.order` and `.where`, and a count of children are comptime text with no value to bind, and a count is read into the Row like any column. A table an aggregate's `.where` reaches is a join the database does, with nothing read into the Row. |
| Memory per idle connection | zero. Nothing here lives on a connection. |
| Throughput and p99 | one round trip for `.exists`, a parent, a group or a count of children, the same as the `db.raw` each replaces; two for children, against N+1 for the loop it replaces. A count of children is one lookup of the counted table's reference column per row answered, which is what the hand-written correlated `count(*)` it replaces costs, and wants the same index: Postgres does not index a foreign key by itself. What the database does with the join or the subquery is the caller's own plan, exactly as when the caller wrote it by hand. Unmeasured on the database's own side: what an `.exists` costs there against the `db.raw` it replaces is the same SQL, so nothing is benchmarked here; if the two ever diverge, [`bench/result/sql.md`](../../bench/result/sql.md) is where the number goes. |
| Binary size | zero for a program with no shaped Row and no `.exists`; all of it is comptime. `zig build size-sql`, stripped `ReleaseFast`: +80 bytes on the Postgres program and −352 on the SQLite one, and −160 on `bench-sql-server`, against a build from before this change. Layout rather than code; the statements are comptime and the flat reader it generalised does the same work ([`sql.md` §14](../../bench/result/sql.md#14-a-row-with-a-parent-children-or-a-sum-costs-a-program-without-one-nothing)). |

Twenty-five Refusals cover the rules above, in `sql/refusals/shape_*.zig`, one per rule, and six more the words added after them: `aggregate_filter_*` for an aggregate's `.where` with nothing to compute, read as never null, or with a pattern, and `children_*` for a count read as anything but `i64`, a list given a `.limit`, and a list's `.where` through a reference. `.exists`'s own correlation carries its own set beside them, for a reference declared twice, none at all, `.on` given beside `.via`, and either naming a column the Row lacks, the last of them added when the correlation gained the outer Row's own side ([ADR 175](./175-an-exists-reads-the-reference-from-either-side.md)).
