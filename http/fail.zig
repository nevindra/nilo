//! Fail functions — stop a request with a given status and message, from
//! anywhere, without having to hold a Ctx (ADR 004).
//!
//! ```zig
//! fn getUser(db: *Db, id: u32) !User {
//!     return db.find(id) orelse fail.notFound("no user {d}", .{id});
//! }
//! ```
//!
//! How it works: the message is written into the Failure belonging to the
//! request currently running, and `error.Failed` is returned. The App that
//! called the handler reads that Failure and assembles the response.
//!
//! The Failure is found through the Bulkhead's slot, which is bound to the
//! fiber — not to the thread — so two requests taking turns on one thread
//! can never overwrite each other's message (ADR 006). Called outside a
//! request there is no Failure, and a fail function just returns a plain
//! error with no message; handlers stay testable as ordinary functions.
//! Two places outside a request give it one anyway: `testing.Refusals`, so
//! a test can read the sentence, and the boot, so work registered with
//! `app.before` that is refused says why in the line that stops the server
//! (ADR 129).

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const watchdog = @import("watchdog.zig");

/// What the Failure's own slot holds. A message longer than this is kept
/// whole in the request arena when there is a request to hold it, up to
/// `max_long_message`, and cut here when there is not (ADR 024). The slot is
/// deliberately a fixed buffer: the common failure must not allocate, and fail
/// functions have to keep working when called outside a request, at the boot
/// or in a plain test, where there is no arena.
pub const max_message = 240;

/// The longest message a fail function keeps inside a request, in bytes. A
/// message is a sentence, or a list of problems an operator reads, not a body
/// dump: past this it is cut at a character boundary the way a message is cut
/// at `max_message` outside a request. 16 KiB is the most a client library
/// prints.
pub const max_long_message = 16 * 1024;

/// What `Failure.n` says when the message is in the request arena: the slot's
/// first bytes then hold the slice, so the struct does not grow (ADR 153
/// pinned its size at 256 bytes). A short message never has `n` this big.
const long_marker: u8 = 255;

/// What `Failure.n` says when the slot's first bytes hold a pointer to a
/// `Detail` in the request arena: the sentence and the fields that failed
/// (ADR 024). Below `long_marker` and above any length a message in the slot
/// can have, which is `max_message`.
const detail_marker: u8 = 254;

/// The most fields one failure carries. A form of sixty-four boxes is past what
/// a page shows, and the body that lists them is built in the arena, so the
/// bound is on what a request can ask the server to write (ADR 024). Past it
/// the sentence still counts every one.
pub const max_fields = 64;

/// Why one field of a request did not fit, in words a client can switch on.
///
/// **The tag names are public API** (ADR 024): they are what a form library
/// compares against in `fields[].code`, so one is never renamed or removed
/// without a `CHANGELOG.md` entry that says what a client changes. It is a
/// list of its own and not `Reason` shown through: `Reason` is what a
/// conversion can fail at inside nilo and may grow a case that a client has no
/// use for, while this is what a client is told (`bound.codeOf` maps one onto
/// the other in one `switch`).
pub const FieldCode = enum {
    /// What a nilo compile error calls this type (ADR 074).
    pub const nilo_type_name = "nilo.FieldCode";

    /// Nothing arrived under this name, and the field has no default and is
    /// not optional.
    missing,
    /// Something arrived and is not what the field takes: text where a
    /// number was wanted, a list where an object was, a value its own type
    /// refused. `expected` says what would have been taken.
    not_that_type,
    /// The field takes one of a list of words and this was not one of them.
    not_one_of,
    /// Several values arrived where the field takes one.
    too_many,
    /// The request names a field the endpoint does not take.
    unknown_field,
    /// A rule of the application's own did not hold (`nilo_check`, `must`).
    rule,
};

/// One field of a request that did not fit.
///
/// **The value the client sent is not a part of this**: it would reach a log
/// line or a frontend's error page, and a password is a field like any other.
/// What `message` quotes is whatever the sentence for the field already
/// quoted (`"age" has to be a whole number, not "soon"`), which is decided
/// where that sentence is written and never widened here.
pub const FieldFailure = struct {
    /// What a nilo compile error calls this type (ADR 074).
    pub const nilo_type_name = "nilo.FieldFailure";

    /// Where the field is, as the client spelled it on the wire: `email`,
    /// `address.city`, `items.0.qty`. The key a form library's `setError`
    /// takes.
    field: []const u8,
    code: FieldCode,
    /// nilo's own sentence for this field, the one the joined `error` is made
    /// of.
    message: []const u8,
    /// What the field would have taken, in the words the sentences use
    /// ("text", "a whole number", "one of newest, oldest"), when that is known.
    expected: ?[]const u8 = null,
};

/// What a failure with fields keeps in the request arena (ADR 024): the
/// sentence, which is also the whole of the message when nothing reads the
/// fields, and the list.
const Detail = struct {
    message: []const u8,
    fields: []const FieldFailure,
};

pub const Error = error{Failed};

