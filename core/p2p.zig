/// p2p.zig — Transport TCP real pentru OmniBus P2P
/// Modular: network.zig pastreaza structurile, p2p.zig adauga transportul
/// Nu modifica blockchain.zig, wallet.zig sau codul existent.
const std = @import("std");
const builtin = @import("builtin");
const network_mod    = @import("network.zig");
const scoring_mod    = @import("peer_scoring.zig");
const bootstrap_mod  = @import("bootstrap.zig");
const tor_mod        = @import("tor_proxy.zig");

// Windows: stream.read() = ReadFile care pica pe sockets acceptate. Folosim ws2_32.
const is_windows = builtin.os.tag == .windows;
const ws2 = if (is_windows) std.os.windows.ws2_32 else undefined;

fn p2pRecv(stream: std.net.Stream, buf: []u8) !usize {
    if (comptime is_windows) {
        const got = ws2.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (got <= 0) return error.ConnectionClosed;
        return @intCast(got);
    } else {
        const n = try stream.read(buf);
        if (n == 0) return error.ConnectionClosed;
        return n;
    }
}

fn p2pSend(stream: std.net.Stream, data: []const u8) !void {
    if (comptime is_windows) {
        var sent: usize = 0;
        while (sent < data.len) {
            const remaining: c_int = @intCast(data.len - sent);
            const n = ws2.send(stream.handle, data[sent..].ptr, remaining, 0);
            if (n <= 0) return error.ConnectionClosed;
            sent += @intCast(n);
        }
    } else {
        try stream.writeAll(data);
    }
}
const array_list     = std.array_list;
const blockchain_mod = @import("blockchain.zig");
const block_mod      = @import("block.zig");
const sync_mod       = @import("sync.zig");
const light_client_mod = @import("light_client.zig");

pub const NetworkNode   = network_mod.NetworkNode;
pub const MessageType   = network_mod.MessageType;
pub const Blockchain    = blockchain_mod.Blockchain;
pub const Block         = block_mod.Block;
pub const SyncManager   = sync_mod.SyncManager;

/// Port implicit P2P (diferit de RPC 8332)
pub const P2P_PORT_DEFAULT: u16 = 8333;

/// Versiunea protocolului P2P
pub const P2P_VERSION: u8 = 1;

/// Marimea maxima a unui mesaj P2P (1 MB)
pub const P2P_MAX_MSG_BYTES: u32 = 1_048_576;

/// Timeout conexiune TCP in ms
pub const P2P_CONNECT_TIMEOUT_MS: u64 = 3_000;

/// Timeout citire in ms
pub const P2P_READ_TIMEOUT_MS: u64 = 5_000;

// ─── P2P Hardening Constants ────────────────────────────────────────────────

/// Max inbound connections
pub const MAX_INBOUND: usize = 32;
/// Max outbound connections
pub const MAX_OUTBOUND: usize = 8;
/// Max total peers (inbound + outbound)
pub const MAX_PEERS: usize = MAX_INBOUND + MAX_OUTBOUND;
/// Max reconnect attempts before removing a peer
pub const MAX_RECONNECT_ATTEMPTS: u8 = 3;
/// Delay before reconnect attempt (seconds)
pub const RECONNECT_DELAY_SEC: i64 = 30;
/// Rate limit: max messages per second per peer
pub const RATE_LIMIT_MSG_PER_SEC: u32 = 100;
/// Rate limit: max bytes per second per peer (10 MB)
pub const RATE_LIMIT_BYTES_PER_SEC: u64 = 10 * 1024 * 1024;
/// Ban score added when rate limit is exceeded
pub const RATE_LIMIT_BAN_SCORE: i32 = 50;
/// Max banned peers tracked
pub const MAX_BANNED_PEERS: usize = 256;
/// Max peers from same /16 subnet (anti-eclipse)
pub const MAX_PEERS_PER_SUBNET: usize = 2;
/// Minimum distinct /16 subnets for diversity
pub const MIN_SUBNET_DIVERSITY: usize = 4;

// ─── Protocolul binar de mesaje P2P ──────────────────────────────────────────
//
// Fiecare mesaj TCP are header fix de 9 bytes:
//  [0]   version   u8      — versiunea protocolului (1)
//  [1]   msg_type  u8      — tipul mesajului (enum MessageType)
//  [2-5] payload_len u32LE — lungimea payload-ului in bytes
//  [6-7] checksum u16      — sum simplu al payload (anti-coruptie)
//  [8]   flags     u8      — rezervat (0 deocamdata)
//  [9..] payload   []u8    — continutul mesajului

pub const MSG_HEADER_SIZE: usize = 9;

pub const MsgHeader = struct {
    version:     u8,
    msg_type:    u8,
    payload_len: u32,
    checksum:    u16,
    flags:       u8,

    pub fn encode(self: MsgHeader, buf: *[MSG_HEADER_SIZE]u8) void {
        buf[0] = self.version;
        buf[1] = self.msg_type;
        std.mem.writeInt(u32, buf[2..6], self.payload_len, .little);
        std.mem.writeInt(u16, buf[6..8], self.checksum, .little);
        buf[8] = self.flags;
    }

    pub fn decode(buf: *const [MSG_HEADER_SIZE]u8) MsgHeader {
        return .{
            .version     = buf[0],
            .msg_type    = buf[1],
            .payload_len = std.mem.readInt(u32, buf[2..6], .little),
            .checksum    = std.mem.readInt(u16, buf[6..8], .little),
            .flags       = buf[8],
        };
    }
};

/// Checksum simplu: suma tuturor byte-ilor payload mod 65536
pub fn calcChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    for (data) |b| sum += b;
    return @truncate(sum);
}

// ─── Tipuri de mesaje P2P ─────────────────────────────────────────────────────

pub const MsgPing = struct {
    node_id:  [32]u8,   // ID nod (padded cu 0)
    height:   u64,      // Inaltimea curenta a lantului
    version:  u8,

    pub fn encode(self: MsgPing, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 41);
        @memcpy(buf[0..32], &self.node_id);
        std.mem.writeInt(u64, buf[32..40], self.height, .little);
        buf[40] = self.version;
        return buf;
    }

    pub fn decode(data: []const u8) ?MsgPing {
        if (data.len < 41) return null;
        var id: [32]u8 = undefined;
        @memcpy(&id, data[0..32]);
        return .{
            .node_id = id,
            .height  = std.mem.readInt(u64, data[32..40], .little),
            .version = data[40],
        };
    }
};

pub const MsgPeerList = struct {
    peers: []PeerAddr,

    pub const PeerAddr = struct {
        ip:   [4]u8,   // IPv4
        port: u16,
    };
};

// ─── PEX (Peer Exchange) message encode/decode (B12) ────────────────────────
//
// Wire format for get_peers:  empty payload (0 bytes)
// Wire format for peer_list:  [count:u16LE][peer0: ip4+port_le][peer1: ...]
//   Each peer entry = 6 bytes: [ip0][ip1][ip2][ip3][port_lo][port_hi]
//   Max 100 peers per message.

pub const PEX_MAX_PEERS: usize = 100;
pub const PEX_PEER_SIZE: usize = 6; // 4 bytes IP + 2 bytes port

/// Encode a list of PeerAddr into a peer_list payload.
pub fn encodePeerList(peers: []const MsgPeerList.PeerAddr, allocator: std.mem.Allocator) ![]u8 {
    const count: u16 = @intCast(@min(peers.len, PEX_MAX_PEERS));
    const total = 2 + @as(usize, count) * PEX_PEER_SIZE;
    var buf = try allocator.alloc(u8, total);
    std.mem.writeInt(u16, buf[0..2], count, .little);
    for (0..count) |i| {
        const off = 2 + i * PEX_PEER_SIZE;
        @memcpy(buf[off .. off + 4], &peers[i].ip);
        std.mem.writeInt(u16, buf[off + 4 ..][0..2], peers[i].port, .little);
    }
    return buf;
}

/// Decode a peer_list payload into a slice of PeerAddr.
/// Caller must free the returned slice with allocator.free().
pub fn decodePeerList(data: []const u8, allocator: std.mem.Allocator) ![]MsgPeerList.PeerAddr {
    if (data.len < 2) return error.InvalidPayload;
    const count: usize = std.mem.readInt(u16, data[0..2], .little);
    if (count > PEX_MAX_PEERS) return error.TooManyPeers;
    if (data.len < 2 + count * PEX_PEER_SIZE) return error.InvalidPayload;
    var peers = try allocator.alloc(MsgPeerList.PeerAddr, count);
    for (0..count) |i| {
        const off = 2 + i * PEX_PEER_SIZE;
        @memcpy(&peers[i].ip, data[off .. off + 4]);
        peers[i].port = std.mem.readInt(u16, data[off + 4 ..][0..2], .little);
    }
    return peers;
}

pub const MsgBlockAnnounce = struct {
    block_height: u64,
    block_hash:   [32]u8,
    miner_id:     [32]u8,
    reward_sat:   u64,

    pub fn encode(self: MsgBlockAnnounce, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 80);
        std.mem.writeInt(u64, buf[0..8],   self.block_height, .little);
        @memcpy(buf[8..40],  &self.block_hash);
        @memcpy(buf[40..72], &self.miner_id);
        std.mem.writeInt(u64, buf[72..80], self.reward_sat, .little);
        return buf;
    }

    pub fn decode(data: []const u8) ?MsgBlockAnnounce {
        if (data.len < 80) return null;
        var bh: [32]u8 = undefined;
        var mi: [32]u8 = undefined;
        @memcpy(&bh, data[8..40]);
        @memcpy(&mi, data[40..72]);
        return .{
            .block_height = std.mem.readInt(u64, data[0..8],   .little),
            .block_hash   = bh,
            .miner_id     = mi,
            .reward_sat   = std.mem.readInt(u64, data[72..80], .little),
        };
    }
};

// ─── P2P Hardening Types ────────────────────────────────────────────────────

/// Banned peer entry — tracks host:port + ban expiry
pub const BannedPeer = struct {
    host: [64]u8,
    host_len: u8,
    port: u16,
    banned_until: i64, // Unix timestamp
    reason: [64]u8,
    reason_len: u8,
    active: bool,

    pub fn init(host: []const u8, port: u16, duration_sec: i64, reason: []const u8) BannedPeer {
        var bp: BannedPeer = .{
            .host = @splat(0),
            .host_len = @intCast(@min(host.len, 64)),
            .port = port,
            .banned_until = std.time.timestamp() + duration_sec,
            .reason = @splat(0),
            .reason_len = @intCast(@min(reason.len, 64)),
            .active = true,
        };
        @memcpy(bp.host[0..bp.host_len], host[0..bp.host_len]);
        @memcpy(bp.reason[0..bp.reason_len], reason[0..bp.reason_len]);
        return bp;
    }

    pub fn isExpired(self: *const BannedPeer) bool {
        return std.time.timestamp() >= self.banned_until;
    }

    pub fn matchesHost(self: *const BannedPeer, host: []const u8, port: u16) bool {
        if (!self.active) return false;
        if (self.port != port) return false;
        if (self.host_len != host.len) return false;
        return std.mem.eql(u8, self.host[0..self.host_len], host);
    }
};

/// Per-peer reconnect tracking
pub const ReconnectInfo = struct {
    host: [64]u8,
    host_len: u8,
    port: u16,
    node_id: [64]u8,
    node_id_len: u8,
    attempts: u8,
    last_disconnect: i64,
    active: bool,

    pub fn init(host: []const u8, port: u16, node_id: []const u8) ReconnectInfo {
        var ri: ReconnectInfo = .{
            .host = @splat(0),
            .host_len = @intCast(@min(host.len, 64)),
            .port = port,
            .node_id = @splat(0),
            .node_id_len = @intCast(@min(node_id.len, 64)),
            .attempts = 0,
            .last_disconnect = std.time.timestamp(),
            .active = true,
        };
        @memcpy(ri.host[0..ri.host_len], host[0..ri.host_len]);
        @memcpy(ri.node_id[0..ri.node_id_len], node_id[0..ri.node_id_len]);
        return ri;
    }
};

/// Per-peer rate limiting state
pub const RateLimitState = struct {
    msg_count: u32,
    byte_count: u64,
    window_start: i64,

    pub fn init() RateLimitState {
        return .{
            .msg_count = 0,
            .byte_count = 0,
            .window_start = 0,
        };
    }

    /// Record a message. Returns true if within limits, false if exceeded.
    pub fn recordMessage(self: *RateLimitState, msg_size: usize) bool {
        const now = std.time.timestamp();
        // Reset window every second
        if (now != self.window_start) {
            self.msg_count = 0;
            self.byte_count = 0;
            self.window_start = now;
        }
        self.msg_count += 1;
        self.byte_count += msg_size;
        return self.msg_count <= RATE_LIMIT_MSG_PER_SEC and
            self.byte_count <= RATE_LIMIT_BYTES_PER_SEC;
    }
};

/// Connection direction for tracking inbound vs outbound
pub const ConnDirection = enum {
    inbound,
    outbound,
};

// ─── Conexiune P2P (un singur peer) ──────────────────────────────────────────

