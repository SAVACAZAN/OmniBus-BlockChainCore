const std = @import("std");
const htlc_mod = @import("htlc.zig");

// ─── Lightning Network — Payment Channels with HTLC Routing ─────────────────
//
// OmniBus Lightning implementation:
//   - Payment channels (open/update/close)
//   - HTLC-based multi-hop routing
//   - Invoice system (BOLT-11 style)
//   - Channel capacity and balance tracking
//
// Channel lifecycle:
//   1. Open: funding TX on-chain (both parties deposit)
//   2. Update: off-chain balance updates (instant, free)
//   3. Close: cooperative (mutual) or force (unilateral) close on-chain

/// Channel state
pub const ChannelState = enum {
    opening,    // Funding TX broadcast, waiting for confirmations
    active,     // Channel is open, can route payments
    closing,    // Cooperative close initiated
    force_closing, // Unilateral close (dispute period)
    closed,     // Channel fully closed on-chain
};

/// A Lightning payment channel between two nodes
pub const Channel = struct {
    /// Unique channel ID
    id: u64,
    /// Funding TX hash (on-chain)
    funding_tx: []const u8,
    /// Local node's address
    local_addr: []const u8,
    /// Remote node's address
    remote_addr: []const u8,
    /// Total channel capacity in SAT
    capacity: u64,
    /// Local balance (our side) in SAT
    local_balance: u64,
    /// Remote balance (their side) in SAT
    remote_balance: u64,
    /// Channel state
    state: ChannelState,
    /// Number of updates (commitment number)
    update_count: u64,
    /// Active HTLCs in this channel
    pending_htlcs: u32,
    /// Reserve amount (minimum balance to keep, prevents cheating)
    reserve: u64,
    /// Creation timestamp
    created_at: i64,

    /// Check if we can send `amount` through this channel
    pub fn canSend(self: *const Channel, amount: u64) bool {
        if (self.state != .active) return false;
        return self.local_balance >= amount + self.reserve;
    }

    /// Check if we can receive `amount` through this channel
    pub fn canReceive(self: *const Channel, amount: u64) bool {
        if (self.state != .active) return false;
        return self.remote_balance >= amount + self.reserve;
    }

    /// Update balances (off-chain payment)
    pub fn updateBalance(self: *Channel, amount: u64, direction: enum { send, receive }) !void {
        if (self.state != .active) return error.ChannelNotActive;

        switch (direction) {
            .send => {
                if (!self.canSend(amount)) return error.InsufficientLocalBalance;
                self.local_balance -= amount;
                self.remote_balance += amount;
            },
            .receive => {
                if (!self.canReceive(amount)) return error.InsufficientRemoteBalance;
                self.remote_balance -= amount;
                self.local_balance += amount;
            },
        }
        self.update_count += 1;
    }

    /// Initiate cooperative close
    pub fn initiateClose(self: *Channel) !void {
        if (self.state != .active) return error.ChannelNotActive;
        if (self.pending_htlcs > 0) return error.PendingHTLCs;
        self.state = .closing;
    }

    /// Force close (unilateral — starts dispute period)
    pub fn forceClose(self: *Channel) !void {
        if (self.state != .active) return error.ChannelNotActive;
        self.state = .force_closing;
    }

    /// Complete close
    pub fn completeClose(self: *Channel) void {
        self.state = .closed;
    }
};

/// Lightning Invoice (BOLT-11 style)
pub const Invoice = struct {
    /// Payment hash (SHA256 of preimage)
    payment_hash: [32]u8,
    /// Amount requested in SAT
    amount: u64,
    /// Recipient address
    recipient: []const u8,
    /// Description/memo
    description: []const u8,
    /// Expiry timestamp (unix seconds)
    expiry: i64,
    /// Is this invoice paid?
    paid: bool,
    /// Creation timestamp
    created_at: i64,

    pub fn isExpired(self: *const Invoice) bool {
        return std.time.timestamp() > self.expiry;
    }

    pub fn create(payment_hash: [32]u8, amount: u64, recipient: []const u8, description: []const u8, expiry_secs: i64) Invoice {
        const now = std.time.timestamp();
        return Invoice{
            .payment_hash = payment_hash,
            .amount = amount,
            .recipient = recipient,
            .description = description,
            .expiry = now + expiry_secs,
            .paid = false,
            .created_at = now,
        };
    }
};

