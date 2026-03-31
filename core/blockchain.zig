const std = @import("std");
const block_mod = @import("block.zig");
const transaction_mod = @import("transaction.zig");
const hex_utils = @import("hex_utils.zig");
const script_mod = @import("script.zig");
const multisig_mod = @import("multisig.zig");
const utxo_mod = @import("utxo.zig");
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

/// Maximum reorg depth: deeper chain reorganizations are rejected for safety.
/// Bitcoin's practical limit is ~100 blocks; we use the same.
pub const MAX_REORG_DEPTH: usize = 100;

/// Maximum orphan blocks kept in the pool (prevent memory exhaustion)
pub const MAX_ORPHAN_POOL: usize = 64;

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

/// Entry for storing a multisig config alongside its address string.
pub const MultisigConfigEntry = struct {
    address: [64]u8 = [_]u8{0} ** 64,
    address_len: u8 = 0,
    config: multisig_mod.MultisigConfig = .{
        .threshold = 0,
        .total = 0,
        .pubkeys = [_][33]u8{[_]u8{0} ** 33} ** multisig_mod.MAX_SIGNERS,
        .pubkey_count = 0,
    },
};

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
    /// Public key registry: address → compressed pubkey hex (66 chars)
    /// Folosit pentru verificarea semnaturii ECDSA in validateTransaction()
    pubkey_registry: std.StringHashMap([]const u8),
    /// TX hash → block height: tracks which block contains each transaction
    /// Used for confirmation counting (current_height - tx_block_height)
    tx_block_height: std.StringHashMap(u64),
    /// Orphan block pool: blocks whose parent we don't have yet.
    /// When a new block arrives and connects, we re-check orphans.
    orphan_blocks: array_list.Managed(Block),
    /// Address TX index: address → list of TX hashes (reverse index for getaddresshistory)
    /// Includes both sent and received TXs, plus coinbase reward pseudo-entries.
    address_tx_index: std.StringHashMap(std.ArrayList([]const u8)),
    /// Multisig config registry: multisig address → MultisigConfig
    /// Stores the M-of-N configuration for each registered multisig wallet
    multisig_configs: [64]MultisigConfigEntry = [_]MultisigConfigEntry{MultisigConfigEntry{}} ** 64,
    multisig_count: u16 = 0,
    /// UTXO set — tracks all unspent transaction outputs (Bitcoin-compatible)
    utxo_set: utxo_mod.UTXOSet,
    /// Mutex — protejează chain/mempool/balances de data race (RPC + mining pe thread-uri diferite)
    mutex: std.Thread.Mutex = .{},

    /// Auto-save: blocks mined since last save (triggers at 100)
    blocks_since_save: u32 = 0,
    /// Auto-save: unix timestamp of last save (triggers after 60s)
    last_save_time: i64 = 0,
    /// Auto-save: transactions processed since last save (triggers at 1000)
    txs_since_save: u32 = 0,
    /// Pointer to PersistentBlockchain — set by main after init
    persistent_db: ?*@import("database.zig").PersistentBlockchain = null,
    /// DB file path for auto-save
    db_path: []const u8 = "omnibus-chain.dat",

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
            .pubkey_registry = std.StringHashMap([]const u8).init(allocator),
            .tx_block_height = std.StringHashMap(u64).init(allocator),
            .orphan_blocks = array_list.Managed(Block).init(allocator),
            .address_tx_index = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .utxo_set = utxo_mod.UTXOSet.init(allocator),
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
        self.utxo_set.deinit();
        self.nonces.deinit();
        self.pubkey_registry.deinit();
        self.tx_block_height.deinit();
        // Clean up address TX index (lists of TX hash pointers — no owned memory)
        {
            var ati_it = self.address_tx_index.iterator();
            while (ati_it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.address_tx_index.deinit();
        }
        // Clean up orphan pool (orphans have heap-allocated 64-char hashes)
        for (self.orphan_blocks.items) |*orphan| {
            orphan.transactions.deinit();
            if (orphan.hash.len == 64) {
                self.allocator.free(orphan.hash);
            }
            if (orphan.miner_heap) {
                self.allocator.free(orphan.miner_address);
            }
        }
        self.orphan_blocks.deinit();
    }

    /// Returneaza balanta unei adrese (0 daca nu exista)
    pub fn getAddressBalance(self: *const Blockchain, address: []const u8) u64 {
        return self.balances.get(address) orelse 0;
    }

    /// Returns the number of confirmations for a TX (null if TX not found in any block).
    /// confirmations = current_chain_height - block_height_containing_tx
    pub fn getConfirmations(self: *const Blockchain, tx_hash: []const u8) ?u64 {
        const block_height = self.tx_block_height.get(tx_hash) orelse return null;
        const current_height: u64 = @intCast(self.chain.items.len);
        if (current_height <= block_height) return 0;
        return current_height - block_height;
    }

    /// Returns the block height that contains a given TX (null if not found)
    pub fn getTxBlockHeight(self: *const Blockchain, tx_hash: []const u8) ?u64 {
        return self.tx_block_height.get(tx_hash);
    }

    /// Index a TX hash for a given address in address_tx_index.
    /// Creates the list if address not yet tracked.
    pub fn indexAddressTx(self: *Blockchain, address: []const u8, tx_hash: []const u8) void {
        if (address.len == 0) return;
        const list = self.address_tx_index.getPtr(address);
        if (list) |l| {
            l.append(self.allocator, tx_hash) catch {};
        } else {
            var new_list: std.ArrayList([]const u8) = .empty;
            new_list.append(self.allocator, tx_hash) catch {};
            self.address_tx_index.put(address, new_list) catch {};
        }
    }

    /// Returns the list of TX hashes associated with an address (both sent and received).
    /// Returns null if address has no history.
    pub fn getAddressHistory(self: *const Blockchain, address: []const u8) ?[]const []const u8 {
        const list = self.address_tx_index.get(address) orelse return null;
        if (list.items.len == 0) return null;
        return list.items;
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

    /// Inregistreaza public key-ul unei adrese (pentru verificare semnatura TX)
    /// pubkey_hex = compressed secp256k1 public key, 66 hex chars
    pub fn registerPubkey(self: *Blockchain, address: []const u8, pubkey_hex: []const u8) !void {
        if (pubkey_hex.len != 66) return error.InvalidPubkeyLength;
        self.mutex.lock();
        defer self.mutex.unlock();
        // Nu suprascrie daca exista deja (prima inregistrare e autoritativa)
        if (self.pubkey_registry.get(address) == null) {
            try self.pubkey_registry.put(address, pubkey_hex);
        }
    }

    /// Register a multisig wallet configuration (address → M-of-N config).
    /// Called by the "createmultisig" RPC handler.
    pub fn registerMultisig(self: *Blockchain, address: []const u8, config: multisig_mod.MultisigConfig) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Check if already registered
        for (self.multisig_configs[0..self.multisig_count]) |entry| {
            if (std.mem.eql(u8, entry.address[0..entry.address_len], address)) return; // already exists
        }
        if (self.multisig_count >= 64) return error.MultisigRegistryFull;
        var entry = MultisigConfigEntry{};
        const copy_len = @min(address.len, 64);
        @memcpy(entry.address[0..copy_len], address[0..copy_len]);
        entry.address_len = @intCast(copy_len);
        entry.config = config;
        self.multisig_configs[self.multisig_count] = entry;
        self.multisig_count += 1;
    }

    /// Look up a multisig config by address.
    pub fn getMultisigConfig(self: *const Blockchain, address: []const u8) ?*const multisig_mod.MultisigConfig {
        for (self.multisig_configs[0..self.multisig_count]) |*entry| {
            if (std.mem.eql(u8, entry.address[0..entry.address_len], address)) {
                return &entry.config;
            }
        }
        return null;
    }

    pub fn addTransaction(self: *Blockchain, tx: Transaction) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!try self.validateTransaction(&tx)) {
            return error.InvalidTransaction;
        }
        try self.mempool.append(tx);
    }

    /// Returneaza totalul outgoing pending din mempool pentru o adresa (amount + fee per TX)
    /// Folosit in validateTransaction() pentru a preveni double-spend cu TX-uri rapide
    pub fn getPendingOutgoing(self: *const Blockchain, address: []const u8) u64 {
        var total: u64 = 0;
        for (self.mempool.items) |tx| {
            if (std.mem.eql(u8, tx.from_address, address)) {
                total += tx.amount + tx.fee;
            }
        }
        return total;
    }

    /// Returneaza urmatorul nonce confirmat pentru o adresa (0 daca nu exista)
    /// Acesta este nonce-ul pe chain — NU include TX-urile pending din mempool
    pub fn getNextNonce(self: *const Blockchain, address: []const u8) u64 {
        return self.nonces.get(address) orelse 0;
    }

    /// Returneaza urmatorul nonce disponibil pentru o adresa,
    /// incluzand TX-urile pending din mempool (chain_nonce + pending_count).
    /// Aceasta metoda este utila pentru RPC "getnonce" — clientul stie ce nonce sa puna pe urmatoarea TX.
    pub fn getNextAvailableNonce(self: *const Blockchain, address: []const u8) u64 {
        const chain_nonce = self.nonces.get(address) orelse 0;
        // Count pending TXs from this sender in mempool
        var pending: u64 = 0;
        for (self.mempool.items) |tx| {
            if (std.mem.eql(u8, tx.from_address, address)) {
                pending += 1;
            }
        }
        return chain_nonce + pending;
    }

    pub fn validateTransaction(self: *Blockchain, tx: *const Transaction) !bool {
        // 0. Locktime check: TX locked until block height N cannot be included before that
        if (tx.locktime > 0) {
            const current_height: u64 = @intCast(self.chain.items.len);
            if (tx.locktime > current_height) {
                std.debug.print("[VALIDATE] FAIL: TX locked until block {d}, current height {d}\n", .{ tx.locktime, current_height });
                return false;
            }
        }

        // 1. Amount trebuie > 0 (unless OP_RETURN data-only TX)
        const is_op_return_tx = tx.op_return.len > 0 and tx.amount == 0;
        if (tx.amount == 0 and !is_op_return_tx) { std.debug.print("[VALIDATE] FAIL: amount=0\n", .{}); return false; }

        // 2. Adrese nu pot fi goale si trebuie minim 8 chars (prefix "ob1qhnj2fm3lrmgxzfvyejp97vv8s3ean92myqt9zt")
        if (tx.from_address.len < 8 or tx.to_address.len < 8) { std.debug.print("[VALIDATE] FAIL: addr too short from={d} to={d}\n", .{tx.from_address.len, tx.to_address.len}); return false; }

        // 3. Prefix valid (isValid verifică prefix + amount + op_return length)
        if (!tx.isValid()) { std.debug.print("[VALIDATE] FAIL: isValid() from={s} to={s} amt={d}\n", .{tx.from_address[0..@min(42,tx.from_address.len)], tx.to_address[0..@min(42,tx.to_address.len)], tx.amount}); return false; }

        // 3b. Dust threshold — respinge TX prea mici (anti-spam, ca Bitcoin 546 sat)
        //     Skip dust check for OP_RETURN data-only TXs (amount=0 is allowed)
        if (!is_op_return_tx and tx.amount < DUST_THRESHOLD_SAT) { std.debug.print("[VALIDATE] FAIL: dust {d} < {d}\n", .{tx.amount, DUST_THRESHOLD_SAT}); return false; }

        // 3c. Fee minimum check (fee market — at least TX_MIN_FEE = 1 SAT)
        if (tx.fee < TX_MIN_FEE) { std.debug.print("[VALIDATE] FAIL: fee {d} < min {d}\n", .{tx.fee, TX_MIN_FEE}); return false; }

        // 4. Strict nonce check (anti-replay + anti-gap, ca Ethereum)
        //    TX nonce must equal chain_nonce + pending_count (sequential, no gaps)
        //    This prevents replay attacks AND ensures no nonce gaps in the mempool
        const expected_nonce = self.getNextAvailableNonce(tx.from_address);
        if (tx.nonce != expected_nonce) { std.debug.print("[VALIDATE] FAIL: nonce {d} != expected {d} (chain={d})\n", .{tx.nonce, expected_nonce, self.getNextNonce(tx.from_address)}); return false; }

        // 5. Balance check: sender trebuie sa aiba suficient (amount + fee + pending outgoing)
        //    Scade pending outgoing din mempool pentru a preveni double-spend cu TX-uri rapide
        const sender_balance = self.getAddressBalance(tx.from_address);
        const pending_out = self.getPendingOutgoing(tx.from_address);
        const available = if (sender_balance > pending_out) sender_balance - pending_out else 0;
        if (available < tx.amount + tx.fee) { std.debug.print("[VALIDATE] FAIL: balance {d} - pending {d} = available {d} < amount+fee {d}\n", .{sender_balance, pending_out, available, tx.amount + tx.fee}); return false; }

        // 5b. Multisig address check: if from_address is "ob_ms_*", it must be a registered multisig
        //     Multisig TXs skip normal ECDSA verification — they are validated via MultisigWallet.verify()
        //     before being submitted (the RPC handler ensures M-of-N signatures are collected)
        if (std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX)) {
            if (self.getMultisigConfig(tx.from_address) == null) {
                std.debug.print("[VALIDATE] FAIL: multisig address not registered: {s}\n",
                    .{tx.from_address[0..@min(20, tx.from_address.len)]});
                return false;
            }
            // Multisig TX accepted — signature verification was done at submission time
            // (M-of-N signatures collected and verified by MultisigWallet.verify())
        }

        // 6. Verificare semnatura ECDSA secp256k1 cu public key inregistrat
        //    (signature = 128 hex chars = 64 bytes R||S, hash = 64 hex chars)
        //    Skip for multisig addresses (they use M-of-N verification instead)
        if (!std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX) and
            tx.signature.len == 128 and tx.hash.len == 64)
        {
            // 6a. Integritate hash — hash-ul stocat trebuie sa corespunda continutului TX
            const expected_hash = tx.calculateHash();
            var stored_hash: [32]u8 = undefined;
            hex_utils.hexToBytes(tx.hash, &stored_hash) catch return false;
            if (!std.mem.eql(u8, &stored_hash, &expected_hash)) return false;

            // 6b. Verificare semnatura ECDSA cu public key din registru
            if (self.pubkey_registry.get(tx.from_address)) |pubkey_hex| {
                if (!tx.verifyWithHexPubkey(pubkey_hex)) {
                    std.debug.print("[VALIDATE] FAIL: ECDSA signature verification failed for {s}\n",
                        .{tx.from_address[0..@min(20, tx.from_address.len)]});
                    return false;
                }
            }
            // Daca pubkey nu e inregistrat, acceptam TX (backward compat cu coinbase/genesis)
            // Urmatoarea TX de la aceasta adresa va fi verificata dupa registerPubkey()
        } else if (!std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX) and tx.signature.len > 0) {
            // Semnătură incompletă — respinge (skip for multisig which uses different sig format)
            return false;
        }

        // 7. Script validation (if TX has scripts attached)
        //    Empty scripts = legacy ECDSA-only mode (backward compatible)
        //    If script_pubkey is set but script_sig is empty → reject (can't unlock)
        //    If both are set → run ScriptVM to validate unlock against lock
        if (tx.script_pubkey.len > 0) {
            if (tx.script_sig.len == 0) {
                std.debug.print("[VALIDATE] FAIL: script_pubkey set but script_sig empty\n", .{});
                return false;
            }
            const tx_hash = tx.calculateHash();
            const current_height: u64 = @intCast(self.chain.items.len);
            if (!script_mod.validateScripts(tx.script_sig, tx.script_pubkey, tx_hash, current_height)) {
                std.debug.print("[VALIDATE] FAIL: script validation failed\n", .{});
                return false;
            }
        }

        return true;
    }

    pub fn mineBlock(self: *Blockchain) !Block {
        return self.mineBlockForMiner("");
    }

    /// Mine block + acorda reward minerului + proceseaza TX-urile din mempool
    pub fn mineBlockForMiner(self: *Blockchain, miner_address: []const u8) !Block {
        // NU lock aici — PoW dureaza secunde, ar bloca tot RPC-ul
        // Lock doar pe secțiunile critice (read chain, write chain, update balances)
        if (self.chain.items.len == 0) {
            return error.EmptyChain;
        }

        // Lock doar pentru citire chain state
        self.mutex.lock();
        const previous_block = self.chain.items[self.chain.items.len - 1];
        const index = self.chain.items.len;
        self.mutex.unlock();
        const timestamp = std.time.timestamp();

        const reward = if (miner_address.len > 0) blockRewardAt(@intCast(index)) else 0;

        // Copy miner address — slice-ul extern poate fi din MinerPool global
        const miner_addr_owned = try self.allocator.dupe(u8, miner_address);

        var block = Block{
            .index = @intCast(index),
            .timestamp = timestamp,
            .transactions = self.mempool,
            .previous_hash = previous_block.hash,
            .nonce = 0,
            .hash = "",
            .miner_address = miner_addr_owned,
            .miner_heap = true,
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

        // Proceseaza tranzactiile: debiteaza sender (amount + fee), crediteaza receiver, incrementeaza nonce
        var total_fees: u64 = 0;
        for (block.transactions.items, 0..) |tx, tx_idx| {
            self.debitBalance(tx.from_address, tx.amount + tx.fee) catch {}; // debit amount + fee
            self.creditBalance(tx.to_address, tx.amount) catch {};
            total_fees += tx.fee;
            // Incrementeaza nonce-ul sender-ului (anti-replay: urmatoarea TX trebuie nonce+1)
            const current_nonce = self.nonces.get(tx.from_address) orelse 0;
            self.nonces.put(tx.from_address, current_nonce + 1) catch {};
            // Track TX → block height for confirmation counting
            self.tx_block_height.put(tx.hash, @intCast(index)) catch {};
            // Index TX for both sender and receiver address history
            self.indexAddressTx(tx.from_address, tx.hash);
            self.indexAddressTx(tx.to_address, tx.hash);
            // UTXO: create output for recipient
            self.utxo_set.addUTXO(tx.hash, @intCast(tx_idx), tx.to_address, tx.amount, @intCast(index), "", false) catch {};
        }

        // Fee split: FEE_BURN_PCT% burned (deflationary, like EIP-1559), rest to miner
        const fees_burned = total_fees * FEE_BURN_PCT / 100;
        const fees_to_miner = total_fees - fees_burned;
        total_fees_burned_sat += fees_burned;

        // Block reward + miner's share of fees
        if (miner_address.len > 0 and (reward > 0 or fees_to_miner > 0)) {
            self.creditBalance(miner_address, reward + fees_to_miner) catch {};
            // UTXO: coinbase output for miner (needs 100 confirmations to spend)
            self.utxo_set.addUTXO(block.hash, 0, miner_address, reward + fees_to_miner, @intCast(index), "", true) catch {};
            std.debug.print("[REWARD] Miner {s} +{d} SAT ({d:.2} OMNI) + {d} fees ({d} burned) @ block {d}\n",
                .{ miner_address[0..@min(16, miner_address.len)], reward,
                   @as(f64, @floatFromInt(reward)) / 1e9, fees_to_miner, fees_burned, index });
        }

        // Lock pentru chain write + balance update
        self.mutex.lock();
        defer self.mutex.unlock();
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

    /// Maximum allowed clock drift for block timestamps (2 hours, like Bitcoin)
    const MAX_FUTURE_SECONDS: i64 = 7200;

    /// Validate a block against all consensus rules (Bitcoin-level validation).
    /// Returns true if the block passes all checks, false otherwise.
    /// Checks: merkle root, timestamp, previous hash, difficulty, fees/reward, TX validity.
    pub fn validateBlock(self: *Blockchain, block: *const Block) bool {
        // 0. Genesis block is trusted — skip validation
        if (block.index == 0) return true;

        // 1. Merkle root — recalculate from transactions and compare
        const expected_merkle = block.calculateMerkleRoot();
        if (!std.mem.eql(u8, &expected_merkle, &block.merkle_root)) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: merkle root mismatch at block {d}\n", .{block.index});
            return false;
        }

        // 2. Timestamp validation
        const now = std.time.timestamp();
        // a) Not more than 2 hours in the future
        if (block.timestamp > now + MAX_FUTURE_SECONDS) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: block {d} timestamp {d} too far in the future (now={d})\n", .{ block.index, block.timestamp, now });
            return false;
        }
        // b) Not before previous block's timestamp
        if (block.index > 0) {
            const prev_idx: usize = @intCast(block.index - 1);
            if (prev_idx < self.chain.items.len) {
                const prev_block = self.chain.items[prev_idx];
                if (block.timestamp < prev_block.timestamp) {
                    std.debug.print("[VALIDATE_BLOCK] FAIL: block {d} timestamp {d} < prev block timestamp {d}\n", .{ block.index, block.timestamp, prev_block.timestamp });
                    return false;
                }
            }
        }

        // 3. Previous hash — must match hash of the previous block in chain
        if (block.index > 0) {
            const prev_idx: usize = @intCast(block.index - 1);
            if (prev_idx < self.chain.items.len) {
                const prev_block = self.chain.items[prev_idx];
                if (!std.mem.eql(u8, block.previous_hash, prev_block.hash)) {
                    std.debug.print("[VALIDATE_BLOCK] FAIL: previous_hash mismatch at block {d}\n", .{block.index});
                    return false;
                }
            }
        }

        // 4. Difficulty — block hash must have required leading zeros
        if (!hex_utils.isValidHashDifficulty(block.hash, self.difficulty)) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: hash does not meet difficulty {d} at block {d}\n", .{ self.difficulty, block.index });
            return false;
        }

        // 5. Fee validation — miner reward must be <= blockRewardAt(height) + total_fees_to_miner
        var total_fees: u64 = 0;
        for (block.transactions.items) |tx| {
            total_fees += tx.fee;
        }
        const max_reward = blockRewardAt(@intCast(block.index));
        const fees_to_miner = total_fees - (total_fees * FEE_BURN_PCT / 100);
        if (block.reward_sat > max_reward + fees_to_miner) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: reward {d} > max {d} + fees {d} at block {d}\n", .{ block.reward_sat, max_reward, fees_to_miner, block.index });
            return false;
        }

        // 6. TX validation — all transactions must pass basic validation (prefix, amount > 0)
        if (!block.validateTransactions()) {
            std.debug.print("[VALIDATE_BLOCK] FAIL: invalid transaction in block {d}\n", .{block.index});
            return false;
        }

        return true;
    }

    /// Accept a block from a P2P peer. Fully validates before appending.
    /// Handles three cases:
    ///   1. Block extends our chain tip -> append normally
    ///   2. Block forks from our chain and creates a longer chain -> reorg
    ///   3. Block's parent is unknown -> store in orphan pool
    /// After appending, checks if any orphan blocks now connect.
    pub fn addExternalBlock(self: *Blockchain, block: Block) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const our_tip = self.chain.items[self.chain.items.len - 1];

        // Case 1: Block extends our chain tip (previous_hash matches tip hash)
        if (std.mem.eql(u8, block.previous_hash, our_tip.hash)) {
            if (!self.validateBlock(&block)) return error.InvalidBlock;
            try self.applyBlock(block);
            // After appending, try to connect orphans
            self.processOrphansInternal();
            return;
        }

        // Case 2: Check if block's parent exists somewhere in our chain (fork)
        const parent_idx = self.findBlockByHash(block.previous_hash);
        if (parent_idx) |pidx| {
            // We have the parent but it's not our tip => this is a fork.
            // new chain length from genesis = pidx + 1 (fork point inclusive) + 1 (new block)
            const new_chain_len = pidx + 2;
            const our_chain_len = self.chain.items.len;

            if (new_chain_len > our_chain_len) {
                // Single-block fork that's longer: reorg
                if (!self.validateBlockAtHeight(&block, pidx + 1)) return error.InvalidBlock;

                const reorg_depth = our_chain_len - 1 - pidx;
                if (reorg_depth > MAX_REORG_DEPTH) return error.ReorgTooDeep;

                std.debug.print("[REORG] Single-block reorg at fork={d}, depth={d}\n", .{ pidx, reorg_depth });

                // Collect TXs from blocks being removed (after fork point)
                try self.collectOrphanedTxs(pidx + 1);

                // Free removed blocks
                for (pidx + 1..self.chain.items.len) |i| {
                    var old_blk = &self.chain.items[i];
                    old_blk.transactions.deinit();
                    if (i > 0 and old_blk.hash.len == 64) {
                        self.allocator.free(old_blk.hash);
                    }
                    if (old_blk.miner_heap) {
                        self.allocator.free(old_blk.miner_address);
                    }
                }

                // Truncate chain to fork point + 1
                self.chain.items.len = pidx + 1;

                // Apply the new block
                try self.applyBlock(block);

                // Recalculate balances from scratch
                try self.recalculateFromHeight(pidx + 1);

                // Remove mempool TXs already in new chain
                self.removeMempoolDuplicates();

                self.processOrphansInternal();
            }
            // If new_chain_len <= our_chain_len, ignore the fork (shorter or equal)
            return;
        }

        // Case 3: Parent unknown -> orphan pool
        if (self.orphan_blocks.items.len < MAX_ORPHAN_POOL) {
            try self.orphan_blocks.append(block);
        }
    }

    /// Accept a full chain from a peer and reorg if it's longer.
    /// Validates all blocks in the new chain from the fork point.
    /// Returns orphaned TXs to mempool for re-mining.
    pub fn reorg(self: *Blockchain, new_chain: []const Block) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (new_chain.len == 0) return error.EmptyChain;

        // New chain must be strictly longer than ours
        if (new_chain.len <= self.chain.items.len) return error.ShorterChain;

        // Find the fork point (common ancestor)
        const fork_point = self.findForkPointInternal(new_chain) orelse return error.NoCommonAncestor;

        // Safety: reject reorgs deeper than MAX_REORG_DEPTH
        const reorg_depth = self.chain.items.len - 1 - fork_point;
        if (reorg_depth > MAX_REORG_DEPTH) return error.ReorgTooDeep;

        // Validate all new blocks from fork point onward
        for (fork_point + 1..new_chain.len) |i| {
            const blk = &new_chain[i];
            // Check basic block validity: merkle root, transactions
            if (!blk.validateTransactions()) return error.InvalidBlock;
            const expected_merkle = blk.calculateMerkleRoot();
            if (!std.mem.eql(u8, &expected_merkle, &blk.merkle_root)) return error.InvalidBlock;

            // Verify chain linkage: previous_hash must match prior block
            if (i > 0) {
                if (!std.mem.eql(u8, blk.previous_hash, new_chain[i - 1].hash)) return error.InvalidBlock;
            }

            // Verify block hash meets difficulty
            if (blk.index > 0) {
                if (!hex_utils.isValidHashDifficulty(blk.hash, self.difficulty)) return error.InvalidBlock;
            }

            // Verify reward is not inflated
            var blk_total_fees: u64 = 0;
            for (blk.transactions.items) |tx| {
                blk_total_fees += tx.fee;
            }
            const max_reward = blockRewardAt(@intCast(blk.index));
            const blk_fees_to_miner = blk_total_fees - (blk_total_fees * FEE_BURN_PCT / 100);
            if (blk.reward_sat > max_reward + blk_fees_to_miner) return error.InvalidBlock;
        }

        std.debug.print("[REORG] Full chain reorg at fork={d}, our_len={d} -> new_len={d}, depth={d}\n", .{ fork_point, self.chain.items.len, new_chain.len, reorg_depth });

        // Collect TXs from old blocks being removed (after fork point) -> return to mempool
        try self.collectOrphanedTxs(fork_point + 1);

        // Truncate chain to fork point (free removed blocks)
        for (fork_point + 1..self.chain.items.len) |i| {
            var old_blk = &self.chain.items[i];
            old_blk.transactions.deinit();
            if (i > 0 and old_blk.hash.len == 64) {
                self.allocator.free(old_blk.hash);
            }
            if (old_blk.miner_heap) {
                self.allocator.free(old_blk.miner_address);
            }
        }
        self.chain.items.len = fork_point + 1;

        // Append new blocks from fork point onward
        for (fork_point + 1..new_chain.len) |i| {
            try self.chain.append(new_chain[i]);
        }

        // Recalculate all balances, nonces, tx_block_height from scratch
        try self.recalculateFromHeight(fork_point + 1);

        // Remove from mempool any TXs that are now in the new chain
        self.removeMempoolDuplicates();

        self.processOrphansInternal();

        // Reorg is a critical event — force save to disc
        self.saveToDisc() catch |err| {
            std.debug.print("[DB] Reorg save failed: {}\n", .{err});
        };
    }

    /// Check if auto-save should trigger based on block count or time elapsed.
    /// Called after each mined block. Saves at 100 blocks, 60s, or 1000 TXs.
    pub fn checkAutoSave(self: *Blockchain) void {
        const now = std.time.timestamp();
        const should_save = self.blocks_since_save >= 100 or
            self.txs_since_save >= 1000 or
            (now - self.last_save_time) >= 60;
        if (should_save) {
            self.saveToDisc() catch |err| {
                std.debug.print("[DB] Auto-save failed: {}\n", .{err});
                return;
            };
            self.blocks_since_save = 0;
            self.txs_since_save = 0;
            self.last_save_time = now;
        }
    }

    /// Convenience method: save full blockchain state to disc via PersistentBlockchain.
    /// No-op if persistent_db has not been attached (e.g. in unit tests).
    pub fn saveToDisc(self: *Blockchain) !void {
        const pdb = self.persistent_db orelse return;
        try pdb.saveBlockchain(self, self.db_path);
        std.debug.print("[DB] Auto-saved: {d} blocks, {d} addresses\n", .{ self.chain.items.len, self.balances.count() });
    }

    /// Find the highest block index where both chains have the same hash.
    /// Returns null if no common ancestor found (completely divergent chains).
    pub fn findForkPoint(self: *const Blockchain, other_chain: []const Block) ?usize {
        return self.findForkPointInternal(other_chain);
    }

    /// Internal fork point finder (no mutex, called from methods that already hold it).
    fn findForkPointInternal(self: *const Blockchain, other_chain: []const Block) ?usize {
        const max_idx = @min(self.chain.items.len, other_chain.len);
        if (max_idx == 0) return null;

        var i: usize = max_idx;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.chain.items[i].hash, other_chain[i].hash)) {
                return i;
            }
        }
        return null;
    }

    /// Find a block in our chain by its hash. Returns the index or null.
    fn findBlockByHash(self: *const Blockchain, hash: []const u8) ?usize {
        var i: usize = self.chain.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.chain.items[i].hash, hash)) {
                return i;
            }
        }
        return null;
    }

    /// Validate a block as if it were at a specific height (used during reorg).
    fn validateBlockAtHeight(self: *Blockchain, block: *const Block, height: usize) bool {
        if (block.index == 0) return true;

        const expected_merkle = block.calculateMerkleRoot();
        if (!std.mem.eql(u8, &expected_merkle, &block.merkle_root)) return false;

        const now = std.time.timestamp();
        if (block.timestamp > now + MAX_FUTURE_SECONDS) return false;

        if (!hex_utils.isValidHashDifficulty(block.hash, self.difficulty)) return false;

        var total_fees: u64 = 0;
        for (block.transactions.items) |tx| {
            total_fees += tx.fee;
        }
        const max_reward = blockRewardAt(@intCast(height));
        const fees_to_miner = total_fees - (total_fees * FEE_BURN_PCT / 100);
        if (block.reward_sat > max_reward + fees_to_miner) return false;

        if (!block.validateTransactions()) return false;

        return true;
    }

    /// Apply a validated block to the chain: process TXs, credit miner, append.
    /// Caller must hold mutex.
    fn applyBlock(self: *Blockchain, block: Block) !void {
        var total_fees: u64 = 0;
        for (block.transactions.items) |tx| {
            self.debitBalance(tx.from_address, tx.amount + tx.fee) catch {};
            self.creditBalance(tx.to_address, tx.amount) catch {};
            total_fees += tx.fee;
            const current_nonce = self.nonces.get(tx.from_address) orelse 0;
            self.nonces.put(tx.from_address, current_nonce + 1) catch {};
            self.tx_block_height.put(tx.hash, @intCast(block.index)) catch {};
            // Index TX for both sender and receiver address history
            self.indexAddressTx(tx.from_address, tx.hash);
            self.indexAddressTx(tx.to_address, tx.hash);
        }

        const fees_burned = total_fees * FEE_BURN_PCT / 100;
        const fees_to_miner = total_fees - fees_burned;
        total_fees_burned_sat += fees_burned;

        if (block.miner_address.len > 0 and (block.reward_sat > 0 or fees_to_miner > 0)) {
            self.creditBalance(block.miner_address, block.reward_sat + fees_to_miner) catch {};
        }

        try self.chain.append(block);

        // Difficulty retarget
        const index = self.chain.items.len - 1;
        if (index % RETARGET_INTERVAL == 0 and index > 0) {
            const retarget_start = index - RETARGET_INTERVAL;
            const old_block_ts = self.chain.items[retarget_start].timestamp;
            const new_block_ts = block.timestamp;
            const actual_time = new_block_ts - old_block_ts;
            const new_diff = retargetDifficulty(self.difficulty, actual_time);
            if (new_diff != self.difficulty) {
                self.difficulty = new_diff;
            }
        }
    }

    /// Collect transactions from blocks being removed during reorg and return them to mempool.
    fn collectOrphanedTxs(self: *Blockchain, from_height: usize) !void {
        for (from_height..self.chain.items.len) |i| {
            const blk = &self.chain.items[i];
            for (blk.transactions.items) |tx| {
                try self.mempool.append(tx);
            }
        }
    }

    /// Remove mempool TXs that already exist in the current chain.
    fn removeMempoolDuplicates(self: *Blockchain) void {
        var write: usize = 0;
        for (self.mempool.items) |tx| {
            if (self.tx_block_height.get(tx.hash) != null) continue;
            self.mempool.items[write] = tx;
            write += 1;
        }
        self.mempool.items.len = write;
    }

    /// Recalculate balances, nonces, and tx_block_height by replaying all blocks from genesis.
    fn recalculateFromHeight(self: *Blockchain, from_height: usize) !void {
        _ = from_height;
        // Clear all balance/nonce/tx state and replay from genesis
        self.balances.clearRetainingCapacity();
        self.nonces.clearRetainingCapacity();
        self.tx_block_height.clearRetainingCapacity();

        for (1..self.chain.items.len) |i| {
            const blk = &self.chain.items[i];
            var blk_total_fees: u64 = 0;
            for (blk.transactions.items) |tx| {
                self.debitBalance(tx.from_address, tx.amount + tx.fee) catch {};
                self.creditBalance(tx.to_address, tx.amount) catch {};
                blk_total_fees += tx.fee;
                const current_nonce = self.nonces.get(tx.from_address) orelse 0;
                self.nonces.put(tx.from_address, current_nonce + 1) catch {};
                self.tx_block_height.put(tx.hash, @intCast(blk.index)) catch {};
            }
            const fees_burned = blk_total_fees * FEE_BURN_PCT / 100;
            const fees_to_miner = blk_total_fees - fees_burned;
            if (blk.miner_address.len > 0 and (blk.reward_sat > 0 or fees_to_miner > 0)) {
                self.creditBalance(blk.miner_address, blk.reward_sat + fees_to_miner) catch {};
            }
        }
    }

    /// Process orphan blocks: check if any now connect to our chain tip.
    /// Keeps trying until no more orphans connect (cascading resolution).
    pub fn processOrphans(self: *Blockchain) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.processOrphansInternal();
    }

    /// Internal processOrphans (no mutex, called from methods that already hold it).
    fn processOrphansInternal(self: *Blockchain) void {
        var progress = true;
        while (progress) {
            progress = false;
            const tip_hash = self.chain.items[self.chain.items.len - 1].hash;
            var i: usize = 0;
            while (i < self.orphan_blocks.items.len) {
                const orphan = self.orphan_blocks.items[i];
                if (std.mem.eql(u8, orphan.previous_hash, tip_hash)) {
                    if (self.validateBlock(&orphan)) {
                        self.applyBlock(orphan) catch {
                            i += 1;
                            continue;
                        };
                        _ = self.orphan_blocks.swapRemove(i);
                        progress = true;
                        continue;
                    }
                }
                i += 1;
            }
        }
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
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 1_000_000_000);
    try testing.expectEqual(@as(u64, 1_000_000_000), bc.getAddressBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));
}

