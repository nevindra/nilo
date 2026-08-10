//! Static files, held in memory (ADR 0010).
//!
//! ```zig
//! try app.static("/", "public");
//! try app.staticWith("/assets", "dist", .{ .cache_control = "public, max-age=31536000, immutable" });
//! ```
//!
//! A directory is read once, at startup, into memory owned by the App.
//! Nothing touches the disk while requests are being served, which is the
//! whole reason it is done this way: a blocking read inside a fiber stalls
//! every other connection sharing that OS thread, and the p99 the project
//! measures itself on would go with it.
//!
//! Two things fall out of that for free. Path traversal is not possible —
//! the set of files is fixed before the socket opens, so `../../etc/passwd`
//! is not a path that gets resolved, it is a name that is not in the list.
//! And every file gets an ETag computed once at load, so a repeat visitor
//! gets a 304 with no body and no work.
//!
//! What it cannot do is serve a file that does not fit in RAM. Range
//! requests, `sendfile`, and reading from disk per request are v2.

const std = @import("std");

pub const Options = struct {
    /// Served for a path ending in `/`. Empty turns that off.
    index: []const u8 = "index.html",
    /// Sent as `Cache-Control` on every file. Empty leaves the header off.
    cache_control: []const u8 = "public, max-age=3600",
    /// Served for any path under the prefix that names no file — what a
    /// single-page app needs so that a browser reload on `/users/42`
    /// reaches the client-side router instead of a 404. Empty turns it off.
    ///
    /// The name is relative to the directory, e.g. `"index.html"`.
    spa_fallback: []const u8 = "",
    /// Files bigger than this are refused at load, with their name in the
    /// error. The whole tree is going into RAM, so the ceiling is a real
    /// one and it is better hit at startup than at 3am.
    max_file_bytes: usize = 8 * 1024 * 1024,
    max_total_bytes: usize = 64 * 1024 * 1024,
    /// Whether to load names starting with `.`. Off by default: a `.env`
    /// or a `.git` that found its way into the directory being published
    /// on the first request is a bad way to learn it was there.
    dotfiles: bool = false,
};

pub const File = struct {
    /// The URL this answers to, prefix included: `/assets/app.css`.
    url: []const u8,
    bytes: []const u8,
    content_type: []const u8,
    /// A strong ETag, quotes included, computed from the contents at load.
    etag: []const u8,
    /// Borrowed from the Set's options.
    cache_control: []const u8,
};

/// One directory, loaded. Owns every byte in it.
pub const Set = struct {
    gpa: std.mem.Allocator,
    prefix: []const u8,
    /// Sorted by url, so a lookup is a binary search rather than a walk.
    files: []File,
    fallback: ?*const File,
    index: []const u8,

    pub fn deinit(self: *Set) void {
        for (self.files) |f| {
            self.gpa.free(f.url);
            self.gpa.free(f.bytes);
            self.gpa.free(f.etag);
        }
        self.gpa.free(self.files);
        self.gpa.free(self.prefix);
        self.files = &.{};
        self.fallback = null;
    }

    /// The file `path` names, or null if this set does not answer for it.
    pub fn find(self: *const Set, path: []const u8) ?*const File {
        if (!underPrefix(self.prefix, path)) return null;

        if (self.lookup(path)) |f| return f;

        // "/docs/" means "/docs/index.html". A path with no trailing slash
        // is left alone: redirecting it is the correct answer and that is a
        // v2 job, so for now it simply is not a file.
        if (self.index.len > 0 and std.mem.endsWith(u8, path, "/")) {
            var buf: [max_url]u8 = undefined;
            if (join(&buf, path, self.index)) |with_index| {
                if (self.lookup(with_index)) |f| return f;
            }
        }

        return self.fallback;
    }

    fn lookup(self: *const Set, url: []const u8) ?*const File {
        var lo: usize = 0;
        var hi: usize = self.files.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.files[mid].url, url)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return &self.files[mid],
            }
        }
        return null;
    }
};

