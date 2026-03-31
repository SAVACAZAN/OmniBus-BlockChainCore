# Module: `tx_receipt`

> Transaction receipts — event logs, gas used, status codes, Ethereum-compatible receipt format.

**Source:** `core/tx_receipt.zig` | **Lines:** 217 | **Functions:** 8 | **Structs:** 2 | **Tests:** 8

---

## Contents

### Structs
- [`EventLog`](#eventlog) — Event log entry (ca Ethereum LOG0-LOG4)
- [`TxReceipt`](#txreceipt) — Transaction Receipt

### Constants
- [8 constants defined](#constants)

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addTopic()`](#addtopic) — Add an indexed topic
- [`setData()`](#setdata) — Set event data
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`success()`](#success) — Mark as successful
- [`fail()`](#fail) — Mark as failed
- [`addEvent()`](#addevent) — Add event log
- [`hash()`](#hash) — Compute receipt hash (for receipt trie/merkle)

---

## Structs

### `EventLog`

Event log entry (ca Ethereum LOG0-LOG4)

| Field | Type | Description |
|-------|------|-------------|
| `event_type` | `[32]u8` | Event_type |
| `topics` | `[MAX_TOPICS][32]u8` | Topics |
| `topic_count` | `u8` | Topic_count |
| `data` | `[MAX_EVENT_DATA]u8` | Data |
| `data_len` | `u16` | Data_len |
| `block_height` | `u64` | Block_height |
| `tx_index` | `u32` | Tx_index |

*Defined at line 29*

---

### `TxReceipt`

Transaction Receipt

| Field | Type | Description |
|-------|------|-------------|
| `tx_hash` | `[32]u8` | Tx_hash |
| `status` | `TxStatus` | Status |
| `block_height` | `u64` | Block_height |
| `tx_index` | `u32` | Tx_index |
| `fee_paid` | `u64` | Fee_paid |
| `cumulative_fee` | `u64` | Cumulative_fee |
| `from_hash` | `[32]u8` | From_hash |
| `to_hash` | `[32]u8` | To_hash |
| `amount` | `u64` | Amount |
| `events` | `[MAX_EVENTS]EventLog` | Events |
| `event_count` | `u8` | Event_count |

*Defined at line 71*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `MAX_EVENTS` | `usize = 16` | M a x_ e v e n t s |
| `MAX_TOPICS` | `usize = 4` | M a x_ t o p i c s |
| `MAX_EVENT_DATA` | `usize = 256` | M a x_ e v e n t_ d a t a |
| `TxStatus` | `enum(u8) {` | Tx status |
| `EVENT_TRANSFER` | `[32]u8 = [_]u8{ 0xA9, 0x05, 0x9C, 0xBB } ++ [_]u8{0} ** 28` | E v e n t_ t r a n s f e r |
| `EVENT_APPROVAL` | `[32]u8 = [_]u8{ 0x8C, 0x5B, 0xE1, 0xE5 } ++ [_]u8{0} ** 28` | E v e n t_ a p p r o v a l |
| `EVENT_STAKE` | `[32]u8 = [_]u8{ 0xE1, 0xFF, 0xFC, 0xC4 } ++ [_]u8{0} ** 28` | E v e n t_ s t a k e |
| `EVENT_SLASH` | `[32]u8 = [_]u8{ 0x3B, 0x88, 0x1E, 0x5D } ++ [_]u8{0} ** 28` | E v e n t_ s l a s h |

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(event_type: [32]u8, block_height: u64, tx_index: u32) EventLog {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `event_type` | `[32]u8` | Event_type |
| `block_height` | `u64` | Block_height |
| `tx_index` | `u32` | Tx_index |

**Returns:** `EventLog`

*Defined at line 43*

---

### `addTopic()`

Add an indexed topic

```zig
pub fn addTopic(self: *EventLog, topic: [32]u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*EventLog` | The instance |
| `topic` | `[32]u8` | Topic |

**Returns:** `!void`

*Defined at line 56*

---

### `setData()`

Set event data

```zig
pub fn setData(self: *EventLog, data_bytes: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*EventLog` | The instance |
| `data_bytes` | `[]const u8` | Data_bytes |

**Returns:** `!void`

*Defined at line 63*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(tx_hash: [32]u8, block_height: u64, tx_index: u32) TxReceipt {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `tx_hash` | `[32]u8` | Tx_hash |
| `block_height` | `u64` | Block_height |
| `tx_index` | `u32` | Tx_index |

**Returns:** `TxReceipt`

*Defined at line 94*

---

### `success()`

Mark as successful

```zig
pub fn success(self: *TxReceipt, fee: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*TxReceipt` | The instance |
| `fee` | `u64` | Fee |

*Defined at line 111*

---

### `fail()`

Mark as failed

```zig
pub fn fail(self: *TxReceipt) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*TxReceipt` | The instance |

*Defined at line 117*

---

### `addEvent()`

Add event log

```zig
pub fn addEvent(self: *TxReceipt, event: EventLog) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*TxReceipt` | The instance |
| `event` | `EventLog` | Event |

**Returns:** `!void`

*Defined at line 122*

---

### `hash()`

Compute receipt hash (for receipt trie/merkle)

```zig
pub fn hash(self: *const TxReceipt) [32]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const TxReceipt` | The instance |

**Returns:** `[32]u8`

*Defined at line 129*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
