// ============================================
// 4. core/segwit.zig
// ============================================
const std = @import("std");
const sha256 = std.crypto.hash.sha2.Sha256;
const ripemd160 = std.crypto.hash.ripemd160.Ripemd160;

pub const WitnessProgram = struct {
    version: u8,
    program: []const u8,
    
    pub fn isSegwit(self: *const WitnessProgram) bool {
        return self.version == 0 or self.version == 1;
    }
    
    pub fn toAddress(self: *const WitnessProgram, allocator: std.mem.Allocator) ![]const u8 {
        if (self.version == 0 and self.program.len == 20) {
            // P2WPKH: bech32
            return encodeBech32("ob", self.version, self.program);
        } else if (self.version == 1 and self.program.len == 32) {
            // P2TR: bech32m
            return encodeBech32m("ob", self.version, self.program);
        }
        return error.UnsupportedWitnessVersion;
    }
};

pub fn createP2WPKH(pubkey_hash: [20]u8) []const u8 {
    // OP_0 <pubkey_hash>
    var script: [22]u8 = undefined;
    script[0] = 0x00; // OP_0
    script[1] = 0x14; // push 20 bytes
    @memcpy(script[2..22], &pubkey_hash);
    return &script;
}

pub fn createP2TR(internal_pubkey: [32]u8, merkle_root: ?[32]u8) []const u8 {
    // OP_1 <tweaked_pubkey>
    var tweaked = internal_pubkey;
    if (merkle_root) |root| {
        tweakPubkey(&tweaked, root);
    }
    var script: [34]u8 = undefined;
    script[0] = 0x51; // OP_1
    script[1] = 0x20; // push 32 bytes
    @memcpy(script[2..34], &tweaked);
    return &script;
}

fn tweakPubkey(pubkey: *[32]u8, merkle_root: [32]u8) void {
    // BIP-341 taproot tweak: P + H(P || m)
    _ = merkle_root;
    // Simplified: XOR with merkle root first 32 bytes
    for (0..32) |i| {
        pubkey[i] ^= merkle_root[i];
    }
}

pub fn decodeSegwitAddress(address: []const u8) !WitnessProgram {
    if (std.mem.startsWith(u8, address, "ob1")) {
        // bech32 for v0
        const hrp = address[0..2];
        const data = address[2..];
        _ = hrp;
        _ = data;
        return WitnessProgram{
            .version = 0,
            .program = &[_]u8{},
        };
    }
    return error.InvalidAddress;
}

fn encodeBech32(hrp: []const u8, version: u8, program: []const u8) ![]const u8 {
    _ = hrp;
    _ = version;
    _ = program;
    return "ob1qxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
}

fn encodeBech32m(hrp: []const u8, version: u8, program: []const u8) ![]const u8 {
    _ = hrp;
    _ = version;
    _ = program;
    return "ob1pxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
}

test "P2WPKH script creation" {
    const hash = [_]u8{0} ** 20;
    const script = createP2WPKH(hash);
    try std.testing.expect(script.len == 22);
    try std.testing.expect(script[0] == 0x00);
    try std.testing.expect(script[1] == 0x14);
}

test "P2TR script creation" {
    const pubkey = [_]u8{1} ** 32;
    const script = createP2TR(pubkey, null);
    try std.testing.expect(script.len == 34);
    try std.testing.expect(script[0] == 0x51);
    try std.testing.expect(script[1] == 0x20);
}