// Transport — TCP listener, outbound connect, heartbeat, accept/recv threads.
//
// Extracted from core/p2p.zig (Phase: thread entry points). Provides free
// functions over `*P2PNode`:
//   - connectToPeer            (outbound dial + spawn recv thread)
//   - startListener / acceptLoop (inbound TCP accept loop)
//   - handleInboundPeer        (per-peer accept handler thread)
//   - startHeartbeat / heartbeatLoop (periodic PING fan-out)
//   - cleanDeadPeers           (reap disconnected peers)
//
// All helper methods (isBanned, checkSubnetDiversity, canAcceptInbound,
// addReconnect, scoring, etc.) still live on P2PNode. The dispatcher
// `P2PNode.dispatchMessage` is invoked via the p2p_mod re-export.

const std = @import("std");
const p2p_mod = @import("../p2p.zig");
const wire = @import("wire.zig");
const socket = @import("socket.zig");
const banman = @import("banman.zig");

const P2PNode = p2p_mod.P2PNode;
const PeerConnection = p2p_mod.PeerConnection;
const enableTcpNoDelay = socket.enableTcpNoDelay;

const MAX_OUTBOUND = p2p_mod.MAX_OUTBOUND;
const MAX_PEERS = p2p_mod.MAX_PEERS;

/// Heartbeat tick interval — see p2p.zig comment for rationale (peer.height
/// would otherwise be frozen at handshake-time forever).
pub const HEARTBEAT_INTERVAL_S: u64 = 10;

// ─── Outbound dial ───────────────────────────────────────────────────────────

