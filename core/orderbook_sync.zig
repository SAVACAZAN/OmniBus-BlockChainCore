/// orderbook_sync.zig — Sincronizarea P2P a orderbook-ului intre mineri
///
/// Toate nodurile de mining trebuie sa aiba orderbook-uri identice.
/// Acest modul asigura sincronizarea prin Kademlia DHT broadcast:
///   - Ordine noi → broadcast la toti peerii
///   - Anulari → broadcast
///   - Fiecare miner mentine orderbook-ul complet
///   - Merkle root al orderbook-ului inclus in block header
///   - Daca merkle root nu se potriveste → block invalid
///
/// Modul self-contained — nu importa din kademlia_dht.zig (evita dependente circulare).
/// Transportul P2P e gestionat de p2p.zig — acest modul gestioneaza PROTOCOLUL si STAREA.
const std = @import("std");

// ============================================================================
// Constante
// ============================================================================

/// Total orders tracked in synced orderbook
pub const MAX_SYNCED_ORDERS: usize = 20_000;
/// Orders per batch message (initial sync)
pub const MAX_BATCH_SIZE: usize = 100;
/// Maximum tracked peers
pub const MAX_PEERS: usize = 64;
/// Dedup circular buffer size
pub const MAX_SEEN_HASHES: usize = 10_000;
/// Pending outbound messages
pub const MAX_OUTBOX: usize = 256;
/// Check sync interval (ms)
pub const SYNC_INTERVAL_MS: i64 = 5_000;
/// Verify merkle root interval (ms)
pub const MERKLE_CHECK_INTERVAL_MS: i64 = 10_000;
/// If sequence gap exceeds this, request full sync
pub const MAX_SEQUENCE_GAP: u64 = 100;
/// Kademlia node ID size (160 bits = 20 bytes)
pub const NODE_ID_SIZE: usize = 20;

// ============================================================================
// Tipuri de mesaje P2P pentru sincronizarea orderbook-ului
// ============================================================================

pub const SyncMessageType = enum(u8) {
    new_order = 0,
    cancel_order = 1,
    order_batch = 2,
    merkle_request = 3,
    merkle_response = 4,
    sync_request = 5,
    sync_response = 6,
};

/// Entry in the synced orderbook
pub const OrderEntry = struct {
    order_id: u64,
    trader_address: [64]u8,
    trader_addr_len: u8,
    pair_id: u16,
    side: u8, // 0 = buy, 1 = sell
    price_micro_usd: u64,
    amount_sat: u64,
    filled_sat: u64,
    timestamp_ms: i64,
    status: u8, // 0=active, 1=partial, 2=filled, 3=cancelled
    /// Node that originated this order
    origin_node: [NODE_ID_SIZE]u8,
};

/// Batch of orders for initial sync
pub const OrderBatch = struct {
    orders: [MAX_BATCH_SIZE]OrderEntry,
    count: u32,
};

/// Payload union (tagged by SyncMessageType)
pub const SyncPayload = union {
    order: OrderEntry,
    cancel_id: u64,
    merkle_root: [32]u8,
    batch: OrderBatch,
    empty: void,
};

/// Mesaj de sincronizare orderbook
pub const SyncMessage = struct {
    msg_type: SyncMessageType,
    sender_id: [NODE_ID_SIZE]u8,
    sequence: u64,
    timestamp_ms: i64,
    payload: SyncPayload,
    msg_hash: [32]u8,

    /// Calculate SHA-256 hash of the message content (for dedup)
    pub fn calculateHash(self: *const SyncMessage) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Hash msg_type
        hasher.update(&[_]u8{@intFromEnum(self.msg_type)});

        // Hash sender_id
        hasher.update(&self.sender_id);

        // Hash sequence (little-endian)
        const seq_bytes = std.mem.toBytes(self.sequence);
        hasher.update(&seq_bytes);

        // Hash timestamp
        const ts_bytes = std.mem.toBytes(self.timestamp_ms);
        hasher.update(&ts_bytes);

        // Hash payload based on type
        switch (self.msg_type) {
            .new_order, .sync_response => {
                const order = self.payload.order;
                const id_bytes = std.mem.toBytes(order.order_id);
                hasher.update(&id_bytes);
                hasher.update(order.trader_address[0..order.trader_addr_len]);
                const pair_bytes = std.mem.toBytes(order.pair_id);
                hasher.update(&pair_bytes);
                hasher.update(&[_]u8{order.side});
                const price_bytes = std.mem.toBytes(order.price_micro_usd);
                hasher.update(&price_bytes);
                const amt_bytes = std.mem.toBytes(order.amount_sat);
                hasher.update(&amt_bytes);
            },
            .cancel_order => {
                const cancel_bytes = std.mem.toBytes(self.payload.cancel_id);
                hasher.update(&cancel_bytes);
            },
            .merkle_request, .merkle_response => {
                hasher.update(&self.payload.merkle_root);
            },
            .order_batch => {
                const batch = self.payload.batch;
                const cnt_bytes = std.mem.toBytes(batch.count);
                hasher.update(&cnt_bytes);
                for (0..batch.count) |i| {
                    const oid_bytes = std.mem.toBytes(batch.orders[i].order_id);
                    hasher.update(&oid_bytes);
                }
            },
            .sync_request => {
                // No extra payload, sender_id + sequence are enough
            },
        }

        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
};

