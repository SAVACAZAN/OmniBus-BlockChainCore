const std = @import("std");
const transaction_mod = @import("transaction.zig");
const array_list = std.array_list;

pub const Transaction = transaction_mod.Transaction;

/// Limite mempool
pub const MEMPOOL_MAX_TX:       usize = 10_000;
pub const MEMPOOL_MAX_BYTES:    usize = 1_048_576;     // 1 MB per block worth
pub const MEMPOOL_MAX_MEMORY:   usize = 314_572_800;   // 300 MB total (ca Bitcoin Core)
/// Max bytes per single TX. Sized to fit the largest PQ signature the chain
/// supports (SLH-DSA-256s ≈ 60 KB hex sig + payload + headroom). At 100 KB a
/// single TX still fits ~10 per 1 MB block, so an attacker can't trivially
/// fill a block with one TX. Smaller-sig schemes (Falcon ~1.4 KB, ML-DSA-87
/// ~9.2 KB, Dilithium-5 ~4.6 KB) all fit comfortably under this cap.
pub const TX_MAX_BYTES:         usize = 100_000;
pub const TX_MIN_FEE_SAT:       u64   = 1;              // min 1 SAT fee (anti-spam)
/// Expiry time: TX neconfirmata dupa 14 zile e stearsa (ca Bitcoin Core: 336 ore)
pub const MEMPOOL_EXPIRY_SEC:   i64   = 14 * 24 * 3600; // 1,209,600 secunde = 14 zile

pub const MempoolError = error{
    Full,
    TxTooLarge,
    TxInvalid,
    TxDuplicate,
    FeeTooLow,
    /// HIGH-05 fix (2026-05-07): Signature verification failed for an incoming
    /// TX (initial submit OR RBF replacement). Without this guard, an attacker
    /// who knows a victim's pending (from_address, nonce) could replace the
    /// victim's TX with a higher-fee variant whose `to_address` is the
    /// attacker's wallet — the RBF path used to skip sig verification entirely.
    BadSignature,
};

/// Verifier callback signature. Returns `true` if the TX's signature is valid
/// against its declared scheme + public key (for PQ) or registered pubkey
/// (for ECDSA). The mempool calls this on every `add()` (including the RBF
/// replacement branch) when `Mempool.verifier` is non-null.
///
/// `ctx` is opaque user data (e.g. pointer to Blockchain so the verifier can
/// look up the ECDSA pubkey registry). Pass `null` ctx if not needed.
pub const TxVerifierFn = *const fn (ctx: ?*anyopaque, tx: *const Transaction) bool;

/// Intrare in mempool — TX + metadata
pub const MempoolEntry = struct {
    tx:           Transaction,
    received_at:  i64,   // Unix timestamp cand a sosit
    fee_sat:      u64,   // Fee estimat (amount-ul din TX pentru simplitate)
    size_bytes:   usize, // Marimea aproximativa
};