/// Where a fail function's message lives for one request. App keeps one
/// per connection and clears it at the start of every request.
pub const Failure = struct {
    /// What a nilo compile error calls this type, which is the name the
    /// reader's own import line gives it (ADR 074).
    pub const nilo_type_name = "nilo.Failure";

    status: u16 = 0,
    /// A `u8` and not a `usize`, so that the pointer below fits in the
    /// padding this struct already had: `@sizeOf(Failure)` is 256 with or
    /// without it, and a connection holds one (ADR 153).
    n: u8 = 0,
    buf: [max_message]u8 = undefined,
    /// What a 401 says in `WWW-Authenticate`, when the failure came from
    /// an endpoint that takes an `Authorization` header (ADR 153). A
    /// comptime string, so a pointer is the whole of it.
    challenge: ?[*:0]const u8 = null,

    pub fn clear(self: *Failure) void {
        self.status = 0;
        self.n = 0;
        self.challenge = null;
    }

    pub fn isSet(self: *const Failure) bool {
        return self.status != 0;
    }

    /// The message, whole: in the slot, or in the request arena when it did
    /// not fit and a request was there to hold it (ADR 024). Valid until the
    /// request ends, which is as long as a Failure is read.
    pub fn message(self: *const Failure) []const u8 {
        if (self.n == detail_marker) return self.detail().message;
        if (self.n == long_marker) {
            var out: []const u8 = undefined;
            @memcpy(std.mem.asBytes(&out), self.buf[0..@sizeOf([]const u8)]);
            return out;
        }
        return self.buf[0..self.n];
    }

    /// The fields that failed, in the order the request's type declares them,
    /// or none: for a failure that was not about fields, outside a request
    /// (there is no arena to keep them in), and after `clear`. Valid until the
    /// request ends. This is the one list a body shape reads, and the list a
    /// failure shape of the application's own is handed (ADR 024).
    pub fn fields(self: *const Failure) []const FieldFailure {
        if (self.n != detail_marker) return &.{};
        return self.detail().fields;
    }

    fn detail(self: *const Failure) *const Detail {
        var out: *const Detail = undefined;
        @memcpy(std.mem.asBytes(&out), self.buf[0..@sizeOf(*const Detail)]);
        return out;
    }

    /// `setIn` for a failure that is about fields: the sentence stays what the
    /// log line and a gRPC call are told, and the list rides beside it in the
    /// request arena, behind a pointer in the slot's first bytes, so the
    /// struct does not grow (ADR 153 pinned it at 256). **An allocation on the
    /// failure path of a request that named fields, and no other**; if the
    /// arena has no room, or there is no request, it is the sentence alone,
    /// which is what every failure was before it carried a list.
    ///
    /// `listed` is copied, so a caller may build it on its stack; the strings
    /// it points at must live as long as the request.
    pub fn setFields(self: *Failure, request: *const InFlight, code: u16, sentence: []const u8, listed: []const FieldFailure) void {
        const kept = listed[0..@min(listed.len, max_fields)];
        if (kept.len != 0) if (keep(request, sentence, kept)) |stored| {
            self.status = code;
            @memcpy(self.buf[0..@sizeOf(*const Detail)], std.mem.asBytes(&stored));
            self.n = detail_marker;
            return;
        };
        self.setIn(request, code, "{s}", .{sentence});
    }

    fn keep(request: *const InFlight, sentence: []const u8, listed: []const FieldFailure) ?*const Detail {
        const text = sentence[0..wholeCharacters(sentence[0..@min(sentence.len, max_long_message)])];
        const detail_slot = allocAligned(request, Detail, 1) orelse return null;
        const array = allocAligned(request, FieldFailure, listed.len) orelse return null;
        const bytes = request.allocate(text.len) orelse return null;
        @memcpy(bytes, text);
        @memcpy(array, listed);
        detail_slot[0] = .{ .message = bytes, .fields = array };
        return &detail_slot[0];
    }

    /// Where the message goes when there is no request to hold a long one:
    /// the slot, cut at `max_message`.
    pub fn set(self: *Failure, code: u16, comptime fmt: []const u8, args: anytype) void {
        self.setIn(null, code, fmt, args);
    }

    /// `set`, with the request this Failure belongs to. The message is
    /// formatted once, through a writer that starts in the slot and, when the
    /// message outgrows it and a request is there to hold it, moves to the
    /// request's arena (`Spill.drain`) and keeps growing there up to
    /// `max_long_message`; the slot then holds where it is. An allocation on
    /// the failure path only, and only for a long message: the success path
    /// and the common failure see none. Where the arena cannot be had, or the
    /// bound is reached, it is the cut, as it always was.
    ///
    /// Formatting once is a binary size decision (ADR 017): this function is
    /// generic over `fmt` and `args`, so every call site instantiates the
    /// formatting path, and the spilling lives in the one non-generic
    /// `Spill.drain`. The price is that growth doubles, so the blocks it
    /// leaves behind stay in the arena until the request ends; a long message
    /// is a failure that is already off the hot path.
    pub fn setIn(self: *Failure, request: ?*const InFlight, code: u16, comptime fmt: []const u8, args: anytype) void {
        self.status = code;
        var spill = Spill.init(&self.buf, request);
        // An over-long message is truncated rather than dropped: half a
        // message is still far more use than a 500 with no explanation.
        spill.writer.print(fmt, args) catch {};
        self.finish(&spill);
    }

    noinline fn finish(self: *Failure, spill: *const Spill) void {
        const w = &spill.writer;
        // The cut falls wherever the buffer ends, which can be inside a
        // multi-byte character, and half of one is not text: the body that
        // carries it would not be JSON (ADR 024).
        const kept = w.buffer[0..wholeCharacters(w.buffered())];
        if (w.buffer.ptr == &self.buf) {
            self.n = @intCast(kept.len);
            return;
        }
        const out: []const u8 = kept;
        @memcpy(self.buf[0..@sizeOf([]const u8)], std.mem.asBytes(&out));
        self.n = long_marker;
    }
};

