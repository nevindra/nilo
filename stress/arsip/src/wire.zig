//! The other half of the testing story: whole requests, through a real App,
//! with no server and no socket.
//!
//! `handlers.zig` tests the functions. This tests what a client actually gets —
//! the status, the JSON, the header — which is the only place a routing
//! mistake, a serialisation surprise or a middleware in the wrong order can
//! show up. Both run in the same `zig build test`.

const std = @import("std");
const nilo = @import("nilo_http");
const auth = @import("auth.zig");
const handlers = @import("handlers.zig");
const Accounts = @import("accounts.zig").Accounts;
const Archive = @import("archive.zig").Archive;
const Settings = @import("settings.zig").Settings;

const testing = std.testing;

/// An App with the whole API on it, plus the two stores it needs.
const Server = struct {
    app: nilo.App,
    archive: Archive,
    accounts: Accounts,
    limits: Settings,
    client: nilo.testing.Client,
    /// The sealed cookie, once something has signed in. Kept here so a test
    /// reads like a session rather than like a header.
    cookie: ?[]const u8 = null,
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator) !*Server {
        // By pointer: the App holds a pointer to each store, so none of them may
        // move after `provide`.
        const self = try gpa.create(Server);
        self.* = .{
            .app = nilo.App.init(gpa),
            .archive = .init(gpa),
            .accounts = .init(gpa),
            .limits = .{ .session_secret = "0123456789abcdef0123456789abcdef" },
            .client = try nilo.testing.Client.init(gpa, .{}),
            .gpa = gpa,
        };
        try self.app.provide(&self.archive);
        try self.app.provide(&self.accounts);
        // Forgetting one of these is a 500 in every test that needed it, because
        // the check that would have named it runs in `listen()` and the test
        // client does not call `listen()`. See item 2 in `DX.md`.
        try self.app.provide(@as(*const Settings, &self.limits));

        // What `.session_secret` becomes. Set directly, because these tests
        // never call `listen()` — a handler asking for a `Session(T)` with no key
        // answers 500 with a sentence naming the option, which is the right
        // behaviour and not what any of these are testing.
        self.app.session_key = @splat(0xA5);

        const v1_prefix = "/v1";
        const v1 = self.app.group(v1_prefix);
        try auth.mountOpen(v1);
        try handlers.mount(v1_prefix, v1);
        self.app.docs(.{ .title = "arsip", .version = "0.2.0" });
        return self;
    }

    fn deinit(self: *Server, gpa: std.mem.Allocator) void {
        if (self.cookie) |c| gpa.free(c);
        self.client.deinit();
        self.accounts.deinit();
        self.archive.deinit();
        self.app.deinit();
        gpa.destroy(self);
    }

    fn send(self: *Server, method: []const u8, path: []const u8, body: ?[]const u8) !nilo.testing.Answer {
        var head: std.Io.Writer.Allocating = .init(self.gpa);
        defer head.deinit();
        try head.writer.print("{s} {s} HTTP/1.1\r\nHost: t\r\n", .{ method, path });
        if (self.cookie) |c| try head.writer.print("Cookie: {s}\r\n", .{c});
        if (body) |b| {
            try head.writer.print("Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ b.len, b });
        } else {
            try head.writer.writeAll("\r\n");
        }
        return self.client.send(&self.app, head.written());
    }

    /// Sign up, and keep whatever `Set-Cookie` came back. **One argon2id hash,
    /// so about 13 ms** — which is why the tests below sign in once and reuse it
    /// rather than doing this per request.
    fn signUp(self: *Server, email: []const u8, name: []const u8) !nilo.testing.Answer {
        var body: std.Io.Writer.Allocating = .init(self.gpa);
        defer body.deinit();
        try body.writer.print(
            "{{\"email\":\"{s}\",\"name\":\"{s}\",\"password\":\"kopi-tubruk-manis\"}}",
            .{ email, name },
        );

        const answer = try self.send("POST", "/v1/sign-up", body.written());
        try self.keepCookie(answer);
        return answer;
    }

    fn keepCookie(self: *Server, answer: nilo.testing.Answer) !void {
        const set = answer.header("set-cookie") orelse return;
        // Only the `name=value` part goes back up; the attributes are the
        // browser's business.
        const upto = std.mem.indexOfScalar(u8, set, ';') orelse set.len;
        if (self.cookie) |old| self.gpa.free(old);
        self.cookie = try self.gpa.dupe(u8, set[0..upto]);
    }

    fn forgetCookie(self: *Server) void {
        if (self.cookie) |c| self.gpa.free(c);
        self.cookie = null;
    }
};