pub const PeerConnection = struct {
    stream:     std.net.Stream,
    node_id:    []const u8,
    host:       []const u8,
    port:       u16,
    height:     u64,
    connected:  bool,
    allocator:  std.mem.Allocator,
    direction:  ConnDirection = .outbound,
    rate_limit: RateLimitState = RateLimitState.init(),
    /// IP bytes for subnet tracking (IPv4)
    ip_bytes:   [4]u8 = .{ 0, 0, 0, 0 },

    /// Trimite un mesaj binar catre peer
    pub fn send(self: *PeerConnection, msg_type: u8, payload: []const u8) !void {
        if (!self.connected) return error.NotConnected;
        if (payload.len > P2P_MAX_MSG_BYTES) return error.PayloadTooLarge;

        var header_buf: [MSG_HEADER_SIZE]u8 = undefined;
        const hdr = MsgHeader{
            .version     = P2P_VERSION,
            .msg_type    = msg_type,
            .payload_len = std.math.cast(u32, payload.len) orelse return error.PayloadTooLarge,
            .checksum    = calcChecksum(payload),
            .flags       = 0,
        };
        hdr.encode(&header_buf);

        try p2pSend(self.stream, &header_buf);
        if (payload.len > 0) try p2pSend(self.stream, payload);
    }

    /// Citeste un mesaj binar de la peer
    /// Caller trebuie sa elibereze payload-ul cu allocator.free()
    pub fn recv(self: *PeerConnection) !struct { msg_type: u8, payload: []u8 } {
        if (!self.connected) return error.NotConnected;

        var header_buf: [MSG_HEADER_SIZE]u8 = undefined;
        const n = try readAllFromStream(self.stream, &header_buf);
        if (n < MSG_HEADER_SIZE) return error.ConnectionClosed;

        const hdr = MsgHeader.decode(&header_buf);
        if (hdr.version != P2P_VERSION) return error.ProtocolMismatch;
        if (hdr.payload_len > P2P_MAX_MSG_BYTES) return error.PayloadTooLarge;

        const payload = try self.allocator.alloc(u8, hdr.payload_len);
        errdefer self.allocator.free(payload);

        if (hdr.payload_len > 0) {
            const read = try readAllFromStream(self.stream, payload);
            if (read < hdr.payload_len) return error.ConnectionClosed;
        }

        // Verifica checksum
        if (calcChecksum(payload) != hdr.checksum) {
            self.allocator.free(payload);
            return error.ChecksumMismatch;
        }

        return .{ .msg_type = hdr.msg_type, .payload = payload };
    }

    /// Trimite PING cu inaltimea curenta a lantului
    pub fn sendPing(self: *PeerConnection, node_id: []const u8, height: u64) !void {
        var id_buf: [32]u8 = @splat(0);
        const copy_len = @min(node_id.len, 32);
        @memcpy(id_buf[0..copy_len], node_id[0..copy_len]);

        const ping = MsgPing{ .node_id = id_buf, .height = height, .version = P2P_VERSION };
        const payload = try ping.encode(self.allocator);
        defer self.allocator.free(payload);

        try self.send(@intFromEnum(MessageType.ping), payload);
    }

    /// Anunta un bloc nou la peer
    pub fn announceBlock(
        self:         *PeerConnection,
        height:       u64,
        hash_hex:     []const u8,
        miner_id:     []const u8,
        reward_sat:   u64,
    ) !void {
        var bh: [32]u8 = @splat(0);
        var mi: [32]u8 = @splat(0);
        const hlen = @min(hash_hex.len, 32);
        const mlen = @min(miner_id.len, 32);
        @memcpy(bh[0..hlen], hash_hex[0..hlen]);
        @memcpy(mi[0..mlen], miner_id[0..mlen]);

        const ann = MsgBlockAnnounce{
            .block_height = height,
            .block_hash   = bh,
            .miner_id     = mi,
            .reward_sat   = reward_sat,
        };
        const payload = try ann.encode(self.allocator);
        defer self.allocator.free(payload);

        try self.send(@intFromEnum(MessageType.block), payload);
    }

    pub fn close(self: *PeerConnection) void {
        if (self.connected) {
            self.stream.close();
            self.connected = false;
        }
    }
};

// ─── Gossip Protocol — TX relay + block propagation (B6) ─────────────────────

/// Maximum number of hashes tracked for deduplication
const SEEN_HASHES_MAX: usize = 8192;
/// Seen hash entries older than this are evicted (10 minutes in seconds)
const SEEN_HASH_EXPIRY_S: i64 = 600;

/// Tracks recently seen TX/block hashes to prevent infinite relay loops.
/// Fixed-size ring buffer — no dynamic allocation after init.
pub const SeenHashes = struct {
    const Entry = struct {
        hash: [64]u8,     // hex hash (64 chars)
        hash_len: u8,
        timestamp: i64,   // when first seen
        active: bool,
    };

    entries: [SEEN_HASHES_MAX]Entry = undefined,
    count: usize = 0,
    next_slot: usize = 0,

    pub fn init() SeenHashes {
        @setEvalBranchQuota(100_000);
        var sh = SeenHashes{};
        for (&sh.entries) |*e| {
            e.active = false;
            e.hash_len = 0;
            e.timestamp = 0;
        }
        return sh;
    }

    /// Returns true if the hash was already seen (still fresh).
    pub fn contains(self: *const SeenHashes, hash: []const u8) bool {
        const now = std.time.timestamp();
        const hlen = @min(hash.len, 64);
        for (&self.entries) |*e| {
            if (!e.active) continue;
            if (e.hash_len != hlen) continue;
            if (now - e.timestamp > SEEN_HASH_EXPIRY_S) continue; // expired
            if (std.mem.eql(u8, e.hash[0..e.hash_len], hash[0..hlen])) return true;
        }
        return false;
    }

    /// Inserts a hash. Returns false if it was already present (duplicate).
    pub fn insert(self: *SeenHashes, hash: []const u8) bool {
        if (self.contains(hash)) return false;

        const hlen: u8 = @intCast(@min(hash.len, 64));
        const slot = self.next_slot;
        self.entries[slot] = .{
            .hash = undefined,
            .hash_len = hlen,
            .timestamp = std.time.timestamp(),
            .active = true,
        };
        @memcpy(self.entries[slot].hash[0..hlen], hash[0..hlen]);
        if (hlen < 64) @memset(self.entries[slot].hash[hlen..], 0);

        self.next_slot = (self.next_slot + 1) % SEEN_HASHES_MAX;
        if (self.count < SEEN_HASHES_MAX) self.count += 1;
        return true;
    }

    /// Evict entries older than SEEN_HASH_EXPIRY_S
    pub fn evictExpired(self: *SeenHashes) void {
        const now = std.time.timestamp();
        for (&self.entries) |*e| {
            if (e.active and (now - e.timestamp > SEEN_HASH_EXPIRY_S)) {
                e.active = false;
                if (self.count > 0) self.count -= 1;
            }
        }
    }
};

/// Gossip TX payload: JSON-encoded transaction for simplicity.
/// Wire format: [hash_len:1][hash:N][json_len:4LE][json:M]
pub const GossipTxPayload = struct {
    tx_hash: []const u8,   // hex hash of the TX
    tx_json: []const u8,   // JSON-encoded TX

    pub fn encode(self: GossipTxPayload, allocator: std.mem.Allocator) ![]u8 {
        const hlen: u8 = @intCast(@min(self.tx_hash.len, 255));
        const jlen: u32 = @intCast(self.tx_json.len);
        const total = @as(usize, 1) + hlen + 4 + jlen;
        var buf = try allocator.alloc(u8, total);
        buf[0] = hlen;
        @memcpy(buf[1 .. 1 + hlen], self.tx_hash[0..hlen]);
        std.mem.writeInt(u32, buf[1 + hlen ..][0..4], jlen, .little);
        @memcpy(buf[1 + hlen + 4 ..][0..jlen], self.tx_json[0..jlen]);
        return buf;
    }

    pub fn decode(data: []const u8) ?GossipTxPayload {
        if (data.len < 6) return null; // min: 1 + 1 + 4 = 6
        const hlen: usize = data[0];
        if (data.len < 1 + hlen + 4) return null;
        const jlen = std.mem.readInt(u32, data[1 + hlen ..][0..4], .little);
        if (data.len < 1 + hlen + 4 + jlen) return null;
        return .{
            .tx_hash = data[1 .. 1 + hlen],
            .tx_json = data[1 + hlen + 4 ..][0..jlen],
        };
    }
};

/// Gossip Block payload: block announce + block hash for relay.
/// Re-uses MsgBlockAnnounce format (80 bytes) — full block data via sync.
pub const GossipBlockPayload = MsgBlockAnnounce;

// ─── SPV Header Sync Protocol ───────────────────────────────────────────────
//
// Wire format for getheaders_p2p:
//   [start_height: u32LE][count: u32LE]    = 8 bytes
//
// Wire format for headers_p2p:
//   [count: u32LE] [header0: 124 bytes] [header1: 124 bytes] ...
//   Per header (124 bytes):
//     [index: u64LE][timestamp: i64LE][prev_hash: 32][merkle_root: 32]
//     [hash: 32][difficulty: u32LE][nonce: u64LE]
//
// Wire format for getmerkleproof_p2p:
//   [tx_hash: 32 bytes][block_index: u32LE]    = 36 bytes
//
// Wire format for merkleproof_p2p:
//   [tx_hash: 32][merkle_root: 32][block_index: u32LE][tx_index: u32LE]
//   [depth: u8][proof_hashes: depth*32][directions: depth bytes (0/1)]
//
// Wire format for filterload:
//   [num_hash_funcs: u8][bits: 512 bytes]    = 513 bytes

/// Size of one serialized SPV header on the wire
pub const SPV_HEADER_SIZE: usize = 124;

/// Max headers per batch
pub const SPV_MAX_HEADERS_PER_MSG: u32 = 2000;

/// Encode a getheaders_p2p request payload
pub fn encodeGetHeaders(start_height: u32, count: u32, buf: *[8]u8) void {
    std.mem.writeInt(u32, buf[0..4], start_height, .little);
    std.mem.writeInt(u32, buf[4..8], count, .little);
}

/// Decode a getheaders_p2p request payload
pub fn decodeGetHeaders(data: []const u8) ?struct { start_height: u32, count: u32 } {
    if (data.len < 8) return null;
    return .{
        .start_height = std.mem.readInt(u32, data[0..4], .little),
        .count = std.mem.readInt(u32, data[4..8], .little),
    };
}

/// Serialize a light_client BlockHeader into the 120-byte wire format.
/// Fields: index(8) + timestamp(8) + prev_hash(32) + merkle_root(32) + hash(32) + difficulty(4) + nonce(8) = 120
pub fn serializeSpvHeader(header: *const light_client_mod.BlockHeader, buf: *[SPV_HEADER_SIZE]u8) void {
    var off: usize = 0;
    std.mem.writeInt(u64, buf[off..][0..8], @as(u64, header.index), .little);
    off += 8;
    std.mem.writeInt(i64, buf[off..][0..8], header.timestamp, .little);
    off += 8;
    @memcpy(buf[off .. off + 32], &header.previous_hash);
    off += 32;
    @memcpy(buf[off .. off + 32], &header.merkle_root);
    off += 32;
    @memcpy(buf[off .. off + 32], &header.hash);
    off += 32;
    std.mem.writeInt(u32, buf[off..][0..4], header.difficulty, .little);
    off += 4;
    std.mem.writeInt(u64, buf[off..][0..8], header.nonce, .little);
}

/// Deserialize a 120-byte wire header into a light_client BlockHeader.
pub fn deserializeSpvHeader(data: *const [SPV_HEADER_SIZE]u8) light_client_mod.BlockHeader {
    var header = light_client_mod.BlockHeader.init(0);
    var off: usize = 0;

    header.index = @intCast(std.mem.readInt(u64, data[off..][0..8], .little));
    off += 8;
    header.timestamp = std.mem.readInt(i64, data[off..][0..8], .little);
    off += 8;
    @memcpy(&header.previous_hash, data[off .. off + 32]);
    off += 32;
    @memcpy(&header.merkle_root, data[off .. off + 32]);
    off += 32;
    @memcpy(&header.hash, data[off .. off + 32]);
    off += 32;
    header.difficulty = std.mem.readInt(u32, data[off..][0..4], .little);
    off += 4;
    header.nonce = std.mem.readInt(u64, data[off..][0..8], .little);

    return header;
}

/// Encode a headers_p2p response: [count:u32LE][header0:120]...[headerN:120]
pub fn encodeHeadersBatch(
    headers: []const light_client_mod.BlockHeader,
    allocator: std.mem.Allocator,
) ![]u8 {
    const count: u32 = @intCast(@min(headers.len, SPV_MAX_HEADERS_PER_MSG));
    const total = 4 + @as(usize, count) * SPV_HEADER_SIZE;
    var buf = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, buf[0..4], count, .little);
    for (0..count) |i| {
        const off = 4 + i * SPV_HEADER_SIZE;
        serializeSpvHeader(&headers[i], buf[off..][0..SPV_HEADER_SIZE]);
    }
    return buf;
}