/// `n` values of `T` from the request arena, which hands out bytes and so is
/// asked for the room to align inside.
pub fn allocAligned(request: *const InFlight, comptime T: type, n: usize) ?[]T {
    const bytes = request.allocate(n * @sizeOf(T) + @alignOf(T) - 1) orelse return null;
    const start = std.mem.alignPointer(bytes.ptr, @alignOf(T)) orelse return null;
    return @as([*]T, @ptrCast(@alignCast(start)))[0..n];
}

/// Stop the request with `code`, naming the fields that did not fit. The
/// sentence is made by whoever calls (a joined one for several, the field's
/// own for one), and `listed` is what a body lists beside it (ADR 024). Called
/// outside a request there is nowhere to keep either, and it is the bare
/// error a fail function returns there too.
pub fn fieldsFailed(code: u16, sentence: []const u8, listed: []const FieldFailure) Error {
    if (inFlight()) |in_flight| in_flight.failure.setFields(in_flight, code, sentence, listed);
    return error.Failed;
}

/// The sentence for `total` fields that did not fit, made of the `listed`
/// ones' own: the field's sentence as it is for one, otherwise
/// `N fields did not fit: …; …`, ending in `; and K more` when the sentence
/// ran out of `buf` before the list did (ADR 034 gave `Bound` this shape).
/// Whole sentences only: one that does not fit is left out, never cut.
pub fn joinFields(buf: []u8, total: usize, listed: []const FieldFailure) []const u8 {
    if (total <= 1 and listed.len == 1) return listed[0].message;
    // Room kept back for the tail, so a sentence that runs out can still say
    // how much of itself is missing. Ten places is more than a count of
    // fields can need.
    const tail_room = "; and  more".len + 10;
    var w = std.Io.Writer.fixed(buf[0 .. buf.len - tail_room]);
    w.print("{d} fields did not fit: ", .{total}) catch {};
    var said: usize = 0;
    for (listed) |f| {
        const mark = w.end;
        if (said > 0) w.writeAll("; ") catch break;
        w.writeAll(f.message) catch {
            w.end = mark;
            break;
        };
        said += 1;
    }
    var out = std.Io.Writer.fixed(buf);
    out.end = w.end;
    if (said < total) out.print("{s}and {d} more", .{
        @as([]const u8, if (said == 0) "" else "; "),
        total - said,
    }) catch {};
    return buf[0..out.end];
}

/// Fields found one at a time while a body is read again to say what is wrong
/// with it, kept in the request arena (ADR 024). A walker adds what it finds
/// and goes on, so a client that sent three bad fields learns about three;
/// `refuse` then ends the request with all of them.
pub const FieldSink = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList(FieldFailure) = .empty,
    /// How many were found, which is more than `items` holds past
    /// `max_fields` or when the arena ran out.
    total: usize = 0,

    pub fn init(arena: std.mem.Allocator) FieldSink {
        return .{ .arena = arena };
    }

    /// One more field. `path` is spelled the way a message spells it, with
    /// `lines[2].qty` for a list element; the field is kept the way a form
    /// library spells it, `lines.2.qty`. An arena with no room costs the entry
    /// its place in the list and not its place in the count.
    pub fn add(
        self: *FieldSink,
        path: []const u8,
        code: FieldCode,
        expected: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        self.total += 1;
        if (self.items.items.len >= max_fields) return;
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch return;
        self.push(path, code, expected, message);
    }

    fn push(self: *FieldSink, path: []const u8, code: FieldCode, expected: ?[]const u8, message: []const u8) void {
        const field = wirePath(self.arena, path) catch return;
        self.items.append(self.arena, .{ .field = field, .code = code, .message = message, .expected = expected }) catch return;
    }

    /// End the request with `code`, naming everything added; null when
    /// nothing was kept, and then the error to answer with is the caller's.
    pub fn refuse(self: *FieldSink, code: u16) ?Error {
        if (self.items.items.len == 0) return null;
        var buf: [max_message]u8 = undefined;
        return fieldsFailed(code, joinFields(&buf, self.total, self.items.items), self.items.items);
    }
};

/// `lines[2].qty` as `lines.2.qty`. A path with no index in it is returned as
/// it is.
fn wirePath(arena: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, path, '[') == null) return path;
    const out = try arena.alloc(u8, path.len);
    var n: usize = 0;
    for (path) |ch| switch (ch) {
        '[' => {
            out[n] = '.';
            n += 1;
        },
        ']' => {},
        else => {
            out[n] = ch;
            n += 1;
        },
    };
    return out[0..n];
}

