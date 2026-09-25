//! A small internal application on one SQLite file: two Rows, the tables
//! made at boot, a list read through a query struct, a filter that may be
//! absent, a page of invoices with their customer's name, a customer with
//! their invoices, a report of totals and groups, and one transaction. The
//! shape most "small internal tool" programs have, and the one that needs
//! `nilo_sql` end to end.
//!
//! ```
//! zig build run-sqlite
//!
//! curl localhost:8787/customers                       # every customer
//! curl 'localhost:8787/customers?q=wa'                # a filter, when it is set
//! curl -i -X POST localhost:8787/customers -d '{"name":"kid","email":"kid@example.dev"}'   # 201
//! curl localhost:8787/customers/1                     # a customer and every invoice of theirs
//! curl 'localhost:8787/invoices?status=open&page=1'   # a page with each customer's name, and its total
//! curl 'localhost:8787/invoices?status=nunggak'       # 400, in a sentence
//! curl localhost:8787/report                          # totals, by status, by customer, by month
//! curl -i -X POST localhost:8787/invoices/1/pay       # a transaction; 409 the second time
//! curl localhost:8787/invoices/999                    # 404, because the handler returns ?Invoice
//! curl localhost:8787/healthz                         # asks the pool with SELECT 1
//! curl localhost:8787/openapi.json                    # written from the signatures
//! ```
//!
//! The file is `invoices.db` in the working directory, made on the first
//! boot and reused after. Delete it to start over.

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
const fail = nilo.fail;
const Str = nilo.Str;

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// The one question SQLite makes you answer: where a statement runs. `.hop`
/// hands each one to the Engine's thread pool so no statement can stall a
/// thread that is serving other connections (ADR 064).
const Db = sql.Sqlite(.{ .threading = .{ .hop = nilo } });

// ---- the Rows -------------------------------------------------------------
//
// Two structs, and everything the database needs to know about them is in
// the marker: the table, the key, a unique, a default, a foreign key and an
// index. `createMissing` writes the DDL from this, `db.checking` holds the
// tables against it at every boot, and the enum becomes a CHECK.

const Customer = struct {
    pub const nilo_table = .{
        .name = "customers",
        .key = .id,
        .unique = .{.email},
        .default = .{ .created_at = .now },
    };

    id: i64,
    name: Str,
    email: Str,
    created_at: sql.Timestamp,
};

const Status = enum { open, paid };

const Invoice = struct {
    pub const nilo_table = .{
        .name = "invoices",
        .key = .id,
        .references = .{ .customer_id = .{ Customer, .id, .cascade } },
        .index = .{.status},
        .default = .{ .status = .open, .issued_at = .now },
    };

    id: i64,
    customer_id: i64,
    /// Whole units of currency. An integer, because a `REAL` column would
    /// round somebody's money.
    total: i64,
    status: Status,
    issued_at: sql.Timestamp,
    paid_at: ?sql.Timestamp,
};

/// One value: the tables the program has, handed to `createMissing` and to
/// `db.checking`, so the two cannot drift (ADR 181).
const schema: sql.Schema = .{ .tables = &.{ Customer, Invoice } };

// ---- the boot -------------------------------------------------------------

/// Registered with `app.before`, so it runs once the pool is open and before
/// the first request, on the server's own loop (ADR 180). `createMissing`
/// is one `CREATE TABLE IF NOT EXISTS` per Row plus its indexes, in one
/// transaction, and a second boot does nothing. The schema check runs
/// *after* this, which is what lets `db.checking` and `createMissing` live
/// in the same program (ADR 180).
fn makeTables(run: *nilo.Run, db: *Db) !void {
    try sql.migrate.createMissing(db, run, schema);
    if (try db.count(Customer, run, .{}) == 0) try seed(run, db);
}

