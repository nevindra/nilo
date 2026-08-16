// Node stdlib http. There is no router in the standard library, so the match
// is hand-rolled — which is what "Node stdlib" means in practice.
//
// CLUSTER=n forks n workers sharing the port. Without it this is one thread,
// which is Node's default and the reason the two numbers differ so much.
const http = require('node:http');
const cluster = require('node:cluster');

const WORKERS = Number(process.env.CLUSTER || 0);

if (WORKERS > 0 && cluster.isPrimary) {
  for (let i = 0; i < WORKERS; i++) cluster.fork();
  return;
}

const bio = 'A systems nerd who writes Zig before breakfast. '.repeat(19);
const MAX_ID = 1000000;

const server = http.createServer((req, res) => {
  const m = /^\/users\/([^/?]+)$/.exec(req.url);
  if (m !== null) {
    const id = Number(m[1]);
    if (!Number.isInteger(id) || id <= 0 || id > MAX_ID) {
      res.writeHead(404, {
        'Content-Type': 'text/plain',
        'Access-Control-Allow-Origin': '*',
      });
      res.end(`no user ${m[1]}`);
      return;
    }
    // Serialised per request, like nilo.
    const body = JSON.stringify({
      id,
      name: 'Routed Tester',
      email: 'tester@example.dev',
      bio,
    });
    // Content-Length explicitly: without it Node picks chunked transfer
    // encoding, which puts 12 bytes of framing on the wire that no other
    // candidate here sends.
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
      'Access-Control-Allow-Origin': '*',
    });
    res.end(body);
    return;
  }

  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('alive\n');
    return;
  }

  res.writeHead(404);
  res.end();
});

server.keepAliveTimeout = 65000;
server.listen(8803, '127.0.0.1');
