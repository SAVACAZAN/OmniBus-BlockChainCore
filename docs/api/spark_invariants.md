# Module: `spark_invariants`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `SupplyGuard`

SupplyGuard — tracker atomic al supply-ului emis
Orice emisie de OMNI trece prin acest guard
Dacă ar depăși MAX_SUPPLY_SAT → @panic (echivalent Ada: Contract_Failure)

*Line: 76*

### `TemporalGuard`

Verifică că un timestamp e în ordine (monoton crescător)

*Line: 154*

## Constants

| Name | Type | Value |
|------|------|-------|
| `MAX_SUPPLY_SAT` | auto | `u64 = 21_000_000 * 1_000_000_000` |
| `INITIAL_REWARD_SAT` | auto | `u64 = 83_333_333` |
| `HALVING_INTERVAL` | auto | `u64 = 126_144_000` |
| `MAX_HALVINGS` | auto | `u64 = 64` |
| `BLOCK_TIME_MS` | auto | `u64 = 1_000` |
| `MICRO_BLOCK_TIME_MS` | auto | `u64 = 100` |
| `MICRO_BLOCKS_PER_KEY` | auto | `u64 = BLOCK_TIME_MS / MICRO_BLOCK_TIME_MS` |

## Functions

### `init`

```zig
pub fn init() SupplyGuard {
```

**Returns:** `SupplyGuard`

*Line: 79*

---

### `emit`

Emit reward pentru un bloc — GARANTAT că nu depășește MAX_SUPPLY_SAT
Echivalent Ada Spark: procedure Emit with
Pre  => Emitted + Amount <= Max_Supply,
Post => Emitted = Emitted'Old + Amount;

```zig
pub fn emit(self: *SupplyGuard, amount_sat: u64) !void {
```

**Parameters:**

- `self`: `*SupplyGuard`
- `amount_sat`: `u64`

**Returns:** `!void`

*Line: 87*

---

### `assertValid`

Verifică că supply-ul curent e valid (runtime check)
Returneaza error in loc de @panic pentru graceful handling

```zig
pub fn assertValid(self: *const SupplyGuard) !void {
```

**Parameters:**

- `self`: `*const SupplyGuard`

**Returns:** `!void`

*Line: 97*

---

### `remaining`

```zig
pub fn remaining(self: *const SupplyGuard) u64 {
```

**Parameters:**

- `self`: `*const SupplyGuard`

**Returns:** `u64`

*Line: 103*

---

### `emittedPercent`

```zig
pub fn emittedPercent(self: *const SupplyGuard) f64 {
```

**Parameters:**

- `self`: `*const SupplyGuard`

**Returns:** `f64`

*Line: 107*

---

### `getBlockReward`

Calculează reward-ul pentru blocul la height dat
INVARIANT: getBlockReward(h1) >= getBlockReward(h2) dacă h1 < h2
Echivalent Ada: function Block_Reward (Height : Block_Height) return Satoshi
with Post => Block_Reward'Result <= Initial_Reward;

```zig
pub fn getBlockReward(height: u64) u64 {
```

**Parameters:**

- `height`: `u64`

**Returns:** `u64`

*Line: 119*

---

### `assertRewardMonotone`

Verifică invariantul monoton: reward(h) >= reward(h+1)
Returneaza error in loc de @panic pentru recoverable handling

```zig
pub fn assertRewardMonotone(height: u64) !void {
```

**Parameters:**

- `height`: `u64`

**Returns:** `!void`

*Line: 131*

---

### `totalEmittedUpTo`

Calculează suma totală de recompense de la bloc 0 la bloc `height`

```zig
pub fn totalEmittedUpTo(height: u64) u64 {
```

**Parameters:**

- `height`: `u64`

**Returns:** `u64`

*Line: 140*

---

### `init`

```zig
pub fn init() TemporalGuard {
```

**Returns:** `TemporalGuard`

*Line: 157*

---

### `checkTimestamp`

Validează că noul timestamp e strict mai mare decât precedentul
INVARIANT: timestamp[n] > timestamp[n-1]

```zig
pub fn checkTimestamp(self: *TemporalGuard, ts_ms: i64) !void {
```

**Parameters:**

- `self`: `*TemporalGuard`
- `ts_ms`: `i64`

**Returns:** `!void`

*Line: 163*

---

### `checkMicroBlockInterval`

Verifică că un micro-bloc e la intervalul corect (0.1s)

```zig
pub fn checkMicroBlockInterval(self: *const TemporalGuard, ts_ms: i64) !void {
```

**Parameters:**

- `self`: `*const TemporalGuard`
- `ts_ms`: `i64`

**Returns:** `!void`

*Line: 172*

---

### `checkedSub`

Verifică că o operație de scădere nu produce underflow
Echivalent Ada: pragma Assert (Balance >= Amount);

```zig
pub fn checkedSub(balance: u64, amount: u64) !u64 {
```

**Parameters:**

- `balance`: `u64`
- `amount`: `u64`

**Returns:** `!u64`

*Line: 183*

---

### `checkedAdd`

Verifică că o operație de adunare nu produce overflow sau supply violation

```zig
pub fn checkedAdd(a: u64, b: u64) !u64 {
```

**Parameters:**

- `a`: `u64`
- `b`: `u64`

**Returns:** `!u64`

*Line: 189*

---