/// The writer a fail function formats into: the Failure's slot first, then
/// the request arena. One non-generic `drain` is the only copy of the
/// spilling in a binary (ADR 017).
const Spill = struct {
    writer: std.Io.Writer,
    request: ?*const InFlight,

    noinline fn init(slot: []u8, request: ?*const InFlight) Spill {
        return .{ .writer = .{ .buffer = slot, .vtable = &.{ .drain = drain } }, .request = request };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Spill = @fieldParentPtr("writer", w);
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| count += bytes.len;
        const pattern = data[data.len - 1];
        count += pattern.len * splat;

        if (count > w.buffer.len - w.end) {
            const want = @min(max_long_message, @max(w.buffer.len * 2, w.end + count));
            if (self.request) |in_flight| {
                if (want > w.buffer.len) {
                    if (in_flight.allocate(want)) |mem| {
                        @memcpy(mem[0..w.end], w.buffered());
                        w.buffer = mem;
                    }
                }
            }
        }
        // What does not fit the slot (no request, no arena) or the bound is
        // cut; the part that fits is kept.
        const fits = count <= w.buffer.len - w.end;
        var left = w.buffer.len - w.end;
        for (data[0 .. data.len - 1]) |bytes| left -= self.put(bytes, left);
        if (pattern.len != 0) for (0..splat) |_| {
            left -= self.put(pattern, left);
        };
        return if (fits) count else error.WriteFailed;
    }

    fn put(self: *Spill, bytes: []const u8, left: usize) usize {
        const n = @min(bytes.len, left);
        @memcpy(self.writer.buffer[self.writer.end..][0..n], bytes[0..n]);
        self.writer.end += n;
        return n;
    }
};

/// How much of `text` to keep so that it does not end inside a UTF-8
/// character: step back over continuation bytes to the lead byte, and drop
/// that too when the character it starts is not all there. Text that already
/// ends on a boundary, or is not UTF-8 at all, keeps its length.
pub fn wholeCharacters(text: []const u8) usize {
    var start = text.len;
    var back: usize = 0;
    while (start > 0 and back < 3 and text[start - 1] & 0xC0 == 0x80) : (back += 1) start -= 1;
    if (start == 0) return text.len;
    const need = std.unicode.utf8ByteSequenceLength(text[start - 1]) catch return text.len;
    return if (text.len - (start - 1) < need) start - 1 else text.len;
}

/// Everything nilo tracks about the request this fiber is serving. It is
/// what the Bulkhead slot points at, so anything reachable from anywhere —
/// a fail function, the panic handler (ADR 007) — finds it here.
pub const InFlight = struct {
    failure: Failure = .{},

    /// Whether this request is holding its thread (ADR 013). Here for the
    /// same reason everything else is: `nilo.blocking` has to find it from
    /// inside a call that knows nothing about the request it is part of.
    watch: watchdog.Watch = .{},

    /// The Ctx of this request and the one function that reads it, for the
    /// two things that must find the request from the fiber slot without
    /// knowing a Ctx: `nilo.logFn` (the id, ADR 262) and the panic handler
    /// (the request line, ADR 007). **Two words replace the method and path
    /// slices this struct held, which were four**, so a connection's frame,
    /// where this lives for as long as it waits for the next request, is
    /// 16 bytes smaller than it was (ADR 062). Opaque because `ctx.zig`
    /// imports this file; set by `serve.serveRequest` once the Ctx exists and
    /// cleared when it returns, so nothing is named between two requests. The
    /// id is looked up only when a line is written, which keeps a request
    /// that logs nothing from paying for one.
    request: ?*anyopaque = null,
    request_ops: ?*const RequestOps = null,

    /// Set by the connection loop on the request that is the connection's
    /// last under `max_requests_per_connection` (ADR 275): the answer then
    /// carries `Connection: close` as if the client had asked for it. Here
    /// because this struct is what the loop already hands every request, so
    /// it costs `serveRequest` no parameter; one byte in a frame whose
    /// padding it fits in.
    closing: bool = false,

    pub const Part = enum { id, method, path };

    /// What `request` can be asked, in one pointer so the slot's size is what
    /// it was: a part of the request, and bytes from its arena, which is
    /// what a message too long for the Failure's slot is kept in (ADR 024).
    pub const RequestOps = struct {
        read: *const fn (*anyopaque, Part) []const u8,
        alloc: *const fn (*anyopaque, usize) ?[]u8,
    };

    /// `n` bytes of this request's arena, or null outside a request or when
    /// it has none to give.
    pub fn allocate(self: *const InFlight, n: usize) ?[]u8 {
        const ops = self.request_ops orelse return null;
        return ops.alloc(self.request orelse return null, n);
    }

    pub fn startRequest(self: *InFlight) void {
        self.failure.clear();
        self.request = null;
    }

    fn part(self: *const InFlight, which: Part) ?[]const u8 {
        const ops = self.request_ops orelse return null;
        return ops.read(self.request orelse return null, which);
    }

    /// The id of the request this is serving, or null when there is none.
    pub fn requestId(self: *const InFlight) ?[]const u8 {
        return self.part(.id);
    }

    /// The method and path, for a crash report; null outside a request.
    pub fn requestLine(self: *const InFlight) ?struct { method: []const u8, path: []const u8 } {
        return .{ .method = self.part(.method) orelse return null, .path = self.part(.path) orelse return null };
    }
};

