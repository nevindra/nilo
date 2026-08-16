//! The awkward half of a real API, which the other examples skip: resources
//! inside resources, a body with structs and lists inside it, a state
//! machine that answers 409, an upsert whose status is not known until it
//! runs, three services of different shapes, a resolver that needs one of
//! them, and a body read as a stream because it might be enormous.
//!
//! `rest` is the example to read first — it is the same ideas without the
//! weight. This one exists to find out what the ideas cost when the domain
//! stops being one flat struct.
//!
//! ```
//! zig build run-orders
//!
//! TOKEN='Authorization: Bearer packer-key'
//!
//! curl -H "$TOKEN" localhost:8787/v1/orders
//! curl -H "$TOKEN" 'localhost:8787/v1/orders?stage=placed&sort=total&per_page=2'
//!
//! # a body with a struct and a list inside it
//! curl -H "$TOKEN" -X POST localhost:8787/v1/orders -d '{
//!   "customer": {"code":"wati","name":"Wati","email":"wati@example.dev"},
//!   "ship_to":  {"line1":"Jl. Melati 4","city":"Bandung","postcode":"40115","country":"ID"},
//!   "lines":    [{"sku":"kopi-250","quantity":2},{"sku":"gula-1kg","quantity":1}]
//! }'
//!
//! # and what it says when the body is wrong three levels down
//! curl -H "$TOKEN" -X POST localhost:8787/v1/orders -d '{
//!   "customer": {"code":"wati","name":"Wati","email":"wati@example.dev"},
//!   "ship_to":  {"line1":"Jl. Melati 4","city":404,"postcode":"40115","country":"ID"},
//!   "lines":    [{"sku":"kopi-250","quantity":2}]
//! }'
//!
//! curl -H "$TOKEN" -X POST localhost:8787/v1/orders/1/lines -d '{"sku":"gula-1kg","quantity":3}'
//! curl -H "$TOKEN" -X DELETE localhost:8787/v1/orders/1/lines/2      # 204
//! curl -H "$TOKEN" -X POST localhost:8787/v1/orders/1/advance -d '{"to":"placed"}'
//! curl -H "$TOKEN" -X POST localhost:8787/v1/orders/1/advance -d '{"to":"draft"}'   # 409
//!
//! curl -i -H "$TOKEN" -X PUT localhost:8787/v1/customers/budi \
//!      -d '{"code":"budi","name":"Budi","email":"budi@example.dev"}'  # 201, then 200
//!
//! curl -H "$TOKEN" --data-binary @invoice.pdf localhost:8787/v1/orders/1/invoice
//!
//! curl -H 'Authorization: Bearer admin-key' localhost:8787/v1/reports/daily
//! curl -H "$TOKEN" localhost:8787/v1/reports/daily                  # 403
//!
//! curl localhost:8787/openapi.json | jq '.components.schemas | keys'
//! ```

const std = @import("std");
const nilo = @import("nilo");
const fail = nilo.fail;
const Str = nilo.Str;
const Allocator = std.mem.Allocator;

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

// ---- what the API talks about ----

const Currency = enum { idr, usd };
const Priority = enum { normal, express };

/// Where an order has got to. An enum in a body, a query and a response all
/// at once, which is three different things the framework has to make of the
/// same declaration: a parsed value, a `?stage=placed` to match, and a list
/// of allowed strings in the generated document.
///
/// `@"packed"` because `packed` is a Zig keyword and "packed" is what the
/// warehouse calls it. Nothing downstream has to know: the wire, the query
/// and the document all get the name, because all three go through
/// `@tagName`. An API whose vocabulary happens to collide with the
/// language's is not a reason to rename the API.
const Stage = enum { draft, placed, @"packed", shipped, cancelled };

/// One shape, written once, used on both sides of the wire.
///
/// A stored address owns its text and is freed with the row; an incoming one
/// borrows the request's and is gone when the request ends. [ADR 0004] is
/// the reason those cannot be the same type — but they can be the same
/// *declaration*, with the text type as a parameter. Six lines instead of
/// twelve, and a field added to one is a field added to both.
///
/// In the generated document these are `Addressed_Text` and `Addressed_Str`
/// — a generic keeps a name, it just does not get to choose it. Where the
/// name matters more than the six lines, write the pair out instead;
/// `Customer` and `NewCustomer` below are the other half of the comparison.
///
/// [ADR 0004]: ../../docs/adr/0004-request-arena-and-the-str-type.md
fn Addressed(comptime Text: type) type {
    return struct {
        line1: Text,
        city: Text,
        postcode: Text,
        country: Text,
    };
}

const Address = Addressed([]const u8);
const NewAddress = Addressed(Str);

/// The written-out pair, for comparison: `Customer` and `NewCustomer` say
/// the same thing twice, and the generated document names both. Which of the
/// two spellings to use is a judgement about who reads the document, not a
/// rule — so this example does one of each rather than pretending there is
/// an answer.
const Customer = struct {
    code: []const u8,
    name: []const u8,
    email: []const u8,
};

const NewCustomer = struct {
    code: Str,
    name: Str,
    email: Str,
};

const Line = struct {
    no: u16,
    sku: []const u8,
    name: []const u8,
    quantity: u16,
    each_cents: i64,
};

const Order = struct {
    id: u32,
    stage: Stage,
    priority: Priority,
    currency: Currency,
    customer: Customer,
    ship_to: Address,
    /// A list of structs in a response: the JSON writer walks it, and the
    /// generated document describes it as an array of `Line`.
    lines: []const Line,
    total_cents: i64,
    note: ?[]const u8 = null,
};