/// Decode a headers_p2p response into a slice of BlockHeaders.
/// Caller must free the returned slice with allocator.free().
pub fn decodeHeadersBatch(
    data: []const u8,
    allocator: std.mem.Allocator,
) ![]light_client_mod.BlockHeader {
    if (data.len < 4) return error.InvalidPayload;
    const count: usize = std.mem.readInt(u32, data[0..4], .little);
    if (count > SPV_MAX_HEADERS_PER_MSG) return error.TooManyHeaders;
    if (data.len < 4 + count * SPV_HEADER_SIZE) return error.InvalidPayload;
    var headers = try allocator.alloc(light_client_mod.BlockHeader, count);
    for (0..count) |i| {
        const off = 4 + i * SPV_HEADER_SIZE;
        headers[i] = deserializeSpvHeader(data[off..][0..SPV_HEADER_SIZE]);
    }
    return headers;
}

/// Encode a filterload payload: [num_hash_funcs:u8][bits:512]
pub fn encodeBloomFilter(filter: *const light_client_mod.BloomFilter, buf: *[513]u8) void {
    buf[0] = filter.num_hash_funcs;
    @memcpy(buf[1..513], &filter.bits);
}

/// Decode a filterload payload into a BloomFilter.
pub fn decodeBloomFilter(data: []const u8) ?light_client_mod.BloomFilter {
    if (data.len < 513) return null;
    var filter = light_client_mod.BloomFilter.init(data[0]);
    @memcpy(&filter.bits, data[1..513]);
    return filter;
}

// ─── P2P Node — server TCP + lista de conexiuni ───────────────────────────────

/// Rezultatul verificarii knock-knock
pub const KnockResult = enum {
    /// Primul miner pe acest IP — poate mina
    alone,
    /// Alt miner detectat pe acelasi IP — sta IDLE
    duplicate_ip,
    /// Broadcast esuat (firewall, VPN, etc.) — continua cu avertizare
    broadcast_failed,
};

