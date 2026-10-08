# Request input

**A request's values are read from wherever they arrived, converted by one set of rules, and every failure is handed back instead of stopping at the first.**

**Guide:** [Requests](../guide/requests.md), [Forms](../guide/forms.md) · **Reference:** [Handler arguments](../reference/handlers.md#handler-arguments), [Reading](../reference/ctx.md#reading)

The code is `http/convert.zig` (`tryConvert`, `Reason`, `Slot`), `http/typed.zig` (`Query`, `FromHeader`, the argument loop), `http/bound.zig` (`Bound`, `Checked`, `must`, `nilo_check`), `http/form.zig` (`Form`, `Upload`, the list collectors), `http/patch.zig`, `http/within.zig`, `http/text.zig`, `http/authorization.zig`, `http/maxbody.zig`, `http/ctx.zig` (`header`, `headers`, `query`, `queries`, `host`, `scheme`, `body`), and `core/str.zig` (`Str.blank`, `Str.trimmed`).

## Overview

```
  path param      Query(T)          Form(T)           JSON body
  (positional)    ?a=1&b=2      urlencoded/multipart     {..}
       \              |               |                   |
        `------------ convert.tryConvert / nilo_parse ----'
                (Reason: .missing .not_a_number .not_true_or_false
                         .not_a_choice .wrong_kind .not_that_type)
                              |
              plain argument: the first bad field is the request's 400
                              |
                    Bound(W): every field, .value() or .fail()
                              |
              nilo_check(self, *Rules(T)): a rule about the whole struct
                              |
                           handler
```

Headers and authentication sit next to this flow rather than inside it. `FromHeader(name, T)` and `Authorization(scheme)` are typed arguments converted by the same `convert`, but each is rejected on its own, before a `Bound` could collect it, and `Authorization`'s rejection is a 401 with a challenge instead of a 400. `c.headers()`, `c.queries()`, `c.host()` and `c.scheme()` are how a middleware reads a request when it does not know the names in advance. The body itself is limited twice: by `max_body` (per route, or `listen()`'s default) before any byte is read, and by `readSizedBody` taking it one page at a time while it arrives.

## Rules

1. **The query string arrives as a struct you define, wrapped in `Query(T)`.** Field names are the query names, a field's default is what "absent" means, a `?T` with no default is absent as null, and conversion and its error messages are shared with path params. A form and a JSON body follow the same rule, held once in `field.zig`. [ADR 011](../adr/011-the-query-string-is-a-struct-of-your-own.md)
2. **`Form(T)` is the body, read by the same rules as `Query(T)`, whichever encoding the browser used.** A checkbox posts `on` instead of `true`/`false`, and only a form field reads it that way. A file field arrives as an `Upload`: three `Str`s (bytes, filename, content type) kept whole in the request arena, never copied. [ADR 030](../adr/030-a-form-is-the-body-read-by-another-rule.md), [ADR 071](../adr/071-a-checkbox-is-a-bool-in-a-form-and-nowhere-else.md)
3. **A `PATCH` body needs three states, and an optional only has two.** `Patch(T)` tells apart "not sent" (`.absent`), "sent as null" (`.cleared`) and "sent with a value". [ADR 025](../adr/025-a-patch-needs-three-answers-and-an-optional-has-two.md)
4. **Text becomes a number by nilo's own simple rule, not Zig's literal syntax**: digits, with a leading `-` only for signed types, and a real number finite. A JSON body's numbers, quoted or not, are read by the same rule, so `300` for a `u8` and `5.0` for an integer are refused naming the field. A type that wants to parse itself declares `nilo_parse(text) ?Self`, and it is then read that way anywhere a value is converted from text: a path param, a `Query(T)` field, a `Form(T)` field. [ADR 084](../adr/084-a-number-in-a-request-is-not-a-zig-literal.md), [ADR 113](../adr/113-a-path-param-can-parse-itself.md)
5. **A type that writes a format can also read it.** `sql.Timestamp.nilo_parse` is the inverse of its own RFC 3339 writer. It accepts more than it prints (any offset, fractional seconds) and less in one place (no time without a zone, no leap second), because a parser that disagreed with its writer would move a cursor without anyone noticing. [ADR 127](../adr/127-what-a-server-prints-it-can-read.md)
6. **A whole number within a range is a type, `Within(min, max)`**: the smallest integer type that fits. A value outside the range is rejected with the same null a bad number gets, and the range is written into the document as `minimum`/`maximum`. [ADR 167](../adr/167-a-whole-number-inside-a-range-is-a-type.md)
7. **Text with constraints is a type too: `Text(.{ .min, .max, .check, .said })`, with `Email` and `Url` as presets.** A rule about the whole struct rather than one field is a function on the struct, `nilo_check(self, *Rules(T))`, which runs after every field has been bound. [ADR 193](../adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)
8. **A binding hands all its failures to the handler instead of stopping at the first.** `Bound(Query(T))`, `Bound(Form(T))` and `Bound(T)` for a JSON body offer `value()` as `?T`, `given(name)` for what the user typed, and `must(field, ok, "…")` to add the application's own message to the same 422. [ADR 034](../adr/034-a-binding-hands-its-failures-to-the-handler.md)
9. **A header or an authentication scheme a handler needs is a typed argument, not a lookup in the handler body.** `FromHeader(name, T)` reads one header the way `Query(T)` reads a field. `Authorization(.bearer)` or `Authorization(.{ .basic = … })` rejects the request with the right `WWW-Authenticate` before the handler runs. `app.guard(middleware, cookie)` adds a session cookie to the document, trusting its declaration the same way a self-describing type is trusted. [ADR 131](../adr/131-a-header-a-handler-can-be-given.md), [ADR 153](../adr/153-an-authorization-header-a-handler-can-ask-for.md)
10. **Everything a handler does not name as an argument can still be read, without touching an underscore field.** `c.headers()` walks every header in arrival order, as `Str` name and value. `c.queries()` and `c.queryString()` do the same for the query string. `c.host()` and `c.scheme()` read `X-Forwarded-*` only when `listen(.{ .trusted_hops = … })` says to trust them. [ADR 085](../adr/085-every-header-without-handing-out-the-head.md), [ADR 090](../adr/090-a-request-can-be-read-past-the-parts-a-handler-names.md)
11. **A query or form field that is a slice is a list, filled from every value with its name.** The query accepts both `?tag=a,b` and `?tag=a&tag=b`, and the document shows the comma form; a form only accepts the repeated name, because that is the only way a browser sends it. [ADR 132](../adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md) **A single optional field treats an empty box as not given**: an empty value becomes its default, or null, whenever `""` is not a valid value of its type. So `age=` on a `?u32` is null rather than a 400, while an empty `?Str` is still `""`.
12. **Memory for a body is committed only as the client actually sends it**, not based on the `Content-Length` a stranger claimed: `readSizedBody` takes 4 KiB first and grows from there. [ADR 083](../adr/083-a-body-is-taken-as-it-arrives.md)
13. **A route can set how much body it accepts.** `app.with(nilo.maxBody(n))` sets a limit lower or higher than `listen()`'s default for one route, checked before any byte is read. Handed `&limit`, the address of a `usize`, it reads the number on each request instead, for a limit that comes from configuration. `c.bodyStream()` is for a different situation and has its own `max_bytes`. [ADR 156](../adr/156-a-route-can-say-how-much-body-it-takes.md)
14. **Required text is checked for more than emptiness.** `Str.blank()` says whether it contains nothing but whitespace, and `Str.trimmed()` returns the part in the middle; both use `std.ascii.whitespace` instead of a character list written again at every call site. [ADR 142](../adr/142-required-text-arrives-as-two-spaces.md)
15. **A body whose type can contain itself is read at most 64 levels deep.** `std.json` recurses once per level with only the fiber's stack to stop it, so for a type that can contain itself (a comment tree, a menu) the body is scanned for nesting before parsing, and deeper than 64 levels is a 400. A type that cannot nest endlessly is recognised while compiling and not scanned. [ADR 226](../adr/226-a-body-that-can-nest-for-ever-is-read-sixty-four-deep.md)

## Decisions

| ADR | What it decides |
|---|---|
| [011](../adr/011-the-query-string-is-a-struct-of-your-own.md) | The query string is a struct you define, `Query(T)`, sharing conversions with path params |
| [025](../adr/025-a-patch-needs-three-answers-and-an-optional-has-two.md) | `Patch(T)`: a PATCH body tells apart "not sent", "sent as null" and "sent with a value" |
| [030](../adr/030-a-form-is-the-body-read-by-another-rule.md) | `Form(T)` is the body read by other rules; `Upload` is three `Str`s kept whole in the arena |
| [034](../adr/034-a-binding-hands-its-failures-to-the-handler.md) | `Bound(W)` hands every field's failure to the handler, and `must` adds the application's own message |
| [071](../adr/071-a-checkbox-is-a-bool-in-a-form-and-nowhere-else.md) | A checkbox posts `on`, and only a form field reads it that way |
| [083](../adr/083-a-body-is-taken-as-it-arrives.md) | `readSizedBody` commits memory for the announced length only as the client actually sends it |
| [084](../adr/084-a-number-in-a-request-is-not-a-zig-literal.md) | A number in request text follows a plain digits rule, not Zig's literal syntax |
| [085](../adr/085-every-header-without-handing-out-the-head.md) | `c.headers()` walks every header in arrival order without exposing the raw head |
| [090](../adr/090-a-request-can-be-read-past-the-parts-a-handler-names.md) | `c.queries()`, `c.queryString()`, `c.host()` and `c.scheme()` read beyond what a handler names |
| [113](../adr/113-a-path-param-can-parse-itself.md) | A type declares `nilo_parse` and is read that way wherever a path param, query or form field is |
| [127](../adr/127-what-a-server-prints-it-can-read.md) | `sql.Timestamp.nilo_parse` is the inverse of its own RFC 3339 writer |
| [131](../adr/131-a-header-a-handler-can-be-given.md) | `FromHeader(name, T)`: a header given to a handler as a typed argument |
| [132](../adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md) | A query or form field that is a slice is a list, filled from every value with its name |
| [142](../adr/142-required-text-arrives-as-two-spaces.md) | `Str.blank()` and `Str.trimmed()`: required text is checked for more than emptiness |
| [153](../adr/153-an-authorization-header-a-handler-can-ask-for.md) | `Authorization(scheme)` and `app.guard(middleware, cookie)`: a typed auth header and a documented cookie |
| [156](../adr/156-a-route-can-say-how-much-body-it-takes.md) | A route sets its own body size limit with `nilo.maxBody(n)`, or one read from configuration with `nilo.maxBody(&limit)`, overriding `listen()`'s default |
| [167](../adr/167-a-whole-number-inside-a-range-is-a-type.md) | `Within(min, max)`: a whole number within a range is a type |
| [193](../adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md) | `Text`/`Email`/`Url` are constrained text, and `nilo_check` puts a whole-struct rule on the struct |
| [226](../adr/226-a-body-that-can-nest-for-ever-is-read-sixty-four-deep.md) | A body whose type can contain itself is rejected beyond 64 levels of nesting, before parsing |

Related topics: why a header's name and value are `Str` instead of `[]const u8` is [ADR 003](../adr/003-request-arena-and-the-str-type.md) (the request head is usually borrowed, not copied); the JSON side of a type parsing itself is [ADR 166](../adr/166-a-body-field-that-parses-itself.md); a JSON body type answering its wrong shape with a 422 instead of the 400 is [ADR 251](../adr/251-json-that-does-not-fit-can-be-a-422.md) (json); how the cookie behind `app.guard` is sealed is [ADR 033](../adr/033-a-session-is-sealed-into-the-cookie.md).

## Open questions

- **Multipart is read whole, never streamed.** `Form(T)` limits an upload by `max_body`, which is right for a photo and wrong for a 2 GB video. A streaming version needs a parser that can resume across reads, and an `Upload` that is a reader instead of bytes. Tracked in [the todo list](../todo.md) under `nilo_http`, linked to [ADR 030](../adr/030-a-form-is-the-body-read-by-another-rule.md).
