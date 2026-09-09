# A response is read back the way it was written

`testing.Client` drives a real request into a real `App` with no server and no
socket, and a caller listed it under *what worked, first try*. Two things around
it were still theirs.

## An `Answer` handed back bytes

nilo had already decided how the value was written — `json.write` generated the
writer from the type — and a test asking what came back reached for `std.json`
and walked a `Value`:

```zig
const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
return parsed.value.object.get("id").?.string;
```

Four lines and an `.?.string` at every call site, to pull one field out of a
create.

```zig
pub fn bytes(self: Answer, arena: std.mem.Allocator) ![]const u8
pub fn json(self: Answer, comptime T: type, arena: std.mem.Allocator) !T
```

`bytes` is `text` with the buffer sized for you, and it de-chunks — a streamed
response read straight off `answer.body` is chunk framing and a parse error.
A chunked body decodes to fewer bytes than it was framed in, so one allocation
the size of the framed body is always enough and there is no growing.

Everything is copied into `arena`, because `answer.body` points into the client's
one response buffer and the next request writes over it.

### Unknown fields are ignored here, and refused on the way in

That is the opposite rule to `ctx.json`, and the difference is who owns the extra
field. A request body with a field nilo does not know is the *client's* typo and
is a 400 naming it. A response with more fields than the test asked about is the
ordinary case — the test is asking a question about part of it. A test that means
to assert the whole shape asks for `std.json.Value` and compares that.

## An `App` and a `Client` were assembled by hand

The caller had a `Wired` struct in each http test file — two copies driving 17
tests, each holding a `pgtest.Db`, an `App`, the `provide` calls, the `docs`
call, the group registration and a `Client`. They said they would take it in
whatever shape nilo wanted.

```zig
var wired = try nilo.testing.Wired.init(testing.allocator, .{});
defer wired.deinit();

try wired.app.provide(&db);
try wired.app.post("/partners", createPartner);

const answer = try wired.post("/partners", body);
```

**The routes and the services stay yours**, which is where the line is. `app` is
a plain field rather than something behind methods, so every registration call is
the one the reference already documents and none of them is wrapped. What `Wired`
owns is the pair: building both, tearing both down in the right order, and
knowing which `App` each request goes to.

The database is not in it. `pgtest.Db` is the caller's own type over a real
Postgres, and a nilo type that assumed a database would be wrong for the nine
suites that have none.

**`Client` is unchanged and is still there.** A test that drives two clients
against one App — two addresses, two cookie jars — makes them itself. This is the
shape nine tests in ten have, offered once rather than written per file.

## Against ADR 0018's four axes

Nothing here is in a running server, so all four are zero by construction. It is
the same argument the rest of `testing.zig` makes.

## Consequences

- `Answer.text(&buf)` stays: a test that already has a buffer and wants no
  allocator is a fair thing to write, and `bytes` is written on top of it.
- `Wired.deinit` puts the client down before the App, which is the order a pair
  of `defer`s would have run them in.
