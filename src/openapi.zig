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
};

/// Everything the signature of one route says about it.
pub const Operation = struct {
    method: http1.Method,
    pattern: []const u8,
    /// In the order they appear in the pattern. A catch-all is named `*`.
    params: []const Param,
    query: []const Field,
    body: ?*const Schema,
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
/// `NewUser`, `Address`. What does not is an anonymous struct — the compiler
/// names those after where they were written, `main.main__struct_2914` — and
/// anything whose last name segment is not a plain identifier, which is how
/// an instantiated generic (`Query(main.Listing)`) reads.
fn nameOf(comptime T: type) ?[]const u8 {
    comptime {
        const full = @typeName(T);
        if (std.mem.indexOf(u8, full, "__") != null) return null;

        var start = full.len;
        while (start > 0 and full[start - 1] != '.') start -= 1;
        const short = full[start..];
        if (short.len == 0) return null;
        if (!std.ascii.isAlphabetic(short[0]) and short[0] != '_') return null;
        for (short[1..]) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return null;
        }
        return full;
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
                    // Already known — and so are its fields, which were
                    // walked when it was first seen. This is also what stops
                    // a type holding one of its own from recursing for ever.
                    if (self.indexOf(full) != null) return;
                    if (self.count < max_components) {
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
        try w.writeAll(",\"requestBody\":{\"required\":true,\"content\":" ++
            "{\"application/json\":{\"schema\":");
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
    try w.writeByte('"');
    if (answer.status) |status| try w.print("{d}", .{status}) else try w.writeAll("default");
    try w.writeAll("\":{\"description\":");

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
                if (components.indexOf(full)) |i| {
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
