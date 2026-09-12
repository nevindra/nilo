//! A `nilo_ready` that takes no Scope, so it could never send the statement
//! that says whether the service is up
//! ([ADR 0192](../docs/adr/0192-a-health-route-asks-the-services.md)).

const nilo = @import("nilo_http");

const Mailer = struct {
    up: bool,

    pub fn nilo_ready(self: *Mailer) ?[]const u8 {
        return if (self.up) null else "down";
    }
};

export fn refusal() void {
    var mailer = Mailer{ .up = true };
    var app: nilo.App = undefined;
    app.provide(&mailer) catch {};
}
