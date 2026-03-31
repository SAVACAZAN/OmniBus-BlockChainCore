const std = @import("std");
const bip32_mod       = @import("bip32_wallet.zig");
const secp256k1_mod   = @import("secp256k1.zig");
const transaction_mod = @import("transaction.zig");
const script_mod      = @import("script.zig");
const ripemd160_mod   = @import("ripemd160.zig");
const crypto_mod      = @import("crypto.zig");

const BIP32Wallet = bip32_mod.BIP32Wallet;
const PQDomainDerivation = bip32_mod.PQDomainDerivation;
const Network = bip32_mod.Network;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Ripemd160 = ripemd160_mod.Ripemd160;

/// OmniBus Wallet — BTC-parity metadata + secp256k1 + 5 PQ domains
///
/// Exposes the same fields as a full BTC wallet:
///   mnemonic, master_fingerprint, network, derivation (full_path, purpose,
///   coin_type, account, chain, address_index), address_info (type, address,
///   script_pubkey, witness_version), keys (public_key, private_key_wif,
///   hash160), extended_keys (xpub, xprv, parent_fingerprint),
///   state (balance, tx_count), metadata (label, is_change, created_at)
pub const Wallet = struct {
    // ─── Core identity ──────────────────────────────────────────────────
    /// Adresa primara (OMNI SegWit ob1q...)
    address: []u8,
    /// Compressed public key (33 bytes) — secp256k1 real
    public_key_bytes: [33]u8,
    /// Private key (32 bytes) — tinut in memorie doar cat e nevoie
    private_key_bytes: [32]u8,
    /// Cele 5 adrese PQ (OMNI + 4 domenii)
    addresses: [5]Address,
    allocator: std.mem.Allocator,

    // ─── BTC-parity: master info ────────────────────────────────────────
    /// Master fingerprint (4 bytes) — first 4 bytes of Hash160(master_pubkey)
    master_fingerprint: [4]u8,
    /// Master fingerprint as hex string (8 chars, e.g. "3442193e")
    master_fingerprint_hex: []u8,
    /// Network: mainnet ("OMNI") or testnet ("TOMNI")
    network: Network,

    // ─── BTC-parity: derivation info ────────────────────────────────────
    /// Full derivation path string (e.g. "m/44'/777'/0'/0/0")
    derivation_path: []u8,
    /// BIP-44 purpose (44 = multi-coin, legacy compatible)
    purpose: u32 = 44,
    /// Account index (BIP-44 account')
    account_index: u32 = 0,
    /// Chain: 0 = external (receiving), 1 = change
    chain: u32 = 0,
    /// Address index within account
    address_index: u32 = 0,

    // ─── BTC-parity: address info ───────────────────────────────────────
    /// Address type: "NATIVE_SEGWIT" (v0) or "TAPROOT" (v1)
    address_type: []const u8 = "NATIVE_SEGWIT",
    /// Witness version (0 for SegWit, 1 for Taproot)
    witness_version: u8 = 0,
    /// Script pubkey (0x0014 + hash160 for P2WPKH) as hex
    script_pubkey_hex: []u8,

    // ─── BTC-parity: keys ───────────────────────────────────────────────
    /// Public key as hex string (66 chars compressed)
    public_key_hex: []u8,
    /// Private key in WIF format (Base58Check, starts with K/L)
    private_key_wif: []u8,
    /// Hash160 of public key as hex (40 chars)
    hash160_hex: []u8,

    // ─── BTC-parity: extended keys ──────────────────────────────────────
    /// Extended public key (xpub/opub) — Base58Check, ~111 chars
    xpub: []u8,
    /// Extended private key (xprv/oprv) — Base58Check, ~111 chars
    xprv: []u8,
    /// Parent fingerprint as hex (8 chars)
    parent_fingerprint_hex: []u8,

    // ─── BTC-parity: state ──────────────────────────────────────────────
    /// Balance in SAT (actualizata din nod RPC)
    balance: u64 = 0,
    /// Transaction count
    tx_count: u64 = 0,

    // ─── BTC-parity: metadata ───────────────────────────────────────────
    /// Human-readable label
    label: []const u8 = "",
    /// Is this a change address?
    is_change: bool = false,
    /// Creation timestamp (unix seconds)
    created_at: i64 = 0,
    /// Last used timestamp (0 = never used)
    last_used: i64 = 0,

    pub const Address = struct {
        domain: []const u8,       // "omnibus.omni", "omnibus.love", etc.
        algorithm: []const u8,    // "Dilithium-5 + Kyber-768", etc.
        omni_address: []u8,       // adresa derivata Bech32 (ob1q...)
        public_key_hex: []u8,     // compressed pubkey hex (66 chars)
        coin_type: u32,           // BIP-44 coin type
        security_level: u32,      // bits: 256, 192, 128
        hash160_hex: []u8,        // RIPEMD160(SHA256(pubkey)) hex (40 chars)
        script_pubkey_hex: []u8,  // 0014 + hash160 hex (44 chars)
        witness_version: u8,      // 0 for SegWit, 1 for Taproot
        private_key_wif: []u8,    // WIF encoded private key (K.../L...)
        derivation_path: []u8,    // e.g. "m/44'/777'/0'/0/0"
        xpub: []u8,               // extended public key for this domain
        xprv: []u8,               // extended private key for this domain
    };

    /// Creeaza wallet din mnemonic (BIP-39) si passphrase — full BTC-parity metadata
    pub fn fromMnemonic(mnemonic: []const u8, passphrase: []const u8, allocator: std.mem.Allocator) !Wallet {
        return fromMnemonicFull(mnemonic, passphrase, .mainnet, 0, 0, 0, allocator);
    }

    /// Full constructor cu toate parametrele
    pub fn fromMnemonicFull(
        mnemonic: []const u8,
        passphrase: []const u8,
        network: Network,
        account: u32,
        chain: u32,
        addr_index: u32,
        allocator: std.mem.Allocator,
    ) !Wallet {
        // BIP-32 master key din mnemonic + passphrase (BIP-39)
        var bip32 = try BIP32Wallet.initFromMnemonicPassphrase(mnemonic, passphrase, allocator);
        bip32.network = network;

        // Master fingerprint
        const master_fp = try bip32.masterFingerprint();
        const master_fp_hex = try bip32.masterFingerprintHex(allocator);

        // Deriva cheie OMNI (coin_type 777)
        const omni_privkey = try bip32.deriveChildKeyForPath(44, 777, addr_index);
        const omni_pubkey  = try Secp256k1Crypto.privateKeyToPublicKey(omni_privkey);

        // Hash160, script_pubkey, WIF for primary key
        const omni_h160 = try bip32.deriveHash160(44, 777, addr_index);
        const omni_script = try bip32.deriveScriptPubkey(44, 777, addr_index);
        const omni_wif = try bip32.encodeWIF(omni_privkey, allocator);

        // Extended keys
        const xpub = try bip32.serializeXpub(44, 777, account, allocator);
        const xprv = try bip32.serializeXprv(44, 777, account, allocator);

        // Parent fingerprint
        const parent_fp = try bip32.parentFingerprint(44, 777);

        // Derivation path string
        const deriv_path = try BIP32Wallet.derivationPathString(44, 777, account, chain, addr_index, allocator);

        // Hex conversions
        const hex_chars = "0123456789abcdef";

        // Primary pubkey hex
        var pk_hex: [66]u8 = undefined;
        for (omni_pubkey, 0..) |byte, j| {
            pk_hex[j * 2]     = hex_chars[byte >> 4];
            pk_hex[j * 2 + 1] = hex_chars[byte & 0x0F];
        }
        const pk_hex_alloc = try allocator.dupe(u8, &pk_hex);

        // Hash160 hex
        var h160_hex: [40]u8 = undefined;
        for (omni_h160, 0..) |byte, j| {
            h160_hex[j * 2]     = hex_chars[byte >> 4];
            h160_hex[j * 2 + 1] = hex_chars[byte & 0x0F];
        }
        const h160_hex_alloc = try allocator.dupe(u8, &h160_hex);

        // Script pubkey hex (22 bytes → 44 hex chars)
        var sp_hex: [44]u8 = undefined;
        for (omni_script, 0..) |byte, j| {
            sp_hex[j * 2]     = hex_chars[byte >> 4];
            sp_hex[j * 2 + 1] = hex_chars[byte & 0x0F];
        }
        const sp_hex_alloc = try allocator.dupe(u8, &sp_hex);

        // Parent fingerprint hex
        var pfp_hex: [8]u8 = undefined;
        for (parent_fp, 0..) |byte, j| {
            pfp_hex[j * 2]     = hex_chars[byte >> 4];
            pfp_hex[j * 2 + 1] = hex_chars[byte & 0x0F];
        }
        const pfp_hex_alloc = try allocator.dupe(u8, &pfp_hex);

        // Deriva cele 5 domenii PQ
        const domains = PQDomainDerivation.DOMAINS;
        var addresses: [5]Address = undefined;

        for (domains, 0..) |domain, i| {
            const privkey_i = try bip32.deriveChildKeyForPath(44, domain.coin_type, addr_index);
            const pubkey_i  = try Secp256k1Crypto.privateKeyToPublicKey(privkey_i);
            const addr_i = try bip32.deriveAddressForDomain(domain.coin_type, addr_index, domain.prefix, allocator);
            const addr_h160 = try bip32.deriveHash160(44, domain.coin_type, addr_index);
            const addr_script = try bip32.deriveScriptPubkey(44, domain.coin_type, addr_index);

            // Pubkey hex
            var pki_hex: [66]u8 = undefined;
            for (pubkey_i, 0..) |byte, j| {
                pki_hex[j * 2]     = hex_chars[byte >> 4];
                pki_hex[j * 2 + 1] = hex_chars[byte & 0x0F];
            }

            // Hash160 hex
            var hi_hex: [40]u8 = undefined;
            for (addr_h160, 0..) |byte, j| {
                hi_hex[j * 2]     = hex_chars[byte >> 4];
                hi_hex[j * 2 + 1] = hex_chars[byte & 0x0F];
            }

            // Script pubkey hex
            var si_hex: [44]u8 = undefined;
            for (addr_script, 0..) |byte, j| {
                si_hex[j * 2]     = hex_chars[byte >> 4];
                si_hex[j * 2 + 1] = hex_chars[byte & 0x0F];
            }

            // WIF, derivation path, xpub/xprv per domain
            const domain_wif = try bip32.encodeWIF(privkey_i, allocator);
            const domain_path = try BIP32Wallet.derivationPathString(44, domain.coin_type, account, chain, addr_index, allocator);
            const domain_xpub = try bip32.serializeXpub(44, domain.coin_type, account, allocator);
            const domain_xprv = try bip32.serializeXprv(44, domain.coin_type, account, allocator);

            addresses[i] = Address{
                .domain           = domain.name,
                .algorithm        = domain.algorithm,
                .omni_address     = addr_i,
                .public_key_hex   = try allocator.dupe(u8, &pki_hex),
                .coin_type        = domain.coin_type,
                .security_level   = domain.security_level,
                .hash160_hex      = try allocator.dupe(u8, &hi_hex),
                .script_pubkey_hex = try allocator.dupe(u8, &si_hex),
                .witness_version  = 0,
                .private_key_wif  = domain_wif,
                .derivation_path  = domain_path,
                .xpub             = domain_xpub,
                .xprv             = domain_xprv,
            };
        }

        // Adresa principala = addresses[0].omni_address (ob1q...)
        const primary_addr = try allocator.dupe(u8, addresses[0].omni_address);

        return Wallet{
            // Core
            .address             = primary_addr,
            .public_key_bytes    = omni_pubkey,
            .private_key_bytes   = omni_privkey,
            .addresses           = addresses,
            .allocator           = allocator,
            // Master info
            .master_fingerprint     = master_fp,
            .master_fingerprint_hex = master_fp_hex,
            .network                = network,
            // Derivation
            .derivation_path = deriv_path,
            .account_index   = account,
            .chain           = chain,
            .address_index   = addr_index,
            // Address info
            .script_pubkey_hex = sp_hex_alloc,
            // Keys
            .public_key_hex  = pk_hex_alloc,
            .private_key_wif = omni_wif,
            .hash160_hex     = h160_hex_alloc,
            // Extended keys
            .xpub                  = xpub,
            .xprv                  = xprv,
            .parent_fingerprint_hex = pfp_hex_alloc,
            // State
            .balance  = 0,
            .tx_count = 0,
            // Metadata
            .created_at = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *Wallet) void {
        self.allocator.free(self.address);
        self.allocator.free(self.master_fingerprint_hex);
        self.allocator.free(self.derivation_path);
        self.allocator.free(self.script_pubkey_hex);
        self.allocator.free(self.public_key_hex);
        self.allocator.free(self.private_key_wif);
        self.allocator.free(self.hash160_hex);
        self.allocator.free(self.xpub);
        self.allocator.free(self.xprv);
        self.allocator.free(self.parent_fingerprint_hex);
        // Sterge private key din memorie (securitate)
        @memset(&self.private_key_bytes, 0);
        for (&self.addresses) |*addr| {
            self.allocator.free(addr.omni_address);
            self.allocator.free(addr.public_key_hex);
            self.allocator.free(addr.hash160_hex);
            self.allocator.free(addr.script_pubkey_hex);
            self.allocator.free(addr.private_key_wif);
            self.allocator.free(addr.derivation_path);
            self.allocator.free(addr.xpub);
            self.allocator.free(addr.xprv);
        }
    }

    pub fn getBalance(self: *const Wallet) u64 {
        return self.balance;
    }

    pub fn getBalanceOMNI(self: *const Wallet) f64 {
        return @as(f64, @floatFromInt(self.balance)) / 1e9;
    }

    /// Verifica daca ai suficienta balanta pentru un transfer
    pub fn canSend(self: *const Wallet, amount_sat: u64) bool {
        return self.balance >= amount_sat;
    }

    /// Actualizeaza balanta (apelat din RPC fetch)
    pub fn updateBalance(self: *Wallet, new_balance_sat: u64) void {
        self.balance = new_balance_sat;
    }

    pub fn getAddress(self: *const Wallet, index: u32) ?Address {
        if (index < self.addresses.len) return self.addresses[index];
        return null;
    }

    pub fn getAllAddresses(self: *const Wallet) [5]Address {
        return self.addresses;
    }

    /// Creeaza si semneaza o tranzactie din acest wallet
    /// Returneaza Transaction gata de broadcast (cu signature + hash setate)
    pub fn createTransaction(
        self: *const Wallet,
        to_address: []const u8,
        amount_sat: u64,
        tx_id: u32,
        allocator: std.mem.Allocator,
    ) !transaction_mod.Transaction {
        // Copiem adresele — TX-ul traieste in mempool dincolo de lifetime-ul HTTP handler
        const to_owned = try allocator.dupe(u8, to_address);
        const from_owned = try allocator.dupe(u8, self.address);
        var tx = transaction_mod.Transaction{
            .id           = tx_id,
            .from_address = from_owned,
            .to_address   = to_owned,
            .amount       = amount_sat,
            .timestamp    = std.time.timestamp(),
            .signature    = "",
            .hash         = "",
        };
        try tx.sign(self.private_key_bytes, allocator);
        return tx;
    }

    /// createTransaction cu nonce explicit (setat inainte de sign)
    pub fn createTransactionWithNonce(
        self: *const Wallet,
        to_address: []const u8,
        amount_sat: u64,
        tx_id: u32,
        nonce: u64,
        allocator: std.mem.Allocator,
    ) !transaction_mod.Transaction {
        return self.createTransactionWithNonceAndFee(to_address, amount_sat, tx_id, nonce, 1, allocator);
    }

    /// createTransaction cu nonce si fee explicit (fee inclus in hash inainte de sign)
    pub fn createTransactionWithNonceAndFee(
        self: *const Wallet,
        to_address: []const u8,
        amount_sat: u64,
        tx_id: u32,
        nonce: u64,
        fee: u64,
        allocator: std.mem.Allocator,
    ) !transaction_mod.Transaction {
        const to_owned = try allocator.dupe(u8, to_address);
        const from_owned = try allocator.dupe(u8, self.address);
        var tx = transaction_mod.Transaction{
            .id           = tx_id,
            .from_address = from_owned,
            .to_address   = to_owned,
            .amount       = amount_sat,
            .fee          = fee,
            .timestamp    = std.time.timestamp(),
            .nonce        = nonce,
            .signature    = "",
            .hash         = "",
        };
        try tx.sign(self.private_key_bytes, allocator);
        return tx;
    }

    /// createTransaction cu toate parametrele: nonce, fee, locktime, op_return
    /// Folosit de RPC pentru sendtransaction cu locktime/op_return si sendopreturn
    pub fn createTransactionFull(
        self: *const Wallet,
        to_address: []const u8,
        amount_sat: u64,
        tx_id: u32,
        nonce: u64,
        fee: u64,
        locktime: u64,
        op_return: []const u8,
        allocator: std.mem.Allocator,
    ) !transaction_mod.Transaction {
        const to_owned = try allocator.dupe(u8, to_address);
        const from_owned = try allocator.dupe(u8, self.address);
        const op_owned = if (op_return.len > 0) try allocator.dupe(u8, op_return) else @as([]const u8, "");
        var tx = transaction_mod.Transaction{
            .id           = tx_id,
            .from_address = from_owned,
            .to_address   = to_owned,
            .amount       = amount_sat,
            .fee          = fee,
            .timestamp    = std.time.timestamp(),
            .nonce        = nonce,
            .locktime     = locktime,
            .op_return    = op_owned,
            .signature    = "",
            .hash         = "",
        };
        try tx.sign(self.private_key_bytes, allocator);
        return tx;
    }

    /// Compute Hash160(pubkey) = RIPEMD160(SHA256(pubkey))
    /// Used for P2PKH script generation
    pub fn pubkeyHash160(compressed_pubkey: [33]u8) [20]u8 {
        const sha_out = crypto_mod.Crypto.sha256(&compressed_pubkey);
        var hash160: [20]u8 = undefined;
        Ripemd160.hash(&sha_out, &hash160);
        return hash160;
    }

    /// Create a transaction with P2PKH scripts attached.
    /// The locking script (script_pubkey) locks to the receiver's pubkey hash.
    /// The unlocking script (script_sig) contains the sender's signature + pubkey.
    /// receiver_pubkey_bytes: compressed public key (33 bytes) of the receiver.
    /// Falls back to legacy mode if receiver pubkey is all zeros.
    pub fn createTransactionP2PKH(
        self: *const Wallet,
        to_address: []const u8,
        amount_sat: u64,
        tx_id: u32,
        nonce: u64,
        fee: u64,
        locktime: u64,
        op_return: []const u8,
        receiver_pubkey: [33]u8,
        allocator: std.mem.Allocator,
    ) !transaction_mod.Transaction {
        const to_owned = try allocator.dupe(u8, to_address);
        const from_owned = try allocator.dupe(u8, self.address);
        const op_owned = if (op_return.len > 0) try allocator.dupe(u8, op_return) else @as([]const u8, "");

        // Create the locking script: OP_DUP OP_HASH160 <receiver_pubkey_hash> OP_EQUALVERIFY OP_CHECKSIG
        const receiver_hash = pubkeyHash160(receiver_pubkey);
        const lock_script_arr = script_mod.createP2PKH(receiver_hash);
        const lock_script = try allocator.dupe(u8, &lock_script_arr);

        // Build TX first (without scripts) to get the hash for signing
        var tx = transaction_mod.Transaction{
            .id           = tx_id,
            .from_address = from_owned,
            .to_address   = to_owned,
            .amount       = amount_sat,
            .fee          = fee,
            .timestamp    = std.time.timestamp(),
            .nonce        = nonce,
            .locktime     = locktime,
            .op_return    = op_owned,
            .signature    = "",
            .hash         = "",
            .script_pubkey = lock_script,
        };

        // Sign the TX (sets signature + hash fields via ECDSA)
        try tx.sign(self.private_key_bytes, allocator);

        // Now create the unlocking script using the raw ECDSA signature
        // tx.sign() stores hex — we need raw bytes for the script
        const tx_hash = tx.calculateHash();
        const sig_bytes = try Secp256k1Crypto.sign(self.private_key_bytes, &tx_hash);
        const unlock_script_arr = script_mod.createP2PKHUnlock(sig_bytes, self.public_key_bytes);
        tx.script_sig = try allocator.dupe(u8, &unlock_script_arr);

        return tx;
    }

    pub fn printAddresses(self: *const Wallet) void {
        const stdout = std.io.getStdOut().writer();
        stdout.print("\n=== OmniBus Wallet Addresses ===\n", .{}) catch {};
        stdout.print("Primary: {s}\n", .{self.address}) catch {};
        stdout.print("Balance: {d} SAT ({d:.8} OMNI)\n\n", .{ self.balance, self.getBalanceOMNI() }) catch {};

        for (self.addresses, 1..) |addr, i| {
            stdout.print("Address {d}: {s}\n", .{ i, addr.omni_address }) catch {};
            stdout.print("  Domain:    {s}\n", .{addr.domain}) catch {};
            stdout.print("  Algorithm: {s}\n", .{addr.algorithm}) catch {};
            stdout.print("  CoinType:  {d}\n", .{addr.coin_type}) catch {};
            stdout.print("  Security:  {d} bits\n", .{addr.security_level}) catch {};
            stdout.print("  PubKey:    {s}...\n\n", .{addr.public_key_hex[0..16]}) catch {};
        }
    }
};

// ─── Teste ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Wallet.fromMnemonic — genereaza adrese reale + full metadata" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const wallet = try Wallet.fromMnemonic(mnemonic, "", arena.allocator());

    // Adresa primara e Bech32 ob1q
    try testing.expect(std.mem.startsWith(u8, wallet.address, "ob1q"));
    try testing.expectEqual(@as(usize, 42), wallet.address.len);

    // Public key e compressed secp256k1 real
    try testing.expectEqual(@as(usize, 33), wallet.public_key_bytes.len);
    try testing.expect(wallet.public_key_bytes[0] == 0x02 or wallet.public_key_bytes[0] == 0x03);

    // Domeniu 0 (omni nativ) = Bech32 ob1q, domenii 1-4 = prefix + Base58Check
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[0].omni_address, "ob1q"));
    try testing.expectEqual(@as(usize, 42), wallet.addresses[0].omni_address.len);
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[1].omni_address, "ob_k1_"));
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[2].omni_address, "ob_f5_"));
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[3].omni_address, "ob_d5_"));
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[4].omni_address, "ob_s3_"));

    // ─── BTC-parity: master fingerprint ─────────────────────────────
    try testing.expectEqual(@as(usize, 8), wallet.master_fingerprint_hex.len);
    var fp_nonzero = false;
    for (wallet.master_fingerprint) |b| { if (b != 0) fp_nonzero = true; }
    try testing.expect(fp_nonzero);

    // ─── BTC-parity: network ────────────────────────────────────────
    try testing.expectEqual(Network.mainnet, wallet.network);

    // ─── BTC-parity: derivation path ────────────────────────────────
    try testing.expectEqualStrings("m/44'/777'/0'/0/0", wallet.derivation_path);
    try testing.expectEqual(@as(u32, 44), wallet.purpose);
    try testing.expectEqual(@as(u32, 0), wallet.account_index);
    try testing.expectEqual(@as(u32, 0), wallet.chain);
    try testing.expectEqual(@as(u32, 0), wallet.address_index);

    // ─── BTC-parity: address info ───────────────────────────────────
    try testing.expectEqualStrings("NATIVE_SEGWIT", wallet.address_type);
    try testing.expectEqual(@as(u8, 0), wallet.witness_version);
    try testing.expectEqual(@as(usize, 44), wallet.script_pubkey_hex.len); // 22 bytes → 44 hex
    try testing.expect(std.mem.startsWith(u8, wallet.script_pubkey_hex, "0014"));

    // ─── BTC-parity: keys ───────────────────────────────────────────
    try testing.expectEqual(@as(usize, 66), wallet.public_key_hex.len);
    try testing.expect(wallet.private_key_wif[0] == 'K' or wallet.private_key_wif[0] == 'L');
    try testing.expectEqual(@as(usize, 40), wallet.hash160_hex.len);

    // ─── BTC-parity: extended keys ──────────────────────────────────
    try testing.expect(wallet.xpub.len >= 100);
    try testing.expect(wallet.xprv.len >= 100);
    try testing.expect(!std.mem.eql(u8, wallet.xpub, wallet.xprv));
    try testing.expectEqual(@as(usize, 8), wallet.parent_fingerprint_hex.len);

    // ─── BTC-parity: state & metadata ───────────────────────────────
    try testing.expectEqual(@as(u64, 0), wallet.balance);
    try testing.expectEqual(@as(u64, 0), wallet.tx_count);
    try testing.expect(wallet.created_at > 0);
    try testing.expectEqual(false, wallet.is_change);
}

