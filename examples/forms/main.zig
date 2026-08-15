//! A form, a cookie and a redirect — the shape of a web page rather than of
//! a JSON API. Sign in with an HTML form, get a session cookie, be redirected
//! back, upload a file, sign out again.
//!
//! ```
//! zig build run-forms
//! open localhost:8787                                  # the page, with the form on it
//!
//! # what the browser does, spelled out
//! curl -i -X POST localhost:8787/sign-in \
//!   -d 'email=wati@example.dev&password=hunter2'       # 303, and a Set-Cookie
//! curl localhost:8787/me -b 'session=…'                # the cookie coming back
//! curl -i -X POST localhost:8787/sign-out -b 'session=…'
//!
//! curl -i -X POST localhost:8787/avatars \
//!   -F 'caption=me, squinting' -F 'image=@some.png'    # multipart, with a file
//!
//! curl -i localhost:8787/home                          # 301 to /
//! curl localhost:8787/openapi.json                     # forms and redirects, described
//! ```
//!
//! The three things worth taking from this file:
//!
//! - **A form is the body.** `Form(T)` sits where a plain struct argument
//!   would have read JSON, and reads urlencoded or multipart without the
//!   endpoint having to know which the browser chose.
//! - **A redirect puts its status in the type.** `Redirect(303)` after a POST
//!   is what stops a reload posting the form a second time.
//! - **A cookie is read by a resolved value**, so every handler behind the
//!   sign-in asks for a `SignedIn` and none of them parses a header.

const std = @import("std");
const zfast = @import("zfast");
const fail = zfast.fail;
const Str = zfast.Str;

pub const std_options = zfast.std_options;
pub const std_options_debug_io = zfast.debug_io;
pub const panic = zfast.panic;

/// The name the session cookie goes by, in one place: it is written by
/// `signIn`, read by `authenticate` and deleted by `signOut`, and three
/// spellings of it is three chances to get one wrong.
const session_cookie = "session";

// ---- the service ----

/// Who is signed in, and under which token.
///
/// A real one would put these in Redis and hand out tokens from a CSPRNG.
/// This one is a list and a counter, because what the example is about is
/// what happens either side of it.
const Sessions = struct {
    gpa: std.mem.Allocator,
    lock: zfast.Mutex = .init,
    open: std.ArrayList(Session) = .empty,
    next: u32 = 1,

    const Session = struct { token: []const u8, email: []const u8 };

    fn deinit(self: *Sessions) void {
        for (self.open.items) |s| {
            self.gpa.free(s.token);
            self.gpa.free(s.email);
        }
        self.open.deinit(self.gpa);
    }

    /// The Store owns its strings: what arrives in a request dies with the
    /// request, so anything kept is copied.
    fn start(self: *Sessions, email: []const u8) ![]const u8 {
        try self.lock.lock();
        defer self.lock.unlock();

        const token = try std.fmt.allocPrint(self.gpa, "s{d}", .{self.next});
        errdefer self.gpa.free(token);
        const kept = try self.gpa.dupe(u8, email);
        errdefer self.gpa.free(kept);

        try self.open.append(self.gpa, .{ .token = token, .email = kept });
        self.next += 1;
        return token;
    }

    /// Whose session this is, or null. The email is copied into `into` —
    /// the request arena — rather than handed out as a pointer into the
    /// Store, so a sign-out landing between here and the response cannot
    /// free the text mid-write.
    fn emailFor(self: *Sessions, token: []const u8, into: std.mem.Allocator) !?[]const u8 {
        try self.lock.lock();
        defer self.lock.unlock();

        for (self.open.items) |s| {
            if (std.mem.eql(u8, s.token, token)) return try into.dupe(u8, s.email);
        }
        return null;
    }

    fn end(self: *Sessions, token: []const u8) !void {
        try self.lock.lock();
        defer self.lock.unlock();

        for (self.open.items, 0..) |s, i| {
            if (!std.mem.eql(u8, s.token, token)) continue;
            self.gpa.free(s.token);
            self.gpa.free(s.email);
            _ = self.open.orderedRemove(i);
            return;
        }
    }
};

