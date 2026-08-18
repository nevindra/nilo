//! nilo's JSON reader asked for by a type that never said its JSON was spelled
//! differently. There is nothing for the reader to do that `std.json` does not
//! already do, so the line is either premature or the marker is missing.

const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const jsonParse = nilo.jsonParseFor(@This());

    metrics: struct { threshold: f64 },
    logs: struct { query: []const u8 },
};

comptime {
    // The reader is refused where it is written, so referring to the
    // declaration is the whole of what it takes to reach it.
    _ = Condition.jsonParse;
}
