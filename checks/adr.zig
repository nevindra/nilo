//! `zig build adr-check`: the ADRs' shape and every citation of one
//! (ADR 221), as a program the build runs (`checks/main.zig` says why).

const std = @import("std");
const Report = @import("main.zig").Report;

/// The step that holds `docs/adr/` to its shape and every citation of an ADR
/// to a file that exists (ADR 221).
///
/// The ADRs were renumbered once, from four digits to three, when every amend
/// chain became one ADR. So a four-digit number is an old one by construction,
/// and refusing it everywhere but `renumbered.md` is what keeps the two
/// numberings from ever meaning the same thing twice. A three-digit number with
/// no file behind it is the other way a citation rots: an ADR merged or deleted
/// and a comment left pointing at it.
///
/// A scan rather than a parse, like `Layering`, and the shapes it reads are the
/// ones this repository writes: `ADR 123`, `ADRs 052, 061 and 123` across a
/// line break inside a comment, and a link to `adr/NNN-slug.md` or
/// `](NNN-slug.md)` from beside it.
pub const AdrCheck = struct {
    const adr_dir = "docs/adr";
    const design_dir = "docs/design";
    /// The one file that may name the old numbers: the table from old to new,
    /// kept so that a commit message written before the renumbering can be read.
    const old_numbers = "renumbered.md";
    /// Not walked. A dot directory holds caches and git's own files, and the
    /// other three are what a build writes or fetches.
    const skipped = [_][]const u8{ "zig-out", "zig-pkg", "node_modules" };

    pub fn run(r: *Report) anyerror!void {
        const io = r.io;
        var refused: usize = 0;
        var have: std.bit_set.Static(1000) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;

        // The directory itself: one file a number, each with a title and the
        // two lines that say whether it is in force and where it belongs.
        {
            var dir = r.root.openDir(io, adr_dir, .{ .iterate = true }) catch |err|
                return r.fail("nilo: cannot read `{s}/`: {s}", .{ adr_dir, @errorName(err) });
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
                if (std.mem.eql(u8, entry.name, old_numbers)) continue;
                const n = numberOf(entry.name) orelse {
                    refused += 1;
                    try r.addError("nilo: {s}/{s} is not named `NNN-slug.md`, three digits and a slug.", .{ adr_dir, entry.name });
                    continue;
                };
                if (have.isSet(n)) {
                    refused += 1;
                    try r.addError("nilo: two ADRs are numbered {d:0>3}; {s}/{s} is the second.", .{ n, adr_dir, entry.name });
                }
                have.set(n);
                try names.put(r.gpa, try r.gpa.dupe(u8, entry.name), {});

                const source = try dir.readFileAlloc(io, entry.name, r.gpa, .limited(1 << 20));
                const head = source[0..@min(source.len, 1200)];
                if (!std.mem.startsWith(u8, source, "# ") or source.len < 3 or std.ascii.isDigit(source[2])) {
                    refused += 1;
                    try r.addError("nilo: {s}/{s} does not open with a title, `# ` and a sentence with no number in it.", .{ adr_dir, entry.name });
                }
                if (std.mem.indexOf(u8, head, "\n**Status:** ") == null) {
                    refused += 1;
                    try r.addError("nilo: {s}/{s} has no `**Status:**` line under its title.", .{ adr_dir, entry.name });
                }
                refused += try topic(r, dir, entry.name, head);
                refused += try relations(r, entry.name, source);
            }
        }

        refused += try pages(r);

        // Every citation, everywhere the repository keeps text.
        var root = try r.root.openDir(io, ".", .{ .iterate = true });
        defer root.close(io);
        var walker = try root.walkSelectively(r.gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (entry.basename[0] != '.' and !listed(entry.basename)) try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            if (!textual(entry.basename)) continue;
            if (std.mem.eql(u8, entry.path, adr_dir ++ "/" ++ old_numbers)) continue;

            const source = entry.dir.readFileAlloc(io, entry.basename, r.gpa, .limited(8 << 20)) catch continue;
            refused += try citations(r, entry.path, source, &have);
            refused += try links(r, entry.path, source, &names);
        }

        if (refused > 0) return error.CheckFailed;
    }

    /// The words an ADR's head may use to name another. None of them says
    /// this ADR revises one: a revision edits the ADR it revises, in place,
    /// and a head line saying `Amends`, `Supersedes` or `Refines` is the sign
    /// that a revision was written as a new file instead (ADR 221).
    const relation_words = [_][]const u8{ "Status", "Topic", "Applies", "Extends", "Carries out", "Closes", "Found by" };

    fn relations(r: *Report, name: []const u8, source: []const u8) !usize {
        const end = std.mem.indexOf(u8, source, "\n## ") orelse source.len;
        var refused: usize = 0;
        var lines = std.mem.splitScalar(u8, source[0..end], '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "**")) continue;
            const close = std.mem.indexOf(u8, line, ":**") orelse continue;
            const word = line[2..close];
            for (relation_words) |allowed| {
                if (std.mem.eql(u8, word, allowed)) break;
            } else {
                refused += 1;
                try r.addError("nilo: {s}/{s} says `**{s}:**` in its head. A revision edits the ADR it revises, in place; a new ADR is for a new decision, and names older ones with one of: Applies, Extends, Carries out, Closes, Found by.", .{ adr_dir, name, word });
            }
        }
        return refused;
    }

    /// `**Topic:** slug`, or `**Topic:** [slug](../design/slug.md)` once the
    /// topic has a page. The link is required as soon as the page exists, so
    /// writing a topic page and pointing its ADRs at it are one change.
    fn topic(r: *Report, dir: std.Io.Dir, name: []const u8, head: []const u8) !usize {
        const io = r.io;
        const at = std.mem.indexOf(u8, head, "\n**Topic:** ") orelse {
            try r.addError("nilo: {s}/{s} has no `**Topic:**` line under its title.", .{ adr_dir, name });
            return 1;
        };
        const rest = head[at + "\n**Topic:** ".len ..];
        const linked = std.mem.startsWith(u8, rest, "[");
        const word = rest[@intFromBool(linked)..];
        var end: usize = 0;
        while (end < word.len and (std.ascii.isLower(word[end]) or std.ascii.isDigit(word[end]) or word[end] == '-')) end += 1;
        const slug = word[0..end];
        if (slug.len == 0 or (end < word.len and !linked and word[end] != '\n' and word[end] != '.')) {
            try r.addError("nilo: {s}/{s} names its topic as something other than a lowercase slug.", .{ adr_dir, name });
            return 1;
        }
        const page = try std.fmt.allocPrint(r.gpa, "../design/{s}.md", .{slug});
        const exists = if (dir.access(io, page, .{})) true else |_| false;
        if (linked) {
            const want = try std.fmt.allocPrint(r.gpa, "{s}]({s})", .{ slug, page });
            if (!std.mem.startsWith(u8, word, want) or !exists) {
                try r.addError("nilo: {s}/{s} links its topic to a page other than `docs/design/{s}.md`, or to one that does not exist.", .{ adr_dir, name, slug });
                return 1;
            }
            // The page lists every ADR that names it, so a new ADR in a topic
            // with a page is one change with the page's Decisions table.
            const text = try dir.readFileAlloc(io, page, r.gpa, .limited(1 << 20));
            if (std.mem.indexOf(u8, text, name) == null) {
                try r.addError("nilo: docs/design/{s}.md does not link {s}/{s}, whose topic it is.", .{ slug, adr_dir, name });
                return 1;
            }
        } else if (exists) {
            try r.addError("nilo: {s}/{s} names topic `{s}`, which has a page; write it `[{s}](../design/{s}.md)`.", .{ adr_dir, name, slug, slug, slug });
            return 1;
        }
        return 0;
    }

    /// A topic page's relative links resolve. Nothing else reads these pages
    /// (`mkdocs` builds `docs/guide/` only), so a renamed guide page or reference
    /// file would otherwise leave them pointing at nothing.
    fn pages(r: *Report) !usize {
        const io = r.io;
        var dir = r.root.openDir(io, design_dir, .{ .iterate = true }) catch return 0;
        defer dir.close(io);
        var refused: usize = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
            const text = try dir.readFileAlloc(io, entry.name, r.gpa, .limited(1 << 20));
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, text, at, "](")) |open| {
                at = open + 2;
                const close = std.mem.indexOfScalarPos(u8, text, at, ')') orelse break;
                var target = text[at..close];
                if (std.mem.indexOf(u8, target, "://") != null or target.len == 0 or target[0] == '#') continue;
                if (std.mem.indexOfScalar(u8, target, '#')) |hash| target = target[0..hash];
                if (dir.access(io, target, .{})) |_| {} else |_| {
                    refused += 1;
                    try r.addError("nilo: {s}/{s}:{d} links to {s}, which does not exist.", .{
                        design_dir, entry.name, std.mem.count(u8, text[0..open], "\n") + 1, target,
                    });
                }
            }
        }
        return refused;
    }

    fn numberOf(name: []const u8) ?u16 {
        if (name.len < 5 or name[3] != '-') return null;
        for (name[0..3]) |c| if (!std.ascii.isDigit(c)) return null;
        if (std.ascii.isDigit(name[4])) return null;
        return std.fmt.parseInt(u16, name[0..3], 10) catch null;
    }

    pub fn listed(name: []const u8) bool {
        for (skipped) |one| if (std.mem.eql(u8, one, name)) return true;
        return false;
    }

    fn textual(name: []const u8) bool {
        inline for (.{ ".md", ".zig", ".zon", ".yml", ".yaml", ".txt", ".py", ".sh" }) |ext|
            if (std.mem.endsWith(u8, name, ext)) return true;
        return false;
    }

    /// `ADR 123`, and the numbers a list goes on to name after it. What sits
    /// between two of them may be a comma, `and` or `or`, and a line break
    /// followed by a comment's `//`, `///` or `//!`.
    fn citations(r: *Report, path: []const u8, source: []const u8, have: *const std.bit_set.Static(1000)) !usize {
        var refused: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, source, at, "ADR")) |found| {
            at = found + 3;
            if (found > 0 and std.ascii.isAlphanumeric(source[found - 1])) continue;
            var i = at;
            if (i < source.len and source[i] == 's') i += 1;
            var first = true;
            while (true) {
                const start = i;
                i = skipGap(source, i, first);
                if (!first) {
                    // A list goes on only through a separator.
                    const sep = source[start..i];
                    if (std.mem.indexOfScalar(u8, sep, ',') == null and
                        std.mem.indexOf(u8, sep, "and") == null and
                        std.mem.indexOf(u8, sep, "or") == null) break;
                }
                var j = i;
                while (j < source.len and std.ascii.isDigit(source[j])) j += 1;
                const digits = source[i..j];
                if (digits.len == 0 or (j < source.len and std.ascii.isAlphabetic(source[j]))) break;
                const line = std.mem.count(u8, source[0..i], "\n") + 1;
                if (digits.len == 4) {
                    refused += 1;
                    try r.addError("nilo: {s}:{d} cites ADR {s}, a number from before the renumbering.\n" ++
                        "  `docs/adr/renumbered.md` says what it is now.", .{ path, line, digits });
                } else if (digits.len == 3) {
                    const n = std.fmt.parseInt(u16, digits, 10) catch unreachable;
                    if (!have.isSet(n)) {
                        refused += 1;
                        try r.addError("nilo: {s}:{d} cites ADR {s}, and there is no ADR {s}.", .{ path, line, digits, digits });
                    }
                } else break;
                i = j;
                first = false;
            }
            at = i;
        }
        return refused;
    }

    /// Spaces, and for anything after the first number the separator too:
    /// a comma, `and`, `or`, and a line break into a comment or a quote.
    fn skipGap(source: []const u8, from: usize, first: bool) usize {
        var i = from;
        while (i < source.len) {
            const c = source[i];
            if (c == ' ' or c == '\t' or c == '/' or c == '!' or c == '>' or c == '*') {
                i += 1;
            } else if (c == '\n') {
                i += 1;
            } else if (!first and c == ',') {
                i += 1;
            } else if (!first and std.mem.startsWith(u8, source[i..], "and ")) {
                i += 4;
            } else if (!first and std.mem.startsWith(u8, source[i..], "or ")) {
                i += 3;
            } else break;
        }
        return i;
    }

    /// A link to an ADR file, from anywhere: `adr/NNN-slug.md`, or
    /// `](NNN-slug.md)` and `](./NNN-slug.md)` from beside it.
    fn links(r: *Report, path: []const u8, source: []const u8, names: *const std.StringHashMapUnmanaged(void)) !usize {
        var refused: usize = 0;
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, source, at, '-')) |dash| {
            at = dash + 1;
            var start = dash;
            while (start > 0 and std.ascii.isDigit(source[start - 1])) start -= 1;
            const digits = dash - start;
            if (digits != 3 and digits != 4) continue;
            const before = source[0..start];
            const in_adr = std.mem.endsWith(u8, before, "adr/") or
                (std.mem.startsWith(u8, path, adr_dir) and
                    (std.mem.endsWith(u8, before, "](") or std.mem.endsWith(u8, before, "](./")));
            if (!in_adr) continue;
            const end = std.mem.indexOfPos(u8, source, dash, ".md") orelse continue;
            const name = source[start .. end + 3];
            if (std.mem.indexOfAny(u8, name, " \n)(]") != null) continue;
            if (names.contains(name)) continue;
            refused += 1;
            try r.addError("nilo: {s}:{d} links to {s}, and `{s}/` has no such file.", .{
                path, std.mem.count(u8, source[0..start], "\n") + 1, name, adr_dir,
            });
        }
        return refused;
    }
};
