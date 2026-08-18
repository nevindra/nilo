//! An internally tagged union whose variant holds a bare value. The encoding
//! puts the variant's own fields beside the discriminator, in one object, and a
//! `f64` has no fields to put there.

const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal" };

    metrics: f64,
    logs: struct { query: []const u8 },
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
