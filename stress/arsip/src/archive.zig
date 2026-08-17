//! The store, in memory. M3 replaces the body of every method here with a
//! query and leaves the signatures alone — which is the point of writing them
//! this way now.
//!
//! Three rules from `guide/services.md`, applied to a domain that is past the
//! size where the guide shows them inline:
//!
//! - **A row gets an arena**, held by pointer. One `free` per stored type stops
//!   scaling once a row holds an optional struct, a list of structs and two
//!   lists of text; an arena is one call that cannot fall behind the type. By
//!   pointer, because an `ArenaAllocator` that moves when the list grows leaves
//!   every handle taken from it pointing at where the arena used to be.
//! - **Nothing here names `Str`.** A service that cannot say the request type
//!   cannot store one by accident. The conversion happens one layer up, in
//!   `handlers.zig`, which is the only place the lifetime is in question.
//! - **A read copies out, under the lock, into the request.** nilo writes the
//!   response after the handler returns, and by then another thread may have
//!   deleted the row the response was about to be written from.
//!
//! `nilo.Mutex` rather than `std.Thread.Mutex`: many requests share one OS
//! thread, so the std one would stop every other request being served on it
//! (ADR 0011).

const std = @import("std");
const nilo = @import("nilo_http");
const domain = @import("domain.zig");
const copy = @import("copy.zig");

const Allocator = std.mem.Allocator;
const Text = domain.Text;
const Doc = domain.Doc;
const Folder = domain.Folder;

/// A row and everything its text lives in.
fn Row(comptime T: type) type {
    return struct {
        memory: std.heap.ArenaAllocator,
        value: T,
    };
}

const DocRow = Row(Doc);
const FolderRow = Row(Folder);

