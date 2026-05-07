// core/cross_chain_oracle.zig
//
// On-Omnibus snapshot of foreign-chain heads. Validators publish into
// this registry (PQ quorum 3-of-4) so that `intent_settle` transactions
// can verify SPV proofs against a known-good chain head without trusting
// any individual oracle.
//
// Persistence layout (mirrors `core/dns_registry.zig`):
//   data/<chain>/cross_chain_oracle.bin
//       header: magic(8) "OBXOA001" | version(u32 LE) |
//               btc_present(u8) | reserved(3) | eth_count(u32 LE)
//       BtcAnchor (if btc_present == 1):
//               block_height(u64 LE) | header_hash(32) | timestamp(u64 LE)
//       EthAnchor[eth_count]:
//               chain_id(u64 LE) | block_number(u64 LE) | block_hash(32) |
//               receipts_root(32) | timestamp(u64 LE)

const std = @import("std");

pub const MAX_ETH_CHAINS: usize = 32;

pub const BtcAnchor = struct {
    block_height: u64 = 0,
    header_hash: [32]u8 = [_]u8{0} ** 32,
    timestamp: u64 = 0,
};

pub const EthAnchor = struct {
    chain_id: u64 = 0,
    block_number: u64 = 0,
    block_hash: [32]u8 = [_]u8{0} ** 32,
    receipts_root: [32]u8 = [_]u8{0} ** 32,
    timestamp: u64 = 0,
};

pub const CrossChainOracle = struct {
    btc: ?BtcAnchor = null,
    eth: [MAX_ETH_CHAINS]EthAnchor = [_]EthAnchor{.{}} ** MAX_ETH_CHAINS,
    eth_count: u32 = 0,

    pub fn init() CrossChainOracle {
        return .{};
    }

    /// Update the BTC tip. Validators only — caller must enforce the
    /// 3-of-4 PQ quorum signature before calling. Rejects non-monotonic
    /// updates so a single faulty validator can't roll back the head.
    pub fn recordBtcAnchor(self: *CrossChainOracle, anchor: BtcAnchor) !void {
        if (self.btc) |existing| {
            if (anchor.block_height < existing.block_height) return error.NonMonotonic;
        }
        self.btc = anchor;
    }

    pub fn latestBtcHeight(self: *const CrossChainOracle) ?u64 {
        if (self.btc) |a| return a.block_height;
        return null;
    }

    pub fn latestBtc(self: *const CrossChainOracle) ?BtcAnchor {
        return self.btc;
    }

    /// Update the tip for a specific Ethereum-compatible chain. Indexed
    /// by `chain_id` (1=Ethereum mainnet, 8453=Base, 42161=Arbitrum,
    /// etc.). New chains are appended; updates to known chains overwrite
    /// in place. Same monotonicity rule as BTC.
    pub fn recordEthAnchor(self: *CrossChainOracle, anchor: EthAnchor) !void {
        // Find existing entry.
        var i: usize = 0;
        while (i < self.eth_count) : (i += 1) {
            if (self.eth[i].chain_id == anchor.chain_id) {
                if (anchor.block_number < self.eth[i].block_number) return error.NonMonotonic;
                self.eth[i] = anchor;
                return;
            }
        }
        if (self.eth_count >= MAX_ETH_CHAINS) return error.TooManyChains;
        self.eth[self.eth_count] = anchor;
        self.eth_count += 1;
    }

    pub fn latestEthHeight(self: *const CrossChainOracle, chain_id: u64) ?u64 {
        var i: usize = 0;
        while (i < self.eth_count) : (i += 1) {
            if (self.eth[i].chain_id == chain_id) return self.eth[i].block_number;
        }
        return null;
    }

    pub fn latestEth(self: *const CrossChainOracle, chain_id: u64) ?EthAnchor {
        var i: usize = 0;
        while (i < self.eth_count) : (i += 1) {
            if (self.eth[i].chain_id == chain_id) return self.eth[i];
        }
        return null;
    }

    // ── Persistence ──────────────────────────────────────────────────────

    const MAGIC: [8]u8 = .{ 'O', 'B', 'X', 'O', 'A', '0', '0', '1' };
    const VERSION: u32 = 1;

    pub fn saveToFile(self: *const CrossChainOracle, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var hdr: [20]u8 = undefined;
        @memcpy(hdr[0..8], &MAGIC);
        std.mem.writeInt(u32, hdr[8..12], VERSION, .little);
        hdr[12] = if (self.btc != null) 1 else 0;
        hdr[13] = 0;
        hdr[14] = 0;
        hdr[15] = 0;
        std.mem.writeInt(u32, hdr[16..20], self.eth_count, .little);
        try file.writeAll(&hdr);

        if (self.btc) |a| {
            var b: [48]u8 = undefined;
            std.mem.writeInt(u64, b[0..8], a.block_height, .little);
            @memcpy(b[8..40], &a.header_hash);
            std.mem.writeInt(u64, b[40..48], a.timestamp, .little);
            try file.writeAll(&b);
        }

        var i: usize = 0;
        while (i < self.eth_count) : (i += 1) {
            const a = self.eth[i];
            var b: [88]u8 = undefined;
            std.mem.writeInt(u64, b[0..8], a.chain_id, .little);
            std.mem.writeInt(u64, b[8..16], a.block_number, .little);
            @memcpy(b[16..48], &a.block_hash);
            @memcpy(b[48..80], &a.receipts_root);
            std.mem.writeInt(u64, b[80..88], a.timestamp, .little);
            try file.writeAll(&b);
        }
    }

    pub fn loadFromFile(self: *CrossChainOracle, path: []const u8) !void {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.* = CrossChainOracle.init();
                return;
            },
            else => return err,
        };
        defer file.close();

        var hdr: [20]u8 = undefined;
        const n = try file.readAll(&hdr);
        if (n < hdr.len) return error.CorruptFile;
        if (!std.mem.eql(u8, hdr[0..8], &MAGIC)) return error.BadMagic;
        const ver = std.mem.readInt(u32, hdr[8..12], .little);
        if (ver != VERSION) return error.UnsupportedVersion;
        const btc_present = hdr[12];
        const eth_count = std.mem.readInt(u32, hdr[16..20], .little);
        if (eth_count > MAX_ETH_CHAINS) return error.TooManyChains;

        self.* = CrossChainOracle.init();

        if (btc_present == 1) {
            var b: [48]u8 = undefined;
            if ((try file.readAll(&b)) < b.len) return error.CorruptFile;
            self.btc = BtcAnchor{
                .block_height = std.mem.readInt(u64, b[0..8], .little),
                .header_hash = b[8..40].*,
                .timestamp = std.mem.readInt(u64, b[40..48], .little),
            };
        }

        var i: u32 = 0;
        while (i < eth_count) : (i += 1) {
            var b: [88]u8 = undefined;
            if ((try file.readAll(&b)) < b.len) return error.CorruptFile;
            self.eth[i] = EthAnchor{
                .chain_id = std.mem.readInt(u64, b[0..8], .little),
                .block_number = std.mem.readInt(u64, b[8..16], .little),
                .block_hash = b[16..48].*,
                .receipts_root = b[48..80].*,
                .timestamp = std.mem.readInt(u64, b[80..88], .little),
            };
        }
        self.eth_count = eth_count;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────────

