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
//! range is a slice and two headers (ADR 0021).
//!
//! A file over `max_file_bytes` is the one exception, and it is a spill
//! rather than a refusal: it stays in the list with its size and the path
//! the walk produced, and a request opens it and sends it from the disk
//! (ADR 0037). Both of the properties above survive that. The name handed
//! to `openat` is the one the walk wrote down and never one a request
//! carried, so there is still nothing to traverse; the memory is still a
//! number, because a spilled file holds no bytes at all; and the read that
//! does happen goes through the Engine, so the fiber parks rather than
//! stopping the thread every other connection on it is being served by.

const std = @import("std");

const bulkhead = @import("bulkhead.zig");

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
    /// The line between a file held in memory and one left where it is.
    ///
    /// At or below it nothing has changed: the file is read at load,
    /// hashed, gzipped if it is worth it, and answered from a slice. Above
    /// it the file is not read at all — it stays in the list with its size,
    /// its modification time and the path the walk produced, and a request
    /// opens it and sends it from the disk (ADR 0037).
    ///
    /// So this is a threshold and not a ceiling. What crossing it costs is
    /// named rather than hidden: no gzipped copy, an ETag made of the
    /// modification time and the size rather than of the contents, and one
    /// file descriptor for as long as the response takes — bounded, like
    /// everything else in flight, by `max_connections`.
    ///
    /// Eight megabytes is about where a file stops being part of a page and
    /// starts being a video, an archive or an installer. All three are
    /// compressed already, which is most of what a spilled file gives up.
    max_file_bytes: usize = 8 * 1024 * 1024,
    /// The ceiling on what one directory may hold in memory, gzipped copies
    /// included. Spilled files count nothing towards it, because they hold
    /// nothing: this number is what an operator multiplies against a memory
    /// budget, and a file that is opened per request is not in that budget.
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
    content_type: []const u8,
    /// A strong ETag, quotes included, worked out once at load. Which two
    /// numbers it is made of depends on where the bytes are — see
    /// `Contents`.
    etag: []const u8,
    /// Borrowed from the Set's options.
    cache_control: []const u8,
    /// Where the bytes are, and everything that follows from that.
    contents: Contents,

    /// A file is either held or spilled, and past the head they answer with
    /// the two have nothing in common.
    ///
    /// A union rather than a `bytes` that is empty for a spilled file: an
    /// empty slice is a perfectly good file, so "check whether it is empty"
    /// is a rule somebody eventually forgets, and the failure it leads to is
    /// a response promising bytes it never sends. This way asking a spilled
    /// file for bytes it never read is a bug where it is written rather than
    /// on the wire (ADR 0037).
    pub const Contents = union(enum) {
        held: Held,
        spilled: Spilled,
    };

    /// Read at load and answered from memory — everything at or below
    /// `max_file_bytes`, which is nearly everything a web tree contains.
    pub const Held = struct {
        bytes: []const u8,
        /// The same file, gzipped at load. Null when it was not worth it —
        /// too small, a type that is already compressed, or it came out no
        /// smaller.
        gzip: ?[]const u8 = null,
        /// The ETag of the gzipped bytes, which is a different one.
        ///
        /// An ETag names a representation, not a file. Handing the same
        /// ETag to both would let anything caching in front of this — a
        /// CDN, a browser, a proxy — answer a client that cannot read gzip
        /// with the gzipped copy, on the grounds that the tag matched.
        /// Empty when `gzip` is null.
        gzip_etag: []const u8 = &.{},
    };

    /// Left on the disk and opened per request (ADR 0037).
    ///
    /// There is no gzipped copy and there never will be: compression here
    /// happens once, while the App is being built (ADR 0018), and a file
    /// that is not being held cannot be compressed once. Compressing it per
    /// request is the trade that was already refused for handler responses.
    pub const Spilled = struct {
        /// The directory `path` is opened against, which is the Set's.
        ///
        /// A copy of the handle rather than a pointer to the Set: a
        /// descriptor is a number, and the Set itself is a value that gets
        /// moved into the App's list of them, so a pointer would be the one
        /// thing here that could go stale. The Set owns it and closes it
        /// once; this is borrowed for as long as the App lives.
        dir: bulkhead.Dir,
        /// The path the directory walk produced, relative to `dir`.
        ///
        /// Not derived from the URL, and that is the whole traversal
        /// argument: the string handed to `openat` was written down before
        /// the socket opened, so `../../etc/passwd` is still not a path
        /// that gets resolved — it is a name that is not in the list.
        path: []const u8,
        /// What the walk's `stat` said. Handed to `sendfile.send` rather
        /// than re-statting per request, because the ETag is made of this
        /// number: a fresh `stat` could hand a client a length and a tag
        /// that describe two different files.
        size: u64,
        /// The other half of that ETag. Kept as the number it came from
        /// rather than only as the hex inside the tag, so that anything
        /// comparing files later compares two integers instead of parsing a
        /// string back.
        mtime_ns: i96,
    };

    /// Which bytes and which ETag to answer with. Kept together so the two
    /// cannot come apart: picking one representation and then tagging it
    /// with the other's ETag is the failure this whole pairing exists to
    /// make impossible.
    pub const Representation = struct {
        bytes: []const u8,
        etag: []const u8,
        gzipped: bool,
    };

    /// The bytes and the ETag of a held file.
    ///
    /// Asking a spilled file is not a case to handle but a bug to hear
    /// about: it has no bytes, and its answer is written from a descriptor
    /// by `sendfile.send`. Callers branch on `contents` first — `App`'s
    /// `serveStaticFile` does it once, at the top.
    pub fn identity(self: *const File) Representation {
        return .{ .bytes = self.contents.held.bytes, .etag = self.etag, .gzipped = false };
    }

    /// The gzipped form if there is one and the client said it can read
    /// one, and the plain form otherwise.
    pub fn representation(self: *const File, wants_gzip: bool) Representation {
        if (!wants_gzip) return self.identity();
        const held = self.contents.held;
        const packed_bytes = held.gzip orelse return self.identity();
        return .{ .bytes = packed_bytes, .etag = held.gzip_etag, .gzipped = true };
    }
};