/// A Server with somebody signed in, which is what most of these tests want.
/// The first account is the curator, so this one can reach everything.
fn signedIn(gpa: std.mem.Allocator) !*Server {
    const s = try Server.init(gpa);
    errdefer s.deinit(gpa);
    const answer = try s.signUp("wati@example.dev", "Wati");
    if (answer.status != 201) return error.SignUpFailed;
    return s;
}

fn field(body: []const u8, name: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, body, .{});
    defer parsed.deinit();
    const found = parsed.value.object.get(name) orelse return error.NoSuchField;
    return switch (found) {
        .string => |s| testing.allocator.dupe(u8, s),
        else => error.NotAString,
    };
}

test "the whole life of a document, over the wire" {
    const gpa = testing.allocator;
    var s = try signedIn(gpa);
    defer s.deinit(gpa);

    // A folder that did not exist answers 201; the same folder again answers 200.
    const made = try s.send("PUT", "/v1/folders/kantor", "{\"name\":\"Kantor\",\"visibility\":\"team\"}");
    try testing.expectEqual(@as(u16, 201), made.status);
    const again = try s.send("PUT", "/v1/folders/kantor", "{\"name\":\"Kantor Pusat\"}");
    try testing.expectEqual(@as(u16, 200), again.status);

    // A body with an optional struct, a list of structs, and a list in each.
    const filed = try s.send("POST", "/v1/folders/kantor/docs",
        \\{"title":"Laporan Q3","kind":"invoice",
        \\ "meta":{"author":"wati","type":"invoice","pages":12},
        \\ "tags":["penting"],
        \\ "sections":[{"heading":"Ringkasan","lines":["Naik 12%"]}]}
    );
    try testing.expectEqual(@as(u16, 201), filed.status);
    try testing.expectEqualStrings("/v1/docs/1", filed.header("location").?);

    // The keyword field survives the round trip under its JSON name.
    try testing.expect(std.mem.indexOf(u8, filed.body, "\"type\":\"invoice\"") != null);
    try testing.expect(std.mem.indexOf(u8, filed.body, "\"lines\":[\"Naik 12%\"]") != null);

    // A document that will not move says what it is in, as a 409.
    const back = try s.send("POST", "/v1/docs/1/advance", "{\"to\":\"archived\"}");
    try testing.expectEqual(@as(u16, 409), back.status);
    const message = try field(back.body, "error");
    defer gpa.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "draft") != null);

    const on = try s.send("POST", "/v1/docs/1/advance", "{\"to\":\"review\"}");
    try testing.expectEqual(@as(u16, 200), on.status);

    // Gone means gone.
    const removed = try s.send("DELETE", "/v1/docs/1", null);
    try testing.expectEqual(@as(u16, 204), removed.status);
    const missing = try s.send("GET", "/v1/docs/1", null);
    try testing.expectEqual(@as(u16, 404), missing.status);
}

test "the whole sign-up, sign-in, sign-out round trip through one cookie" {
    const gpa = testing.allocator;
    var s = try Server.init(gpa);
    defer s.deinit(gpa);

    // Nothing is signed in, so the guarded prefix refuses — and the message
    // names the route to fix it rather than saying "unauthorized".
    const anonymous = try s.send("GET", "/v1/docs", null);
    try testing.expectEqual(@as(u16, 401), anonymous.status);
    const why = try field(anonymous.body, "error");
    defer gpa.free(why);
    try testing.expect(std.mem.indexOf(u8, why, "/v1/sign-in") != null);

    // Whoever signs up first is the curator.
    const made = try s.signUp("wati@example.dev", "Wati");
    try testing.expectEqual(@as(u16, 201), made.status);
    try testing.expect(s.cookie != null);
    // The response carries a profile and no hash, which is a property of the
    // type rather than of remembering to leave a field out.
    try testing.expect(std.mem.indexOf(u8, made.body, "argon2") == null);
    try testing.expect(std.mem.indexOf(u8, made.body, "\"curator\":true") != null);

    // The `public` id is a v7, and it goes out as text rather than as sixteen
    // numbers — `Uuid` carries a `jsonStringify`, so `nilo_http` needs no
    // knowledge of `nilo_id` at all.
    const public = try field(made.body, "public");
    defer gpa.free(public);
    try testing.expectEqual(@as(usize, 36), public.len);
    try testing.expectEqual(@as(u8, '7'), public[14]);

    // The cookie is the whole session: nothing was kept on the server.
    const signed = try s.send("GET", "/v1/whoami", null);
    try testing.expectEqual(@as(u16, 200), signed.status);
    try testing.expect(std.mem.indexOf(u8, signed.body, "\"name\":\"Wati\"") != null);

    // A second account is not the curator, so the curators' prefix refuses it —
    // and says who it refused.
    const second = try s.signUp("budi@example.dev", "Budi");
    try testing.expectEqual(@as(u16, 201), second.status);
    const nosy = try s.send("GET", "/v1/curate/report", null);
    try testing.expectEqual(@as(u16, 403), nosy.status);
    const refusal = try field(nosy.body, "error");
    defer gpa.free(refusal);
    try testing.expect(std.mem.indexOf(u8, refusal, "Budi") != null);

    // Signing out deletes the cookie in this browser, and dropping it locally
    // is the same thing from the server's side — there is nothing else to undo.
    const out = try s.send("POST", "/v1/sign-out", null);
    try testing.expectEqual(@as(u16, 204), out.status);
    s.forgetCookie();
    try testing.expectEqual(@as(u16, 401), (try s.send("GET", "/v1/whoami", null)).status);

    // And signing back in with the right password works, with the wrong one not.
    const wrong = try s.send("POST", "/v1/sign-in",
        \\{"email":"budi@example.dev","password":"salah-sekali"}
    );
    try testing.expectEqual(@as(u16, 401), wrong.status);

    const back = try s.send("POST", "/v1/sign-in",
        \\{"email":"budi@example.dev","password":"kopi-tubruk-manis"}
    );
    try testing.expectEqual(@as(u16, 200), back.status);
    try s.keepCookie(back);
    try testing.expectEqual(@as(u16, 200), (try s.send("GET", "/v1/whoami", null)).status);
}

