/// bridge_listener.zig — Ascultator de events Liberty Chain (EVM) pentru OmniBus
///
/// Fiecare miner OmniBus ruleaza acest modul. Polleaza Liberty Chain RPC
/// pentru events de la contractul OmniBusBridgeRelay:
///   - OrderPlaced(orderId, user, token, amount, targetChainId) → adauga in orderbook local
///   - OrderCancelled(orderId, user) → sterge din orderbook local
///
/// Arhitectura:
///   - Nu face HTTP — caller-ul (main.zig) polleaza RPC-ul si trimite log data aici
///   - Parseaza EVM event topics si data din eth_getLogs response
///   - Buffer-eaza events si le livreaza catre matching engine prin drain pattern
///   - Dedup prin circular buffer de TX hashes
///   - Complet determinist: aceleasi log data → aceleasi events pe toti minerii
///
/// Unitati:
///   - amount_wei: [32]u8 big-endian (uint256 nativ EVM)
///   - Timestamps: millisecunde Unix (i64)
///   - Adrese EVM: [42]u8 "0x..." hex string
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

// --- CONSTANTE ---------------------------------------------------------------

/// Numar maxim de events in pending buffer (orders sau cancels)
pub const MAX_PENDING_EVENTS: usize = 256;

/// Numar maxim de TX hashes in circular dedup buffer
pub const MAX_SEEN_HASHES: usize = 1000;

/// Poll interval implicit (Liberty Chain block time ~2s)
pub const DEFAULT_POLL_INTERVAL_MS: u64 = 2000;

/// Maxim blocuri scanate per poll (limita de siguranta)
pub const MAX_BLOCKS_PER_POLL: u64 = 100;

/// EVM event topic hashes (keccak256 of event signatures)
/// keccak256("OrderPlaced(uint256,address,address,uint256,uint256)")
/// NOTE: Aceste valori trebuie recalculate cu keccak256 real la deploy.
///       Placeholder-uri derivate din signatura evenimentului.
pub const ORDER_PLACED_TOPIC: [64]u8 =
    "e1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c".*;

/// keccak256("OrderCancelled(uint256,address)")
pub const ORDER_CANCELLED_TOPIC: [64]u8 =
    "a]0cc6c2c4f6d8e8b7c6c2c4f6d8e8b7c6c2c4f6d8e8b7c6c2c4f6d8e0a1b2".*;

/// Default Liberty Chain RPC endpoint
pub const DEFAULT_LIBERTY_RPC: []const u8 = "https://testnet-rpc.lcx.com";

/// Default bridge contract address (placeholder — must be set at deploy)
pub const DEFAULT_BRIDGE_CONTRACT: [42]u8 = "0x0000000000000000000000000000000000000000".*;

/// Default OmniBus target chain ID
pub const DEFAULT_TARGET_CHAIN: u64 = 42069;

// --- TIPURI ------------------------------------------------------------------

/// Configuratie pentru bridge listener
pub const BridgeConfig = struct {
    /// Liberty Chain RPC URL (max 256 chars)
    rpc_url: [256]u8,
    rpc_url_len: u16,
    /// OmniBusBridgeRelay contract address (0x... 42 chars)
    contract_address: [42]u8,
    /// Target chain ID (42069 for OmniBus)
    target_chain_id: u64,
    /// Poll interval in milliseconds
    poll_interval_ms: u64,
    /// Starting block number for scanning
    from_block: u64,

    /// Returns the RPC URL as a slice
    pub fn getRpcUrl(self: *const BridgeConfig) []const u8 {
        return self.rpc_url[0..self.rpc_url_len];
    }

    /// Returns the contract address as a slice (always 42 bytes: "0x" + 40 hex)
    pub fn getContractAddress(self: *const BridgeConfig) []const u8 {
        return &self.contract_address;
    }

    /// Creates a default config with Liberty Chain testnet settings
    pub fn default() BridgeConfig {
        var cfg: BridgeConfig = undefined;
        cfg.rpc_url = @splat(0);
        const rpc = DEFAULT_LIBERTY_RPC;
        @memcpy(cfg.rpc_url[0..rpc.len], rpc);
        cfg.rpc_url_len = @intCast(rpc.len);
        cfg.contract_address = DEFAULT_BRIDGE_CONTRACT;
        cfg.target_chain_id = DEFAULT_TARGET_CHAIN;
        cfg.poll_interval_ms = DEFAULT_POLL_INTERVAL_MS;
        cfg.from_block = 0;
        return cfg;
    }
};

