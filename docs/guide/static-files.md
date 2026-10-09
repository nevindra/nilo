# Static files

**`app.static` reads a directory into memory when the server starts, so files are served without touching the disk and path traversal is impossible.**

**Reference:** [`app.static`, `app.embedded`](../reference/app.md#app), [static options](../reference/app.md#static-options) · **Design:** [Static files](../design/static-files.md)

```zig
try app.static("/", "public");

try app.staticWith("/assets", "dist", .{
    .cache_control = "public, max-age=31536000, immutable",
    .spa_fallback = "index.html",
});
```

The directory is read into memory when the server starts, so nothing touches the disk while requests are being served ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)). Each file gets an ETag when it is loaded, so a repeat visit is a 304 with no body. Path traversal isn't possible, because there is no path to resolve, only a name looked up in a fixed list.

The one exception is a file over `max_file_bytes`. It is not refused: it stays in the list with its size and the path the directory walk found, and a request opens it and sends it from the disk ([below](#large-files-served-from-disk)). Both properties above still hold.

The path is relative to the working directory the server runs in. A directory that can't be opened stops `listen()` with that reason in the error.

## Options

**Every option has a default, listed here and [in the reference](../reference/app.md#static-options).**

| | |
|---|---|
| `index` | served for a path ending in `/`. Default `"index.html"`; empty turns it off |
| `cache_control` | sent on every file. Default `"public, max-age=3600"` |
| `cache_rules` | exceptions to `cache_control` by where a file sits in the tree, so hashed bundles and the page that names them take different headers ([below](#one-tree-two-cache-policies)). Default none |
| `spa_fallback` | served for a path under the prefix that names no file and could be a browser opening a page. Empty (the default) turns it off |
| `spa_fallback_for` | which requests that covers. `.navigations` (the default) or `.any_path`, which is how it worked before 0.2.0 ([below](#the-spa-fallback)) |
| `max_file_bytes` | the size above which a file is opened per request instead of held in memory. Default 8 MB |
| `max_total_bytes` | the most one tree may hold in memory, gzipped copies included. Default 64 MB |
| `dotfiles` | whether to load names starting with `.`. Off by default |
| `compress` | gzip every file worth gzipping, once, at load. On by default |
| `precompressed` | serve a `.br` or `.gz` the build wrote beside a file. On by default |
| `compress_min_bytes` | files smaller than this are served as they are. Default 1 KB |

Dotfiles are off because finding out on the first request that a `.env` or a `.git` ended up in the published directory is a bad way to learn it was there.

**File names are matched as a browser sends them.** `café.png` is requested as `/caf%C3%A9.png` and `My Doc.pdf` as `/My%20Doc.pdf`; both are served under their names on disk. A path that decodes to an escaped `/`, a NUL, a backslash or a `.` or `..` segment (`%2e%2e` included), or holds a malformed escape, names no file ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)).

**A symlink in the tree is not served.** The walk skips every link and says so at startup in one warning (the first three paths and a count). A file that is loaded from disk per request, over `max_file_bytes` or under `reload`, is opened without following a link, so replacing one with a link to somewhere else answers 404 rather than sending what it points at. Copy the file into the directory to serve it.

### The SPA fallback

**`spa_fallback` answers only a browser opening a page**, so a reload on `/users/42` reaches your client-side router, and a missing asset or a mistyped API path is a 404 that names it ([ADR 087](../adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md)):

| The request | The answer |
|---|---|
| `GET /users/42`, `Sec-Fetch-Mode: navigate`: a reload, a deep link, a typed URL | the page |
| `GET /users/42`, no `Sec-Fetch-Mode`, `Accept: text/html,…`: an older client, or a browser on plain HTTP away from `localhost` | the page |
| `GET /app.abc123.js`, `Sec-Fetch-Mode: no-cors`: a `<script src>` | **404**, naming the path |
| `GET /api/orders`, `Sec-Fetch-Mode: cors`: a `fetch`, whatever its `Accept` | **404** |
| `GET /users/42`, `Accept: */*` or nothing: `curl`, a health check | **404** |

**Two tests, in this order.** A browser says what it is doing in `Sec-Fetch-Mode`, and every current one sends it: when the header is there, `navigate` is a navigation and anything else is not. When it is missing, the request has to ask for `text/html` by name, which every browser's page load does. `*/*` alone is never a navigation. The path is not read, so there is no list of API prefixes to keep: a `fetch('/api/nope')` is a 404 whether or not the API has a route registered anywhere near it, and you do not write a catch-all route to stop it being a page. A route you did register keeps its own answers, a 405 for the wrong verb included.

The answer to a mistyped API path is nilo's ordinary 404, so a client sees an error where it used to see a 200 and a page.

**Typing `/api/nope` into the address bar is a navigation and gets the page**, because the browser says it is one; your client-side router then shows its own not-found screen, which is the right thing for a person to see. If a path should never fall back, give it a route.

A directory that really wants the old behaviour can ask for it:

```zig
try app.staticWith("/", "public", .{
    .spa_fallback = "index.html",
    .spa_fallback_for = .any_path,     // every path under the prefix, as before
});
```

`max_total_bytes` is a real limit, because the held part of the tree goes into RAM, and it is better to hit it at startup than at 3am. `max_file_bytes` is not a limit: a file over it is served from the disk instead of refused, and holds nothing that counts against the total ([below](#large-files-served-from-disk)).

## One tree, two cache policies

**`cache_rules` gives some files a `Cache-Control` of their own**, which is what a front-end build needs: hashed bundles that can be kept for a year, and an `index.html` that must be asked about every time.

```zig
try app.staticWith("/", "dist", .{
    .spa_fallback = "index.html",
    .cache_control = "no-cache",
    .cache_rules = &.{
        .{ .prefix = "assets/", .cache_control = "public, max-age=31536000, immutable" },
    },
});
```

A rule matches a file by its path in the tree, relative with forward slashes (`assets/app.3f9a1c.js`): `.prefix` is the start of it, `.suffix` the end, and a rule with both needs both. The first rule a file matches gives its header, and a file no rule matches takes `cache_control`. An empty `.cache_control` in a rule leaves the header off for the files it matches. The page a deep link falls back to answers with the page's own policy, so a reload revalidates.

Rules are settled once while the files are loaded, into the header each file already carries, so a request pays nothing for there being any. Two sets would also do it, and nothing is wrong with them where the tree is already two directories; one set is shorter when it is one build output.

## Compression

**Every file worth compressing is gzipped once, while the App is being built**, and a client that sends `Accept-Encoding: gzip` gets the copy already made. Nothing is compressed per request, so serving a compressed asset costs a slice and a header, measured at zero allocations and held by a test.

That stays true with middleware in front of it, which did not always hold: the middleware chain for an asset is worked out at `listen()`, per file, the same as a route's. A logger, CORS, or anything scoped to a prefix above or below the asset adds nothing to the request.

This timing is the design, not an optimisation added later. A gzip compressor needs a 64 KB window. One per connection would take an idle connection from 4,669 bytes to roughly fifteen times that, and one per request would add an allocation to the request path, whose budget is one ([ADR 017](../adr/017-the-trade-budget-has-four-axes.md)). A file that never changes avoids both, because it can be compressed before the socket is open.

What it costs instead is memory held for the life of the process: the compressed copy sits beside the original and counts against `max_total_bytes` like everything else. The startup line says how much it came to:

```
nilo: loaded 34 static file(s) (2411903 bytes held, 383204 of them gzipped
       copies) from "dist" onto "/assets"
```

A file is skipped when it is under `compress_min_bytes`, when its type is already compressed (a PNG, a woff2, an MP4), when gzip did not make it smaller, or when it is over `max_file_bytes` and so was never read. **Compressing a handler's own answer is a different feature**: files are gzipped once here, while `app.compress(.{})` gzips an endpoint's JSON per request with a compressor borrowed from a pool ([Responses](./responses.md#compression)). Without it, an endpoint returning JSON goes out uncompressed.

Three details that are easy to get wrong, and that nilo gets right:

- **`Vary: Accept-Encoding`** goes out whenever a file has two versions, including on the response carrying the plain one. Without it a shared cache stores whichever answer it saw first and hands it to everyone after.
- **The two versions have different ETags.** An ETag names a representation, not a file. If both had the same one, a cache could answer a client that can't read gzip with the gzipped copy, because the tag matched.
- **`gzip;q=0` means no.** It contains the word `gzip` and means the opposite: it is how a client that can't decompress says so.

## Files your build already compressed

**If your build writes `app.js.br` and `app.js.gz` beside `app.js`, nilo serves them**, and a brotli-capable browser gets the smallest one. There is nothing to turn on:

```
dist/app.js       803,121 bytes
dist/app.js.br    169,659
dist/app.js.gz    205,519
```

A client that sends `Accept-Encoding: gzip, deflate, br` gets the `.br`, one that sends `br;q=0.5, gzip;q=0.9` the `.gz` (the highest `q` wins, brotli on a tie), and `br;q=0` is never given brotli. Nilo has no brotli encoder, so only a file somebody else compressed is served this way. A `.gz` replaces the gzip copy nilo would have made at startup, so the startup work is saved too; with only a `.br`, nilo still makes its own gzip copy, for the browsers that take gzip and not brotli (Chrome sends no `br` over plain HTTP).

What to know:

- **The siblings are not files.** `/app.js.br` is a 404: its bytes are held once, as a form of `app.js`. A tree that publishes `notes.txt.gz` to be downloaded beside `notes.txt` passes `.precompressed = false`. A `.gz` beside a PNG is a file, because a PNG is not worth compressing.
- **A stale sibling is not served.** A `.gz` is checked against the file it sits beside (its trailer carries the CRC-32 of what it compressed), and its age does not matter; a `.br` has no such check and is held to the modification time, so one older than its file is ignored. Either way the startup log names it: `holds 1 precompressed file(s) that are not served: "app.js.br" (older than the file beside it)`.
- **Each form has its own ETag and every answer for the file says `Vary: Accept-Encoding`**, the plain one and the 304 too. A request for a `Range` gets the plain bytes.
- **It costs the bytes it holds.** On a six-file, 1.4 MB front end the siblings were 273,497 bytes more than nilo's own gzip copy ([the run](../../bench/result/http.md#a-file-a-build-compressed-is-held-beside-the-file)); brotli was 17.7% smaller on the wire than nilo's gzip. The startup line counts them: `(2034416 bytes held, 333516 of them gzipped copies, 279412 of them precompressed files)`.
- **A file over `max_file_bytes` takes its siblings from the disk**, the way it is served from the disk itself.

## Range requests

**A request for a byte range gets that range**, which is what a video being scrubbed and a download being resumed both ask for:

```
$ curl -i -r 0-20 localhost:8787/video.mp4
HTTP/1.1 206 Partial Content
Content-Length: 21
Accept-Ranges: bytes
Content-Range: bytes 0-20/739
```

`bytes=3-7`, `bytes=20-` and `bytes=-30` all work, and `Accept-Ranges: bytes` goes out on every file response so a client knows it may ask.

For everything else, **a `Range` that can't be understood is ignored and the whole file goes out** ([ADR 020](../adr/020-a-range-is-a-slice-and-two-headers.md)). That is a correct answer to every request, so `bytes=abc-def` or `bytes=99-10` gets a 200, not an error. The one case that is refused is a range starting past the end of the file: the client has the wrong idea about the size, and a `416` with `Content-Range: bytes */739` is the only way to say so.

`If-Range` is checked against the ETag, which is what matters for correctness: resuming a download of a file that has changed since would join two halves of two different files, so a stale ETag gets the whole file instead.

The comparison is **strong**, which is stricter than the one `If-None-Match` uses: a tag wrapped in `W/` and a bare `*` both get the whole file, not a range. A weak validator promises the content is equivalent, not that it is the same bytes, and the same bytes is exactly what a client needs when it appends this range to a part it already has ([ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md)).

A request for a range gets the **uncompressed** file, whatever it said in `Accept-Encoding`. A range is an offset into one version of the file, and the gzipped copy has different offsets, so answering one from the other would return the wrong bytes without saying so.

A request for several ranges at once is legal, but needs a `multipart/byteranges` body that nilo doesn't build, so it gets the whole file too. Nothing sends them in practice.

## Large files served from disk

**A file over `max_file_bytes` stays on disk and is opened by the request that asks for it.** It keeps its place in the list with its size, its modification time and the path the directory walk found ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)). So a directory with a video in it still loads and serves.

Below the limit nothing changes: the file is read at load, hashed, gzipped if worth it, and answered from memory. Above it, three things change:

- **There is no gzipped copy of nilo's making** (a `.br` or `.gz` your build wrote beside it is served from the disk). Compression happens once, while the App is being built, and a file that is never read then cannot be compressed then. A file that size is usually a video, an archive or an installer, and all three are compressed already.
- **The ETag is the modification time and the size**, `"<mtime>-<size>"` in hex, instead of a hash of the contents. It is strong, and it is what nginx has sent by default for twenty years. Hashing would mean reading the whole file at startup, and a weak tag would make `If-Range` unusable for exactly the large downloads that get resumed. Both numbers come from one look at the file descriptor whose bytes are about to be sent, so a file that changed on disk cannot go out with a length and a tag from different versions of it ([ADR 098](../adr/098-a-file-is-described-by-the-descriptor-being-sent.md)).
- **One file descriptor is held while the response is sent**: one per request in flight, which `max_connections` already bounds.

Two things do not change, and they are the two benefits of holding everything in memory. Path traversal is still impossible: the name handed to the kernel is the one the directory walk recorded before the socket opened, never one from a request. And memory is still bounded: a file over the limit holds no bytes at all, so `max_total_bytes` counts only what is held.

Ranges, `If-Range`, `If-None-Match` and `HEAD` are answered exactly as for a file in memory, by the same code.

The startup line counts the files served from disk separately, because their bytes are not in the total:

```
nilo: loaded 12 static file(s) (48211 bytes held, 9022 of them gzipped copies)
       from "public" onto "/", 2 of them over 8388608 bytes and opened per
       request rather than held
```

A handler can answer with a file the same way; see [Responses](./responses.md#files).

## Embedded files

```zig
try app.embeddedWith("/", &.{
    .{ .path = "index.html", .bytes = @embedFile("dist/index.html") },
    .{ .path = "assets/app.js", .bytes = @embedFile("dist/assets/app.js") },
    .{ .path = "assets/app.css", .bytes = @embedFile("dist/assets/app.css") },
}, .{ .spa_fallback = "index.html" });
```

**`app.embedded` serves files compiled into the binary**, for a product that ships as one binary with no `dist/` on the machine it runs on. It is `static` without the disk read ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)): the bytes come from `@embedFile`, and everything after that is the same code (the sorted list, an ETag per file, a gzipped copy made once for the files worth it, the fallback, and nothing per request). A request cannot tell it apart from a directory read at startup.

You can write the `@embedFile` calls yourself, because the path is relative to the file it is written in and nilo cannot know where your `dist/` is. Most programs let `embedDir` write the list from a directory instead ([below](#a-vue-or-react-build-in-the-binary)).

The options are `static`'s minus every one that is about a disk: `index`, `cache_control`, `spa_fallback`, `spa_fallback_for`, `compress` and `compress_min_bytes`, with the same defaults. There is no `max_file_bytes`, because nothing here can be served from disk; no `max_total_bytes`, because the bytes are part of the binary whether or not they are served, so counting them would count memory that is not spent twice; no `dotfiles`, because you wrote every name; and no `reload`, because there is no disk.

Two mistakes a directory cannot make are refused at startup, in one line: a path listed twice (the second entry could never be reached) and a `spa_fallback` that names no entry. There is no `tryEmbedded`: the list was fixed when the program was compiled, so there is nothing the program can do about it at run time but stop.

It costs what a held file costs, minus the bytes: the URL, two ETags and the gzipped copy are allocated once at startup, and the file itself is part of the binary. The log line gives both numbers.

### A Vue or React build in the binary

**`embedDir` in your `build.zig` lists a directory into a module that `app.embedded` takes**, so a front end's build output is carried without a hand-written list ([ADR 009](../adr/009-static-files-are-held-in-memory-or-opened.md)). It is a function of nilo's own `build.zig`, which a dependent imports by the name of the dependency:

```zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize });
const frontend = @import("nilo").embedDir(b, nilo.module("nilo_http"), "frontend/dist");
exe.root_module.addImport("frontend", frontend);
```

The directory is walked each time `zig build` runs, so the next build after `npm run build` carries the new hashed names with nothing to regenerate. It lists regular files only, skips a name with a `.` segment and every symlink (the rules `app.static` follows), and stops the build naming the directory if it holds no files. The module exports `files`. Build the front end before the program: the list is read when the build is configured, so a bundle written while `zig build --watch` is running is carried by the next build you start, not by the running one.

The program mounts it with the page revalidated and the hashed bundles kept:

<!-- compiles -->
```zig
fn mountFrontend(app: *nilo.App, files: []const nilo.static.Embedded) !void {
    try app.embeddedWith("/", files, .{
        .spa_fallback = "index.html",
        .cache_control = "no-cache",
        .cache_rules = &.{
            .{ .prefix = "assets/", .cache_control = "public, max-age=31536000, immutable" },
        },
    });
}
```

and calls `mountFrontend(&app, &@import("frontend").files)`. Vite and Vue write `assets/` with a hash in each name; Create React App writes `static/`, and a flat bundle can be matched by `.suffix = ".js"`. A reload on `/users/42` is the page, and a `fetch('/api/typo')` is a 404 with no catch-all route to write, because only a request that says it is a navigation gets the page. The `examples/embedded` program is this, built and tested with the rest of the examples.

## Following the disk

**`staticWith(.{ .follow = true })` keeps the files in memory and replaces them when the disk changes.** Replace `app.js`, its `.br` or `.gz`, add a file or remove one, and the next response after nilo notices carries it. On Linux it notices in tens of milliseconds (`inotify`); elsewhere, and on a filesystem that raises no events, it looks at the tree every `follow_poll_ms` (default 1,000). Use it where files are replaced under a running server: a directory a deploy tool writes into, a bind mount changed from the host.

It is off by default. A directory read once at startup is a set of URLs a deploy can reason about, and following costs one thread per directory, one `inotify` descriptor (a per-user limit), and a tree that can be read half way through an in-place deploy. A tree is read again as a whole, so what a file is never depends on a neighbour from another write; a response already being written finishes on the tree it began on; a tree that cannot be read keeps the last good one and warns once. A reload costs what the start did, on a thread that serves nothing, so a tree of tens of megabytes wants `follow_poll_ms` raised. A directory replaced by renaming it is found by the periodic look, not at once. Unlike `.reload`, it keeps the gzipped and precompressed copies, which is the difference between 22.8 and 44.3 µs a request on the HTTP/2 board profile ([ADR 277](../adr/277-a-static-directory-can-follow-the-disk-and-a-response-finishes-on-the-tree-it-began-on.md)).

## Reloading files during development

**`staticWith(.{ .reload = true })` holds nothing in memory**: every file stays on disk and is opened per request, so you can edit files under a running server.

It is `max_file_bytes = 0` under another name: every file takes the from-disk path above. No fiber watches anything, and nothing is swapped under live readers. You give up what holding the files buys: the in-memory copy, the gzipped copy, and one open and one stat per request. It says so in the log once at startup, so a release binary built with it on does not hide it.

**A file that did not exist at startup still needs a restart.** The list of names comes from the directory walk, and turning a string from a request into a filename is exactly the path traversal the design rules out.

**A bundler that renames its output is where this goes wrong.** Vite, esbuild and the rest write `app-3f9a1c.js` and a fresh `index.html` pointing at it on every build. With `.reload` on, the edited `index.html` is served and the script it names is a 404, because that name did not exist when the server started. There are two ways around it. Neither is rescanning the directory on a miss, which would let a string from a request decide when the disk is walked ([decided](../decided.md#nilo_http-1)):

- **While developing, serve the frontend from the bundler's own dev server** and proxy `/api` to nilo. Every bundler has the proxy option, hot reload comes with it, and nilo never sees a hashed name until the build is real.
- **Or restart nilo yourself after each bundle.** `zig build dev` will not do it: it restarts when the binary changes and watches nothing else ([Getting started](./getting-started.md#what-triggers-a-restart)), and a bundle landing in `public/` leaves the binary alone.

A production build is written once and the server starts after it, so all the names are there and none of this applies.

## The limits

**The set of file names is fixed at startup.** Without `.reload` or `.follow`, so are the bytes: changing a file means restarting the process, which a deploy does anyway. An embedded tree goes one step further: changing a file means rebuilding the binary.

Static files are not middleware. The file set holds state, so it is a final handler that the middleware chain wraps like any other route. Your logger sees static requests, and CORS applies to them.
