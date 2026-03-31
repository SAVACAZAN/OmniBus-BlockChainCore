const std = @import("std");

// ─── Bech32 / Bech32m Encoder & Decoder (BIP-173 + BIP-350) ─────────────────
//
// HRP pentru OmniBus: "ob"
// Witness version 0  → Bech32  (ob1q...)  — P2WPKH / P2WSH
// Witness version 1+ → Bech32m (ob1p...)  — Taproot / viitoare versiuni
//
// Format: <hrp> "1" <data characters> <6 char checksum>
//   - data[0] = witness version (0..16)
//   - data[1..] = witness program (hash160 sau hash256) convertit în 5-bit groups

pub const Encoding = enum {
    bech32,
    bech32m,
};

/// Constantele checksum conform BIP-173 / BIP-350
const BECH32_CONST: u32 = 1;
const BECH32M_CONST: u32 = 0x2bc830a3;

const CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

const CHARSET_REV = blk: {
    var table: [128]i8 = .{-1} ** 128;
    for (CHARSET, 0..) |c, i| {
        table[c] = @intCast(i);
    }
    break :blk table;
};

const GEN = [5]u32{ 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };

fn polymod(values: []const u5) u32 {
    var chk: u32 = 1;
    for (values) |v| {
        const b = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ @as(u32, v);
        inline for (0..5) |i| {
            if ((b >> @intCast(i)) & 1 != 0) {
                chk ^= GEN[i];
            }
        }
    }
    return chk;
}

/// Expand HRP for checksum computation: [high bits] ++ [0] ++ [low bits]
fn hrpExpand(hrp: []const u8, allocator: std.mem.Allocator) ![]u5 {
    var result = try allocator.alloc(u5, hrp.len * 2 + 1);
    for (hrp, 0..) |c, i| {
        result[i] = @truncate(c >> 5);
    }
    result[hrp.len] = 0;
    for (hrp, 0..) |c, i| {
        result[hrp.len + 1 + i] = @truncate(c & 0x1f);
    }
    return result;
}

// u5 is a Zig primitive type — no alias needed

fn verifyChecksum(hrp: []const u8, data: []const u5, allocator: std.mem.Allocator) !?Encoding {
    const hrp_exp = try hrpExpand(hrp, allocator);
    defer allocator.free(hrp_exp);

    var combined = try allocator.alloc(u5, hrp_exp.len + data.len);
    defer allocator.free(combined);
    @memcpy(combined[0..hrp_exp.len], hrp_exp);
    @memcpy(combined[hrp_exp.len..], data);

    const p = polymod(combined);
    if (p == BECH32_CONST) return .bech32;
    if (p == BECH32M_CONST) return .bech32m;
    return null;
}

fn createChecksum(hrp: []const u8, data: []const u5, encoding: Encoding, allocator: std.mem.Allocator) ![6]u5 {
    const hrp_exp = try hrpExpand(hrp, allocator);
    defer allocator.free(hrp_exp);

    var values = try allocator.alloc(u5, hrp_exp.len + data.len + 6);
    defer allocator.free(values);
    @memcpy(values[0..hrp_exp.len], hrp_exp);
    @memcpy(values[hrp_exp.len .. hrp_exp.len + data.len], data);
    @memset(values[hrp_exp.len + data.len ..], 0);

    const target: u32 = switch (encoding) {
        .bech32 => BECH32_CONST,
        .bech32m => BECH32M_CONST,
    };
    const p = polymod(values) ^ target;

    var result: [6]u5 = undefined;
    inline for (0..6) |i| {
        result[i] = @truncate((p >> @intCast(5 * (5 - i))) & 31);
    }
    return result;
}

// ─── Public API ──────────────────────────────────────────────────────────────