/// Un event OrderPlaced detectat pe Liberty Chain
pub const OrderPlacedEvent = struct {
    order_id: u64,
    user_address: [42]u8, // 0x... EVM address
    token_address: [42]u8, // 0x... EVM token address
    amount_wei: [32]u8, // uint256 as 32-byte big-endian
    target_chain_id: u64,
    block_number: u64,
    tx_hash: [66]u8, // 0x... 64 hex chars
    timestamp_ms: i64,

    pub fn getUserAddress(self: *const OrderPlacedEvent) []const u8 {
        return &self.user_address;
    }

    pub fn getTokenAddress(self: *const OrderPlacedEvent) []const u8 {
        return &self.token_address;
    }

    pub fn getTxHash(self: *const OrderPlacedEvent) []const u8 {
        return &self.tx_hash;
    }
};

/// Un event OrderCancelled detectat pe Liberty Chain
pub const OrderCancelledEvent = struct {
    order_id: u64,
    user_address: [42]u8,
    block_number: u64,
    tx_hash: [66]u8,
    timestamp_ms: i64,

    pub fn getUserAddress(self: *const OrderCancelledEvent) []const u8 {
        return &self.user_address;
    }

    pub fn getTxHash(self: *const OrderCancelledEvent) []const u8 {
        return &self.tx_hash;
    }
};

/// Stare interna a listener-ului
pub const ListenerState = enum(u8) {
    idle = 0, // not started
    polling = 1, // actively polling
    syncing = 2, // catching up on missed blocks
    error_state = 3, // last poll failed
    stopped = 4, // manually stopped
};

/// Statistici agregate ale listener-ului
pub const ListenerStats = struct {
    state: ListenerState,
    last_scanned_block: u64,
    total_orders: u64,
    total_cancels: u64,
    total_polls: u64,
    pending_orders: u32,
    pending_cancels: u32,
    last_poll_ms: i64,
    last_error: u16,
};

// --- BRIDGE LISTENER ---------------------------------------------------------