test "record + lookup + monotonic guard" {
    var o = CrossChainOracle.init();
    try o.recordBtcAnchor(.{ .block_height = 100, .header_hash = [_]u8{1} ** 32, .timestamp = 1000 });
    try std.testing.expect(o.latestBtcHeight().? == 100);

    try o.recordBtcAnchor(.{ .block_height = 200, .header_hash = [_]u8{2} ** 32, .timestamp = 2000 });
    try std.testing.expect(o.latestBtcHeight().? == 200);

    // Roll-back rejected.
    try std.testing.expectError(error.NonMonotonic, o.recordBtcAnchor(
        .{ .block_height = 150, .header_hash = [_]u8{3} ** 32, .timestamp = 3000 },
    ));

    try o.recordEthAnchor(.{ .chain_id = 1, .block_number = 19_000_000, .block_hash = [_]u8{4} ** 32, .receipts_root = [_]u8{5} ** 32, .timestamp = 1700 });
    try o.recordEthAnchor(.{ .chain_id = 8453, .block_number = 12_000_000, .block_hash = [_]u8{6} ** 32, .receipts_root = [_]u8{7} ** 32, .timestamp = 1800 });
    try std.testing.expect(o.latestEthHeight(1).? == 19_000_000);
    try std.testing.expect(o.latestEthHeight(8453).? == 12_000_000);
    try std.testing.expect(o.latestEthHeight(42161) == null);
}

test "persistence roundtrip" {
    const tmp_path = "test_cross_chain_oracle.bin";
    // Clean any leftover.
    std.fs.cwd().deleteFile(tmp_path) catch {};

    var o1 = CrossChainOracle.init();
    try o1.recordBtcAnchor(.{ .block_height = 800_000, .header_hash = [_]u8{0xab} ** 32, .timestamp = 1_700_000_000 });
    try o1.recordEthAnchor(.{ .chain_id = 1, .block_number = 19_500_000, .block_hash = [_]u8{0xcd} ** 32, .receipts_root = [_]u8{0xef} ** 32, .timestamp = 1_700_000_500 });
    try o1.recordEthAnchor(.{ .chain_id = 8453, .block_number = 13_000_000, .block_hash = [_]u8{0x12} ** 32, .receipts_root = [_]u8{0x34} ** 32, .timestamp = 1_700_000_600 });
    try o1.saveToFile(tmp_path);

    var o2 = CrossChainOracle.init();
    try o2.loadFromFile(tmp_path);

    const btc1 = o1.latestBtc().?;
    const btc2 = o2.latestBtc().?;
    try std.testing.expect(btc1.block_height == btc2.block_height);
    try std.testing.expectEqualSlices(u8, &btc1.header_hash, &btc2.header_hash);
    try std.testing.expect(btc1.timestamp == btc2.timestamp);

    try std.testing.expect(o2.eth_count == 2);
    const e1 = o2.latestEth(1).?;
    try std.testing.expect(e1.block_number == 19_500_000);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xef} ** 32), &e1.receipts_root);

    const e2 = o2.latestEth(8453).?;
    try std.testing.expect(e2.block_number == 13_000_000);

    std.fs.cwd().deleteFile(tmp_path) catch {};
}

test "load missing file returns empty" {
    const path = "definitely_does_not_exist_xcco.bin";
    var o = CrossChainOracle.init();
    try o.loadFromFile(path);
    try std.testing.expect(o.eth_count == 0);
    try std.testing.expect(o.btc == null);
}
