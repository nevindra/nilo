//! A case nilo does not write. The list is deliberately short — it holds the
//! transforms that are unambiguous from a Zig field name — so a name outside it
//! is a typo rather than a gap.

const nilo = @import("nilo_http");

const Severity = enum {
    pub const nilo_json = .{ .rename_all = .Titlecase };

    info,
    critical,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Severity);
}
