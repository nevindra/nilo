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
//! Range requests come along nearly free once the bytes are in memory — a
//! range is a slice and two headers (ADR 0021). What this cannot do is
//! serve a file that does not fit in RAM: `sendfile` and reading from disk
//! per request contradict holding the tree in memory rather than extending
//! it, and are on the roadmap with that argument still to have.

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

    /// Gzip every file worth gzipping, once, while the App is being built.
    ///
    /// This is the only shape compression can take here without giving up
    /// something the project has measured and published
    /// ([ADR 0018](../docs/adr/0018-the-trade-budget-has-three-axes.md)). A
    /// compressor needs a 64 KB window: one per connection would take an
    /// idle connection from 8,767 bytes to something like ten times that,
    /// and one per request would be an allocation on the request path where
    /// the invariant is one. A file that never changes has a third option —
    /// compress it before the socket is even open, and spend nothing at all
    /// per request.
    ///
    /// What it costs instead is memory that stays: the compressed copy
    /// lives beside the original for as long as the App does. It is charged
    /// against `max_total_bytes` like everything else, and the load line
    /// says how much it came to.
    compress: bool = true,

    /// Files smaller than this are served as they are.
    ///
    /// A gzip stream carries about 20 bytes of framing, so below a few
    /// hundred bytes compression can make a file bigger — and even where it
    /// does not, it is saving less than one TCP segment on a response that
    /// was already one packet. A file that comes out no smaller is dropped
    /// whatever this says.
    compress_min_bytes: usize = 1024,
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

    /// The same file, gzipped at load. Null when it was not worth it — too
    /// small, a type that is already compressed, or it came out no smaller.
    gzip: ?[]const u8 = null,
    /// The ETag of the gzipped bytes, which is a different one.
    ///
    /// An ETag names a representation, not a file. Handing the same ETag to
    /// both would let anything caching in front of this — a CDN, a browser,
    /// a proxy — answer a client that cannot read gzip with the gzipped
    /// copy, on the grounds that the tag matched. Empty when `gzip` is null.
    gzip_etag: []const u8 = &.{},

    /// Which bytes and which ETag to answer with. Kept together so the two
    /// cannot come apart: picking one representation and then tagging it
    /// with the other's ETag is the failure this whole pairing exists to
    /// make impossible.
    pub const Representation = struct {
        bytes: []const u8,
        etag: []const u8,
        gzipped: bool,
    };

    pub fn identity(self: *const File) Representation {
        return .{ .bytes = self.bytes, .etag = self.etag, .gzipped = false };
    }

    /// The gzipped form if there is one and the client said it can read
    /// one, and the plain form otherwise.
    pub fn representation(self: *const File, wants_gzip: bool) Representation {
        if (!wants_gzip) return self.identity();
        const packed_bytes = self.gzip orelse return self.identity();
        return .{ .bytes = packed_bytes, .etag = self.gzip_etag, .gzipped = true };
    }
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
            if (f.gzip) |p| self.gpa.free(p);
            if (f.gzip_etag.len > 0) self.gpa.free(f.gzip_etag);
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
        // is left alone: redirecting it is the correct answer and nothing
        // here redirects yet, so for now it simply is not a file.
        if (self.index.len > 0 and std.mem.endsWith(u8, path, "/")) {
            var buf: [max_url]u8 = undefined;
            if (join(&buf, path, self.index)) |with_index| {
                if (self.lookup(with_index)) |f| return f;
            }
        }

        return self.fallback;
    }

    /// Where a file this Set handed back sits in `files`, for a caller
    /// keeping an array alongside it — `App` keeps the middleware chains
    /// there, resolved once at `listen()`.
    ///
    /// Exact because every `*const File` a Set returns points into `files`:
    /// `lookup` returns `&self.files[mid]`, and `fallback` is set from
    /// `lookup` rather than from anywhere else.
    pub fn indexOf(self: *const Set, file: *const File) usize {
        return (@intFromPtr(file) - @intFromPtr(self.files.ptr)) / @sizeOf(File);
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

/// Which of these failures `load` has already put into words, so `App` can
/// stop the process on them instead of letting the error reach `main` and
/// print a stack trace through zfast's own files on top of the answer
/// (ADR 0002). The same rule `bulkhead.explained` states for `listen()`.
///
/// `OutOfMemory` is not on the list: nothing explained it, and there is
/// nothing useful to say about it that the error name does not.
pub fn explained(err: anyerror) bool {
    return switch (err) {
        error.StaticDirNotFound,
        error.StaticFileTooLarge,
        error.StaticSetTooLarge,
        error.StaticUrlTooLong,
        error.StaticReadFailed,
        => true,
        else => false,
    };
}

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

    // The same rule a loaded directory follows, with the same defaults.
    // The API description is JSON and is the largest thing that comes
    // through here, so leaving it out would have meant the one file zfast
    // generates itself being the one file it does not compress.
    const defaults = Options{};

    for (entries, set.files) |entry, *file| {
        file.url = try gpa.dupe(u8, entry.url);
        file.bytes = try gpa.dupe(u8, entry.bytes);
        file.etag = try etagFor(gpa, entry.bytes);
        file.content_type = entry.content_type;
        file.cache_control = entry.cache_control;

        if (entry.bytes.len >= defaults.compress_min_bytes and compressible(entry.content_type)) {
            file.gzip = try gzipped(gpa, entry.bytes);
            if (file.gzip) |p| file.gzip_etag = try etagFor(gpa, p);
        }
    }

    sortByUrl(set.files);
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
            if (f.gzip) |p| gpa.free(p);
            if (f.gzip_etag.len > 0) gpa.free(f.gzip_etag);
        }
        files.deinit(gpa);
    }

    var total: usize = 0;
    var packed_total: usize = 0;
    var skipped_dotfiles: usize = 0;

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (walker.next(io) catch |err| {
        std.log.err(
            "zfast: static directory \"{s}\" could not be walked ({s})",
            .{ dir_path, @errorName(err) },
        );
        return error.StaticReadFailed;
    }) |entry| {
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

        const content_type = contentTypeFor(url);
        var packed_bytes: ?[]const u8 = null;
        errdefer if (packed_bytes) |p| gpa.free(p);
        if (options.compress and
            bytes.len >= options.compress_min_bytes and
            compressible(content_type))
        {
            packed_bytes = try gzipped(gpa, bytes);
            if (packed_bytes) |p| {
                packed_total += p.len;
                total += p.len;
                if (total > options.max_total_bytes) {
                    std.log.err(
                        "zfast: static directory \"{s}\" is over the {d} byte total limit " ++
                            "once the gzipped copies are counted — raise .max_total_bytes, " ++
                            "or pass .compress = false",
                        .{ dir_path, options.max_total_bytes },
                    );
                    return error.StaticSetTooLarge;
                }
            }
        }

        try files.append(gpa, .{
            .url = try gpa.dupe(u8, url),
            .bytes = bytes,
            .content_type = content_type,
            .etag = try etagFor(gpa, bytes),
            .cache_control = options.cache_control,
            .gzip = packed_bytes,
            .gzip_etag = if (packed_bytes) |p| try etagFor(gpa, p) else &.{},
        });
    }

    const owned = try files.toOwnedSlice(gpa);
    errdefer gpa.free(owned);
    sortByUrl(owned);

    var set = Set{
        .gpa = gpa,
        .prefix = try gpa.dupe(u8, url_prefix),
        .files = owned,
        .fallback = null,
        .index = options.index,
    };

    if (options.spa_fallback.len > 0) {
        var buf: [max_url]u8 = undefined;
        const url = join(&buf, url_prefix, options.spa_fallback) orelse {
            std.log.err(
                "zfast: the SPA fallback URL \"{s}\" + \"{s}\" is longer than {d} bytes",
                .{ url_prefix, options.spa_fallback, max_url },
            );
            return error.StaticUrlTooLong;
        };
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
        "zfast: loaded {d} static file(s) ({d} bytes{f}) from \"{s}\" onto \"{s}\"{s}",
        .{
            set.files.len,
            total,
            GzipNote{ .bytes = packed_total },
            dir_path,
            url_prefix,
            if (skipped_dotfiles > 0) " (dotfiles skipped)" else "",
        },
    );
    return set;
}

