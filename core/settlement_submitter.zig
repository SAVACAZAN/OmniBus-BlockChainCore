/// settlement_submitter.zig — Pregateste datele de settlement pentru Liberty Chain
///
/// Dupa ce matching engine-ul produce fill-uri, acest modul:
///   1. Colecteaza fill-urile dintr-un batch
///   2. Construieste un Merkle tree din datele de settlement
///   3. Semneaza Merkle root-ul cu cheia minerului (secp256k1 placeholder)
///   4. Pregateste calldata pentru submitSettlement() pe OmniBusBridgeRelay.sol
///   5. POST-ul HTTP catre Liberty Chain e facut de caller (main.zig / RPC thread)
///
/// Unitati:
///   - Cantitati: SAT (u64, 1 OMNI = 1_000_000_000 SAT)
///   - Preturi: micro-USD (u64, 1_000_000 = $1.00)
///   - Timestamps: millisecunde Unix (i64)
///   - Adrese: [42]u8 EVM hex (0x + 40 hex chars)
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

// --- CONSTANTE ---------------------------------------------------------------

/// Numar maxim de fill-uri intr-un batch
pub const MAX_FILLS_PER_BATCH: usize = 64;

/// Adancime maxima proof Merkle (log2(64) = 6)
pub const MAX_PROOF_DEPTH: usize = 6;

/// Cate batch-uri pastram in istorie (circular buffer)
pub const MAX_BATCH_HISTORY: usize = 100;

/// Numar minim default de fill-uri inainte de submit
pub const DEFAULT_MIN_FILLS: u32 = 1;

// --- TIPURI ------------------------------------------------------------------

/// Un fill din matching engine care trebuie settled pe Liberty Chain
pub const SettlementFill = struct {
    order_id: u64,
    buyer_address: [42]u8,
    seller_address: [42]u8,
    token_address: [42]u8,
    fill_amount_sat: u64,
    fill_price_micro_usd: u64,
    timestamp_ms: i64,

    /// Returneaza buyer address ca slice valid (trimmed la 42 bytes EVM)
    pub fn getBuyerAddress(self: *const SettlementFill) []const u8 {
        return &self.buyer_address;
    }

    /// Returneaza seller address ca slice valid
    pub fn getSellerAddress(self: *const SettlementFill) []const u8 {
        return &self.seller_address;
    }

    /// Returneaza token address ca slice valid
    pub fn getTokenAddress(self: *const SettlementFill) []const u8 {
        return &self.token_address;
    }

    /// Fill gol (slot liber in array)
    pub fn empty() SettlementFill {
        return SettlementFill{
            .order_id = 0,
            .buyer_address = [_]u8{0} ** 42,
            .seller_address = [_]u8{0} ** 42,
            .token_address = [_]u8{0} ** 42,
            .fill_amount_sat = 0,
            .fill_price_micro_usd = 0,
            .timestamp_ms = 0,
        };
    }
};

/// Nod Merkle tree
pub const MerkleNode = struct {
    hash: [32]u8,
    left: ?u16,
    right: ?u16,
};

/// Statusul unui batch de settlement
pub const BatchStatus = enum(u8) {
    building = 0,
    merkle_built = 1,
    signed = 2,
    ready = 3,
    submitted = 4,
    confirmed = 5,
    failed = 6,
};

/// Batch de settlement — gata de trimis pe Liberty Chain
pub const SettlementBatch = struct {
    /// Fill-urile din batch
    fills: [MAX_FILLS_PER_BATCH]SettlementFill,
    fill_count: u32,

    /// Merkle tree
    merkle_root: [32]u8,
    leaves: [MAX_FILLS_PER_BATCH][32]u8,
    leaf_count: u32,
    proofs: [MAX_FILLS_PER_BATCH][MAX_PROOF_DEPTH][32]u8,
    proof_lengths: [MAX_FILLS_PER_BATCH]u8,

    /// Semnatura minerului peste merkle root (r(32) + s(32) + v(1))
    miner_signature: [65]u8,
    signature_valid: bool,

    /// Metadata
    block_height: u64,
    timestamp_ms: i64,
    miner_address: [64]u8,
    miner_addr_len: u8,

    /// Status
    status: BatchStatus,

    /// Returneaza miner address ca slice
    pub fn getMinerAddress(self: *const SettlementBatch) []const u8 {
        return self.miner_address[0..self.miner_addr_len];
    }
};

