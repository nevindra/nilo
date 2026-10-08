//! `zig build docs-check` and `docs-index`: the documentation held to one
//! shape (ADR 236), as a program the build runs (`checks/main.zig` says why).

const std = @import("std");
const Report = @import("main.zig").Report;
const AdrCheck = @import("adr.zig").AdrCheck;

/// The step that holds the documentation to one shape, so a reader, a person
/// or an agent, finds any topic the same way (ADR 236).
///
/// Every page of `docs/guide/`, `docs/design/` and `docs/reference/`, and the
/// map at `docs/README.md`, opens with five lines: a title, one bold sentence
/// saying what the page is, and a line linking the same topic in the other two
/// layers. Its prose is one paragraph a line, so a phrase is never split for
/// grep, and carries no em dash. Every relative link on it resolves, every
/// anchor any Markdown file in the repository names on it exists, the map
/// links every page, and the reference's list of every heading is exactly the
/// one the pages produce. `docs-index` rewrites that list; `docs-check`, on
/// `test`, refuses it when it is out of step.
///
/// The todo list and the roadmap are held the same way. An anchor into them,
/// or into `decided.md`, `history.md` and `risks.md`, is checked as one into a
/// page is, though their own heads and prose are not a page's. A todo entry
/// names the roadmap direction it serves on a `**Direction:**` line, and each
/// direction's list of those entries is written by `docs-index` from those
/// lines, so a direction never lists an entry that has left. The todo list
/// says on its `**Ranked at X.**` line which version it was last ranked at,
/// and a release that bumps `build.zig.zon` past it fails here until the list
/// is ranked again.
///
/// Anchors are GitHub's, lowercase with punctuation dropped, because the
/// reference and the design pages are read on GitHub (ADR 219). A scan rather
/// than a parse, like `AdrCheck`: the shapes it reads are the ones these pages
/// are written in.
pub const DocsCheck = struct {
    const map = "docs/README.md";
    const index = "docs/reference/README.md";
    const index_heading = "## Every heading";
    const index_note = "Every heading of every page, in page order. Find a name here, then read it on its page. `zig build docs-index` writes this list from the pages, and `zig build docs-check` refuses it when it is out of step.";
    const folders = [_][]const u8{ "docs/guide", "docs/design", "docs/reference" };
    const todo = "docs/todo.md";
    const roadmap = "docs/roadmap.md";
    /// Files other pages link into by heading that are not pages themselves.
    const targets = [_][]const u8{ todo, roadmap, "docs/decided.md", "docs/history.md", "docs/risks.md" };
    const gathered_open = "<!-- gathered: `zig build docs-index` writes this list from the Direction lines in docs/todo.md -->";
    const gathered_close = "<!-- /gathered -->";
    const direction_line = "**Direction:**";
    const heads = [_][]const u8{ "**Guide:**", "**Reference:**", "**Design:**" };

    const Page = struct { path: []const u8, text: []const u8 };

    /// With `write` the pages are rewritten to what they should say (`zig
    /// build docs-index`), and without it they are only compared.
    pub fn run(r: *Report, write: bool) anyerror!void {
        const io = r.io;
        const gpa = r.gpa;
        const root = r.root;

        var pages: std.ArrayList(Page) = .empty;
        try pages.append(gpa, .{ .path = map, .text = try root.readFileAlloc(io, map, gpa, .limited(1 << 20)) });
        for (folders) |folder| {
            var dir = root.openDir(io, folder, .{ .iterate = true }) catch |err|
                return r.fail("nilo: cannot read `{s}/`: {s}", .{ folder, @errorName(err) });
            defer dir.close(io);
            var walker = try dir.walk(gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".md")) continue;
                try pages.append(gpa, .{
                    .path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ folder, entry.path }),
                    .text = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 << 20)),
                });
            }
        }

        var known: std.ArrayList(Page) = .empty;
        try known.appendSlice(gpa, pages.items);
        for (targets) |path| try known.append(gpa, .{ .path = path, .text = try root.readFileAlloc(io, path, gpa, .limited(1 << 20)) });

        var refused: usize = 0;
        const current = pageAt(pages.items, index).?.text;
        const wanted = try indexed(gpa, pages.items, current);
        const plan = pageAt(known.items, roadmap).?.text;
        const planned = try gathered(r, pageAt(known.items, todo).?.text, plan, &refused);
        if (write) {
            if (!std.mem.eql(u8, wanted, current)) try root.writeFile(io, .{ .sub_path = index, .data = wanted });
            if (!std.mem.eql(u8, planned, plan)) try root.writeFile(io, .{ .sub_path = roadmap, .data = planned });
            if (refused > 0) return error.CheckFailed;
            return;
        }

        for (pages.items) |page| {
            refused += try head(r, page);
            refused += try prose(r, page);
            refused += try links(r, page.path, page.text, known.items, true);
        }
        refused += try mapped(r, pages.items);
        if (!std.mem.eql(u8, wanted, current)) {
            refused += 1;
            try r.addError("nilo: {s}'s list of every heading is out of step with the pages; `zig build docs-index` rewrites it.", .{index});
        }
        if (!std.mem.eql(u8, planned, plan)) {
            refused += 1;
            try r.addError("nilo: {s}'s lists of todo entries are out of step with the Direction lines in {s}; `zig build docs-index` rewrites them.", .{ roadmap, todo });
        }
        refused += try ranked(r, pageAt(known.items, todo).?.text, try root.readFileAlloc(io, "build.zig.zon", gpa, .limited(1 << 16)));

        // An anchor named from anywhere else: an ADR, the changelog, the roadmap.
        var repo = try root.openDir(io, ".", .{ .iterate = true });
        defer repo.close(io);
        var walker = try repo.walkSelectively(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (entry.basename[0] != '.' and !AdrCheck.listed(entry.basename)) try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".md")) continue;
            if (pageAt(pages.items, entry.path) != null) continue;
            const text = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(8 << 20)) catch continue;
            refused += try links(r, try gpa.dupe(u8, entry.path), text, known.items, false);
        }

        if (refused > 0) return error.CheckFailed;
    }

    fn pageAt(pages: []const Page, path: []const u8) ?Page {
        for (pages) |page| if (std.mem.eql(u8, page.path, path)) return page;
        return null;
    }

    /// Lines 1 to 5: `# Title`, a blank, `**One sentence.**`, a blank, and the
    /// line that links the other layers.
    fn head(r: *Report, page: Page) !usize {
        var lines = std.mem.splitScalar(u8, page.text, '\n');
        var first: [5][]const u8 = @splat("");
        for (&first) |*line| line.* = lines.next() orelse "";
        const claim = std.mem.trimEnd(u8, first[2], " ");
        const says: ?[]const u8 = if (!std.mem.startsWith(u8, first[0], "# "))
            "line 1 is not a `# ` title"
        else if (first[1].len != 0 or first[3].len != 0)
            "lines 2 and 4 are not blank"
        else if (claim.len < 5 or !std.mem.startsWith(u8, claim, "**") or !std.mem.endsWith(u8, claim, "**"))
            "line 3 is not one bold sentence saying what the page is"
        else for (heads) |layer| {
            if (std.mem.startsWith(u8, first[4], layer)) break null;
        } else "line 5 does not start with `**Guide:**`, `**Reference:**` or `**Design:**`, linking the same topic in the other layers";
        if (says) |why| {
            try r.addError("nilo: {s}: {s}. See how `docs/README.md` opens.", .{ page.path, why });
            return 1;
        }
        return 0;
    }

    /// Outside a code fence and outside inline code: no em dash, and no
    /// paragraph carried onto a second line.
    fn prose(r: *Report, page: Page) !usize {
        var refused: usize = 0;
        var fenced = false;
        var lines = std.mem.splitScalar(u8, page.text, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (fence(line)) {
                fenced = !fenced;
                continue;
            }
            if (fenced) continue;
            if (dashed(line)) {
                refused += 1;
                try r.addError("nilo: {s}:{d} has an em dash in prose; use a comma, a colon, a full stop or parentheses.", .{ page.path, n });
            }
            const next = lines.peek() orelse "";
            if (paragraph(line) and continues(next) and !std.mem.endsWith(u8, line, "  ") and !std.mem.endsWith(u8, line, ":")) {
                refused += 1;
                try r.addError("nilo: {s}:{d} carries a paragraph onto the next line; a paragraph is one line.", .{ page.path, n });
            }
        }
        return refused;
    }

    fn fence(line: []const u8) bool {
        const t = std.mem.trimStart(u8, line, " ");
        return std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~");
    }

    fn dashed(line: []const u8) bool {
        var code = false;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (line[i] == '`') code = !code;
            if (!code and std.mem.startsWith(u8, line[i..], "\u{2014}")) return true;
        }
        return false;
    }

    fn numbered(t: []const u8) bool {
        var i: usize = 0;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        return i > 0 and i < t.len and t[i] == '.';
    }

    /// A line of running text: not a heading, table, quote, list item, HTML
    /// comment or a line that opens in bold.
    fn paragraph(line: []const u8) bool {
        const t = std.mem.trimStart(u8, line, " ");
        return t.len > 0 and std.mem.indexOfScalar(u8, "#|>*-<", t[0]) == null and !numbered(t);
    }

    /// The line after a paragraph line, read as the same paragraph going on.
    fn continues(line: []const u8) bool {
        const t = std.mem.trimStart(u8, line, " ");
        if (t.len == 0 or std.mem.indexOfScalar(u8, "#|>-<`~", t[0]) != null or numbered(t)) return false;
        if (std.mem.startsWith(u8, t, "**")) {
            if (std.mem.indexOf(u8, t, ":**")) |colon| {
                for (t[2..colon]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return true;
                return false;
            }
        }
        return true;
    }

    /// Every `](target)` whose target is in the repository: the file exists
    /// (checked on the pages only), and an anchor into a page, or into one of
    /// `targets`, is a heading on it.
    fn links(r: *Report, path: []const u8, text: []const u8, pages: []const Page, files: bool) !usize {
        const gpa = r.gpa;
        var refused: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "](")) |open| {
            at = open + 2;
            const close = std.mem.indexOfAnyPos(u8, text, at, ") \n") orelse break;
            if (text[close] != ')') continue;
            const target = text[at..close];
            if (target.len == 0 or std.mem.indexOf(u8, target, "://") != null or std.mem.startsWith(u8, target, "mailto:")) continue;
            const hash = std.mem.indexOfScalar(u8, target, '#');
            const file = target[0 .. hash orelse target.len];
            const resolved = if (file.len == 0) path else try std.fs.path.resolvePosix(gpa, &.{ std.fs.path.dirnamePosix(path) orelse ".", file });
            if (std.mem.startsWith(u8, resolved, "..")) continue;
            const line = std.mem.count(u8, text[0..open], "\n") + 1;
            if (files and file.len > 0) {
                if (r.root.access(r.io, resolved, .{})) |_| {} else |_| {
                    refused += 1;
                    try r.addError("nilo: {s}:{d} links to {s}, which does not exist.", .{ path, line, file });
                    continue;
                }
            }
            const anchor = if (hash) |h| target[h + 1 ..] else continue;
            const page = pageAt(pages, resolved) orelse continue;
            if (!try hasAnchor(gpa, page.text, anchor)) {
                refused += 1;
                try r.addError("nilo: {s}:{d} links to {s}#{s}, and no heading there has that anchor.", .{ path, line, resolved, anchor });
            }
        }
        return refused;
    }

    /// GitHub's anchor for a heading: lowercase, spaces to `-`, and everything
    /// but letters, digits, `-` and `_` dropped. A byte past ASCII is dropped
    /// too, which is right for the `…` and `→` these headings use.
    fn slug(gpa: std.mem.Allocator, heading: []const u8) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (std.mem.trim(u8, heading, " ")) |c| {
            if (c == ' ') {
                try out.append(gpa, '-');
            } else if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
                try out.append(gpa, std.ascii.toLower(c));
            }
        }
        return out.items;
    }

    const Heading = struct { depth: usize, text: []const u8, anchor: []const u8 };

    /// Every heading outside a code fence, with its anchor; a repeated one
    /// gets `-1`, `-2` on the end, the way GitHub numbers them.
    fn headings(gpa: std.mem.Allocator, text: []const u8) ![]Heading {
        var out: std.ArrayList(Heading) = .empty;
        var seen: std.StringHashMapUnmanaged(usize) = .empty;
        var fenced = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (fence(line)) {
                fenced = !fenced;
                continue;
            }
            if (fenced) continue;
            var depth: usize = 0;
            while (depth < line.len and line[depth] == '#') depth += 1;
            if (depth == 0 or depth > 6 or depth >= line.len or line[depth] != ' ') continue;
            const words = std.mem.trim(u8, line[depth + 1 ..], " ");
            const base = try slug(gpa, words);
            const count = try seen.getOrPut(gpa, base);
            const n = if (count.found_existing) count.value_ptr.* else 0;
            count.value_ptr.* = n + 1;
            try out.append(gpa, .{
                .depth = depth,
                .text = words,
                .anchor = if (n == 0) base else try std.fmt.allocPrint(gpa, "{s}-{d}", .{ base, n }),
            });
        }
        return out.items;
    }

    fn hasAnchor(gpa: std.mem.Allocator, text: []const u8, anchor: []const u8) !bool {
        for (try headings(gpa, text)) |h| if (std.mem.eql(u8, h.anchor, anchor)) return true;
        return false;
    }

    /// The map links every page of the three folders.
    fn mapped(r: *Report, pages: []const Page) !usize {
        const gpa = r.gpa;
        const text = pageAt(pages, map).?.text;
        var linked: std.StringHashMapUnmanaged(void) = .empty;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, text, at, "](")) |open| {
            at = open + 2;
            const close = std.mem.indexOfScalarPos(u8, text, at, ')') orelse break;
            const target = text[at..close];
            const file = target[0 .. std.mem.indexOfScalar(u8, target, '#') orelse target.len];
            if (file.len == 0) continue;
            try linked.put(gpa, try std.fs.path.resolvePosix(gpa, &.{ "docs", file }), {});
        }
        var refused: usize = 0;
        for (pages) |page| {
            if (std.mem.eql(u8, page.path, map) or linked.contains(page.path)) continue;
            refused += 1;
            try r.addError("nilo: {s} does not link {s}; every page of the guide, the reference and the design pages has a row or a link there.", .{ map, page.path });
        }
        return refused;
    }

    /// The reference's README with its list of every heading as the pages
    /// produce it: pages in the order the list has them, a page it does not
    /// list yet on the end, and each page's headings from `##` down to `####`.
    fn indexed(gpa: std.mem.Allocator, pages: []const Page, current: []const u8) ![]u8 {
        const cut = std.mem.indexOf(u8, current, index_heading) orelse current.len;
        var order: std.ArrayList([]const u8) = .empty;
        var at = cut;
        while (std.mem.indexOfPos(u8, current, at, "\n**[")) |found| {
            at = found + 4;
            const open = std.mem.indexOfPos(u8, current, at, "](./") orelse break;
            const close = std.mem.indexOfScalarPos(u8, current, open, ')') orelse break;
            const path = try std.fmt.allocPrint(gpa, "docs/reference/{s}", .{current[open + 4 .. close]});
            if (pageAt(pages, path) != null) try order.append(gpa, path);
        }
        for (pages) |page| {
            if (!std.mem.startsWith(u8, page.path, "docs/reference/") or std.mem.eql(u8, page.path, index)) continue;
            for (order.items) |listed| {
                if (std.mem.eql(u8, listed, page.path)) break;
            } else try order.append(gpa, page.path);
        }

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(gpa, current[0..cut]);
        try out.print(gpa, "{s}\n\n{s}\n", .{ index_heading, index_note });
        for (order.items) |path| {
            const text = pageAt(pages, path).?.text;
            var lines = std.mem.splitScalar(u8, text, '\n');
            const title = std.mem.trimStart(u8, lines.next() orelse "", "# ");
            _ = lines.next();
            const claim = std.mem.trim(u8, lines.next() orelse "", "* ");
            const name = path["docs/reference/".len..];
            try out.print(gpa, "\n**[{s}](./{s})**: {s}\n\n", .{ title, name, claim });
            for (try headings(gpa, text)) |h| {
                if (h.depth < 2 or h.depth > 4) continue;
                for (0..h.depth - 2) |_| try out.appendSlice(gpa, "  ");
                try out.print(gpa, "- [{s}](./{s}#{s})\n", .{ h.text, name, h.anchor });
            }
        }
        return out.items;
    }

    const Served = struct { direction: []const u8, line: []const u8 };

    /// The roadmap with each direction's list of the todo entries that serve
    /// it written again from the todo list. A direction is a `###` heading of
    /// the roadmap, and its list sits between `gathered_open` and
    /// `gathered_close`; an entry is the last bold claim of the todo list
    /// above a `**Direction:**` line, listed with its tier (the `##` heading
    /// it is under, up to a colon) and its module (the `###` one).
    fn gathered(r: *Report, todo_text: []const u8, plan: []const u8, refused: *usize) ![]u8 {
        const gpa = r.gpa;
        var directions: std.StringHashMapUnmanaged(void) = .empty;
        for (try headings(gpa, plan)) |h| if (h.depth == 3) try directions.put(gpa, h.anchor, {});

        var served: std.ArrayList(Served) = .empty;
        var tier: []const u8 = "";
        var tier_anchor: []const u8 = "";
        var module: []const u8 = "";
        var claim: []const u8 = "";
        var fenced = false;
        var number: usize = 0;
        var lines = std.mem.splitScalar(u8, todo_text, '\n');
        while (lines.next()) |line| {
            number += 1;
            if (fence(line)) fenced = !fenced;
            if (fenced) continue;
            if (std.mem.startsWith(u8, line, "## ")) {
                const words = std.mem.trim(u8, line[3..], " ");
                tier = words[0 .. std.mem.indexOfScalar(u8, words, ':') orelse words.len];
                tier_anchor = try slug(gpa, words);
                module = "";
                claim = "";
            } else if (std.mem.startsWith(u8, line, "### ")) {
                module = std.mem.trim(u8, line[4..], " ");
            } else if (std.mem.startsWith(u8, line, direction_line)) {
                var at: usize = 0;
                var named: usize = 0;
                while (std.mem.indexOfPos(u8, line, at, "](./roadmap.md#")) |open| {
                    at = open + "](./roadmap.md#".len;
                    const close = std.mem.indexOfScalarPos(u8, line, at, ')') orelse break;
                    const anchor = line[at..close];
                    named += 1;
                    if (!directions.contains(anchor)) {
                        refused.* += 1;
                        try r.addError("nilo: {s}:{d} names #{s} as its direction, and no `###` heading of {s} has that anchor.", .{ todo, number, anchor, roadmap });
                    } else if (claim.len == 0) {
                        refused.* += 1;
                        try r.addError("nilo: {s}:{d} names a direction with no bold claim above it in its tier.", .{ todo, number });
                    } else {
                        try served.append(gpa, .{
                            .direction = anchor,
                            .line = try std.fmt.allocPrint(gpa, "- [{s}](./todo.md#{s}) · {s} · {s}", .{ tier, tier_anchor, module, claim }),
                        });
                    }
                }
                if (named == 0) {
                    refused.* += 1;
                    try r.addError("nilo: {s}:{d} is a Direction line that links no heading of {s}.", .{ todo, number, roadmap });
                }
            } else if (std.mem.startsWith(u8, line, "**") and !std.mem.startsWith(u8, line, "**Needs:**") and !std.mem.startsWith(u8, line, "**What would settle it:**")) {
                if (std.mem.indexOfPos(u8, line, 2, "**")) |end| claim = line[2..end];
            }
        }

        var out: std.ArrayList(u8) = .empty;
        var listed: std.StringHashMapUnmanaged(void) = .empty;
        var direction: []const u8 = "";
        var skipping = false;
        var rest = std.mem.splitScalar(u8, plan, '\n');
        var first = true;
        while (rest.next()) |line| {
            if (skipping) {
                if (!std.mem.eql(u8, line, gathered_close)) continue;
                skipping = false;
            }
            if (!first) try out.append(gpa, '\n');
            first = false;
            try out.appendSlice(gpa, line);
            if (std.mem.startsWith(u8, line, "## ")) direction = "";
            if (std.mem.startsWith(u8, line, "### ")) direction = try slug(gpa, line[4..]);
            if (!std.mem.eql(u8, line, gathered_open)) continue;
            if (direction.len == 0) {
                refused.* += 1;
                try r.addError("nilo: {s} has a list of todo entries outside any direction.", .{roadmap});
                continue;
            }
            try listed.put(gpa, direction, {});
            try out.appendSlice(gpa, "\n\n");
            var any = false;
            for (served.items) |item| {
                if (!std.mem.eql(u8, item.direction, direction)) continue;
                try out.print(gpa, "{s}\n", .{item.line});
                any = true;
            }
            if (!any) try out.appendSlice(gpa, "No entry in the todo list names this direction yet.\n");
            skipping = true;
        }
        if (skipping) {
            refused.* += 1;
            try r.addError("nilo: {s} opens a list of todo entries and never closes it with `{s}`.", .{ roadmap, gathered_close });
        }
        var it = directions.keyIterator();
        while (it.next()) |anchor| {
            if (listed.contains(anchor.*)) continue;
            refused.* += 1;
            try r.addError("nilo: {s}'s direction #{s} has no list of the todo entries that serve it; put `{s}` and `{s}` under it, and `zig build docs-index` fills them.", .{ roadmap, anchor.*, gathered_open, gathered_close });
        }
        return out.items;
    }

    /// The todo list was last ranked at the version `build.zig.zon` names,
    /// which a release bumps: ranking it again is part of cutting one.
    fn ranked(r: *Report, todo_text: []const u8, zon: []const u8) !usize {
        const gpa = r.gpa;
        const key = ".version = \"";
        const from = (std.mem.indexOf(u8, zon, key) orelse return 0) + key.len;
        const to = std.mem.indexOfScalarPos(u8, zon, from, '"') orelse return 0;
        const line = try std.fmt.allocPrint(gpa, "**Ranked at {s}.**", .{zon[from..to]});
        if (std.mem.indexOf(u8, todo_text, line) != null) return 0;
        try r.addError("nilo: {s} does not say `{s}`: build.zig.zon names a version the list was not ranked at. Rank it again (its rule 9) and say so on that line.", .{ todo, line });
        return 1;
    }
};
