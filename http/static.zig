//! Static files, held in memory (ADR 009).
//!
//! ```zig
//! try app.static("/", "public");
//! try app.staticWith("/assets", "dist", .{ .cache_control = "public, max-age=31536000, immutable" });
//! try app.embedded("/", &.{ .{ .path = "index.html", .bytes = @embedFile("dist/index.html") } });
//! ```
//!
//! A directory is read once, at startup, into memory owned by the App.
//! Nothing touches the disk while requests are being served, which is the
//! whole reason it is done this way: a blocking read inside a fiber stalls
//! every other connection sharing that OS thread, and the p99 the project
//! measures itself on would go with it.
//!
//! A tree the binary carries takes the same path from one step further in
//! (ADR 009): `embed` is `load` with the read taken out. The bytes are
//! borrowed from the binary rather than read from a disk, and everything
//! after that — the sorted list, the ETag, the gzipped copy, the fallback —
//! is the same code, which is why a product that compiles its UI in serves
//! it exactly as one that ships a directory does, and nothing per request
//! knows the difference.
//!
//! Two things fall out of that for free. Path traversal is not possible —
//! the set of files is fixed before the socket opens, so `../../etc/passwd`
//! is not a path that gets resolved, it is a name that is not in the list.
//! And every file gets an ETag computed once at load, so a repeat visitor
//! gets a 304 with no body and no work.
//!
//! A `.br` or `.gz` the build wrote beside a file is held (or, over the
//! line, left on the disk) as that file's other form and served to a client
//! that prefers it, under a tag of its own (ADR 273).
//!
//! Range requests come along nearly free once the bytes are in memory — a
//! range is a slice and two headers (ADR 020).
//!
//! A file over `max_file_bytes` is the one exception, and it is a spill
//! rather than a refusal: it stays in the list with its size and the path
//! the walk produced, and a request opens it and sends it from the disk
//! (ADR 009). Both of the properties above survive that. The name handed
//! to `openat` is the one the walk wrote down and never one a request
//! carried, so there is still nothing to traverse; the memory is still a
//! number, because a spilled file holds no bytes at all; and the read that
//! does happen goes through the Engine, so the fiber parks rather than
//! stopping the thread every other connection on it is being served by.

const std = @import("std");

const accept_mod = @import("accept.zig");
const compress_mod = @import("compress.zig");
const bulkhead = @import("bulkhead.zig");
const follow_mod = @import("follow.zig");

pub const Options = struct {
    /// Served for a path ending in `/`. Empty turns that off.
    index: []const u8 = "index.html",
    /// Sent as `Cache-Control` on every file. Empty leaves the header off.
    cache_control: []const u8 = "public, max-age=3600",
    /// Exceptions to `cache_control`, by where a file sits in the tree: the
    /// first rule a file matches gives its header, and a file no rule matches
    /// takes `cache_control`. What a single-page app needs is two policies in
    /// one tree, hashed bundles that never change and a page that always
    /// does (ADR 009):
    ///
    /// ```zig
    /// .cache_control = "no-cache",
    /// .cache_rules = &.{.{ .prefix = "assets/", .cache_control = "public, max-age=31536000, immutable" }},
    /// ```
    ///
    /// Settled once at load, into the header each file already carries, so a
    /// request pays nothing for there being rules.
    cache_rules: []const CacheRule = &.{},
    /// Served for a path under the prefix that names no file and could be a
    /// browser opening a page — what a single-page app needs so that a reload
    /// on `/users/42` reaches the client-side router instead of a 404. Empty
    /// turns it off.
    ///
    /// The name is relative to the directory, e.g. `"index.html"`.
    spa_fallback: []const u8 = "",
    /// Which requests the fallback answers (ADR 087).
    ///
    /// `.navigations` is the default and is the rule every single-page server
    /// arrives at: a request that asked for HTML gets the page, and a request
    /// for `/app.abc123.js` that is not there gets a 404 saying so. Answering
    /// a missing asset with a page turns a stale build hash into a syntax
    /// error on line 1 of something that is not JavaScript, and a `fetch()`
    /// into a JSON parse error, neither of which names the file.
    ///
    /// `.any_path` is what shipped through 0.2.0 and is kept for an app that
    /// depends on it. It answers every path under the prefix, which is the
    /// behaviour above.
    spa_fallback_for: Fallback = .navigations,
    /// The line between a file held in memory and one left where it is.
    ///
    /// At or below it nothing has changed: the file is read at load,
    /// hashed, gzipped if it is worth it, and answered from a slice. Above
    /// it the file is not read at all — it stays in the list with its size,
    /// its modification time and the path the walk produced, and a request
    /// opens it and sends it from the disk (ADR 009).
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
    /// ([ADR 017](../docs/adr/017-the-trade-budget-has-four-axes.md)). A
    /// compressor needs a 64 KB window: one per connection would take an
    /// idle connection from 4,669 bytes to something like fifteen times that,
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

    /// Serve every file from the disk, so editing one is visible on the next
    /// request without restarting the server. **For development.**
    ///
    /// This is not a watcher and there is no fiber behind it. A file over
    /// `max_file_bytes` was always left on the disk and opened per request
    /// (ADR 009), and since
    /// [ADR 098](../docs/adr/098-a-file-is-described-by-the-descriptor-being-sent.md)
    /// that path describes what it is about to send rather than what the walk
    /// saw — so "hold nothing in memory" already *is* reload, and this option
    /// is the name for it rather than machinery beside it. It sets the
    /// threshold to zero. Nothing else changes.
    ///
    /// What it costs is what a spilled file costs, on every file: an `open`,
    /// a `stat` and a read from the disk per request, no gzipped copy, and no
    /// answer at all from memory. That is the trade development wants and
    /// production never does, so it says one line at load and is off by
    /// default.
    ///
    /// **What it does not do is notice a file that did not exist at startup.**
    /// The list of names comes from the walk, and a request for a name that is
    /// not in it is a 404 whatever is on the disk. Editing a file works;
    /// adding one still needs a restart.
    reload: bool = false,

    /// Serve a file a build already compressed: `app.js.br` or `app.js.gz`
    /// beside `app.js` answers a client that accepts that coding, in place of
    /// anything nilo would make (ADR 273).
    ///
    /// **On by default, and guarded where the others are not.** Caddy, nginx
    /// and tower-http trust a sibling blindly, and a `.br` left behind by the
    /// build before last is then served to every browser for a script that
    /// has changed. Here a `.gz` is checked against the plain file it sits
    /// beside (its trailer carries the CRC-32 and the length of what it
    /// compressed), a sibling not smaller than the file is ignored, and each
    /// one ignored is said in one line at load. Brotli has no such trailer,
    /// so a `.br` is held to the modification time alone: one older than its
    /// file is ignored.
    ///
    /// What it takes from the tree: a `X.br` or `X.gz` whose `X` is in the
    /// tree and is a type worth compressing (`compressible`) is a sibling,
    /// not a file, and **its own URL is a 404**. Its bytes are held once, as
    /// the coding of `X`; listing it as well would hold them twice. A tree
    /// that publishes `notes.txt.gz` for download beside `notes.txt` sets
    /// this to false.
    ///
    /// A sibling takes the place of the gzipped copy `compress` would have
    /// made, so the gzip is not made twice. A `.br` alone leaves that copy in
    /// place for a client that takes gzip and not brotli (every browser over
    /// plain HTTP). `compress = false` turns off the copy and not this.
    precompressed: bool = true,

    /// Keep what is held in step with the directory while the server runs
    /// (ADR 277): replace a file, or its `.br` and `.gz`, add one or remove
    /// one, and the next response carries it. **Off by default**, because
    /// what `app.static` says is that the tree is read once and a restart is
    /// how it changes (ADR 009), and a program that ships an image does not
    /// want a thread, a descriptor and a tree that can change under it.
    ///
    /// Nothing is added to a request: one background thread watches the
    /// directory (inotify on Linux, a `stat` of every file each
    /// `follow_poll_ms` anywhere else and as the backstop where inotify says
    /// nothing), builds the new tree beside the one being served and swaps
    /// them, and a response that began on the old tree finishes on it.
    follow: bool = false,
    /// The longest a change can go unnoticed: how often the directory is
    /// walked and every file `stat`ed on the watching thread, whatever
    /// inotify has or has not said. A tree of tens of thousands of files
    /// wants a larger number; a change is picked up at once where the OS
    /// tells, and within this where it does not (a network or FUSE mount).
    follow_poll_ms: u32 = 1000,

    /// Files smaller than this are served as they are.
    ///
    /// A gzip stream carries about 20 bytes of framing, so below a few
    /// hundred bytes compression can make a file bigger — and even where it
    /// does not, it is saving less than one TCP segment on a response that
    /// was already one packet. A file that comes out no smaller is dropped
    /// whatever this says.
    compress_min_bytes: usize = 1024,

    /// Which requests a single-page fallback answers.
    pub const Fallback = enum { navigations, any_path };
};

/// One exception to a set's `cache_control`, matched against a file's path in
/// the tree: relative to the directory (or the `path` of an `Embedded`), with
/// forward slashes and no leading `/`, so `"assets/app.3f9a.js"`.
///
/// Both halves must hold, and an empty one holds for every file, so
/// `.{ .prefix = "assets/" }` is a directory, `.{ .suffix = ".js" }` is a type
/// anywhere, and `.{ .prefix = "index.html" }` is that one file (and anything
/// else starting with the name). An empty `cache_control` leaves the header
/// off for the files it matches.
pub const CacheRule = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    cache_control: []const u8,
};

/// The `Cache-Control` for the file at `path` in the tree: the first rule it
/// matches, else `default`. Called once per file while a Set is built.
fn cacheControlFor(rules: []const CacheRule, default: []const u8, path: []const u8) []const u8 {
    for (rules) |rule| {
        if (std.mem.startsWith(u8, path, rule.prefix) and std.mem.endsWith(u8, path, rule.suffix))
            return rule.cache_control;
    }
    return default;
}

/// What a request said about itself that decides whether a single-page
/// fallback answers it: the two headers, borrowed from the request, null when
/// it sent none.
pub const Asked = struct {
    /// `Accept`.
    accept: ?[]const u8 = null,
    /// `Sec-Fetch-Mode`.
    fetch_mode: ?[]const u8 = null,
};

/// Whether a request that named no file is a browser opening a page, which is
/// the question `.navigations` asks before it answers with one (ADR 087).
///
/// **The browser says so when it can.** Every current browser sends
/// `Sec-Fetch-Mode: navigate` on a page load, a reload and a followed link,
/// and `cors`, `no-cors` or `same-origin` on a `fetch`, a `<script src>` and
/// an `<img>`. When the header is there it is the whole answer, whatever
/// `Accept` says.
///
/// **Without it, `Accept` has to ask for HTML by name.** A client old enough
/// to send no fetch metadata (and any browser on plain HTTP away from
/// `localhost`, where it is withheld) still opens a page with `text/html` at
/// the front of its list. `*/*` is not a navigation: it is what `curl`, a
/// health check, a `<script src>` and most of `fetch()` send, so a missing
/// asset or a mistyped API path is a 404 naming it, never a page.
///
/// Nothing is read from the path. The extension test this replaced guessed
/// for the client that said nothing; that client now gets a 404, which is the
/// one answer it cannot mistake for success.
pub fn navigational(asked: Asked) bool {
    if (asked.fetch_mode) |mode| return std.ascii.eqlIgnoreCase(std.mem.trim(u8, mode, " \t"), "navigate");
    return accept_mod.asks(asked.accept, "text/html") == .named;
}

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
    /// on the wire (ADR 009).
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
        /// The same file as the build brotli-compressed it (`app.js.br`),
        /// read at load. Nilo has no encoder for it (decided.md), so this is
        /// only ever a file somebody else wrote. Null when there is none.
        br: ?[]const u8 = null,
        /// The ETag of `br`: its own, for the reason `gzip_etag` is.
        br_etag: []const u8 = &.{},
        /// `gzip` is a `.gz` out of an embedded tree, borrowed from the
        /// binary like `bytes` and not the Set's to free (ADR 273). Always
        /// false for one nilo compressed itself.
        gzip_borrowed: bool = false,

        /// Whether there is more than one representation to choose between,
        /// which is when `Vary: Accept-Encoding` is owed on every answer,
        /// the plain one and the 304 included.
        pub fn varies(self: Held) bool {
            return self.gzip != null or self.br != null;
        }
    };

    /// A precompressed file left on the disk beside a spilled one, the way
    /// the plain file is (ADR 273). Opened per request by the same rule.
    pub const Sibling = struct {
        /// Relative to the Set's directory, written by the walk.
        path: []const u8,
        size: u64,
        mtime_ns: i96,
    };

    /// Left on the disk and opened per request (ADR 009).
    ///
    /// There is no gzipped copy and there never will be: compression here
    /// happens once, while the App is being built (ADR 017), and a file
    /// that is not being held cannot be compressed once. Compressing it per
    /// request is the trade that was already refused for handler responses.
    /// A form the build wrote (`app.js.br` beside `app.js`) is not nilo's
    /// copy and is served from the disk (ADR 273).
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
        /// What the walk's `stat` said, and **not** what any response
        /// promises. A request describes the file from the descriptor it is
        /// about to send
        /// ([ADR 098](../docs/adr/098-a-file-is-described-by-the-descriptor-being-sent.md)),
        /// because a name is all this entry really holds and the file under
        /// that name is free to move while the server runs.
        ///
        /// Kept because it is what the load line reports and what the suite
        /// holds the two ETag writers to: the tag the walk wrote and the tag
        /// a request writes from an unchanged file have to be the same bytes,
        /// and these are the numbers that make that checkable.
        size: u64,
        /// The other half of that ETag. Kept as the number it came from
        /// rather than only as the hex inside the tag, so that anything
        /// comparing files later compares two integers instead of parsing a
        /// string back.
        mtime_ns: i96,
        /// `app.js.br` and `app.js.gz` beside a spilled `app.js`, found at
        /// load and opened per request when the client prefers them. A
        /// request describes them from their own descriptor like the file
        /// itself (ADR 098).
        br: ?Sibling = null,
        gzip: ?Sibling = null,

        pub fn varies(self: Spilled) bool {
            return self.br != null or self.gzip != null;
        }
    };

    /// Which bytes and which ETag to answer with. Kept together so the two
    /// cannot come apart: picking one representation and then tagging it
    /// with the other's ETag is the failure this whole pairing exists to
    /// make impossible.
    pub const Representation = struct {
        bytes: []const u8,
        etag: []const u8,
        coding: compress_mod.Coding,
    };

    /// The bytes and the ETag of a held file.
    ///
    /// Asking a spilled file is not a case to handle but a bug to hear
    /// about: it has no bytes, and its answer is written from a descriptor
    /// by `sendfile.send`. Callers branch on `contents` first — `App`'s
    /// `serveStaticFile` does it once, at the top.
    pub fn identity(self: *const File) Representation {
        return .{ .bytes = self.contents.held.bytes, .etag = self.etag, .coding = .identity };
    }

    /// The form in `coding` if the file has one, and the plain form
    /// otherwise.
    pub fn representation(self: *const File, coding: compress_mod.Coding) Representation {
        const held = self.contents.held;
        switch (coding) {
            .identity => {},
            .gzip => if (held.gzip) |g| return .{ .bytes = g, .etag = held.gzip_etag, .coding = .gzip },
            .br => if (held.br) |b| return .{ .bytes = b, .etag = held.br_etag, .coding = .br },
        }
        return self.identity();
    }
};

