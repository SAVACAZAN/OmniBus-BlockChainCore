# Module: `benchmark`

> Performance benchmarks — measure hash rate, TX throughput, block validation speed, P2P latency.

**Source:** `core/benchmark.zig` | **Lines:** 628 | **Functions:** 22 | **Structs:** 3 | **Tests:** 14

---

## Contents

### Structs
- [`BenchResult`](#benchresult) — Data structure for bench result. Fields include: name, iterations, total_ns, avg...
- [`Metrics`](#metrics) — Data structure for metrics. Fields include: start_time, blocks_mined, txs_proces...
- [`Benchmark`](#benchmark) — Data structure representing a benchmark in the benchmark module.

### Functions
- [`print()`](#print) — Performs the print operation on the benchmark module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`start()`](#start) — Set the start time to now (call at runtime, not comptime)
- [`recordTx()`](#recordtx) — Record a processed transaction
- [`recordBlock()`](#recordblock) — Record a mined block
- [`recordRpcRequest()`](#recordrpcrequest) — Record an RPC request
- [`recordP2pMessage()`](#recordp2pmessage) — Record a P2P message
- [`updateHashrate()`](#updatehashrate) — Update mining hashrate from nonces tried and time taken
- [`currentTps()`](#currenttps) — Calculate current TPS from the rolling window (TXs in the last 10 seco...
- [`uptimeSeconds()`](#uptimeseconds) — Uptime in seconds
- [`avgBlockTimeMs()`](#avgblocktimems) — Average block time in ms (blocks_mined / uptime)
- [`blocksPerMinute()`](#blocksperminute) — Blocks per minute
- [`benchHashing()`](#benchhashing) — Benchmark SHA256d hashing
- [`benchKeyGen()`](#benchkeygen) — Benchmark secp256k1 key generation
- [`benchTxValidation()`](#benchtxvalidation) — Benchmark TX hash calculation (the core of TX validation)
- [`benchTxSigning()`](#benchtxsigning) — Benchmark TX creation + signing speed (secp256k1 ECDSA sign)
- [`benchMining()`](#benchmining) — Benchmark block mining (PoW) — hashes with leading zeros check
- [`benchMerkleRoot()`](#benchmerkleroot) — Benchmark merkle root calculation
- [`benchMempool()`](#benchmempool) — Benchmark mempool add/remove throughput
- [`benchHmacSha512()`](#benchhmacsha512) — Benchmark HMAC-SHA512 (BIP32 key derivation core)
- [`runAll()`](#runall) — Run all benchmarks and print results
- [`main()`](#main) — Performs the main operation on the benchmark module.

---

## Structs

### `BenchResult`

Data structure for bench result. Fields include: name, iterations, total_ns, avg_ns, ops_per_sec.

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Name |
| `iterations` | `u32` | Iterations |
| `total_ns` | `u64` | Total_ns |
| `avg_ns` | `u64` | Avg_ns |
| `ops_per_sec` | `u64` | Ops_per_sec |

*Defined at line 16*

---

### `Metrics`

Data structure for metrics. Fields include: start_time, blocks_mined, txs_processed, rpc_requests, p2p_messages.

| Field | Type | Description |
|-------|------|-------------|
| `start_time` | `i64` | Start_time |
| `blocks_mined` | `u64` | Blocks_mined |
| `txs_processed` | `u64` | Txs_processed |
| `rpc_requests` | `u64` | Rpc_requests |
| `p2p_messages` | `u64` | P2p_messages |
| `peak_tps` | `u64` | Peak_tps |
| `tx_timestamps` | `[TX_TS_RING_SIZE]i64` | Tx_timestamps |
| `tx_ts_head` | `u32` | Tx_ts_head |
| `tx_ts_count` | `u32` | Tx_ts_count |
| `last_mining_nonces` | `u64` | Last_mining_nonces |
| `last_mining_time_ns` | `u64` | Last_mining_time_ns |
| `hashrate` | `u64` | Hashrate |

*Defined at line 38*

---

### `Benchmark`

Data structure representing a benchmark in the benchmark module.

*Defined at line 157*

---

## Functions

### `print()`

Performs the print operation on the benchmark module.

```zig
pub fn print(self: *const BenchResult) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BenchResult` | The instance |

*Defined at line 23*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() Metrics {
```

**Returns:** `Metrics`

*Defined at line 54*

---

### `start()`

Set the start time to now (call at runtime, not comptime)

```zig
pub fn start(self: *Metrics) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Metrics` | The instance |

*Defined at line 72*

---

### `recordTx()`

Record a processed transaction

```zig
pub fn recordTx(self: *Metrics) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Metrics` | The instance |

*Defined at line 77*

---

### `recordBlock()`

Record a mined block

```zig
pub fn recordBlock(self: *Metrics) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Metrics` | The instance |

*Defined at line 93*

---

### `recordRpcRequest()`

Record an RPC request

```zig
pub fn recordRpcRequest(self: *Metrics) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Metrics` | The instance |

*Defined at line 98*

---

### `recordP2pMessage()`

Record a P2P message

```zig
pub fn recordP2pMessage(self: *Metrics) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Metrics` | The instance |

*Defined at line 103*

---

### `updateHashrate()`

Update mining hashrate from nonces tried and time taken

```zig
pub fn updateHashrate(self: *Metrics, nonces: u64, time_ns: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Metrics` | The instance |
| `nonces` | `u64` | Nonces |
| `time_ns` | `u64` | Time_ns |

*Defined at line 108*

---

### `currentTps()`

Calculate current TPS from the rolling window (TXs in the last 10 seconds)

```zig
pub fn currentTps(self: *const Metrics) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Metrics` | The instance |

**Returns:** `u64`

*Defined at line 118*

---

### `uptimeSeconds()`

Uptime in seconds

```zig
pub fn uptimeSeconds(self: *const Metrics) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Metrics` | The instance |

**Returns:** `u64`

*Defined at line 134*

---

### `avgBlockTimeMs()`

Average block time in ms (blocks_mined / uptime)

```zig
pub fn avgBlockTimeMs(self: *const Metrics) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Metrics` | The instance |

**Returns:** `u64`

*Defined at line 141*

---

### `blocksPerMinute()`

Blocks per minute

```zig
pub fn blocksPerMinute(self: *const Metrics) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Metrics` | The instance |

**Returns:** `u64`

*Defined at line 148*

---

### `benchHashing()`

Benchmark SHA256d hashing

```zig
pub fn benchHashing(iterations: u32) BenchResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `iterations` | `u32` | Iterations |

**Returns:** `BenchResult`

*Defined at line 159*

---

### `benchKeyGen()`

Benchmark secp256k1 key generation

```zig
pub fn benchKeyGen(iterations: u32) BenchResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `iterations` | `u32` | Iterations |

**Returns:** `BenchResult`

*Defined at line 183*

---

### `benchTxValidation()`

Benchmark TX hash calculation (the core of TX validation)

```zig
pub fn benchTxValidation(iterations: u32) BenchResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `iterations` | `u32` | Iterations |

**Returns:** `BenchResult`

*Defined at line 206*

---

### `benchTxSigning()`

Benchmark TX creation + signing speed (secp256k1 ECDSA sign)

```zig
pub fn benchTxSigning(iterations: u32) BenchResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `iterations` | `u32` | Iterations |

**Returns:** `BenchResult`

*Defined at line 242*

---

### `benchMining()`

Benchmark block mining (PoW) — hashes with leading zeros check

```zig
pub fn benchMining(difficulty: u32, max_nonces: u64) BenchResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `difficulty` | `u32` | Difficulty |
| `max_nonces` | `u64` | Max_nonces |

**Returns:** `BenchResult`

*Defined at line 272*

---

### `benchMerkleRoot()`

Benchmark merkle root calculation

```zig
pub fn benchMerkleRoot(tx_count: u32) BenchResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `tx_count` | `u32` | Tx_count |

**Returns:** `BenchResult`

*Defined at line 312*

---

### `benchMempool()`

Benchmark mempool add/remove throughput

```zig
pub fn benchMempool(iterations: u32) BenchResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `iterations` | `u32` | Iterations |

**Returns:** `BenchResult`

*Defined at line 365*

---

### `benchHmacSha512()`

Benchmark HMAC-SHA512 (BIP32 key derivation core)

```zig
pub fn benchHmacSha512(iterations: u32) BenchResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `iterations` | `u32` | Iterations |

**Returns:** `BenchResult`

*Defined at line 408*

---

### `runAll()`

Run all benchmarks and print results

```zig
pub fn runAll() void {
```

*Defined at line 434*

---

### `main()`

Performs the main operation on the benchmark module.

```zig
pub fn main() void {
```

*Defined at line 474*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
