const std = @import("std");
const crypto_mod = @import("crypto.zig");
const secp256k1_mod = @import("secp256k1.zig");

const Crypto = crypto_mod.Crypto;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;

/// Maximum signers in a multisig scheme
pub const MAX_SIGNERS: usize = 16;
/// Maximum signatures that can be collected
pub const MAX_SIGNATURES: usize = 16;

/// MultiSig address prefix (like Bitcoin P2SH "3...")
pub const MULTISIG_PREFIX = "ob_ms_";

/// M-of-N MultiSig configuration
/// Requires M out of N public keys to authorize a transaction
/// Compatible with Bitcoin P2SH multisig concept
pub const MultisigConfig = struct {
    /// Required signatures (M)
    threshold: u8,
    /// Total public keys (N)
    total: u8,
    /// Compressed public keys of all signers (33 bytes each, up to 16)
    pubkeys: [MAX_SIGNERS][33]u8,
    /// Number of pubkeys actually stored
    pubkey_count: u8,

    /// Create a new M-of-N multisig config
    pub fn init(threshold: u8, pubkeys: []const [33]u8) !MultisigConfig {
        if (threshold == 0) return error.ThresholdZero;
        if (pubkeys.len == 0) return error.NoPubkeys;
        if (threshold > pubkeys.len) return error.ThresholdExceedsTotal;
        if (pubkeys.len > MAX_SIGNERS) return error.TooManySigners;

        var config = MultisigConfig{
            .threshold = threshold,
            .total = @intCast(pubkeys.len),
            .pubkeys = [_][33]u8{[_]u8{0} ** 33} ** MAX_SIGNERS,
            .pubkey_count = @intCast(pubkeys.len),
        };

        for (pubkeys, 0..) |pk, i| {
            config.pubkeys[i] = pk;
        }

        return config;
    }

    /// Generate the multisig address (hash of config)
    /// address = "ob_ms_" + hex(SHA256(threshold || N || pk1 || pk2 || ... || pkN))[0..32]
    pub fn address(self: *const MultisigConfig) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&[_]u8{self.threshold});
        hasher.update(&[_]u8{self.total});
        for (0..self.pubkey_count) |i| {
            hasher.update(&self.pubkeys[i]);
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    /// Check if a public key is part of this multisig
    pub fn containsPubkey(self: *const MultisigConfig, pubkey: [33]u8) bool {
        for (0..self.pubkey_count) |i| {
            if (std.mem.eql(u8, &self.pubkeys[i], &pubkey)) return true;
        }
        return false;
    }

    /// Serialize config for storage/transmission
    pub fn serialize(self: *const MultisigConfig) [2 + MAX_SIGNERS * 33]u8 {
        var buf = [_]u8{0} ** (2 + MAX_SIGNERS * 33);
        buf[0] = self.threshold;
        buf[1] = self.pubkey_count;
        for (0..self.pubkey_count) |i| {
            const offset = 2 + i * 33;
            @memcpy(buf[offset..offset + 33], &self.pubkeys[i]);
        }
        return buf;
    }
};

/// Collected signature for multisig verification
pub const MultisigSignature = struct {
    /// Index of the signer in the MultisigConfig.pubkeys array
    signer_index: u8,
    /// ECDSA signature (64 bytes: R || S)
    signature: [64]u8,
};

/// Multisig verification: check that M valid signatures from config pubkeys exist
pub fn verifyMultisig(
    config: *const MultisigConfig,
    message_hash: [32]u8,
    signatures: []const MultisigSignature,
) bool {
    if (signatures.len < config.threshold) return false;

    var valid_count: u8 = 0;
    var used_indices: [MAX_SIGNERS]bool = [_]bool{false} ** MAX_SIGNERS;

    for (signatures) |msig| {
        // Bounds check
        if (msig.signer_index >= config.pubkey_count) continue;
        // Prevent double-signing by same key
        if (used_indices[msig.signer_index]) continue;

        // Verify ECDSA signature against the signer's public key
        const pubkey = config.pubkeys[msig.signer_index];
        if (Secp256k1Crypto.verify(pubkey, &message_hash, msig.signature)) {
            valid_count += 1;
            used_indices[msig.signer_index] = true;
        }

        // Early exit if threshold reached
        if (valid_count >= config.threshold) return true;
    }

    return valid_count >= config.threshold;
}

