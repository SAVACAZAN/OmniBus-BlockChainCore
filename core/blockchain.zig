const std = @import("std");
const block_mod = @import("block.zig");
const transaction_mod = @import("transaction.zig");
const hex_utils = @import("hex_utils.zig");
const array_list = std.array_list;

pub const Block = block_mod.Block;
pub const Transaction = transaction_mod.Transaction;

/// Block reward: 0.08333333 OMNI in SAT (9 decimale: 1 OMNI = 1,000,000,000 sat)
/// Echivalent cu 50 OMNI la 10 minute (600 blocuri × 0.08333333 = 50 OMNI)
/// Identic economic cu Bitcoin (50 BTC / 10 min), dar la viteza de 1 bloc/secunda
pub const BLOCK_REWARD_SAT: u64 = 8_333_333; // 0.08333333 OMNI
pub const HALVING_INTERVAL: u64 = 126_144_000; // 4 ani × 365.25 zile × 86400 sec/zi

/// Numarul total de SAT emisi vreodata: 21,000,000 × 10^9 = 21 × 10^15
pub const MAX_SUPPLY_SAT: u64 = 21_000_000_000_000_000;

/// Coinbase maturity: block rewards nu pot fi cheltuite inainte de N confirmari
/// Bitcoin: 100 blocks, Dogecoin: 100 blocks
/// OmniBus: 100 blocks (~100 secunde la 1 block/s)
pub const COINBASE_MATURITY: u32 = 100;

/// Dust threshold: TX cu amount sub aceasta valoare sunt respinse
/// Bitcoin: 546 sat, Dogecoin: 1 DOGE
/// OmniBus: 100 SAT (0.0000001 OMNI)
pub const DUST_THRESHOLD_SAT: u64 = 100;

/// Difficulty retarget: la fiecare 2016 blocuri (ca Bitcoin)
pub const RETARGET_INTERVAL: u64 = 2016;
/// Timp tinta per bloc: 1 secunda (OmniBus block time)
pub const TARGET_BLOCK_TIME_S: i64 = 1;
/// Timp tinta total pentru un interval retarget: 2016 secunde
pub const TARGET_INTERVAL_S: i64 = @intCast(RETARGET_INTERVAL); // 2016s
/// Dificultate minima si maxima permisa
/// Extended range: MAX=256 (was 32) — closer to Bitcoin's full difficulty range
/// Bitcoin difficulty can go up to ~80 trillion; 256 leading zero bits = full SHA-256
pub const MIN_DIFFICULTY: u32 = 1;
pub const MAX_DIFFICULTY: u32 = 256;

/// Fee burn percentage (0-100): ce procent din fees se ard (ca EIP-1559)
/// Default 50%: jumatate la miner, jumatate arse (deflationary pressure)
/// Configurabil prin governance
pub const FEE_BURN_PCT: u64 = 50;

/// Minimum fee per transaction (1 SAT anti-spam, same as mempool)
pub const TX_MIN_FEE: u64 = 1;

/// Total fees burned (tracked for supply accounting)
pub var total_fees_burned_sat: u64 = 0;

/// Calculeaza noua dificultate dupa un interval de retarget.
/// Formula: new_difficulty = old_difficulty * TARGET_INTERVAL / actual_time
/// Clamped la ±4x fata de dificultatea anterioara (ca Bitcoin) si [MIN, MAX].
pub fn retargetDifficulty(old_difficulty: u32, actual_time_s: i64) u32 {
    if (actual_time_s <= 0) return old_difficulty;

    // Clamp actual time la [target/4, target*4] (ca Bitcoin)
    const clamped_time = @max(TARGET_INTERVAL_S / 4, @min(TARGET_INTERVAL_S * 4, actual_time_s));

    // new = old * TARGET / actual  (integer math)
    const old: i64 = @intCast(old_difficulty);
    const new_diff_i64 = @divTrunc(old * TARGET_INTERVAL_S, clamped_time);

    // Clamp la [MIN_DIFFICULTY, MAX_DIFFICULTY]
    if (new_diff_i64 < MIN_DIFFICULTY) return MIN_DIFFICULTY;
    if (new_diff_i64 > MAX_DIFFICULTY) return MAX_DIFFICULTY;
    return @intCast(new_diff_i64);
}

