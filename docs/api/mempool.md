# Module: `mempool`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `MempoolEntry`

Intrare in mempool — TX + metadata

*Line: 25*

### `Mempool`

Mempool FIFO — First In First Out, anti-MEV
Modulul e independent de blockchain.zig — nu il modifica

*Line: 34*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Transaction` | auto | `transaction_mod.Transaction` |
| `MEMPOOL_MAX_TX` | auto | `usize = 10_000` |
| `MEMPOOL_MAX_BYTES` | auto | `usize = 1_048_576` |
| `MEMPOOL_MAX_MEMORY` | auto | `usize = 314_572_800` |
| `TX_MAX_BYTES` | auto | `usize = 512` |
| `TX_MIN_FEE_SAT` | auto | `u64   = 1` |
| `MEMPOOL_EXPIRY_SEC` | auto | `i64   = 14 * 24 * 3600` |
| `MempoolError` | auto | `error{` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) Mempool {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `Mempool`

*Line: 40*

---

### `deinit`

```zig
pub fn deinit(self: *Mempool) void {
```

**Parameters:**

- `self`: `*Mempool`

*Line: 49*

---

### `add`

Adauga o TX in mempool (FIFO — la coada)
Returneaza eroare daca e plina, invalida, duplicata sau fee prea mic

```zig
pub fn add(self: *Mempool, tx: Transaction) MempoolError!void {
```

**Parameters:**

- `self`: `*Mempool`
- `tx`: `Transaction`

**Returns:** `MempoolError!void`

*Line: 56*

---

### `popN`

Scoate primele N TX-uri din mempool (FIFO — din fata)
Folosit de miner la construirea unui bloc

```zig
pub fn popN(self: *Mempool, n: usize, allocator: std.mem.Allocator) ![]Transaction {
```

**Parameters:**

- `self`: `*Mempool`
- `n`: `usize`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]Transaction`

*Line: 106*

---

### `removeConfirmed`

Sterge toate TX-urile confirmate (dupa minarea unui bloc)

```zig
pub fn removeConfirmed(self: *Mempool, confirmed: []const Transaction) void {
```

**Parameters:**

- `self`: `*Mempool`
- `confirmed`: `[]const Transaction`

*Line: 131*

---

### `size`

Numarul de TX in asteptare

```zig
pub fn size(self: *const Mempool) usize {
```

**Parameters:**

- `self`: `*const Mempool`

**Returns:** `usize`

*Line: 160*

---

### `bytes`

Bytes totali ocupati

```zig
pub fn bytes(self: *const Mempool) usize {
```

**Parameters:**

- `self`: `*const Mempool`

**Returns:** `usize`

*Line: 165*

---

### `isEmpty`

Verifica daca mempool-ul e gol

```zig
pub fn isEmpty(self: *const Mempool) bool {
```

**Parameters:**

- `self`: `*const Mempool`

**Returns:** `bool`

*Line: 170*

---

### `evictOld`

Elimina TX-urile mai vechi de `max_age_sec` secunde (anti-bloat)

```zig
pub fn evictOld(self: *Mempool, max_age_sec: i64) void {
```

**Parameters:**

- `self`: `*Mempool`
- `max_age_sec`: `i64`

*Line: 175*

---

### `evictExpired`

Elimina TX-urile expirate (default: 14 zile, ca Bitcoin Core)
Fondurile NU se pierd — TX nu a fost niciodata scrisa in blockchain
Portofelul va debloca soldul dupa expirare

```zig
pub fn evictExpired(self: *Mempool) usize {
```

**Parameters:**

- `self`: `*Mempool`

**Returns:** `usize`

*Line: 196*

---

### `estimateMemoryUsage`

Estimare totala memorie folosita (pentru MAX_MEMPOOL_MEMORY check)

```zig
pub fn estimateMemoryUsage(self: *const Mempool) usize {
```

**Parameters:**

- `self`: `*const Mempool`

**Returns:** `usize`

*Line: 203*

---

### `maintenance`

Cleanup complet: expira vechi + verifica memorie

```zig
pub fn maintenance(self: *Mempool) void {
```

**Parameters:**

- `self`: `*Mempool`

*Line: 209*

---

### `printStats`

```zig
pub fn printStats(self: *const Mempool) void {
```

**Parameters:**

- `self`: `*const Mempool`

*Line: 230*

---