/// Everything one file allocated, in one place. `load` frees a half-built
/// list with this and `Set.deinit` frees a finished one, so a file that
/// grows an allocation cannot be freed on one path and leaked on the other.
fn freeFile(gpa: std.mem.Allocator, f: File) void {
    gpa.free(f.url);
    gpa.free(f.etag);
    switch (f.contents) {
        .held => |held| {
            gpa.free(held.bytes);
            if (held.gzip) |p| gpa.free(p);
            if (held.gzip_etag.len > 0) gpa.free(held.gzip_etag);
        },
        // The descriptor belongs to the Set, not to the file that borrowed
        // it, so there is nothing here but the name.
        .spilled => |on_disk| gpa.free(on_disk.path),
    }
}

/// One directory, loaded. Owns every byte in it.
pub const Set = struct {
    gpa: std.mem.Allocator,
    prefix: []const u8,
    /// Sorted by url, so a lookup is a binary search rather than a walk.
    files: []File,
    fallback: ?*const File,
    index: []const u8,
    /// The directory itself, held open for as long as the App is, because a
    /// spilled file is opened relative to it on every request that asks for
    /// one. Opened by `load` before the socket is, which is what makes the
    /// name a request never chose the only name that ever reaches `openat`.
    ///
    /// Null for a Set that has no directory — `fromMemory`, which is bytes
    /// that were already here (ADR 0017) and can spill nothing.
    dir: ?bulkhead.Dir = null,

    pub fn deinit(self: *Set) void {
        for (self.files) |f| freeFile(self.gpa, f);
        self.gpa.free(self.files);
        self.gpa.free(self.prefix);
        if (self.dir) |d| d.close();
        self.files = &.{};
        self.fallback = null;
        self.dir = null;
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
    StaticSetTooLarge,
    StaticUrlTooLong,
    OutOfMemory,
    StaticReadFailed,
};

/// Which of these failures `load` has already put into words, so `App` can
/// stop the process on them instead of letting the error reach `main` and
/// print a stack trace through nilo's own files on top of the answer
/// (ADR 0002). The same rule `bulkhead.explained` states for `listen()`.
///
/// `OutOfMemory` is not on the list: nothing explained it, and there is
/// nothing useful to say about it that the error name does not.
pub fn explained(err: anyerror) bool {
    return switch (err) {
        error.StaticDirNotFound,
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
        .etag = &.{},
        .content_type = "",
        .cache_control = "",
        // Held, and empty. Nothing here can spill: there is no directory to
        // spill to, and these bytes are already in memory by definition.
        .contents = .{ .held = .{ .bytes = &.{} } },
    };

    // The same rule a loaded directory follows, with the same defaults.
    // The API description is JSON and is the largest thing that comes
    // through here, so leaving it out would have meant the one file nilo
    // generates itself being the one file it does not compress.
    const defaults = Options{};

    for (entries, set.files) |entry, *file| {
        file.url = try gpa.dupe(u8, entry.url);
        file.etag = try etagFor(gpa, entry.bytes);
        file.content_type = entry.content_type;
        file.cache_control = entry.cache_control;

        const held = &file.contents.held;
        held.bytes = try gpa.dupe(u8, entry.bytes);
        if (entry.bytes.len >= defaults.compress_min_bytes and compressible(entry.content_type)) {
            held.gzip = try gzipped(gpa, entry.bytes);
            if (held.gzip) |p| held.gzip_etag = try etagFor(gpa, p);
        }
    }

    sortByUrl(set.files);
    return set;
}

/// Read `dir_path` into memory, mapping every file in it to a URL under
/// `url_prefix`. Called before `listen()`, so the blocking reads here
/// happen while nothing is being served.
///
/// A file over `options.max_file_bytes` is listed rather than read: it keeps
/// its place in the set with the path the walk produced, and the request
/// that asks for it opens it (ADR 0037).
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
            "nilo: static directory \"{s}\" could not be opened ({s}) — " ++
                "the path is relative to the working directory the server runs in",
            .{ dir_path, @errorName(err) },
        );
        return error.StaticDirNotFound;
    };
    defer dir.close(io);

    // The same directory a second time, through the Bulkhead, and this one
    // is kept: a spilled file is opened relative to it by every request that
    // asks for one. Opened here rather than at the first request, which is
    // what makes the descriptor older than the socket and the name from the
    // walk the only name that ever reaches `openat` (ADR 0037). One
    // descriptor per set, whether or not anything spilled today — the
    // alternative is a lazily opened directory on the request path and a
    // branch to go with it.
    const serving = bulkhead.Dir.open(dir_path) catch |err| {
        std.log.err(
            "nilo: static directory \"{s}\" could not be held open ({s}) — " ++
                "the path is relative to the working directory the server runs in",
            .{ dir_path, @errorName(err) },
        );
        return error.StaticDirNotFound;
    };

    // Built empty and up front so that one `errdefer` owns everything from
    // here: the files, the prefix and the descriptor above. The list below
    // is filled first and handed over at the end, which is the only window
    // where two things are being tidied up rather than one.
    var set = Set{
        .gpa = gpa,
        .prefix = &.{},
        .files = &.{},
        .fallback = null,
        .index = options.index,
        .dir = serving,
    };
    errdefer set.deinit();
    set.prefix = try gpa.dupe(u8, url_prefix);

    var files: std.ArrayList(File) = .empty;
    errdefer {
        for (files.items) |f| freeFile(gpa, f);
        files.deinit(gpa);
    }

    var held_total: usize = 0;
    var packed_total: usize = 0;
    var spilled_files: usize = 0;
    var skipped_dotfiles: usize = 0;

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (walker.next(io) catch |err| {
        std.log.err(
            "nilo: static directory \"{s}\" could not be walked ({s})",
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
            std.log.err("nilo: static file \"{s}\" has a path longer than {d} bytes", .{ entry.path, max_url });
            return error.StaticUrlTooLong;
        };
        toForwardSlashes(url);

        const content_type = contentTypeFor(url);

        // Asked before anything is read, which is the whole point: a file
        // over the line must not be read even once, or startup on a
        // directory of videos costs a pass over every one of them.
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| {
            std.log.err("nilo: static file \"{s}\" could not be read ({s})", .{ entry.path, @errorName(err) });
            return error.StaticReadFailed;
        };

        if (stat.size > options.max_file_bytes) {
            // Over the line, so what goes in the list is where to find it
            // rather than what is in it (ADR 0037). Nothing is added to
            // `held_total`: this file holds no memory to be counted.
            const relative = try gpa.dupe(u8, entry.path);
            errdefer gpa.free(relative);

            try files.append(gpa, .{
                .url = try gpa.dupe(u8, url),
                .content_type = content_type,
                .etag = try etagForSpilled(gpa, stat.mtime.nanoseconds, stat.size),
                .cache_control = options.cache_control,
                .contents = .{ .spilled = .{
                    .dir = serving,
                    .path = relative,
                    .size = stat.size,
                    .mtime_ns = stat.mtime.nanoseconds,
                } },
            });
            spilled_files += 1;
            continue;
        }

        // One byte past the threshold, not the threshold itself:
        // `readFileAlloc` gives up as soon as it has taken the whole limit,
        // so a file of exactly `max_file_bytes` would come back as
        // `error.StreamTooLong` — and at or below the line is held. Reaching
        // it at all now means the file grew between the `stat` above and
        // this read, which is a read that failed rather than a size that was
        // refused.
        const bytes = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited64(options.max_file_bytes +| 1)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            std.log.err("nilo: static file \"{s}\" could not be read ({s})", .{ entry.path, @errorName(err) });
            return error.StaticReadFailed;
        };
        errdefer gpa.free(bytes);

        held_total += bytes.len;
        if (held_total > options.max_total_bytes) {
            std.log.err(
                "nilo: static directory \"{s}\" is over the {d} byte total limit",
                .{ dir_path, options.max_total_bytes },
            );
            return error.StaticSetTooLarge;
        }

        var packed_bytes: ?[]const u8 = null;
        errdefer if (packed_bytes) |p| gpa.free(p);
        if (options.compress and
            bytes.len >= options.compress_min_bytes and
            compressible(content_type))
        {
            packed_bytes = try gzipped(gpa, bytes);
            if (packed_bytes) |p| {
                packed_total += p.len;
                held_total += p.len;
                if (held_total > options.max_total_bytes) {
                    std.log.err(
                        "nilo: static directory \"{s}\" is over the {d} byte total limit " ++
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
            .content_type = content_type,
            .etag = try etagFor(gpa, bytes),
            .cache_control = options.cache_control,
            .contents = .{ .held = .{
                .bytes = bytes,
                .gzip = packed_bytes,
                .gzip_etag = if (packed_bytes) |p| try etagFor(gpa, p) else &.{},
            } },
        });
    }

    // Handed over, so the list is empty and its `errdefer` above has nothing
    // left to free — from here the Set's own one covers all of it.
    set.files = try files.toOwnedSlice(gpa);
    sortByUrl(set.files);

    if (options.spa_fallback.len > 0) {
        var buf: [max_url]u8 = undefined;
        const url = join(&buf, url_prefix, options.spa_fallback) orelse {
            std.log.err(
                "nilo: the SPA fallback URL \"{s}\" + \"{s}\" is longer than {d} bytes",
                .{ url_prefix, options.spa_fallback, max_url },
            );
            return error.StaticUrlTooLong;
        };
        set.fallback = set.lookup(url) orelse {
            std.log.err(
                "nilo: the SPA fallback \"{s}\" is not in \"{s}\" — " ++
                    "the name is relative to the directory, e.g. \"index.html\"",
                .{ options.spa_fallback, dir_path },
            );
            // Nothing freed by hand: the `errdefer` on the Set above is what
            // gives back the files, the prefix and the descriptor, and doing
            // it twice was a double free waiting for somebody to configure a
            // fallback that is not there.
            return error.StaticDirNotFound;
        };
    }

    // Held bytes and spilled files are two different numbers and are said as
    // two, because the first one is what an operator multiplies against a
    // memory budget and the second one is not in that budget at all — it is
    // one descriptor each, and only while a response is being written.
    std.log.info(
        "nilo: loaded {d} static file(s) ({d} bytes held{f}) from \"{s}\" onto \"{s}\"{f}{s}",
        .{
            set.files.len,
            held_total,
            GzipNote{ .bytes = packed_total },
            dir_path,
            url_prefix,
            SpillNote{ .files = spilled_files, .over = options.max_file_bytes },
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

/// The spilled half, on the same terms as `GzipNote`: a tree where every
/// file fit is a tree that should not have to read about the threshold.
///
/// Outside the byte total on purpose. What is in the brackets is memory, and
/// this is a count of files that are not in it — putting the two together
/// would invite exactly the reading the split exists to prevent.
const SpillNote = struct {
    files: usize,
    over: usize,

    pub fn format(self: SpillNote, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.files == 0) return;
        try w.print(
            ", {d} of them over {d} bytes and opened per request rather than held",
            .{ self.files, self.over },
        );
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

/// The ETag of a file nobody read: its modification time and its size.
///
/// Also strong, and deliberately so. The tempting alternative is a weak
/// validator, and RFC 9110 says an `If-Range` carrying one must be ignored —
/// which would send the whole file to every client resuming a download, and
/// resuming is what large files are *for*. Hashing is not on offer up here:
/// a strong tag for a four-gigabyte file means reading four gigabytes, at
/// startup or per request, and both are worse than what is being risked.
/// What is being risked is two different contents sharing a size and a
/// modification time to the nanosecond, which is the risk nginx has been
/// taking by default for twenty years (ADR 0037).
///
/// The time goes through `@bitCast` rather than a cast that could fail: a
/// clock is allowed to say anything, including a negative number, and a
/// panic while loading a directory is not the way to find that out.
fn etagForSpilled(gpa: std.mem.Allocator, mtime_ns: i96, size: u64) ![]const u8 {
    return std.fmt.allocPrint(gpa, "\"{x}-{x}\"", .{ @as(u96, @bitCast(mtime_ns)), size });
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
            .content_type = contentTypeFor(url),
            .etag = try etagFor(gpa, "x"),
            .cache_control = "",
            .contents = .{ .held = .{ .bytes = try gpa.dupe(u8, "x") } },
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
    const held = file.contents.held;
    try testing.expect(held.gzip != null);
    // Different bytes, so a different tag. Sharing one would let a cache in
    // front answer a client that cannot read gzip with the gzipped copy,
    // because the tag it was holding matched.
    try testing.expect(!std.mem.eql(u8, file.etag, held.gzip_etag));

    const plain = file.representation(false);
    try testing.expect(!plain.gzipped);
    try testing.expectEqualStrings(html, plain.bytes);
    try testing.expectEqualStrings(file.etag, plain.etag);

    const squeezed = file.representation(true);
    try testing.expect(squeezed.gzipped);
    try testing.expect(squeezed.bytes.len < html.len);
    try testing.expectEqualStrings(held.gzip_etag, squeezed.etag);
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
    try testing.expect(file.contents.held.gzip == null);
    try testing.expect(!file.representation(true).gzipped);
    try testing.expectEqualStrings("no", file.representation(true).bytes);
}

// ---- a file too big to hold (ADR 0037) ----

const App = @import("app.zig").App;
const nilo_testing = @import("testing.zig");

/// A directory of real files, written for one test and removed after it.
/// The path is relative to the working directory, which is what `load` and
/// `app.static` both take.
const TmpTree = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(gpa: std.mem.Allocator, files: []const [2][]const u8) !TmpTree {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        for (files) |entry| {
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = entry[0], .data = entry[1] });
        }
        return .{
            .tmp = tmp,
            .path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
        };
    }

    fn deinit(self: *TmpTree, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }
};

test "a file over the threshold is listed rather than refused, and holds no bytes" {
    const gpa = testing.allocator;
    // Text, and repetitive, so this is a file gzip would certainly have been
    // worth had it been held. That is what makes "no compressed copy" a
    // decision here rather than an accident of the contents.
    const big = "the quick brown fox jumps over the lazy dog. " ** 8;
    var tree = try TmpTree.init(gpa, &.{
        .{ "small.txt", "small" },
        .{ "big.txt", big },
    });
    defer tree.deinit(gpa);

    // A total limit far below the big file's size, on purpose: a spilled
    // file holds nothing, so it is charged nothing, and a set that would
    // once have been refused twice over loads.
    var set = try load(gpa, "/", tree.path, .{
        .max_file_bytes = 64,
        .max_total_bytes = 128,
        .compress_min_bytes = 16,
    });
    defer set.deinit();

    try testing.expectEqual(@as(usize, 2), set.files.len);

    // Below the line, nothing changed.
    const held = set.find("/small.txt").?;
    try testing.expectEqualStrings("small", held.contents.held.bytes);

    // Above it, the file is where to find it rather than what is in it.
    // There is no gzipped copy to ask about — a spilled file has nowhere to
    // put one, which is the union's doing rather than a rule to remember.
    const spilled = set.find("/big.txt").?;
    const on_disk = switch (spilled.contents) {
        .held => return error.TestExpectedSpill,
        .spilled => |s| s,
    };
    try testing.expectEqualStrings("big.txt", on_disk.path);
    try testing.expectEqual(@as(u64, big.len), on_disk.size);
    try testing.expectEqualStrings("text/plain; charset=utf-8", spilled.content_type);

    // The size and the time are the file's own, not something derived from
    // the URL or guessed at.
    const stat = try tree.tmp.dir.statFile(std.testing.io, "big.txt", .{});
    try testing.expectEqual(stat.size, on_disk.size);
    try testing.expectEqual(stat.mtime.nanoseconds, on_disk.mtime_ns);

    // The tag is made of those two numbers, and is not a hash of the
    // contents — which is the point, because nothing read the contents.
    const from_contents = try etagFor(gpa, big);
    defer gpa.free(from_contents);
    try testing.expect(!std.mem.eql(u8, from_contents, spilled.etag));

    const expected = try etagForSpilled(gpa, on_disk.mtime_ns, on_disk.size);
    defer gpa.free(expected);
    try testing.expectEqualStrings(expected, spilled.etag);

    // `"<mtime>-<size>"`, hex, quotes included: nginx's shape, and strong,
    // so an `If-Range` resuming a large download is honoured rather than
    // ignored.
    try testing.expect(spilled.etag[0] == '"');
    try testing.expect(spilled.etag[spilled.etag.len - 1] == '"');
    const inner = spilled.etag[1 .. spilled.etag.len - 1];
    const dash = std.mem.indexOfScalar(u8, inner, '-').?;
    try testing.expect(dash > 0);
    for (inner[0..dash]) |ch| try testing.expect(std.ascii.isHex(ch));
    var size_hex: [32]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&size_hex, "{x}", .{on_disk.size}),
        inner[dash + 1 ..],
    );

    // The same directory again with the threshold moved above it: the very
    // same file is now held, hashed and gzipped. So everything asserted
    // above is the spill's doing and not something about this file.
    var all_held = try load(gpa, "/", tree.path, .{ .compress_min_bytes = 16 });
    defer all_held.deinit();
    const now_held = all_held.find("/big.txt").?.contents.held;
    try testing.expectEqualStrings(big, now_held.bytes);
    try testing.expect(now_held.gzip != null);
    try testing.expectEqualStrings(from_contents, all_held.find("/big.txt").?.etag);
}

