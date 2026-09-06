// The request in flight, for a snippet in the SQL guide that is a run of
// statements rather than a declaration — the `c`, `db` and `tx` such a
// snippet says without introducing (ADR 0083).
//
// Not a file that compiles on its own: it is pasted after
// `sql_types.zig` and the declarations the page has made so far, and before
// the snippet, which is where these names have to be. `user` below is a
// `User`, and `User` is the guide's own first block rather than anything in
// this directory.
//
// `undefined` throughout, because a snippet is compiled and never run. What
// is being checked is that the lines type-check.

pub var c: *nilo.Ctx = undefined;
// The Db itself rather than a pointer to one: `try app.provide(&db);` is a
// line the page shows, and `&` of a `*sql.Db` is one indirection too many.
// A method call auto-references, so every other snippet reads the same.
pub var db: sql.Db = undefined;
pub var gpa: std.mem.Allocator = undefined;
pub var app: nilo.App = undefined;

// The two Scopes a statement can be given. `run` is the one a startup path
// or a test uses, where there is no request to hang the arena off.
pub var run: nilo.Run = undefined;
pub var tx: sql.Db.Tx = undefined;

// A row already read, for the snippets that go on to change it.
pub var user: User = undefined;

// The values a condition binds. Named for what they are rather than for
// where they came from: the page is about the statement, not the parsing.
pub var id: i64 = undefined;
pub var user_id: i64 = undefined;
pub var email: []const u8 = undefined;
pub var name: []const u8 = undefined;
pub var month: i32 = undefined;
pub var tags: []const []const u8 = undefined;
pub var schema_sql: []const u8 = undefined;
pub var url: []const u8 = undefined;
