//! Which addresses in front of this server are allowed to say who the client
//! is ([ADR 0129](../docs/adr/0129-a-proxy-is-trusted-by-which-one-it-is.md)).
//!
//! `.trusted_hops` counts entries from the right of `X-Forwarded-For`, which
//! is sound arithmetic and is all there was. What a count cannot say is that
//! the header counts only when the connection came from `10.0.0.0/8`, and it
//! cannot describe a deployment where the number of hops differs by path — a
//! load balancer adding one for public traffic while a health check reaches
//! the pod directly. Gin takes a list of CIDRs and Fiber takes ranges plus the
//! loopback and private classes; both answer that question and a hop count
//! cannot.
//!
//! **A wrong count is silent, and that is what earned the change.**
//! `clientIp()` returns something that looks like an address either way, so a
//! deployment that grew a hop keeps answering — with the proxy's address, or
//! with whatever a client put in the header. Describing the network instead
//! makes the answer stop depending on a number nobody re-checks: walk the
//! header from the right, drop entries that came from an address you named,
//! and the first one that did not is the client.
//!
//! **What it costs.** Parsing happens once, at `listen()`. Per request it is a
//! prefix compare per entry per rule, on requests that call `clientIp()` and
//! carry the header — nothing at all for everybody else, because `Ctx` reads
//! this only when asked ([ADR 0018](../docs/adr/0018-the-trade-budget-has-three-axes.md)).

const std = @import("std");
const net = std.Io.net;

/// One network, as an address and how many leading bits of it matter.
///
/// Held as 16 bytes whichever family it came from: a v4 rule is kept as its
/// v4-mapped v6 form, so an IPv4 client arriving on a socket bound to `::`
/// — which reaches a handler as `::ffff:203.0.113.9` — is matched by
/// `10.0.0.0/8` without the caller having to write the rule twice.
pub const Cidr = struct {
    bytes: [16]u8,
    /// Bits of `bytes` that have to match, counted from the front of the
    /// 128-bit form. A v4 `/8` is stored as `/104`.
    bits: u8,

    /// Whether `address`, as text, is inside this network.
    ///
    /// Text in rather than a parsed address, because that is what both callers
    /// hold: `Peer.address()` is text and an `X-Forwarded-For` entry is text.
    /// Anything that does not parse is outside every network — a header entry
    /// is whatever a proxy wrote, and "not an address" is not a reason to
    /// trust it.
    pub fn contains(self: Cidr, address: []const u8) bool {
        const parsed = mapped(address) orelse return false;
        return self.containsBytes(parsed);
    }

    fn containsBytes(self: Cidr, address: [16]u8) bool {
        const whole = self.bits / 8;
        const spare = self.bits % 8;
        if (!std.mem.eql(u8, self.bytes[0..whole], address[0..whole])) return false;
        if (spare == 0) return true;
        const mask: u8 = @truncate(@as(u16, 0xff) << @intCast(8 - spare));
        return (self.bytes[whole] & mask) == (address[whole] & mask);
    }
};

/// An address as its 128-bit form, whichever way it was written.
fn mapped(text: []const u8) ?[16]u8 {
    const parsed = net.IpAddress.parse(text, 0) catch return null;
    return switch (parsed) {
        .ip4 => |v4| v4mapped(v4.bytes),
        .ip6 => |v6| v6.bytes,
    };
}

fn v4mapped(four: [4]u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    out[10] = 0xff;
    out[11] = 0xff;
    @memcpy(out[12..], &four);
    return out;
}

pub const ParseError = error{TrustedProxyNotAnAddress};

/// The networks a name stands for.
///
/// Two names rather than a general vocabulary, and they are the two every
/// deployment writes. `"private"` is what a pod, a container network or an
/// office LAN sits in; `"loopback"` is a sidecar or a proxy on the same host.
/// Anything else is a CIDR, or a bare address meaning just that one.
const named = struct {
    const loopback = [_][]const u8{ "127.0.0.0/8", "::1/128" };
    const private = [_][]const u8{
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        // Carrier-grade NAT, which is where a cloud load balancer often sits.
        "100.64.0.0/10",
        // Link-local, both families, and unique-local v6.
        "169.254.0.0/16",
        "fe80::/10",
        "fc00::/7",
    } ++ loopback;
};

/// How many `Cidr`s one written rule expands to. `"private"` is the widest.
pub fn expands(rule: []const u8) usize {
    if (std.mem.eql(u8, rule, "private")) return named.private.len;
    if (std.mem.eql(u8, rule, "loopback")) return named.loopback.len;
    return 1;
}

/// Parse one written rule into `out`, returning how many it filled.
///
/// Called once per rule at `listen()`, so the cost is startup and the error is
/// a sentence a person reads before any request arrives.
pub fn parseInto(out: []Cidr, rule: []const u8) ParseError!usize {
    if (std.mem.eql(u8, rule, "private")) return parseList(out, &named.private);
    if (std.mem.eql(u8, rule, "loopback")) return parseList(out, &named.loopback);
    out[0] = try parseOne(rule);
    return 1;
}

