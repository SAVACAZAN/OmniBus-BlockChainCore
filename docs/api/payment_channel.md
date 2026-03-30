# Module: `payment_channel`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `ChannelState`

State update off-chain — semnată de ambele părți

*Line: 30*

### `HTLC`

HTLC — Hash Time Lock Contract (pentru routing multi-hop)
A trimite lui B condiționat de revelarea unui secret (preimage)

*Line: 60*

### `PaymentChannel`

Payment Channel — canal bidirectional între două adrese

*Line: 89*

### `ChannelRegistry`

ChannelRegistry — registrul tuturor channel-elor active (pe L1)
Fiecare nod ține evidența channel-elor în care e participant

*Line: 255*

## Constants

| Name | Type | Value |
|------|------|-------|
| `DISPUTE_WINDOW_BLOCKS` | auto | `u64 = 100` |
| `MAX_CHANNEL_AMOUNT` | auto | `u64   = 21_000_000 * 1_000_000_000` |
| `ChannelStatus` | auto | `enum(u8) {` |

## Functions

### `hash`

Hash-ul acestui state (pentru verificare on-chain)

```zig
pub fn hash(self: *const ChannelState) [32]u8 {
```

**Parameters:**

- `self`: `*const ChannelState`

**Returns:** `[32]u8`

*Line: 40*

---

### `totalBalance`

```zig
pub fn totalBalance(self: *const ChannelState) u64 {
```

**Parameters:**

- `self`: `*const ChannelState`

**Returns:** `u64`

*Line: 53*

---

### `reveal`

Verifică dacă preimage-ul deblochează HTLC-ul

```zig
pub fn reveal(self: *HTLC, preimage: [32]u8) bool {
```

**Parameters:**

- `self`: `*HTLC`
- `preimage`: `[32]u8`

**Returns:** `bool`

*Line: 69*

---

### `isExpired`

```zig
pub fn isExpired(self: *const HTLC, current_block: u64) bool {
```

**Parameters:**

- `self`: `*const HTLC`
- `current_block`: `u64`

**Returns:** `bool`

*Line: 83*

---

### `deinit`

```zig
pub fn deinit(self: *PaymentChannel) void {
```

**Parameters:**

- `self`: `*PaymentChannel`

*Line: 149*

---

### `revealHTLC`

Revelează preimage-ul unui HTLC (deblochează plata)

```zig
pub fn revealHTLC(self: *PaymentChannel, htlc_id: u32, preimage: [32]u8) !void {
```

**Parameters:**

- `self`: `*PaymentChannel`
- `htlc_id`: `u32`
- `preimage`: `[32]u8`

**Returns:** `!void`

*Line: 203*

---

### `initiateClose`

Inițiază close — postează ultimul state pe L1

```zig
pub fn initiateClose(self: *PaymentChannel, current_block: u64) !void {
```

**Parameters:**

- `self`: `*PaymentChannel`
- `current_block`: `u64`

**Returns:** `!void`

*Line: 211*

---

### `finalizeClose`

Finalizează close după dispute window (dacă nu a fost contestat)

```zig
pub fn finalizeClose(self: *PaymentChannel, current_block: u64) !ChannelState {
```

**Parameters:**

- `self`: `*PaymentChannel`
- `current_block`: `u64`

**Returns:** `!ChannelState`

*Line: 220*

---

### `dispute`

Dispute: A contestă un state vechi postat de B
Dacă A are un state cu sequence mai mare → câștigă disputa

```zig
pub fn dispute(self: *PaymentChannel, challenger_state: ChannelState) !void {
```

**Parameters:**

- `self`: `*PaymentChannel`
- `challenger_state`: `ChannelState`

**Returns:** `!void`

*Line: 233*

---

### `getChannelIdHex`

```zig
pub fn getChannelIdHex(self: *const PaymentChannel, buf: []u8) []u8 {
```

**Parameters:**

- `self`: `*const PaymentChannel`
- `buf`: `[]u8`

**Returns:** `[]u8`

*Line: 248*

---

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) ChannelRegistry {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `ChannelRegistry`

*Line: 259*

---

### `deinit`

```zig
pub fn deinit(self: *ChannelRegistry) void {
```

**Parameters:**

- `self`: `*ChannelRegistry`

*Line: 266*

---

### `addChannel`

```zig
pub fn addChannel(self: *ChannelRegistry, ch: PaymentChannel) !void {
```

**Parameters:**

- `self`: `*ChannelRegistry`
- `ch`: `PaymentChannel`

**Returns:** `!void`

*Line: 271*

---

### `findChannel`

```zig
pub fn findChannel(self: *ChannelRegistry, channel_id: [32]u8) ?*PaymentChannel {
```

**Parameters:**

- `self`: `*ChannelRegistry`
- `channel_id`: `[32]u8`

**Returns:** `?*PaymentChannel`

*Line: 275*

---

### `getOpenCount`

```zig
pub fn getOpenCount(self: *const ChannelRegistry) usize {
```

**Parameters:**

- `self`: `*const ChannelRegistry`

**Returns:** `usize`

*Line: 282*

---

### `getTotalLockedSat`

```zig
pub fn getTotalLockedSat(self: *const ChannelRegistry) u64 {
```

**Parameters:**

- `self`: `*const ChannelRegistry`

**Returns:** `u64`

*Line: 290*

---

### `printStatus`

```zig
pub fn printStatus(self: *const ChannelRegistry) void {
```

**Parameters:**

- `self`: `*const ChannelRegistry`

*Line: 300*

---