// ---- who is signed in ----

/// A resolved value that reads the session cookie (ADR 0016). Writing
/// `SignedIn` in an argument list is the whole of the wiring — no
/// middleware, no header parsing in the handler.
const SignedIn = struct {
    pub const zfast_resolve = authenticate;

    email: []const u8,
};

fn authenticate(c: *zfast.Ctx, sessions: *Sessions, arena: std.mem.Allocator) !SignedIn {
    const token = c.cookie(session_cookie) orelse
        return fail.unauthorized("you are not signed in", .{});
    const email = try sessions.emailFor(token.view(), arena) orelse
        return fail.unauthorized("that session has ended — sign in again", .{});
    return .{ .email = email };
}

// ---- the form ----

/// One field per form field, exactly as a `Query(T)` is one field per query
/// param. A default is what "the browser did not send it" means, which for
/// an unticked checkbox is precisely the case.
const SignIn = struct {
    email: Str,
    password: Str,
    /// An unticked checkbox is not sent at all, so the default is the
    /// answer — and a ticked one arrives as `remember=on` rather than as
    /// `true`, which is why this is a `Str` and not a `bool`.
    remember: Str = .static(""),
};

/// A form in, a cookie out, and a 303 back to the page.
///
/// 303 rather than 302 is the whole reason a form POST redirects: it turns
/// the follow-up into a GET, so the browser's reload button re-reads the
/// page instead of signing in a second time.
fn signIn(
    sessions: *Sessions,
    arena: std.mem.Allocator,
    incoming: zfast.Form(SignIn),
) !zfast.Redirect(303) {
    const email = incoming.value.email.view();
    // The example's entire authentication policy. Yours goes here.
    if (!std.mem.eql(u8, incoming.value.password.view(), "hunter2")) {
        return fail.unauthorized("that is not the password", .{});
    }

    const token = try sessions.start(email);
    const cookie = try std.fmt.allocPrint(
        arena,
        "{s}={s}; Path=/; HttpOnly; SameSite=Lax{s}",
        .{
            session_cookie,
            token,
            // "Remember me" is the difference between a cookie that outlives
            // the browser window and one that does not.
            if (incoming.value.remember.len() > 0) "; Max-Age=1209600" else "",
        },
    );
    return .with("/", .of(&.{.{ .name = "Set-Cookie", .value = cookie }}));
}

/// The other half. `c.clearCookie` is the same call as `setCookie` with an
/// age that has already run out — and it has to name the same path the
/// cookie was set with, or the browser keeps it.
fn signOut(c: *zfast.Ctx, sessions: *Sessions) !zfast.Redirect(303) {
    if (c.cookie(session_cookie)) |token| try sessions.end(token.view());
    try c.clearCookie(.{ .name = session_cookie });
    return .to("/");
}

/// Behind the sign-in, and it says so by taking a `SignedIn`. A request
/// with no session never reaches this function at all.
fn me(user: SignedIn) !struct { email: []const u8 } {
    return .{ .email = user.email };
}

// ---- a file ----

/// A form with an `Upload` in it can only arrive as multipart, and zfast
/// says so rather than reporting the field as missing.
const NewAvatar = struct {
    caption: Str,
    image: zfast.Upload,
};

const Avatar = struct {
    caption: []const u8,
    filename: []const u8,
    content_type: []const u8,
    bytes: usize,
};

fn uploadAvatar(user: SignedIn, incoming: zfast.Form(NewAvatar)) !zfast.Status(201, Avatar) {
    _ = user; // signing in is what earns you an upload
    const image = incoming.value.image;
    if (image.len() == 0) return fail.badRequest("no file was chosen", .{});

    return .{ .value = .{
        .caption = incoming.value.caption.view(),
        // What the client called it, which a client can make up. It is a
        // label to show back, never a path to write to.
        .filename = image.filename.view(),
        .content_type = image.content_type.view(),
        .bytes = image.len(),
    } };
}

