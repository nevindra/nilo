//! Two values that a case maps onto one name. `.lowercase` joins the words
//! rather than keeping the underscore, so these two arrive on the wire as the
//! same string — and a reader matching it takes whichever the `inline for`
//! reaches first, which is declaration order and is written down nowhere.
//!
//! The sibling of `json_tag_collides_with_a_field`: a mistake that corrupts
//! the wire rather than failing.

const nilo = @import("nilo_http");

const Severity = enum {
    pub const nilo_json = .{ .rename_all = .lowercase };

    not_found,
    notfound,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Severity);
}
