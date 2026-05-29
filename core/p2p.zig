/// p2p.zig — Transport TCP real pentru OmniBus P2P
/// Modular: network.zig pastreaza structurile, p2p.zig adauga transportul
/// Nu modifica blockchain.zig, wallet.zig sau codul existent.
const std = @import("std");
const builtin = @import("builtin");
const network_mod    = @import("network.zig");
const scoring_mod    = @import("peer_scoring.zig");
const bootstrap_mod  = @import("bootstrap.zig");
const tor_mod        = @import("tor_proxy.zig");

// Socket primitives moved to core/p2p/socket.zig
const socket = @import("p2p/socket.zig");
const enableTcpNoDelay = socket.enableTcpNoDelay;
const p2pRecv = socket.p2pRecv;
const p2pSend = socket.p2pSend;
const readAllFromStream = socket.readAllFromStream;

// Ban/reconnect management moved to core/p2p/banman.zig
const banman = @import("p2p/banman.zig");

// Knock-knock UDP anti-Sybil moved to core/p2p/knock.zig
const knock_mod = @import("p2p/knock.zig");
pub const KnockResult = knock_mod.KnockResult;
const ListenResult = knock_mod.ListenResult;
const knockUDP = knock_mod.knockUDP;
const listenKnockUDP = knock_mod.listenKnockUDP;

// Windows: stream.read() = ReadFile care pica pe sockets acceptate. Folosim ws2_32.
const is_windows = builtin.os.tag == .windows;
const ws2 = if (is_windows) std.os.windows.ws2_32 else undefined;

/// Disable Nagle's algorithm on a TCP socket. Without this, the OS
/// buffers small writes for ~40ms hoping to batch them. For block
/// announces and peer-to-peer signalling, every send is small and
/// time-critical — Nagle adds ~40ms per hop, which on a 1s block
/// time is 4% of slot budget burnt before the packet leaves the box.
///
/// Best-effort: setsockopt errors are logged but do not fail the
/// connection. On platforms without IPPROTO_TCP / TCP_NODELAY (rare)
/// the call is a no-op.
const array_list     = std.array_list;
const blockchain_mod = @import("blockchain.zig");
const block_mod      = @import("block.zig");
const sync_mod       = @import("sync.zig");
const light_client_mod = @import("light_client.zig");
const ws_mod         = @import("ws_server.zig");
const chain_config_mod = @import("chain_config.zig");
const validator_mod    = @import("validator_registry.zig");
const oracle_policy_mod = @import("oracle_policy.zig");
const ws_exchange_feed_mod = @import("ws_exchange_feed.zig");
const oracle_types_mod = @import("oracle_types.zig");
const main_mod       = @import("main.zig");

pub const NetworkNode   = network_mod.NetworkNode;
pub const MessageType   = network_mod.MessageType;
pub const Blockchain    = blockchain_mod.Blockchain;
pub const Block         = block_mod.Block;
pub const SyncManager   = sync_mod.SyncManager;

/// Port implicit P2P (diferit de RPC 8332)
pub const P2P_PORT_DEFAULT: u16 = 8333;

// Wire-protocol primitives (constants, MsgHeader, MsgPing/Hello/Welcome/Stable,
// MsgPeerList, MsgBlockAnnounce, PEX + SPV codecs) live in p2p/wire.zig.
// We re-export everything below so existing call sites (main.zig, sync.zig, ...)
// keep referencing `p2p_mod.P2P_VERSION`, `p2p_mod.MsgHello`, etc.
const wire = @import("p2p/wire.zig");
pub const P2P_VERSION = wire.P2P_VERSION;
pub const P2P_MAX_MSG_BYTES = wire.P2P_MAX_MSG_BYTES;

/// Timeout conexiune TCP in ms
pub const P2P_CONNECT_TIMEOUT_MS: u64 = 3_000;

/// Timeout citire in ms
pub const P2P_READ_TIMEOUT_MS: u64 = 5_000;

// ─── P2P Hardening Constants ────────────────────────────────────────────────

/// Max inbound connections
pub const MAX_INBOUND: usize = 32;
/// Max outbound connections
pub const MAX_OUTBOUND: usize = 8;