/// What this fiber is serving, or null outside a request.
pub fn inFlight() ?*InFlight {
    const p = bulkhead.slot() orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The Failure belonging to the request currently running, or null when
/// there is no request.
pub fn current() ?*Failure {
    return &(inFlight() orelse return null).failure;
}

/// Stop the request with any status.
pub fn status(code: u16, comptime fmt: []const u8, args: anytype) Error {
    if (inFlight()) |in_flight| in_flight.failure.setIn(in_flight, code, fmt, args);
    return error.Failed;
}

pub fn badRequest(comptime fmt: []const u8, args: anytype) Error {
    return status(400, fmt, args);
}

pub fn unauthorized(comptime fmt: []const u8, args: anytype) Error {
    return status(401, fmt, args);
}

/// A 401 that says what would have been accepted: `with` goes out as the
/// `WWW-Authenticate` header, which RFC 9110 §15.5.2 says every 401
/// carries. `nilo.Authorization(…)` supplies it for the header it reads;
/// `T.refuse` is this with the type's own challenge filled in (ADR 153).
pub fn challenge(comptime with: [:0]const u8, comptime fmt: []const u8, args: anytype) Error {
    if (inFlight()) |in_flight| {
        in_flight.failure.setIn(in_flight, 401, fmt, args);
        in_flight.failure.challenge = with;
    }
    return error.Failed;
}

pub fn forbidden(comptime fmt: []const u8, args: anytype) Error {
    return status(403, fmt, args);
}

pub fn notFound(comptime fmt: []const u8, args: anytype) Error {
    return status(404, fmt, args);
}

pub fn conflict(comptime fmt: []const u8, args: anytype) Error {
    return status(409, fmt, args);
}

pub fn unprocessable(comptime fmt: []const u8, args: anytype) Error {
    return status(422, fmt, args);
}

/// A 413, for a request body bigger than the endpoint will take. What
/// `c.bodyStream()` refusing a `Content-Length` wants to become (ADR 019).
pub fn tooLarge(comptime fmt: []const u8, args: anytype) Error {
    return status(413, fmt, args);
}

pub fn tooManyRequests(comptime fmt: []const u8, args: anytype) Error {
    return status(429, fmt, args);
}

/// A 500 with a message. The message is sent to the client, so do not put
/// anything in it that outsiders should not see.
pub fn internal(comptime fmt: []const u8, args: anytype) Error {
    return status(500, fmt, args);
}

/// The status a failed request will actually answer with: whatever a fail
/// function asked for, otherwise the mapping table. App uses this to build
/// the response; the logger middleware uses it to report the status
/// without having to guess the same thing twice.
///
/// The Failure speaks only for the error the fail functions return. It is
/// cleared when a request starts and never again, so a handler that caught a
/// `Failed` and went on to return something else would otherwise answer, and
/// log, the old status and message for an error that has nothing to do with
/// them. Every reader goes through `failed` for the same reason.
pub fn resolveStatus(failure: *const Failure, err: anyerror) u16 {
    return if (failed(failure, err)) failure.status else statusFor(err);
}

/// Whether `err` is the one the Failure describes: the sentinel a fail
/// function returned, with a message set behind it.
pub fn failed(failure: *const Failure, err: anyerror) bool {
    return err == error.Failed and failure.isSet();
}

/// What `app.errors` says about one error: its status, and the sentence the
/// client reads when the table gave one.
pub const Mapped = struct {
    status: u16,
    message: ?[]const u8 = null,
};

/// One row of the table as the API description reads it: the error's name
/// and its status. Names, because an inferred error set is readable while
/// compiling and a value of it is not (ADR 004).
pub const Row = struct {
    name: []const u8,
    status: u16,
};

/// The table `app.errors` was given, built while compiling. `find` is an
/// unrolled comparison against each listed error, not a scan of data, so an
/// App that never calls `errors` links none of it, and `rows` is what the
/// document reads at `listen()` (ADR 004).
pub const ErrorMap = struct {
    find: *const fn (anyerror) ?Mapped,
    rows: []const Row,
};

/// Check `table` and build the `ErrorMap` for it. Each entry is a tuple of an
/// error, a status from 400 to 599 and, if the client should read something
/// better than the status's reason phrase, a sentence. A status outside that
/// range, an error listed twice and an entry of any other shape are compile
/// errors, because the table is read on the failure path only and a
/// mistake in it would otherwise be found by the first client to hit it.
pub fn errorMapOf(comptime table: anytype) *const ErrorMap {
    comptime {
        const T = @TypeOf(table);
        if (@typeInfo(T) != .@"struct" or !@typeInfo(T).@"struct".is_tuple)
            @compileError("nilo: `app.errors` takes a tuple of entries, `.{ .{ error.EmailTaken, 409 }, … }`, not " ++ @typeName(T) ++ ".");
        if (table.len == 0)
            @compileError("nilo: `app.errors` was given no entries, and there is nothing to map.");
        var rows: []const Row = &.{};
        for (table, 0..) |entry, i| {
            const E = @TypeOf(entry);
            const shape = "nilo: entry " ++ std.fmt.comptimePrint("{d}", .{i + 1}) ++
                " of `app.errors` is not `.{ error.Name, status }` or `.{ error.Name, status, \"sentence\" }`.";
            if (@typeInfo(E) != .@"struct" or !@typeInfo(E).@"struct".is_tuple or entry.len < 2 or entry.len > 3)
                @compileError(shape);
            if (@typeInfo(@TypeOf(entry[0])) != .error_set) @compileError(shape);
            const name = @errorName(entry[0]);
            const code: i64 = entry[1];
            if (code < 400 or code > 599)
                @compileError("nilo: `app.errors` maps error." ++ name ++ " to " ++ std.fmt.comptimePrint("{d}", .{code}) ++
                    ", and a status for an error is 400 to 599.");
            if (entry.len == 3) {
                const sentence: []const u8 = entry[2];
                if (sentence.len > max_message)
                    @compileError("nilo: `app.errors` gives error." ++ name ++ " a sentence of " ++
                        std.fmt.comptimePrint("{d}", .{sentence.len}) ++ " bytes, and the most a failure carries is " ++
                        std.fmt.comptimePrint("{d}", .{max_message}) ++ ".");
            }
            for (rows) |seen| {
                if (std.mem.eql(u8, seen.name, name))
                    @compileError("nilo: `app.errors` lists error." ++ name ++ " twice, and an error has one status.");
            }
            rows = rows ++ [_]Row{.{ .name = name, .status = code }};
        }
        const Built = struct {
            fn find(err: anyerror) ?Mapped {
                inline for (table) |entry| {
                    if (err == @as(anyerror, entry[0])) return .{
                        .status = entry[1],
                        .message = if (entry.len == 3) @as([]const u8, entry[2]) else null,
                    };
                }
                return null;
            }
            const map: ErrorMap = .{ .find = &find, .rows = rows };
        };
        return &Built.map;
    }
}

/// The status a failed request answers with, given the App's table: the
/// fail function's first, then `app.errors`, then the built-in one. The
/// logger and `App` both come here so the line and the response agree.
pub fn statusWith(map: ?*const ErrorMap, failure: ?*const Failure, err: anyerror) u16 {
    if (failure) |f| if (failed(f, err)) return f.status;
    if (map) |m| if (m.find(err)) |mapped| return mapped.status;
    return statusFor(err);
}

/// Ordinary Zig errors coming from anywhere — a database, a parser, an
/// allocator — are mapped through this table. Anything unrecognised
/// becomes a 500 and is logged with its error name (ADR 004).
pub fn statusFor(err: anyerror) u16 {
    return switch (err) {
        error.Failed => 500, // should already have been handled via the Failure

        error.NotFound, error.FileNotFound => 404,

        // A body the client stopped sending before its end, read through
        // `bodyStream()`. `Ctx.body()` says the same in a sentence of its
        // own. Not `EndOfStream`: that name is every reader's, and a file a
        // handler read too far is not the client's fault (ADR 019).
        error.BodyTruncated,
        error.BadChunk,
        error.BadEncodedBody,
        error.InvalidCharacter,
        error.Overflow,
        error.InvalidNumber,
        error.SyntaxError,
        error.UnexpectedToken,
        error.UnexpectedEndOfInput,
        error.InvalidEnumTag,
        error.MissingField,
        error.UnknownField,
        error.DuplicateField,
        error.LengthMismatch,
        => 400,

        error.Unauthorized => 401,
        error.Forbidden => 403,
        // `AlreadyExists` is `nilo_sql`'s, and one of the three errors of that
        // module's given a row here. A unique violation means the client
        // asked for something that is already there, and that is true
        // whatever the request around it was.
        //
        // The other two say the same thing whatever the request was, too:
        // `RolledBack` is a transaction the database gave up to keep the ones
        // beside it consistent, and `Disconnected` is a database that is not
        // there. Neither is the request's fault, and the same request sent
        // again may well succeed, which is what a 503 tells a client. Both
        // used to fall through to 500 — a server that looked broken while the
        // truth was a server that was busy or waiting on its database.
        //
        // **Every other constraint failure stays 500 and the handler
        // decides**, `ForeignKeyViolated` included (ADR 036, ADR 117).
        // That one is a 409 for a delete that lost a race and a 400 for an
        // insert naming a parent that was never there, and nothing here can
        // tell those apart — which is the reason it has a name rather than a
        // row.
        //
        // Naming it costs no dependency. A Zig error is a member of one
        // global set, so this file can match on the name without importing
        // the module that raises it — the arrow still runs one way.
        error.Conflict, error.AlreadyExists => 409,
        error.BodyTooLarge => 413,
        // The request never finished arriving, which is not the server's
        // fault and is worth retrying (ADR 022).
        error.BodyTooSlow => 408,
        error.Timeout, error.Canceled => 503,
        // The client went before the answer (`c.gone()`, ADR 287). nginx's
        // number for it: nobody is left to read this, so it is for the log.
        error.ClientGone => 499,
        error.RolledBack, error.Disconnected => 503,

        else => 500,
    };
}

// ---- tests ----

const testing = std.testing;

/// Fail functions return a bare error value so they can be used as
/// `orelse fail.notFound(...)`; tests wrap that into an error union first.
fn asUnion(e: Error) Error!void {
    return e;
}

test "with no Failure, a fail function is just a plain error" {
    const previous = bulkhead.setFallbackSlot(null);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, asUnion(notFound("no user {d}", .{7})));
}