// ---- the services ----

/// A service that is never written to, so it needs no lock and is provided
/// as a `*const`. Nothing about a handler asking for one is different —
/// `catalog: *const Catalog` is a pointer, so it is a service.
const Catalog = struct {
    items: []const Item,

    const Item = struct { sku: []const u8, name: []const u8, each_cents: i64 };

    fn find(self: *const Catalog, sku: []const u8) ?Item {
        for (self.items) |item| {
            if (std.mem.eql(u8, item.sku, sku)) return item;
        }
        return null;
    }
};

/// The store, and the one thing worth copying out of this example: **a row
/// owns an arena, and freeing the row is freeing the arena.**
///
/// An order holds a customer, an address and a list of lines, every one of
/// them holding text of its own. Written the obvious way that is a `free`
/// function with a dozen calls in it that has to be kept in step with the
/// types — and one that is wrong the first time a field is added. With an
/// arena per row there is nothing to keep in step: the row is built into it,
/// and `deinit` is the whole of freeing.
///
/// Rows are held by pointer rather than by value so that the list growing
/// never moves one. An `ArenaAllocator` that moves after something took its
/// `allocator()` leaves that handle pointing at where the arena used to be.
const Orders = struct {
    gpa: Allocator,
    lock: nilo.Mutex = .init,
    rows: std.ArrayList(*Row) = .empty,
    people: std.ArrayList(*Person) = .empty,
    next_id: u32 = 1,

    const Row = struct { memory: std.heap.ArenaAllocator, order: Order };
    const Person = struct { memory: std.heap.ArenaAllocator, customer: Customer };

    fn deinit(self: *Orders) void {
        for (self.rows.items) |row| {
            row.memory.deinit();
            self.gpa.destroy(row);
        }
        for (self.people.items) |person| {
            person.memory.deinit();
            self.gpa.destroy(person);
        }
        self.rows.deinit(self.gpa);
        self.people.deinit(self.gpa);
    }

    // ---- copying in ----
    //
    // Everything below the line takes `Str` and returns owned text. A
    // Service that never names `Str` in a field cannot accidentally keep
    // one; these functions name it in an argument, which is the safe half —
    // read now, copied now, never stored.

    fn keepCustomer(into: Allocator, from: NewCustomer) !Customer {
        return .{
            .code = try into.dupe(u8, from.code.view()),
            .name = try into.dupe(u8, from.name.view()),
            .email = try into.dupe(u8, from.email.view()),
        };
    }

    fn keepAddress(into: Allocator, from: NewAddress) !Address {
        return .{
            .line1 = try into.dupe(u8, from.line1.view()),
            .city = try into.dupe(u8, from.city.view()),
            .postcode = try into.dupe(u8, from.postcode.view()),
            .country = try into.dupe(u8, from.country.view()),
        };
    }

    // ---- copying out ----
    //
    // Every read hands back a copy in the request arena rather than a view
    // into the store. That is not caution: a handler returns to nilo, which
    // then writes the response — and between those two moments another
    // request on another thread can delete this order and free the arena the
    // text lived in. The copy is thrown away with the request, and costs one
    // walk of a structure that is about to be walked again anyway.

    fn copyOut(into: Allocator, order: Order) !Order {
        var copied = order;
        copied.customer = .{
            .code = try into.dupe(u8, order.customer.code),
            .name = try into.dupe(u8, order.customer.name),
            .email = try into.dupe(u8, order.customer.email),
        };
        copied.ship_to = .{
            .line1 = try into.dupe(u8, order.ship_to.line1),
            .city = try into.dupe(u8, order.ship_to.city),
            .postcode = try into.dupe(u8, order.ship_to.postcode),
            .country = try into.dupe(u8, order.ship_to.country),
        };
        const lines = try into.alloc(Line, order.lines.len);
        for (order.lines, lines) |from, *to| {
            to.* = from;
            to.sku = try into.dupe(u8, from.sku);
            to.name = try into.dupe(u8, from.name);
        }
        copied.lines = lines;
        if (order.note) |n| copied.note = try into.dupe(u8, n);
        return copied;
    }

    fn rowFor(self: *Orders, id: u32) ?*Row {
        for (self.rows.items) |row| {
            if (row.order.id == id) return row;
        }
        return null;
    }

    fn get(self: *Orders, into: Allocator, id: u32) !?Order {
        try self.lock.lock();
        defer self.lock.unlock();

        const row = self.rowFor(id) orelse return null;
        return try copyOut(into, row.order);
    }

    fn place(self: *Orders, into: Allocator, catalog: *const Catalog, incoming: NewOrder) !Order {
        const row = try self.gpa.create(Row);
        errdefer self.gpa.destroy(row);
        row.* = .{ .memory = .init(self.gpa), .order = undefined };
        errdefer row.memory.deinit();

        const mine = row.memory.allocator();
        const lines = try mine.alloc(Line, incoming.lines.len);
        var total: i64 = 0;
        for (incoming.lines, lines, 1..) |asked, *line, no| {
            const item = catalog.find(asked.sku.view()) orelse
                return fail.unprocessable("no such sku: {s}", .{asked.sku.view()});
            if (asked.quantity == 0) return fail.unprocessable("a line wants at least one of something", .{});
            line.* = .{
                .no = @intCast(no),
                .sku = try mine.dupe(u8, item.sku),
                .name = try mine.dupe(u8, item.name),
                .quantity = asked.quantity,
                .each_cents = item.each_cents,
            };
            total += item.each_cents * asked.quantity;
        }

        try self.lock.lock();
        defer self.lock.unlock();

        try self.rows.ensureUnusedCapacity(self.gpa, 1);
        row.order = .{
            .id = self.next_id,
            .stage = .draft,
            .priority = incoming.priority,
            .currency = incoming.currency,
            .customer = try keepCustomer(mine, incoming.customer),
            .ship_to = try keepAddress(mine, incoming.ship_to),
            .lines = lines,
            .total_cents = total,
            .note = if (incoming.note) |n| try mine.dupe(u8, n.view()) else null,
        };
        self.rows.appendAssumeCapacity(row);
        self.next_id += 1;
        return try copyOut(into, row.order);
    }

    fn addLine(self: *Orders, into: Allocator, catalog: *const Catalog, id: u32, asked: NewLine) !?Order {
        const item = catalog.find(asked.sku.view()) orelse
            return fail.unprocessable("no such sku: {s}", .{asked.sku.view()});

        try self.lock.lock();
        defer self.lock.unlock();

        const row = self.rowFor(id) orelse return null;
        if (row.order.stage != .draft) return error.Conflict;

        const mine = row.memory.allocator();
        // The old list is not freed, because an arena does not free — it is
        // dropped, and the row's whole arena goes when the row does. An
        // order edited a thousand times would want a different design; one
        // edited a handful of times wants this one.
        const grown = try mine.alloc(Line, row.order.lines.len + 1);
        @memcpy(grown[0..row.order.lines.len], row.order.lines);
        grown[grown.len - 1] = .{
            .no = nextLineNumber(row.order.lines),
            .sku = try mine.dupe(u8, item.sku),
            .name = try mine.dupe(u8, item.name),
            .quantity = asked.quantity,
            .each_cents = item.each_cents,
        };
        row.order.lines = grown;
        row.order.total_cents += item.each_cents * asked.quantity;
        return try copyOut(into, row.order);
    }

    fn dropLine(self: *Orders, id: u32, no: u16) !?bool {
        try self.lock.lock();
        defer self.lock.unlock();

        const row = self.rowFor(id) orelse return null;
        if (row.order.stage != .draft) return error.Conflict;

        for (row.order.lines, 0..) |line, at| {
            if (line.no != no) continue;
            const kept = try row.memory.allocator().alloc(Line, row.order.lines.len - 1);
            @memcpy(kept[0..at], row.order.lines[0..at]);
            @memcpy(kept[at..], row.order.lines[at + 1 ..]);
            row.order.total_cents -= line.each_cents * line.quantity;
            row.order.lines = kept;
            return true;
        }
        return false;
    }

    /// `error.Conflict` rather than `fail.conflict`: a store knows an
    /// illegal transition when it sees one and knows nothing about HTTP.
    /// nilo maps the error to a 409 on its own, and the handler above puts
    /// a sentence on it — so the store stays a store and the client still
    /// gets told what happened.
    fn advance(self: *Orders, into: Allocator, id: u32, to: Stage) !?Order {
        try self.lock.lock();
        defer self.lock.unlock();

        const row = self.rowFor(id) orelse return null;
        if (!mayGo(row.order.stage, to)) return error.Conflict;
        row.order.stage = to;
        return try copyOut(into, row.order);
    }

    fn edit(self: *Orders, into: Allocator, id: u32, incoming: EditOrder) !?Order {
        try self.lock.lock();
        defer self.lock.unlock();

        const row = self.rowFor(id) orelse return null;
        const mine = row.memory.allocator();

        switch (incoming.priority) {
            .absent => {},
            .cleared => return fail.unprocessable("an order always has a priority", .{}),
            .value => |v| row.order.priority = v,
        }
        switch (incoming.note) {
            .absent => {}, // not mentioned: leave it
            .cleared => row.order.note = null, // sent as null: empty it
            .value => |v| row.order.note = try mine.dupe(u8, v.view()),
        }
        if (incoming.ship_to.sent()) {
            const where = incoming.ship_to.orNull() orelse
                return fail.unprocessable("an order has to go somewhere", .{});
            row.order.ship_to = try keepAddress(mine, where);
        }
        return try copyOut(into, row.order);
    }

    /// The upsert: whether this made something or replaced something is not
    /// known until it has run, which is exactly the case `Response(T)`
    /// exists for and `Status(code, T)` cannot state.
    fn putCustomer(self: *Orders, into: Allocator, code: []const u8, incoming: NewCustomer) !struct {
        customer: Customer,
        created: bool,
    } {
        const person = try self.gpa.create(Person);
        errdefer self.gpa.destroy(person);
        person.* = .{ .memory = .init(self.gpa), .customer = undefined };
        errdefer person.memory.deinit();

        const mine = person.memory.allocator();
        person.customer = try keepCustomer(mine, incoming);
        person.customer.code = try mine.dupe(u8, code); // the path wins over the body

        try self.lock.lock();
        defer self.lock.unlock();

        for (self.people.items) |*held| {
            if (!std.mem.eql(u8, held.*.customer.code, code)) continue;
            // Replaced, and the old one's memory goes in one call.
            held.*.memory.deinit();
            self.gpa.destroy(held.*);
            held.* = person;
            return .{ .customer = try copyCustomer(into, person.customer), .created = false };
        }
        try self.people.append(self.gpa, person);
        return .{ .customer = try copyCustomer(into, person.customer), .created = true };
    }

    fn copyCustomer(into: Allocator, from: Customer) !Customer {
        return .{
            .code = try into.dupe(u8, from.code),
            .name = try into.dupe(u8, from.name),
            .email = try into.dupe(u8, from.email),
        };
    }

    fn list(self: *Orders, into: Allocator, filter: Filter, code: ?[]const u8) !Page(Order) {
        try self.lock.lock();
        defer self.lock.unlock();

        var matched: std.ArrayList(Order) = .empty;
        defer matched.deinit(into);
        for (self.rows.items) |row| {
            if (filter.stage) |wanted| {
                if (row.order.stage != wanted) continue;
            }
            if (code) |c| {
                if (!std.mem.eql(u8, row.order.customer.code, c)) continue;
            }
            try matched.append(into, row.order);
        }

        if (filter.sort == .total) {
            std.mem.sort(Order, matched.items, {}, struct {
                fn desc(_: void, a: Order, b: Order) bool {
                    return a.total_cents > b.total_cents;
                }
            }.desc);
        }

        const total = matched.items.len;
        const from = @min((filter.page - 1) * filter.per_page, total);
        const to = @min(from + filter.per_page, total);
        const window = matched.items[from..to];

        const items = try into.alloc(Order, window.len);
        for (window, items) |row, *out| out.* = try copyOut(into, row);

        return .{
            .items = items,
            .total = total,
            .page = filter.page,
            .next = if (to < total) filter.page + 1 else null,
        };
    }

    /// Deliberately slow, and deliberately not written to be fast: it stands
    /// in for the report that goes to a database and takes a second. What
    /// matters is where it is called from — see `daily` below.
    fn summarise(self: *Orders) !Summary {
        self.lock.lock() catch return error.Canceled;
        defer self.lock.unlock();

        var summary = Summary{ .orders = self.rows.items.len, .revenue_cents = 0, .by_stage = .{} };
        for (self.rows.items) |row| {
            summary.revenue_cents += row.order.total_cents;
            switch (row.order.stage) {
                .draft => summary.by_stage.draft += 1,
                .placed => summary.by_stage.placed += 1,
                .@"packed" => summary.by_stage.@"packed" += 1,
                .shipped => summary.by_stage.shipped += 1,
                .cancelled => summary.by_stage.cancelled += 1,
            }
        }
        return summary;
    }
};