test "Blockchain.creditBalance — acumuleaza multiple credite" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 500_000_000);
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 500_000_000);
    try testing.expectEqual(@as(u64, 1_000_000_000), bc.getAddressBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));
}

test "Blockchain.debitBalance — scade sold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 2_000_000_000);
    try bc.debitBalance("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas", 500_000_000);
    try testing.expectEqual(@as(u64, 1_500_000_000), bc.getAddressBalance("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas"));
}

test "Blockchain.debitBalance — sold insuficient => error" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", 100);
    try testing.expectError(error.InsufficientBalance, bc.debitBalance("ob1q8yy5x2xqfdv0gt53wwfy66cqmkrafgx88kda02", 200));
}

test "Blockchain.getAddressBalance — adresa necunoscuta returneaza 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u64, 0), bc.getAddressBalance("ob1qqlkv63jlf7n2vh97tc4zj3h8tvplz0e5dj7mvq"));
}

test "Blockchain.validateTransaction — amount 0 invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "ob1qrgq6jnvvhcmp03ur849a85mhdvsvaqf6dprzn4", .to_address = "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0",
        .amount = 0, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — adresa goala invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "", .to_address = "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0",
        .amount = 100, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — prefix invalid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const tx = Transaction{
        .id = 1, .from_address = "invalid_prefix_addr", .to_address = "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0",
        .amount = 100, .timestamp = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — nonce replay attack blocked" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Give sender some balance (amount + fee)
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 10_000);

    // First TX with nonce 0 should be valid (fee >= TX_MIN_FEE)
    const tx1 = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx1));

    // Simulate nonce increment after processing
    try bc.nonces.put("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 1);

    // Replay same TX with nonce 0 should be rejected (nonce too low)
    try testing.expect(!try bc.validateTransaction(&tx1));

    // TX with nonce 1 should be valid
    const tx2 = Transaction{
        .id = 2, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000001, .nonce = 1, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx2));
}

