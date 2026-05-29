/// p2p/peer.zig — PeerConnection + ConnDirection + RateLimitState
/// Extracted from core/p2p.zig (~190 LOC). PeerConnection owns a TCP stream
/// + per-peer metadata and serializes MsgX wire types onto the stream.
/// Self-contained: depends only on wire types, socket primitives, and
/// network_mod.MessageType. p2p.zig re-exports these symbols for back-compat.
const std = @import("std");

const wire = @import("wire.zig");
const socket = @import("socket.zig");
const network_mod = @import("../network.zig");

const MessageType = network_mod.MessageType;
const MSG_HEADER_SIZE = wire.MSG_HEADER_SIZE;
const MsgHeader = wire.MsgHeader;
const calcChecksum = wire.calcChecksum;
const P2P_VERSION = wire.P2P_VERSION;
const P2P_MAX_MSG_BYTES = wire.P2P_MAX_MSG_BYTES;
const MsgPing = wire.MsgPing;
const MsgHello = wire.MsgHello;
const MsgWelcome = wire.MsgWelcome;
const MsgStable = wire.MsgStable;
const MsgBlockAnnounce = wire.MsgBlockAnnounce;

const p2pSend = socket.p2pSend;
const readAllFromStream = socket.readAllFromStream;

/// Rate-limit thresholds — kept in sync with the canonical values in
/// core/p2p.zig. PeerConnection is the sole consumer, so duplicating two
/// constants here is cheaper than introducing a circular import.
const RATE_LIMIT_MSG_PER_SEC: u32 = 100;
const RATE_LIMIT_BYTES_PER_SEC: u64 = 10 * 1024 * 1024;

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
    /// Unix timestamp (seconds) of the last message received from this peer.
    /// Used by the slot-skip anti-fork check: if a peer was active in the
    /// last few seconds, it is probably about to (or just did) take its
    /// slot, so we should NOT also take it. Initialized to 0 (never seen).
    last_msg_ts: i64 = 0,

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

    /// "WE ARE HERE!!" — first message a dialer sends after TCP connect.
    /// Carries node_id, chain magic, listening port, current height, and the
    /// genesis_hash so the acceptor can detect cross-genesis fork (e.g. same
    /// chain magic but different genesis = different testnet instance).
    pub fn sendHello(
        self: *PeerConnection,
        node_id: []const u8,
        chain_magic: [4]u8,
        listen_port: u16,
        height: u64,
        genesis_hash: [32]u8,
    ) !void {
        var id_buf: [32]u8 = @splat(0);
        const copy_len = @min(node_id.len, 32);
        @memcpy(id_buf[0..copy_len], node_id[0..copy_len]);

        const hello = MsgHello{
            .node_id = id_buf,
            .chain_magic = chain_magic,
            .listen_port = listen_port,
            .height = height,
            .version = P2P_VERSION,
            .genesis_hash = genesis_hash,
        };
        const payload = try hello.encode(self.allocator);
        defer self.allocator.free(payload);
        try self.send(@intFromEnum(MessageType.hello), payload);
    }

    /// "WE WANT TO WORK" / "WE DON'T" — acceptor's reply to HELLO.
    pub fn sendWelcome(
        self: *PeerConnection,
        node_id: []const u8,
        chain_magic: [4]u8,
        height: u64,
        accepted: bool,
        reason: u8,
    ) !void {
        var id_buf: [32]u8 = @splat(0);
        const copy_len = @min(node_id.len, 32);
        @memcpy(id_buf[0..copy_len], node_id[0..copy_len]);

        const welcome = MsgWelcome{
            .node_id = id_buf,
            .chain_magic = chain_magic,
            .height = height,
            .accepted = if (accepted) 1 else 0,
            .reason = reason,
        };
        const payload = try welcome.encode(self.allocator);
        defer self.allocator.free(payload);
        try self.send(@intFromEnum(MessageType.welcome), payload);
    }

    /// "WE ARE STABLE" — confirmation after sync settles.
    pub fn sendStable(self: *PeerConnection, confirmed_height: u64, peer_count: u16) !void {
        const msg = MsgStable{
            .confirmed_height = confirmed_height,
            .peer_count = peer_count,
        };
        const payload = try msg.encode(self.allocator);
        defer self.allocator.free(payload);
        try self.send(@intFromEnum(MessageType.stable), payload);
    }

    /// Anunta un bloc nou la peer.
    /// hash_hex = 64-char lowercase hex string of block hash. We decode it
    /// to 32 raw bytes for the wire (V2). miner_id = OmniBus wallet address
    /// (max 42 chars, NUL-padded).
    pub fn announceBlock(
        self:         *PeerConnection,
        height:       u64,
        hash_hex:     []const u8,
        miner_id:     []const u8,
        reward_sat:   u64,
    ) !void {
        // Decode 64-char hex hash → 32 raw bytes. If the hash is shorter
        // (genesis literal "genesis_hash_omnibus_v1"), result is zero-
        // padded — peers will see all-zero hash and recognize a malformed
        // header, but we don't want to fail-fast here on broken inputs.
        var bh: [32]u8 = @splat(0);
        if (hash_hex.len >= 64) {
            for (0..32) |i| {
                const hi = std.fmt.charToDigit(hash_hex[i * 2], 16) catch break;
                const lo = std.fmt.charToDigit(hash_hex[i * 2 + 1], 16) catch break;
                bh[i] = (@as(u8, hi) << 4) | @as(u8, lo);
            }
        }
        var mi: [42]u8 = @splat(0);
        const mlen = @min(miner_id.len, 42);
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