/// Bridge Listener — asculta events de pe Liberty Chain si le buffer-eaza
/// pentru matching engine. Nu face I/O — caller-ul trimite raw log data.
pub const BridgeListener = struct {
    config: BridgeConfig,
    state: ListenerState,

    /// Last successfully scanned block
    last_scanned_block: u64,

    /// Events buffer — orders detected since last drain
    pending_orders: [MAX_PENDING_EVENTS]OrderPlacedEvent,
    pending_order_count: u32,

    /// Cancellations buffer
    pending_cancels: [MAX_PENDING_EVENTS]OrderCancelledEvent,
    pending_cancel_count: u32,

    /// Stats
    total_orders_detected: u64,
    total_cancels_detected: u64,
    total_polls: u64,
    last_poll_ms: i64,
    last_error_code: u16,

    /// Processed event hashes (dedup) — circular buffer
    seen_tx_hashes: [MAX_SEEN_HASHES][66]u8,
    seen_count: u32,
    seen_head: u32,

    /// Initializeaza un BridgeListener cu configuratia data
    pub fn init(config: BridgeConfig) BridgeListener {
        return BridgeListener{
            .config = config,
            .state = .idle,
            .last_scanned_block = config.from_block,
            .pending_orders = undefined,
            .pending_order_count = 0,
            .pending_cancels = undefined,
            .pending_cancel_count = 0,
            .total_orders_detected = 0,
            .total_cancels_detected = 0,
            .total_polls = 0,
            .last_poll_ms = 0,
            .last_error_code = 0,
            .seen_tx_hashes = @splat([_]u8{0} ** 66),
            .seen_count = 0,
            .seen_head = 0,
        };
    }

    // --- Event processing (called by the actual HTTP poller in main loop) ---

    /// Adauga un OrderPlaced event in pending buffer.
    /// Returneaza error daca buffer-ul e plin sau TX-ul e duplicat.
    pub fn addOrderEvent(self: *BridgeListener, event: OrderPlacedEvent) !void {
        // Dedup check
        if (self.isDuplicate(&event.tx_hash)) {
            return error.DuplicateEvent;
        }

        // Buffer full check
        if (self.pending_order_count >= MAX_PENDING_EVENTS) {
            return error.BufferFull;
        }

        // Filter: only accept events targeting our chain
        if (event.target_chain_id != self.config.target_chain_id) {
            return error.WrongTargetChain;
        }

        self.pending_orders[self.pending_order_count] = event;
        self.pending_order_count += 1;
        self.total_orders_detected += 1;
        self.markSeen(&event.tx_hash);
    }

    /// Adauga un OrderCancelled event in pending buffer.
    pub fn addCancelEvent(self: *BridgeListener, event: OrderCancelledEvent) !void {
        // Dedup check
        if (self.isDuplicate(&event.tx_hash)) {
            return error.DuplicateEvent;
        }

        // Buffer full check
        if (self.pending_cancel_count >= MAX_PENDING_EVENTS) {
            return error.BufferFull;
        }

        self.pending_cancels[self.pending_cancel_count] = event;
        self.pending_cancel_count += 1;
        self.total_cancels_detected += 1;
        self.markSeen(&event.tx_hash);
    }

    // --- Drain events (called by matching engine integration) ----------------

    /// Returneaza slice cu toate pending orders si goleste buffer-ul.
    /// Matching engine-ul apeleaza asta la fiecare sub-block.
    pub fn drainOrders(self: *BridgeListener) []const OrderPlacedEvent {
        const count = self.pending_order_count;
        if (count == 0) return self.pending_orders[0..0];
        self.pending_order_count = 0;
        return self.pending_orders[0..count];
    }

    /// Returneaza slice cu toate pending cancellations si goleste buffer-ul.
    pub fn drainCancels(self: *BridgeListener) []const OrderCancelledEvent {
        const count = self.pending_cancel_count;
        if (count == 0) return self.pending_cancels[0..0];
        self.pending_cancel_count = 0;
        return self.pending_cancels[0..count];
    }

    // --- State management ----------------------------------------------------

    /// Actualizeaza ultimul bloc scanat cu succes
    pub fn updateLastBlock(self: *BridgeListener, block_number: u64) void {
        if (block_number > self.last_scanned_block) {
            self.last_scanned_block = block_number;
        }
        self.total_polls += 1;
    }

    /// Seteaza error state cu un cod specific
    pub fn setError(self: *BridgeListener, error_code: u16) void {
        self.state = .error_state;
        self.last_error_code = error_code;
    }

    /// Curata error state si revine la polling
    pub fn clearError(self: *BridgeListener) void {
        if (self.state == .error_state) {
            self.state = .polling;
            self.last_error_code = 0;
        }
    }

    /// Verifica daca listener-ul e activ (polling sau syncing)
    pub fn isActive(self: *const BridgeListener) bool {
        return self.state == .polling or self.state == .syncing;
    }

    /// Porneste listener-ul — trece in starea polling
    pub fn start(self: *BridgeListener) void {
        if (self.state == .idle or self.state == .stopped or self.state == .error_state) {
            self.state = .polling;
            self.last_error_code = 0;
        }
    }

    /// Opreste listener-ul manual
    pub fn stop(self: *BridgeListener) void {
        self.state = .stopped;
    }

    // --- Dedup ---------------------------------------------------------------

    /// Verifica daca un TX hash a fost deja procesat
    pub fn isDuplicate(self: *const BridgeListener, tx_hash: []const u8) bool {
        const check_len = @min(tx_hash.len, 66);
        const count = @min(self.seen_count, MAX_SEEN_HASHES);
        for (0..count) |i| {
            if (mem.eql(u8, self.seen_tx_hashes[i][0..check_len], tx_hash[0..check_len])) {
                return true;
            }
        }
        return false;
    }

    /// Marcheaza un TX hash ca vazut (circular buffer)
    fn markSeen(self: *BridgeListener, tx_hash: []const u8) void {
        const idx = self.seen_head % MAX_SEEN_HASHES;
        self.seen_tx_hashes[idx] = @splat(0);
        const copy_len = @min(tx_hash.len, 66);
        @memcpy(self.seen_tx_hashes[idx][0..copy_len], tx_hash[0..copy_len]);
        self.seen_head = (self.seen_head + 1) % @as(u32, MAX_SEEN_HASHES);
        if (self.seen_count < MAX_SEEN_HASHES) {
            self.seen_count += 1;
        }
    }

    // --- Stats ---------------------------------------------------------------

    /// Returneaza un snapshot al statisticilor curente
    pub fn getStats(self: *const BridgeListener) ListenerStats {
        return ListenerStats{
            .state = self.state,
            .last_scanned_block = self.last_scanned_block,
            .total_orders = self.total_orders_detected,
            .total_cancels = self.total_cancels_detected,
            .total_polls = self.total_polls,
            .pending_orders = self.pending_order_count,
            .pending_cancels = self.pending_cancel_count,
            .last_poll_ms = self.last_poll_ms,
            .last_error = self.last_error_code,
        };
    }

    // --- EVM event topic parsing helpers --------------------------------------

    /// Parseaza un OrderPlaced event din EVM log data (topics + data).
    ///
    /// Layout EVM log:
    ///   topics[0] = event signature hash (ORDER_PLACED_TOPIC)
    ///   topics[1] = orderId (uint256, but we take low 8 bytes)
    ///   topics[2] = user address (address, 20 bytes padded to 32)
    ///   data = abi.encode(tokenAddress, amount, targetChainId)
    ///          = 32 bytes token (address padded) + 32 bytes amount + 32 bytes chainId
    ///
    /// `log_data` must be at least 3*64 (topics) + 3*64 (data) = 384 hex chars.
    /// All values are hex-encoded without "0x" prefix.
    pub fn parseOrderPlacedTopic(log_data: []const u8) ?OrderPlacedEvent {
        // Minimum: 3 topics * 64 hex + 3 data fields * 64 hex = 384 chars
        if (log_data.len < 384) return null;

        var event: OrderPlacedEvent = undefined;
        event.tx_hash = @splat(0);
        event.timestamp_ms = 0;
        event.block_number = 0;

        // topic[1] = orderId: take last 16 hex chars (8 bytes) of 64 hex chars
        const order_id_hex = log_data[64 + 48 .. 64 + 64]; // last 16 hex of topic[1]
        event.order_id = hexToU64(order_id_hex) orelse return null;

        // topic[2] = user address: take last 40 hex chars, prepend "0x"
        event.user_address[0] = '0';
        event.user_address[1] = 'x';
        @memcpy(event.user_address[2..42], log_data[128 + 24 .. 128 + 64]);

        // data[0] = token address: 32 bytes (address is last 20 bytes = 40 hex)
        const data_start: usize = 192; // 3 topics * 64
        event.token_address[0] = '0';
        event.token_address[1] = 'x';
        @memcpy(event.token_address[2..42], log_data[data_start + 24 .. data_start + 64]);

        // data[1] = amount: 32 bytes big-endian
        const amount_hex = log_data[data_start + 64 .. data_start + 128];
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            const hi = hexCharToNibble(amount_hex[i * 2]) orelse return null;
            const lo = hexCharToNibble(amount_hex[i * 2 + 1]) orelse return null;
            event.amount_wei[i] = (hi << 4) | lo;
        }

        // data[2] = targetChainId: last 16 hex chars of 64 hex
        const chain_hex = log_data[data_start + 128 + 48 .. data_start + 128 + 64];
        event.target_chain_id = hexToU64(chain_hex) orelse return null;

        return event;
    }

    /// Parseaza un OrderCancelled event din EVM log data.
    ///
    /// Layout:
    ///   topics[0] = event signature hash (ORDER_CANCELLED_TOPIC)
    ///   topics[1] = orderId (uint256)
    ///   topics[2] = user address
    ///   data = empty
    ///
    /// `log_data` must be at least 3*64 = 192 hex chars.
    pub fn parseOrderCancelledTopic(log_data: []const u8) ?OrderCancelledEvent {
        if (log_data.len < 192) return null;

        var event: OrderCancelledEvent = undefined;
        event.tx_hash = @splat(0);
        event.timestamp_ms = 0;
        event.block_number = 0;

        // topic[1] = orderId
        const order_id_hex = log_data[64 + 48 .. 64 + 64];
        event.order_id = hexToU64(order_id_hex) orelse return null;

        // topic[2] = user address
        event.user_address[0] = '0';
        event.user_address[1] = 'x';
        @memcpy(event.user_address[2..42], log_data[128 + 24 .. 128 + 64]);

        return event;
    }

    // --- JSON-RPC request builder --------------------------------------------

    /// Construieste un JSON-RPC eth_getLogs request in buffer-ul dat.
    /// Returneaza slice-ul scris din buffer.
    ///
    /// Format:
    /// {
    ///   "jsonrpc": "2.0",
    ///   "method": "eth_getLogs",
    ///   "params": [{
    ///     "fromBlock": "0x...",
    ///     "toBlock": "0x...",
    ///     "address": "0x...",
    ///     "topics": [null]
    ///   }],
    ///   "id": 1
    /// }
    ///
    /// Topics filter is null (accept both OrderPlaced and OrderCancelled).
    /// Caller is responsible for filtering by topic after parsing.
    pub fn buildGetLogsRequest(self: *const BridgeListener, buf: []u8) ![]u8 {
        const from_block = self.last_scanned_block;
        const to_block_raw = from_block + MAX_BLOCKS_PER_POLL;

        // Format hex block numbers
        var from_hex_buf: [18]u8 = undefined; // "0x" + max 16 hex digits
        const from_hex = formatHexU64(&from_hex_buf, from_block);
        var to_hex_buf: [18]u8 = undefined;
        const to_hex = formatHexU64(&to_hex_buf, to_block_raw);

        const contract = self.config.getContractAddress();

        // Build JSON manually (no allocator)
        const template_pre = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"";
        const template_to = "\",\"toBlock\":\"";
        const template_addr = "\",\"address\":\"";
        const template_post = "\"}],\"id\":1}";

        const total_len = template_pre.len + from_hex.len + template_to.len +
            to_hex.len + template_addr.len + contract.len + template_post.len;

        if (buf.len < total_len) return error.BufferTooSmall;

        var pos: usize = 0;

        @memcpy(buf[pos .. pos + template_pre.len], template_pre);
        pos += template_pre.len;

        @memcpy(buf[pos .. pos + from_hex.len], from_hex);
        pos += from_hex.len;

        @memcpy(buf[pos .. pos + template_to.len], template_to);
        pos += template_to.len;

        @memcpy(buf[pos .. pos + to_hex.len], to_hex);
        pos += to_hex.len;

        @memcpy(buf[pos .. pos + template_addr.len], template_addr);
        pos += template_addr.len;

        @memcpy(buf[pos .. pos + contract.len], contract);
        pos += contract.len;

        @memcpy(buf[pos .. pos + template_post.len], template_post);
        pos += template_post.len;

        return buf[0..pos];
    }
};

