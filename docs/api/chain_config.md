# Module: `chain_config`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Checkpoint`

Checkpoint — bloc cu hash verificat (ca Bitcoin's assumevalid)
Nodurile noi pot sari validarea PoW pentru blocuri mai vechi decat ultimul checkpoint

*Line: 26*

### `NetworkMagic`

Network magic bytes (ca Bitcoin: 0xF9BEB4D9 mainnet, 0xFABFB5DA testnet)
Primii 4 bytes din fiecare mesaj P2P — identifica reteaua

*Line: 35*

### `ChainConfig`

Full chain configuration

*Line: 54*

### `FeeEstimator`

Gas estimation for transaction fees
Bitcoin: estimatesmartfee RPC
Ethereum: eth_estimateGas + EIP-1559 base fee
OmniBus: simplified — fee based on mempool pressure

*Line: 165*

## Constants

| Name | Type | Value |
|------|------|-------|
| `ChainId` | auto | `enum(u32) {` |
| `MAINNET` | auto | `NetworkMagic{ .bytes = .{ 0x4F, 0x4D, 0x4E, 0x49 }...` |
| `TESTNET` | auto | `NetworkMagic{ .bytes = .{ 0x54, 0x45, 0x53, 0x54 }...` |
| `DEVNET` | auto | `NetworkMagic{ .bytes = .{ 0x44, 0x45, 0x56, 0x4E }...` |
| `REGTEST` | auto | `NetworkMagic{ .bytes = .{ 0x52, 0x45, 0x47, 0x54 }...` |

## Functions

### `forChain`

```zig
pub fn forChain(chain_id: ChainId) NetworkMagic {
```

**Parameters:**

- `chain_id`: `ChainId`

**Returns:** `NetworkMagic`

*Line: 43*

---

### `mainnet`

Mainnet configuration

```zig
pub fn mainnet() ChainConfig {
```

**Returns:** `ChainConfig`

*Line: 89*

---

### `testnet`

Testnet configuration (faster blocks, lower difficulty)

```zig
pub fn testnet() ChainConfig {
```

**Returns:** `ChainConfig`

*Line: 111*

---

### `regtest`

Regtest (instant mining, difficulty 1)

```zig
pub fn regtest() ChainConfig {
```

**Returns:** `ChainConfig`

*Line: 133*

---

### `init`

```zig
pub fn init(mempool_size: usize, mempool_max: usize) FeeEstimator {
```

**Parameters:**

- `mempool_size`: `usize`
- `mempool_max`: `usize`

**Returns:** `FeeEstimator`

*Line: 171*

---

### `estimateFee`

Estimate fee in SAT for next-block inclusion
Returns: fee in SAT per transaction
Algorithm: base_fee * (1 + mempool_pressure)
When mempool is empty → min fee (1 SAT)
When mempool is 50% full → 2x fee
When mempool is 100% full → 10x fee

```zig
pub fn estimateFee(self: *const FeeEstimator) u64 {
```

**Parameters:**

- `self`: `*const FeeEstimator`

**Returns:** `u64`

*Line: 181*

---

### `estimateBlocks`

Estimate confirmation time in blocks

```zig
pub fn estimateBlocks(self: *const FeeEstimator, fee_sat: u64) u32 {
```

**Parameters:**

- `self`: `*const FeeEstimator`
- `fee_sat`: `u64`

**Returns:** `u32`

*Line: 193*

---