/// Peer sync state — track what each peer has
pub const PeerSyncState = struct {
    peer_id: [NODE_ID_SIZE]u8,
    last_sequence: u64,
    last_merkle_root: [32]u8,
    last_sync_ms: i64,
    in_sync: bool,
    missed_messages: u32,
};

// ============================================================================
// Erori
// ============================================================================

pub const SyncError = error{
    OrderbookFull,
    OutboxFull,
    OrderNotFound,
    DuplicateOrder,
    InvalidMessage,
    PeerListFull,
};

// ============================================================================
// Manager principal de sincronizare
// ============================================================================

pub const OrderbookSyncManager = struct {
    // Local orderbook state (mirror of matching engine)
    orders: [MAX_SYNCED_ORDERS]OrderEntry,
    order_count: u32,
    order_valid: [MAX_SYNCED_ORDERS]bool,

    // Message dedup (circular buffer of seen message hashes)
    seen_hashes: [MAX_SEEN_HASHES][32]u8,
    seen_count: u32,
    seen_head: u32,

    // Peer sync tracking
    peers: [MAX_PEERS]PeerSyncState,
    peer_count: u32,

    // Outbound message queue
    outbox: [MAX_OUTBOX]SyncMessage,
    outbox_count: u32,

    // Local state
    local_node_id: [NODE_ID_SIZE]u8,
    local_sequence: u64,
    current_merkle_root: [32]u8,

    const Self = @This();

    /// Initializeaza un OrderbookSyncManager cu un node ID dat
    pub fn init(node_id: [NODE_ID_SIZE]u8) OrderbookSyncManager {
        var mgr: OrderbookSyncManager = undefined;

        mgr.order_count = 0;
        for (0..MAX_SYNCED_ORDERS) |i| {
            mgr.order_valid[i] = false;
        }

        mgr.seen_count = 0;
        mgr.seen_head = 0;

        mgr.peer_count = 0;
        mgr.outbox_count = 0;

        mgr.local_node_id = node_id;
        mgr.local_sequence = 0;
        mgr.current_merkle_root = std.mem.zeroes([32]u8);

        return mgr;
    }

    // ========================================================================
    // Inbound message handling
    // ========================================================================

    /// Handle an incoming sync message from a peer
    pub fn handleMessage(self: *Self, msg: SyncMessage) SyncError!void {
        // Dedup check
        if (self.isDuplicate(msg.msg_hash)) return;

        // Record hash in seen buffer
        self.recordSeen(msg.msg_hash);

        // Update peer state
        self.updatePeerState(msg.sender_id, msg.sequence);

        // Dispatch by type
        switch (msg.msg_type) {
            .new_order => try self.handleNewOrder(msg.payload.order),
            .cancel_order => try self.handleCancelOrder(msg.payload.cancel_id),
            .sync_request => try self.handleSyncRequest(msg.sender_id),
            .merkle_response => self.handleMerkleResponse(msg.sender_id, msg.payload.merkle_root),
            .order_batch => try self.handleOrderBatch(msg.payload.batch),
            .merkle_request => try self.respondMerkleRoot(msg.sender_id),
            .sync_response => try self.handleNewOrder(msg.payload.order),
        }
    }

    /// Handle a new order from a peer — add to local orderbook
    pub fn handleNewOrder(self: *Self, entry: OrderEntry) SyncError!void {
        // Check for duplicate order_id
        if (self.getOrder(entry.order_id) != null) return SyncError.DuplicateOrder;
        try self.addOrder(entry);
        self.current_merkle_root = self.recalcMerkleRoot();
    }

    /// Handle a cancel order from a peer — remove from local orderbook
    pub fn handleCancelOrder(self: *Self, order_id: u64) SyncError!void {
        try self.removeOrder(order_id);
        self.current_merkle_root = self.recalcMerkleRoot();
    }

    /// Handle a sync request — queue full orderbook as batch messages for the peer
    pub fn handleSyncRequest(self: *Self, peer_id: [NODE_ID_SIZE]u8) SyncError!void {
        var batch: OrderBatch = undefined;
        batch.count = 0;

        for (0..MAX_SYNCED_ORDERS) |i| {
            if (!self.order_valid[i]) continue;

            batch.orders[batch.count] = self.orders[i];
            batch.count += 1;

            // Flush batch when full
            if (batch.count >= MAX_BATCH_SIZE) {
                try self.enqueueBatchMessage(peer_id, batch);
                batch.count = 0;
            }
        }

        // Flush remaining
        if (batch.count > 0) {
            try self.enqueueBatchMessage(peer_id, batch);
        }
    }

    /// Handle incoming batch of orders (initial sync)
    fn handleOrderBatch(self: *Self, batch: OrderBatch) SyncError!void {
        for (0..batch.count) |i| {
            // Skip duplicates silently during batch sync
            if (self.getOrder(batch.orders[i].order_id) == null) {
                self.addOrder(batch.orders[i]) catch break;
            }
        }
        self.current_merkle_root = self.recalcMerkleRoot();
    }

    /// Handle merkle response from a peer
    fn handleMerkleResponse(self: *Self, peer_id: [NODE_ID_SIZE]u8, root: [32]u8) void {
        for (0..self.peer_count) |i| {
            if (std.mem.eql(u8, &self.peers[i].peer_id, &peer_id)) {
                self.peers[i].last_merkle_root = root;
                self.peers[i].in_sync = std.mem.eql(u8, &root, &self.current_merkle_root);
                return;
            }
        }
    }

    /// Respond to a merkle request with our current merkle root
    fn respondMerkleRoot(self: *Self, peer_id: [NODE_ID_SIZE]u8) SyncError!void {
        _ = peer_id;
        var msg: SyncMessage = undefined;
        msg.msg_type = .merkle_response;
        msg.sender_id = self.local_node_id;
        self.local_sequence += 1;
        msg.sequence = self.local_sequence;
        msg.timestamp_ms = 0; // caller sets real timestamp
        msg.payload = .{ .merkle_root = self.current_merkle_root };
        msg.msg_hash = msg.calculateHash();
        try self.enqueueOutbox(msg);
    }

    // ========================================================================
    // Outbound message creation
    // ========================================================================

    /// Broadcast a new order to all peers (queues in outbox)
    pub fn broadcastNewOrder(self: *Self, entry: OrderEntry) SyncError!void {
        // Add to local orderbook first
        try self.addOrder(entry);
        self.current_merkle_root = self.recalcMerkleRoot();

        // Create broadcast message
        self.local_sequence += 1;
        var msg: SyncMessage = undefined;
        msg.msg_type = .new_order;
        msg.sender_id = self.local_node_id;
        msg.sequence = self.local_sequence;
        msg.timestamp_ms = entry.timestamp_ms;
        msg.payload = .{ .order = entry };
        msg.msg_hash = msg.calculateHash();

        try self.enqueueOutbox(msg);
    }

    /// Broadcast an order cancellation to all peers
    pub fn broadcastCancel(self: *Self, order_id: u64) SyncError!void {
        // Remove from local orderbook
        try self.removeOrder(order_id);
        self.current_merkle_root = self.recalcMerkleRoot();

        // Create broadcast message
        self.local_sequence += 1;
        var msg: SyncMessage = undefined;
        msg.msg_type = .cancel_order;
        msg.sender_id = self.local_node_id;
        msg.sequence = self.local_sequence;
        msg.timestamp_ms = 0;
        msg.payload = .{ .cancel_id = order_id };
        msg.msg_hash = msg.calculateHash();

        try self.enqueueOutbox(msg);
    }

    /// Request merkle root from a specific peer
    pub fn requestMerkleRoot(self: *Self, peer_id: [NODE_ID_SIZE]u8) SyncError!void {
        _ = peer_id;
        self.local_sequence += 1;
        var msg: SyncMessage = undefined;
        msg.msg_type = .merkle_request;
        msg.sender_id = self.local_node_id;
        msg.sequence = self.local_sequence;
        msg.timestamp_ms = 0;
        msg.payload = .{ .merkle_root = self.current_merkle_root };
        msg.msg_hash = msg.calculateHash();

        try self.enqueueOutbox(msg);
    }

    // ========================================================================
    // State management
    // ========================================================================

    /// Recalculate merkle root of all active orders.
    /// Deterministic ordering: sorted by (pair_id, side, price, timestamp).
    /// Uses a simple incremental hash approach (no tree needed for fixed arrays).
    pub fn recalcMerkleRoot(self: *Self) [32]u8 {
        // Collect indices of valid, active orders
        var indices: [MAX_SYNCED_ORDERS]usize = undefined;
        var idx_count: usize = 0;

        for (0..MAX_SYNCED_ORDERS) |i| {
            if (self.order_valid[i] and self.orders[i].status <= 1) {
                // Only active (0) and partial (1) orders
                indices[idx_count] = i;
                idx_count += 1;
            }
        }

        // Sort indices by (pair_id, side, price, timestamp) for determinism
        sortOrderIndices(indices[0..idx_count], &self.orders);

        // Hash all orders in sorted order
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        for (0..idx_count) |j| {
            const o = &self.orders[indices[j]];
            hasher.update(&std.mem.toBytes(o.order_id));
            hasher.update(&std.mem.toBytes(o.pair_id));
            hasher.update(&[_]u8{o.side});
            hasher.update(&std.mem.toBytes(o.price_micro_usd));
            hasher.update(&std.mem.toBytes(o.amount_sat));
            hasher.update(&std.mem.toBytes(o.filled_sat));
            hasher.update(&std.mem.toBytes(o.timestamp_ms));
            hasher.update(&[_]u8{o.status});
            hasher.update(o.trader_address[0..o.trader_addr_len]);
            hasher.update(&o.origin_node);
        }

        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    /// Check if a specific peer is in sync with us
    pub fn isInSync(self: *Self, peer_id: [NODE_ID_SIZE]u8) bool {
        for (0..self.peer_count) |i| {
            if (std.mem.eql(u8, &self.peers[i].peer_id, &peer_id)) {
                return self.peers[i].in_sync;
            }
        }
        return false;
    }

    /// Count how many peers are currently in sync
    pub fn syncedPeerCount(self: *Self) u32 {
        var count: u32 = 0;
        for (0..self.peer_count) |i| {
            if (self.peers[i].in_sync) count += 1;
        }
        return count;
    }

    /// Check if a message hash was already seen (dedup)
    pub fn isDuplicate(self: *Self, msg_hash: [32]u8) bool {
        const limit = if (self.seen_count < MAX_SEEN_HASHES) self.seen_count else MAX_SEEN_HASHES;
        for (0..limit) |i| {
            if (std.mem.eql(u8, &self.seen_hashes[i], &msg_hash)) return true;
        }
        return false;
    }

    /// Add an order to the local orderbook
    pub fn addOrder(self: *Self, entry: OrderEntry) SyncError!void {
        // Find a free slot
        for (0..MAX_SYNCED_ORDERS) |i| {
            if (!self.order_valid[i]) {
                self.orders[i] = entry;
                self.order_valid[i] = true;
                self.order_count += 1;
                return;
            }
        }
        return SyncError.OrderbookFull;
    }

    /// Remove an order by ID (mark as cancelled and invalidate slot)
    pub fn removeOrder(self: *Self, order_id: u64) SyncError!void {
        for (0..MAX_SYNCED_ORDERS) |i| {
            if (self.order_valid[i] and self.orders[i].order_id == order_id) {
                self.orders[i].status = 3; // cancelled
                self.order_valid[i] = false;
                self.order_count -= 1;
                return;
            }
        }
        return SyncError.OrderNotFound;
    }

    /// Get a pointer to an order by ID (or null if not found)
    pub fn getOrder(self: *Self, order_id: u64) ?*OrderEntry {
        for (0..MAX_SYNCED_ORDERS) |i| {
            if (self.order_valid[i] and self.orders[i].order_id == order_id) {
                return &self.orders[i];
            }
        }
        return null;
    }

    /// Get pending outbound messages as a slice
    pub fn drainOutbox(self: *Self) []SyncMessage {
        return self.outbox[0..self.outbox_count];
    }

    /// Clear the outbox after messages have been sent
    pub fn clearOutbox(self: *Self) void {
        self.outbox_count = 0;
    }

    /// Validate merkle consensus: at least 2/3 of peers must have matching root
    pub fn validateMerkleConsensus(self: *Self, peer_roots: []const [32]u8) bool {
        if (peer_roots.len == 0) return false;

        // Count how many peers match our root
        var matching: u32 = 0;
        for (peer_roots) |root| {
            if (std.mem.eql(u8, &root, &self.current_merkle_root)) {
                matching += 1;
            }
        }

        // 2/3 majority required
        const total: u32 = @intCast(peer_roots.len);
        return matching * 3 >= total * 2;
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    /// Record a message hash in the circular dedup buffer
    fn recordSeen(self: *Self, hash: [32]u8) void {
        self.seen_hashes[self.seen_head] = hash;
        self.seen_head = @intCast((@as(usize, self.seen_head) + 1) % MAX_SEEN_HASHES);
        if (self.seen_count < MAX_SEEN_HASHES) {
            self.seen_count += 1;
        }
    }

    /// Update (or add) peer sync state based on incoming message
    fn updatePeerState(self: *Self, peer_id: [NODE_ID_SIZE]u8, sequence: u64) void {
        // Find existing peer
        for (0..self.peer_count) |i| {
            if (std.mem.eql(u8, &self.peers[i].peer_id, &peer_id)) {
                // Check for sequence gap
                if (sequence > self.peers[i].last_sequence + 1) {
                    const gap = sequence - self.peers[i].last_sequence - 1;
                    self.peers[i].missed_messages += @intCast(if (gap > std.math.maxInt(u32)) std.math.maxInt(u32) else gap);
                }
                self.peers[i].last_sequence = sequence;
                return;
            }
        }

        // Add new peer if room
        if (self.peer_count < MAX_PEERS) {
            self.peers[self.peer_count] = .{
                .peer_id = peer_id,
                .last_sequence = sequence,
                .last_merkle_root = std.mem.zeroes([32]u8),
                .last_sync_ms = 0,
                .in_sync = false,
                .missed_messages = 0,
            };
            self.peer_count += 1;
        }
    }

    /// Enqueue a message in the outbox
    fn enqueueOutbox(self: *Self, msg: SyncMessage) SyncError!void {
        if (self.outbox_count >= MAX_OUTBOX) return SyncError.OutboxFull;
        self.outbox[self.outbox_count] = msg;
        self.outbox_count += 1;
    }

    /// Enqueue a batch message for a specific peer
    fn enqueueBatchMessage(self: *Self, peer_id: [NODE_ID_SIZE]u8, batch: OrderBatch) SyncError!void {
        _ = peer_id;
        self.local_sequence += 1;
        var msg: SyncMessage = undefined;
        msg.msg_type = .order_batch;
        msg.sender_id = self.local_node_id;
        msg.sequence = self.local_sequence;
        msg.timestamp_ms = 0;
        msg.payload = .{ .batch = batch };
        msg.msg_hash = msg.calculateHash();
        try self.enqueueOutbox(msg);
    }
};

// ============================================================================
// Sorting helper — insertion sort (no allocator needed, small N)
// ============================================================================

/// Sort order indices by (pair_id, side, price_micro_usd, timestamp_ms)
fn sortOrderIndices(indices: []usize, orders: *const [MAX_SYNCED_ORDERS]OrderEntry) void {
    if (indices.len <= 1) return;

    // Insertion sort — deterministic, no allocator, fine for typical orderbook sizes
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const key = indices[i];
        var j: usize = i;
        while (j > 0 and orderGreater(orders, indices[j - 1], key)) {
            indices[j] = indices[j - 1];
            j -= 1;
        }
        indices[j] = key;
    }
}

/// Compare two orders: returns true if order at index `a` should come AFTER order at index `b`
fn orderGreater(orders: *const [MAX_SYNCED_ORDERS]OrderEntry, a: usize, b: usize) bool {
    const oa = &orders[a];
    const ob = &orders[b];

    // Sort by pair_id first
    if (oa.pair_id != ob.pair_id) return oa.pair_id > ob.pair_id;
    // Then by side
    if (oa.side != ob.side) return oa.side > ob.side;
    // Then by price
    if (oa.price_micro_usd != ob.price_micro_usd) return oa.price_micro_usd > ob.price_micro_usd;
    // Finally by timestamp
    return oa.timestamp_ms > ob.timestamp_ms;
}

// ============================================================================
// Helper: create a test order entry
// ============================================================================

fn makeTestOrder(id: u64, pair: u16, side: u8, price: u64, amount: u64, ts: i64) OrderEntry {
    var entry: OrderEntry = undefined;
    entry.order_id = id;
    entry.trader_address = std.mem.zeroes([64]u8);
    entry.trader_address[0] = 'T';
    entry.trader_address[1] = 'E';
    entry.trader_address[2] = 'S';
    entry.trader_address[3] = 'T';
    entry.trader_addr_len = 4;
    entry.pair_id = pair;
    entry.side = side;
    entry.price_micro_usd = price;
    entry.amount_sat = amount;
    entry.filled_sat = 0;
    entry.timestamp_ms = ts;
    entry.status = 0; // active
    entry.origin_node = std.mem.zeroes([NODE_ID_SIZE]u8);
    return entry;
}

// ============================================================================
// Test helper — heap allocate manager (struct too large for stack)
// ============================================================================

fn createTestManager(node_id: [NODE_ID_SIZE]u8) !*OrderbookSyncManager {
    const mgr = try std.testing.allocator.create(OrderbookSyncManager);
    mgr.* = OrderbookSyncManager.init(node_id);
    return mgr;
}

fn destroyTestManager(mgr: *OrderbookSyncManager) void {
    std.testing.allocator.destroy(mgr);
}

// ============================================================================
// Teste
// ============================================================================

test "init sync manager" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0xAB);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    try std.testing.expectEqual(@as(u32, 0), mgr.order_count);
    try std.testing.expectEqual(@as(u32, 0), mgr.peer_count);
    try std.testing.expectEqual(@as(u32, 0), mgr.outbox_count);
    try std.testing.expectEqual(@as(u32, 0), mgr.seen_count);
    try std.testing.expectEqual(@as(u64, 0), mgr.local_sequence);
    try std.testing.expect(std.mem.eql(u8, &mgr.local_node_id, &node_id));
}