test "a sign-in for an address with no account is refused the same way as a wrong password" {
    const gpa = testing.allocator;
    var s = try Server.init(gpa);
    defer s.deinit(gpa);

    _ = try s.signUp("wati@example.dev", "Wati");
    s.forgetCookie();

    // Same status, and the same sentence — the point of `verifyPassword` taking
    // an optional `stored` is that the no-account path does the work anyway, so
    // the form cannot be turned into a list of which addresses are registered.
    const no_account = try s.send("POST", "/v1/sign-in",
        \\{"email":"nobody@example.dev","password":"kopi-tubruk-manis"}
    );
    const wrong_password = try s.send("POST", "/v1/sign-in",
        \\{"email":"wati@example.dev","password":"salah-sekali"}
    );
    try testing.expectEqual(@as(u16, 401), no_account.status);
    try testing.expectEqual(@as(u16, 401), wrong_password.status);

    const a = try field(no_account.body, "error");
    defer gpa.free(a);
    const b = try field(wrong_password.body, "error");
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
}

test "a short password is refused before anything is hashed" {
    const gpa = testing.allocator;
    var s = try Server.init(gpa);
    defer s.deinit(gpa);

    const refused = try s.send("POST", "/v1/sign-up",
        \\{"email":"wati@example.dev","name":"Wati","password":"kopi"}
    );
    try testing.expectEqual(@as(u16, 422), refused.status);
    try testing.expectEqual(@as(usize, 0), try s.accounts.count());
}

test "three bad fields in one body are named in one answer" {
    const gpa = testing.allocator;
    var s = try signedIn(gpa);
    defer s.deinit(gpa);

    _ = try s.send("PUT", "/v1/folders/kantor", "{\"name\":\"Kantor\"}");
    const refused = try s.send("POST", "/v1/folders/kantor/docs",
        \\{"title":"x","kind":"gold","visibility":"loud"}
    );

    // 422 rather than 400: the request was understood and its contents were not.
    try testing.expectEqual(@as(u16, 422), refused.status);
    const message = try field(refused.body, "error");
    defer gpa.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "kind") != null);
    try testing.expect(std.mem.indexOf(u8, message, "visibility") != null);
}

test "a query struct that does not fit is refused before the handler runs" {
    const gpa = testing.allocator;
    var s = try signedIn(gpa);
    defer s.deinit(gpa);

    const bad = try s.send("GET", "/v1/docs?sort=sideways", null);
    try testing.expectEqual(@as(u16, 400), bad.status);

    const message = try field(bad.body, "error");
    defer gpa.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "sort") != null);
}

