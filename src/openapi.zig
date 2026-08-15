//! The API description, worked out from the handler signatures (ADR 0017).
//!
//! FastAPI's one big idea, which zfast was already most of the way to
//! without noticing: you write the function signature, and everything else
//! is derived from it (ADR 0015). The typed engine has read those
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
//! Two things about the shape of this file follow from ADR 0018. Everything
//! a route contributes is **comptime data**, not a generated function: one
//! `Operation` value per route, its slices pointing at read-only memory, and
//! a single writer walking them. A per-route writer would have put a copy of
//! the JSON-emitting code in the binary for each one. And nothing here is on
//! the request path — the document is built once when `listen()` resolves
//! the routes, and served from memory afterwards like any other file
//! (ADR 0010).

const std = @import("std");
const http1 = @import("http1.zig");
const str_mod = @import("str.zig");
const patch_mod = @import("patch.zig");

const Str = str_mod.Str;

/// What zfast can say about the shape of a value. Deliberately smaller than
/// JSON Schema: it holds what a Zig type actually tells you, and `unknown`
/// is the honest answer for the rest rather than a guess dressed up as a
/// description.
pub const Schema = union(enum) {
    string,
    integer,
    number,
    boolean,
    /// A string from a fixed set — what an enum becomes.
    choice: []const []const u8,
    array: *const Schema,
    /// `?T`, which in a JSON body means the value may also be null.
    nullable: *const Schema,
    object: Object,
    /// A file out of a multipart form — `{"type":"string","format":"binary"}`,
    /// which is how OpenAPI 3.1 says "bytes" (ADR 0031).
    binary,
    /// A type with no useful JSON shape, or one nested deeper than this
    /// module follows. Emitted as `{}`, which in JSON Schema means "anything"
    /// — true, and better than a wrong claim.
    unknown,
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
};

pub const Field = struct {
    name: []const u8,
    schema: *const Schema,
    /// A field with a default is what "absent" is allowed to mean, so it is
    /// not required — the same rule `Query(T)` and the body parser follow.
    required: bool,
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
    /// there — which is exactly the handlers returning `?T` (ADR 0024). The
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
    /// `Redirect(303)` (ADR 0032). The status is already in `status`; what
    /// this adds is that the header is part of the promise, which is the
    /// half a client generator has to see to follow it.
    redirect: bool = false,
};

