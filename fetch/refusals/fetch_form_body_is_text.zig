//! A body already encoded, handed to `postForm`. The call writes the
//! fields itself, and text has none; a body already encoded goes through
//! `post` with the `content-type` said.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

export fn refusal() void {
    var client: fetch.Client = undefined;
    var run: core.Run = undefined;
    _ = client.postForm(&run, "https://auth.example.com/token", "grant_type=client_credentials", .{}) catch {};
}