pub const Archive = struct {
    gpa: Allocator,
    lock: nilo.Mutex = .init,
    docs: std.ArrayList(*DocRow) = .empty,
    folders: std.ArrayList(*FolderRow) = .empty,
    next_id: u32 = 1,

    pub fn init(gpa: Allocator) Archive {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Archive) void {
        for (self.docs.items) |row| self.drop(DocRow, row);
        for (self.folders.items) |row| self.drop(FolderRow, row);
        self.docs.deinit(self.gpa);
        self.folders.deinit(self.gpa);
    }

    fn drop(self: *Archive, comptime R: type, row: *R) void {
        row.memory.deinit();
        self.gpa.destroy(row);
    }

    /// Allocate a row and hand back its arena. The caller fills `.value` and
    /// must `errdefer` the drop until it is on a list.
    fn newRow(self: *Archive, comptime R: type) !*R {
        const row = try self.gpa.create(R);
        row.* = .{ .memory = .init(self.gpa), .value = undefined };
        return row;
    }

    // ---- folders ----

    /// Create or replace. The status the client sees depends on which it was,
    /// which is why this says so rather than answering a `Folder` alone.
    pub fn upsertFolder(
        self: *Archive,
        into: Allocator,
        slug: Text,
        name: Text,
        visibility: domain.Visibility,
    ) !struct { created: bool, folder: Folder } {
        try self.lock.lock();
        defer self.lock.unlock();

        const row = try self.newRow(FolderRow);
        errdefer self.drop(FolderRow, row);
        const mine = row.memory.allocator();
        row.value = .{
            .slug = try mine.dupe(u8, slug),
            .name = try mine.dupe(u8, name),
            .visibility = visibility,
            .docs = 0,
        };

        if (self.findFolder(slug)) |existing| {
            row.value.docs = existing.value.docs;
            const at = std.mem.indexOfScalar(*FolderRow, self.folders.items, existing).?;
            // The new row is complete before the old one goes, so a failure
            // above leaves the folder exactly as it was.
            self.folders.items[at] = row;
            self.drop(FolderRow, existing);
            return .{ .created = false, .folder = try copy.into(Folder, into, row.value, .own) };
        }

        try self.folders.append(self.gpa, row);
        return .{ .created = true, .folder = try copy.into(Folder, into, row.value, .own) };
    }

    pub fn listFolders(self: *Archive, into: Allocator) ![]const Folder {
        try self.lock.lock();
        defer self.lock.unlock();

        const out = try into.alloc(Folder, self.folders.items.len);
        for (out, self.folders.items) |*dst, row| {
            dst.* = try copy.into(Folder, into, row.value, .own);
            dst.docs = self.countIn(row.value.slug);
        }
        return out;
    }

    pub fn hasFolder(self: *Archive, slug: Text) !bool {
        try self.lock.lock();
        defer self.lock.unlock();
        return self.findFolder(slug) != null;
    }

    fn findFolder(self: *Archive, slug: Text) ?*FolderRow {
        for (self.folders.items) |row| {
            if (std.mem.eql(u8, row.value.slug, slug)) return row;
        }
        return null;
    }

    fn countIn(self: *Archive, slug: Text) usize {
        var n: usize = 0;
        for (self.docs.items) |row| {
            if (std.mem.eql(u8, row.value.folder, slug)) n += 1;
        }
        return n;
    }

    // ---- documents ----

    pub fn file(self: *Archive, into: Allocator, folder: Text, incoming: domain.Filing(Text)) !Doc {
        try self.lock.lock();
        defer self.lock.unlock();

        const row = try self.newRow(DocRow);
        errdefer self.drop(DocRow, row);
        const mine = row.memory.allocator();

        // The one deep copy: every byte the row will ever own, in one call.
        const owned = try copy.into(domain.Filing(Text), mine, incoming, .own);
        row.value = .{
            .id = self.next_id,
            .folder = try mine.dupe(u8, folder),
            .stage = .draft,
            .title = owned.title,
            .kind = owned.kind,
            .visibility = owned.visibility,
            .meta = owned.meta,
            .sections = owned.sections,
            .tags = owned.tags,
        };

        try self.docs.append(self.gpa, row);
        self.next_id += 1;
        return try copy.into(Doc, into, row.value, .own);
    }

    pub fn get(self: *Archive, into: Allocator, id: u32) !?Doc {
        try self.lock.lock();
        defer self.lock.unlock();
        const row = self.findDoc(id) orelse return null;
        return try copy.into(Doc, into, row.value, .own);
    }

    pub fn list(
        self: *Archive,
        into: Allocator,
        folder: ?Text,
        filter: domain.Filter(Text),
    ) !domain.Page(Doc) {
        try self.lock.lock();
        defer self.lock.unlock();

        var matched: std.ArrayList(*DocRow) = .empty;
        defer matched.deinit(into);
        for (self.docs.items) |row| {
            if (matches(row.value, folder, filter)) try matched.append(into, row);
        }

        std.mem.sort(*DocRow, matched.items, filter.sort, lessThan);

        const per_page = @max(filter.per_page, 1);
        const first = (@max(filter.page, 1) - 1) * per_page;
        const last = @min(first + per_page, matched.items.len);
        const window = if (first >= matched.items.len) matched.items[0..0] else matched.items[first..last];

        const items = try into.alloc(Doc, window.len);
        for (items, window) |*dst, row| dst.* = try copy.into(Doc, into, row.value, .own);

        return .{
            .items = items,
            .page = @max(filter.page, 1),
            .per_page = per_page,
            .total = matched.items.len,
        };
    }

    pub fn edit(self: *Archive, into: Allocator, id: u32, change: domain.Edit) !?Doc {
        try self.lock.lock();
        defer self.lock.unlock();

        const row = self.findDoc(id) orelse return null;
        const mine = row.memory.allocator();

        // An arena never reclaims, so an edited row grows. That is the trade a
        // row arena makes and it is fine for a store this size; M3 hands the
        // whole question to Postgres.
        if (change.title) |t| row.value.title = try mine.dupe(u8, t);
        if (change.visibility) |v| row.value.visibility = v;
        switch (change.meta) {
            .keep => {},
            .clear => row.value.meta = null,
            .set => |m| row.value.meta = try copy.into(domain.Meta(Text), mine, m, .own),
        }

        return try copy.into(Doc, into, row.value, .own);
    }

    pub fn advance(self: *Archive, into: Allocator, id: u32, to: domain.Stage) !?domain.Advanced {
        try self.lock.lock();
        defer self.lock.unlock();

        const row = self.findDoc(id) orelse return null;
        const current = row.value.stage;
        if (current.next() != to) return .{ .refused = current };

        row.value.stage = to;
        return .{ .moved = try copy.into(Doc, into, row.value, .own) };
    }

    pub fn remove(self: *Archive, id: u32) !bool {
        try self.lock.lock();
        defer self.lock.unlock();

        const row = self.findDoc(id) orelse return false;
        const at = std.mem.indexOfScalar(*DocRow, self.docs.items, row).?;
        _ = self.docs.orderedRemove(at);
        self.drop(DocRow, row);
        return true;
    }

    pub fn summary(self: *Archive) !domain.Summary {
        try self.lock.lock();
        defer self.lock.unlock();

        var out: domain.Summary = .{
            .folders = self.folders.items.len,
            .docs = self.docs.items.len,
            .draft = 0,
            .review = 0,
            .filed = 0,
            .archived = 0,
        };
        for (self.docs.items) |row| switch (row.value.stage) {
            .draft => out.draft += 1,
            .review => out.review += 1,
            .filed => out.filed += 1,
            .archived => out.archived += 1,
        };
        return out;
    }

    fn findDoc(self: *Archive, id: u32) ?*DocRow {
        for (self.docs.items) |row| {
            if (row.value.id == id) return row;
        }
        return null;
    }
};

fn matches(doc: Doc, folder: ?Text, filter: domain.Filter(Text)) bool {
    if (folder) |slug| {
        if (!std.mem.eql(u8, doc.folder, slug)) return false;
    }
    if (filter.stage) |s| {
        if (doc.stage != s) return false;
    }
    if (filter.kind) |k| {
        if (doc.kind != k) return false;
    }
    if (filter.q) |needle| {
        if (needle.len != 0 and std.mem.indexOf(u8, doc.title, needle) == null) {
            for (doc.tags) |tag| {
                if (std.mem.eql(u8, tag, needle)) return true;
            }
            return false;
        }
    }
    return true;
}