pub const P2PNode = struct {
    local_id:    []const u8,
    local_host:  []const u8,
    local_port:  u16,
    peers:       array_list.Managed(PeerConnection),
    allocator:   std.mem.Allocator,
    chain_height: u64,
    /// true daca un alt miner a fost detectat pe acelasi IP — nu minaza
    is_idle:     bool,
    /// Pointer la blockchain — setat via attachBlockchain() dupa init
    blockchain:  ?*Blockchain = null,
    /// Pointer la sync manager — setat via attachBlockchain()
    sync_mgr:    ?*SyncManager = null,
    /// Pointer la light client — setat via attachLightClient() for SPV mode
    light_client: ?*light_client_mod.LightClient = null,
    /// Gossip deduplication — recently seen TX hashes
    seen_tx_hashes: SeenHashes = SeenHashes.init(),
    /// Gossip deduplication — recently seen block hashes
    seen_block_hashes: SeenHashes = SeenHashes.init(),
    /// Gossip stats — total TX relayed
    gossip_tx_count: u64 = 0,
    /// Gossip stats — total blocks relayed
    gossip_block_count: u64 = 0,
    // ── P2P Hardening fields ──────────────────────────────────────────────
    /// Peer scoring engine for ban management
    scoring_engine: scoring_mod.PeerScoringEngine = scoring_mod.PeerScoringEngine.init(),
    /// Banned peers list (host:port level)
    banned_peers: [MAX_BANNED_PEERS]BannedPeer = undefined,
    banned_count: u16 = 0,
    /// Pending reconnect entries
    reconnect_queue: [MAX_PEERS]ReconnectInfo = undefined,
    reconnect_count: u16 = 0,
    /// Connection counters
    inbound_count: u16 = 0,
    outbound_count: u16 = 0,
    /// Initialized flag for banned_peers array
    hardening_init: bool = false,
    /// Tor proxy configuration (disabled by default)
    tor_config: tor_mod.TorConfig = tor_mod.TorConfig.default(),

    pub fn init(
        local_id:   []const u8,
        local_host: []const u8,
        local_port: u16,
        allocator:  std.mem.Allocator,
    ) P2PNode {
        var node: P2PNode = .{
            .local_id    = local_id,
            .local_host  = local_host,
            .local_port  = local_port,
            .peers       = array_list.Managed(PeerConnection).init(allocator),
            .allocator   = allocator,
            .chain_height = 0,
            .is_idle     = false,
            .blockchain  = null,
            .sync_mgr    = null,
            .seen_tx_hashes = SeenHashes.init(),
            .seen_block_hashes = SeenHashes.init(),
            .gossip_tx_count = 0,
            .gossip_block_count = 0,
        };
        // Initialize hardening arrays
        for (&node.banned_peers) |*bp| bp.active = false;
        for (&node.reconnect_queue) |*ri| ri.active = false;
        node.hardening_init = true;
        return node;
    }

    /// Ataseaza blockchain si sync_mgr — apelat din main dupa init P2PNode
    /// Necesar pentru ca dispatchMessage sa poata aplica blocuri primite
    pub fn attachBlockchain(self: *P2PNode, bc: *Blockchain, sm: *SyncManager) void {
        self.blockchain = bc;
        self.sync_mgr   = sm;
    }

    /// Attach a light client for SPV header sync mode
    pub fn attachLightClient(self: *P2PNode, lc: *light_client_mod.LightClient) void {
        self.light_client = lc;
    }

    /// Enable Tor proxy for all outbound P2P connections
    pub fn enableTor(self: *P2PNode, config: tor_mod.TorConfig) void {
        self.tor_config = config;
        std.debug.print("[P2P] Tor enabled — proxy {s}:{d}\n", .{
            config.proxy_host, config.proxy_port,
        });
    }

    /// Check if a peer address is a .onion hidden service
    pub fn isOnionPeer(host: []const u8) bool {
        return tor_mod.isOnionAddress(host);
    }

    /// SPV: Send getheaders_p2p to all connected peers.
    /// Requests headers starting from our current header chain height.
    pub fn syncHeaders(self: *P2PNode) void {
        const lc = self.light_client orelse return;
        const start_height = lc.getHeight();
        const count: u32 = @intCast(@min(SPV_MAX_HEADERS_PER_MSG, 500));

        var payload: [8]u8 = undefined;
        encodeGetHeaders(start_height, count, &payload);

        var sent: usize = 0;
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            peer.send(@intFromEnum(MessageType.getheaders_p2p), &payload) catch |err| {
                std.debug.print("[SPV] getheaders_p2p send to {s} failed: {}\n",
                    .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
                continue;
            };
            sent += 1;
        }
        if (sent > 0) {
            std.debug.print("[SPV] getheaders_p2p sent to {d} peers (from height {d}, max {d})\n",
                .{ sent, start_height, count });
        }
    }

    /// SPV: Request a Merkle proof for a specific TX hash in a specific block.
    pub fn requestMerkleProof(self: *P2PNode, tx_hash: [32]u8, block_index: u32) void {
        var payload: [36]u8 = undefined;
        @memcpy(payload[0..32], &tx_hash);
        std.mem.writeInt(u32, payload[32..36], block_index, .little);

        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            peer.send(@intFromEnum(MessageType.getmerkleproof_p2p), &payload) catch continue;
            std.debug.print("[SPV] getmerkleproof_p2p sent to {s}\n",
                .{peer.node_id[0..@min(peer.node_id.len, 16)]});
            return; // send to first available peer
        }
    }

    /// SPV: Send our Bloom filter to all connected peers (filterload).
    pub fn sendBloomFilter(self: *P2PNode) void {
        const lc = self.light_client orelse return;
        var payload: [513]u8 = undefined;
        encodeBloomFilter(&lc.bloom, &payload);

        var sent: usize = 0;
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            peer.send(@intFromEnum(MessageType.filterload), &payload) catch continue;
            sent += 1;
        }
        if (sent > 0) {
            std.debug.print("[SPV] Bloom filter sent to {d} peers\n", .{sent});
        }
    }

    pub fn deinit(self: *P2PNode) void {
        for (self.peers.items) |*peer| peer.close();
        self.peers.deinit();
    }

    /// Conecteaza la un peer (TCP outbound)
    pub fn connectToPeer(self: *P2PNode, host: []const u8, port: u16, node_id: []const u8) !void {
        // Evita duplicate
        for (self.peers.items) |p| {
            if (std.mem.eql(u8, p.node_id, node_id)) return; // deja conectat
        }

        // ── Hardening: check ban list ────────────────────────────────────
        if (self.isBanned(host, port)) {
            std.debug.print("[P2P] Rejected banned peer {s}:{d}\n", .{ host, port });
            return error.PeerBanned;
        }

        // ── Hardening: connection limits ─────────────────────────────────
        if (self.outbound_count >= MAX_OUTBOUND) {
            std.debug.print("[P2P] Outbound limit reached ({d}/{d})\n",
                .{ self.outbound_count, MAX_OUTBOUND });
            return error.TooManyOutbound;
        }
        if (self.peers.items.len >= MAX_PEERS) {
            std.debug.print("[P2P] Total peer limit reached ({d}/{d})\n",
                .{ self.peers.items.len, MAX_PEERS });
            return error.TooManyPeers;
        }

        const addr = try std.net.Address.parseIp4(host, port);

        // ── Hardening: subnet diversity (anti-eclipse) ───────────────────
        const ip_bytes = std.mem.toBytes(addr.in.sa.addr);
        const ip4 = [4]u8{ ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] };
        if (!self.checkSubnetDiversity(ip4)) {
            std.debug.print("[P2P] Subnet limit reached for {d}.{d}.x.x — rejected\n",
                .{ ip4[0], ip4[1] });
            return error.SubnetLimitReached;
        }

        const stream = std.net.tcpConnectToAddress(addr) catch |err| {
            std.debug.print("[P2P] Connect failed to {s}:{d}: {}\n", .{ host, port, err });
            return err;
        };

        const conn = PeerConnection{
            .stream    = stream,
            .node_id   = node_id,
            .host      = host,
            .port      = port,
            .height    = 0,
            .connected = true,
            .allocator = self.allocator,
            .direction = .outbound,
            .ip_bytes  = ip4,
        };

        try self.peers.append(conn);
        self.outbound_count += 1;
        std.debug.print("[P2P] Connected to peer {s} ({s}:{d})\n", .{ node_id, host, port });

        // On successful connect, clear any reconnect entry
        self.clearReconnect(host, port);

        // Trimite PING imediat
        const last_idx = self.peers.items.len - 1;
        self.peers.items[last_idx].sendPing(self.local_id, self.chain_height) catch |err| {
            std.debug.print("[P2P] Ping failed: {}\n", .{err});
        };
    }

    /// Anunta un bloc nou la toti peerii conectati
    pub fn broadcastBlock(
        self:       *P2PNode,
        height:     u64,
        hash_hex:   []const u8,
        reward_sat: u64,
    ) void {
        self.chain_height = height;
        for (self.peers.items) |*peer| {
            peer.announceBlock(height, hash_hex, self.local_id, reward_sat) catch |err| {
                std.debug.print("[P2P] Broadcast block to {s} failed: {}\n", .{ peer.node_id, err });
            };
        }
        if (self.peers.items.len > 0) {
            std.debug.print("[P2P] Block #{d} anuntat la {d} peeri\n",
                .{ height, self.peers.items.len });
        }
    }

    // ─── Gossip Protocol (B6) ────────────────────────────────────────────────

    /// Broadcast a TX to all connected peers via gossip.
    /// Deduplicates: if we already saw this TX hash, skip.
    /// tx_hash: hex hash of the transaction (64 chars)
    /// tx_json: JSON-encoded transaction payload
    pub fn broadcastTx(self: *P2PNode, tx_hash: []const u8, tx_json: []const u8) void {
        // Dedup: skip if already seen
        if (!self.seen_tx_hashes.insert(tx_hash)) {
            return; // already relayed
        }
        self.gossip_tx_count += 1;

        // Encode gossip TX payload
        const payload = (GossipTxPayload{
            .tx_hash = tx_hash,
            .tx_json = tx_json,
        }).encode(self.allocator) catch |err| {
            std.debug.print("[GOSSIP] TX encode failed: {}\n", .{err});
            return;
        };
        defer self.allocator.free(payload);

        var sent: usize = 0;
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            peer.send(@intFromEnum(MessageType.tx_gossip), payload) catch |err| {
                std.debug.print("[GOSSIP] TX send to {s} failed: {}\n",
                    .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
                continue;
            };
            sent += 1;
        }
        if (sent > 0) {
            std.debug.print("[GOSSIP] TX {s}.. relayed to {d} peers\n",
                .{ tx_hash[0..@min(tx_hash.len, 12)], sent });
        }
    }

    /// Broadcast a newly mined/received block to all peers via gossip.
    /// Deduplicates: if we already saw this block hash, skip.
    /// Uses the block_gossip message type for gossip-aware relay.
    pub fn broadcastBlockGossip(
        self:       *P2PNode,
        height:     u64,
        hash_hex:   []const u8,
        reward_sat: u64,
    ) void {
        // Dedup: skip if already seen
        if (!self.seen_block_hashes.insert(hash_hex)) {
            return; // already relayed
        }
        self.gossip_block_count += 1;
        self.chain_height = height;

        // Use MsgBlockAnnounce as gossip payload
        var bh: [32]u8 = @splat(0);
        var mi: [32]u8 = @splat(0);
        const hlen = @min(hash_hex.len, 32);
        const mlen = @min(self.local_id.len, 32);
        @memcpy(bh[0..hlen], hash_hex[0..hlen]);
        @memcpy(mi[0..mlen], self.local_id[0..mlen]);

        const ann = MsgBlockAnnounce{
            .block_height = height,
            .block_hash   = bh,
            .miner_id     = mi,
            .reward_sat   = reward_sat,
        };
        const payload = ann.encode(self.allocator) catch |err| {
            std.debug.print("[GOSSIP] Block encode failed: {}\n", .{err});
            return;
        };
        defer self.allocator.free(payload);

        var sent: usize = 0;
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            peer.send(@intFromEnum(MessageType.block_gossip), payload) catch |err| {
                std.debug.print("[GOSSIP] Block send to {s} failed: {}\n",
                    .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
                continue;
            };
            sent += 1;
        }
        if (sent > 0) {
            std.debug.print("[GOSSIP] Block #{d} relayed to {d} peers\n", .{ height, sent });
        }
    }

    /// Relay a received TX to all peers except the sender.
    /// Called from dispatchMessage when we receive a tx_gossip message.
    fn relayTxExcept(self: *P2PNode, except_peer: []const u8, payload: []const u8) void {
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            // Don't relay back to sender
            if (std.mem.eql(u8, peer.node_id, except_peer)) continue;
            peer.send(@intFromEnum(MessageType.tx_gossip), payload) catch {};
        }
    }

    /// Relay a received block to all peers except the sender.
    fn relayBlockExcept(self: *P2PNode, except_peer: []const u8, payload: []const u8) void {
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            if (std.mem.eql(u8, peer.node_id, except_peer)) continue;
            peer.send(@intFromEnum(MessageType.block_gossip), payload) catch {};
        }
    }

    /// Periodic maintenance: evict expired seen hashes
    pub fn gossipMaintenance(self: *P2PNode) void {
        self.seen_tx_hashes.evictExpired();
        self.seen_block_hashes.evictExpired();
    }

    /// Returns gossip statistics for logging
    pub fn getGossipStats(self: *const P2PNode) struct { tx_relayed: u64, blocks_relayed: u64, seen_tx: usize, seen_blocks: usize } {
        return .{
            .tx_relayed = self.gossip_tx_count,
            .blocks_relayed = self.gossip_block_count,
            .seen_tx = self.seen_tx_hashes.count,
            .seen_blocks = self.seen_block_hashes.count,
        };
    }

    // ─── PEX Protocol (B12) ────────────────────────────────────────────────

    /// Send a get_peers request to a specific peer
    pub fn sendGetPeers(_: *P2PNode, peer: *PeerConnection) void {
        peer.send(@intFromEnum(MessageType.get_peers), &.{}) catch |err| {
            std.debug.print("[PEX] get_peers send failed to {s}: {}\n",
                .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
        };
    }

    /// Send get_peers to all connected peers
    pub fn requestPeersFromAll(self: *P2PNode) void {
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            self.sendGetPeers(peer);
        }
    }

    /// Build a peer_list payload from our known connected peers
    /// Returns encoded bytes; caller must free with allocator.
    pub fn buildPeerListPayload(self: *P2PNode) ![]u8 {
        // Collect connected peers as PeerAddr entries
        var addrs: [PEX_MAX_PEERS]MsgPeerList.PeerAddr = undefined;
        var count: usize = 0;
        for (self.peers.items) |p| {
            if (!p.connected) continue;
            if (count >= PEX_MAX_PEERS) break;
            // Parse host IP string to 4 bytes
            const addr = std.net.Address.parseIp4(p.host, p.port) catch continue;
            const ip_bytes = addr.in.sa.addr;
            const ip_raw = std.mem.toBytes(ip_bytes);
            addrs[count] = .{
                .ip = .{ ip_raw[0], ip_raw[1], ip_raw[2], ip_raw[3] },
                .port = p.port,
            };
            count += 1;
        }
        return encodePeerList(addrs[0..count], self.allocator);
    }

    /// Shim pentru network.zig broadcast_fn — evita import circular
    fn broadcastShim(node_ptr: *anyopaque, height: u64, message: []const u8, reward_sat: u64) void {
        const self: *P2PNode = @alignCast(@ptrCast(node_ptr));
        self.broadcastBlock(height, message, reward_sat);
    }

    /// Ataseaza acest P2PNode la un P2PNetwork — de apelat din main.zig dupa init
    pub fn attachToNetwork(self: *P2PNode, net: *network_mod.P2PNetwork) void {
        net.attachP2PNode(@ptrCast(self), &broadcastShim);
    }

    /// Numarul de peeri conectati
    pub fn peerCount(self: *const P2PNode) usize {
        var count: usize = 0;
        for (self.peers.items) |p| {
            if (p.connected) count += 1;
        }
        return count;
    }

    /// Deconecteaza peerii morti — adauga la reconnect queue in loc de stergere directa
    pub fn cleanDeadPeers(self: *P2PNode) void {
        var i: usize = 0;
        while (i < self.peers.items.len) {
            if (!self.peers.items[i].connected) {
                const peer = &self.peers.items[i];
                // Track direction for counter update
                if (peer.direction == .inbound) {
                    if (self.inbound_count > 0) self.inbound_count -= 1;
                } else {
                    if (self.outbound_count > 0) self.outbound_count -= 1;
                }
                // Add to reconnect queue (outbound only)
                if (peer.direction == .outbound) {
                    self.addReconnect(peer.host, peer.port, peer.node_id);
                }
                peer.close();
                _ = self.peers.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Knock Knock — anunta reteaua + verifica daca exista duplicat pe acelasi IP
    ///
    /// Pasi:
    ///   1. Trimite UDP broadcast "OMNI:we are here:<node_id>:<height>" pe 3 porturi
    ///   2. Asculta 3 secunde raspunsuri UDP pe portul principal
    ///   3. Daca primeste acelasi mesaj de pe acelasi IP → seteaza is_idle = true
    ///   4. VPN/Tor: daca IP-ul sursa e acelasi cu al nostru (loopback sau LAN) → idle
    ///
    /// Returneaza KnockResult pentru logging in main
    pub fn knockKnock(self: *P2PNode) KnockResult {
        // ── 1. Construieste mesajul ───────────────────────────────────────────
        var msg_buf: [256]u8 = undefined;
        const id_short = self.local_id[0..@min(32, self.local_id.len)];
        const msg = std.fmt.bufPrint(&msg_buf,
            "OMNI:we are here:{s}:{d}",
            .{ id_short, self.chain_height },
        ) catch return .broadcast_failed;

        const knock_ports = [3]u16{
            P2P_PORT_DEFAULT,
            P2P_PORT_DEFAULT + 1,
            P2P_PORT_DEFAULT + 2,
        };

        // ── 2. Trimite broadcast pe toate cele 3 porturi ──────────────────────
        var sent: u8 = 0;
        for (knock_ports) |port| {
            knockUDP(msg, port) catch continue;
            sent += 1;
        }
        if (sent == 0) {
            std.debug.print("[KNOCK] Broadcast failed pe toate porturile\n", .{});
            return .broadcast_failed;
        }
        std.debug.print("[KNOCK] >> \"{s}\" → broadcast:{d}/{d}/{d}\n", .{
            msg[0..@min(48, msg.len)],
            knock_ports[0], knock_ports[1], knock_ports[2],
        });

        // ── 3. Asculta 3 secunde pe portul principal ──────────────────────────
        const listen_result = listenKnockUDP(
            self.local_id,
            knock_ports[0],
            3_000, // ms
        );

        switch (listen_result) {
            .alone => {
                std.debug.print("[KNOCK] OK — singur pe retea, mining activ\n", .{});
                self.is_idle = false;
                return .alone;
            },
            .duplicate_ip => |ip| {
                std.debug.print(
                    "[KNOCK] !! DUPLICAT detectat — alt miner pe {d}.{d}.{d}.{d}\n",
                    .{ ip[0], ip[1], ip[2], ip[3] },
                );
                std.debug.print(
                    "[KNOCK] Acest nod intra in modul IDLE — nu minaza, nu primeste reward\n",
                    .{},
                );
                std.debug.print(
                    "[KNOCK] Daca folosesti VPN/Tor cu acelasi IP extern — acelasi rezultat\n",
                    .{},
                );
                self.is_idle = true;
                return .duplicate_ip;
            },
            .broadcast_failed => {
                std.debug.print("[KNOCK] Listen timeout/error — continuam (best-effort)\n", .{});
                return .broadcast_failed;
            },
        }
    }

    // ─── Hardening: Ban Management ─────────────────────────────────────────

    /// Check if a host:port is currently banned
    pub fn isBanned(self: *const P2PNode, host: []const u8, port: u16) bool {
        for (&self.banned_peers) |*bp| {
            if (!bp.active) continue;
            if (bp.matchesHost(host, port)) {
                return !bp.isExpired();
            }
        }
        return false;
    }

    /// Ban a peer by host:port for the configured duration
    pub fn banPeer(self: *P2PNode, host: []const u8, port: u16, reason: []const u8) void {
        // Check if already banned — update expiry
        for (&self.banned_peers) |*bp| {
            if (bp.active and bp.matchesHost(host, port)) {
                bp.banned_until = std.time.timestamp() + scoring_mod.BAN_DURATION_SEC;
                @memcpy(bp.reason[0..@min(reason.len, 64)], reason[0..@min(reason.len, 64)]);
                bp.reason_len = @intCast(@min(reason.len, 64));
                return;
            }
        }
        // Find empty slot or oldest entry
        var slot: usize = 0;
        var found_empty = false;
        var oldest_time: i64 = std.math.maxInt(i64);
        for (&self.banned_peers, 0..) |*bp, i| {
            if (!bp.active) {
                slot = i;
                found_empty = true;
                break;
            }
            if (bp.banned_until < oldest_time) {
                oldest_time = bp.banned_until;
                slot = i;
            }
        }
        self.banned_peers[slot] = BannedPeer.init(host, port, scoring_mod.BAN_DURATION_SEC, reason);
        if (!found_empty) {
            // Overwritten an existing entry
        } else {
            if (self.banned_count < MAX_BANNED_PEERS) self.banned_count += 1;
        }
        std.debug.print("[P2P] Banned {s}:{d} reason: {s}\n", .{ host, port, reason });

        // Disconnect the peer if currently connected
        self.disconnectPeerByHost(host, port);
    }

    /// Disconnect a peer by host:port
    fn disconnectPeerByHost(self: *P2PNode, host: []const u8, port: u16) void {
        for (self.peers.items) |*peer| {
            if (peer.connected and peer.port == port and std.mem.eql(u8, peer.host, host)) {
                peer.connected = false;
                peer.close();
                return;
            }
        }
    }

    /// Evict expired bans
    pub fn evictExpiredBans(self: *P2PNode) void {
        for (&self.banned_peers) |*bp| {
            if (bp.active and bp.isExpired()) {
                bp.active = false;
                if (self.banned_count > 0) self.banned_count -= 1;
            }
        }
    }

    /// Score a peer event and auto-ban if threshold reached
    pub fn scorePeer(self: *P2PNode, peer: *PeerConnection, event: scoring_mod.ScoreEvent) void {
        // Build a 16-byte peer_id hash for the scoring engine
        var peer_id: [16]u8 = @splat(0);
        const id_len = @min(peer.node_id.len, 16);
        @memcpy(peer_id[0..id_len], peer.node_id[0..id_len]);

        const was_banned = self.scoring_engine.isAllowed(peer_id);
        self.scoring_engine.scoreEvent(peer_id, event);
        const now_allowed = self.scoring_engine.isAllowed(peer_id);

        // If peer just got banned, add to host-level ban list
        if (was_banned and !now_allowed) {
            self.banPeer(peer.host, peer.port, "scoring threshold exceeded");
        }
    }

    // ─── Hardening: Rate Limiting ───────────────────────────────────────────

    /// Check rate limit for a peer. Returns true if within limits.
    /// If exceeded, adds ban score and returns false.
    pub fn checkRateLimit(self: *P2PNode, peer: *PeerConnection, msg_size: usize) bool {
        if (peer.rate_limit.recordMessage(msg_size)) {
            return true;
        }
        // Rate limit exceeded
        self.scorePeer(peer, .malformed_data); // +20 ban score for rate limit violation
        std.debug.print("[P2P] Rate limit exceeded by {s} ({d} msgs, {d} bytes)\n",
            .{ peer.node_id[0..@min(peer.node_id.len, 16)],
               peer.rate_limit.msg_count, peer.rate_limit.byte_count });
        return false;
    }

    // ─── Hardening: Reconnect Management ────────────────────────────────────

    /// Add a disconnected peer to the reconnect queue
    fn addReconnect(self: *P2PNode, host: []const u8, port: u16, node_id: []const u8) void {
        // Check if already in queue — increment attempts
        for (&self.reconnect_queue) |*ri| {
            if (!ri.active) continue;
            if (ri.port == port and ri.host_len == host.len and
                std.mem.eql(u8, ri.host[0..ri.host_len], host))
            {
                ri.attempts += 1;
                ri.last_disconnect = std.time.timestamp();
                if (ri.attempts >= MAX_RECONNECT_ATTEMPTS) {
                    std.debug.print("[P2P] Reconnect limit reached for {s}:{d} — removing\n",
                        .{ host, port });
                    ri.active = false;
                    if (self.reconnect_count > 0) self.reconnect_count -= 1;
                }
                return;
            }
        }
        // Add new entry
        if (self.reconnect_count >= MAX_PEERS) return;
        for (&self.reconnect_queue) |*ri| {
            if (!ri.active) {
                ri.* = ReconnectInfo.init(host, port, node_id);
                self.reconnect_count += 1;
                return;
            }
        }
    }

    /// Clear reconnect entry on successful connection
    fn clearReconnect(self: *P2PNode, host: []const u8, port: u16) void {
        for (&self.reconnect_queue) |*ri| {
            if (!ri.active) continue;
            if (ri.port == port and ri.host_len == host.len and
                std.mem.eql(u8, ri.host[0..ri.host_len], host))
            {
                ri.active = false;
                if (self.reconnect_count > 0) self.reconnect_count -= 1;
                return;
            }
        }
    }

    /// Process reconnect queue — attempt reconnects for peers past the delay
    pub fn processReconnects(self: *P2PNode) void {
        const now = std.time.timestamp();
        for (&self.reconnect_queue) |*ri| {
            if (!ri.active) continue;
            if (ri.attempts >= MAX_RECONNECT_ATTEMPTS) {
                ri.active = false;
                if (self.reconnect_count > 0) self.reconnect_count -= 1;
                continue;
            }
            if (now - ri.last_disconnect < RECONNECT_DELAY_SEC) continue;

            // Attempt reconnect
            const host = ri.host[0..ri.host_len];
            const node_id = ri.node_id[0..ri.node_id_len];
            std.debug.print("[P2P] Reconnect attempt {d}/{d} to {s}:{d}\n",
                .{ ri.attempts + 1, MAX_RECONNECT_ATTEMPTS, host, ri.port });

            self.connectToPeer(host, ri.port, node_id) catch {
                ri.attempts += 1;
                ri.last_disconnect = now;
                if (ri.attempts >= MAX_RECONNECT_ATTEMPTS) {
                    std.debug.print("[P2P] Reconnect failed permanently for {s}:{d}\n",
                        .{ host, ri.port });
                    ri.active = false;
                    if (self.reconnect_count > 0) self.reconnect_count -= 1;
                }
                continue;
            };
            // Success — clearReconnect is called inside connectToPeer
        }
    }

    // ─── Hardening: Subnet Diversity (Anti-Eclipse) ─────────────────────────

    /// Check if adding a peer with this IP would violate subnet diversity rules.
    /// Returns true if the peer is allowed, false if too many from same /16 subnet.
    pub fn checkSubnetDiversity(self: *const P2PNode, ip: [4]u8) bool {
        var same_subnet: usize = 0;
        for (self.peers.items) |p| {
            if (!p.connected) continue;
            if (p.ip_bytes[0] == ip[0] and p.ip_bytes[1] == ip[1]) {
                same_subnet += 1;
            }
        }
        return same_subnet < MAX_PEERS_PER_SUBNET;
    }

    /// Count the number of distinct /16 subnets among connected peers
    pub fn subnetCount(self: *const P2PNode) usize {
        // Fixed-size tracking (max MAX_PEERS subnets possible)
        var subnets: [MAX_PEERS][2]u8 = undefined;
        var count: usize = 0;
        for (self.peers.items) |p| {
            if (!p.connected) continue;
            const sn = [2]u8{ p.ip_bytes[0], p.ip_bytes[1] };
            var found = false;
            for (subnets[0..count]) |existing| {
                if (existing[0] == sn[0] and existing[1] == sn[1]) {
                    found = true;
                    break;
                }
            }
            if (!found and count < MAX_PEERS) {
                subnets[count] = sn;
                count += 1;
            }
        }
        return count;
    }

    /// Check if we have enough subnet diversity (at least MIN_SUBNET_DIVERSITY)
    pub fn hasMinSubnetDiversity(self: *const P2PNode) bool {
        // If fewer peers than minimum, don't enforce yet
        if (self.peerCount() < MIN_SUBNET_DIVERSITY) return true;
        return self.subnetCount() >= MIN_SUBNET_DIVERSITY;
    }

    // ─── Hardening: Connection Limits ───────────────────────────────────────

    /// Check if we can accept an inbound connection
    pub fn canAcceptInbound(self: *const P2PNode) bool {
        return self.inbound_count < MAX_INBOUND and self.peers.items.len < MAX_PEERS;
    }

    /// Periodic hardening maintenance
    pub fn hardeningMaintenance(self: *P2PNode) void {
        self.evictExpiredBans();
        self.processReconnects();
        self.gossipMaintenance();
    }

    pub fn printStatus(self: *const P2PNode) void {
        std.debug.print("[P2P] Node={s} | Peers={d} (in:{d}/out:{d}) | Height={d} | Port={d} | Idle={} | Banned={d} | Reconnect={d}\n", .{
            self.local_id, self.peerCount(),
            self.inbound_count, self.outbound_count,
            self.chain_height,
            self.local_port, self.is_idle,
            self.banned_count, self.reconnect_count,
        });
    }

    // ─── TCP Listener ─────────────────────────────────────────────────────────

    /// Porneste server TCP inbound pe `local_port` — thread detached.
    /// Fiecare peer inbound primeste propriul thread handler.
    /// Returneaza error daca bind/listen esueaza (port ocupat, permisiuni etc.)
    pub fn startListener(self: *P2PNode) !void {
        const addr = try std.net.Address.parseIp4(self.local_host, self.local_port);
        const server = try addr.listen(.{ .reuse_address = true });

        std.debug.print("[P2P] Listener pornit pe {s}:{d}\n", .{ self.local_host, self.local_port });

        // Pasam server-ul + node ptr la thread prin heapAllocator
        const AcceptArgs = struct { server: std.net.Server, node: *P2PNode };
        const aargs = try self.allocator.create(AcceptArgs);
        aargs.* = .{ .server = server, .node = self };

        const t = try std.Thread.spawn(.{}, acceptLoop, .{aargs});
        t.detach();
    }

    fn acceptLoop(args: anytype) void {
        var server = args.server;
        const node  = args.node;
        defer node.allocator.destroy(args);

        while (true) {
            const conn = server.accept() catch |err| {
                std.debug.print("[P2P] Accept error: {}\n", .{err});
                std.Thread.sleep(1 * std.time.ns_per_s);
                continue;
            };

            // ── Hardening: check inbound limits ──────────────────────────
            if (!node.canAcceptInbound()) {
                std.debug.print("[P2P] Inbound limit reached — rejecting connection\n", .{});
                conn.stream.close();
                continue;
            }

            std.debug.print("[P2P] Inbound connection de la {any}\n", .{conn.address});

            // Aloca context peer inbound
            const PeerArgs = struct { conn: std.net.Server.Connection, node: *P2PNode };
            const pargs = node.allocator.create(PeerArgs) catch continue;
            pargs.* = .{ .conn = conn, .node = node };

            const pt = std.Thread.spawn(.{}, handleInboundPeer, .{pargs}) catch |err| {
                std.debug.print("[P2P] Thread spawn error: {}\n", .{err});
                node.allocator.destroy(pargs);
                conn.stream.close();
                continue;
            };
            pt.detach();
        }
    }

    fn handleInboundPeer(args: anytype) void {
        const conn = args.conn;
        const node = args.node;
        defer node.allocator.destroy(args);
        defer conn.stream.close();

        // Track inbound connection
        node.inbound_count += 1;
        defer {
            if (node.inbound_count > 0) node.inbound_count -= 1;
        }

        // Genereaza un peer_id temporar din adresa IP
        var id_buf: [32]u8 = undefined;
        const peer_id = std.fmt.bufPrint(&id_buf, "inbound-{any}", .{conn.address})
            catch "inbound-unknown";

        var peer = PeerConnection{
            .stream    = conn.stream,
            .node_id   = peer_id,
            .host      = "?",
            .port      = 0,
            .height    = 0,
            .connected = true,
            .allocator = node.allocator,
            .direction = .inbound,
        };

        std.debug.print("[P2P] Handler pornit pentru {s}\n", .{peer_id[0..@min(peer_id.len, 24)]});

        // Trimite PING imediat dupa accept
        peer.sendPing(node.local_id, node.chain_height) catch {};

        // Loop citire mesaje
        while (peer.connected) {
            const msg = peer.recv() catch |err| {
                if (err != error.ConnectionClosed) {
                    std.debug.print("[P2P] Recv error ({s}): {}\n", .{ peer_id[0..@min(peer_id.len, 16)], err });
                }
                break;
            };
            defer node.allocator.free(msg.payload);

            dispatchMessage(node, &peer, msg.msg_type, msg.payload);
        }

        std.debug.print("[P2P] Peer {s} deconectat\n", .{peer_id[0..@min(peer_id.len, 24)]});
    }

    /// Proceseaza un mesaj primit de la un peer (inbound sau outbound)
    fn dispatchMessage(node: *P2PNode, peer: *PeerConnection, msg_type: u8, payload: []const u8) void {
        const mt: MessageType = @enumFromInt(msg_type);
        const pid = peer.node_id[0..@min(peer.node_id.len, 16)];
        switch (mt) {
            .ping => {
                if (MsgPing.decode(payload)) |ping| {
                    peer.height = ping.height;
                    std.debug.print("[P2P] PING de la {s} height={d}\n", .{ pid, ping.height });
                    peer.send(@intFromEnum(MessageType.pong), payload) catch {};
                    if (ping.height > node.chain_height) node.chain_height = ping.height;
                    // Daca peer-ul e mai avansat, pornim sync
                    if (node.sync_mgr) |sm| {
                        if (sm.onPeerHeight(ping.height)) |_| {
                            node.requestSync(node.blockchain.?.chain.items.len);
                        }
                    }
                }
            },
            .pong => {
                if (MsgPing.decode(payload)) |pong| {
                    peer.height = pong.height;
                    std.debug.print("[P2P] PONG de la {s} height={d}\n", .{ pid, pong.height });
                    if (pong.height > node.chain_height) node.chain_height = pong.height;
                }
            },
            .block => {
                if (MsgBlockAnnounce.decode(payload)) |ann| {
                    std.debug.print("[P2P] BLOC #{d} anuntat de {s} reward={d} SAT\n",
                        .{ ann.block_height, pid, ann.reward_sat });
                    if (ann.block_height > node.chain_height) {
                        node.chain_height = ann.block_height;
                    }
                    // Daca suntem in urma → cerem blocurile lipsa
                    if (node.blockchain) |bc| {
                        if (ann.block_height > @as(u64, bc.chain.items.len)) {
                            node.requestSync(bc.chain.items.len);
                        }
                    }
                }
            },
            .sync_request => {
                // Peer cere blocuri de la noi — construim raspuns cu headerele noastre
                if (payload.len < 10) return;
                const req = sync_mod.MsgGetHeaders.decode(payload) orelse return;
                std.debug.print("[P2P] SYNC_REQUEST de la {s} from={d} max={d}\n",
                    .{ pid, req.from_height, req.max_count });

                if (node.blockchain) |bc| {
                    if (node.sync_mgr) |sm| {
                        const resp_buf = sm.buildHeadersResponse(bc, req) catch |err| {
                            std.debug.print("[P2P] buildHeadersResponse error: {}\n", .{err});
                            return;
                        };
                        defer node.allocator.free(resp_buf);
                        peer.send(@intFromEnum(MessageType.sync_response), resp_buf) catch {};
                        std.debug.print("[P2P] SYNC_RESPONSE trimis la {s} ({d} bytes)\n",
                            .{ pid, resp_buf.len });
                    }
                } else {
                    // Nu avem blockchain atasat — raspundem cu raspuns gol
                    peer.send(@intFromEnum(MessageType.sync_response), &.{}) catch {};
                }
            },
            .sync_response => {
                // Am primit blocuri de la peer — le aplicam in blockchain
                std.debug.print("[P2P] SYNC_RESPONSE de la {s} ({d} bytes)\n",
                    .{ pid, payload.len });
                if (payload.len < 2) return;

                const blocks_msg = sync_mod.MsgBlocks.decode(payload, node.allocator) catch |err| {
                    std.debug.print("[P2P] MsgBlocks decode error: {}\n", .{err});
                    return;
                };
                defer node.allocator.free(blocks_msg.headers);

                if (blocks_msg.count == 0) {
                    std.debug.print("[P2P] SYNC_RESPONSE gol de la {s} — suntem la zi\n", .{pid});
                    return;
                }

                if (node.blockchain) |bc| {
                    const applied = applyBlocksFromPeer(node, bc, blocks_msg.headers[0..blocks_msg.count]);
                    if (node.sync_mgr) |sm| sm.onBlocksReceived(applied);
                    std.debug.print("[P2P] Aplicat {d}/{d} blocuri de la {s}\n",
                        .{ applied, blocks_msg.count, pid });
                }
            },
            .peer_list => {
                std.debug.print("[PEX] PEER_LIST de la {s} ({d} bytes)\n", .{ pid, payload.len });
                // Decode and log received peers (B12)
                if (payload.len >= 2) {
                    const peers = decodePeerList(payload, node.allocator) catch |err| {
                        std.debug.print("[PEX] decode error: {}\n", .{err});
                        return;
                    };
                    defer node.allocator.free(peers);
                    std.debug.print("[PEX] Received {d} peers from {s}\n", .{ peers.len, pid });
                    for (peers) |pa| {
                        std.debug.print("[PEX]   peer {d}.{d}.{d}.{d}:{d}\n",
                            .{ pa.ip[0], pa.ip[1], pa.ip[2], pa.ip[3], pa.port });
                    }
                    // TODO: try connecting to new peers discovered via PEX
                }
            },
            .get_peers => {
                std.debug.print("[PEX] GET_PEERS de la {s}\n", .{pid});
                // Respond with our known peer list (B12)
                const resp = node.buildPeerListPayload() catch |err| {
                    std.debug.print("[PEX] buildPeerListPayload error: {}\n", .{err});
                    return;
                };
                defer node.allocator.free(resp);
                peer.send(@intFromEnum(MessageType.peer_list), resp) catch |err| {
                    std.debug.print("[PEX] peer_list send failed: {}\n", .{err});
                };
            },
            // ── Gossip Protocol (B6) ─────────────────────────────────────
            .tx_gossip => {
                // Received a gossiped TX from peer
                if (GossipTxPayload.decode(payload)) |gtx| {
                    // Dedup: skip if already seen
                    if (!node.seen_tx_hashes.insert(gtx.tx_hash)) {
                        return; // already processed
                    }
                    node.gossip_tx_count += 1;

                    std.debug.print("[GOSSIP] TX received from {s}: {s}..\n",
                        .{ pid, gtx.tx_hash[0..@min(gtx.tx_hash.len, 12)] });

                    // TODO: deserialize JSON TX → validate → add to mempool
                    // For now, relay to other peers (gossip fan-out)
                    node.relayTxExcept(peer.node_id, payload);
                } else {
                    std.debug.print("[GOSSIP] TX decode failed from {s}\n", .{pid});
                }
            },
            .block_gossip => {
                // Received a gossiped block announcement from peer
                if (MsgBlockAnnounce.decode(payload)) |ann| {
                    // Build hash hex for dedup
                    var hash_hex_buf: [64]u8 = @splat(0);
                    const copy_len = @min(ann.block_hash.len, 32);
                    // Find actual hash length (trim trailing zeros)
                    var actual_len: usize = 32;
                    while (actual_len > 0 and ann.block_hash[actual_len - 1] == 0) actual_len -= 1;
                    @memcpy(hash_hex_buf[0..actual_len], ann.block_hash[0..actual_len]);
                    _ = copy_len;

                    // Dedup: skip if already seen
                    if (!node.seen_block_hashes.insert(hash_hex_buf[0..actual_len])) {
                        return; // already processed
                    }
                    node.gossip_block_count += 1;

                    std.debug.print("[GOSSIP] Block #{d} from {s} reward={d} SAT\n",
                        .{ ann.block_height, pid, ann.reward_sat });

                    // Update chain height if peer is ahead
                    if (ann.block_height > node.chain_height) {
                        node.chain_height = ann.block_height;
                    }

                    // If we're behind, request sync
                    if (node.blockchain) |bc| {
                        if (ann.block_height > @as(u64, bc.chain.items.len)) {
                            node.requestSync(bc.chain.items.len);
                        }
                    }

                    // Relay to other peers (gossip fan-out)
                    node.relayBlockExcept(peer.node_id, payload);
                } else {
                    std.debug.print("[GOSSIP] Block decode failed from {s}\n", .{pid});
                }
            },
            .inv => {
                // Peer announces they have items (hashes) — for future optimization
                std.debug.print("[GOSSIP] INV from {s} ({d} bytes)\n", .{ pid, payload.len });
            },
            .getdata => {
                // Peer requests items by hash — for future optimization
                std.debug.print("[GOSSIP] GETDATA from {s} ({d} bytes)\n", .{ pid, payload.len });
            },
            .getblocks => {
                // Peer asks "what blocks do you have after hash X?"
                // For now, treat as sync_request equivalent
                std.debug.print("[GOSSIP] GETBLOCKS from {s} ({d} bytes)\n", .{ pid, payload.len });
                if (payload.len >= 8) {
                    const from_height = std.mem.readInt(u64, payload[0..8], .little);
                    if (node.blockchain) |bc| {
                        if (node.sync_mgr) |sm| {
                            const req = sync_mod.MsgGetHeaders{
                                .from_height = from_height,
                                .max_count   = 50,
                            };
                            const resp_buf = sm.buildHeadersResponse(bc, req) catch return;
                            defer node.allocator.free(resp_buf);
                            peer.send(@intFromEnum(MessageType.sync_response), resp_buf) catch {};
                        }
                    }
                }
            },
            // ── SPV Light Client Protocol ────────────────────────────────
            .getheaders_p2p => {
                // Peer (light client) requests headers from us (full node)
                const req = decodeGetHeaders(payload) orelse return;
                std.debug.print("[SPV] GETHEADERS from {s} start={d} count={d}\n",
                    .{ pid, req.start_height, req.count });

                if (node.blockchain) |bc| {
                    const chain_len = bc.chain.items.len;
                    const start: usize = @intCast(@min(req.start_height, chain_len));
                    const max_count: usize = @intCast(@min(req.count, SPV_MAX_HEADERS_PER_MSG));
                    const end = @min(start + max_count, chain_len);
                    const actual_count = end - start;

                    if (actual_count == 0) {
                        // No headers to send — empty response
                        var empty: [4]u8 = undefined;
                        std.mem.writeInt(u32, &empty, 0, .little);
                        peer.send(@intFromEnum(MessageType.headers_p2p), &empty) catch {};
                        return;
                    }

                    // Build BlockHeader array from blockchain blocks
                    const resp_size = 4 + actual_count * SPV_HEADER_SIZE;
                    const resp_buf = node.allocator.alloc(u8, resp_size) catch return;
                    defer node.allocator.free(resp_buf);

                    std.mem.writeInt(u32, resp_buf[0..4], @intCast(actual_count), .little);

                    for (start..end) |i| {
                        const blk = &bc.chain.items[i];
                        var hdr_buf: [SPV_HEADER_SIZE]u8 = undefined;
                        // Build a light_client BlockHeader from the full block
                        var lc_header = light_client_mod.BlockHeader.init(@intCast(i));
                        lc_header.timestamp = blk.timestamp;
                        lc_header.nonce = blk.nonce;
                        lc_header.difficulty = 4; // default
                        // Copy hash bytes from hex string (first 32 bytes of hash field)
                        if (blk.hash.len >= 32) {
                            @memcpy(&lc_header.hash, blk.hash[0..32]);
                        }
                        // previous_hash is stored as string in block
                        if (blk.previous_hash.len >= 32) {
                            @memcpy(&lc_header.previous_hash, blk.previous_hash[0..32]);
                        }

                        serializeSpvHeader(&lc_header, &hdr_buf);
                        const off = 4 + (i - start) * SPV_HEADER_SIZE;
                        @memcpy(resp_buf[off .. off + SPV_HEADER_SIZE], &hdr_buf);
                    }

                    peer.send(@intFromEnum(MessageType.headers_p2p), resp_buf) catch |err| {
                        std.debug.print("[SPV] headers_p2p send failed: {}\n", .{err});
                    };
                    std.debug.print("[SPV] Sent {d} headers to {s}\n", .{ actual_count, pid });
                }
            },
            .headers_p2p => {
                // We received headers from a full node — add to our light client chain
                std.debug.print("[SPV] HEADERS from {s} ({d} bytes)\n", .{ pid, payload.len });

                if (node.light_client) |lc| {
                    const headers = decodeHeadersBatch(payload, node.allocator) catch |err| {
                        std.debug.print("[SPV] headers decode error: {}\n", .{err});
                        return;
                    };
                    defer node.allocator.free(headers);

                    var added: u32 = 0;
                    for (headers) |header| {
                        lc.addValidatedHeader(header) catch {
                            // Skip invalid headers (wrong prev_hash, etc.)
                            continue;
                        };
                        added += 1;
                    }
                    std.debug.print("[SPV] Added {d}/{d} validated headers (height now {d})\n",
                        .{ added, headers.len, lc.getHeight() });
                }
            },
            .getmerkleproof_p2p => {
                // Peer requests a Merkle proof for a TX — placeholder (requires TX index)
                if (payload.len < 36) return;
                const block_idx = std.mem.readInt(u32, payload[32..36], .little);
                std.debug.print("[SPV] GETMERKLEPROOF from {s} block={d}\n", .{ pid, block_idx });
                // Full implementation would look up the TX in the block and build a proof.
                // For now, respond with an empty proof (depth 0).
            },
            .merkleproof_p2p => {
                // We received a Merkle proof — verify against our header chain
                std.debug.print("[SPV] MERKLEPROOF from {s} ({d} bytes)\n", .{ pid, payload.len });
                // Full implementation would decode the proof and call verifyMerkleProof.
            },
            .filterload => {
                // Peer sends us their Bloom filter — store for TX filtering
                if (decodeBloomFilter(payload)) |filter| {
                    std.debug.print("[SPV] FILTERLOAD from {s} ({d} hash funcs)\n",
                        .{ pid, filter.num_hash_funcs });
                    // In a full implementation, store per-peer and filter relayed TXs.
                    // For now, just acknowledge receipt.
                } else {
                    std.debug.print("[SPV] FILTERLOAD decode failed from {s}\n", .{pid});
                }
            },
            else => {
                std.debug.print("[P2P] Mesaj necunoscut tip={d} de la {s}\n", .{ msg_type, pid });
            },
        }
    }

    // ─── Sync: aplica blocuri primite de la peer ──────────────────────────────

    /// Aplica o lista de BlockHeader primite de la peer in blockchain-ul local.
    /// Blocurile sunt adaugate in ordine, fara PoW (peer le-a minat deja).
    /// Returneaza numarul de blocuri aplicate cu succes.
    fn applyBlocksFromPeer(
        node:    *P2PNode,
        bc:      *Blockchain,
        headers: []const sync_mod.BlockHeader,
    ) u32 {
        var applied: u32 = 0;

        for (headers) |hdr| {
            const local_len = bc.chain.items.len;

            // Sarim blocurile pe care le avem deja
            if (hdr.height < @as(u64, local_len)) continue;

            // Verificam ca vine in ordine
            if (hdr.height != @as(u64, local_len)) {
                std.debug.print("[SYNC] Gap in blocuri: avem {d}, primit {d} — abandon\n",
                    .{ local_len, hdr.height });
                break;
            }

            // Reconstituim previous_hash din prev_hash[32] ca hex string
            const prev_block = bc.chain.items[local_len - 1];

            // Reconstituim hash-ul blocului din merkle_root (stocat acolo)
            // Aloca hash_hex (64 chars) pe heap — va fi eliberat de bc.deinit
            const hash_hex = node.allocator.alloc(u8, 64) catch break;
            for (0..32) |i| {
                _ = std.fmt.bufPrint(hash_hex[i * 2 .. (i + 1) * 2], "{x:0>2}", .{hdr.merkle_root[i]})
                    catch { node.allocator.free(hash_hex); break; };
            }

            // Aloca miner_address — bloc primit de la peer, nu stim minerul → ""
            const miner_addr = node.allocator.dupe(u8, "") catch {
                node.allocator.free(hash_hex);
                break;
            };

            const new_block = Block{
                .index         = @intCast(hdr.height),
                .timestamp     = hdr.timestamp,
                .transactions  = std.array_list.Managed(block_mod.Transaction).init(node.allocator),
                .previous_hash = prev_block.hash,
                .nonce         = hdr.nonce,
                .hash          = hash_hex,
                .miner_address = miner_addr,
                .reward_sat    = 0,
                .miner_heap    = true, // hash_hex si miner_addr alocate pe heap
            };

            bc.chain.append(new_block) catch {
                node.allocator.free(hash_hex);
                node.allocator.free(miner_addr);
                break;
            };

            applied += 1;
            std.debug.print("[SYNC] Bloc #{d} aplicat (nonce={d})\n", .{ hdr.height, hdr.nonce });
        }

        return applied;
    }

    // ─── Outbound helpers ─────────────────────────────────────────────────────

    /// Trimite un mesaj raw la un peer specific (dupa node_id)
    /// Folosit de SyncManager pentru GetHeaders etc.
    pub fn sendToPeer(self: *P2PNode, node_id: []const u8, msg_type: u8, payload: []const u8) !void {
        for (self.peers.items) |*peer| {
            if (peer.connected and std.mem.eql(u8, peer.node_id, node_id)) {
                try peer.send(msg_type, payload);
                return;
            }
        }
        return error.PeerNotFound;
    }

    /// Trimite sync_request la primul peer conectat mai sus decat noi
    /// Payload: [from_height: u64 LE]
    pub fn requestSync(self: *P2PNode, from_height: u64) void {
        var height_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &height_buf, from_height, .little);

        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            if (peer.height <= from_height) continue; // peer nu are mai mult decat noi
            peer.send(@intFromEnum(MessageType.sync_request), &height_buf) catch |err| {
                std.debug.print("[P2P] Sync request la {s} failed: {}\n",
                    .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
            };
            std.debug.print("[P2P] SYNC_REQUEST trimis la {s} (from height={d})\n",
                .{ peer.node_id[0..@min(peer.node_id.len, 16)], from_height });
            return; // trimitem la primul peer disponibil
        }
    }
};

/// Citeste exact `buf.len` bytes dintr-un Stream TCP — echivalent readAll
/// Returneaza numarul de bytes cititi (< buf.len daca stream inchis)
fn readAllFromStream(stream: std.net.Stream, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = p2pRecv(stream, buf[total..]) catch break;
        total += n;
    }
    return total;
}