/// Everything one file allocated, in one place. `load` frees a half-built
/// list with this and `Set.deinit` frees a finished one, so a file that
/// grows an allocation cannot be freed on one path and leaked on the other.
///
/// `owns_bytes` is the Set's: a held file's bytes were read by `load` and
/// are the Set's to free, or were handed to `embed` out of the binary and
/// are nobody's to free. The gzipped copy and both ETags are always the
/// Set's own, whichever way the bytes arrived.
fn freeFile(gpa: std.mem.Allocator, f: File, owns_bytes: bool) void {
    gpa.free(f.url);
    gpa.free(f.etag);
    switch (f.contents) {
        .held => |held| {
            if (owns_bytes) gpa.free(held.bytes);
            if (held.gzip) |p| if (!held.gzip_borrowed) gpa.free(p);
            if (held.gzip_etag.len > 0) gpa.free(held.gzip_etag);
            // Only a directory has a `.br` it read itself: an embedded one is
            // the binary's, borrowed exactly as `bytes` is.
            if (held.br) |p| if (owns_bytes) gpa.free(p);
            if (held.br_etag.len > 0) gpa.free(held.br_etag);
        },
        // The descriptor belongs to the Set, not to the file that borrowed
        // it, so there is nothing here but the names.
        .spilled => |on_disk| {
            gpa.free(on_disk.path);
            if (on_disk.br) |b| gpa.free(b.path);
            if (on_disk.gzip) |g| gpa.free(g.path);
        },
    }
}

/// One directory, loaded. Owns every byte in it.
pub const Set = struct {
    gpa: std.mem.Allocator,
    prefix: []const u8,
    /// Sorted by url, so a lookup is a binary search rather than a walk.
    files: []File,
    fallback: ?*const File,
    /// Which requests `fallback` answers — `Options.spa_fallback_for`, kept
    /// here because the decision is per directory and `App` holds several.
    fallback_for: Options.Fallback = .navigations,
    index: []const u8,
    /// The directory itself, held open for as long as the App is, because a
    /// spilled file is opened relative to it on every request that asks for
    /// one. Opened by `load` before the socket is, which is what makes the
    /// name a request never chose the only name that ever reaches `openat`.
    ///
    /// Null for a Set that has no directory — `fromMemory`, which is bytes
    /// that were already here (ADR 016), and `embed`, which is bytes the
    /// binary carries (ADR 009). Neither can spill anything.
    dir: ?bulkhead.Dir = null,
    /// Whether a held file's bytes are this Set's to free. `load` and
    /// `fromMemory` read or copy them and own them; `embed` borrows them
    /// from the binary, where they cost nothing to keep and cannot be
    /// given back.
    owns_bytes: bool = true,
    /// What the walk saw of the tree, one number: every listed file's path,
    /// size, modification time and inode, summed, so that the order they were
    /// found in does not matter. A followed directory is reloaded when a
    /// fresh walk gives another one (ADR 277).
    fingerprint: u64 = 0,
    /// Set on the entry `App` keeps for a followed directory, whose own
    /// `files` are empty: the files are the follower's generations, and a
    /// request asks it for one (`Follower.acquire`).
    follower: ?*follow_mod.Follower = null,

    pub fn deinit(self: *Set) void {
        if (self.follower) |f| {
            self.follower = null;
            f.destroy();
        }
        for (self.files) |f| freeFile(self.gpa, f, self.owns_bytes);
        self.gpa.free(self.files);
        self.gpa.free(self.prefix);
        if (self.dir) |d| d.close();
        self.files = &.{};
        self.fallback = null;
        self.dir = null;
    }

    /// The file `path` actually names, or null if this set holds no such
    /// file.
    ///
    /// **The single-page fallback is not here**, and that is the seam
    /// ADR 087 moved: a lookup that answers with `index.html` for every
    /// path there is cannot tell a caller whether the file was found, so the
    /// caller could not decide anything about the miss. `fallbackFor` is the
    /// other half and the request decides which of the two it gets.
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

        return null;
    }

    /// The page this set answers a miss under its prefix with, if it has one
    /// and if this request is the kind it is for.
    ///
    /// `asked` is what the request said about itself. A set configured
    /// `.any_path` never reads it.
    pub fn fallbackFor(
        self: *const Set,
        path: []const u8,
        asked: Asked,
    ) ?*const File {
        const page = self.fallback orelse return null;
        if (!underPrefix(self.prefix, path)) return null;
        if (self.fallback_for == .any_path) return page;
        return if (navigational(asked)) page else null;
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

    /// The file whose URL is `url`, a request path as it was sent.
    ///
    /// **The table holds names as they are on disk and the request is still
    /// percent-encoded**: a browser asks for `café.png` as `/caf%C3%A9.png`
    /// and `My Doc.pdf` as `/My%20Doc.pdf`, and comparing the raw bytes made
    /// both a 404 to every browser. A path with a `%` in it is compared
    /// decoded, one byte at a time against each candidate, so nothing is
    /// allocated and no buffer is held on the connection's stack (ADR 062).
    /// A path without one, nearly every request, costs the one scan for the
    /// `%` and then the byte comparison it always had.
    ///
    /// Decoding is what could open a traversal, so a path whose decoded form
    /// holds a `/` that was escaped, a NUL, a backslash or a `.` or `..`
    /// segment, or whose escape is malformed, is no file (ADR 009). The table
    /// is searched rather than the disk, so nothing here could walk out of
    /// the tree; the refusal keeps that true if the lookup ever changes.
    fn lookup(self: *const Set, url: []const u8) ?*const File {
        const encoded = std.mem.indexOfScalar(u8, url, '%') != null;
        if (encoded and !decodedPathIsSafe(url)) return null;
        var lo: usize = 0;
        var hi: usize = self.files.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const order = if (encoded)
                orderDecoded(self.files[mid].url, url)
            else
                std.mem.order(u8, self.files[mid].url, url);
            switch (order) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return &self.files[mid],
            }
        }
        return null;
    }
};

/// One byte of a request path, decoded: what `raw[i..]` starts with, where
/// the next byte begins, and whether it came from a `%XX`. Null for a `%`
/// without two hex digits after it.
fn decodedAt(raw: []const u8, i: usize) ?struct { byte: u8, next: usize, escaped: bool } {
    if (raw[i] != '%') return .{ .byte = raw[i], .next = i + 1, .escaped = false };
    if (i + 2 >= raw.len) return null;
    const hi = std.fmt.charToDigit(raw[i + 1], 16) catch return null;
    const lo = std.fmt.charToDigit(raw[i + 2], 16) catch return null;
    return .{ .byte = hi << 4 | lo, .next = i + 3, .escaped = true };
}

/// Whether a request path with a `%` in it is one a file could be under,
/// decoded: every escape well formed, no `/`, NUL or backslash that an escape
/// produced, and no `.` or `..` segment however it was spelled (`%2e%2e`).
fn decodedPathIsSafe(raw: []const u8) bool {
    var i: usize = 0;
    var dots: usize = 0;
    var other = false;
    while (i < raw.len) {
        const d = decodedAt(raw, i) orelse return false;
        i = d.next;
        if (d.byte == 0 or d.byte == '\\') return false;
        if (d.byte == '/') {
            if (d.escaped) return false;
            if (!other and dots > 0 and dots <= 2) return false;
            dots = 0;
            other = false;
        } else if (d.byte == '.') {
            dots += 1;
        } else {
            other = true;
        }
    }
    return other or dots == 0 or dots > 2;
}

/// How `stored`, a URL as written from a name on disk, orders against
/// `raw`, a request path decoded as it is walked. Only for a path that
/// `decodedPathIsSafe` has passed, so every escape in it is well formed.
fn orderDecoded(stored: []const u8, raw: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < stored.len and j < raw.len) {
        const d = decodedAt(raw, j) orelse return .gt;
        const order = std.math.order(stored[i], d.byte);
        if (order != .eq) return order;
        i += 1;
        j = d.next;
    }
    if (i < stored.len) return .gt;
    return if (j < raw.len) .lt else .eq;
}

/// How many skipped symlinks `load` names in its one warning.
const max_named_links = 3;

/// The longest URL a file can have. Generous for a build output tree, and
/// bounded so a lookup never allocates.
pub const max_url = 512;

pub const LoadError = error{
    StaticDirNotFound,
    StaticSetTooLarge,
    StaticUrlTooLong,
    OutOfMemory,
    StaticReadFailed,
    /// Two entries handed to `embed` under one URL. A directory cannot
    /// hold two files by one name, so `load` never sees this; a list can.
    StaticDuplicateUrl,
};

