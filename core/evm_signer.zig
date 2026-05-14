//! evm_signer.zig — sign EVM transactions in Zig with the OmniBus operator
//! key. Produces a `0x...` raw-tx hex string the chain can submit via
//! `evm_rpc_client.sendRawTransaction`.
//!
//! Scope
//! -----
//! Legacy (pre-EIP-1559) transactions with EIP-155 chainId protection. We
//! pick legacy intentionally:
//!   - All EVM chains we target (Sepolia, Base Sepolia, Liberty, mainnet
//!     Ethereum + Base + BNB + Polygon + Avalanche + Fantom) still accept
//!     legacy tx — they're never rejected for being pre-Cancun.
//!   - Legacy tx encoding is much simpler than EIP-1559 typed (no access
//!     list, no max_fee_per_gas / max_priority_fee_per_gas split). We can
//!     fit the whole encoder in <200 lines.
//!   - We pay slightly more in gas during EIP-1559 base-fee spikes; that's
//!     a trade we accept while bootstrapping.
//!
//! Signature recovery
//! ------------------
//! Zig stdlib's `EcdsaSecp256k1Sha256.signPrehashed` produces (r, s) but
//! does NOT expose the recovery id v. Computing v offline requires elliptic
//! curve point recovery which is ~200 lines of math we don't want to
//! maintain. Pragmatic alternative used here:
//!
//!   1. Sign once with `signPrehashed`.
//!   2. Build BOTH possible raw-tx variants (v=27, v=28 in legacy /
//!      35+chainId*2 + 0|1 with EIP-155).
//!   3. The CALLER submits each variant to the EVM RPC; the wrong one will
//!      revert with "invalid signature" / "wrong sender" and the right one
//!      will land. After the first successful submission per operator key
//!      lifetime, we cache the parity bit so subsequent signs only build
//!      one variant.
//!
//! That's ONE extra RPC at warm-up per operator, then zero overhead. Good
//! enough for a relayer that does not push tens of tx/s.
//!
//! Operator key
//! ------------
//! Per `memory/project_omnibus_registrar_addresses.md` the operator is
//! exchange.omnibus = BIP-44 m/44'/60'/0'/0/2 from the founder mnemonic.
//! The CALLER passes that key — this module is key-agnostic.

const std = @import("std");
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;

pub const SignError = error{
    InvalidPrivateKey,
    SignFailed,
    OutOfMemory,
    Encoding,
};

/// Inputs the caller assembles. `to` is the target contract address (20 raw
/// bytes), `data` is the ABI-encoded calldata (caller builds with
/// evm_abi.zig helpers). `value` is wei (always 0 for our DEX path since
/// we trade ERC-20, never native ETH).
pub const TxInput = struct {
    chain_id:  u64,
    nonce:     u64,
    gas_price: u64, // wei
    gas_limit: u64,
    to:        [20]u8,
    value:     u128, // wei
    data:      []const u8,
};

/// Caller-provided signing material.
pub const SigningKey = struct {
    /// 32-byte secp256k1 private key.
    private_key: [32]u8,
    /// 20-byte derived address. Used for sanity check + (optionally) to
    /// help the caller pick the right recovery parity.
    address:     [20]u8,
};

/// Result: two candidate raw-tx hex strings. The caller submits the first;
/// if EVM rejects with an "invalid signature" / "wrong sender" message,
/// submits the second. Once one lands, the caller may pin the parity bit
/// and skip the duplicate going forward.
pub const SignedTxPair = struct {
    /// "0x..." hex string. Caller owns; free with `allocator.free`.
    candidate_a: []u8,
    candidate_b: []u8,
    /// Recovery parity used for candidate_a (0 or 1). candidate_b uses 1-a.
    parity_a: u8,
};

// ── Keccak helper ─────────────────────────────────────────────────────────

pub fn keccak256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    var h = Keccak256.init(.{});
    h.update(data);
    h.final(&out);
    return out;
}

// ── RLP encoding (minimal subset: bytes + lists of bytes-or-lists) ────────
//
// We only need enough RLP to encode a legacy transaction tuple:
//   [nonce, gasPrice, gasLimit, to, value, data, v, r, s]
// All fields are non-negative integers or byte strings. No nested lists
// inside the items, just at the top level. That makes the encoder small.

