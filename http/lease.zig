//! A count of the responses still reading from one generation of a followed
//! static directory (ADR 277).
//!
//! A followed directory is replaced as a whole when a file changes, and the
//! generation it replaces cannot be freed while a response is still being
//! written from its bytes: on HTTP/1.1 that is until the handler returns, on
//! HTTP/2 until the stream is let go of, which is after the handler returned
//! and for as long as the client's window takes. This is the number that says
//! so. It is the whole of the cost a request pays for a directory that
//! follows the disk: two atomic operations on a word that sits in the
//! generation, and nothing allocated.
//!
//! It is not a general reference count. Nothing is freed when it reaches
//! zero: the thread that swapped the generations looks, on its own schedule,
//! and frees a retired one that is at zero (`follow.Follower.reap`). That is
//! what keeps a request thread from ever freeing bytes, or running a
//! destructor, in the middle of a response.

const std = @import("std");

pub const Lease = struct {
    refs: std.atomic.Value(u32) = .init(0),

    /// Counted before the generation is trusted: `follow.Follower.enter`
    /// takes it and then looks again at which generation is live, and a
    /// generation that is not any more is let go of unread.
    pub fn retain(self: *Lease) void {
        _ = self.refs.fetchAdd(1, .seq_cst);
    }

    /// Given back. Never frees anything (see the header).
    pub fn release(self: *Lease) void {
        const was = self.refs.fetchSub(1, .seq_cst);
        std.debug.assert(was > 0);
    }

    /// How many responses hold it now.
    pub fn held(self: *const Lease) u32 {
        return self.refs.load(.seq_cst);
    }
};

test "a lease counts what holds it and says when nothing does" {
    var lease: Lease = .{};
    try std.testing.expectEqual(@as(u32, 0), lease.held());
    lease.retain();
    lease.retain();
    try std.testing.expectEqual(@as(u32, 2), lease.held());
    lease.release();
    lease.release();
    try std.testing.expectEqual(@as(u32, 0), lease.held());
}