/// Create a signature for multisig participation
pub fn signForMultisig(
    config: *const MultisigConfig,
    private_key: [32]u8,
    message_hash: [32]u8,
) !MultisigSignature {
    // Derive public key
    const pubkey = try Secp256k1Crypto.privateKeyToPublicKey(private_key);

    // Find signer index
    var signer_index: ?u8 = null;
    for (0..config.pubkey_count) |i| {
        if (std.mem.eql(u8, &config.pubkeys[i], &pubkey)) {
            signer_index = @intCast(i);
            break;
        }
    }

    if (signer_index == null) return error.NotASigner;

    // Sign
    const sig = try Secp256k1Crypto.sign(private_key, &message_hash);

    return MultisigSignature{
        .signer_index = signer_index.?,
        .signature = sig,
    };
}

/// Timelock: multisig with time constraints (for payment channels / escrow)
pub const TimelockMultisig = struct {
    config: MultisigConfig,
    /// Block height after which the timelock expires
    lock_until_block: u64,
    /// After expiry, this key can unilaterally spend (recovery key)
    recovery_pubkey: [33]u8,

    pub fn isLocked(self: *const TimelockMultisig, current_block: u64) bool {
        return current_block < self.lock_until_block;
    }

    /// Verify: if locked, needs M-of-N. If expired, recovery key alone suffices.
    pub fn verify(
        self: *const TimelockMultisig,
        message_hash: [32]u8,
        signatures: []const MultisigSignature,
        current_block: u64,
    ) bool {
        if (self.isLocked(current_block)) {
            // Normal multisig verification
            return verifyMultisig(&self.config, message_hash, signatures);
        } else {
            // Timelock expired — recovery key can spend alone
            if (signatures.len == 0) return false;
            return Secp256k1Crypto.verify(self.recovery_pubkey, &message_hash, signatures[0].signature);
        }
    }
};

// ─── Hex helper ─────────────────────────────────────────────────────────────

const hex_chars = "0123456789abcdef";

fn bytesToHexBuf(bytes: []const u8, out: []u8) void {
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}

// ─── MultisigWallet — high-level M-of-N wallet ─────────────────────────────

