//! A `Cached` over a store that takes the request's scope, the shape
//! `sql.Replays` has for `Idempotent`
//! ([ADR 268](../docs/adr/268-an-answer-kept-for-a-retry-is-a-row-when-instances-share-a-database.md)).
//! A page is read on every GET, which is a cache's job and not a round trip
//! to a database, and `Cached` calls its Space without a scope.

const nilo = @import("nilo_http");

const Shared = struct {
    pub const takes_scope = true;
    pub const max_bytes: usize = 4096;
};

fn page(key: nilo.Cached(Shared, .{ .ttl_s = 60 })) u32 {
    _ = key;
    return 1;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/pages", page) catch {};
}
