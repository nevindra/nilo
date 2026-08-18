//! A type that writes its own JSON and says so wrong. `nilo_openapi` exists to
//! name the JSON the custom writer sends (ADR 0076), and `type` is the one
//! thing it has to carry — without it nothing has been said.

const nilo = @import("nilo_http");

const Uuid = struct {
    bytes: [16]u8,

    // `format` alone says how the thing is spelled without saying what it is.
    pub const nilo_openapi = .{ .format = "uuid" };

    pub fn jsonStringify(_: Uuid, jw: anytype) !void {
        try jw.write("00000000-0000-0000-0000-000000000000");
    }
};

const Account = struct { public: Uuid };

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Account);
}
