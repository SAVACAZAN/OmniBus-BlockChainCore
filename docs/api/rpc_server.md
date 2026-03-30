# Module: `rpc_server`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `RPCServer`

*Line: 17*

### `ServerCtx`

Context partajat intre thread-uri (blockchain + wallet + module noi)

*Line: 39*

### `HTTPConfig`

Context extins pentru startHTTP cu module optionale

*Line: 55*

### `ConnCtx`

*Line: 94*

## Constants

| Name | Type | Value |
|------|------|-------|
| `Blockchain` | auto | `blockchain_mod.Blockchain` |
| `Wallet` | auto | `wallet_mod.Wallet` |
| `RPCContext` | auto | `ServerCtx` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, bc: *Blockchain, w: *Wallet) !RPCServer {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `bc`: `*Blockchain`
- `w`: `*Wallet`

**Returns:** `!RPCServer`

*Line: 22*

---

### `deinit`

```zig
pub fn deinit(_: *RPCServer) void {}
```

**Parameters:**

- `_`: `*RPCServer`

*Line: 26*

---

### `getBlockCount`

```zig
pub fn getBlockCount(self: *RPCServer) u32  { return self.blockchain.getBlockCount(); }
```

**Parameters:**

- `self`: `*RPCServer`

**Returns:** `u32`

*Line: 28*

---

### `getBalance`

```zig
pub fn getBalance(self: *RPCServer)    u64  { return self.wallet.getBalance(); }
```

**Parameters:**

- `self`: `*RPCServer`

**Returns:** `u64`

*Line: 29*

---

### `getMempoolSize`

```zig
pub fn getMempoolSize(self: *RPCServer) u32 { return std.math.cast(u32, self.blockchain.mempool.items.len) orelse std.math.maxInt(u32); }
```

**Parameters:**

- `self`: `*RPCServer`

**Returns:** `u32`

*Line: 30*

---

### `startHTTP`

Porneste serverul HTTP pe portul 8332 (blocking — ruleaza pe thread separat)

```zig
pub fn startHTTP(bc: *Blockchain, wallet: *Wallet, allocator: std.mem.Allocator) !void {
```

**Parameters:**

- `bc`: `*Blockchain`
- `wallet`: `*Wallet`
- `allocator`: `std.mem.Allocator`

**Returns:** `!void`

*Line: 62*

---

### `startHTTPEx`

Versiunea extinsa cu module optionale (mempool, p2p, sync)

```zig
pub fn startHTTPEx(bc: *Blockchain, wallet: *Wallet, allocator: std.mem.Allocator, cfg: HTTPConfig) !void {
```

**Parameters:**

- `bc`: `*Blockchain`
- `wallet`: `*Wallet`
- `allocator`: `std.mem.Allocator`
- `cfg`: `HTTPConfig`

**Returns:** `!void`

*Line: 67*

---

### `main`

```zig
pub fn main() !void {
```

**Returns:** `!void`

*Line: 523*

---