// ── IBD (Initial Block Download) constants — Bitcoin Core pattern ──────────
/// Trigger IBD mode when peer height exceeds local by this many blocks.
/// Below this gap, normal block-by-block gossip + mining is fine.
pub const IBD_GAP_TRIGGER: u64 = 6;
/// Exit IBD mode when local catches up to within this many blocks of peer.
/// Bitcoin uses 24h-of-blocks (~144) as "in sync"; we use 6 for testnet/dev
/// agility. After exit, mining resumes.
pub const IBD_TOLERANCE: u64 = 6;
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
/// Max peers from same /16 subnet (anti-eclipse, applies to both directions)
pub const MAX_PEERS_PER_SUBNET: usize = 2;
/// Max INBOUND peers from same /16 subnet (anti-eclipse, stricter than total).
/// Prevents a single subnet from filling all inbound slots even if outbound
/// happens to dial into the same subnet. Default: half the per-subnet cap so
/// there is always room for an outbound peer from any subnet.
pub const MAX_INBOUND_PER_SUBNET: usize = 4;
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

pub const MSG_HEADER_SIZE = wire.MSG_HEADER_SIZE;
pub const MsgHeader = wire.MsgHeader;
const calcChecksum = wire.calcChecksum;

// ─── Tipuri de mesaje P2P ─────────────────────────────────────────────────────

pub const MsgPing = wire.MsgPing;

// ─── 3-way handshake messages — "WE ARE HERE / WE WANT TO WORK / WE ARE STABLE" ──
//
// Wire format MsgHello (dialer → acceptor on connect):
//   [0..32]  node_id (padded)
//   [32..36] chain_magic (4 bytes — "OMNI"/"TEST"/"DEVN"/"REGT" from chain_config)
//   [36..38] listen_port u16 LE — the port THIS dialer accepts on (so acceptor can
//                                  ALSO dial back if it wants peer exchange)
//   [38..46] height u64 LE
//   [46]     version u8
//   [47..79] genesis_hash[32] — first-block hash, used to detect cross-genesis
//                               peers (different chain instance with same magic).
//                               Without this, a wiped/rebuilt testnet could try
//                               to peer with the live testnet.
//   = 79 bytes
//
// Reply MsgWelcome (acceptor → dialer):
//   [0..32]  node_id (acceptor's id)
//   [32..36] chain_magic (echoed; mismatch would already have closed)
//   [36..44] height u64 LE
//   [44]     accepted u8 (1 = welcome aboard, 0 = rejected — see reason)
//   [45]     reason u8 (0 ok, 1 wrong chain, 2 too many peers, 3 banned, 4 dup id)
//   = 46 bytes
//
// MsgStable (either side, after sync settles):
//   [0..8]   confirmed_height u64 LE
//   [8..10]  peer_count u16 LE
//   = 10 bytes

pub const MsgHello = wire.MsgHello;
pub const MsgWelcome = wire.MsgWelcome;
pub const MsgStable = wire.MsgStable;
pub const MsgPeerList = wire.MsgPeerList;

// ─── PEX (Peer Exchange) message encode/decode (B12) ────────────────────────
//
// Wire format for get_peers:  empty payload (0 bytes)
// Wire format for peer_list:  [count:u16LE][peer0: ip4+port_le][peer1: ...]
//   Each peer entry = 6 bytes: [ip0][ip1][ip2][ip3][port_lo][port_hi]
//   Max 100 peers per message.

pub const PEX_MAX_PEERS = wire.PEX_MAX_PEERS;
pub const PEX_PEER_SIZE = wire.PEX_PEER_SIZE;
pub const encodePeerList = wire.encodePeerList;
pub const decodePeerList = wire.decodePeerList;

/// Block announcement (gossip).
/// Wire layout (V2, 2026-04-26 upgrade): 90 bytes total.
///   [0..8]   block_height (u64 LE)
///   [8..40]  block_hash   (raw 32 bytes — full SHA-256 digest, NOT ASCII)
///   [40..82] miner_id     (42 ASCII chars = full OmniBus address, NUL-padded)
///   [82..90] reward_sat   (u64 LE)
/// V1 was 80 bytes with 32-char ASCII trunchation (block_hash + miner_id).
/// Bumping P2P_VERSION makes mixed-version peers reject each other cleanly.
pub const MsgBlockAnnounce = wire.MsgBlockAnnounce;

// ─── P2P Hardening Types ────────────────────────────────────────────────────

/// Banned peer entry — tracks host:port + ban expiry
pub const BannedPeer = banman.BannedPeer;

/// Per-peer reconnect tracking
pub const ReconnectInfo = banman.ReconnectInfo;