/// The gzip half of the load line, and nothing at all when no file was
/// worth compressing — a directory of images should not have to read a
/// clause about a feature that did not apply to it.
const GzipNote = struct {
    bytes: usize,

    pub fn format(self: GzipNote, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.bytes == 0) return;
        try w.print(", {d} of them gzipped copies", .{self.bytes});
    }
};

fn lessByUrl(_: void, a: File, b: File) bool {
    return std.mem.order(u8, a.url, b.url) == .lt;
}

/// URLs in a set are unique, so nothing can tie and a stable sort buys
/// nothing. It costs plenty: `std.mem.sort` is an in-place stable merge, and
/// one instantiation of it for `File` is 37 KB of machine code — which
/// turned out to be 88% of what switching the API description on added to a
/// binary, before anybody wrote any JSON ([ADR 0017](../docs/adr/0017-the-api-description-comes-from-the-signatures.md)).
fn sortByUrl(files: []File) void {
    std.sort.pdq(File, files, {}, lessByUrl);
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

/// Whether an `Accept-Encoding` header says gzip is welcome.
///
/// Not `indexOf("gzip")`, because `gzip;q=0` contains the word and means the
/// exact opposite — it is how a client that cannot decompress says so, and
/// answering it with a gzipped body is a broken page rather than a slow one.
/// `*` is honoured too, with an explicit `gzip` entry outranking it either
/// way, which is what RFC 9110 §12.5.3 says to do.
pub fn acceptsGzip(header: ?[]const u8) bool {
    const value = header orelse return false;

    var star: ?bool = null;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;

        const semi = std.mem.indexOfScalar(u8, entry, ';');
        const name = std.mem.trimEnd(u8, entry[0 .. semi orelse entry.len], " \t");
        const wanted = if (semi) |i| !isQualityZero(entry[i + 1 ..]) else true;

        if (std.ascii.eqlIgnoreCase(name, "gzip")) return wanted;
        if (std.mem.eql(u8, name, "*")) star = wanted;
    }
    return star orelse false;
}