/// The longest URL a file can have. Generous for a build output tree, and
/// bounded so a lookup never allocates.
pub const max_url = 512;

pub const LoadError = error{
    StaticDirNotFound,
    StaticFileTooLarge,
    StaticSetTooLarge,
    StaticUrlTooLong,
    OutOfMemory,
    StaticReadFailed,
};

/// One file for `fromMemory` — bytes that are already here rather than on
/// a disk. `url` and `bytes` are copied; `content_type` and `cache_control`
/// are borrowed and have to outlive the Set, exactly as a loaded Set
/// borrows them from its Options.
pub const Entry = struct {
    url: []const u8,
    bytes: []const u8,
    content_type: []const u8,
    cache_control: []const u8 = "no-cache",
};

/// A Set built from bytes already in memory instead of from a directory.
///
/// What this is for is the generated API description (ADR 0017), which is a
/// file in every way that matters: fixed once the routes are known, worth an
/// ETag, and a repeat visit should be a 304. Going through the same Set that
/// serves `public/` means all of that arrives without a second code path,
/// and without a new field on `Ctx`.
///
/// The prefix is `/`, so the Set is asked about every path that reached the
/// static layer and answers only for the URLs it was given.
pub fn fromMemory(gpa: std.mem.Allocator, entries: []const Entry) !Set {
    var set = Set{
        .gpa = gpa,
        .prefix = try gpa.dupe(u8, "/"),
        .files = &.{},
        .fallback = null,
        .index = "",
    };
    errdefer set.deinit();

    set.files = try gpa.alloc(File, entries.len);
    // Emptied before anything can fail, so that `deinit` on the way out of a
    // half-built Set frees what exists and steps over what does not — an
    // empty slice is nothing to free.
    for (set.files) |*file| file.* = .{
        .url = &.{},
        .bytes = &.{},
        .etag = &.{},
        .content_type = "",
        .cache_control = "",
    };

    for (entries, set.files) |entry, *file| {
        file.url = try gpa.dupe(u8, entry.url);
        file.bytes = try gpa.dupe(u8, entry.bytes);
        file.etag = try etagFor(gpa, entry.bytes);
        file.content_type = entry.content_type;
        file.cache_control = entry.cache_control;
    }

    std.mem.sort(File, set.files, {}, lessByUrl);
    return set;
}