// --- HELPER FUNCTIONS --------------------------------------------------------

/// Converts a hex string (up to 16 chars) to u64
fn hexToU64(hex: []const u8) ?u64 {
    var result: u64 = 0;
    for (hex) |c| {
        const nibble = hexCharToNibble(c) orelse return null;
        result = (result << 4) | @as(u64, nibble);
    }
    return result;
}

/// Converts a single hex character to its 4-bit value
fn hexCharToNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => null,
    };
}

/// Formats a u64 as "0x" + lowercase hex (no leading zeros, minimum 1 digit)
fn formatHexU64(buf: []u8, value: u64) []u8 {
    buf[0] = '0';
    buf[1] = 'x';
    if (value == 0) {
        buf[2] = '0';
        return buf[0..3];
    }

    // Find number of hex digits
    var v = value;
    var digits: usize = 0;
    while (v > 0) : (digits += 1) {
        v >>= 4;
    }

    // Write digits from right to left
    v = value;
    var i: usize = 0;
    while (i < digits) : (i += 1) {
        const nibble: u4 = @intCast(v & 0xF);
        buf[2 + digits - 1 - i] = if (nibble < 10) '0' + @as(u8, nibble) else 'a' + @as(u8, nibble) - 10;
        v >>= 4;
    }

    return buf[0 .. 2 + digits];
}

