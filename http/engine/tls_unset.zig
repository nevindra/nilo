//! What the `tls` import is until a dependent replaces it (ADR 274).
//!
//! A dependent that passes `.tls_own = true` to `b.dependency("nilo", …)`
//! supplies the TLS library itself, and nilo's pin is neither fetched nor
//! built. The import still has to name something, because Zig's own answer to
//! a missing one, "no module named 'tls' available within module", says
//! nothing about what to write. This file is that something: nothing in it
//! compiles, and the one error it raises is the line the dependent forgot.
//!
//! It is reached only from `http/engine/zio.zig`, under `nilo_build.tls`, so
//! a program that never listens with TLS support analysed never sees it.
//! `addImport` on the same name replaces it, so the dependent's module takes
//! its place with nothing else to undo.

comptime {
    @compileError("nilo: `.tls_own = true` leaves the `tls` import to you, and this build never wrote it. " ++
        "In your build.zig, after `const nilo = b.dependency(\"nilo\", .{ .tls = true, .tls_own = true, … });`, write " ++
        "`nilo.module(\"nilo_http\").addImport(\"tls\", your_tls_module);` where `your_tls_module` is " ++
        "`b.dependency(\"tls\", .{ … }).module(\"tls\")` or any module with the API `docs/reference/app.md` lists (ADR 274).");
}