/// Read `dir_path` into memory, mapping every file in it to a URL under
/// `url_prefix`. Called before `listen()`, so the blocking reads here
/// happen while nothing is being served.
pub fn load(
    gpa: std.mem.Allocator,
    url_prefix: []const u8,
    dir_path: []const u8,
    options: Options,
) LoadError!Set {
    std.debug.assert(url_prefix.len > 0 and url_prefix[0] == '/');

    // A throwaway blocking I/O instance, unrelated to the Engine that will
    // serve requests. Nothing from here survives into the request path,
    // which is exactly why static files need nothing from the Bulkhead.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.err(
            "zfast: static directory \"{s}\" could not be opened ({s}) — " ++
                "the path is relative to the working directory the server runs in",
            .{ dir_path, @errorName(err) },
        );
        return error.StaticDirNotFound;
    };
    defer dir.close(io);

    var files: std.ArrayList(File) = .empty;
    errdefer {
        for (files.items) |f| {
            gpa.free(f.url);
            gpa.free(f.bytes);
            gpa.free(f.etag);
        }
        files.deinit(gpa);
    }

    var total: usize = 0;
    var skipped_dotfiles: usize = 0;

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (walker.next(io) catch return error.StaticReadFailed) |entry| {
        if (entry.kind != .file) continue;
        if (!options.dotfiles and hasDotSegment(entry.path)) {
            skipped_dotfiles += 1;
            continue;
        }

        var url_buf: [max_url]u8 = undefined;
        const url = join(&url_buf, url_prefix, entry.path) orelse {
            std.log.err("zfast: static file \"{s}\" has a path longer than {d} bytes", .{ entry.path, max_url });
            return error.StaticUrlTooLong;
        };
        toForwardSlashes(url);

        const bytes = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited64(options.max_file_bytes)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            if (err == error.StreamTooLong) {
                std.log.err(
                    "zfast: static file \"{s}\" is over the {d} byte limit — " ++
                        "everything is held in memory, so raise .max_file_bytes only if you mean it",
                    .{ entry.path, options.max_file_bytes },
                );
                return error.StaticFileTooLarge;
            }
            std.log.err("zfast: static file \"{s}\" could not be read ({s})", .{ entry.path, @errorName(err) });
            return error.StaticReadFailed;
        };
        errdefer gpa.free(bytes);

        total += bytes.len;
        if (total > options.max_total_bytes) {
            std.log.err(
                "zfast: static directory \"{s}\" is over the {d} byte total limit",
                .{ dir_path, options.max_total_bytes },
            );
            return error.StaticSetTooLarge;
        }

        try files.append(gpa, .{
            .url = try gpa.dupe(u8, url),
            .bytes = bytes,
            .content_type = contentTypeFor(url),
            .etag = try etagFor(gpa, bytes),
            .cache_control = options.cache_control,
        });
    }

    const owned = try files.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    std.mem.sort(File, owned, {}, lessByUrl);

    var set = Set{
        .gpa = gpa,
        .prefix = try gpa.dupe(u8, url_prefix),
        .files = owned,
        .fallback = null,
        .index = options.index,
    };

    if (options.spa_fallback.len > 0) {
        var buf: [max_url]u8 = undefined;
        const url = join(&buf, url_prefix, options.spa_fallback) orelse return error.StaticUrlTooLong;
        set.fallback = set.lookup(url) orelse {
            std.log.err(
                "zfast: the SPA fallback \"{s}\" is not in \"{s}\" — " ++
                    "the name is relative to the directory, e.g. \"index.html\"",
                .{ options.spa_fallback, dir_path },
            );
            set.deinit();
            return error.StaticDirNotFound;
        };
    }

    std.log.info(
        "zfast: loaded {d} static file(s) ({d} bytes) from \"{s}\" onto \"{s}\"{s}",
        .{ set.files.len, total, dir_path, url_prefix, if (skipped_dotfiles > 0) " (dotfiles skipped)" else "" },
    );
    return set;
}

fn lessByUrl(_: void, a: File, b: File) bool {
    return std.mem.order(u8, a.url, b.url) == .lt;
}

/// Whether `path` sits under `prefix`, on a segment boundary — so a
/// prefix of `/app` covers `/app/x` but not `/apple`.
fn underPrefix(prefix: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, prefix, "/")) return true;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// `join("/assets", "css/app.css")` → `/assets/css/app.css`, with exactly
/// one slash between the two however they were written. Null if it does
/// not fit.
fn join(buf: []u8, prefix: []const u8, rest: []const u8) ?[]u8 {
    const left = std.mem.trimEnd(u8, prefix, "/");
    const right = std.mem.trimStart(u8, rest, "/");
    const total = left.len + 1 + right.len;
    if (total > buf.len) return null;
    @memcpy(buf[0..left.len], left);
    buf[left.len] = '/';
    @memcpy(buf[left.len + 1 ..][0..right.len], right);
    return buf[0..total];
}

fn toForwardSlashes(url: []u8) void {
    if (std.fs.path.sep == '/') return;
    std.mem.replaceScalar(u8, url, std.fs.path.sep, '/');
}

/// Whether any segment of a relative path starts with a dot.
fn hasDotSegment(rel_path: []const u8) bool {
    var start: usize = 0;
    for (rel_path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') {
            if (i > start and rel_path[start] == '.') return true;
            start = i + 1;
        }
    }
    return rel_path.len > start and rel_path[start] == '.';
}