// --- TESTE -------------------------------------------------------------------

/// Helper: creeaza un OrderPlacedEvent de test
fn makeTestOrderEvent(order_id: u64, chain_id: u64) OrderPlacedEvent {
    var tx_hash: [66]u8 = @splat(0);
    tx_hash[0] = '0';
    tx_hash[1] = 'x';
    // Encode order_id into tx_hash for uniqueness (4 hex digits from low 16 bits)
    const id_val: u16 = @intCast(order_id & 0xFFFF);
    const hex_chars = "0123456789abcdef";
    tx_hash[2] = hex_chars[(id_val >> 12) & 0xF];
    tx_hash[3] = hex_chars[(id_val >> 8) & 0xF];
    tx_hash[4] = hex_chars[(id_val >> 4) & 0xF];
    tx_hash[5] = hex_chars[id_val & 0xF];

    return OrderPlacedEvent{
        .order_id = order_id,
        .user_address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".*,
        .token_address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48".*,
        .amount_wei = @splat(0),
        .target_chain_id = chain_id,
        .block_number = 1000,
        .tx_hash = tx_hash,
        .timestamp_ms = 1700000000000,
    };
}

/// Helper: creeaza un OrderCancelledEvent de test
fn makeTestCancelEvent(order_id: u64) OrderCancelledEvent {
    var tx_hash: [66]u8 = @splat(0);
    tx_hash[0] = '0';
    tx_hash[1] = 'x';
    tx_hash[2] = 'c'; // 'c' for cancel — distinguishes from order TX hashes
    const id_val: u16 = @intCast(order_id & 0xFFFF);
    const hex_chars = "0123456789abcdef";
    tx_hash[3] = hex_chars[(id_val >> 12) & 0xF];
    tx_hash[4] = hex_chars[(id_val >> 8) & 0xF];
    tx_hash[5] = hex_chars[(id_val >> 4) & 0xF];
    tx_hash[6] = hex_chars[id_val & 0xF];

    return OrderCancelledEvent{
        .order_id = order_id,
        .user_address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045".*,
        .block_number = 1001,
        .tx_hash = tx_hash,
        .timestamp_ms = 1700000001000,
    };
}

