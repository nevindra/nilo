//! The API description, worked out from the handler signatures (ADR 016).
//!
//! FastAPI's one big idea, which nilo was already most of the way to
//! without noticing: you write the function signature, and everything else
//! is derived from it (ADR 014). The typed engine has read those
//! signatures since stage 3 to decide what to pass in. This reads the same
//! information to say what the endpoint takes and returns.
//!
//! ```zig
//! fn getUser(db: *Db, id: u32) !User { … }
//! app.get("/users/:id", getUser);
//! ```
//!
//! ```json
//! "/users/{id}": { "get": {
//!   "parameters": [{"name":"id","in":"path","required":true,"schema":{"type":"integer"}}],
//!   "responses": {"200": {"content": {"application/json": {"schema": … User … }}}}
//! }}
//! ```
//!
//! Two things about the shape of this file follow from ADR 017. Everything
//! a route contributes is **comptime data**, not a generated function: one
//! `Operation` value per route, its slices pointing at read-only memory, and
//! a single writer walking them. A per-route writer would have put a copy of
//! the JSON-emitting code in the binary for each one. And nothing here is on
//! the request path — the document is built once when `listen()` resolves
//! the routes, and served from memory afterwards like any other file
//! (ADR 009).

const std = @import("std");
const http1 = @import("http1.zig");
const str_mod = @import("nilo_core");
const patch_mod = @import("patch.zig");
const mark = @import("jsonmark.zig");
const convert = @import("convert.zig");
const field_mod = @import("field.zig");

const Str = str_mod.Str;

/// What nilo can say about the shape of a value. Deliberately smaller than
/// JSON Schema: it holds what a Zig type actually tells you, and `unknown`
/// is the honest answer for the rest rather than a guess dressed up as a
/// description.
pub const Schema = union(enum) {
    string,
    integer,
    /// An integer with a bound the server holds: both ends of a Zig integer's
    /// own range (`widthOf`), or of a `nilo.Within(min, max)`
    /// ([ADR 167](../docs/adr/167-a-whole-number-inside-a-range-is-a-type.md)).
    bounded: Bounds,
    /// Text with a shape the server holds — `minLength`, `maxLength`, a
    /// `format` — read off a `nilo.Text`
    /// ([ADR 193](../docs/adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)).
    sized: TextShape,
    number,
    boolean,
    /// A string from a fixed set — what an enum becomes.
    choice: []const []const u8,
    array: *const Schema,
    /// `?T`, which in a JSON body means the value may also be null.
    nullable: *const Schema,
    object: Object,
    /// A file out of a multipart form — `{"type":"string","format":"binary"}`,
    /// which is how OpenAPI 3.1 says "bytes" (ADR 030).
    binary,
    /// What a type said about itself, because it writes its own JSON and this
    /// module cannot read that off its fields (ADR 016).
    told: Told,
    /// A `union(enum)`, in whichever encoding the type asked for (ADR 016).
    one_of: OneOf,
    /// A type that writes its own JSON and did **not** say what it looks like.
    /// Emitted as `{}` with a note — the fields are known to be the wrong
    /// answer, so anything derived from them would be a confident lie.
    untold,
    /// A type with no useful JSON shape, or one nested deeper than this
    /// module follows. Emitted as `{}`, which in JSON Schema means "anything"
    /// — true, and better than a wrong claim.
    unknown,
};

/// The bounds on an integer the server refuses outside of — so they are a
/// promise the document may make. Wide enough for any Zig integer up to 128
/// bits, which is the widest a request text is read into.
pub const Bounds = struct {
    min: ?i128 = null,
    max: ?i128 = null,
};

/// The declaration a bounded integer carries (`nilo.Within`), read by name.
const within_marker = "nilo_within";

/// The shape of a `nilo.Text`, as the document says it. A check of the
/// caller's own has no JSON Schema and is not claimed.
pub const TextShape = struct {
    min: ?usize = null,
    max: ?usize = null,
    format: ?[]const u8 = null,
};

/// The declaration shaped text carries (`nilo.Text`), read by name.
const text_marker = "nilo_text";

/// What a `pub const nilo_openapi` says, and the whole of what it may say.
///
/// Deliberately two fields. The point is to let a type that writes its own
/// JSON name the shape it writes, not to give anybody a second way to describe
/// a struct — a type whose fields *are* its JSON needs none of this, and one
/// that wants `pattern`, `minimum` and `examples` is asking this module to
/// become a JSON Schema builder, which ADR 017 prices and refuses.
pub const Told = struct {
    /// `"string"`, `"integer"`, `"number"`, `"boolean"` — a JSON type.
    type: []const u8,
    /// OpenAPI's `format`: `"uuid"`, `"date-time"`, `"decimal"`. Optional
    /// because it is a hint to a generator rather than a constraint.
    format: ?[]const u8 = null,
};

/// A struct, and the name of the Zig type it came from.
pub const Object = struct {
    /// The type's full name — `myapp.models.User`. It is what lets a shape
    /// be written once under `components/schemas` and referred to from every
    /// route that uses it, instead of being copied out per route.
    ///
    /// Null when there is no name worth putting in somebody's generated
    /// client: an anonymous struct, a tuple, or one the compiler named after
    /// where it was written.
    name: ?[]const u8,
    fields: []const Field,
    /// Whether the type says it skips a key it has no field for
    /// (`.unknown_fields = .ignore`, ADR 168), written as
    /// `additionalProperties: true`. A type that says nothing is left silent
    /// rather than `false`: ADR 016 promises a 400 for an unknown key in a
    /// request and no such thing for a response, which this schema is shared
    /// with and which a client reads ignoring keys it does not know.
    open: bool = false,
    /// Whether this is the half a client sends, read from a request, as
    /// against the half the server writes (`responseSchemaOf`). The two have
    /// the same name; the document files them apart when they differ
    /// ([ADR 016](../docs/adr/016-the-api-description-comes-from-the-signatures.md)).
    input: bool = false,
};

/// A `union(enum)` and its two encodings.
///
/// `tag` is null for the one `std.json` writes — an object with a single key,
/// the arm's name — and is the discriminator's own key when the type said so
/// with `nilo_json` ([ADR 016](../docs/adr/016-the-api-description-comes-from-the-signatures.md)).
/// The two are different documents, not a different rendering of one: the first
/// nests the arm under its name, the second puts the name beside the arm's own
/// fields, and a generated client cannot read one from the other.
pub const OneOf = struct {
    tag: ?[]const u8 = null,
    cases: []const Case,
};

/// One arm of a tagged union: the name it goes by on the wire, and the shape
/// that comes with it. The name is the Zig field's unless `rename_all` said
/// otherwise, which is why it is carried rather than read back off the type.
pub const Case = struct {
    name: []const u8,
    schema: *const Schema,
};

pub const Field = struct {
    name: []const u8,
    schema: *const Schema,
    /// A field with a default is what "absent" is allowed to mean, so it is
    /// not required — the same rule `Query(T)` and the body parser follow.
    required: bool,
    /// Whether this parameter takes more than one value, which the document
    /// has to say *how* ([ADR 132](../docs/adr/132-a-query-parameter-or-a-form-field-that-is-a-list.md)).
    /// `?tag=a,b` and `?tag=a&tag=b` are two wire contracts and a client
    /// generated against the wrong one sends a filter the server reads half
    /// of. Written as `style: form, explode: false`, which is the comma.
    list: bool = false,
};

/// One path or query param.
pub const Param = struct {
    name: []const u8,
    schema: *const Schema,
};

/// What an endpoint answers with.
pub const Answer = struct {
    /// Null when the status is not knowable while compiling, which is the
    /// case for a handler returning `Response(T)` — the status is a field it
    /// fills in at runtime. Written as OpenAPI's `default` rather than
    /// guessed at, because a spec claiming 200 for a route that answers 201
    /// is worse than one that declines to say.
    status: ?u16,
    content_type: []const u8,
    schema: ?*const Schema,
    /// Whether this endpoint answers 404 when the thing asked for is not
    /// there — which is exactly the handlers returning `?T` (ADR 023). The
    /// only failure mode a signature can state, and so the only one this
    /// document is entitled to promise.
    not_found: bool = false,
    /// Whether the handler writes its own response — it takes a `*Ctx` and
    /// returns nothing, so the answer is a `c.send…` call in its body and
    /// there is no return type to read it off.
    ///
    /// Worth a field of its own because the alternative is a lie: a handler
    /// that streams a CSV or sends a 202 looks, to a reader of return types,
    /// exactly like one that answers an empty 200.
    written: bool = false,
    /// Whether this endpoint answers with a `Location` and no body — a
    /// `Redirect(303)` (ADR 031). The status is already in `status`; what
    /// this adds is that the header is part of the promise, which is the
    /// half a client generator has to see to follow it.
    redirect: bool = false,
    /// Whether this endpoint answers with the bytes of a file — a
    /// `FileBody` (ADR 009). Written as `application/octet-stream` with
    /// `{"type":"string","format":"binary"}`, which is OpenAPI's way of
    /// saying "bytes".
    ///
    /// A flag rather than a content type and a schema, because the real
    /// content type is a field the handler fills in while the request is
    /// running: naming `application/pdf` here would be a guess about a value
    /// that has not been decided yet. Declining to say is the same
    /// discipline that makes a `Response(T)` report its status as `default`
    /// rather than claiming 200 — a document that guesses is worse than one
    /// that only promises what the signature settles.
    binary: bool = false,
    /// Content types the answer is also filed under, with the same schema:
    /// a protobuf message goes out as JSON or as protobuf by the request's
    /// content type (ADR 256).
    more_types: []const []const u8 = &.{},
    /// Whether this endpoint answers with an `ETag` and a 304 to a client
    /// that sends it back — a `Versioned(T)` (ADR 189). The body described
    /// is `T`'s; what this adds is the header on the 200 and the 304 beside
    /// it, which is the half a client that caches has to see.
    versioned: bool = false,
};

/// How a request body is expected to arrive on the wire. The shape is
/// described the same way whichever it is; this is the content type it is
/// filed under, and a form with a file in it can only be the last one
/// (ADR 030).
pub const BodyKind = enum {
    json,
    urlencoded,
    multipart,
    /// A protobuf message, which is read as JSON or as protobuf by the
    /// request's content type and so is filed under both, with one schema:
    /// the schema is the message's fields, and the media type how they are
    /// spelled (ADR 256).
    message,
    /// A type that reads its own bytes, filed under its own label
    /// (`Operation.body_type`), the mirror of ADR 157 (ADR 256).
    own,

    /// The content types a body of this kind is filed under, decided while
    /// compiling so the writer only walks a list. `own` is the type's label.
    pub fn contentTypes(comptime self: BodyKind, comptime own_type: []const u8) []const []const u8 {
        return comptime switch (self) {
            .json => &.{"application/json"},
            .message => &.{ "application/json", "application/proto" },
            .urlencoded => &.{"application/x-www-form-urlencoded"},
            .multipart => &.{"multipart/form-data"},
            .own => &.{own_type},
        };
    }
};

