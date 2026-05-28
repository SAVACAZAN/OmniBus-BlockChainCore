// Block + transaction validation helpers for the Blockchain struct.
//
// Extracted from blockchain.zig as part of the file-size cleanup.
// Pattern: free functions taking `*Blockchain` (or `*const Blockchain` where
// read-only). Thin delegating method shims stay on the struct in blockchain.zig
// so external callers (bc.validateTransaction(...), bc.validateBlock(...), etc.)
// keep working unchanged.

const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const consensus_params = @import("consensus_params.zig");
const hex_utils = @import("../hex_utils.zig");
const script_mod = @import("../script.zig");
const multisig_mod = @import("../multisig.zig");
const faucet_mod = @import("../faucet.zig");
const block_mod = @import("../block.zig");
const transaction_mod = @import("../transaction.zig");

const Blockchain  = blockchain_mod.Blockchain;
const Block       = block_mod.Block;
const Transaction = transaction_mod.Transaction;

const DUST_THRESHOLD_SAT = consensus_params.DUST_THRESHOLD_SAT;
const TX_MIN_FEE         = consensus_params.TX_MIN_FEE;
const FEE_BURN_PCT       = consensus_params.FEE_BURN_PCT;
const blockRewardAt      = consensus_params.blockRewardAt;

/// Maximum allowed clock drift for block timestamps (2 hours, like Bitcoin).
pub const MAX_FUTURE_SECONDS: i64 = 7200;

// ── Transaction validation ──────────────────────────────────────────────────