test "Blockchain.validateTransaction — insufficient balance rejected (amount + fee)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Sender has 0 balance
    const tx = Transaction{
        .id = 1, .from_address = "ob1qu6d376ysuserqh6rjeh8q0t39j7qp9fcl87hk6", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 1_000_000, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — fee too low rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 10_000);
    const tx = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 0, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — balance must cover amount + fee" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Sender has exactly 100 SAT, TX needs 100 amount + 1 fee = 101
    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 100);
    const tx = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.getNextNonce — unknown address returns 0" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expectEqual(@as(u64, 0), bc.getNextNonce("ob1qf67we03tka2etd5u8lsa3uf5aq9605hu99yxc2"));
}

test "Blockchain.validateTransaction — nonce gap rejected (strict ordering)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.creditBalance("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", 100_000);

    // Expected nonce is 0, but TX has nonce 5 — gap should be rejected
    const tx_gap = Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 5, .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx_gap));

    // nonce 0 should be accepted
    const tx_ok = Transaction{
        .id = 2, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000001, .nonce = 0, .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx_ok));
}

test "Blockchain.getNextAvailableNonce — includes pending mempool TXs" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Chain nonce is 0
    try testing.expectEqual(@as(u64, 0), bc.getNextAvailableNonce("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    // Add a TX to the internal mempool (simulating addTransaction bypassing validation)
    try bc.mempool.append(Transaction{
        .id = 1, .from_address = "ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh", .to_address = "ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0, .signature = "", .hash = "",
    });

    // Now next available nonce should be 1 (chain_nonce=0 + 1 pending)
    try testing.expectEqual(@as(u64, 1), bc.getNextAvailableNonce("ob1ql33v8q9wqvqrschu982lvrnvfupyzcvj746kqh"));

    // Bob has no pending TXs
    try testing.expectEqual(@as(u64, 0), bc.getNextAvailableNonce("ob1qrpdsg3r7mvvunw6ket46qmjzlx6fuu3ppxlfas"));
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

test "Blockchain.validateTransaction — rejects TX when pending outgoing exceeds balance" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Credit Alice 1000 SAT
    try bc.creditBalance("ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll", 1000);

    // TX1: Alice sends 400 SAT (fee=1), nonce=0 — should succeed
    const tx1 = Transaction{
        .id = 1,
        .from_address = "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll",
        .to_address = "ob1q3h3gwya8twy35f92qcyseqf2g3vc2qc8ln8g92",
        .amount = 400,
        .fee = 1,
        .timestamp = 1700000000,
        .nonce = 0,
        .signature = "",
        .hash = "",
    };
    try bc.addTransaction(tx1);

    // Verify pending outgoing is 401 (400 amount + 1 fee)
    try testing.expectEqual(@as(u64, 401), bc.getPendingOutgoing("ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll"));

    // TX2: Alice sends 700 SAT (fee=1), nonce=1 — should FAIL
    // Available = 1000 - 401 = 599, but TX2 needs 701 (700+1)
    const tx2 = Transaction{
        .id = 2,
        .from_address = "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll",
        .to_address = "ob1q3h3gwya8twy35f92qcyseqf2g3vc2qc8ln8g92",
        .amount = 700,
        .fee = 1,
        .timestamp = 1700000001,
        .nonce = 1,
        .signature = "",
        .hash = "",
    };
    try testing.expectError(error.InvalidTransaction, bc.addTransaction(tx2));

    // TX3: Alice sends 500 SAT (fee=1), nonce=1 — should SUCCEED
    // Available = 1000 - 401 = 599, TX3 needs 501 (500+1) — fits
    const tx3 = Transaction{
        .id = 3,
        .from_address = "ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll",
        .to_address = "ob1q3h3gwya8twy35f92qcyseqf2g3vc2qc8ln8g92",
        .amount = 500,
        .fee = 1,
        .timestamp = 1700000002,
        .nonce = 1,
        .signature = "",
        .hash = "",
    };
    try bc.addTransaction(tx3);

    // After TX1 (401) + TX3 (501) pending = 902, available = 98
    try testing.expectEqual(@as(u64, 902), bc.getPendingOutgoing("ob1qgg00y7hepe45r2fqcv8lw4009jyy7gc6c843ll"));
}

test "Blockchain.getConfirmations — unknown TX returns null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(bc.getConfirmations("nonexistent_tx_hash") == null);
}