// ---- the page ----

const page =
    \\<!doctype html><meta charset="utf-8"><title>zfast forms</title>
    \\<h1>Sign in</h1>
    \\<form method="post" action="/sign-in">
    \\  <input name="email" value="wati@example.dev">
    \\  <input name="password" type="password" value="hunter2">
    \\  <label><input name="remember" type="checkbox"> remember me</label>
    \\  <button>Sign in</button>
    \\</form>
    \\<h1>Upload</h1>
    \\<form method="post" action="/avatars" enctype="multipart/form-data">
    \\  <input name="caption"><input name="image" type="file"><button>Upload</button>
    \\</form>
    \\<form method="post" action="/sign-out"><button>Sign out</button></form>
;

/// A `*Ctx` handler, because the content type is `text/html` and a handler
/// returning text gets `text/plain`.
fn home(c: *zfast.Ctx) !void {
    try c.send(200, "text/html; charset=utf-8", page);
}

/// A permanent move. 301 and 308 are the permanent pair, 302 and 307 the
/// temporary one; the two ending in 7 and 8 keep the request's method.
fn oldHome() zfast.Redirect(301) {
    return .to("/");
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var sessions = Sessions{ .gpa = gpa };
    defer sessions.deinit();

    var app = zfast.App.init(gpa);
    defer app.deinit();

    try app.provide(&sessions);
    try app.use(zfast.logger.standard);

    try app.get("/", home);
    try app.get("/home", oldHome);
    try app.post("/sign-in", signIn);
    try app.post("/sign-out", signOut);
    try app.get("/me", me);
    try app.post("/avatars", uploadAvatar);

    app.docs(.{ .title = "Forms", .version = "1.0.0" });

    try app.listen(.{});
}

// ---- tests ----
//
// A handler is an ordinary function, so most of these call one. The two that
// cannot — a redirect that clears a cookie, and a multipart body — go through
// the test client, which runs a real request into the App with no server
// under it.

const testing = std.testing;

test "signIn refuses the wrong password and hands out a session for the right one" {
    var sessions = Sessions{ .gpa = testing.allocator };
    defer sessions.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    try testing.expectError(error.Failed, signIn(&sessions, scratch, .{ .value = .{
        .email = .static("wati@example.dev"),
        .password = .static("wrong"),
    } }));

    // A `Form(T)` is an ordinary struct, so a test builds one and never
    // writes a request body.
    const answer = try signIn(&sessions, scratch, .{ .value = .{
        .email = .static("wati@example.dev"),
        .password = .static("hunter2"),
    } });
    // The 303 is in the return type, so there is nothing to assert about it.
    try testing.expectEqualStrings("/", answer.location);
    try testing.expectEqualStrings("Set-Cookie", answer.headers.view()[0].name);
    try testing.expect(std.mem.startsWith(u8, answer.headers.view()[0].value, "session=s1;"));
    // Not remembered, so the cookie goes when the browser does.
    try testing.expect(std.mem.indexOf(u8, answer.headers.view()[0].value, "Max-Age") == null);
}

test "remember me is the difference between a session cookie and a lasting one" {
    var sessions = Sessions{ .gpa = testing.allocator };
    defer sessions.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const answer = try signIn(&sessions, arena.allocator(), .{ .value = .{
        .email = .static("wati@example.dev"),
        .password = .static("hunter2"),
        .remember = .static("on"), // what a ticked checkbox actually sends
    } });
    try testing.expect(std.mem.indexOf(u8, answer.headers.view()[0].value, "Max-Age=1209600") != null);
}

test "a session can be looked up and then ended" {
    var sessions = Sessions{ .gpa = testing.allocator };
    defer sessions.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const token = try sessions.start("wati@example.dev");
    try testing.expectEqualStrings("wati@example.dev", (try sessions.emailFor(token, scratch)).?);

    try sessions.end(token);
    try testing.expect(try sessions.emailFor(token, scratch) == null);
}

