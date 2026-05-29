// PEX (Peer Exchange) + subnet diversity + hardening maintenance
//
// Extracted from core/p2p.zig. Free functions over *P2PNode for:
//   - sendGetPeers, requestPeersFromAll, buildPeerListPayload (PEX B12)
//   - checkSubnetDiversity, checkInboundSubnetDiversity, subnetCount,
//     hasMinSubnetDiversity (anti-eclipse / /16 subnet caps)
//   - canAcceptInbound (inbound connection-limit gate)
//   - hardeningMaintenance (periodic banlist/reconnect/gossip tick)
//
// Methods on P2PNode are thin delegates calling these.

const std = @import("std");
const p2p_mod = @import("../p2p.zig");
const wire = @import("wire.zig");

const P2PNode = p2p_mod.P2PNode;
const PeerConnection = p2p_mod.PeerConnection;
const MessageType = p2p_mod.MessageType;
const MsgPeerList = wire.MsgPeerList;
const PEX_MAX_PEERS = wire.PEX_MAX_PEERS;
const encodePeerList = wire.encodePeerList;

const MAX_PEERS = p2p_mod.MAX_PEERS;
const MAX_PEERS_PER_SUBNET = p2p_mod.MAX_PEERS_PER_SUBNET;
const MAX_INBOUND_PER_SUBNET = p2p_mod.MAX_INBOUND_PER_SUBNET;
const MIN_SUBNET_DIVERSITY = p2p_mod.MIN_SUBNET_DIVERSITY;
const MAX_INBOUND = p2p_mod.MAX_INBOUND;

// ─── PEX Protocol (B12) ──────────────────────────────────────────────────────

/// Send a get_peers request to a specific peer
pub fn sendGetPeers(_: *P2PNode, peer: *PeerConnection) void {
    peer.send(@intFromEnum(MessageType.get_peers), &.{}) catch |err| {
        std.debug.print("[PEX] get_peers send failed to {s}: {}\n",
            .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
    };
}

/// Send get_peers to all connected peers
pub fn requestPeersFromAll(node: *P2PNode) void {
    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    for (node.peers.items) |*peer| {
        if (!peer.connected) continue;
        sendGetPeers(node, peer);
    }
}

/// Build a peer_list payload from our known connected peers.
/// Returns encoded bytes; caller must free with allocator.
pub fn buildPeerListPayload(node: *P2PNode) ![]u8 {
    var addrs: [PEX_MAX_PEERS]MsgPeerList.PeerAddr = undefined;
    var count: usize = 0;
    {
        node.peers_mutex.lock();
        defer node.peers_mutex.unlock();
        for (node.peers.items) |p| {
            if (!p.connected) continue;
            if (count >= PEX_MAX_PEERS) break;
            const addr = std.net.Address.parseIp4(p.host, p.port) catch continue;
            const ip_bytes = addr.in.sa.addr;
            const ip_raw = std.mem.toBytes(ip_bytes);
            addrs[count] = .{
                .ip = .{ ip_raw[0], ip_raw[1], ip_raw[2], ip_raw[3] },
                .port = p.port,
            };
            count += 1;
        }
    }
    return encodePeerList(addrs[0..count], node.allocator);
}

// ─── Subnet Diversity (Anti-Eclipse) ─────────────────────────────────────────

/// Check if adding a peer with this IP would violate subnet diversity rules.
/// Returns true if the peer is allowed, false if too many from same /16 subnet.
pub fn checkSubnetDiversity(node: *P2PNode, ip: [4]u8) bool {
    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    var same_subnet: usize = 0;
    for (node.peers.items) |p| {
        if (!p.connected) continue;
        if (p.ip_bytes[0] == ip[0] and p.ip_bytes[1] == ip[1]) {
            same_subnet += 1;
        }
    }
    return same_subnet < MAX_PEERS_PER_SUBNET;
}

/// Inbound-only subnet diversity check (anti-eclipse on accept path).
/// Loopback (127.x.x.x) is exempt.
pub fn checkInboundSubnetDiversity(node: *P2PNode, ip: [4]u8) bool {
    if (ip[0] == 127) return true;
    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    var same_inbound: usize = 0;
    for (node.peers.items) |p| {
        if (!p.connected) continue;
        if (p.direction != .inbound) continue;
        if (p.ip_bytes[0] == ip[0] and p.ip_bytes[1] == ip[1]) {
            same_inbound += 1;
        }
    }
    return same_inbound < MAX_INBOUND_PER_SUBNET;
}

/// Count the number of distinct /16 subnets among connected peers.
pub fn subnetCount(node: *P2PNode) usize {
    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    var subnets: [MAX_PEERS][2]u8 = undefined;
    var count: usize = 0;
    for (node.peers.items) |p| {
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

/// Check if we have enough subnet diversity (at least MIN_SUBNET_DIVERSITY).
pub fn hasMinSubnetDiversity(node: *P2PNode) bool {
    if (node.peerCount() < MIN_SUBNET_DIVERSITY) return true;
    return subnetCount(node) >= MIN_SUBNET_DIVERSITY;
}

// ─── Connection Limits ───────────────────────────────────────────────────────

/// Check if we can accept an inbound connection.
pub fn canAcceptInbound(node: *P2PNode) bool {
    const in_now = node.inbound_count.load(.acquire);
    if (in_now >= MAX_INBOUND) return false;
    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    return node.peers.items.len < MAX_PEERS;
}

// ─── Periodic Maintenance ────────────────────────────────────────────────────

/// Periodic hardening maintenance: ban expiry, reconnects, gossip housekeeping.
pub fn hardeningMaintenance(node: *P2PNode) void {
    node.evictExpiredBans();
    node.processReconnects();
    node.gossipMaintenance();
}
