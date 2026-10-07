//! A page with a dozen subresources, served over TLS, for what a browser
//! gets from `h2` against `http/1.1` (stage 7 of
//! [framing](../docs/design/framing.md), ADR 259, ADR 027).
//!
//! ```
//! zig build bench-page-server -Dtls -Dhttp2 -Doptimize=ReleaseFast
//! PORT=8443 STATIC_DIR=/tmp/files zig-out/bin/nilo-bench-page-server
//! node bench/page_load.mjs --port 8443 --runs 10
//! ```
//!
//! `/` is the page: four stylesheets, four scripts, eight images, a `fetch`
//! of JSON, an `EventSource` on `/events` and a WebSocket on `/ws`. The
//! script sets `window.__done` once every one has answered, which is what
//! `page_load.mjs` waits for. The WebSocket is here to show where a browser
//! that negotiated `h2` puts it: nilo sends no
//! `SETTINGS_ENABLE_CONNECT_PROTOCOL`, so Chromium opens it on an HTTP/1.1
//! connection of its own (ADR 260).
//!
//! `STATIC_DIR`, when set, is served at `/files`: the 1 MiB and 64 MiB
//! files the static-throughput rows of `bench/result/http.md` are read from
//! (a file over `max_file_bytes` is spilled, read from the disk per request).
//!
//! The certificate is the suite's fixture, read relative to the checkout.

const std = @import("std");
const nilo = @import("nilo_http");

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

const css_body = "/* a stylesheet */\n.a{color:#123;margin:0;padding:0}\n" ** 60;
const js_body = "/* a script */\nwindow.__n=(window.__n||0)+1;\n" ** 200;
const img_body =
    "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='64'>" ++
    "<rect width='64' height='64' fill='#369'/></svg>";
const json_body = "{\"id\":42,\"name\":\"Routed Tester\",\"bio\":\"" ++ ("A systems nerd. " ** 60) ++ "\"}";

const page_head =
    "<!doctype html><meta charset=utf-8><title>page</title>" ++
    "<link rel=stylesheet href=/css/0.css><link rel=stylesheet href=/css/1.css>" ++
    "<link rel=stylesheet href=/css/2.css><link rel=stylesheet href=/css/3.css>" ++
    "<script src=/js/0.js defer></script><script src=/js/1.js defer></script>" ++
    "<script src=/js/2.js defer></script><script src=/js/3.js defer></script>";
const page_body =
    "<img src=/img/0.svg><img src=/img/1.svg><img src=/img/2.svg><img src=/img/3.svg>" ++
    "<img src=/img/4.svg><img src=/img/5.svg><img src=/img/6.svg><img src=/img/7.svg>" ++
    "<script>" ++
    "const R={};window.__r=R;" ++
    "function check(){if(R.sse&&R.ws&&R.json&&R.loaded)window.__done=performance.now()}" ++
    "const es=new EventSource('/events');" ++
    "es.onopen=()=>fetch('/api/poke').then(r=>r.text());" ++
    "es.onmessage=e=>{R.sse=e.data;check()};" ++
    "const ws=new WebSocket('wss://'+location.host+'/ws');" ++
    "ws.onopen=()=>ws.send('ping');" ++
    "ws.onmessage=e=>{R.ws=e.data;check()};" ++
    "fetch('/api/data').then(r=>r.json()).then(j=>{R.json=j.id;check()});" ++
    "addEventListener('load',()=>{R.loaded=performance.now();check()});" ++
    "</script>";

var feed: nilo.Room = undefined;

fn page(c: *nilo.Ctx) !void {
    try c.send(200, "text/html; charset=utf-8", page_head ++ "<body>" ++ page_body);
}

fn css(c: *nilo.Ctx) !void {
    try c.send(200, "text/css", css_body);
}

fn js(c: *nilo.Ctx) !void {
    try c.send(200, "text/javascript", js_body);
}

fn img(c: *nilo.Ctx) !void {
    try c.send(200, "image/svg+xml", img_body);
}

fn data(c: *nilo.Ctx) !void {
    try c.send(200, "application/json", json_body);
}

fn poke(c: *nilo.Ctx) !void {
    feed.print("poked", .{}) catch {};
    try c.sendText(200, "ok");
}

fn events(c: *nilo.Ctx) !void {
    return c.eventsFrom(&feed, .{ .keepalive_ms = 0 });
}

fn echoLoop(socket: *nilo.Socket, _: *nilo.Room) !void {
    while (try socket.receive()) |message| try socket.send(message.kind, message.data);
    try socket.close(.normal, "");
}

fn ws(c: *nilo.Ctx) !void {
    return c.upgrade(echoLoop, &feed);
}

pub fn main(init: std.process.Init) !void {
    const env = init.minimal.environ;
    const port: u16 = if (env.getPosix("PORT")) |p| try std.fmt.parseInt(u16, p, 10) else 8443;

    feed = try nilo.Room.initWith(std.heap.smp_allocator, .{ .seats = 64 });
    defer feed.deinit();

    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.get("/", page);
    try app.get("/css/:n", css);
    try app.get("/js/:n", js);
    try app.get("/img/:n", img);
    try app.get("/api/data", data);
    try app.get("/api/poke", poke);
    try app.get("/events", events);
    try app.get("/ws", ws);
    if (env.getPosix("STATIC_DIR")) |dir| try app.static("/files", dir);

    try app.listen(.{ .port = port, .tls = .{
        .cert = "http/testdata/tls/localhost.pem",
        .key = "http/testdata/tls/localhost-key.pem",
    } });
}