/// A few rows so the report has something to add up. Text written into a
/// `Str` column is a plain `[]const u8` here: an insert takes the bytes,
/// and it is reading a row *out* that hands back a `Str` bound to the Scope.
fn seed(run: *nilo.Run, db: *Db) !void {
    var tx = try db.begin(run, .{});
    errdefer tx.rollback();

    const wati = try tx.insert(Customer, run, .{ .name = "wati", .email = "wati@example.dev" });
    const budi = try tx.insert(Customer, run, .{ .name = "budi", .email = "budi@example.dev" });

    // Issued over three months, so the per-month report has three lines.
    const month: i64 = 30 * std.time.us_per_day;
    const now = sql.Timestamp.now().micros;
    _ = try tx.insert(Invoice, run, .{ .customer_id = wati.id, .total = 250, .issued_at = sql.Timestamp{ .micros = now - 2 * month } });
    _ = try tx.insert(Invoice, run, .{ .customer_id = wati.id, .total = 400, .issued_at = sql.Timestamp{ .micros = now - month } });
    _ = try tx.insert(Invoice, run, .{ .customer_id = budi.id, .total = 125, .issued_at = sql.Timestamp{ .micros = now } });
    _ = try tx.insert(Invoice, run, .{
        .customer_id = budi.id,
        .total = 90,
        .status = .paid,
        .issued_at = sql.Timestamp{ .micros = now - month },
        .paid_at = sql.Timestamp{ .micros = now - month + std.time.us_per_day },
    });
    try tx.commit();
}

// ---- the handlers ---------------------------------------------------------
//
// Ordinary functions. `db` is a service, `c` is the request's Scope, and
// everything else is request data: a path param, a query struct, a body.

/// `?Str` in a query struct is "absent is null", and `sql.given` turns that
/// null into *no condition at all* rather than `= NULL` (ADR 149).
const CustomerFilter = struct {
    q: ?Str = null,
    limit: nilo.Within(1, 200) = .of(50),
};

fn listCustomers(db: *Db, c: *nilo.Ctx, filter: nilo.Query(CustomerFilter)) ![]Customer {
    return db.select(Customer, c, .{
        .where = .{ .name = .{ .icontains = sql.given(filter.value.q) } },
        .order = .{ .id = .asc },
        .limit = filter.value.limit.value,
    });
}

const NewCustomer = struct { name: Str, email: Str };

/// The status is part of the contract, so it is in the type and the API
/// description names it. `.unique = .{.email}` is what makes the second
/// `POST` with the same address an `AlreadyExists`, and the `catch` turns
/// that into the 409 a client can act on.
fn createCustomer(db: *Db, c: *nilo.Ctx, incoming: NewCustomer) !nilo.Status(201, Customer) {
    const made = db.insert(Customer, c, .{
        .name = incoming.name,
        .email = incoming.email,
    }) catch |err| switch (err) {
        error.AlreadyExists => return fail.conflict("{f} already has an account", .{incoming.email}),
        else => return err,
    };
    return .{ .value = made };
}

/// A customer with their invoices. `invoices` is a list of another table's
/// Row, which makes it the **children** of the customer: the rows whose
/// reference points back here, read by a second statement once the customer
/// is (ADR 218). A customer with none has an empty list.
const CustomerAccount = struct {
    pub const nilo_table = Customer;

    id: i64,
    name: Str,
    email: Str,
    invoices: []const InvoiceBrief,
};

const InvoiceBrief = struct {
    pub const nilo_table = Invoice;

    id: i64,
    total: i64,
    status: Status,
};

fn getCustomer(db: *Db, c: *nilo.Ctx, id: i64) !?CustomerAccount {
    return db.find(CustomerAccount, c, id);
}

/// `?Invoice` is the whole 404: null goes out as `404 Not Found`, and the
/// document says the route answers one (ADR 023).
fn getInvoice(db: *Db, c: *nilo.Ctx, id: i64) !?Invoice {
    return db.find(Invoice, c, id);
}

/// A list screen: a filter that may be absent, a page, and the total the
/// filter matched. `?Status` in the query struct is a 400 with the choices
/// in it when the text is not one of them, written by nobody here.
const InvoiceFilter = struct {
    status: ?Status = null,
    page: nilo.Within(1, 100_000) = .of(1),
};

/// A line of the list, with the customer's name beside the invoice.
/// `customer` holds a Row of another table, which makes it the invoice's
/// **parent**: joined in the same statement through the one `.references`
/// from invoices to customers, and answered in JSON as `"customer":
/// {"name": …}` (ADR 218). No SQL is written here, and a page is still ten
/// invoices, because a reference points at one customer.
const InvoiceLine = struct {
    pub const nilo_table = Invoice;

    id: i64,
    total: i64,
    status: Status,
    issued_at: sql.Timestamp,
    customer: CustomerName,
};

const CustomerName = struct {
    pub const nilo_table = Customer;

    name: Str,
};

const page_size = 10;

