//! A marker with nothing in it. Written, presumably, to be filled in later —
//! and until it is, the type is spelled exactly as it would be with no marker
//! at all, which is the kind of silence ADR 0085 refuses.

const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{};

    metrics: struct { threshold: f64 },
    logs: struct { query: []const u8 },
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