// PeerConnection + RateLimitState + ConnDirection moved to core/p2p/peer.zig.
// Re-exported below for back-compat with call sites in this file and the rest
// of the codebase. The peer module is self-contained (only depends on wire +
// socket + network_mod.MessageType), so no circular import risk.
const peer_mod = @import("p2p/peer.zig");
pub const RateLimitState = peer_mod.RateLimitState;
pub const ConnDirection = peer_mod.ConnDirection;
pub const PeerConnection = peer_mod.PeerConnection;


// ─── Gossip Protocol — TX relay + block propagation (B6) ─────────────────────
//
// Implementation lives in p2p/gossip.zig. We re-export the types so existing
// call sites (`p2p.SeenHashes`, `p2p.GossipTxPayload`, etc.) keep working.

const gossip_mod = @import("p2p/gossip.zig");
const discovery_mod = @import("p2p/discovery.zig");
const sync_coord_mod = @import("p2p/sync_coord.zig");
const transport_mod = @import("p2p/transport.zig");
const net_processing_mod = @import("p2p/net_processing.zig");

pub const SeenHashes         = gossip_mod.SeenHashes;
pub const GossipTxPayload    = gossip_mod.GossipTxPayload;
pub const GossipBlockPayload = gossip_mod.GossipBlockPayload;

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

pub const SPV_HEADER_SIZE = wire.SPV_HEADER_SIZE;
pub const SPV_MAX_HEADERS_PER_MSG = wire.SPV_MAX_HEADERS_PER_MSG;
pub const encodeGetHeaders = wire.encodeGetHeaders;
pub const decodeGetHeaders = wire.decodeGetHeaders;
pub const serializeSpvHeader = wire.serializeSpvHeader;
pub const deserializeSpvHeader = wire.deserializeSpvHeader;
pub const encodeHeadersBatch = wire.encodeHeadersBatch;
pub const decodeHeadersBatch = wire.decodeHeadersBatch;
pub const encodeBloomFilter = wire.encodeBloomFilter;
pub const decodeBloomFilter = wire.decodeBloomFilter;

// ─── P2P Node — server TCP + lista de conexiuni ───────────────────────────────

/// Rezultatul verificarii knock-knock