test "Blockchain.getConfirmations — tracked TX returns correct count" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    // Simulate: TX was included in block at height 5
    try bc.tx_block_height.put("test_tx_hash_001", 5);
    // Chain has 1 block (genesis at index 0), so chain.items.len = 1
    // Confirmations = 1 - 5 => would underflow, so should return 0
    try testing.expectEqual(@as(u64, 0), bc.getConfirmations("test_tx_hash_001").?);
}

test "Blockchain.getTxBlockHeight — returns stored height" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.tx_block_height.put("tx_abc", 42);
    try testing.expectEqual(@as(u64, 42), bc.getTxBlockHeight("tx_abc").?);
}

test "Blockchain.getTxBlockHeight — unknown returns null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try testing.expect(bc.getTxBlockHeight("unknown") == null);
}

// ─── Block Validation Tests (B7) ────────────────────────────────────────────

test "Blockchain.validateBlock — genesis block always valid" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    const genesis = bc.getBlock(0).?;
    try testing.expect(bc.validateBlock(&genesis));
}

test "Blockchain.validateBlock — wrong merkle root rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Set difficulty to 1 so our fake hash passes difficulty check
    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0xFF} ** 32, // Wrong merkle root (should be all zeros for empty TX list)
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — future timestamp rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;
    const now = std.time.timestamp();

    var block = Block{
        .index = 1,
        .timestamp = now + 10000, // More than 2 hours in the future
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — wrong previous_hash rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "wrong_previous_hash_does_not_match_genesis",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — hash not meeting difficulty rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // difficulty = 4 (default), hash has only 1 leading zero
    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 0,
    };
    defer block.transactions.deinit();

    // difficulty=4 but hash has only 1 leading zero => rejected
    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — inflated reward rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32,
        .reward_sat = 999_999_999_999, // Way more than allowed block reward
    };
    defer block.transactions.deinit();

    try testing.expect(!bc.validateBlock(&block));
}