fn lessThan(sort: domain.Sort, a: *DocRow, b: *DocRow) bool {
    return switch (sort) {
        .newest => a.value.id > b.value.id,
        .oldest => a.value.id < b.value.id,
        .title => std.mem.lessThan(u8, a.value.title, b.value.title),
    };
}

// ---- tests ----
//
// A service is an ordinary struct, so these run with no server in the process
// and no HTTP anywhere.

const testing = std.testing;

fn filed(store: *Archive, arena: Allocator, title: Text) !Doc {
    return store.file(arena, "kantor", .{ .title = title, .tags = &.{"penting"} });
}

test "a document that was filed comes back with its own copy of the text" {
    var store: Archive = .init(testing.allocator);
    defer store.deinit();

    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var title: [7]u8 = "laporan".*;
    const doc = try store.file(arena, "kantor", .{ .title = &title, .sections = &.{
        .{ .heading = "ringkasan", .lines = &.{ "satu", "dua" } },
    } });

    // The store owns its bytes: scribbling on the caller's buffer changes
    // nothing that was stored.
    @memset(&title, 'x');
    const found = (try store.get(arena, doc.id)).?;
    try testing.expectEqualStrings("laporan", found.title);
    try testing.expectEqualStrings("dua", found.sections[0].lines[1]);
}

test "a document moves one stage at a time and says what it is in when it will not" {
    var store: Archive = .init(testing.allocator);
    defer store.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const doc = try filed(&store, arena, "laporan");

    switch ((try store.advance(arena, doc.id, .filed)).?) {
        .refused => |stage| try testing.expectEqual(domain.Stage.draft, stage),
        .moved => return error.TestUnexpectedResult,
    }
    switch ((try store.advance(arena, doc.id, .review)).?) {
        .moved => |moved| try testing.expectEqual(domain.Stage.review, moved.stage),
        .refused => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(?domain.Advanced, null), try store.advance(arena, 999, .review));
}

test "an edit can leave a field alone, replace it, or empty it out" {
    var store: Archive = .init(testing.allocator);
    defer store.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const doc = try store.file(arena, "kantor", .{
        .title = "laporan",
        .meta = .{ .author = "wati", .@"type" = .invoice },
    });

    const untouched = (try store.edit(arena, doc.id, .{})).?;
    try testing.expectEqualStrings("wati", untouched.meta.?.author);
    try testing.expectEqualStrings("laporan", untouched.title);

    const replaced = (try store.edit(arena, doc.id, .{
        .title = "laporan akhir",
        .meta = .{ .set = .{ .author = "budi", .@"type" = .contract } },
    })).?;
    try testing.expectEqualStrings("laporan akhir", replaced.title);
    try testing.expectEqual(domain.Kind.contract, replaced.meta.?.@"type");

    const cleared = (try store.edit(arena, doc.id, .{ .meta = .clear })).?;
    try testing.expectEqual(@as(?domain.Meta(Text), null), cleared.meta);
}

test "listing filters, sorts and pages" {
    var store: Archive = .init(testing.allocator);
    defer store.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    _ = try store.file(arena, "kantor", .{ .title = "anggaran", .kind = .invoice });
    _ = try store.file(arena, "kantor", .{ .title = "berita", .kind = .note });
    _ = try store.file(arena, "rumah", .{ .title = "cerita", .kind = .note });

    const all = try store.list(arena, null, .{});
    try testing.expectEqual(@as(usize, 3), all.total);
    try testing.expectEqualStrings("cerita", all.items[0].title); // newest first

    const in_office = try store.list(arena, "kantor", .{ .sort = .title });
    try testing.expectEqual(@as(usize, 2), in_office.total);
    try testing.expectEqualStrings("anggaran", in_office.items[0].title);

    const notes = try store.list(arena, null, .{ .kind = .note, .per_page = 1, .page = 2 });
    try testing.expectEqual(@as(usize, 2), notes.total);
    try testing.expectEqual(@as(usize, 1), notes.items.len);

    const past_the_end = try store.list(arena, null, .{ .page = 9 });
    try testing.expectEqual(@as(usize, 0), past_the_end.items.len);
}

test "a folder written twice is replaced rather than added" {
    var store: Archive = .init(testing.allocator);
    defer store.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const first = try store.upsertFolder(arena, "kantor", "Kantor", .private);
    try testing.expect(first.created);

    const second = try store.upsertFolder(arena, "kantor", "Kantor Pusat", .team);
    try testing.expect(!second.created);
    try testing.expectEqualStrings("Kantor Pusat", second.folder.name);

    const folders = try store.listFolders(arena);
    try testing.expectEqual(@as(usize, 1), folders.len);
}