pub fn blockRewardAt(height: u64) u64 {
    const halvings = height / HALVING_INTERVAL;
    if (halvings >= 64) return 0;
    return BLOCK_REWARD_SAT >> @intCast(halvings);
}

pub const Blockchain = struct {
    chain: array_list.Managed(Block),
    mempool: array_list.Managed(Transaction),
    difficulty: u32,
    allocator: std.mem.Allocator,
    /// Balantele adreselor (in-memory, sincronizat cu database)
    balances: std.StringHashMap(u64),
    /// Nonce tracking per adresa: urmatorul nonce asteptat (anti-replay, ca Ethereum)
    /// Previne replay attacks: aceeasi TX nu poate fi trimisa de doua ori
    nonces: std.StringHashMap(u64),

    pub fn init(allocator: std.mem.Allocator) !Blockchain {
        var chain = array_list.Managed(Block).init(allocator);
        const mempool = array_list.Managed(Transaction).init(allocator);

        // Create genesis block
        const genesis = Block{
            .index = 0,
            .timestamp = 1743000000,
            .transactions = array_list.Managed(Transaction).init(allocator),
            .previous_hash = "0000000000000000000000000000000000000000000000000000000000000000",
            .nonce = 0,
            .hash = "genesis_hash_omnibus_v1",
        };

        try chain.append(genesis);

        return Blockchain{
            .chain = chain,
            .mempool = mempool,
            .difficulty = 4,
            .allocator = allocator,
            .balances = std.StringHashMap(u64).init(allocator),
            .nonces = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *Blockchain) void {
        for (self.chain.items, 0..) |*block, i| {
            block.transactions.deinit();
            // Blocurile minate (index > 0) au hash alocat pe heap (64 hex chars)
            // Genesis (index 0) are hash string literal — nu se elibereaza
            if (i > 0 and block.hash.len == 64) {
                self.allocator.free(block.hash);
            }
            // miner_address alocat pe heap doar la blocuri restaurate din disc
            if (block.miner_heap) {
                self.allocator.free(block.miner_address);
            }
        }
        self.chain.deinit();
        self.mempool.deinit();
        self.balances.deinit();
        self.nonces.deinit();
    }

    /// Returneaza balanta unei adrese (0 daca nu exista)
    pub fn getAddressBalance(self: *const Blockchain, address: []const u8) u64 {
        return self.balances.get(address) orelse 0;
    }

    /// Adauga reward la balanta minerului
    pub fn creditBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
        const existing = self.balances.get(address) orelse 0;
        try self.balances.put(address, existing + amount);
    }

    /// Scade din balanta (pentru tranzactii)
    pub fn debitBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
        const existing = self.balances.get(address) orelse 0;
        if (existing < amount) return error.InsufficientBalance;
        try self.balances.put(address, existing - amount);
    }

    pub fn addTransaction(self: *Blockchain, tx: Transaction) !void {
        // Validate transaction
        if (!try self.validateTransaction(&tx)) {
            return error.InvalidTransaction;
        }

        try self.mempool.append(tx);
    }

    /// Returneaza urmatorul nonce asteptat pentru o adresa (0 daca nu exista)
    pub fn getNextNonce(self: *const Blockchain, address: []const u8) u64 {
        return self.nonces.get(address) orelse 0;
    }

    pub fn validateTransaction(self: *Blockchain, tx: *const Transaction) !bool {
        // 1. Amount trebuie > 0
        if (tx.amount == 0) { std.debug.print("[VALIDATE] FAIL: amount=0\n", .{}); return false; }

        // 2. Adrese nu pot fi goale
        if (tx.from_address.len == 0 or tx.to_address.len == 0) { std.debug.print("[VALIDATE] FAIL: empty addr\n", .{}); return false; }

        // 3. Prefix valid (isValid verifică prefix + amount)
        if (!tx.isValid()) { std.debug.print("[VALIDATE] FAIL: isValid() from={s} to={s} amt={d}\n", .{tx.from_address[0..@min(20,tx.from_address.len)], tx.to_address[0..@min(20,tx.to_address.len)], tx.amount}); return false; }

        // 3b. Dust threshold — respinge TX prea mici (anti-spam, ca Bitcoin 546 sat)
        if (tx.amount < DUST_THRESHOLD_SAT) { std.debug.print("[VALIDATE] FAIL: dust {d} < {d}\n", .{tx.amount, DUST_THRESHOLD_SAT}); return false; }

        // 4. Nonce check (anti-replay attack, ca Ethereum/EGLD)
        const expected_nonce = self.getNextNonce(tx.from_address);
        if (tx.nonce < expected_nonce) { std.debug.print("[VALIDATE] FAIL: nonce {d} < expected {d}\n", .{tx.nonce, expected_nonce}); return false; }

        // 5. Balance check: sender trebuie sa aiba suficient sold
        const sender_balance = self.getAddressBalance(tx.from_address);
        if (sender_balance < tx.amount) { std.debug.print("[VALIDATE] FAIL: balance {d} < amount {d}\n", .{sender_balance, tx.amount}); return false; }

        // 6. Dacă TX are semnătură — verifică integritatea hash-ului
        //    (signature = 128 hex chars = 64 bytes R||S, hash = 64 hex chars)
        //    Nu putem verifica semnătura fără public key, dar verificăm că
        //    hash-ul stocat corespunde conținutului TX (anti-tampering)
        if (tx.signature.len == 128 and tx.hash.len == 64) {
            const expected_hash = tx.calculateHash();
            // Reconvertim hash stocat din hex (using shared hex_utils)
            var stored_hash: [32]u8 = undefined;
            hex_utils.hexToBytes(tx.hash, &stored_hash) catch return false;
            if (!std.mem.eql(u8, &stored_hash, &expected_hash)) return false;
        } else if (tx.signature.len > 0) {
            // Semnătură incompletă — respinge
            return false;
        }

        return true;
    }

    pub fn mineBlock(self: *Blockchain) !Block {
        return self.mineBlockForMiner("");
    }

    /// Mine block + acorda reward minerului + proceseaza TX-urile din mempool
    pub fn mineBlockForMiner(self: *Blockchain, miner_address: []const u8) !Block {
        if (self.chain.items.len == 0) {
            return error.EmptyChain;
        }

        const previous_block = self.chain.items[self.chain.items.len - 1];
        const index = self.chain.items.len;
        const timestamp = std.time.timestamp();

        const reward = if (miner_address.len > 0) blockRewardAt(@intCast(index)) else 0;

        var block = Block{
            .index = @intCast(index),
            .timestamp = timestamp,
            .transactions = self.mempool,
            .previous_hash = previous_block.hash,
            .nonce = 0,
            .hash = "",
            .miner_address = miner_address,
            .reward_sat = reward,
        };

        // Calculate Merkle Root (commits to all TX in block header, like Bitcoin)
        block.merkle_root = block.calculateMerkleRoot();

        // Proof-of-Work (bounded: max 2^32 nonces before giving up, like Bitcoin)
        var nonce: u64 = 0;
        const MAX_NONCE: u64 = 4_294_967_296; // 2^32 — if not found, re-roll with new timestamp
        while (nonce < MAX_NONCE) {
            block.nonce = nonce;
            const hash = try self.calculateBlockHash(&block);
            if (try self.isValidHash(hash)) {
                block.hash = hash;
                break;
            }
            self.allocator.free(hash);
            nonce += 1;
        }

        // Proceseaza tranzactiile: debiteaza sender, crediteaza receiver, incrementeaza nonce
        for (block.transactions.items) |tx| {
            self.debitBalance(tx.from_address, tx.amount) catch {}; // ignora daca insuficient
            self.creditBalance(tx.to_address, tx.amount) catch {};
            // Incrementeaza nonce-ul sender-ului (anti-replay: urmatoarea TX trebuie nonce+1)
            const current_nonce = self.nonces.get(tx.from_address) orelse 0;
            self.nonces.put(tx.from_address, current_nonce + 1) catch {};
        }

        // Collect fees — all fees go to miner (like Bitcoin)
        const total_fees: u64 = block.transactions.items.len * TX_MIN_FEE;

        // Block reward + all fees for miner (Bitcoin model: miner gets reward + all TX fees)
        if (miner_address.len > 0 and (reward > 0 or total_fees > 0)) {
            self.creditBalance(miner_address, reward + total_fees) catch {};
            std.debug.print("[REWARD] Miner {s} +{d} SAT ({d:.2} OMNI) + {d} fees @ block {d}\n",
                .{ miner_address[0..@min(16, miner_address.len)], reward,
                   @as(f64, @floatFromInt(reward)) / 1e9, total_fees, index });
        }

        // Add block to chain
        try self.chain.append(block);

        // Difficulty retarget la fiecare RETARGET_INTERVAL blocuri
        if (index % RETARGET_INTERVAL == 0 and index > 0) {
            const retarget_start = index - RETARGET_INTERVAL;
            const old_block_ts = self.chain.items[retarget_start].timestamp;
            const new_block_ts = block.timestamp;
            const actual_time = new_block_ts - old_block_ts;
            const new_diff = retargetDifficulty(self.difficulty, actual_time);
            if (new_diff != self.difficulty) {
                std.debug.print("[RETARGET] Block {d}: difficulty {d} → {d} (actual {d}s, target {d}s)\n",
                    .{ index, self.difficulty, new_diff, actual_time, TARGET_INTERVAL_S });
                self.difficulty = new_diff;
            }
        }

        // Reset mempool
        self.mempool = array_list.Managed(Transaction).init(self.allocator);

        return block;
    }

    /// Calculate block hash as 64-char hex string (shared implementation in hex_utils)
    pub fn calculateBlockHash(self: *Blockchain, block: *const Block) ![]const u8 {
        return hex_utils.hashBlock(block.*, self.allocator);
    }

    /// Check if hash meets difficulty (delegates to shared hex_utils)
    pub fn isValidHash(self: *Blockchain, hash: []const u8) !bool {
        return hex_utils.isValidHashDifficulty(hash, self.difficulty);
    }

    pub fn getBlock(self: *Blockchain, index: u32) ?Block {
        if (index < self.chain.items.len) {
            return self.chain.items[index];
        }
        return null;
    }

    pub fn getLatestBlock(self: *Blockchain) Block {
        return self.chain.items[self.chain.items.len - 1];
    }

    pub fn getBlockCount(self: *Blockchain) u32 {
        return @intCast(self.chain.items.len);
    }
};

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "blockRewardAt — bloc 0 = reward initial" {
    try testing.expectEqual(BLOCK_REWARD_SAT, blockRewardAt(0));
}

