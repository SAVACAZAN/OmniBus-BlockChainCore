# Module: `oracle`

> Price oracle — BID/ASK feeds per exchange, best ask/best bid aggregation, on-chain price attestations for DeFi.

**Source:** `core/oracle.zig` | **Lines:** 377 | **Functions:** 12 | **Structs:** 3 | **Tests:** 10

---

## Contents

### Structs
- [`ExchangeQuote`](#exchangequote) — BID/ASK de pe un exchange specific pentru un asset
Validatorul OmniBus citeste a...
- [`BridgeReferencePrice`](#bridgereferenceprice) — Pretul de referinta pentru bridge — median din mid-price-urile CEX/DEX
Acesta NU...
- [`PriceOracle`](#priceoracle) — Data structure for price oracle. Fields include: quotes, quote_valid, bridge_pri...

### Constants
- [5 constants defined](#constants)

### Functions
- [`name()`](#name) — Performs the name operation on the oracle module.
- [`name()`](#name) — Performs the name operation on the oracle module.
- [`isDex()`](#isdex) — Checks whether the dex condition is true.
- [`spread()`](#spread) — Performs the spread operation on the oracle module.
- [`midPrice()`](#midprice) — Performs the mid price operation on the oracle module.
- [`isStale()`](#isstale) — Checks whether the stale condition is true.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`submitQuote()`](#submitquote) — Submitera un quote BID/ASK de pe un exchange specific
- [`getBridgePrice()`](#getbridgeprice) — Returneaza pretul de referinta pentru bridge (median din mid-prices)
- [`bestAsk()`](#bestask) — Gaseste cel mai mic ASK (best ask) dintre toate exchange-urile pt un a...
- [`bestBid()`](#bestbid) — Gaseste cel mai mare BID (best bid) dintre toate exchange-urile pt un ...
- [`printStatus()`](#printstatus) — Performs the print status operation on the oracle module.

---

## Structs

### `ExchangeQuote`

BID/ASK de pe un exchange specific pentru un asset
Validatorul OmniBus citeste aceste date si le submitera pe chain

| Field | Type | Description |
|-------|------|-------------|
| `chain_id` | `ChainId` | Chain_id |
| `exchange_id` | `ExchangeId` | Exchange_id |
| `bid_micro_usd` | `u64` | Bid_micro_usd |
| `ask_micro_usd` | `u64` | Ask_micro_usd |
| `volume_24h_micro_usd` | `u64` | Volume_24h_micro_usd |
| `timestamp_ms` | `i64` | Timestamp_ms |

*Defined at line 90*

---

### `BridgeReferencePrice`

Pretul de referinta pentru bridge — median din mid-price-urile CEX/DEX
Acesta NU e pretul de arbitraj — e doar pretul trustless pt bridge

| Field | Type | Description |
|-------|------|-------------|
| `chain_id` | `ChainId` | Chain_id |
| `reference_micro_usd` | `u64` | Reference_micro_usd |
| `last_update_ms` | `i64` | Last_update_ms |
| `source_count` | `u8` | Source_count |
| `is_valid` | `bool` | Is_valid |

*Defined at line 117*

---

### `PriceOracle`

Data structure for price oracle. Fields include: quotes, quote_valid, bridge_prices, chain.

| Field | Type | Description |
|-------|------|-------------|
| `quotes` | `[CHAINS][MAX_EXCHANGES]ExchangeQuote` | Quotes |
| `quote_valid` | `[CHAINS][MAX_EXCHANGES]bool` | Quote_valid |
| `bridge_prices` | `[CHAINS]BridgeReferencePrice` | Bridge_prices |
| `chain` | `ChainId` | Chain |

*Defined at line 130*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `ChainId` | `enum(u8) {` | Chain id |
| `ExchangeId` | `enum(u8) {` | Exchange id |
| `MAX_PRICE_AGE_MS` | `i64 = 60_000` | M a x_ p r i c e_ a g e_ m s |
| `MAX_EXCHANGES` | `usize = 9` | M a x_ e x c h a n g e s |
| `CHAINS` | `usize = 20` | C h a i n s |

---

## Functions

### `name()`

Performs the name operation on the oracle module.

```zig
pub fn name(self: ChainId) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `ChainId` | The instance |

**Returns:** `[]const u8`

*Defined at line 39*

---

### `name()`

Performs the name operation on the oracle module.

```zig
pub fn name(self: ExchangeId) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `ExchangeId` | The instance |

**Returns:** `[]const u8`

*Defined at line 64*

---

### `isDex()`

Checks whether the dex condition is true.

```zig
pub fn isDex(self: ExchangeId) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `ExchangeId` | The instance |

**Returns:** `bool`

*Defined at line 78*

---

### `spread()`

Performs the spread operation on the oracle module.

```zig
pub fn spread(self: *const ExchangeQuote) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ExchangeQuote` | The instance |

**Returns:** `u64`

*Defined at line 101*

---

### `midPrice()`

Performs the mid price operation on the oracle module.

```zig
pub fn midPrice(self: *const ExchangeQuote) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ExchangeQuote` | The instance |

**Returns:** `u64`

*Defined at line 106*

---

### `isStale()`

Checks whether the stale condition is true.

```zig
pub fn isStale(self: *const ExchangeQuote, now_ms: i64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ExchangeQuote` | The instance |
| `now_ms` | `i64` | Now_ms |

**Returns:** `bool`

*Defined at line 110*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() PriceOracle {
```

**Returns:** `PriceOracle`

*Defined at line 138*

---

### `submitQuote()`

Submitera un quote BID/ASK de pe un exchange specific

```zig
pub fn submitQuote(self: *PriceOracle, quote: ExchangeQuote) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PriceOracle` | The instance |
| `quote` | `ExchangeQuote` | Quote |

**Returns:** `!void`

*Defined at line 156*

---

### `getBridgePrice()`

Returneaza pretul de referinta pentru bridge (median din mid-prices)

```zig
pub fn getBridgePrice(self: *const PriceOracle, chain: ChainId) !BridgeReferencePrice {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PriceOracle` | The instance |
| `chain` | `ChainId` | Chain |

**Returns:** `!BridgeReferencePrice`

*Defined at line 184*

---

### `bestAsk()`

Gaseste cel mai mic ASK (best ask) dintre toate exchange-urile pt un asset

```zig
pub fn bestAsk(self: *const PriceOracle, chain: ChainId) !ExchangeQuote {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PriceOracle` | The instance |
| `chain` | `ChainId` | Chain |

**Returns:** `!ExchangeQuote`

*Defined at line 194*

---

### `bestBid()`

Gaseste cel mai mare BID (best bid) dintre toate exchange-urile pt un asset

```zig
pub fn bestBid(self: *const PriceOracle, chain: ChainId) !ExchangeQuote {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PriceOracle` | The instance |
| `chain` | `ChainId` | Chain |

**Returns:** `!ExchangeQuote`

*Defined at line 212*

---

### `printStatus()`

Performs the print status operation on the oracle module.

```zig
pub fn printStatus(self: *const PriceOracle, chain: ChainId) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PriceOracle` | The instance |
| `chain` | `ChainId` | Chain |

*Defined at line 264*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
