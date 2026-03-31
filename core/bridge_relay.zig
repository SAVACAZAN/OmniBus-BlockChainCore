/// bridge_relay.zig — Cross-Chain Bridge Relay (Lock/Mint/Burn/Redeem)
///
/// Modelul: Lock-and-Mint (ca Wrapped Bitcoin, WBTC)
///   1. User trimite BTC pe adresa de lock a bridge-ului
///   2. Relayer-ul confirma lock-ul pe BTC chain
///   3. Bridge minteaza wBTC pe OMNI chain
///   4. La redeem: burn wBTC pe OMNI → unlock BTC pe BTC chain
///
/// Securitate:
///   - Relayer-ii sunt validatori OmniBus cu stake
///   - N/M multisig: 2/3 relayeri trebuie sa confirme
///   - Timeout: daca nu se confirma in 100 blocuri → refund automat
///   - Oracle furnizeaza rata de conversie (BID/ASK de pe exchange-uri)
const std = @import("std");
const oracle_mod = @import("oracle.zig");
const array_list = std.array_list;

pub const ChainId    = oracle_mod.ChainId;
pub const ExchangeId = oracle_mod.ExchangeId;

// --- CONSTANTE ---------------------------------------------------------------

/// Multisig: din N relayeri, M trebuie sa semneze
pub const BRIDGE_REQUIRED_SIGS: u8 = 2;
pub const BRIDGE_MAX_RELAYERS:  u8 = 9;

/// Timeout in blocuri pentru o operatie de bridge
pub const BRIDGE_TIMEOUT_BLOCKS: u64 = 100;

/// Fee bridge: 0.1% (in basis points: 10/10000)
pub const BRIDGE_FEE_BPS: u64 = 10;

// --- TIPURI ------------------------------------------------------------------

pub const BridgeOpType = enum(u8) {
    lock_and_mint = 1,   // Extern → OMNI: lock pe chain extern, mint wrapped pe OMNI
    burn_and_redeem = 2, // OMNI → Extern: burn wrapped pe OMNI, redeem pe chain extern
};

pub const BridgeOpStatus = enum(u8) {
    pending    = 0,  // Initiata, asteptam confirmari
    confirmed  = 1,  // N/M relayeri au confirmat
    executed   = 2,  // Executata (mint/redeem facut)
    failed     = 3,  // Timeout sau eroare
    refunded   = 4,  // Returnat utilizatorului
};

/// O operatie de bridge (lock→mint sau burn→redeem)
pub const BridgeOperation = struct {
    op_id:       u64,
    op_type:     BridgeOpType,
    status:      BridgeOpStatus,

    /// Chain-ul extern (BTC, ETH, etc.)
    foreign_chain: ChainId,

    /// Adresa user-ului pe chain-ul extern
    foreign_addr: [64]u8,
    foreign_addr_len: u8,

    /// Adresa user-ului pe OMNI chain
    omni_addr: [32]u8,

    /// Suma in "atomic units" ale chain-ului extern (satoshi pt BTC, wei pt ETH)
    /// Stocata ca u64 — suficienta pt BTC/EGLD; pentru ETH wei folosim scaled
    amount_foreign: u64,

    /// Suma in SAT OMNI (dupa conversie prin oracle)
    amount_omni_sat: u64,

    /// Fee-ul preluat de bridge (in SAT OMNI)
    fee_sat: u64,

    /// Hash-ul TX pe chain-ul extern (dovada lock-ului)
    foreign_tx_hash: [32]u8,

    /// Blocul OMNI la care a fost initiata operatia
    initiated_block: u64,

    /// Semnaturile relayer-ilor care au confirmat
    relayer_sigs: [BRIDGE_MAX_RELAYERS][64]u8,
    sig_count:    u8,

    pub fn isExpired(self: *const BridgeOperation, current_block: u64) bool {
        return current_block > self.initiated_block + BRIDGE_TIMEOUT_BLOCKS;
    }

    pub fn hasEnoughSigs(self: *const BridgeOperation) bool {
        return self.sig_count >= BRIDGE_REQUIRED_SIGS;
    }

    /// Calculeaza fee-ul: amount * BRIDGE_FEE_BPS / 10000
    pub fn calcFee(amount: u64) u64 {
        return amount * BRIDGE_FEE_BPS / 10_000;
    }
};

/// Wrapped asset pe OMNI chain (ex: wBTC, wETH)
pub const WrappedAsset = struct {
    chain_id:    ChainId,
    total_minted_sat: u64,   // Total mintat (= total locked pe chain extern)
    total_burned_sat: u64,   // Total burnuit (= total redeemed)

    pub fn circulatingSupply(self: *const WrappedAsset) u64 {
        if (self.total_burned_sat >= self.total_minted_sat) return 0;
        return self.total_minted_sat - self.total_burned_sat;
    }
};

