//! `.order` on a grouped Row naming a column of its table the Row does not
//! carry. A narrower Row that is not grouped may do this, because every row
//! of the table is a row of its answer; a grouped one is one row per group,
//! and the column has no single value there to sort by.

const sql = @import("nilo_sql");

const Customer = struct {
    pub const nilo_table = .{ .name = "customers", .key = .id };

    id: i64,
    name: []const u8,
};

const Order = struct {
    pub const nilo_table = .{
        .name = "orders",
        .key = .id,
        .references = .{ .customer_id = .{ Customer, .id } },
    };

    id: i64,
    customer_id: i64,
    total: i64,
    year: i32,
};

const CustomerName = struct {
    pub const nilo_table = Customer;

    name: []const u8,
};

const ByCustomer = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{ .revenue = .{ .sum = .total } };

    customer: CustomerName,
    revenue: i64,
};

export fn refusal() void {
    _ = sql.selectFor(ByCustomer, @TypeOf(.{ .order = .{ .year = .desc } }));
}
