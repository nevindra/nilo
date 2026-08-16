//! The root of `zig build test`, and nothing else.
//!
//! This file used to set `std_options` to swallow the log lines a few tests
//! provoke on purpose. That never ran once, in any Zig version this project
//! has been built with: in a test build the root module is the compiler's own
//! `lib/compiler/test_runner.zig`, which declares `std_options` itself, so a
//! tested file's copy of it is never consulted. The silence it appeared to be
//! buying was the build runner caching the run step and not executing the
//! binary at all — which is why the noise looked intermittent, and why six
//! green runs in a row proved nothing.
//!
//! What the runner does honour is `std.testing.log_level`, a plain `pub var`
//! it compares against on every line. So a test that means to provoke a log
//! line turns it down around itself and says why — `stream.zig` has the one
//! test that needs it.
//!
//! Worth knowing if this comes back: the build still *succeeds*. A test
//! process that writes to stderr gets a red `failed command` block that is
//! shaped exactly like a failure report, printed above a summary that says
//! every step passed.

test {
    _ = @import("http.zig");
}
