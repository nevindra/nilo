# A query parameter, or a form field, that is a list

**Status:** accepted
**Topic:** [request-input](../design/request-input.md)

## Context

```
error: nilo: the field `types: ?[]const nilo.Str` of the `Query(FeedQuery)` on
route "/api/activity" is not something a query value can become.
```

Every multi-select filter in a product is this field, and the workaround was thirteen lines called `commaList`, multiplied by most list screens. It is not only ergonomics: `?type=A&type=B` and `?type=A,B` are two different wire contracts, and picking the wrong one is invisible, since a server that takes the first repeated key and drops the rest answers with fewer rows, which looks exactly like a filter that worked. The Go original this came from pins the choice in two places that must agree, `explode: false` in the OpenAPI document and a matching `querySerializer` in the generated client. nilo could say neither half: there was no field type for a list, so the document said nothing, and the convention lived in a private helper in the caller's own code.

A `<select multiple>` or a checkbox group into a `Form(T)` was the same compile error one slot over, even though the data was already there: `parseMultipart` keeps every occurrence in order, `parseQuery` does the same for a urlencoded body, and `Fields.find` deliberately answers the first so a repeated name would not silently become the last.

## Decision

**A query or form field that is a slice of anything a value in that slot can become is a list, filled from every value under its name, in the order sent.**

```zig
const Feed = struct {
    tag: []const Str = &.{},
    kind: []const Kind = &.{},
    limit: u32 = 50,
};
```

The two slots pick different wire contracts, because they answer to different clients.

### The query reads both spellings, and writes one of them

**Both spellings are read.** `?tag=a,b` and `?tag=a&tag=b` both give two values, and so does `?tag=a,b&tag=c`. Reading both costs one comparison and removes the ambiguity above rather than documenting it. **One of them is written down**: the parameter carries `style: form, explode: false`, the comma, so a client generated from the document sends the one nilo would also have printed, which is the half a helper in the caller could never supply. The element may be anything a query value can become, which makes a list of enums the ordinary case: `?kind=comment,nonsense` is a 400 before the handler runs, and the fourteen valid words are in the document.

### The form reads one spelling, because there is only one client

A `Form(T)` field is filled from a repeated name and nothing else, and a comma is data. A browser sends a checkbox group or a `<select multiple>` as the same name once per value and never comma-joined, so there is no client to keep in step with and no second spelling in the world to read; the document already describes a form array as `explode: true`, which is the repeated name, so nilo has nothing to write. Splitting on a comma here would turn `a,b` typed into one box into two tags, for no client that exists.

**A list of `Upload` is every file under the name.** `<input type="file" multiple>` sends one part per file under one name, and a field declared `[]const Upload` is filled from all of them, in the order sent. The bytes, names and types are slices of the body, as for one file; the only allocation is the slice of `Upload`s, sized by a count first. No new limit: the parts are the form's parts, so `max_parts` and `max_body` bound the list. A file input left empty sends a part that is dropped, so it adds nothing. **A single `Upload` that receives two or more files is a 400** (a `Bound` records `several_files`) naming the field and saying to declare it `[]const nilo.Upload`, never the first kept and the rest dropped. The unbound reader has `Fields.fileCount` and `Fields.filesNamed`.

### The rules a list follows, on both slots

- **Absent is the empty list**, not a 400 and not null-unless-optional. Every filter written against a list already means "no filter" by not being sent, and a group with nothing ticked sends no name at all, so a list field is never `required` in the document and wants `= &.{}` so the document says it is optional.
- **An empty value contributes nothing.** On the query, `?tag=` is an empty list rather than a list holding one empty string, which is what an empty text box submits. On a form, an unticked box is never sent, an empty text box is sent empty, and a row of inputs sharing a name with two left blank is a list of the ones filled in.
- **The element converts exactly as a single field would**, so `[]const Kind` refuses `tag=nonsense` with the sentence a single field of that name gets, and under `Bound(Query(T))` or `Bound(Form(T))` the **first** bad value is the one reported while the rest of the list is still read.
- **"Not sent" and "sent empty" are the same thing**, and there is no spelling that separates them. `?[]const Str` is the shape somebody reaching for the difference will try, and it does not buy it: nothing found is null whether the parameter was absent or arrived empty. Telling the two apart would mean a second sentinel on the wire for a distinction no filter has yet wanted.