/// Which of these failures `load` has already put into words, so `App` can
/// stop the process on them instead of letting the error reach `main` and
/// print a stack trace through nilo's own files on top of the answer
/// (ADR 001). The same rule `bulkhead.explained` states for `listen()`.
///
/// `OutOfMemory` is not on the list: nothing explained it, and there is
/// nothing useful to say about it that the error name does not.
pub fn explained(err: anyerror) bool {
    return switch (err) {
        error.StaticDirNotFound,
        error.StaticSetTooLarge,
        error.StaticUrlTooLong,
        error.StaticReadFailed,
        error.StaticDuplicateUrl,
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
/// What this is for is the generated API description (ADR 016), which is a
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

/// What `load` does about a directory that is not there: say so in one
/// line and hand the error back, or hand it back alone
/// ([ADR 207](../docs/adr/207-a-try-call-hands-back-the-error-and-says-nothing.md)).
///
/// `app.static` wants the line, because on it the process stops and the
/// line is the whole explanation. `app.tryStatic` exists so a program can
/// decide for itself (a backend that serves without its frontend built
/// is not a broken program), and a program that decided is one that
/// should not read `error:` in its own log for the case it handles. A
/// problem *inside* a directory that is there is still said either way:
/// the error name cannot carry which file, and the line can.
pub const Absent = enum { reported, returned };

/// Read `dir_path` into memory, mapping every file in it to a URL under
/// `url_prefix`. Called before `listen()`, so the blocking reads here
/// happen while nothing is being served.
///
/// A file over `options.max_file_bytes` is listed rather than read: it keeps
/// its place in the set with the path the walk produced, and the request
/// that asks for it opens it (ADR 009).
pub fn load(
    gpa: std.mem.Allocator,
    url_prefix: []const u8,
    dir_path: []const u8,
    options: Options,
    absent: Absent,
) LoadError!Set {
    // A throwaway blocking I/O instance, unrelated to the Engine that will
    // serve requests. Nothing from here survives into the request path,
    // which is exactly why static files need nothing from the Bulkhead.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return loadOn(threaded.io(), gpa, url_prefix, dir_path, options, absent);
}

/// Whether the calling thread is the one that reloads a followed directory
/// (ADR 277), where a directory that cannot be read is a warning and the old
/// one goes on being served, and not the line that says the server is about
/// to stop.
pub threadlocal var reloading: bool = false;

/// What `load` says of a problem with a directory that is there: an `err` at
/// startup, where the process is about to stop, and a `warn` on the thread
/// that reloads, where it is not and the zig test runner fails a run on any
/// `err` line.
fn complain(comptime fmt: []const u8, args: anytype) void {
    if (reloading) std.log.warn(fmt, args) else std.log.err(fmt, args);
}

/// `load` on an `Io` the caller owns, which is how the thread that follows a
/// directory reads it again without making one each time.
pub fn loadOn(
    io: std.Io,
    gpa: std.mem.Allocator,
    url_prefix: []const u8,
    dir_path: []const u8,
    options: Options,
    absent: Absent,
) LoadError!Set {
    std.debug.assert(url_prefix.len > 0 and url_prefix[0] == '/');

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        if (absent == .reported) complain(
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
    // walk the only name that ever reaches `openat` (ADR 009). One
    // descriptor per set, whether or not anything spilled today — the
    // alternative is a lazily opened directory on the request path and a
    // branch to go with it.
    const serving = bulkhead.Dir.open(dir_path) catch |err| {
        if (absent == .reported) complain(
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
        for (files.items) |f| freeFile(gpa, f, true);
        files.deinit(gpa);
    }

    var held_total: usize = 0;
    var packed_total: usize = 0;
    var sibling_total: usize = 0;
    var spilled_files: usize = 0;

    // `.reload` is the threshold set to zero and nothing else, so there is one
    // spill rule below rather than two (see `Options.reload`). Said out loud
    // at load, because a directory answering from the disk on every request is
    // not what anybody wants in production and the line is how they find out.
    const spill_over: usize = if (options.reload) 0 else options.max_file_bytes;
    if (options.reload and !reloading) {
        std.log.warn(
            "nilo: static directory \"{s}\" is serving every file from the disk (.reload) — " ++
                "an open, a stat and a read per request, and no gzipped copies. " ++
                "For development; take it out to serve from memory again.",
            .{dir_path},
        );
    }

    // Two passes, because what a file is depends on its neighbours: `app.js.br`
    // is a file of its own or the brotli form of `app.js`, and whether
    // `app.js` is then held or spilled decides how its form is kept (ADR 273).
    // The first only names and stats, which is all a spilled file ever gets.
    var walked: Walked = .{};
    defer walked.deinit(gpa);
    try walkTree(gpa, io, dir, dir_path, options, &walked);
    const found = &walked.found;
    set.fingerprint = fingerprintOf(found.items);

    var ignored: Ignored = .{};
    defer ignored.names.deinit(gpa);
    if (options.precompressed) try pairSiblings(gpa, found.items, &ignored);

    for (found.items) |f| {
        if (f.role != .plain) continue;

        var url_buf: [max_url]u8 = undefined;
        const url = join(&url_buf, url_prefix, f.path) orelse {
            complain("nilo: static file \"{s}\" has a path longer than {d} bytes", .{ f.path, max_url });
            return error.StaticUrlTooLong;
        };

        const content_type = contentTypeFor(url);

        if (f.size > spill_over) {
            // Over the line, so what goes in the list is where to find it
            // rather than what is in it (ADR 009). Nothing is added to
            // `held_total`: this file holds no memory to be counted.
            const relative = try gpa.dupe(u8, f.path);
            errdefer gpa.free(relative);
            const br = try spilledSibling(gpa, found.items, f.br);
            errdefer if (br) |b| gpa.free(b.path);
            const gzip_sibling = try spilledSibling(gpa, found.items, f.gzip);
            errdefer if (gzip_sibling) |g| gpa.free(g.path);

            try files.append(gpa, .{
                .url = try gpa.dupe(u8, url),
                .content_type = content_type,
                .etag = try etagForSpilled(gpa, f.mtime_ns, f.size),
                .cache_control = cacheControlFor(options.cache_rules, options.cache_control, f.path),
                .contents = .{ .spilled = .{
                    .dir = serving,
                    .path = relative,
                    .size = f.size,
                    .mtime_ns = f.mtime_ns,
                    .br = br,
                    .gzip = gzip_sibling,
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
        const bytes = try readHeld(gpa, io, dir, f.path, spill_over +| 1);
        errdefer gpa.free(bytes);

        held_total += bytes.len;
        try checkTotal(held_total, options.max_total_bytes, dir_path);

        // What the build compressed, read the same way. A sibling is smaller
        // than its file, which `pairSiblings` held it to, so it is under the
        // line whenever the file is.
        var br_bytes: ?[]const u8 = null;
        errdefer if (br_bytes) |p| gpa.free(p);
        if (f.br) |at| {
            br_bytes = try readHeld(gpa, io, dir, found.items[at].path, found.items[at].size +| 1);
            held_total += br_bytes.?.len;
            sibling_total += br_bytes.?.len;
            try checkTotal(held_total, options.max_total_bytes, dir_path);
        }

        var packed_bytes: ?[]const u8 = null;
        errdefer if (packed_bytes) |p| gpa.free(p);
        if (f.gzip) |at| {
            const sibling = try readHeld(gpa, io, dir, found.items[at].path, found.items[at].size +| 1);
            if (gzipMatches(sibling, bytes)) {
                packed_bytes = sibling;
                held_total += sibling.len;
                sibling_total += sibling.len;
                try checkTotal(held_total, options.max_total_bytes, dir_path);
            } else {
                gpa.free(sibling);
                try ignored.note(gpa, found.items[at].path, "its contents are not a gzip of the file beside it");
            }
        }
        const sibling_gzip = packed_bytes != null;
        if (!sibling_gzip and
            options.compress and
            bytes.len >= options.compress_min_bytes and
            compressible(content_type))
        {
            packed_bytes = try gzipped(gpa, bytes);
            if (packed_bytes) |p| {
                packed_total += p.len;
                held_total += p.len;
                try checkTotal(held_total, options.max_total_bytes, dir_path);
            }
        }

        try files.append(gpa, .{
            .url = try gpa.dupe(u8, url),
            .content_type = content_type,
            .etag = try etagFor(gpa, bytes),
            .cache_control = cacheControlFor(options.cache_rules, options.cache_control, f.path),
            .contents = .{ .held = .{
                .bytes = bytes,
                .gzip = packed_bytes,
                .gzip_etag = if (packed_bytes) |p| try etagFor(gpa, p) else &.{},
                .br = br_bytes,
                .br_etag = if (br_bytes) |p| try etagFor(gpa, p) else &.{},
            } },
        });
    }
    ignored.say(dir_path);

    if (walked.links > 0) std.log.warn(
        "nilo: static directory \"{s}\" holds {d} symlink(s) that are not served: {s}{s}. " ++
            "A link is never followed out of the tree (ADR 009); copy the file in to serve it.",
        .{ dir_path, walked.links, walked.link_names.items, if (walked.links > max_named_links) " and more" else "" },
    );

    // Handed over, so the list is empty and its `errdefer` above has nothing
    // left to free — from here the Set's own one covers all of it.
    set.files = try files.toOwnedSlice(gpa);
    sortByUrl(set.files);

    if (options.spa_fallback.len > 0) {
        var buf: [max_url]u8 = undefined;
        const url = join(&buf, url_prefix, options.spa_fallback) orelse {
            complain(
                "nilo: the SPA fallback URL \"{s}\" + \"{s}\" is longer than {d} bytes",
                .{ url_prefix, options.spa_fallback, max_url },
            );
            return error.StaticUrlTooLong;
        };
        set.fallback = set.lookup(url) orelse {
            complain(
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
        set.fallback_for = options.spa_fallback_for;
    }

    // Held bytes and spilled files are two different numbers and are said as
    // two, because the first one is what an operator multiplies against a
    // memory budget and the second one is not in that budget at all — it is
    // one descriptor each, and only while a response is being written.
    std.log.info(
        "nilo: {s} {d} static file(s) ({d} bytes held{f}{f}) from \"{s}\" onto \"{s}\"{f}{s}",
        .{
            if (reloading) "reloaded" else "loaded",
            set.files.len,
            held_total,
            GzipNote{ .bytes = packed_total },
            SiblingNote{ .bytes = sibling_total },
            dir_path,
            url_prefix,
            SpillNote{ .files = spilled_files, .over = options.max_file_bytes },
            if (walked.dotfiles > 0) " (dotfiles skipped)" else "",
        },
    );
    return set;
}

/// What the first pass of `load` collected: the files, and what it passed over.
const Walked = struct {
    found: std.ArrayList(Found) = .empty,
    /// Links the walk passed over, named once at the end: the first few and a
    /// count (ADR 009). A link is not a file the walk listed, so nothing is
    /// served for it and a reader of the directory would otherwise find out
    /// from a 404.
    links: usize = 0,
    link_names: std.ArrayList(u8) = .empty,
    dotfiles: usize = 0,

    fn deinit(self: *Walked, gpa: std.mem.Allocator) void {
        for (self.found.items) |f| gpa.free(f.path);
        self.found.deinit(gpa);
        self.link_names.deinit(gpa);
    }
};

/// The first pass, which only names and stats: what `load` builds from, and
/// all a followed directory's watcher needs to know whether anything changed.
fn walkTree(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    dir_path: []const u8,
    options: Options,
    walked: *Walked,
) LoadError!void {
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (walker.next(io) catch |err| {
        complain(
            "nilo: static directory \"{s}\" could not be walked ({s})",
            .{ dir_path, @errorName(err) },
        );
        return error.StaticReadFailed;
    }) |entry| {
        if (entry.kind == .sym_link) {
            walked.links += 1;
            if (walked.links <= max_named_links) {
                if (walked.link_names.items.len > 0) try walked.link_names.appendSlice(gpa, ", ");
                try walked.link_names.print(gpa, "\"{s}\"", .{entry.path});
            }
            continue;
        }
        if (entry.kind != .file) continue;
        if (!options.dotfiles and hasDotSegment(entry.path)) {
            walked.dotfiles += 1;
            continue;
        }

        // Asked before anything is read, which is the whole point: a file
        // over the line must not be read even once, or startup on a
        // directory of videos costs a pass over every one of them.
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| {
            complain("nilo: static file \"{s}\" could not be read ({s})", .{ entry.path, @errorName(err) });
            return error.StaticReadFailed;
        };
        const relative = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(relative);
        toForwardSlashes(relative);
        try walked.found.append(gpa, .{
            .path = relative,
            .size = stat.size,
            .mtime_ns = stat.mtime.nanoseconds,
            .inode = @intCast(stat.inode),
        });
    }
}

/// One number for what a walk found: a hash of each file's path, size,
/// modification time and inode, added together, so the order a directory
/// lists them in does not change it. A file replaced by a rename has a new
/// inode and one written in place a new modification time, and a file added
/// or removed is a term more or fewer (ADR 277).
fn fingerprintOf(found: []const Found) u64 {
    var sum: u64 = 0;
    for (found) |f| {
        var h = std.hash.Wyhash.init(0);
        h.update(f.path);
        h.update(std.mem.asBytes(&f.size));
        h.update(std.mem.asBytes(&f.mtime_ns));
        h.update(std.mem.asBytes(&f.inode));
        sum +%= h.final();
    }
    return sum;
}

/// The fingerprint of `dir_path` as it is now, without reading a file: the
/// follower's question each time something may have changed (ADR 277).
pub fn scan(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, options: Options) LoadError!u64 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.StaticDirNotFound;
    defer dir.close(io);
    var walked: Walked = .{};
    defer walked.deinit(gpa);
    try walkTree(gpa, io, dir, dir_path, options, &walked);
    return fingerprintOf(walked.found.items);
}

/// What the first pass of `load` knows about a file: where it is, how big,
/// when it changed, and what the pairing made of it (ADR 273).
const Found = struct {
    /// Relative to the directory, forward slashes, owned.
    path: []u8,
    size: u64,
    mtime_ns: i96,
    inode: u64 = 0,
    /// A plain file is listed. A `.br` or `.gz` that is the form of a file
    /// beside it is not, whether or not it turned out usable.
    role: Role = .plain,
    /// For a plain file: the index in the same list of its forms.
    br: ?usize = null,
    gzip: ?usize = null,

    const Role = enum { plain, br, gzip };
};

fn lessByPath(_: void, a: Found, b: Found) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

/// The coding a name says it is, and the name of the file it would be the
/// form of: `("app.js.br")` is `(.br, "app.js")`.
fn siblingOf(path: []const u8) ?struct { coding: compress_mod.Coding, base: []const u8 } {
    if (std.mem.endsWith(u8, path, ".br")) return .{ .coding = .br, .base = path[0 .. path.len - 3] };
    if (std.mem.endsWith(u8, path, ".gz")) return .{ .coding = .gzip, .base = path[0 .. path.len - 3] };
    return null;
}

/// The siblings `load` found and did not use, named once (ADR 273). A sibling
/// is consumed by the file it sits beside even when it cannot be served, so
/// that the rule a reader has to know is one sentence; this is how they hear
/// that one was passed over.
const Ignored = struct {
    count: usize = 0,
    names: std.ArrayList(u8) = .empty,

    fn note(self: *Ignored, gpa: std.mem.Allocator, path: []const u8, why: []const u8) !void {
        self.count += 1;
        if (self.count > max_named_links) return;
        if (self.names.items.len > 0) try self.names.appendSlice(gpa, "; ");
        try self.names.print(gpa, "\"{s}\" ({s})", .{ path, why });
    }

    fn say(self: *const Ignored, dir_path: []const u8) void {
        if (self.count == 0) return;
        std.log.warn(
            "nilo: static directory \"{s}\" holds {d} precompressed file(s) that are not served: {s}{s}. " ++
                "A .br or .gz beside its file is never served under its own name (ADR 273); " ++
                "rebuild it, or pass .precompressed = false.",
            .{ dir_path, self.count, self.names.items, if (self.count > max_named_links) " and more" else "" },
        );
    }
};

/// Match every `X.br` and `X.gz` in `found` (sorted here by path) with the
/// `X` beside it, when `X` is a type worth compressing, and mark it a sibling
/// of `X`. One that cannot be used, because it is not smaller than `X` or is
/// a `.br` older than it, is marked all the same and `ignored` says so; the
/// contents of a `.gz` are checked once its bytes are read.
fn pairSiblings(gpa: std.mem.Allocator, found: []Found, ignored: *Ignored) !void {
    std.sort.pdq(Found, found, {}, lessByPath);
    for (found, 0..) |*f, at| {
        const named = siblingOf(f.path) orelse continue;
        const base = baseIndex(found, named.base) orelse continue;
        if (!compressible(contentTypeFor(named.base))) continue;
        f.role = if (named.coding == .br) .br else .gzip;

        const plain = &found[base];
        if (f.size == 0 or f.size >= plain.size) {
            try ignored.note(gpa, f.path, "not smaller than the file beside it");
            continue;
        }
        // Make's rule, for the form with nothing else to check it by. A build
        // writes the file and then its forms, so a `.br` older than the file
        // was left by an earlier build. A `.gz` is not held to it: its trailer
        // says exactly which bytes it compresses, and `load` checks that
        // against the file once both are read, so a `.gz` written before its
        // file (a deploy that copies in either order, a checkout, `cp -p`) is
        // used when it is the file's and ignored when it is not (ADR 273).
        if (named.coding == .br and f.mtime_ns < plain.mtime_ns) {
            try ignored.note(gpa, f.path, "older than the file beside it");
            continue;
        }
        switch (named.coding) {
            .br => plain.br = at,
            .gzip => plain.gzip = at,
            .identity => unreachable,
        }
    }
}

fn baseIndex(sorted: []const Found, path: []const u8) ?usize {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, sorted[mid].path, path)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return mid,
        }
    }
    return null;
}

/// A precompressed file for a spilled one: where to open it, copied.
fn spilledSibling(gpa: std.mem.Allocator, found: []const Found, at: ?usize) !?File.Sibling {
    const index = at orelse return null;
    return .{
        .path = try gpa.dupe(u8, found[index].path),
        .size = found[index].size,
        .mtime_ns = found[index].mtime_ns,
    };
}

fn readHeld(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, limit: u64) LoadError![]u8 {
    return dir.readFileAlloc(io, path, gpa, .limited64(limit)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        complain("nilo: static file \"{s}\" could not be read ({s})", .{ path, @errorName(err) });
        return error.StaticReadFailed;
    };
}

fn checkTotal(held_total: usize, max_total_bytes: usize, dir_path: []const u8) LoadError!void {
    if (held_total <= max_total_bytes) return;
    complain(
        "nilo: static directory \"{s}\" is over the {d} byte total limit, " ++
            "gzipped and precompressed copies counted — raise .max_total_bytes, " ++
            "or pass .compress = false",
        .{ dir_path, max_total_bytes },
    );
    return error.StaticSetTooLarge;
}

/// Whether `gz` is a gzip of exactly `plain`: the magic, and the CRC-32 and
/// the length mod 2^32 its last eight bytes carry. This is what makes a stale
/// `.gz` detectable, which brotli's format has no equivalent of (ADR 273).
pub fn gzipMatches(gz: []const u8, plain: []const u8) bool {
    if (gz.len < 18 or gz[0] != 0x1f or gz[1] != 0x8b) return false;
    const crc = std.mem.readInt(u32, gz[gz.len - 8 ..][0..4], .little);
    const size = std.mem.readInt(u32, gz[gz.len - 4 ..][0..4], .little);
    return size == @as(u32, @truncate(plain.len)) and crc == std.hash.Crc32.hash(plain);
}

/// One file the binary carries, for `embed`.
///
/// ```zig
/// try app.embedded("/", &.{
///     .{ .path = "index.html", .bytes = @embedFile("dist/index.html") },
///     .{ .path = "assets/app.js", .bytes = @embedFile("dist/assets/app.js") },
/// });
/// ```
///
/// `@embedFile` has to be written by the caller: its path is relative to
/// the file it is written in and the file has to be inside that module, so
/// nothing in nilo can name a caller's `dist/`. The list is the whole of
/// what the caller writes, or `embedDir` in nilo's `build.zig` writes it from
/// a directory (ADR 009).
pub const Embedded = struct {
    /// Where the file sits in the tree, relative and with forward slashes:
    /// `"index.html"`, `"assets/app.js"`. Joined onto the URL prefix the
    /// way a directory walk's path is.
    path: []const u8,
    /// The file. Borrowed for as long as the App lives and never freed,
    /// which is what bytes in the binary are.
    bytes: []const u8,
};

/// What `embed` takes: `Options`, less every field that is about a disk.
///
/// A file in the binary cannot spill, so there is no threshold to set and
/// no total to stay under — the bytes are mapped whether or not a Set names
/// them, and `max_total_bytes` would be counting memory that is not spent
/// twice. `dotfiles` is the walk's rule about names it found; here every
/// name was written by the caller. `reload` is the disk. What is left is
/// what the request sees, with the same defaults, taken from `Options` so
/// there is one place they are written.
pub const EmbedOptions = struct {
    index: []const u8 = (Options{}).index,
    cache_control: []const u8 = (Options{}).cache_control,
    cache_rules: []const CacheRule = (Options{}).cache_rules,
    spa_fallback: []const u8 = (Options{}).spa_fallback,
    spa_fallback_for: Options.Fallback = (Options{}).spa_fallback_for,
    compress: bool = (Options{}).compress,
    compress_min_bytes: usize = (Options{}).compress_min_bytes,
    precompressed: bool = (Options{}).precompressed,
};

/// A Set over bytes the binary carries, mapped to URLs under `url_prefix`
/// (ADR 009).
///
/// Everything past this call is the path `load` built: the same sorted list,
/// the same lookup, an ETag per file, a gzipped copy made once for the files
/// worth it, the SPA fallback, and nothing per request. What differs is where
/// the bytes come from — they are borrowed rather than read, so the Set owns
/// the ETags and the gzipped copies and not the files — and what cannot
/// happen: nothing spills, and nothing is over any limit, because the binary
/// already holds it.
///
/// Two things a directory walk could not produce are refused here. Two
/// entries under one URL is `error.StaticDuplicateUrl` naming the URL, and a
/// fallback that names no entry is `error.StaticDirNotFound`, both said in
/// one line the way `load`'s failures are.
pub fn embed(
    gpa: std.mem.Allocator,
    url_prefix: []const u8,
    files: []const Embedded,
    options: EmbedOptions,
) LoadError!Set {
    std.debug.assert(url_prefix.len > 0 and url_prefix[0] == '/');

    var set = Set{
        .gpa = gpa,
        .prefix = &.{},
        .files = &.{},
        .fallback = null,
        .index = options.index,
        .owns_bytes = false,
    };
    errdefer set.deinit();
    set.prefix = try gpa.dupe(u8, url_prefix);

    // Which entries are the forms of which, before anything is allocated for
    // the files, so that the list is the size of what is served (ADR 273).
    const forms = try gpa.alloc(EmbeddedForms, files.len);
    defer gpa.free(forms);
    @memset(forms, .{});
    var consumed: usize = 0;
    var ignored: Ignored = .{};
    defer ignored.names.deinit(gpa);
    if (options.precompressed) {
        for (files, 0..) |entry, at| {
            const named = siblingOf(entry.path) orelse continue;
            if (!compressible(contentTypeFor(named.base))) continue;
            const base = for (files, 0..) |other, j| {
                if (std.mem.eql(u8, other.path, named.base)) break j;
            } else continue;
            forms[at].consumed = true;
            consumed += 1;
            if (entry.bytes.len == 0 or entry.bytes.len >= files[base].bytes.len) {
                try ignored.note(gpa, entry.path, "not smaller than the file beside it");
            } else if (named.coding == .gzip and !gzipMatches(entry.bytes, files[base].bytes)) {
                try ignored.note(gpa, entry.path, "its contents are not a gzip of the file beside it");
            } else switch (named.coding) {
                .br => forms[base].br = at,
                .gzip => forms[base].gzip = at,
                .identity => unreachable,
            }
        }
        ignored.say("the embedded tree");
    }

    set.files = try gpa.alloc(File, files.len - consumed);
    // Emptied before anything can fail, for the reason `fromMemory` does it:
    // `deinit` on the way out of a half-built Set frees what exists and steps
    // over what does not.
    for (set.files) |*file| file.* = .{
        .url = &.{},
        .etag = &.{},
        .content_type = "",
        .cache_control = "",
        .contents = .{ .held = .{ .bytes = &.{} } },
    };

    var carried_total: usize = 0;
    var packed_total: usize = 0;
    var next: usize = 0;

    for (files, forms) |entry, form| {
        if (form.consumed) continue;
        const file = &set.files[next];
        next += 1;

        var url_buf: [max_url]u8 = undefined;
        const url = join(&url_buf, url_prefix, entry.path) orelse {
            std.log.err("nilo: embedded file \"{s}\" has a path longer than {d} bytes", .{ entry.path, max_url });
            return error.StaticUrlTooLong;
        };
        toForwardSlashes(url);

        file.url = try gpa.dupe(u8, url);
        file.content_type = contentTypeFor(url);
        file.cache_control = cacheControlFor(options.cache_rules, options.cache_control, entry.path);
        file.etag = try etagFor(gpa, entry.bytes);

        const held = &file.contents.held;
        held.bytes = entry.bytes;
        carried_total += entry.bytes.len;
        // The binary carries these already, so they are borrowed, and only
        // their tags are the Set's (ADR 273).
        if (form.br) |at| {
            held.br = files[at].bytes;
            held.br_etag = try etagFor(gpa, files[at].bytes);
        }
        if (form.gzip) |at| {
            held.gzip = files[at].bytes;
            held.gzip_borrowed = true;
            held.gzip_etag = try etagFor(gpa, files[at].bytes);
        } else if (options.compress and
            entry.bytes.len >= options.compress_min_bytes and
            compressible(file.content_type))
        {
            held.gzip = try gzipped(gpa, entry.bytes);
            if (held.gzip) |p| {
                held.gzip_etag = try etagFor(gpa, p);
                packed_total += p.len;
            }
        }
    }

    sortByUrl(set.files);

    if (listedTwice(set.files)) |url| {
        std.log.err("nilo: embedded file \"{s}\" is listed twice", .{url});
        return error.StaticDuplicateUrl;
    }

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
                "nilo: the SPA fallback \"{s}\" is not among the embedded files — " ++
                    "the name is relative to the tree, e.g. \"index.html\"",
                .{options.spa_fallback},
            );
            return error.StaticDirNotFound;
        };
        set.fallback_for = options.spa_fallback_for;
    }

    // Two numbers again, and different ones from `load`'s: the first is what
    // the binary carries and costs nothing more to serve, the second is what
    // this call allocated and is the only memory the Set adds.
    std.log.info(
        "nilo: embedded {d} static file(s) ({d} bytes in the binary{f}) onto \"{s}\"",
        .{ set.files.len, carried_total, EmbedGzipNote{ .bytes = packed_total }, url_prefix },
    );
    return set;
}

/// What `embed` worked out about one entry before building the list: whether
/// it is the form of another entry, and for a plain one the entries that are
/// its forms.
const EmbeddedForms = struct {
    consumed: bool = false,
    br: ?usize = null,
    gzip: ?usize = null,
};

/// The URL that appears twice in a list sorted by URL, or null when every
/// one is its own. A directory cannot hold two files by one name and a
/// list can, and the second entry would then be unreachable forever,
/// quietly — the binary search stops at whichever of the two it finds.
/// Sorted, so a repeat is beside itself and this is one pass.
fn listedTwice(sorted: []const File) ?[]const u8 {
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        if (std.mem.eql(u8, sorted[i - 1].url, sorted[i].url)) return sorted[i].url;
    }
    return null;
}

/// The gzip half of `embed`'s line, on `GzipNote`'s terms — and worded so
/// the number is read as memory allocated beside the binary rather than as
/// part of what the binary carries.
const EmbedGzipNote = struct {
    bytes: usize,

    pub fn format(self: EmbedGzipNote, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.bytes == 0) return;
        try w.print(", plus {d} bytes of gzipped copies allocated", .{self.bytes});
    }
};

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

/// The precompressed half of the load line: bytes read from `.br` and `.gz`
/// files the build wrote, which are held beside the plain file like the copy
/// nilo makes (ADR 273). Absent when there were none.
const SiblingNote = struct {
    bytes: usize,

    pub fn format(self: SiblingNote, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.bytes == 0) return;
        try w.print(", {d} of them precompressed files", .{self.bytes});
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
/// binary, before anybody wrote any JSON ([ADR 016](../docs/adr/016-the-api-description-comes-from-the-signatures.md)).
fn sortByUrl(files: []File) void {
    std.sort.pdq(File, files, {}, lessByUrl);
}

/// Whether `path` sits under `prefix`, on a segment boundary — so a
/// prefix of `/app` covers `/app/x` but not `/apple`.
pub fn underPrefix(prefix: []const u8, path: []const u8) bool {
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
pub fn hasDotSegment(rel_path: []const u8) bool {
    var start: usize = 0;
    for (rel_path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') {
            if (i > start and rel_path[start] == '.') return true;
            start = i + 1;
        }
    }
    return rel_path.len > start and rel_path[start] == '.';
}

/// What a file has to be for a gzipped copy to be worth holding: the same
/// question response compression asks of a body, per request, so the
/// answer lives there (ADR 211). `serve.zig` asks the other half, whether
/// the client takes gzip, of the same module.
const compressible = compress_mod.compressible;

/// Gzip `bytes`, or null if the result is not smaller than what went in.
/// A file that does not shrink is a file served as it is: keeping the copy
/// would cost memory to send more bytes than the original.
///
/// Whatever the compressor needs lives for the length of this call and is
/// gone before the server starts. That is the whole reason compression can
/// be here at all and not on the request path. Which compressor is the
/// build's, through `compress.gzipOnce`, so a build with libdeflate in it
/// does not carry the standard library's for this alone (ADR 248).
fn gzipped(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!?[]const u8 {
    return compress_mod.gzipOnce(gpa, bytes);
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
/// taking by default for twenty years (ADR 009).
///
/// The time goes through `@bitCast` rather than a cast that could fail: a
/// clock is allowed to say anything, including a negative number, and a
/// panic while loading a directory is not the way to find that out.
fn etagForSpilled(gpa: std.mem.Allocator, mtime_ns: i96, size: u64) ![]const u8 {
    var buf: [max_spilled_etag]u8 = undefined;
    return gpa.dupe(u8, spilledEtag(&buf, mtime_ns, size));
}

/// The longest `spilledEtag` can write: two quotes, a dash, 24 hex digits of
/// a u96 and 16 of a u64.
pub const max_spilled_etag = 2 + 1 + 24 + 16 + 3;

/// The same tag, written into a caller's buffer instead of an allocation.
///
/// **The two callers are the two moments a spilled file is described**, and
/// they have to agree to the byte or a client's `If-None-Match` stops
/// matching a file that never changed: the directory walk writes one at load,
/// and `serveSpilledFile` writes one per request from a fresh look at the
/// descriptor ([ADR 098](../docs/adr/098-a-file-is-described-by-the-descriptor-being-sent.md)).
/// Sharing the format string is not tidiness — it is the only reason those
/// two are the same tag rather than two spellings of one idea.
///
/// The request-path caller writes into its own stack frame, so this costs no
/// allocation on a path whose budget is one ([ADR 017](../docs/adr/017-the-trade-budget-has-four-axes.md)).
pub fn spilledEtag(buf: *[max_spilled_etag]u8, mtime_ns: i96, size: u64) []const u8 {
    // Cannot overflow: `max_spilled_etag` is what the widest pair of numbers
    // comes to, so the only way past it is a wider integer type.
    return std.fmt.bufPrint(buf, "\"{x}-{x}\"", .{ @as(u96, @bitCast(mtime_ns)), size }) catch unreachable;
}

/// The tag of a precompressed file left on the disk: its own modification
/// time and size, and the coding after them (`"1a2b-ff-br"`).
///
/// The suffix is not decoration. A representation has its own tag (ADR 273),
/// and two files sharing a nanosecond and a length is as unlikely for a build
/// that wrote them side by side as for any pair, but "unlikely" is not the
/// property a cache is owed: with the coding in the tag the plain file's and
/// the sibling's cannot be equal.
pub fn spilledEtagCoded(
    buf: *[max_spilled_etag]u8,
    mtime_ns: i96,
    size: u64,
    coding: compress_mod.Coding,
) []const u8 {
    const suffix = switch (coding) {
        .identity => "",
        .gzip => "-gz",
        .br => "-br",
    };
    return std.fmt.bufPrint(buf, "\"{x}-{x}{s}\"", .{ @as(u96, @bitCast(mtime_ns)), size, suffix }) catch unreachable;
}

/// Whether an `If-None-Match` header matches `etag`. Handles the `*`
/// wildcard, a comma-separated list, and the `W/` weak marker — all three
/// turn up in the wild and none of them is worth a 200 with a full body.
///
/// **Not for `If-Range`**, which needs `etagMatchesStrong` below. The two
/// comparisons are different on purpose and RFC 9110 says which goes where.
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

/// Whether an `If-Range` header matches `etag`, by the **strong** comparison
/// RFC 9110 §13.1.5 requires there (ADR 073).
///
/// Three differences from `etagMatches`, each of them the difference between
/// resuming a download and corrupting one. **A `W/` tag never matches** — a
/// weak validator does not promise byte for byte, which is the claim a resumed
/// download acts on. **`*` never matches**, or a bare `*` stands in for a
/// comparison that never happened. **A single tag, not a list**: `If-Range`
/// carries one validator where `If-None-Match` carries a list.
///
/// An empty `etag` matches nothing, so a file with no tag takes the safe
/// answer without its caller having to remember to check.
pub fn etagMatchesStrong(if_range: []const u8, etag: []const u8) bool {
    if (etag.len == 0) return false;
    return std.mem.eql(u8, std.mem.trim(u8, if_range, " \t"), etag);
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

test "If-Range: only the same tag, spelled the same way, resumes a download" {
    try testing.expect(etagMatchesStrong("\"abc\"", "\"abc\""));
    try testing.expect(etagMatchesStrong("  \"abc\" ", "\"abc\""));

    // The three `If-None-Match` accepts and `If-Range` must not. Each of them
    // is a client being handed bytes to staple onto a prefix of a file that
    // may have moved on underneath it.
    try testing.expect(!etagMatchesStrong("W/\"abc\"", "\"abc\""));
    try testing.expect(!etagMatchesStrong("*", "\"abc\""));
    try testing.expect(!etagMatchesStrong("\"other\", \"abc\"", "\"abc\""));

    try testing.expect(!etagMatchesStrong("\"other\"", "\"abc\""));
    try testing.expect(!etagMatchesStrong("", "\"abc\""));
    // A file with no tag has nothing to compare, so nothing matches it — not
    // even the empty header, and not `*`.
    try testing.expect(!etagMatchesStrong("*", ""));
    try testing.expect(!etagMatchesStrong("", ""));
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
    try testing.expect(set.find("/users/42") == null);
    try testing.expectEqualStrings("/index.html", set.fallbackFor("/users/42", browser).?.url);
}

const browser: Asked = .{
    .accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    .fetch_mode = "navigate",
};
const old_browser: Asked = .{ .accept = "text/html,application/xhtml+xml,*/*;q=0.8" };
const script: Asked = .{ .accept = "*/*", .fetch_mode = "no-cors" };
const fetch_any: Asked = .{ .accept = "*/*", .fetch_mode = "cors" };

test "a fallback answers a page a browser asked for and not an asset that is gone" {
    var set = try fakeSet(testing.allocator, "/", &.{ "/index.html", "/app.js" });
    defer set.deinit();
    set.fallback = set.lookup("/index.html").?;

    // The whole point: a stale build hash is a 404 naming the file rather
    // than a page a parser then reports a syntax error on (ADR 087). A
    // `<script src>` is the request that fetches one, and it says `*/*`.
    try testing.expect(set.fallbackFor("/app.abc123.js", script) == null);
    // Nor is a JSON call to a path that is not a route a page.
    try testing.expect(set.fallbackFor("/api/orders", .{ .accept = "application/json", .fetch_mode = "cors" }) == null);

    // Somebody typing that same URL into the address bar is a different
    // request and gets the page: it is a navigation and there is a page.
    try testing.expectEqualStrings("/index.html", set.fallbackFor("/app.abc123.js", browser).?.url);
    try testing.expectEqualStrings("/index.html", set.fallbackFor("/users/42", browser).?.url);

    // And nothing outside the prefix is this set's business either way.
    var under = try fakeSet(testing.allocator, "/app", &.{"/app/index.html"});
    defer under.deinit();
    under.fallback = under.lookup("/app/index.html").?;
    try testing.expect(under.fallbackFor("/other/42", browser) == null);
}

test "a fetch or a curl that accepts anything is not a navigation, whatever the path looks like" {
    var set = try fakeSet(testing.allocator, "/", &.{ "/index.html", "/app.js" });
    defer set.deinit();
    set.fallback = set.lookup("/index.html").?;

    // The bug this rule exists for: `fetch('/api/nope')` sends `*/*` and used
    // to receive the page with a 200, so a typo looked like success.
    try testing.expect(set.fallbackFor("/api/nope", fetch_any) == null);
    try testing.expect(set.fallbackFor("/api/nope", .{ .accept = "*/*" }) == null);
    try testing.expect(set.fallbackFor("/users/42", .{}) == null);
}

test "the fetch metadata decides when the browser sent it, and Accept decides when it did not" {
    // Sent, and it wins in both directions.
    try testing.expect(navigational(.{ .fetch_mode = "navigate" }));
    try testing.expect(navigational(.{ .fetch_mode = "Navigate", .accept = "*/*" }));
    try testing.expect(!navigational(.{ .fetch_mode = "cors", .accept = "text/html" }));
    try testing.expect(!navigational(.{ .fetch_mode = "no-cors", .accept = "text/html,*/*" }));
    try testing.expect(!navigational(.{ .fetch_mode = "same-origin" }));
    try testing.expect(!navigational(.{ .fetch_mode = "websocket" }));

    // Not sent: a client that lists HTML by name is opening a page.
    try testing.expect(navigational(old_browser));
    try testing.expect(navigational(.{ .accept = "text/html" }));
    // `*/*` alone, no header at all, and a refusal are none of them one.
    try testing.expect(!navigational(.{ .accept = "*/*" }));
    try testing.expect(!navigational(.{}));
    try testing.expect(!navigational(.{ .accept = "application/json" }));
    try testing.expect(!navigational(.{ .accept = "text/html;q=0, */*" }));
}

test "a set told to answer any path does what it did through 0.2.0" {
    var set = try fakeSet(testing.allocator, "/", &.{ "/index.html", "/app.js" });
    defer set.deinit();
    set.fallback = set.lookup("/index.html").?;
    set.fallback_for = .any_path;

    try testing.expectEqualStrings("/index.html", set.fallbackFor("/app.abc123.js", script).?.url);
    try testing.expectEqualStrings("/index.html", set.fallbackFor("/api/orders", fetch_any).?.url);
}

// ---- gzip, done once when the App is built ----

test "a gzipped copy is smaller, and inflates back to exactly the original" {
    const gpa = testing.allocator;
    // Repetitive enough to compress, which is what a real stylesheet is.
    const original = repeat("body { margin: 0; padding: 0; } ", 64);

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
    const html = repeat("<!doctype html><title>hello</title>", 64);

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

    const plain = file.representation(.identity);
    try testing.expect(plain.coding == .identity);
    try testing.expectEqualStrings(html, plain.bytes);
    try testing.expectEqualStrings(file.etag, plain.etag);

    const squeezed = file.representation(.gzip);
    try testing.expect(squeezed.coding == .gzip);
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
    try testing.expect(file.representation(.gzip).coding == .identity);
    try testing.expectEqualStrings("no", file.representation(.gzip).bytes);
}

// ---- a file too big to hold (ADR 009) ----

const App = @import("app.zig").App;
const nilo_testing = @import("testing.zig");
const wiring = @import("wiring.zig");

/// A directory of real files, written for one test and removed after it.
/// The path is relative to the working directory, which is what `load` and
/// `app.static` both take.
const TmpTree = struct {
    tmp: nilo_testing.TmpDir,
    path: [:0]u8,

    fn init(gpa: std.mem.Allocator, files: []const [2][]const u8) !TmpTree {
        var tmp = nilo_testing.tmpDir();
        errdefer tmp.cleanup();
        for (files) |entry| {
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = entry[0], .data = entry[1] });
        }
        return .{
            .tmp = tmp,
            .path = try tmp.pathAlloc(gpa, ""),
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
    const big = repeat("the quick brown fox jumps over the lazy dog. ", 8);
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
    }, .reported);
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
    var all_held = try load(gpa, "/", tree.path, .{ .compress_min_bytes = 16 }, .reported);
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

    var first = try load(gpa, "/", tree.path, .{ .max_file_bytes = 4 }, .reported);
    // Freed before the second load, so the two ETags are compared as copies
    // rather than as pointers into a Set that has been thrown away.
    var etag_buf: [64]u8 = undefined;
    const before = etag_buf[0..first.find("/video.mp4").?.etag.len];
    @memcpy(before, first.find("/video.mp4").?.etag);
    first.deinit();

    // Rewritten: different contents, a different length, and a modification
    // time the filesystem moved.
    try tree.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "video.mp4", .data = "abcdefghijkl" });

    var second = try load(gpa, "/", tree.path, .{ .max_file_bytes = 4 }, .reported);
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
    // (ADR 017). No `Vary` either: there is only one representation.
    const asked = try client.send(
        &app,
        "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 200), asked.status);
    try testing.expect(asked.header("Content-Encoding") == null);
    try testing.expect(asked.header("Vary") == null);
    try testing.expectEqualStrings(alphabet, asked.body);

    // Part of it, from the middle, without the rest being read.
    const part = try client.send(&app, "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=3-5\r\n\r\n");
    try testing.expectEqual(@as(u16, 206), part.status);
    try testing.expectEqualStrings("bytes 3-5/26", part.header("Content-Range").?);
    try testing.expectEqualStrings("def", part.body);

    // A resumed download, held to the file it started with by the tag it was
    // given — which is why that tag has to be strong (ADR 009).
    var request_buf: [256]u8 = undefined;
    const resumed = try client.send(&app, try std.fmt.bufPrint(
        &request_buf,
        "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=20-\r\nIf-Range: {s}\r\n\r\n",
        .{etag},
    ));
    try testing.expectEqual(@as(u16, 206), resumed.status);
    try testing.expectEqualStrings("uvwxyz", resumed.body);

    // And a repeat visitor: a comparison and a head, no body and no disk.
    const conditional = try client.send(&app, try std.fmt.bufPrint(
        &request_buf,
        "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nIf-None-Match: {s}\r\n\r\n",
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
            "GET /a.bin HTTP/1.1\r\nHost: t\r\nRange: bytes=20-\r\nIf-Range: {s}\r\n\r\n",
            .{etag},
        ));
        try testing.expectEqual(@as(u16, 206), resumed.status);
        try testing.expectEqualStrings("bytes 20-25/26", resumed.header("Content-Range").?);
        try testing.expectEqualStrings("uvwxyz", resumed.body);

        // The file the client started with is gone, so byte 20 of this one is
        // not the byte it wanted: all of it, and no `Content-Range` (ADR 020).
        const stale = try client.send(
            &app,
            "GET /a.bin HTTP/1.1\r\nHost: t\r\nRange: bytes=20-\r\nIf-Range: \"gone\"\r\n\r\n",
        );
        try testing.expectEqual(@as(u16, 200), stale.status);
        try testing.expectEqualStrings(alphabet, stale.body);
        try testing.expect(stale.header("Content-Range") == null);

        // `If-Range` is the one comparison RFC 9110 §13.1.5 says must be
        // strong, and these are the two shapes `If-None-Match`'s comparison
        // accepts (ADR 073). Both get the whole file rather than a range,
        // because "close enough to reuse" is not "the same bytes you already
        // hold the front of". The weak one carries this file's real tag, so
        // only the `W/` decides it.
        const weak = try client.send(&app, try std.fmt.bufPrint(
            &request_buf,
            "GET /a.bin HTTP/1.1\r\nHost: t\r\nRange: bytes=20-\r\nIf-Range: W/{s}\r\n\r\n",
            .{etag},
        ));
        try testing.expectEqual(@as(u16, 200), weak.status);
        try testing.expectEqualStrings(alphabet, weak.body);
        try testing.expect(weak.header("Content-Range") == null);

        const wildcard = try client.send(
            &app,
            "GET /a.bin HTTP/1.1\r\nHost: t\r\nRange: bytes=20-\r\nIf-Range: *\r\n\r\n",
        );
        try testing.expectEqual(@as(u16, 200), wildcard.status);
        try testing.expectEqualStrings(alphabet, wildcard.body);
        try testing.expect(wildcard.header("Content-Range") == null);

        // And the tag still works when it is the only thing in the header, so
        // the strong comparison did not simply refuse everything.
        const still_resumes = try client.send(&app, try std.fmt.bufPrint(
            &request_buf,
            "GET /a.bin HTTP/1.1\r\nHost: t\r\nRange: bytes=24-\r\nIf-Range: {s}\r\n\r\n",
            .{etag},
        ));
        try testing.expectEqual(@as(u16, 206), still_resumes.status);
        try testing.expectEqualStrings("yz", still_resumes.body);

        // Past the end says how big it really is, on both sides.
        const past = try client.send(&app, "GET /a.bin HTTP/1.1\r\nHost: t\r\nRange: bytes=99-\r\n\r\n");
        try testing.expectEqual(@as(u16, 416), past.status);
        try testing.expectEqualStrings("bytes */26", past.header("Content-Range").?);
    }
}

test "a spilled file that grew on disk goes out whole, under a tag that moved with it" {
    // The bug this is here for: the walk recorded a size and an ETag, the
    // request wrote both into the head, and the bytes came from a file that
    // had moved on. What went out was a complete, correct-looking response
    // carrying a prefix of the new file under the old file's tag — and a
    // client holding that tag was then told 304 for content that had changed
    // (ADR 098).
    const gpa = testing.allocator;
    var tree = try TmpTree.init(gpa, &.{.{ "app.js", "0123456789" }});
    defer tree.deinit(gpa);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStaticWith("/", tree.path, .{ .max_file_bytes = 4 });

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    const before = try client.get(&app, "/app.js");
    try testing.expectEqual(@as(u16, 200), before.status);
    try testing.expectEqualStrings("0123456789", before.body);
    var etag_buf: [max_spilled_etag]u8 = undefined;
    const old_etag = etag_buf[0..before.header("ETag").?.len];
    @memcpy(old_etag, before.header("ETag").?);

    // The same name, longer contents — a rebuilt asset, which is the whole
    // reason this file was left on the disk in the first place.
    const grown = "0123456789abcdefghij";
    try tree.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app.js", .data = grown });

    const after = try client.get(&app, "/app.js");
    try testing.expectEqual(@as(u16, 200), after.status);
    // All twenty bytes, and a `Content-Length` that says twenty. Before the
    // fix this was the first ten, with a head promising ten.
    try testing.expectEqualStrings(grown, after.body);
    try testing.expectEqualStrings("20", after.header("Content-Length").?);

    // And the tag moved, so a cache in front is not still holding the old
    // bytes under a name that now means something else.
    try testing.expect(!std.mem.eql(u8, old_etag, after.header("ETag").?));

    // The other half of the same bug: the client that kept the old tag is
    // told the file changed rather than handed a 304.
    var request_buf: [256]u8 = undefined;
    const conditional = try client.send(&app, try std.fmt.bufPrint(
        &request_buf,
        "GET /app.js HTTP/1.1\r\nHost: t\r\nIf-None-Match: {s}\r\n\r\n",
        .{old_etag},
    ));
    try testing.expectEqual(@as(u16, 200), conditional.status);
    try testing.expectEqualStrings(grown, conditional.body);
}

test "an unchanged spilled file is described the same way twice, by two different writers" {
    // `load` writes the tag with `etagForSpilled` and a request writes it with
    // `spilledEtag` from a fresh look at the descriptor. They are the same
    // function underneath, and this is what says so: drift here would break
    // every `If-None-Match` a client ever sends for a file nobody touched.
    const gpa = testing.allocator;
    var tree = try TmpTree.init(gpa, &.{.{ "big.bin", "0123456789" }});
    defer tree.deinit(gpa);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStaticWith("/", tree.path, .{ .max_file_bytes = 4 });

    // What the walk wrote down, before any request runs.
    const at_load = app.static_sets.items[0].find("/big.bin").?.etag;

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    const served = try client.get(&app, "/big.bin");
    try testing.expectEqualStrings(at_load, served.header("ETag").?);
}

test "tryStatic hands back a directory that is not there, and says nothing about it" {
    // The program this is for decides for itself — a backend that serves
    // without its frontend built — and the test runner is the witness that
    // nothing was logged: a logged `err` fails the test whatever level it
    // prints at (`test_root.zig`), so this test passing *is* the silence
    // (ADR 207).
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();

    try testing.expectError(error.StaticDirNotFound, app.tryStatic("/", "a-directory-nobody-made"));
    try testing.expectError(error.StaticDirNotFound, app.tryStaticWith("/", "a-directory-nobody-made", .{ .reload = true }));
    try testing.expectEqual(@as(usize, 0), app.static_sets.items.len);
}

test "reload leaves every file on the disk, however small it is" {
    // `.reload` is the spill threshold set to zero and nothing else — no
    // watcher, no fiber, no second code path (see `Options.reload`). What it
    // buys is that editing a file is visible on the next request, which falls
    // out of the spilled path describing what it is about to send.
    const gpa = testing.allocator;
    var tree = try TmpTree.init(gpa, &.{
        .{ "app.css", "body{}" },
        .{ "page.html", "<p>one</p>" },
    });
    defer tree.deinit(gpa);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStaticWith("/", tree.path, .{ .reload = true });

    // Nothing is held, so nothing was gzipped and nothing counts against the
    // memory budget — a six-byte stylesheet included.
    for (app.static_sets.items[0].files) |f| {
        try testing.expect(f.contents == .spilled);
    }

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    const first = try client.get(&app, "/page.html");
    try testing.expectEqualStrings("<p>one</p>", first.body);
    // Copied out: the next request writes over the buffer this points into.
    var etag_buf: [max_spilled_etag]u8 = undefined;
    const before = etag_buf[0..first.header("ETag").?.len];
    @memcpy(before, first.header("ETag").?);

    // Edited under a running server, which is the whole point of the option.
    // A different length as well as different bytes, so the tag has to move
    // even on a filesystem whose modification times are coarse.
    try tree.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "page.html", .data = "<p>two, longer</p>" });
    const second = try client.get(&app, "/page.html");
    try testing.expectEqualStrings("<p>two, longer</p>", second.body);
    try testing.expect(!std.mem.eql(u8, before, second.header("ETag").?));
}

