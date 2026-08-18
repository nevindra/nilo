//! A marker written as something other than a struct. `nilo_json` says how a
//! type's JSON is spelled (ADR 0085), and everything it can say is a field, so
//! there is nowhere for a bare value to go.

const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = 3;

    metrics: struct { threshold: f64 },
    logs: struct { query: []const u8 },
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