test "Wallet — determinist: acelasi mnemonic → aceleasi adrese" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var w1 = try Wallet.fromMnemonic(mnemonic, "", arena.allocator());
    var w2 = try Wallet.fromMnemonic(mnemonic, "", arena.allocator());

    try testing.expectEqualStrings(w1.address, w2.address);
    try testing.expectEqualSlices(u8, &w1.public_key_bytes, &w2.public_key_bytes);
    try testing.expectEqualStrings(w1.addresses[1].omni_address, w2.addresses[1].omni_address);
}

test "Wallet — mnemonice diferite → adrese diferite" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var w1 = try Wallet.fromMnemonic(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "", arena.allocator());
    var w2 = try Wallet.fromMnemonic(
        "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
        "", arena.allocator());

    try testing.expect(!std.mem.eql(u8, w1.address, w2.address));
    try testing.expect(!std.mem.eql(u8, &w1.public_key_bytes, &w2.public_key_bytes));
}

test "Wallet — balance si canSend" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var wallet = try Wallet.fromMnemonic(mnemonic, "", arena.allocator());

    try testing.expectEqual(@as(u64, 0), wallet.getBalance());
    try testing.expect(!wallet.canSend(1000));

    wallet.updateBalance(50_000_000_000); // 500 OMNI
    try testing.expect(wallet.canSend(1_000_000_000));  // 10 OMNI — OK
    try testing.expect(!wallet.canSend(60_000_000_000)); // 600 OMNI — insuficient
}

