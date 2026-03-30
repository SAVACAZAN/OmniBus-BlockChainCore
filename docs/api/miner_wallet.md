# Module: `miner_wallet`

> Miner-specific wallet — coinbase TX creation, reward tracking, miner key management.

**Source:** `core/miner_wallet.zig` | **Lines:** 449 | **Functions:** 12 | **Structs:** 2 | **Tests:** 8

---

## Contents

### Structs
- [`MinerWallet`](#minerwallet) — MinerWallet — a lightweight wallet for virtual miners in the pool.
Each miner ge...
- [`MinerWalletPool`](#minerwalletpool) — Global miner wallet pool — stores real key pairs for each virtual miner.
Thread-...

### Constants
- [1 constants defined](#constants)

### Functions
- [`fromMnemonic()`](#frommnemonic) — Derive a MinerWallet from a BIP-39 mnemonic.
Uses BIP-32 path m/44'/77...
- [`fromRandom()`](#fromrandom) — Generate a MinerWallet from a random private key (no mnemonic).
Addres...
- [`getAddress()`](#getaddress) — Get address as a slice.
- [`getPubkeyHex()`](#getpubkeyhex) — Get public key hex as a slice.
- [`wipeKey()`](#wipekey) — Securely wipe private key from memory.
- [`registerWithRandomKey()`](#registerwithrandomkey) — Register a miner with a random key pair (no mnemonic provided).
- [`findByAddress()`](#findbyaddress) — Look up a miner wallet by address. Returns null if not found.
- [`getMinerForBlock()`](#getminerforblock) — Get miner address for a given block (round-robin, same as old MinerPoo...
- [`register()`](#register) — Register a miner in the pool (address only — for backward compat).
Als...
- [`updateBalance()`](#updatebalance) — Update cached balance for a miner wallet.
- [`pickAutoTxPair()`](#pickautotxpair) — Pick two miners with balance > threshold for auto-TX.
Returns (sender_...
- [`getWalletAt()`](#getwalletat) — Get wallet at index (for auto-TX). Caller must hold no lock.

---

## Structs

### `MinerWallet`

MinerWallet — a lightweight wallet for virtual miners in the pool.
Each miner gets a real secp256k1 key pair and can sign transactions.
Unlike the full Wallet (which derives 5 PQ domains), MinerWallet only
derives the primary OMNI key (coin_type 777) for minimal overhead.

| Field | Type | Description |
|-------|------|-------------|
| `address` | `[64]u8` | Address |
| `address_len` | `u8` | Address_len |
| `private_key` | `[32]u8` | Private_key |
| `balance_cache` | `u64` | Balance_cache |
| `has_mnemonic` | `bool` | Has_mnemonic |

*Defined at line 16*

---

### `MinerWalletPool`

Global miner wallet pool — stores real key pairs for each virtual miner.
Thread-safe: accessed from RPC thread (registration) and mining loop (auto-TX).

| Field | Type | Description |
|-------|------|-------------|
| `wallets` | `[MAX]MinerWallet` | Wallets |
| `count` | `usize` | Count |

*Defined at line 150*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MAX` | `usize = 256` | M a x |

---

## Functions

### `fromMnemonic()`

Derive a MinerWallet from a BIP-39 mnemonic.
Uses BIP-32 path m/44'/777'/0'/0/0 (OMNI primary).

```zig
pub fn fromMnemonic(mnemonic: []const u8, address_slice: []const u8, allocator: std.mem.Allocator) !MinerWallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `mnemonic` | `[]const u8` | Mnemonic |
| `address_slice` | `[]const u8` | Address_slice |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!MinerWallet`

*Defined at line 35*

---

### `fromRandom()`

Generate a MinerWallet from a random private key (no mnemonic).
Address is derived from the public key using Hash160.

```zig
pub fn fromRandom(address_slice: []const u8) !MinerWallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `address_slice` | `[]const u8` | Address_slice |

**Returns:** `!MinerWallet`

*Defined at line 66*

---

### `getAddress()`

Get address as a slice.

```zig
pub fn getAddress(self: *const MinerWallet) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerWallet` | The instance |

**Returns:** `[]const u8`

*Defined at line 103*

---

### `getPubkeyHex()`

Get public key hex as a slice.

```zig
pub fn getPubkeyHex(self: *const MinerWallet) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const MinerWallet` | The instance |

**Returns:** `[]const u8`

*Defined at line 108*

---

### `wipeKey()`

Securely wipe private key from memory.

```zig
pub fn wipeKey(self: *MinerWallet) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWallet` | The instance |

*Defined at line 141*

---

### `registerWithRandomKey()`

Register a miner with a random key pair (no mnemonic provided).

```zig
pub fn registerWithRandomKey(self: *MinerWalletPool, address: []const u8) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWalletPool` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `!bool`

*Defined at line 185*

---

### `findByAddress()`

Look up a miner wallet by address. Returns null if not found.

```zig
pub fn findByAddress(self: *MinerWalletPool, address: []const u8) ?*const MinerWallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWalletPool` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `?*const MinerWallet`

*Defined at line 204*

---

### `getMinerForBlock()`

Get miner address for a given block (round-robin, same as old MinerPool).

```zig
pub fn getMinerForBlock(self: *MinerWalletPool, block_num: u32, fallback: []const u8) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWalletPool` | The instance |
| `block_num` | `u32` | Block_num |
| `fallback` | `[]const u8` | Fallback |

**Returns:** `[]const u8`

*Defined at line 216*

---

### `register()`

Register a miner in the pool (address only — for backward compat).
Also used when the old MinerPool.register() path is called.
Uses random key derivation since no mnemonic is available.

```zig
pub fn register(self: *MinerWalletPool, addr: []const u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWalletPool` | The instance |
| `addr` | `[]const u8` | Addr |

*Defined at line 227*

---

### `updateBalance()`

Update cached balance for a miner wallet.

```zig
pub fn updateBalance(self: *MinerWalletPool, address: []const u8, balance: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWalletPool` | The instance |
| `address` | `[]const u8` | Address |
| `balance` | `u64` | Balance |

*Defined at line 232*

---

### `pickAutoTxPair()`

Pick two miners with balance > threshold for auto-TX.
Returns (sender_index, receiver_index) or null if not enough funded miners.

```zig
pub fn pickAutoTxPair(self: *MinerWalletPool, min_balance: u64) ?struct { sender: usize, receiver: usize } {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWalletPool` | The instance |
| `min_balance` | `u64` | Min_balance |

**Returns:** `?struct`

*Defined at line 246*

---

### `getWalletAt()`

Get wallet at index (for auto-TX). Caller must hold no lock.

```zig
pub fn getWalletAt(self: *MinerWalletPool, index: usize) ?MinerWallet {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MinerWalletPool` | The instance |
| `index` | `usize` | Index |

**Returns:** `?MinerWallet`

*Defined at line 275*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
