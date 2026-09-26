//! A filtered sum read as a plain number. Its column is never null, and still
//! a group none of whose rows meets the `.where` sums nothing, which is null:
//! a customer with no rupiah deal has no rupiah total, not a total of zero.

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
    pub const nilo_aggregate = .{ .idr = .{ .sum = .amount_minor, .where = .{ .currency = "IDR" } } };

    customer: CustomerName,
    idr: i64,
};

export fn refusal() void {
    _ = sql.selectFor(ByCustomer, @TypeOf(.{}));
}
