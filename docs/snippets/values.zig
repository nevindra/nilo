// The request in flight, for a snippet that is a run of statements rather
// than a declaration — the `c`, `db` and `form` such a snippet says without
// introducing (ADR 0083).
//
// Not a file that compiles on its own: it is pasted after `types.zig` and
// before the snippet, which is where these names have to be.
//
// `undefined` throughout, because a snippet is compiled and never run. What
// is being checked is that the lines type-check.

pub var c: *nilo.Ctx = undefined;
pub var db: *sql.Db = undefined;
pub var form: SignIn = undefined;
pub var gpa: std.mem.Allocator = undefined;