test "add order and recalc merkle root" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x01);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    const empty_root = mgr.recalcMerkleRoot();

    // Add an order
    const order = makeTestOrder(1, 0, 0, 50_000_000, 100_000_000, 1000);
    try mgr.addOrder(order);

    const root_after = mgr.recalcMerkleRoot();

    // Root should change after adding an order
    try std.testing.expect(!std.mem.eql(u8, &empty_root, &root_after));
}

test "broadcast new order — message in outbox" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x02);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    const order = makeTestOrder(42, 1, 0, 30_000_000, 500_000, 2000);
    try mgr.broadcastNewOrder(order);

    // Order should be in the book
    try std.testing.expectEqual(@as(u32, 1), mgr.order_count);

    // Message should be in outbox
    try std.testing.expectEqual(@as(u32, 1), mgr.outbox_count);

    const msgs = mgr.drainOutbox();
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqual(SyncMessageType.new_order, msgs[0].msg_type);
    try std.testing.expectEqual(@as(u64, 42), msgs[0].payload.order.order_id);
}

test "handle incoming order — added to book" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x03);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    const order = makeTestOrder(100, 2, 1, 45_000_000, 200_000, 3000);

    // Create an incoming message
    var msg: SyncMessage = undefined;
    msg.msg_type = .new_order;
    @memset(&msg.sender_id, 0xFF);
    msg.sequence = 1;
    msg.timestamp_ms = 3000;
    msg.payload = .{ .order = order };
    msg.msg_hash = msg.calculateHash();

    try mgr.handleMessage(msg);

    try std.testing.expectEqual(@as(u32, 1), mgr.order_count);
    const found = mgr.getOrder(100);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, 45_000_000), found.?.price_micro_usd);
}