/// Everything the signature of one route says about it.
pub const Operation = struct {
    method: http1.Method,
    pattern: []const u8,
    /// In the order they appear in the pattern. A catch-all is named `*`.
    params: []const Param,
    query: []const Field,
    /// The request headers the signature asks for
    /// ([ADR 131](../docs/adr/131-a-header-a-handler-can-be-given.md)).
    /// Empty for every route that reads its headers with `c.header`, which
    /// nilo cannot see and does not guess at.
    headers: []const Field = &.{},
    /// The `Authorization` header the signature asks for, as the security
    /// scheme a generated client signs in with
    /// ([ADR 153](../docs/adr/153-an-authorization-header-a-handler-can-ask-for.md)).
    security: Security = .none,
    /// Whether a middleware `app.guard` declared stands in front of this
    /// route — the cookie scheme, which no signature can say because the
    /// cookie is read by a guard on the group rather than by the handler
    /// ([ADR 153](../docs/adr/153-an-authorization-header-a-handler-can-ask-for.md)).
    /// Settled by `writeOpenApi` from the App's middleware, not at
    /// registration, because `without` and `with` can still move it.
    guarded: bool = false,
    /// Whether the route answers once per `Idempotency-Key`, and so can
    /// answer 409 and 422 on the key alone (ADR 155).
    idempotent: bool = false,
    body: ?*const Schema,
    /// What the body is filed under, from `BodyKind.contentTypes`: one
    /// content type, or a message's two (ADR 256).
    body_types: []const []const u8 = &.{"application/json"},
    answer: Answer,
    /// Whether nilo itself can refuse this request with a 400 before the
    /// handler runs — true as soon as there is anything to convert or
    /// validate. Not a guess: it is exactly the set of routes with a typed
    /// param, a query struct, or a body.
    can_reject: bool,
    /// Whether a body that is JSON and not this endpoint's shape is a 422
    /// rather than the 400, because the body's type says `.misfit = 422`
    /// ([ADR 251](../docs/adr/251-json-that-does-not-fit-can-be-a-422.md)).
    /// The 400 stays listed beside it: text that is not JSON is still one.
    misfit: bool = false,
    /// The `operationId`, when the route was given one with `app.named(…)`.
    /// Null is the derived name below
    /// ([ADR 119](../docs/adr/119-a-route-can-say-its-own-name.md)).
    name: ?[]const u8 = null,
};

/// The two schemes `nilo.Authorization(…)` reads. Both are `type: http` in
/// the document, which is the one shape every generator handles.
pub const Security = enum {
    none,
    bearer,
    basic,

    /// The name under `components.securitySchemes`, which is also what an
    /// operation's `security` refers to.
    fn name(self: Security) []const u8 {
        return switch (self) {
            .none => unreachable,
            .bearer => "bearerAuth",
            .basic => "basicAuth",
        };
    }
};

/// The name the cookie scheme is written under. One per document, because
/// a program has one session cookie (ADR 033), and the guard that reads
/// it is declared once (ADR 153).
pub const cookie_scheme = "cookieAuth";

pub const Info = struct {
    title: []const u8 = "API",
    version: []const u8 = "1.0.0",
    description: []const u8 = "",
    /// The cookie a guarded route is behind, from `app.guard`, or null when
    /// no guard was declared. What `components.securitySchemes.cookieAuth`
    /// names as `name` (ADR 153).
    cookie: ?[]const u8 = null,
    /// The shape of a failure body, from `app.failures`, or null for nilo's
    /// own (ADR 024). Written under `components.schemas.Failure` in place
    /// of `error_schema`, so the document describes what the wire carries.
    failure: ?*const Schema = null,
};

/// What `app.docs(…)` takes. Every field has a default, so `app.docs(.{})`
/// is a working API description.
pub const Options = struct {
    title: []const u8 = "API",
    version: []const u8 = "1.0.0",
    description: []const u8 = "",
    /// Where the document itself is served.
    path: []const u8 = "/openapi.json",
    /// Where the page for reading it is served. Empty for none, which is
    /// what a server with no outbound network wants — the page pulls its
    /// viewer from a CDN, the document does not.
    ui_path: []const u8 = "/docs",
};

// ---- turning a Zig type into a Schema, while compiling ----

/// How far into nested types to follow. A shape deeper than this is
/// `unknown`, which stops a self-referential type — a tree node holding
/// children of its own type — from expanding for ever.
const max_depth = 8;

pub fn schemaOf(comptime T: type) *const Schema {
    comptime {
        return schemaWithin(T, 0, false);
    }
}

pub fn responseSchemaOf(comptime T: type) *const Schema {
    comptime {
        return schemaWithin(T, 0, true);
    }
}

fn schemaWithin(comptime T: type, comptime depth: usize, comptime written: bool) *const Schema {
    comptime {
        if (depth >= max_depth) return held(.unknown);
        // The same reason `covers` does it: reading the marker is what checks
        // it, so a marker on a shape it cannot describe is refused rather than
        // quietly ignored (ADR 016).
        if (mark.marked(T)) _ = mark.of(T);
        if (T == Str) return held(.string);
        // A file is bytes, not the three-field struct it is carried in.
        if (T == @import("form.zig").Upload) return held(.binary);
        // On the wire a `Patch(T)` is the value or null — the third state it
        // carries is "the field was not here at all", and JSON Schema says
        // that with `required`, which a default already takes care of.
        if (patch_mod.isPatch(T)) {
            return held(.{ .nullable = schemaWithin(T.nilo_patch, depth + 1, written) });
        }

        // A whole number inside a range says its range (ADR 167). Before
        // the writer check below, because it writes itself as the number and
        // the number's bounds are the thing worth telling a client.
        if (withinOf(T)) |bounds| return held(.{ .bounded = bounds });
        // Text with a shape says its shape, for the same reason (ADR 193).
        if (textOf(T)) |shape| return held(.{ .sized = shape });

        // **A type that writes its own JSON is not described by its fields**
        // (ADR 016). `std.json` calls `jsonStringify` and never looks at the
        // struct, so reflecting the struct describes something the server does
        // not send: a `Uuid` went out as a 36-character string and was
        // documented as an object with a `bytes` field, which broke every
        // generated client that read one.
        //
        // The same test ADR 036 uses to decide what its generated writer may
        // touch, asked here for the same reason. What a type says about itself
        // wins; a type that says nothing gets `{}` and a note, because being
        // visibly silent beats being confidently wrong.
        // **A document is its value** (ADR 163): `sql.Json(Theme)` sends a
        // `Theme` and is described as one, and `Json(std.json.Value)` falls
        // through to whatever the value says of itself — which for that one
        // is nothing, and `untold` below is the honest answer.
        if (mark.documentOf(T)) |Inner| return schemaWithin(Inner, depth + 1, written);
        if (writesItsOwnJson(T)) {
            if (@hasDecl(T, "nilo_openapi")) return held(.{ .told = toldOf(T) });
            return held(.untold);
        }
        // **A type that parses itself arrives as text, and its fields are
        // not what arrives** (ADR 166). One that said what it looks like is
        // described as that; `sql.Ordering` is one, and so is a bounded
        // integer, which says its bounds.
        if (convert.parsesItself(T)) {
            if (@hasDecl(T, "nilo_openapi")) return held(.{ .told = toldOf(T) });
        }
        // **And a type that writes its own body is not JSON at all**
        // (ADR 157): the bytes under its label are whatever `nilo_write`
        // put there, and the only thing this document can say about them
        // is what the type says with `nilo_openapi` — or that it said
        // nothing, which is the same discipline as above. The same holds
        // for a type that reads its own bytes (ADR 256).
        if (@import("ownbody.zig").writesItsOwnBody(T) or @import("message.zig").decodesItsOwnBody(T)) {
            if (@hasDecl(T, "nilo_openapi")) return held(.{ .told = toldOf(T) });
            return held(.untold);
        }

        return switch (@typeInfo(T)) {
            .bool => held(.boolean),
            // An integer refuses what its type cannot hold with a 400, so the
            // document says both ends: a promise the signature makes
            // (ADR 167).
            .int => held(.{ .bounded = widthOf(T) }),
            .comptime_int => held(.integer),
            .float, .comptime_float => held(.number),

            // The choices are the names that go out, which is not the same as
            // the field names once `rename_all` is in play (ADR 016).
            .@"enum" => |e| blk: {
                if (mark.marked(T)) break :blk held(.{ .choice = mark.wireNames(T) });
                var names: []const []const u8 = &.{};
                for (e.field_names) |f_name| names = names ++ [_][]const u8{f_name};
                break :blk held(.{ .choice = names });
            },

            .optional => |o| held(.{ .nullable = schemaWithin(o.child, depth + 1, written) }),

            // A tagged union has a derivable shape and used to get `{}`
            // (ADR 016). `std.json` writes it externally tagged — one object
            // with one key — so JSON Schema says it with `oneOf`. An
            // *untagged* union still gets `{}`, which is the honest answer:
            // nothing in the type says which arm is live, so nothing can.
            .@"union" => |u| if (u.tag_type == null) held(.unknown) else blk: {
                const said = mark.of(T);
                const names = mark.wireNames(T);
                var cases: []const Case = &.{};
                for (u.field_types, names) |f_type, on_the_wire| cases = cases ++ [_]Case{.{
                    .name = on_the_wire,
                    // A variant carrying nothing has no shape under its name,
                    // and only the internally tagged encoding can say so — the
                    // name is the whole of the object there (ADR 016).
                    .schema = if (f_type == void) held(.unknown) else schemaWithin(f_type, depth + 1, written),
                }};
                break :blk held(.{ .one_of = .{
                    .tag = if (said) |m| m.tag else null,
                    .cases = cases,
                } });
            },

            .@"struct" => |s| blk: {
                // A tuple is a list of mixed things, which JSON Schema can
                // describe and this deliberately does not try to.
                if (s.is_tuple) break :blk held(.unknown);

                // The keys are the names that go out, which is not the same as
                // the field names once `rename_all` is in play — the same
                // sentence the enum arm above makes, now true of a struct too
                // ([ADR 148](../docs/adr/148-a-field-name-is-a-spelling-too.md)).
                // A document that named `full_name` while the server sent
                // `fullName` is the failure ADR 016 already recorded once.
                const said = mark.of(T);
                var fields: []const Field = &.{};
                // Each field is described, and a field that is a struct is a
                // walk of its own: 200 fields stopped at "evaluation exceeded
                // 20000 backwards branches" at this line.
                @setEvalBranchQuota(20_000 + 4 * convert.budget(s.field_names));
                for (s.field_names, s.field_types, s.field_attrs) |f_name, f_type, f_attrs| {
                    fields = fields ++ [_]Field{.{
                        .name = mark.wire(f_name, said),
                        .schema = schemaWithin(f_type, depth + 1, written),
                        // Read: the rule the readers apply (`field.zig`), a
                        // field the client may leave out is not required,
                        // whether it has a default or is a `?T`. Written: the
                        // writer sends every field it has, a `?T` that is
                        // empty as `null` (`json.zig`), so the answer is
                        // required whatever its default is, and a client does
                        // not null-check what the server always sends. A
                        // `void` field is the one the writer skips.
                        .required = if (written)
                            f_type != void
                        else
                            !field_mod.FieldRule(f_type, f_attrs).may_be_absent,
                    }};
                }
                break :blk held(.{ .object = .{
                    .name = nameOf(T),
                    .fields = fields,
                    .open = mark.ignoresUnknown(T),
                    .input = !written,
                } });
            },

            .pointer => |p| switch (p.size) {
                // `[]const u8` is text, not a list of numbers — the same
                // reading `std.json` gives it.
                .slice => if (p.child == u8)
                    held(.string)
                else
                    held(.{ .array = schemaWithin(p.child, depth + 1, written) }),
                // A single-item pointer is followed: `*const Config` in a
                // response is the config, as far as JSON is concerned.
                .one => schemaWithin(p.child, depth + 1, written),
                else => held(.unknown),
            },

            .array => |a| if (a.child == u8)
                held(.string)
            else
                held(.{ .array = schemaWithin(a.child, depth + 1, written) }),

            else => held(.unknown),
        };
    }
}

/// The range an integer type holds. The reader takes the token's digits as
/// they are (`parseInt`, [ADR 084](../docs/adr/084-a-number-in-a-request-is-not-a-zig-literal.md)),
/// so a `u64` above 2^53 arrives exact and the bound is the type's own.
/// `Bounds` is an `i128`, so a type whose top does not fit one (`u128`
/// and wider) states no `maximum` rather than a wrong one, and one whose
/// bottom does not fit (`i129` and wider) states neither end.
fn widthOf(comptime T: type) Bounds {
    comptime {
        const i = @typeInfo(T).int;
        const signed = i.signedness == .signed;
        const fits_below = if (signed) i.bits <= 128 else true;
        const fits_above = if (signed) i.bits <= 128 else i.bits <= 127;
        return .{
            .min = if (!fits_below) null else if (signed) std.math.minInt(T) else 0,
            .max = if (fits_above) std.math.maxInt(T) else null,
        };
    }
}