/// The longest a test waits for a followed directory to be noticed: the thread
/// answers in a few hundred milliseconds and this is where a failure gives up.
const follow_wait_ms = 5000;

fn followNap() void {
    std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
}

/// GET `path` until it answers `status` with `body`, and fail past the bound.
fn getUntil(client: *nilo_testing.Client, app: *App, path: []const u8, status: u16, body: []const u8) !void {
    const since = bulkhead.monotonicNanos();
    while ((bulkhead.monotonicNanos() - since) / std.time.ns_per_ms < follow_wait_ms) : (followNap()) {
        const answer = try client.get(app, path);
        if (answer.status == status and std.mem.eql(u8, answer.body, body)) return;
    }
    return error.NeverFollowed;
}

test "a directory that follows the disk answers a file replaced, added or removed, and one that does not follow keeps what it read" {
    const gpa = testing.allocator;
    var tree = try TmpTree.init(gpa, &.{
        .{ "app.css", "body{one}" },
        .{ "gone.css", "gone" },
    });
    defer tree.deinit(gpa);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStaticWith("/", tree.path, .{ .follow = true, .follow_poll_ms = 100 });
    try app.resolveChains();
    try wiring.startFollowing(&app);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try getUntil(&client, &app, "/app.css", 200, "body{one}");

    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "app.css", .data = "body{two}" });
    try getUntil(&client, &app, "/app.css", 200, "body{two}");

    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "new.css", .data = "new" });
    try getUntil(&client, &app, "/new.css", 200, "new");

    try tree.tmp.dir.deleteFile(testing.io, "gone.css");
    const since = bulkhead.monotonicNanos();
    while ((client.get(&app, "/gone.css") catch unreachable).status == 200) : (followNap()) {
        if ((bulkhead.monotonicNanos() - since) / std.time.ns_per_ms > follow_wait_ms) return error.NeverFollowed;
    }
    // A 404 naming the path, the answer for any file that is not there.
    const missing = try client.get(&app, "/gone.css");
    try testing.expectEqual(@as(u16, 404), missing.status);
}