test "cancel order — removed from book" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x04);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    // Add two orders
    try mgr.addOrder(makeTestOrder(10, 0, 0, 50_000_000, 100_000, 1000));
    try mgr.addOrder(makeTestOrder(20, 0, 1, 51_000_000, 200_000, 1001));
    try std.testing.expectEqual(@as(u32, 2), mgr.order_count);

    // Cancel one
    try mgr.broadcastCancel(10);

    try std.testing.expectEqual(@as(u32, 1), mgr.order_count);
    try std.testing.expect(mgr.getOrder(10) == null);
    try std.testing.expect(mgr.getOrder(20) != null);
}

test "message dedup — duplicate ignored" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x05);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    const order = makeTestOrder(200, 3, 0, 60_000_000, 300_000, 4000);

    var msg: SyncMessage = undefined;
    msg.msg_type = .new_order;
    @memset(&msg.sender_id, 0xEE);
    msg.sequence = 1;
    msg.timestamp_ms = 4000;
    msg.payload = .{ .order = order };
    msg.msg_hash = msg.calculateHash();

    // First time — should be added
    try mgr.handleMessage(msg);
    try std.testing.expectEqual(@as(u32, 1), mgr.order_count);

    // Second time — same hash, should be ignored (dedup)
    try mgr.handleMessage(msg);
    try std.testing.expectEqual(@as(u32, 1), mgr.order_count);
}