/// Sumar batch (pentru istorie)
pub const SettlementBatchSummary = struct {
    merkle_root: [32]u8,
    fill_count: u32,
    block_height: u64,
    timestamp_ms: i64,
    status: BatchStatus,
};

/// Statistici submitter
pub const SubmitterStats = struct {
    pending_fills: u32,
    batch_status: BatchStatus,
    total_submitted: u64,
    total_settled: u64,
    total_failed: u64,
    history_count: u32,
};

// --- SETTLEMENT SUBMITTER ----------------------------------------------------

/// Modulul principal care colecteaza fill-uri, construieste Merkle tree,
/// semneaza si pregateste calldata pentru Liberty Chain.
pub const SettlementSubmitter = struct {
    /// Batch-ul curent in constructie
    current_batch: SettlementBatch,

    /// Istoric batch-uri trimise (circular buffer)
    history: [MAX_BATCH_HISTORY]SettlementBatchSummary,
    history_count: u32,
    history_head: u32,

    /// Config
    min_fills_per_batch: u32,
    max_fills_per_batch: u32,

    /// Statistici
    total_batches_submitted: u64,
    total_fills_settled: u64,
    total_batches_failed: u64,

    /// Initializeaza un SettlementSubmitter cu valori default
    pub fn init() SettlementSubmitter {
        return SettlementSubmitter{
            .current_batch = emptyBatch(),
            .history = [_]SettlementBatchSummary{emptySummary()} ** MAX_BATCH_HISTORY,
            .history_count = 0,
            .history_head = 0,
            .min_fills_per_batch = DEFAULT_MIN_FILLS,
            .max_fills_per_batch = MAX_FILLS_PER_BATCH,
            .total_batches_submitted = 0,
            .total_fills_settled = 0,
            .total_batches_failed = 0,
        };
    }

    /// Adauga un fill la batch-ul curent
    pub fn addFill(self: *SettlementSubmitter, fill: SettlementFill) !void {
        if (self.current_batch.fill_count >= self.max_fills_per_batch) {
            return error.BatchFull;
        }
        if (self.current_batch.status != .building) {
            return error.BatchNotBuilding;
        }
        self.current_batch.fills[self.current_batch.fill_count] = fill;
        self.current_batch.fill_count += 1;
    }

    /// Construieste Merkle tree din fill-urile curente
    pub fn buildMerkleTree(self: *SettlementSubmitter) void {
        const count = self.current_batch.fill_count;
        if (count == 0) return;

        // compute leaf hashes
        for (0..count) |i| {
            self.current_batch.leaves[i] = computeLeafHash(&self.current_batch.fills[i]);
        }
        self.current_batch.leaf_count = count;

        // build tree bottom-up and collect proofs
        // We work with a temporary layer array
        var layer: [MAX_FILLS_PER_BATCH][32]u8 = undefined;
        var layer_size: u32 = count;
        for (0..count) |i| {
            layer[i] = self.current_batch.leaves[i];
        }

        // reset proofs
        for (0..MAX_FILLS_PER_BATCH) |i| {
            self.current_batch.proof_lengths[i] = 0;
        }

        // track which original leaf maps to which current index
        var leaf_positions: [MAX_FILLS_PER_BATCH]u32 = undefined;
        for (0..count) |i| {
            leaf_positions[i] = @intCast(i);
        }

        var depth: u8 = 0;
        while (layer_size > 1) : (depth += 1) {
            const next_size = (layer_size + 1) / 2;
            var next_layer: [MAX_FILLS_PER_BATCH][32]u8 = undefined;
            var next_positions: [MAX_FILLS_PER_BATCH]u32 = undefined;

            // For each original leaf, record the sibling at this depth
            for (0..count) |leaf_idx| {
                const pos = leaf_positions[leaf_idx];
                const sibling_pos: u32 = if (pos % 2 == 0)
                    if (pos + 1 < layer_size) pos + 1 else pos
                else
                    pos - 1;

                if (sibling_pos != pos) {
                    const pl = self.current_batch.proof_lengths[leaf_idx];
                    if (pl < MAX_PROOF_DEPTH) {
                        self.current_batch.proofs[leaf_idx][pl] = layer[sibling_pos];
                        self.current_batch.proof_lengths[leaf_idx] = pl + 1;
                    }
                }
            }

            // Compute next layer
            var j: u32 = 0;
            var i: u32 = 0;
            while (i < layer_size) : (i += 2) {
                if (i + 1 < layer_size) {
                    next_layer[j] = hashPair(layer[i], layer[i + 1]);
                } else {
                    // odd node — promoted as-is
                    next_layer[j] = layer[i];
                }
                j += 1;
            }

            // Update leaf positions for next level
            for (0..count) |leaf_idx| {
                leaf_positions[leaf_idx] = leaf_positions[leaf_idx] / 2;
            }

            layer_size = next_size;
            for (0..next_size) |k| {
                layer[k] = next_layer[k];
            }
            _ = &next_positions;
        }

        self.current_batch.merkle_root = layer[0];
        self.current_batch.status = .merkle_built;
    }

    /// Calculeaza hash-ul frunzei pentru un fill
    /// SHA256(orderId ++ buyerAddress ++ tokenAddress ++ amount)
    /// Determinist — identic cu verificarea din Solidity contract
    pub fn computeLeafHash(fill: *const SettlementFill) [32]u8 {
        var hasher = Sha256.init(.{});

        // order_id as big-endian 8 bytes
        const order_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, fill.order_id));
        hasher.update(&order_bytes);

        // buyer address (42 bytes EVM)
        hasher.update(&fill.buyer_address);

        // token address (42 bytes EVM)
        hasher.update(&fill.token_address);

        // fill amount as big-endian 8 bytes
        const amount_bytes = std.mem.toBytes(std.mem.nativeToBig(u64, fill.fill_amount_sat));
        hasher.update(&amount_bytes);

        return hasher.finalResult();
    }

    /// Semneaza merkle root-ul cu cheia privata a minerului.
    /// Placeholder: SHA256(privkey ++ merkle_root) — in productie se foloseste secp256k1.
    pub fn signMerkleRoot(self: *SettlementSubmitter, miner_privkey: [32]u8) void {
        if (self.current_batch.status != .merkle_built) return;

        var hasher = Sha256.init(.{});
        hasher.update(&miner_privkey);
        hasher.update(&self.current_batch.merkle_root);
        const sig_hash = hasher.finalResult();

        // r = first 32 bytes of hash, s = SHA256(hash), v = 27
        @memcpy(self.current_batch.miner_signature[0..32], &sig_hash);

        var s_hasher = Sha256.init(.{});
        s_hasher.update(&sig_hash);
        const s_hash = s_hasher.finalResult();
        @memcpy(self.current_batch.miner_signature[32..64], &s_hash);

        self.current_batch.miner_signature[64] = 27; // v = 27
        self.current_batch.signature_valid = true;
        self.current_batch.status = .signed;
    }

    /// Returneaza Merkle proof pentru un fill anume (dupa index)
    pub fn getProof(self: *const SettlementSubmitter, fill_index: u32) ?[]const [32]u8 {
        if (fill_index >= self.current_batch.fill_count) return null;
        const len = self.current_batch.proof_lengths[fill_index];
        if (len == 0) return null;
        return self.current_batch.proofs[fill_index][0..len];
    }

    /// Construieste calldata pentru submitSettlement(bytes32, bytes, uint256[], bytes32[][])
    /// Format: function selector (4 bytes) + ABI-encoded params
    /// Scrie in buf si returneaza slice-ul scris.
    pub fn buildCalldata(self: *const SettlementSubmitter, buf: []u8) ![]u8 {
        if (self.current_batch.status != .signed and self.current_batch.status != .ready) {
            return error.BatchNotSigned;
        }

        const count = self.current_batch.fill_count;
        // Minimum space: 4 (selector) + 32 (merkle root) + 65 (sig) + count*8 (orderIds)
        const min_size = 4 + 32 + 65 + count * 8;
        if (buf.len < min_size) return error.BufferTooSmall;

        var pos: usize = 0;

        // Function selector: keccak256("submitSettlement(bytes32,bytes,uint256[],bytes32[][])") first 4 bytes
        // Hardcoded selector: 0xa1b2c3d4 (placeholder — real one computed from Solidity ABI)
        buf[pos] = 0xa1;
        buf[pos + 1] = 0xb2;
        buf[pos + 2] = 0xc3;
        buf[pos + 3] = 0xd4;
        pos += 4;

        // merkle root (32 bytes)
        @memcpy(buf[pos .. pos + 32], &self.current_batch.merkle_root);
        pos += 32;

        // signature (65 bytes: r + s + v)
        @memcpy(buf[pos .. pos + 65], &self.current_batch.miner_signature);
        pos += 65;

        // order IDs count (4 bytes big-endian)
        const count_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, count));
        @memcpy(buf[pos .. pos + 4], &count_bytes);
        pos += 4;

        // order IDs (8 bytes each, big-endian)
        for (0..count) |i| {
            const oid = std.mem.toBytes(std.mem.nativeToBig(u64, self.current_batch.fills[i].order_id));
            @memcpy(buf[pos .. pos + 8], &oid);
            pos += 8;
        }

        // proof data: for each fill, write proof_length (1 byte) + proof hashes (32 bytes each)
        for (0..count) |i| {
            const plen = self.current_batch.proof_lengths[i];
            buf[pos] = plen;
            pos += 1;
            for (0..plen) |p| {
                @memcpy(buf[pos .. pos + 32], &self.current_batch.proofs[i][p]);
                pos += 32;
            }
        }

        return buf[0..pos];
    }

    /// Marcheaza batch-ul ca trimis — muta in starea submitted
    pub fn markSubmitted(self: *SettlementSubmitter) void {
        if (self.current_batch.status == .signed or self.current_batch.status == .ready) {
            self.current_batch.status = .submitted;
            self.total_batches_submitted += 1;
            self.total_fills_settled += self.current_batch.fill_count;
            pushHistory(self);
        }
    }

    /// Marcheaza batch-ul ca confirmat on-chain
    pub fn markConfirmed(self: *SettlementSubmitter) void {
        if (self.current_batch.status == .submitted) {
            self.current_batch.status = .confirmed;
            // Update history entry too
            if (self.history_count > 0) {
                const last = if (self.history_head == 0) MAX_BATCH_HISTORY - 1 else self.history_head - 1;
                self.history[last].status = .confirmed;
            }
        }
    }

    /// Marcheaza batch-ul ca esuat
    pub fn markFailed(self: *SettlementSubmitter) void {
        if (self.current_batch.status == .submitted) {
            self.current_batch.status = .failed;
            self.total_batches_failed += 1;
            if (self.history_count > 0) {
                const last = if (self.history_head == 0) MAX_BATCH_HISTORY - 1 else self.history_head - 1;
                self.history[last].status = .failed;
            }
        }
    }

    /// Reseteaza batch-ul pentru urmatorul ciclu
    pub fn resetBatch(self: *SettlementSubmitter) void {
        self.current_batch = emptyBatch();
    }

    /// Verifica daca batch-ul e gata de submit
    pub fn isReady(self: *const SettlementSubmitter) bool {
        return self.current_batch.status == .signed and
            self.current_batch.fill_count >= self.min_fills_per_batch;
    }

    /// Numarul de fill-uri in asteptare
    pub fn pendingFills(self: *const SettlementSubmitter) u32 {
        return self.current_batch.fill_count;
    }

    /// Returneaza statisticile curente
    pub fn getStats(self: *const SettlementSubmitter) SubmitterStats {
        return SubmitterStats{
            .pending_fills = self.current_batch.fill_count,
            .batch_status = self.current_batch.status,
            .total_submitted = self.total_batches_submitted,
            .total_settled = self.total_fills_settled,
            .total_failed = self.total_batches_failed,
            .history_count = self.history_count,
        };
    }

    // --- Functii interne ---

    fn pushHistory(self: *SettlementSubmitter) void {
        self.history[self.history_head] = SettlementBatchSummary{
            .merkle_root = self.current_batch.merkle_root,
            .fill_count = self.current_batch.fill_count,
            .block_height = self.current_batch.block_height,
            .timestamp_ms = self.current_batch.timestamp_ms,
            .status = self.current_batch.status,
        };
        self.history_head = (self.history_head + 1) % @as(u32, MAX_BATCH_HISTORY);
        if (self.history_count < MAX_BATCH_HISTORY) {
            self.history_count += 1;
        }
    }
};