fn nextLineNumber(lines: []const Line) u16 {
    var highest: u16 = 0;
    for (lines) |line| highest = @max(highest, line.no);
    return highest + 1;
}

/// The state machine, as a function rather than a table: what a wrong move
/// answers is the interesting part, and that is in the handler.
fn mayGo(from: Stage, to: Stage) bool {
    if (from == to) return false;
    return switch (from) {
        .draft => to == .placed or to == .cancelled,
        .placed => to == .@"packed" or to == .cancelled,
        .@"packed" => to == .shipped or to == .cancelled,
        .shipped, .cancelled => false,
    };
}

/// A second service, written to by handlers that have already written to the
/// first. Two locks held one after the other rather than one around both,
/// which is the whole reason it is a separate service.
const Audit = struct {
    lock: nilo.Mutex = .init,
    entries: [64]Entry = undefined,
    written: usize = 0,

    const Entry = struct { order: u32, from: Stage, to: Stage, by: []const u8 };

    fn note(self: *Audit, entry: Entry) void {
        self.lock.lock() catch return; // a cancelled request is not worth failing over
        defer self.lock.unlock();
        self.entries[self.written % self.entries.len] = entry;
        self.written += 1;
    }

    fn recent(self: *Audit, into: Allocator) ![]const Entry {
        try self.lock.lock();
        defer self.lock.unlock();
        const held = @min(self.written, self.entries.len);
        return try into.dupe(Entry, self.entries[0..held]);
    }
};

