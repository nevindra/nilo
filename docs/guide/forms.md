# Forms

**`Form(T)` reads an HTML form, urlencoded or multipart, into a struct of yours, and each field's type says what its text has to become.**

**Reference:** [`Form(T)`](../reference/handlers.md#handler-arguments), [`Bound(W)`](../reference/handlers.md#boundw), [`Upload`](../reference/ctx.md#upload), [`c.form`](../reference/ctx.md#reading) · **Design:** [Request input](../design/request-input.md)

An HTML form is not JSON. A browser posts `application/x-www-form-urlencoded`, and as soon as the form has a file in it, `multipart/form-data`. `Form(T)` reads both.

```zig
const SignIn = struct {
    email: nilo.Str,
    password: nilo.Str,
    remember: bool = false,   // an unticked checkbox is not sent at all
};

fn signIn(incoming: nilo.Form(SignIn)) !nilo.Redirect(303) {
    ... incoming.value.email ...
    return .to("/welcome");
}
```

It works like [`Query(T)`](./requests.md#query-params), but reads the body instead of the query string: one struct field per form field, the field's type says what its text has to become, and a default says what "not sent" means.

| Field | Means |
|---|---|
| `email: Str` | required: absent is a 400 saying which field |
| `page: u32` | converted, and `page=soon` is a 400 saying so |
| `sort: enum { newest, oldest }` | one of those words, or a 400 listing them |
| `nickname: ?Str = null` | optional: absent is null, with or without the `= null` |
| `limit: u32 = 20` | absent means the default |
| `remember: bool = false` | a checkbox, see below |
| `tags: []const Str = &.{}` | a checkbox group or a `<select multiple>`, see below |
| `avatar: Upload` | a file, see below |

The error messages are the same ones a query param gets, because it is the same code: `"age" has to be a whole number, not "soon"`.

## Checkboxes

**A checkbox is a `bool` with a default of `false`.** A ticked checkbox posts `on`. An unticked one posts **nothing at all** (its name does not appear in the body), so the field needs the default:

```zig
newsletter: bool = false,
```

Ticked gives `true`, unticked leaves the default, and that is all. `true` and `false` are accepted too, for a client that is not a browser.

**Only a form reads `on` this way.** The same field in a `Query(T)` or a JSON body accepts only `true` or `false`, because `on` is an HTML convention, not a boolean. A JSON client sending `"on"` has a bug, and an error is more useful than a guess. `off` is not accepted anywhere: no browser sends it, and an unticked box is a missing field, not a present false one.

## Checkbox groups and multiple selects

**A field that is a slice collects every value sent under its name.** Three boxes named `tags` post `tags=zig&tags=http` when two are ticked, and a `<select multiple>` posts the same shape. The values arrive in the order the browser sent them, and each one is converted the way a single field would be ([ADR 132](../adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md)):

<!-- compiles -->
```zig
const NewPost = struct {
    title: nilo.Str,
    tags: []const nilo.Str = &.{},
    notify: []const enum { comment, mention } = &.{},
};

fn create(incoming: nilo.Form(NewPost)) !nilo.Redirect(303) {
    for (incoming.value.tags) |tag| _ = tag;
    return .to("/posts");
}
```

**Nothing ticked gives an empty list**, never a 400: a group with no box ticked sends no name at all, which is what every filter and every opt-in already means by not being sent. Give the field `= &.{}` and the document marks it optional. **An empty value adds nothing**, so a row of text boxes named `alias` with two left blank gives a list of the ones filled in. **A comma inside a value is just a comma**: a browser never joins a group with commas, so unlike a [query list](./requests.md#query-params) there is no second spelling to read, and `tags=a%2Cb` is one tag. A list of `Upload` is refused at compile time, because a file is a part, not a value, and a field takes one.

**A blank box on a field that may be absent counts as not given.** A browser sends an empty box as `age=`, so an optional or defaulted number, bool or choice reads it as its default, or null, rather than as a 400. Text keeps the empty string: an empty `?Str` is `""`, and `blank()` tells you whether anything was typed. A required field left blank is still refused.

A value that will not convert, such as `notify=nonsense`, gets the 400 the single field would have got, naming the field. Behind a [`Bound(Form(T))`](#collecting-every-field-error-bound) the first bad value is recorded and the rest of the list is still read, so a group with one bad box is still a group rather than a form with nothing in it.

## Urlencoded and multipart bodies

**`Form(T)` reads either encoding, so the handler never has to check which one arrived.** A browser picks urlencoded or multipart depending on whether the form has a file in it. That is the browser's choice, so `Form(T)` handles both, the same way `c.body()` reads a chunked body and a `Content-Length` one without saying which it got.

A body that is neither gets a 400 naming what was sent:

```
this endpoint takes a form, so the body has to be sent as
application/x-www-form-urlencoded or multipart/form-data — this one arrived
as "application/json"
```

## File uploads

**A field typed [`nilo.Upload`](../reference/ctx.md#upload) is a file.** It has three pieces, all `Str`:

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

`?Upload = null` is a file that may not have been chosen. **A file input left empty in a browser counts as not chosen**: the browser sends it as a part with an empty filename and no bytes, and nilo reads that as no file, so an optional `Upload` is null and a required one is a 400 saying the form is missing the file. An edit form can therefore write `if (incoming.value.avatar) |a| …` and keep the old file when nothing new was picked. A file that was chosen and happens to be empty has a filename and is still an `Upload` of 0 bytes.

A form with an `Upload` in it can only arrive as multipart, so a request that is not multipart is told which encoding to send, instead of getting a "missing field" error:

```
this endpoint takes a file, so the form has to be sent as
multipart/form-data — this one arrived as application/x-www-form-urlencoded.
In HTML that is <form enctype="multipart/form-data">.
```

### The uploaded filename

**`filename` is whatever the client sent, so never use it as a path.** A browser will happily send `../../etc/passwd` as a filename if asked to. Store the bytes under a name of your own, and treat this one as a label to show somebody. `content_type` is also just the client's claim; check the bytes if it matters.

nilo reads the plain `filename`, not RFC 6266's `filename*=UTF-8''…`, which is the encoded form a browser sends *alongside* it for a name that is not Latin-1. A part carrying **only** the encoded form is a 400 naming the part ([ADR 073](../adr/073-a-header-is-answered-as-asked-or-refused.md)). It is refused rather than read as a text field full of upload bytes, which is what used to happen. No browser sends that shape; a hand-written HTTP client can.

### Saving an upload to disk

**[`saveTo`](../reference/ctx.md#upload) writes the bytes into a directory, under a name you choose:**

<!-- compiles -->
```zig
const Uploads = struct { dir: nilo.Dir };

const Avatar = struct {
    caption: nilo.Str,
    image: nilo.Upload,
};

fn setAvatar(uploads: *Uploads, account: u32, incoming: nilo.Form(Avatar)) !nilo.Status(201, void) {
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "{d}.png", .{account});
    try incoming.value.image.saveTo(uploads.dir, name);
    return .{};
}
```

The `Dir` is opened once at startup and held as a service, exactly like the one [`FileBody`](responses.md#files) takes, and it can be the same one, which is the case `saveTo` is careful about. **The file is either replaced completely or not touched**: the bytes go to a temporary name next to it and one rename puts them in place, so a request reading that name during the write gets the old file, not a truncated one ([ADR 097](../adr/097-a-file-is-written-by-the-engine.md)).

Passing `image.filename` as the name returns `error.NameNotAllowed` instead of resolving it as a path inside the directory. `sendFile` makes the same check on the way out, for the same reason.

The fiber pauses for the write while the thread keeps serving every other connection it holds, so there is nothing to wrap in `nilo.blocking`.

### Form size limit

**A form is read whole into the request arena, up to `listen()`'s `max_body`, which is 1 MB by default.** A form is read into a struct, and you cannot have half a struct.

For a bigger upload, raise the limit for that one route with [`app.with(nilo.maxBody(50 << 20))`](../reference/middleware.md#nilomaxbody), rather than for the whole server. Or read the body in pieces yourself with [`c.bodyStream()`](./requests.md#streaming-a-large-body), which holds nothing in memory at all. `Form(T)` is the convenient option; the stream is the one with no limit.

**A form is also bounded by how many fields it carries**: 256 parts of a multipart form, and 1,024 pairs of a urlencoded one. Past either it is a 400 that says so, rather than a form with the rest silently left blank ([ADR 030](../adr/030-a-form-is-the-body-read-by-another-rule.md)).

Within the limit nothing is copied: a file's bytes are a slice of the body that was already read, not a second copy.

## Collecting every field error (`Bound`)

**`Bound(Form(T))` gives the handler every failed field, instead of stopping at the first one with a 400.** Plain `Form(T)` is all-or-nothing: the first field that will not convert is a 400 and the request is over. For an API that is usually what you want. For a page it is not, because somebody who mistypes their age loses everything else they typed.

[`Bound(Form(T))`](../reference/handlers.md#boundw) hands the failures to the handler instead:

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

`value()` returns an optional, and there is no way around it. A field that did not bind holds nothing worth reading, so the binding withholds the whole struct rather than letting you read a zero nobody sent.

### Showing the form again

**To refill the form, use `given`: it returns what the person typed, for every field, whether it bound or not.** A page needs the raw input, not the converted values: you put `soon` back in the age box, not `0`.

```zig
fn signUp(arena: std.mem.Allocator, b: nilo.Bound(nilo.Form(SignUp))) !Page {
    if (b.value()) |form| return welcome(form);

    var wrong: std.ArrayList(Problem) = .empty;
    var it = b.failures();
    while (it.next()) |f| {
        f.field      // "age"
        f.reason     // .not_a_number — null when it is a rule of yours
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

The field name in `given("…")` is checked at compile time; otherwise a typo there would be an empty box nobody notices.

### Validating text length and format

**`nilo.Text` checks a string's length or pattern the way a number type checks its range.** The failure reasons above are exactly the conversions nilo performs: `.missing`, `.not_a_number`, `.not_true_or_false`, `.not_a_choice`, `.wrong_kind`. **This is not a validation library.** But a `u8` already refuses 300 without anyone calling it validation, and text can have a shape in the same way ([ADR 193](../adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)):

<!-- compiles -->
```zig
fn startsWithSku(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "SKU-");
}

const SignUp = struct {
    email: nilo.Email,
    password: nilo.Text(.{ .min = 10, .max = 72 }),
    nickname: nilo.Text(.{ .max = 30 }) = .of(""),
    sku: nilo.Text(.{ .check = startsWithSku, .said = "has to be a SKU code" }),
    confirm: Str,

    pub fn nilo_check(self: SignUp, r: *nilo.Rules(SignUp)) void {
        r.must("confirm", self.password.eql(self.confirm.view()), "has to match the password");
    }
};
```

A [`nilo.Text`](../reference/handlers.md#handler-arguments) is a `Str` that parses itself, so it works wherever a `Str` does (a form field, a query value, a JSON body, a path param) and is refused with the same one sentence in all four. `min` and `max` count characters (code points, the same thing JSON Schema's `minLength` counts). `check` is any `fn ([]const u8) bool` of your own, with `said` as its sentence, worded like `must`'s. `Email` and `Url` are presets. The `Str` is `.value`, and `view`, `len`, `eql` and `blank` are available on the `Text` itself. `.of("…")` sets the default, checked against the shape at compile time.

**A `Text` never repeats the input back.** A password in a 422 body would be a leak, so the sentence gives the count: `"password" has to be text of 10 to 72 characters, not 7`. `Email` does quote the input, because seeing the address is how the typo is found: `"email" has to look like an address, not "wati"`.

**A rule about the whole struct goes on the struct.** `nilo_check` runs once every field has bound, however the struct arrived, and whatever it reports with `must` comes out in the same 422 as everything else. So a second handler using `SignUp` cannot forget the rule. It receives the value and nothing else: a rule that needs the request goes in the handler, as the next section shows.

With a plain `Form(SignUp)`, a field outside its shape is a 400, like a bad number, and a `nilo_check` that fails is a 422 naming every failed rule. Under `Bound` all of it is collected:

```
3 fields did not fit: "email" has to look like an address, not "wati";
"password" has to be text of 10 to 72 characters, not 7;
"confirm" has to match the password
```

The API document includes the shape (`minLength`, `maxLength`, `format: email`), read from the type, so a generated client rejects the same text before sending it. A `check` and a `nilo_check` have no JSON Schema equivalent and are not described.

### Custom validation rules

**A rule that needs the request, such as "that address is already registered", goes in the handler, and its message comes out in the same 422 as nilo's own.** Write the check, pass the sentence, and the client gets one error shape instead of two:

```zig
fn signUp(db: *Db, b: nilo.Bound(nilo.Form(SignUp))) !nilo.Status(201, User) {
    const in = b.value() orelse return b.fail();

    const checked = b.must("email", !try db.exists(in.email.view()), "is already registered");
    if (checked.failed()) return checked.fail();

    return db.create(in);
}
```

```
"email" is already registered
```

The bool is the condition that must **hold**, not the failure. Read the call as a sentence: password must be at least 10 characters. nilo writes the label, so a rule on a query string says `?page stops at 100` without you needing to know that slot is labelled differently.

`must` returns a `Checked`, which has `value`, `failed`, `failedCount`, `given`, `failures` and `fail`. The names are the same, so nothing above needs rewriting to use it. A `Failure` from a rule has `reason == null` and its own words in `said`. Conversion failures still come first, because a rule checked against a field that never bound was checked against nothing.

A handler that checks no rules never builds a `Checked` and pays nothing for this ([ADR 034](../adr/034-a-binding-hands-its-failures-to-the-handler.md)).

Three things stay a plain 400, because none of them leaves a binding to hand back: a body that is not a form at all, text that is not JSON, and a field the endpoint does not know.

The same wrapper works on the other two input slots: `Bound(T)` for a JSON body and `Bound(Query(T))` for the query string. A `nilo.Text` or a `nilo_check` on the struct works the same way in all three, with or without the wrapper.

## A form or a JSON body, not both

**`Form(T)` takes the slot a plain struct argument would use to read JSON, so a handler cannot ask for both.** They are the same bytes read two ways, and asking for both stops compilation:

```zig
// nilo: the handler for route "/sign-up" asks for both a request body
// (argument 1, a main.Profile) and a form (argument 2) — and a request only
// has one body.
fn signUp(profile: Profile, incoming: nilo.Form(SignIn)) !void { … }
```

## Reading a form from a `Ctx`

**[`c.form(T)`](../reference/ctx.md#reading) does the same for a handler holding a `*Ctx`**, the way `c.json(T)` does for a JSON body:

```zig
fn signIn(c: *nilo.Ctx) !void {
    const incoming = try c.form(SignIn);
    ...
}
```

`c.formCollecting(T, &outcomes)` and `c.jsonCollecting(T, &outcomes)` are what `Bound(…)` is built on, for a `*Ctx` handler that wants the failures.

## Testing

**A `Form(T)` is an ordinary struct, so a test builds one directly and never writes a request body:**

```zig
const answer = try signIn(&sessions, arena, .{ .value = .{
    .email = .static("wati@example.dev"),
    .password = .static("hunter2"),
} });
```

When the encoding itself is what you are testing, the [test client](./testing.md) posts a real body:

```zig
const answer = try client.postWith(
    &app,
    "/sign-in",
    "application/x-www-form-urlencoded",
    "email=wati%40example.dev&password=hunter2",
);
```

## In the OpenAPI document

The generated API description says which encoding the endpoint takes (`application/x-www-form-urlencoded`, or `multipart/form-data` once there is a file) and describes the file as bytes rather than as the struct carrying it. See [OpenAPI](./openapi.md).

## See also

- [`examples/forms`](../../examples/forms/main.zig): a form, a session cookie, an upload and a redirect, end to end.
- [Cookies](./cookies.md), which is what a sign-in does next.
- [ADR 030](../adr/030-a-form-is-the-body-read-by-another-rule.md): why `Form(T)` is explicit rather than detected, and what the multipart parser is careful about.
- [ADR 034](../adr/034-a-binding-hands-its-failures-to-the-handler.md): why `value()` is an optional, why the list of reasons stops where it does, and what stays a plain 400.