/// A strong ETag: the contents hashed, so it changes exactly when the file
/// does. Computed once at load, which is what makes 304s free.
fn etagFor(gpa: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hash = std.hash.Wyhash.hash(0, bytes);
    return std.fmt.allocPrint(gpa, "\"{x}-{x}\"", .{ bytes.len, hash });
}

/// Whether an `If-None-Match` header matches `etag`. Handles the `*`
/// wildcard, a comma-separated list, and the `W/` weak marker — all three
/// turn up in the wild and none of them is worth a 200 with a full body.
pub fn etagMatches(if_none_match: []const u8, etag: []const u8) bool {
    var candidates = std.mem.splitScalar(u8, if_none_match, ',');
    while (candidates.next()) |raw| {
        var candidate = std.mem.trim(u8, raw, " \t");
        if (std.mem.eql(u8, candidate, "*")) return true;
        if (std.mem.startsWith(u8, candidate, "W/")) candidate = candidate[2..];
        if (std.mem.eql(u8, candidate, etag)) return true;
    }
    return false;
}

/// The Content-Type for a file name. An extension nobody listed becomes
/// `application/octet-stream`, which makes a browser download it rather
/// than guess — the safe way to be wrong.
pub fn contentTypeFor(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "application/octet-stream";
    const ext = name[dot + 1 ..];

    const table = .{
        .{ "html", "text/html; charset=utf-8" },
        .{ "htm", "text/html; charset=utf-8" },
        .{ "css", "text/css; charset=utf-8" },
        .{ "js", "text/javascript; charset=utf-8" },
        .{ "mjs", "text/javascript; charset=utf-8" },
        .{ "json", "application/json" },
        .{ "map", "application/json" },
        .{ "txt", "text/plain; charset=utf-8" },
        .{ "md", "text/markdown; charset=utf-8" },
        .{ "xml", "application/xml" },
        .{ "svg", "image/svg+xml" },
        .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },
        .{ "jpeg", "image/jpeg" },
        .{ "gif", "image/gif" },
        .{ "webp", "image/webp" },
        .{ "avif", "image/avif" },
        .{ "ico", "image/x-icon" },
        .{ "woff2", "font/woff2" },
        .{ "woff", "font/woff" },
        .{ "ttf", "font/ttf" },
        .{ "otf", "font/otf" },
        .{ "wasm", "application/wasm" },
        .{ "pdf", "application/pdf" },
        .{ "mp4", "video/mp4" },
        .{ "webm", "video/webm" },
        .{ "mp3", "audio/mpeg" },
        .{ "zip", "application/zip" },
    };

    inline for (table) |row| {
        if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    }
    return "application/octet-stream";
}

const testing = std.testing;

test "content types, and an unknown extension downloads rather than guesses" {
    try testing.expectEqualStrings("text/html; charset=utf-8", contentTypeFor("/index.html"));
    try testing.expectEqualStrings("text/css; charset=utf-8", contentTypeFor("/a/b/app.css"));
    try testing.expectEqualStrings("image/svg+xml", contentTypeFor("/logo.SVG"));
    try testing.expectEqualStrings("application/octet-stream", contentTypeFor("/data.sqlite"));
    try testing.expectEqualStrings("application/octet-stream", contentTypeFor("/LICENSE"));
}

test "If-None-Match: wildcards, lists and weak tags all count as a match" {
    try testing.expect(etagMatches("\"abc\"", "\"abc\""));
    try testing.expect(etagMatches("*", "\"abc\""));
    try testing.expect(etagMatches("W/\"abc\"", "\"abc\""));
    try testing.expect(etagMatches("\"other\", \"abc\"", "\"abc\""));
    try testing.expect(!etagMatches("\"other\"", "\"abc\""));
    try testing.expect(!etagMatches("", "\"abc\""));
}

test "a prefix only covers whole segments" {
    try testing.expect(underPrefix("/", "/anything"));
    try testing.expect(underPrefix("/app", "/app"));
    try testing.expect(underPrefix("/app", "/app/main.js"));
    try testing.expect(!underPrefix("/app", "/apple.js"));
    try testing.expect(!underPrefix("/app", "/other"));
}

