//! The awkward ways in.
//!
//! `handlers.zig` is the JSON API, which is the path every framework's example
//! walks. This file is the rest of what a real archive has to accept, and every
//! route in it exists because it puts a *different* nilo surface under load:
//!
//! | Route | What it is really testing |
//! |---|---|
//! | `POST /v1/docs/:id/attach` | `Form(T)` with an `Upload`, multipart, and a 303 |
//! | `GET  /v1/docs/:id/attachment` | a `*Ctx` handler sending bytes it chose the type of |
//! | `POST /v1/folders/:f/import` | a body too big to hold, read in pieces |
//! | `POST /v1/curate/reindex` | `nilo.blocking`, and the watchdog when you forget |
//! | `GET  /v1/tree/*` | a wildcard, which is the one param with no argument |
//! | `POST /v1/deep` | how far down a body error still names the field |
//!
//! `Settings` arrives as a `*const Settings`, which is a different type from
//! `*Settings` and looked up as such — a read-only service saying so.

const std = @import("std");
const nilo = @import("nilo_http");
const domain = @import("domain.zig");
const copy = @import("copy.zig");
const Archive = @import("archive.zig").Archive;
const Settings = @import("settings.zig").Settings;

const fail = nilo.fail;
const Str = nilo.Str;
const Text = domain.Text;
const Doc = domain.Doc;
const Allocator = std.mem.Allocator;

// ---- a form with a file in it ----

const Attachment = struct {
    /// What a person typed. Shown back to them if the rest of the form is wrong.
    caption: Str,
    /// The file. A form carrying one of these can only arrive as multipart, and
    /// nilo says which to send rather than reporting a missing field.
    file: nilo.Upload,
};

/// A browser posted this, so the answer is a redirect rather than JSON: a 303
/// is what stops a refresh re-sending the file.
///
/// `Bound(Form(T))` rather than `Form(T)` because a person mistyping one box
/// should not lose the other. For the API-shaped route next door, `attachJson`,
/// all-or-nothing would be fine.
fn attachForm(
    store: *Archive,
    limits: *const Settings,
    arena: Allocator,
    id: u32,
    body: nilo.Bound(nilo.Form(Attachment)),
) !nilo.Redirect(303) {
    const form = body.value() orelse return body.fail();

    if (form.file.len() == 0) return fail.unprocessable("that file is empty", .{});
    if (form.file.len() > limits.attachment_bytes) return fail.tooLarge(
        "an attachment goes up to {d} bytes; that one is {d}",
        .{ limits.attachment_bytes, form.file.len() },
    );

    // The filename is whatever the client sent. `../../etc/passwd` is a
    // filename a browser will happily send if asked to, so it is a label to
    // show somebody and never a path (guide/forms.md).
    _ = try store.attach(
        arena,
        id,
        form.file.filename.view(),
        form.file.content_type.view(),
        form.file.bytes.view(),
    ) orelse return fail.notFound("no document {d}", .{id});

    return .to(try std.fmt.allocPrint(arena, "/v1/docs/{d}", .{id}));
}

/// The bytes back. A handler holding a `*Ctx` and returning nothing has
/// answered somewhere in its body, so the API description says `default` about
/// this one — which is correct and is the trade the whole feature rests on.
fn getAttachment(c: *nilo.Ctx, store: *Archive, arena: Allocator, id: u32) !void {
    const found = try store.attachment(arena, id) orelse
        return fail.notFound("document {d} has nothing attached", .{id});
    try c.send(200, found.content_type, found.bytes);
}

// ---- a body too big to hold ----

const Imported = struct {
    filed: usize,
    skipped: usize,
    bytes: usize,
};

/// One JSON object per line, and however many lines they like.
///
/// `c.body()` reads whole and is refused past a megabyte, which is right for
/// JSON and wrong for a bulk import. This holds one line at a time and the read
/// buffer, and nothing else — the ceiling is a number rather than a hope,
/// because a chunked body announces no size and "however much they send" is a
/// client's decision about your memory.
fn importDocs(
    c: *nilo.Ctx,
    store: *Archive,
    limits: *const Settings,
    arena: Allocator,
    folder: Str,
) !Imported {
    if (!try store.hasFolder(folder.view()))
        return fail.notFound("no folder \"{s}\"", .{folder.view()});

    var incoming = c.bodyStreamWith(.{ .max_bytes = limits.import_bytes }) catch
        return fail.tooLarge("this endpoint takes up to {d} bytes", .{limits.import_bytes});

    var out: Imported = .{ .filed = 0, .skipped = 0, .bytes = 0 };
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(arena);

    var buf: [16 * 1024]u8 = undefined;
    while (try incoming.read(&buf)) |part| {
        for (part) |ch| {
            if (ch != '\n') {
                try line.append(arena, ch);
                continue;
            }
            try fileOne(store, arena, folder.view(), line.items, &out);
            line.clearRetainingCapacity();
        }
    }
    try fileOne(store, arena, folder.view(), line.items, &out);

    out.bytes = incoming.seen();
    return out;
}

