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

// The App a snippet about assembling one says without building one — the
// `app.metrics(.{})` of the metrics page, and anything else registered on the
// way to `listen()`.
pub var app: nilo.App = undefined;

// The cache a snippet about reading one says without opening one.
pub var store: cache.Store = undefined;
pub var carts: Carts = undefined;

// The outbound client and the Scope a snippet that calls somebody else says
// without building either — what the JWKS fetch on the `nilo_jwt` page needs.
pub var client: fetch.Client = undefined;
pub var run: nilo.Run = undefined;

// The queue a snippet about pushing says without opening one, and the
// table it sits on.
pub var table: job.Table(Db) = undefined;
pub var jobs: Jobs = undefined;
