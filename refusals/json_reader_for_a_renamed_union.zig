//! A union that renames its variants without tagging them, handing nilo the
//! reader anyway. Renaming moves the key `std.json` looks for, and with no
//! discriminator there is nothing for nilo to find the variant by on the way
//! back in.

const nilo = @import("nilo_http");

const Channel = union(enum) {
    pub const nilo_json = .{ .rename_all = .@"kebab-case" };
    pub const jsonParse = nilo.jsonParseFor(@This());

    web_hook: struct { url: []const u8 },
    discord_dm: struct { user: []const u8 },
};

comptime {
    // The reader is refused where it is written, so referring to the
    // declaration is the whole of what it takes to reach it.
    _ = Channel.jsonParse;
}
