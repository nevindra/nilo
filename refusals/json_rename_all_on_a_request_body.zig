//! A response spelling used for what comes in. `rename_all` on a struct renames
//! the keys nilo *writes* and the keys the API description promises; nothing
//! renames on the way in, because `std.json` chooses the parser for a body and
//! reads it into the field names as they are written.
//!
//! So this route would document `fullName`, and answer 400 to a client that
//! sent it. One direction that works beats two that can disagree about one
//! field (ADR 0181).

const nilo = @import("nilo_http");

const NewContact = struct {
    pub const nilo_json = .{ .rename_all = .camelCase };

    full_name: []const u8,
};

fn addContact(incoming: NewContact) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/contacts", addContact) catch {};
}
