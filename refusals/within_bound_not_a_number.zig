//! `Within` with a bound that is not a number, which would otherwise be a
//! comparison error inside nilo ([ADR 167](../docs/adr/167-a-whole-number-inside-a-range-is-a-type.md)).

const nilo = @import("nilo_http");

const Query = struct {
    limit: nilo.Within("1", 200),
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Query);
}
