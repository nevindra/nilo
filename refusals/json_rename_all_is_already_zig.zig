//! Asking for the case a Zig field name is already written in. It would change
//! nothing, so writing it means expecting something else — usually the shouted
//! version, which is a different name.

const nilo = @import("nilo_http");

const Severity = enum {
    pub const nilo_json = .{ .rename_all = .snake_case };

    info,
    not_reported,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Severity);
}