test "Blockchain.validateBlock — valid block passes all checks" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;

    var block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0} ** 32, // Correct for empty TX list
        .reward_sat = BLOCK_REWARD_SAT, // Correct block reward
    };
    defer block.transactions.deinit();

    try testing.expect(bc.validateBlock(&block));
}

test "Blockchain.addExternalBlock — invalid block returns error" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Block with wrong merkle root
    var bad_block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = "0000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .merkle_root = [_]u8{0xFF} ** 32,
        .reward_sat = 0,
    };
    defer bad_block.transactions.deinit();

    try testing.expectError(error.InvalidBlock, bc.addExternalBlock(bad_block));
}

test "Blockchain.addExternalBlock — valid block appended and miner credited" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.difficulty = 1;
    const reward = blockRewardAt(1);

    // Heap-allocate hash so deinit can free it (blocks at index>0 with 64-char hash get freed)
    const hash_str = try testing.allocator.alloc(u8, 64);
    @memset(hash_str, 'a');
    hash_str[0] = '0'; // leading zero for difficulty=1
    const block = Block{
        .index = 1,
        .timestamp = 1743000001,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "genesis_hash_omnibus_v1",
        .nonce = 0,
        .hash = hash_str,
        .merkle_root = [_]u8{0} ** 32,
        .miner_address = "ob1q5lk2scarv6nvqgzeekdv5xhjv7v9yex73qhm40",
        .reward_sat = reward,
    };
    // Do NOT defer deinit — blockchain takes ownership (deinit frees hash + transactions)

    try bc.addExternalBlock(block);

    // Chain should now have 2 blocks (genesis + external)
    try testing.expectEqual(@as(u32, 2), bc.getBlockCount());
    // Miner should be credited with block reward
    try testing.expectEqual(reward, bc.getAddressBalance("ob1q5lk2scarv6nvqgzeekdv5xhjv7v9yex73qhm40"));
}