test "joining a prefix and a relative path never doubles the slash" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/assets/app.css", join(&buf, "/assets", "app.css").?);
    try testing.expectEqualStrings("/assets/app.css", join(&buf, "/assets/", "/app.css").?);
    try testing.expectEqualStrings("/index.html", join(&buf, "/", "index.html").?);
    try testing.expectEqualStrings("/a/b/c.js", join(&buf, "/a", "b/c.js").?);

    var tiny: [4]u8 = undefined;
    try testing.expect(join(&tiny, "/assets", "app.css") == null);
}

test "a dot anywhere in the path counts, not just at the start" {
    try testing.expect(hasDotSegment(".env"));
    try testing.expect(hasDotSegment(".git/config"));
    try testing.expect(hasDotSegment("build/.secret"));
    try testing.expect(hasDotSegment("a/.b/c"));
    try testing.expect(!hasDotSegment("index.html"));
    try testing.expect(!hasDotSegment("a/b/style.css"));
}

test "the ETag changes with the contents and with the length" {
    const a = try etagFor(testing.allocator, "hello");
    defer testing.allocator.free(a);
    const b = try etagFor(testing.allocator, "hellp");
    defer testing.allocator.free(b);
    const c = try etagFor(testing.allocator, "hello");
    defer testing.allocator.free(c);

    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expectEqualStrings(a, c);
    try testing.expect(a[0] == '"' and a[a.len - 1] == '"');
}

/// Build a Set by hand, so lookup can be tested without touching a disk.
fn fakeSet(gpa: std.mem.Allocator, prefix: []const u8, urls: []const []const u8) !Set {
    const files = try gpa.alloc(File, urls.len);
    for (files, urls) |*f, url| {
        f.* = .{
            .url = try gpa.dupe(u8, url),
            .bytes = try gpa.dupe(u8, "x"),
            .content_type = contentTypeFor(url),
            .etag = try etagFor(gpa, "x"),
            .cache_control = "",
        };
    }
    std.mem.sort(File, files, {}, lessByUrl);
    return .{
        .gpa = gpa,
        .prefix = try gpa.dupe(u8, prefix),
        .files = files,
        .fallback = null,
        .index = "index.html",
    };
}

test "lookup finds files, index.html and nothing else" {
    var set = try fakeSet(testing.allocator, "/", &.{ "/index.html", "/app.css", "/docs/index.html" });
    defer set.deinit();

    try testing.expectEqualStrings("/app.css", set.find("/app.css").?.url);
    try testing.expectEqualStrings("/index.html", set.find("/").?.url);
    try testing.expectEqualStrings("/docs/index.html", set.find("/docs/").?.url);
    try testing.expect(set.find("/docs") == null); // no trailing slash, no index
    try testing.expect(set.find("/missing.js") == null);
    // Not a resolved path but a name that is not in the list, which is why
    // there is nothing to traverse to.
    try testing.expect(set.find("/../secret") == null);
}

test "a prefixed set answers only under its prefix" {
    var set = try fakeSet(testing.allocator, "/assets", &.{ "/assets/app.css", "/assets/logo.png" });
    defer set.deinit();

    try testing.expectEqualStrings("/assets/app.css", set.find("/assets/app.css").?.url);
    try testing.expect(set.find("/app.css") == null);
    try testing.expect(set.find("/assetsx/app.css") == null);
}

test "the SPA fallback catches unknown paths but not unknown prefixes" {
    var set = try fakeSet(testing.allocator, "/", &.{ "/index.html", "/app.js" });
    defer set.deinit();
    set.fallback = set.lookup("/index.html").?;

    try testing.expectEqualStrings("/app.js", set.find("/app.js").?.url);
    // A browser reload deep inside a client-side route.
    try testing.expectEqualStrings("/index.html", set.find("/users/42").?.url);
}
