//! A handler asking for a JSON body and a form at once. They are the same
//! bytes read two ways, so a request has one or the other and never both.

const nilo = @import("nilo");

const Profile = struct { bio: nilo.Str };
const SignUp = struct { email: nilo.Str };

fn signUp(profile: Profile, incoming: nilo.Form(SignUp)) u32 {
    _ = profile;
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
