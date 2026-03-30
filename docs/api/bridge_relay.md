# Module: `bridge_relay`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `BridgeOperation`

O operatie de bridge (lock→mint sau burn→redeem)

*Line: 49*

### `WrappedAsset`

Wrapped asset pe OMNI chain (ex: wBTC, wETH)

*Line: 99*

### `BridgeRelay`

*Line: 112*

## Constants

| Name | Type | Value |
|------|------|-------|
| `ChainId` | auto | `oracle_mod.ChainId` |
| `ExchangeId` | auto | `oracle_mod.ExchangeId` |
| `BRIDGE_REQUIRED_SIGS` | auto | `u8 = 2` |
| `BRIDGE_MAX_RELAYERS` | auto | `u8 = 9` |
| `BRIDGE_TIMEOUT_BLOCKS` | auto | `u64 = 100` |
| `BRIDGE_FEE_BPS` | auto | `u64 = 10` |
| `BridgeOpType` | auto | `enum(u8) {` |
| `BridgeOpStatus` | auto | `enum(u8) {` |

## Functions

### `isExpired`

```zig
pub fn isExpired(self: *const BridgeOperation, current_block: u64) bool {
```

**Parameters:**

- `self`: `*const BridgeOperation`
- `current_block`: `u64`

**Returns:** `bool`

*Line: 84*

---

### `hasEnoughSigs`

```zig
pub fn hasEnoughSigs(self: *const BridgeOperation) bool {
```

**Parameters:**

- `self`: `*const BridgeOperation`

**Returns:** `bool`

*Line: 88*

---

### `calcFee`

Calculeaza fee-ul: amount * BRIDGE_FEE_BPS / 10000

```zig
pub fn calcFee(amount: u64) u64 {
```

**Parameters:**

- `amount`: `u64`

**Returns:** `u64`

*Line: 93*

---

### `circulatingSupply`

```zig
pub fn circulatingSupply(self: *const WrappedAsset) u64 {
```

**Parameters:**

- `self`: `*const WrappedAsset`

**Returns:** `u64`

*Line: 104*

---

### `deinit`

```zig
pub fn deinit(self: *BridgeRelay) void {
```

**Parameters:**

- `self`: `*BridgeRelay`

*Line: 143*

---

### `printStatus`

```zig
pub fn printStatus(self: *const BridgeRelay) void {
```

**Parameters:**

- `self`: `*const BridgeRelay`

*Line: 294*

---

