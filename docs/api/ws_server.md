# Module: `ws_server`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `WsServer`

Stare globala WebSocket — lista de conexiuni active

*Line: 14*

### `Args`

*Line: 51*

### `HandlerArgs`

*Line: 92*

### `WsClient`

Un client WebSocket conectat

*Line: 259*

## Constants

| Name | Type | Value |
|------|------|-------|
| `WS_PORT` | auto | `u16 = 8334` |

## Functions

### `init`

```zig
pub fn init(port: u16, allocator: std.mem.Allocator) WsServer {
```

**Parameters:**

- `port`: `u16`
- `allocator`: `std.mem.Allocator`

**Returns:** `WsServer`

*Line: 21*

---

### `deinit`

```zig
pub fn deinit(self: *WsServer) void {
```

**Parameters:**

- `self`: `*WsServer`

*Line: 31*

---

### `attachBlockchain`

```zig
pub fn attachBlockchain(self: *WsServer, bc: *const Blockchain) void {
```

**Parameters:**

- `self`: `*WsServer`
- `bc`: `*const Blockchain`

*Line: 41*

---

### `start`

Porneste TCP listener + accept loop in thread detasat

```zig
pub fn start(self: *WsServer) !void {
```

**Parameters:**

- `self`: `*WsServer`

**Returns:** `!void`

*Line: 46*

---

### `broadcast`

Broadcast JSON la toti clientii conectati
Apelat din mining loop la fiecare bloc minat

```zig
pub fn broadcast(self: *WsServer, json: []const u8) void {
```

**Parameters:**

- `self`: `*WsServer`
- `json`: `[]const u8`

*Line: 195*

---

### `broadcastTx`

Trimite eveniment "new_tx" la toti clientii

```zig
pub fn broadcastTx(self: *WsServer, tx_id: []const u8, from: []const u8, amount_sat: u64) void {
```

**Parameters:**

- `self`: `*WsServer`
- `tx_id`: `[]const u8`
- `from`: `[]const u8`
- `amount_sat`: `u64`

*Line: 244*

---

### `sendText`

Trimite un frame TEXT WebSocket (opcode 1)
RFC 6455: [0x81][len][payload] — server nu maskeaza

```zig
pub fn sendText(self: *WsClient, text: []const u8) !void {
```

**Parameters:**

- `self`: `*WsClient`
- `text`: `[]const u8`

**Returns:** `!void`

*Line: 266*

---