// --- BRIDGE RELAY ------------------------------------------------------------

pub const BridgeRelay = struct {
    allocator:  std.mem.Allocator,
    operations: array_list.Managed(BridgeOperation),
    next_op_id: u64,

    /// Wrapped assets per chain
    wrapped:    [20]WrappedAsset,

    /// Oracle pentru conversie
    oracle:     *oracle_mod.PriceOracle,

    pub fn init(allocator: std.mem.Allocator,
                oracle: *oracle_mod.PriceOracle) BridgeRelay {
        var wrapped: [20]WrappedAsset = undefined;
        for (0..20) |i| {
            wrapped[i] = WrappedAsset{
                .chain_id         = @enumFromInt(i),
                .total_minted_sat = 0,
                .total_burned_sat = 0,
            };
        }

        return BridgeRelay{
            .allocator  = allocator,
            .operations = array_list.Managed(BridgeOperation).init(allocator),
            .next_op_id = 1,
            .wrapped    = wrapped,
            .oracle     = oracle,
        };
    }

    pub fn deinit(self: *BridgeRelay) void {
        self.operations.deinit();
    }

    /// Initiaza o operatie Lock-and-Mint
    /// User a trimis `amount_foreign` pe chain-ul extern si vrea wrapped pe OMNI
    pub fn initiateLockMint(self: *BridgeRelay,
                             foreign_chain: ChainId,
                             foreign_addr:  []const u8,
                             omni_addr:     [32]u8,
                             amount_foreign: u64,
                             foreign_tx_hash: [32]u8,
                             current_block: u64) !u64 {

        // Obtine rata de conversie din oracle
        const bridge_price = self.oracle.getBridgePrice(foreign_chain) catch |err| {
            // Daca oracle-ul nu are pret, respingem bridge-ul
            std.debug.print("[BRIDGE] Oracle price unavailable for {s}: {}\n",
                .{ foreign_chain.name(), err });
            return error.OraclePriceUnavailable;
        };

        // Conversie: amount_foreign → amount_omni_sat
        // amount_foreign e in "micro" unitati ale chain-ului extern
        // bridge_price.reference_micro_usd e pretul assetului in micro-USD
        // OMNI price e 1 OMNI = X micro-USD
        const omni_price = self.oracle.getBridgePrice(.omni) catch {
            return error.OraclePriceUnavailable;
        };

        if (omni_price.reference_micro_usd == 0) return error.InvalidOraclePrice;

        // amount_omni_sat = amount_foreign * foreign_price / omni_price
        // Folosim u128 pentru overflow protection
        const amount_omni_sat_raw = @as(u128, amount_foreign) *
                                    @as(u128, bridge_price.reference_micro_usd) /
                                    @as(u128, omni_price.reference_micro_usd);

        if (amount_omni_sat_raw > std.math.maxInt(u64)) return error.AmountTooLarge;
        const amount_omni_sat: u64 = @intCast(amount_omni_sat_raw);

        const fee = BridgeOperation.calcFee(amount_omni_sat);
        const amount_net = if (amount_omni_sat > fee) amount_omni_sat - fee else return error.AmountTooSmall;

        var fa: [64]u8 = @splat(0);
        const copy_len = @min(foreign_addr.len, 64);
        @memcpy(fa[0..copy_len], foreign_addr[0..copy_len]);

        const op = BridgeOperation{
            .op_id           = self.next_op_id,
            .op_type         = .lock_and_mint,
            .status          = .pending,
            .foreign_chain   = foreign_chain,
            .foreign_addr    = fa,
            .foreign_addr_len = @intCast(copy_len),
            .omni_addr       = omni_addr,
            .amount_foreign  = amount_foreign,
            .amount_omni_sat = amount_net,
            .fee_sat         = fee,
            .foreign_tx_hash = foreign_tx_hash,
            .initiated_block = current_block,
            .relayer_sigs    = @splat([_]u8{0} ** 64),
            .sig_count       = 0,
        };

        try self.operations.append(op);
        self.next_op_id += 1;

        std.debug.print("[BRIDGE] Lock-Mint initiated: op#{d} | {s} {d} -> OMNI {d} SAT (fee={d})\n",
            .{ op.op_id, foreign_chain.name(), amount_foreign, amount_net, fee });

        return op.op_id;
    }

    /// Relayer confirma o operatie (adauga semnatura)
    pub fn confirmOperation(self: *BridgeRelay,
                             op_id: u64,
                             relayer_sig: [64]u8) !void {
        const op = try self.findOperation(op_id);
        if (op.status != .pending) return error.OperationNotPending;
        if (op.sig_count >= BRIDGE_MAX_RELAYERS) return error.TooManyRelayers;

        op.relayer_sigs[op.sig_count] = relayer_sig;
        op.sig_count += 1;

        std.debug.print("[BRIDGE] Op #{d} confirmed by relayer ({d}/{d})\n",
            .{ op_id, op.sig_count, BRIDGE_REQUIRED_SIGS });

        // Daca avem destule semnaturi, marcam ca confirmed
        if (op.hasEnoughSigs() and op.status == .pending) {
            op.status = .confirmed;
        }
    }

    /// Executa operatia confirmata (mint sau redeem)
    pub fn executeOperation(self: *BridgeRelay,
                             op_id: u64,
                             current_block: u64) !u64 {
        const op = try self.findOperation(op_id);

        if (op.status == .pending) {
            if (op.isExpired(current_block)) {
                op.status = .failed;
                return error.OperationExpired;
            }
            return error.NotEnoughConfirmations;
        }
        if (op.status != .confirmed) return error.OperationNotConfirmed;

        const chain_idx = @intFromEnum(op.foreign_chain);

        switch (op.op_type) {
            .lock_and_mint => {
                // Mint wrapped asset pe OMNI
                self.wrapped[chain_idx].total_minted_sat += op.amount_omni_sat;
                op.status = .executed;
                std.debug.print("[BRIDGE] MINT: w{s} {d} SAT -> omni_addr\n",
                    .{ op.foreign_chain.name(), op.amount_omni_sat });
                return op.amount_omni_sat;
            },
            .burn_and_redeem => {
                // Burn wrapped asset
                const ws = &self.wrapped[chain_idx];
                if (ws.circulatingSupply() < op.amount_omni_sat) return error.InsufficientWrappedSupply;
                ws.total_burned_sat += op.amount_omni_sat;
                op.status = .executed;
                std.debug.print("[BRIDGE] BURN: w{s} {d} SAT -> redeem {d} foreign units\n",
                    .{ op.foreign_chain.name(), op.amount_omni_sat, op.amount_foreign });
                return op.amount_foreign;
            },
        }
    }

    /// Refund daca operatia a expirat
    pub fn refundExpired(self: *BridgeRelay,
                          op_id: u64,
                          current_block: u64) !void {
        const op = try self.findOperation(op_id);
        if (op.status != .pending) return error.OperationNotPending;
        if (!op.isExpired(current_block)) return error.OperationNotExpired;
        op.status = .refunded;
        std.debug.print("[BRIDGE] Op #{d} REFUNDED (expired)\n", .{op_id});
    }

    fn findOperation(self: *BridgeRelay, op_id: u64) !*BridgeOperation {
        for (self.operations.items) |*op| {
            if (op.op_id == op_id) return op;
        }
        return error.OperationNotFound;
    }

    pub fn printStatus(self: *const BridgeRelay) void {
        std.debug.print("[BRIDGE] Operations: {d} | next_id: {d}\n",
            .{ self.operations.items.len, self.next_op_id });
        for (0..20) |i| {
            const w = self.wrapped[i];
            if (w.total_minted_sat > 0) {
                std.debug.print("  w{s}: minted={d} burned={d} circulating={d}\n",
                    .{ w.chain_id.name(), w.total_minted_sat, w.total_burned_sat, w.circulatingSupply() });
            }
        }
    }
};

