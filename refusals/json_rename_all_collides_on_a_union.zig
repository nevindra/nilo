//! The same collision one type over, where the name is a variant's rather
//! than an enum value's. `.UPPERCASE` drops the underscore the way
//! `.lowercase` does, so both of these go out as `WEBHOOK` and the tag stops
//! saying which arm is live.

const nilo = @import("nilo_http");

const Channel = union(enum) {
    pub const nilo_json = .{ .tag = "kind", .rename_all = .UPPERCASE };

    web_hook: struct { target_url: []const u8 },
    webhook: struct { url: []const u8 },
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Channel);
}
