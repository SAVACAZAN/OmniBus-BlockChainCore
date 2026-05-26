//! Native Segwit support pentru OmniBus (BIP-141 / BIP-143 / BIP-173 / BIP-350).
//!
//! Wrapper peste core/bech32.zig pentru P2WPKH (v0/20B), P2WSH (v0/32B), P2TR (v1/32B).
//! Adauga si calcul vsize cu segwit discount (BIP-141): vsize = (base*3 + total + 3) / 4.

const std = @import("std");
const bech32 = @import("bech32.zig");
const Allocator = std.mem.Allocator;

pub const WitnessVersion = u5;
pub const WITNESS_V0: WitnessVersion = 0;
pub const WITNESS_V1: WitnessVersion = 1; // taproot

pub const WitnessProgram = struct {
    version: WitnessVersion,
    program: []const u8,

    pub fn isValid(self: WitnessProgram) bool {
        if (self.version == WITNESS_V0) {
            return self.program.len == 20 or self.program.len == 32;
        }
        return self.program.len >= 2 and self.program.len <= 40;
    }
};

// ============================================================
// Address generation (encoding)
// ============================================================

/// P2WPKH bech32 (v0 + 20-byte hash160). Caller free.
pub fn encodeP2WPKH(hrp: []const u8, pubkey_hash20: [20]u8, allocator: Allocator) ![]u8 {
    return bech32.encodeWitnessAddress(hrp, WITNESS_V0, &pubkey_hash20, allocator);
}

/// P2WSH bech32 (v0 + 32-byte sha256 over script). Caller free.
pub fn encodeP2WSH(hrp: []const u8, script_hash32: [32]u8, allocator: Allocator) ![]u8 {
    return bech32.encodeWitnessAddress(hrp, WITNESS_V0, &script_hash32, allocator);
}

/// P2TR bech32m (v1 + 32-byte x-only pubkey). Caller free.
pub fn encodeP2TR(hrp: []const u8, xonly_pubkey32: [32]u8, allocator: Allocator) ![]u8 {
    return bech32.encodeWitnessAddress(hrp, WITNESS_V1, &xonly_pubkey32, allocator);
}

/// Decode orice witness address (bech32 sau bech32m), verificand HRP.
/// Returneaza WitnessResult. Caller free pe .program.
pub fn decodeWitnessAddress(expected_hrp: []const u8, addr: []const u8, allocator: Allocator) !bech32.WitnessResult {
    return bech32.decodeWitnessAddress(expected_hrp, addr, allocator);
}

// ============================================================
// Witness transaction + vsize calculation
// ============================================================

pub const OutPoint = struct {
    txid: [32]u8,
    vout: u32,
};

pub const WitnessInput = struct {
    previous_outpoint: OutPoint,
    script_sig: []const u8,
    sequence: u32,
};

pub const TxOutput = struct {
    amount: u64,
    script_pubkey: []const u8,
};

pub const WitnessTransaction = struct {
    version: i32,
    inputs: []const WitnessInput,
    outputs: []const TxOutput,
    /// Per-input witness stack: witnesses.len == inputs.len.
    /// Fiecare witness e o lista de items (push-uri).
    witnesses: []const []const []const u8,
    locktime: u32,
};

/// Encode CompactSize (Bitcoin VarInt) — returneaza dimensiunea in octeti.
fn varIntSize(n: usize) u64 {
    if (n < 0xFD) return 1;
    if (n <= 0xFFFF) return 3;
    if (n <= 0xFFFFFFFF) return 5;
    return 9;
}

/// Marime "base" — TX serializat fara witness flag/marker si fara witness data.
pub fn baseSize(tx: *const WitnessTransaction) u64 {
    var size: u64 = 4 + 4; // version + locktime

    size += varIntSize(tx.inputs.len);
    for (tx.inputs) |input| {
        size += 32 + 4; // outpoint (txid + vout)
        size += varIntSize(input.script_sig.len);
        size += input.script_sig.len;
        size += 4; // sequence
    }

    size += varIntSize(tx.outputs.len);
    for (tx.outputs) |output| {
        size += 8; // amount
        size += varIntSize(output.script_pubkey.len);
        size += output.script_pubkey.len;
    }

    return size;
}

/// Marime "total" — include marker+flag (2 bytes) + witness data.
pub fn totalSize(tx: *const WitnessTransaction) u64 {
    var size = baseSize(tx);

    // marker (0x00) + flag (0x01) — doar daca exista witness data
    var has_witness = false;
    for (tx.witnesses) |w| {
        if (w.len > 0) {
            has_witness = true;
            break;
        }
    }
    if (!has_witness) return size;
    size += 2;

    for (tx.witnesses) |witness| {
        size += varIntSize(witness.len);
        for (witness) |item| {
            size += varIntSize(item.len);
            size += item.len;
        }
    }

    return size;
}

