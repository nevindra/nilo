//! Origins named in two places at once. `cors.reading` takes its list from
//! the `Origins` it was handed, so the `.origins` field would be ignored —
//! and an ignored list is one somebody edits and then wonders about.

const nilo = @import("nilo_http");

var origins: nilo.cors.Origins = .empty;

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.reading(&origins, .{
        .origins = &.{"https://example.com"},
        .credentials = true,
    })) catch {};
}
