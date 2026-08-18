//! A discriminator on a type that has no variants. `tag` puts the name of the
//! live variant into the JSON, and a struct is only ever itself, so there is no
//! name for it to write.

const nilo = @import("nilo_http");

const Condition = struct {
    pub const nilo_json = .{ .tag = "signal" };

    metric_name: []const u8,
    threshold: f64,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
