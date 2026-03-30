# Module: `omni_brain`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `BrainConfig`

*Line: 27*

### `BrainStats`

*Line: 47*

### `OmniBrain`

*Line: 58*

## Constants

| Name | Type | Value |
|------|------|-------|
| `OsMode` | auto | `os_mode_mod.OsMode` |
| `OsModeManager` | auto | `os_mode_mod.OsModeManager` |
| `SynapseScheduler` | auto | `synapse_mod.SynapseScheduler` |
| `SupplyGuard` | auto | `spark_mod.SupplyGuard` |
| `NodeType` | auto | `enum(u8) {` |

## Functions

### `init`

```zig
pub fn init(allocator: std.mem.Allocator, config: BrainConfig) OmniBrain {
```

**Parameters:**

- `allocator`: `std.mem.Allocator`
- `config`: `BrainConfig`

**Returns:** `OmniBrain`

*Line: 67*

---

### `start`

Porneste OmniBrain: activeaza OS-urile corespunzatoare node_type

```zig
pub fn start(self: *OmniBrain) !void {
```

**Parameters:**

- `self`: `*OmniBrain`

**Returns:** `!void`

*Line: 80*

---

### `runCycles`

Ruleaza N cicluri ale brain-ului

```zig
pub fn runCycles(self: *OmniBrain, n: u64) !void {
```

**Parameters:**

- `self`: `*OmniBrain`
- `n`: `u64`

**Returns:** `!void`

*Line: 120*

---

### `recordTrade`

Inregistreaza un trade executat (din ExecutionOS)

```zig
pub fn recordTrade(self: *OmniBrain) void {
```

**Parameters:**

- `self`: `*OmniBrain`

*Line: 138*

---

### `assertInvariants`

Verifica invariantii Ada/SPARK

```zig
pub fn assertInvariants(self: *const OmniBrain) void {
```

**Parameters:**

- `self`: `*const OmniBrain`

*Line: 143*

---

### `printStatus`

```zig
pub fn printStatus(self: *const OmniBrain) void {
```

**Parameters:**

- `self`: `*const OmniBrain`

*Line: 151*

---

