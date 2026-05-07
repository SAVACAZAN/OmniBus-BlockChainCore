const std = @import("std");
const bech32 = @import("bech32.zig");

// ─── Bitcoin HTLC (P2WSH) Builder ────────────────────────────────────────────
//
// Builds canonical Bitcoin HTLC redeem script + P2WSH address for atomic swaps
// with the OmniBus blockchain.
//
// Script layout (BIP-199 style):
//
//   OP_IF
//       OP_SHA256 <hash_lock> OP_EQUALVERIFY
//       <recipient_pubkey> OP_CHECKSIG
//   OP_ELSE
//       <timelock_block> OP_CHECKLOCKTIMEVERIFY OP_DROP
//       <sender_pubkey> OP_CHECKSIG
//   OP_ENDIF
//
// Spending:
//   - Success path  : witness = <sig> <preimage> <01>        <redeem_script>
//   - Refund  path  : witness = <sig>            <>          <redeem_script>
//                     (empty pushdata selects OP_ELSE branch)
//
// This module performs NO broadcasting and NO on-chain validation — it only
// constructs scripts/witnesses. Callers (TS frontend / wallets) sign and
// broadcast externally.

// ─── Bitcoin Script opcodes we use ───────────────────────────────────────────

pub const OP_0:                u8 = 0x00;
pub const OP_1:                u8 = 0x51;
pub const OP_IF:               u8 = 0x63;
pub const OP_ELSE:             u8 = 0x67;
pub const OP_ENDIF:            u8 = 0x68;
pub const OP_DROP:             u8 = 0x75;
pub const OP_EQUALVERIFY:      u8 = 0x88;
pub const OP_SHA256:           u8 = 0xa8;
pub const OP_CHECKSIG:         u8 = 0xac;
pub const OP_CHECKLOCKTIMEVERIFY: u8 = 0xb1;

// ─── Network HRPs ────────────────────────────────────────────────────────────

pub const HRP_MAINNET: []const u8 = "bc";
pub const HRP_TESTNET: []const u8 = "tb";
pub const HRP_REGTEST: []const u8 = "bcrt";
pub const HRP_SIGNET:  []const u8 = "tb"; // signet shares HRP with testnet

pub const Network = enum {
    mainnet,
    testnet,
    regtest,
    signet,

    pub fn hrp(self: Network) []const u8 {
        return switch (self) {
            .mainnet => HRP_MAINNET,
            .testnet => HRP_TESTNET,
            .regtest => HRP_REGTEST,
            .signet  => HRP_SIGNET,
        };
    }

    pub fn fromStr(s: []const u8) ?Network {
        if (std.mem.eql(u8, s, "mainnet")) return .mainnet;
        if (std.mem.eql(u8, s, "testnet")) return .testnet;
        if (std.mem.eql(u8, s, "regtest")) return .regtest;
        if (std.mem.eql(u8, s, "signet"))  return .signet;
        return null;
    }
};

// ─── Script encoding helpers ─────────────────────────────────────────────────

/// Encode a small integer (1..16 → OP_1..OP_16, 0 → OP_0) for CLTV timelock.
/// For values that don't fit a single OP_N, use scriptNum encoding.
fn encodeScriptNum(buf: []u8, n: u32) usize {
    if (n == 0) {
        buf[0] = OP_0;
        return 1;
    }
    if (n <= 16) {
        buf[0] = OP_1 + @as(u8, @intCast(n - 1));
        return 1;
    }
    // CScriptNum little-endian, with sign bit padding.
    // Bitcoin's CScriptNum: encode magnitude little-endian; if MSB of last byte
    // has the sign bit set, append a 0x00 byte (since our values are unsigned).
    var tmp: [5]u8 = undefined;
    var len: usize = 0;
    var v = n;
    while (v != 0) : (v >>= 8) {
        tmp[len] = @intCast(v & 0xff);
        len += 1;
    }
    // Sign-bit padding for unsigned values whose top bit is set.
    if ((tmp[len - 1] & 0x80) != 0) {
        tmp[len] = 0x00;
        len += 1;
    }
    // Prefix with push-length opcode (we know len ∈ 1..5 → fits in OP_PUSHBYTES_N).
    buf[0] = @intCast(len);
    @memcpy(buf[1 .. 1 + len], tmp[0..len]);
    return 1 + len;
}