test "a directory read without follow is the tree as it was at startup, whatever the disk does" {
    const gpa = testing.allocator;
    var tree = try TmpTree.init(gpa, &.{.{ "app.css", "body{one}" }});
    defer tree.deinit(gpa);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStatic("/", tree.path);
    try app.resolveChains();
    try wiring.startFollowing(&app);
    try testing.expect(app.static_sets.items[0].follower == null);

    try tree.tmp.dir.writeFile(testing.io, .{ .sub_path = "app.css", .data = "body{two}" });
    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    var waited: u32 = 0;
    while (waited < 400) : (waited += 20) followNap();
    const answer = try client.get(&app, "/app.css");
    try testing.expectEqualStrings("body{one}", answer.body);
}

test "a set with no directory closes cleanly, and one with a directory gives it back" {
    // `fromMemory` is the API description (ADR 016): no directory, nothing
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
    var loaded = try load(gpa, "/", tree.path, .{}, .reported);
    // Held open for the App's lifetime whether or not anything spilled, so
    // that opening one is never something a request has to do.
    try testing.expect(loaded.dir != null);
    loaded.deinit();
    try testing.expect(loaded.dir == null);
}

// ---- embedded trees (ADR 009) ----

/// A tree the way a caller writes one: `@embedFile` on each entry. These
/// are the repository's own files, because a test cannot embed what the
/// build did not put beside it — and `bytes` is a `[]const u8` pointing
/// into the binary either way, which is what `embed` is being handed.
const embedded_tree = [_]Embedded{
    .{ .path = "index.html", .bytes = @embedFile("testdata/embedded/index.html") },
    .{ .path = "assets/app.js", .bytes = @embedFile("testdata/embedded/assets/app.js") },
    .{ .path = "assets/logo.svg", .bytes = @embedFile("testdata/embedded/assets/logo.svg") },
};

