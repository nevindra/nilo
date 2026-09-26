//! An aggregate entry that is only a `.where`. A condition narrows a
//! computation, and with none there is nothing it narrows. Counting the rows
//! that match names a column that is never null, `.{ .count = .id, .where = … }`,
//! which is the one spelling rather than a second one for the same count.

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
    pub const nilo_aggregate = .{ .foreign = .{ .where = .{ .currency = .{ .ne = "IDR" } } } };

    customer: CustomerName,
    foreign: i64,
};

export fn refusal() void {
    _ = sql.selectFor(ByCustomer, @TypeOf(.{}));
}