// --- HELPER FUNCTIONS --------------------------------------------------------

/// Hash-ul a doua noduri Merkle — sortat (lower hash first) pentru consistenta
fn hashPair(a: [32]u8, b: [32]u8) [32]u8 {
    var hasher = Sha256.init(.{});
    // sort: lower hash first (matches Solidity convention)
    const order = std.mem.order(u8, &a, &b);
    if (order == .lt or order == .eq) {
        hasher.update(&a);
        hasher.update(&b);
    } else {
        hasher.update(&b);
        hasher.update(&a);
    }
    return hasher.finalResult();
}

/// Verifica un Merkle proof: recalculeaza root-ul din leaf + proof
pub fn verifyMerkleProof(leaf: [32]u8, proof: []const [32]u8, expected_root: [32]u8) bool {
    var current = leaf;
    for (proof) |sibling| {
        current = hashPair(current, sibling);
    }
    return std.mem.eql(u8, &current, &expected_root);
}

/// Batch gol — toate valorile la zero
fn emptyBatch() SettlementBatch {
    return SettlementBatch{
        .fills = [_]SettlementFill{SettlementFill.empty()} ** MAX_FILLS_PER_BATCH,
        .fill_count = 0,
        .merkle_root = [_]u8{0} ** 32,
        .leaves = [_][32]u8{[_]u8{0} ** 32} ** MAX_FILLS_PER_BATCH,
        .leaf_count = 0,
        .proofs = [_][MAX_PROOF_DEPTH][32]u8{[_][32]u8{[_]u8{0} ** 32} ** MAX_PROOF_DEPTH} ** MAX_FILLS_PER_BATCH,
        .proof_lengths = [_]u8{0} ** MAX_FILLS_PER_BATCH,
        .miner_signature = [_]u8{0} ** 65,
        .signature_valid = false,
        .block_height = 0,
        .timestamp_ms = 0,
        .miner_address = [_]u8{0} ** 64,
        .miner_addr_len = 0,
        .status = .building,
    };
}

