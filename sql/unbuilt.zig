//! What `nilo_sql` is when the project building it did not ask for it.
//!
//! `sql/sql.zig` needs two drivers — pg.zig and zqlite — and reaching for them
//! is what downloads them. `b.lazyDependency` does not mean "fetch this if
//! somebody imports it"; it means *request* this, so a call at the top of
//! `build()` runs for every dependent whatever they import. For a year that
//! made `.lazy = true` in the manifest worth nothing: an application that
//! served HTTP and named no database still fetched 11.1 MB of driver, of which
//! it linked zero bytes (ADR 0075).
//!
//! So the calls sit behind `-Dsql`, and a dependent that wants the module says
//! so once. This file is what the module's root is until they do — a
//! `@compileError` rather than a missing module, because `dep.module(…)` on a
//! name that is not in the graph is a panic from inside `std.Build` about a
//! name it could not find, and a Refusal in this repository is supposed to be
//! a sentence nilo wrote (ADR 0027).
//!
//! Nothing else is in here. A file that declared a stub `Db` would compile,
//! and the mistake would land at the first query instead of at the import.

comptime {
    @compileError("nilo: nilo_sql was not built, because this project did not ask for it. " ++
        "Add `.sql = true` to the `b.dependency(\"nilo\", .{ … })` call in your build.zig. " ++
        "That flag is what downloads pg.zig and zqlite, 11 MB of driver a project " ++
        "without a database should not fetch, so it is off until you say otherwise (ADR 0075).");
}