test "a whole set can spill, and the ETag moves when the file does" {
    const gpa = testing.allocator;
    var tree = try TmpTree.init(gpa, &.{.{ "video.mp4", "0123456789" }});
    defer tree.deinit(gpa);

    var first = try load(gpa, "/", tree.path, .{ .max_file_bytes = 4 });
    // Freed before the second load, so the two ETags are compared as copies
    // rather than as pointers into a Set that has been thrown away.
    var etag_buf: [64]u8 = undefined;
    const before = etag_buf[0..first.find("/video.mp4").?.etag.len];
    @memcpy(before, first.find("/video.mp4").?.etag);
    first.deinit();

    // Rewritten: different contents, a different length, and a modification
    // time the filesystem moved.
    try tree.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "video.mp4", .data = "abcdefghijkl" });

    var second = try load(gpa, "/", tree.path, .{ .max_file_bytes = 4 });
    defer second.deinit();
    try testing.expect(!std.mem.eql(u8, before, second.find("/video.mp4").?.etag));
}

test "a spilled file answers whole, in parts, and with a 304" {
    const gpa = testing.allocator;
    const alphabet = "abcdefghijklmnopqrstuvwxyz";
    var tree = try TmpTree.init(gpa, &.{.{ "alphabet.txt", alphabet }});
    defer tree.deinit(gpa);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStaticWith("/", tree.path, .{
        .max_file_bytes = 8,
        .cache_control = "public, max-age=60",
    });

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    // The whole thing, with everything a held file's answer carries.
    const whole = try client.get(&app, "/alphabet.txt");
    try testing.expectEqual(@as(u16, 200), whole.status);
    try testing.expectEqualStrings(alphabet, whole.body);
    try testing.expectEqualStrings("26", whole.header("Content-Length").?);
    try testing.expectEqualStrings("bytes", whole.header("Accept-Ranges").?);
    try testing.expectEqualStrings("public, max-age=60", whole.header("Cache-Control").?);
    try testing.expectEqualStrings("text/plain; charset=utf-8", whole.header("Content-Type").?);

    // Copied out: the next request writes over the buffer this points into.
    var etag_buf: [64]u8 = undefined;
    const etag = etag_buf[0..whole.header("ETag").?.len];
    @memcpy(etag, whole.header("ETag").?);

    // Text, and a client that would take a gzipped copy — but a file nobody
    // is holding has none to give, and nothing here compresses per request
    // (ADR 0018). No `Vary` either: there is only one representation.
    const asked = try client.send(
        &app,
        "GET /alphabet.txt HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 200), asked.status);
    try testing.expect(asked.header("Content-Encoding") == null);
    try testing.expect(asked.header("Vary") == null);
    try testing.expectEqualStrings(alphabet, asked.body);

    // Part of it, from the middle, without the rest being read.
    const part = try client.send(&app, "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=3-5\r\n\r\n");
    try testing.expectEqual(@as(u16, 206), part.status);
    try testing.expectEqualStrings("bytes 3-5/26", part.header("Content-Range").?);
    try testing.expectEqualStrings("def", part.body);

    // A resumed download, held to the file it started with by the tag it was
    // given — which is why that tag has to be strong (ADR 0037).
    var request_buf: [256]u8 = undefined;
    const resumed = try client.send(&app, try std.fmt.bufPrint(
        &request_buf,
        "GET /alphabet.txt HTTP/1.1\r\nRange: bytes=20-\r\nIf-Range: {s}\r\n\r\n",
        .{etag},
    ));
    try testing.expectEqual(@as(u16, 206), resumed.status);
    try testing.expectEqualStrings("uvwxyz", resumed.body);

    // And a repeat visitor: a comparison and a head, no body and no disk.
    const conditional = try client.send(&app, try std.fmt.bufPrint(
        &request_buf,
        "GET /alphabet.txt HTTP/1.1\r\nIf-None-Match: {s}\r\n\r\n",
        .{etag},
    ));
    try testing.expectEqual(@as(u16, 304), conditional.status);
    try testing.expectEqualStrings("", conditional.body);
    try testing.expectEqualStrings(etag, conditional.header("ETag").?);
}

test "a held file and a spilled one answer a conditional range the same way" {
    // The two arms of `serveStaticFile` are written out separately, because
    // one picks between representations and the other has only one (see the
    // comment there). This is what stops them drifting: the same four
    // requests, the same four answers, whichever side of the threshold the
    // file is on.
    const gpa = testing.allocator;
    const alphabet = "abcdefghijklmnopqrstuvwxyz";

    for ([_]usize{ 8, 1024 }) |max_file_bytes| {
        var tree = try TmpTree.init(gpa, &.{.{ "a.bin", alphabet }});
        defer tree.deinit(gpa);

        var app = App.init(gpa);
        defer app.deinit();
        try app.tryStaticWith("/", tree.path, .{ .max_file_bytes = max_file_bytes });

        var client = try nilo_testing.Client.init(gpa, .{});
        defer client.deinit();

        const whole = try client.get(&app, "/a.bin");
        try testing.expectEqual(@as(u16, 200), whole.status);
        try testing.expectEqualStrings(alphabet, whole.body);
        var etag_buf: [64]u8 = undefined;
        const etag = etag_buf[0..whole.header("ETag").?.len];
        @memcpy(etag, whole.header("ETag").?);

        var request_buf: [256]u8 = undefined;
        const resumed = try client.send(&app, try std.fmt.bufPrint(
            &request_buf,
            "GET /a.bin HTTP/1.1\r\nRange: bytes=20-\r\nIf-Range: {s}\r\n\r\n",
            .{etag},
        ));
        try testing.expectEqual(@as(u16, 206), resumed.status);
        try testing.expectEqualStrings("bytes 20-25/26", resumed.header("Content-Range").?);
        try testing.expectEqualStrings("uvwxyz", resumed.body);

        // The file the client started with is gone, so byte 20 of this one is
        // not the byte it wanted: all of it, and no `Content-Range` (ADR 0021).
        const stale = try client.send(
            &app,
            "GET /a.bin HTTP/1.1\r\nRange: bytes=20-\r\nIf-Range: \"gone\"\r\n\r\n",
        );
        try testing.expectEqual(@as(u16, 200), stale.status);
        try testing.expectEqualStrings(alphabet, stale.body);
        try testing.expect(stale.header("Content-Range") == null);

        // Past the end says how big it really is, on both sides.
        const past = try client.send(&app, "GET /a.bin HTTP/1.1\r\nRange: bytes=99-\r\n\r\n");
        try testing.expectEqual(@as(u16, 416), past.status);
        try testing.expectEqualStrings("bytes */26", past.header("Content-Range").?);
    }
}

test "a set with no directory closes cleanly, and one with a directory gives it back" {
    // `fromMemory` is the API description (ADR 0017): no directory, nothing
    // to spill, and a `deinit` that must not reach for a descriptor that was
    // never opened.
    const gpa = testing.allocator;
    var from_memory = try fromMemory(gpa, &.{.{
        .url = "/openapi.json",
        .bytes = "{}",
        .content_type = "application/json",
    }});
    try testing.expect(from_memory.dir == null);
    from_memory.deinit();

    var tree = try TmpTree.init(gpa, &.{.{ "a.txt", "a" }});
    defer tree.deinit(gpa);
    var loaded = try load(gpa, "/", tree.path, .{});
    // Held open for the App's lifetime whether or not anything spilled, so
    // that opening one is never something a request has to do.
    try testing.expect(loaded.dir != null);
    loaded.deinit();
    try testing.expect(loaded.dir == null);
}