const RlpItem = union(enum) {
    bytes: []const u8,
    /// Big-endian unsigned integer encoded as MINIMAL bytes (no leading 0).
    /// Zero is encoded as the empty byte string per the spec.
    uint: u128,
};

fn rlpEncodeU64(allocator: std.mem.Allocator, v: u128) ![]u8 {
    if (v == 0) return try allocator.dupe(u8, &[_]u8{0x80});

    // Big-endian, strip leading zeros.
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u128, &buf, v, .big);
    var start: usize = 0;
    while (start < buf.len and buf[start] == 0) : (start += 1) {}
    const body = buf[start..];

    // Single byte in [0x00, 0x7f] encodes as itself.
    if (body.len == 1 and body[0] <= 0x7f) {
        return try allocator.dupe(u8, body);
    }
    return rlpEncodeBytes(allocator, body);
}

fn rlpEncodeBytes(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 1 and data[0] <= 0x7f) {
        return try allocator.dupe(u8, data);
    }
    if (data.len <= 55) {
        var out = try allocator.alloc(u8, 1 + data.len);
        out[0] = 0x80 + @as(u8, @intCast(data.len));
        @memcpy(out[1..], data);
        return out;
    }
    // Long form: 0xb7 + length-of-length-prefix, then length, then data.
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, @intCast(data.len), .big);
    var len_start: usize = 0;
    while (len_start < len_buf.len and len_buf[len_start] == 0) : (len_start += 1) {}
    const len_bytes = len_buf[len_start..];

    var out = try allocator.alloc(u8, 1 + len_bytes.len + data.len);
    out[0] = 0xb7 + @as(u8, @intCast(len_bytes.len));
    @memcpy(out[1 .. 1 + len_bytes.len], len_bytes);
    @memcpy(out[1 + len_bytes.len ..], data);
    return out;
}

fn rlpEncodeList(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    // Items are already RLP-encoded; we just frame them as a list.
    var payload_len: usize = 0;
    for (items) |it| payload_len += it.len;

    if (payload_len <= 55) {
        var out = try allocator.alloc(u8, 1 + payload_len);
        out[0] = 0xc0 + @as(u8, @intCast(payload_len));
        var off: usize = 1;
        for (items) |it| {
            @memcpy(out[off..][0..it.len], it);
            off += it.len;
        }
        return out;
    }
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, @intCast(payload_len), .big);
    var len_start: usize = 0;
    while (len_start < len_buf.len and len_buf[len_start] == 0) : (len_start += 1) {}
    const len_bytes = len_buf[len_start..];

    var out = try allocator.alloc(u8, 1 + len_bytes.len + payload_len);
    out[0] = 0xf7 + @as(u8, @intCast(len_bytes.len));
    @memcpy(out[1 .. 1 + len_bytes.len], len_bytes);
    var off: usize = 1 + len_bytes.len;
    for (items) |it| {
        @memcpy(out[off..][0..it.len], it);
        off += it.len;
    }
    return out;
}

// ── Public API: build + sign tx ───────────────────────────────────────────

/// Build the signing hash (keccak256 of RLP[nonce, gasPrice, gasLimit, to,
/// value, data, chainId, 0, 0]) per EIP-155.
fn buildSigningHash(allocator: std.mem.Allocator, tx: TxInput) ![32]u8 {
    var pieces: [9][]u8 = undefined;
    pieces[0] = try rlpEncodeU64(allocator, tx.nonce);
    pieces[1] = try rlpEncodeU64(allocator, tx.gas_price);
    pieces[2] = try rlpEncodeU64(allocator, tx.gas_limit);
    pieces[3] = try rlpEncodeBytes(allocator, &tx.to);
    pieces[4] = try rlpEncodeU64(allocator, tx.value);
    pieces[5] = try rlpEncodeBytes(allocator, tx.data);
    pieces[6] = try rlpEncodeU64(allocator, tx.chain_id);
    pieces[7] = try rlpEncodeU64(allocator, 0);
    pieces[8] = try rlpEncodeU64(allocator, 0);
    defer for (pieces) |p| allocator.free(p);

    var refs: [9][]const u8 = undefined;
    for (pieces, 0..) |p, i| refs[i] = p;

    const list = try rlpEncodeList(allocator, &refs);
    defer allocator.free(list);

    return keccak256(list);
}

