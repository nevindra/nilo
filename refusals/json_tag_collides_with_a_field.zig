//! A discriminator whose name a variant already uses. Both would be written
//! into one object under one key, and which of the two a reader keeps is its
//! own business — the one mistake here that corrupts the wire rather than
//! failing.

const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "kind" };

    metrics: struct { kind: []const u8, threshold: f64 },
    logs: struct { query: []const u8 },
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
