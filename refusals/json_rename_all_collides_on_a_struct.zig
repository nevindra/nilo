//! Two fields that a case maps onto one key. `.lowercase` joins the words
//! rather than keeping the underscore, so both of these arrive on the wire as
//! the same string — and an object carrying one key twice is read as whichever
//! the reader met last.
//!
//! The sibling of `json_rename_all_collides_on_an_enum`, one type shape over:
//! a mistake that corrupts the wire rather than failing (ADR 0181).

const nilo = @import("nilo_http");

const Contact = struct {
    pub const nilo_json = .{ .rename_all = .lowercase };

    full_name: []const u8,
    fullname: []const u8,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Contact);
}
