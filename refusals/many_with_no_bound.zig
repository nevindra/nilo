//! `Many(…, .{})` asks nothing of the count, so it is a slice with a longer
//! name ([ADR 266](../docs/adr/266-a-list-with-a-length-is-a-type.md)).

const nilo = @import("nilo_http");

const Body = struct {
    tags: nilo.Many(nilo.Str, .{}),
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Body);
}