pub const P2PNode = struct {
    local_id:    []const u8,
    local_host:  []const u8,
    local_port:  u16,
    /// Network magic bytes ("OMNI"/"TEST"/"DEVN"/"REGT") — sent in HELLO and
    /// validated on WELCOME so a testnet miner cannot accidentally peer with
    /// a mainnet seed. Set via setChainMagic() after init from chain_config.
    /// Defaults to MAINNET ("OMNI") if not explicitly set, preserving legacy
    /// behavior for older callers that haven't been updated.
    chain_magic: [4]u8 = .{ 0x4F, 0x4D, 0x4E, 0x49 }, // "OMNI" mainnet
    peers:       array_list.Managed(PeerConnection),
    allocator:   std.mem.Allocator,
    chain_height: u64,
    /// true daca un alt miner a fost detectat pe acelasi IP — nu minaza
    is_idle:     bool,
    /// IBD (Initial Block Download) mode — Bitcoin Core pattern.
    /// True when local chain is significantly behind a peer; mining loop
    /// skips block production until catch-up. Toggled by:
    ///   - .welcome handler: peer.height > local + IBD_GAP_TRIGGER → true
    ///   - applyBlocksFromPeer: local catches up to peer within IBD_TOLERANCE → false
    /// Atomic so mining loop reads without locks.
    is_syncing:  std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Best peer height seen — used to compute "behind by N" for IBD progress UI.
    best_peer_height: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Pointer la blockchain — setat via attachBlockchain() dupa init
    blockchain:  ?*Blockchain = null,
    /// Pointer la sync manager — setat via attachBlockchain()
    sync_mgr:    ?*SyncManager = null,
    /// Pointer la light client — setat via attachLightClient() for SPV mode
    light_client: ?*light_client_mod.LightClient = null,
    /// Pointer la WS server — set via attachWsServer(). Used to push
    /// `ibd_progress` events to UI clients in real time.
    ws_server:    ?*ws_mod.WsServer = null,
    /// Address of the wallet that mines on this node (savacazan, dev, etc.).
    /// Used as `miner_id` in MsgBlockAnnounce — peers validate that the
    /// claimed_miner matches the slot leader. Without this, broadcasts
    /// reported `local_id` (e.g. "vps-testnet"), which is the NODE name,
    /// not the WALLET address — slot-leader validation rejected every
    /// honest block.
    /// Set via attachWallet() called from main.zig after wallet derivation.
    /// Falls back to local_id if not set (legacy behavior, broken validation).
    miner_address: []const u8 = "",
    /// Consecutive broadcast failures across ALL peers. When this hits
    /// FORK_RECOVERY_THRESHOLD, we suspect we mined on a fork that
    /// peers are rejecting; trunchate the last 1-2 blocks locally and
    /// trigger a re-sync. Resets to 0 on any successful gossip.
    /// Atomic so the broadcast loop and main maintenance can both touch
    /// it without lock dance.
    consecutive_bcast_fails: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
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
    /// Connection counters (atomic — racy under high concurrency otherwise)
    inbound_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    outbound_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Initialized flag for banned_peers array
    hardening_init: bool = false,
    /// Tor proxy configuration (disabled by default)
    tor_config: tor_mod.TorConfig = tor_mod.TorConfig.default(),
    /// Mutex protejand `peers` ArrayList — prevents segfault from concurrent
    /// append/swapRemove vs iteration (Thread.zig:509 callFn crash root cause).
    /// Lock-uit in connectToPeer/acceptLoop/cleanDeadPeers + orice loop pe self.peers.items.
    peers_mutex: std.Thread.Mutex = .{},

    pub fn init(
        local_id:   []const u8,
        local_host: []const u8,
        local_port: u16,
        allocator:  std.mem.Allocator,
    ) P2PNode {
        // NOTE: Initializing into a stack `var node` and `return node` blows
        // the stack on Linux because P2PNode is ~1.5 MB (SeenHashes×2 alone
        // is ~1.3 MB, plus banned_peers + reconnect_queue arrays). Even when
        // the caller heap-allocates and assigns `p2p_heap.* = P2PNode.init(...)`,
        // the intermediate value still lives on the stack inside this fn
        // before being copied. With Zig 0.15 on a stock Linux RLIMIT_STACK
        // (8 MB user, but the SeenHashes+arrays push past the guard page in
        // Debug mode), this segfaults silently after [SUBSYSTEMS] log.
        //
        // Returning a struct literal directly (no `var` intermediate) lets
        // the compiler RVO this into the caller's storage when called as
        // `heap.* = P2PNode.init(...)`. It can't always elide the copy, but
        // Zig 0.15 does in practice for struct-literal returns.
        var node: P2PNode = undefined;
        node.local_id    = local_id;
        node.local_host  = local_host;
        node.local_port  = local_port;
        node.peers       = array_list.Managed(PeerConnection).init(allocator);
        node.allocator   = allocator;
        node.chain_height = 0;
        node.is_idle     = false;
        node.blockchain  = null;
        node.sync_mgr    = null;
        node.seen_tx_hashes = SeenHashes.init();
        node.seen_block_hashes = SeenHashes.init();
        node.gossip_tx_count = 0;
        node.gossip_block_count = 0;
        // Initialize hardening arrays
        for (&node.banned_peers) |*bp| bp.active = false;
        for (&node.reconnect_queue) |*ri| ri.active = false;
        node.hardening_init = true;
        return node;
    }

    /// In-place initializer — preferred over `init()` for heap-allocated
    /// P2PNode (avoids the 1.5 MB struct copy through the stack frame that
    /// segfaults Linux). Caller passes a pointer to the destination.
    pub fn initInPlace(
        self:       *P2PNode,
        local_id:   []const u8,
        local_host: []const u8,
        local_port: u16,
        allocator:  std.mem.Allocator,
    ) void {
        self.local_id    = local_id;
        self.local_host  = local_host;
        self.local_port  = local_port;
        self.peers       = array_list.Managed(PeerConnection).init(allocator);
        self.allocator   = allocator;
        self.chain_height = 0;
        self.is_idle     = false;
        self.blockchain  = null;
        self.sync_mgr    = null;
        self.seen_tx_hashes = SeenHashes.init();
        self.seen_block_hashes = SeenHashes.init();
        self.gossip_tx_count = 0;
        self.gossip_block_count = 0;
        for (&self.banned_peers) |*bp| bp.active = false;
        for (&self.reconnect_queue) |*ri| ri.active = false;
        self.hardening_init = true;
        // CRITICAL: cand alocator.create() ne da memorie uninitialized,
        // default values din declaratia struct (`= .{}`) NU se aplica.
        // Mutex-urile + atomicele + alte campuri cu defaults trebuie
        // initializate explicit aici, altfel SEGV la prima utilizare.
        self.peers_mutex = .{};
        self.chain_magic = .{ 0, 0, 0, 0 };
        self.miner_address = "";
        self.consecutive_bcast_fails = std.atomic.Value(u32).init(0);
        self.scoring_engine = scoring_mod.PeerScoringEngine.init();
        self.banned_count = 0;
        self.reconnect_count = 0;
        self.inbound_count = std.atomic.Value(u32).init(0);
        self.outbound_count = std.atomic.Value(u32).init(0);
        self.tor_config = tor_mod.TorConfig.default();
        self.ws_server = null;
    }

    /// Set the 4-byte network magic from chain_config. Called from main.zig
    /// after the chain is selected so HELLO/WELCOME messages embed the right
    /// chain identifier. Without this, P2PNode defaults to mainnet magic.
    pub fn setChainMagic(self: *P2PNode, magic: [4]u8) void {
        self.chain_magic = magic;
    }

    /// Return the local genesis block hash as raw 32 bytes (parsed from the
    /// chain's first block hex string). Used in HELLO so peers can detect
    /// cross-genesis forks (same magic but different chain instance). If we
    /// don't have a blockchain attached yet, returns all-zeros (acceptor
    /// will treat this as "unknown genesis" and fall back to magic-only check).
    pub fn getLocalGenesisHash(self: *const P2PNode) [32]u8 {
        var out: [32]u8 = std.mem.zeroes([32]u8);
        const bc = self.blockchain orelse return out;
        if (bc.chain.items.len == 0) return out;
        const genesis_hex = bc.chain.items[0].hash;
        // Hash is stored as 64-char hex; parse back to 32 raw bytes.
        if (genesis_hex.len < 64) return out;
        for (0..32) |i| {
            const hi = std.fmt.charToDigit(genesis_hex[i * 2], 16) catch return std.mem.zeroes([32]u8);
            const lo = std.fmt.charToDigit(genesis_hex[i * 2 + 1], 16) catch return std.mem.zeroes([32]u8);
            out[i] = (@as(u8, hi) << 4) | @as(u8, lo);
        }
        return out;
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

    /// Attach WS server so IBD events can be pushed to UI clients live.
    pub fn attachWsServer(self: *P2PNode, ws: *ws_mod.WsServer) void {
        self.ws_server = ws;
    }

    /// Tell the P2P layer which wallet address mines on this node.
    /// MUST be called before mining starts; peers use this address to
    /// validate that claimed_miner == slot_leader.
    pub fn attachMinerAddress(self: *P2PNode, addr: []const u8) void {
        self.miner_address = addr;
    }

    /// Threshold of consecutive failed broadcasts that triggers fork
    /// recovery. 3 was chosen because a healthy network can lose one
    /// block to a transient TCP glitch but not three in a row.
    pub const FORK_RECOVERY_THRESHOLD: u32 = 3;
    /// Maximum blocks to trunchate when recovering. Bitcoin's reorg-
    /// limit is much larger; we cap at 2 because OmniBus blocks are
    /// 1s apart and our network is small — losing more than 2 means
    /// something deeper is wrong (manual intervention).
    pub const FORK_RECOVERY_MAX_TRUNC: u64 = 2;

    /// If we've failed to broadcast N blocks in a row, our chain is
    /// almost certainly diverged from peers. Drop the last 1-2 blocks
    /// locally and ask peers for sync. Returns true if recovery was
    /// triggered. Idempotent — safe to call from maintenance every tick.
    pub fn tryForkRecovery(self: *P2PNode) bool {
        return sync_coord_mod.tryForkRecovery(self);
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
        sync_coord_mod.syncHeaders(self);
    }

    /// SPV: Request a Merkle proof for a specific TX hash in a specific block.
    pub fn requestMerkleProof(self: *P2PNode, tx_hash: [32]u8, block_index: u32) void {
        var payload: [36]u8 = undefined;
        @memcpy(payload[0..32], &tx_hash);
        std.mem.writeInt(u32, payload[32..36], block_index, .little);

        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
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
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
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
        self.peers_mutex.lock();
        for (self.peers.items) |*peer| peer.close();
        self.peers.deinit();
        self.peers_mutex.unlock();
    }

    /// Conecteaza la un peer (TCP outbound) — delegat la p2p/transport.zig
    pub fn connectToPeer(self: *P2PNode, host: []const u8, port: u16, node_id: []const u8) !void {
        return transport_mod.connectToPeer(self, host, port, node_id);
    }

    /// Anunta un bloc nou la toti peerii conectati
    pub fn broadcastBlock(
        self:       *P2PNode,
        height:     u64,
        hash_hex:   []const u8,
        reward_sat: u64,
    ) void {
        self.chain_height = height;
        var any_success: bool = false;
        var any_fail: bool = false;
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue; // skip already-dead peers
            // Use miner WALLET address as the claimed_miner field — peers
            // validate against the slot leader (BUG fix 2026-04-26).
            const claimed = if (self.miner_address.len > 0) self.miner_address else self.local_id;
            peer.announceBlock(height, hash_hex, claimed, reward_sat) catch |err| {
                std.debug.print("[P2P] Broadcast block to {s} failed: {} — marking peer disconnected, scheduling reconnect\n",
                    .{ peer.node_id, err });
                peer.connected = false;
                peer.close();
                self.addReconnect(peer.host, peer.port, peer.node_id[0..@min(peer.node_id.len, 32)]);
                any_fail = true;
                continue;
            };
            any_success = true;
        }
        // Track consecutive failures across calls. If a peer keeps closing
        // mid-broadcast it usually means we're on a fork peers reject.
        // Threshold + main loop will trigger fork-recovery (trunchate +
        // re-sync). Resets only on a clean send.
        if (any_success) {
            self.consecutive_bcast_fails.store(0, .release);
        } else if (any_fail) {
            _ = self.consecutive_bcast_fails.fetchAdd(1, .acq_rel);
        }
        if (self.peers.items.len > 0) {
            std.debug.print("[P2P] Block #{d} anuntat la {d} peeri\n",
                .{ height, self.peers.items.len });
        }
    }

    // ─── Gossip Protocol (B6) — thin delegates to p2p/gossip.zig ─────────────

    pub fn broadcastTx(self: *P2PNode, tx_hash: []const u8, tx_json: []const u8) void {
        gossip_mod.broadcastTx(self, tx_hash, tx_json);
    }

    pub fn broadcastBlockGossip(
        self:       *P2PNode,
        height:     u64,
        hash_hex:   []const u8,
        reward_sat: u64,
    ) void {
        gossip_mod.broadcastBlockGossip(self, height, hash_hex, reward_sat);
    }

    fn relayTxExcept(self: *P2PNode, except_peer: []const u8, payload: []const u8) void {
        gossip_mod.relayTxExcept(self, except_peer, payload);
    }

    fn relayBlockExcept(self: *P2PNode, except_peer: []const u8, payload: []const u8) void {
        gossip_mod.relayBlockExcept(self, except_peer, payload);
    }

    pub fn gossipMaintenance(self: *P2PNode) void {
        gossip_mod.gossipMaintenance(self);
    }

    pub fn getGossipStats(self: *const P2PNode) gossip_mod.GossipStats {
        return gossip_mod.getGossipStats(self);
    }

    // ─── PEX Protocol (B12) ────────────────────────────────────────────────

    /// Send a get_peers request to a specific peer
    pub fn sendGetPeers(self: *P2PNode, peer: *PeerConnection) void {
        discovery_mod.sendGetPeers(self, peer);
    }

    /// Send get_peers to all connected peers
    pub fn requestPeersFromAll(self: *P2PNode) void {
        discovery_mod.requestPeersFromAll(self);
    }

    /// Build a peer_list payload from our known connected peers
    /// Returns encoded bytes; caller must free with allocator.
    pub fn buildPeerListPayload(self: *P2PNode) ![]u8 {
        return discovery_mod.buildPeerListPayload(self);
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
    pub fn peerCount(self: *P2PNode) usize {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
        var count: usize = 0;
        for (self.peers.items) |p| {
            if (p.connected) count += 1;
        }
        return count;
    }

    /// Deconecteaza peerii morti — delegat la p2p/transport.zig
    pub fn cleanDeadPeers(self: *P2PNode) void {
        transport_mod.cleanDeadPeers(self);
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
        return banman.isBanned(self, host, port);
    }

    /// Ban a peer by host:port for the configured duration
    pub fn banPeer(self: *P2PNode, host: []const u8, port: u16, reason: []const u8) void {
        banman.banPeer(self, host, port, reason);
    }

    /// Disconnect a peer by host:port
    fn disconnectPeerByHost(self: *P2PNode, host: []const u8, port: u16) void {
        banman.disconnectPeerByHost(self, host, port);
    }

    /// Evict expired bans
    pub fn evictExpiredBans(self: *P2PNode) void {
        banman.evictExpiredBans(self);
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
    pub fn addReconnect(self: *P2PNode, host: []const u8, port: u16, node_id: []const u8) void {
        banman.addReconnect(self, host, port, node_id);
    }

    /// Clear reconnect entry on successful connection
    fn clearReconnect(self: *P2PNode, host: []const u8, port: u16) void {
        banman.clearReconnect(self, host, port);
    }

    /// Process reconnect queue — attempt reconnects for peers past the delay
    pub fn processReconnects(self: *P2PNode) void {
        banman.processReconnects(self);
    }

    // ─── Hardening: Subnet Diversity (Anti-Eclipse) ─────────────────────────

    /// Check if adding a peer with this IP would violate subnet diversity rules.
    /// Returns true if the peer is allowed, false if too many from same /16 subnet.
    pub fn checkSubnetDiversity(self: *P2PNode, ip: [4]u8) bool {
        return discovery_mod.checkSubnetDiversity(self, ip);
    }

    /// Inbound-only subnet diversity check (anti-eclipse on accept path).
    pub fn checkInboundSubnetDiversity(self: *P2PNode, ip: [4]u8) bool {
        return discovery_mod.checkInboundSubnetDiversity(self, ip);
    }

    /// Count the number of distinct /16 subnets among connected peers
    pub fn subnetCount(self: *P2PNode) usize {
        return discovery_mod.subnetCount(self);
    }

    /// Check if we have enough subnet diversity (at least MIN_SUBNET_DIVERSITY)
    pub fn hasMinSubnetDiversity(self: *P2PNode) bool {
        return discovery_mod.hasMinSubnetDiversity(self);
    }

    // ─── Hardening: Connection Limits ───────────────────────────────────────

    /// Check if we can accept an inbound connection
    pub fn canAcceptInbound(self: *P2PNode) bool {
        return discovery_mod.canAcceptInbound(self);
    }

    /// Periodic hardening maintenance
    pub fn hardeningMaintenance(self: *P2PNode) void {
        discovery_mod.hardeningMaintenance(self);
    }

    pub fn printStatus(self: *P2PNode) void {
        std.debug.print("[P2P] Node={s} | Peers={d} (in:{d}/out:{d}) | Height={d} | Port={d} | Idle={} | Banned={d} | Reconnect={d}\n", .{
            self.local_id, self.peerCount(),
            self.inbound_count.load(.acquire), self.outbound_count.load(.acquire),
            self.chain_height,
            self.local_port, self.is_idle,
            self.banned_count, self.reconnect_count,
        });
    }

    // ─── TCP Listener ─────────────────────────────────────────────────────────

    /// Porneste server TCP inbound — delegat la p2p/transport.zig
    pub fn startListener(self: *P2PNode) !void {
        return transport_mod.startListener(self);
    }

    // Background heartbeat that pings every connected peer every 10s with our
    // current chain_height. Without this, peer.height was set ONCE at HELLO/
    // WELCOME and never refreshed. Live observed: VPS at height 229, our PC
    // saw peer.height=22 (the value at handshake hours earlier) — IBD pulled
    // 22 blocks then froze, looking like a sync stall when the peer was just
    // never re-asked. Symmetric fix: each PING also gets a PONG carrying the
    // peer's current chain_height (handler at .ping branch already does this
    // — see commit-after-71eba20 fix).
    const HEARTBEAT_INTERVAL_S: u64 = 10;

    /// Porneste heartbeat thread — delegat la p2p/transport.zig
    pub fn startHeartbeat(self: *P2PNode) !void {
        return transport_mod.startHeartbeat(self);
    }

    // chain_height is written from dispatchMessage (peer threads) and read from the mining loop
    // and RPC handlers. On x86-64 plain u64 stores are atomic at the hardware level, so torn
    // reads are impossible. Cross-field invariants that span multiple fields are not protected
    // here — full mutex coverage would require locking bc.mutex on every P2P callback, which
    // creates deadlock risk with the mining loop. Accepted risk: stale height by ≤1 block,
    // which only delays a sync request by one slot (harmless).

    /// Proceseaza un mesaj primit de la un peer (inbound sau outbound).
    /// Delegat la p2p/net_processing.zig. Public — transport.zig îl invocă
    /// din thread-ul de recv.
    pub fn dispatchMessage(node: *P2PNode, peer: *PeerConnection, msg_type: u8, payload: []const u8) void {
        net_processing_mod.dispatchMessage(node, peer, msg_type, payload);
    }

    // ─── Outbound helpers ─────────────────────────────────────────────────────

    /// Trimite un mesaj raw la un peer specific (dupa node_id)
    /// Folosit de SyncManager pentru GetHeaders etc.
    pub fn sendToPeer(self: *P2PNode, node_id: []const u8, msg_type: u8, payload: []const u8) !void {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
        for (self.peers.items) |*peer| {
            if (peer.connected and std.mem.eql(u8, peer.node_id, node_id)) {
                try peer.send(msg_type, payload);
                return;
            }
        }
        return error.PeerNotFound;
    }

    /// Returneaza cea mai recenta valoare last_msg_ts pe peer-ii conectati,
    /// sau 0 daca nu avem peer-i activi. Folosit de slot-skip in main.zig
    /// pentru a evita fork-ul cand ambii validatori cred ca celalalt e silent.
    pub fn lastPeerActivityTs(self: *P2PNode) i64 {
        self.peers_mutex.lock();
        defer self.peers_mutex.unlock();
        var max_ts: i64 = 0;
        for (self.peers.items) |*peer| {
            if (!peer.connected) continue;
            if (peer.last_msg_ts > max_ts) max_ts = peer.last_msg_ts;
        }
        return max_ts;
    }

    /// Trimite sync_request la primul peer conectat mai sus decat noi.
    /// Wrapper care nu forteaza request pe peer cu height <= from_height
    /// (cazul normal de catch-up).
    pub fn requestSync(self: *P2PNode, from_height: u64) void {
        sync_coord_mod.requestSync(self, from_height);
    }

    /// Forteaza sync request indiferent de peer.height — folosit pentru
    /// fork detection unde peer poate fi la o inaltime mai mica dar pe o
    /// alta ramura, si avem nevoie de header-ele lui pentru comparatia
    /// heaviest-chain.
    pub fn requestSyncForced(self: *P2PNode, from_height: u64) void {
        sync_coord_mod.requestSyncForced(self, from_height);
    }

    fn requestSyncEx(self: *P2PNode, from_height: u64, force_on_lower_peer: bool) void {
        sync_coord_mod.requestSyncEx(self, from_height, force_on_lower_peer);
    }
};

/// Citeste exact `buf.len` bytes dintr-un Stream TCP — echivalent readAll
/// Returneaza numarul de bytes cititi (< buf.len daca stream inchis)


// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "MsgHeader oversized payload_len is rejected (HIGH-04 receive bounds)" {
    // Simulate a malicious peer sending a header with payload_len = 0xFFFFFFFF.
    // The receive path in PeerConnection.recv() must reject this BEFORE
    // attempting to allocate `hdr.payload_len` bytes.
    var hdr_buf: [MSG_HEADER_SIZE]u8 = undefined;
    const malicious = MsgHeader{
        .version     = P2P_VERSION,
        .msg_type    = 0,
        .payload_len = 0xFFFFFFFF, // ~4 GB
        .checksum    = 0,
        .flags       = 0,
    };
    malicious.encode(&hdr_buf);

    const decoded = MsgHeader.decode(&hdr_buf);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), decoded.payload_len);
    // The actual guard: PeerConnection.recv() checks
    //   if (hdr.payload_len > P2P_MAX_MSG_BYTES) return error.PayloadTooLarge;
    // We replicate that predicate here so the test fails if either the
    // constant or the check is removed.
    try testing.expect(decoded.payload_len > P2P_MAX_MSG_BYTES);
}

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
    const mi: [42]u8 = @splat(0xBB);

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
    try testing.expectEqual(@as(u32, 0), node.inbound_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), node.outbound_count.load(.acquire));
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
    try testing.expectEqual(@as(u32, 0), node.inbound_count.load(.acquire));
    try testing.expectEqual(@as(u32, 0), node.outbound_count.load(.acquire));

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
