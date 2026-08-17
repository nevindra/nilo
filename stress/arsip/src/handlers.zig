//! The API. Every function here is an ordinary Zig function — no HTTP type in
//! any signature that did not need one, so every one of them is callable from
//! the tests at the bottom without a server, a socket or a fake request.
//!
//! This file is where the two text types meet. Above it a body is `Str` and
//! below it a row is `[]const u8`, and `copy.into(…, .borrow)` is the one line
//! that crosses. Nothing under here can name `Str`, which is the property that
//! makes it impossible to store one by accident.

const std = @import("std");
const nilo = @import("nilo_http");
const domain = @import("domain.zig");
const copy = @import("copy.zig");
const Archive = @import("archive.zig").Archive;

const fail = nilo.fail;
const Str = nilo.Str;
const Text = domain.Text;
const Doc = domain.Doc;
const Allocator = std.mem.Allocator;

/// Neither a service nor request data: worked out *from* the request, once,
/// whichever route asked for it. M2 replaces the body of `authenticate` with a
/// session cookie and a password, and no handler below changes.
pub const Operator = struct {
    pub const nilo_resolve = authenticate;

    name: Str,
    curator: bool,
};

fn authenticate(c: *nilo.Ctx) !Operator {
    const who = c.header("X-Operator") orelse
        return fail.unauthorized("this endpoint needs an X-Operator header", .{});
    if (who.len() == 0) return fail.unauthorized("X-Operator is empty", .{});
    return .{ .name = who, .curator = who.eql("bu-sri") };
}

/// A resolved value built out of **another resolved value** rather than out of
/// a second copy of the auth code. That is the whole reason a resolver may take
/// one: `Curator` is `Operator` plus a refusal, and neither of them reads a
/// header twice — both are worked out once per request, whichever route or
/// middleware asks first.
pub const Curator = struct {
    pub const nilo_resolve = onlyCurators;

    name: Str,
};

fn onlyCurators(operator: Operator) !Curator {
    if (!operator.curator) return fail.forbidden(
        "only a curator can do that, and {s} is not one",
        .{operator.name.view()},
    );
    return .{ .name = operator.name };
}

/// A prefix guard. A resolved value alone is the wrong tool for securing a
/// prefix — only routes that name one get it, so a handler that forgets the
/// argument is simply not authenticated. `useOn` applies whether the handler
/// cooperates or not, and `c.resolve` is how the two meet: this lookup and the
/// handler's argument are the same one lookup, not two.
pub fn requireCurator(c: *nilo.Ctx, next: nilo.Next) !void {
    _ = try c.resolve(Curator);
    try next.run(c);
}

// ---- folders ----

fn listFolders(store: *Archive, arena: Allocator) ![]const domain.Folder {
    return store.listFolders(arena);
}

/// The status is not known until it runs, which is what `Response(T)` is for.
/// `Status(201, T)` would put the code in the type and be a lie half the time.
fn putFolder(
    store: *Archive,
    arena: Allocator,
    slug: Str,
    incoming: domain.NewFolder,
) !nilo.Response(domain.Folder) {
    const done = try store.upsertFolder(arena, slug.view(), incoming.name.view(), incoming.visibility);
    return .{ .status = if (done.created) 201 else 200, .value = done.folder };
}

// ---- documents ----

fn listDocs(
    store: *Archive,
    arena: Allocator,
    params: nilo.Query(domain.Search),
) !domain.Page(Doc) {
    const filter = try copy.into(domain.Filter(Text), arena, params.value, .borrow);
    return store.list(arena, null, filter);
}

fn listInFolder(
    store: *Archive,
    arena: Allocator,
    folder: Str,
    params: nilo.Query(domain.Search),
) !domain.Page(Doc) {
    try requireFolder(store, folder);
    const filter = try copy.into(domain.Filter(Text), arena, params.value, .borrow);
    return store.list(arena, folder.view(), filter);
}

/// `Bound(T)` rather than a plain struct argument: a plain one stops at the
/// first field it cannot read and answers a 400 about that one, which makes
/// filling in a form a game of twenty questions. This answers a 422 naming
/// every bad field at once.
fn fileDoc(
    store: *Archive,
    arena: Allocator,
    folder: Str,
    body: nilo.Bound(domain.NewDoc),
) !nilo.Status(201, Doc) {
    try requireFolder(store, folder);
    const incoming = body.value() orelse return body.fail();
    if (incoming.title.len() == 0) return fail.unprocessable("a document needs a title", .{});

    const borrowed = try copy.into(domain.Filing(Text), arena, incoming, .borrow);
    const doc = try store.file(arena, folder.view(), borrowed);

    return .{
        .headers = .of(&.{.{
            .name = "Location",
            .value = try std.fmt.allocPrint(arena, "/v1/docs/{d}", .{doc.id}),
        }}),
        .value = doc,
    };
}