### A blank box on a single field that may be absent is the field not given

A browser submits an empty text box as `age=`, never as nothing, on a POST form and a GET one alike. So an optional or defaulted field whose type has no empty value, a number, a bool, an enum, a type of its own that refuses `""`, reads an empty value as absent: its default, or null. It was a 400 saying an optional age has to be a whole number, on the first form anybody submitted without filling in every box. A field that has to be given still has to be given something, so an empty value on a required field is still refused, and a value that is there and wrong is still wrong. Text keeps what arrived: an empty `?Str` is `""`, because `""` is a value of text and whether a blank box means nothing or the empty string is the field's to say (`Str.blank()` asks). The rule is `convert.emptyIsAbsent`, and `Form(T)`, `Query(T)` and both `Bound` forms go through it. `test "a box left blank is a field not given, where blank is not a value of its type"` in `behaviour.zig` holds all four.

## What was rejected

**Repeated keys as the written query contract** (`explode: true`), OpenAPI's default and what a browser's own multi-select sends. Comma-joined wins on one argument: it is one value on the wire and therefore one thing to log, grep and paste back, where six repetitions of a key cannot be. Both are still *read*, so the choice costs a caller nothing either way.

**Both spellings for the form, as the query reads them.** The comma is a contract for a client that does not exist on a form submission, and it costs the value with a comma in it for nothing.

**Letting the caller pick the separator**, on either slot. A second knob whose two settings are invisible from the outside, on the exact axis that made this worth building: nilo picks, and says which in the document.

**Widening `convert.convertible` instead of checking in the query and form slots.** `convertible` is shared with a JSON body, which reads a body neither of these files does; promising a list there would compile and fill nothing. The list is a slot question, so it is asked in the slot.

**Reading a form's list in `typed.zig` beside the query one.** The query collectors read `c.queries()`, and a form's values are in the `Fields` the body parser produced, so the collectors sit in `form.zig` beside `fill` and `fillCollecting`, the one place that knows both the parsed body and the slot's conversion rules.

**Refusing a list of `Upload`**, on the grounds that an `Upload` is a part rather than a value and a field takes one. It left `<input multiple>` silently keeping the first file and dropping the rest, so a handler saved one photo of five and the browser showed success. Gin and Echo bind a slice of file headers, actix-multipart and Rocket a `Vec` of files, so the refusal was the odd one out. The "how many, how big together" question it deferred was already answered by `max_parts` and `max_body`.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | One, on a route that asked for a list (of values or of files) and on no other, for the slice of elements, sized by a first pass. The elements point into the query string or the parsed body, which live as long as the request; only the slice holding them is allocated, out of the request arena. `test "the request path stays inside its allocation budget"` covers a route with no list field and is unmoved, the invariant [ADR 017](./017-the-trade-budget-has-four-axes.md) guards: a DX feature may not add an allocation to a path that did not ask for it. |
| Memory per idle connection | Unchanged. |
| Throughput and p99 | A route with a list field walks its fields once more per list field, which is the count; a route without one does not. |
| Binary size | Two collectors instantiated per list element type a program names; the file list adds a third pair, only in a program with a `[]const Upload` field. |

## Consequences

- `queryList`, `countList`, `collectList` and `collectListCollecting` in `typed.zig`; the same shapes in `http/form.zig` (`Fields.count`, `collectList`, `collectListCollecting`) for a form, with `fill` and `fillCollecting` taking the arena; one field on `openapi.Field` and clauses in the writer for both slots.
- `checkFields` accepts a slice of a convertible element and refuses a list of an optional (`refusals/form_list_of_optional_cannot_convert`) and accepts a list of `Upload`, filled by `collectFiles`.
- Thirteen lines and a paragraph of convention delete themselves in the port that reported the query case, per list screen; the roadmap loses "A form field cannot bind to a list".
