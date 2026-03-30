# Module: `genesis`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `NetworkConfig`

Configuratia retelei — schimbabila fara sa afecteze trecutul

*Line: 27*

### `GenesisState`

Starea Genesis — toate datele necesare pentru primul bloc

*Line: 120*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Block` | auto | `block_mod.Block` |
| `Transaction` | auto | `transaction_mod.Transaction` |
| `Blockchain` | auto | `blockchain_mod.Blockchain` |
| `GENESIS_TIMESTAMP` | auto | `i64 = 1_743_000_000` |
| `GENESIS_VERSION` | auto | `u32 = 1` |

## Functions

### `mainnet`

```zig
pub fn mainnet() NetworkConfig {
```

**Returns:** `NetworkConfig`

*Line: 53*

---

### `testnet`

```zig
pub fn testnet() NetworkConfig {
```

**Returns:** `NetworkConfig`

*Line: 70*

---

### `print`

```zig
pub fn print(self: *const NetworkConfig) void {
```

**Parameters:**

- `self`: `*const NetworkConfig`

*Line: 87*

---

### `init`

```zig
pub fn init(config: NetworkConfig, allocator: std.mem.Allocator) GenesisState {
```

**Parameters:**

- `config`: `NetworkConfig`
- `allocator`: `std.mem.Allocator`

**Returns:** `GenesisState`

*Line: 124*

---

### `buildBlockchain`

Construieste Blockchain-ul cu blocul genesis corect
Returneaza un Blockchain gata de mining

```zig
pub fn buildBlockchain(self: *const GenesisState) !Blockchain {
```

**Parameters:**

- `self`: `*const GenesisState`

**Returns:** `!Blockchain`

*Line: 130*

---

### `validateGenesisBlock`

Verifica daca un blockchain existent are genesis-ul corect

```zig
pub fn validateGenesisBlock(self: *const GenesisState, bc: *const Blockchain) bool {
```

**Parameters:**

- `self`: `*const GenesisState`
- `bc`: `*const Blockchain`

**Returns:** `bool`

*Line: 156*

---

### `calculateGenesisMessageHash`

Calculeaza hash-ul mesajului genesis (pentru audit)

```zig
pub fn calculateGenesisMessageHash(self: *const GenesisState) [32]u8 {
```

**Parameters:**

- `self`: `*const GenesisState`

**Returns:** `[32]u8`

*Line: 166*

---

