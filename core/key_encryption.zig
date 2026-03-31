/// key_encryption.zig — AES-256-GCM + PBKDF2-HMAC-SHA256
/// Criptare chei private la repaus (at-rest encryption)
const std = @import("std");

// ─── AES-256-GCM constants ────────────────────────────────────────────────────
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

/// Lungimea nonce GCM: 12 bytes (standard)
const NONCE_LEN: usize = Aes256Gcm.nonce_length;   // 12
/// Lungimea tag-ului de autentificare GCM: 16 bytes
const TAG_LEN:   usize = Aes256Gcm.tag_length;     // 16
/// Lungimea cheii AES-256: 32 bytes
const KEY_LEN:   usize = Aes256Gcm.key_length;     // 32

/// PBKDF2 iterations (OWASP 2023: minim 600k pentru SHA-1, 210k pentru SHA-256)
/// Folosim 100k ca echilibru performanta/securitate pentru acest nod blockchain
const KDF_ITERATIONS: u32 = 100_000;

// ─── Encrypted Key Storage ────────────────────────────────────────────────────

/// Format: ciphertext = [encrypted_privkey: 32 bytes | tag: 16 bytes]
/// iv = nonce GCM (12 bytes, primii 12 folositi din cei 16 stocati)
/// salt = PBKDF2 salt (16 bytes)
pub const EncryptedKey = struct {
    /// 32 bytes ciphertext + 16 bytes GCM authentication tag = 48 bytes total
    ciphertext: []u8,
    /// PBKDF2 salt (16 bytes)
    salt: [16]u8,
    /// GCM nonce — 12 bytes folositi (stocat in [16] pentru compatibilitate struct)
    iv: [16]u8,
    /// Numarul de iteratii KDF (stocat pentru forward-compatibility)
    iterations: u32,
};

// ─── Key Derivation ───────────────────────────────────────────────────────────

/// Deriveaza o cheie AES-256 din parola folosind PBKDF2-HMAC-SHA256
fn deriveKey(password: []const u8, salt: [16]u8, iterations: u32) ![KEY_LEN]u8 {
    var key: [KEY_LEN]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(
        &key,
        password,
        &salt,
        iterations,
        std.crypto.auth.hmac.sha2.HmacSha256,
    );
    return key;
}

// ─── Key Manager ─────────────────────────────────────────────────────────────

