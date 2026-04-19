# Module: `mempool`

> Transaction memory pool — FIFO queue with size/time limits, fee-based priority, duplicate detection, replace-by-nonce, and mineable TX selection.

**Source:** `core/mempool.zig` | **Lines:** 766 | **Functions:** 18 | **Structs:** 2 | **Tests:** 21

---

## Contents

### Structs
- [`MempoolEntry`](#mempoolentry) — Intrare in mempool — TX + metadata
- [`Mempool`](#mempool) — Mempool FIFO — First In First Out, anti-MEV
Modulul e independent de blockchain....

### Constants
- [8 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`add()`](#add) — Adauga o TX in mempool (FIFO — la coada)
Returneaza eroare daca e plin...
- [`getMineable()`](#getmineable) — Returns up to N mineable TXs (locktime <= current_height), FIFO order....
- [`popN()`](#popn) — Scoate primele N TX-uri din mempool (FIFO — din fata)
Folosit de miner...
- [`getByFee()`](#getbyfee) — Returns up to N entries sorted by fee descending (highest fee first).
...
- [`medianFee()`](#medianfee) — Returns the median fee from current mempool entries, or TX_MIN_FEE_SAT...
- [`removeConfirmed()`](#removeconfirmed) — Sterge toate TX-urile confirmate (dupa minarea unui bloc)
- [`size()`](#size) — Numarul de TX in asteptare
- [`bytes()`](#bytes) — Bytes totali ocupati
- [`isEmpty()`](#isempty) — Verifica daca mempool-ul e gol
- [`evictOld()`](#evictold) — Elimina TX-urile mai vechi de `max_age_sec` secunde (anti-bloat)
- [`evictExpired()`](#evictexpired) — Elimina TX-urile expirate (default: 14 zile, ca Bitcoin Core)
Fonduril...
- [`estimateMemoryUsage()`](#estimatememoryusage) — Estimare totala memorie folosita (pentru MAX_MEMPOOL_MEMORY check)
- [`maintenance()`](#maintenance) — Cleanup complet: expira vechi + verifica memorie
- [`getPendingCount()`](#getpendingcount) — Returns the number of pending TXs from a given sender address.
Used to...
- [`replaceByNonce()`](#replacebynonce) — Replace-by-nonce: if a TX with the same sender+nonce already exists in...
- [`printStats()`](#printstats) — Performs the print stats operation on the mempool module.

---

## Structs

### `MempoolEntry`

Intrare in mempool — TX + metadata

| Field | Type | Description |
|-------|------|-------------|
| `tx` | `Transaction` | Tx |
| `received_at` | `i64` | Received_at |
| `fee_sat` | `u64` | Fee_sat |
| `size_bytes` | `usize` | Size_bytes |

*Defined at line 25*

---

### `Mempool`

Mempool FIFO — First In First Out, anti-MEV
Modulul e independent de blockchain.zig — nu il modifica

| Field | Type | Description |
|-------|------|-------------|
| `entries` | `array_list.Managed(MempoolEntry)` | Entries |
| `tx_hashes` | `std.StringHashMap(void)` | Tx_hashes |
| `total_bytes` | `usize` | Total_bytes |
| `allocator` | `std.mem.Allocator` | Allocator |
| `pending_count` | `std.StringHashMap(u64)` | Pending_count |

*Defined at line 34*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `Transaction` | `transaction_mod.Transaction` | Transaction |
| `MEMPOOL_MAX_TX` | `usize = 10_000` | M e m p o o l_ m a x_ t x |
| `MEMPOOL_MAX_BYTES` | `usize = 1_048_576` | M e m p o o l_ m a x_ b y t e s |
| `MEMPOOL_MAX_MEMORY` | `usize = 314_572_800` | M e m p o o l_ m a x_ m e m o r y |
| `TX_MAX_BYTES` | `usize = 512` | T x_ m a x_ b y t e s |
| `TX_MIN_FEE_SAT` | `u64   = 1` | T x_ m i n_ f e e_ s a t |
| `MEMPOOL_EXPIRY_SEC` | `i64   = 14 * 24 * 3600` | M e m p o o l_ e x p i r y_ s e c |
| `MempoolError` | `error{` | Mempool error |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) Mempool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `Mempool`

*Defined at line 44*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *Mempool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Mempool` | The instance |

*Defined at line 54*

---

### `add()`

Adauga o TX in mempool (FIFO — la coada)
Returneaza eroare daca e plina, invalida, duplicata sau fee prea mic

```zig
pub fn add(self: *Mempool, tx: Transaction) MempoolError!void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Mempool` | The instance |
| `tx` | `Transaction` | Tx |

**Returns:** `MempoolError!void`

*Defined at line 62*

---

### `getMineable()`

Returns up to N mineable TXs (locktime <= current_height), FIFO order.
Locked TXs remain in the mempool until their locktime is reached.
Caller must free returned slice.

```zig
pub fn getMineable(self: *Mempool, n: usize, current_height: u64, allocator: std.mem.Allocator) ![]Transaction {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Mempool` | The instance |
| `n` | `usize` | N |
| `current_height` | `u64` | Current_height |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]Transaction`

*Defined at line 117*

---

### `popN()`

Scoate primele N TX-uri din mempool (FIFO — din fata)
Folosit de miner la construirea unui bloc

```zig
pub fn popN(self: *Mempool, n: usize, allocator: std.mem.Allocator) ![]Transaction {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Mempool` | The instance |
| `n` | `usize` | N |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]Transaction`

*Defined at line 179*

---

### `getByFee()`

Returns up to N entries sorted by fee descending (highest fee first).
FIFO order is used as tiebreaker when fees are equal.
Caller must free returned slice.

```zig
pub fn getByFee(self: *const Mempool, n: usize, allocator: std.mem.Allocator) ![]MempoolEntry {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Mempool` | The instance |
| `n` | `usize` | N |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]MempoolEntry`

*Defined at line 206*

---

### `medianFee()`

Returns the median fee from current mempool entries, or TX_MIN_FEE_SAT if empty.
Used by the estimatefee RPC method.

```zig
pub fn medianFee(self: *const Mempool) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Mempool` | The instance |

**Returns:** `u64`

*Defined at line 236*

---

### `removeConfirmed()`

Sterge toate TX-urile confirmate (dupa minarea unui bloc)

```zig
pub fn removeConfirmed(self: *Mempool, confirmed: []const Transaction) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Mempool` | The instance |
| `confirmed` | `[]const Transaction` | Confirmed |

*Defined at line 264*

---

### `size()`

Numarul de TX in asteptare

```zig
pub fn size(self: *const Mempool) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Mempool` | The instance |

**Returns:** `usize`

*Defined at line 301*

---

### `bytes()`

Bytes totali ocupati

```zig
pub fn bytes(self: *const Mempool) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Mempool` | The instance |

**Returns:** `usize`

*Defined at line 306*

---

### `isEmpty()`

Verifica daca mempool-ul e gol

```zig
pub fn isEmpty(self: *const Mempool) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Mempool` | The instance |

**Returns:** `bool`

*Defined at line 311*

---

### `evictOld()`

Elimina TX-urile mai vechi de `max_age_sec` secunde (anti-bloat)

```zig
pub fn evictOld(self: *Mempool, max_age_sec: i64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Mempool` | The instance |
| `max_age_sec` | `i64` | Max_age_sec |

*Defined at line 316*

---

### `evictExpired()`

Elimina TX-urile expirate (default: 14 zile, ca Bitcoin Core)
Fondurile NU se pierd — TX nu a fost niciodata scrisa in blockchain
Portofelul va debloca soldul dupa expirare

```zig
pub fn evictExpired(self: *Mempool) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Mempool` | The instance |

**Returns:** `usize`

*Defined at line 345*

---

### `estimateMemoryUsage()`

Estimare totala memorie folosita (pentru MAX_MEMPOOL_MEMORY check)

```zig
pub fn estimateMemoryUsage(self: *const Mempool) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Mempool` | The instance |

**Returns:** `usize`

*Defined at line 352*

---

### `maintenance()`

Cleanup complet: expira vechi + verifica memorie

```zig
pub fn maintenance(self: *Mempool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Mempool` | The instance |

*Defined at line 358*

---

### `getPendingCount()`

Returns the number of pending TXs from a given sender address.
Used to compute the next available nonce: chain_nonce + getPendingCount(addr)

```zig
pub fn getPendingCount(self: *const Mempool, address: []const u8) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Mempool` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `u64`

*Defined at line 390*

---

### `replaceByNonce()`

Replace-by-nonce: if a TX with the same sender+nonce already exists in mempool,
replace it (useful for fee bumping or TX cancellation).
Returns true if replacement happened, false if no existing TX with that nonce.

```zig
pub fn replaceByNonce(self: *Mempool, tx: Transaction) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Mempool` | The instance |
| `tx` | `Transaction` | Tx |

**Returns:** `bool`

*Defined at line 397*

---

### `printStats()`

Performs the print stats operation on the mempool module.

```zig
pub fn printStats(self: *const Mempool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Mempool` | The instance |

*Defined at line 428*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