/// A line that will not parse is skipped rather than ending the import. That is
/// an application's decision and not nilo's — which is the point: nothing here
/// had to be turned off to make it.
fn fileOne(store: *Archive, arena: Allocator, folder: Text, text: []const u8, out: *Imported) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (trimmed.len == 0) return;

    const Line = struct {
        title: []const u8,
        kind: domain.Kind = .note,
        tags: []const []const u8 = &.{},
    };

    const parsed = std.json.parseFromSlice(Line, arena, trimmed, .{}) catch {
        out.skipped += 1;
        return;
    };
    defer parsed.deinit();

    _ = try store.file(arena, folder, .{
        .title = parsed.value.title,
        .kind = parsed.value.kind,
        .tags = parsed.value.tags,
    });
    out.filed += 1;
}

// ---- work that is not IO ----

const Reindexed = struct {
    touched: usize,
    held_thread: bool,
};

/// The right way. `nilo.blocking` hands the call to a pool of real threads and
/// parks only this request — same arguments, same return value, allocates
/// nothing, and outside a running server it just calls the function, so this is
/// still an ordinary function a test can call.
fn reindex(store: *Archive, limits: *const Settings) !Reindexed {
    return .{
        .touched = nilo.blocking(Archive.reindex, .{ store, limits.reindex_rounds }),
        .held_thread = false,
    };
}

/// The wrong way, on purpose, and the only route in this app that is not
/// something you would ship.
///
/// It is here because the interesting thing about this mistake is *when* nilo
/// notices: on the first request, with nobody else on the server. One `curl`
/// against a handler that computes synchronously gives the right answer at the
/// right speed and looks correct in every way you can check by looking — it
/// only misbehaves once there is a second request, which normally means
/// production. What the log says when you hit this is in `DX.md`.
fn reindexHoldingTheThread(store: *Archive, limits: *const Settings) !Reindexed {
    return .{
        .touched = store.reindex(limits.reindex_rounds),
        .held_thread = true,
    };
}

// ---- the param with no argument ----

/// A `*` matches the whole rest of the path and arrives under the name `*`,
/// which is not a legal Zig identifier — so it is the one param that cannot be
/// a typed argument and has to be read from a `*Ctx`.
fn tree(c: *nilo.Ctx, store: *Archive, arena: Allocator) !domain.Page(Doc) {
    const under = c.param("*") orelse return fail.badRequest("no path after /tree/", .{});
    const slug = std.mem.trimEnd(u8, under.view(), "/");
    return store.list(arena, if (slug.len == 0) null else slug, .{ .per_page = 1000 });
}

// ---- how far down does a message still name the field ----

/// Nine levels, one deeper than the eight `guide/requests.md` promises. The
/// route exists to find out what the ninth looks like from a client's side, not
/// because an archive needs one.
fn deep(body: domain.Deep(9)) domain.Deep(9) {
    return body;
}

// ---- wiring ----

pub fn mount(g: anytype) !void {
    try g.post("/docs/:id/attach", attachForm);
    try g.get("/docs/:id/attachment", getAttachment);
    try g.post("/folders/:folder/import", importDocs);
    try g.get("/tree/*", tree);
    try g.post("/deep", deep);
}

pub fn mountCurate(g: anytype) !void {
    try g.post("/reindex", reindex);
    try g.post("/reindex-holding-the-thread", reindexHoldingTheThread);
}

// ---- tests ----

const testing = std.testing;

test "reindexing is an ordinary call when there is no server under it" {
    var store: Archive = .init(testing.allocator);
    defer store.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();

    _ = try store.file(scratch.allocator(), "kantor", .{ .title = "laporan" });

    const done = try reindex(&store, &.{ .reindex_rounds = 4 });
    try testing.expect(!done.held_thread);
}

test "an attachment is bytes beside the row, not a field of it" {
    var store: Archive = .init(testing.allocator);
    defer store.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const doc = try store.file(arena, "kantor", .{ .title = "laporan" });
    try testing.expectEqual(@as(?domain.Attached, null), doc.attachment);

    const after = (try store.attach(arena, doc.id, "q3.pdf", "application/pdf", "%PDF-1.7")).?;
    try testing.expectEqualStrings("q3.pdf", after.attachment.?.filename);
    try testing.expectEqual(@as(usize, 8), after.attachment.?.bytes);

    const blob = (try store.attachment(arena, doc.id)).?;
    try testing.expectEqualStrings("%PDF-1.7", blob.bytes);
    try testing.expectEqual(@as(?@TypeOf(blob), null), try store.attachment(arena, 999));
}