/// The whole 404 is in the return type, and the generated description says so.
fn getDoc(store: *Archive, arena: Allocator, id: u32) !?Doc {
    return store.get(arena, id);
}

/// Three answers where an optional has two — and the mapping onto the store's
/// own three is where `.cleared` on a field that cannot be cleared becomes a
/// 400 rather than a silent nothing.
fn editDoc(store: *Archive, arena: Allocator, id: u32, incoming: domain.EditDoc) !?Doc {
    const title: ?Text = switch (incoming.title) {
        .absent => null,
        .cleared => return fail.badRequest(
            "a document keeps its title — send a new one rather than null",
            .{},
        ),
        .value => |v| v.view(),
    };

    const visibility: ?domain.Visibility = switch (incoming.visibility) {
        .absent => null,
        .cleared => return fail.badRequest(
            "visibility cannot be emptied; it is one of private, team, public",
            .{},
        ),
        .value => |v| v,
    };

    const meta: domain.Change(domain.Meta(Text)) = switch (incoming.meta) {
        .absent => .keep,
        .cleared => .clear,
        .value => |m| .{ .set = try copy.into(domain.Meta(Text), arena, m, .borrow) },
    };

    return store.edit(arena, id, .{ .title = title, .visibility = visibility, .meta = meta });
}

/// A state machine that answers 409 — the one failure a signature cannot
/// state, so it is a `fail` function and the API description does not claim it
/// (ADR 0024).
fn advanceDoc(store: *Archive, arena: Allocator, id: u32, incoming: domain.Advance) !Doc {
    const done = try store.advance(arena, id, incoming.to) orelse
        return fail.notFound("no document {d}", .{id});

    switch (done) {
        .moved => |doc| return doc,
        .refused => |stage| return fail.conflict(
            "a document in {s} cannot go to {s}; from {s} the only way on is {s}",
            .{
                @tagName(stage),
                @tagName(incoming.to),
                @tagName(stage),
                if (stage.next()) |n| @tagName(n) else "nowhere",
            },
        ),
    }
}

fn deleteDoc(store: *Archive, id: u32) !nilo.Status(204, void) {
    if (!try store.remove(id)) return fail.notFound("no document {d}", .{id});
    return .{};
}

/// The way out. A handler holding a `*Ctx` and returning nothing has answered
/// somewhere in its body, and no reading of its signature will find out what —
/// so this is the one route the API description says `default` about, and
/// `listen()` counts it out loud at startup.
fn rawDoc(c: *nilo.Ctx, store: *Archive, arena: Allocator, id: u32) !void {
    const doc = try store.get(arena, id) orelse return fail.notFound("no document {d}", .{id});

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{s}\n\n", .{doc.title});
    for (doc.sections) |section| {
        try out.writer.print("## {s}\n", .{section.heading});
        for (section.lines) |line| try out.writer.print("{s}\n", .{line});
        try out.writer.writeByte('\n');
    }
    try c.send(200, "text/plain; charset=utf-8", out.written());
}

// ---- who is asking ----

const Profile = struct {
    name: Str,
    curator: bool,
};

fn me(operator: Operator) Profile {
    return .{ .name = operator.name, .curator = operator.curator };
}

/// Takes the `Curator`, not the `Operator`. The middleware on this prefix has
/// already resolved one; asking for it here is a read of that same value rather
/// than a second check somebody could forget to write.
fn report(store: *Archive, curator: Curator) !domain.Summary {
    _ = curator;
    return store.summary();
}

// ---- wiring ----

/// A plugin is an ordinary function that takes a group. Nothing to register,
/// and the same function mounts at any prefix.
pub fn mount(g: anytype) !void {
    try g.use(requireOperator);

    try g.get("/me", me);
    try g.get("/folders", listFolders);
    try g.put("/folders/:slug", putFolder);
    try g.get("/folders/:folder/docs", listInFolder);
    try g.post("/folders/:folder/docs", fileDoc);

    try g.get("/docs", listDocs);
    try g.get("/docs/:id", getDoc);
    try g.get("/docs/:id/raw", rawDoc);
    try g.patch("/docs/:id", editDoc);
    try g.delete("/docs/:id", deleteDoc);
    try g.post("/docs/:id/advance", advanceDoc);

    try @import("intake.zig").mount(g);

    const curators = g.group("/curate");
    try curators.use(requireCurator);
    try curators.get("/report", report);
    try @import("intake.zig").mountCurate(curators);
}

