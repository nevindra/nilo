//! A pattern in an aggregate's `.where`. The filter is written into the
//! statement with its values in it, so it takes the words a literal can say:
//! a value, null, the six comparisons, `.in` and `.not_in`. A search belongs
//! in the statement's own `.where`, where the text is bound.

const sql = @import("nilo_sql");

const Customer = struct {
    pub const nilo_table = .{ .name = "customers", .key = .id };

    id: i64,
    name: []const u8,
};

const Deal = struct {
    pub const nilo_table = .{
        .name = "deals",
        .key = .id,
        .references = .{ .customer_id = .{ Customer, .id } },
    };

    id: i64,
    customer_id: i64,
    currency: []const u8,
    amount_minor: i64,
};

const CustomerName = struct {
    pub const nilo_table = Customer;

    name: []const u8,
};

const ByCustomer = struct {
    pub const nilo_table = Deal;
    pub const nilo_aggregate = .{ .rupiah = .{ .count = .id, .where = .{ .currency = .{ .starts_with = "ID" } } } };

    customer: CustomerName,
    rupiah: i64,
};

export fn refusal() void {
    _ = sql.selectFor(ByCustomer, @TypeOf(.{}));
}