/// `T.nilo_text`, or null for a type that carries none. Read by name the
/// way `nilo_within` is, and checked the same way.
fn textOf(comptime T: type) ?TextShape {
    comptime {
        const holds = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, text_marker),
            else => false,
        };
        if (!holds) return null;
        const said = @field(T, text_marker);
        const Said = @TypeOf(said);
        if (@typeInfo(Said) != .@"struct" or !@hasField(Said, "min") or !@hasField(Said, "max") or !@hasField(Said, "format")) @compileError(
            "nilo: " ++ @typeName(T) ++ "'s `" ++ text_marker ++ "` does not say `min`, `max` and `format`, " ++
                "which is what shaped text's document carries.\n" ++
                "  Write `pub const " ++ text_marker ++ " = .{ .min = 10, .max = 72, .format = null };`, or use `nilo.Text(.{ .min = 10, .max = 72 })`.",
        );
        return .{ .min = said.min, .max = said.max, .format = said.format };
    }
}

/// `T.nilo_within`, or null for a type that carries none. Read by name for
/// the reason every marker is, and checked here so a marker written wrong is
/// a sentence rather than a `has no member named 'min'` inside this file.
fn withinOf(comptime T: type) ?Bounds {
    comptime {
        const holds = switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, within_marker),
            else => false,
        };
        if (!holds) return null;
        const said = @field(T, within_marker);
        const Said = @TypeOf(said);
        if (@typeInfo(Said) != .@"struct" or !@hasField(Said, "min") or !@hasField(Said, "max")) @compileError(
            "nilo: " ++ @typeName(T) ++ "'s `" ++ within_marker ++ "` does not say both a `min` " ++
                "and a `max`, which is what a bounded integer's document carries.\n" ++
                "  Write `pub const " ++ within_marker ++ " = .{ .min = 1, .max = 200 };`, or use `nilo.Within(1, 200)`.",
        );
        return .{ .min = said.min, .max = said.max };
    }
}

/// `T.nilo_openapi`, read field by field rather than coerced.
///
/// It is written as `.{ .type = "string", .format = "uuid" }` in a module that
/// may not import this one — `nilo_id` imports nothing at all (ADR 038) — so
/// it arrives as an anonymous struct and there is no shared type to coerce it
/// to. Reading it here is also where a mistake gets a sentence: a marker with
/// no `type` is the one way to write this wrong, and it would otherwise be a
/// `has no member named 'type'` pointing at a line of nilo's.
fn toldOf(comptime T: type) Told {
    comptime {
        const said = T.nilo_openapi;
        const Said = @TypeOf(said);
        if (!@hasField(Said, "type")) @compileError(
            "nilo: " ++ @typeName(T) ++ "'s `nilo_openapi` has no `type`, so it does not say " ++
                "what this value looks like in JSON. Write `pub const nilo_openapi = " ++
                ".{ .type = \"string\" };`, with `type` one of \"string\", \"integer\", " ++
                "\"number\" or \"boolean\", and an optional `format`.",
        );
        return .{
            .type = said.type,
            .format = if (@hasField(Said, "format")) said.format else null,
        };
    }
}

/// Whether `T` supplies the JSON `std.json` writes for it.
///
/// `@hasDecl` only answers for a container, so the kind is checked first —
/// asking it about `u32` is a compile error rather than a false.
fn writesItsOwnJson(comptime T: type) bool {
    comptime {
        return switch (@typeInfo(T)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "jsonStringify"),
            else => false,
        };
    }
}

/// A pointer to a Schema that lives in read-only memory rather than on
/// somebody's stack. The same trick `typed.rolesOf` uses to hand back a
/// slice built at compile time.
fn held(comptime s: Schema) *const Schema {
    const frozen = s;
    return &frozen;
}

/// The name to file `T`'s shape under, or null for a struct whose name would
/// be noise in somebody's generated client.
///
/// What gets a name is a type a person declared and can say out loud: `User`,
/// `NewUser`, `Address` — and an instantiated generic, which reads as
/// `main.Page(main.Order)` and is filed as `Page_Order`. What does not is an
/// anonymous struct, because the compiler names those after where they were
/// written (`main.main__struct_2914`) and that is a name that moves when a
/// line is added above it.
fn nameOf(comptime T: type) ?[]const u8 {
    comptime {
        const full = @typeName(T);
        if (std.mem.indexOf(u8, full, "__") != null) return null;

        const short = shortNameOf(full);
        if (isIdentifier(short)) return full;

        // Not an identifier, so either an instantiated generic — which has a
        // name once it is read rather than copied — or something this does
        // not recognise, which gets none.
        if (std.mem.indexOfScalar(u8, full, '(') == null) return null;
        return genericNameOf(full);
    }
}

fn isIdentifier(comptime name: []const u8) bool {
    comptime {
        if (name.len == 0) return false;
        if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
        for (name[1..]) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        }
        return true;
    }
}

/// A generic instantiation, rendered as a name a document can use.
///
/// `Page(T)` and `Addressed(Text)` are how Zig says "the same shape, twice"
/// — which is the answer to writing every request struct out a second time
/// with `Str` in it. The answer should not cost the shape its name, so the
/// compiler's rendering is turned back into an identifier: module prefixes
/// dropped, `[]const u8` read as `Text`, the pieces joined with `_`.
///
/// ```
/// main.Page(main.Order)        -> Page_Order
/// main.Addressed(str.Str)      -> Addressed_Str
/// main.Addressed([]const u8)   -> Addressed_Text
/// ```
///
/// Null when the result would not be an identifier — a numeric parameter, a
/// pointer with attributes, anything this does not recognise. An unnamed
/// shape is written out where it appears, which is what every generic used
/// to get and is never wrong, only repetitive.
fn genericNameOf(comptime full: []const u8) ?[]const u8 {
    comptime {
        // Building a string a character at a time is what a comptime branch
        // budget is counted in, and the default budget is smaller than a
        // handful of type names. Raised here rather than by whoever calls
        // `docs()`, because a quota is not a thing anybody should have to
        // know about to describe their API.
        @setEvalBranchQuota(100 * full.len + 4_000);
        // The one spelling common enough to be worth reading rather than
        // taking apart: a slice of bytes is text, and `List_const_u8` would
        // be nobody's idea of a name.
        var text = replaceAll(full, "[]const u8", "Text");
        text = replaceAll(text, "[]u8", "Text");

        var out: []const u8 = "";
        var segment: []const u8 = "";
        for (text) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '_') {
                segment = segment ++ [_]u8{ch};
                continue;
            }
            // A dot means what came before it was the module, not the type.
            if (ch == '.') {
                segment = "";
                continue;
            }
            out = out ++ joinable(segment, out);
            segment = "";
        }
        out = out ++ joinable(segment, out);

        if (out.len == 0) return null;
        if (!std.ascii.isAlphabetic(out[0]) and out[0] != '_') return null;
        return out;
    }
}

/// One rendered piece, with the separator it needs — and nothing at all for
/// the pieces that are Zig grammar rather than names.
fn joinable(comptime segment: []const u8, comptime so_far: []const u8) []const u8 {
    comptime {
        if (segment.len == 0) return "";
        for ([_][]const u8{ "const", "volatile", "allowzero", "align" }) |word| {
            if (std.mem.eql(u8, segment, word)) return "";
        }
        return if (so_far.len == 0) segment else "_" ++ segment;
    }
}

fn replaceAll(comptime haystack: []const u8, comptime needle: []const u8, comptime with: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var rest = haystack;
        while (std.mem.indexOf(u8, rest, needle)) |at| {
            out = out ++ rest[0..at] ++ with;
            rest = rest[at + needle.len ..];
        }
        return out ++ rest;
    }
}

/// The last segment of a full type name — `myapp.models.User` → `User`.
fn shortNameOf(full: []const u8) []const u8 {
    var start = full.len;
    while (start > 0 and full[start - 1] != '.') start -= 1;
    return full[start..];
}

// ---- the shapes that are written once and referred to ----

/// What the failure body goes by in the document. Not `Error`, which is a
/// name a user type may well already have taken.
const error_schema_name = "Failure";

/// One named shape in the document.
const Slot = struct {
    name: []const u8,
    schema: *const Schema,
    /// Whether two shapes turned out to answer to this name. A declared type
    /// cannot collide with another — its full name has its module in it — but
    /// a *rendered* one can: `a.Page(b.Order)` and `c.Page(d.Order)` are both
    /// `Page_Order`. When that happens neither gets the name, and both are
    /// written out where they appear. Bigger document, still a true one.
    contested: bool = false,
    /// The other name this slot answers to, when a shape arrived twice
    /// because its `Str` half and its `Text` half are separate Zig types
    /// (ADR 016). Empty for every other slot, which is most of them.
    twin: []const u8 = "",
    /// The request half of a type (`Object.input`), which is a slot of its
    /// own beside the response half under the same name.
    input: bool = false,
    /// Set by `settle` on a request half that renders exactly as the
    /// response half of the same type: it is that slot, not a second one.
    same_as: ?usize = null,
    /// Set by `settle` on a request half that differs from a response half
    /// beside it: it is written as `<Name>Input`. A request half with no
    /// response half keeps the plain name.
    suffixed: bool = false,
};

