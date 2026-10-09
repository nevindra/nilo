//! nilo_core — what every layer of nilo agrees about (ADR 038).
//!
//! Five things live here. Text that belongs to a piece of work, the Scope
//! that hands out the memory it lives in, what time it is (and the `Timestamp`
//! and `Date` that hold it), and percent encoding. Each is used by two layers, which is the rule for a fifth: **a
//! file earns its place by being needed by two layers, not by having nowhere
//! else to live.** The moment this is where things go because they fit
//! nowhere, the layering has stopped meaning anything and only the directory
//! is left.
//!
//! `percent` is the first file that arrived by passing that test rather than
//! by being here from the start (ADR 057): the App layer decodes every path
//! param, a Service signing a URL encodes one, and a Service cannot import
//! `nilo_http` to share the App layer's copy.
//! `trace` is the second (ADR 247): the server reads `traceparent` on the
//! way in and `nilo_fetch`, a Fitting that cannot name the server, writes it
//! on the way out.
//! `time` is the fourth (ADR 057): the App layer reads a `Timestamp` or a
//! `Date` in a body, a query and a path, and `nilo_sql` stores them, so a
//! service with a date in its body no longer turns on `-Dsql`.
//! `tmp` is the third (ADR 250): a test under `http/` and a test under
//! `sql/` both need the path of a directory of their own, and the second
//! cannot reach `nilo.testing`. It is the one file here only a test calls.
//!
//! **Nothing here needs the event loop**, names an Engine, or knows that
//! HTTP exists. That is what lets `zig test core/core.zig` run the whole of
//! it in a second without the module graph, and what lets a program with no
//! server in it link this and nothing else.
//!
//! That sentence used to read *nothing here does IO*, and the clock is why
//! it does not (ADR 041): reading it is a syscall by the letter and a read
//! from a mapped page in practice, so there is nothing for a fiber to wait
//! on. **Needing the loop is the question the layering has always actually
//! been asking**, and it is the one to keep asking of a fourth.

const str_mod = @import("str.zig");
const scope_mod = @import("scope.zig");
const clock_mod = @import("clock.zig");

pub const Str = str_mod.Str;
pub const Lifetime = str_mod.Lifetime;
pub const stamp = str_mod.stamp;
pub const stampWith = str_mod.stampWith;
pub const stampLike = str_mod.stampLike;
pub const trap_enabled = str_mod.trap_enabled;

pub const Run = scope_mod.Run;
pub const checkScope = scope_mod.check;
/// A Scope's request id as an optional, whichever way the Scope declares it —
/// and null for one that declares none (ADR 158).
pub const requestIdOf = scope_mod.requestIdOf;

/// The route a Scope's request matched, or null for a Scope that is not a
/// request or a request nothing matched (ADR 108).
pub const routeNameOf = scope_mod.routeNameOf;

/// Which request or tick a Scope is on, for a module that keeps something
/// between calls and has to know it is still the same one (ADR 117).
pub const serialOf = scope_mod.serialOf;

/// The time a Scope has left and the shorter of that and a call's own bound,
/// for a call that leaves the process
/// ([ADR 105](../docs/adr/105-a-route-can-say-how-long-it-has.md)).
pub const timeLeftOf = scope_mod.timeLeftOf;
pub const within = scope_mod.within;

/// W3C Trace Context, and the two Scope calls a call that leaves makes so it
/// joins the request's trace
/// ([ADR 247](../docs/adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md)).
pub const trace = @import("trace.zig");
pub const traceBeginOf = scope_mod.traceBeginOf;
pub const traceEndOf = scope_mod.traceEndOf;

/// A Scope with its type erased, for the one place a shape checked while
/// compiling cannot reach: the other side of a function pointer
/// ([ADR 144](../docs/adr/144-a-scope-that-crosses-a-function-pointer.md)).
/// The ordinary Scope is unchanged and still costs nothing.
pub const AnyScope = scope_mod.AnyScope;

/// A moment and a calendar day, with RFC 3339 and ISO 8601 text both ways
/// (ADR 057). `nilo_sql` re-exports them; the framework root does too.
pub const Timestamp = @import("time.zig").Timestamp;
pub const Date = @import("time.zig").Date;

pub const nowMicros = clock_mod.nowMicros;
pub const nowMillis = clock_mod.nowMillis;
pub const monotonicMicros = clock_mod.monotonicMicros;

/// A namespace rather than flat names, because it is the one thing here with
/// two directions and a set to pick: `percent.encode…`, `percent.decode…`.
pub const percent = @import("percent.zig");

pub const Limits = @import("limits.zig").Limits;

/// A directory for one test, with the path to it that `std.testing.tmpDir`
/// does not give ([ADR 250](../docs/adr/250-a-test-directory-hands-back-its-path.md)).
/// `nilo.testing.tmpDir` is this one.
pub const tmpDir = @import("tmp.zig").tmpDir;
pub const TmpDir = @import("tmp.zig").TmpDir;

test {
    _ = @import("str.zig");
    _ = @import("scope.zig");
    _ = @import("clock.zig");
    _ = @import("time.zig");
    _ = @import("percent.zig");
    _ = @import("limits.zig");
    _ = @import("trace.zig");
    _ = @import("tmp.zig");
}
