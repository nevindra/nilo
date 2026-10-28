//! A `nilo_field` that hands back something other than the entry type the
//! shape lists (ADR 024).

const nilo = @import("nilo_http");

const ApiError = struct {
    code: u16,
    errors: []const Err,

    const Err = struct {
        path: []const u8,

        pub fn nilo_field(f: nilo.FieldFailure) []const u8 {
            return f.field;
        }
    };

    pub fn nilo_failure(status: u16, message: []const u8, errors: []const Err) ApiError {
        _ = message;
        return .{ .code = status, .errors = errors };
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.failures(ApiError) catch {};
}