test "me is an ordinary function of the value the cookie resolved to" {
    // The point of a resolved value: testing an endpoint behind the sign-in
    // means building a `SignedIn`, not a request and not a cookie.
    try testing.expectEqualStrings("wati@example.dev", (try me(.{ .email = "wati@example.dev" })).email);
}

test "a form posted the way a browser posts it signs in and redirects" {
    var sessions = Sessions{ .gpa = testing.allocator };
    defer sessions.deinit();

    var app = zfast.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.post("/sign-in", signIn);

    var client = try zfast.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.postWith(
        &app,
        "/sign-in",
        "application/x-www-form-urlencoded",
        "email=wati%40example.dev&password=hunter2",
    );
    try testing.expectEqual(@as(u16, 303), answer.status);
    try testing.expectEqualStrings("/", answer.header("Location").?);
    try testing.expect(answer.setCookie("session") != null);
}

test "signing out clears the cookie the browser is holding" {
    var sessions = Sessions{ .gpa = testing.allocator };
    defer sessions.deinit();
    const token = try sessions.start("wati@example.dev");

    var app = zfast.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.post("/sign-out", signOut);

    var client = try zfast.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    var request: [256]u8 = undefined;
    const answer = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "POST /sign-out HTTP/1.1\r\nHost: test\r\nCookie: session={s}\r\nContent-Length: 0\r\n\r\n",
        .{token},
    ));
    try testing.expectEqual(@as(u16, 303), answer.status);
    try testing.expect(std.mem.indexOf(u8, answer.setCookie("session").?, "Max-Age=0") != null);

    // And the session really is gone, not merely forgotten by the browser.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try sessions.emailFor(token, arena.allocator()) == null);
}

test "an upload arrives with its bytes, and an endpoint behind the sign-in refuses without one" {
    var sessions = Sessions{ .gpa = testing.allocator };
    defer sessions.deinit();
    const token = try sessions.start("wati@example.dev");

    var app = zfast.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.post("/avatars", uploadAvatar);

    var client = try zfast.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const body = "--B\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\nme, squinting\r\n" ++
        "--B\r\nContent-Disposition: form-data; name=\"image\"; filename=\"me.png\"\r\n" ++
        "Content-Type: image/png\r\n\r\n\x89PNG\r\n\x1a\n\r\n" ++
        "--B--\r\n";

    // No cookie: the resolved value refuses and the handler never runs.
    const anonymous = try client.postWith(&app, "/avatars", "multipart/form-data; boundary=B", body);
    try testing.expectEqual(@as(u16, 401), anonymous.status);

    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(testing.allocator);
    try request.print(
        testing.allocator,
        "POST /avatars HTTP/1.1\r\nHost: test\r\nCookie: session={s}\r\n" ++
            "Content-Type: multipart/form-data; boundary=B\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ token, body.len, body },
    );

    const answer = try client.send(&app, request.items);
    try testing.expectEqual(@as(u16, 201), answer.status);
    try testing.expectEqualStrings(
        "{\"caption\":\"me, squinting\",\"filename\":\"me.png\"," ++
            "\"content_type\":\"image/png\",\"bytes\":8}",
        answer.body,
    );
}

test "the same endpoint sent a form that cannot carry a file says which to send" {
    var sessions = Sessions{ .gpa = testing.allocator };
    defer sessions.deinit();
    const token = try sessions.start("wati@example.dev");

    var app = zfast.App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.post("/avatars", uploadAvatar);

    var client = try zfast.testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    var request: [256]u8 = undefined;
    const answer = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "POST /avatars HTTP/1.1\r\nHost: test\r\nCookie: session={s}\r\n" ++
            "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\ncaption=hey",
        .{token},
    ));
    try testing.expectEqual(@as(u16, 400), answer.status);
    try testing.expect(std.mem.indexOf(u8, answer.body, "multipart/form-data") != null);
}

test "the old address is a permanent redirect to the new one" {
    try testing.expectEqualStrings("/", oldHome().location);
    try testing.expectEqual(@as(u16, 301), @TypeOf(oldHome()).zfast_redirect);
}
