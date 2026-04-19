# Module: `spark_invariants`

> Formal verification — 17 Ada/SPARK-style compile-time invariants for critical blockchain properties.

**Source:** `core/spark_invariants.zig` | **Lines:** 297 | **Functions:** 13 | **Structs:** 2 | **Tests:** 17

---

## Contents

### Structs
- [`SupplyGuard`](#supplyguard) — SupplyGuard — tracker atomic al supply-ului emis
Orice emisie de OMNI trece prin...
- [`TemporalGuard`](#temporalguard) — Verifică că un timestamp e în ordine (monoton crescător)

### Constants
- [7 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`emit()`](#emit) — Emit reward pentru un bloc — GARANTAT că nu depășește MAX_SUPPLY_SAT
E...
- [`assertValid()`](#assertvalid) — Verifică că supply-ul curent e valid (runtime check)
Returneaza error ...
- [`remaining()`](#remaining) — Performs the remaining operation on the spark_invariants module.
- [`emittedPercent()`](#emittedpercent) — Performs the emitted percent operation on the spark_invariants module.
- [`getBlockReward()`](#getblockreward) — Calculează reward-ul pentru blocul la height dat
INVARIANT: getBlockRe...
- [`assertRewardMonotone()`](#assertrewardmonotone) — Verifică invariantul monoton: reward(h) >= reward(h+1)
Returneaza erro...
- [`totalEmittedUpTo()`](#totalemittedupto) — Calculează suma totală de recompense de la bloc 0 la bloc `height`
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`checkTimestamp()`](#checktimestamp) — Validează că noul timestamp e strict mai mare decât precedentul
INVARI...
- [`checkMicroBlockInterval()`](#checkmicroblockinterval) — Verifică că un micro-bloc e la intervalul corect (0.1s)
- [`checkedSub()`](#checkedsub) — Verifică că o operație de scădere nu produce underflow
Echivalent Ada:...
- [`checkedAdd()`](#checkedadd) — Verifică că o operație de adunare nu produce overflow sau supply viola...

---

## Structs

### `SupplyGuard`

SupplyGuard — tracker atomic al supply-ului emis
Orice emisie de OMNI trece prin acest guard
Dacă ar depăși MAX_SUPPLY_SAT → @panic (echivalent Ada: Contract_Failure)

| Field | Type | Description |
|-------|------|-------------|
| `emitted_sat` | `u64` | Emitted_sat |

*Defined at line 76*

---

### `TemporalGuard`

Verifică că un timestamp e în ordine (monoton crescător)

| Field | Type | Description |
|-------|------|-------------|
| `last_timestamp_ms` | `i64` | Last_timestamp_ms |

*Defined at line 154*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MAX_SUPPLY_SAT` | `u64 = 21_000_000 * 1_000_000_000` | M a x_ s u p p l y_ s a t |
| `INITIAL_REWARD_SAT` | `u64 = 83_333_333` | I n i t i a l_ r e w a r d_ s a t |
| `HALVING_INTERVAL` | `u64 = 126_144_000` | H a l v i n g_ i n t e r v a l |
| `MAX_HALVINGS` | `u64 = 64` | M a x_ h a l v i n g s |
| `BLOCK_TIME_MS` | `u64 = 1_000` | B l o c k_ t i m e_ m s |
| `MICRO_BLOCK_TIME_MS` | `u64 = 100` | M i c r o_ b l o c k_ t i m e_ m s |
| `MICRO_BLOCKS_PER_KEY` | `u64 = BLOCK_TIME_MS / MICRO_BLOCK_TIME_MS` | M i c r o_ b l o c k s_ p e r_ k e y |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() SupplyGuard {
```

**Returns:** `SupplyGuard`

*Defined at line 79*

---

### `emit()`

Emit reward pentru un bloc — GARANTAT că nu depășește MAX_SUPPLY_SAT
Echivalent Ada Spark: procedure Emit with
Pre  => Emitted + Amount <= Max_Supply,
Post => Emitted = Emitted'Old + Amount;

```zig
pub fn emit(self: *SupplyGuard, amount_sat: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SupplyGuard` | The instance |
| `amount_sat` | `u64` | Amount_sat |

**Returns:** `!void`

*Defined at line 87*

---

### `assertValid()`

Verifică că supply-ul curent e valid (runtime check)
Returneaza error in loc de @panic pentru graceful handling

```zig
pub fn assertValid(self: *const SupplyGuard) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SupplyGuard` | The instance |

**Returns:** `!void`

*Defined at line 97*

---

### `remaining()`

Performs the remaining operation on the spark_invariants module.

```zig
pub fn remaining(self: *const SupplyGuard) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SupplyGuard` | The instance |

**Returns:** `u64`

*Defined at line 103*

---

### `emittedPercent()`

Performs the emitted percent operation on the spark_invariants module.

```zig
pub fn emittedPercent(self: *const SupplyGuard) f64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SupplyGuard` | The instance |

**Returns:** `f64`

*Defined at line 107*

---

### `getBlockReward()`

Calculează reward-ul pentru blocul la height dat
INVARIANT: getBlockReward(h1) >= getBlockReward(h2) dacă h1 < h2
Echivalent Ada: function Block_Reward (Height : Block_Height) return Satoshi
with Post => Block_Reward'Result <= Initial_Reward;

```zig
pub fn getBlockReward(height: u64) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `height` | `u64` | Height |

**Returns:** `u64`

*Defined at line 119*

---

### `assertRewardMonotone()`

Verifică invariantul monoton: reward(h) >= reward(h+1)
Returneaza error in loc de @panic pentru recoverable handling

```zig
pub fn assertRewardMonotone(height: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `height` | `u64` | Height |

**Returns:** `!void`

*Defined at line 131*

---

### `totalEmittedUpTo()`

Calculează suma totală de recompense de la bloc 0 la bloc `height`

```zig
pub fn totalEmittedUpTo(height: u64) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `height` | `u64` | Height |

**Returns:** `u64`

*Defined at line 140*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() TemporalGuard {
```

**Returns:** `TemporalGuard`

*Defined at line 157*

---

### `checkTimestamp()`

Validează că noul timestamp e strict mai mare decât precedentul
INVARIANT: timestamp[n] > timestamp[n-1]

```zig
pub fn checkTimestamp(self: *TemporalGuard, ts_ms: i64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*TemporalGuard` | The instance |
| `ts_ms` | `i64` | Ts_ms |

**Returns:** `!void`

*Defined at line 163*

---

### `checkMicroBlockInterval()`

Verifică că un micro-bloc e la intervalul corect (0.1s)

```zig
pub fn checkMicroBlockInterval(self: *const TemporalGuard, ts_ms: i64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const TemporalGuard` | The instance |
| `ts_ms` | `i64` | Ts_ms |

**Returns:** `!void`

*Defined at line 172*

---

### `checkedSub()`

Verifică că o operație de scădere nu produce underflow
Echivalent Ada: pragma Assert (Balance >= Amount);

```zig
pub fn checkedSub(balance: u64, amount: u64) !u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `balance` | `u64` | Balance |
| `amount` | `u64` | Amount |

**Returns:** `!u64`

*Defined at line 183*

---

### `checkedAdd()`

Verifică că o operație de adunare nu produce overflow sau supply violation

```zig
pub fn checkedAdd(a: u64, b: u64) !u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `a` | `u64` | A |
| `b` | `u64` | B |

**Returns:** `!u64`

*Defined at line 189*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