/// `sql.given` makes an absent `?status` no condition at all, the same
/// statement either way (ADR 149). `db.page` reads the rows and the total
/// the filter matched in one statement (ADR 150).
fn listInvoices(db: *Db, c: *nilo.Ctx, filter: nilo.Query(InvoiceFilter)) !Db.Page(InvoiceLine) {
    const offset = (@as(i64, filter.value.page.value) - 1) * page_size;
    return db.page(InvoiceLine, c, .{
        .where = .{ .status = sql.given(filter.value.status) },
        .order = .{ .id = .asc },
        .limit = page_size,
        .offset = offset,
    });
}

// ---- the report -----------------------------------------------------------
//
// Aggregates are most of an application like this one. A count or a sum over
// a column, grouped by columns or by a parent, is a Row that says so in
// `nilo_aggregate`; its other fields are what it groups by (ADR 218). What
// a Row cannot say, a date computed out of a column, is `raw`.

/// Every field an aggregate, so it is grouped by nothing: exactly one row
/// whatever matched, read with `exactlyOne`. `billed` is optional because a
/// sum over no invoices at all is null.
const Totals = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{ .invoices = .count, .billed = .{ .sum = .total } };

    invoices: i64,
    billed: ?i64,
};

/// One line per status. `status` is not in `nilo_aggregate`, so it is what
/// the lines are grouped by.
const StatusLine = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{ .invoices = .count, .billed = .{ .sum = .total } };

    status: Status,
    invoices: i64,
    billed: i64,
};

/// One line per customer, grouped by a parent's column: the join and the
/// `GROUP BY` both follow from `customer`'s type.
const CustomerLine = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{ .invoices = .count, .billed = .{ .sum = .total } };

    customer: CustomerName,
    invoices: i64,
    billed: i64,
};

/// A month is computed out of `issued_at`, and a Row groups by columns, not
/// by expressions over them, so this one is `raw`. A `sql.Timestamp` is
/// stored as microseconds since the epoch on SQLite (ADR 067), so a date
/// function reads it as `issued_at / 1000000, 'unixepoch'`; on Postgres the
/// same line is `to_char(issued_at, 'YYYY-MM')`.
const MonthLine = struct {
    pub const nilo_table = .projection;

    month: Str,
    invoices: i64,
    billed: i64,
};

const Report = struct {
    totals: Totals,
    by_status: []StatusLine,
    by_customer: []CustomerLine,
    by_month: []MonthLine,
};

fn report(db: *Db, c: *nilo.Ctx) !Report {
    return .{
        .totals = try db.exactlyOne(Totals, c, .{}),
        .by_status = try db.select(StatusLine, c, .{ .order = .{ .status = .asc } }),
        .by_customer = try db.select(CustomerLine, c, .{ .order = .{ .billed = .desc } }),
        .by_month = try db.raw(MonthLine, c,
            \\SELECT strftime('%Y-%m', issued_at / 1000000, 'unixepoch') AS month,
            \\       count(*) AS invoices,
            \\       coalesce(sum(total), 0) AS billed
            \\FROM invoices GROUP BY month ORDER BY month
        , .{}),
    };
}

// ---- the transaction ------------------------------------------------------

/// Paying is a read and then a write that have to see the same state: two
/// requests paying one invoice at once must not both succeed. A `Tx` holds
/// one connection until it ends, and on SQLite that is the writer, so the
/// second request's `find` waits its turn and sees `paid`. It ends however
/// the handler leaves: `deinit` rolls back unless the commit ran, on every
/// early return below, and a `fail.*` is an early return.
fn payInvoice(db: *Db, c: *nilo.Ctx, id: i64) !Invoice {
    var tx = try db.begin(c, .{});
    defer tx.deinit();

    const invoice = try tx.find(Invoice, c, id) orelse return fail.notFound("there is no invoice {d}", .{id});
    if (invoice.status == .paid) return fail.conflict("invoice {d} was already paid", .{id});

    const paid = try tx.updateReturningOne(Invoice, c, .{
        .set = .{ .status = Status.paid, .paid_at = sql.Timestamp.now() },
        .where = .{ .id = id },
    }) orelse return error.QueryFailed;

    try tx.commit();
    return paid;
}

// ---- wiring ---------------------------------------------------------------

fn routes(app: *nilo.App) !void {
    try app.get("/customers", listCustomers);
    try app.post("/customers", createCustomer);
    try app.get("/customers/:id", getCustomer);
    try app.get("/invoices", listInvoices);
    try app.get("/invoices/:id", getInvoice);
    try app.post("/invoices/:id/pay", payInvoice);
    try app.get("/report", report);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var db = Db.init(gpa, "invoices.db", .{ .size = 4 });
    defer db.deinit();
    // The Rows against their tables, once, at boot, after `makeTables` has
    // run. A Row that disagrees with its table stops the server starting
    // rather than failing a request at three in the morning.
    db.checking(schema);

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.before(makeTables, .{&db});
    try app.use(nilo.logger.standard);
    try app.health("/healthz");
    app.docs(.{ .title = "Invoices", .version = "1.0.0" });
    try routes(&app);

    try app.listen(.{});
}

