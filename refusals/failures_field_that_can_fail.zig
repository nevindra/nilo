//! A `nilo_field` that can fail. The failure path must not have a failure
//! path of its own (ADR 024), so the function that maps one entry is handed
//! it and hands the type back, and nothing else.

const nilo = @import("nilo_http");

const ApiError = struct {
    code: u16,
    errors: []const Err,

    const Err = struct {
        path: []const u8,

        pub fn nilo_field(f: nilo.FieldFailure) !Err {
            return .{ .path = f.field };
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