test "init bridge listener" {
    const cfg = BridgeConfig.default();
    const listener = BridgeListener.init(cfg);

    try testing.expectEqual(ListenerState.idle, listener.state);
    try testing.expectEqual(@as(u64, 0), listener.last_scanned_block);
    try testing.expectEqual(@as(u32, 0), listener.pending_order_count);
    try testing.expectEqual(@as(u32, 0), listener.pending_cancel_count);
    try testing.expectEqual(@as(u64, 0), listener.total_orders_detected);
    try testing.expectEqual(@as(u64, 0), listener.total_cancels_detected);
    try testing.expectEqual(@as(u32, 0), listener.seen_count);

    // Verify default config values
    try testing.expectEqualStrings(DEFAULT_LIBERTY_RPC, cfg.getRpcUrl());
    try testing.expectEqual(DEFAULT_TARGET_CHAIN, cfg.target_chain_id);
    try testing.expectEqual(DEFAULT_POLL_INTERVAL_MS, cfg.poll_interval_ms);
}

test "add order event" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);

    const event = makeTestOrderEvent(1, DEFAULT_TARGET_CHAIN);
    try listener.addOrderEvent(event);

    try testing.expectEqual(@as(u32, 1), listener.pending_order_count);
    try testing.expectEqual(@as(u64, 1), listener.total_orders_detected);
    try testing.expectEqual(@as(u64, 1), listener.pending_orders[0].order_id);
    try testing.expectEqual(@as(u32, 1), listener.seen_count);
}

test "add cancel event" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);

    const event = makeTestCancelEvent(42);
    try listener.addCancelEvent(event);

    try testing.expectEqual(@as(u32, 1), listener.pending_cancel_count);
    try testing.expectEqual(@as(u64, 1), listener.total_cancels_detected);
    try testing.expectEqual(@as(u64, 42), listener.pending_cancels[0].order_id);
}