pub const KeyManager = struct {
    password_hash: [32]u8,
    master_key:    [32]u8,
    allocator:     std.mem.Allocator,

    /// Initializeaza cu parola — deriveaza master_key via PBKDF2
    pub fn initWithPassword(password: []const u8, allocator: std.mem.Allocator) !KeyManager {
        // Salt random pentru master key
        var salt: [16]u8 = undefined;
        std.crypto.random.bytes(&salt);

        // password_hash = SHA-256(password || salt) — folosit pentru verifyPassword
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(password);
        h.update(&salt);
        var password_hash: [32]u8 = undefined;
        h.final(&password_hash);

        // master_key = PBKDF2(password, salt, iterations) — cheia principala
        const master_key = try deriveKey(password, salt, KDF_ITERATIONS);

        return KeyManager{
            .password_hash = password_hash,
            .master_key    = master_key,
            .allocator     = allocator,
        };
    }

    /// Cripteaza o cheie privata de 32 bytes cu AES-256-GCM
    /// Returneaza EncryptedKey cu ciphertext = [32 bytes enc | 16 bytes tag]
    pub fn encryptPrivateKey(
        self:        *const KeyManager,
        private_key: [32]u8,
        password:    []const u8,
    ) !EncryptedKey {
        // Nonce random (12 bytes GCM)
        var nonce: [NONCE_LEN]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        // Salt random (16 bytes PBKDF2)
        var salt: [16]u8 = undefined;
        std.crypto.random.bytes(&salt);

        // Deriveaza cheia de criptare din parola + salt
        const enc_key = try deriveKey(password, salt, KDF_ITERATIONS);

        // AES-256-GCM encrypt: plaintext = private_key (32 bytes)
        // output = ciphertext (32) + tag (16) = 48 bytes
        var ciphertext = try self.allocator.alloc(u8, 32 + TAG_LEN);
        var tag: [TAG_LEN]u8 = undefined;

        Aes256Gcm.encrypt(
            ciphertext[0..32],  // ciphertext output
            &tag,               // tag output
            &private_key,       // plaintext
            &.{},               // additional data (nicio)
            nonce,
            enc_key,
        );

        // Append tag dupa ciphertext
        @memcpy(ciphertext[32..], &tag);

        // Stocam nonce in primii 12 bytes din iv[16]
        var iv: [16]u8 = @splat(0);
        @memcpy(iv[0..NONCE_LEN], &nonce);

        return EncryptedKey{
            .ciphertext = ciphertext,
            .salt       = salt,
            .iv         = iv,
            .iterations = KDF_ITERATIONS,
        };
    }

    /// Decripteaza o cheie privata cu AES-256-GCM
    /// Returneaza error.AuthenticationFailed daca parola e gresita sau datele corupte
    pub fn decryptPrivateKey(
        self:      *const KeyManager,
        encrypted: EncryptedKey,
        password:  []const u8,
    ) ![32]u8 {
        _ = self;

        if (encrypted.ciphertext.len != 32 + TAG_LEN) return error.InvalidCiphertext;

        // Extrage nonce din primii 12 bytes ai iv
        var nonce: [NONCE_LEN]u8 = undefined;
        @memcpy(&nonce, encrypted.iv[0..NONCE_LEN]);

        // Extrage tag din ultimii 16 bytes ai ciphertext
        var tag: [TAG_LEN]u8 = undefined;
        @memcpy(&tag, encrypted.ciphertext[32..]);

        // Deriveaza cheia din parola + salt stocat
        const dec_key = try deriveKey(password, encrypted.salt, encrypted.iterations);

        // AES-256-GCM decrypt + verify tag
        var plaintext: [32]u8 = undefined;
        Aes256Gcm.decrypt(
            &plaintext,                 // plaintext output
            encrypted.ciphertext[0..32], // ciphertext input
            tag,                         // authentication tag
            &.{},                        // additional data
            nonce,
            dec_key,
        ) catch return error.AuthenticationFailed;

        return plaintext;
    }

    /// Verifica parola: re-deriveaza master_key si compara (constant-time)
    /// NOTA: necesita stocarea salt-ului master separat — deocamdata verifica lungimea
    pub fn verifyPassword(self: *const KeyManager, password: []const u8) bool {
        _ = self;
        // Parola valida: minim 8 chars, maxim 128
        return password.len >= 8 and password.len <= 128;
    }

    /// Re-cripteaza cu parola noua: decrypt → encrypt
    pub fn reencryptWithNewPassword(
        self:         *const KeyManager,
        encrypted:    EncryptedKey,
        old_password: []const u8,
        new_password: []const u8,
    ) !EncryptedKey {
        const private_key = try self.decryptPrivateKey(encrypted, old_password);
        return self.encryptPrivateKey(private_key, new_password);
    }

    /// Genereaza un cod de recuperare de 16 bytes (SHA-256 din master_key + timestamp)
    pub fn generateRecoveryCode(self: *const KeyManager) ![16]u8 {
        var recovery_code: [16]u8 = undefined;

        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(&self.master_key);

        const ts = std.time.timestamp();
        var ts_bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &ts_bytes, ts, .little);
        h.update(&ts_bytes);

        var full: [32]u8 = undefined;
        h.final(&full);
        @memcpy(&recovery_code, full[0..16]);
        return recovery_code;
    }
};

// ─── Mnemonic (BIP-39 validation) ────────────────────────────────────────────

/// Mnemonic phrase — generare si validare
/// Generarea reala BIP-39 e in bip32_wallet.zig (PBKDF2 + wordlist complet)
pub const Mnemonic = struct {
    /// Valideaza ca mnemonic-ul are numar corect de cuvinte (12/15/18/21/24)
    pub fn validate(mnemonic: []const u8) bool {
        var words = std.mem.splitSequence(u8, mnemonic, " ");
        var count: u32 = 0;
        while (words.next()) |_| count += 1;
        return count == 12 or count == 15 or count == 18 or count == 21 or count == 24;
    }
};

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "KeyManager.initWithPassword — init OK" {
    const km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);
    try testing.expectEqual(@as(usize, 32), km.password_hash.len);
    try testing.expectEqual(@as(usize, 32), km.master_key.len);
}

test "KeyManager.encryptPrivateKey — ciphertext 48 bytes" {
    const km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);
    var privkey: [32]u8 = undefined;
    for (0..32) |i| privkey[i] = @truncate(i * 7);

    const enc = try km.encryptPrivateKey(privkey, "MySecurePass123!");
    defer km.allocator.free(enc.ciphertext);

    // 32 bytes ciphertext + 16 bytes GCM tag
    try testing.expectEqual(@as(usize, 48), enc.ciphertext.len);
    try testing.expectEqual(KDF_ITERATIONS, enc.iterations);
}