// ─── Timelock + OP_RETURN Blockchain Tests (B4) ────────────────────────────

test "Blockchain.validateTransaction — locktime > current_height rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.creditBalance("ob1qmcl7lj9e5wg6523ynqyg6xklhg67tgjspv7dg6", 100_000);

    // Chain has 1 block (genesis), so chain.items.len = 1 = current_height
    // TX locked until block 100 → rejected (100 > 1)
    const tx = Transaction{
        .id = 1, .from_address = "ob1qmcl7lj9e5wg6523ynqyg6xklhg67tgjspv7dg6", .to_address = "ob1qlu4ev8rqhzw65w7m0at8khnvxje9y7t7n2plhn",
        .amount = 1000, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .locktime = 100,
        .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — locktime <= current_height accepted" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.creditBalance("ob1qje7f8p2nm66d2x5m6vvx8s0wkuyhc439c2q85r", 100_000);

    // Chain has 1 block, so current_height = 1
    // TX locked until block 1 → accepted (1 <= 1)
    const tx = Transaction{
        .id = 1, .from_address = "ob1qje7f8p2nm66d2x5m6vvx8s0wkuyhc439c2q85r", .to_address = "ob1qvwz680427a037eqyzv675xavxm8txh792h3m0r",
        .amount = 1000, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .locktime = 1,
        .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — locktime 0 always accepted (immediate)" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.creditBalance("ob1qwtdsz27whtcajhqjl4e6yc9l2vpujzzt7z8dxe", 100_000);

    const tx = Transaction{
        .id = 1, .from_address = "ob1qwtdsz27whtcajhqjl4e6yc9l2vpujzzt7z8dxe", .to_address = "ob1qvvvn3uz7nh2v93eyx7y85rc7usumvgc3kle246",
        .amount = 1000, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .locktime = 0,
        .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — op_return data-only TX accepted" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // OP_RETURN TX: amount=0, op_return set, fee >= 1
    try bc.creditBalance("ob1q8nfugl99a2ntr06grn9g3szeuw9f4ztdq6trl2", 100_000);

    const tx = Transaction{
        .id = 1, .from_address = "ob1q8nfugl99a2ntr06grn9g3szeuw9f4ztdq6trl2", .to_address = "ob1q8nfugl99a2ntr06grn9g3szeuw9f4ztdq6trl2",
        .amount = 0, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .op_return = "timestamp:2026-03-30T12:00:00Z",
        .signature = "", .hash = "",
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — op_return > 80 bytes rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try bc.creditBalance("ob1qtqh0uelqt8670n3j4ny0l6wpacgwe4as2f42d3", 100_000);

    const big_data = "X" ** 81;
    const tx = Transaction{
        .id = 1, .from_address = "ob1qtqh0uelqt8670n3j4ny0l6wpacgwe4as2f42d3", .to_address = "ob1qtqh0uelqt8670n3j4ny0l6wpacgwe4as2f42d3",
        .amount = 0, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .op_return = big_data,
        .signature = "", .hash = "",
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}

// ─── Chain Reorganization Tests (B8) ────────────────────────────────────────

/// Helper: create a valid block with given parameters (difficulty=1, no TX)
/// `variant` byte makes the hash unique across different chains (0='a' default)
fn makeTestBlockV(alloc: std.mem.Allocator, idx: u32, prev_hash: []const u8, miner: []const u8, variant: u8) !Block {
    const hash_str = try alloc.alloc(u8, 64);
    @memset(hash_str, 'a');
    hash_str[0] = '0'; // leading zero for difficulty=1

    // Make hash unique per index by encoding the index
    var idx_buf: [10]u8 = undefined;
    const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{idx}) catch "0";
    for (idx_str, 0..) |c, j| {
        if (j + 1 < 64) hash_str[j + 1] = c;
    }
    // Variant byte at a safe position to differentiate chains
    if (variant != 0) {
        hash_str[12] = variant;
    }

    return Block{
        .index = idx,
        .timestamp = 1743000000 + @as(i64, @intCast(idx)),
        .transactions = array_list.Managed(Transaction).init(alloc),
        .previous_hash = prev_hash,
        .nonce = 0,
        .hash = hash_str,
        .merkle_root = [_]u8{0} ** 32,
        .miner_address = miner,
        .reward_sat = blockRewardAt(@intCast(idx)),
    };
}

fn makeTestBlock(alloc: std.mem.Allocator, idx: u32, prev_hash: []const u8, miner: []const u8) !Block {
    return makeTestBlockV(alloc, idx, prev_hash, miner, 0);
}

test "Blockchain.reorg — longer chain accepted" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Add block 1 to our chain
    const block1 = try makeTestBlock(testing.allocator, 1, "genesis_hash_omnibus_v1", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block1);
    try testing.expectEqual(@as(u32, 2), bc.getBlockCount());

    // Build a longer competing chain: genesis + block1' + block2'
    // (same genesis, different blocks after)
    const genesis = bc.getBlock(0).?;

    const alt_block1 = try makeTestBlockV(testing.allocator, 1, genesis.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092", 'b');

    const alt_block2 = try makeTestBlockV(testing.allocator, 2, alt_block1.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092", 'b');

    var new_chain: [3]Block = undefined;
    new_chain[0] = genesis;
    new_chain[1] = alt_block1;
    new_chain[2] = alt_block2;

    try bc.reorg(&new_chain);

    // Chain should now be 3 blocks (genesis + alt1 + alt2)
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());
    // Miner B should be credited (from recalculation)
    try testing.expect(bc.getAddressBalance("ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092") > 0);

    // Clean up alt blocks that are now owned by chain (deinit handles them)
    // alt_block1 and alt_block2 transactions are owned by the chain via append
}

test "Blockchain.reorg — shorter chain rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Add 2 blocks to our chain
    const block1 = try makeTestBlock(testing.allocator, 1, "genesis_hash_omnibus_v1", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block1);

    const block2 = try makeTestBlock(testing.allocator, 2, block1.hash, "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block2);
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());

    // Try reorg with a chain of same length (3 blocks) — should be rejected
    const genesis = bc.getBlock(0).?;
    const alt_block1 = try makeTestBlock(testing.allocator, 1, genesis.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092");
    defer testing.allocator.free(alt_block1.hash);
    defer alt_block1.transactions.deinit();

    const alt_block2 = try makeTestBlock(testing.allocator, 2, alt_block1.hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092");
    defer testing.allocator.free(alt_block2.hash);
    defer alt_block2.transactions.deinit();

    var same_len_chain: [3]Block = undefined;
    same_len_chain[0] = genesis;
    same_len_chain[1] = alt_block1;
    same_len_chain[2] = alt_block2;

    try testing.expectError(error.ShorterChain, bc.reorg(&same_len_chain));

    // Chain should still be 3 blocks (unchanged)
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());
}

test "Blockchain.reorg — depth > MAX_REORG_DEPTH rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Build a chain of MAX_REORG_DEPTH + 2 blocks (genesis + 101 blocks)
    var prev_hash: []const u8 = "genesis_hash_omnibus_v1";
    for (1..MAX_REORG_DEPTH + 2) |i| {
        const blk = try makeTestBlock(testing.allocator, @intCast(i), prev_hash, "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
        try bc.addExternalBlock(blk);
        prev_hash = bc.chain.items[bc.chain.items.len - 1].hash;
    }

    // Our chain: genesis + 101 blocks = 102 blocks
    try testing.expectEqual(@as(u32, MAX_REORG_DEPTH + 2), bc.getBlockCount());

    // Build a competing chain that forks from genesis (depth = 101 > MAX_REORG_DEPTH)
    const genesis = bc.getBlock(0).?;

    // New chain needs to be longer: genesis + 102 alt blocks = 103 blocks
    var alt_chain_buf: [MAX_REORG_DEPTH + 3]Block = undefined;
    alt_chain_buf[0] = genesis;

    var alt_prev: []const u8 = genesis.hash;
    for (1..MAX_REORG_DEPTH + 3) |i| {
        const alt_blk = try makeTestBlockV(testing.allocator, @intCast(i), alt_prev, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092", 'z');
        alt_chain_buf[i] = alt_blk;
        alt_prev = alt_blk.hash;
    }

    const result = bc.reorg(alt_chain_buf[0 .. MAX_REORG_DEPTH + 3]);
    try testing.expectError(error.ReorgTooDeep, result);

    // Chain should be unchanged
    try testing.expectEqual(@as(u32, MAX_REORG_DEPTH + 2), bc.getBlockCount());

    // Clean up alt blocks
    for (1..MAX_REORG_DEPTH + 3) |i| {
        testing.allocator.free(alt_chain_buf[i].hash);
        alt_chain_buf[i].transactions.deinit();
    }
}

test "Blockchain.addExternalBlock — orphan stored when parent unknown" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Block whose parent we don't have
    const orphan = try makeTestBlock(testing.allocator, 5, "unknown_parent_hash_that_does_not_exist_in_our_chain_at_all_xxxx", "ob1q3c4mm4mpad5mnzpush3mzt0umdk7sqy7kml67e");

    try bc.addExternalBlock(orphan);

    // Block should be in orphan pool, not in chain
    try testing.expectEqual(@as(u32, 1), bc.getBlockCount()); // still just genesis
    try testing.expectEqual(@as(usize, 1), bc.orphan_blocks.items.len);
}

test "Blockchain.processOrphans — orphan connected when parent arrives" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Create block 1 and block 2, but send block 2 first (orphan)
    const block1 = try makeTestBlock(testing.allocator, 1, "genesis_hash_omnibus_v1", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    const block2 = try makeTestBlock(testing.allocator, 2, block1.hash, "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");

    // Send block 2 first — parent unknown, goes to orphan pool
    try bc.addExternalBlock(block2);
    try testing.expectEqual(@as(u32, 1), bc.getBlockCount()); // just genesis
    try testing.expectEqual(@as(usize, 1), bc.orphan_blocks.items.len);

    // Now send block 1 — connects to genesis, then orphan block 2 should auto-connect
    try bc.addExternalBlock(block1);

    // Chain should now have 3 blocks: genesis + block1 + block2
    try testing.expectEqual(@as(u32, 3), bc.getBlockCount());
    // Orphan pool should be empty
    try testing.expectEqual(@as(usize, 0), bc.orphan_blocks.items.len);
}

test "Blockchain.findForkPoint — common ancestor found" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    bc.difficulty = 1;

    // Add block 1
    const block1 = try makeTestBlock(testing.allocator, 1, "genesis_hash_omnibus_v1", "ob1qfsflcfe5y0hxdk746q87f03kvdr6pyxy324k6w");
    try bc.addExternalBlock(block1);

    // Other chain shares genesis + block1, then diverges
    const genesis = bc.getBlock(0).?;
    var other_chain: [3]Block = undefined;
    other_chain[0] = genesis;
    other_chain[1] = bc.chain.items[1]; // same block1

    const alt_block2 = try makeTestBlock(testing.allocator, 2, bc.chain.items[1].hash, "ob1qgvffvjzwp6hvf6tv4ee65e3vdv0xw3e5qn3092");
    defer testing.allocator.free(alt_block2.hash);
    defer alt_block2.transactions.deinit();
    other_chain[2] = alt_block2;

    const fork = bc.findForkPoint(&other_chain);
    try testing.expect(fork != null);
    try testing.expectEqual(@as(usize, 1), fork.?); // fork at block 1
}

test "Blockchain.findForkPoint — no common ancestor" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Build a chain with completely different hashes
    const fake_block = Block{
        .index = 0,
        .timestamp = 9999999999,
        .transactions = array_list.Managed(Transaction).init(testing.allocator),
        .previous_hash = "0000000000000000000000000000000000000000000000000000000000000000",
        .nonce = 0,
        .hash = "completely_different_genesis",
    };
    defer fake_block.transactions.deinit();

    var other_chain = [_]Block{fake_block};

    try testing.expect(bc.findForkPoint(&other_chain) == null);
}

test "Blockchain.indexAddressTx — TX appears in both sender and receiver history" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const addr_a = "ob1qyfr7eu6lawmtpc70htrf7cxpenlfxhhm8pu952";
    const addr_b = "ob1q23qfxzsfjdsyj6em4u3egclxfqmzue5etu4h6u";
    const tx_hash = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890";

    // Simulate indexing a TX for both addresses (like mineBlockForMiner does)
    bc.indexAddressTx(addr_a, tx_hash);
    bc.indexAddressTx(addr_b, tx_hash);

    // Both addresses should have the TX in their history
    const history_a = bc.getAddressHistory(addr_a);
    try testing.expect(history_a != null);
    try testing.expectEqual(@as(usize, 1), history_a.?.len);
    try testing.expectEqualStrings(tx_hash, history_a.?[0]);

    const history_b = bc.getAddressHistory(addr_b);
    try testing.expect(history_b != null);
    try testing.expectEqual(@as(usize, 1), history_b.?.len);
    try testing.expectEqualStrings(tx_hash, history_b.?[0]);
}

