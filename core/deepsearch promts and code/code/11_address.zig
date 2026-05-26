//! TON Address Generation and Management
//! Supports bounceable and non-bounceable addresses

const std = @import("std");
const allocator = std.mem.Allocator;
const base64 = std.base64;
const crc16 = @import("crc16.zig"); // Would need to implement

// ============================================================
// TON Address Types
// ============================================================

/// Workchain ID
pub const Workchain = enum(i8) {
    /// Masterchain (workchain -1)
    masterchain = -1,
    
    /// Basechain (workchain 0)
    basechain = 0,
    
    /// Custom workchain
    custom: i8,
};

/// TON Address structure
pub const TonAddress = struct {
    workchain: i8,
    hash: [32]u8,
    
    /// Create address from workchain and hash
    pub fn init(workchain: i8, hash: [32]u8) TonAddress {
        return .{
            .workchain = workchain,
            .hash = hash,
        };
    }
    
    /// Parse from raw representation (workchain + 32-byte hash)
    pub fn fromRaw(raw: [33]u8) TonAddress {
        return .{
            .workchain = @as(i8, @bitCast(raw[0])),
            .hash = raw[1..33].*,
        };
    }
    
    /// Convert to raw representation
    pub fn toRaw(self: TonAddress) [33]u8 {
        var raw: [33]u8 = undefined;
        raw[0] = @as(u8, @bitCast(self.workchain));
        @memcpy(raw[1..33], &self.hash);
        return raw;
    }
    
    /// Get bounceable address string (starts with EQ or UQ)
    pub fn toBounceable(self: TonAddress) ![]u8 {
        return self.encode(true);
    }
    
    /// Get non-bounceable address string (starts with EQ or UQ but different flag)
    pub fn toNonBounceable(self: TonAddress) ![]u8 {
        return self.encode(false);
    }
    
    /// Get raw hex address
    pub fn toHex(self: TonAddress) []u8 {
        var hex = std.ArrayList(u8).init(allocator);
        defer hex.deinit();
        
        hex.writer().print("{:02x}", .{@as(u8, @bitCast(self.workchain))}) catch unreachable;
        hex.writer().print("{s}", .{std.fmt.bytesToHex(&self.hash, .lower)}) catch unreachable;
        
        return hex.toOwnedSlice() catch unreachable;
    }
    
    /// Parse address from string (supports bounceable, non-bounceable, raw)
    pub fn fromString(s: []const u8) !TonAddress {
        // Check if it's raw hex (starts with 0: or -1: or just hex)
        if (s.len == 66) {
            // Raw hex: workchain(2) + hash(64)
            const workchain_hex = s[0..2];
            if (std.mem.eql(u8, workchain_hex, "00")) {
                return TonAddress.decodeRaw(s);
            } else if (std.mem.eql(u8, workchain_hex, "ff")) {
                return TonAddress.decodeRaw(s);
            }
        }
        
        // Check for bounceable/non-bounceable base64
        if (s.len >= 48 and (s[0] == 'E' or s[0] == 'U')) {
            const flag = if (s[0] == 'E') @as(u8, 0x11) else @as(u8, 0x51);
            return try TonAddress.decodeBase64Url(s, flag);
        }
        
        return error.InvalidAddress;
    }
    
    /// Encode address to base64url format (for bounceable/non-bounceable)
    fn encode(self: TonAddress, bounceable: bool) ![]u8 {
        var raw = std.ArrayList(u8).init(allocator);
        defer raw.deinit();
        
        // Tag byte: 0x11 for bounceable, 0x51 for non-bounceable
        const tag: u8 = if (bounceable) 0x11 else 0x51;
        try raw.append(tag);
        
        // Workchain
        try raw.append(@as(u8, @bitCast(self.workchain)));
        
        // Hash
        try raw.appendSlice(&self.hash);
        
        // Calculate CRC16
        const checksum = crc16.calculate(raw.items);
        try raw.appendSlice(&std.mem.toBytes(checksum));
        
        // Base64url encode
        var encoder = base64.url_safe.NoPaddingEncoder;
        var result = try allocator.alloc(u8, encoder.calcSize(raw.items.len));
        _ = encoder.encode(result, raw.items);
        
        return result;
    }
    
    /// Decode address from base64url format
    fn decodeBase64Url(s: []const u8, expected_tag: u8) !TonAddress {
        // Base64url decode
        var decoder = base64.url_safe.NoPaddingDecoder;
        const decoded_len = try decoder.calcSizeForSlice(s);
        var decoded = try allocator.alloc(u8, decoded_len);
        defer allocator.free(decoded);
        try decoder.decode(decoded, s);
        
        if (decoded.len != 35) return error.InvalidAddress; // tag(1) + wc(1) + hash(32) + crc(1)
        
        // Verify tag
        if (decoded[0] != expected_tag) return error.InvalidTag;
        
        // Verify CRC
        const checksum = crc16.calculate(decoded[0..decoded.len - 2]);
        const provided_crc = std.mem.readInt(u16, decoded[decoded.len - 2 ..], .big);
        if (checksum != provided_crc) return error.InvalidChecksum;
        
        return TonAddress{
            .workchain = @as(i8, @bitCast(decoded[1])),
            .hash = decoded[2..34].*,
        };
    }
    
    /// Decode raw hex address
    fn decodeRaw(s: []const u8) !TonAddress {
        if (s.len != 66) return error.InvalidAddress;
        
        const workchain_hex = s[0..2];
        const workchain = if (std.mem.eql(u8, workchain_hex, "00"))
            @as(i8, 0)
        else if (std.mem.eql(u8, workchain_hex, "ff"))
            @as(i8, -1)
        else
            return error.InvalidWorkchain;
        
        var hash: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash, s[2..]);
        
        return TonAddress{
            .workchain = workchain,
            .hash = hash,
        };
    }
};