fn parseList(out: []Cidr, rules: []const []const u8) ParseError!usize {
    for (rules, 0..) |rule, i| out[i] = try parseOne(rule);
    return rules.len;
}

/// The first rule that is not an address, for the sentence `listen()` prints
/// before it refuses to start.
///
/// Separate from the parse on purpose. A `std.log.err` inside a test is a
/// failed test whatever level it prints at — the runner counts it rather than
/// reading it (see `test_root.zig`) — so the parse stays quiet and returns,
/// and the caller that is about to stop the server is the one that says why.
pub fn firstBad(rules: []const []const u8) ?[]const u8 {
    for (rules) |rule| {
        if (std.mem.eql(u8, rule, "private") or std.mem.eql(u8, rule, "loopback")) continue;
        _ = parseOne(rule) catch return rule;
    }
    return null;
}

/// `10.0.0.0/8`, `fd00::/8`, or a bare address meaning only itself.
pub fn parseOne(rule: []const u8) ParseError!Cidr {
    const slash = std.mem.indexOfScalar(u8, rule, '/');
    const address = if (slash) |at| rule[0..at] else rule;

    const parsed = net.IpAddress.parse(address, 0) catch return error.TrustedProxyNotAnAddress;
    const is_v4 = parsed == .ip4;
    const bytes = switch (parsed) {
        .ip4 => |v4| v4mapped(v4.bytes),
        .ip6 => |v6| v6.bytes,
    };

    // A bare address is one host: every bit of it has to match.
    const written: u8 = if (slash) |at|
        std.fmt.parseInt(u8, rule[at + 1 ..], 10) catch return error.TrustedProxyNotAnAddress
    else if (is_v4) 32 else 128;

    const ceiling: u8 = if (is_v4) 32 else 128;
    if (written > ceiling) return error.TrustedProxyNotAnAddress;

    // A v4 rule is stored in the v4-mapped form, so its prefix starts 96 bits
    // in. That is what lets one rule match a client that arrived either way.
    return .{ .bytes = bytes, .bits = if (is_v4) written + 96 else written };
}

/// Whether any of these networks holds `address`.
pub fn holds(rules: []const Cidr, address: []const u8) bool {
    if (rules.len == 0) return false;
    const parsed = mapped(address) orelse return false;
    for (rules) |rule| {
        if (rule.containsBytes(parsed)) return true;
    }
    return false;
}

/// The client's address, out of an `X-Forwarded-For` written by proxies whose
/// own addresses are in `rules`.
///
/// Walk right to left. The rightmost entry was written by the proxy nearest
/// this server, so an entry that names a trusted address is a proxy of ours
/// and is skipped; the first that does not is the client, and everything to
/// the left of it is whatever the client claimed and is never looked at.
///
/// `peer` is the address the connection itself came from, and it is checked
/// first: a header from a machine that is not one of ours is not read at all.
/// Null means "no answer from the header" — the caller falls back to `peer`,
/// which is what the kernel says and cannot be forged.
///
/// `local` is that check already answered. A connection that arrived over a
/// unix socket has no address to test and cannot have come from anywhere but
/// this machine, which is the thing a `"loopback"` rule is trying to
/// establish about a proxy over TCP ([ADR 0130](../docs/adr/0130-a-path-is-an-address-to-listen-on.md)).
/// It does not make the header trusted on its own: `rules` still has to be
/// set, because reading it at all is the thing an operator opts into.
pub fn clientFrom(
    rules: []const Cidr,
    peer: []const u8,
    local: bool,
    forwarded: []const u8,
) ?[]const u8 {
    if (!local and !holds(rules, peer)) return null;

    var rest = forwarded;
    while (rest.len > 0) {
        const at = std.mem.lastIndexOfScalar(u8, rest, ',');
        const entry = std.mem.trim(u8, if (at) |i| rest[i + 1 ..] else rest, " \t");
        if (entry.len > 0 and !holds(rules, entry)) return entry;
        rest = if (at) |i| rest[0..i] else "";
    }
    // Every entry was one of ours, which happens when a proxy of ours is
    // itself the client — a health check from the load balancer. The socket's
    // address is the honest answer.
    return null;
}

const testing = std.testing;

fn cidrs(comptime rules: []const []const u8) [rules.len]Cidr {
    var out: [rules.len]Cidr = undefined;
    for (rules, 0..) |rule, i| out[i] = parseOne(rule) catch unreachable;
    return out;
}

test "a network holds the addresses inside it and no others" {
    const ten = try parseOne("10.0.0.0/8");
    try testing.expect(ten.contains("10.0.0.1"));
    try testing.expect(ten.contains("10.255.255.255"));
    try testing.expect(!ten.contains("11.0.0.1"));
    try testing.expect(!ten.contains("192.168.0.1"));

    // A prefix that does not land on a byte boundary.
    const twelve = try parseOne("172.16.0.0/12");
    try testing.expect(twelve.contains("172.16.0.1"));
    try testing.expect(twelve.contains("172.31.255.254"));
    try testing.expect(!twelve.contains("172.32.0.1"));
    try testing.expect(!twelve.contains("172.15.255.255"));
}