// ---- who is asking ----

const Scope = enum { viewer, packer, admin };

/// A third service, and the one the resolver below needs. A resolver is not
/// a special kind of function: it takes a `*Ctx` and whatever services it
/// names, exactly as a handler does.
const Keys = struct {
    known: []const Key,

    const Key = struct { token: []const u8, name: []const u8, scope: Scope };

    fn lookUp(self: *const Keys, token: []const u8) ?Key {
        for (self.known) |key| {
            if (std.mem.eql(u8, key.token, token)) return key;
        }
        return null;
    }
};

const Caller = struct {
    pub const nilo_resolve = identify;

    name: []const u8,
    scope: Scope,
};

fn identify(c: *nilo.Ctx, keys: *const Keys) !Caller {
    const header = c.header("Authorization") orelse
        return fail.unauthorized("this endpoint wants an Authorization header", .{});
    const bearer = "Bearer ";
    const raw = header.view();
    if (!std.mem.startsWith(u8, raw, bearer)) {
        return fail.unauthorized("the Authorization header has to say \"Bearer <token>\"", .{});
    }
    const key = keys.lookUp(raw[bearer.len..]) orelse
        return fail.forbidden("that token is not one of ours", .{});
    return .{ .name = key.name, .scope = key.scope };
}

/// Middleware written by a function, so the scope is part of the
/// registration rather than a copy of the same six lines per level. The
/// returned value is a plain function pointer — there is nothing to allocate
/// and nothing to free, because `wanted` is comptime and lives in the
/// generated function rather than in a closure.
fn needs(comptime wanted: Scope) nilo.Middleware {
    return struct {
        fn check(c: *nilo.Ctx, next: nilo.Next) !void {
            const caller = try c.resolve(Caller);
            if (@intFromEnum(caller.scope) < @intFromEnum(wanted)) {
                return fail.forbidden(
                    "{s} is a {s}; this endpoint wants the {s} scope",
                    .{ caller.name, @tagName(caller.scope), @tagName(wanted) },
                );
            }
            return next.run(c);
        }
    }.check;
}

