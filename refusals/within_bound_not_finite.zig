//! `Within` with a bound that is no number a request could be inside, which
//! would be a range with no end ([ADR 167](../docs/adr/167-a-whole-number-inside-a-range-is-a-type.md)).

const nilo = @import("nilo_http");

const Body = struct {
    score: nilo.Within(0.0, 1.0e400),
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Body);
}
