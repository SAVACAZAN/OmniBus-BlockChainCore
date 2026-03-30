/// p2p.zig — Transport TCP real pentru OmniBus P2P
/// Modular: network.zig pastreaza structurile, p2p.zig adauga transportul
/// Nu modifica blockchain.zig, wallet.zig sau codul existent.
const std = @import("std");
const builtin = @import("builtin");
const network_mod    = @import("network.zig");

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
            .is_idle     = false,
            .blockchain  = null,
            .sync_mgr    = null,
        };
    }

    /// Ataseaza blockchain si sync_mgr — apelat din main dupa init P2PNode
    /// Necesar pentru ca dispatchMessage sa poata aplica blocuri primite
    pub fn attachBlockchain(self: *P2PNode, bc: *Blockchain, sm: *SyncManager) void {
        self.blockchain = bc;
        self.sync_mgr   = sm;
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

    pub fn printStatus(self: *const P2PNode) void {
        std.debug.print("[P2P] Node={s} | Peers={d} | Height={d} | Port={d} | Idle={}\n", .{
            self.local_id, self.peerCount(), self.chain_height,
            self.local_port, self.is_idle,
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
                std.debug.print("[P2P] PEER_LIST de la {s} ({d} bytes)\n", .{ pid, payload.len });
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