// ---- what arrives ----

const NewLine = struct {
    sku: Str,
    quantity: u16,
};

/// The body that makes the point: a struct inside it, another struct inside
/// it, and a list of structs inside it. A field wrong at any depth is named
/// where it is — `"ship_to.city"`, `"lines[1].quantity"` — rather than being
/// a 400 that says the body was bad and leaves the finding to you.
const NewOrder = struct {
    customer: NewCustomer,
    ship_to: NewAddress,
    lines: []const NewLine,
    priority: Priority = .normal,
    currency: Currency = .idr,
    note: ?Str = null,
};

/// A PATCH body where one of the three-state fields holds a whole struct.
/// `Patch(NewAddress)` is the same three answers as `Patch(Str)`: not
/// mentioned, sent as null, sent as an address.
const EditOrder = struct {
    priority: nilo.Patch(Priority) = .absent,
    note: nilo.Patch(Str) = .absent,
    ship_to: nilo.Patch(NewAddress) = .absent,
};

const Move = struct { to: Stage };

/// The query string, with an optional enum in it. `?stage=placed` filters,
/// `?stage=nonsense` is a 400 naming the five it could have been, and
/// leaving it out is null rather than a default that quietly means
/// something.
const Filter = struct {
    stage: ?Stage = null,
    sort: enum { id, total } = .id,
    page: u32 = 1,
    per_page: u32 = 20,
};

// ---- what goes back ----

/// A generic envelope, so `Page(Order)` and `Page(Customer)` are one
/// declaration. `Page_Order` is what it is called in the document — the
/// compiler writes `main.Page(main.Order)`, and that is read back into a
/// name rather than given up on.
fn Page(comptime T: type) type {
    return struct {
        items: []const T,
        total: usize,
        page: u32,
        /// Null on the last page, which is a client's whole stopping rule.
        next: ?u32,
    };
}

const Summary = struct {
    orders: usize,
    revenue_cents: i64,
    by_stage: struct {
        draft: u32 = 0,
        placed: u32 = 0,
        @"packed": u32 = 0,
        shipped: u32 = 0,
        cancelled: u32 = 0,
    },
};

// ---- handlers ----

fn listOrders(orders: *Orders, arena: Allocator, filter: nilo.Query(Filter)) !Page(Order) {
    return orders.list(arena, filter.value, null);
}

/// Two services, the request arena and a body, in one argument list. The
/// order they are written in is the order they read best in — nilo matches
/// them by type, not by position.
fn placeOrder(
    orders: *Orders,
    catalog: *const Catalog,
    arena: Allocator,
    incoming: NewOrder,
) !nilo.Status(201, Order) {
    if (incoming.lines.len == 0) return fail.unprocessable("an order needs at least one line", .{});

    const placed = try orders.place(arena, catalog, incoming);
    return .{
        .headers = .of(&.{.{
            .name = "Location",
            .value = try std.fmt.allocPrint(arena, "/v1/orders/{d}", .{placed.id}),
        }}),
        .value = placed,
    };
}

fn getOrder(orders: *Orders, arena: Allocator, id: u32) !?Order {
    return orders.get(arena, id);
}

fn editOrder(orders: *Orders, arena: Allocator, id: u32, incoming: EditOrder) !?Order {
    return orders.edit(arena, id, incoming);
}

/// A resource inside a resource. The path param is still positional and
/// still typed; there is just one of them.
fn addLine(
    orders: *Orders,
    catalog: *const Catalog,
    arena: Allocator,
    id: u32,
    asked: NewLine,
) !nilo.Status(201, Order) {
    const grown = orders.addLine(arena, catalog, id, asked) catch |err| switch (err) {
        error.Conflict => return fail.conflict("order {d} has been placed, so its lines are settled", .{id}),
        else => |other| return other,
    };
    return .{ .value = grown orelse return fail.notFound("no order {d}", .{id}) };
}

/// **Two** path params, in the order they appear in the pattern:
/// `/v1/orders/:id/lines/:no` hands `id` to the `u32` and `no` to the `u16`.
/// Get the order wrong and nothing warns you, which is the honest cost of
/// positional matching — the alternative is naming them, and naming them is
/// what `Query(T)` is for.
fn dropLine(orders: *Orders, id: u32, no: u16) !nilo.Status(204, void) {
    const dropped = orders.dropLine(id, no) catch |err| switch (err) {
        error.Conflict => return fail.conflict("order {d} has been placed, so its lines are settled", .{id}),
        else => |other| return other,
    };
    const found = dropped orelse return fail.notFound("no order {d}", .{id});
    if (!found) return fail.notFound("order {d} has no line {d}", .{ id, no });
    return .{};
}