/// Push raw bytes onto the script. `data.len` must be ≤ 75 (OP_PUSHBYTES_N).
fn pushData(buf: []u8, data: []const u8) usize {
    std.debug.assert(data.len <= 75);
    buf[0] = @intCast(data.len);
    @memcpy(buf[1 .. 1 + data.len], data);
    return 1 + data.len;
}

// ─── Public API ──────────────────────────────────────────────────────────────

/// Maximum witness script size for our HTLC layout.
/// 1 + 1 + 33 (OP_IF/ELSE/ENDIF + push33 pubkey ≤ 35 each) — bounded by
/// fixed shape: ~ 1 (IF) + 1 (SHA256) + 33 (push32 hash) + 1 (EQVERIFY)
///            + 34 (push33 pubkey) + 1 (CHECKSIG) + 1 (ELSE)
///            + 6 (push5 timelock) + 1 (CLTV) + 1 (DROP)
///            + 34 (push33 pubkey) + 1 (CHECKSIG) + 1 (ENDIF) ≈ 117 bytes max.
pub const MAX_REDEEM_SCRIPT_SIZE: usize = 128;

/// Build the canonical HTLC redeem (witness) script.
/// Caller owns the returned slice.
pub fn buildRedeemScript(
    recipient_pk: [33]u8,
    sender_pk: [33]u8,
    hash_lock: [32]u8,
    timelock: u32,
    allocator: std.mem.Allocator,
) ![]u8 {
    var buf: [MAX_REDEEM_SCRIPT_SIZE]u8 = undefined;
    var i: usize = 0;

    // OP_IF
    buf[i] = OP_IF; i += 1;
    //   OP_SHA256
    buf[i] = OP_SHA256; i += 1;
    //   <hash_lock>  (push 32 bytes)
    i += pushData(buf[i..], &hash_lock);
    //   OP_EQUALVERIFY
    buf[i] = OP_EQUALVERIFY; i += 1;
    //   <recipient_pubkey>  (push 33 bytes)
    i += pushData(buf[i..], &recipient_pk);
    //   OP_CHECKSIG
    buf[i] = OP_CHECKSIG; i += 1;

    // OP_ELSE
    buf[i] = OP_ELSE; i += 1;
    //   <timelock>
    i += encodeScriptNum(buf[i..], timelock);
    //   OP_CHECKLOCKTIMEVERIFY
    buf[i] = OP_CHECKLOCKTIMEVERIFY; i += 1;
    //   OP_DROP
    buf[i] = OP_DROP; i += 1;
    //   <sender_pubkey>
    i += pushData(buf[i..], &sender_pk);
    //   OP_CHECKSIG
    buf[i] = OP_CHECKSIG; i += 1;

    // OP_ENDIF
    buf[i] = OP_ENDIF; i += 1;

    const out = try allocator.alloc(u8, i);
    @memcpy(out, buf[0..i]);
    return out;
}

/// Convert a witness script to its 22-byte P2WSH `scriptPubKey` payload:
/// `OP_0 <0x20> <sha256(script)>` — i.e. witness program v0 + 32-byte hash.
/// This is the on-chain output script; the bech32 address encodes the
/// witness program (the 32-byte hash) without the leading `OP_0 0x20`.
pub fn scriptToP2WSH(script: []const u8) [34]u8 {
    var out: [34]u8 = undefined;
    out[0] = OP_0;       // witness version 0
    out[1] = 0x20;       // push 32 bytes
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &hash, .{});
    @memcpy(out[2..34], &hash);
    return out;
}

