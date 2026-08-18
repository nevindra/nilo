//! Reaching for serde's spelling. The attribute is `tag` in nilo, and a marker
//! field nobody reads would change nothing while looking like it had.

const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tagged = "signal" };

    metrics: struct { threshold: f64 },
    logs: struct { query: []const u8 },
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