/// The named shapes a document refers to rather than repeating. Collected in
/// one pass over the routes before anything is written, because the
/// `components` section and the `$ref`s pointing into it have to agree and
/// only one of them can be written first.
///
/// A list that grows rather than an array of sixty-four: a product of six
/// contexts reached the fixed ceiling, and past it a shape was written out
/// in place — a true document whose generated client had lost the name
/// ([ADR 170](../docs/adr/170-a-document-names-every-shape-it-has.md)).
/// The document is written once, before the server listens, so the list is
/// the one allocation that is free to make here.
const Components = struct {
    gpa: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,

    fn init(gpa: std.mem.Allocator) Components {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Components) void {
        self.slots.deinit(self.gpa);
    }

    fn count(self: *const Components) usize {
        return self.slots.items.len;
    }

    fn gather(self: *Components, ops: []const Operation) !void {
        for (ops) |op| {
            for (op.params) |p| try self.add(p.schema);
            for (op.query) |f| try self.add(f.schema);
            if (op.body) |b| try self.add(b);
            if (op.answer.schema) |s| try self.add(s);
        }
    }

    fn add(self: *Components, schema: *const Schema) !void {
        switch (schema.*) {
            .object => |o| {
                if (o.name) |full| {
                    if (self.indexOf(full, o.input)) |i| {
                        // The same shape under the same name — and its fields
                        // were walked when it was first seen. This is also
                        // what stops a type holding one of its own from
                        // recursing for ever.
                        if (sameShape(self.slots.items[i].schema, schema)) return;
                        // A second shape wanting the same name. Once is
                        // enough to settle it; returning on the second visit
                        // is what keeps a self-referential one from looping.
                        if (self.slots.items[i].contested) return;
                        self.slots.items[i].contested = true;
                    } else if (self.lifetimeTwinOf(full, schema)) |i| {
                        // The same shape, once with `Str` in it and once with
                        // `Text` — one JSON shape wearing two Zig lifetimes
                        // (ADR 016). Its fields were walked when the first
                        // half was seen.
                        self.slots.items[i].twin = full;
                        return;
                    } else {
                        try self.slots.append(self.gpa, .{ .name = full, .schema = schema, .input = o.input });
                    }
                }
                for (o.fields) |f| try self.add(f.schema);
            },
            .array => |item| try self.add(item),
            .nullable => |inner| try self.add(inner),
            .one_of => |o| for (o.cases) |case| try self.add(case.schema),
            else => {},
        }
    }

    /// Whether two schemas are the same shape, as far as sharing a name goes.
    /// Field names and their order, which is enough: the same type reached by
    /// two routes produces two `Schema` values at two addresses, and the only
    /// thing this has to tell apart is two *different* types that render to
    /// one name.
    fn sameShape(a: *const Schema, b: *const Schema) bool {
        if (a == b) return true;
        const one = switch (a.*) {
            .object => |o| o,
            else => return false,
        };
        const other = switch (b.*) {
            .object => |o| o,
            else => return false,
        };
        if (one.fields.len != other.fields.len) return false;
        for (one.fields, other.fields) |f, g| {
            if (!std.mem.eql(u8, f.name, g.name) or f.required != g.required) return false;
        }
        return true;
    }

    /// The slot holding this shape's other half, if it has one.
    ///
    /// **What splits it is a Zig lifetime, and a lifetime has no rendering in
    /// JSON.** `Meta(Str)` is the body half of a shape and `Meta(Text)` is the
    /// row half, which is the split nilo itself asks for
    /// ([ADR 003](../docs/adr/003-request-arena-and-the-str-type.md)); both
    /// used to reach a generated client as `Meta_Str` and `Meta_Text`,
    /// byte-identical and twice.
    ///
    /// Narrow on purpose (ADR 016): only a `_Str`/`_Text` pair over the same
    /// stem, and only when the two render the same all the way down. Anything
    /// else keeps its own name — `Page_Order` and `Page_User` share field
    /// names and are not the same shape.
    fn lifetimeTwinOf(self: *const Components, full: []const u8, schema: *const Schema) ?usize {
        const stem = stemOf(full) orelse return null;
        for (self.slots.items, 0..) |slot, i| {
            if (slot.twin.len > 0) continue;
            const other_stem = stemOf(slot.name) orelse continue;
            if (!std.mem.eql(u8, stem, other_stem)) continue;
            if (std.mem.eql(u8, slot.name, full)) continue;
            if (rendersTheSame(slot.schema, schema)) return i;
        }
        return null;
    }

    /// The name without the half that is only a lifetime: `Meta_Str` → `Meta`.
    /// Null for a name that is not one half of such a pair.
    fn stemOf(name: []const u8) ?[]const u8 {
        for ([_][]const u8{ "_Str", "_Text" }) |half| {
            if (std.mem.endsWith(u8, name, half) and name.len > half.len)
                return name[0 .. name.len - half.len];
        }
        return null;
    }

    /// The slot this shape is named in, or null if it has no name of its own
    /// in this document — either it never had one, or something else wanted
    /// the same one.
    fn slotFor(self: *const Components, full: []const u8, input: bool) ?usize {
        var i = self.indexOf(full, input) orelse return null;
        if (self.slots.items[i].same_as) |into| i = into;
        return if (self.slots.items[i].contested) null else i;
    }

    fn indexOf(self: *const Components, full: []const u8, input: bool) ?usize {
        for (self.slots.items, 0..) |slot, i| {
            // A twin pair is the request half with `Str` in it and the
            // response half with `Text`, and they merge only when they render
            // the same, so whichever of the two arrived first holds both.
            if (slot.input == input and std.mem.eql(u8, slot.name, full)) return i;
            if (slot.twin.len > 0 and std.mem.eql(u8, slot.twin, full)) return i;
        }
        return null;
    }

    /// Decide, once every shape is gathered, which request halves are the
    /// response half of the same type and which are a component of their own.
    /// A request schema keeps the rule the readers apply (a default or a
    /// `?T` may be left out) and a response schema lists what the writer
    /// always sends, so a type used both ways often has two shapes. Where
    /// they render the same, one component serves both, as before. Where
    /// they differ the response keeps the plain name and the request is
    /// `<Name>Input`, each referred to from where it is used. The test is
    /// the whole shape, so a type holding such a type differs too.
    fn settle(self: *Components) void {
        for (self.slots.items, 0..) |*slot, i| {
            if (!slot.input or slot.contested) continue;
            const j = self.indexOf(slot.name, false) orelse continue;
            if (self.slots.items[j].contested) continue;
            if (rendersTheSame(self.slots.items[j].schema, slot.schema)) {
                self.slots.items[i].same_as = j;
            } else {
                self.slots.items[i].suffixed = true;
            }
        }
    }

    /// What this shape is called in the document: its short name, unless
    /// something else in the same document would answer to it too. Two
    /// modules can both have a `User`, and a client generator handed one
    /// `User` meaning two shapes produces code that does not compile — so
    /// where that happens both keep their full names.
    fn writeName(self: *const Components, w: *std.Io.Writer, i: usize) !void {
        try writeComponentName(w, self.nameAt(i));
        if (self.slots.items[i].suffixed) try writeComponentName(w, self.suffixAt(i));
    }

    /// A merged pair drops the half that was only a lifetime, so the client
    /// gets `Meta` rather than one of `Meta_Str` and `Meta_Text` standing in
    /// for both.
    fn nameAt(self: *const Components, i: usize) []const u8 {
        const full = self.slots.items[i].name;
        if (self.slots.items[i].twin.len > 0) return stemOf(full) orelse full;
        const short = shortNameOf(full);
        return if (self.shortIsFree(i, short)) short else full;
    }

    /// What a request half with a response half beside it adds to its name.
    /// Behind a full name it follows a `.`, which a component name may hold, so it
    /// cannot meet a type whose own name ends in `Input`.
    fn suffixAt(self: *const Components, i: usize) []const u8 {
        const full = self.slots.items[i].name;
        const base = nameAt(self, i);
        return if (std.mem.eql(u8, base, full) and self.slots.items[i].twin.len == 0 and
            !std.mem.eql(u8, base, shortNameOf(full))) ".Input" else "Input";
    }

    fn shortIsFree(self: *const Components, i: usize, short: []const u8) bool {
        const mine: []const u8 = if (self.slots.items[i].suffixed) "Input" else "";
        if (std.mem.eql(u8, short, error_schema_name) and mine.len == 0) return false;
        for (self.slots.items, 0..) |other, j| {
            // A contested slot is written nowhere, so it is not competing
            // for the short name it would otherwise have taken, and a request
            // half that is another slot is not written either.
            if (j == i or other.contested or other.same_as != null) continue;
            const other_short = if (other.twin.len > 0)
                (stemOf(other.name) orelse other.name)
            else
                shortNameOf(other.name);
            const theirs: []const u8 = if (other.suffixed) "Input" else "";
            if (sameJoined(other_short, theirs, short, mine)) return false;
        }
        return true;
    }

    /// Whether `a ++ b` is `c ++ d`, without building either.
    fn sameJoined(a: []const u8, b: []const u8, c: []const u8, d: []const u8) bool {
        if (a.len + b.len != c.len + d.len) return false;
        var k: usize = 0;
        while (k < a.len + b.len) : (k += 1) {
            const x = if (k < a.len) a[k] else b[k - a.len];
            const y = if (k < c.len) c[k] else d[k - c.len];
            if (x != y) return false;
        }
        return true;
    }

    /// Whether two schemas produce the same JSON, all the way down.
    ///
    /// Stronger than `sameShape`, and needed for a stronger claim: `sameShape`
    /// only has to tell two *different* types that rendered to one name apart,
    /// so field names are enough. Merging two shapes into one component says
    /// they are interchangeable to a client, which is a claim about every
    /// field's type as well (ADR 016).
    ///
    /// Terminates because `max_depth` caps a Schema's height — a type holding
    /// one of its own becomes `unknown` at the eighth level.
    fn rendersTheSame(a: *const Schema, b: *const Schema) bool {
        if (a == b) return true;
        if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
        return switch (a.*) {
            .string, .integer, .number, .boolean, .binary, .untold, .unknown => true,
            .bounded => |x| x.min == b.bounded.min and x.max == b.bounded.max,
            .sized => |x| x.min == b.sized.min and x.max == b.sized.max and
                ((x.format == null and b.sized.format == null) or
                    (x.format != null and b.sized.format != null and
                        std.mem.eql(u8, x.format.?, b.sized.format.?))),
            .told => |t| std.mem.eql(u8, t.type, b.told.type) and
                ((t.format == null and b.told.format == null) or
                    (t.format != null and b.told.format != null and
                        std.mem.eql(u8, t.format.?, b.told.format.?))),
            .choice => |names| blk: {
                if (names.len != b.choice.len) break :blk false;
                for (names, b.choice) |one, other| {
                    if (!std.mem.eql(u8, one, other)) break :blk false;
                }
                break :blk true;
            },
            .array => |item| rendersTheSame(item, b.array),
            .nullable => |inner| rendersTheSame(inner, b.nullable),
            .object => |o| blk: {
                if (o.fields.len != b.object.fields.len) break :blk false;
                if (o.open != b.object.open) break :blk false;
                for (o.fields, b.object.fields) |f, g| {
                    if (!std.mem.eql(u8, f.name, g.name)) break :blk false;
                    if (f.required != g.required) break :blk false;
                    if (!rendersTheSame(f.schema, g.schema)) break :blk false;
                }
                break :blk true;
            },
            .one_of => |o| blk: {
                // The encoding is part of the shape, not a rendering of it: the
                // same arms under a discriminator are a different document, and
                // merging the two would hand a client one name for both.
                if ((o.tag == null) != (b.one_of.tag == null)) break :blk false;
                if (o.tag) |key| if (!std.mem.eql(u8, key, b.one_of.tag.?)) break :blk false;
                if (o.cases.len != b.one_of.cases.len) break :blk false;
                for (o.cases, b.one_of.cases) |one, other| {
                    if (!std.mem.eql(u8, one.name, other.name)) break :blk false;
                    if (!rendersTheSame(one.schema, other.schema)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Whether anything in this document promises a failure, and so whether
    /// the shape those failures take has to be described.
    fn anyFailure(ops: []const Operation) bool {
        for (ops) |op| {
            if (op.can_reject or op.answer.not_found or op.security != .none) return true;
        }
        return false;
    }

    /// Whether any route signs in with `which`, and so whether that scheme
    /// has to be described.
    fn anyGuarded(ops: []const Operation) bool {
        for (ops) |op| {
            if (op.guarded) return true;
        }
        return false;
    }

    fn anySecurity(ops: []const Operation, which: Security) bool {
        for (ops) |op| {
            if (op.security == which) return true;
        }
        return false;
    }
};

// ---- writing the document ----

/// Write the whole OpenAPI document for `ops`.
///
/// Called once, from `resolveChains()`, against a buffer that becomes a file
/// served from memory. Nothing here runs while a request is in flight, so it
/// is written for clarity rather than for speed — the quadratic grouping
/// below included, over a route list that is dozens long at most.
pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer, ops: []const Operation, info: Info) !void {
    var components = Components.init(gpa);
    defer components.deinit();
    try components.gather(ops);
    // A failure shape of the application's is written inline under
    // `Failure` rather than under its own name, so only what it holds is
    // gathered — a nested struct it carries gets a slot like any other.
    if (info.failure) |shape| {
        switch (shape.*) {
            .object => |o| for (o.fields) |f| try components.add(f.schema),
            else => try components.add(shape),
        }
    }
    components.settle();

    try w.writeAll("{\"openapi\":\"3.1.0\",\"info\":{\"title\":");
    try writeString(w, info.title);
    try w.writeAll(",\"version\":");
    try writeString(w, info.version);
    if (info.description.len > 0) {
        try w.writeAll(",\"description\":");
        try writeString(w, info.description);
    }
    try w.writeAll("},\"paths\":{");

    var wrote_path = false;
    for (ops, 0..) |op, i| {
        // One entry per path, holding every method registered on it. The
        // first occurrence opens it and gathers the rest.
        if (alreadyWritten(ops[0..i], op.pattern)) continue;
        if (wrote_path) try w.writeByte(',');
        wrote_path = true;

        try writePathTemplate(w, op.pattern);
        try w.writeByte(':');
        try w.writeByte('{');

        var wrote_method = false;
        for (ops[i..]) |sibling| {
            if (!std.mem.eql(u8, sibling.pattern, op.pattern)) continue;
            // Not a verb anybody registered, so not a verb to document.
            if (sibling.method == .other) continue;
            if (wrote_method) try w.writeByte(',');
            wrote_method = true;
            try writeOperation(w, &components, sibling);
        }

        try w.writeByte('}');
    }

    try w.writeAll("},\"components\":{\"schemas\":{");
    var wrote_schema = false;
    if (Components.anyFailure(ops)) {
        try w.writeAll("\"" ++ error_schema_name ++ "\":");
        if (info.failure) |shape| {
            switch (shape.*) {
                .object => |o| try writeObject(w, &components, o),
                else => try writeSchema(w, &components, shape),
            }
        } else {
            try w.writeAll(error_schema);
        }
        wrote_schema = true;
    }
    for (components.slots.items, 0..) |slot, i| {
        // A name two shapes wanted belongs to neither, and both were written
        // out where they appear rather than referred to here.
        if (slot.contested or slot.same_as != null) continue;
        if (wrote_schema) try w.writeByte(',');
        wrote_schema = true;
        try w.writeByte('"');
        try components.writeName(w, i);
        try w.writeAll("\":");
        try writeObject(w, &components, slot.schema.object);
    }
    try w.writeByte('}');

    // Only the schemes a route actually takes: a document that lists a
    // scheme nothing uses is a document promising a sign-in that goes
    // nowhere (ADR 153).
    var wrote_scheme = false;
    for ([_]Security{ .bearer, .basic }) |which| {
        if (!Components.anySecurity(ops, which)) continue;
        try w.writeAll(if (wrote_scheme) "," else ",\"securitySchemes\":{");
        wrote_scheme = true;
        try w.print("\"{s}\":{{\"type\":\"http\",\"scheme\":\"{s}\"}}", .{
            which.name(),
            switch (which) {
                .bearer => "bearer",
                .basic => "basic",
                .none => unreachable,
            },
        });
    }
    // The cookie: `apiKey` in a cookie is the one spelling OpenAPI has for
    // a session, and every generator reads it as "send the cookie" (ADR 153).
    if (info.cookie) |cookie| if (Components.anyGuarded(ops)) {
        try w.writeAll(if (wrote_scheme) "," else ",\"securitySchemes\":{");
        wrote_scheme = true;
        try w.print("\"{s}\":{{\"type\":\"apiKey\",\"in\":\"cookie\",\"name\":", .{cookie_scheme});
        try writeString(w, cookie);
        try w.writeByte('}');
    };
    if (wrote_scheme) try w.writeByte('}');

    try w.writeAll("}}");
}

/// The shape of every failure nilo assembles (ADR 024). Written out here
/// rather than derived from a Zig type, because the type it would be derived
/// from is a fixed buffer and a status code, not a struct anybody returns.
const error_schema =
    "{\"type\":\"object\",\"properties\":{" ++
    "\"error\":{\"type\":\"string\",\"description\":\"what went wrong, in words\"}," ++
    "\"status\":{\"type\":\"integer\"}}," ++
    "\"required\":[\"error\",\"status\"]}";

fn alreadyWritten(earlier: []const Operation, pattern: []const u8) bool {
    for (earlier) |op| {
        if (std.mem.eql(u8, op.pattern, pattern)) return true;
    }
    return false;
}

fn writeOperation(w: *std.Io.Writer, components: *const Components, op: Operation) !void {
    try w.writeByte('"');
    for (@tagName(op.method)) |ch| try w.writeByte(std.ascii.toLower(ch));
    try w.writeAll("\":{\"operationId\":");
    try writeOperationId(w, op);

    if (op.params.len > 0 or op.query.len > 0 or op.headers.len > 0) {
        try w.writeAll(",\"parameters\":[");
        for (op.params, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try writeString(w, pathParamName(p.name));
            // A path param on a route that matched is always there, and
            // OpenAPI requires saying so explicitly.
            try w.writeAll(",\"in\":\"path\",\"required\":true,\"schema\":");
            try writeSchema(w, components, p.schema);
            try w.writeByte('}');
        }
        for (op.query, 0..) |f, i| {
            if (i > 0 or op.params.len > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try writeString(w, f.name);
            try w.print(",\"in\":\"query\",\"required\":{s},", .{
                if (f.required) "true" else "false",
            });
            // Which of the two spellings a generated client should send
            // (ADR 132). Only on a list, because on a scalar the pair means
            // nothing and every generator would carry it about anyway.
            if (f.list) try w.writeAll("\"style\":\"form\",\"explode\":false,");
            try w.writeAll("\"schema\":");
            try writeSchema(w, components, f.schema);
            try w.writeByte('}');
        }
        // Last, so that adding one does not move the path and query params a
        // generated client has already been built against (ADR 131).
        for (op.headers, 0..) |f, i| {
            if (i > 0 or op.params.len > 0 or op.query.len > 0) try w.writeByte(',');
            try w.writeAll("{\"name\":");
            try writeString(w, f.name);
            try w.print(",\"in\":\"header\",\"required\":{s},\"schema\":", .{
                if (f.required) "true" else "false",
            });
            try writeSchema(w, components, f.schema);
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }

    if (op.body) |body| {
        try w.writeAll(",\"requestBody\":{\"required\":true,\"content\":{");
        for (op.body_types, 0..) |content_type, i| {
            if (i != 0) try w.writeByte(',');
            try writeString(w, content_type);
            try w.writeAll(":{\"schema\":");
            try writeSchema(w, components, body);
            try w.writeByte('}');
        }
        try w.writeAll("}}");
    }

    // Before the responses, and written whether or not the route can be
    // refused for anything else: the 401 is nilo's, sent before the handler
    // runs, so the document can promise it (ADR 153). A guard's cookie and
    // a signature's header in one requirement object, which OpenAPI reads
    // as *both*: the guard ran first and the handler still asked (ADR 153).
    if (op.security != .none or op.guarded) {
        try w.writeAll(",\"security\":[{");
        if (op.guarded) try w.print("\"{s}\":[]", .{cookie_scheme});
        if (op.guarded and op.security != .none) try w.writeByte(',');
        if (op.security != .none) try w.print("\"{s}\":[]", .{op.security.name()});
        try w.writeAll("}]");
    }

    try w.writeAll(",\"responses\":{");
    try writeAnswer(w, components, op.answer);
    if (op.security != .none) {
        try writeFailure(w, "401", "no Authorization header, or not the scheme this endpoint " ++
            "takes; WWW-Authenticate says which");
    } else if (op.guarded) {
        try writeFailure(w, "401", "refused by the guard in front of this endpoint: no session " ++
            "cookie, or not one it accepts");
    }
    if (op.idempotent) {
        try writeFailure(w, "409", "a request with this Idempotency-Key is still being answered");
    }
    // Not a failure: no body, and the `ETag` the 200 carries. Only where a
    // client can be told it: a GET or a HEAD, because a write has run by
    // then and answers in full (ADR 189).
    if (op.answer.versioned and (op.method == .GET or op.method == .HEAD)) {
        try w.writeAll(",\"304\":{\"description\":\"the client already holds this version\"," ++
            "\"headers\":{\"ETag\":{\"description\":\"the version the client holds\"," ++
            "\"schema\":{\"type\":\"string\"}}}}");
    }
    if (op.can_reject) {
        try writeFailure(w, "400", "the request did not fit what this endpoint takes; " ++
            "the body says which part");
    }
    if (op.answer.not_found) {
        try writeFailure(w, "404", "there is no such thing");
    }
    // One key for both 422s a route can give, because a JSON object read
    // twice keeps one of them.
    if (op.idempotent) {
        try writeFailure(w, "422", if (op.misfit) both_422 else both_422[0..reused_key_len]);
    } else if (op.misfit) {
        try writeFailure(w, "422", both_422[both_422.len - misfit_len ..]);
    }
    try w.writeAll("}}");
}

/// The three 422 descriptions, as one string sliced three ways. This writer
/// is in every program that serves its document, whether or not a route says
/// `.misfit`, so three literals were 304 stripped bytes on `hello` and one is
/// what the Idempotency-Key sentence already cost (ADR 251).
const both_422 = "this Idempotency-Key was already used for a different request, " ++
    "or the body is JSON that does not fit what this endpoint takes";
const reused_key_len = "this Idempotency-Key was already used for a different request".len;
const misfit_len = "the body is JSON that does not fit what this endpoint takes".len;

/// A failure this endpoint's signature promises, carrying the shape every
/// failure nilo assembles has (ADR 024).
fn writeFailure(w: *std.Io.Writer, status: []const u8, description: []const u8) !void {
    try w.print(",\"{s}\":{{\"description\":", .{status});
    try writeString(w, description);
    try w.writeAll(",\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/" ++
        error_schema_name ++ "\"}}}}");
}

fn writeAnswer(w: *std.Io.Writer, components: *const Components, answer: Answer) !void {
    // A handler that writes its own response has told this document nothing,
    // and saying so is the only honest thing left. `default` with no content
    // is OpenAPI's way of writing "an answer, unspecified" — which beats the
    // "200, empty" that reading the return type alone would produce for a
    // handler that in fact streams a CSV.
    if (answer.written) {
        try w.writeAll("\"default\":{\"description\":\"this endpoint holds the Ctx and returns " ++
            "nothing, so it may write its own response — its signature does not settle what " ++
            "it answers\"}");
        return;
    }

    try w.writeByte('"');
    if (answer.status) |status| try w.print("{d}", .{status}) else try w.writeAll("default");
    try w.writeAll("\":{\"description\":");

    // A redirect promises a header rather than a body, and the header is the
    // whole of the answer — a client that cannot see it has nowhere to go.
    if (answer.redirect) {
        try w.writeAll("\"the client is sent somewhere else\",\"headers\":{\"Location\":" ++
            "{\"description\":\"where to go instead\",\"required\":true," ++
            "\"schema\":{\"type\":\"string\"}}}}");
        return;
    }

    // A file, described as bytes. The one content type this document writes
    // without having read it off a Zig type — see `Answer.binary` for why the
    // handler's own is not the one that goes here.
    if (answer.binary) {
        try w.writeAll("\"the file's bytes\",\"content\":{\"application/octet-stream\":" ++
            "{\"schema\":{\"type\":\"string\",\"format\":\"binary\"}}}}");
        return;
    }

    if (answer.schema == null) {
        try w.writeAll("\"an empty response\"}");
        return;
    }
    try w.writeAll(if (answer.status == null)
        "\"what the handler answers with; the status is chosen at runtime\""
    else
        "\"the response\"");
    try w.writeAll(",\"content\":{");
    try writeString(w, answer.content_type);
    try w.writeAll(":{\"schema\":");
    try writeSchema(w, components, answer.schema.?);
    // A message answers in the spelling it was asked in (ADR 256).
    for (answer.more_types) |content_type| {
        try w.writeAll("},");
        try writeString(w, content_type);
        try w.writeAll(":{\"schema\":");
        try writeSchema(w, components, answer.schema.?);
    }
    try w.writeAll("}}");
    if (answer.versioned) {
        try w.writeAll(",\"headers\":{\"ETag\":{\"description\":\"the version of the body; " ++
            "send it back as If-None-Match to be told when it has not changed\"," ++
            "\"schema\":{\"type\":\"string\"}}}");
    }
    try w.writeByte('}');
}

/// `getUsersId` — a name for the endpoint that a client generator can turn
/// into a method. Built from the verb and the path so that it is stable
/// across runs and unique wherever the routes are.
///
/// **Unless the route said its own** (ADR 119). The derived name is a good
/// default and a poor key: it is not a word anybody chose, and it changes when
/// the path moves. A consumer keying an authorisation table off it wants both
/// of those the other way round, so `app.named("addPartnerCapability")` puts
/// the name in the route's own hands.
fn writeOperationId(w: *std.Io.Writer, op: Operation) !void {
    try w.writeByte('"');
    if (op.name) |given| {
        try w.writeAll(given);
    } else {
        try writeDerivedName(w, op.method, op.pattern);
    }
    try w.writeByte('"');
}

/// The `operationId` a route that said nothing gets: `getUsersId` for
/// `GET /users/:id`, with a catch-all read as `path`.
///
/// Public because it is written twice — into the document here, and onto
/// the `Route` at registration so that `Ctx.routeName` answers the same word
/// the document prints ([ADR 162](../docs/adr/162-a-middleware-can-learn-which-route-it-is-in-front-of.md)).
/// One copy of the derivation is what keeps those two from drifting, which
/// is the property an authorisation table keyed by the name depends on.
pub fn writeDerivedName(w: *std.Io.Writer, method: http1.Method, pattern: []const u8) !void {
    for (@tagName(method)) |ch| try w.writeByte(std.ascii.toLower(ch));

    var segments = std.mem.splitScalar(u8, pattern, '/');
    while (segments.next()) |seg| {
        const text = if (seg.len > 1 and seg[0] == ':')
            seg[1..]
        else if (std.mem.eql(u8, seg, "*"))
            "path"
        else
            seg;
        var start_of_word = true;
        for (text) |ch| {
            if (!std.ascii.isAlphanumeric(ch)) {
                start_of_word = true;
                continue;
            }
            try w.writeByte(if (start_of_word) std.ascii.toUpper(ch) else ch);
            start_of_word = false;
        }
    }
}

/// `/users/:id` → `"/users/{id}"`, and a catch-all `*` → `{path}`, which is
/// the closest OpenAPI has to one.
fn writePathTemplate(w: *std.Io.Writer, pattern: []const u8) !void {
    try w.writeByte('"');
    // Every pattern begins with a slash, and the router treats "/api" and
    // "/api/" as one route, so the leading empty segment is skipped and each
    // slash written back on.
    var segments = std.mem.splitScalar(u8, pattern[1..], '/');
    while (segments.next()) |seg| {
        try w.writeByte('/');
        if (seg.len > 1 and seg[0] == ':') {
            try w.writeByte('{');
            try writeEscaped(w, seg[1..]);
            try w.writeByte('}');
        } else if (std.mem.eql(u8, seg, "*")) {
            try w.writeAll("{path}");
        } else {
            try writeEscaped(w, seg);
        }
    }
    try w.writeByte('"');
}

/// The name a catch-all goes by in the document. `*` is what `c.param`
/// answers to and is not a name OpenAPI accepts, so the two differ here and
/// nowhere else.
fn pathParamName(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "*")) "path" else name;
}

/// One schema, as it appears inside a route: a shape with a name of its own
/// is a `$ref` into `components`, and everything else is written out.
/// The error set is written out rather than inferred: this and `writeObject`
/// call each other, and two inferred sets that depend on one another are a
/// loop the compiler cannot settle.
fn writeSchema(
    w: *std.Io.Writer,
    components: *const Components,
    schema: *const Schema,
) std.Io.Writer.Error!void {
    switch (schema.*) {
        .string => try w.writeAll("{\"type\":\"string\"}"),
        .integer => try w.writeAll("{\"type\":\"integer\"}"),
        .bounded => |b| {
            try w.writeAll("{\"type\":\"integer\"");
            if (b.min) |min| try w.print(",\"minimum\":{d}", .{min});
            if (b.max) |max| try w.print(",\"maximum\":{d}", .{max});
            try w.writeByte('}');
        },
        .sized => |s| {
            try w.writeAll("{\"type\":\"string\"");
            if (s.min) |min| try w.print(",\"minLength\":{d}", .{min});
            if (s.max) |max| try w.print(",\"maxLength\":{d}", .{max});
            if (s.format) |f| {
                try w.writeAll(",\"format\":");
                try writeString(w, f);
            }
            try w.writeByte('}');
        },
        .number => try w.writeAll("{\"type\":\"number\"}"),
        .boolean => try w.writeAll("{\"type\":\"boolean\"}"),
        .binary => try w.writeAll("{\"type\":\"string\",\"format\":\"binary\"}"),
        .unknown => try w.writeAll("{}"),

        .told => |t| {
            try w.writeAll("{\"type\":");
            try writeString(w, t.type);
            if (t.format) |f| {
                try w.writeAll(",\"format\":");
                try writeString(w, f);
            }
            try w.writeByte('}');
        },

        // `{}` means "anything", which is true. The description is there
        // because a reader who sees `{}` on one field of an otherwise precise
        // document should be told it is a gap somebody can close rather than a
        // shape nobody could name (ADR 016).
        .untold => try w.writeAll(
            "{\"description\":\"This type reads or writes its own bytes, and has not said what they look like." ++
                " Add `pub const nilo_openapi = .{ .type = \\\"string\\\" };` to it to describe them.\"}",
        ),

        .choice => |names| {
            try w.writeAll("{\"type\":\"string\",\"enum\":[");
            for (names, 0..) |name, i| {
                if (i > 0) try w.writeByte(',');
                try writeString(w, name);
            }
            try w.writeAll("]}");
        },

        .array => |item| {
            try w.writeAll("{\"type\":\"array\",\"items\":");
            try writeSchema(w, components, item);
            try w.writeByte('}');
        },

        // Two encodings, two documents.
        //
        // Externally tagged: `{"link":{"url":"…"}}` — one key, whose name is
        // the arm. Written out as the alternatives rather than as `{}`, which
        // is what a union used to get while serialising perfectly well
        // (ADR 016). A void arm carries no value and is the bare key.
        //
        // Internally tagged: `{"signal":"metrics","threshold":0.9}` — the arm's
        // own fields, with the discriminator among them (ADR 016). The arm may
        // already be a named component, and nothing can be merged into a
        // `$ref`, so the two halves are put side by side with `allOf` — which is
        // the pattern OpenAPI has for exactly this. `discriminator` names the
        // key, and each arm pins its own value with a one-item `enum`, which is
        // what makes the choice unambiguous without a `mapping` that anonymous
        // structs could not be given anyway.
        .one_of => |o| {
            try w.writeAll("{\"oneOf\":[");
            for (o.cases, 0..) |case, i| {
                if (i > 0) try w.writeByte(',');
                if (o.tag) |key| {
                    // `allOf: [{}, X]` and `X` say the same thing, so a variant
                    // with nothing under it is written as the tag alone.
                    const bare = case.schema.* == .unknown;
                    if (!bare) {
                        try w.writeAll("{\"allOf\":[");
                        try writeSchema(w, components, case.schema);
                        try w.writeByte(',');
                    }
                    try w.writeAll("{\"type\":\"object\",\"properties\":{");
                    try writeString(w, key);
                    try w.writeAll(":{\"type\":\"string\",\"enum\":[");
                    try writeString(w, case.name);
                    try w.writeAll("]}},\"required\":[");
                    try writeString(w, key);
                    try w.writeAll("]}");
                    if (!bare) try w.writeAll("]}");
                    continue;
                }
                try w.writeAll("{\"type\":\"object\",\"properties\":{");
                try writeString(w, case.name);
                try w.writeByte(':');
                try writeSchema(w, components, case.schema);
                try w.writeAll("},\"required\":[");
                try writeString(w, case.name);
                try w.writeAll("]}");
            }
            try w.writeAll("]");
            if (o.tag) |key| {
                try w.writeAll(",\"discriminator\":{\"propertyName\":");
                try writeString(w, key);
                try w.writeByte('}');
            }
            try w.writeByte('}');
        },

        // OpenAPI 3.1 is JSON Schema, so a nullable value is written as the
        // two possibilities rather than with 3.0's `nullable` keyword.
        .nullable => |inner| {
            try w.writeAll("{\"anyOf\":[");
            try writeSchema(w, components, inner);
            try w.writeAll(",{\"type\":\"null\"}]}");
        },

        .object => |o| {
            if (o.name) |full| {
                if (components.slotFor(full, o.input)) |i| {
                    try w.writeAll("{\"$ref\":\"#/components/schemas/");
                    try components.writeName(w, i);
                    try w.writeAll("\"}");
                    return;
                }
            }
            try writeObject(w, components, o);
        },
    }
}

/// A struct written out in full. This is what goes into `components`, and
/// what an unnamed shape gets wherever it appears. Its fields go through
/// `writeSchema`, so a named shape inside it is still a reference.
fn writeObject(
    w: *std.Io.Writer,
    components: *const Components,
    object: Object,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"type\":\"object\",\"properties\":{");
    for (object.fields, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try writeString(w, f.name);
        try w.writeByte(':');
        try writeSchema(w, components, f.schema);
    }
    try w.writeByte('}');

    var required = false;
    for (object.fields) |f| {
        if (!f.required) continue;
        try w.writeAll(if (required) "," else ",\"required\":[");
        required = true;
        try writeString(w, f.name);
    }
    if (required) try w.writeByte(']');
    if (object.open) try w.writeAll(",\"additionalProperties\":true");
    try w.writeByte('}');
}

/// A name inside a `$ref`, which OpenAPI restricts to letters, digits and
/// `.`, `_`, `-`. Anything else a Zig type name carries becomes an
/// underscore rather than a document nothing can read.
fn writeComponentName(w: *std.Io.Writer, name: []const u8) !void {
    for (name) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-';
        try w.writeByte(if (ok) ch else '_');
    }
}

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    try writeEscaped(w, text);
    try w.writeByte('"');
}

fn writeEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
}