/// Lightning Network node — manages channels and routes payments
pub const LightningNode = struct {
    /// Our node's address
    address: []const u8,
    /// Active channels
    channels: std.AutoHashMap(u64, Channel),
    /// HTLC registry for cross-channel routing
    htlc_registry: htlc_mod.HTLCRegistry,
    /// Pending invoices
    invoices: std.AutoHashMap([32]u8, Invoice),
    /// Next channel ID
    next_channel_id: u64,
    allocator: std.mem.Allocator,

    pub fn init(address: []const u8, allocator: std.mem.Allocator) LightningNode {
        return LightningNode{
            .address = address,
            .channels = std.AutoHashMap(u64, Channel).init(allocator),
            .htlc_registry = htlc_mod.HTLCRegistry.init(allocator),
            .invoices = std.AutoHashMap([32]u8, Invoice).init(allocator),
            .next_channel_id = 1,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LightningNode) void {
        self.channels.deinit();
        self.htlc_registry.deinit();
        self.invoices.deinit();
    }

    /// Open a new channel with a peer
    pub fn openChannel(
        self: *LightningNode,
        remote_addr: []const u8,
        local_deposit: u64,
        remote_deposit: u64,
        funding_tx: []const u8,
    ) !u64 {
        const id = self.next_channel_id;
        self.next_channel_id += 1;

        const capacity = local_deposit + remote_deposit;
        const reserve = capacity / 100; // 1% reserve

        try self.channels.put(id, Channel{
            .id = id,
            .funding_tx = funding_tx,
            .local_addr = self.address,
            .remote_addr = remote_addr,
            .capacity = capacity,
            .local_balance = local_deposit,
            .remote_balance = remote_deposit,
            .state = .active,
            .update_count = 0,
            .pending_htlcs = 0,
            .reserve = reserve,
            .created_at = std.time.timestamp(),
        });

        return id;
    }

    /// Send payment through a channel
    pub fn sendPayment(self: *LightningNode, channel_id: u64, amount: u64) !void {
        if (self.channels.getPtr(channel_id)) |ch| {
            try ch.updateBalance(amount, .send);
        } else return error.ChannelNotFound;
    }

    /// Receive payment through a channel
    pub fn receivePayment(self: *LightningNode, channel_id: u64, amount: u64) !void {
        if (self.channels.getPtr(channel_id)) |ch| {
            try ch.updateBalance(amount, .receive);
        } else return error.ChannelNotFound;
    }

    /// Create an invoice for receiving payment
    pub fn createInvoice(self: *LightningNode, amount: u64, description: []const u8, expiry_secs: i64) ![32]u8 {
        const pair = htlc_mod.HTLC.generatePreimage();
        const invoice = Invoice.create(pair.hash, amount, self.address, description, expiry_secs);
        try self.invoices.put(pair.hash, invoice);
        return pair.hash;
    }

    /// Close a channel cooperatively
    pub fn closeChannel(self: *LightningNode, channel_id: u64) !void {
        if (self.channels.getPtr(channel_id)) |ch| {
            try ch.initiateClose();
        } else return error.ChannelNotFound;
    }

    /// Get total capacity across all active channels
    pub fn totalCapacity(self: *const LightningNode) u64 {
        var total: u64 = 0;
        var it = self.channels.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .active) total += entry.value_ptr.capacity;
        }
        return total;
    }

    /// Get total outbound liquidity (can send)
    pub fn outboundLiquidity(self: *const LightningNode) u64 {
        var total: u64 = 0;
        var it = self.channels.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .active) {
                if (entry.value_ptr.local_balance > entry.value_ptr.reserve) {
                    total += entry.value_ptr.local_balance - entry.value_ptr.reserve;
                }
            }
        }
        return total;
    }

    /// Get total inbound liquidity (can receive)
    pub fn inboundLiquidity(self: *const LightningNode) u64 {
        var total: u64 = 0;
        var it = self.channels.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .active) {
                if (entry.value_ptr.remote_balance > entry.value_ptr.reserve) {
                    total += entry.value_ptr.remote_balance - entry.value_ptr.reserve;
                }
            }
        }
        return total;
    }

    /// Get number of active channels
    pub fn activeChannels(self: *const LightningNode) u32 {
        var count: u32 = 0;
        var it = self.channels.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .active) count += 1;
        }
        return count;
    }
};

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Lightning — open channel and send payment" {
    var node = LightningNode.init("ob1qlocal", testing.allocator);
    defer node.deinit();

    const ch_id = try node.openChannel("ob1qremote", 100000, 50000, "funding_tx_hash");
    try testing.expectEqual(@as(u32, 1), node.activeChannels());
    try testing.expectEqual(@as(u64, 150000), node.totalCapacity());

    // Send 30000 SAT
    try node.sendPayment(ch_id, 30000);
    const ch = node.channels.get(ch_id).?;
    try testing.expectEqual(@as(u64, 70000), ch.local_balance);
    try testing.expectEqual(@as(u64, 80000), ch.remote_balance);
}

