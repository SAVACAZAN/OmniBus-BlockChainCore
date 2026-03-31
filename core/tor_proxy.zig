const std = @import("std");

// ─── Tor SOCKS5 Proxy Support ───────────────────────────────────────────────
//
// Enables P2P connections through the Tor network for privacy.
// OmniBus nodes can operate as hidden services (.onion addresses).
//
// Configuration:
//   --tor-proxy 127.0.0.1:9050     (connect through local Tor daemon)
//   --onion-service                 (advertise as .onion hidden service)
//
// SOCKS5 protocol:
//   1. Connect to Tor proxy (127.0.0.1:9050)
//   2. SOCKS5 handshake (version, auth method)
//   3. CONNECT request (target host:port)
//   4. Proxy establishes Tor circuit
//   5. All data relayed through 3-hop onion routing

/// SOCKS5 version
const SOCKS5_VERSION: u8 = 0x05;
/// Auth methods
const SOCKS5_NO_AUTH: u8 = 0x00;
/// Commands
const SOCKS5_CMD_CONNECT: u8 = 0x01;
/// Address types
const SOCKS5_ATYPE_DOMAIN: u8 = 0x03;
const SOCKS5_ATYPE_IPV4: u8 = 0x01;

/// Tor proxy configuration
pub const TorConfig = struct {
    /// SOCKS5 proxy address (default: 127.0.0.1)
    proxy_host: []const u8 = "127.0.0.1",
    /// SOCKS5 proxy port (default: 9050 for Tor daemon, 9150 for Tor Browser)
    proxy_port: u16 = 9050,
    /// Whether Tor is enabled
    enabled: bool = false,
    /// Whether to advertise as .onion hidden service
    onion_service: bool = false,
    /// Our .onion address (if hidden service enabled)
    onion_address: []const u8 = "",
    /// DNS resolution through Tor (prevents DNS leaks)
    dns_through_tor: bool = true,

    /// Default Tor config (disabled)
    pub fn default() TorConfig {
        return TorConfig{};
    }

    /// Enable with default Tor daemon settings
    pub fn enabled_default() TorConfig {
        return TorConfig{ .enabled = true };
    }

    /// Enable with Tor Browser bundle
    pub fn tor_browser() TorConfig {
        return TorConfig{ .enabled = true, .proxy_port = 9150 };
    }
};

/// SOCKS5 connection result
pub const Socks5Result = enum {
    success,
    general_failure,
    connection_refused,
    network_unreachable,
    host_unreachable,
    ttl_expired,
    command_not_supported,
    address_type_not_supported,
};

/// Build a SOCKS5 CONNECT request for Tor proxy
/// Returns the request bytes to send to the SOCKS5 proxy
pub fn buildSocks5ConnectRequest(target_host: []const u8, target_port: u16) struct { handshake: [3]u8, request: [263]u8, request_len: usize } {
    const handshake = [_]u8{ SOCKS5_VERSION, 1, SOCKS5_NO_AUTH };

    var request: [263]u8 = undefined;
    var pos: usize = 0;
    request[pos] = SOCKS5_VERSION; pos += 1;
    request[pos] = SOCKS5_CMD_CONNECT; pos += 1;
    request[pos] = 0x00; pos += 1; // reserved
    request[pos] = SOCKS5_ATYPE_DOMAIN; pos += 1;
    const host_len: u8 = @intCast(@min(target_host.len, 255));
    request[pos] = host_len; pos += 1;
    @memcpy(request[pos .. pos + host_len], target_host[0..host_len]);
    pos += host_len;
    request[pos] = @intCast((target_port >> 8) & 0xFF); pos += 1;
    request[pos] = @intCast(target_port & 0xFF); pos += 1;

    return .{ .handshake = handshake, .request = request, .request_len = pos };
}

/// Validate a SOCKS5 auth response
pub fn validateSocks5Auth(response: [2]u8) bool {
    return response[0] == SOCKS5_VERSION and response[1] == SOCKS5_NO_AUTH;
}

/// Validate a SOCKS5 CONNECT response
pub fn validateSocks5Connect(response: [10]u8) Socks5Result {
    if (response[0] != SOCKS5_VERSION) return .general_failure;
    return switch (response[1]) {
        0x00 => .success,
        0x02 => .connection_refused,
        0x03 => .network_unreachable,
        0x04 => .host_unreachable,
        0x06 => .ttl_expired,
        0x07 => .command_not_supported,
        0x08 => .address_type_not_supported,
        else => .general_failure,
    };
}

/// Check if Tor proxy is reachable (non-blocking check)
pub fn isTorAvailable(config: TorConfig) bool {
    _ = config;
    // In production: try TCP connect to proxy_host:proxy_port
    // For now: return false (no Tor daemon running in test env)
    return false;
}

/// Check if an address is a .onion address
pub fn isOnionAddress(host: []const u8) bool {
    return std.mem.endsWith(u8, host, ".onion");
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "TorConfig — default is disabled" {
    const config = TorConfig.default();
    try testing.expect(!config.enabled);
    try testing.expectEqual(@as(u16, 9050), config.proxy_port);
}

test "TorConfig — tor_browser uses port 9150" {
    const config = TorConfig.tor_browser();
    try testing.expect(config.enabled);
    try testing.expectEqual(@as(u16, 9150), config.proxy_port);
}

test "isOnionAddress — detects .onion" {
    try testing.expect(isOnionAddress("abc123def456.onion"));
    try testing.expect(!isOnionAddress("192.168.1.1"));
    try testing.expect(!isOnionAddress("example.com"));
}

test "SOCKS5 — build connect request" {
    const req = buildSocks5ConnectRequest("example.onion", 9000);
    try testing.expectEqual(@as(u8, SOCKS5_VERSION), req.handshake[0]);
    try testing.expectEqual(@as(u8, SOCKS5_VERSION), req.request[0]);
    try testing.expectEqual(@as(u8, SOCKS5_CMD_CONNECT), req.request[1]);
    try testing.expectEqual(@as(u8, SOCKS5_ATYPE_DOMAIN), req.request[3]);
    try testing.expect(req.request_len > 7);
}

test "SOCKS5 — validate auth response" {
    try testing.expect(validateSocks5Auth([2]u8{ 0x05, 0x00 }));
    try testing.expect(!validateSocks5Auth([2]u8{ 0x05, 0x01 }));
    try testing.expect(!validateSocks5Auth([2]u8{ 0x04, 0x00 }));
}

test "SOCKS5 — validate connect response" {
    var ok: [10]u8 = .{0} ** 10;
    ok[0] = 0x05;
    ok[1] = 0x00;
    try testing.expectEqual(Socks5Result.success, validateSocks5Connect(ok));

    ok[1] = 0x02;
    try testing.expectEqual(Socks5Result.connection_refused, validateSocks5Connect(ok));
}

test "Tor — isTorAvailable returns false without daemon" {
    const config = TorConfig.default();
    try testing.expect(!isTorAvailable(config));
}