test "blockRewardAt — halving la HALVING_INTERVAL" {
    const r0 = blockRewardAt(0);
    const r1 = blockRewardAt(HALVING_INTERVAL);
    try testing.expectEqual(r0 / 2, r1);
}

test "blockRewardAt — dupa 64 halvings = 0" {
    try testing.expectEqual(@as(u64, 0), blockRewardAt(HALVING_INTERVAL * 64));
}

test "Blockchain.init — geneza + 1 bloc in chain" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u32, 1), bc.getBlockCount());
}

test "Blockchain.init — difficulty = 4" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u32, 4), bc.difficulty);
}

test "Blockchain.getBlock — bloc genesis la index 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0);
    try testing.expect(genesis != null);
    try testing.expectEqual(@as(u32, 0), genesis.?.index);
}

test "Blockchain.getBlock — index inexistent returneaza null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(bc.getBlock(999) == null);
}

test "Blockchain.getLatestBlock — initial = genesis" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const latest = bc.getLatestBlock();
    try testing.expectEqual(@as(u32, 0), latest.index);
}

test "Blockchain.creditBalance — adauga sold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob_omni_alice", 1_000_000_000);
    try testing.expectEqual(@as(u64, 1_000_000_000), bc.getAddressBalance("ob_omni_alice"));
}