test "an embedded tree answers the way a directory does: the file, the index, the fallback, a 304" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.embeddedWith("/", &embedded_tree, .{
        .spa_fallback = "index.html",
        .cache_control = "public, max-age=60",
        // Below every file here, so the one that is text and worth it gets
        // a copy and the test can see it.
        .compress_min_bytes = 16,
    });

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    // A file, with everything a held file's answer carries.
    const js = try client.get(&app, "/assets/app.js");
    try testing.expectEqual(@as(u16, 200), js.status);
    try testing.expectEqualStrings(embedded_tree[1].bytes, js.body);
    try testing.expectEqualStrings("text/javascript; charset=utf-8", js.header("Content-Type").?);
    try testing.expectEqualStrings("public, max-age=60", js.header("Cache-Control").?);
    try testing.expect(js.header("ETag") != null);
    var etag_buf: [64]u8 = undefined;
    const etag = etag_buf[0..js.header("ETag").?.len];
    @memcpy(etag, js.header("ETag").?);

    // The index, for a path ending in a slash.
    const index = try client.get(&app, "/");
    try testing.expectEqual(@as(u16, 200), index.status);
    try testing.expectEqualStrings(embedded_tree[0].bytes, index.body);

    // The fallback, for a page a browser asked for, and a 404 for an asset
    // that is not there (ADR 087) — the same two answers a directory gives.
    const deep = try client.send(&app, "GET /users/42 HTTP/1.1\r\nHost: t\r\nAccept: text/html\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), deep.status);
    try testing.expectEqualStrings(embedded_tree[0].bytes, deep.body);
    const missing = try client.get(&app, "/assets/gone.js");
    try testing.expectEqual(@as(u16, 404), missing.status);

    // Gzipped once at build, and served from that copy under its own tag.
    const packed_answer = try client.send(
        &app,
        "GET /assets/app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 200), packed_answer.status);
    try testing.expectEqualStrings("gzip", packed_answer.header("Content-Encoding").?);
    try testing.expect(!std.mem.eql(u8, etag, packed_answer.header("ETag").?));

    // A repeat visitor: a comparison and a head, no body.
    var request_buf: [256]u8 = undefined;
    const conditional = try client.send(&app, try std.fmt.bufPrint(
        &request_buf,
        "GET /assets/app.js HTTP/1.1\r\nHost: t\r\nIf-None-Match: {s}\r\n\r\n",
        .{etag},
    ));
    try testing.expectEqual(@as(u16, 304), conditional.status);
    try testing.expectEqualStrings("", conditional.body);
}

test "an embedded file is borrowed, and the Set frees the tags and the copies and not the bytes" {
    // `testing.allocator` is the check: bytes from `@embedFile` are in the
    // binary, and a `free` on them would be reported as an invalid free.
    // What the Set does own — the URL, the ETags, the gzipped copy — is what
    // a leak would show.
    const gpa = testing.allocator;
    var set = try embed(gpa, "/app", &embedded_tree, .{ .compress_min_bytes = 16 });
    defer set.deinit();

    try testing.expect(!set.owns_bytes);
    try testing.expect(set.dir == null);
    try testing.expectEqual(@as(usize, 3), set.files.len);

    const js = set.find("/app/assets/app.js").?;
    try testing.expectEqual(embedded_tree[1].bytes.ptr, js.contents.held.bytes.ptr);
    try testing.expect(js.contents.held.gzip != null);
    // An SVG is `+xml`, which is text however it starts, so it gets a copy.
    try testing.expect(set.find("/app/assets/logo.svg").?.contents.held.gzip != null);
    // Under its prefix only, on a segment boundary, as a directory is.
    try testing.expect(set.find("/assets/app.js") == null);
    try testing.expect(set.find("/apple/assets/app.js") == null);
}

test "a URL listed twice is found by name, whichever way the two were spelled" {
    // The refusal itself logs at `err`, which the test runner counts as a
    // failure, so what is tested is the check `embed` makes and not the
    // line it prints — the same split `docs/history.md` records for the
    // schema check. A directory cannot hold two files by one name; a list
    // can, and whichever the binary search stopped at would answer forever.
    const gpa = testing.allocator;
    var twice = try fakeSet(gpa, "/", &.{ "/a.txt", "/b.txt", "/a.txt" });
    defer twice.deinit();
    sortByUrl(twice.files);
    try testing.expectEqualStrings("/a.txt", listedTwice(twice.files).?);

    var once = try fakeSet(gpa, "/", &.{ "/a.txt", "/b.txt", "/c.txt" });
    defer once.deinit();
    sortByUrl(once.files);
    try testing.expect(listedTwice(once.files) == null);
    try testing.expect(listedTwice(&.{}) == null);

    // `join` is what makes "/a.txt" and "a.txt" one URL before the check
    // runs, so the two spellings meet here rather than at a request.
    var buf: [max_url]u8 = undefined;
    try testing.expectEqualStrings("/a.txt", join(&buf, "/", "/a.txt").?);
    try testing.expectEqualStrings("/a.txt", join(&buf, "/", "a.txt").?);

    // An empty list is a Set that answers nothing, and closes.
    var empty = try embed(gpa, "/", &.{}, .{});
    empty.deinit();
}

fn listItems() []const u8 {
    return "items";
}

fn makeItem() []const u8 {
    return "made";
}

test "a cache rule gives a file its own header and every other file the default" {
    const rules = [_]CacheRule{
        .{ .prefix = "assets/", .cache_control = "public, max-age=31536000, immutable" },
        .{ .suffix = ".map", .cache_control = "" },
        .{ .prefix = "assets/", .suffix = ".txt", .cache_control = "never reached" },
    };
    try testing.expectEqualStrings("public, max-age=31536000, immutable", cacheControlFor(&rules, "no-cache", "assets/app.3f9a.js"));
    // The first rule that matches wins, so the narrower one below it is dead
    // here, and a rule can switch the header off.
    try testing.expectEqualStrings("public, max-age=31536000, immutable", cacheControlFor(&rules, "no-cache", "assets/notes.txt"));
    try testing.expectEqualStrings("", cacheControlFor(&rules, "no-cache", "app.js.map"));
    try testing.expectEqualStrings("no-cache", cacheControlFor(&rules, "no-cache", "index.html"));
    try testing.expectEqualStrings("no-cache", cacheControlFor(&.{}, "no-cache", "assets/app.js"));
}

test "a single-page app is one embedded set: hashed assets cached for good, the page never, and a typo in the API a 404" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.get("/api/items", listItems);
    try app.post("/api/make", makeItem);
    try app.embeddedWith("/", &embedded_tree, .{
        .spa_fallback = "index.html",
        .cache_control = "no-cache",
        .cache_rules = &.{.{ .prefix = "assets/", .cache_control = "public, max-age=31536000, immutable" }},
    });

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    // One set, two policies, settled at load.
    const js = try client.get(&app, "/assets/app.js");
    try testing.expectEqualStrings("public, max-age=31536000, immutable", js.header("Cache-Control").?);
    const index = try client.get(&app, "/index.html");
    try testing.expectEqualStrings("no-cache", index.header("Cache-Control").?);

    // A reload on a client-side route is the page, with the page's policy.
    const reload = try client.send(
        &app,
        "GET /users/42 HTTP/1.1\r\nHost: t\r\nSec-Fetch-Mode: navigate\r\nAccept: text/html\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 200), reload.status);
    try testing.expectEqualStrings(embedded_tree[0].bytes, reload.body);
    try testing.expectEqualStrings("no-cache", reload.header("Cache-Control").?);
    const head = try client.send(
        &app,
        "HEAD /users/42 HTTP/1.1\r\nHost: t\r\nSec-Fetch-Mode: navigate\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 200), head.status);

    // The mistake this exists for: a `fetch` or a `curl` at an API path that
    // is not there is a 404 and not the page, and there is no catch-all
    // route standing in for that.
    const typo = try client.send(&app, "GET /api/nope HTTP/1.1\r\nHost: t\r\nAccept: */*\r\nSec-Fetch-Mode: cors\r\n\r\n");
    try testing.expectEqual(@as(u16, 404), typo.status);
    try testing.expect(std.mem.indexOf(u8, typo.body, "/api/nope") != null);
    const bare = try client.get(&app, "/api/nope");
    try testing.expectEqual(@as(u16, 404), bare.status);
    const posted = try client.send(&app, "POST /api/nope HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n");
    try testing.expectEqual(@as(u16, 404), posted.status);

    // A path some route spells keeps its 405, for a caller that is not a
    // browser opening a page, and the route itself is untouched.
    const wrong_verb = try client.send(&app, "GET /api/make HTTP/1.1\r\nHost: t\r\nAccept: */*\r\n\r\n");
    try testing.expectEqual(@as(u16, 405), wrong_verb.status);
    const wrong_verb_put = try client.send(&app, "PUT /api/items HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n");
    try testing.expectEqual(@as(u16, 405), wrong_verb_put.status);
    const route = try client.get(&app, "/api/items");
    try testing.expectEqual(@as(u16, 200), route.status);
    try testing.expectEqualStrings("items", route.body);

    // And a missing bundle named by a `<script src>` is a 404, not a page.
    const stale = try client.send(&app, "GET /assets/app.old.js HTTP/1.1\r\nHost: t\r\nAccept: */*\r\nSec-Fetch-Mode: no-cors\r\n\r\n");
    try testing.expectEqual(@as(u16, 404), stale.status);
}

test "a name with a space or a non-ASCII character is served at the URL a browser sends for it" {
    const gpa = testing.allocator;
    var tree = try TmpTree.init(gpa, &.{
        .{ "café.png", "png bytes" },
        .{ "My Doc.pdf", "pdf bytes" },
        .{ "plain.txt", "plain" },
    });
    defer tree.deinit(gpa);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStatic("/", tree.path);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    // The table holds the names as the disk spells them (ADR 009).
    var names_ok = false;
    for (app.static_sets.items[0].files) |f| {
        if (std.mem.eql(u8, f.url, "/café.png")) names_ok = true;
    }
    try testing.expect(names_ok);

    const accent = try client.get(&app, "/caf%C3%A9.png");
    try testing.expectEqual(@as(u16, 200), accent.status);
    try testing.expectEqualStrings("png bytes", accent.body);
    const lower = try client.get(&app, "/caf%c3%a9.png");
    try testing.expectEqual(@as(u16, 200), lower.status);
    const space = try client.get(&app, "/My%20Doc.pdf");
    try testing.expectEqual(@as(u16, 200), space.status);
    try testing.expectEqualStrings("pdf bytes", space.body);
    // An escape for a byte that needs none still names the file.
    const needless = try client.get(&app, "/pl%61in.txt");
    try testing.expectEqual(@as(u16, 200), needless.status);
    try testing.expectEqualStrings("plain", needless.body);
}

test "a decoded path that could leave the tree names no file" {
    const gpa = testing.allocator;
    var tree = try TmpTree.init(gpa, &.{
        .{ "index.html", "home" },
        .{ "a.txt", "a" },
    });
    defer tree.deinit(gpa);
    var set = try load(gpa, "/", tree.path, .{}, .reported);
    defer set.deinit();

    const refused = [_][]const u8{
        "/%2e%2e/a.txt", "/%2E%2E/a.txt", "/%2e/a.txt", "/.%2e/a.txt", "/x/%2e%2e",
        "/..%2fa.txt",   "/%2Fa.txt",     "/a.txt%00",  "/a%00.txt",   "/a.txt%zz",
        "/a.txt%",       "/a.txt%4",      "/%5Ca.txt",  "/x%5Ca.txt",  "/a%2fb",
    };
    for (refused) |path| try testing.expect(set.find(path) == null);
    // The same bytes without an escape in them were never a file either.
    try testing.expect(set.find("/../a.txt") == null);
    // And the safe ones still find it.
    try testing.expect(set.find("/%61.txt") != null);
    try testing.expect(set.find("/") != null);
}

test "a symlink in the tree at load is not listed, and the file it pointed at is not served" {
    const gpa = testing.allocator;
    var outside = try TmpTree.init(gpa, &.{.{ "secret.txt", "outside" }});
    defer outside.deinit(gpa);
    var tree = try TmpTree.init(gpa, &.{.{ "real.txt", "inside" }});
    defer tree.deinit(gpa);

    const target = try outside.tmp.dir.realPathFileAlloc(std.testing.io, "secret.txt", gpa);
    defer gpa.free(target);
    try tree.tmp.dir.symLink(std.testing.io, target, "link.txt", .{});

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStatic("/", tree.path);
    try testing.expectEqual(@as(usize, 1), app.static_sets.items[0].files.len);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/real.txt")).status);
    try testing.expectEqual(@as(u16, 404), (try client.get(&app, "/link.txt")).status);
}

test "a spilled file replaced by a symlink after load is not served out of the tree" {
    const gpa = testing.allocator;
    var outside = try TmpTree.init(gpa, &.{.{ "secret.txt", "outside the tree" }});
    defer outside.deinit(gpa);
    var tree = try TmpTree.init(gpa, &.{.{ "big.txt", "0123456789" }});
    defer tree.deinit(gpa);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStaticWith("/", tree.path, .{ .max_file_bytes = 4 });
    try testing.expect(app.static_sets.items[0].files[0].contents == .spilled);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    const before = try client.get(&app, "/big.txt");
    try testing.expectEqual(@as(u16, 200), before.status);
    try testing.expectEqualStrings("0123456789", before.body);

    // Swapped after the walk: the name is the same and what it opens is not.
    const target = try outside.tmp.dir.realPathFileAlloc(std.testing.io, "secret.txt", gpa);
    defer gpa.free(target);
    try tree.tmp.dir.deleteFile(std.testing.io, "big.txt");
    try tree.tmp.dir.symLink(std.testing.io, target, "big.txt", .{});

    const after = try client.get(&app, "/big.txt");
    try testing.expectEqual(@as(u16, 404), after.status);
    try testing.expect(std.mem.indexOf(u8, after.body, "outside the tree") == null);
}

test "reload does not follow a file swapped for a symlink either" {
    const gpa = testing.allocator;
    var outside = try TmpTree.init(gpa, &.{.{ "secret.txt", "outside the tree" }});
    defer outside.deinit(gpa);
    var tree = try TmpTree.init(gpa, &.{.{ "page.html", "<p>in</p>" }});
    defer tree.deinit(gpa);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStaticWith("/", tree.path, .{ .reload = true });

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/page.html")).status);

    const target = try outside.tmp.dir.realPathFileAlloc(std.testing.io, "secret.txt", gpa);
    defer gpa.free(target);
    try tree.tmp.dir.deleteFile(std.testing.io, "page.html");
    try tree.tmp.dir.symLink(std.testing.io, target, "page.html", .{});

    const after = try client.get(&app, "/page.html");
    try testing.expectEqual(@as(u16, 404), after.status);
    try testing.expect(std.mem.indexOf(u8, after.body, "outside the tree") == null);
}

/// `s` written `n` times over, at compile time: what `s ** n` said before
/// Zig 0.17 took the operator away.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    // A comptime-known constant, so that `&built` is a pointer into the
    // binary and the call is as good at runtime as `**` was.
    const built = comptime blk: {
        @setEvalBranchQuota(10 * n + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        break :blk final;
    };
    return &built;
}

// ---- a file the build already compressed (ADR 273) ----

const bundle_js = repeat("function add(a, b) { return a + b; } // a bundle line\n", 60);
/// Not brotli, and nothing here decodes it: a sibling's bytes are the build's,
/// and what is under test is which bytes go out, under which headers.
const bundle_br = repeat("BR-BYTES-", 20);

/// A tree with `app.js`, a `.br` made of `bundle_br` and a real `.gz`,
/// written in that order so the siblings are not older than the file.
fn bundleTree(gpa: std.mem.Allocator, with_br: bool, with_gz: bool) !struct { tree: TmpTree, gz: []const u8 } {
    const gz = (try gzipped(gpa, bundle_js)).?;
    errdefer gpa.free(gz);
    var tree = try TmpTree.init(gpa, &.{.{ "app.js", bundle_js }});
    errdefer tree.deinit(gpa);
    if (with_br) try tree.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app.js.br", .data = bundle_br });
    if (with_gz) try tree.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "app.js.gz", .data = gz });
    return .{ .tree = tree, .gz = gz };
}

