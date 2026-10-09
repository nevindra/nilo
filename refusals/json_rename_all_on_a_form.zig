//! A struct that renames its JSON keys read as a form. `nilo_json` is a
//! statement about JSON: a request body honours it in both directions, but a
//! form is read by the field names as they are written, so a browser posting
//! what the document promised would be a 400 naming every field (ADR 148).

const nilo = @import("nilo_http");

const NewContact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    full_name: []const u8,
};

fn addContact(incoming: nilo.Form(NewContact)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/contacts", addContact) catch {};
}
