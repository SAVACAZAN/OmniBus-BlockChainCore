/// agent_wallet.zig — derivare BIP-44 per-agent.
///
/// Fiecare agent are wallet propriu derivat din mnemonic + wallet_index unic
/// (BIP-44 path m/44'/777'/0'/0/N unde N = wallet_index). Asa, agent #1 are
/// adresa diferita de agent #2, balance separat, P&L separat.
///
/// Reuseam `MinerWallet` struct ca să avem fix-size + createSignedTx gata.
/// Singura diferenta: aici DERIVAM adresa intern din BIP-32 (MinerWallet
/// originar primea adresa de la caller).
const std = @import("std");
const bip32_mod = @import("bip32_wallet.zig");
const secp256k1_mod = @import("secp256k1.zig");
const bech32_mod = @import("bech32.zig");
const miner_wallet_mod = @import("miner_wallet.zig");

const BIP32Wallet = bip32_mod.BIP32Wallet;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
pub const MinerWallet = miner_wallet_mod.MinerWallet;

/// Derivare standard pentru agent: m/44'/777'/0'/0/wallet_index
/// Returnează un MinerWallet complet (privkey + pubkey + adresa Bech32 ob1q...).
///
/// Pentru wallet_index=0 obții același wallet ca nodul (miner default), așa
/// că agenții ar trebui să folosească index >= 1.
pub fn deriveAgentWallet(
    mnemonic: []const u8,
    wallet_index: u32,
    allocator: std.mem.Allocator,
) !MinerWallet {
    var bip32 = try BIP32Wallet.initFromMnemonic(mnemonic, allocator);
    const privkey = try bip32.deriveChildKeyForPath(44, 777, wallet_index);
    const pubkey = try Secp256k1Crypto.privateKeyToPublicKey(privkey);

    // Hash160 din pubkey → bech32 (ob1q...)
    const h160 = try bip32.deriveHash160(44, 777, wallet_index);
    const addr = try bech32_mod.encodeOBAddress(h160, allocator);
    defer allocator.free(addr);

    var wallet = MinerWallet{
        .address = undefined,
        .address_len = 0,
        .private_key = privkey,
        .public_key = pubkey,
        .public_key_hex = undefined,
        .balance_cache = 0,
        .has_mnemonic = true,
    };
    const alen = @min(addr.len, 64);
    @memcpy(wallet.address[0..alen], addr[0..alen]);
    wallet.address_len = @intCast(alen);

    const HEX = "0123456789abcdef";
    for (pubkey, 0..) |byte, j| {
        wallet.public_key_hex[j * 2] = HEX[byte >> 4];
        wallet.public_key_hex[j * 2 + 1] = HEX[byte & 0x0F];
    }
    return wallet;
}

// ─── Teste ──────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "deriveAgentWallet — adrese diferite pentru indexes diferite" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w0 = try deriveAgentWallet(mnemonic, 0, a);
    const w1 = try deriveAgentWallet(mnemonic, 1, a);
    const w2 = try deriveAgentWallet(mnemonic, 2, a);

    try testing.expect(!std.mem.eql(u8, w0.getAddress(), w1.getAddress()));
    try testing.expect(!std.mem.eql(u8, w1.getAddress(), w2.getAddress()));
    try testing.expect(std.mem.startsWith(u8, w0.getAddress(), "ob1q"));
    try testing.expect(std.mem.startsWith(u8, w1.getAddress(), "ob1q"));
}

test "deriveAgentWallet — deterministic pentru acelasi mnemonic + index" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w_a = try deriveAgentWallet(mnemonic, 5, a);
    const w_b = try deriveAgentWallet(mnemonic, 5, a);
    try testing.expectEqualStrings(w_a.getAddress(), w_b.getAddress());
    try testing.expectEqualSlices(u8, &w_a.private_key, &w_b.private_key);
}

test "deriveAgentWallet — privkey diferit per index" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const w1 = try deriveAgentWallet(mnemonic, 1, a);
    const w2 = try deriveAgentWallet(mnemonic, 2, a);
    try testing.expect(!std.mem.eql(u8, &w1.private_key, &w2.private_key));
}

test "deriveAgentWallet — semneaza un TX" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var w = try deriveAgentWallet(mnemonic, 1, a);
    const tx = try w.createSignedTx("ob1q_recipient_test_addr", 1000, 42, 0, 1, a);
    try testing.expect(tx.signature.len > 0);
    try testing.expectEqual(@as(u64, 1000), tx.amount);
}
