//! fills_log.zig — append-only binary log of executed trade fills.
//!
//! Each fill in the matching engine is volatile (RAM only). To make trade
//! history queryable across restarts and visible in the frontend's
//! "My Trades" panel, we mirror every fill into a binary log on disk.
//!
//! The log is local to each node (not propagated via P2P). PC and VPS keep
//! independent copies; if you want a consolidated history, query whichever
//! node served the fill (matching engine runs only on the node that accepted
//! the order via exchange_placeOrder RPC).
//!
//! Wire format (fixed 224-byte records, little-endian):
//!   [0..1]    version: u8           — currently 1
//!   [1..9]    fill_id: u64
//!   [9..11]   pair_id: u16
//!   [11..12]  taker_side: u8        — 0=buy taker, 1=sell taker
//!   [12..20]  price_micro_usd: u64
//!   [20..28]  amount_sat: u64
//!   [28..36]  buy_order_id: u64
//!   [36..44]  sell_order_id: u64
//!   [44..52]  timestamp_ms: i64
//!   [52..60]  block_height: u64
//!   [60..68]  evm_chain_id: u64     — 0 = OMNI-only fill
//!   [68..132] buyer_address: [64]u8 — null-padded UTF-8
//!   [132..133] buyer_addr_len: u8
//!   [133..197] seller_address: [64]u8
//!   [197..198] seller_addr_len: u8
//!   [198..218] seller_evm: [20]u8   — zero if non-cross-chain
//!   [218..220] _reserved: u16       — must be 0
//!   [220..224] settle_status: u32   — 0=pending, 1=settled, 2=failed
//!
//! Plus a 32-byte settle tx hash region (appended after a settle confirms,
//! held in a parallel `fills_settle.bin` file keyed by fill_id; written by
//! recordSettle()).
//!
//! Reader pattern: open file, stream RECORD_SIZE chunks, decode each. The
//! file is monotonic — newer fills appended at end.

const std = @import("std");
const matching_mod = @import("matching_engine.zig");

pub const RECORD_SIZE: usize = 224;
pub const SETTLE_RECORD_SIZE: usize = 8 + 32 + 4; // fill_id + tx_hash + chain_id

pub const SettleStatus = enum(u32) {
    pending = 0,
    settled = 1,
    failed = 2,
};

pub const SettleEntry = struct {
    tx_hash: [32]u8,
    chain_id: u32,
};

pub const SettleMap = std.AutoHashMap(u64, SettleEntry);

pub const Record = struct {
    version: u8 = 1,
    fill_id: u64,
    pair_id: u16,
    taker_side: u8, // 0=buy taker, 1=sell taker
    price_micro_usd: u64,
    amount_sat: u64,
    buy_order_id: u64,
    sell_order_id: u64,
    timestamp_ms: i64,
    block_height: u64,
    evm_chain_id: u64,
    buyer_address: [64]u8,
    buyer_addr_len: u8,
    seller_address: [64]u8,
    seller_addr_len: u8,
    seller_evm: [20]u8,
    settle_status: SettleStatus = .pending,

    pub fn buyerAddrSlice(self: *const Record) []const u8 {
        return self.buyer_address[0..self.buyer_addr_len];
    }
    pub fn sellerAddrSlice(self: *const Record) []const u8 {
        return self.seller_address[0..self.seller_addr_len];
    }
};