// ---- the page that reads it ----

/// A single-page reader for the document, for people who would rather click
/// than curl. Loaded from a CDN, which is the honest trade: bundling a
/// viewer would put a few hundred kilobytes of somebody else's JavaScript
/// into this repository, and generating one would be a second project.
///
/// A server with no outbound network — which is most production ones — still
/// serves the document itself perfectly well; it is only this page that
/// needs the CDN, and `ui_path = ""` turns it off.
///
/// **The script is pinned to one version and its hash.** The page is served
/// from the application's own origin, so what it loads runs with the
/// session cookie beside it: an unpinned URL let whatever the package
/// published next run there. With `integrity` the browser refuses any file
/// but this one, and a new version is a change here with its own hash, the
/// sha384 of the file (`openssl dgst -sha384 -binary | openssl base64 -A`),
/// which jsdelivr's `?structure=flat` listing confirms by its sha256.
pub const reader_script =
    \\<script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference@1.72.0/dist/browser/standalone.js" integrity="sha384-OPr81V05YKGVtMFR7bgn6teWINJ+Qb5LIgvuAi2xv2C/5Y1/PcjZ0DrvpMdP39ix" crossorigin="anonymous"></script>
;

pub fn writeReaderPage(w: *std.Io.Writer, title: []const u8, spec_path: []const u8) !void {
    try w.writeAll(
        \\<!doctype html>
        \\<html><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>
    );
    try writeEscaped(w, title);
    try w.writeAll(
        \\</title></head>
        \\<body style="margin:0">
        \\<script id="api-reference" data-url="
    );
    try writeEscaped(w, spec_path);
    try w.writeAll(
        \\"></script>
        \\
    );
    try w.writeAll(reader_script);
    try w.writeAll(
        \\
        \\</body></html>
        \\
    );
}

