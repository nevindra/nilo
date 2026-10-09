//! A form field whose type no form body can carry. The fields are held to
//! `withQuery`'s rules, so a struct is refused by name here too rather than
//! written in some convention nilo made up.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

const When = struct { year: u16, month: u8 };

export fn refusal() void {
    var client: fetch.Client = undefined;
    var run: core.Run = undefined;
    const when: When = .{ .year = 2026, .month = 9 };
    _ = client.postForm(&run, "https://auth.example.com/token", .{ .grant_type = "client_credentials", .when = when }, .{}) catch {};
}