test "merkle root deterministic — same orders = same root" {
    var node_id_a: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id_a, 0x0A);
    var node_id_b: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id_b, 0x0B);

    const mgr_a = try createTestManager(node_id_a);
    defer destroyTestManager(mgr_a);
    const mgr_b = try createTestManager(node_id_b);
    defer destroyTestManager(mgr_b);

    // Add same orders in DIFFERENT order
    const o1 = makeTestOrder(1, 0, 0, 50_000_000, 100_000, 1000);
    const o2 = makeTestOrder(2, 0, 1, 51_000_000, 200_000, 1001);
    const o3 = makeTestOrder(3, 1, 0, 30_000_000, 50_000, 1002);

    try mgr_a.addOrder(o1);
    try mgr_a.addOrder(o2);
    try mgr_a.addOrder(o3);

    // Add in reverse order
    try mgr_b.addOrder(o3);
    try mgr_b.addOrder(o1);
    try mgr_b.addOrder(o2);

    const root_a = mgr_a.recalcMerkleRoot();
    const root_b = mgr_b.recalcMerkleRoot();

    // Same orders → same merkle root regardless of insertion order
    try std.testing.expect(std.mem.eql(u8, &root_a, &root_b));
}

test "peer sync state tracking" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x06);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    // Simulate incoming messages from two peers
    var peer1_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&peer1_id, 0xA1);
    var peer2_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&peer2_id, 0xA2);

    const order1 = makeTestOrder(300, 0, 0, 50_000_000, 100_000, 5000);
    const order2 = makeTestOrder(301, 0, 1, 51_000_000, 100_000, 5001);

    var msg1: SyncMessage = undefined;
    msg1.msg_type = .new_order;
    msg1.sender_id = peer1_id;
    msg1.sequence = 1;
    msg1.timestamp_ms = 5000;
    msg1.payload = .{ .order = order1 };
    msg1.msg_hash = msg1.calculateHash();

    var msg2: SyncMessage = undefined;
    msg2.msg_type = .new_order;
    msg2.sender_id = peer2_id;
    msg2.sequence = 1;
    msg2.timestamp_ms = 5001;
    msg2.payload = .{ .order = order2 };
    msg2.msg_hash = msg2.calculateHash();

    try mgr.handleMessage(msg1);
    try mgr.handleMessage(msg2);

    // Should have two peers tracked
    try std.testing.expectEqual(@as(u32, 2), mgr.peer_count);
    try std.testing.expectEqual(@as(u64, 1), mgr.peers[0].last_sequence);
    try std.testing.expectEqual(@as(u64, 1), mgr.peers[1].last_sequence);
}