/// Registered on the whole group rather than named by each handler, so a route
/// added later is guarded whether or not its author remembered.
fn requireOperator(c: *nilo.Ctx, next: nilo.Next) !void {
    _ = try c.resolve(Operator);
    try next.run(c);
}

fn requireFolder(store: *Archive, folder: Str) !void {
    if (!try store.hasFolder(folder.view()))
        return fail.notFound("no folder \"{s}\"", .{folder.view()});
}

// ---- tests ----
//
// Handlers are ordinary functions, so none of this starts a server.

const testing = std.testing;

const Fixture = struct {
    store: Archive,
    scratch: std.heap.ArenaAllocator,

    fn init(gpa: Allocator) Fixture {
        return .{ .store = .init(gpa), .scratch = .init(gpa) };
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.scratch.deinit();
    }

    fn arena(self: *Fixture) Allocator {
        return self.scratch.allocator();
    }
};

/// `Bound(T)` is the one handler argument the testing page does not show how to
/// build. `from(value, outcomes)` is public and `Outcome`'s fields all have
/// defaults, so `@splat(.{})` is "every field bound fine" — but you have to
/// read `http/bound.zig` to find that out. See `DX.md`.
fn bound(value: domain.NewDoc) nilo.Bound(domain.NewDoc) {
    return .from(value, @splat(.{}));
}

test "filing a document into a folder nobody made is a 404, not a new folder" {
    var f: Fixture = .init(testing.allocator);
    defer f.deinit();

    try testing.expectError(error.Failed, fileDoc(
        &f.store,
        f.arena(),
        .static("hilang"),
        bound(.{ .title = .static("laporan") }),
    ));
}

test "a document filed through the handler keeps the folder it was filed into" {
    var f: Fixture = .init(testing.allocator);
    defer f.deinit();

    _ = try f.store.upsertFolder(f.arena(), "kantor", "Kantor", .team);
    const created = try fileDoc(&f.store, f.arena(), .static("kantor"), bound(.{
        .title = .static("laporan"),
        .kind = .invoice,
        .sections = &.{.{ .heading = .static("ringkasan"), .lines = &.{.static("satu")} }},
    }));

    try testing.expectEqualStrings("kantor", created.value.folder);
    try testing.expectEqualStrings("satu", created.value.sections[0].lines[0]);
    try testing.expectEqual(domain.Stage.draft, created.value.stage);
}

test "a document that will not move says what it is in" {
    var f: Fixture = .init(testing.allocator);
    defer f.deinit();

    const doc = try f.store.file(f.arena(), "kantor", .{ .title = "laporan" });
    try testing.expectError(error.Failed, advanceDoc(&f.store, f.arena(), doc.id, .{ .to = .archived }));

    const moved = try advanceDoc(&f.store, f.arena(), doc.id, .{ .to = .review });
    try testing.expectEqual(domain.Stage.review, moved.stage);
}

test "clearing a title is refused, clearing the meta is not" {
    var f: Fixture = .init(testing.allocator);
    defer f.deinit();

    const doc = try f.store.file(f.arena(), "kantor", .{
        .title = "laporan",
        .meta = .{ .author = "wati" },
    });

    try testing.expectError(error.Failed, editDoc(&f.store, f.arena(), doc.id, .{ .title = .cleared }));

    const cleared = (try editDoc(&f.store, f.arena(), doc.id, .{ .meta = .cleared })).?;
    try testing.expectEqual(@as(?domain.Meta(Text), null), cleared.meta);
}

test "a document that is not there is a null, which is the 404" {
    var f: Fixture = .init(testing.allocator);
    defer f.deinit();
    try testing.expectEqual(@as(?Doc, null), try getDoc(&f.store, f.arena(), 404));
}

test "the profile a curator sees is the one the resolver worked out" {
    const seen = me(.{ .name = .static("bu-sri"), .curator = true });
    try testing.expect(seen.curator);
    try testing.expectEqualStrings("bu-sri", seen.name.view());
}