pub fn validateTransaction(self: *Blockchain, tx: *const Transaction) !bool {
    // 0. Locktime check: TX locked until block height N cannot be included before that
    if (tx.locktime > 0) {
        const current_height: u64 = @intCast(self.chain.items.len);
        if (tx.locktime > current_height) {
            std.debug.print("[VALIDATE] FAIL: TX locked until block {d}, current height {d}\n", .{ tx.locktime, current_height });
            return false;
        }
    }

    // 1. Amount trebuie > 0 (unless OP_RETURN data-only TX OR Phase-2A typed TX
    //    that carries its semantic value in `data`, e.g. order_place/order_cancel
    //    where the orderbook collateral is reserved separately and `amount`=0
    //    is the canonical wire form).
    const is_op_return_tx = tx.op_return.len > 0 and tx.amount == 0;
    const is_typed_tx = tx.tx_type != .transfer;
    if (tx.amount == 0 and !is_op_return_tx and !is_typed_tx) { std.debug.print("[VALIDATE] FAIL: amount=0\n", .{}); return false; }

    // 2. Adrese nu pot fi goale si trebuie minim 8 chars (prefix "ob1qhnj2fm3lrmgxzfvyejp97vv8s3ean92myqt9zt")
    if (tx.from_address.len < 8 or tx.to_address.len < 8) { std.debug.print("[VALIDATE] FAIL: addr too short from={d} to={d}\n", .{tx.from_address.len, tx.to_address.len}); return false; }

    // 3. Prefix valid (isValid verifică prefix + amount + op_return length)
    if (!tx.isValid()) { std.debug.print("[VALIDATE] FAIL: isValid() from={s} to={s} amt={d}\n", .{tx.from_address[0..@min(42,tx.from_address.len)], tx.to_address[0..@min(42,tx.to_address.len)], tx.amount}); return false; }

    // 3b. Dust threshold — respinge TX prea mici (anti-spam, ca Bitcoin 546 sat)
    //     Skip dust check for OP_RETURN data-only TXs (amount=0 is allowed)
    //     Skip for Phase-2A typed TXs (orderbook/bridge/etc. — amount carries
    //     no transfer semantics, the typed `data` payload does).
    if (!is_op_return_tx and !is_typed_tx and tx.amount < DUST_THRESHOLD_SAT) { std.debug.print("[VALIDATE] FAIL: dust {d} < {d}\n", .{tx.amount, DUST_THRESHOLD_SAT}); return false; }

    // 3c. Fee minimum check (fee market — at least TX_MIN_FEE = 1 SAT)
    if (tx.fee < TX_MIN_FEE) { std.debug.print("[VALIDATE] FAIL: fee {d} < min {d}\n", .{tx.fee, TX_MIN_FEE}); return false; }

    // 4. Strict nonce check (anti-replay + anti-gap, ca Ethereum)
    //    TX nonce must equal chain_nonce + pending_count (sequential, no gaps)
    //    This prevents replay attacks AND ensures no nonce gaps in the mempool
    const expected_nonce = self.getNextAvailableNonce(tx.from_address);
    if (tx.nonce != expected_nonce) { std.debug.print("[VALIDATE] FAIL: nonce {d} != expected {d} (chain={d})\n", .{tx.nonce, expected_nonce, self.getNextNonce(tx.from_address)}); return false; }

    // 5. PHASE-C wire v2: explicit UTXO inputs check.
    //    For v2 TXs, every listed input must exist in the UTXO set,
    //    must be owned by from_address, and the input total must
    //    cover amount + fee. No implicit balance check needed —
    //    the inputs ARE the balance.
    if (tx.isV2()) {
        var input_total: u64 = 0;
        const current_height: u64 = if (self.chain.items.len == 0) 0
            else @as(u64, @intCast(self.chain.items.len - 1));
        for (tx.inputs) |inp| {
            const utxo = self.utxo_set.getUTXO(inp.tx_hash, inp.output_index) orelse {
                std.debug.print(
                    "[VALIDATE v2] FAIL: input {s}:{d} not in UTXO set\n",
                    .{ inp.tx_hash, inp.output_index },
                );
                return false;
            };
            if (!std.mem.eql(u8, utxo.address, tx.from_address)) {
                std.debug.print(
                    "[VALIDATE v2] FAIL: input owner mismatch (expected={s}, got={s})\n",
                    .{ tx.from_address, utxo.address },
                );
                return false;
            }
            if (!utxo.isMature(current_height)) {
                std.debug.print(
                    "[VALIDATE v2] FAIL: input {s}:{d} immature (coinbase needs 100 confirms)\n",
                    .{ inp.tx_hash, inp.output_index },
                );
                return false;
            }
            input_total += utxo.amount;
        }
        // Sum of explicit outputs (if any) must not exceed inputs - fee.
        var out_total: u64 = 0;
        for (tx.outputs) |out| out_total += out.amount;
        if (input_total < out_total + tx.fee) {
            std.debug.print(
                "[VALIDATE v2] FAIL: inputs {d} < outputs {d} + fee {d}\n",
                .{ input_total, out_total, tx.fee },
            );
            return false;
        }
        // Also enforce the implicit (amount, to_address) when outputs[]
        // is empty — keeps the v1 amount field meaningful.
        if (tx.outputs.len == 0 and input_total < tx.amount + tx.fee) {
            std.debug.print(
                "[VALIDATE v2] FAIL: inputs {d} < amount {d} + fee {d}\n",
                .{ input_total, tx.amount, tx.fee },
            );
            return false;
        }
    } else {
        // v1 backward-compat: classic balance + pending check + DEX escrow.
        // OMNI locked in resting sell orders is real escrow — debit it
        // from spendable so a user cannot send away OMNI promised to a
        // pending fill. Cancelling the order releases the lock immediately.
        const sender_balance = self.getAddressBalance(tx.from_address);
        const pending_out = self.getPendingOutgoing(tx.from_address);
        const reserved_in_orders = self.getReservedFromOrders(tx.from_address);
        const debits = pending_out +| reserved_in_orders;
        const available = if (sender_balance > debits) sender_balance - debits else 0;
        if (available < tx.amount + tx.fee) { std.debug.print("[VALIDATE] FAIL: balance {d} - pending {d} - reserved {d} = available {d} < amount+fee {d}\n", .{sender_balance, pending_out, reserved_in_orders, available, tx.amount + tx.fee}); return false; }
    }

    // 5b-faucet. Faucet address restriction: TX from FAUCET_ADDR may only go
    //   to addresses that have NOT yet completed pq_attest (onboarding gate).
    //   This rule is enforced by every miner — funds cannot leave the faucet
    //   for any purpose other than onboarding a fresh address.
    if (std.mem.eql(u8, tx.from_address, faucet_mod.FAUCET_ADDR)) {
        // op_return must be a valid faucet_claim
        if (!std.mem.startsWith(u8, tx.op_return, faucet_mod.FAUCET_OP_PREFIX)) {
            std.debug.print("[VALIDATE] FAIL: faucet TX missing faucet_claim op_return\n", .{});
            return false;
        }
        // destination must NOT already have pq_attest (no double-funding)
        if (self.pq_identity_map.contains(tx.to_address)) {
            std.debug.print("[VALIDATE] FAIL: faucet TX to already-attested address {s}\n",
                .{tx.to_address[0..@min(20, tx.to_address.len)]});
            return false;
        }
        // amount must not exceed FAUCET_AMOUNT_SAT (prevent draining)
        if (tx.amount > faucet_mod.FAUCET_AMOUNT_SAT) {
            std.debug.print("[VALIDATE] FAIL: faucet TX amount {d} > max {d}\n",
                .{tx.amount, faucet_mod.FAUCET_AMOUNT_SAT});
            return false;
        }
    }

    // 5c-covenant. Covenant whitelist check: if the sender has an active
    //   destination-whitelist covenant, the TX.to_address must be allowed
    //   and amount must not exceed per-TX cap.
    {
        const current_block: u64 = @intCast(self.chain.items.len);
        if (!self.covenant_store.checkTx(tx.from_address, tx.to_address, tx.amount, current_block)) {
            std.debug.print("[VALIDATE] FAIL: covenant violation from={s} to={s} amt={d}\n",
                .{ tx.from_address[0..@min(20, tx.from_address.len)],
                   tx.to_address[0..@min(20, tx.to_address.len)],
                   tx.amount });
            return false;
        }
    }

    // 5c. Multisig validation: if from_address is "ob_ms_*", recover the
    //     registered MultisigConfig, decode the M-of-N signature bundle
    //     from script_sig, and re-verify the quorum independently. Without
    //     re-verifying here anyone could spend from a registered multisig
    //     by submitting a TX with signature="multisig_verified".
    if (std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX)) {
        const ms_config = self.getMultisigConfig(tx.from_address) orelse {
            std.debug.print("[VALIDATE] FAIL: multisig address not registered: {s}\n",
                .{tx.from_address[0..@min(20, tx.from_address.len)]});
            return false;
        };
        if (tx.script_sig.len == 0) {
            std.debug.print("[VALIDATE] FAIL: multisig TX missing script_sig bundle\n", .{});
            return false;
        }
        // The signers signed Transaction.calculateHash() — re-derive it
        // and verify the M-of-N quorum against the registered pubkeys.
        const expected_hash = tx.calculateHash();
        if (!multisig_mod.verifyBundle(ms_config, expected_hash, tx.script_sig)) {
            std.debug.print("[VALIDATE] FAIL: multisig M-of-N quorum verification failed for {s}\n",
                .{tx.from_address[0..@min(20, tx.from_address.len)]});
            return false;
        }
        // Bonus check: tx.hash (if set) must match the canonical hash so
        // explorers/clients see a consistent value.
        if (tx.hash.len == 64) {
            var stored_hash: [32]u8 = undefined;
            hex_utils.hexToBytes(tx.hash, &stored_hash) catch return false;
            if (!std.mem.eql(u8, &stored_hash, &expected_hash)) {
                std.debug.print("[VALIDATE] FAIL: multisig tx.hash mismatch\n", .{});
                return false;
            }
        }
    }

    // 6. Verificare semnatura ECDSA secp256k1 cu public key inregistrat
    //    (signature = 128 hex chars = 64 bytes R||S, hash = 64 hex chars)
    //    Skip for multisig addresses (they use M-of-N verification instead)
    //    Skip for PQ schemes (love/food/rent/vacation) — verificate de RPC handler
    //    inainte de submit; signature size este variabila per scheme.
    const is_pq_scheme = tx.scheme != .omni_ecdsa;
    if (is_pq_scheme and tx.hash.len == 64) {
        // PQ TX: verifica integritatea hash-ului doar (semnatura PQ a fost
        // verificata de handler la submit). Daca hash-ul nu corespunde
        // bytes-urilor TX, respinge.
        const expected_hash = tx.calculateHash();
        var stored_hash: [32]u8 = undefined;
        hex_utils.hexToBytes(tx.hash, &stored_hash) catch return false;
        if (!std.mem.eql(u8, &stored_hash, &expected_hash)) return false;
    }
    if (!std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX) and
        !is_pq_scheme and
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
                std.debug.print(
                    "[VALIDATE] FAIL: ECDSA signature verification failed for {s} (registered pubkey: {s}, tx_hash: {s}, sig: {s}..)\n",
                    .{
                        tx.from_address[0..@min(20, tx.from_address.len)],
                        pubkey_hex[0..@min(16, pubkey_hex.len)],
                        tx.hash[0..@min(16, tx.hash.len)],
                        tx.signature[0..@min(16, tx.signature.len)],
                    },
                );
                return false;
            }
        }
        // Daca pubkey nu e inregistrat, acceptam TX (backward compat cu coinbase/genesis)
        // Urmatoarea TX de la aceasta adresa va fi verificata dupa registerPubkey()
    } else if (!std.mem.startsWith(u8, tx.from_address, multisig_mod.MULTISIG_PREFIX) and
               !is_pq_scheme and
               tx.signature.len > 0) {
        // Semnătură incompletă — respinge (skip for multisig which uses different sig format,
        // and for PQ schemes which validate at RPC layer with a separate verifier)
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

// ── Block hash helpers ──────────────────────────────────────────────────────

/// Calculate block hash as 64-char hex string (shared implementation in hex_utils)
pub fn calculateBlockHash(self: *Blockchain, block: *const Block) ![]const u8 {
    return hex_utils.hashBlock(block.*, self.allocator);
}

/// Check if hash meets difficulty (delegates to shared hex_utils)
pub fn isValidHash(self: *Blockchain, hash: []const u8) !bool {
    return hex_utils.isValidHashDifficulty(hash, self.difficulty);
}

// ── Block validation ────────────────────────────────────────────────────────

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

    // 7. Bridge limits — sum bridge-lock TXs in this block + last 86400
    // blocks must not exceed BRIDGE_MAX_DAILY_SAT, and no single TX may
    // exceed BRIDGE_MAX_PER_TX_SAT. Defense-in-depth from Ronin/Orbit
    // hacks: even a malicious miner can't push a giant lock through.
    if (!validateBridgeLimits(self, block)) {
        std.debug.print("[VALIDATE_BLOCK] FAIL: bridge cap exceeded in block {d}\n", .{block.index});
        return false;
    }

    return true;
}