/// The state machine's endpoint, and the shape worth copying: the store
/// answers `error.Conflict` because it knows the rule, and the handler turns
/// that into a sentence because it knows the words. Neither of them mentions
/// the number 409.
fn advanceOrder(
    orders: *Orders,
    audit: *Audit,
    arena: Allocator,
    caller: Caller,
    id: u32,
    move: Move,
) !?Order {
    const before = try orders.get(arena, id) orelse return null;

    const moved = orders.advance(arena, id, move.to) catch |err| switch (err) {
        error.Conflict => return fail.conflict(
            "an order that is {s} cannot go to {s}",
            .{ @tagName(before.stage), @tagName(move.to) },
        ),
        else => |other| return other,
    };

    audit.note(.{ .order = id, .from = before.stage, .to = move.to, .by = caller.name });
    return moved;
}

/// `Response(T)` rather than `Status(code, T)`, because which status this
/// answers with is not knowable until it has run. The generated document
/// says `default` for it, and that is the trade: a runtime status cannot be
/// in a type that is fixed at compile time ([ADR 0024]).
///
/// [ADR 0024]: ../../docs/adr/0024-a-failure-mode-belongs-in-the-return-type.md
fn putCustomer(
    orders: *Orders,
    arena: Allocator,
    code: Str,
    incoming: NewCustomer,
) !nilo.Response(Customer) {
    if (code.len() == 0) return fail.badRequest("a customer code cannot be empty", .{});

    const done = try orders.putCustomer(arena, code.view(), incoming);
    return .{
        .status = if (done.created) 201 else 200,
        .value = done.customer,
    };
}

/// A `Str` path param alongside a query struct: `/v1/customers/wati/orders?page=2`.
fn customerOrders(
    orders: *Orders,
    arena: Allocator,
    code: Str,
    filter: nilo.Query(Filter),
) !Page(Order) {
    return orders.list(arena, filter.value, code.view());
}

/// The one call in this file that would stop every other request sharing its
/// thread if it were made directly. `blocking` hands it to a pool and parks
/// only this request ([ADR 0014]) — and outside a server it simply calls the
/// function, so the test at the bottom is an ordinary call.
///
/// [ADR 0014]: ../../docs/adr/0014-blocking-calls-go-to-a-thread-pool.md
fn daily(orders: *Orders) !Summary {
    return nilo.blocking(Orders.summarise, .{orders});
}

fn auditTrail(audit: *Audit, arena: Allocator) ![]const Audit.Entry {
    return audit.recent(arena);
}

/// A body nobody wants in memory: read in pieces, counted, and thrown away.
/// This handler takes a `*Ctx` because there is no argument that means "the
/// body, in pieces" — and taking one has a price this example is the right
/// place to name: **a route that drops to `*Ctx` drops out of the generated
/// document.** Nothing at startup says so.
fn attachInvoice(c: *nilo.Ctx, orders: *Orders, arena: Allocator, id: u32) !void {
    if (try orders.get(arena, id) == null) return fail.notFound("no order {d}", .{id});

    var body = try c.bodyStreamWith(.{ .max_bytes = 8 * 1024 * 1024 });
    var digest = std.hash.Wyhash.init(0);
    var buf: [16 * 1024]u8 = undefined;
    while (try body.read(&buf)) |piece| digest.update(piece);

    try c.sendJson(202, .{
        .order = id,
        .bytes = body.seen(),
        .fingerprint = digest.final(),
    });
}

// ---- mounting ----

/// A plugin: everything about orders, registered against whatever it is
/// handed. `anytype` rather than `nilo.Group("/v1")` is what makes it
/// mountable anywhere — the prefix is part of a group's type, so spelling
/// the type spells the prefix.
fn mountOrders(group: anytype) !void {
    try group.get("/orders", listOrders);
    try group.post("/orders", placeOrder);
    try group.get("/orders/:id", getOrder);
    try group.patch("/orders/:id", editOrder);
    try group.post("/orders/:id/lines", addLine);
    try group.delete("/orders/:id/lines/:no", dropLine);
    try group.post("/orders/:id/advance", advanceOrder);
    try group.post("/orders/:id/invoice", attachInvoice);

    try group.put("/customers/:code", putCustomer);
    try group.get("/customers/:code/orders", customerOrders);
}

const shop = Catalog{ .items = &.{
    .{ .sku = "kopi-250", .name = "Kopi Gayo 250g", .each_cents = 8_500_000 },
    .{ .sku = "gula-1kg", .name = "Gula Aren 1kg", .each_cents = 4_200_000 },
    .{ .sku = "teh-100", .name = "Teh Melati 100g", .each_cents = 2_750_000 },
} };

const issued = Keys{ .known = &.{
    .{ .token = "viewer-key", .name = "tamu", .scope = .viewer },
    .{ .token = "packer-key", .name = "budi", .scope = .packer },
    .{ .token = "admin-key", .name = "wati", .scope = .admin },
} };

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var orders = Orders{ .gpa = gpa };
    defer orders.deinit();
    var audit = Audit{};

    var app = nilo.App.init(gpa);
    defer app.deinit();

    // Three services of three shapes: one written to under a lock, one
    // written to under a different lock, and two that are never written to
    // at all and so are provided as `*const`.
    try app.provide(&orders);
    try app.provide(&audit);
    try app.provide(@as(*const Catalog, &shop));
    try app.provide(@as(*const Keys, &issued));

    app.docs(.{
        .title = "Orders",
        .version = "1.0.0",
        .description = "Nested resources, nested bodies, and a state machine.",
    });

    try app.use(nilo.logger.standard);

    const v1 = app.group("/v1");
    // Everything under /v1 needs a token; the resolver decides who, and this
    // decides whether that is enough. A resolved value cannot enforce
    // anything on its own — only routes that name one get it — which is why
    // the pair is a resolver *and* a middleware.
    try v1.use(needs(.viewer));
    try mountOrders(v1);

    const reports = v1.group("/reports");
    try reports.use(needs(.admin));
    try reports.get("/daily", daily);
    try reports.get("/audit", auditTrail);

    try app.listen(.{});
}