test "with a Failure, the message and status are stored" {
    var failure = Failure{};
    const previous = bulkhead.setFallbackSlot(&failure);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, asUnion(notFound("no user {d}", .{7})));
    try testing.expect(failure.isSet());
    try testing.expectEqual(@as(u16, 404), failure.status);
    try testing.expectEqualStrings("no user 7", failure.message());

    failure.clear();
    try testing.expect(!failure.isSet());
    try testing.expectEqualStrings("", failure.message());
}

test "an over-long message is truncated, not dropped" {
    // No request behind it, which is the boot: there is no arena to hold more.
    var in_flight = InFlight{};
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);
    const failure = &in_flight.failure;

    try testing.expectError(error.Failed, asUnion(badRequest("{s}", .{&@as([(max_message * 2)]u8, @splat('x'))})));
    try testing.expectEqual(@as(u16, 400), failure.status);
    try testing.expect(failure.message().len <= max_message);
}

/// A request that holds an arena, for what a long message needs.
const Held = struct {
    arena: std.heap.ArenaAllocator,
    full: bool = false,

    fn alloc(p: *anyopaque, n: usize) ?[]u8 {
        const self: *Held = @ptrCast(@alignCast(p));
        if (self.full) return null;
        return self.arena.allocator().alloc(u8, n) catch null;
    }

    fn read(_: *anyopaque, _: InFlight.Part) []const u8 {
        return "";
    }

    const ops: InFlight.RequestOps = .{ .read = read, .alloc = alloc };
};

