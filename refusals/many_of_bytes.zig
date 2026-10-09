//! `Many(u8, …)` is bytes, and bytes are text in a request
//! ([ADR 266](../docs/adr/266-a-list-with-a-length-is-a-type.md)).

const nilo = @import("nilo_http");

const Body = struct {
    name: nilo.Many(u8, .{ .max = 10 }),
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Body);
}