/// Trimite un pachet UDP broadcast pe portul specificat (255.255.255.255)
fn knockUDP(msg: []const u8, port: u16) !void {
    const sock = try std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        std.posix.IPPROTO.UDP,
    );
    defer std.posix.close(sock);

    // SO_BROADCAST necesar pentru 255.255.255.255
    const opt_val: i32 = 1;
    try std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.BROADCAST,
        std.mem.asBytes(&opt_val),
    );

    // SO_REUSEADDR — permite multiple noduri sa asculte pe acelasi port
    try std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.REUSEADDR,
        std.mem.asBytes(&opt_val),
    );

    const dest = std.net.Address.initIp4(.{ 255, 255, 255, 255 }, port);
    _ = try std.posix.sendto(sock, msg, 0, &dest.any, dest.getOsSockLen());
}

/// Rezultat intern listen (cu IP sursa pentru duplicate_ip)
const ListenResult = union(KnockResult) {
    alone:            void,
    duplicate_ip:     [4]u8,  // IP-ul care a trimis duplicat
    broadcast_failed: void,
};

/// Asculta UDP pe `port` pentru `timeout_ms` milisecunde.
/// Daca primeste "OMNI:we are here:<alt_node_id>:<h>" de pe acelasi IP → duplicate_ip
/// Propria noastra reflectie (acelasi node_id) e ignorata.
fn listenKnockUDP(
    own_node_id: []const u8,
    port:        u16,
    timeout_ms:  u64,
) ListenResult {
    const sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        std.posix.IPPROTO.UDP,
    ) catch return .{ .broadcast_failed = {} };
    defer std.posix.close(sock);

    // SO_REUSEADDR + SO_REUSEPORT ca mai multi mineri pe acelasi host sa poata asculta
    const opt_val: i32 = 1;
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR,
        std.mem.asBytes(&opt_val)) catch {};
    // SO_REUSEPORT disponibil pe Linux/macOS, ignorat pe Windows
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, 15, // SO_REUSEPORT = 15
        std.mem.asBytes(&opt_val)) catch {};

    // Bind pe 0.0.0.0:port
    const bind_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    std.posix.bind(sock, &bind_addr.any, bind_addr.getOsSockLen()) catch
        return .{ .broadcast_failed = {} };

    // SO_RCVTIMEO — timeout receive
    // struct timeval: { tv_sec: i64, tv_usec: i64 } pe Linux
    const tv_sec  = timeout_ms / 1000;
    const tv_usec = (timeout_ms % 1000) * 1000;
    var timeval_buf: [16]u8 = @splat(0);
    std.mem.writeInt(i64, timeval_buf[0..8],  @intCast(tv_sec),  .little);
    std.mem.writeInt(i64, timeval_buf[8..16], @intCast(tv_usec), .little);
    std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO,
        &timeval_buf) catch {};

    // Asculta pana la timeout
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    var recv_buf: [512]u8 = undefined;
    var src_addr: std.posix.sockaddr = undefined;
    var src_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

    while (std.time.milliTimestamp() < deadline) {
        const n = std.posix.recvfrom(
            sock, &recv_buf, 0, &src_addr, &src_len,
        ) catch break; // timeout sau eroare → iesim

        if (n < 5) continue;
        const pkt = recv_buf[0..n];

        // Verifica prefix "OMNI:we are here:"
        const prefix = "OMNI:we are here:";
        if (!std.mem.startsWith(u8, pkt, prefix)) continue;

        // Extrage node_id din mesaj (dupa prefix, pana la urmatorul ':')
        const after_prefix = pkt[prefix.len..];
        const colon_pos = std.mem.indexOfScalar(u8, after_prefix, ':') orelse continue;
        const sender_node_id = after_prefix[0..colon_pos];

        // Ignora propria reflectie (acelasi node_id)
        const own_short = own_node_id[0..@min(own_node_id.len, sender_node_id.len)];
        if (std.mem.eql(u8, sender_node_id, own_short)) continue;

        // Alt nod detectat — extrage IP sursa
        const sa_in: *const std.posix.sockaddr.in = @alignCast(@ptrCast(&src_addr));
        const ip_raw = std.mem.toBytes(sa_in.addr); // network byte order (big-endian)
        const ip = [4]u8{ ip_raw[0], ip_raw[1], ip_raw[2], ip_raw[3] };

        std.debug.print("[KNOCK] << Raspuns de la {d}.{d}.{d}.{d} — node \"{s}\"\n",
            .{ ip[0], ip[1], ip[2], ip[3], sender_node_id[0..@min(16, sender_node_id.len)] });

        return .{ .duplicate_ip = ip };
    }

    return .{ .alone = {} };
}

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "MsgHeader encode/decode round-trip" {
    const hdr = MsgHeader{
        .version     = 1,
        .msg_type    = 2,
        .payload_len = 1234,
        .checksum    = 0xABCD,
        .flags       = 0,
    };
    var buf: [MSG_HEADER_SIZE]u8 = undefined;
    hdr.encode(&buf);

    const decoded = MsgHeader.decode(&buf);
    try testing.expectEqual(hdr.version,     decoded.version);
    try testing.expectEqual(hdr.msg_type,    decoded.msg_type);
    try testing.expectEqual(hdr.payload_len, decoded.payload_len);
    try testing.expectEqual(hdr.checksum,    decoded.checksum);
}

