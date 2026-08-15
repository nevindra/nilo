//! A file asked for as an argument of its own. A file arrives as one field
//! of a form, so it belongs inside the struct the form is read into.

const zfast = @import("zfast");

fn uploadAvatar(image: zfast.Upload) u32 {
    _ = image;
    return 0;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/avatars", uploadAvatar) catch {};
}