// ---- tests ----

const testing = std.testing;

fn schemaJson(comptime T: type) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    // Nothing collected, so nothing is a reference and every shape is
    // written out — which is what these tests are about.
    const none = Components.init(testing.allocator);
    // `comptime` here rather than inside `schemaOf`: the whole point of a
    // Schema is that it exists before the program runs, and a call from a
    // runtime context would be asking for one that does not.
    try writeSchema(&out.writer, &none, comptime schemaOf(T));
    return out.toOwnedSlice();
}

fn expectSchema(comptime T: type, expected: []const u8) !void {
    const json = try schemaJson(T);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(expected, json);
}

test "text with a shape says its shape, and a check of the caller's own is not claimed" {
    const text_mod = @import("text.zig");
    try expectSchema(text_mod.Text(.{ .min = 10, .max = 72 }), "{\"type\":\"string\",\"minLength\":10,\"maxLength\":72}");
    try expectSchema(text_mod.Text(.{ .max = 30 }), "{\"type\":\"string\",\"maxLength\":30}");
    try expectSchema(text_mod.Email, "{\"type\":\"string\",\"maxLength\":254,\"format\":\"email\"}");
    try expectSchema(text_mod.Url, "{\"type\":\"string\",\"maxLength\":2048,\"format\":\"uri\"}");
    try expectSchema(
        text_mod.Text(.{ .check = struct {
            fn f(_: []const u8) bool {
                return true;
            }
        }.f, .said = "has to be a SKU code" }),
        "{\"type\":\"string\"}",
    );
    try expectSchema(?text_mod.Email, "{\"anyOf\":[{\"type\":\"string\",\"maxLength\":254,\"format\":\"email\"},{\"type\":\"null\"}]}");
}