test "a message longer than the slot is kept whole when a request holds it" {
    var held: Held = .{ .arena = .init(testing.allocator) };
    defer held.arena.deinit();
    var in_flight = InFlight{};
    in_flight.request = &held;
    in_flight.request_ops = &Held.ops;
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    const long = &@as([1000]u8, @splat('y'));
    try testing.expectError(error.Failed, asUnion(badRequest("{s}", .{long})));
    try testing.expectEqualStrings(long, in_flight.failure.message());
    try testing.expectEqual(@as(u16, 400), in_flight.failure.status);

    // A short one never touches the arena, and clearing forgets the long one.
    in_flight.failure.clear();
    held.full = true;
    try testing.expectError(error.Failed, asUnion(badRequest("no user {d}", .{7})));
    try testing.expectEqualStrings("no user 7", in_flight.failure.message());

    // An arena with no room is the cut, as it was.
    try testing.expectError(error.Failed, asUnion(badRequest("{s}", .{long})));
    try testing.expectEqual(@as(usize, max_message), in_flight.failure.message().len);
}

test "a long message is bounded, and cut between characters" {
    var held: Held = .{ .arena = .init(testing.allocator) };
    defer held.arena.deinit();
    var in_flight = InFlight{};
    in_flight.request = &held;
    in_flight.request_ops = &Held.ops;
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    const huge = try testing.allocator.alloc(u8, max_long_message * 2);
    defer testing.allocator.free(huge);
    @memset(huge, 'z');
    try testing.expectError(error.Failed, asUnion(badRequest("{s}", .{huge})));
    try testing.expectEqual(@as(usize, max_long_message), in_flight.failure.message().len);

    // A two-byte character that straddles the bound is dropped, not halved.
    @memset(huge, 'z');
    huge[max_long_message - 1] = 0xC3;
    huge[max_long_message] = 0xA9;
    try testing.expectError(error.Failed, asUnion(badRequest("{s}", .{huge})));
    try testing.expect(std.unicode.utf8ValidateSlice(in_flight.failure.message()));
    try testing.expectEqual(@as(usize, max_long_message - 1), in_flight.failure.message().len);
}

test "the error mapping table" {
    try testing.expectEqual(@as(u16, 404), statusFor(error.NotFound));
    try testing.expectEqual(@as(u16, 400), statusFor(error.InvalidCharacter));
    try testing.expectEqual(@as(u16, 413), statusFor(error.BodyTooLarge));
    try testing.expectEqual(@as(u16, 400), statusFor(error.BodyTruncated));
    try testing.expectEqual(@as(u16, 500), statusFor(error.SomethingUnrecognised));
    // A database that gave a transaction up, or is not there, is not the
    // request's fault, and the same request may go through if sent again.
    try testing.expectEqual(@as(u16, 499), statusFor(error.ClientGone));
    try testing.expectEqual(@as(u16, 503), statusFor(error.RolledBack));
    try testing.expectEqual(@as(u16, 503), statusFor(error.Disconnected));
    // And a constraint failure other than a duplicate stays the handler's.
    try testing.expectEqual(@as(u16, 500), statusFor(error.ForeignKeyViolated));
}

test "a challenge is a 401 that remembers what would have been accepted, and clear forgets it" {
    var failure = Failure{};
    const previous = bulkhead.setFallbackSlot(&failure);
    defer _ = bulkhead.setFallbackSlot(previous);

    try testing.expectError(error.Failed, asUnion(challenge("Bearer", "no token", .{})));
    try testing.expectEqual(@as(u16, 401), failure.status);
    try testing.expectEqualStrings("no token", failure.message());
    try testing.expectEqualStrings("Bearer", std.mem.span(failure.challenge.?));

    failure.clear();
    try testing.expect(failure.challenge == null);
}

test "a message cut at the limit is cut between characters, never inside one" {
    var in_flight = InFlight{};
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);
    const failure = &in_flight.failure;

    // 239 bytes, then a two-byte character that has room for only half of it.
    try testing.expectError(error.Failed, asUnion(badRequest("{s}\u{e9}", .{&@as([(max_message - 1)]u8, @splat('x'))})));
    try testing.expect(std.unicode.utf8ValidateSlice(failure.message()));
    try testing.expectEqual(@as(usize, max_message - 1), failure.message().len);

    // A four-byte one cut after its first three bytes.
    try testing.expectError(error.Failed, asUnion(badRequest("{s}\u{1F600}", .{&@as([(max_message - 3)]u8, @splat('x'))})));
    try testing.expect(std.unicode.utf8ValidateSlice(failure.message()));

    // One that fits whole is kept whole.
    try testing.expectError(error.Failed, asUnion(badRequest("{s}\u{e9}", .{&@as([(max_message - 2)]u8, @splat('x'))})));
    try testing.expectEqual(@as(usize, max_message), failure.message().len);
}

test "a failure decides the status only for the error the fail functions return" {
    var failure = Failure{};
    failure.set(404, "no user", .{});
    try testing.expectEqual(@as(u16, 404), resolveStatus(&failure, error.Failed));
    // A handler that caught the Failed and went on to hit something else is
    // answering that something else (ADR 004).
    try testing.expectEqual(@as(u16, 500), resolveStatus(&failure, error.OutOfMemory));
    try testing.expectEqual(@as(u16, 413), resolveStatus(&failure, error.BodyTooLarge));
}