/// Mempool FIFO — First In First Out, anti-MEV
/// Modulul e independent de blockchain.zig — nu il modifica
pub const Mempool = struct {
    entries:     array_list.Managed(MempoolEntry),
    tx_hashes:   std.StringHashMap(void),
    total_bytes: usize,
    allocator:   std.mem.Allocator,
    /// Pending nonce count per sender address — tracks how many TXs from each sender
    /// are currently in the mempool. Used to compute next expected nonce:
    ///   next_nonce = chain_nonce + pending_count
    pending_count: std.StringHashMap(u64) = undefined,
    /// Optional signature verifier (HIGH-05 fix). When non-null, `add()` calls
    /// it before accepting any TX — this closes the RBF-without-sig-check
    /// hole. Production wires this to a closure that consults the blockchain
    /// pubkey registry; tests/benchmarks leave it null to keep TX builders
    /// trivial (sig field stays empty).
    verifier: ?TxVerifierFn = null,
    verifier_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator) Mempool {
        return .{
            .entries     = array_list.Managed(MempoolEntry).init(allocator),
            .tx_hashes   = std.StringHashMap(void).init(allocator),
            .total_bytes = 0,
            .allocator   = allocator,
            .pending_count = std.StringHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *Mempool) void {
        self.entries.deinit();
        self.tx_hashes.deinit();
        self.pending_count.deinit();
    }

    /// Adauga o TX in mempool (FIFO — la coada)
    /// Returneaza eroare daca e plina, invalida, duplicata sau fee prea mic
    pub fn add(self: *Mempool, tx: Transaction) MempoolError!void {
        // 1. Verifica limita numar TX
        if (self.entries.items.len >= MEMPOOL_MAX_TX) {
            return MempoolError.Full;
        }

        // 2. Verifica marimea TX
        const tx_size = estimateTxSize(&tx);
        if (tx_size > TX_MAX_BYTES) {
            return MempoolError.TxTooLarge;
        }

        // 3. Verifica limita bytes totali
        if (self.total_bytes + tx_size > MEMPOOL_MAX_BYTES) {
            return MempoolError.Full;
        }

        // 4. Valideaza TX (prefix valid, amount > 0, adrese non-goale)
        if (!tx.isValid()) {
            return MempoolError.TxInvalid;
        }

        // 5. Fee minim anti-spam — TX must declare fee >= TX_MIN_FEE_SAT (1 SAT)
        if (tx.fee < TX_MIN_FEE_SAT) {
            return MempoolError.FeeTooLow;
        }

        // 6. Detectie duplicate dupa hash
        const hash_key = tx.hash;
        if (hash_key.len > 0 and self.tx_hashes.contains(hash_key)) {
            return MempoolError.TxDuplicate;
        }

        // 6b. HIGH-05 FIX (2026-05-07): Signature verification gate.
        //     Runs BEFORE the RBF branch so a replacement TX with a corrupted
        //     signature is rejected even when its fee is higher. Previously,
        //     `canBeReplacedBy()` only checked fee delta — an attacker who
        //     knew a victim's (from_address, nonce) could replace the
        //     victim's TX with one that pays the attacker. The verifier
        //     callback consults whatever sig source is appropriate for the
        //     scheme (registry for ECDSA, embedded pubkey for PQ).
        if (self.verifier) |v| {
            if (!v(self.verifier_ctx, &tx)) {
                return MempoolError.BadSignature;
            }
        }

        // 7. BIP-125 RBF: Check if this TX replaces an existing one
        //    Same sender + same nonce = same "slot", higher fee = replacement
        var rbf_replaced = false;
        for (self.entries.items, 0..) |entry, idx| {
            if (std.mem.eql(u8, entry.tx.from_address, tx.from_address) and
                entry.tx.nonce == tx.nonce)
            {
                // Found existing TX with same sender+nonce
                if (entry.tx.canBeReplacedBy(&tx)) {
                    // RBF replacement: remove old, add new
                    self.total_bytes -= entry.size_bytes;
                    if (entry.tx.hash.len > 0) {
                        _ = self.tx_hashes.remove(entry.tx.hash);
                    }
                    _ = self.entries.orderedRemove(idx);
                    rbf_replaced = true;
                    break;
                } else if (!entry.tx.isRBF()) {
                    // Same slot but not RBF-enabled — reject
                    return MempoolError.TxDuplicate;
                } else {
                    // RBF enabled but fee not high enough
                    return MempoolError.FeeTooLow;
                }
            }
        }
        if (rbf_replaced) {
            std.debug.print("[MEMPOOL] RBF: replaced TX nonce={d} from={s} (fee {d} -> {d})\n",
                .{ tx.nonce, tx.from_address[0..@min(20, tx.from_address.len)], tx.fee - 1, tx.fee });
        }

        // Adauga in FIFO (la coada)
        self.entries.append(.{
            .tx          = tx,
            .received_at = std.time.timestamp(),
            .fee_sat     = tx.fee, // actual TX fee (fee market — no longer flat)
            .size_bytes  = tx_size,
        }) catch return MempoolError.Full;

        if (hash_key.len > 0) {
            self.tx_hashes.put(hash_key, {}) catch {};
        }

        // Track pending nonce count per sender (for nonce gap detection)
        const cur = self.pending_count.get(tx.from_address) orelse 0;
        self.pending_count.put(tx.from_address, cur + 1) catch {};

        self.total_bytes += tx_size;
    }

    /// CPFP (Child-Pays-For-Parent): Calculate package feerate for a TX
    /// If a TX spends from another TX in mempool (same sender, nonce = parent_nonce + 1),
    /// the combined fee of parent+child is used for mining priority.
    /// Returns: combined fee of the TX and any ancestors in mempool
    pub fn getPackageFee(self: *const Mempool, tx: *const Transaction) u64 {
        var total_fee = tx.fee;

        // Look for parent TX: same sender, nonce = this.nonce - 1
        if (tx.nonce > 0) {
            for (self.entries.items) |entry| {
                if (std.mem.eql(u8, entry.tx.from_address, tx.from_address) and
                    entry.tx.nonce == tx.nonce - 1)
                {
                    // Found parent — add its fee (recursive would be overkill for now)
                    total_fee += entry.tx.fee;
                    break;
                }
            }
        }

        // Also check if any child TX exists that boosts us
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.tx.from_address, tx.from_address) and
                entry.tx.nonce == tx.nonce + 1)
            {
                total_fee += entry.tx.fee;
                break;
            }
        }

        return total_fee;
    }

    /// Check if a TX has a child in mempool that boosts its fee (CPFP)
    pub fn hasChildBoost(self: *const Mempool, tx: *const Transaction) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.tx.from_address, tx.from_address) and
                entry.tx.nonce == tx.nonce + 1 and
                entry.tx.fee > tx.fee)
            {
                return true;
            }
        }
        return false;
    }

    /// Returns up to N mineable TXs (locktime <= current_height), FIFO order.
    /// Locked TXs remain in the mempool until their locktime is reached.
    /// Caller must free returned slice.
    pub fn getMineable(self: *Mempool, n: usize, current_height: u64, allocator: std.mem.Allocator) ![]Transaction {
        // First pass: count eligible TXs
        var eligible_count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.tx.locktime == 0 or entry.tx.locktime <= current_height) {
                eligible_count += 1;
            }
        }

        const count = @min(n, eligible_count);
        var result = try allocator.alloc(Transaction, count);
        var collected: usize = 0;

        // Collect eligible TXs (FIFO order preserved)
        var remove_indices: [10_000]usize = undefined; // max entries = MEMPOOL_MAX_TX
        var remove_count: usize = 0;

        for (self.entries.items, 0..) |entry, idx| {
            if (collected >= count) break;
            if (entry.tx.locktime == 0 or entry.tx.locktime <= current_height) {
                result[collected] = entry.tx;
                collected += 1;
                if (remove_count < remove_indices.len) {
                    remove_indices[remove_count] = idx;
                    remove_count += 1;
                }
            }
        }

        // Remove collected entries from mempool (reverse order to maintain indices)
        var ri: usize = remove_count;
        while (ri > 0) {
            ri -= 1;
            const idx = remove_indices[ri];
            const entry = self.entries.items[idx];
            // Update hash index
            if (entry.tx.hash.len > 0) {
                _ = self.tx_hashes.remove(entry.tx.hash);
            }
            // Decrement pending count
            if (self.pending_count.get(entry.tx.from_address)) |cur| {
                if (cur <= 1) {
                    _ = self.pending_count.remove(entry.tx.from_address);
                } else {
                    self.pending_count.put(entry.tx.from_address, cur - 1) catch {};
                }
            }
            self.total_bytes -= entry.size_bytes;
            // Remove by shifting
            const remaining = self.entries.items.len - 1;
            var i: usize = idx;
            while (i < remaining) : (i += 1) {
                self.entries.items[i] = self.entries.items[i + 1];
            }
            self.entries.shrinkRetainingCapacity(remaining);
        }

        return result[0..collected];
    }

    /// Scoate primele N TX-uri din mempool (FIFO — din fata)
    /// Folosit de miner la construirea unui bloc
    pub fn popN(self: *Mempool, n: usize, allocator: std.mem.Allocator) ![]Transaction {
        const count = @min(n, self.entries.items.len);
        var result = try allocator.alloc(Transaction, count);

        for (0..count) |i| {
            result[i] = self.entries.items[i].tx;
        }

        // Sterge primele `count` elemente din FIFO
        const remaining = self.entries.items.len - count;
        for (0..remaining) |i| {
            self.entries.items[i] = self.entries.items[i + count];
        }
        self.entries.shrinkRetainingCapacity(remaining);

        // Recalculeaza total_bytes
        self.total_bytes = 0;
        for (self.entries.items) |e| {
            self.total_bytes += e.size_bytes;
        }

        return result;
    }

    /// Returns up to N entries sorted by fee descending (highest fee first).
    /// FIFO order is used as tiebreaker when fees are equal.
    /// Caller must free returned slice.
    pub fn getByFee(self: *const Mempool, n: usize, allocator: std.mem.Allocator) ![]MempoolEntry {
        const count = @min(n, self.entries.items.len);
        if (count == 0) return try allocator.alloc(MempoolEntry, 0);

        // Copy entries for sorting (don't mutate original FIFO order)
        var sorted = try allocator.alloc(MempoolEntry, self.entries.items.len);
        @memcpy(sorted, self.entries.items);

        // Insertion sort by fee descending — stable sort preserves FIFO for equal fees
        var i: usize = 1;
        while (i < sorted.len) : (i += 1) {
            const key = sorted[i];
            var j: usize = i;
            while (j > 0 and sorted[j - 1].fee_sat < key.fee_sat) : (j -= 1) {
                sorted[j] = sorted[j - 1];
            }
            sorted[j] = key;
        }

        // Return only first `count` entries
        if (count < sorted.len) {
            // Shrink — free tail
            const result = try allocator.realloc(sorted, count);
            return result;
        }
        return sorted;
    }

    /// Returns the median fee from current mempool entries, or TX_MIN_FEE_SAT if empty.
    /// Used by the estimatefee RPC method.
    pub fn medianFee(self: *const Mempool) u64 {
        const len = self.entries.items.len;
        if (len == 0) return TX_MIN_FEE_SAT;
        if (len == 1) return self.entries.items[0].fee_sat;

        // Simple median without full sort: find median via partial scan
        // For small mempools this is fine; for large ones a proper O(n) select would be better
        // We collect fees into a fixed-size buffer and sort
        const MAX_SAMPLE: usize = 1024;
        var fees: [MAX_SAMPLE]u64 = undefined;
        const sample_len = @min(len, MAX_SAMPLE);
        for (0..sample_len) |i| {
            fees[i] = self.entries.items[i].fee_sat;
        }
        // Insertion sort the sample
        var i: usize = 1;
        while (i < sample_len) : (i += 1) {
            const key = fees[i];
            var j: usize = i;
            while (j > 0 and fees[j - 1] > key) : (j -= 1) {
                fees[j] = fees[j - 1];
            }
            fees[j] = key;
        }
        return fees[sample_len / 2];
    }

    /// Sterge toate TX-urile confirmate (dupa minarea unui bloc)
    pub fn removeConfirmed(self: *Mempool, confirmed: []const Transaction) void {
        for (confirmed) |conf| {
            // Sterge din hash index
            if (conf.hash.len > 0) {
                _ = self.tx_hashes.remove(conf.hash);
            }
            // Decrement pending nonce count for sender
            if (self.pending_count.get(conf.from_address)) |cur| {
                if (cur <= 1) {
                    _ = self.pending_count.remove(conf.from_address);
                } else {
                    self.pending_count.put(conf.from_address, cur - 1) catch {};
                }
            }
        }
        // Rebuild entries fara cele confirmate
        var new_entries = array_list.Managed(MempoolEntry).init(self.allocator);
        for (self.entries.items) |entry| {
            var found = false;
            for (confirmed) |conf| {
                if (entry.tx.id == conf.id) { found = true; break; }
            }
            if (!found) {
                new_entries.append(entry) catch {};
            }
        }
        self.entries.deinit();
        self.entries = new_entries;

        // Recalculeaza bytes
        self.total_bytes = 0;
        for (self.entries.items) |e| {
            self.total_bytes += e.size_bytes;
        }
    }

    /// Numarul de TX in asteptare
    pub fn size(self: *const Mempool) usize {
        return self.entries.items.len;
    }

    /// Future-block pool stats: number of TXs whose locktime > `current_height`
    /// (i.e. waiting for a future slot to land before they can be mined). The
    /// `earliest_target` is the lowest locktime among locked TXs, or 0 if
    /// none. The `latest_target` is the highest locktime, or 0 if none.
    pub fn futurePoolStats(self: *const Mempool, current_height: u64) struct {
        locked_count: usize,
        earliest_target: u64,
        latest_target: u64,
    } {
        var locked: usize = 0;
        var earliest: u64 = 0;
        var latest: u64 = 0;
        for (self.entries.items) |entry| {
            if (entry.tx.locktime > current_height) {
                locked += 1;
                if (earliest == 0 or entry.tx.locktime < earliest) earliest = entry.tx.locktime;
                if (entry.tx.locktime > latest) latest = entry.tx.locktime;
            }
        }
        return .{
            .locked_count = locked,
            .earliest_target = earliest,
            .latest_target = latest,
        };
    }

    /// Bytes totali ocupati
    pub fn bytes(self: *const Mempool) usize {
        return self.total_bytes;
    }

    /// Verifica daca mempool-ul e gol
    pub fn isEmpty(self: *const Mempool) bool {
        return self.entries.items.len == 0;
    }

    /// Elimina TX-urile mai vechi de `max_age_sec` secunde (anti-bloat)
    pub fn evictOld(self: *Mempool, max_age_sec: i64) void {
        const now = std.time.timestamp();
        var new_entries = array_list.Managed(MempoolEntry).init(self.allocator);
        for (self.entries.items) |entry| {
            if (now - entry.received_at <= max_age_sec) {
                new_entries.append(entry) catch {};
            } else {
                if (entry.tx.hash.len > 0) {
                    _ = self.tx_hashes.remove(entry.tx.hash);
                }
                // Decrement pending count for evicted TX sender
                if (self.pending_count.get(entry.tx.from_address)) |cur| {
                    if (cur <= 1) {
                        _ = self.pending_count.remove(entry.tx.from_address);
                    } else {
                        self.pending_count.put(entry.tx.from_address, cur - 1) catch {};
                    }
                }
            }
        }
        self.entries.deinit();
        self.entries = new_entries;
        self.total_bytes = 0;
        for (self.entries.items) |e| self.total_bytes += e.size_bytes;
    }

    /// Elimina TX-urile expirate (default: 14 zile, ca Bitcoin Core)
    /// Fondurile NU se pierd — TX nu a fost niciodata scrisa in blockchain
    /// Portofelul va debloca soldul dupa expirare
    pub fn evictExpired(self: *Mempool) usize {
        const before = self.entries.items.len;
        self.evictOld(MEMPOOL_EXPIRY_SEC);
        return before - self.entries.items.len;
    }

    /// Estimare totala memorie folosita (pentru MAX_MEMPOOL_MEMORY check)
    pub fn estimateMemoryUsage(self: *const Mempool) usize {
        // Entry struct overhead + TX data
        return self.entries.items.len * @sizeOf(MempoolEntry) + self.total_bytes;
    }

    /// Cleanup complet: expira vechi + verifica memorie
    pub fn maintenance(self: *Mempool) void {
        // 1. Elimina TX expirate (>14 zile)
        _ = self.evictExpired();

        // 2. Daca inca e prea mare, elimina din coada (cele mai vechi FIFO)
        //    In FIFO anti-MEV nu scoatem dupa fee (ar fi priority queue = MEV!)
        //    Scoatem cele mai vechi care n-au fost procesate
        while (self.estimateMemoryUsage() > MEMPOOL_MAX_MEMORY and self.entries.items.len > 0) {
            const evicted = self.entries.items[0];
            if (evicted.tx.hash.len > 0) {
                _ = self.tx_hashes.remove(evicted.tx.hash);
            }
            // Decrement pending count for evicted TX sender
            if (self.pending_count.get(evicted.tx.from_address)) |cur| {
                if (cur <= 1) {
                    _ = self.pending_count.remove(evicted.tx.from_address);
                } else {
                    self.pending_count.put(evicted.tx.from_address, cur - 1) catch {};
                }
            }
            self.total_bytes -= evicted.size_bytes;
            // Shift left
            const remaining = self.entries.items.len - 1;
            for (0..remaining) |i| {
                self.entries.items[i] = self.entries.items[i + 1];
            }
            self.entries.shrinkRetainingCapacity(remaining);
        }
    }

    /// Returns the number of pending TXs from a given sender address.
    /// Used to compute the next available nonce: chain_nonce + getPendingCount(addr)
    pub fn getPendingCount(self: *const Mempool, address: []const u8) u64 {
        return self.pending_count.get(address) orelse 0;
    }

    /// Replace-by-nonce: if a TX with the same sender+nonce already exists in mempool,
    /// replace it (useful for fee bumping or TX cancellation).
    /// Returns true if replacement happened, false if no existing TX with that nonce.
    pub fn replaceByNonce(self: *Mempool, tx: Transaction) bool {
        for (self.entries.items, 0..) |*entry, idx| {
            if (std.mem.eql(u8, entry.tx.from_address, tx.from_address) and
                entry.tx.nonce == tx.nonce)
            {
                // Remove old hash from index
                if (entry.tx.hash.len > 0) {
                    _ = self.tx_hashes.remove(entry.tx.hash);
                }
                // Adjust total bytes
                const old_size = entry.size_bytes;
                const new_size = estimateTxSize(&tx);
                self.total_bytes = self.total_bytes - old_size + new_size;
                // Replace entry in-place
                self.entries.items[idx] = .{
                    .tx          = tx,
                    .received_at = std.time.timestamp(),
                    .fee_sat     = tx.fee,
                    .size_bytes  = new_size,
                };
                // Add new hash to index
                if (tx.hash.len > 0) {
                    self.tx_hashes.put(tx.hash, {}) catch {};
                }
                // pending_count stays the same (replaced, not added)
                return true;
            }
        }
        return false;
    }

    pub fn printStats(self: *const Mempool) void {
        std.debug.print("[MEMPOOL] TX: {d}/{d} | Bytes: {d}/{d} | Empty: {}\n", .{
            self.size(), MEMPOOL_MAX_TX,
            self.bytes(), MEMPOOL_MAX_BYTES,
            self.isEmpty(),
        });
    }
};

/// Estimare marime TX in bytes (aproximare conservatoare).
/// Includes EVERY variable-length field so the TX_MAX_BYTES cap is honest —
/// an attacker can't smuggle huge payloads in `data`/`public_key`/`script_*`
/// past the cap by hiding them outside the legacy id/amount/sig/hash slots.
fn estimateTxSize(tx: *const Transaction) usize {
    var n: usize = 64;             // fixed-field overhead (id, amount, fee,
                                   // nonce, timestamp, locktime, sequence,
                                   // tx_type, scheme, struct padding)
    n += tx.from_address.len;
    n += tx.to_address.len;
    n += tx.signature.len;
    n += tx.hash.len;
    n += tx.public_key.len;
    n += tx.data.len;              // PHASE-2A typed payload
    n += tx.op_return.len;
    n += tx.script_pubkey.len;
    n += tx.script_sig.len;
    // PHASE-C v2 inputs/outputs — variable-length owners + amounts + indexes.
    // Conservative ~96 bytes/input (tx_hash hex + idx + struct overhead) and
    // ~96 bytes/output (address + amount + struct overhead).
    n += tx.inputs.len * 96;
    n += tx.outputs.len * 96;
    return n;
}