/// Conecteaza la un peer (TCP outbound).
pub fn connectToPeer(node: *P2PNode, host: []const u8, port: u16, node_id: []const u8) !void {
    // Evita duplicate (sub lock — alte threaduri pot append concurent)
    {
        node.peers_mutex.lock();
        defer node.peers_mutex.unlock();
        for (node.peers.items) |p| {
            if (std.mem.eql(u8, p.node_id, node_id)) return; // deja conectat
        }
    }

    // ── Hardening: check ban list ────────────────────────────────────
    if (node.isBanned(host, port)) {
        std.debug.print("[P2P] Rejected banned peer {s}:{d}\n", .{ host, port });
        return error.PeerBanned;
    }

    // ── Hardening: connection limits ─────────────────────────────────
    const out_now = node.outbound_count.load(.acquire);
    if (out_now >= MAX_OUTBOUND) {
        std.debug.print("[P2P] Outbound limit reached ({d}/{d})\n",
            .{ out_now, MAX_OUTBOUND });
        return error.TooManyOutbound;
    }
    // Lock for the peers cap check + later append (avoid TOCTOU + UAF).
    node.peers_mutex.lock();
    if (node.peers.items.len >= MAX_PEERS) {
        const peers_len = node.peers.items.len;
        node.peers_mutex.unlock();
        std.debug.print("[P2P] Total peer limit reached ({d}/{d})\n",
            .{ peers_len, MAX_PEERS });
        return error.TooManyPeers;
    }
    node.peers_mutex.unlock();

    // Try parseIp4 first (literal "1.2.3.4"); fall back to DNS lookup so
    // we can also accept hostnames like "omnibusblockchain.cc". Without
    // this, --seed-host omnibusblockchain.cc fails with InvalidCharacter
    // and the node sits in single-miner mode forever.
    const addr = blk: {
        if (std.net.Address.parseIp4(host, port)) |a| {
            break :blk a;
        } else |_| {
            // Hostname: resolve via getAddressList. Pick first IPv4.
            var arena = std.heap.ArenaAllocator.init(node.allocator);
            defer arena.deinit();
            const list = std.net.getAddressList(arena.allocator(), host, port) catch |dns_err| {
                std.debug.print("[P2P] DNS resolve failed for '{s}': {}\n", .{ host, dns_err });
                return dns_err;
            };
            defer list.deinit();
            var picked: ?std.net.Address = null;
            for (list.addrs) |a| {
                if (a.any.family == std.posix.AF.INET) { picked = a; break; }
            }
            if (picked == null and list.addrs.len > 0) picked = list.addrs[0];
            if (picked) |a| {
                std.debug.print("[P2P] Resolved {s} -> {f}\n", .{ host, a });
                break :blk a;
            }
            std.debug.print("[P2P] No addresses returned for '{s}'\n", .{host});
            return error.NoAddressForHost;
        }
    };

    // ── Hardening: subnet diversity (anti-eclipse) ───────────────────
    const ip_bytes = std.mem.toBytes(addr.in.sa.addr);
    const ip4 = [4]u8{ ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] };
    if (!node.checkSubnetDiversity(ip4)) {
        std.debug.print("[P2P] Subnet limit reached for {d}.{d}.x.x — rejected\n",
            .{ ip4[0], ip4[1] });
        return error.SubnetLimitReached;
    }

    const stream = std.net.tcpConnectToAddress(addr) catch |err| {
        std.debug.print("[P2P] Connect failed to {s}:{d}: {}\n", .{ host, port, err });
        return err;
    };
    // Disable Nagle so small block_announce / ping packets ship
    // immediately rather than waiting up to 40ms for a coalesce.
    enableTcpNoDelay(stream);

    const conn = PeerConnection{
        .stream    = stream,
        .node_id   = node_id,
        .host      = host,
        .port      = port,
        .height    = 0,
        .connected = true,
        .allocator = node.allocator,
        .direction = .outbound,
        .ip_bytes  = ip4,
    };

    // SEGFAULT-FIX [scan-2026-04-25]: lock peers_mutex around append so concurrent
    // iterators (RPC handlePeers, broadcast*, gossipMaintenance, mining) see a stable
    // items pointer. The append may realloc; iterators without the lock would UAF.
    node.peers_mutex.lock();
    node.peers.append(conn) catch |err| {
        node.peers_mutex.unlock();
        return err;
    };
    const last_idx = node.peers.items.len - 1;
    // 3-way handshake: send HELLO ("WE ARE HERE!!") first so the acceptor
    // can register us with our real node_id + listening port and validate
    // our chain (magic + genesis_hash). Then the legacy PING for height sync.
    const my_genesis = node.getLocalGenesisHash();
    node.peers.items[last_idx].sendHello(node.local_id, node.chain_magic, node.local_port, node.chain_height, my_genesis) catch |err| {
        std.debug.print("[P2P] Hello failed: {}\n", .{err});
    };
    node.peers.items[last_idx].sendPing(node.local_id, node.chain_height) catch |err| {
        std.debug.print("[P2P] Ping failed: {}\n", .{err});
    };
    const peer_ptr = &node.peers.items[last_idx];
    node.peers_mutex.unlock();
    _ = node.outbound_count.fetchAdd(1, .release);
    std.debug.print("[P2P] Connected to peer {s} ({s}:{d}) — HELLO sent\n", .{ node_id, host, port });

    // WS push: notify UI that a peer joined. Network panel updates the
    // peer count + adds the entry without polling getpeers.
    if (node.ws_server) |ws| {
        ws.broadcastPeerConnect(node_id, host, port);
    }

    // CRITICAL FIX (2026-04-26): spawn a recv thread for this OUTBOUND peer
    // so we can actually read the WELCOME, PONG, blocks, sync responses
    // that the acceptor sends back. Without this, the dialer never learned
    // peer.height — onPeerHeight was never triggered, requestSync was
    // never sent, and PC mined its own chain forever (observed: PC at
    // 954 blocs while VPS at 41k+, no REORG attempted).
    const ArgsT = struct { node: *P2PNode, peer: *PeerConnection };
    const pargs = node.allocator.create(ArgsT) catch {
        std.debug.print("[P2P] outbound recv thread: alloc failed\n", .{});
        return;
    };
    pargs.* = .{ .node = node, .peer = peer_ptr };
    const t = std.Thread.spawn(.{}, struct {
        fn run(args: *ArgsT) void {
            defer args.node.allocator.destroy(args);
            const peer = args.peer;
            const pid = peer.node_id[0..@min(peer.node_id.len, 24)];
            std.debug.print("[P2P] Outbound recv thread started for {s}\n", .{pid});
            while (peer.connected) {
                const msg = peer.recv() catch |err| {
                    if (err != error.ConnectionClosed) {
                        std.debug.print("[P2P] Outbound recv error ({s}): {}\n", .{ pid, err });
                    }
                    break;
                };
                defer args.node.allocator.free(msg.payload);
                peer.last_msg_ts = std.time.timestamp();
                P2PNode.dispatchMessage(args.node, peer, msg.msg_type, msg.payload);
            }
            std.debug.print("[P2P] Outbound peer {s} disconnected\n", .{pid});
            // WS push: peer dropped — UI removes from active list.
            if (args.node.ws_server) |ws| {
                ws.broadcastPeerDisconnect(peer.node_id[0..@min(peer.node_id.len, 32)], peer.host, peer.port);
            }
        }
    }.run, .{pargs}) catch |err| {
        std.debug.print("[P2P] outbound recv thread spawn failed: {}\n", .{err});
        node.allocator.destroy(pargs);
        return;
    };
    t.detach();

    // On successful connect, clear any reconnect entry
    banman.clearReconnect(node, host, port);
}