/// Summary gol
fn emptySummary() SettlementBatchSummary {
    return SettlementBatchSummary{
        .merkle_root = [_]u8{0} ** 32,
        .fill_count = 0,
        .block_height = 0,
        .timestamp_ms = 0,
        .status = .building,
    };
}

/// Creeaza un fill de test cu valori parametrizate
fn testFill(order_id: u64, amount: u64, price: u64) SettlementFill {
    var fill = SettlementFill.empty();
    fill.order_id = order_id;
    fill.fill_amount_sat = amount;
    fill.fill_price_micro_usd = price;
    fill.timestamp_ms = 1700000000000;

    // Set test addresses
    const buyer = "0x1111111111111111111111111111111111111111";
    const seller = "0x2222222222222222222222222222222222222222";
    const token = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    @memcpy(fill.buyer_address[0..buyer.len], buyer);
    @memcpy(fill.seller_address[0..seller.len], seller);
    @memcpy(fill.token_address[0..token.len], token);

    return fill;
}

// =============================================================================
// TESTE
// =============================================================================

test "init settlement submitter" {
    const sub = SettlementSubmitter.init();
    try std.testing.expectEqual(@as(u32, 0), sub.current_batch.fill_count);
    try std.testing.expectEqual(BatchStatus.building, sub.current_batch.status);
    try std.testing.expectEqual(@as(u64, 0), sub.total_batches_submitted);
    try std.testing.expectEqual(@as(u64, 0), sub.total_fills_settled);
    try std.testing.expectEqual(@as(u32, 0), sub.history_count);
    try std.testing.expectEqual(DEFAULT_MIN_FILLS, sub.min_fills_per_batch);
    try std.testing.expectEqual(@as(u32, MAX_FILLS_PER_BATCH), sub.max_fills_per_batch);
}