/// Compute SHA256(script) — the 32-byte witness program for a P2WSH output.
pub fn witnessProgram(script: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &hash, .{});
    return hash;
}

/// Encode a P2WSH bech32 address for the given network from a redeem script.
/// Caller owns the returned slice.
pub fn addressFromScript(
    script: []const u8,
    network: Network,
    allocator: std.mem.Allocator,
) ![]u8 {
    const wp = witnessProgram(script);
    return bech32.encodeWitnessAddress(network.hrp(), 0, &wp, allocator);
}

/// One-shot helper: derive bech32 P2WSH address from HTLC parameters.
pub fn deriveHtlcAddress(
    recipient_pk: [33]u8,
    sender_pk: [33]u8,
    hash_lock: [32]u8,
    timelock: u32,
    network: Network,
    allocator: std.mem.Allocator,
) !struct { redeem_script: []u8, address: []u8 } {
    const script = try buildRedeemScript(recipient_pk, sender_pk, hash_lock, timelock, allocator);
    errdefer allocator.free(script);
    const addr = try addressFromScript(script, network, allocator);
    return .{ .redeem_script = script, .address = addr };
}

// ─── Witness construction ────────────────────────────────────────────────────

/// Serialize a witness stack as a Bitcoin segwit witness field:
/// `<varint num_items> ( <varint item_len> <item_bytes> ) ...`
fn serializeWitness(items: []const []const u8, allocator: std.mem.Allocator) ![]u8 {
    var total: usize = varintLen(items.len);
    for (items) |it| total += varintLen(it.len) + it.len;
    var out = try allocator.alloc(u8, total);
    var i: usize = 0;
    i += writeVarint(out[i..], items.len);
    for (items) |it| {
        i += writeVarint(out[i..], it.len);
        @memcpy(out[i .. i + it.len], it);
        i += it.len;
    }
    std.debug.assert(i == total);
    return out;
}

fn varintLen(n: usize) usize {
    if (n < 0xfd) return 1;
    if (n <= 0xffff) return 3;
    if (n <= 0xffffffff) return 5;
    return 9;
}

fn writeVarint(buf: []u8, n: usize) usize {
    if (n < 0xfd) {
        buf[0] = @intCast(n);
        return 1;
    }
    if (n <= 0xffff) {
        buf[0] = 0xfd;
        std.mem.writeInt(u16, buf[1..3], @intCast(n), .little);
        return 3;
    }
    if (n <= 0xffffffff) {
        buf[0] = 0xfe;
        std.mem.writeInt(u32, buf[1..5], @intCast(n), .little);
        return 5;
    }
    buf[0] = 0xff;
    std.mem.writeInt(u64, buf[1..9], @intCast(n), .little);
    return 9;
}

/// Build the witness stack for the SUCCESS path (recipient redeems with preimage).
///
/// Stack (bottom to top, as Bitcoin pops top first):
///   [ <sig>, <preimage>, <01>, <redeem_script> ]
///
/// The trailing `<01>` (a non-empty push) selects the OP_IF branch.
/// `sig` is expected to be a DER-encoded signature with sighash byte appended
/// (typical 71-73 bytes). For simplicity we accept a 64-byte schnorr-style sig
/// here — callers must wrap it as the wallet expects (Bitcoin Core uses ECDSA
/// DER + sighash, so callers using DER signatures should construct the witness
/// directly via `serializeWitnessItems`).
pub fn buildClaimWitness(
    sig: []const u8,
    preimage: [32]u8,
    redeem_script: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const branch_selector: [1]u8 = .{0x01};
    const items = [_][]const u8{
        sig,
        &preimage,
        &branch_selector,
        redeem_script,
    };
    return serializeWitness(&items, allocator);
}