test "calcChecksum — determinist" {
    const data = "OmniBus P2P test";
    const c1 = calcChecksum(data);
    const c2 = calcChecksum(data);
    try testing.expectEqual(c1, c2);
    try testing.expect(c1 != 0);
}

test "MsgPing encode/decode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var id: [32]u8 = @splat(0);
    @memcpy(id[0..7], "node-01");

    const ping = MsgPing{ .node_id = id, .height = 12345, .version = 1 };
    const encoded = try ping.encode(arena.allocator());

    const decoded = MsgPing.decode(encoded).?;
    try testing.expectEqualSlices(u8, &ping.node_id, &decoded.node_id);
    try testing.expectEqual(ping.height, decoded.height);
    try testing.expectEqual(ping.version, decoded.version);
}

test "MsgBlockAnnounce encode/decode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const bh: [32]u8 = @splat(0xAA);
    const mi: [32]u8 = @splat(0xBB);

    const ann = MsgBlockAnnounce{
        .block_height = 999,
        .block_hash   = bh,
        .miner_id     = mi,
        .reward_sat   = 8_333_333,
    };
    const encoded = try ann.encode(arena.allocator());
    const decoded = MsgBlockAnnounce.decode(encoded).?;

    try testing.expectEqual(ann.block_height, decoded.block_height);
    try testing.expectEqualSlices(u8, &ann.block_hash, &decoded.block_hash);
    try testing.expectEqual(ann.reward_sat, decoded.reward_sat);
}