test "merkle consensus — 2/3 agree" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x07);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    // Add an order so we have a non-zero merkle root
    try mgr.addOrder(makeTestOrder(500, 0, 0, 50_000_000, 100_000, 6000));
    mgr.current_merkle_root = mgr.recalcMerkleRoot();

    const our_root = mgr.current_merkle_root;
    var bad_root: [32]u8 = undefined;
    @memset(&bad_root, 0xFF);

    // 3 peers: 2 match, 1 doesn't → consensus (2/3 >= 2/3)
    const roots_good = [_][32]u8{ our_root, our_root, bad_root };
    try std.testing.expect(mgr.validateMerkleConsensus(&roots_good));

    // 3 peers: 1 match, 2 don't → no consensus
    const roots_bad = [_][32]u8{ our_root, bad_root, bad_root };
    try std.testing.expect(!mgr.validateMerkleConsensus(&roots_bad));

    // 6 peers: 4 match, 2 don't → consensus (4/6 >= 2/3)
    const roots_six = [_][32]u8{ our_root, our_root, our_root, our_root, bad_root, bad_root };
    try std.testing.expect(mgr.validateMerkleConsensus(&roots_six));

    // 6 peers: 3 match, 3 don't → no consensus (3/6 < 2/3)
    const roots_split = [_][32]u8{ our_root, our_root, our_root, bad_root, bad_root, bad_root };
    try std.testing.expect(!mgr.validateMerkleConsensus(&roots_split));
}

