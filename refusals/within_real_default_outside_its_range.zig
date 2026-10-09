//! A default a request could never have sent, on a real range
//! ([ADR 167](../docs/adr/167-a-whole-number-inside-a-range-is-a-type.md)).

const nilo = @import("nilo_http");

const Body = struct {
    score: nilo.Within(0.0, 1.0) = .of(1.5),
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Body);
}
