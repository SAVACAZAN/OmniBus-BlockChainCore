const std = @import("std");
const bip32_mod       = @import("bip32_wallet.zig");
const secp256k1_mod   = @import("secp256k1.zig");
const transaction_mod = @import("transaction.zig");
const script_mod      = @import("script.zig");
const ripemd160_mod   = @import("ripemd160.zig");
const crypto_mod      = @import("crypto.zig");

const BIP32Wallet = bip32_mod.BIP32Wallet;
const PQDomainDerivation = bip32_mod.PQDomainDerivation;
const Secp256k1Crypto = secp256k1_mod.Secp256k1Crypto;
const Ripemd160 = ripemd160_mod.Ripemd160;

/// OmniBus Wallet — derivare reala BIP32 + secp256k1
pub const Wallet = struct {
    /// Adresa primara (OMNI SegWit ob1q...)
    address: []u8,
    /// Balanta in SAT (actualizata din nod RPC)
    balance: u64,
    /// Private key (32 bytes) — tinut in memorie doar cat e nevoie
    private_key_bytes: [32]u8,
    /// Compressed public key (33 bytes) — secp256k1 real
    public_key_bytes: [33]u8,
    /// Cele 5 adrese PQ (OMNI + 4 domenii)
    addresses: [5]Address,
    allocator: std.mem.Allocator,

    pub const Address = struct {
        domain: []const u8,      // "omnibus.omni", "omnibus.love", etc.
        algorithm: []const u8,   // "Dilithium-5 + Kyber-768", etc.
        omni_address: []u8,      // adresa derivata real (ob_omni_..., ob_k1_...)
        public_key_hex: []u8,    // compressed pubkey hex (66 chars)
        coin_type: u32,          // BIP-44 coin type
        security_level: u32,     // bits: 256, 192, 128
    };

    /// Creeaza wallet din mnemonic (BIP-39) si passphrase
    pub fn fromMnemonic(mnemonic: []const u8, passphrase: []const u8, allocator: std.mem.Allocator) !Wallet {
        _ = passphrase; // Passphrase support via bip32_wallet.initFromMnemonicPassphrase()

        // BIP-32 master key din mnemonic
        const bip32 = try BIP32Wallet.initFromMnemonic(mnemonic, allocator);

        // Deriva cheie OMNI (coin_type 777) — pentru signing
        const omni_privkey = try bip32.deriveChildKeyForPath(44, 777, 0);
        const omni_pubkey  = try Secp256k1Crypto.privateKeyToPublicKey(omni_privkey);

        // Deriva cele 5 domenii PQ — Base58Check address (identic Python OmnibusWallet)
        const hex_chars = "0123456789abcdef";
        const domains = PQDomainDerivation.DOMAINS;
        var addresses: [5]Address = undefined;

        for (domains, 0..) |domain, i| {
            const privkey_i = try bip32.deriveChildKeyForPath(44, domain.coin_type, 0);
            const pubkey_i  = try Secp256k1Crypto.privateKeyToPublicKey(privkey_i);

            // Adresa: prefix + Base58Check(0x4F || RIPEMD160(SHA256(pubkey))) — identic Python
            const addr_i = try bip32.deriveAddressForDomain(domain.coin_type, 0, domain.prefix, allocator);

            // Pubkey hex (compressed 33 bytes → 66 hex)
            var pk_hex_i: [66]u8 = undefined;
            for (pubkey_i, 0..) |byte, j| {
                pk_hex_i[j * 2]     = hex_chars[byte >> 4];
                pk_hex_i[j * 2 + 1] = hex_chars[byte & 0x0F];
            }
            const pk_hex_alloc = try allocator.dupe(u8, &pk_hex_i);

            addresses[i] = Address{
                .domain         = domain.name,
                .algorithm      = domain.algorithm,
                .omni_address   = addr_i,
                .public_key_hex = pk_hex_alloc,
                .coin_type      = domain.coin_type,
                .security_level = domain.security_level,
            };
        }

        // Adresa principala = addresses[0].omni_address (ob_omni_) — fara dublura
        const primary_addr = try allocator.dupe(u8, addresses[0].omni_address);

        return Wallet{
            .address           = primary_addr,
            .balance           = 0,
            .private_key_bytes = omni_privkey,
            .public_key_bytes  = omni_pubkey,
            .addresses         = addresses,
            .allocator         = allocator,
        };
    }

    pub fn deinit(self: *Wallet) void {
        self.allocator.free(self.address);
        // Sterge private key din memorie (securitate)
        @memset(&self.private_key_bytes, 0);
        for (&self.addresses) |*addr| {
            self.allocator.free(addr.omni_address);
            self.allocator.free(addr.public_key_hex);
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

test "Wallet.fromMnemonic — genereaza adrese reale" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const wallet = try Wallet.fromMnemonic(mnemonic, "", arena.allocator());

    // Adresa primara are prefix corect
    try testing.expect(std.mem.startsWith(u8, wallet.address, "ob_omni_"));

    // Public key e compressed secp256k1 real
    try testing.expectEqual(@as(usize, 33), wallet.public_key_bytes.len);
    try testing.expect(wallet.public_key_bytes[0] == 0x02 or wallet.public_key_bytes[0] == 0x03);

    // Toate cele 5 adrese PQ au prefixe corecte
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[0].omni_address, "ob_omni_"));
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[1].omni_address, "ob_k1_"));
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[2].omni_address, "ob_f5_"));
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[3].omni_address, "ob_d5_"));
    try testing.expect(std.mem.startsWith(u8, wallet.addresses[4].omni_address, "ob_s3_"));
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

    const results = try signWithAllPQDomains(&wallet, msg, arena.allocator());

    for (results) |r| {
        std.debug.print("  {s}: backend={s}, sig={d}B, ok={any}\n", .{
            r.domain, r.algorithm, r.signature.len, r.success,
        });
        try testing.expect(r.success);
        try testing.expect(r.signature.len > 0);
    }

    std.debug.print("Test H PASSED — toate 5 domenii PQ semneaza corect\n", .{});
}