test "full sync request" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x08);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    // Add several orders
    for (0..5) |i| {
        const order = makeTestOrder(
            @intCast(600 + i),
            0,
            if (i % 2 == 0) @as(u8, 0) else @as(u8, 1),
            @intCast(50_000_000 + i * 1_000_000),
            100_000,
            @intCast(7000 + @as(i64, @intCast(i))),
        );
        try mgr.addOrder(order);
    }

    // Simulate a sync request from a new peer
    var requester_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&requester_id, 0xCC);

    try mgr.handleSyncRequest(requester_id);

    // Should have batch message(s) in outbox
    try std.testing.expect(mgr.outbox_count >= 1);
    try std.testing.expectEqual(SyncMessageType.order_batch, mgr.outbox[0].msg_type);

    // Batch should contain all 5 orders
    const batch = mgr.outbox[0].payload.batch;
    try std.testing.expectEqual(@as(u32, 5), batch.count);
}

test "sequence gap detection" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x09);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    var peer_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&peer_id, 0xDD);

    // First message with sequence 1
    const order1 = makeTestOrder(700, 0, 0, 50_000_000, 100_000, 8000);
    var msg1: SyncMessage = undefined;
    msg1.msg_type = .new_order;
    msg1.sender_id = peer_id;
    msg1.sequence = 1;
    msg1.timestamp_ms = 8000;
    msg1.payload = .{ .order = order1 };
    msg1.msg_hash = msg1.calculateHash();
    try mgr.handleMessage(msg1);

    // Skip to sequence 10 (gap of 8 messages)
    const order2 = makeTestOrder(701, 0, 1, 51_000_000, 200_000, 8010);
    var msg2: SyncMessage = undefined;
    msg2.msg_type = .new_order;
    msg2.sender_id = peer_id;
    msg2.sequence = 10;
    msg2.timestamp_ms = 8010;
    msg2.payload = .{ .order = order2 };
    msg2.msg_hash = msg2.calculateHash();
    try mgr.handleMessage(msg2);

    // Peer should have recorded missed messages
    try std.testing.expectEqual(@as(u32, 8), mgr.peers[0].missed_messages);
    try std.testing.expectEqual(@as(u64, 10), mgr.peers[0].last_sequence);
}

test "clear outbox" {
    var node_id: [NODE_ID_SIZE]u8 = undefined;
    @memset(&node_id, 0x0C);

    const mgr = try createTestManager(node_id);
    defer destroyTestManager(mgr);

    const order = makeTestOrder(800, 0, 0, 50_000_000, 100_000, 9000);
    try mgr.broadcastNewOrder(order);
    try std.testing.expect(mgr.outbox_count > 0);

    mgr.clearOutbox();
    try std.testing.expectEqual(@as(u32, 0), mgr.outbox_count);
    try std.testing.expectEqual(@as(usize, 0), mgr.drainOutbox().len);
}
