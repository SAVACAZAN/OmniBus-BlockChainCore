# Module: `compact_blocks`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `PrefilledTx`

Prefilled transaction (TX that receiver likely doesn't have)

*Line: 48*

### `CompactBlock`

Compact Block message
Sent instead of full block — ~90% bandwidth reduction

*Line: 59*

### `ReconstructResult`

Result of compact block reconstruction

*Line: 100*

### `MsgGetBlockTxn`

GetBlockTxn message — request missing TX by index

*Line: 160*

## Constants

| Name | Type | Value |
|------|------|-------|
| `SHORT_TXID_SIZE` | auto | `usize = 6` |
| `MAX_COMPACT_TX` | auto | `usize = 10_000` |
| `MAX_PREFILLED` | auto | `usize = 100` |
| `SIPHASH_KEY_SIZE` | auto | `usize = 16` |
| `ShortTxId` | auto | `[SHORT_TXID_SIZE]u8` |

## Functions

### `computeShortTxId`

Compute short TX ID from full TX hash
Uses block header hash as SipHash key for domain separation

```zig
pub fn computeShortTxId(tx_hash: [32]u8, block_nonce: u64) ShortTxId {
```

**Parameters:**

- `tx_hash`: `[32]u8`
- `block_nonce`: `u64`

**Returns:** `ShortTxId`

*Line: 33*

---

### `compactSize`

Total compact block size in bytes (header + short IDs + prefilled)

```zig
pub fn compactSize(self: *const CompactBlock) usize {
```

**Parameters:**

- `self`: `*const CompactBlock`

**Returns:** `usize`

*Line: 76*

---

### `estimatedFullSize`

Estimated full block size

```zig
pub fn estimatedFullSize(self: *const CompactBlock) usize {
```

**Parameters:**

- `self`: `*const CompactBlock`

**Returns:** `usize`

*Line: 85*

---

### `savingsPercent`

Bandwidth savings percentage

```zig
pub fn savingsPercent(self: *const CompactBlock) u8 {
```

**Parameters:**

- `self`: `*const CompactBlock`

**Returns:** `u8`

*Line: 91*

---

### `encode`

```zig
pub fn encode(self: *const MsgGetBlockTxn) [32 + 2 + MAX_COMPACT_TX * 2]u8 {
```

**Parameters:**

- `self`: `*const MsgGetBlockTxn`

**Returns:** `[32 + 2 + MAX_COMPACT_TX * 2]u8`

*Line: 165*

---