// ---- tests ----------------------------------------------------------------
//
// The same App a program builds, driven with no server: `app.start(io)` is
// everything `listen()` does before it accepts anything, `makeTables`
// included, on an `Io` of the test's own.

const testing = std.testing;

/// A Db over a shared in-memory file, the App around it, and a client to
/// drive handlers through. Heap-allocated because the App holds a pointer
/// to the Db and the Client hands out a Ctx pointing at the App.
const Stack = struct {
    threaded: std.Io.Threaded,
    db: Db,
    app: nilo.App,
    client: nilo.testing.Client,

    fn open(gpa: std.mem.Allocator, comptime name: []const u8) !*Stack {
        const self = try gpa.create(Stack);
        self.* = .{
            .threaded = .init(gpa, .{}),
            .db = Db.init(gpa, "file:example-" ++ name ++ "?mode=memory&cache=shared", .{ .size = 2 }),
            .app = nilo.App.init(gpa),
            .client = try nilo.testing.Client.init(gpa, .{}),
        };
        self.db.checking(schema);
        try self.app.provide(&self.db);
        try self.app.before(makeTables, .{&self.db});
        try routes(&self.app);
        // Opens the pool, makes the tables, seeds them, and checks the
        // Rows against what was made, in that order (ADR 180).
        try self.app.start(self.threaded.io());
        return self;
    }

    fn close(self: *Stack, gpa: std.mem.Allocator) void {
        self.client.deinit();
        self.app.deinit();
        self.db.nilo_stop();
        self.db.deinit();
        self.threaded.deinit();
        gpa.destroy(self);
    }
};

test "the tables are made at boot and the schema check passes against them" {
    const gpa = testing.allocator;
    var stack = try Stack.open(gpa, "boot");
    defer stack.close(gpa);

    // The boot seeded two customers and four invoices.
    var run: nilo.Run = .init(gpa);
    defer run.deinit();
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Customer, &run, .{}));
    try testing.expectEqual(@as(usize, 4), try stack.db.count(Invoice, &run, .{}));
    try testing.expectEqual(@as(usize, 0), try stack.db.checkSchema(schema.tables));

    // And a second boot changes nothing: `createMissing` creates what is
    // missing and the seed runs on an empty table only.
    var run2: nilo.Run = .init(gpa);
    defer run2.deinit();
    try makeTables(&run2, &stack.db);
    try testing.expectEqual(@as(usize, 2), try stack.db.count(Customer, &run2, .{}));
}

test "a customer filter that is absent is no filter, and one that is set narrows the list" {
    const gpa = testing.allocator;
    var stack = try Stack.open(gpa, "filter");
    defer stack.close(gpa);

    const all = try stack.client.get(&stack.app, "/customers");
    try testing.expectEqual(@as(u16, 200), all.status);
    try testing.expect(std.mem.indexOf(u8, all.body, "wati@example.dev") != null);
    try testing.expect(std.mem.indexOf(u8, all.body, "budi@example.dev") != null);

    const some = try stack.client.get(&stack.app, "/customers?q=WA");
    try testing.expect(std.mem.indexOf(u8, some.body, "wati@example.dev") != null);
    try testing.expect(std.mem.indexOf(u8, some.body, "budi@example.dev") == null);
}

test "a second customer with the same address is a 409, from the unique in the marker" {
    const gpa = testing.allocator;
    var stack = try Stack.open(gpa, "unique");
    defer stack.close(gpa);

    const made = try stack.client.post(&stack.app, "/customers", "{\"name\":\"kid\",\"email\":\"kid@example.dev\"}");
    try testing.expectEqual(@as(u16, 201), made.status);

    const again = try stack.client.post(&stack.app, "/customers", "{\"name\":\"kid\",\"email\":\"kid@example.dev\"}");
    try testing.expectEqual(@as(u16, 409), again.status);
}