test "drain orders clears buffer" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);

    // Add 3 orders
    var i: u64 = 0;
    while (i < 3) : (i += 1) {
        const event = makeTestOrderEvent(i + 1, DEFAULT_TARGET_CHAIN);
        try listener.addOrderEvent(event);
    }
    try testing.expectEqual(@as(u32, 3), listener.pending_order_count);

    // Drain — should return 3 and clear
    const drained = listener.drainOrders();
    try testing.expectEqual(@as(usize, 3), drained.len);
    try testing.expectEqual(@as(u64, 1), drained[0].order_id);
    try testing.expectEqual(@as(u64, 2), drained[1].order_id);
    try testing.expectEqual(@as(u64, 3), drained[2].order_id);

    // Buffer is now empty
    try testing.expectEqual(@as(u32, 0), listener.pending_order_count);

    // Drain again — empty
    const drained2 = listener.drainOrders();
    try testing.expectEqual(@as(usize, 0), drained2.len);

    // Stats should still reflect total
    try testing.expectEqual(@as(u64, 3), listener.total_orders_detected);
}

test "dedup — duplicate TX hash ignored" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);

    const event = makeTestOrderEvent(1, DEFAULT_TARGET_CHAIN);
    try listener.addOrderEvent(event);

    // Same TX hash again → DuplicateEvent
    try testing.expectError(error.DuplicateEvent, listener.addOrderEvent(event));

    // Only 1 event in buffer
    try testing.expectEqual(@as(u32, 1), listener.pending_order_count);
    try testing.expectEqual(@as(u64, 1), listener.total_orders_detected);
}

test "state transitions — start/stop" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);

    // Initial state: idle
    try testing.expectEqual(ListenerState.idle, listener.state);
    try testing.expect(!listener.isActive());

    // Start
    listener.start();
    try testing.expectEqual(ListenerState.polling, listener.state);
    try testing.expect(listener.isActive());

    // Stop
    listener.stop();
    try testing.expectEqual(ListenerState.stopped, listener.state);
    try testing.expect(!listener.isActive());

    // Restart from stopped
    listener.start();
    try testing.expectEqual(ListenerState.polling, listener.state);
    try testing.expect(listener.isActive());

    // Error state
    listener.setError(500);
    try testing.expectEqual(ListenerState.error_state, listener.state);
    try testing.expectEqual(@as(u16, 500), listener.last_error_code);
    try testing.expect(!listener.isActive());

    // Clear error → back to polling
    listener.clearError();
    try testing.expectEqual(ListenerState.polling, listener.state);
    try testing.expectEqual(@as(u16, 0), listener.last_error_code);

    // Start from error state
    listener.setError(404);
    listener.start();
    try testing.expectEqual(ListenerState.polling, listener.state);
    try testing.expectEqual(@as(u16, 0), listener.last_error_code);
}

test "stats tracking" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);
    listener.start();

    // Add events
    try listener.addOrderEvent(makeTestOrderEvent(1, DEFAULT_TARGET_CHAIN));
    try listener.addOrderEvent(makeTestOrderEvent(2, DEFAULT_TARGET_CHAIN));
    try listener.addCancelEvent(makeTestCancelEvent(1));

    // Update block
    listener.updateLastBlock(1050);
    listener.last_poll_ms = 1700000005000;

    const stats = listener.getStats();
    try testing.expectEqual(ListenerState.polling, stats.state);
    try testing.expectEqual(@as(u64, 1050), stats.last_scanned_block);
    try testing.expectEqual(@as(u64, 2), stats.total_orders);
    try testing.expectEqual(@as(u64, 1), stats.total_cancels);
    try testing.expectEqual(@as(u64, 1), stats.total_polls);
    try testing.expectEqual(@as(u32, 2), stats.pending_orders);
    try testing.expectEqual(@as(u32, 1), stats.pending_cancels);
    try testing.expectEqual(@as(i64, 1700000005000), stats.last_poll_ms);
    try testing.expectEqual(@as(u16, 0), stats.last_error);
}

test "build getLogs request" {
    var cfg = BridgeConfig.default();
    cfg.from_block = 100;
    var listener = BridgeListener.init(cfg);
    listener.last_scanned_block = 100;

    var buf: [1024]u8 = undefined;
    const result = try listener.buildGetLogsRequest(&buf);

    // Verify it's valid-ish JSON
    try testing.expect(mem.startsWith(u8, result, "{\"jsonrpc\":\"2.0\""));
    try testing.expect(mem.indexOf(u8, result, "eth_getLogs") != null);
    try testing.expect(mem.indexOf(u8, result, "fromBlock") != null);
    try testing.expect(mem.indexOf(u8, result, "toBlock") != null);
    try testing.expect(mem.indexOf(u8, result, "0x64") != null); // 100 = 0x64
    try testing.expect(mem.indexOf(u8, result, "address") != null);
}