/// A MultisigWallet holds the M-of-N configuration and derives an "ob_ms_" address.
/// It can create unsigned transactions and collect signatures until the threshold is met.
pub const MultisigWallet = struct {
    config: MultisigConfig,
    address: [64]u8,
    address_len: u8,

    /// Create an M-of-N multisig wallet from a set of compressed public keys.
    /// The address is derived as "ob_ms_" + hex(SHA256(M || N || sorted_pubkeys))[0..32].
    pub fn create(required: u8, pubkeys: []const [33]u8) !MultisigWallet {
        // Sort pubkeys lexicographically for deterministic address derivation
        var sorted: [MAX_SIGNERS][33]u8 = [_][33]u8{[_]u8{0} ** 33} ** MAX_SIGNERS;
        for (pubkeys, 0..) |pk, i| {
            sorted[i] = pk;
        }
        // Simple insertion sort on pubkeys (small N, max 16)
        const n = pubkeys.len;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const key = sorted[i];
            var j: usize = i;
            while (j > 0 and lessThan33(&sorted[j - 1], &key)) {
                sorted[j] = sorted[j - 1];
                j -= 1;
            }
            sorted[j] = key;
        }

        const config = try MultisigConfig.init(required, sorted[0..n]);

        // Derive address
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&[_]u8{required});
        hasher.update(&[_]u8{@intCast(n)});
        for (0..n) |idx| {
            hasher.update(&sorted[idx]);
        }
        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        // Format as "ob_ms_" + 32 hex chars (first 16 bytes of hash)
        var addr_buf: [64]u8 = [_]u8{0} ** 64;
        const prefix = MULTISIG_PREFIX;
        @memcpy(addr_buf[0..prefix.len], prefix);
        bytesToHexBuf(hash[0..16], addr_buf[prefix.len .. prefix.len + 32]);
        const addr_len: u8 = @intCast(prefix.len + 32);

        return MultisigWallet{
            .config = config,
            .address = addr_buf,
            .address_len = addr_len,
        };
    }

    /// Return the multisig address as a slice.
    pub fn getAddress(self: *const MultisigWallet) []const u8 {
        return self.address[0..self.address_len];
    }

    /// Create an unsigned MultisigTx from this wallet.
    pub fn createTx(self: *const MultisigWallet, to: []const u8, amount: u64, fee: u64, tx_id: u32) MultisigTx {
        return MultisigTx{
            .from_address = self.address,
            .from_len = self.address_len,
            .to_address_buf = blk: {
                var buf: [64]u8 = [_]u8{0} ** 64;
                const copy_len = @min(to.len, 64);
                @memcpy(buf[0..copy_len], to[0..copy_len]);
                break :blk buf;
            },
            .to_len = @intCast(@min(to.len, 64)),
            .amount = amount,
            .fee = fee,
            .tx_id = tx_id,
            .signatures = [_][64]u8{[_]u8{0} ** 64} ** MAX_SIGNERS,
            .signer_indices = [_]u8{0} ** MAX_SIGNERS,
            .sig_count = 0,
            .signed_by = [_]bool{false} ** MAX_SIGNERS,
            .config = self.config,
        };
    }

    /// Add a signature from a private key. Returns true when threshold is met.
    pub fn addSignature(self: *const MultisigWallet, tx: *MultisigTx, privkey: [32]u8) !bool {
        _ = self;
        const msg_hash = tx.txHash();
        const msig = try signForMultisig(&tx.config, privkey, msg_hash);
        if (tx.signed_by[msig.signer_index]) return error.AlreadySigned;
        tx.signatures[tx.sig_count] = msig.signature;
        tx.signer_indices[tx.sig_count] = msig.signer_index;
        tx.signed_by[msig.signer_index] = true;
        tx.sig_count += 1;
        return tx.sig_count >= tx.config.threshold;
    }

    /// Verify all collected signatures on a MultisigTx.
    pub fn verify(self: *const MultisigWallet, tx: *const MultisigTx) bool {
        _ = self;
        const msg_hash = tx.txHash();
        var msigs: [MAX_SIGNERS]MultisigSignature = undefined;
        for (0..tx.sig_count) |i| {
            msigs[i] = .{
                .signer_index = tx.signer_indices[i],
                .signature = tx.signatures[i],
            };
        }
        return verifyMultisig(&tx.config, msg_hash, msigs[0..tx.sig_count]);
    }
};

/// Compare two 33-byte arrays — returns true if a > b (for reverse sort, so smallest first after swap)
fn lessThan33(a: *const [33]u8, b: *const [33]u8) bool {
    for (0..33) |i| {
        if (a[i] > b[i]) return true;
        if (a[i] < b[i]) return false;
    }
    return false;
}

