# Forms

An HTML form is not JSON. A browser posts
`application/x-www-form-urlencoded`, and the moment the form has a file in it,
`multipart/form-data`. `Form(T)` reads both.

```zig
const SignIn = struct {
    email: nilo.Str,
    password: nilo.Str,
    remember: nilo.Str = .static(""),   // an unticked checkbox is not sent at all
};

fn signIn(incoming: nilo.Form(SignIn)) !nilo.Redirect(303) {
    ... incoming.value.email ...
    return .to("/welcome");
}
```

It is the same idea as [`Query(T)`](./requests.md#query-params),
moved from the query string to the body: one field per form field, a field's
type says what its text has to become, and a default is what "not sent" means.

| Field | Means |
|---|---|
| `email: Str` | required — absent is a 400 saying which |
| `page: u32` | converted, and `page=soon` is a 400 saying so |
| `sort: enum { newest, oldest }` | one of those words, or a 400 listing them |
| `nickname: ?Str = null` | optional: absent is null |
| `limit: u32 = 20` | absent means the default |
| `avatar: Upload` | a file — see below |

The messages are the ones a query param gets, because it is the same code:
`"age" has to be a whole number, not "soon"`.

## Which encoding arrived is not your problem

A browser picks urlencoded or multipart depending on whether the form has a
file in it. That is a fact about the browser, so `Form(T)` reads either and the
handler never asks — the same way `c.body()` reads a chunked body and a
`Content-Length` one without saying which turned up.

A body that is neither gets a 400 naming what was sent:

```
this endpoint takes a form, so the body has to be sent as
application/x-www-form-urlencoded or multipart/form-data — this one arrived
as "application/json"
```

## Files

A field typed `nilo.Upload` is a file. Three pieces, all `Str`:

```zig
const NewAvatar = struct {
    caption: nilo.Str,
    image: nilo.Upload,
};

fn upload(incoming: nilo.Form(NewAvatar)) !nilo.Status(201, Avatar) {
    const image = incoming.value.image;
    image.filename.view()      // "me.png"
    image.content_type.view()  // "image/png"
    image.bytes.view()         // the file
    image.len()                // how big it is
}
```

`?Upload = null` is a file that may not have been chosen.

A form with an `Upload` in it can only arrive as multipart, so one that does
not gets told which to send rather than being reported as a missing field:

```
this endpoint takes a file, so the form has to be sent as
multipart/form-data — this one arrived as application/x-www-form-urlencoded.
In HTML that is <form enctype="multipart/form-data">.
```

### The filename is not a path

**`filename` is whatever the client sent.** `../../etc/passwd` is a filename a
browser will happily send if asked to. Store the bytes under a name of your
own; treat this one as a label to show somebody. `content_type` is likewise the
client's claim, not a fact — sniff the bytes if it matters.

### How big a form can be

The whole body is read into the request arena, bounded by `listen()`'s
`max_body` — **1 MB by default**. A form is read into a struct, and a struct is
not something you can have half of.

For an upload bigger than that, turn `max_body` up, or take the body in pieces
yourself with [`c.bodyStream()`](./requests.md#bodies-too-big-to-hold), where
nothing is held in memory at all. `Form(T)` is the convenient one; the stream
is the one with no ceiling.

Inside the ceiling nothing is copied: a file's bytes are a slice of the body
that was already read, not a second copy of it.

## When one field is wrong and the rest are fine

`Form(T)` is all-or-nothing: the first field that will not convert is a 400 and
the request is over. For an API that is usually what you want. For a page, it
is not — somebody mistypes their age and loses everything else they typed.

`Bound(Form(T))` hands the failures to the handler instead:

```zig
fn signUp(b: nilo.Bound(nilo.Form(SignUp))) !nilo.Redirect(303) {
    const form = b.value() orelse return b.fail();
    ...
}
```

`b.fail()` is a **422** naming every field that did not bind:

```
2 fields did not fit: the form is missing "email" (text);
"age" has to be a whole number, not "soon"
```

`value()` is an optional and there is no way past it. A field that did not bind
holds nothing worth reading, so the binding withholds the whole struct rather
than letting you read a zero nobody sent.

### Showing the form again

What a page needs is not the converted values — it is **what the person
typed**. You put `soon` back in the age box, not `0`. That is `given`, and it
works for every field whether or not it bound:

```zig
fn signUp(arena: std.mem.Allocator, b: nilo.Bound(nilo.Form(SignUp))) !Page {
    if (b.value()) |form| return welcome(form);

    var wrong: std.ArrayList(Problem) = .empty;
    var it = b.failures();
    while (it.next()) |f| {
        f.field      // "age"
        f.reason     // .not_a_number
        f.given      // Str "soon" — what arrived
        f.expected   // "a whole number"
        try f.say(w) // nilo's own sentence, so yours cannot drift from it
    }

    return signUpPage(.{
        .email = b.given("email").view(),   // still in the box
        .age = b.given("age").view(),       // "soon", so they can see it
        .problems = wrong.items,
    });
}
```

The field name in `given("…")` is checked while compiling — a typo there would
otherwise be an empty box nobody notices.

### What it does not do

The reasons are exactly the conversions nilo already performs: `.missing`,
`.not_a_number`, `.not_true_or_false`, `.not_a_choice`, `.wrong_kind`. **This
is not a validator.** Whether the age is plausible, whether the email has an
`@`, whether the two passwords match — all yours.

And three things stay a plain 400, because none of them leaves a binding to
hand back: a body that is not a form at all, text that is not JSON, and a field
the endpoint has never heard of.

The same wrapper works on the other two slots: `Bound(T)` for a JSON body and
`Bound(Query(T))` for the query string.

## A form is the body

`Form(T)` sits exactly where a plain struct argument would have read JSON.
They are the same bytes read two ways, so asking for both stops compilation:

```zig
// nilo: the handler for route "/sign-up" asks for both a request body
// (argument 1, a main.Profile) and a form (argument 2) — and a request only
// has one body.
fn signUp(profile: Profile, incoming: nilo.Form(SignIn)) !void { … }
```

## From a `Ctx`

`c.form(T)` is the same thing for a handler holding a `*Ctx`, the way
`c.json(T)` is for a JSON body:

```zig
fn signIn(c: *nilo.Ctx) !void {
    const incoming = try c.form(SignIn);
    ...
}
```

`c.formCollecting(T, &outcomes)` and `c.jsonCollecting(T, &outcomes)` are what
`Bound(…)` is built on, for a `*Ctx` handler that wants the failures.

## Testing one

A `Form(T)` is an ordinary struct, so a test builds one and never writes a
request body:

```zig
const answer = try signIn(&sessions, arena, .{ .value = .{
    .email = .static("wati@example.dev"),
    .password = .static("hunter2"),
} });
```

For the multipart case — where the framing is the thing being tested — the
[test client](./testing.md) posts a real body:

```zig
const answer = try client.postWith(
    &app,
    "/sign-in",
    "application/x-www-form-urlencoded",
    "email=wati%40example.dev&password=hunter2",
);
```

## In the document

The generated API description says which encoding the endpoint takes —
`application/x-www-form-urlencoded`, or `multipart/form-data` once there is a
file — and describes the file as bytes rather than as the struct carrying it.
See [OpenAPI](./openapi.md).

## See also

- [`examples/forms`](../../examples/forms/main.zig) — a form, a session cookie,
  an upload and a redirect, end to end.
- [Cookies](./cookies.md), which is what a sign-in does next.
- [ADR 0031](../adr/0031-a-form-is-the-body-read-by-another-rule.md) — why
  `Form(T)` is explicit rather than sniffed, and what the multipart parser is
  careful about.
- [ADR 0036](../adr/0036-a-binding-hands-its-failures-to-the-handler.md) — why
  `value()` is an optional, why the reason list stops where it does, and what
  stays a plain 400.