// --- TESTE -------------------------------------------------------------------
const testing = std.testing;

fn setupOracle() oracle_mod.PriceOracle {
    var oracle = oracle_mod.PriceOracle.init();
    const now = std.time.milliTimestamp();

    // OMNI = $10
    oracle.submitQuote(.{
        .chain_id = .omni, .exchange_id = .binance,
        .bid_micro_usd = 9_900_000, .ask_micro_usd = 10_100_000,
        .volume_24h_micro_usd = 0, .timestamp_ms = now,
    }) catch {};

    // BTC = $50,000
    oracle.submitQuote(.{
        .chain_id = .btc, .exchange_id = .binance,
        .bid_micro_usd = 49_900_000_000, .ask_micro_usd = 50_100_000_000,
        .volume_24h_micro_usd = 0, .timestamp_ms = now,
    }) catch {};

    // ETH = $3,000
    oracle.submitQuote(.{
        .chain_id = .eth, .exchange_id = .binance,
        .bid_micro_usd = 2_990_000_000, .ask_micro_usd = 3_010_000_000,
        .volume_24h_micro_usd = 0, .timestamp_ms = now,
    }) catch {};

    return oracle;
}

test "BridgeOperation — fee calculat corect" {
    // 10 BPS = 0.1% din 1_000_000 = 1_000
    try testing.expectEqual(@as(u64, 1_000), BridgeOperation.calcFee(1_000_000));
}