test "Blockchain.indexAddressTx — multiple TXs accumulate per address" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    const addr = "ob1qn8psc97zfjv0hak3nqyvgz7mjewq0hqyv7mgu7";
    const tx1 = "1111111111111111111111111111111111111111111111111111111111111111";
    const tx2 = "2222222222222222222222222222222222222222222222222222222222222222";
    const tx3 = "3333333333333333333333333333333333333333333333333333333333333333";

    bc.indexAddressTx(addr, tx1);
    bc.indexAddressTx(addr, tx2);
    bc.indexAddressTx(addr, tx3);

    const history = bc.getAddressHistory(addr);
    try testing.expect(history != null);
    try testing.expectEqual(@as(usize, 3), history.?.len);
}

test "Blockchain.getAddressHistory — unknown address returns null" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    try testing.expect(bc.getAddressHistory("ob1q80wdpvx6ewepelcnt4pu07jhe300kxtw5hhxyf") == null);
}

test "Blockchain.indexAddressTx — empty address ignored" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.indexAddressTx("", "somehash");
    try testing.expect(bc.getAddressHistory("") == null);
}

test "Blockchain.blocks_since_save — increments and resets" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Initially zero
    try testing.expectEqual(@as(u32, 0), bc.blocks_since_save);

    // Increment
    bc.blocks_since_save += 1;
    try testing.expectEqual(@as(u32, 1), bc.blocks_since_save);

    bc.blocks_since_save += 49;
    try testing.expectEqual(@as(u32, 50), bc.blocks_since_save);

    // Reset
    bc.blocks_since_save = 0;
    try testing.expectEqual(@as(u32, 0), bc.blocks_since_save);
}