/// Whether the parameters after a `;` say `q=0` — `q=0`, `q=0.0`, `q=0.000`.
/// Anything else, including a malformed one, is read as "wanted": the cost
/// of being wrong that way is a header the client asked for by listing the
/// encoding at all.
fn isQualityZero(params: []const u8) bool {
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |raw| {
        const param = std.mem.trim(u8, raw, " \t");
        if (param.len < 2) continue;
        if (param[0] != 'q' and param[0] != 'Q') continue;
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        if (std.mem.trim(u8, param[1..eq], " \t").len != 0) continue;

        const q = std.mem.trim(u8, param[eq + 1 ..], " \t");
        const value = std.fmt.parseFloat(f32, q) catch continue;
        return value == 0;
    }
    return false;
}

/// Whether gzipping a file of this type is worth the memory it will sit in
/// for the life of the process.
///
/// An allowlist rather than a blocklist. Getting it wrong in the permissive
/// direction means spending a second copy of a JPEG to save nothing; in the
/// strict direction it means a CSS file goes out uncompressed, which is
/// merely the behaviour of every previous version. So the list names what is
/// known to be text.
fn compressible(content_type: []const u8) bool {
    // `text/anything` is text, including the ones nobody has thought of.
    if (std.mem.startsWith(u8, content_type, "text/")) return true;

    // A structured type ending in `+json` or `+xml` — `image/svg+xml`,
    // `application/manifest+json` — is text however it starts.
    const base = content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len];
    const trimmed = std.mem.trimEnd(u8, base, " ");
    if (std.mem.endsWith(u8, trimmed, "+json")) return true;
    if (std.mem.endsWith(u8, trimmed, "+xml")) return true;

    for ([_][]const u8{
        "application/json",
        "application/javascript",
        "application/xml",
        "application/wasm",
        "application/x-ndjson",
        "image/x-icon",
        "font/ttf",
        "font/otf",
    }) |known| {
        if (std.mem.eql(u8, trimmed, known)) return true;
    }
    return false;
}

