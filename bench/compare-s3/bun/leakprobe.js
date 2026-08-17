// Which half of `/o/64k` retains — reading the object, or answering with it?
//
// Not part of the comparison. This exists because Bun 1.3.13 could not finish
// the harness: it grew by about the number of bytes `Bun.S3Client` read, gave
// none of it back when idle, and was killed by the kernel at 27 GB. The
// numbers are in `bench/result/s3.md`. What they do not say is *where* the
// bytes are held, and that is the first thing a Bun maintainer will ask.
//
// Three routes, one S3 client, one key, differing only in what happens to the
// bytes after they arrive:
//
//   /read    read the object, answer with its length as text — the bytes are
//            dropped and nothing but a number leaves the handler
//   /send    read it and answer with it, which is what `/o/64k` does
//   /alloc   allocate the same 64 KB locally and answer with it, no S3 at all
//
// If `/read` climbs, the read path retains and the response path is innocent.
// If only `/send` climbs, it is the response path. `/alloc` is the control
// that says a 64 KB body per request is not itself the problem — in the main
// run `/warm/1m` allocated 20.8 GB in five seconds and grew 32 MB, so the
// collector keeps up with allocation fine.
//
// Run it with `bun` confined, so an answer costs a dead `bun` rather than a
// dead machine — the OOM killer that fired during the sweep was global and
// took MinIO and a Postgres container with it:
//
//   systemd-run --user --scope -p MemoryMax=6G -p MemorySwapMax=0 \
//     bun bench/compare-s3/bun/leakprobe.js
//
// then hammer one route at a time and watch `VmRSS` in /proc/<pid>/status:
//
//   wrk -t4 -c64 -d3s http://127.0.0.1:8814/read
//
// Needs the same bucket and objects as the rest: `python3 bench/s3_setup.py`.
const endpoint = process.env.S3_ENDPOINT || 'http://127.0.0.1:9100';
const KEY = 'bench/64k.bin';
const N = 65536;

const s3 = new Bun.S3Client({
  accessKeyId: process.env.S3_ACCESS_KEY || 'niloadmin',
  secretAccessKey: process.env.S3_SECRET_KEY || 'nilosecret123',
  region: process.env.S3_REGION || 'us-east-1',
  bucket: 'nilo-test',
  endpoint,
  virtualHostedStyle: false,
});

// One warm call before the port opens, so the first request is not the one
// that dials the store.
await s3.file(KEY).arrayBuffer();

Bun.serve({
  port: 8814,
  hostname: '127.0.0.1',
  routes: {
    '/read': async () => {
      const bytes = await s3.file(KEY).arrayBuffer();
      return new Response(String(bytes.byteLength));
    },
    '/send': async () => {
      const bytes = await s3.file(KEY).arrayBuffer();
      return new Response(new Uint8Array(bytes));
    },
    '/alloc': () => new Response(new Uint8Array(N).fill(0x78)),
    '/health': () => new Response('alive\n'),
  },
});