test "Lightning — insufficient balance rejected" {
    var node = LightningNode.init("ob1qlocal", testing.allocator);
    defer node.deinit();

    const ch_id = try node.openChannel("ob1qremote", 10000, 5000, "tx1");
    // Try to send more than local balance (minus reserve)
    try testing.expectError(error.InsufficientLocalBalance, node.sendPayment(ch_id, 10000));
}

test "Lightning — create invoice" {
    var node = LightningNode.init("ob1qshop", testing.allocator);
    defer node.deinit();

    const payment_hash = try node.createInvoice(5000, "coffee", 3600);
    const invoice = node.invoices.get(payment_hash).?;
    try testing.expectEqual(@as(u64, 5000), invoice.amount);
    try testing.expect(!invoice.paid);
}

test "Lightning — close channel" {
    var node = LightningNode.init("ob1qlocal", testing.allocator);
    defer node.deinit();

    const ch_id = try node.openChannel("ob1qremote", 50000, 50000, "tx1");
    try node.closeChannel(ch_id);
    const ch = node.channels.get(ch_id).?;
    try testing.expectEqual(ChannelState.closing, ch.state);
}

test "Lightning — liquidity tracking" {
    var node = LightningNode.init("ob1qlocal", testing.allocator);
    defer node.deinit();

    _ = try node.openChannel("ob1qpeer1", 100000, 50000, "tx1");
    _ = try node.openChannel("ob1qpeer2", 200000, 100000, "tx2");

    // Outbound = local_balance - reserve for each channel
    try testing.expect(node.outboundLiquidity() > 0);
    try testing.expect(node.inboundLiquidity() > 0);
    try testing.expectEqual(@as(u32, 2), node.activeChannels());
}

test "Lightning — multiple payments update count" {
    var node = LightningNode.init("ob1qlocal", testing.allocator);
    defer node.deinit();

    const ch_id = try node.openChannel("ob1qremote", 100000, 100000, "tx1");
    try node.sendPayment(ch_id, 1000);
    try node.sendPayment(ch_id, 2000);
    try node.receivePayment(ch_id, 500);

    const ch = node.channels.get(ch_id).?;
    try testing.expectEqual(@as(u64, 3), ch.update_count);
    try testing.expectEqual(@as(u64, 97500), ch.local_balance);
    try testing.expectEqual(@as(u64, 102500), ch.remote_balance);
}