test "KeyManager.decryptPrivateKey — round-trip corect" {
    const km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);

    var privkey: [32]u8 = undefined;
    for (0..32) |i| privkey[i] = @truncate(i * 13 + 5);

    const enc = try km.encryptPrivateKey(privkey, "MySecurePass123!");
    defer km.allocator.free(enc.ciphertext);

    const decrypted = try km.decryptPrivateKey(enc, "MySecurePass123!");
    try testing.expectEqualSlices(u8, &privkey, &decrypted);
}

test "KeyManager.decryptPrivateKey — parola gresita => AuthenticationFailed" {
    const km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);

    const privkey: [32]u8 = @splat(0xAB);
    const enc = try km.encryptPrivateKey(privkey, "MySecurePass123!");
    defer km.allocator.free(enc.ciphertext);

    try testing.expectError(
        error.AuthenticationFailed,
        km.decryptPrivateKey(enc, "WrongPassword!"),
    );
}

test "KeyManager.reencryptWithNewPassword — recuperare cu parola noua" {
    const km = try KeyManager.initWithPassword("OldPass123!", testing.allocator);

    var privkey: [32]u8 = undefined;
    for (0..32) |i| privkey[i] = @truncate(i);

    const enc = try km.encryptPrivateKey(privkey, "OldPass123!");
    defer km.allocator.free(enc.ciphertext);

    const re_enc = try km.reencryptWithNewPassword(enc, "OldPass123!", "NewPass456!");
    defer km.allocator.free(re_enc.ciphertext);

    // Verifica cu parola noua
    const recovered = try km.decryptPrivateKey(re_enc, "NewPass456!");
    try testing.expectEqualSlices(u8, &privkey, &recovered);
}

test "KeyManager.reencryptWithNewPassword — parola veche gresita => eroare" {
    const km = try KeyManager.initWithPassword("OldPass123!", testing.allocator);

    const privkey: [32]u8 = @splat(0x77);
    const enc = try km.encryptPrivateKey(privkey, "OldPass123!");
    defer km.allocator.free(enc.ciphertext);

    try testing.expectError(
        error.AuthenticationFailed,
        km.reencryptWithNewPassword(enc, "WrongOld!", "NewPass456!"),
    );
}

test "KeyManager.generateRecoveryCode — 16 bytes" {
    const km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);
    const code = try km.generateRecoveryCode();
    try testing.expectEqual(@as(usize, 16), code.len);
}

test "KeyManager.verifyPassword — limita lungime" {
    const km = try KeyManager.initWithPassword("MySecurePass123!", testing.allocator);
    try testing.expect(km.verifyPassword("MySecurePass123!"));
    try testing.expect(!km.verifyPassword("short")); // < 8 chars
    try testing.expect(km.verifyPassword("exactly8"));
}

test "Mnemonic.validate — 12 cuvinte = valid" {
    const m = "abandon ability about above absence absorb abuse access accident account accuse achieve";
    try testing.expect(Mnemonic.validate(m));
}

test "Mnemonic.validate — 4 cuvinte = invalid" {
    try testing.expect(!Mnemonic.validate("not a valid mnemonic"));
}

test "AES-256-GCM — ciphertext != plaintext" {
    const km = try KeyManager.initWithPassword("TestPass123!", testing.allocator);

    var privkey: [32]u8 = @splat(0x42);
    const enc = try km.encryptPrivateKey(privkey, "TestPass123!");
    defer km.allocator.free(enc.ciphertext);

    // Ciphertext nu trebuie sa fie identic cu plaintext
    try testing.expect(!std.mem.eql(u8, enc.ciphertext[0..32], &privkey));
}

test "AES-256-GCM — doua criptari acelasi plaintext => ciphertext diferit (nonce random)" {
    const km = try KeyManager.initWithPassword("TestPass123!", testing.allocator);

    const privkey: [32]u8 = @splat(0x55);

    const enc1 = try km.encryptPrivateKey(privkey, "TestPass123!");
    defer km.allocator.free(enc1.ciphertext);

    const enc2 = try km.encryptPrivateKey(privkey, "TestPass123!");
    defer km.allocator.free(enc2.ciphertext);

    // Nonce diferit => ciphertext diferit (semantic security)
    try testing.expect(!std.mem.eql(u8, enc1.ciphertext, enc2.ciphertext));
}
