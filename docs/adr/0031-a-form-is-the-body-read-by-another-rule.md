# A form is the body, read by another rule

Until now a struct argument meant one thing: the request body, parsed as JSON. That covers an API and misses the web — `<form method="post">` sends `application/x-www-form-urlencoded`, and the moment it has a file in it, `multipart/form-data`. Neither reached a handler at all.

## `Form(T)` rather than sniffing the content type

The tempting version is to leave the signature alone and let a plain struct argument read whichever encoding turned up. It reads beautifully and it is wrong twice.

It makes the **API description lie**: the document would have to promise `application/json` or guess, and a generated client posting the wrong one gets a 400 from a server that could have said so up front. And it makes the endpoint's contract depend on what the caller happened to send, which is the opposite of every other thing nilo reads off a signature (ADR 0017).

So it is explicit, and it is spelled the way its neighbour is: `Query(T)` is the query string as a struct of yours, and `Form(T)` is the body as a struct of yours. Same rules in both — a field's type says what its text has to become, a default is what "not sent" means, `?T` may be absent — and the same conversions, which is why `convert.zig` now exists as one module instead of as two copies that could drift. `"age" has to be a whole number, not "soon"` is the same sentence a bad `?age=` has always produced.

## The two encodings are one thing from here

A browser sends urlencoded until the form has a file in it and multipart afterwards. That is a fact about the browser, not about the endpoint, so `Form(T)` reads either without the handler being told which — exactly as `c.body()` reads a chunked body and a `Content-Length` one without saying which arrived (ADR 0020).

The exception is stated rather than implied: a form with an `Upload` field **cannot** arrive urlencoded, so one that does gets a message saying to send multipart and quoting the `enctype` to put in the HTML. Reporting the file as a missing field would have been true and useless.

## A form is the body, so a handler cannot have both

`Form(T)` and a plain struct argument are the same bytes read two ways. Asking for both stops compilation with its own message, because the fix for the two-bodies case — "make one of them a pointer, so it is a service" — is the wrong advice here. One of the two has to go.

## The whole body is held, and the boundary is where that stops

A form is read into a struct, and a struct is not something you can have half of. So the body is read whole into the request arena, bounded by `listen()`'s `max_body` — the same trade and the same ceiling as `c.json`.

That is a real limit and it is written down rather than discovered: **an upload bigger than `max_body` is `c.bodyStream()`'s job**, where the handler drives the reading and nothing is held (ADR 0020). Streaming multipart is a different design — a parser that resumes across reads, and a `Upload` that is a reader rather than bytes — and it wants its own argument if anybody needs it.

Inside that ceiling, nothing is copied. Every name, filename and file is a slice of the body already sitting in the arena, so a 900 KB upload costs the one allocation `c.body()` made and not a second one. A test pins the file's bytes to the body's own address, because "it works" and "it does not memcpy" look identical from the outside.

## What the multipart parser is careful about

Three things, each of which is silent when got wrong:

- **The boundary is matched at the start of a line only.** A boundary string occurring inside a file is data, and an `indexOf` that did not check would truncate the upload there.
- **The line break in front of the boundary is framing, not content.** A byte too many or too few corrupts every file that goes through, and only binary ones would show it.
- **A part with a `filename` is a file even when it is empty.** That is a browser saying "the field was there and nothing was chosen"; reading it as a text field would put an empty string where a handler expected an `Upload`.

The number of parts is bounded (`max_parts`, 256). The arrays are sized from a count of boundaries in the body, and without a cap a megabyte of nothing but boundaries — about 15,000 of them — would turn into half a megabyte of arena for a request carrying no data at all.

## `Upload` is three `Str`s, and its filename is not a path

`filename`, `content_type`, `bytes`. All three are `Str`, so they die with the request and `keep` is what takes one out (ADR 0004) — including `bytes`, where `Str` is doing lifetime duty rather than claiming the contents are text.

The filename is **what the client said, and a client can say anything.** `../../etc/passwd` is a filename a browser will send if asked to. It is documented at the type, in the guide and in `nilo.zig` as a label to show back and never a path to write to, because that is the one mistake this feature makes easy.

`Content-Type` on a part is likewise unverified and says so.

## Consequences

- `nilo.Form`, `nilo.Upload`, and `c.form(T)` for a handler holding a `*Ctx`. `Query`'s field checks and `Form`'s are now the same function.
- The document names the encoding: `application/x-www-form-urlencoded` for a form of text, `multipart/form-data` for one with a file, and the file itself as `{"type":"string","format":"binary"}` rather than as the three-field struct that carries it.
- `RFC 6266`'s `filename*=UTF-8''…` is not read. It is the fallback a browser uses for a name that is not Latin-1, and the plain `filename` is always sent alongside it — reading half of that convention would be worse than reading none.
- Five refusals: a field of a type no form value can become, a `Form` of a non-struct, a `Form` with no fields, a form and a body together, and two forms. Plus one for an `Upload` asked for as an argument of its own, which is the mistake somebody makes on the way to writing the right thing.