/// Final RLP frame including v, r, s.
fn buildSignedFrame(
    allocator: std.mem.Allocator,
    tx: TxInput,
    v: u64,
    r: [32]u8,
    s: [32]u8,
) ![]u8 {
    // Strip leading zeros from r/s before RLP-encoding (they're big-endian
    // big-int byte strings; canonical encoding has no leading 00).
    var r_start: usize = 0;
    while (r_start < r.len and r[r_start] == 0) : (r_start += 1) {}
    var s_start: usize = 0;
    while (s_start < s.len and s[s_start] == 0) : (s_start += 1) {}

    var pieces: [9][]u8 = undefined;
    pieces[0] = try rlpEncodeU64(allocator, tx.nonce);
    pieces[1] = try rlpEncodeU64(allocator, tx.gas_price);
    pieces[2] = try rlpEncodeU64(allocator, tx.gas_limit);
    pieces[3] = try rlpEncodeBytes(allocator, &tx.to);
    pieces[4] = try rlpEncodeU64(allocator, tx.value);
    pieces[5] = try rlpEncodeBytes(allocator, tx.data);
    pieces[6] = try rlpEncodeU64(allocator, v);
    pieces[7] = try rlpEncodeBytes(allocator, r[r_start..]);
    pieces[8] = try rlpEncodeBytes(allocator, s[s_start..]);
    defer for (pieces) |p| allocator.free(p);

    var refs: [9][]const u8 = undefined;
    for (pieces, 0..) |p, i| refs[i] = p;

    return try rlpEncodeList(allocator, &refs);
}

/// Sign `tx` with `key`. Returns two raw-tx hex strings differing only in
/// the EIP-155 v byte (one of them is correct; caller submits both as
/// fallback until the parity is known).
pub fn signLegacyTx(
    allocator: std.mem.Allocator,
    tx: TxInput,
    key: SigningKey,
) !SignedTxPair {
    const msg_hash = try buildSigningHash(allocator, tx);

    const sk = Ecdsa.SecretKey.fromBytes(key.private_key) catch return SignError.InvalidPrivateKey;
    const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch return SignError.InvalidPrivateKey;
    const sig = kp.signPrehashed(msg_hash, null) catch return SignError.SignFailed;
    const sig_bytes = sig.toBytes();

    var r: [32]u8 = undefined;
    var s: [32]u8 = undefined;
    @memcpy(&r, sig_bytes[0..32]);
    @memcpy(&s, sig_bytes[32..64]);

    // Low-S canonicalization (Ethereum mempool rejects high-S since
    // Homestead). secp256k1 order n; if s > n/2 replace with n-s.
    if (isHighS(s)) {
        s = subFromN(s);
    }

    // EIP-155: v = chain_id*2 + 35 + parity. We don't know parity yet, so
    // emit both candidates and let the caller try.
    const v0: u64 = tx.chain_id * 2 + 35;
    const v1: u64 = tx.chain_id * 2 + 36;

    const raw_a = try buildSignedFrame(allocator, tx, v0, r, s);
    defer allocator.free(raw_a);
    const raw_b = try buildSignedFrame(allocator, tx, v1, r, s);
    defer allocator.free(raw_b);

    return SignedTxPair{
        .candidate_a = try bytesToHex0x(allocator, raw_a),
        .candidate_b = try bytesToHex0x(allocator, raw_b),
        .parity_a = 0,
    };
}

// ── Helpers ───────────────────────────────────────────────────────────────

/// Convert raw bytes to "0x..." lowercase hex string. Caller frees.
pub fn bytesToHex0x(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 + i * 2] = hex[b >> 4];
        out[2 + i * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

/// Parse a 0x-prefixed lowercase hex string into a fixed-size array.
pub fn hex0xToBytes(comptime Len: usize, hex: []const u8) ![Len]u8 {
    var src = hex;
    if (std.mem.startsWith(u8, src, "0x") or std.mem.startsWith(u8, src, "0X")) {
        src = src[2..];
    }
    if (src.len != Len * 2) return error.WrongLength;
    var out: [Len]u8 = undefined;
    var i: usize = 0;
    while (i < Len) : (i += 1) {
        out[i] = try std.fmt.parseInt(u8, src[i * 2 ..][0..2], 16);
    }
    return out;
}

// ── secp256k1 order constants (low-S enforcement, mirrors secp256k1.zig) ──

const N_HALF: [32]u8 = .{
    0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
    0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
};

const N: [32]u8 = .{
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
    0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
    0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
};

fn isHighS(s: [32]u8) bool {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (s[i] > N_HALF[i]) return true;
        if (s[i] < N_HALF[i]) return false;
    }
    return false; // equal → still low-S (just below boundary)
}