// ─── Dead peer reaper ────────────────────────────────────────────────────────

/// Deconecteaza peerii morti — adauga la reconnect queue in loc de stergere directa
/// SEGFAULT-FIX [scan-2026-04-25]: hold peers_mutex for entire iteration. swapRemove
/// invalidates iterators of any concurrent reader (RPC, broadcast, mining).
pub fn cleanDeadPeers(node: *P2PNode) void {
    node.peers_mutex.lock();
    defer node.peers_mutex.unlock();
    var i: usize = 0;
    while (i < node.peers.items.len) {
        if (!node.peers.items[i].connected) {
            const peer = &node.peers.items[i];
            // Track direction for counter update (atomic).
            if (peer.direction == .inbound) {
                if (node.inbound_count.load(.acquire) > 0)
                    _ = node.inbound_count.fetchSub(1, .release);
            } else {
                if (node.outbound_count.load(.acquire) > 0)
                    _ = node.outbound_count.fetchSub(1, .release);
            }
            // Add to reconnect queue (outbound only)
            if (peer.direction == .outbound) {
                node.addReconnect(peer.host, peer.port, peer.node_id);
            }
            peer.close();
            _ = node.peers.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

// ─── TCP Listener ────────────────────────────────────────────────────────────

/// Porneste server TCP inbound pe `local_port` — thread detached.
/// Fiecare peer inbound primeste propriul thread handler.
/// Returneaza error daca bind/listen esueaza (port ocupat, permisiuni etc.)
pub fn startListener(node: *P2PNode) !void {
    const addr = try std.net.Address.parseIp4(node.local_host, node.local_port);
    const server = try addr.listen(.{ .reuse_address = true });

    std.debug.print("[P2P] Listener pornit pe {s}:{d}\n", .{ node.local_host, node.local_port });

    // Pasam server-ul + node ptr la thread prin heapAllocator
    const AcceptArgs = struct { server: std.net.Server, node: *P2PNode };
    const aargs = try node.allocator.create(AcceptArgs);
    aargs.* = .{ .server = server, .node = node };

    const t = try std.Thread.spawn(.{}, acceptLoop, .{aargs});
    t.detach();
}

// ─── Heartbeat ───────────────────────────────────────────────────────────────

pub fn startHeartbeat(node: *P2PNode) !void {
    const t = try std.Thread.spawn(.{}, heartbeatLoop, .{node});
    t.detach();
    std.debug.print("[P2P] Heartbeat pornit — PING la fiecare {d}s\n", .{HEARTBEAT_INTERVAL_S});
}

pub fn heartbeatLoop(node: *P2PNode) void {
    while (true) {
        std.Thread.sleep(HEARTBEAT_INTERVAL_S * std.time.ns_per_s);
        const my_height = node.chain_height;
        var sent: usize = 0;
        node.peers_mutex.lock();
        for (node.peers.items) |*peer| {
            if (!peer.connected) continue;
            peer.sendPing(node.local_id, my_height) catch |err| {
                std.debug.print("[HEARTBEAT] sendPing to {s} failed: {}\n",
                    .{ peer.node_id[0..@min(peer.node_id.len, 16)], err });
                continue;
            };
            sent += 1;
        }
        node.peers_mutex.unlock();
        if (sent > 0) {
            std.debug.print("[HEARTBEAT] PING sent to {d} peers (my height={d})\n",
                .{ sent, my_height });
        }
    }
}

// ─── Accept loop + per-peer handler ──────────────────────────────────────────

pub fn acceptLoop(args: anytype) void {
    var server = args.server;
    const node  = args.node;
    defer node.allocator.destroy(args);

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("[P2P] Accept error: {}\n", .{err});
            std.Thread.sleep(1 * std.time.ns_per_s);
            continue;
        };
        // Disable Nagle on the inbound stream so our outgoing
        // PINGs / block announces from this side hit the wire
        // immediately. Symmetric with the outbound connect path.
        enableTcpNoDelay(conn.stream);

        // ── Hardening: extract remote IPv4 bytes for diversity checks ──
        // Note: when family != AF.INET (IPv6), we leave ip4 = {0,0,0,0}.
        // IPv6 inbound is currently out of scope for diversity gating;
        // the node listens on an IPv4 address so this is unreachable in
        // practice, but we keep the fallback safe.
        var ip4: [4]u8 = .{ 0, 0, 0, 0 };
        if (conn.address.any.family == std.posix.AF.INET) {
            const raw = std.mem.toBytes(conn.address.in.sa.addr);
            ip4 = .{ raw[0], raw[1], raw[2], raw[3] };
        }

        // ── Hardening: anti-eclipse subnet diversity (FINDING-1 fix) ──
        // The outbound dial path already calls checkSubnetDiversity at
        // line 1397; mirror the same gate here on accept. Without this,
        // a single attacker /16 (or single host with many ephemeral src
        // ports) can fill every inbound slot — the classic eclipse setup.
        if (!node.checkInboundSubnetDiversity(ip4)) {
            std.debug.print("[P2P] Inbound subnet limit reached for {d}.{d}.x.x — rejected\n",
                .{ ip4[0], ip4[1] });
            conn.stream.close();
            continue;
        }

        // ── Hardening: check inbound limits ──────────────────────────
        if (!node.canAcceptInbound()) {
            std.debug.print("[P2P] Inbound limit reached — rejecting connection\n", .{});
            conn.stream.close();
            continue;
        }

        std.debug.print("[P2P] Inbound connection de la {any}\n", .{conn.address});

        // Aloca context peer inbound. We carry ip4 forward so the
        // PeerConnection slot in node.peers gets its real subnet — without
        // this, ip_bytes stays {0,0,0,0} and subsequent diversity checks
        // (inbound + outbound) see all inbound peers as subnet 0.0,
        // poisoning the eviction / diversity logic.
        const PeerArgs = struct { conn: std.net.Server.Connection, node: *P2PNode, ip4: [4]u8 };
        const pargs = node.allocator.create(PeerArgs) catch continue;
        pargs.* = .{ .conn = conn, .node = node, .ip4 = ip4 };

        const pt = std.Thread.spawn(.{}, handleInboundPeer, .{pargs}) catch |err| {
            std.debug.print("[P2P] Thread spawn error: {}\n", .{err});
            node.allocator.destroy(pargs);
            conn.stream.close();
            continue;
        };
        pt.detach();
    }
}

pub fn handleInboundPeer(args: anytype) void {
    const conn = args.conn;
    const node = args.node;
    const ip4 = args.ip4;
    defer node.allocator.destroy(args);
    defer conn.stream.close();

    // SEGFAULT-FIX [scan-2026-04-25]: atomic increment/decrement on inbound_count
    // (was racy plain u32 RMW with multiple handler threads + acceptLoop).
    _ = node.inbound_count.fetchAdd(1, .release);
    defer {
        const cur = node.inbound_count.load(.acquire);
        if (cur > 0) _ = node.inbound_count.fetchSub(1, .release);
    }

    // Genereaza un peer_id temporar din adresa IP
    var id_buf: [32]u8 = undefined;
    const peer_id = std.fmt.bufPrint(&id_buf, "inbound-{any}", .{conn.address})
        catch "inbound-unknown";

    // Build the inbound PeerConnection. Note we keep `var peer` for the
    // dispatch loop to use as a stable pointer, but we ALSO register it
    // in `node.peers` so RPC `getpeers` and gossip broadcast see it.
    // Without this append, the connection works (PING/PONG, dispatch),
    // but the node is invisible to its own peers list — causing
    // dialer's view to show 1 peer while the seed shows 0.
    var peer = PeerConnection{
        .stream    = conn.stream,
        .node_id   = peer_id,
        .host      = "?",
        .port      = 0,
        .height    = 0,
        .connected = true,
        .allocator = node.allocator,
        .direction = .inbound,
        // FINDING-1 fix: populate the real /16 subnet so subsequent
        // checkSubnetDiversity / checkInboundSubnetDiversity calls
        // see this peer's actual network rather than 0.0.x.x.
        .ip_bytes  = ip4,
    };

    std.debug.print("[P2P] Handler pornit pentru {s}\n", .{peer_id[0..@min(peer_id.len, 24)]});

    // CRITICAL FIX (commit after 09a4a54): the registered peer in node.peers
    // is a COPY of `peer` local var (Zig append makes memcpy). Any subsequent
    // mutation on `peer` (e.g. HELLO updates peer.node_id) won't reflect in
    // node.peers[idx] — leading to RPC getpeers showing 'inbound-unknown'
    // forever. Solution: after append, use a *direct pointer* to the slot
    // for all subsequent recv/dispatch calls.
    var peer_index: ?usize = null;
    var peer_ptr: ?*PeerConnection = null;
    node.peers_mutex.lock();
    if (node.peers.items.len < MAX_PEERS) {
        node.peers.append(peer) catch |err| {
            node.peers_mutex.unlock();
            std.debug.print("[P2P] Failed to append inbound peer: {}\n", .{err});
            return;
        };
        peer_index = node.peers.items.len - 1;
        peer_ptr = &node.peers.items[peer_index.?];
        std.debug.print("[P2P] Inbound peer registered: {s} (peers={d})\n",
            .{ peer_id[0..@min(peer_id.len, 24)], node.peers.items.len });
    }
    node.peers_mutex.unlock();

    // Cleanup on exit: remove from peers list (symmetric with cleanDeadPeers).
    defer {
        if (peer_index) |idx| {
            node.peers_mutex.lock();
            if (idx < node.peers.items.len) {
                _ = node.peers.swapRemove(idx);
            }
            node.peers_mutex.unlock();
        }
    }

    // Use the pointer from node.peers[idx] from now on, NOT the local `peer`
    // variable. dispatchMessage mutates peer.node_id/host/port from HELLO —
    // those mutations MUST land in node.peers so RPC getpeers + gossip see
    // the real identity (not "inbound-unknown").
    const active_peer: *PeerConnection = peer_ptr orelse &peer;

    // Trimite PING imediat dupa accept
    active_peer.sendPing(node.local_id, node.chain_height) catch {};

    // Loop citire mesaje
    while (active_peer.connected) {
        const msg = active_peer.recv() catch |err| {
            if (err != error.ConnectionClosed) {
                std.debug.print("[P2P] Recv error ({s}): {}\n", .{ peer_id[0..@min(peer_id.len, 16)], err });
            }
            break;
        };
        defer node.allocator.free(msg.payload);

        // Track liveness — used by slot-skip anti-fork check in main.zig.
        active_peer.last_msg_ts = std.time.timestamp();

        P2PNode.dispatchMessage(node, active_peer, msg.msg_type, msg.payload);
    }

    std.debug.print("[P2P] Peer {s} deconectat\n", .{peer_id[0..@min(peer_id.len, 24)]});
}
