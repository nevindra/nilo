//! A `nilo_failure` that takes a list of a type of the application's own,
//! with nothing that says how to make one from a `nilo.FieldFailure`
//! (ADR 024).

const nilo = @import("nilo_http");

const ApiError = struct {
    code: u16,
    errors: []const Err,

    const Err = struct { path: []const u8 };

    pub fn nilo_failure(status: u16, message: []const u8, errors: []const Err) ApiError {
        _ = message;
        return .{ .code = status, .errors = errors };
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.failures(ApiError) catch {};
}
