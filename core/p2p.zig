/// p2p.zig — Transport TCP real pentru OmniBus P2P
/// Modular: network.zig pastreaza structurile, p2p.zig adauga transportul
/// Nu modifica blockchain.zig, wallet.zig sau codul existent.
const std = @import("std");
const network_mod = @import("network.zig");
const array_list  = std.array_list;

pub const NetworkNode   = network_mod.NetworkNode;
pub const MessageType   = network_mod.MessageType;

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

// ─── Conexiune P2P (un singur peer) ──────────────────────────────────────────

pub const PeerConnection = struct {
    stream:     std.net.Stream,
    node_id:    []const u8,
    host:       []const u8,
    port:       u16,
    height:     u64,
    connected:  bool,
    allocator:  std.mem.Allocator,

    /// Trimite un mesaj binar catre peer
    pub fn send(self: *PeerConnection, msg_type: u8, payload: []const u8) !void {
        if (!self.connected) return error.NotConnected;
        if (payload.len > P2P_MAX_MSG_BYTES) return error.PayloadTooLarge;

        var header_buf: [MSG_HEADER_SIZE]u8 = undefined;
        const hdr = MsgHeader{
            .version     = P2P_VERSION,
            .msg_type    = msg_type,
            .payload_len = @intCast(payload.len),
            .checksum    = calcChecksum(payload),
            .flags       = 0,
        };
        hdr.encode(&header_buf);

        try self.stream.writeAll(&header_buf);
        if (payload.len > 0) try self.stream.writeAll(payload);
    }

    /// Citeste un mesaj binar de la peer
    /// Caller trebuie sa elibereze payload-ul cu allocator.free()
    pub fn recv(self: *PeerConnection) !struct { msg_type: u8, payload: []u8 } {
        if (!self.connected) return error.NotConnected;

        var header_buf: [MSG_HEADER_SIZE]u8 = undefined;
        const n = try self.stream.readAll(&header_buf);
        if (n < MSG_HEADER_SIZE) return error.ConnectionClosed;

        const hdr = MsgHeader.decode(&header_buf);
        if (hdr.version != P2P_VERSION) return error.ProtocolMismatch;
        if (hdr.payload_len > P2P_MAX_MSG_BYTES) return error.PayloadTooLarge;

        const payload = try self.allocator.alloc(u8, hdr.payload_len);
        errdefer self.allocator.free(payload);

        if (hdr.payload_len > 0) {
            const read = try self.stream.readAll(payload);
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

// ─── P2P Node — server TCP + lista de conexiuni ───────────────────────────────

pub const P2PNode = struct {
    local_id:    []const u8,
    local_host:  []const u8,
    local_port:  u16,
    peers:       array_list.Managed(PeerConnection),
    allocator:   std.mem.Allocator,
    chain_height: u64,

    pub fn init(
        local_id:   []const u8,
        local_host: []const u8,
        local_port: u16,
        allocator:  std.mem.Allocator,
    ) P2PNode {
        return .{
            .local_id    = local_id,
            .local_host  = local_host,
            .local_port  = local_port,
            .peers       = array_list.Managed(PeerConnection).init(allocator),
            .allocator   = allocator,
            .chain_height = 0,
        };
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

        const addr = try std.net.Address.parseIp4(host, port);
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
        };

        try self.peers.append(conn);
        std.debug.print("[P2P] Connected to peer {s} ({s}:{d})\n", .{ node_id, host, port });

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

    /// Numarul de peeri conectati
    pub fn peerCount(self: *const P2PNode) usize {
        var count: usize = 0;
        for (self.peers.items) |p| {
            if (p.connected) count += 1;
        }
        return count;
    }

    /// Deconecteaza peerii morti (nu mai raspund)
    pub fn cleanDeadPeers(self: *P2PNode) void {
        var i: usize = 0;
        while (i < self.peers.items.len) {
            if (!self.peers.items[i].connected) {
                self.peers.items[i].close();
                _ = self.peers.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn printStatus(self: *const P2PNode) void {
        std.debug.print("[P2P] Node={s} | Peers={d} | Height={d} | Port={d}\n", .{
            self.local_id, self.peerCount(), self.chain_height, self.local_port,
        });
    }
};

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
