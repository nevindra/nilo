//! A small REST API: a Service holding state, typed handlers, JSON in and
//! out, fail functions, and a middleware of your own.
//!
//! ```
//! zig build run-rest
//!
//! curl localhost:8787/users
//! curl 'localhost:8787/users?sort=name&limit=1'  # query params, typed
//! curl localhost:8787/users/1
//! curl localhost:8787/users/999                 # 404 with a message
//! curl -i -X POST localhost:8787/users -d '{"name":"wati","email":"wati@example.dev"}'
//! curl -H 'X-Token: let-me-in' localhost:8787/admin/stats
//! ```

const std = @import("std");
const zfast = @import("zfast");
const fail = zfast.fail;

// The two lines every zfast root file wants: one keeps `std.log` from
// blocking the event loop, the other keeps the Engine's debug chatter out
// of your logs. `listen()` says so at startup if either is missing.
pub const std_options = zfast.std_options;
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

/// The query string, read into a struct. A field with a default is
/// optional and a field without one is required; either way the type is
/// checked before the handler runs, so `?limit=soon` is a 400 that says so
/// rather than something to remember to guard against.
const Listing = struct {
    sort: enum { id, name } = .id,
    limit: usize = 100,
};

fn listUsers(store: *Store, arena: std.mem.Allocator, listing: zfast.Query(Listing)) ![]const User {
    try store.lock.lock();
    defer store.lock.unlock();

    // Copied into the request arena rather than sorted where it lies: this
    // Service is shared by every request being served at once, and one
    // asking for `?sort=name` has no business reordering it for the rest.
    // The copy is thrown away with the request.
    const page = store.users.items[0..@min(listing.value.limit, store.users.items.len)];
    const out = try arena.dupe(User, page);

    if (listing.value.sort == .name) {
        std.mem.sort(User, out, {}, struct {
            fn lessThan(_: void, a: User, b: User) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);
    }
    return out;
}

fn getUser(store: *Store, id: u32) !User {
    return store.find(id) orelse fail.notFound("no user {d}", .{id});
}

const NewUser = struct {
    name: zfast.Str,
    email: zfast.Str,
};

/// A struct argument is the request body, parsed from JSON. `Response(T)`
/// is how a handler answers with a status other than 200, headers of its
/// own, or — as here — both. A `Location` on a 201 is the reason it needs
/// to be both, and it does not cost a drop down to `*Ctx` to get one.
fn createUser(store: *Store, arena: std.mem.Allocator, incoming: NewUser) !zfast.Response(User) {
    if (incoming.name.len() == 0) return fail.unprocessable("name must not be empty", .{});
    if (std.mem.indexOfScalar(u8, incoming.email.view(), '@') == null) {
        return fail.unprocessable("\"{s}\" is not an email address", .{incoming.email.view()});
    }

    const created = try store.add(incoming.name.view(), incoming.email.view());
    return .{
        .status = 201,
        .headers = &.{.{
            .name = "Location",
            // A `std.mem.Allocator` argument is the request arena: it lives
            // exactly long enough to build a header with, and is thrown
            // away with the request. Nothing to free.
            .value = try std.fmt.allocPrint(arena, "/users/{d}", .{created.id}),
        }},
        .value = created,
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

    // The handler asks for the request arena, so the test hands it one.
    // Still no server and no fake request — an allocator is an argument
    // like any other.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try testing.expectError(error.Failed, createUser(&store, scratch, .{
        .name = .static(""),
        .email = .static("wati@example.dev"),
    }));
    try testing.expectError(error.Failed, createUser(&store, scratch, .{
        .name = .static("wati"),
        .email = .static("not-an-email"),
    }));

    const created = try createUser(&store, scratch, .{
        .name = .static("wati"),
        .email = .static("wati@example.dev"),
    });
    try testing.expectEqual(@as(u16, 201), created.status);
    try testing.expectEqualStrings("wati", created.value.name);
    try testing.expectEqualStrings("Location", created.headers[0].name);
    try testing.expectEqualStrings("/users/1", created.headers[0].value);
}

test "listUsers reads its options from the query struct" {
    var store = Store{ .gpa = testing.allocator };
    defer store.deinit();
    _ = try store.add("wati", "wati@example.dev");
    _ = try store.add("budi", "budi@example.dev");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    // A `Query(T)` is an ordinary struct too, so a test builds one and
    // never touches a query string.
    const by_name = try listUsers(&store, scratch, .{ .value = .{ .sort = .name } });
    try testing.expectEqualStrings("budi", by_name[0].name);

    const just_one = try listUsers(&store, scratch, .{ .value = .{ .limit = 1 } });
    try testing.expectEqual(@as(usize, 1), just_one.len);

    // Sorting a copy, so the Service every other request shares is as it was.
    try testing.expectEqualStrings("wati", store.users.items[0].name);
}