/// A multisig transaction that accumulates signatures from multiple signers.
pub const MultisigTx = struct {
    from_address: [64]u8,
    from_len: u8,
    to_address_buf: [64]u8,
    to_len: u8,
    amount: u64,
    fee: u64,
    tx_id: u32,
    signatures: [MAX_SIGNERS][64]u8,
    signer_indices: [MAX_SIGNERS]u8, // which signer produced each signature
    sig_count: u8,
    signed_by: [MAX_SIGNERS]bool,
    config: MultisigConfig,

    /// Compute the transaction hash that signers sign over.
    pub fn txHash(self: *const MultisigTx) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        // tx_id
        var id_buf: [16]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{self.tx_id}) catch "0";
        hasher.update(id_str);
        hasher.update(":");
        // from
        hasher.update(self.from_address[0..self.from_len]);
        hasher.update(":");
        // to
        hasher.update(self.to_address_buf[0..self.to_len]);
        hasher.update(":");
        // amount
        var amt_buf: [24]u8 = undefined;
        const amt_str = std.fmt.bufPrint(&amt_buf, "{d}", .{self.amount}) catch "0";
        hasher.update(amt_str);
        hasher.update(":");
        // fee
        var fee_buf: [24]u8 = undefined;
        const fee_str = std.fmt.bufPrint(&fee_buf, "{d}", .{self.fee}) catch "0";
        hasher.update(fee_str);

        var hash1: [32]u8 = undefined;
        hasher.final(&hash1);
        // Double SHA256 (SHA256d)
        return Crypto.sha256(&hash1);
    }

    /// Return true if enough signatures have been collected.
    pub fn isComplete(self: *const MultisigTx) bool {
        return self.sig_count >= self.config.threshold;
    }

    /// Get the "from" address as a slice.
    pub fn fromAddress(self: *const MultisigTx) []const u8 {
        return self.from_address[0..self.from_len];
    }

    /// Get the "to" address as a slice.
    pub fn toAddress(self: *const MultisigTx) []const u8 {
        return self.to_address_buf[0..self.to_len];
    }
};

// ─── Signature bundle codec (for embedding in Transaction.script_sig) ───────
//
// Layout (raw bytes, NOT hex):
//   magic[3] = "MS\x01"
//   count   : u8     (number of signatures, must be >= threshold)
//   entries : count * 65 bytes
//             - signer_index : u8
//             - signature    : [64]u8 (R || S, ECDSA secp256k1)
//
// Total size: 4 + 65 * count, capped at 4 + 65*16 = 1044 bytes.
// Stored in Transaction.script_sig — wire codec already length-prefixes it.

pub const BUNDLE_MAGIC: [3]u8 = .{ 'M', 'S', 0x01 };
pub const BUNDLE_MAX_SIZE: usize = 4 + 65 * MAX_SIGNERS;

/// Encode collected signatures into a script_sig bundle.
/// `out_buf` must hold at least 4 + 65*sig_count bytes.
/// Returns the number of bytes written.
pub fn encodeBundle(
    sig_count: u8,
    signer_indices: []const u8,
    signatures: []const [64]u8,
    out_buf: []u8,
) !usize {
    if (sig_count == 0 or sig_count > MAX_SIGNERS) return error.InvalidSigCount;
    if (signer_indices.len < sig_count or signatures.len < sig_count) return error.BufferTooSmall;
    const need = 4 + @as(usize, sig_count) * 65;
    if (out_buf.len < need) return error.BufferTooSmall;
    @memcpy(out_buf[0..3], &BUNDLE_MAGIC);
    out_buf[3] = sig_count;
    var off: usize = 4;
    var i: usize = 0;
    while (i < sig_count) : (i += 1) {
        out_buf[off] = signer_indices[i];
        off += 1;
        @memcpy(out_buf[off..off + 64], &signatures[i]);
        off += 64;
    }
    return need;
}

/// Decode a script_sig bundle. Returns sig_count and fills indices/sigs arrays.
pub const DecodedBundle = struct {
    sig_count: u8,
    signer_indices: [MAX_SIGNERS]u8,
    signatures: [MAX_SIGNERS][64]u8,
};

