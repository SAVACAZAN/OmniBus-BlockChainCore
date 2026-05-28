//! Pubkey + multisig registry helpers extracted from blockchain.zig.
//!
//! Free functions taking `*Blockchain` (or `*const Blockchain`). The
//! Blockchain struct re-exposes them as thin method shims so callers
//! keep using `bc.registerPubkey(...)` syntax.
const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");
const multisig_mod = @import("../multisig.zig");

const Blockchain = blockchain_mod.Blockchain;
const MultisigConfigEntry = blockchain_mod.MultisigConfigEntry;

/// Inregistreaza public key-ul unei adrese (pentru verificare semnatura TX)
/// pubkey_hex = compressed secp256k1 public key, 66 hex chars
pub fn registerPubkey(self: *Blockchain, address: []const u8, pubkey_hex: []const u8) !void {
    if (pubkey_hex.len != 66) return error.InvalidPubkeyLength;
    self.mutex.lock();
    defer self.mutex.unlock();
    // Nu suprascrie daca exista deja (prima inregistrare e autoritativa)
    if (self.pubkey_registry.get(address) == null) {
        try self.pubkey_registry.put(address, pubkey_hex);
    }
}

/// Register a multisig wallet configuration (address → M-of-N config).
/// Called by the "createmultisig" RPC handler.
pub fn registerMultisig(self: *Blockchain, address: []const u8, config: multisig_mod.MultisigConfig) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    // Check if already registered
    for (self.multisig_configs[0..self.multisig_count]) |entry| {
        if (std.mem.eql(u8, entry.address[0..entry.address_len], address)) return; // already exists
    }
    if (self.multisig_count >= 64) return error.MultisigRegistryFull;
    var entry = MultisigConfigEntry{};
    const copy_len = @min(address.len, 64);
    @memcpy(entry.address[0..copy_len], address[0..copy_len]);
    entry.address_len = @intCast(copy_len);
    entry.config = config;
    self.multisig_configs[self.multisig_count] = entry;
    self.multisig_count += 1;
}

/// Look up a multisig config by address.
pub fn getMultisigConfig(self: *const Blockchain, address: []const u8) ?*const multisig_mod.MultisigConfig {
    for (self.multisig_configs[0..self.multisig_count]) |*entry| {
        if (std.mem.eql(u8, entry.address[0..entry.address_len], address)) {
            return &entry.config;
        }
    }
    return null;
}