test "the plain types map to what JSON Schema calls them" {
    // An unsigned integer is refused below zero, and the document says so
    // (ADR 167). A signed one is any integer.
    try expectSchema(u32, "{\"type\":\"integer\",\"minimum\":0,\"maximum\":4294967295}");
    try expectSchema(i8, "{\"type\":\"integer\",\"minimum\":-128,\"maximum\":127}");
    try expectSchema(f64, "{\"type\":\"number\"}");
    try expectSchema(bool, "{\"type\":\"boolean\"}");
    try expectSchema(Str, "{\"type\":\"string\"}");
    // Text, not a list of numbers — the same reading std.json gives it.
    try expectSchema([]const u8, "{\"type\":\"string\"}");
}

test "an integer states the range its type holds, and leaves out a bound too wide to be an exact number" {
    try expectSchema(u8, "{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}");
    try expectSchema(i8, "{\"type\":\"integer\",\"minimum\":-128,\"maximum\":127}");
    // A number past 2^53 is read exactly (`parseInt` on the token), so the
    // bound is the type's own.
    try expectSchema(u64, "{\"type\":\"integer\",\"minimum\":0,\"maximum\":18446744073709551615}");
    try expectSchema(i64, "{\"type\":\"integer\",\"minimum\":-9223372036854775808,\"maximum\":9223372036854775807}");
    try expectSchema(i128, "{\"type\":\"integer\",\"minimum\":-170141183460469231731687303715884105728,\"maximum\":170141183460469231731687303715884105727}");
    // A `u128` reaches past what `Bounds` holds: no `maximum` rather than a wrong one.
    try expectSchema(u128, "{\"type\":\"integer\",\"minimum\":0}");
}

fn responseJson(comptime T: type) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const none = Components.init(testing.allocator);
    try writeSchema(&out.writer, &none, comptime responseSchemaOf(T));
    return out.toOwnedSlice();
}

test "a response lists every field it always writes as required, and a request keeps its rule" {
    const Row = struct {
        name: Str,
        nickname: ?Str,
        plan: u8 = 1,
    };
    const response = try responseJson(Row);
    defer testing.allocator.free(response);
    try testing.expectEqualStrings(
        \\{"type":"object","properties":{"name":{"type":"string"},"nickname":{"anyOf":[{"type":"string"},{"type":"null"}]},"plan":{"type":"integer","minimum":0,"maximum":255}},"required":["name","nickname","plan"]}
    , response);
    // The same type read from a body is as it was: only `name` has to be sent.
    try expectSchema(Row,
        \\{"type":"object","properties":{"name":{"type":"string"},"nickname":{"anyOf":[{"type":"string"},{"type":"null"}]},"plan":{"type":"integer","minimum":0,"maximum":255}},"required":["name"]}
    );
}

test "a response is required all the way down, through a list, an optional and a union arm" {
    const Inner = struct { n: u8 = 0, note: ?Str = null };
    const Row = struct { inner: ?Inner, items: []const Inner, pick: union(enum) { a: Inner } };
    const response = try responseJson(Row);
    defer testing.allocator.free(response);
    // Three objects with an optional or a default inside, and none leaves a field out.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, response, "\"required\":[\"n\",\"note\"]"));
    try testing.expect(std.mem.indexOf(u8, response, "\"required\":[\"inner\",\"items\",\"pick\"]") != null);
}

/// A PUT-shaped route: `Req` read from the body, `Res` written back.
fn roundTrip(comptime Req: type, comptime Res: type, comptime pattern: []const u8) Operation {
    return .{
        .method = .PUT,
        .pattern = pattern,
        .params = &.{},
        .query = &.{},
        .body = schemaOf(Req),
        .answer = .{ .status = 200, .content_type = "application/json", .schema = responseSchemaOf(Res) },
        .can_reject = false,
    };
}

fn documentOf(ops: []const Operation, out: *std.Io.Writer.Allocating) ![]const u8 {
    try write(testing.allocator, &out.writer, ops, .{});
    return out.written();
}

test "a type read from a body and written back is two components when its two halves differ" {
    const User = struct { name: Str, plan: u8 = 1 };
    const ops = comptime [_]Operation{roundTrip(User, User, "/users")};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const doc = try documentOf(&ops, &out);
    // The answer keeps the plain name, the body gets `Input` after it, and
    // each is referred to where it is used.
    try testing.expect(std.mem.indexOf(u8, doc, "\"requestBody\":{\"required\":true,\"content\":{\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/UserInput\"}}}}") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"schema\":{\"$ref\":\"#/components/schemas/User\"}") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"UserInput\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"plan\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}},\"required\":[\"name\"]}") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"User\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"plan\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":255}},\"required\":[\"name\",\"plan\"]}") != null);
    // Nothing is written inline.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, doc, "\"$ref\":"));
}

test "a type read and written whose halves agree stays one component" {
    const Point = struct { x: i32, y: i32 };
    const ops = comptime [_]Operation{roundTrip(Point, Point, "/points")};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const doc = try documentOf(&ops, &out);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, doc, "\"$ref\":\"#/components/schemas/Point\""));
    try testing.expect(std.mem.indexOf(u8, doc, "PointInput") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, doc, "\"Point\":{"));
}

test "a type only read keeps its plain name" {
    const NewUser = struct { name: Str, plan: u8 = 1 };
    const Done = struct { ok: bool };
    const ops = comptime [_]Operation{roundTrip(NewUser, Done, "/users")};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const doc = try documentOf(&ops, &out);
    try testing.expect(std.mem.indexOf(u8, doc, "\"$ref\":\"#/components/schemas/NewUser\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "NewUserInput") == null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"NewUser\":{") != null);
}

test "a type holding one whose halves differ is split as well, and refers to the half it is" {
    const Inner = struct { n: u8 = 0 };
    const Outer = struct { inner: Inner, tag: Str };
    const ops = comptime [_]Operation{roundTrip(Outer, Outer, "/outers")};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const doc = try documentOf(&ops, &out);
    // `Outer` has the same required fields both ways, but its `inner` points
    // at a different component each way, so it is two as well.
    try testing.expect(std.mem.indexOf(u8, doc, "\"OuterInput\":{\"type\":\"object\",\"properties\":{\"inner\":{\"$ref\":\"#/components/schemas/InnerInput\"}") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"Outer\":{\"type\":\"object\",\"properties\":{\"inner\":{\"$ref\":\"#/components/schemas/Inner\"}") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"InnerInput\":{") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"Inner\":{") != null);
}

test "a split name another type already answers to is not overwritten" {
    const a = struct {
        const User = struct { name: Str, plan: u8 = 1 };
    };
    const b = struct {
        const UserInput = struct { id: u32 };
    };
    const ops = comptime [_]Operation{
        roundTrip(a.User, a.User, "/users"),
        roundTrip(b.UserInput, b.UserInput, "/inputs"),
    };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const doc = try documentOf(&ops, &out);
    // The plain `UserInput` type and the request half of `User` both want
    // that name, so neither takes it: each keeps its full name, as two types
    // with one short name do.
    try testing.expect(std.mem.indexOf(u8, doc, "\"UserInput\":{") == null);
    try testing.expect(std.mem.indexOf(u8, doc, "UserInput\":{\"type\":\"object\",\"properties\":{\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc, ".User.Input\":{") != null);
    // Every name written is unique.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, doc, "\"type\":\"object\",\"properties\":{"));
}

test "the same routes give the same document twice, split components included" {
    const User = struct { name: Str, plan: u8 = 1 };
    const Other = struct { who: ?Str };
    const ops = comptime [_]Operation{ roundTrip(User, User, "/users"), roundTrip(Other, Other, "/others") };
    var one: std.Io.Writer.Allocating = .init(testing.allocator);
    defer one.deinit();
    var two: std.Io.Writer.Allocating = .init(testing.allocator);
    defer two.deinit();
    try testing.expectEqualStrings(try documentOf(&ops, &one), try documentOf(&ops, &two));
}

test "an enum becomes the strings it can be" {
    const Sort = enum { newest, oldest };
    try expectSchema(Sort, "{\"type\":\"string\",\"enum\":[\"newest\",\"oldest\"]}");
}

test "a struct lists its fields, and a default is what makes one optional" {
    const NewUser = struct {
        name: Str,
        age: u32,
        admin: bool = false,
    };
    try expectSchema(NewUser,
        \\{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer","minimum":0,"maximum":4294967295},"admin":{"type":"boolean"}},"required":["name","age"]}
    );
}

test "a struct where nothing is required says so by leaving the list out" {
    const AllOptional = struct { page: u32 = 1 };
    try expectSchema(AllOptional,
        \\{"type":"object","properties":{"page":{"type":"integer","minimum":0,"maximum":4294967295}}}
    );
}

test "a ?T with no default is optional in a struct as a default is, because absent reads as null" {
    const Contact = struct {
        name: Str,
        nickname: ?Str,
        age: ?u32,
        plan: u8 = 1,
    };
    try expectSchema(Contact,
        \\{"type":"object","properties":{"name":{"type":"string"},"nickname":{"anyOf":[{"type":"string"},{"type":"null"}]},"age":{"anyOf":[{"type":"integer","minimum":0,"maximum":4294967295},{"type":"null"}]},"plan":{"type":"integer","minimum":0,"maximum":255}},"required":["name"]}
    );
}

test "an optional is the value or null, the 3.1 way" {
    try expectSchema(?u32,
        \\{"anyOf":[{"type":"integer","minimum":0,"maximum":4294967295},{"type":"null"}]}
    );
}

test "a list carries the shape of what is in it" {
    const Item = struct { id: u32 };
    try expectSchema([]const Item,
        \\{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer","minimum":0,"maximum":4294967295}},"required":["id"]}}
    );
}

test "a type that refers to itself stops rather than expanding for ever" {
    const Node = struct {
        name: Str,
        children: []const @This(),
    };
    const json = try schemaJson(Node);
    defer testing.allocator.free(json);

    // Followed to the depth limit and then honest about stopping: `{}` is
    // JSON Schema for "anything", which is true.
    try testing.expect(std.mem.indexOf(u8, json, "{}") != null);
    try testing.expect(std.mem.startsWith(u8, json, "{\"type\":\"object\""));
}

test "a tagged union is the alternatives it can be, one key each" {
    const Target = union(enum) {
        link: struct { url: []const u8 },
        count: u32,
    };
    try expectSchema(Target,
        \\{"oneOf":[{"type":"object","properties":{"link":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}},"required":["link"]},{"type":"object","properties":{"count":{"type":"integer","minimum":0,"maximum":4294967295}},"required":["count"]}]}
    );
}

test "an untagged union still says nothing, because nothing in it says which arm is live" {
    const Bytes = union { a: u32, b: f32 };
    try expectSchema(Bytes, "{}");
}

test "a union that says its tag is described with the discriminator beside the fields" {
    const Condition = union(enum) {
        pub const nilo_json = .{ .tag = "signal" };

        metrics: struct { threshold: f64 },
        logs: struct { query: []const u8 },
    };
    // `allOf` rather than a merge, because the arm may already be a named
    // component and nothing can be merged into a `$ref` (ADR 016).
    try expectSchema(Condition,
        \\{"oneOf":[{"allOf":[{"type":"object","properties":{"threshold":{"type":"number"}},"required":["threshold"]},{"type":"object","properties":{"signal":{"type":"string","enum":["metrics"]}},"required":["signal"]}]},{"allOf":[{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]},{"type":"object","properties":{"signal":{"type":"string","enum":["logs"]}},"required":["signal"]}]}],"discriminator":{"propertyName":"signal"}}
    );
}

test "a variant carrying nothing is the discriminator on its own" {
    const Step = union(enum) {
        pub const nilo_json = .{ .tag = "step" };

        queued,
        running: struct { pid: u32 },
    };
    try expectSchema(Step,
        \\{"oneOf":[{"type":"object","properties":{"step":{"type":"string","enum":["queued"]}},"required":["step"]},{"allOf":[{"type":"object","properties":{"pid":{"type":"integer","minimum":0,"maximum":4294967295}},"required":["pid"]},{"type":"object","properties":{"step":{"type":"string","enum":["running"]}},"required":["step"]}]}],"discriminator":{"propertyName":"step"}}
    );
}

