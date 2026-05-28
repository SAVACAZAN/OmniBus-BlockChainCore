// Wire-protocol messages + codecs for OmniBus P2P.
//
// Extracted from core/p2p.zig (2026-05-29) to keep the transport file
// focused on PeerConnection / P2PNode plumbing. Pure data + codecs only:
// no PeerConnection / P2PNode field access here.
const std = @import("std");
const light_client_mod = @import("../light_client.zig");

// ─── Protocol constants ─────────────────────────────────────────────────────

/// Versiunea protocolului P2P
/// Wire protocol version.
/// V3 (2026-04-26 PM): BlockHeader is 130 bytes (was 88 in V2). The extra
///   42 bytes carry miner_id, so blocks received via sync_response /
///   block_gossip retain the miner address instead of being credited to "".
///   Without this, dashboards showed only 1 miner per chain.
/// V2 (2026-04-26 AM): block hashes are 32 raw bytes (not 32 ASCII chars),
///   block_announce miner_id is 42 chars.
/// Bumping P2P_VERSION makes mixed-version peers reject each other cleanly
/// via the handshake check in `parseFrame` (returns ProtocolMismatch).
pub const P2P_VERSION: u8 = 3;

/// Marimea maxima a unui mesaj P2P (1 MB)
pub const P2P_MAX_MSG_BYTES: u32 = 1_048_576;

pub const MSG_HEADER_SIZE: usize = 9;

// ─── PEX constants ──────────────────────────────────────────────────────────

pub const PEX_MAX_PEERS: usize = 100;
pub const PEX_PEER_SIZE: usize = 6; // 4 bytes IP + 2 bytes port

// ─── SPV constants ──────────────────────────────────────────────────────────

/// Size of one serialized SPV header on the wire
pub const SPV_HEADER_SIZE: usize = 124;

/// Max headers per batch
pub const SPV_MAX_HEADERS_PER_MSG: u32 = 2000;

// ─── Message header ─────────────────────────────────────────────────────────

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

pub const MsgHello = struct {
    node_id:      [32]u8,
    chain_magic:  [4]u8,
    listen_port:  u16,
    height:       u64,
    version:      u8,
    genesis_hash: [32]u8,

    pub fn encode(self: MsgHello, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 79);
        @memcpy(buf[0..32], &self.node_id);
        @memcpy(buf[32..36], &self.chain_magic);
        std.mem.writeInt(u16, buf[36..38], self.listen_port, .little);
        std.mem.writeInt(u64, buf[38..46], self.height, .little);
        buf[46] = self.version;
        @memcpy(buf[47..79], &self.genesis_hash);
        return buf;
    }

    pub fn decode(data: []const u8) ?MsgHello {
        // Backward-compatible: accept legacy 47-byte HELLO with zeroed genesis.
        // Once all peers upgrade we can require >= 79.
        if (data.len < 47) return null;
        var id: [32]u8 = undefined;
        @memcpy(&id, data[0..32]);
        var magic: [4]u8 = undefined;
        @memcpy(&magic, data[32..36]);
        var ghash: [32]u8 = std.mem.zeroes([32]u8);
        if (data.len >= 79) {
            @memcpy(&ghash, data[47..79]);
        }
        return .{
            .node_id      = id,
            .chain_magic  = magic,
            .listen_port  = std.mem.readInt(u16, data[36..38], .little),
            .height       = std.mem.readInt(u64, data[38..46], .little),
            .version      = data[46],
            .genesis_hash = ghash,
        };
    }
};

pub const MsgWelcome = struct {
    node_id:     [32]u8,
    chain_magic: [4]u8,
    height:      u64,
    accepted:    u8,
    reason:      u8,

    pub const REASON_OK: u8 = 0;
    pub const REASON_WRONG_CHAIN: u8 = 1;
    pub const REASON_TOO_MANY_PEERS: u8 = 2;
    pub const REASON_BANNED: u8 = 3;
    pub const REASON_DUPLICATE_ID: u8 = 4;

    pub fn encode(self: MsgWelcome, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 46);
        @memcpy(buf[0..32], &self.node_id);
        @memcpy(buf[32..36], &self.chain_magic);
        std.mem.writeInt(u64, buf[36..44], self.height, .little);
        buf[44] = self.accepted;
        buf[45] = self.reason;
        return buf;
    }

    pub fn decode(data: []const u8) ?MsgWelcome {
        if (data.len < 46) return null;
        var id: [32]u8 = undefined;
        @memcpy(&id, data[0..32]);
        var magic: [4]u8 = undefined;
        @memcpy(&magic, data[32..36]);
        return .{
            .node_id     = id,
            .chain_magic = magic,
            .height      = std.mem.readInt(u64, data[36..44], .little),
            .accepted    = data[44],
            .reason      = data[45],
        };
    }
};

pub const MsgStable = struct {
    confirmed_height: u64,
    peer_count:       u16,

    pub fn encode(self: MsgStable, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 10);
        std.mem.writeInt(u64, buf[0..8], self.confirmed_height, .little);
        std.mem.writeInt(u16, buf[8..10], self.peer_count, .little);
        return buf;
    }

    pub fn decode(data: []const u8) ?MsgStable {
        if (data.len < 10) return null;
        return .{
            .confirmed_height = std.mem.readInt(u64, data[0..8], .little),
            .peer_count       = std.mem.readInt(u16, data[8..10], .little),
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

// ─── PEX (Peer Exchange) message encode/decode ──────────────────────────────

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

/// Block announcement (gossip).
/// Wire layout (V2, 2026-04-26 upgrade): 90 bytes total.
///   [0..8]   block_height (u64 LE)
///   [8..40]  block_hash   (raw 32 bytes — full SHA-256 digest, NOT ASCII)
///   [40..82] miner_id     (42 ASCII chars = full OmniBus address, NUL-padded)
///   [82..90] reward_sat   (u64 LE)
pub const MsgBlockAnnounce = struct {
    block_height: u64,
    block_hash:   [32]u8,
    miner_id:     [42]u8,
    reward_sat:   u64,

    pub fn encode(self: MsgBlockAnnounce, allocator: std.mem.Allocator) ![]u8 {
        var buf = try allocator.alloc(u8, 90);
        std.mem.writeInt(u64, buf[0..8],   self.block_height, .little);
        @memcpy(buf[8..40],  &self.block_hash);
        @memcpy(buf[40..82], &self.miner_id);
        std.mem.writeInt(u64, buf[82..90], self.reward_sat, .little);
        return buf;
    }

    pub fn decode(data: []const u8) ?MsgBlockAnnounce {
        if (data.len < 90) return null;
        var bh: [32]u8 = undefined;
        var mi: [42]u8 = undefined;
        @memcpy(&bh, data[8..40]);
        @memcpy(&mi, data[40..82]);
        return .{
            .block_height = std.mem.readInt(u64, data[0..8],   .little),
            .block_hash   = bh,
            .miner_id     = mi,
            .reward_sat   = std.mem.readInt(u64, data[82..90], .little),
        };
    }
};

// ─── SPV codecs ─────────────────────────────────────────────────────────────

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

/// Serialize a light_client BlockHeader into the 124-byte wire format.
/// Fields: index(8) + timestamp(8) + prev_hash(32) + merkle_root(32) + hash(32) + difficulty(4) + nonce(8) = 124
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

/// Deserialize a 124-byte wire header into a light_client BlockHeader.
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

/// Encode a headers_p2p response: [count:u32LE][header0:124]...[headerN:124]
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