test "BridgeOperation — isExpired dupa 100 blocuri" {
    const op = BridgeOperation{
        .op_id = 1, .op_type = .lock_and_mint, .status = .pending,
        .foreign_chain = .btc, .foreign_addr = @splat(0), .foreign_addr_len = 0,
        .omni_addr = @splat(0), .amount_foreign = 0, .amount_omni_sat = 0,
        .fee_sat = 0, .foreign_tx_hash = @splat(0), .initiated_block = 100,
        .relayer_sigs = @splat([_]u8{0} ** 64), .sig_count = 0,
    };
    try testing.expect(!op.isExpired(150));
    try testing.expect(!op.isExpired(200));
    try testing.expect(op.isExpired(201));
}

test "BridgeRelay — init ok" {
    var oracle = setupOracle();
    var bridge = BridgeRelay.init(testing.allocator, &oracle);
    defer bridge.deinit();
    try testing.expectEqual(@as(u64, 1), bridge.next_op_id);
}

test "BridgeRelay — initiateLockMint creeaza operatie" {
    var oracle = setupOracle();
    var bridge = BridgeRelay.init(testing.allocator, &oracle);
    defer bridge.deinit();

    const omni_addr: [32]u8 = @splat(0xAA);
    const tx_hash:   [32]u8 = @splat(0x11);

    const op_id = try bridge.initiateLockMint(
        .btc, "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
        omni_addr, 100_000_000,  // 1 BTC (in satoshi)
        tx_hash, 1000,
    );
    try testing.expectEqual(@as(u64, 1), op_id);
    try testing.expectEqual(@as(usize, 1), bridge.operations.items.len);
}

test "BridgeRelay — confirm si execute" {
    var oracle = setupOracle();
    var bridge = BridgeRelay.init(testing.allocator, &oracle);
    defer bridge.deinit();

    const omni_addr: [32]u8 = @splat(0xAA);
    // ETH amount in micro-USD scaled units: 3000 * 10^6 = 3_000_000_000 (=$3000 worth)
    const op_id = try bridge.initiateLockMint(
        .eth, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
        omni_addr, 3_000_000_000,  // $3000 in micro-USD units
        @splat(0x22), 1000,
    );

    const sig1: [64]u8 = @splat(0x01);
    const sig2: [64]u8 = @splat(0x02);
    try bridge.confirmOperation(op_id, sig1);
    try bridge.confirmOperation(op_id, sig2);

    // Dupa 2 confirmari trebuie sa fie confirmed
    const op = try bridge.findOperation(op_id);
    try testing.expectEqual(BridgeOpStatus.confirmed, op.status);

    const minted = try bridge.executeOperation(op_id, 1001);
    try testing.expect(minted > 0);
    try testing.expectEqual(BridgeOpStatus.executed, op.status);
}

test "BridgeRelay — execute fara confirmari returneaza eroare" {
    var oracle = setupOracle();
    var bridge = BridgeRelay.init(testing.allocator, &oracle);
    defer bridge.deinit();

    const op_id = try bridge.initiateLockMint(
        .btc, "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
        @splat(0xAA), 100_000_000, @splat(0x11), 1000,
    );
    try testing.expectError(error.NotEnoughConfirmations,
        bridge.executeOperation(op_id, 1001));
}

test "BridgeRelay — refund dupa expirare" {
    var oracle = setupOracle();
    var bridge = BridgeRelay.init(testing.allocator, &oracle);
    defer bridge.deinit();

    const op_id = try bridge.initiateLockMint(
        .btc, "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
        @splat(0xAA), 100_000_000, @splat(0x11), 1000,
    );

    // Inainte de expirare
    try testing.expectError(error.OperationNotExpired,
        bridge.refundExpired(op_id, 1050));

    // Dupa expirare (1000 + 100 = 1100)
    try bridge.refundExpired(op_id, 1200);
    const op = try bridge.findOperation(op_id);
    try testing.expectEqual(BridgeOpStatus.refunded, op.status);
}

test "BridgeRelay — wrapped asset supply tracking" {
    var oracle = setupOracle();
    var bridge = BridgeRelay.init(testing.allocator, &oracle);
    defer bridge.deinit();

    const chain_idx = @intFromEnum(ChainId.btc);
    try testing.expectEqual(@as(u64, 0), bridge.wrapped[chain_idx].circulatingSupply());

    // Mint manual pt test
    bridge.wrapped[chain_idx].total_minted_sat = 1_000_000;
    bridge.wrapped[chain_idx].total_burned_sat = 300_000;
    try testing.expectEqual(@as(u64, 700_000), bridge.wrapped[chain_idx].circulatingSupply());
}
