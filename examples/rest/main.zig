//! A small REST API: a Service holding state, typed handlers, JSON in and
//! out, fail functions, and a middleware of your own.
//!
//! ```
//! zig build run-rest
//!
//! curl localhost:8787/users
//! curl localhost:8787/users/1
//! curl localhost:8787/users/999                 # 404 with a message
//! curl -X POST localhost:8787/users -d '{"name":"wati","email":"wati@example.dev"}'
//! curl -H 'X-Token: let-me-in' localhost:8787/admin/stats
//! ```

const std = @import("std");
const zfast = @import("zfast");
const fail = zfast.fail;

pub const std_options_debug_io = zfast.debug_io;
pub const panic = zfast.panic;

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

/// A Service: built once in `main`, then asked for by any handler that
/// names its type.
///
/// The lock is not decoration. Handlers run concurrently on several OS
/// threads, so anything a Service can write to needs one — and it is
/// `zfast.Mutex` rather than `std.Thread.Mutex`, because that one stops
/// the whole thread and every other request being served on it.
const Store = struct {
    gpa: std.mem.Allocator,
    lock: zfast.Mutex = .init,
    users: std.ArrayList(User) = .empty,
    next_id: u32 = 1,

    fn deinit(self: *Store) void {
        for (self.users.items) |u| {
            self.gpa.free(u.name);
            self.gpa.free(u.email);
        }
        self.users.deinit(self.gpa);
    }

    fn add(self: *Store, name: []const u8, email: []const u8) !User {
        try self.lock.lock();
        defer self.lock.unlock();

        const user = User{
            .id = self.next_id,
            .name = try self.gpa.dupe(u8, name),
            .email = try self.gpa.dupe(u8, email),
        };
        try self.users.append(self.gpa, user);
        self.next_id += 1;
        return user;
    }

    fn find(self: *Store, id: u32) ?User {
        self.lock.lock() catch return null; // only fails if the request was cancelled
        defer self.lock.unlock();

        for (self.users.items) |u| {
            if (u.id == id) return u;
        }
        return null;
    }
};

// ---- handlers ----
//
// Ordinary functions. A pointer argument is a Service, a value argument is
// request data, and the return value is the response. None of them mention
// HTTP, which is why every one of them is testable without a server.

fn listUsers(store: *Store) ![]const User {
    try store.lock.lock();
    defer store.lock.unlock();
    return store.users.items;
}

fn getUser(store: *Store, id: u32) !User {
    return store.find(id) orelse fail.notFound("no user {d}", .{id});
}

const NewUser = struct {
    name: zfast.Str,
    email: zfast.Str,
};

/// A struct argument is the request body, parsed from JSON. `Response(T)`
/// is how a handler answers with a status other than 200.
fn createUser(store: *Store, incoming: NewUser) !zfast.Response(User) {
    if (incoming.name.len() == 0) return fail.unprocessable("name must not be empty", .{});
    if (std.mem.indexOfScalar(u8, incoming.email.view(), '@') == null) {
        return fail.unprocessable("\"{s}\" is not an email address", .{incoming.email.view()});
    }

    return .{
        .status = 201,
        .value = try store.add(incoming.name.view(), incoming.email.view()),
    };
}

fn stats(store: *Store) struct { users: usize } {
    return .{ .users = store.users.items.len };
}

// ---- middleware ----

/// A middleware that does not call `next.run(c)` ends the chain. That is
/// all rejecting a request takes.
fn requireToken(c: *zfast.Ctx, next: zfast.Next) !void {
    const token = c.header("X-Token") orelse
        return fail.unauthorized("this endpoint needs an X-Token header", .{});
    if (!token.eql("let-me-in")) return fail.forbidden("that token is not one of ours", .{});
    return next.run(c);
}

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    var store = Store{ .gpa = gpa };
    defer store.deinit();
    _ = try store.add("wati", "wati@example.dev");
    _ = try store.add("budi", "budi@example.dev");

    var app = zfast.App.init(gpa);
    defer app.deinit();

    try app.provide(&store);

    // Registration order between `use` and `get` does not matter; the
    // chains are put together when `listen()` runs.
    try app.use(zfast.logger.standard);
    try app.use(zfast.cors.permissive);
    try app.useOn("/admin", requireToken);

    try app.get("/users", listUsers);
    try app.get("/users/:id", getUser);
    try app.post("/users", createUser);
    try app.get("/admin/stats", stats);

    try app.listen(.{});
}

// ---- tests ----
//
// The point of the typed layer: no server, no fake HTTP request, no
// harness. The handler is a function, so it is called like one.

const testing = std.testing;

test "getUser answers with the user, or fails with a 404" {
    var store = Store{ .gpa = testing.allocator };
    defer store.deinit();
    const wati = try store.add("wati", "wati@example.dev");

    try testing.expectEqualStrings("wati", (try getUser(&store, wati.id)).name);
    try testing.expectError(error.Failed, getUser(&store, 999));
}

test "createUser refuses a body that does not make sense" {
    var store = Store{ .gpa = testing.allocator };
    defer store.deinit();

    try testing.expectError(error.Failed, createUser(&store, .{
        .name = .static(""),
        .email = .static("wati@example.dev"),
    }));
    try testing.expectError(error.Failed, createUser(&store, .{
        .name = .static("wati"),
        .email = .static("not-an-email"),
    }));

    const created = try createUser(&store, .{
        .name = .static("wati"),
        .email = .static("wati@example.dev"),
    });
    try testing.expectEqual(@as(u16, 201), created.status);
    try testing.expectEqualStrings("wati", created.value.name);
}
