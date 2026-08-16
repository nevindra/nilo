//! A file asked for as an argument of its own. A file arrives as one field
//! of a form, so it belongs inside the struct the form is read into.

const nilo = @import("nilo");

fn uploadAvatar(image: nilo.Upload) u32 {
    _ = image;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/avatars", uploadAvatar) catch {};
}
