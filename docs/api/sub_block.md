# Module: `sub_block`

> Sub-block engine — 10 sub-blocks × 100ms = 1 KeyBlock (1s), faster confirmation times while maintaining security.

**Source:** `core/sub_block.zig` | **Lines:** 403 | **Functions:** 11 | **Structs:** 3 | **Tests:** 7

---

## Contents

### Structs
- [`SubBlock`](#subblock) — Sub-block — confirmare soft la 0.1s
- [`KeyBlock`](#keyblock) — Data structure for key block. Fields include: block_number, sub_blocks, received...
- [`SubBlockEngine`](#subblockengine) — Data structure for sub block engine. Fields include: current_key_block, block_nu...

### Constants
- [5 constants defined](#constants)

### Functions
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`addTransaction()`](#addtransaction) — Adds a new transaction to the collection.
- [`finalize()`](#finalize) — Performs the finalize operation on the sub_block module.
- [`isValid()`](#isvalid) — Checks whether the valid condition is true.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addSubBlock()`](#addsubblock) — Adauga un sub-bloc (trebuie sa aiba sub_id unic 0-9)
Returneaza true d...
- [`finalize()`](#finalize) — Finalizeaza Key-Block-ul — calculeaza hash-ul agregat
- [`totalTxCount()`](#totaltxcount) — Total TX-uri din toate sub-blocurile
- [`latencyMs()`](#latencyms) — Latenta totala de la primul sub-bloc la finalizare (ms)
- [`missing()`](#missing) — Cate sub-blocuri lipsesc
- [`printStatus()`](#printstatus) — Performs the print status operation on the sub_block module.

---

## Structs

### `SubBlock`

Sub-block — confirmare soft la 0.1s

| Field | Type | Description |
|-------|------|-------------|
| `sub_id` | `u8` | Sub_id |
| `block_number` | `u32` | Block_number |
| `timestamp_ms` | `i64` | Timestamp_ms |
| `merkle_root` | `[32]u8` | Merkle_root |
| `shard_id` | `u8` | Shard_id |
| `miner_id` | `[]const u8` | Miner_id |
| `nonce` | `u64` | Nonce |
| `hash` | `[32]u8` | Hash |
| `tx_count` | `u32` | Tx_count |
| `transactions` | `array_list.Managed(Transaction)` | Transactions |
| `allocator` | `std.mem.Allocator` | Allocator |
| `sub_id` | `u8` | Sub_id |
| `block_number` | `u32` | Block_number |
| `shard_id` | `u8` | Shard_id |
| `miner_id` | `[]const u8` | Miner_id |

*Defined at line 18*

---

### `KeyBlock`

Data structure for key block. Fields include: block_number, sub_blocks, received, state, started_at_ms.

| Field | Type | Description |
|-------|------|-------------|
| `block_number` | `u32` | Block_number |
| `sub_blocks` | `[SUB_BLOCKS_PER_BLOCK]?SubBlock` | Sub_blocks |
| `received` | `u8` | Received |
| `state` | `KeyBlockState` | State |
| `started_at_ms` | `i64` | Started_at_ms |
| `finalized_at_ms` | `i64` | Finalized_at_ms |
| `sub_merkle_root` | `[32]u8` | Sub_merkle_root |
| `key_hash` | `[32]u8` | Key_hash |
| `total_reward_sat` | `u64` | Total_reward_sat |

*Defined at line 107*

---

### `SubBlockEngine`

Data structure for sub block engine. Fields include: current_key_block, block_number, sub_counter, miner_id, shard_id.

| Field | Type | Description |
|-------|------|-------------|
| `current_key_block` | `KeyBlock` | Current_key_block |
| `block_number` | `u32` | Block_number |
| `sub_counter` | `u8` | Sub_counter |
| `miner_id` | `[]const u8` | Miner_id |
| `shard_id` | `u8` | Shard_id |
| `allocator` | `std.mem.Allocator` | Allocator |
| `miner_id` | `[]const u8` | Miner_id |
| `shard_id` | `u8` | Shard_id |
| `allocator` | `std.mem.Allocator` | Allocator |
| `self` | `*SubBlockEngine` | Self |
| `txs` | `[]Transaction` | Txs |
| `reward_sat` | `u64` | Reward_sat |

*Defined at line 223*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `Transaction` | `transaction_mod.Transaction` | Transaction |
| `Block` | `blockchain_mod.Block` | Block |
| `SUB_BLOCKS_PER_BLOCK` | `u8 = 10` | S u b_ b l o c k s_ p e r_ b l o c k |
| `SUB_BLOCK_INTERVAL_MS` | `u64 = 75` | S u b_ b l o c k_ i n t e r v a l_ m s |
| `KeyBlockState` | `enum {` | Key block state |

---

## Functions

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *SubBlock) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SubBlock` | The instance |

*Defined at line 51*

---

### `addTransaction()`

Adds a new transaction to the collection.

```zig
pub fn addTransaction(self: *SubBlock, tx: Transaction) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SubBlock` | The instance |
| `tx` | `Transaction` | Tx |

**Returns:** `!void`

*Defined at line 55*

---

### `finalize()`

Performs the finalize operation on the sub_block module.

```zig
pub fn finalize(self: *SubBlock) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SubBlock` | The instance |

*Defined at line 60*

---

### `isValid()`

Checks whether the valid condition is true.

```zig
pub fn isValid(self: *const SubBlock) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SubBlock` | The instance |

**Returns:** `bool`

*Defined at line 89*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(block_number: u32) KeyBlock {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `block_number` | `u32` | Block_number |

**Returns:** `KeyBlock`

*Defined at line 121*

---

### `addSubBlock()`

Adauga un sub-bloc (trebuie sa aiba sub_id unic 0-9)
Returneaza true daca Key-Block-ul e complet (10/10)

```zig
pub fn addSubBlock(self: *KeyBlock, sb: SubBlock) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*KeyBlock` | The instance |
| `sb` | `SubBlock` | Sb |

**Returns:** `!bool`

*Defined at line 137*

---

### `finalize()`

Finalizeaza Key-Block-ul — calculeaza hash-ul agregat

```zig
pub fn finalize(self: *KeyBlock, reward_sat: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*KeyBlock` | The instance |
| `reward_sat` | `u64` | Reward_sat |

*Defined at line 154*

---

### `totalTxCount()`

Total TX-uri din toate sub-blocurile

```zig
pub fn totalTxCount(self: *const KeyBlock) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const KeyBlock` | The instance |

**Returns:** `u32`

*Defined at line 163*

---

### `latencyMs()`

Latenta totala de la primul sub-bloc la finalizare (ms)

```zig
pub fn latencyMs(self: *const KeyBlock) i64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const KeyBlock` | The instance |

**Returns:** `i64`

*Defined at line 172*

---

### `missing()`

Cate sub-blocuri lipsesc

```zig
pub fn missing(self: *const KeyBlock) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const KeyBlock` | The instance |

**Returns:** `u8`

*Defined at line 178*

---

### `printStatus()`

Performs the print status operation on the sub_block module.

```zig
pub fn printStatus(self: *const KeyBlock) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const KeyBlock` | The instance |

*Defined at line 209*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