test "the invoice page carries the total its filter matched, and a bad filter is a 400 in a sentence" {
    const gpa = testing.allocator;
    var stack = try Stack.open(gpa, "page");
    defer stack.close(gpa);

    const open = try stack.client.get(&stack.app, "/invoices?status=open");
    try testing.expectEqual(@as(u16, 200), open.status);
    try testing.expect(std.mem.indexOf(u8, open.body, "\"total\":3") != null);
    try testing.expect(std.mem.indexOf(u8, open.body, "\"customer\":{\"name\":\"wati\"}") != null);

    // No filter: every invoice, and the total says so.
    const every = try stack.client.get(&stack.app, "/invoices");
    try testing.expect(std.mem.indexOf(u8, every.body, "\"total\":4") != null);

    // A word the enum has not got is refused with the choices in the
    // sentence, by the query struct rather than by anything written here.
    const wrong = try stack.client.get(&stack.app, "/invoices?status=nunggak");
    try testing.expectEqual(@as(u16, 400), wrong.status);
    try testing.expect(std.mem.indexOf(u8, wrong.body, "open, paid") != null);
}

test "the report adds up, and the per-month table has one line per month" {
    const gpa = testing.allocator;
    var stack = try Stack.open(gpa, "report");
    defer stack.close(gpa);

    const answer = try stack.client.get(&stack.app, "/report");
    try testing.expectEqual(@as(u16, 200), answer.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, answer.body, .{});
    defer parsed.deinit();

    const totals = parsed.value.object.get("totals").?.object;
    try testing.expectEqual(@as(i64, 4), totals.get("invoices").?.integer);
    try testing.expectEqual(@as(i64, 865), totals.get("billed").?.integer);

    // One line per status, in the enum's order as text: open, then paid.
    const by_status = parsed.value.object.get("by_status").?.array;
    try testing.expectEqual(@as(usize, 2), by_status.items.len);
    try testing.expectEqualStrings("open", by_status.items[0].object.get("status").?.string);
    try testing.expectEqual(@as(i64, 3), by_status.items[0].object.get("invoices").?.integer);
    try testing.expectEqual(@as(i64, 90), by_status.items[1].object.get("billed").?.integer);

    // One line per customer, the one billed most first.
    const by_customer = parsed.value.object.get("by_customer").?.array;
    try testing.expectEqual(@as(usize, 2), by_customer.items.len);
    try testing.expectEqualStrings("wati", by_customer.items[0].object.get("customer").?.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 650), by_customer.items[0].object.get("billed").?.integer);
    try testing.expectEqual(@as(i64, 215), by_customer.items[1].object.get("billed").?.integer);

    // Three months of invoices, from the microsecond column read through
    // `strftime(…, 'unixepoch')`.
    const by_month = parsed.value.object.get("by_month").?.array;
    try testing.expectEqual(@as(usize, 3), by_month.items.len);
    try testing.expectEqual(@as(i64, 2), by_month.items[1].object.get("invoices").?.integer);
}

test "a customer comes with their invoices, and one nobody has is a 404" {
    const gpa = testing.allocator;
    var stack = try Stack.open(gpa, "account");
    defer stack.close(gpa);

    const answer = try stack.client.get(&stack.app, "/customers/1");
    try testing.expectEqual(@as(u16, 200), answer.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, answer.body, .{});
    defer parsed.deinit();

    // wati was seeded with two invoices, and they come in key order.
    const invoices = parsed.value.object.get("invoices").?.array;
    try testing.expectEqualStrings("wati", parsed.value.object.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), invoices.items.len);
    try testing.expectEqual(@as(i64, 250), invoices.items[0].object.get("total").?.integer);
    try testing.expectEqual(@as(i64, 400), invoices.items[1].object.get("total").?.integer);

    const missing = try stack.client.get(&stack.app, "/customers/999");
    try testing.expectEqual(@as(u16, 404), missing.status);
}

test "paying an invoice is a transaction, and paying it twice is a 409" {
    const gpa = testing.allocator;
    var stack = try Stack.open(gpa, "pay");
    defer stack.close(gpa);

    const paid = try stack.client.post(&stack.app, "/invoices/1/pay", "");
    try testing.expectEqual(@as(u16, 200), paid.status);
    try testing.expect(std.mem.indexOf(u8, paid.body, "\"status\":\"paid\"") != null);

    const again = try stack.client.post(&stack.app, "/invoices/1/pay", "");
    try testing.expectEqual(@as(u16, 409), again.status);

    const missing = try stack.client.post(&stack.app, "/invoices/999/pay", "");
    try testing.expectEqual(@as(u16, 404), missing.status);

    // `?Invoice` is the 404 with nothing written in the handler.
    const gone = try stack.client.get(&stack.app, "/invoices/999");
    try testing.expectEqual(@as(u16, 404), gone.status);
}