/// Virtual size (BIP-141): weight = base*3 + total, vsize = ceil(weight / 4).
pub fn vsize(tx: *const WitnessTransaction) u64 {
    const b = baseSize(tx);
    const t = totalSize(tx);
    const w = b * 3 + t;
    return (w + 3) / 4;
}

/// Witness weight (4*base + witness_bytes) — folosit la fee_rate sat/vbyte.
pub fn txWeight(tx: *const WitnessTransaction) u64 {
    return baseSize(tx) * 3 + totalSize(tx);
}

// ============================================================
// Tests
// ============================================================

test "WitnessProgram isValid for v0" {
    var p20 = [_]u8{0} ** 20;
    var p32 = [_]u8{0} ** 32;
    var p15 = [_]u8{0} ** 15;
    try std.testing.expect((WitnessProgram{ .version = WITNESS_V0, .program = &p20 }).isValid());
    try std.testing.expect((WitnessProgram{ .version = WITNESS_V0, .program = &p32 }).isValid());
    try std.testing.expect(!(WitnessProgram{ .version = WITNESS_V0, .program = &p15 }).isValid());
}

test "encodeP2WPKH round-trip via bech32" {
    const allocator = std.testing.allocator;
    const pkh = [_]u8{0xAA} ** 20;
    const addr = try encodeP2WPKH("ob", pkh, allocator);
    defer allocator.free(addr);

    try std.testing.expect(std.mem.startsWith(u8, addr, "ob1"));

    const result = try decodeWitnessAddress("ob", addr, allocator);
    defer allocator.free(result.program);
    try std.testing.expectEqual(WITNESS_V0, result.version);
    try std.testing.expectEqual(@as(usize, 20), result.program.len);
    try std.testing.expectEqualSlices(u8, &pkh, result.program);
}

test "encodeP2TR round-trip via bech32m" {
    const allocator = std.testing.allocator;
    const xpk = [_]u8{0xBB} ** 32;
    const addr = try encodeP2TR("ob", xpk, allocator);
    defer allocator.free(addr);

    try std.testing.expect(std.mem.startsWith(u8, addr, "ob1p"));

    const result = try decodeWitnessAddress("ob", addr, allocator);
    defer allocator.free(result.program);
    try std.testing.expectEqual(WITNESS_V1, result.version);
    try std.testing.expectEqualSlices(u8, &xpk, result.program);
}

test "vsize discount: witness < base for same logical TX" {
    // Construim un TX cu un singur input segwit (script_sig empty, witness 1 push de 73 bytes).
    const input = WitnessInput{
        .previous_outpoint = .{ .txid = [_]u8{0} ** 32, .vout = 0 },
        .script_sig = &[_]u8{},
        .sequence = 0xFFFFFFFF,
    };
    const output = TxOutput{ .amount = 1_000_000, .script_pubkey = &[_]u8{ 0, 0x14 } ++ [_]u8{0xAA} ** 20 };
    const sig = [_]u8{0xCC} ** 73;
    const wit_items = [_][]const u8{&sig};
    const witnesses = [_][]const []const u8{&wit_items};

    const tx = WitnessTransaction{
        .version = 2,
        .inputs = &[_]WitnessInput{input},
        .outputs = &[_]TxOutput{output},
        .witnesses = &witnesses,
        .locktime = 0,
    };

    const b = baseSize(&tx);
    const t = totalSize(&tx);
    const v = vsize(&tx);
    try std.testing.expect(t > b); // total > base, exista witness
    try std.testing.expect(v < t); // vsize < total cu discount-ul x4
    try std.testing.expect(v >= b); // dar vsize >= base
}

test "totalSize == baseSize when no witnesses" {
    const input = WitnessInput{
        .previous_outpoint = .{ .txid = [_]u8{0} ** 32, .vout = 0 },
        .script_sig = &[_]u8{0x76},
        .sequence = 0xFFFFFFFF,
    };
    const output = TxOutput{ .amount = 50_000, .script_pubkey = &[_]u8{0x76} };
    const empty: []const []const u8 = &.{};
    const witnesses = [_][]const []const u8{empty};

    const tx = WitnessTransaction{
        .version = 1,
        .inputs = &[_]WitnessInput{input},
        .outputs = &[_]TxOutput{output},
        .witnesses = &witnesses,
        .locktime = 0,
    };

    try std.testing.expectEqual(baseSize(&tx), totalSize(&tx));
    try std.testing.expectEqual(baseSize(&tx), vsize(&tx));
}
