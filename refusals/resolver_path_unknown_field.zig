//! A resolver's `Path(T)` is held against the route of the handler that asks
//! for it (ADR 015): `:team` is not a param of this route.

const nilo = @import("nilo_http");

const InTeam = struct {
    pub const nilo_resolve = teamOf;

    team: u32,
};

const TeamParams = struct { team: u32 };

fn teamOf(p: nilo.Path(TeamParams)) InTeam {
    return .{ .team = p.value.team };
}

fn show(scope: InTeam) u32 {
    return scope.team;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orgs/:org", show) catch {};
}