fn lengthOf(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("{d}", .{n});
}

test "a build's brotli and gzip are served by the client's q, each under its own tag, and never under their own names" {
    const gpa = testing.allocator;
    var built = try bundleTree(gpa, true, true);
    defer built.tree.deinit(gpa);
    defer gpa.free(built.gz);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStaticWith("/", built.tree.path, .{});

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    const ask = struct {
        fn get(cl: *nilo_testing.Client, a: *App, extra: []const u8) !nilo_testing.Answer {
            var buf: [256]u8 = undefined;
            return cl.send(a, try std.fmt.bufPrint(&buf, "GET /app.js HTTP/1.1\r\nHost: t\r\n{s}\r\n", .{extra}));
        }
    }.get;

    // Copied out, because the next request writes over the buffer.
    var plain_tag: [64]u8 = undefined;
    var br_tag: [64]u8 = undefined;
    var gz_tag: [64]u8 = undefined;

    const plain = try ask(&client, &app, "");
    try testing.expectEqual(@as(u16, 200), plain.status);
    try testing.expectEqualStrings(bundle_js, plain.body);
    try testing.expect(plain.header("Content-Encoding") == null);
    // The plain answer says it varies too: a cache that stored it without
    // would hand it to a browser that could have had the small one.
    try testing.expectEqualStrings("Accept-Encoding", plain.header("Vary").?);
    @memcpy(plain_tag[0..plain.header("ETag").?.len], plain.header("ETag").?);

    const br = try ask(&client, &app, "Accept-Encoding: gzip, deflate, br\r\n");
    try testing.expectEqualStrings(bundle_br, br.body);
    try testing.expectEqualStrings("br", br.header("Content-Encoding").?);
    try testing.expectEqualStrings("Accept-Encoding", br.header("Vary").?);
    try testing.expectEqualStrings(lengthOf(bundle_br.len), br.header("Content-Length").?);
    @memcpy(br_tag[0..br.header("ETag").?.len], br.header("ETag").?);

    // The build's gzip, byte for byte: nilo made no copy of its own.
    const gz = try ask(&client, &app, "Accept-Encoding: gzip, deflate\r\n");
    try testing.expectEqualSlices(u8, built.gz, gz.body);
    try testing.expectEqualStrings("gzip", gz.header("Content-Encoding").?);
    @memcpy(gz_tag[0..gz.header("ETag").?.len], gz.header("ETag").?);

    try testing.expect(!std.mem.eql(u8, plain_tag[0..plain.header("ETag").?.len], br_tag[0..br.header("ETag").?.len]));

    // q-values: highest wins, brotli on a tie, and a refused one never.
    try testing.expectEqualStrings("gzip", (try ask(&client, &app, "Accept-Encoding: br;q=0.4, gzip;q=0.8\r\n")).header("Content-Encoding").?);
    try testing.expectEqualStrings("br", (try ask(&client, &app, "Accept-Encoding: br;q=0.9, gzip;q=0.8\r\n")).header("Content-Encoding").?);
    try testing.expectEqualStrings("gzip", (try ask(&client, &app, "Accept-Encoding: br;q=0, gzip\r\n")).header("Content-Encoding").?);
    const refused = try ask(&client, &app, "Accept-Encoding: br;q=0, gzip;q=0\r\n");
    try testing.expect(refused.header("Content-Encoding") == null);
    try testing.expectEqualStrings(bundle_js, refused.body);
    try testing.expectEqualStrings("br", (try ask(&client, &app, "Accept-Encoding: *\r\n")).header("Content-Encoding").?);

    // A repeat visitor, per encoding: its own tag is a 304, another's is not.
    var request: [256]u8 = undefined;
    const same = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br\r\nIf-None-Match: {s}\r\n\r\n",
        .{br_tag[0..br.header("ETag").?.len]},
    ));
    try testing.expectEqual(@as(u16, 304), same.status);
    try testing.expectEqualStrings("Accept-Encoding", same.header("Vary").?);
    const other = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br\r\nIf-None-Match: {s}\r\n\r\n",
        .{plain_tag[0..plain.header("ETag").?.len]},
    ));
    try testing.expectEqual(@as(u16, 200), other.status);
    try testing.expectEqualStrings(bundle_br, other.body);

    // A range is an offset into the plain bytes, as it is for nilo's own
    // copy, so the compressed forms are not cut anywhere.
    const part = try ask(&client, &app, "Accept-Encoding: br\r\nRange: bytes=0-9\r\n");
    try testing.expectEqual(@as(u16, 206), part.status);
    try testing.expectEqualStrings(bundle_js[0..10], part.body);
    try testing.expect(part.header("Content-Encoding") == null);
    try testing.expectEqualStrings("Accept-Encoding", part.header("Vary").?);

    // A HEAD gets the head the GET would have, with the compressed length.
    const head = try client.send(&app, "HEAD /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br\r\n\r\n");
    try testing.expectEqualStrings("br", head.header("Content-Encoding").?);
    try testing.expectEqualStrings(lengthOf(bundle_br.len), head.header("Content-Length").?);
    try testing.expectEqualStrings("", head.body);

    // The siblings are the file's forms and not files.
    try testing.expectEqual(@as(u16, 404), (try client.get(&app, "/app.js.br")).status);
    try testing.expectEqual(@as(u16, 404), (try client.get(&app, "/app.js.gz")).status);
}

