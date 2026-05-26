// ============================================
// 6. core/hybrid_signature.zig
// ============================================
const std = @import("std");
const secp256k1 = @import("secp256k1.zig");
const pq_crypto = @import("pq_crypto.zig");

pub const HybridScheme = enum(u8) {
    ECDSA_MLDSA65 = 0x01,
    ECDSA_MLDSA87 = 0x02,
    ECDSA_FALCON512 = 0x03,
};

pub const HybridSignature = struct {
    scheme: HybridScheme,
    classic_sig: secp256k1.Signature,
    pq_sig: []const u8,
    
    pub fn deinit(self: *HybridSignature, allocator: std.mem.Allocator) void {
        allocator.free(self.pq_sig);
    }
    
    pub fn serialize(self: *const HybridSignature, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try buf.append(@intFromEnum(self.scheme));
        try buf.appendSlice(&self.classic_sig.r);
        try buf.appendSlice(&self.classic_sig.s);
        try buf.appendSlice(self.pq_sig);
        return try buf.toOwnedSlice();
    }
    
    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !HybridSignature {
        if (data.len < 65) return error.InvalidSignature;
        const scheme: HybridScheme = @enumFromInt(data[0]);
        var classic_sig: secp256k1.Signature = undefined;
        @memcpy(&classic_sig.r, data[1..33]);
        @memcpy(&classic_sig.s, data[33..65]);
        const pq_sig = try allocator.duplicate(u8, data[65..]);
        return HybridSignature{
            .scheme = scheme,
            .classic_sig = classic_sig,
            .pq_sig = pq_sig,
        };
    }
};

pub fn signHybrid(
    allocator: std.mem.Allocator,
    msg: []const u8,
    classic_sk: [32]u8,
    pq_sk: []const u8,
    scheme: HybridScheme,
) !HybridSignature {
    // Classic signature (ECDSA)
    const classic_sig = try secp256k1.sign(msg, classic_sk);
    
    // PQ signature based on scheme
    const pq_sig = switch (scheme) {
        .ECDSA_MLDSA65 => try pq_crypto.MLDSA65.sign(allocator, msg, pq_sk),
        .ECDSA_MLDSA87 => try pq_crypto.MLDSA87.sign(allocator, msg, pq_sk),
        .ECDSA_FALCON512 => try pq_crypto.FALCON512.sign(allocator, msg, pq_sk),
    };
    
    return HybridSignature{
        .scheme = scheme,
        .classic_sig = classic_sig,
        .pq_sig = pq_sig,
    };
}

pub fn verifyHybrid(
    msg: []const u8,
    sig: *const HybridSignature,
    classic_pk: [64]u8,
    pq_pk: []const u8,
) !bool {
    // Verify classic signature
    const classic_ok = secp256k1.verify(msg, sig.classic_sig, classic_pk);
    if (!classic_ok) return false;
    
    // Verify PQ signature
    const pq_ok = switch (sig.scheme) {
        .ECDSA_MLDSA65 => try pq_crypto.MLDSA65.verify(msg, sig.pq_sig, pq_pk),
        .ECDSA_MLDSA87 => try pq_crypto.MLDSA87.verify(msg, sig.pq_sig, pq_pk),
        .ECDSA_FALCON512 => try pq_crypto.FALCON512.verify(msg, sig.pq_sig, pq_pk),
    };
    
    return pq_ok;
}

test "Hybrid signature roundtrip" {
    var allocator = std.testing.allocator;
    const msg = "Hello OmniBus Hybrid Signatures";
    
    // Mock keys for test
    var classic_sk: [32]u8 = undefined;
    var classic_pk: [64]u8 = undefined;
    for (0..32) |i| classic_sk[i] = @intCast(i);
    _ = secp256k1.derivePublicKey(&classic_pk, classic_sk);
    
    const pq_sk = try allocator.alloc(u8, 64);
    const pq_pk = try allocator.alloc(u8, 32);
    defer {
        allocator.free(pq_sk);
        allocator.free(pq_pk);
    }
    for (0..64) |i| pq_sk[i] = @intCast(i);
    for (0..32) |i| pq_pk[i] = @intCast(i + 100);
    
    const sig = try signHybrid(allocator, msg, classic_sk, pq_sk, .ECDSA_MLDSA65);
    defer sig.deinit(allocator);
    
    const valid = try verifyHybrid(msg, &sig, classic_pk, pq_pk);
    try std.testing.expect(valid);
}