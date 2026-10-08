// Load bench/page_server.zig's page in headless Chromium, cold each time, and
// say what protocol it came over, over how many connections, and how long it
// took (stage 7 of framing, ADR 259, ADR 027).
//
//   node bench/page_load.mjs --port 8443 --runs 10            # offers h2 as Chromium does
//   node bench/page_load.mjs --port 8443 --runs 10 --http1    # Chromium's --disable-http2
//   node bench/page_load.mjs --port 8443 --runs 10 --latency 20   # +20 ms on every request
//
// A fresh browser and profile every run, so no connection, session or cache
// carries over. The certificate is not checked (the server's is the suite's
// self-signed fixture). The connection count is the distinct connection ids
// Chromium reports for the page's own requests; the WebSocket is not among
// them, because Chromium reports no connection id for it; its handshake
// status (101, HTTP/1.1's upgrade) and the sockets the server holds are what
// say where it went (a browser that had tried it over an h2 connection would
// have failed: no SETTINGS_ENABLE_CONNECT_PROTOCOL).
// Needs Node 22 or later (its global WebSocket) and `chromium` on the PATH.

import { execSync, spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const args = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i < 0 ? fallback : args[i + 1];
};
const port = Number(opt("port", "8443"));
const runs = Number(opt("runs", "10"));
const latency = Number(opt("latency", "0"));
const http1 = args.includes("--http1");
const debugPort = 9300 + Math.floor(Math.random() * 500);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function once() {
  const dir = mkdtempSync(join(tmpdir(), "nilo-page-"));
  const flags = [
    "--headless=new",
    `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${dir}`,
    "--ignore-certificate-errors",
    "--no-first-run",
    "--disable-gpu",
    "--no-sandbox",
    ...(http1 ? ["--disable-http2"] : []),
    "about:blank",
  ];
  const browser = spawn("chromium", flags, { stdio: "ignore" });
  try {
    let target;
    for (let i = 0; i < 100 && !target; i++) {
      try {
        const list = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
        target = list.find((t) => t.type === "page");
      } catch {}
      if (!target) await sleep(100);
    }
    if (!target) throw new Error("no page target");
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
    let id = 0;
    const pending = new Map();
    const responses = [];
    let wsStatus = null;
    ws.onmessage = (m) => {
      const msg = JSON.parse(m.data);
      if (msg.id && pending.has(msg.id)) {
        pending.get(msg.id)(msg.result ?? msg.error);
        pending.delete(msg.id);
      } else if (msg.method === "Network.webSocketHandshakeResponseReceived") {
        wsStatus = msg.params.response.status;
      } else if (msg.method === "Network.responseReceived") {
        const r = msg.params.response;
        responses.push({ url: r.url, protocol: r.protocol, connection: r.connectionId });
      }
    };
    const send = (method, params = {}) =>
      new Promise((res) => {
        pending.set(++id, res);
        ws.send(JSON.stringify({ id, method, params }));
      });
    await send("Network.enable");
    await send("Network.setCacheDisabled", { cacheDisabled: true });
    if (latency > 0)
      await send("Network.emulateNetworkConditions", {
        offline: false, latency, downloadThroughput: -1, uploadThroughput: -1,
      });
    await send("Page.navigate", { url: `https://localhost:${port}/` });

    let done = null;
    for (let i = 0; i < 600 && done === null; i++) {
      await sleep(25);
      const r = await send("Runtime.evaluate", { expression: "window.__done||0", returnByValue: true });
      if (r.result?.value) done = r.result.value;
    }
    if (done === null) throw new Error("the page never finished");
    const r = await send("Runtime.evaluate", {
      returnByValue: true,
      expression: `JSON.stringify({
        load: performance.getEntriesByType("navigation")[0].loadEventEnd,
        done: window.__done,
        ws: window.__r.ws,
        sse: window.__r.sse,
        protocols: [...new Set(performance.getEntriesByType("resource").map((e) => e.nextHopProtocol))],
        resources: performance.getEntriesByType("resource").length,
      })`,
    });
    const page = JSON.parse(r.result.value);
    const own = responses.filter((x) => x.connection !== undefined);
    page.connections = new Set(own.map((x) => x.connection)).size;
    page.wireProtocols = [...new Set(own.map((x) => x.protocol))];
    // 101 is HTTP/1.1's upgrade: a WebSocket over h2 would have been a 200
    // to an extended CONNECT, which nilo does not offer (ADR 260).
    page.wsStatus = wsStatus;
    // Sockets the server holds for this browser right now: the page's
    // connections and the WebSocket's own, the event stream riding the first.
    page.sockets = Number(
      execSync(`ss -Htn state established '( sport = :${port} )' | wc -l`, { shell: "/bin/bash" }).toString().trim(),
    );
    ws.close();
    return page;
  } finally {
    browser.kill("SIGKILL");
    await sleep(200);
    rmSync(dir, { recursive: true, force: true });
  }
}

const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const rows = [];
for (let i = 0; i < runs; i++) {
  const p = await once();
  rows.push(p);
  console.log(
    `run ${i + 1}: load ${p.load.toFixed(1)} ms, all done ${p.done.toFixed(1)} ms, ` +
      `${p.connections} connections, ${p.resources} resources, nextHop ${p.protocols.join("+")}, ` +
      `wire ${p.wireProtocols.join("+")}, ws ${p.ws} (handshake ${p.wsStatus}), sse ${p.sse}, ${p.sockets} sockets open`,
  );
}
const stat = (k) => {
  const xs = rows.map((r) => r[k]);
  return `median ${median(xs).toFixed(1)} (${Math.min(...xs).toFixed(1)} to ${Math.max(...xs).toFixed(1)})`;
};
console.log(`load: ${stat("load")} ms; all done: ${stat("done")} ms; connections: ${[...new Set(rows.map((r) => r.connections))].join(",")}`);