// ---- tests ----

const testing = std.testing;

/// Declared here rather than written inside `sample()`, and this is not
/// tidiness. `&.{ … }` inside a function is a pointer to that function's
/// stack, and a `NewOrder` carrying one outlives the frame it points into:
/// the values are still there in a `Debug` build and are not in a release
/// one. That is [ADR 0019]'s bug, met from the other side — the suite runs
/// in both modes precisely so this fails somewhere rather than in
/// production.
///
/// [ADR 0019]: ../../docs/adr/0019-a-response-owns-its-headers.md
const sample_lines = [_]NewLine{
    .{ .sku = .static("kopi-250"), .quantity = 2 },
    .{ .sku = .static("gula-1kg"), .quantity = 1 },
};

const nonsense_lines = [_]NewLine{
    .{ .sku = .static("bukan-sku"), .quantity = 1 },
};

fn sample() NewOrder {
    return .{
        .customer = .{
            .code = .static("wati"),
            .name = .static("Wati"),
            .email = .static("wati@example.dev"),
        },
        .ship_to = .{
            .line1 = .static("Jl. Melati 4"),
            .city = .static("Bandung"),
            .postcode = .static("40115"),
            .country = .static("ID"),
        },
        .lines = &sample_lines,
    };
}

test "an order is priced from the catalog, not from the body" {
    var orders = Orders{ .gpa = testing.allocator };
    defer orders.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const placed = (try placeOrder(&orders, &shop, arena, sample())).value;
    try testing.expectEqual(@as(usize, 2), placed.lines.len);
    try testing.expectEqualStrings("Kopi Gayo 250g", placed.lines[0].name);
    try testing.expectEqual(@as(i64, 8_500_000 * 2 + 4_200_000), placed.total_cents);

    // A sku nobody sells is a 422 rather than a line priced at zero.
    var wrong = sample();
    wrong.lines = &nonsense_lines;
    try testing.expectError(error.Failed, placeOrder(&orders, &shop, arena, wrong));
}

test "the state machine refuses a move, and the refusal is a 409" {
    var orders = Orders{ .gpa = testing.allocator };
    defer orders.deinit();
    var audit = Audit{};

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const placed = (try placeOrder(&orders, &shop, arena, sample())).value;
    const caller = Caller{ .name = "wati", .scope = .admin };

    const moved = try advanceOrder(&orders, &audit, arena, caller, placed.id, .{ .to = .placed });
    try testing.expectEqual(Stage.placed, moved.?.stage);

    // Backwards is refused by the store, and the handler turns that into a
    // sentence. Both halves are ordinary function calls.
    try testing.expectError(
        error.Failed,
        advanceOrder(&orders, &audit, arena, caller, placed.id, .{ .to = .draft }),
    );

    // ...and the move that worked was written down, by name.
    const trail = try audit.recent(arena);
    try testing.expectEqual(@as(usize, 1), trail.len);
    try testing.expectEqualStrings("wati", trail[0].by);
}

test "a line can be added and dropped while an order is a draft, and not after" {
    var orders = Orders{ .gpa = testing.allocator };
    defer orders.deinit();
    var audit = Audit{};

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const placed = (try placeOrder(&orders, &shop, arena, sample())).value;

    const grown = (try addLine(&orders, &shop, arena, placed.id, .{
        .sku = .static("teh-100"),
        .quantity = 4,
    })).value;
    try testing.expectEqual(@as(usize, 3), grown.lines.len);
    try testing.expectEqual(@as(u16, 3), grown.lines[2].no);

    _ = try dropLine(&orders, placed.id, 1);
    const left = (try getOrder(&orders, arena, placed.id)).?;
    try testing.expectEqual(@as(usize, 2), left.lines.len);
    try testing.expectEqual(@as(i64, 4_200_000 + 2_750_000 * 4), left.total_cents);

    // A line number nobody has is a 404, and so is an order nobody has.
    try testing.expectError(error.Failed, dropLine(&orders, placed.id, 99));
    try testing.expectError(error.Failed, dropLine(&orders, 999, 1));

    // Once it is placed, the lines are settled.
    const caller = Caller{ .name = "wati", .scope = .admin };
    _ = try advanceOrder(&orders, &audit, arena, caller, placed.id, .{ .to = .placed });
    try testing.expectError(error.Failed, dropLine(&orders, placed.id, 2));
}

test "a PATCH tells a field left out from one sent as null, even when the field is a struct" {
    var orders = Orders{ .gpa = testing.allocator };
    defer orders.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const placed = (try placeOrder(&orders, &shop, arena, sample())).value;

    // Not mentioned: left alone.
    const kept = (try editOrder(&orders, arena, placed.id, .{
        .note = .{ .value = .static("leave it with the neighbour") },
    })).?;
    try testing.expectEqualStrings("Bandung", kept.ship_to.city);
    try testing.expectEqualStrings("leave it with the neighbour", kept.note.?);

    // Sent as null: cleared.
    const cleared = (try editOrder(&orders, arena, placed.id, .{ .note = .cleared })).?;
    try testing.expect(cleared.note == null);

    // A whole struct, sent.
    const moved = (try editOrder(&orders, arena, placed.id, .{
        .ship_to = .{ .value = .{
            .line1 = .static("Jl. Anggrek 9"),
            .city = .static("Bogor"),
            .postcode = .static("16111"),
            .country = .static("ID"),
        } },
    })).?;
    try testing.expectEqualStrings("Bogor", moved.ship_to.city);

    // A struct sent as null, where null makes no sense, is a 422 rather than
    // an order with no address.
    try testing.expectError(
        error.Failed,
        editOrder(&orders, arena, placed.id, .{ .ship_to = .cleared }),
    );
}

