//! A `nilo_failure` with a parameter nilo has no value for. It takes the
//! status and the sentence, or those two and the fields that did not fit
//! (ADR 024); a fourth has nothing to be filled from.

const nilo = @import("nilo_http");

const ApiError = struct {
    code: u16,
    detail: []const u8,

    pub fn nilo_failure(status: u16, message: []const u8, fields: []const nilo.FieldFailure, extra: u8) ApiError {
        _ = fields;
        _ = extra;
        return .{ .code = status, .detail = message };
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.failures(ApiError) catch {};
}