/// Build the witness stack for the REFUND path (sender reclaims after timeout).
///
/// Stack:
///   [ <sig>, <> (empty), <redeem_script> ]
///
/// The empty push selects the OP_ELSE branch. The spending TX must set
/// `nLockTime ≥ timelock` and the input's `nSequence < 0xffffffff` for CLTV
/// to validate — that is the caller's responsibility.
pub fn buildRefundWitness(
    sig: []const u8,
    redeem_script: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const empty: [0]u8 = .{};
    const items = [_][]const u8{
        sig,
        &empty,
        redeem_script,
    };
    return serializeWitness(&items, allocator);
}

/// Lower-level: serialize an arbitrary witness stack. Useful when the caller
/// already has a DER+sighash ECDSA signature of arbitrary length.
pub fn serializeWitnessItems(items: []const []const u8, allocator: std.mem.Allocator) ![]u8 {
    return serializeWitness(items, allocator);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "htlc_btc — redeem script structure" {
    const allocator = std.testing.allocator;

    var recipient_pk: [33]u8 = undefined;
    var sender_pk:    [33]u8 = undefined;
    var hash_lock:    [32]u8 = undefined;
    @memset(&recipient_pk, 0x02); recipient_pk[0] = 0x02;
    @memset(&sender_pk,    0x03); sender_pk[0]    = 0x03;
    @memset(&hash_lock,    0xab);

    const script = try buildRedeemScript(recipient_pk, sender_pk, hash_lock, 500_000, allocator);
    defer allocator.free(script);

    // Minimum sanity: must contain the structural opcodes in order.
    try std.testing.expectEqual(OP_IF,           script[0]);
    try std.testing.expectEqual(OP_SHA256,       script[1]);
    try std.testing.expectEqual(@as(u8, 0x20),   script[2]); // push 32 bytes
    // Hash bytes follow at script[3..35]
    try std.testing.expectEqualSlices(u8, &hash_lock, script[3..35]);
    try std.testing.expectEqual(OP_EQUALVERIFY,  script[35]);
    try std.testing.expectEqual(@as(u8, 0x21),   script[36]); // push 33 bytes
    try std.testing.expectEqualSlices(u8, &recipient_pk, script[37..70]);
    try std.testing.expectEqual(OP_CHECKSIG,     script[70]);
    try std.testing.expectEqual(OP_ELSE,         script[71]);
    // Timelock 500000 = 0x07a120 → CScriptNum (no sign-bit pad needed: 0x20 < 0x80)
    try std.testing.expectEqual(@as(u8, 0x03),   script[72]); // push 3 bytes
    try std.testing.expectEqual(@as(u8, 0x20),   script[73]);
    try std.testing.expectEqual(@as(u8, 0xa1),   script[74]);
    try std.testing.expectEqual(@as(u8, 0x07),   script[75]);
    try std.testing.expectEqual(OP_CHECKLOCKTIMEVERIFY, script[76]);
    try std.testing.expectEqual(OP_DROP,         script[77]);
    try std.testing.expectEqual(@as(u8, 0x21),   script[78]); // push 33 bytes
    try std.testing.expectEqualSlices(u8, &sender_pk, script[79..112]);
    try std.testing.expectEqual(OP_CHECKSIG,     script[112]);
    try std.testing.expectEqual(OP_ENDIF,        script[113]);
    try std.testing.expectEqual(@as(usize, 114), script.len);
}

test "htlc_btc — P2WSH derivation matches sha256(script)" {
    const allocator = std.testing.allocator;

    var recipient_pk: [33]u8 = undefined;
    var sender_pk:    [33]u8 = undefined;
    var hash_lock:    [32]u8 = undefined;
    @memset(&recipient_pk, 0x02);
    @memset(&sender_pk,    0x03);
    @memset(&hash_lock,    0xcd);

    const script = try buildRedeemScript(recipient_pk, sender_pk, hash_lock, 100, allocator);
    defer allocator.free(script);

    const p2wsh = scriptToP2WSH(script);
    try std.testing.expectEqual(OP_0,           p2wsh[0]);
    try std.testing.expectEqual(@as(u8, 0x20),  p2wsh[1]);

    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(script, &expected_hash, .{});
    try std.testing.expectEqualSlices(u8, &expected_hash, p2wsh[2..34]);
}

test "htlc_btc — mainnet vs testnet HRP encoding" {
    const allocator = std.testing.allocator;

    var recipient_pk: [33]u8 = undefined;
    var sender_pk:    [33]u8 = undefined;
    var hash_lock:    [32]u8 = undefined;
    @memset(&recipient_pk, 0x02);
    @memset(&sender_pk,    0x03);
    @memset(&hash_lock,    0xee);

    const script = try buildRedeemScript(recipient_pk, sender_pk, hash_lock, 1234, allocator);
    defer allocator.free(script);

    const mainnet_addr = try addressFromScript(script, .mainnet, allocator);
    defer allocator.free(mainnet_addr);
    const testnet_addr = try addressFromScript(script, .testnet, allocator);
    defer allocator.free(testnet_addr);
    const regtest_addr = try addressFromScript(script, .regtest, allocator);
    defer allocator.free(regtest_addr);

    try std.testing.expect(std.mem.startsWith(u8, mainnet_addr, "bc1q"));
    try std.testing.expect(std.mem.startsWith(u8, testnet_addr, "tb1q"));
    try std.testing.expect(std.mem.startsWith(u8, regtest_addr, "bcrt1q"));

    // P2WSH addresses are 62 chars (mainnet/testnet) — `<hrp>1` + 1 char ver + 52 char data + 6 char checksum.
    try std.testing.expectEqual(@as(usize, 62), mainnet_addr.len);
    try std.testing.expectEqual(@as(usize, 62), testnet_addr.len);
    // bcrt is 4-char HRP → 64 chars total
    try std.testing.expectEqual(@as(usize, 64), regtest_addr.len);
}

test "htlc_btc — claim witness shape" {
    const allocator = std.testing.allocator;

    var recipient_pk: [33]u8 = undefined;
    var sender_pk:    [33]u8 = undefined;
    var hash_lock:    [32]u8 = undefined;
    @memset(&recipient_pk, 0x02);
    @memset(&sender_pk,    0x03);
    @memset(&hash_lock,    0x77);

    const script = try buildRedeemScript(recipient_pk, sender_pk, hash_lock, 42, allocator);
    defer allocator.free(script);

    var sig: [72]u8 = undefined;
    @memset(&sig, 0x30);
    var preimage: [32]u8 = undefined;
    @memset(&preimage, 0x55);

    const witness = try buildClaimWitness(&sig, preimage, script, allocator);
    defer allocator.free(witness);

    // First byte = varint num_items = 4 (sig, preimage, branch-selector, script)
    try std.testing.expectEqual(@as(u8, 0x04), witness[0]);
    // Then push <72> <sig...>
    try std.testing.expectEqual(@as(u8, 72),   witness[1]);
    try std.testing.expectEqualSlices(u8, &sig, witness[2..74]);
    // Then push <32> <preimage...>
    try std.testing.expectEqual(@as(u8, 32),   witness[74]);
    try std.testing.expectEqualSlices(u8, &preimage, witness[75..107]);
    // Branch selector: push <1> <0x01>
    try std.testing.expectEqual(@as(u8, 1),    witness[107]);
    try std.testing.expectEqual(@as(u8, 0x01), witness[108]);
    // Script: push <script.len> <script...>
    try std.testing.expectEqual(@as(u8, @intCast(script.len)), witness[109]);
    try std.testing.expectEqualSlices(u8, script, witness[110 .. 110 + script.len]);
}

test "htlc_btc — refund witness shape" {
    const allocator = std.testing.allocator;

    var recipient_pk: [33]u8 = undefined;
    var sender_pk:    [33]u8 = undefined;
    var hash_lock:    [32]u8 = undefined;
    @memset(&recipient_pk, 0x02);
    @memset(&sender_pk,    0x03);
    @memset(&hash_lock,    0x99);

    const script = try buildRedeemScript(recipient_pk, sender_pk, hash_lock, 999, allocator);
    defer allocator.free(script);

    var sig: [71]u8 = undefined;
    @memset(&sig, 0x30);

    const witness = try buildRefundWitness(&sig, script, allocator);
    defer allocator.free(witness);

    // num_items = 3 (sig, empty, script)
    try std.testing.expectEqual(@as(u8, 0x03), witness[0]);
    // sig push
    try std.testing.expectEqual(@as(u8, 71),   witness[1]);
    try std.testing.expectEqualSlices(u8, &sig, witness[2..73]);
    // Empty pushdata: 0-length item — single varint 0x00
    try std.testing.expectEqual(@as(u8, 0x00), witness[73]);
    // Script push
    try std.testing.expectEqual(@as(u8, @intCast(script.len)), witness[74]);
    try std.testing.expectEqualSlices(u8, script, witness[75 .. 75 + script.len]);
}

test "htlc_btc — deterministic + roundtrip via deriveHtlcAddress" {
    const allocator = std.testing.allocator;

    var recipient_pk: [33]u8 = undefined;
    var sender_pk:    [33]u8 = undefined;
    var hash_lock:    [32]u8 = undefined;
    @memset(&recipient_pk, 0x02);
    @memset(&sender_pk,    0x03);
    @memset(&hash_lock,    0x11);

    const r1 = try deriveHtlcAddress(recipient_pk, sender_pk, hash_lock, 1000, .testnet, allocator);
    defer allocator.free(r1.redeem_script);
    defer allocator.free(r1.address);

    const r2 = try deriveHtlcAddress(recipient_pk, sender_pk, hash_lock, 1000, .testnet, allocator);
    defer allocator.free(r2.redeem_script);
    defer allocator.free(r2.address);

    try std.testing.expectEqualSlices(u8, r1.redeem_script, r2.redeem_script);
    try std.testing.expectEqualStrings(r1.address, r2.address);

    // Address must round-trip through bech32 decoder back to the same 32-byte program.
    const decoded = try bech32.decodeWitnessAddress("tb", r1.address, allocator);
    defer allocator.free(decoded.program);
    try std.testing.expectEqual(@as(u5, 0), decoded.version);
    try std.testing.expectEqual(@as(usize, 32), decoded.program.len);

    const expected_program = witnessProgram(r1.redeem_script);
    try std.testing.expectEqualSlices(u8, &expected_program, decoded.program);
}

test "htlc_btc — scriptNum encoding for small and large timelocks" {
    const allocator = std.testing.allocator;

    var recipient_pk: [33]u8 = undefined;
    var sender_pk:    [33]u8 = undefined;
    var hash_lock:    [32]u8 = undefined;
    @memset(&recipient_pk, 0x02);
    @memset(&sender_pk,    0x03);
    @memset(&hash_lock,    0xab);

    // timelock = 5 → encoded as OP_5 (single byte 0x55), not push.
    const s_small = try buildRedeemScript(recipient_pk, sender_pk, hash_lock, 5, allocator);
    defer allocator.free(s_small);
    // After OP_ELSE at index 71, next byte must be OP_5 = 0x55.
    try std.testing.expectEqual(@as(u8, 0x55), s_small[72]);
    try std.testing.expectEqual(OP_CHECKLOCKTIMEVERIFY, s_small[73]);

    // timelock = 0x80 → needs sign-bit pad: push 2 bytes <0x80, 0x00>.
    const s_pad = try buildRedeemScript(recipient_pk, sender_pk, hash_lock, 0x80, allocator);
    defer allocator.free(s_pad);
    try std.testing.expectEqual(@as(u8, 0x02), s_pad[72]); // push 2
    try std.testing.expectEqual(@as(u8, 0x80), s_pad[73]);
    try std.testing.expectEqual(@as(u8, 0x00), s_pad[74]);
    try std.testing.expectEqual(OP_CHECKLOCKTIMEVERIFY, s_pad[75]);
}
