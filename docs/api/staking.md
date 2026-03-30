# Module: `staking`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `Validator`

A validator in the staking system

*Line: 55*

### `Delegation`

Delegation record

*Line: 120*

### `StakingEngine`

Staking Engine — manages the validator set

*Line: 129*

## Constants

| Name | Type | Value |
|------|------|-------|
| `VALIDATOR_MIN_STAKE` | auto | `u64 = 100_000_000_000` |
| `MAX_VALIDATORS` | auto | `usize = 128` |
| `UNBONDING_PERIOD` | auto | `u64 = 604_800` |
| `SLASH_EQUIVOCATION_PCT` | auto | `u64 = 5` |
| `SLASH_DOWNTIME_PERMILLE` | auto | `u64 = 1` |
| `MIN_UPTIME_PCT` | auto | `u8 = 95` |
| `REWARD_EPOCH_BLOCKS` | auto | `u64 = 100` |
| `ValidatorStatus` | auto | `enum(u8) {` |

## Functions

### `init`

```zig
pub fn init(address: []const u8, stake: u64, block: u64) Validator {
```

**Parameters:**

- `address`: `[]const u8`
- `stake`: `u64`
- `block`: `u64`

**Returns:** `Validator`

*Line: 82*

---

### `uptimePct`

Uptime percentage (0-100)

```zig
pub fn uptimePct(self: *const Validator) u8 {
```

**Parameters:**

- `self`: `*const Validator`

**Returns:** `u8`

*Line: 96*

---

### `votingPower`

Voting power (proportional to total stake)

```zig
pub fn votingPower(self: *const Validator) u64 {
```

**Parameters:**

- `self`: `*const Validator`

**Returns:** `u64`

*Line: 103*

---

### `shouldSlashDowntime`

Check if validator can be slashed for downtime

```zig
pub fn shouldSlashDowntime(self: *const Validator) bool {
```

**Parameters:**

- `self`: `*const Validator`

**Returns:** `bool`

*Line: 109*

---

### `getAddress`

```zig
pub fn getAddress(self: *const Validator) []const u8 {
```

**Parameters:**

- `self`: `*const Validator`

**Returns:** `[]const u8`

*Line: 114*

---

### `init`

```zig
pub fn init() StakingEngine {
```

**Returns:** `StakingEngine`

*Line: 139*

---

### `registerValidator`

Register a new validator with initial stake

```zig
pub fn registerValidator(self: *StakingEngine, address: []const u8, stake: u64, current_block: u64) !u8 {
```

**Parameters:**

- `self`: `*StakingEngine`
- `address`: `[]const u8`
- `stake`: `u64`
- `current_block`: `u64`

**Returns:** `!u8`

*Line: 150*

---

### `activateValidator`

Activate a pending validator

```zig
pub fn activateValidator(self: *StakingEngine, index: u8) !void {
```

**Parameters:**

- `self`: `*StakingEngine`
- `index`: `u8`

**Returns:** `!void`

*Line: 167*

---

### `startUnbonding`

Start unbonding process

```zig
pub fn startUnbonding(self: *StakingEngine, index: u8, current_block: u64) !void {
```

**Parameters:**

- `self`: `*StakingEngine`
- `index`: `u8`
- `current_block`: `u64`

**Returns:** `!void`

*Line: 175*

---

### `completeUnbonding`

Complete unbonding (after UNBONDING_PERIOD blocks)

```zig
pub fn completeUnbonding(self: *StakingEngine, index: u8, current_block: u64) !u64 {
```

**Parameters:**

- `self`: `*StakingEngine`
- `index`: `u8`
- `current_block`: `u64`

**Returns:** `!u64`

*Line: 184*

---

### `slashEquivocation`

Slash a validator for equivocation (double signing)

```zig
pub fn slashEquivocation(self: *StakingEngine, index: u8) !u64 {
```

**Parameters:**

- `self`: `*StakingEngine`
- `index`: `u8`

**Returns:** `!u64`

*Line: 199*

---

### `slashDowntime`

Slash for downtime

```zig
pub fn slashDowntime(self: *StakingEngine, index: u8) !u64 {
```

**Parameters:**

- `self`: `*StakingEngine`
- `index`: `u8`

**Returns:** `!u64`

*Line: 216*

---

### `selectProposer`

Select block proposer (weighted random by stake)
Uses block_hash as randomness source (like EGLD SPoS)

```zig
pub fn selectProposer(self: *const StakingEngine, block_hash: [32]u8) ?u8 {
```

**Parameters:**

- `self`: `*const StakingEngine`
- `block_hash`: `[32]u8`

**Returns:** `?u8`

*Line: 235*

---

### `activeCount`

Get number of active validators

```zig
pub fn activeCount(self: *const StakingEngine) usize {
```

**Parameters:**

- `self`: `*const StakingEngine`

**Returns:** `usize`

*Line: 252*

---

### `totalVotingPower`

Total active voting power

```zig
pub fn totalVotingPower(self: *const StakingEngine) u64 {
```

**Parameters:**

- `self`: `*const StakingEngine`

**Returns:** `u64`

*Line: 261*

---

### `distributeRewards`

Distribute rewards to active validators proportional to stake

```zig
pub fn distributeRewards(self: *StakingEngine, total_reward: u64) void {
```

**Parameters:**

- `self`: `*StakingEngine`
- `total_reward`: `u64`

*Line: 270*

---

