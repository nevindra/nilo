//! A discriminator with no name. The variant's name would go out under `""`,
//! which is legal JSON and nothing a reader can be expected to look for.

const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "" };

    metrics: struct { threshold: f64 },
    logs: struct { query: []const u8 },
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
