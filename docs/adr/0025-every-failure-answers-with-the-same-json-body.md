# Every failure answers with the same JSON body

zfast's error messages are the part of it most worth keeping. A body field that does not fit gets `the request body is missing "title" (text)`, not a blob of validator output somebody has to decode first. That is a real advantage over what FastAPI hands back.

It was going out as `text/plain`.

Every endpoint zfast is built for answers JSON, so every client of one calls `res.json()`. On a 422 that throws — and it throws in the `catch` where the frontend was going to show the user what went wrong. The best message in the ecosystem was arriving in the one format the code reading it could not accept, so the first thing anybody would write is middleware to turn it into JSON, which means the message would be reformatted by hand in every application that uses zfast.

## The shape

```json
{"error": "the request body is missing \"title\" (text)", "status": 400}
```

The sentence is unchanged. `curl` still shows it, one pair of braces further in, and `res.json()` now works. `status` is in the body as well as the status line because a client that has already given up on the response object still has it.

## What was considered and refused

- **Negotiating on `Accept`.** The obvious answer, and it does not work. `fetch()` sends `Accept: */*` and so does `curl`, so the header cannot tell the browser from the terminal — the two cases this would exist to separate. Choosing JSON for `*/*` is the same as choosing JSON always, with a rule on top that never fires.
- **An option on `App`.** `errors: .text | .json` is two behaviours to test, two to document, and a decision every user has to make on their first day with nothing to base it on. The whole point of one shape is that there is one shape.
- **Copying RFC 7807 `application/problem+json`.** More fields (`type`, `title`, `detail`, `instance`), a content type most clients do not special-case, and nothing to put in the fields that zfast actually knows. `error` and `status` is what there is.

## Where it applies

Everywhere, which is what makes it worth doing. The three responses that go out before there is a `Ctx` — a malformed head, a head too long, a head that timed out — carry it as a compile-time constant. The built-in 404 and 405 handlers were changed to *fail* rather than to answer, so they go through the one function that assembles a failure body instead of writing one of their own. That is the property to keep: **one place writes an error response.**

A 405 still carries its `Allow` header, because a failure response goes out with whatever headers the request collected. That is the same mechanism that keeps CORS headers on an error, and it is worth naming: an error response that quietly loses its CORS headers is one the browser refuses to show, at the worst possible moment.

## Consequences

- **Breaking for anyone matching on error text off the wire.** The message is the same; it is quoted and JSON-escaped now. In zfast's own tests this turned out to be an improvement — a helper reads the `error` field back out, so a test spells the message the way a person reads it and gets "the body really was JSON" asserted along the way.
- The API description gives every documented failure a `$ref` to one `Failure` schema, written once under `components`.
- A message is a fixed 240 bytes ([ADR 0005](./0005-http-errors-via-fail-functions.md)) and escaping can turn each byte into six, so the failure path carries a ~1.5 KB stack buffer sized for the worst case. It still allocates nothing, which is the invariant that matters: the failure path must not have a failure path of its own.
- A `Str` is written into the message by the fail function, not by this, so nothing here reads request memory. Escaping is over bytes already copied.
