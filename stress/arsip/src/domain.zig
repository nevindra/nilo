//! What arsip talks about.
//!
//! Two rules decide the shapes here, and both come from nilo rather than from
//! the domain. **Text arriving from a request is a `Str` and text a service
//! owns is a `[]const u8`**, so every shape that is both a body and a row
//! exists twice — written once as a generic over the text type, which is what
//! `Meta` and `Section` are ([ADR 0004], guide/openapi.md#named-shapes). And
//! **the signature is the whole contract**, so anything the API refuses is
//! spelled as a type here rather than as a check in a handler.
//!
//! The awkward bits are deliberate. `@"type"` is a Zig keyword and a very
//! ordinary JSON field name; `sections` is a list whose elements hold lists;
//! `meta` is an optional nested struct; `EditDoc` needs three answers where an
//! optional has two. Each one is here because it is where a "your types are the
//! contract" claim would break if it were going to.

const std = @import("std");
const nilo = @import("nilo_http");

pub const Str = nilo.Str;

/// The text type a row owns, as opposed to the `Str` a request lends it. Named
/// so the generated API description calls the two shapes `Meta_Str` and
/// `Meta_Text` rather than giving up and writing both out in place.
pub const Text = []const u8;

pub const Kind = enum { note, invoice, photo, contract };

pub const Visibility = enum { private, team, public };

/// A document moves forward and never back. `advance` is the only thing that
/// knows that, and it is the reason there is a 409 in this API at all.
pub const Stage = enum {
    draft,
    review,
    filed,
    archived,

    pub fn next(self: Stage) ?Stage {
        return switch (self) {
            .draft => .review,
            .review => .filed,
            .filed => .archived,
            .archived => null,
        };
    }
};

/// `@"type"` is the point: a JSON field named `type` is completely ordinary and
/// a Zig field named `type` needs an escape. Whether that survives the round
/// trip — body, response, error message, API description — is a thing worth
/// knowing before an app is built on it.
pub fn Meta(comptime T: type) type {
    return struct {
        author: T,
        @"type": Kind = .note,
        pages: ?u32 = null,
    };
}

/// A list inside a list element, which is the shape a real document has and the
/// shape a flat example never reaches.
pub fn Section(comptime T: type) type {
    return struct {
        heading: T,
        lines: []const T = &.{},
    };
}

/// What a client sends to file a document, and what the store is handed once
/// the text has stopped being borrowed from the request. Generic for the same
/// reason `Meta` is: it is one shape that exists on both sides of the `Str`
/// boundary, and writing it twice is how a field gets added to one copy only.
///
/// Every field with a default is a field the client may leave out, and that is
/// the same sentence in the generated description.
pub fn Filing(comptime T: type) type {
    return struct {
        title: T,
        kind: Kind = .note,
        visibility: Visibility = .private,
        meta: ?Meta(T) = null,
        sections: []const Section(T) = &.{},
        tags: []const T = &.{},
    };
}

pub const NewDoc = Filing(Str);

/// A PATCH needs three answers where an optional has two: not sent, sent as
/// null, sent with a value. `Patch(T)` is the field type that keeps all three,
/// and `= .absent` is not decoration — it is what "the field was not in the
/// body" means (ADR 0026).
pub const EditDoc = struct {
    title: nilo.Patch(Str) = .absent,
    visibility: nilo.Patch(Visibility) = .absent,
    /// Clearing this one means something: forget who wrote it.
    meta: nilo.Patch(Meta(Str)) = .absent,
};

/// Moving a document along. A struct rather than a query param because it is a
/// decision, and a decision belongs in a body.
pub const Advance = struct {
    to: Stage,
};

/// A file somebody attached, as far as anybody reading JSON is concerned. The
/// bytes are deliberately not in here: they live beside the row and go out
/// through an endpoint of their own, because a document listing that carried
/// two megabytes of PDF per item would be a different kind of mistake.
pub const Attached = struct {
    filename: Text,
    content_type: Text,
    bytes: usize,
};

/// What goes out. The same shape as `NewDoc` with the text type swapped and the
/// server's own fields added — which is exactly why `Meta` and `Section` are
/// generic rather than written twice.
pub const Doc = struct {
    id: u32,
    folder: Text,
    title: Text,
    kind: Kind,
    stage: Stage,
    visibility: Visibility,
    meta: ?Meta(Text),
    sections: []const Section(Text),
    tags: []const Text,
    attachment: ?Attached = null,
};

/// A shape whose only property is depth, for finding out where nilo stops
/// naming the field that broke. `guide/requests.md` says eight levels and then
/// a plain 400; this is the type that asks.
pub fn Deep(comptime levels: u8) type {
    if (levels == 0) return struct { leaf: u32 };
    return struct { down: Deep(levels - 1) };
}

pub const NewFolder = struct {
    name: Str,
    visibility: Visibility = .private,
};

pub const Folder = struct {
    slug: Text,
    name: Text,
    visibility: Visibility,
    docs: usize,
};

pub const Sort = enum { newest, oldest, title };

/// The query string, as a struct. A field with no default is a 400 saying which
/// one is missing; a field with one is what "absent" is allowed to mean. It is
/// generic for the same reason everything else here is — the store gets the
/// `[]const u8` half.
pub fn Filter(comptime T: type) type {
    return struct {
        q: ?T = null,
        stage: ?Stage = null,
        kind: ?Kind = null,
        sort: Sort = .newest,
        page: u32 = 1,
        per_page: u32 = 20,
    };
}

pub const Search = Filter(Str);

/// What an edit does to one field, on the store's side of the boundary. The
/// handler maps `Patch(T)` onto this, and the mapping is where a `.cleared` on
/// a field that cannot be cleared becomes a 400 rather than a silent nothing.
pub fn Change(comptime T: type) type {
    return union(enum) {
        keep,
        clear,
        set: T,
    };
}

pub const Edit = struct {
    title: ?Text = null,
    visibility: ?Visibility = null,
    meta: Change(Meta(Text)) = .keep,
};

/// What the curators' endpoint answers. Flat on purpose: a shape a dashboard
/// can read without knowing anything about this API.
pub const Summary = struct {
    folders: usize,
    docs: usize,
    draft: usize,
    review: usize,
    filed: usize,
    archived: usize,
};

/// What `advance` answers. A document that will not move is not an error — it
/// is a 409 with the stage it is actually in, which the client needs.
pub const Advanced = union(enum) {
    moved: Doc,
    refused: Stage,
};

/// A generic is how Zig says "the same shape twice", and a page of documents is
/// the same shape as a page of anything else. The description calls this one
/// `Page_Doc`.
pub fn Page(comptime T: type) type {
    return struct {
        items: []const T,
        page: u32,
        per_page: u32,
        total: usize,
    };
}

test "a document moves forward and stops" {
    try std.testing.expectEqual(Stage.review, Stage.draft.next().?);
    try std.testing.expectEqual(@as(?Stage, null), Stage.archived.next());
}