test "a multipart form with a file in it, and the 303 it answers with" {
    const gpa = testing.allocator;
    var s = try signedIn(gpa);
    defer s.deinit(gpa);

    _ = try s.send("PUT", "/v1/folders/kantor", "{\"name\":\"Kantor\"}");
    _ = try s.send("POST", "/v1/folders/kantor/docs", "{\"title\":\"Laporan\"}");

    const boundary = "----arsip";
    const form =
        "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"caption\"\r\n\r\n" ++
        "Laporan asli\r\n" ++
        "--" ++ boundary ++ "\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"q3.pdf\"\r\n" ++
        "Content-Type: application/pdf\r\n\r\n" ++
        "%PDF-1.7 hello\r\n" ++
        "--" ++ boundary ++ "--\r\n";

    // Built by hand rather than through `send`, because this is the one request
    // whose Content-Type is not JSON — so the cookie has to be carried by hand
    // too. M1 sent an `X-Operator:` header here and M2 sends the session, which
    // is the whole of what changed on the client's side.
    var raw: std.Io.Writer.Allocating = .init(gpa);
    defer raw.deinit();
    try raw.writer.print(
        "POST /v1/docs/1/attach HTTP/1.1\r\nHost: t\r\nCookie: {s}\r\n" ++
            "Content-Type: multipart/form-data; boundary={s}\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ s.cookie.?, boundary, form.len, form },
    );

    const answer = try s.client.send(&s.app, raw.written());
    try testing.expectEqual(@as(u16, 303), answer.status);
    try testing.expectEqualStrings("/v1/docs/1", answer.header("location").?);

    // The bytes come back under the type the client claimed, and the document
    // carries the metadata without carrying the file.
    const back = try s.send("GET", "/v1/docs/1/attachment", null);
    try testing.expectEqualStrings("application/pdf", back.header("content-type").?);
    try testing.expect(std.mem.indexOf(u8, back.body, "%PDF-1.7 hello") != null);

    const doc = try s.send("GET", "/v1/docs/1", null);
    try testing.expect(std.mem.indexOf(u8, doc.body, "\"filename\":\"q3.pdf\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc.body, "%PDF") == null);
}

test "a body read in pieces files what parses and counts what does not" {
    const gpa = testing.allocator;
    var s = try signedIn(gpa);
    defer s.deinit(gpa);

    _ = try s.send("PUT", "/v1/folders/kantor", "{\"name\":\"Kantor\"}");

    const ndjson =
        \\{"title":"Nota 1","kind":"invoice"}
        \\{"title":"Nota 2","tags":["bulk"]}
        \\{ not json at all }
        \\
        \\{"title":"Nota 3"}
    ;
    const answer = try s.send("POST", "/v1/folders/kantor/import", ndjson);
    try testing.expectEqual(@as(u16, 200), answer.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, answer.body, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("filed").?.integer);
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("skipped").?.integer);
}

test "a wildcard is the one param a handler cannot take as an argument" {
    const gpa = testing.allocator;
    var s = try signedIn(gpa);
    defer s.deinit(gpa);

    _ = try s.send("PUT", "/v1/folders/kantor", "{\"name\":\"Kantor\"}");
    _ = try s.send("PUT", "/v1/folders/rumah", "{\"name\":\"Rumah\"}");
    _ = try s.send("POST", "/v1/folders/kantor/docs", "{\"title\":\"Laporan\"}");
    _ = try s.send("POST", "/v1/folders/rumah/docs", "{\"title\":\"Cerita\"}");

    const under = try s.send("GET", "/v1/tree/kantor", null);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, under.body, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 1), parsed.value.object.get("total").?.integer);
}

test "a body deeper than eight levels parses, and its errors stop naming the field" {
    const gpa = testing.allocator;
    var s = try signedIn(gpa);
    defer s.deinit(gpa);

    // Nine levels is fine on the happy path.
    const good = try s.send("POST", "/v1/deep",
        \\{"down":{"down":{"down":{"down":{"down":{"down":{"down":{"down":{"down":{"leaf":7}}}}}}}}}}
    );
    try testing.expectEqual(@as(u16, 200), good.status);

    // A mistake at level eight is named exactly...
    const named = try s.send("POST", "/v1/deep",
        \\{"down":{"down":{"down":{"down":{"down":{"down":{"down":{"down":"nope"}}}}}}}}
    );
    try testing.expectEqual(@as(u16, 400), named.status);
    try testing.expect(std.mem.indexOf(u8, named.body, "down.down") != null);

    // ...and one at level nine is a bare 400 with nothing to go on. That is
    // the documented cliff, and `DX.md` argues it should say so.
    const bare = try s.send("POST", "/v1/deep",
        \\{"down":{"down":{"down":{"down":{"down":{"down":{"down":{"down":{"down":{"leaf":"x"}}}}}}}}}}
    );
    try testing.expectEqual(@as(u16, 400), bare.status);
    try testing.expect(std.mem.indexOf(u8, bare.body, "down") == null);
}

test "the API description names every shape the signatures mention" {
    const gpa = testing.allocator;
    var s = try signedIn(gpa);
    defer s.deinit(gpa);

    const doc = try s.client.get(&s.app, "/openapi.json");
    try testing.expectEqual(@as(u16, 200), doc.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, doc.body, .{});
    defer parsed.deinit();

    const schemas = parsed.value.object.get("components").?.object.get("schemas").?.object;
    // A generic instantiation keeps a name, which is what stops a generated
    // client growing five copies of one shape.
    try testing.expect(schemas.get("Page_Doc") != null);
    try testing.expect(schemas.get("Doc") != null);
    try testing.expect(schemas.get("Failure") != null);
}