test "add fill to batch" {
    var sub = SettlementSubmitter.init();
    const fill = testFill(1001, 50_000_000, 30_000_000_000);
    try sub.addFill(fill);

    try std.testing.expectEqual(@as(u32, 1), sub.current_batch.fill_count);
    try std.testing.expectEqual(@as(u64, 1001), sub.current_batch.fills[0].order_id);
    try std.testing.expectEqual(@as(u64, 50_000_000), sub.current_batch.fills[0].fill_amount_sat);

    // Add a second fill
    const fill2 = testFill(1002, 75_000_000, 31_000_000_000);
    try sub.addFill(fill2);
    try std.testing.expectEqual(@as(u32, 2), sub.current_batch.fill_count);
}

test "add fill — batch full error" {
    var sub = SettlementSubmitter.init();
    sub.max_fills_per_batch = 2;

    try sub.addFill(testFill(1, 100, 100));
    try sub.addFill(testFill(2, 200, 200));

    // Third fill should fail
    const result = sub.addFill(testFill(3, 300, 300));
    try std.testing.expectError(error.BatchFull, result);
}

test "compute leaf hash deterministic" {
    const fill_a = testFill(42, 1_000_000, 50_000_000);
    const fill_b = testFill(42, 1_000_000, 50_000_000);

    const hash_a = SettlementSubmitter.computeLeafHash(&fill_a);
    const hash_b = SettlementSubmitter.computeLeafHash(&fill_b);

    // Same input → same hash
    try std.testing.expect(std.mem.eql(u8, &hash_a, &hash_b));

    // Different input → different hash
    const fill_c = testFill(43, 1_000_000, 50_000_000);
    const hash_c = SettlementSubmitter.computeLeafHash(&fill_c);
    try std.testing.expect(!std.mem.eql(u8, &hash_a, &hash_c));
}

