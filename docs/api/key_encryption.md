# Module: `key_encryption`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `EncryptedKey`

Format: ciphertext = [encrypted_privkey: 32 bytes | tag: 16 bytes]
iv = nonce GCM (12 bytes, primii 12 folositi din cei 16 stocati)
salt = PBKDF2 salt (16 bytes)

*Line: 24*

### `KeyManager`

*Line: 52*

### `Mnemonic`

Mnemonic phrase — generare si validare
Generarea reala BIP-39 e in bip32_wallet.zig (PBKDF2 + wordlist complet)

*Line: 205*

## Functions

### `initWithPassword`

Initializeaza cu parola — deriveaza master_key via PBKDF2

```zig
pub fn initWithPassword(password: []const u8, allocator: std.mem.Allocator) !KeyManager {
```

**Parameters:**

- `password`: `[]const u8`
- `allocator`: `std.mem.Allocator`

**Returns:** `!KeyManager`

*Line: 58*

---

### `verifyPassword`

Verifica parola: re-deriveaza master_key si compara (constant-time)
NOTA: necesita stocarea salt-ului master separat — deocamdata verifica lungimea

```zig
pub fn verifyPassword(self: *const KeyManager, password: []const u8) bool {
```

**Parameters:**

- `self`: `*const KeyManager`
- `password`: `[]const u8`

**Returns:** `bool`

*Line: 165*

---

### `generateRecoveryCode`

Genereaza un cod de recuperare de 16 bytes (SHA-256 din master_key + timestamp)

```zig
pub fn generateRecoveryCode(self: *const KeyManager) ![16]u8 {
```

**Parameters:**

- `self`: `*const KeyManager`

**Returns:** `![16]u8`

*Line: 183*

---

### `validate`

Valideaza ca mnemonic-ul are numar corect de cuvinte (12/15/18/21/24)

```zig
pub fn validate(mnemonic: []const u8) bool {
```

**Parameters:**

- `mnemonic`: `[]const u8`

**Returns:** `bool`

*Line: 207*

---