pub const FillsLog = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    settle_path: []const u8,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) !FillsLog {
        const path = try std.fmt.allocPrint(allocator, "{s}/fills_log.bin", .{dir});
        const settle_path = try std.fmt.allocPrint(allocator, "{s}/fills_settle.bin", .{dir});
        // Make sure dir exists.
        std.fs.cwd().makePath(dir) catch {};
        return FillsLog{
            .allocator = allocator,
            .path = path,
            .settle_path = settle_path,
        };
    }

    pub fn deinit(self: *FillsLog) void {
        self.allocator.free(self.path);
        self.allocator.free(self.settle_path);
    }

    /// Append a new fill. Idempotent on fill_id only if caller checks first;
    /// no internal dedup so the matching engine doesn't pay a scan cost.
    pub fn append(
        self: *FillsLog,
        fill: matching_mod.Fill,
        taker_side: u8,
        block_height: u64,
        evm_chain_id: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: [RECORD_SIZE]u8 = [_]u8{0} ** RECORD_SIZE;
        buf[0] = 1; // version
        std.mem.writeInt(u64, buf[1..9], fill.fill_id, .little);
        std.mem.writeInt(u16, buf[9..11], fill.pair_id, .little);
        buf[11] = taker_side;
        std.mem.writeInt(u64, buf[12..20], fill.price_micro_usd, .little);
        std.mem.writeInt(u64, buf[20..28], fill.amount_sat, .little);
        std.mem.writeInt(u64, buf[28..36], fill.buy_order_id, .little);
        std.mem.writeInt(u64, buf[36..44], fill.sell_order_id, .little);
        std.mem.writeInt(i64, buf[44..52], fill.timestamp_ms, .little);
        std.mem.writeInt(u64, buf[52..60], block_height, .little);
        std.mem.writeInt(u64, buf[60..68], evm_chain_id, .little);
        @memcpy(buf[68..132], &fill.buyer_address);
        buf[132] = fill.buyer_addr_len;
        @memcpy(buf[133..197], &fill.seller_address);
        buf[197] = fill.seller_addr_len;
        @memcpy(buf[198..218], &fill.seller_evm);
        // 218..220 reserved (already zero)
        std.mem.writeInt(u32, buf[220..224], @intFromEnum(SettleStatus.pending), .little);

        const f = try std.fs.cwd().createFile(self.path, .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writeAll(&buf);
    }

    /// Record settle outcome — appended to the parallel settle log. Reader
    /// merges by fill_id when serving exchange_getUserTrades.
    pub fn recordSettle(
        self: *FillsLog,
        fill_id: u64,
        tx_hash: [32]u8,
        chain_id: u32,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf: [SETTLE_RECORD_SIZE]u8 = [_]u8{0} ** SETTLE_RECORD_SIZE;
        std.mem.writeInt(u64, buf[0..8], fill_id, .little);
        @memcpy(buf[8..40], &tx_hash);
        std.mem.writeInt(u32, buf[40..44], chain_id, .little);

        const f = try std.fs.cwd().createFile(self.settle_path, .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writeAll(&buf);
    }

    /// Settle map: fill_id → (tx_hash, chain_id). Caller owns the returned map.
    pub fn loadSettleMap(self: *FillsLog) !SettleMap {
        var map = SettleMap.init(self.allocator);

        const f = std.fs.cwd().openFile(self.settle_path, .{}) catch return map;
        defer f.close();

        var buf: [SETTLE_RECORD_SIZE]u8 = undefined;
        while (true) {
            const n = f.readAll(&buf) catch break;
            if (n < SETTLE_RECORD_SIZE) break;
            const fill_id = std.mem.readInt(u64, buf[0..8], .little);
            var tx_hash: [32]u8 = undefined;
            @memcpy(&tx_hash, buf[8..40]);
            const chain_id = std.mem.readInt(u32, buf[40..44], .little);
            try map.put(fill_id, .{ .tx_hash = tx_hash, .chain_id = chain_id });
        }
        return map;
    }

    /// Read all records, filtered by trader address (empty = all). Returns
    /// owned slice; caller frees with allocator.free(records).
    pub fn readForTrader(
        self: *FillsLog,
        allocator: std.mem.Allocator,
        trader: []const u8,
        limit: usize,
    ) ![]Record {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list = std.array_list.Managed(Record).init(allocator);
        defer list.deinit();

        const f = std.fs.cwd().openFile(self.path, .{}) catch return try list.toOwnedSlice();
        defer f.close();

        var buf: [RECORD_SIZE]u8 = undefined;
        while (true) {
            const n = f.readAll(&buf) catch break;
            if (n < RECORD_SIZE) break;

            var rec = Record{
                .version = buf[0],
                .fill_id = std.mem.readInt(u64, buf[1..9], .little),
                .pair_id = std.mem.readInt(u16, buf[9..11], .little),
                .taker_side = buf[11],
                .price_micro_usd = std.mem.readInt(u64, buf[12..20], .little),
                .amount_sat = std.mem.readInt(u64, buf[20..28], .little),
                .buy_order_id = std.mem.readInt(u64, buf[28..36], .little),
                .sell_order_id = std.mem.readInt(u64, buf[36..44], .little),
                .timestamp_ms = std.mem.readInt(i64, buf[44..52], .little),
                .block_height = std.mem.readInt(u64, buf[52..60], .little),
                .evm_chain_id = std.mem.readInt(u64, buf[60..68], .little),
                .buyer_address = undefined,
                .buyer_addr_len = buf[132],
                .seller_address = undefined,
                .seller_addr_len = buf[197],
                .seller_evm = undefined,
                .settle_status = @enumFromInt(std.mem.readInt(u32, buf[220..224], .little)),
            };
            @memcpy(&rec.buyer_address, buf[68..132]);
            @memcpy(&rec.seller_address, buf[133..197]);
            @memcpy(&rec.seller_evm, buf[198..218]);

            if (trader.len > 0) {
                const is_buyer = std.mem.eql(u8, rec.buyerAddrSlice(), trader);
                const is_seller = std.mem.eql(u8, rec.sellerAddrSlice(), trader);
                if (!is_buyer and !is_seller) continue;
            }

            try list.append(rec);
            if (limit > 0 and list.items.len >= limit) break;
        }

        return try list.toOwnedSlice();
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "fills_log append + read roundtrip" {
    const alloc = std.testing.allocator;
    const tmp_dir = "test_fills_log_tmp";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    var log = try FillsLog.init(alloc, tmp_dir);
    defer log.deinit();

    var fill = matching_mod.Fill.empty();
    fill.fill_id = 42;
    fill.pair_id = 0;
    fill.price_micro_usd = 1_000_000;
    fill.amount_sat = 5_000_000_000;
    fill.buy_order_id = 1;
    fill.sell_order_id = 2;
    fill.timestamp_ms = 1_700_000_000_000;
    const addr_a = "ob1qbuyer000000";
    const addr_b = "ob1qseller00000";
    @memcpy(fill.buyer_address[0..addr_a.len], addr_a);
    fill.buyer_addr_len = @intCast(addr_a.len);
    @memcpy(fill.seller_address[0..addr_b.len], addr_b);
    fill.seller_addr_len = @intCast(addr_b.len);

    try log.append(fill, 0, 100, 11155111);

    const recs = try log.readForTrader(alloc, addr_a, 10);
    defer alloc.free(recs);
    try std.testing.expectEqual(@as(usize, 1), recs.len);
    try std.testing.expectEqual(@as(u64, 42), recs[0].fill_id);
    try std.testing.expectEqual(@as(u64, 11155111), recs[0].evm_chain_id);

    // Record settle for the same fill_id.
    var tx_hash: [32]u8 = undefined;
    for (&tx_hash, 0..) |*b, i| b.* = @intCast(i);
    try log.recordSettle(42, tx_hash, 11155111);

    var settle_map = try log.loadSettleMap();
    defer settle_map.deinit();
    const entry = settle_map.get(42) orelse return error.MissingSettle;
    try std.testing.expectEqual(@as(u32, 11155111), entry.chain_id);
    try std.testing.expectEqual(@as(u8, 0), entry.tx_hash[0]);
    try std.testing.expectEqual(@as(u8, 31), entry.tx_hash[31]);
}