pub fn decodeBundle(buf: []const u8) !DecodedBundle {
    if (buf.len < 4) return error.BundleTooShort;
    if (!std.mem.eql(u8, buf[0..3], &BUNDLE_MAGIC)) return error.BadMagic;
    const count = buf[3];
    if (count == 0 or count > MAX_SIGNERS) return error.InvalidSigCount;
    const need = 4 + @as(usize, count) * 65;
    if (buf.len < need) return error.BundleTooShort;
    var out: DecodedBundle = .{
        .sig_count = count,
        .signer_indices = [_]u8{0} ** MAX_SIGNERS,
        .signatures = [_][64]u8{[_]u8{0} ** 64} ** MAX_SIGNERS,
    };
    var off: usize = 4;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        out.signer_indices[i] = buf[off];
        off += 1;
        @memcpy(&out.signatures[i], buf[off..off + 64]);
        off += 64;
    }
    return out;
}

/// Verify a script_sig bundle against a multisig config and a transaction hash.
/// This is the chain-side validation entrypoint: anyone with the registered
/// MultisigConfig + the TX hash can independently re-verify the M-of-N quorum.
pub fn verifyBundle(
    config: *const MultisigConfig,
    tx_hash: [32]u8,
    bundle_bytes: []const u8,
) bool {
    const decoded = decodeBundle(bundle_bytes) catch return false;
    if (decoded.sig_count < config.threshold) return false;
    var msigs: [MAX_SIGNERS]MultisigSignature = undefined;
    var i: usize = 0;
    while (i < decoded.sig_count) : (i += 1) {
        msigs[i] = .{
            .signer_index = decoded.signer_indices[i],
            .signature = decoded.signatures[i],
        };
    }
    return verifyMultisig(config, tx_hash, msigs[0..decoded.sig_count]);
}

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "MultisigConfig init 2-of-3" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const config = try MultisigConfig.init(2, &pks);

    try testing.expectEqual(@as(u8, 2), config.threshold);
    try testing.expectEqual(@as(u8, 3), config.total);
    try testing.expect(config.containsPubkey(kp1.public_key));
    try testing.expect(config.containsPubkey(kp2.public_key));
    try testing.expect(config.containsPubkey(kp3.public_key));
}

test "MultisigConfig init — threshold 0 fails" {
    const pk = [_][33]u8{[_]u8{0x02} ** 33};
    try testing.expectError(error.ThresholdZero, MultisigConfig.init(0, &pk));
}

test "MultisigConfig init — threshold > total fails" {
    const pk = [_][33]u8{[_]u8{0x02} ** 33};
    try testing.expectError(error.ThresholdExceedsTotal, MultisigConfig.init(3, &pk));
}

test "MultisigConfig address is deterministic" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };

    const config = try MultisigConfig.init(2, &pks);
    const addr1 = config.address();
    const addr2 = config.address();
    try testing.expectEqualSlices(u8, &addr1, &addr2);
}

test "MultisigConfig address differs with different keys" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks_a = [_][33]u8{ kp1.public_key, kp2.public_key };
    const pks_b = [_][33]u8{ kp1.public_key, kp3.public_key };

    const config_a = try MultisigConfig.init(2, &pks_a);
    const config_b = try MultisigConfig.init(2, &pks_b);
    try testing.expect(!std.mem.eql(u8, &config_a.address(), &config_b.address()));
}

test "MultisigConfig containsPubkey — unknown key returns false" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const config = try MultisigConfig.init(1, &pks);
    try testing.expect(!config.containsPubkey(kp3.public_key));
}

test "signForMultisig — valid signer succeeds" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const config = try MultisigConfig.init(1, &pks);

    const msg = Crypto.sha256("test multisig tx");
    const msig = try signForMultisig(&config, kp1.private_key, msg);

    try testing.expectEqual(@as(u8, 0), msig.signer_index);
}

test "signForMultisig — non-signer fails" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const config = try MultisigConfig.init(1, &pks);

    const msg = Crypto.sha256("test");
    try testing.expectError(error.NotASigner, signForMultisig(&config, kp3.private_key, msg));
}