// ── Bridge consensus hooks ──────────────────────────────────────────────────

/// Returns true if `tx` is a bridge lock: destination = vault address
/// (case-insensitive 0x... 40-hex compare) AND op_return starts with
/// "OMNIBRIDGE:". Cheap inline check called on every TX during block
/// validation, so kept simple.
pub fn isBridgeLockTx(tx: *const Transaction) bool {
    const cfg = @import("../chain_config.zig");
    const vault = cfg.BRIDGE_VAULT_ADDR_HEX;
    // to_address may be lowercase or mixed; compare case-insensitive on
    // the hex chars after "0x".
    if (tx.to_address.len != vault.len) return false;
    for (tx.to_address, vault) |a, b| {
        const al = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const bl = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (al != bl) return false;
    }
    const prefix = "OMNIBRIDGE:";
    if (tx.op_return.len < prefix.len) return false;
    return std.mem.eql(u8, tx.op_return[0..prefix.len], prefix);
}

/// Sum lock amounts in `block` and verify per-tx + rolling-day caps.
/// Caller MUST hold mutex (or be in single-threaded context).
pub fn validateBridgeLimits(self: *Blockchain, block: *const Block) bool {
    const cfg = @import("../chain_config.zig");
    var block_lock_sum: u64 = 0;
    for (block.transactions.items) |tx| {
        if (!isBridgeLockTx(&tx)) continue;
        // Per-tx hard cap.
        if (tx.amount == 0 or tx.amount > cfg.BRIDGE_MAX_PER_TX_SAT) {
            std.debug.print(
                "[BRIDGE-LIMIT] TX over per-tx cap: amount={d} max={d}\n",
                .{ tx.amount, cfg.BRIDGE_MAX_PER_TX_SAT },
            );
            return false;
        }
        block_lock_sum +%= tx.amount;
        if (block_lock_sum < tx.amount) return false; // overflow
    }
    if (block_lock_sum == 0) return true; // no bridge TXs in this block

    // Rolling 24h: sum lock TXs in the last BRIDGE_DAILY_WINDOW_BLOCKS
    // blocks (excluding the candidate block itself, which is not in
    // chain yet) plus the candidate's own lock sum.
    const window = cfg.BRIDGE_DAILY_WINDOW_BLOCKS;
    const tip = self.chain.items.len;
    const start = if (tip > window) tip - window else 0;
    var historical: u64 = 0;
    var i: usize = start;
    while (i < tip) : (i += 1) {
        const blk = &self.chain.items[i];
        for (blk.transactions.items) |htx| {
            if (isBridgeLockTx(&htx)) {
                historical +%= htx.amount;
                if (historical < htx.amount) return false; // overflow
            }
        }
    }
    const grand_total = historical +% block_lock_sum;
    if (grand_total < historical) return false; // overflow
    if (grand_total > cfg.BRIDGE_MAX_DAILY_SAT) {
        std.debug.print(
            "[BRIDGE-LIMIT] daily cap exceeded: hist={d} block={d} cap={d}\n",
            .{ historical, block_lock_sum, cfg.BRIDGE_MAX_DAILY_SAT },
        );
        return false;
    }
    return true;
}

// ── Validate-at-height (reorg helper) ───────────────────────────────────────

/// Validate a block as if it were at a specific height (used during reorg).
pub fn validateBlockAtHeight(self: *Blockchain, block: *const Block, height: usize) bool {
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
