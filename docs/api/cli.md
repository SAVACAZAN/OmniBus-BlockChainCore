# Module: `cli`

## Contents

- [Structs](#structs)
- [Functions](#functions)

## Structs

### `CLI`

CLI argument parser for node startup

*Line: 5*

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator) CLI {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`

**Returns:** `CLI`

*Line: 8*

---

### `parseArgs`

Parse command-line arguments and return NodeConfig
Usage:
omnibus-node --mode seed --primary --port 9000
omnibus-node --mode miner --node-id miner-1 --seed-host 127.0.0.1 --seed-port 9000 --hashrate 1000

```zig
pub fn parseArgs(self: CLI, args: []const []const u8) !node_launcher.NodeConfig {
```

**Parameters:**

- `self`: `CLI`
- `args`: `[]const []const u8`

**Returns:** `!node_launcher.NodeConfig`

*Line: 16*

---