test "verifyMultisig 2-of-3 — sufficient signatures" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const config = try MultisigConfig.init(2, &pks);

    const msg = Crypto.sha256("2of3 transaction");
    const sig1 = try signForMultisig(&config, kp1.private_key, msg);
    const sig2 = try signForMultisig(&config, kp3.private_key, msg);

    const sigs = [_]MultisigSignature{ sig1, sig2 };
    try testing.expect(verifyMultisig(&config, msg, &sigs));
}

test "verifyMultisig 2-of-3 — insufficient signatures" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const config = try MultisigConfig.init(2, &pks);

    const msg = Crypto.sha256("only one sig");
    const sig1 = try signForMultisig(&config, kp1.private_key, msg);

    const sigs = [_]MultisigSignature{sig1};
    try testing.expect(!verifyMultisig(&config, msg, &sigs));
}

test "verifyMultisig — duplicate signer rejected" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const config = try MultisigConfig.init(2, &pks);

    const msg = Crypto.sha256("double sign attempt");
    const sig1a = try signForMultisig(&config, kp1.private_key, msg);
    const sig1b = try signForMultisig(&config, kp1.private_key, msg);

    // Both from same signer — should fail (need 2 different signers)
    const sigs = [_]MultisigSignature{ sig1a, sig1b };
    try testing.expect(!verifyMultisig(&config, msg, &sigs));
}

test "TimelockMultisig — locked requires multisig" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const recovery = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{kp1.public_key};
    const config = try MultisigConfig.init(1, &pks);

    const tl = TimelockMultisig{
        .config = config,
        .lock_until_block = 1000,
        .recovery_pubkey = recovery.public_key,
    };

    try testing.expect(tl.isLocked(500)); // block 500 < 1000
    try testing.expect(!tl.isLocked(1000)); // block 1000 >= 1000
}

test "MultisigConfig serialize roundtrip" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const config = try MultisigConfig.init(2, &pks);
    const serialized = config.serialize();

    try testing.expectEqual(@as(u8, 2), serialized[0]); // threshold
    try testing.expectEqual(@as(u8, 2), serialized[1]); // count
}

// ─── MultisigWallet Tests ───────────────────────────────────────────────────

test "MultisigWallet create 2-of-3 — address has ob_ms_ prefix" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const wallet = try MultisigWallet.create(2, &pks);

    const addr = wallet.getAddress();
    try testing.expect(std.mem.startsWith(u8, addr, "ob_ms_"));
    try testing.expectEqual(@as(u8, 38), wallet.address_len); // "ob_ms_" (6) + 32 hex chars
}

test "MultisigWallet address is deterministic regardless of input order" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks_a = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const pks_b = [_][33]u8{ kp3.public_key, kp1.public_key, kp2.public_key };

    const wallet_a = try MultisigWallet.create(2, &pks_a);
    const wallet_b = try MultisigWallet.create(2, &pks_b);

    try testing.expectEqualSlices(u8, wallet_a.getAddress(), wallet_b.getAddress());
}

test "MultisigWallet 2-of-3 — 2 sigs valid" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const wallet = try MultisigWallet.create(2, &pks);

    var tx = wallet.createTx("ob1qya9sq7xpg4shf3r67772vnfg5xre5wvwvgc959", 1_000_000_000, 100, 1);
    try testing.expect(!tx.isComplete());

    // First signature — not yet complete
    const done1 = try wallet.addSignature(&tx, kp1.private_key);
    try testing.expect(!done1);
    try testing.expect(!tx.isComplete());

    // Second signature — now complete
    const done2 = try wallet.addSignature(&tx, kp3.private_key);
    try testing.expect(done2);
    try testing.expect(tx.isComplete());

    // Verify
    try testing.expect(wallet.verify(&tx));
}

test "MultisigWallet 2-of-3 — 1 sig insufficient" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const wallet = try MultisigWallet.create(2, &pks);

    var tx = wallet.createTx("ob1qya9sq7xpg4shf3r67772vnfg5xre5wvwvgc959", 500_000_000, 50, 2);
    _ = try wallet.addSignature(&tx, kp2.private_key);

    // Only 1 of 2 required — should fail verification
    try testing.expect(!wallet.verify(&tx));
}

