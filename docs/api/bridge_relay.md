# Module: `bridge_relay`

> Ethereum bridge relay — lock-and-mint cross-chain transfers, refund on expiry, relay verification.

**Source:** `core/bridge_relay.zig` | **Lines:** 453 | **Functions:** 6 | **Structs:** 3 | **Tests:** 8

---

## Contents

### Structs
- [`BridgeOperation`](#bridgeoperation) — O operatie de bridge (lock→mint sau burn→redeem)
- [`WrappedAsset`](#wrappedasset) — Wrapped asset pe OMNI chain (ex: wBTC, wETH)
- [`BridgeRelay`](#bridgerelay) — Data structure for bridge relay. Fields include: allocator, operations, next_op_...

### Constants
- [8 constants defined](#constants)

### Functions
- [`isExpired()`](#isexpired) — Checks whether the expired condition is true.
- [`hasEnoughSigs()`](#hasenoughsigs) — Checks whether the enough sigs condition is true.
- [`calcFee()`](#calcfee) — Calculeaza fee-ul: amount * BRIDGE_FEE_BPS / 10000
- [`circulatingSupply()`](#circulatingsupply) — Performs the circulating supply operation on the bridge_relay module.
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`printStatus()`](#printstatus) — Performs the print status operation on the bridge_relay module.

---

## Structs

### `BridgeOperation`

O operatie de bridge (lock→mint sau burn→redeem)

| Field | Type | Description |
|-------|------|-------------|
| `op_id` | `u64` | Op_id |
| `op_type` | `BridgeOpType` | Op_type |
| `status` | `BridgeOpStatus` | Status |
| `foreign_chain` | `ChainId` | Foreign_chain |
| `foreign_addr` | `[64]u8` | Foreign_addr |
| `foreign_addr_len` | `u8` | Foreign_addr_len |
| `omni_addr` | `[32]u8` | Omni_addr |
| `amount_foreign` | `u64` | Amount_foreign |
| `amount_omni_sat` | `u64` | Amount_omni_sat |
| `fee_sat` | `u64` | Fee_sat |
| `foreign_tx_hash` | `[32]u8` | Foreign_tx_hash |
| `initiated_block` | `u64` | Initiated_block |
| `relayer_sigs` | `[BRIDGE_MAX_RELAYERS][64]u8` | Relayer_sigs |
| `sig_count` | `u8` | Sig_count |

*Defined at line 49*

---

### `WrappedAsset`

Wrapped asset pe OMNI chain (ex: wBTC, wETH)

| Field | Type | Description |
|-------|------|-------------|
| `chain_id` | `ChainId` | Chain_id |
| `total_minted_sat` | `u64` | Total_minted_sat |
| `total_burned_sat` | `u64` | Total_burned_sat |

*Defined at line 99*

---

### `BridgeRelay`

Data structure for bridge relay. Fields include: allocator, operations, next_op_id, wrapped, oracle.

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `operations` | `array_list.Managed(BridgeOperation)` | Operations |
| `next_op_id` | `u64` | Next_op_id |
| `wrapped` | `[20]WrappedAsset` | Wrapped |
| `oracle` | `*oracle_mod.PriceOracle` | Oracle |
| `foreign_chain` | `ChainId` | Foreign_chain |
| `foreign_addr` | `[]const u8` | Foreign_addr |
| `omni_addr` | `[32]u8` | Omni_addr |
| `amount_foreign` | `u64` | Amount_foreign |
| `foreign_tx_hash` | `[32]u8` | Foreign_tx_hash |

*Defined at line 112*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `ChainId` | `oracle_mod.ChainId` | Chain id |
| `ExchangeId` | `oracle_mod.ExchangeId` | Exchange id |
| `BRIDGE_REQUIRED_SIGS` | `u8 = 2` | B r i d g e_ r e q u i r e d_ s i g s |
| `BRIDGE_MAX_RELAYERS` | `u8 = 9` | B r i d g e_ m a x_ r e l a y e r s |
| `BRIDGE_TIMEOUT_BLOCKS` | `u64 = 100` | B r i d g e_ t i m e o u t_ b l o c k s |
| `BRIDGE_FEE_BPS` | `u64 = 10` | B r i d g e_ f e e_ b p s |
| `BridgeOpType` | `enum(u8) {` | Bridge op type |
| `BridgeOpStatus` | `enum(u8) {` | Bridge op status |

---

## Functions

### `isExpired()`

Checks whether the expired condition is true.

```zig
pub fn isExpired(self: *const BridgeOperation, current_block: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BridgeOperation` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `bool`

*Defined at line 84*

---

### `hasEnoughSigs()`

Checks whether the enough sigs condition is true.

```zig
pub fn hasEnoughSigs(self: *const BridgeOperation) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BridgeOperation` | The instance |

**Returns:** `bool`

*Defined at line 88*

---

### `calcFee()`

Calculeaza fee-ul: amount * BRIDGE_FEE_BPS / 10000

```zig
pub fn calcFee(amount: u64) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `amount` | `u64` | Amount |

**Returns:** `u64`

*Defined at line 93*

---

### `circulatingSupply()`

Performs the circulating supply operation on the bridge_relay module.

```zig
pub fn circulatingSupply(self: *const WrappedAsset) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const WrappedAsset` | The instance |

**Returns:** `u64`

*Defined at line 104*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *BridgeRelay) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BridgeRelay` | The instance |

*Defined at line 143*

---

### `printStatus()`

Performs the print status operation on the bridge_relay module.

```zig
pub fn printStatus(self: *const BridgeRelay) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BridgeRelay` | The instance |

*Defined at line 294*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