test "max pending events limit" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);

    // Fill the buffer to capacity
    var i: u64 = 0;
    while (i < MAX_PENDING_EVENTS) : (i += 1) {
        const event = makeTestOrderEvent(i + 1, DEFAULT_TARGET_CHAIN);
        try listener.addOrderEvent(event);
    }
    try testing.expectEqual(@as(u32, MAX_PENDING_EVENTS), listener.pending_order_count);

    // Next one should fail
    const overflow_event = makeTestOrderEvent(MAX_PENDING_EVENTS + 1, DEFAULT_TARGET_CHAIN);
    try testing.expectError(error.BufferFull, listener.addOrderEvent(overflow_event));

    // Count unchanged
    try testing.expectEqual(@as(u32, MAX_PENDING_EVENTS), listener.pending_order_count);

    // Drain frees the buffer
    _ = listener.drainOrders();
    try testing.expectEqual(@as(u32, 0), listener.pending_order_count);
}

test "circular dedup buffer wraps" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);

    // Insert MAX_SEEN_HASHES + 10 events — oldest should be evicted from dedup
    var i: u64 = 0;
    while (i < MAX_SEEN_HASHES + 10) : (i += 1) {
        const event = makeTestOrderEvent(i + 1, DEFAULT_TARGET_CHAIN);
        try listener.addOrderEvent(event);
        // Drain to keep buffer from filling
        _ = listener.drainOrders();
    }

    // seen_count should be capped at MAX_SEEN_HASHES
    try testing.expectEqual(@as(u32, MAX_SEEN_HASHES), listener.seen_count);

    // Total orders should reflect all added events
    try testing.expectEqual(@as(u64, MAX_SEEN_HASHES + 10), listener.total_orders_detected);

    // The first few TX hashes should have been evicted (overwritten by circular buffer).
    // Event with order_id=1 had its TX hash at position 0, which was overwritten
    // after MAX_SEEN_HASHES insertions. Re-adding it should succeed (not duplicate).
    const old_event = makeTestOrderEvent(1, DEFAULT_TARGET_CHAIN);
    // It should NOT be detected as duplicate since it was evicted
    const is_dup = listener.isDuplicate(&old_event.tx_hash);
    try testing.expect(!is_dup);
}

test "wrong target chain rejected" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);

    // Event targeting a different chain
    const event = makeTestOrderEvent(1, 99999);
    try testing.expectError(error.WrongTargetChain, listener.addOrderEvent(event));
    try testing.expectEqual(@as(u32, 0), listener.pending_order_count);
}

test "updateLastBlock only moves forward" {
    const cfg = BridgeConfig.default();
    var listener = BridgeListener.init(cfg);

    listener.updateLastBlock(100);
    try testing.expectEqual(@as(u64, 100), listener.last_scanned_block);

    // Should not go backwards
    listener.updateLastBlock(50);
    try testing.expectEqual(@as(u64, 100), listener.last_scanned_block);

    // Should advance
    listener.updateLastBlock(200);
    try testing.expectEqual(@as(u64, 200), listener.last_scanned_block);
    try testing.expectEqual(@as(u64, 3), listener.total_polls);
}

test "hexToU64 helper" {
    try testing.expectEqual(@as(?u64, 0), hexToU64("0"));
    try testing.expectEqual(@as(?u64, 255), hexToU64("ff"));
    try testing.expectEqual(@as(?u64, 256), hexToU64("100"));
    try testing.expectEqual(@as(?u64, 42069), hexToU64("a455"));
    try testing.expectEqual(@as(?u64, null), hexToU64("xyz"));
}

test "formatHexU64 helper" {
    var buf: [18]u8 = undefined;

    try testing.expectEqualStrings("0x0", formatHexU64(&buf, 0));
    try testing.expectEqualStrings("0x1", formatHexU64(&buf, 1));
    try testing.expectEqualStrings("0xa", formatHexU64(&buf, 10));
    try testing.expectEqualStrings("0xff", formatHexU64(&buf, 255));
    try testing.expectEqualStrings("0x64", formatHexU64(&buf, 100));
    try testing.expectEqualStrings("0xa455", formatHexU64(&buf, 42069));
}
