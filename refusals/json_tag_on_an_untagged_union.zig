//! A discriminator on a union with no tag. Nothing in the value says which arm
//! is live, so there is nothing for nilo to write the name of — the same reason
//! the API description gives one `{}` (ADR 0077).

const nilo = @import("nilo_http");

const Condition = union {
    pub const nilo_json = .{ .tag = "signal" };

    metrics: f64,
    logs: u32,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