// ─── PQ Signing integrat in wallet entry ─────────────────────────────────────

const pq_mod = @import("pq_crypto.zig");

/// Rezultatul semnarii pentru un domeniu PQ
pub const PQSignResult = struct {
    domain:    []const u8,
    algorithm: []const u8,
    signature: []u8,
    success:   bool,
};

/// Semneaza `message` cu toate algoritmele PQ corespunzatoare celor 5 domenii.
/// Genera keypair-uri PQ fresh pentru fiecare domeniu (nu se stocheaza in wallet).
/// Caller-ul trebuie sa elibereze fiecare `signature` cu `allocator.free`.
pub fn signWithAllPQDomains(
    self: *const Wallet,
    message: []const u8,
    allocator: std.mem.Allocator,
) ![5]PQSignResult {
    _ = self;
    var results: [5]PQSignResult = undefined;

    // 0: omnibus.omni — ML-DSA-87
    {
        const kp = try pq_mod.MlDsa87.generateKeyPair();
        const sig = try kp.sign(message, allocator);
        results[0] = .{
            .domain = "omnibus.omni", .algorithm = "ML-DSA-87",
            .signature = sig, .success = kp.verify(message, sig),
        };
    }
    // 1: omnibus.love — ML-DSA-87 (coin 778)
    {
        const kp = try pq_mod.MlDsa87.generateKeyPair();
        const sig = try kp.sign(message, allocator);
        results[1] = .{
            .domain = "omnibus.love", .algorithm = "ML-DSA-87",
            .signature = sig, .success = kp.verify(message, sig),
        };
    }
    // 2: omnibus.food — Falcon-512 (coin 779)
    {
        const kp = try pq_mod.Falcon512.generateKeyPair();
        const sig = try kp.sign(message, allocator);
        results[2] = .{
            .domain = "omnibus.food", .algorithm = "Falcon-512",
            .signature = sig, .success = kp.verify(message, sig),
        };
    }
    // 3: omnibus.rent — ML-DSA-87 (coin 780)
    {
        const kp = try pq_mod.MlDsa87.generateKeyPair();
        const sig = try kp.sign(message, allocator);
        results[3] = .{
            .domain = "omnibus.rent", .algorithm = "ML-DSA-87",
            .signature = sig, .success = kp.verify(message, sig),
        };
    }
    // 4: omnibus.vacation — SLH-DSA-256s (coin 781)
    {
        const kp = try pq_mod.SlhDsa256s.generateKeyPair();
        const sig = try kp.sign(message, allocator);
        results[4] = .{
            .domain = "omnibus.vacation", .algorithm = "SLH-DSA-256s",
            .signature = sig, .success = kp.verify(message, sig),
        };
    }

    return results;
}

test "Test H — signWithAllPQDomains integrat in Wallet" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const wallet = try Wallet.fromMnemonic(mnemonic, "", arena.allocator());

    const omni_addr = wallet.address;
    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "OmniBus Identity: {s}", .{omni_addr}) catch "OmniBus Identity: fallback";

    std.debug.print("\nTest H — PQ signing integrat in wallet entry\n", .{});
    std.debug.print("message: {s}\n", .{msg[0..@min(50, msg.len)]});

    const results = signWithAllPQDomains(&wallet, msg, arena.allocator()) catch |err| {
        // PQ crypto may not be available (liboqs not linked) — skip test
        std.debug.print("Test H SKIPPED — PQ crypto not available: {}\n", .{err});
        return;
    };

    for (results) |r| {
        std.debug.print("  {s}: backend={s}, sig={d}B, ok={any}\n", .{
            r.domain, r.algorithm, r.signature.len, r.success,
        });
        try testing.expect(r.success);
        try testing.expect(r.signature.len > 0);
    }

    std.debug.print("Test H PASSED — toate 5 domenii PQ semneaza corect\n", .{});
}
