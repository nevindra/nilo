//! A ring, a client and a claims type, held as one value — so that the layer
//! with a request can ask for "the user behind this bearer token" by naming
//! one type
//! ([ADR 191](../docs/adr/191-verified-claims-are-a-handler-argument.md)).
//!
//! ```zig
//! const Google = jwt.Verifier(Claims, fetch.Client);
//!
//! var google: jwt.Keyring = try .init(gpa, .{ .url = …, .issuer = .{ .is = … }, .audience = .{ .is = … } });
//! var verifier = Google.init(&google, &api);
//! try app.provide(&verifier);
//!
//! fn me(user: nilo.Verified(Google)) !Profile { … user.claims.sub … }
//! ```
//!
//! `Keyring.verifyOrRefresh` takes six arguments, and three of them — the
//! claims type, the ring and the client the refresh needs — are the same on
//! every call a program makes. A `nilo.Verified(T)` argument can name one
//! type and nothing else, so the three are held here, and the argument names
//! this. That is the whole of what the roadmap was waiting on: how a
//! resolver reaches the client, given that the argument names the ring.
//!
//! **The client is a type parameter, so this file still imports nothing**
//! — the arrangement `job.Table(Db)` uses for a store (ADR 160), and the
//! one `Keyring.refresh` already asks of its `client: anytype`. What it is
//! asked for is one `get(scope, url, .{})` answering `ok()` and
//! `body.view()`, which is what `fetch.Client` answers and what a test's
//! fake answers too.
//!
//! A Verifier is a Service the way a Keyring is not: it is what `provide`
//! takes and what the argument looks up. It has no `nilo_start`, because it
//! holds two pointers and nothing that needs the loop; the client under it
//! is started by the App on its own, as the Service it already was.

const std = @import("std");
const keyring_mod = @import("keyring.zig");

const Keyring = keyring_mod.Keyring;

pub fn Verifier(comptime Claims: type, comptime Client: type) type {
    return struct {
        const Self = @This();

        /// What `nilo.Verified(T)` reads to know this is a Verifier, and
        /// what it hands the handler: the claims type.
        pub const nilo_verifier = Claims;

        ring: *Keyring,
        client: *Client,

        pub fn init(ring: *Keyring, client: *Client) Self {
            return .{ .ring = ring, .client = client };
        }

        /// `Keyring.verifyOrRefresh` with the three constant arguments
        /// filled in. Strings in the result point into `gpa`; `scope` goes
        /// through to the client for the fetch a rotation costs.
        pub fn verify(self: *Self, gpa: std.mem.Allocator, token: []const u8, now_s: i64, scope: anytype) !Claims {
            return self.ring.verifyOrRefresh(Claims, gpa, token, now_s, scope, self.client);
        }
    };
}

// ---- tests ----

const testing = std.testing;
const vector = @import("vector.zig");

const Sub = struct { sub: []const u8 };

/// The one call a Verifier's client is asked for — the fake `keyring.zig`
/// tests with, in the shape `fetch.Client` has.
const FakeClient = struct {
    body: []const u8,
    gets: usize = 0,

    const Body = struct {
        bytes: []const u8,
        pub fn view(self: Body) []const u8 {
            return self.bytes;
        }
    };
    const Answer = struct {
        body: Body,
        pub fn ok(self: Answer) bool {
            _ = self;
            return true;
        }
    };

    pub fn get(self: *FakeClient, scope: *u8, url: []const u8, call: struct {}) !Answer {
        _ = scope;
        _ = url;
        _ = call;
        self.gets += 1;
        return .{ .body = .{ .bytes = self.body } };
    }
};

test "a Verifier verifies with the ring and refreshes through the client it holds" {
    var ring: Keyring = try .init(testing.allocator, .{
        .url = "https://issuer.example/certs",
        .issuer = .{ .is = "https://accounts.example" },
        .audience = .{ .is = "client-1" },
    });
    defer ring.deinit();
    var client: FakeClient = .{ .body = vector.jwks };

    const Google = Verifier(Sub, FakeClient);
    var google = Google.init(&ring, &client);
    try testing.expectEqual(Sub, Google.nilo_verifier);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var scope: u8 = 0;

    // The ring is empty, so the first verify is a `NoSuchKey` that fetches
    // once and verifies again — with the client the Verifier holds, which
    // the caller never named.
    const claims = try google.verify(arena.allocator(), vector.token, 1_500_000_000, &scope);
    try testing.expectEqualStrings("u-7", claims.sub);
    try testing.expectEqual(@as(usize, 1), client.gets);

    // The second verify finds the key and fetches nothing.
    _ = try google.verify(arena.allocator(), vector.token, 1_500_000_000, &scope);
    try testing.expectEqual(@as(usize, 1), client.gets);

    // And a token the ring refuses is refused through the same call.
    try testing.expectError(error.Expired, google.verify(arena.allocator(), vector.token, 2_500_000_000, &scope));
}