test "P2PNode init si deinit" {
    var node = P2PNode.init("node-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    try testing.expectEqualStrings("node-test", node.local_id);
    try testing.expectEqual(@as(usize, 0), node.peerCount());
    try testing.expectEqual(@as(u64, 0), node.chain_height);
}

test "P2PNode broadcastBlock cu 0 peeri — nu crapa" {
    var node = P2PNode.init("miner-1", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    // Fara peeri — broadcast trebuie sa fie no-op
    node.broadcastBlock(1, "0000abcd", 8_333_333);
    try testing.expectEqual(@as(u64, 1), node.chain_height);
}

test "P2PNode cleanDeadPeers — nu crapa gol" {
    var node = P2PNode.init("seed-1", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    node.cleanDeadPeers(); // lista goala — OK
    try testing.expectEqual(@as(usize, 0), node.peerCount());
}

// ─── Gossip Protocol Tests (B6) ─────────────────────────────────────────────

test "SeenHashes — insert and dedup" {
    var seen = SeenHashes.init();

    // First insert succeeds
    try testing.expect(seen.insert("abc123"));
    try testing.expectEqual(@as(usize, 1), seen.count);

    // Duplicate insert fails (returns false)
    try testing.expect(!seen.insert("abc123"));
    try testing.expectEqual(@as(usize, 1), seen.count);

    // Different hash succeeds
    try testing.expect(seen.insert("def456"));
    try testing.expectEqual(@as(usize, 2), seen.count);
}

test "SeenHashes — contains" {
    var seen = SeenHashes.init();

    try testing.expect(!seen.contains("abc123"));
    _ = seen.insert("abc123");
    try testing.expect(seen.contains("abc123"));
    try testing.expect(!seen.contains("xyz789"));
}

test "GossipTxPayload encode/decode roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const original = GossipTxPayload{
        .tx_hash = "aabbccdd11223344aabbccdd11223344aabbccdd11223344aabbccdd11223344",
        .tx_json = "{\"from\":\"ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh\",\"to\":\"ob1qq5tpx4wxy5jmww0x2mpklguwmmlj8s2rfn7su9\",\"amount\":1000}",
    };

    const encoded = try original.encode(arena.allocator());
    const decoded = GossipTxPayload.decode(encoded).?;

    try testing.expectEqualStrings(original.tx_hash, decoded.tx_hash);
    try testing.expectEqualStrings(original.tx_json, decoded.tx_json);
}

test "GossipTxPayload decode — too short returns null" {
    const short_data = [_]u8{ 0, 1, 2 };
    try testing.expect(GossipTxPayload.decode(&short_data) == null);
}

test "broadcastTx with 0 peers — no crash, dedup works" {
    var node = P2PNode.init("gossip-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    const tx_hash = "0011223344556677889900aabbccddeeff0011223344556677889900aabbccdd";
    const tx_json = "{\"test\":true}";

    // First broadcast marks as seen
    node.broadcastTx(tx_hash, tx_json);
    try testing.expectEqual(@as(u64, 1), node.gossip_tx_count);
    try testing.expect(node.seen_tx_hashes.contains(tx_hash));

    // Second broadcast is deduped (no increment)
    node.broadcastTx(tx_hash, tx_json);
    try testing.expectEqual(@as(u64, 1), node.gossip_tx_count);
}

test "broadcastBlockGossip with 0 peers — dedup works" {
    var node = P2PNode.init("gossip-block-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    const hash = "aabb0011223344556677";

    // First broadcast
    node.broadcastBlockGossip(42, hash, 8_333_333);
    try testing.expectEqual(@as(u64, 1), node.gossip_block_count);
    try testing.expectEqual(@as(u64, 42), node.chain_height);
    try testing.expect(node.seen_block_hashes.contains(hash));

    // Duplicate is skipped
    node.broadcastBlockGossip(42, hash, 8_333_333);
    try testing.expectEqual(@as(u64, 1), node.gossip_block_count);
}

test "getGossipStats — initial zeros" {
    var node = P2PNode.init("stats-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    const stats = node.getGossipStats();
    try testing.expectEqual(@as(u64, 0), stats.tx_relayed);
    try testing.expectEqual(@as(u64, 0), stats.blocks_relayed);
    try testing.expectEqual(@as(usize, 0), stats.seen_tx);
    try testing.expectEqual(@as(usize, 0), stats.seen_blocks);
}

test "gossipMaintenance — does not crash on empty" {
    var node = P2PNode.init("maint-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    node.gossipMaintenance(); // no-op on empty, should not crash
    try testing.expectEqual(@as(usize, 0), node.seen_tx_hashes.count);
}

// ─── PEX (Peer Exchange) Tests (B12) ───────────────────────────────────────

test "B12: PEX encodePeerList/decodePeerList roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const peers = [_]MsgPeerList.PeerAddr{
        .{ .ip = .{ 10, 0, 0, 1 }, .port = 9000 },
        .{ .ip = .{ 192, 168, 1, 50 }, .port = 8333 },
        .{ .ip = .{ 127, 0, 0, 1 }, .port = 9001 },
    };

    const encoded = try encodePeerList(&peers, arena.allocator());
    const decoded = try decodePeerList(encoded, arena.allocator());

    try testing.expectEqual(@as(usize, 3), decoded.len);
    try testing.expectEqual(peers[0].ip, decoded[0].ip);
    try testing.expectEqual(peers[0].port, decoded[0].port);
    try testing.expectEqual(peers[1].ip, decoded[1].ip);
    try testing.expectEqual(peers[1].port, decoded[1].port);
    try testing.expectEqual(peers[2].ip, decoded[2].ip);
    try testing.expectEqual(peers[2].port, decoded[2].port);
}

test "B12: PEX decodePeerList — empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const empty_peers = [_]MsgPeerList.PeerAddr{};
    const encoded = try encodePeerList(&empty_peers, arena.allocator());
    const decoded = try decodePeerList(encoded, arena.allocator());
    try testing.expectEqual(@as(usize, 0), decoded.len);
}

test "B12: PEX decodePeerList — too short returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const short = [_]u8{0};
    try testing.expectError(error.InvalidPayload, decodePeerList(&short, arena.allocator()));
}

test "B12: PEX max peers cap" {
    try testing.expectEqual(@as(usize, 100), PEX_MAX_PEERS);
}

test "B12: P2PNode buildPeerListPayload — empty peers" {
    var node = P2PNode.init("pex-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    // No connected peers → should produce payload with count=0
    const payload = try node.buildPeerListPayload();
    defer testing.allocator.free(payload);

    try testing.expectEqual(@as(usize, 2), payload.len); // just the u16 count
    const count = std.mem.readInt(u16, payload[0..2], .little);
    try testing.expectEqual(@as(u16, 0), count);
}

// ─── P2P Hardening Tests ────────────────────────────────────────────────────

test "Hardening: BannedPeer — init and match" {
    const bp = BannedPeer.init("10.0.0.1", 9000, 3600, "test ban");
    try testing.expect(bp.active);
    try testing.expect(bp.matchesHost("10.0.0.1", 9000));
    try testing.expect(!bp.matchesHost("10.0.0.2", 9000));
    try testing.expect(!bp.matchesHost("10.0.0.1", 9001));
    try testing.expect(!bp.isExpired()); // just created, 1 hour from now
}

test "Hardening: P2PNode ban and check" {
    var node = P2PNode.init("ban-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    // Not banned initially
    try testing.expect(!node.isBanned("10.0.0.1", 9000));

    // Ban a peer
    node.banPeer("10.0.0.1", 9000, "test reason");
    try testing.expect(node.isBanned("10.0.0.1", 9000));
    try testing.expectEqual(@as(u16, 1), node.banned_count);

    // Different host not banned
    try testing.expect(!node.isBanned("10.0.0.2", 9000));
}

test "Hardening: ban score accumulation and threshold" {
    var node = P2PNode.init("score-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    const peer_id = [_]u8{0xAA} ** 16;

    // Apply many negative events
    node.scoring_engine.scoreEvent(peer_id, .invalid_tx); // -10
    node.scoring_engine.scoreEvent(peer_id, .invalid_tx); // -10
    node.scoring_engine.scoreEvent(peer_id, .invalid_tx); // -10
    try testing.expect(node.scoring_engine.isAllowed(peer_id)); // -30, still allowed

    // Hit threshold with double_spend
    node.scoring_engine.scoreEvent(peer_id, .double_spend_attempt); // -100 → total -130
    try testing.expect(!node.scoring_engine.isAllowed(peer_id)); // banned
}

test "Hardening: RateLimitState — within limits" {
    var rl = RateLimitState.init();
    // First message should be within limits
    try testing.expect(rl.recordMessage(100));
    try testing.expectEqual(@as(u32, 1), rl.msg_count);
    try testing.expectEqual(@as(u64, 100), rl.byte_count);
}

test "Hardening: RateLimitState — exceed message count" {
    var rl = RateLimitState.init();
    // Send RATE_LIMIT_MSG_PER_SEC messages — all should pass
    for (0..RATE_LIMIT_MSG_PER_SEC) |_| {
        try testing.expect(rl.recordMessage(1));
    }
    // Next message should exceed the limit
    try testing.expect(!rl.recordMessage(1));
}

test "Hardening: RateLimitState — exceed byte count" {
    var rl = RateLimitState.init();
    // Send one huge message exceeding byte limit — should be rejected immediately
    try testing.expect(!rl.recordMessage(RATE_LIMIT_BYTES_PER_SEC + 1));
    // Confirm still rejected
    try testing.expect(!rl.recordMessage(1));
}

test "Hardening: ReconnectInfo — init" {
    const ri = ReconnectInfo.init("10.0.0.1", 9000, "peer-1");
    try testing.expect(ri.active);
    try testing.expectEqual(@as(u8, 0), ri.attempts);
    try testing.expectEqual(@as(u16, 9000), ri.port);
}

test "Hardening: P2PNode reconnect queue management" {
    var node = P2PNode.init("reconn-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    // Add a reconnect entry
    node.addReconnect("10.0.0.1", 9000, "peer-1");
    try testing.expectEqual(@as(u16, 1), node.reconnect_count);

    // Adding same again increments attempts
    node.addReconnect("10.0.0.1", 9000, "peer-1");
    try testing.expectEqual(@as(u16, 1), node.reconnect_count);
    // Find the entry and check attempts
    for (&node.reconnect_queue) |*ri| {
        if (ri.active and ri.port == 9000) {
            try testing.expectEqual(@as(u8, 1), ri.attempts);
            break;
        }
    }

    // Clear reconnect
    node.clearReconnect("10.0.0.1", 9000);
    try testing.expectEqual(@as(u16, 0), node.reconnect_count);
}

test "Hardening: reconnect attempt counting — max attempts removes entry" {
    var node = P2PNode.init("reconn-max", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    node.addReconnect("10.0.0.1", 9000, "peer-1");
    try testing.expectEqual(@as(u16, 1), node.reconnect_count);

    // Simulate MAX_RECONNECT_ATTEMPTS failures
    for (0..MAX_RECONNECT_ATTEMPTS) |_| {
        node.addReconnect("10.0.0.1", 9000, "peer-1");
    }
    // After max attempts, entry should be removed
    try testing.expectEqual(@as(u16, 0), node.reconnect_count);
}

test "Hardening: subnet diversity check" {
    var node = P2PNode.init("subnet-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    // No peers — any subnet is ok
    try testing.expect(node.checkSubnetDiversity(.{ 10, 0, 1, 1 }));

    // We cannot add real peers without TCP sockets, but we can test subnetCount
    try testing.expectEqual(@as(usize, 0), node.subnetCount());
    try testing.expect(node.hasMinSubnetDiversity()); // fewer peers than minimum
}

test "Hardening: connection limits constants" {
    try testing.expectEqual(@as(usize, 32), MAX_INBOUND);
    try testing.expectEqual(@as(usize, 8), MAX_OUTBOUND);
    try testing.expectEqual(@as(usize, 40), MAX_PEERS);
}

test "Hardening: canAcceptInbound — initial state" {
    var node = P2PNode.init("inbound-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    try testing.expect(node.canAcceptInbound());
    try testing.expectEqual(@as(u16, 0), node.inbound_count);
    try testing.expectEqual(@as(u16, 0), node.outbound_count);
}

test "Hardening: hardeningMaintenance — no crash on empty" {
    var node = P2PNode.init("maint-hard", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    node.hardeningMaintenance(); // should not crash
    try testing.expectEqual(@as(u16, 0), node.banned_count);
    try testing.expectEqual(@as(u16, 0), node.reconnect_count);
}

test "Hardening: P2PNode init — hardening fields initialized" {
    var node = P2PNode.init("init-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    try testing.expect(node.hardening_init);
    try testing.expectEqual(@as(u16, 0), node.banned_count);
    try testing.expectEqual(@as(u16, 0), node.reconnect_count);
    try testing.expectEqual(@as(u16, 0), node.inbound_count);
    try testing.expectEqual(@as(u16, 0), node.outbound_count);

    // All banned_peers should be inactive
    for (&node.banned_peers) |*bp| {
        try testing.expect(!bp.active);
    }
}

test "Hardening: ConnDirection enum" {
    const inb: ConnDirection = .inbound;
    const outb: ConnDirection = .outbound;
    try testing.expect(inb != outb);
}

test "Hardening: multiple bans tracked" {
    var node = P2PNode.init("multi-ban", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    node.banPeer("10.0.0.1", 9000, "reason1");
    node.banPeer("10.0.0.2", 9001, "reason2");
    node.banPeer("10.0.0.3", 9002, "reason3");

    try testing.expect(node.isBanned("10.0.0.1", 9000));
    try testing.expect(node.isBanned("10.0.0.2", 9001));
    try testing.expect(node.isBanned("10.0.0.3", 9002));
    try testing.expect(!node.isBanned("10.0.0.4", 9003));
    try testing.expectEqual(@as(u16, 3), node.banned_count);
}

// ─── SPV Header Sync Tests ─────────────────────────────────────────────────

test "SPV: encodeGetHeaders/decodeGetHeaders roundtrip" {
    var buf: [8]u8 = undefined;
    encodeGetHeaders(42, 100, &buf);
    const decoded = decodeGetHeaders(&buf).?;
    try testing.expectEqual(@as(u32, 42), decoded.start_height);
    try testing.expectEqual(@as(u32, 100), decoded.count);
}

test "SPV: decodeGetHeaders — too short returns null" {
    const short = [_]u8{ 0, 1, 2 };
    try testing.expect(decodeGetHeaders(&short) == null);
}

test "SPV: serializeSpvHeader/deserializeSpvHeader roundtrip" {
    var header = light_client_mod.BlockHeader.init(0);
    header.index = 42;
    header.timestamp = 1711792800;
    header.nonce = 999;
    header.difficulty = 8;
    header.previous_hash = [_]u8{0xAA} ** 32;
    header.merkle_root = [_]u8{0xBB} ** 32;
    header.hash = [_]u8{0xCC} ** 32;

    var buf: [SPV_HEADER_SIZE]u8 = undefined;
    serializeSpvHeader(&header, &buf);
    const decoded = deserializeSpvHeader(&buf);

    try testing.expectEqual(@as(u32, 42), decoded.index);
    try testing.expectEqual(@as(i64, 1711792800), decoded.timestamp);
    try testing.expectEqual(@as(u64, 999), decoded.nonce);
    try testing.expectEqual(@as(u32, 8), decoded.difficulty);
    try testing.expectEqualSlices(u8, &header.previous_hash, &decoded.previous_hash);
    try testing.expectEqualSlices(u8, &header.merkle_root, &decoded.merkle_root);
    try testing.expectEqualSlices(u8, &header.hash, &decoded.hash);
}

test "SPV: encodeHeadersBatch/decodeHeadersBatch roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var headers: [3]light_client_mod.BlockHeader = undefined;
    for (0..3) |i| {
        headers[i] = light_client_mod.BlockHeader.init(@intCast(i));
        headers[i].nonce = @intCast(i * 100);
        headers[i].difficulty = @intCast(i + 1);
    }

    const encoded = try encodeHeadersBatch(&headers, arena.allocator());
    const decoded = try decodeHeadersBatch(encoded, arena.allocator());

    try testing.expectEqual(@as(usize, 3), decoded.len);
    for (0..3) |i| {
        try testing.expectEqual(headers[i].index, decoded[i].index);
        try testing.expectEqual(headers[i].nonce, decoded[i].nonce);
        try testing.expectEqual(headers[i].difficulty, decoded[i].difficulty);
    }
}

test "SPV: decodeHeadersBatch — empty batch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const empty: [0]light_client_mod.BlockHeader = .{};
    const encoded = try encodeHeadersBatch(&empty, arena.allocator());
    const decoded = try decodeHeadersBatch(encoded, arena.allocator());
    try testing.expectEqual(@as(usize, 0), decoded.len);
}

test "SPV: decodeHeadersBatch — too short returns error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const short = [_]u8{ 0, 1 };
    try testing.expectError(error.InvalidPayload, decodeHeadersBatch(&short, arena.allocator()));
}

test "SPV: encodeBloomFilter/decodeBloomFilter roundtrip" {
    var filter = light_client_mod.BloomFilter.init(7);
    filter.add("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh");
    filter.add("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas");

    var buf: [513]u8 = undefined;
    encodeBloomFilter(&filter, &buf);
    const decoded = decodeBloomFilter(&buf).?;

    try testing.expectEqual(filter.num_hash_funcs, decoded.num_hash_funcs);
    try testing.expect(decoded.contains("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));
    try testing.expect(decoded.contains("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas"));
}

test "SPV: decodeBloomFilter — too short returns null" {
    const short = [_]u8{0} ** 100;
    try testing.expect(decodeBloomFilter(&short) == null);
}

test "SPV: P2PNode syncHeaders with 0 peers — no crash" {
    var node = P2PNode.init("spv-test", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    var lc = light_client_mod.LightClient.init(testing.allocator);
    defer lc.deinit();

    node.attachLightClient(&lc);
    node.syncHeaders(); // no peers, should be no-op
}

test "SPV: P2PNode sendBloomFilter with 0 peers — no crash" {
    var node = P2PNode.init("spv-bloom", "127.0.0.1", P2P_PORT_DEFAULT, testing.allocator);
    defer node.deinit();

    var lc = light_client_mod.LightClient.init(testing.allocator);
    defer lc.deinit();

    lc.watchAddress("ob1q54k8s2w5awzza0g2wtf22e2gzjqhxperxz6hr8");
    node.attachLightClient(&lc);
    node.sendBloomFilter(); // no peers, should be no-op
}

test "SPV: light client header chain after simulated headers_p2p" {
    // Simulate what would happen when headers_p2p is received:
    // decode a batch and add to light client
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lc = light_client_mod.LightClient.init(testing.allocator);
    defer lc.deinit();

    // Build a chain of 5 headers with proper linkage
    var headers: [5]light_client_mod.BlockHeader = undefined;
    for (0..5) |i| {
        headers[i] = light_client_mod.BlockHeader.init(@intCast(i));
        headers[i].timestamp = @intCast(1711792800 + @as(i64, @intCast(i)) * 10);
        headers[i].hash = [_]u8{@intCast(i + 1)} ** 32;
        if (i > 0) {
            headers[i].previous_hash = [_]u8{@intCast(i)} ** 32;
        }
    }

    // Encode and decode (simulating wire transfer)
    const encoded = try encodeHeadersBatch(&headers, arena.allocator());
    const decoded = try decodeHeadersBatch(encoded, arena.allocator());

    // Add to light client
    for (decoded) |header| {
        lc.addHeader(header) catch {};
    }

    try testing.expectEqual(@as(usize, 5), lc.getHeaderCount());
    try testing.expectEqual(@as(u32, 4), lc.getHeight());
    try testing.expect(lc.verifyChain());
}
