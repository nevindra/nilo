//! A `nilo_failure` whose third parameter is not a slice. The fields that did
//! not fit arrive as a `[]const E` (ADR 024), not as one entry or a count.

const nilo = @import("nilo_http");

const ApiError = struct {
    code: u16,
    detail: []const u8,

    pub fn nilo_failure(status: u16, message: []const u8, fields: usize) ApiError {
        _ = fields;
        return .{ .code = status, .detail = message };
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.failures(ApiError) catch {};
}