test "the challenge lives in the padding a Failure already had" {
    // The pointer is paid for by shrinking `n` to a byte, which the
    // 240-byte buffer allows. A connection holds one Failure, so this is
    // the per-connection number the feature must not move (ADR 153). A long
    // message's slice is kept inside the buffer, so keeping one in the
    // request arena moved it by nothing either (ADR 024).
    try testing.expectEqual(@as(usize, 256), @sizeOf(Failure));
}

fn aField(name: []const u8, code: FieldCode) FieldFailure {
    return .{ .field = name, .code = code, .message = "a sentence", .expected = "text" };
}

test "fields ride in the request arena behind a marker, and clear forgets them" {
    var held: Held = .{ .arena = .init(testing.allocator) };
    defer held.arena.deinit();
    var in_flight = InFlight{};
    in_flight.request = &held;
    in_flight.request_ops = &Held.ops;
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);
    const failure = &in_flight.failure;

    // The list is copied, so the caller's own array may go out of scope.
    {
        const list = [_]FieldFailure{ aField("email", .missing), aField("address.city", .not_that_type) };
        try testing.expectError(error.Failed, asUnion(fieldsFailed(422, "2 fields did not fit: a; b", &list)));
    }
    try testing.expectEqual(@as(u16, 422), failure.status);
    try testing.expectEqualStrings("2 fields did not fit: a; b", failure.message());
    try testing.expectEqual(@as(usize, 2), failure.fields().len);
    try testing.expectEqualStrings("address.city", failure.fields()[1].field);
    try testing.expectEqual(FieldCode.not_that_type, failure.fields()[1].code);

    failure.clear();
    try testing.expectEqual(@as(usize, 0), failure.fields().len);
    try testing.expectEqualStrings("", failure.message());

    // A fail function after it is a failure of no fields at all.
    try testing.expectError(error.Failed, asUnion(notFound("no user {d}", .{7})));
    try testing.expectEqual(@as(usize, 0), failure.fields().len);
    try testing.expectEqualStrings("no user 7", failure.message());
}

test "fields with no arena to hold them are the sentence alone" {
    var in_flight = InFlight{};
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    const list = [_]FieldFailure{aField("email", .missing)};
    try testing.expectError(error.Failed, asUnion(fieldsFailed(422, "the form is missing email", &list)));
    try testing.expectEqual(@as(u16, 422), in_flight.failure.status);
    try testing.expectEqualStrings("the form is missing email", in_flight.failure.message());
    try testing.expectEqual(@as(usize, 0), in_flight.failure.fields().len);

    // And an arena with no room is the same.
    var held: Held = .{ .arena = .init(testing.allocator), .full = true };
    defer held.arena.deinit();
    in_flight.request = &held;
    in_flight.request_ops = &Held.ops;
    try testing.expectError(error.Failed, asUnion(fieldsFailed(422, "once more", &list)));
    try testing.expectEqualStrings("once more", in_flight.failure.message());
    try testing.expectEqual(@as(usize, 0), in_flight.failure.fields().len);
}

test "a failure keeps at most max_fields fields, and the joined sentence counts them all" {
    var sink_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer sink_arena.deinit();
    var held: Held = .{ .arena = .init(testing.allocator) };
    defer held.arena.deinit();
    var in_flight = InFlight{};
    in_flight.request = &held;
    in_flight.request_ops = &Held.ops;
    const previous = bulkhead.setFallbackSlot(&in_flight);
    defer _ = bulkhead.setFallbackSlot(previous);

    var sink = FieldSink.init(sink_arena.allocator());
    for (0..max_fields + 6) |i| sink.add("items[2].qty", .missing, null, "field {d} is missing", .{i});
    try testing.expectEqual(@as(usize, max_fields + 6), sink.total);
    try testing.expectEqual(@as(usize, max_fields), sink.items.items.len);
    try testing.expectEqualStrings("items.2.qty", sink.items.items[0].field);

    try testing.expectError(error.Failed, asUnion(sink.refuse(400).?));
    try testing.expectEqual(@as(usize, max_fields), in_flight.failure.fields().len);
    try testing.expect(std.mem.startsWith(u8, in_flight.failure.message(), "70 fields did not fit: field 0 is missing; "));
    try testing.expect(std.mem.endsWith(u8, in_flight.failure.message(), " more"));
}

test "one field is the sentence it would have been, and none is left to the caller" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var sink = FieldSink.init(arena.allocator());
    try testing.expect(sink.refuse(400) == null);

    var buf: [max_message]u8 = undefined;
    sink.add("age", .not_that_type, "a whole number", "\"age\" has to be a whole number", .{});
    try testing.expectEqualStrings("\"age\" has to be a whole number", joinFields(&buf, sink.total, sink.items.items));
}

test "a field code is spelled the way a client switches on it" {
    try testing.expectEqualStrings("not_that_type", @tagName(FieldCode.not_that_type));
    try testing.expectEqualStrings("unknown_field", @tagName(FieldCode.unknown_field));
}

test "the fields marker sits between the longest message and the long one" {
    // A message in the slot is at most `max_message` bytes, so no length can be
    // taken for either marker.
    try testing.expect(max_message < detail_marker and detail_marker < long_marker);
}