/// Encode raw 5-bit data with HRP into a bech32/bech32m string.
/// Low-level — most callers should use `encodeWitnessAddress` instead.
pub fn encode(hrp: []const u8, data: []const u5, encoding: Encoding, allocator: std.mem.Allocator) ![]u8 {
    const checksum = try createChecksum(hrp, data, encoding, allocator);
    const total_len = hrp.len + 1 + data.len + 6;
    var result = try allocator.alloc(u8, total_len);

    // HRP (lowercase)
    for (hrp, 0..) |c, i| {
        result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    result[hrp.len] = '1'; // separator

    // Data characters
    for (data, 0..) |d, i| {
        result[hrp.len + 1 + i] = CHARSET[d];
    }
    // Checksum
    for (checksum, 0..) |d, i| {
        result[hrp.len + 1 + data.len + i] = CHARSET[d];
    }

    return result;
}

/// Decode a bech32/bech32m string → (hrp, 5-bit data, encoding).
/// Caller owns the returned slices.
pub fn decode(input: []const u8, allocator: std.mem.Allocator) !struct { hrp: []u8, data: []u5, encoding: Encoding } {
    // Find separator '1' — last occurrence
    var sep_pos: ?usize = null;
    for (0..input.len) |i| {
        if (input[input.len - 1 - i] == '1') {
            sep_pos = input.len - 1 - i;
            break;
        }
    }
    const pos = sep_pos orelse return error.InvalidBech32NoSeparator;

    if (pos < 1 or pos + 7 > input.len) return error.InvalidBech32TooShort;
    if (input.len > 90) return error.InvalidBech32TooLong;

    // Extract HRP (lowercase)
    var hrp = try allocator.alloc(u8, pos);
    for (input[0..pos], 0..) |c, i| {
        hrp[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    // Extract data part
    const data_part = input[pos + 1 ..];
    var data = try allocator.alloc(u5, data_part.len);
    for (data_part, 0..) |c, i| {
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (lower >= 128) {
            allocator.free(hrp);
            allocator.free(data);
            return error.InvalidBech32Character;
        }
        const val = CHARSET_REV[lower];
        if (val < 0) {
            allocator.free(hrp);
            allocator.free(data);
            return error.InvalidBech32Character;
        }
        data[i] = @intCast(@as(u8, @bitCast(val)));
    }

    // Verify checksum
    const enc = try verifyChecksum(hrp, data, allocator) orelse {
        allocator.free(hrp);
        allocator.free(data);
        return error.InvalidBech32Checksum;
    };

    // Strip checksum from returned data
    const payload = try allocator.alloc(u5, data.len - 6);
    @memcpy(payload, data[0 .. data.len - 6]);
    allocator.free(data);

    return .{ .hrp = hrp, .data = payload, .encoding = enc };
}

// ─── Witness Address helpers (SegWit / Taproot) ──────────────────────────────

/// Convert between bit groups (e.g. 8→5 for encoding, 5→8 for decoding)
/// For 8→5: pass u8 data. For 5→8: pass u5 data.
pub fn convertBits8to5(data: []const u8, pad: bool, allocator: std.mem.Allocator) ![]u5 {
    return convertBitsGeneric(u8, data, 8, 5, pad, allocator);
}

pub fn convertBits5to8(data: []const u5, pad: bool, allocator: std.mem.Allocator) ![]u8 {
    return convertBitsGeneric(u5, data, 5, 8, pad, allocator);
}

fn convertBitsGeneric(comptime T: type, data: []const T, comptime from_bits: u5, comptime to_bits: u5, pad: bool, allocator: std.mem.Allocator) ![]std.meta.Int(.unsigned, to_bits) {
    const OutT = std.meta.Int(.unsigned, to_bits);
    var acc: u32 = 0;
    var bits: u6 = 0;
    const maxv: u32 = (@as(u32, 1) << to_bits) - 1;

    // Max output size
    const max_out = (data.len * @as(usize, from_bits) + @as(usize, to_bits) - 1) / @as(usize, to_bits);
    var result = try allocator.alloc(OutT, max_out + 1);
    var out_idx: usize = 0;

    for (data) |val| {
        acc = (acc << from_bits) | @as(u32, val);
        bits += from_bits;
        while (bits >= to_bits) {
            bits -= to_bits;
            result[out_idx] = @truncate((acc >> @intCast(bits)) & maxv);
            out_idx += 1;
        }
    }
    if (pad) {
        if (bits > 0) {
            result[out_idx] = @truncate((acc << @intCast(@as(u6, to_bits) - bits)) & maxv);
            out_idx += 1;
        }
    } else {
        if (bits >= from_bits) {
            allocator.free(result);
            return error.InvalidBitConversion;
        }
        if (((acc << @intCast(@as(u6, to_bits) - bits)) & maxv) != 0) {
            allocator.free(result);
            return error.NonZeroPadding;
        }
    }

    // Shrink to actual size
    const final = try allocator.alloc(OutT, out_idx);
    @memcpy(final, result[0..out_idx]);
    allocator.free(result);
    return final;
}

/// Encode a witness address: hrp + witness_version + witness_program (hash bytes)
/// witness_version=0 → Bech32 (P2WPKH: 20 bytes, P2WSH: 32 bytes)
/// witness_version=1 → Bech32m (Taproot: 32 bytes)
pub fn encodeWitnessAddress(
    hrp: []const u8,
    witness_version: u5,
    witness_program: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    // Validate witness program length
    if (witness_program.len < 2 or witness_program.len > 40) return error.InvalidWitnessLength;
    if (witness_version == 0 and witness_program.len != 20 and witness_program.len != 32)
        return error.InvalidV0WitnessLength;

    // Convert 8-bit → 5-bit
    const converted = try convertBits8to5(witness_program, true, allocator);
    defer allocator.free(converted);

    // Prepend witness version
    var data = try allocator.alloc(u5, 1 + converted.len);
    defer allocator.free(data);
    data[0] = witness_version;
    @memcpy(data[1..], converted);

    // Bech32 for v0, Bech32m for v1+
    const encoding: Encoding = if (witness_version == 0) .bech32 else .bech32m;

    return encode(hrp, data, encoding, allocator);
}

pub const WitnessResult = struct { version: u5, program: []u8 };

/// Decode a witness address → (witness_version, witness_program bytes)
/// Validates checksum, witness version, and program length per BIP-141/BIP-350.
pub fn decodeWitnessAddress(
    expected_hrp: []const u8,
    addr: []const u8,
    allocator: std.mem.Allocator,
) !WitnessResult {
    const decoded = try decode(addr, allocator);
    defer allocator.free(decoded.hrp);
    defer allocator.free(decoded.data);

    // Verify HRP
    if (!std.mem.eql(u8, decoded.hrp, expected_hrp)) return error.InvalidHRP;

    if (decoded.data.len < 1) return error.EmptyWitnessData;

    const version = decoded.data[0];
    if (version > 16) return error.InvalidWitnessVersion;

    // Verify encoding matches version
    const expected_enc: Encoding = if (version == 0) .bech32 else .bech32m;
    if (decoded.encoding != expected_enc) return error.WrongBech32Variant;

    // Convert 5-bit → 8-bit
    const program = try convertBits5to8(decoded.data[1..], false, allocator);

    // Validate program length
    if (program.len < 2 or program.len > 40) {
        allocator.free(program);
        return error.InvalidWitnessLength;
    }
    if (version == 0 and program.len != 20 and program.len != 32) {
        allocator.free(program);
        return error.InvalidV0WitnessLength;
    }

    return .{ .version = version, .program = program };
}

// ─── OmniBus convenience ────────────────────────────────────────────────────

pub const OB_HRP = "ob";

/// Generate an OmniBus P2WPKH address: ob1q... (witness v0, 20-byte hash160)
pub fn encodeOBAddress(hash160: [20]u8, allocator: std.mem.Allocator) ![]u8 {
    return encodeWitnessAddress(OB_HRP, 0, &hash160, allocator);
}

/// Generate an OmniBus Taproot address: ob1p... (witness v1, 32-byte x-only pubkey)
pub fn encodeOBTaprootAddress(pubkey_x: [32]u8, allocator: std.mem.Allocator) ![]u8 {
    return encodeWitnessAddress(OB_HRP, 1, &pubkey_x, allocator);
}

/// Validate and decode an OmniBus address (any witness version)
pub fn decodeOBAddress(addr: []const u8, allocator: std.mem.Allocator) !WitnessResult {
    return decodeWitnessAddress(OB_HRP, addr, allocator);
}

/// Quick validation — returns true if addr is a valid ob1... address
pub fn isValidOBAddress(addr: []const u8, allocator: std.mem.Allocator) bool {
    const decoded = decodeOBAddress(addr, allocator) catch return false;
    allocator.free(decoded.program);
    return true;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "Bech32 — encode and decode roundtrip (witness v0, P2WPKH)" {
    const allocator = std.testing.allocator;

    // Hash160 known value (20 bytes)
    const hash160 = [20]u8{ 0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4, 0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23, 0xf1, 0x43, 0x3b, 0xd6 };

    const addr = try encodeOBAddress(hash160, allocator);
    defer allocator.free(addr);

    // Must start with ob1q
    try std.testing.expect(std.mem.startsWith(u8, addr, "ob1q"));

    // Decode back
    const decoded = try decodeOBAddress(addr, allocator);
    defer allocator.free(decoded.program);

    try std.testing.expectEqual(@as(u5, 0), decoded.version);
    try std.testing.expectEqual(@as(usize, 20), decoded.program.len);
    try std.testing.expectEqualSlices(u8, &hash160, decoded.program);
}

test "Bech32m — encode and decode roundtrip (witness v1, Taproot)" {
    const allocator = std.testing.allocator;

    // 32-byte x-only pubkey
    var pubkey: [32]u8 = undefined;
    for (&pubkey, 0..) |*b, i| b.* = @truncate(i + 1);

    const addr = try encodeOBTaprootAddress(pubkey, allocator);
    defer allocator.free(addr);

    // Must start with ob1p (witness v1 = 'p' in bech32 charset)
    try std.testing.expect(std.mem.startsWith(u8, addr, "ob1p"));

    // Decode back
    const decoded = try decodeOBAddress(addr, allocator);
    defer allocator.free(decoded.program);

    try std.testing.expectEqual(@as(u5, 1), decoded.version);
    try std.testing.expectEqual(@as(usize, 32), decoded.program.len);
    try std.testing.expectEqualSlices(u8, &pubkey, decoded.program);
}

test "Bech32 — invalid checksum rejected" {
    const allocator = std.testing.allocator;

    // Generate valid address, then corrupt it
    const hash160 = [20]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd };
    const addr = try encodeOBAddress(hash160, allocator);
    defer allocator.free(addr);

    // Corrupt last character
    var bad = try allocator.alloc(u8, addr.len);
    defer allocator.free(bad);
    @memcpy(bad, addr);
    bad[bad.len - 1] = if (addr[addr.len - 1] == 'q') 'p' else 'q';

    try std.testing.expectError(error.InvalidBech32Checksum, decodeOBAddress(bad, allocator));
}

test "Bech32 — wrong encoding for witness version rejected" {
    const allocator = std.testing.allocator;

    // Encode v1 address with Bech32 (should be Bech32m) — manual encode
    var pubkey: [32]u8 = undefined;
    @memset(&pubkey, 0x42);

    const converted = try convertBits8to5(&pubkey, true, allocator);
    defer allocator.free(converted);

    var data = try allocator.alloc(u5, 1 + converted.len);
    defer allocator.free(data);
    data[0] = 1; // witness v1
    @memcpy(data[1..], converted);

    // Force Bech32 encoding (wrong for v1)
    const wrong_addr = try encode(OB_HRP, data, .bech32, allocator);
    defer allocator.free(wrong_addr);

    // Decoding should fail with WrongBech32Variant
    try std.testing.expectError(error.WrongBech32Variant, decodeOBAddress(wrong_addr, allocator));
}

test "Bech32 — isValidOBAddress" {
    const allocator = std.testing.allocator;

    const hash160 = [20]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14 };
    const addr = try encodeOBAddress(hash160, allocator);
    defer allocator.free(addr);

    try std.testing.expect(isValidOBAddress(addr, allocator));
    try std.testing.expect(!isValidOBAddress("ob1qinvalid", allocator));
    try std.testing.expect(!isValidOBAddress("bc1qnotours", allocator));
    try std.testing.expect(!isValidOBAddress("", allocator));
}

test "Bech32 — deterministic encoding" {
    const allocator = std.testing.allocator;

    const hash160 = [20]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };

    const addr1 = try encodeOBAddress(hash160, allocator);
    defer allocator.free(addr1);
    const addr2 = try encodeOBAddress(hash160, allocator);
    defer allocator.free(addr2);

    try std.testing.expectEqualStrings(addr1, addr2);
}
