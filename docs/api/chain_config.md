# Module: `chain_config`

> Chain configuration — mainnet/testnet/regtest parameters, fee estimation, network-specific settings.

**Source:** `core/chain_config.zig` | **Lines:** 271 | **Functions:** 7 | **Structs:** 4 | **Tests:** 10

---

## Contents

### Structs
- [`Checkpoint`](#checkpoint) — Checkpoint — bloc cu hash verificat (ca Bitcoin's assumevalid)
Nodurile noi pot ...
- [`NetworkMagic`](#networkmagic) — Network magic bytes (ca Bitcoin: 0xF9BEB4D9 mainnet, 0xFABFB5DA testnet)
Primii ...
- [`ChainConfig`](#chainconfig) — Full chain configuration
- [`FeeEstimator`](#feeestimator) — Gas estimation for transaction fees
Bitcoin: estimatesmartfee RPC
Ethereum: eth_...

### Constants
- [5 constants defined](#constants)

### Functions
- [`forChain()`](#forchain) — Performs the for chain operation on the chain_config module.
- [`mainnet()`](#mainnet) — Mainnet configuration
- [`testnet()`](#testnet) — Testnet configuration (faster blocks, lower difficulty)
- [`regtest()`](#regtest) — Regtest (instant mining, difficulty 1)
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`estimateFee()`](#estimatefee) — Estimate fee in SAT for next-block inclusion
Returns: fee in SAT per t...
- [`estimateBlocks()`](#estimateblocks) — Estimate confirmation time in blocks

---

## Structs

### `Checkpoint`

Checkpoint — bloc cu hash verificat (ca Bitcoin's assumevalid)
Nodurile noi pot sari validarea PoW pentru blocuri mai vechi decat ultimul checkpoint

| Field | Type | Description |
|-------|------|-------------|
| `height` | `u64` | Height |
| `hash` | `[64]u8` | Hash |
| `timestamp` | `i64` | Timestamp |

*Defined at line 26*

---

### `NetworkMagic`

Network magic bytes (ca Bitcoin: 0xF9BEB4D9 mainnet, 0xFABFB5DA testnet)
Primii 4 bytes din fiecare mesaj P2P — identifica reteaua

| Field | Type | Description |
|-------|------|-------------|
| `bytes` | `[4]u8` | Bytes |

*Defined at line 35*

---

### `ChainConfig`

Full chain configuration

| Field | Type | Description |
|-------|------|-------------|
| `chain_id` | `ChainId` | Chain_id |
| `name` | `[]const u8` | Name |
| `magic` | `NetworkMagic` | Magic |
| `genesis_hash` | `[]const u8` | Genesis_hash |
| `genesis_timestamp` | `i64` | Genesis_timestamp |
| `p2p_port` | `u16` | P2p_port |
| `rpc_port` | `u16` | Rpc_port |
| `ws_port` | `u16` | Ws_port |
| `initial_difficulty` | `u32` | Initial_difficulty |
| `block_time_ms` | `u64` | Block_time_ms |
| `max_supply_sat` | `u64` | Max_supply_sat |
| `initial_reward_sat` | `u64` | Initial_reward_sat |
| `halving_interval` | `u64` | Halving_interval |
| `retarget_interval` | `u64` | Retarget_interval |
| `sub_blocks_per_block` | `u8` | Sub_blocks_per_block |
| `checkpoints` | `[]const Checkpoint` | Checkpoints |

*Defined at line 54*

---

### `FeeEstimator`

Gas estimation for transaction fees
Bitcoin: estimatesmartfee RPC
Ethereum: eth_estimateGas + EIP-1559 base fee
OmniBus: simplified — fee based on mempool pressure

| Field | Type | Description |
|-------|------|-------------|
| `mempool_size` | `usize` | Mempool_size |
| `mempool_max` | `usize` | Mempool_max |

*Defined at line 165*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `ChainId` | `enum(u32) {` | Chain id |
| `MAINNET` | `NetworkMagic{ .bytes = .{ 0x4F, 0x4D, 0x4E, 0x49 } }` | M a i n n e t |
| `TESTNET` | `NetworkMagic{ .bytes = .{ 0x54, 0x45, 0x53, 0x54 } }` | T e s t n e t |
| `DEVNET` | `NetworkMagic{ .bytes = .{ 0x44, 0x45, 0x56, 0x4E } }` | D e v n e t |
| `REGTEST` | `NetworkMagic{ .bytes = .{ 0x52, 0x45, 0x47, 0x54 } }` | R e g t e s t |

---

## Functions

### `forChain()`

Performs the for chain operation on the chain_config module.

```zig
pub fn forChain(chain_id: ChainId) NetworkMagic {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `chain_id` | `ChainId` | Chain_id |

**Returns:** `NetworkMagic`

*Defined at line 43*

---

### `mainnet()`

Mainnet configuration

```zig
pub fn mainnet() ChainConfig {
```

**Returns:** `ChainConfig`

*Defined at line 89*

---

### `testnet()`

Testnet configuration (faster blocks, lower difficulty)

```zig
pub fn testnet() ChainConfig {
```

**Returns:** `ChainConfig`

*Defined at line 111*

---

### `regtest()`

Regtest (instant mining, difficulty 1)

```zig
pub fn regtest() ChainConfig {
```

**Returns:** `ChainConfig`

*Defined at line 133*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(mempool_size: usize, mempool_max: usize) FeeEstimator {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `mempool_size` | `usize` | Mempool_size |
| `mempool_max` | `usize` | Mempool_max |

**Returns:** `FeeEstimator`

*Defined at line 171*

---

### `estimateFee()`

Estimate fee in SAT for next-block inclusion
Returns: fee in SAT per transaction
Algorithm: base_fee * (1 + mempool_pressure)
When mempool is empty → min fee (1 SAT)
When mempool is 50% full → 2x fee
When mempool is 100% full → 10x fee

```zig
pub fn estimateFee(self: *const FeeEstimator) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const FeeEstimator` | The instance |

**Returns:** `u64`

*Defined at line 181*

---

### `estimateBlocks()`

Estimate confirmation time in blocks

```zig
pub fn estimateBlocks(self: *const FeeEstimator, fee_sat: u64) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const FeeEstimator` | The instance |
| `fee_sat` | `u64` | Fee_sat |

**Returns:** `u32`

*Defined at line 193*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