test "build merkle tree — single fill" {
    var sub = SettlementSubmitter.init();
    try sub.addFill(testFill(1, 100_000, 25_000_000));
    sub.buildMerkleTree();

    try std.testing.expectEqual(BatchStatus.merkle_built, sub.current_batch.status);
    try std.testing.expectEqual(@as(u32, 1), sub.current_batch.leaf_count);

    // For a single leaf, merkle root == leaf hash
    const leaf_hash = SettlementSubmitter.computeLeafHash(&sub.current_batch.fills[0]);
    try std.testing.expect(std.mem.eql(u8, &sub.current_batch.merkle_root, &leaf_hash));
}

test "build merkle tree — two fills" {
    var sub = SettlementSubmitter.init();
    try sub.addFill(testFill(1, 100_000, 25_000_000));
    try sub.addFill(testFill(2, 200_000, 26_000_000));
    sub.buildMerkleTree();

    try std.testing.expectEqual(BatchStatus.merkle_built, sub.current_batch.status);
    try std.testing.expectEqual(@as(u32, 2), sub.current_batch.leaf_count);

    // Root should be hash of the two leaves (sorted)
    const h0 = SettlementSubmitter.computeLeafHash(&sub.current_batch.fills[0]);
    const h1 = SettlementSubmitter.computeLeafHash(&sub.current_batch.fills[1]);
    const expected_root = hashPair(h0, h1);
    try std.testing.expect(std.mem.eql(u8, &sub.current_batch.merkle_root, &expected_root));
}