test "Blockchain.creditBalance — acumuleaza multiple credite" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob_omni_alice", 500_000_000);
    try bc.creditBalance("ob_omni_alice", 500_000_000);
    try testing.expectEqual(@as(u64, 1_000_000_000), bc.getAddressBalance("ob_omni_alice"));
}

test "Blockchain.debitBalance — scade sold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob_omni_bob", 2_000_000_000);
    try bc.debitBalance("ob_omni_bob", 500_000_000);
    try testing.expectEqual(@as(u64, 1_500_000_000), bc.getAddressBalance("ob_omni_bob"));
}

test "Blockchain.debitBalance — sold insuficient => error" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob_omni_carol", 100);
    try testing.expectError(error.InsufficientBalance, bc.debitBalance("ob_omni_carol", 200));
}

test "Blockchain.getAddressBalance — adresa necunoscuta returneaza 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u64, 0), bc.getAddressBalance("ob_omni_necunoscut"));
}

test "Blockchain.validateTransaction — amount 0 invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "ob_omni_a", .to_address = "ob_omni_b",
        .amount = 0, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — adresa goala invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "", .to_address = "ob_omni_b",
        .amount = 100, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — prefix invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "invalid_prefix_addr", .to_address = "ob_omni_b",
        .amount = 100, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — nonce replay attack blocked" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Give sender some balance
    try bc.creditBalance("ob_omni_alice", 10_000);

    // First TX with nonce 0 should be valid
    const tx1 = Transaction{
        .id = 1, .from_address = "ob_omni_alice", .to_address = "ob_omni_bob",
        .amount = 100, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx1));

    // Simulate nonce increment after processing
    try bc.nonces.put("ob_omni_alice", 1);

    // Replay same TX with nonce 0 should be rejected (nonce too low)
    try testing.expect(!try bc.validateTransaction(&tx1));

    // TX with nonce 1 should be valid
    const tx2 = Transaction{
        .id = 2, .from_address = "ob_omni_alice", .to_address = "ob_omni_bob",
        .amount = 100, .timestamp = 1700000001, .nonce = 1, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx2));
}