test "MultisigWallet 3-of-5 — works" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();
    const kp4 = try Secp256k1Crypto.generateKeyPair();
    const kp5 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key, kp4.public_key, kp5.public_key };
    const wallet = try MultisigWallet.create(3, &pks);

    var tx = wallet.createTx("ob1qry95qmwrhpaqfg69j65qej9whjqjh2ydpjurgh", 2_000_000_000, 200, 3);
    _ = try wallet.addSignature(&tx, kp1.private_key);
    _ = try wallet.addSignature(&tx, kp3.private_key);
    const done = try wallet.addSignature(&tx, kp5.private_key);

    try testing.expect(done);
    try testing.expect(wallet.verify(&tx));
}

test "MultisigWallet — wrong key rejected" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp_outsider = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const wallet = try MultisigWallet.create(2, &pks);

    var tx = wallet.createTx("ob1qry95qmwrhpaqfg69j65qej9whjqjh2ydpjurgh", 1_000_000_000, 100, 4);
    try testing.expectError(error.NotASigner, wallet.addSignature(&tx, kp_outsider.private_key));
}

test "MultisigWallet — duplicate signature rejected" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const wallet = try MultisigWallet.create(2, &pks);

    var tx = wallet.createTx("ob1qry95qmwrhpaqfg69j65qej9whjqjh2ydpjurgh", 1_000_000_000, 100, 5);
    _ = try wallet.addSignature(&tx, kp1.private_key);
    try testing.expectError(error.AlreadySigned, wallet.addSignature(&tx, kp1.private_key));
}

test "MultisigTx — txHash is deterministic" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const wallet = try MultisigWallet.create(1, &pks);

    const tx = wallet.createTx("ob1qry95qmwrhpaqfg69j65qej9whjqjh2ydpjurgh", 1_000_000_000, 100, 6);
    const h1 = tx.txHash();
    const h2 = tx.txHash();
    try testing.expectEqualSlices(u8, &h1, &h2);
}

// ─── Bundle codec tests (chain-side re-verification path) ───────────────────

test "encodeBundle / decodeBundle roundtrip 2-of-3" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const wallet = try MultisigWallet.create(2, &pks);

    var tx = wallet.createTx("ob1qry95qmwrhpaqfg69j65qej9whjqjh2ydpjurgh", 5000, 50, 7);
    _ = try wallet.addSignature(&tx, kp1.private_key);
    _ = try wallet.addSignature(&tx, kp3.private_key);
    try testing.expect(tx.isComplete());

    var buf: [BUNDLE_MAX_SIZE]u8 = undefined;
    const n = try encodeBundle(tx.sig_count, &tx.signer_indices, &tx.signatures, &buf);
    try testing.expectEqual(@as(usize, 4 + 65 * 2), n);

    const decoded = try decodeBundle(buf[0..n]);
    try testing.expectEqual(@as(u8, 2), decoded.sig_count);
}

test "verifyBundle 2-of-3 — valid quorum passes" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const wallet = try MultisigWallet.create(2, &pks);

    var tx = wallet.createTx("ob1qry95qmwrhpaqfg69j65qej9whjqjh2ydpjurgh", 5000, 50, 8);
    _ = try wallet.addSignature(&tx, kp1.private_key);
    _ = try wallet.addSignature(&tx, kp2.private_key);

    var buf: [BUNDLE_MAX_SIZE]u8 = undefined;
    const n = try encodeBundle(tx.sig_count, &tx.signer_indices, &tx.signatures, &buf);

    try testing.expect(verifyBundle(&wallet.config, tx.txHash(), buf[0..n]));
}

