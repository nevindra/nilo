//! A default a request could never have sent, on a list with a length
//! ([ADR 266](../docs/adr/266-a-list-with-a-length-is-a-type.md)).

const nilo = @import("nilo_http");

const Body = struct {
    tags: nilo.Many(u32, .{ .min = 1, .max = 3 }) = .of(&.{}),
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Body);
}