/// Gzip `bytes`, or null if the result is not smaller than what went in.
///
/// The 64 KB window lives on this function's stack and is gone before the
/// server starts. That is the whole reason compression can be here at all
/// and not on the request path.
fn gzipped(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!?[]const u8 {
    // `Compress.init` asserts its output has somewhere to write, and an
    // `Allocating` starts with a buffer of nothing at all. Half the input
    // is roughly where text lands, so this is also the size that usually
    // means the output is never grown.
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, bytes.len / 2 + 64);
    errdefer out.deinit();

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var compressor = std.compress.flate.Compress.init(
        &out.writer,
        window,
        .gzip,
        .default,
    ) catch return error.OutOfMemory;
    compressor.writer.writeAll(bytes) catch return error.OutOfMemory;
    compressor.finish() catch return error.OutOfMemory;

    // A file that does not shrink is a file served as it is. Keeping the
    // copy would cost memory to send more bytes than the original.
    if (out.written().len >= bytes.len) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
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
    sortByUrl(files);
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

// ---- gzip, done once when the App is built ----

test "Accept-Encoding is read, not searched for the word gzip" {
    // The plain yes.
    try testing.expect(acceptsGzip("gzip"));
    try testing.expect(acceptsGzip("gzip, deflate, br"));
    try testing.expect(acceptsGzip("deflate, gzip"));
    try testing.expect(acceptsGzip("GZIP"));
    try testing.expect(acceptsGzip("gzip;q=1.0"));
    try testing.expect(acceptsGzip("gzip ; q=0.5"));

    // The header contains "gzip" and means the opposite. A server that
    // searched for the word would send a body this client cannot read.
    try testing.expect(!acceptsGzip("gzip;q=0"));
    try testing.expect(!acceptsGzip("gzip;q=0.0"));
    try testing.expect(!acceptsGzip("gzip;q=0.000"));
    try testing.expect(!acceptsGzip("deflate, gzip;q=0"));

    // A wildcard stands in, and an explicit entry outranks it either way.
    try testing.expect(acceptsGzip("*"));
    try testing.expect(!acceptsGzip("*;q=0"));
    try testing.expect(!acceptsGzip("*, gzip;q=0"));
    try testing.expect(acceptsGzip("*;q=0, gzip"));

    // Nothing asked for it.
    try testing.expect(!acceptsGzip(null));
    try testing.expect(!acceptsGzip(""));
    try testing.expect(!acceptsGzip("identity"));
    try testing.expect(!acceptsGzip("deflate, br"));

    // A word that merely starts the same way is a different encoding.
    try testing.expect(!acceptsGzip("gzip-x"));
    try testing.expect(!acceptsGzip("x-gzip"));
}

test "only the types that are text get a compressed copy" {
    try testing.expect(compressible("text/html; charset=utf-8"));
    try testing.expect(compressible("text/css"));
    try testing.expect(compressible("application/json"));
    try testing.expect(compressible("application/javascript"));
    try testing.expect(compressible("image/svg+xml"));
    try testing.expect(compressible("application/manifest+json"));
    try testing.expect(compressible("application/wasm"));

    // Already compressed. A second copy would cost memory to save nothing.
    try testing.expect(!compressible("image/png"));
    try testing.expect(!compressible("image/jpeg"));
    try testing.expect(!compressible("font/woff2"));
    try testing.expect(!compressible("video/mp4"));
    try testing.expect(!compressible("application/zip"));
    try testing.expect(!compressible("application/octet-stream"));
}

test "a gzipped copy is smaller, and inflates back to exactly the original" {
    const gpa = testing.allocator;
    // Repetitive enough to compress, which is what a real stylesheet is.
    const original = "body { margin: 0; padding: 0; } " ** 64;

    const squeezed = (try gzipped(gpa, original)) orelse return error.TestExpectedCompression;
    defer gpa.free(squeezed);
    try testing.expect(squeezed.len < original.len);
    // The gzip magic, so this is a container a browser will recognise
    // rather than a raw deflate stream.
    try testing.expectEqual(@as(u8, 0x1f), squeezed[0]);
    try testing.expectEqual(@as(u8, 0x8b), squeezed[1]);

    // The whole point: what comes back out is what went in.
    var in: std.Io.Reader = .fixed(squeezed);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    _ = try inflate.reader.streamRemaining(&out.writer);
    try testing.expectEqualStrings(original, out.written());
}

test "a file that does not shrink keeps no copy" {
    const gpa = testing.allocator;
    // Already-random bytes are the case gzip cannot help with, and the
    // container's own header makes the result bigger than the input.
    var noise: [512]u8 = undefined;
    var seed: u32 = 12345;
    for (&noise) |*b| {
        seed = seed *% 1664525 +% 1013904223;
        b.* = @truncate(seed >> 24);
    }
    try testing.expect((try gzipped(gpa, &noise)) == null);
}

test "the two representations of one file never share an ETag" {
    const gpa = testing.allocator;
    const html = "<!doctype html><title>hello</title>" ** 64;

    var set = try fromMemory(gpa, &.{.{
        .url = "/index.html",
        .bytes = html,
        .content_type = "text/html; charset=utf-8",
    }});
    defer set.deinit();

    const file = set.find("/index.html").?;
    try testing.expect(file.gzip != null);
    // Different bytes, so a different tag. Sharing one would let a cache in
    // front answer a client that cannot read gzip with the gzipped copy,
    // because the tag it was holding matched.
    try testing.expect(!std.mem.eql(u8, file.etag, file.gzip_etag));

    const plain = file.representation(false);
    try testing.expect(!plain.gzipped);
    try testing.expectEqualStrings(html, plain.bytes);
    try testing.expectEqualStrings(file.etag, plain.etag);

    const squeezed = file.representation(true);
    try testing.expect(squeezed.gzipped);
    try testing.expect(squeezed.bytes.len < html.len);
    try testing.expectEqualStrings(file.gzip_etag, squeezed.etag);
}

test "a file with no compressed copy asks for the plain one whatever the client says" {
    const gpa = testing.allocator;
    var set = try fromMemory(gpa, &.{.{
        .url = "/tiny.txt",
        .bytes = "no",
        .content_type = "text/plain",
    }});
    defer set.deinit();

    const file = set.find("/tiny.txt").?;
    try testing.expect(file.gzip == null);
    try testing.expect(!file.representation(true).gzipped);
    try testing.expectEqualStrings("no", file.representation(true).bytes);
}
