// Bun.serve with its built-in route patterns — the closest Bun equivalent to
// a routed GET with a path param.
const bio = 'A systems nerd who writes Zig before breakfast. '.repeat(19);
const MAX_ID = 1000000;

Bun.serve({
  port: 8804,
  hostname: '127.0.0.1',
  // With CLUSTER=n the driver starts n of these; SO_REUSEPORT lets the kernel
  // spread accepts across them. Without it this is one thread, Bun's default.
  reusePort: Boolean(process.env.CLUSTER),
  routes: {
    '/users/:id': (req) => {
      const raw = req.params.id;
      const id = Number(raw);
      if (!Number.isInteger(id) || id <= 0 || id > MAX_ID) {
        return new Response(`no user ${raw}`, {
          status: 404,
          headers: {
            'Content-Type': 'text/plain',
            'Access-Control-Allow-Origin': '*',
          },
        });
      }
      // Serialised per request, like zfast.
      const body = JSON.stringify({
        id,
        name: 'Routed Tester',
        email: 'tester@example.dev',
        bio,
      });
      return new Response(body, {
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
      });
    },
    '/health': () => new Response('alive\n'),
  },
});