test "build merkle tree — multiple fills" {
    var sub = SettlementSubmitter.init();
    // Add 5 fills
    for (0..5) |i| {
        try sub.addFill(testFill(@intCast(i + 1), @intCast((i + 1) * 100_000), 30_000_000));
    }
    sub.buildMerkleTree();

    try std.testing.expectEqual(BatchStatus.merkle_built, sub.current_batch.status);
    try std.testing.expectEqual(@as(u32, 5), sub.current_batch.leaf_count);

    // Root should not be all zeros
    const zero_hash = [_]u8{0} ** 32;
    try std.testing.expect(!std.mem.eql(u8, &sub.current_batch.merkle_root, &zero_hash));
}

test "merkle proof verification" {
    var sub = SettlementSubmitter.init();
    try sub.addFill(testFill(10, 500_000, 40_000_000));
    try sub.addFill(testFill(20, 600_000, 41_000_000));
    try sub.addFill(testFill(30, 700_000, 42_000_000));
    try sub.addFill(testFill(40, 800_000, 43_000_000));
    sub.buildMerkleTree();

    // Verify proof for each fill
    for (0..4) |i| {
        const leaf = sub.current_batch.leaves[i];
        const proof = sub.getProof(@intCast(i));
        try std.testing.expect(proof != null);
        const valid = verifyMerkleProof(leaf, proof.?, sub.current_batch.merkle_root);
        try std.testing.expect(valid);
    }

    // Invalid proof should fail
    var bad_leaf = sub.current_batch.leaves[0];
    bad_leaf[0] ^= 0xFF; // corrupt
    const proof0 = sub.getProof(0);
    const invalid = verifyMerkleProof(bad_leaf, proof0.?, sub.current_batch.merkle_root);
    try std.testing.expect(!invalid);
}

test "sign merkle root" {
    var sub = SettlementSubmitter.init();
    try sub.addFill(testFill(1, 100_000, 25_000_000));
    sub.buildMerkleTree();

    const privkey = [_]u8{0xAB} ** 32;
    sub.signMerkleRoot(privkey);

    try std.testing.expectEqual(BatchStatus.signed, sub.current_batch.status);
    try std.testing.expect(sub.current_batch.signature_valid);
    try std.testing.expectEqual(@as(u8, 27), sub.current_batch.miner_signature[64]);

    // Signature should not be all zeros
    const zero_sig = [_]u8{0} ** 65;
    try std.testing.expect(!std.mem.eql(u8, &sub.current_batch.miner_signature, &zero_sig));
}

test "batch status transitions" {
    var sub = SettlementSubmitter.init();
    try std.testing.expectEqual(BatchStatus.building, sub.current_batch.status);

    try sub.addFill(testFill(1, 100_000, 25_000_000));
    try std.testing.expectEqual(BatchStatus.building, sub.current_batch.status);

    sub.buildMerkleTree();
    try std.testing.expectEqual(BatchStatus.merkle_built, sub.current_batch.status);

    sub.signMerkleRoot([_]u8{0x01} ** 32);
    try std.testing.expectEqual(BatchStatus.signed, sub.current_batch.status);

    sub.markSubmitted();
    try std.testing.expectEqual(BatchStatus.submitted, sub.current_batch.status);

    sub.markConfirmed();
    try std.testing.expectEqual(BatchStatus.confirmed, sub.current_batch.status);
}

test "reset batch clears state" {
    var sub = SettlementSubmitter.init();
    try sub.addFill(testFill(1, 100_000, 25_000_000));
    sub.buildMerkleTree();
    sub.signMerkleRoot([_]u8{0x01} ** 32);

    try std.testing.expectEqual(@as(u32, 1), sub.current_batch.fill_count);
    try std.testing.expectEqual(BatchStatus.signed, sub.current_batch.status);

    sub.resetBatch();

    try std.testing.expectEqual(@as(u32, 0), sub.current_batch.fill_count);
    try std.testing.expectEqual(BatchStatus.building, sub.current_batch.status);
    try std.testing.expect(!sub.current_batch.signature_valid);
}

