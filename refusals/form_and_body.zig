//! A handler asking for a JSON body and a form at once. They are the same
//! bytes read two ways, so a request has one or the other and never both.

const zfast = @import("zfast");

const Profile = struct { bio: zfast.Str };
const SignUp = struct { email: zfast.Str };

fn signUp(profile: Profile, incoming: zfast.Form(SignUp)) u32 {
    _ = profile;
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