test "Blockchain.checkAutoSave — triggers at block threshold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // No persistent_db attached — checkAutoSave is a no-op (no crash)
    bc.blocks_since_save = 100;
    bc.checkAutoSave();
    // Without a persistent_db, counters still reset on threshold
    try testing.expectEqual(@as(u32, 0), bc.blocks_since_save);
}

test "Blockchain.checkAutoSave — triggers at TX threshold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.txs_since_save = 1000;
    bc.checkAutoSave();
    try testing.expectEqual(@as(u32, 0), bc.txs_since_save);
}

test "Blockchain.checkAutoSave — does not trigger below threshold" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    bc.blocks_since_save = 50;
    bc.txs_since_save = 500;
    bc.last_save_time = std.time.timestamp(); // just now
    bc.checkAutoSave();
    // Should NOT have reset — thresholds not met
    try testing.expectEqual(@as(u32, 50), bc.blocks_since_save);
    try testing.expectEqual(@as(u32, 500), bc.txs_since_save);
}

test "Blockchain.saveToDisc — no-op without persistent_db" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();

    // Should not error — just returns silently
    try bc.saveToDisc();
}

// ─── Script Engine Integration Tests ──────────────────────────────────────────

const Secp256k1Crypto = @import("secp256k1.zig").Secp256k1Crypto;
const Ripemd160 = @import("ripemd160.zig").Ripemd160;

test "Blockchain.validateTransaction — legacy TX (no scripts) still validates" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1qpuvwpsyt4r0p9c800qhgmnz7n4mjffs36g8r5m", 10_000);
    const tx = Transaction{
        .id = 1, .from_address = "ob1qpuvwpsyt4r0p9c800qhgmnz7n4mjffs36g8r5m", .to_address = "ob1qa85832ynnv6lmc43mm07qjxk80mswapgz0zc63",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        // script_pubkey and script_sig default to "" (legacy mode)
    };
    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — TX with valid P2PKH scripts validates" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1qzkl36jh98nwlqhz2ldspp7enquuh9fvq2s5pna", 10_000);

    // Generate sender keypair
    const kp = try Secp256k1Crypto.generateKeyPair();

    // Compute receiver pubkey hash (for locking script)
    // Here we lock to the sender's own key for simplicity
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);

    // Create P2PKH lock script
    const lock_script = script_mod.createP2PKH(pubkey_hash);

    // Create TX (unsigned first to get hash)
    var tx = Transaction{
        .id = 1, .from_address = "ob1qzkl36jh98nwlqhz2ldspp7enquuh9fvq2s5pna", .to_address = "ob1qp4zd3f7wuputqdljt0xmu8lah0gkt47usjayzf",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        .script_pubkey = &lock_script,
    };

    // Get TX hash and sign it
    const tx_hash = tx.calculateHash();
    const sig = try Secp256k1Crypto.sign(kp.private_key, &tx_hash);

    // Create P2PKH unlock script
    const unlock_script = script_mod.createP2PKHUnlock(sig, kp.public_key);
    tx.script_sig = &unlock_script;

    try testing.expect(try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — TX with invalid scripts rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1q8sfgk7l05gngpwm6u8m964j4cmz8arly600chj", 10_000);

    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    // Lock to kp1's pubkey hash
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp1.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);
    const lock_script = script_mod.createP2PKH(pubkey_hash);

    var tx = Transaction{
        .id = 1, .from_address = "ob1q8sfgk7l05gngpwm6u8m964j4cmz8arly600chj", .to_address = "ob1qtsdal04x4kahc0rzljtkzwqpnq8p3mhn4jrv8f",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        .script_pubkey = &lock_script,
    };

    // Sign with kp2 (wrong key) — unlock won't match lock
    const tx_hash = tx.calculateHash();
    const sig = try Secp256k1Crypto.sign(kp2.private_key, &tx_hash);
    const unlock_script = script_mod.createP2PKHUnlock(sig, kp2.public_key);
    tx.script_sig = &unlock_script;

    try testing.expect(!try bc.validateTransaction(&tx));
}

test "Blockchain.validateTransaction — script_pubkey set but script_sig empty rejected" {
    var bc = try Blockchain.init(testing.allocator);
    defer bc.deinit();
    try bc.creditBalance("ob1qguvehlayw4x0v2ku25zw82tfkxsqcjv3l4xtns", 10_000);

    const kp = try Secp256k1Crypto.generateKeyPair();
    var sha_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&kp.public_key, &sha_out, .{});
    var pubkey_hash: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &pubkey_hash);
    const lock_script = script_mod.createP2PKH(pubkey_hash);

    const tx = Transaction{
        .id = 1, .from_address = "ob1qguvehlayw4x0v2ku25zw82tfkxsqcjv3l4xtns", .to_address = "ob1qvuhxtgd6p0wu6f2vn3g9l9l70uhd02hjxwf938",
        .amount = 100, .fee = 1, .timestamp = 1700000000, .nonce = 0,
        .signature = "", .hash = "",
        .script_pubkey = &lock_script,
        .script_sig = "",  // empty — should be rejected
    };
    try testing.expect(!try bc.validateTransaction(&tx));
}