/// How a request body is expected to arrive on the wire. The shape is
/// described the same way whichever it is; this is the content type it is
/// filed under, and a form with a file in it can only be the last one
/// (ADR 0031).
pub const BodyKind = enum {
    json,
    urlencoded,
    multipart,

    pub fn contentType(self: BodyKind) []const u8 {
        return switch (self) {
            .json => "application/json",
            .urlencoded => "application/x-www-form-urlencoded",
            .multipart => "multipart/form-data",
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
    body: ?*const Schema,
    body_kind: BodyKind = .json,
    answer: Answer,
    /// Whether zfast itself can refuse this request with a 400 before the
    /// handler runs — true as soon as there is anything to convert or
    /// validate. Not a guess: it is exactly the set of routes with a typed
    /// param, a query struct, or a body.
    can_reject: bool,
};

pub const Info = struct {
    title: []const u8 = "API",
    version: []const u8 = "1.0.0",
    description: []const u8 = "",
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
        return schemaWithin(T, 0);
    }
}

fn schemaWithin(comptime T: type, comptime depth: usize) *const Schema {
    comptime {
        if (depth >= max_depth) return held(.unknown);
        if (T == Str) return held(.string);
        // A file is bytes, not the three-field struct it is carried in.
        if (T == @import("form.zig").Upload) return held(.binary);
        // On the wire a `Patch(T)` is the value or null — the third state it
        // carries is "the field was not here at all", and JSON Schema says
        // that with `required`, which a default already takes care of.
        if (patch_mod.isPatch(T)) {
            return held(.{ .nullable = schemaWithin(T.zfast_patch, depth + 1) });
        }

        return switch (@typeInfo(T)) {
            .bool => held(.boolean),
            .int, .comptime_int => held(.integer),
            .float, .comptime_float => held(.number),

            .@"enum" => |e| blk: {
                var names: []const []const u8 = &.{};
                for (e.fields) |f| names = names ++ [_][]const u8{f.name};
                break :blk held(.{ .choice = names });
            },

            .optional => |o| held(.{ .nullable = schemaWithin(o.child, depth + 1) }),

            .@"struct" => |s| blk: {
                // A tuple is a list of mixed things, which JSON Schema can
                // describe and this deliberately does not try to.
                if (s.is_tuple) break :blk held(.unknown);

                var fields: []const Field = &.{};
                for (s.fields) |f| {
                    fields = fields ++ [_]Field{.{
                        .name = f.name,
                        .schema = schemaWithin(f.type, depth + 1),
                        .required = f.default_value_ptr == null,
                    }};
                }
                break :blk held(.{ .object = .{ .name = nameOf(T), .fields = fields } });
            },

            .pointer => |p| switch (p.size) {
                // `[]const u8` is text, not a list of numbers — the same
                // reading `std.json` gives it.
                .slice => if (p.child == u8)
                    held(.string)
                else
                    held(.{ .array = schemaWithin(p.child, depth + 1) }),
                // A single-item pointer is followed: `*const Config` in a
                // response is the config, as far as JSON is concerned.
                .one => schemaWithin(p.child, depth + 1),
                else => held(.unknown),
            },

            .array => |a| if (a.child == u8)
                held(.string)
            else
                held(.{ .array = schemaWithin(a.child, depth + 1) }),

            else => held(.unknown),
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

/// How many named shapes one document can hold. Past this a shape is written
/// out in place, exactly as it used to be everywhere — the document is
/// bigger and still correct.
const max_components = 64;

/// The named shapes a document refers to rather than repeating. Collected in
/// one pass over the routes before anything is written, because the
/// `components` section and the `$ref`s pointing into it have to agree and
/// only one of them can be written first.
const Components = struct {
    names: [max_components][]const u8 = undefined,
    schemas: [max_components]*const Schema = undefined,
    /// Whether two shapes turned out to answer to this name. A declared type
    /// cannot collide with another — its full name has its module in it — but
    /// a *rendered* one can: `a.Page(b.Order)` and `c.Page(d.Order)` are both
    /// `Page_Order`. When that happens neither gets the name, and both are
    /// written out where they appear. Bigger document, still a true one.
    contested: [max_components]bool = @splat(false),
    count: usize = 0,

    fn gather(self: *Components, ops: []const Operation) void {
        for (ops) |op| {
            for (op.params) |p| self.add(p.schema);
            for (op.query) |f| self.add(f.schema);
            if (op.body) |b| self.add(b);
            if (op.answer.schema) |s| self.add(s);
        }
    }

    fn add(self: *Components, schema: *const Schema) void {
        switch (schema.*) {
            .object => |o| {
                if (o.name) |full| {
                    if (self.indexOf(full)) |i| {
                        // The same shape under the same name — and its fields
                        // were walked when it was first seen. This is also
                        // what stops a type holding one of its own from
                        // recursing for ever.
                        if (sameShape(self.schemas[i], schema)) return;
                        // A second shape wanting the same name. Once is
                        // enough to settle it; returning on the second visit
                        // is what keeps a self-referential one from looping.
                        if (self.contested[i]) return;
                        self.contested[i] = true;
                    } else if (self.count < max_components) {
                        self.names[self.count] = full;
                        self.schemas[self.count] = schema;
                        self.count += 1;
                    }
                }
                for (o.fields) |f| self.add(f.schema);
            },
            .array => |item| self.add(item),
            .nullable => |inner| self.add(inner),
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
            if (!std.mem.eql(u8, f.name, g.name)) return false;
        }
        return true;
    }

    /// The slot this shape is named in, or null if it has no name of its own
    /// in this document — either it never had one, or something else wanted
    /// the same one.
    fn slotFor(self: *const Components, full: []const u8) ?usize {
        const i = self.indexOf(full) orelse return null;
        return if (self.contested[i]) null else i;
    }

    fn indexOf(self: *const Components, full: []const u8) ?usize {
        for (self.names[0..self.count], 0..) |name, i| {
            if (std.mem.eql(u8, name, full)) return i;
        }
        return null;
    }

    /// What this shape is called in the document: its short name, unless
    /// something else in the same document would answer to it too. Two
    /// modules can both have a `User`, and a client generator handed one
    /// `User` meaning two shapes produces code that does not compile — so
    /// where that happens both keep their full names.
    fn writeName(self: *const Components, w: *std.Io.Writer, i: usize) !void {
        const full = self.names[i];
        const short = shortNameOf(full);
        return writeComponentName(w, if (self.shortIsFree(i, short)) short else full);
    }

    fn shortIsFree(self: *const Components, i: usize, short: []const u8) bool {
        if (std.mem.eql(u8, short, error_schema_name)) return false;
        for (self.names[0..self.count], 0..) |other, j| {
            // A contested slot is written nowhere, so it is not competing
            // for the short name it would otherwise have taken.
            if (self.contested[j]) continue;
            if (j != i and std.mem.eql(u8, shortNameOf(other), short)) return false;
        }
        return true;
    }

    /// Whether anything in this document promises a failure, and so whether
    /// the shape those failures take has to be described.
    fn anyFailure(ops: []const Operation) bool {
        for (ops) |op| {
            if (op.can_reject or op.answer.not_found) return true;
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
pub fn write(w: *std.Io.Writer, ops: []const Operation, info: Info) !void {
    var components: Components = .{};
    components.gather(ops);

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
        try w.writeAll("\"" ++ error_schema_name ++ "\":" ++ error_schema);
        wrote_schema = true;
    }
    for (components.schemas[0..components.count], 0..) |schema, i| {
        // A name two shapes wanted belongs to neither, and both were written
        // out where they appear rather than referred to here.
        if (components.contested[i]) continue;
        if (wrote_schema) try w.writeByte(',');
        wrote_schema = true;
        try w.writeByte('"');
        try components.writeName(w, i);
        try w.writeAll("\":");
        try writeObject(w, &components, schema.object);
    }
    try w.writeAll("}}}");
}

/// The shape of every failure zfast assembles (ADR 0025). Written out here
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

    if (op.params.len > 0 or op.query.len > 0) {
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
            try w.print(",\"in\":\"query\",\"required\":{s},\"schema\":", .{
                if (f.required) "true" else "false",
            });
            try writeSchema(w, components, f.schema);
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }

    if (op.body) |body| {
        try w.writeAll(",\"requestBody\":{\"required\":true,\"content\":{");
        try writeString(w, op.body_kind.contentType());
        try w.writeAll(":{\"schema\":");
        try writeSchema(w, components, body);
        try w.writeAll("}}}");
    }

    try w.writeAll(",\"responses\":{");
    try writeAnswer(w, components, op.answer);
    if (op.can_reject) {
        try writeFailure(w, "400", "the request did not fit what this endpoint takes; " ++
            "the body says which part");
    }
    if (op.answer.not_found) {
        try writeFailure(w, "404", "there is no such thing");
    }
    try w.writeAll("}}");
}

/// A failure this endpoint's signature promises, carrying the shape every
/// failure zfast assembles has (ADR 0025).
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
        try w.writeAll("\"default\":{\"description\":\"this endpoint writes its own response, " ++
            "so its signature does not describe it\"}");
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
    try w.writeAll("}}}");
}

/// `getUsersId` — a name for the endpoint that a client generator can turn
/// into a method. Built from the verb and the path so that it is stable
/// across runs and unique wherever the routes are.
fn writeOperationId(w: *std.Io.Writer, op: Operation) !void {
    try w.writeByte('"');
    for (@tagName(op.method)) |ch| try w.writeByte(std.ascii.toLower(ch));

    var segments = std.mem.splitScalar(u8, op.pattern, '/');
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
    try w.writeByte('"');
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
        .number => try w.writeAll("{\"type\":\"number\"}"),
        .boolean => try w.writeAll("{\"type\":\"boolean\"}"),
        .binary => try w.writeAll("{\"type\":\"string\",\"format\":\"binary\"}"),
        .unknown => try w.writeAll("{}"),

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

        // OpenAPI 3.1 is JSON Schema, so a nullable value is written as the
        // two possibilities rather than with 3.0's `nullable` keyword.
        .nullable => |inner| {
            try w.writeAll("{\"anyOf\":[");
            try writeSchema(w, components, inner);
            try w.writeAll(",{\"type\":\"null\"}]}");
        },

        .object => |o| {
            if (o.name) |full| {
                if (components.slotFor(full)) |i| {
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
        \\<script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
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
    const none: Components = .{};
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

test "the plain types map to what JSON Schema calls them" {
    try expectSchema(u32, "{\"type\":\"integer\"}");
    try expectSchema(i8, "{\"type\":\"integer\"}");
    try expectSchema(f64, "{\"type\":\"number\"}");
    try expectSchema(bool, "{\"type\":\"boolean\"}");
    try expectSchema(Str, "{\"type\":\"string\"}");
    // Text, not a list of numbers — the same reading std.json gives it.
    try expectSchema([]const u8, "{\"type\":\"string\"}");
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
        \\{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"},"admin":{"type":"boolean"}},"required":["name","age"]}
    );
}

test "a struct where nothing is required says so by leaving the list out" {
    const AllOptional = struct { page: u32 = 1 };
    try expectSchema(AllOptional,
        \\{"type":"object","properties":{"page":{"type":"integer"}}}
    );
}

test "an optional is the value or null, the 3.1 way" {
    try expectSchema(?u32,
        \\{"anyOf":[{"type":"integer"},{"type":"null"}]}
    );
}

test "a list carries the shape of what is in it" {
    const Item = struct { id: u32 };
    try expectSchema([]const Item,
        \\{"type":"array","items":{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"]}}
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

test "a zfast pattern becomes an OpenAPI path template" {
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
