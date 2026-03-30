# Module: `oracle`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `ExchangeQuote`

BID/ASK de pe un exchange specific pentru un asset
Validatorul OmniBus citeste aceste date si le submitera pe chain

*Line: 90*

### `BridgeReferencePrice`

Pretul de referinta pentru bridge — median din mid-price-urile CEX/DEX
Acesta NU e pretul de arbitraj — e doar pretul trustless pt bridge

*Line: 117*

### `PriceOracle`

*Line: 130*

## Constants

| Name | Type | Value |
|------|------|-------|
| `ChainId` | auto | `enum(u8) {` |
| `ExchangeId` | auto | `enum(u8) {` |
| `MAX_PRICE_AGE_MS` | auto | `i64 = 60_000` |
| `MAX_EXCHANGES` | auto | `usize = 9` |
| `CHAINS` | auto | `usize = 20` |

## Functions

### `name`

```zig
pub fn name(self: ChainId) []const u8 {
```

**Parameters:**

- `self`: `ChainId`

**Returns:** `[]const u8`

*Line: 39*

---

### `name`

```zig
pub fn name(self: ExchangeId) []const u8 {
```

**Parameters:**

- `self`: `ExchangeId`

**Returns:** `[]const u8`

*Line: 64*

---

### `isDex`

```zig
pub fn isDex(self: ExchangeId) bool {
```

**Parameters:**

- `self`: `ExchangeId`

**Returns:** `bool`

*Line: 78*

---

### `spread`

```zig
pub fn spread(self: *const ExchangeQuote) u64 {
```

**Parameters:**

- `self`: `*const ExchangeQuote`

**Returns:** `u64`

*Line: 101*

---

### `midPrice`

```zig
pub fn midPrice(self: *const ExchangeQuote) u64 {
```

**Parameters:**

- `self`: `*const ExchangeQuote`

**Returns:** `u64`

*Line: 106*

---

### `isStale`

```zig
pub fn isStale(self: *const ExchangeQuote, now_ms: i64) bool {
```

**Parameters:**

- `self`: `*const ExchangeQuote`
- `now_ms`: `i64`

**Returns:** `bool`

*Line: 110*

---

### `init`

```zig
pub fn init() PriceOracle {
```

**Returns:** `PriceOracle`

*Line: 138*

---

### `submitQuote`

Submitera un quote BID/ASK de pe un exchange specific

```zig
pub fn submitQuote(self: *PriceOracle, quote: ExchangeQuote) !void {
```

**Parameters:**

- `self`: `*PriceOracle`
- `quote`: `ExchangeQuote`

**Returns:** `!void`

*Line: 156*

---

### `getBridgePrice`

Returneaza pretul de referinta pentru bridge (median din mid-prices)

```zig
pub fn getBridgePrice(self: *const PriceOracle, chain: ChainId) !BridgeReferencePrice {
```

**Parameters:**

- `self`: `*const PriceOracle`
- `chain`: `ChainId`

**Returns:** `!BridgeReferencePrice`

*Line: 184*

---

### `bestAsk`

Gaseste cel mai mic ASK (best ask) dintre toate exchange-urile pt un asset

```zig
pub fn bestAsk(self: *const PriceOracle, chain: ChainId) !ExchangeQuote {
```

**Parameters:**

- `self`: `*const PriceOracle`
- `chain`: `ChainId`

**Returns:** `!ExchangeQuote`

*Line: 194*

---

### `bestBid`

Gaseste cel mai mare BID (best bid) dintre toate exchange-urile pt un asset

```zig
pub fn bestBid(self: *const PriceOracle, chain: ChainId) !ExchangeQuote {
```

**Parameters:**

- `self`: `*const PriceOracle`
- `chain`: `ChainId`

**Returns:** `!ExchangeQuote`

*Line: 212*

---

### `printStatus`

```zig
pub fn printStatus(self: *const PriceOracle, chain: ChainId) void {
```

**Parameters:**

- `self`: `*const PriceOracle`
- `chain`: `ChainId`

*Line: 264*

---

