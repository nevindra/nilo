//! Spawned work handed a struct, behind a pointer, that holds a `Str` in a
//! list. The walk goes through pointers, slices and fields, and a struct that
//! points to itself does not make it loop.

const nilo = @import("nilo_http");

const Entry = struct {
    next: ?*Entry,
    tags: []const Tag,
};
const Tag = struct { name: nilo.Str };

fn audit(entry: *Entry) void {
    _ = entry;
}

export fn refusal() void {
    nilo.spawn(audit, .{@as(*Entry, undefined)}) catch {};
}
