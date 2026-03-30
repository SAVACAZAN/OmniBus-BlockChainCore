# Module: `tx_receipt`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `EventLog`

Event log entry (ca Ethereum LOG0-LOG4)

*Line: 29*

### `TxReceipt`

Transaction Receipt

*Line: 71*

## Constants

| Name | Type | Value |
|------|------|-------|
| `MAX_EVENTS` | auto | `usize = 16` |
| `MAX_TOPICS` | auto | `usize = 4` |
| `MAX_EVENT_DATA` | auto | `usize = 256` |
| `TxStatus` | auto | `enum(u8) {` |
| `EVENT_TRANSFER` | auto | `[32]u8 = [_]u8{ 0xA9, 0x05, 0x9C, 0xBB } ++ [_]u8{...` |
| `EVENT_APPROVAL` | auto | `[32]u8 = [_]u8{ 0x8C, 0x5B, 0xE1, 0xE5 } ++ [_]u8{...` |
| `EVENT_STAKE` | auto | `[32]u8 = [_]u8{ 0xE1, 0xFF, 0xFC, 0xC4 } ++ [_]u8{...` |
| `EVENT_SLASH` | auto | `[32]u8 = [_]u8{ 0x3B, 0x88, 0x1E, 0x5D } ++ [_]u8{...` |

## Functions

### `init`

```zig
pub fn init(event_type: [32]u8, block_height: u64, tx_index: u32) EventLog {
```

**Parameters:**

- `event_type`: `[32]u8`
- `block_height`: `u64`
- `tx_index`: `u32`

**Returns:** `EventLog`

*Line: 43*

---

### `addTopic`

Add an indexed topic

```zig
pub fn addTopic(self: *EventLog, topic: [32]u8) !void {
```

**Parameters:**

- `self`: `*EventLog`
- `topic`: `[32]u8`

**Returns:** `!void`

*Line: 56*

---

### `setData`

Set event data

```zig
pub fn setData(self: *EventLog, data_bytes: []const u8) !void {
```

**Parameters:**

- `self`: `*EventLog`
- `data_bytes`: `[]const u8`

**Returns:** `!void`

*Line: 63*

---

### `init`

```zig
pub fn init(tx_hash: [32]u8, block_height: u64, tx_index: u32) TxReceipt {
```

**Parameters:**

- `tx_hash`: `[32]u8`
- `block_height`: `u64`
- `tx_index`: `u32`

**Returns:** `TxReceipt`

*Line: 94*

---

### `success`

Mark as successful

```zig
pub fn success(self: *TxReceipt, fee: u64) void {
```

**Parameters:**

- `self`: `*TxReceipt`
- `fee`: `u64`

*Line: 111*

---

### `fail`

Mark as failed

```zig
pub fn fail(self: *TxReceipt) void {
```

**Parameters:**

- `self`: `*TxReceipt`

*Line: 117*

---

### `addEvent`

Add event log

```zig
pub fn addEvent(self: *TxReceipt, event: EventLog) !void {
```

**Parameters:**

- `self`: `*TxReceipt`
- `event`: `EventLog`

**Returns:** `!void`

*Line: 122*

---

### `hash`

Compute receipt hash (for receipt trie/merkle)

```zig
pub fn hash(self: *const TxReceipt) [32]u8 {
```

**Parameters:**

- `self`: `*const TxReceipt`

**Returns:** `[32]u8`

*Line: 129*

---

