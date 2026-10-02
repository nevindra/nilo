//! Answering gRPC from a build that was not asked for it. A call is collected
//! through a framing only `.grpc = true` compiles in, so without it the path
//! a call would take does not exist, and reaching it in ReleaseFast would be
//! undefined behaviour rather than an error.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    _ = app.grpcHost();
}