test "a gzip beside the file replaces the copy nilo would make, and a brotli alone leaves that copy" {
    const gpa = testing.allocator;

    var with_gz = try bundleTree(gpa, true, true);
    defer with_gz.tree.deinit(gpa);
    defer gpa.free(with_gz.gz);
    var set = try load(gpa, "/", with_gz.tree.path, .{}, .reported);
    defer set.deinit();
    const both = set.find("/app.js").?.contents.held;
    try testing.expectEqualSlices(u8, with_gz.gz, both.gzip.?);
    try testing.expectEqualStrings(bundle_br, both.br.?);
    try testing.expectEqual(@as(usize, 1), set.files.len);

    var only_br = try bundleTree(gpa, true, false);
    defer only_br.tree.deinit(gpa);
    defer gpa.free(only_br.gz);
    var made = try load(gpa, "/", only_br.tree.path, .{}, .reported);
    defer made.deinit();
    const held = made.find("/app.js").?.contents.held;
    // Nilo's own, for the client that takes gzip and not brotli.
    try testing.expect(held.gzip != null);
    try testing.expect(held.br != null);
    try testing.expect(!std.mem.eql(u8, held.gzip_etag, held.br_etag));
}

test "a sibling that is stale, not smaller or not a gzip of its file is passed over, and still not a file" {
    const gpa = testing.allocator;

    // A gzip of something else: what an old build left behind.
    const other = (try gzipped(gpa, repeat("not the bundle at all, but compressible enough. ", 80))).?;
    defer gpa.free(other);
    var tree = try TmpTree.init(gpa, &.{
        .{ "app.js", bundle_js },
        .{ "app.js.gz", other },
        .{ "big.js", "tiny();" },
        .{ "big.js.br", "this is longer than the file it claims to compress" },
        .{ "old.js", bundle_js },
        .{ "old.js.br", bundle_br },
    });
    defer tree.deinit(gpa);

    // Older than the file, by a build before this one.
    var old_br = try tree.tmp.dir.openFile(std.testing.io, "old.js.br", .{ .mode = .read_write });
    defer old_br.close(std.testing.io);
    try old_br.setTimestamps(std.testing.io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1_000_000_000 } } });

    var set = try load(gpa, "/", tree.path, .{}, .reported);
    defer set.deinit();

    try testing.expectEqual(@as(usize, 3), set.files.len);
    const app_js = set.find("/app.js").?.contents.held;
    try testing.expect(!std.mem.eql(u8, other, app_js.gzip.?));
    try testing.expect(set.find("/big.js").?.contents.held.br == null);
    try testing.expect(set.find("/old.js").?.contents.held.br == null);
    try testing.expect(set.find("/app.js.gz") == null);
    try testing.expect(set.find("/big.js.br") == null);
    try testing.expect(set.find("/old.js.br") == null);
}

test "with precompressed off the siblings are ordinary files, and a type not worth compressing keeps its neighbour" {
    const gpa = testing.allocator;
    var built = try bundleTree(gpa, true, true);
    defer built.tree.deinit(gpa);
    defer gpa.free(built.gz);

    var off = try load(gpa, "/", built.tree.path, .{ .precompressed = false }, .reported);
    defer off.deinit();
    try testing.expectEqual(@as(usize, 3), off.files.len);
    try testing.expect(off.find("/app.js.br") != null);
    try testing.expect(off.find("/app.js").?.contents.held.br == null);

    // A picture is not compressible, so `photo.png.gz` is somebody's download.
    var tree = try TmpTree.init(gpa, &.{
        .{ "photo.png", repeat("not really a png ", 100) },
        .{ "photo.png.gz", "x" },
    });
    defer tree.deinit(gpa);
    var png = try load(gpa, "/", tree.path, .{}, .reported);
    defer png.deinit();
    try testing.expectEqual(@as(usize, 2), png.files.len);
}

test "a spilled file takes its sibling from the disk, under a tag of its own" {
    const gpa = testing.allocator;
    var built = try bundleTree(gpa, true, true);
    defer built.tree.deinit(gpa);
    defer gpa.free(built.gz);

    var app = App.init(gpa);
    defer app.deinit();
    try app.tryStaticWith("/", built.tree.path, .{ .max_file_bytes = 16 });

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    var plain_tag: [64]u8 = undefined;
    const plain = try client.get(&app, "/app.js");
    try testing.expectEqualStrings(bundle_js, plain.body);
    try testing.expectEqualStrings("Accept-Encoding", plain.header("Vary").?);
    const plain_tag_len = plain.header("ETag").?.len;
    @memcpy(plain_tag[0..plain_tag_len], plain.header("ETag").?);

    const br = try client.send(&app, "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br, gzip\r\n\r\n");
    try testing.expectEqualStrings(bundle_br, br.body);
    try testing.expectEqualStrings("br", br.header("Content-Encoding").?);
    try testing.expectEqualStrings("Accept-Encoding", br.header("Vary").?);
    try testing.expectEqualStrings(lengthOf(bundle_br.len), br.header("Content-Length").?);
    try testing.expect(!std.mem.eql(u8, plain_tag[0..plain_tag_len], br.header("ETag").?));
    var br_tag: [64]u8 = undefined;
    const br_tag_len = br.header("ETag").?.len;
    @memcpy(br_tag[0..br_tag_len], br.header("ETag").?);

    const gz = try client.send(&app, "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br;q=0, gzip\r\n\r\n");
    try testing.expectEqualSlices(u8, built.gz, gz.body);
    try testing.expectEqualStrings("gzip", gz.header("Content-Encoding").?);

    var request: [256]u8 = undefined;
    const again = try client.send(&app, try std.fmt.bufPrint(
        &request,
        "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br\r\nIf-None-Match: {s}\r\n\r\n",
        .{br_tag[0..br_tag_len]},
    ));
    try testing.expectEqual(@as(u16, 304), again.status);

    const part = try client.send(&app, "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br\r\nRange: bytes=0-9\r\n\r\n");
    try testing.expectEqual(@as(u16, 206), part.status);
    try testing.expectEqualStrings(bundle_js[0..10], part.body);
    try testing.expect(part.header("Content-Encoding") == null);

    // The sibling gone since the walk: the plain file answers.
    try built.tree.tmp.dir.deleteFile(std.testing.io, "app.js.br");
    const gone = try client.send(&app, "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), gone.status);
    try testing.expectEqualStrings(bundle_js, gone.body);
    try testing.expect(gone.header("Content-Encoding") == null);
}

test "an embedded tree serves the forms it carries and frees only what it made" {
    const gpa = testing.allocator;
    const gz = (try gzipped(gpa, bundle_js)).?;
    defer gpa.free(gz);

    var app = App.init(gpa);
    defer app.deinit();
    try app.embedded("/", &.{
        .{ .path = "app.js.br", .bytes = bundle_br },
        .{ .path = "app.js", .bytes = bundle_js },
        .{ .path = "app.js.gz", .bytes = gz },
    });

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    const br = try client.send(&app, "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: br\r\n\r\n");
    try testing.expectEqualStrings(bundle_br, br.body);
    try testing.expectEqualStrings("Accept-Encoding", br.header("Vary").?);
    const zipped = try client.send(&app, "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expectEqualSlices(u8, gz, zipped.body);
    try testing.expectEqual(@as(u16, 404), (try client.get(&app, "/app.js.br")).status);
}