// ============================================================
// Address Derivation (BIP-44)
// ============================================================

pub const AddressGenerator = struct {
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) AddressGenerator {
        return .{ .allocator = allocator };
    }
    
    /// Derive TON address from seed using BIP-44 path: m/44'/607'/account'/0/index
    /// TON coin type is 607
    pub fn deriveAddress(
        self: *AddressGenerator,
        seed: []const u8,
        account: u32,
        index: u32,
    ) !TonAddress {
        const purpose: u32 = 44;
        const coin_type: u32 = 607; // TON
        const change: u32 = 0;
        
        // Use Ed25519 derivation
        const derivation_ops = @import("../sol/ed25519.zig").SolanaDerivation.init(self.allocator);
        const keypair = try derivation_ops.deriveKeypair(seed, account, index);
        
        // TON address is derived from Ed25519 public key hash
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&keypair.public);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        
        // Default workchain is 0 (basechain)
        return TonAddress{
            .workchain = 0,
            .hash = hash,
        };
    }
    
    /// Derive from mnemonic
    pub fn deriveFromMnemonic(
        self: *AddressGenerator,
        mnemonic: []const u8,
        account: u32,
        index: u32,
    ) !TonAddress {
        const seed = try self.mnemonicToSeed(mnemonic);
        defer self.allocator.free(seed);
        return try self.deriveAddress(seed, account, index);
    }
    
    fn mnemonicToSeed(self: *AddressGenerator, mnemonic: []const u8) ![]u8 {
        _ = self;
        _ = mnemonic;
        // In production, implement BIP-39
        var seed = try self.allocator.alloc(u8, 64);
        @memset(seed, 0);
        return seed;
    }
};

// ============================================================
// Tests
// ============================================================

test "TON address encoding/decoding" {
    const hash = [_]u8{0x01} ** 32;
    const addr = TonAddress.init(0, hash);
    
    const bounceable = try addr.toBounceable();
    defer allocator.free(bounceable);
    
    try std.testing.expect(bounceable.len >= 48);
    
    const decoded = try TonAddress.fromString(bounceable);
    try std.testing.expectEqual(decoded.workchain, 0);
    try std.testing.expectEqualSlices(u8, &decoded.hash, &hash);
}

test "Raw hex address" {
    const hash = [_]u8{0xAA} ** 32;
    const addr = TonAddress.init(-1, hash);
    
    const hex = addr.toHex();
    defer allocator.free(hex);
    
    try std.testing.expect(hex.len == 66);
    try std.testing.expect(std.mem.startsWith(u8, hex, "ff"));
}