test "an upsert answers 201 the first time and 200 after that" {
    var orders = Orders{ .gpa = testing.allocator };
    defer orders.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const incoming = NewCustomer{
        .code = .static("ignored"),
        .name = .static("Budi"),
        .email = .static("budi@example.dev"),
    };

    const made = try putCustomer(&orders, arena, .static("budi"), incoming);
    try testing.expectEqual(@as(u16, 201), made.status);
    // The path wins over the body, so a mismatched code cannot make a
    // customer nobody can address.
    try testing.expectEqualStrings("budi", made.value.code);

    const again = try putCustomer(&orders, arena, .static("budi"), incoming);
    try testing.expectEqual(@as(u16, 200), again.status);
}

test "filtering and paging happen on a copy, and the page says where to go next" {
    var orders = Orders{ .gpa = testing.allocator };
    defer orders.deinit();
    var audit = Audit{};

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    for (0..3) |_| _ = try placeOrder(&orders, &shop, arena, sample());
    const caller = Caller{ .name = "wati", .scope = .admin };
    _ = try advanceOrder(&orders, &audit, arena, caller, 1, .{ .to = .placed });

    const first = try listOrders(&orders, arena, .{ .value = .{ .per_page = 2 } });
    try testing.expectEqual(@as(usize, 3), first.total);
    try testing.expectEqual(@as(usize, 2), first.items.len);
    try testing.expectEqual(@as(?u32, 2), first.next);

    const last = try listOrders(&orders, arena, .{ .value = .{ .per_page = 2, .page = 2 } });
    try testing.expectEqual(@as(usize, 1), last.items.len);
    try testing.expect(last.next == null);

    // The optional in the query means "no filter" rather than a default that
    // quietly picks one.
    const drafts = try listOrders(&orders, arena, .{ .value = .{ .stage = .draft } });
    try testing.expectEqual(@as(usize, 2), drafts.total);

    // Only the copy was sorted; the store is in the order things arrived.
    _ = try listOrders(&orders, arena, .{ .value = .{ .sort = .total } });
    try testing.expectEqual(@as(u32, 1), orders.rows.items[0].order.id);
}

test "a handler behind a scope is still an ordinary function" {
    var orders = Orders{ .gpa = testing.allocator };
    defer orders.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    _ = try placeOrder(&orders, &shop, arena, sample());

    // `blocking` runs the call inline when there is no Engine under it, so
    // the report is a function call in a test and a pool job in a server.
    const summary = try daily(&orders);
    try testing.expectEqual(@as(usize, 1), summary.orders);
    try testing.expectEqual(@as(u32, 1), summary.by_stage.draft);
}

test "the document names every shape that has a name, and the paths that have params" {
    var orders = Orders{ .gpa = testing.allocator };
    defer orders.deinit();

    var app = nilo.App.init(testing.allocator);
    defer app.deinit();

    try app.provide(&orders);
    try app.provide(@as(*const Catalog, &shop));
    app.docs(.{ .title = "Orders", .version = "1.0.0" });
    try mountOrders(app.group("/v1"));

    var client = try nilo.testing.Client.init(testing.allocator, .{ .response_bytes = 256 * 1024 });
    defer client.deinit();

    const answer = try client.get(&app, "/openapi.json");
    try testing.expectEqual(@as(u16, 200), answer.status);
    const document = answer.body;

    // A path param becomes a path param, whichever depth it is at.
    try testing.expect(std.mem.indexOf(u8, document, "/v1/orders/{id}/lines/{no}") != null);
    try testing.expect(std.mem.indexOf(u8, document, "/v1/customers/{code}/orders") != null);

    // A shape used more than once is named once and referred to after that.
    try testing.expect(std.mem.indexOf(u8, document, "\"Order\":{") != null);
    try testing.expect(std.mem.indexOf(u8, document, "#/components/schemas/Order") != null);
    try testing.expect(std.mem.indexOf(u8, document, "#/components/schemas/Line") != null);

    // Including the shapes that are generic, which is what makes writing one
    // `Addressed(Text)` instead of two `Address` structs a free choice.
    try testing.expect(std.mem.indexOf(u8, document, "#/components/schemas/Page_Order") != null);
    try testing.expect(std.mem.indexOf(u8, document, "#/components/schemas/Addressed_Str") != null);
    try testing.expect(std.mem.indexOf(u8, document, "#/components/schemas/Addressed_Text") != null);

    // An enum is the list of what it may be, keyword or no keyword.
    try testing.expect(std.mem.indexOf(u8, document, "\"enum\":[\"draft\",\"placed\",\"packed\"") != null);

    // The statuses that are in the signatures are in the document.
    try testing.expect(std.mem.indexOf(u8, document, "\"201\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "\"204\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "\"404\"") != null);

    // And the route that writes its own response says so, rather than
    // claiming the empty 200 its return type would otherwise imply.
    try testing.expect(std.mem.indexOf(u8, document, "writes its own response") != null);
}