test "verifyBundle — wrong tx_hash rejected (replay-by-hash defence)" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const wallet = try MultisigWallet.create(2, &pks);

    var tx = wallet.createTx("ob1qry95qmwrhpaqfg69j65qej9whjqjh2ydpjurgh", 5000, 50, 9);
    _ = try wallet.addSignature(&tx, kp1.private_key);
    _ = try wallet.addSignature(&tx, kp2.private_key);

    var buf: [BUNDLE_MAX_SIZE]u8 = undefined;
    const n = try encodeBundle(tx.sig_count, &tx.signer_indices, &tx.signatures, &buf);

    // Tamper: flip a byte in the hash. Sigs are over the real hash, so verify must fail.
    var wrong_hash: [32]u8 = tx.txHash();
    wrong_hash[0] ^= 0xff;
    try testing.expect(!verifyBundle(&wallet.config, wrong_hash, buf[0..n]));
}

test "verifyBundle — replay same sig twice rejected (M sigs from <M signers)" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();

    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const config = try MultisigConfig.init(2, &pks);

    const msg = Crypto.sha256("replay attack");
    const sig = try signForMultisig(&config, kp1.private_key, msg);

    // Build a forged bundle with the same signature twice.
    var indices: [MAX_SIGNERS]u8 = [_]u8{0} ** MAX_SIGNERS;
    var sigs: [MAX_SIGNERS][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** MAX_SIGNERS;
    indices[0] = sig.signer_index;
    indices[1] = sig.signer_index;
    sigs[0] = sig.signature;
    sigs[1] = sig.signature;

    var buf: [BUNDLE_MAX_SIZE]u8 = undefined;
    const n = try encodeBundle(2, &indices, &sigs, &buf);

    try testing.expect(!verifyBundle(&config, msg, buf[0..n]));
}

test "verifyBundle — magic bytes invalid → reject" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const pks = [_][33]u8{kp1.public_key};
    const config = try MultisigConfig.init(1, &pks);
    const msg = Crypto.sha256("bad magic");
    const garbage = [_]u8{ 'X', 'Y', 'Z', 1, 0 } ++ [_]u8{0} ** 64;
    try testing.expect(!verifyBundle(&config, msg, &garbage));
}

test "verifyBundle 1-of-2 — single sig sufficient" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const pks = [_][33]u8{ kp1.public_key, kp2.public_key };
    const wallet = try MultisigWallet.create(1, &pks);

    var tx = wallet.createTx("ob1qry95qmwrhpaqfg69j65qej9whjqjh2ydpjurgh", 5000, 50, 10);
    _ = try wallet.addSignature(&tx, kp2.private_key);
    var buf: [BUNDLE_MAX_SIZE]u8 = undefined;
    const n = try encodeBundle(tx.sig_count, &tx.signer_indices, &tx.signatures, &buf);
    try testing.expect(verifyBundle(&wallet.config, tx.txHash(), buf[0..n]));
}

test "verifyBundle M==N (3-of-3) edge case" {
    const kp1 = try Secp256k1Crypto.generateKeyPair();
    const kp2 = try Secp256k1Crypto.generateKeyPair();
    const kp3 = try Secp256k1Crypto.generateKeyPair();
    const pks = [_][33]u8{ kp1.public_key, kp2.public_key, kp3.public_key };
    const wallet = try MultisigWallet.create(3, &pks);

    var tx = wallet.createTx("ob1qry95qmwrhpaqfg69j65qej9whjqjh2ydpjurgh", 5000, 50, 11);
    _ = try wallet.addSignature(&tx, kp1.private_key);
    _ = try wallet.addSignature(&tx, kp2.private_key);
    _ = try wallet.addSignature(&tx, kp3.private_key);
    var buf: [BUNDLE_MAX_SIZE]u8 = undefined;
    const n = try encodeBundle(tx.sig_count, &tx.signer_indices, &tx.signatures, &buf);
    try testing.expect(verifyBundle(&wallet.config, tx.txHash(), buf[0..n]));
}