test "batch history tracking" {
    var sub = SettlementSubmitter.init();

    // Submit two batches
    try sub.addFill(testFill(1, 100_000, 25_000_000));
    sub.buildMerkleTree();
    sub.signMerkleRoot([_]u8{0x01} ** 32);
    sub.markSubmitted();
    const root1 = sub.current_batch.merkle_root;
    sub.resetBatch();

    try sub.addFill(testFill(2, 200_000, 26_000_000));
    sub.buildMerkleTree();
    sub.signMerkleRoot([_]u8{0x02} ** 32);
    sub.markSubmitted();
    sub.resetBatch();

    try std.testing.expectEqual(@as(u32, 2), sub.history_count);
    try std.testing.expectEqual(@as(u64, 2), sub.total_batches_submitted);
    try std.testing.expectEqual(@as(u64, 2), sub.total_fills_settled);

    // First entry should have root1
    try std.testing.expect(std.mem.eql(u8, &sub.history[0].merkle_root, &root1));
    try std.testing.expectEqual(@as(u32, 1), sub.history[0].fill_count);
}

test "isReady after sign" {
    var sub = SettlementSubmitter.init();

    // Not ready before adding fills
    try std.testing.expect(!sub.isReady());

    try sub.addFill(testFill(1, 100_000, 25_000_000));

    // Not ready — only building
    try std.testing.expect(!sub.isReady());

    sub.buildMerkleTree();

    // Not ready — only merkle_built
    try std.testing.expect(!sub.isReady());

    sub.signMerkleRoot([_]u8{0x01} ** 32);

    // Now ready
    try std.testing.expect(sub.isReady());
}

test "buildCalldata produces valid output" {
    var sub = SettlementSubmitter.init();
    try sub.addFill(testFill(1001, 500_000, 30_000_000));
    try sub.addFill(testFill(1002, 600_000, 31_000_000));
    sub.buildMerkleTree();
    sub.signMerkleRoot([_]u8{0xAB} ** 32);

    var buf: [4096]u8 = undefined;
    const calldata = try sub.buildCalldata(&buf);

    // Check function selector
    try std.testing.expectEqual(@as(u8, 0xa1), calldata[0]);
    try std.testing.expectEqual(@as(u8, 0xb2), calldata[1]);
    try std.testing.expectEqual(@as(u8, 0xc3), calldata[2]);
    try std.testing.expectEqual(@as(u8, 0xd4), calldata[3]);

    // Check merkle root is at offset 4
    try std.testing.expect(std.mem.eql(u8, calldata[4..36], &sub.current_batch.merkle_root));

    // Check signature at offset 36
    try std.testing.expect(std.mem.eql(u8, calldata[36..101], &sub.current_batch.miner_signature));

    // Total length should be > 0
    try std.testing.expect(calldata.len > 101);
}

test "getStats returns correct values" {
    var sub = SettlementSubmitter.init();
    try sub.addFill(testFill(1, 100_000, 25_000_000));

    const stats = sub.getStats();
    try std.testing.expectEqual(@as(u32, 1), stats.pending_fills);
    try std.testing.expectEqual(BatchStatus.building, stats.batch_status);
    try std.testing.expectEqual(@as(u64, 0), stats.total_submitted);

    sub.buildMerkleTree();
    sub.signMerkleRoot([_]u8{0x01} ** 32);
    sub.markSubmitted();

    const stats2 = sub.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats2.total_submitted);
    try std.testing.expectEqual(@as(u64, 1), stats2.total_settled);
    try std.testing.expectEqual(BatchStatus.submitted, stats2.batch_status);
}

test "markFailed increments counter" {
    var sub = SettlementSubmitter.init();
    try sub.addFill(testFill(1, 100_000, 25_000_000));
    sub.buildMerkleTree();
    sub.signMerkleRoot([_]u8{0x01} ** 32);
    sub.markSubmitted();
    sub.markFailed();

    try std.testing.expectEqual(BatchStatus.failed, sub.current_batch.status);
    try std.testing.expectEqual(@as(u64, 1), sub.total_batches_failed);
    try std.testing.expectEqual(@as(u64, 1), sub.total_batches_submitted);
}
