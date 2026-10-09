//! `Many(…, .{ .min = 5, .max = 1 })`: a count nothing is inside
//! ([ADR 266](../docs/adr/266-a-list-with-a-length-is-a-type.md)).

const nilo = @import("nilo_http");

const Body = struct {
    tags: nilo.Many(nilo.Str, .{ .min = 5, .max = 1 }),
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Body);
}
