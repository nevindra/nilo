// Bun's answer to the seven routes in bench/s3_server.zig, on Bun.serve with
// the built-in Bun.S3Client.
//
// This is the most interesting row in the table and the reason Bun is in it at
// all: `Bun.S3Client` is not a JavaScript SDK wrapped round fetch — it is
// native code in Bun's runtime, written in Zig, doing SigV4 and HTTP the same
// way nilo does. Every other candidate compares an ecosystem's ordinary
// answer. This one compares two Zig implementations of the same thing, with
// the JavaScript only holding the handler.
//
// Nothing is hand-rolled here for the same reason it is not in the Go and Rust
// candidates: what is being measured is what a service written in this
// language ordinarily costs.
const endpoint = process.env.S3_ENDPOINT || 'http://127.0.0.1:9100';

const BUCKET = 'nilo-test';
const ONE_K = 'bench/1k.bin';
const SIXTY_FOUR_K = 'bench/64k.bin';
const ONE_M = 'bench/1m.bin';
const OCTETS = 'application/octet-stream';

const s3 = new Bun.S3Client({
  accessKeyId: process.env.S3_ACCESS_KEY || 'niloadmin',
  secretAccessKey: process.env.S3_SECRET_KEY || 'nilosecret123',
  region: process.env.S3_REGION || 'us-east-1',
  bucket: BUCKET,
  endpoint,
  // MinIO on an IP address cannot carry the bucket as a DNS label, which is
  // the same reason every other candidate here asks for path style.
  virtualHostedStyle: false,
});

// Allocated and filled **per request**, because that is what the routes they
// are subtracted from do.
//
// The first version built these once and reused them, which was wrong in a way
// that flattered whichever candidate did it: `/o/1m` sizes a buffer from
// `content-length` and fills it every time, so a control handing out the same
// array repeatedly is not the same work minus the object store — it is less
// work. Measured, the gap was 2.2x at a megabyte.
const FILL = 0x78; // 'x'
const warm = (n) => () => send(new Uint8Array(n).fill(FILL), OCTETS);

function send(body, contentType) {
  return new Response(body, {
    headers: {
      'Content-Type': contentType,
      // Explicit, so the megabyte is framed by length rather than chunked.
      // Without it the wire bytes stop matching the other candidates, which is
      // how Node was caught in the sibling benchmark.
      'Content-Length': String(body.byteLength ?? body.length),
    },
  });
}

async function object(key) {
  try {
    // `arrayBuffer` sizes from Content-Length and fills once, which is what
    // every other candidate does — not a growing buffer.
    const bytes = await s3.file(key).arrayBuffer();
    return send(new Uint8Array(bytes), OCTETS);
  } catch (e) {
    return new Response(String(e), { status: 502 });
  }
}

// One warm call before the port opens, so the first request the load generator
// sends is not the one that dials the store.
try {
  await s3.file(ONE_K).arrayBuffer();
} catch (e) {
  console.error(`could not reach ${endpoint}: ${e}`);
  process.exit(1);
}

Bun.serve({
  port: 8813,
  hostname: '0.0.0.0',
  // With CLUSTER=1 the driver starts one process per core and SO_REUSEPORT
  // lets the kernel spread accepts across them. Without it this is Bun's
  // default, which is one thread — and the distance between those two rows is
  // itself a finding, the way it was in the sibling benchmark.
  reusePort: Boolean(process.env.CLUSTER),
  routes: {
    '/health': () => new Response('alive\n', {
      headers: { 'Content-Type': 'text/plain', 'Content-Length': '6' },
    }),
    '/warm/1k': warm(1 << 10),
    '/warm/1m': warm(1 << 20),
    '/o/1k': () => object(ONE_K),
    '/o/64k': () => object(SIXTY_FOUR_K),
    '/o/1m': () => object(ONE_M),
    '/presign': () => {
      const url = s3.presign(ONE_K, { expiresIn: 900 });
      return send(url, 'text/plain');
    },
  },
});