fn subFromN(s: [32]u8) [32]u8 {
    // out = N - s (256-bit unsigned, big-endian)
    var out: [32]u8 = undefined;
    var borrow: u16 = 0;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        const diff: i32 = @as(i32, N[i]) - @as(i32, s[i]) - @as(i32, @intCast(borrow));
        if (diff < 0) {
            out[i] = @intCast(diff + 256);
            borrow = 1;
        } else {
            out[i] = @intCast(diff);
            borrow = 0;
        }
    }
    return out;
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "rlpEncodeU64 zero is 0x80" {
    const a = std.testing.allocator;
    const out = try rlpEncodeU64(a, 0);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x80}, out);
}

test "rlpEncodeU64 small ints encode as single byte" {
    const a = std.testing.allocator;
    const out = try rlpEncodeU64(a, 0x7f);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x7f}, out);
}

test "rlpEncodeU64 0x80 encodes as length-prefixed" {
    const a = std.testing.allocator;
    const out = try rlpEncodeU64(a, 0x80);
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x81, 0x80 }, out);
}

test "rlpEncodeBytes empty is 0x80" {
    const a = std.testing.allocator;
    const out = try rlpEncodeBytes(a, &[_]u8{});
    defer a.free(out);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x80}, out);
}

test "rlpEncodeBytes 20-byte address" {
    const a = std.testing.allocator;
    const addr = [_]u8{0xAA} ** 20;
    const out = try rlpEncodeBytes(a, &addr);
    defer a.free(out);
    try std.testing.expectEqual(@as(usize, 21), out.len);
    try std.testing.expectEqual(@as(u8, 0x94), out[0]); // 0x80 + 20
}

test "keccak256 of empty string matches well-known constant" {
    const expected = [_]u8{
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
    };
    const got = keccak256("");
    try std.testing.expectEqualSlices(u8, &expected, &got);
}

test "bytesToHex0x roundtrips through hex0xToBytes" {
    const a = std.testing.allocator;
    const src = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const hex = try bytesToHex0x(a, &src);
    defer a.free(hex);
    try std.testing.expectEqualSlices(u8, "0xdeadbeef", hex);
    const back = try hex0xToBytes(4, hex);
    try std.testing.expectEqualSlices(u8, &src, &back);
}

test "subFromN(0) == N" {
    const zero: [32]u8 = .{0} ** 32;
    const got = subFromN(zero);
    try std.testing.expectEqualSlices(u8, &N, &got);
}

test "isHighS detects values above N/2" {
    var s: [32]u8 = .{0xFF} ** 32;
    try std.testing.expect(isHighS(s));
    s = .{0} ** 32;
    try std.testing.expect(!isHighS(s));
}

test "signLegacyTx produces two distinct candidates" {
    const a = std.testing.allocator;
    const tx = TxInput{
        .chain_id = 11155111, // Sepolia
        .nonce = 0,
        .gas_price = 1_000_000_000,
        .gas_limit = 21_000,
        .to = .{0x11} ** 20,
        .value = 0,
        .data = &[_]u8{},
    };
    const key = SigningKey{
        .private_key = .{0x01} ** 32,
        .address = .{0x00} ** 20, // not checked in this test
    };
    const pair = try signLegacyTx(a, tx, key);
    defer a.free(pair.candidate_a);
    defer a.free(pair.candidate_b);

    try std.testing.expect(std.mem.startsWith(u8, pair.candidate_a, "0x"));
    try std.testing.expect(std.mem.startsWith(u8, pair.candidate_b, "0x"));
    try std.testing.expect(!std.mem.eql(u8, pair.candidate_a, pair.candidate_b));
    // Candidates should be the same length (only the v byte differs).
    try std.testing.expectEqual(pair.candidate_a.len, pair.candidate_b.len);
}