test "Blockchain.validateTransaction — insufficient balance rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Sender has 0 balance
    const tx = Transaction{
        .id = 1, .from_address = "ob_omni_broke", .to_address = "ob_omni_bob",
        .amount = 1_000_000, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.getNextNonce — unknown address returns 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u64, 0), bc.getNextNonce("ob_omni_new_user"));
}

test "Blockchain.isValidHash — 4 zerouri leading = valid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(try bc.isValidHash("0000abcdef123456789012345678901234567890123456789012345678901234"));
}

test "Blockchain.isValidHash — 3 zerouri leading = invalid (difficulty=4)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(!try bc.isValidHash("000abcdef1234567890123456789012345678901234567890123456789012345"));
}

test "Blockchain.calculateBlockHash — produce 64 chars hex" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0).?;
    const hash = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(hash);
    try testing.expectEqual(@as(usize, 64), hash.len);
}

test "retargetDifficulty — prea rapid → creste dificultatea" {
    // actual_time = 504s = target/4 → clamp → new = old * 2016 / 504 = old*4
    const new_d = retargetDifficulty(4, 504);
    try testing.expectEqual(@as(u32, 16), new_d);
}

test "retargetDifficulty — prea lent → scade dificultatea" {
    // actual_time = 8064s = target*4 → clamp → new = old * 2016 / 8064 = old/4
    const new_d = retargetDifficulty(8, 8064);
    try testing.expectEqual(@as(u32, 2), new_d);
}

test "retargetDifficulty — exact target → dificultate neschimbata" {
    const new_d = retargetDifficulty(6, TARGET_INTERVAL_S);
    try testing.expectEqual(@as(u32, 6), new_d);
}

test "retargetDifficulty — clamp la MAX_DIFFICULTY" {
    // actual_time extrem de mic → ar da overflow → limitat la MAX
    const new_d = retargetDifficulty(MAX_DIFFICULTY, 1);
    try testing.expectEqual(MAX_DIFFICULTY, new_d);
}

test "retargetDifficulty — clamp la MIN_DIFFICULTY" {
    // actual_time maxim posibil, dificultate mica → nu scade sub 1
    const new_d = retargetDifficulty(1, TARGET_INTERVAL_S * 100);
    try testing.expectEqual(MIN_DIFFICULTY, new_d);
}

test "retargetDifficulty — actual_time zero → returneaza old" {
    const new_d = retargetDifficulty(5, 0);
    try testing.expectEqual(@as(u32, 5), new_d);
}

test "Blockchain.calculateBlockHash — determinist" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0).?;
    const h1 = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(h1);
    const h2 = try bc.calculateBlockHash(&genesis);
    defer bc.allocator.free(h2);
    try testing.expectEqualSlices(u8, h1, h2);
}