test "a v4 rule matches a client that arrived v4-mapped" {
    // The case this exists for: a server bound to `::` hands an IPv4 client to
    // a handler as `::ffff:203.0.113.9`, and nobody should have to write the
    // rule twice.
    const rule = try parseOne("203.0.113.0/24");
    try testing.expect(rule.contains("203.0.113.9"));
    try testing.expect(rule.contains("::ffff:203.0.113.9"));
    try testing.expect(!rule.contains("::ffff:203.0.114.9"));
}

test "a bare address is one host" {
    const one = try parseOne("192.168.1.7");
    try testing.expect(one.contains("192.168.1.7"));
    try testing.expect(!one.contains("192.168.1.8"));

    const six = try parseOne("fd00::1");
    try testing.expect(six.contains("fd00::1"));
    try testing.expect(!six.contains("fd00::2"));
}

test "a rule that is not an address is refused where it is written" {
    try testing.expectError(error.TrustedProxyNotAnAddress, parseOne("not-an-address"));
    try testing.expectError(error.TrustedProxyNotAnAddress, parseOne("10.0.0.0/goat"));
    // A prefix wider than the family has bits.
    try testing.expectError(error.TrustedProxyNotAnAddress, parseOne("10.0.0.0/33"));
}

test "private and loopback expand to the networks everybody means by them" {
    var buf: [16]Cidr = undefined;
    const n = try parseInto(&buf, "private");
    try testing.expectEqual(expands("private"), n);

    const rules = buf[0..n];
    try testing.expect(holds(rules, "10.1.2.3"));
    try testing.expect(holds(rules, "192.168.0.9"));
    try testing.expect(holds(rules, "172.20.0.1"));
    try testing.expect(holds(rules, "127.0.0.1"));
    try testing.expect(holds(rules, "::1"));
    try testing.expect(holds(rules, "fd12::1"));
    // A public address is not private, which is the whole point.
    try testing.expect(!holds(rules, "203.0.113.9"));
}

test "the client is the first entry the trusted set does not hold" {
    const rules = cidrs(&.{"10.0.0.0/8"});

    // One proxy of ours, and the client to the left of it.
    try testing.expectEqualStrings(
        "203.0.113.9",
        clientFrom(&rules, "10.0.0.7", false, "203.0.113.9, 10.0.0.7").?,
    );

    // Two of ours, however many the operator thought there were — which is
    // the number a hop count would have had to get right.
    try testing.expectEqualStrings(
        "203.0.113.9",
        clientFrom(&rules, "10.0.0.7", false, "203.0.113.9, 10.0.0.4, 10.0.0.7").?,
    );

    // A client that forged entries of its own: they sit to the left of the
    // first untrusted entry and are never reached.
    try testing.expectEqualStrings(
        "203.0.113.9",
        clientFrom(&rules, "10.0.0.7", false, "10.9.9.9, 1.1.1.1, 203.0.113.9, 10.0.0.7").?,
    );
}

test "a header from a machine that is not ours is not read at all" {
    const rules = cidrs(&.{"10.0.0.0/8"});
    // The connection came straight off the internet. Whatever it says about
    // who it is forwarding for is its own invention.
    try testing.expect(clientFrom(&rules, "203.0.113.9", false, "1.2.3.4") == null);
}

test "a request from the proxy itself falls back to the socket" {
    const rules = cidrs(&.{"10.0.0.0/8"});
    // A health check from the load balancer: every entry is one of ours, so
    // there is no client behind them to name.
    try testing.expect(clientFrom(&rules, "10.0.0.7", false, "10.0.0.4") == null);
    try testing.expect(clientFrom(&rules, "10.0.0.7", false, "") == null);
}

test "a connection over a unix socket may carry a forwarded header" {
    // The deployment this is for: nginx in front, reaching the server over
    // `unix:/run/nilo.sock`. There is no connection address to put a rule
    // against, and nothing but a process on this machine could have opened
    // the socket — so the check the rules exist to make is already answered
    // (ADR 0130).
    const rules = cidrs(&.{"10.0.0.0/8"});
    try testing.expectEqualStrings(
        "203.0.113.9",
        clientFrom(&rules, "", true, "203.0.113.9").?,
    );

    // Reading the header is still something the operator turns on: with no
    // rules set, `Ctx.clientIp` never calls this at all.

    // And a proxy of ours writing its own address over the socket is still
    // skipped, exactly as over TCP.
    try testing.expectEqualStrings(
        "203.0.113.9",
        clientFrom(&rules, "", true, "203.0.113.9, 10.0.0.7").?,
    );
}

test "an entry that is not an address is not trusted" {
    const rules = cidrs(&.{"10.0.0.0/8"});
    // `unknown` is what RFC 7239 says a proxy may write when it cannot say.
    // It is not one of ours, so the walk stops there rather than reading past
    // it into whatever the client claimed.
    try testing.expectEqualStrings(
        "unknown",
        clientFrom(&rules, "10.0.0.7", false, "1.1.1.1, unknown, 10.0.0.7").?,
    );
}