test "a renamed variant is described by the name that goes out, not the Zig one" {
    const Channel = union(enum) {
        pub const nilo_json = .{ .tag = "kind", .rename_all = .@"kebab-case" };

        web_hook: struct { url: []const u8 },
    };
    try expectSchema(Channel,
        \\{"oneOf":[{"allOf":[{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]},{"type":"object","properties":{"kind":{"type":"string","enum":["web-hook"]}},"required":["kind"]}]}],"discriminator":{"propertyName":"kind"}}
    );
}

test "a renamed struct is described by the keys it actually sends" {
    // The half that has to move with the writer or the document lies. ADR 016
    // is this failure once already: a `Uuid` went out as 36 characters and was
    // described as an object with a `bytes` field, and every generated client
    // that read one broke.
    const Contact = struct {
        pub const nilo_json = .{ .rename_all = .camelCase };

        id: u32,
        full_name: Str,
        email_address: ?Str = null,
    };
    try expectSchema(Contact,
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":0,"maximum":4294967295},"fullName":{"type":"string"},"emailAddress":{"anyOf":[{"type":"string"},{"type":"null"}]}},"required":["id","fullName"]}
    );
}

test "a renamed enum lists the choices it actually sends" {
    const Agg = enum {
        pub const nilo_json = .{ .rename_all = .SCREAMING_SNAKE_CASE };

        avg,
        rate_per_second,
    };
    // The document promising `avg` while the server sends `AVG` is the exact
    // failure ADR 016 was written about, arriving from a new direction.
    try expectSchema(Agg, "{\"type\":\"string\",\"enum\":[\"AVG\",\"RATE_PER_SECOND\"]}");
}

test "the same arms under two encodings are two shapes, not one component" {
    const External = union(enum) { a: struct { n: u32 } };
    const Internal = union(enum) {
        pub const nilo_json = .{ .tag = "kind" };
        a: struct { n: u32 },
    };
    // A client cannot read one of these from the other, so merging them under
    // one name would be the `Meta_Str`/`Meta_Text` fix applied where it is
    // wrong (ADR 016).
    try testing.expect(!comptime Components.rendersTheSame(schemaOf(External), schemaOf(Internal)));
}

test "one shape split only by a lifetime is one component" {
    // What the `Str`-in / `Text`-out rule produces: the same generic twice,
    // and two Zig types that render identically (ADR 016).
    const Meta = struct {
        fn of(comptime T: type) type {
            return struct { label: T, note: ?T };
        }
    };
    const Body = struct { meta: Meta.of(Str) };
    const Row = struct { meta: Meta.of([]const u8) };

    var components = Components.init(testing.allocator);
    defer components.deinit();
    try components.add(comptime schemaOf(Body));
    try components.add(comptime schemaOf(Row));

    // One slot, answering to both names, written without the half that was
    // only a lifetime. Three components rather than four: `Body`, `Row`, and
    // the one `Meta`.
    try testing.expectEqual(@as(usize, 3), components.count());
    const meta = components.indexOf(comptime nameOf(Meta.of(Str)).?, true).?;
    try testing.expectEqual(meta, components.indexOf(comptime nameOf(Meta.of([]const u8)).?, true).?);

    const written = components.nameAt(meta);
    try testing.expect(std.mem.endsWith(u8, written, "_of"));
    try testing.expect(std.mem.indexOf(u8, written, "_Str") == null);
    try testing.expect(std.mem.indexOf(u8, written, "_Text") == null);
}

test "a document past sixty-four named shapes still refers to every one of them by name" {
    // Seventy shapes with a name each, on seventy routes. Six contexts of a
    // real product reached the old ceiling of sixty-four, and the shapes past
    // it were written out in place — a true document whose generated client
    // had lost their names (ADR 170).
    const Shape = struct {
        fn of(comptime n: usize) type {
            return struct { id: u32, digits: [n]u8 };
        }
    };
    const many = 70;
    const ops = comptime blk: {
        // Seventy shapes named in one evaluation, where an app names one per
        // route registered; the budget is this test's, not a caller's.
        @setEvalBranchQuota(400_000);
        var built: [many]Operation = undefined;
        for (&built, 0..) |*op, i| {
            op.* = .{
                .method = .GET,
                .pattern = std.fmt.comptimePrint("/shapes/{d}", .{i}),
                .params = &.{},
                .query = &.{},
                .body = null,
                .answer = .{ .status = 200, .content_type = "application/json", .schema = schemaOf(Shape.of(i + 1)) },
                .can_reject = false,
            };
        }
        break :blk built;
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(testing.allocator, &out.writer, &ops, .{});
    const doc = out.written();

    // Every answer is a reference, and every reference has a shape under
    // `components` to point at.
    try testing.expectEqual(@as(usize, many), std.mem.count(u8, doc, "\"$ref\":"));
    try testing.expectEqual(@as(usize, many), std.mem.count(u8, doc, "\"digits\":"));
    // The seventieth is referred to, not written into its route.
    try testing.expect(std.mem.indexOf(u8, doc, "_of_70\"}") != null);
}

test "two shapes that only look alike keep their own names" {
    const Order = struct { id: u32 };
    const User = struct { id: u32 };
    const Page = struct {
        fn of(comptime T: type) type {
            return struct { items: []const T };
        }
    };

    var components = Components.init(testing.allocator);
    defer components.deinit();
    try components.add(comptime schemaOf(Page.of(Order)));
    try components.add(comptime schemaOf(Page.of(User)));

    // `Page_of_Order` and `Page_of_User` are neither a `_Str`/`_Text` pair nor
    // the same shape, so nothing is merged: two pages, two item types.
    try testing.expectEqual(@as(usize, 4), components.count());
}

test "a type that writes its own JSON is described by what it says, not by its fields" {
    // The shape of `nilo_id`'s `Uuid`, written out here so this test does not
    // need the module: sixteen bytes that go out as thirty-six characters.
    const Uuid = struct {
        bytes: [16]u8,
        pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
        pub fn jsonStringify(_: @This(), jw: anytype) !void {
            try jw.write("00000000-0000-0000-0000-000000000000");
        }
    };
    try expectSchema(Uuid, "{\"type\":\"string\",\"format\":\"uuid\"}");
}

test "a format is optional, and left out rather than guessed" {
    const Money = struct {
        text: []const u8,
        pub const nilo_openapi = .{ .type = "string" };
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.text);
        }
    };
    try expectSchema(Money, "{\"type\":\"string\"}");
}

test "a custom writer that says nothing is visibly silent rather than confidently wrong" {
    const Opaque = struct {
        secret: u32,
        pub fn jsonStringify(_: @This(), jw: anytype) !void {
            try jw.write("whatever it likes");
        }
    };
    const json = try schemaJson(Opaque);
    defer testing.allocator.free(json);

    // The one thing that must not happen: describing `secret`, which the
    // writer above never sends. That was the bug (ADR 016).
    try testing.expect(std.mem.indexOf(u8, json, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, json, "reads or writes its own bytes") != null);
    try testing.expect(std.mem.indexOf(u8, json, "nilo_openapi") != null);
}

test "a custom writer inside a struct does not describe the struct's fields either" {
    const Uuid = struct {
        bytes: [16]u8,
        pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
        pub fn jsonStringify(_: @This(), jw: anytype) !void {
            try jw.write("…");
        }
    };
    const Account = struct { public: Uuid, email: Str };
    try expectSchema(Account,
        \\{"type":"object","properties":{"public":{"type":"string","format":"uuid"},"email":{"type":"string"}},"required":["public","email"]}
    );
}

test "a document is described as its value, and a value that says nothing stays silent" {
    // The shape of `sql.Json(T)`, written out here so this test does not need
    // the module: exactly a `T` under `.value` (ADR 163).
    const Theme = struct { theme: []const u8 };
    const Settings = struct {
        value: Theme,
        pub const nilo_json_of = Theme;
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.value);
        }
    };
    try expectSchema(struct { settings: Settings },
        \\{"type":"object","properties":{"settings":{"type":"object","properties":{"theme":{"type":"string"}},"required":["theme"]}},"required":["settings"]}
    );

    // A document of `std.json.Value` is a document of a type that writes
    // itself and says nothing, which is `untold` exactly as it was.
    const Payload = struct {
        value: std.json.Value,
        pub const nilo_json_of = std.json.Value;
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(self.value);
        }
    };
    const json = try schemaJson(Payload);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "nilo_openapi") != null);
}

test "text that would break the JSON is escaped" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeString(&out.writer, "a \"quoted\" \\ thing\nand a tab\t");
    try testing.expectEqualStrings(
        "\"a \\\"quoted\\\" \\\\ thing\\nand a tab\\t\"",
        out.written(),
    );
}

fn templateOf(pattern: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try writePathTemplate(&out.writer, pattern);
    return out.toOwnedSlice();
}

test "a nilo pattern becomes an OpenAPI path template" {
    const cases = [_][2][]const u8{
        .{ "/users/:id", "\"/users/{id}\"" },
        .{ "/", "\"/\"" },
        .{ "/files/*", "\"/files/{path}\"" },
        .{ "/orgs/:org/repos/:repo", "\"/orgs/{org}/repos/{repo}\"" },
    };
    for (cases) |case| {
        const got = try templateOf(case[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "a struct that says .ignore is described as open, and one that says nothing is left silent" {
    const Loose = struct {
        pub const nilo_json = .{ .unknown_fields = .ignore };
        id: u32,
    };
    const Cased = struct {
        pub const nilo_json = .{ .rename_all = .camelCase, .unknown_fields = .ignore };
        full_name: Str,
    };
    const Tight = struct { id: u32 };
    try expectSchema(Loose,
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":0,"maximum":4294967295}},"required":["id"],"additionalProperties":true}
    );
    try expectSchema(Cased,
        \\{"type":"object","properties":{"fullName":{"type":"string"}},"required":["fullName"],"additionalProperties":true}
    );
    // ADR 016 does not promise `false`: the schema is the response's too, and
    // a client reads a response ignoring the keys it does not know.
    try expectSchema(Tight,
        \\{"type":"object","properties":{"id":{"type":"integer","minimum":0,"maximum":4294967295}},"required":["id"]}
    );
}

test "openness is the type's own: a strict struct holding an open one says nothing about itself" {
    const Loose = struct {
        pub const nilo_json = .{ .unknown_fields = .ignore };
        id: u32,
    };
    const Outer = struct { inner: Loose };
    try expectSchema(Outer,
        \\{"type":"object","properties":{"inner":{"type":"object","properties":{"id":{"type":"integer","minimum":0,"maximum":4294967295}},"required":["id"],"additionalProperties":true}},"required":["inner"]}
    );
}

test "a route that can answer 422 two ways lists it once, saying both" {
    const Body = struct { id: u32 };
    const ops = comptime [_]Operation{
        .{
            .method = .POST,
            .pattern = "/orders",
            .params = &.{},
            .query = &.{},
            .body = schemaOf(Body),
            .answer = .{ .status = 200, .content_type = "application/json", .schema = schemaOf(Body) },
            .can_reject = true,
            .idempotent = true,
            .misfit = true,
        },
        .{
            .method = .POST,
            .pattern = "/search",
            .params = &.{},
            .query = &.{},
            .body = schemaOf(Body),
            .answer = .{ .status = 200, .content_type = "application/json", .schema = schemaOf(Body) },
            .can_reject = true,
            .misfit = true,
        },
    };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(testing.allocator, &out.writer, &ops, .{});
    const doc = out.written();

    // A JSON object holding the key twice keeps one of them, so the two
    // reasons share a key on the route that has both (ADR 251).
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, doc, "\"422\":"));
    try testing.expect(std.mem.indexOf(u8, doc, "different request, or the body is JSON that does not fit") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"description\":\"the body is JSON that does not fit") != null);
    // Text that is not JSON is still a 400 on both.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, doc, "\"400\":"));
}
