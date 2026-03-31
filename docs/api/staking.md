# Module: `staking`

> Proof-of-Stake validator system — deposit/withdraw stake, slashing for equivocation and downtime, unbonding period (7 days), minimum stake enforcement.

**Source:** `core/staking.zig` | **Lines:** 1087 | **Functions:** 29 | **Structs:** 8 | **Tests:** 24

---

## Contents

### Structs
- [`SlashEvidence`](#slashevidence) — Cryptographic evidence that a validator cheated.
For double_sign: two different ...
- [`SlashResult`](#slashresult) — Result of processing slash evidence
- [`SlashRecord`](#slashrecord) — Persistent record of a slashing event
- [`Validator`](#validator) — A validator in the staking system
- [`Delegation`](#delegation) — Delegation record
- [`StakingEngine`](#stakingengine) — Staking Engine — manages the validator set
- [`SlashHistoryResult`](#slashhistoryresult) — Result container for slash history queries (fixed-size, no allocation)
- [`ValidatorInfo`](#validatorinfo) — Validator info summary for RPC responses

### Constants
- [17 constants defined](#constants)

### Functions
- [`getValidatorAddress()`](#getvalidatoraddress) — Returns the current validator address.
- [`getReporterAddress()`](#getreporteraddress) — Returns the current reporter address.
- [`getReason()`](#getreason) — Returns the current reason.
- [`rejected()`](#rejected) — Performs the rejected operation on the staking module.
- [`getValidator()`](#getvalidator) — Returns the current validator.
- [`getReporter()`](#getreporter) — Returns the current reporter.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`uptimePct()`](#uptimepct) — Uptime percentage (0-100)
- [`votingPower()`](#votingpower) — Voting power (proportional to total stake)
- [`shouldSlashDowntime()`](#shouldslashdowntime) — Check if validator can be slashed for downtime
- [`getAddress()`](#getaddress) — Returns the current address.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`registerValidator()`](#registervalidator) — Register a new validator with initial stake
- [`activateValidator()`](#activatevalidator) — Activate a pending validator
- [`startUnbonding()`](#startunbonding) — Start unbonding process
- [`completeUnbonding()`](#completeunbonding) — Complete unbonding (after UNBONDING_PERIOD blocks)
- [`slashEquivocation()`](#slashequivocation) — Slash a validator for equivocation (double signing)
- [`slashDowntime()`](#slashdowntime) — Slash for downtime
- [`selectProposer()`](#selectproposer) — Select block proposer (weighted random by stake)
Uses block_hash as ra...
- [`activeCount()`](#activecount) — Get number of active validators
- [`totalVotingPower()`](#totalvotingpower) — Total active voting power
- [`distributeRewards()`](#distributerewards) — Distribute rewards to active validators proportional to stake
- [`submitSlashEvidence()`](#submitslashevidence) — Submit slash evidence — verify the proof and execute the slash if vali...
- [`findValidatorIndex()`](#findvalidatorindex) — Look up a validator by address. Returns index or null.
- [`getSlashHistory()`](#getslashhistory) — Get slash history for a specific validator.
Returns a slice of the int...
- [`getValidatorInfo()`](#getvalidatorinfo) — Get staking info for a validator (for RPC getstakinginfo)
- [`slice()`](#slice) — Performs the slice operation on the staking module.
- [`getAddress()`](#getaddress) — Returns the current address.
- [`statusString()`](#statusstring) — Performs the status string operation on the staking module.

---

## Structs

### `SlashEvidence`

Cryptographic evidence that a validator cheated.
For double_sign: two different block hashes at the same height,
each signed by the same validator. Both signatures must verify.

| Field | Type | Description |
|-------|------|-------------|
| `validator_address` | `[64]u8` | Validator_address |
| `validator_addr_len` | `u8` | Validator_addr_len |
| `reason` | `SlashReason` | Reason |
| `block_hash_1` | `[32]u8` | Block_hash_1 |
| `block_hash_2` | `[32]u8` | Block_hash_2 |
| `block_height` | `u64` | Block_height |
| `signature_1` | `[64]u8` | Signature_1 |
| `signature_2` | `[64]u8` | Signature_2 |
| `reporter_address` | `[64]u8` | Reporter_address |
| `reporter_addr_len` | `u8` | Reporter_addr_len |
| `timestamp` | `i64` | Timestamp |
| `validator_addr` | `[]const u8` | Validator_addr |
| `reason` | `SlashReason` | Reason |
| `hash1` | `[32]u8` | Hash1 |
| `hash2` | `[32]u8` | Hash2 |
| `height` | `u64` | Height |
| `sig1` | `[64]u8` | Sig1 |
| `sig2` | `[64]u8` | Sig2 |
| `reporter_addr` | `[]const u8` | Reporter_addr |
| `ts` | `i64` | Ts |

*Defined at line 73*

---

### `SlashResult`

Result of processing slash evidence

| Field | Type | Description |
|-------|------|-------------|
| `valid` | `bool` | Valid |
| `slashed_amount` | `u64` | Slashed_amount |
| `reporter_reward` | `u64` | Reporter_reward |
| `new_stake` | `u64` | New_stake |
| `reason` | `[128]u8` | Reason |
| `reason_len` | `u8` | Reason_len |

*Defined at line 133*

---

### `SlashRecord`

Persistent record of a slashing event

| Field | Type | Description |
|-------|------|-------------|
| `validator` | `[64]u8` | Validator |
| `validator_len` | `u8` | Validator_len |
| `reason` | `SlashReason` | Reason |
| `amount_slashed` | `u64` | Amount_slashed |
| `block_height` | `u64` | Block_height |
| `timestamp` | `i64` | Timestamp |
| `reporter` | `[64]u8` | Reporter |
| `reporter_len` | `u8` | Reporter_len |
| `reporter_reward` | `u64` | Reporter_reward |

*Defined at line 165*

---

### `Validator`

A validator in the staking system

| Field | Type | Description |
|-------|------|-------------|
| `address` | `[64]u8` | Address |
| `addr_len` | `u8` | Addr_len |
| `total_stake` | `u64` | Total_stake |
| `self_stake` | `u64` | Self_stake |
| `delegated_stake` | `u64` | Delegated_stake |
| `status` | `ValidatorStatus` | Status |
| `registered_block` | `u64` | Registered_block |
| `unbonding_block` | `u64` | Unbonding_block |
| `blocks_produced` | `u32` | Blocks_produced |
| `blocks_missed` | `u32` | Blocks_missed |
| `total_rewards` | `u64` | Total_rewards |
| `commission_pct` | `u8` | Commission_pct |
| `slash_count` | `u8` | Slash_count |

*Defined at line 212*

---

### `Delegation`

Delegation record

| Field | Type | Description |
|-------|------|-------------|
| `delegator` | `[64]u8` | Delegator |
| `delegator_len` | `u8` | Delegator_len |
| `validator_index` | `u8` | Validator_index |
| `amount` | `u64` | Amount |
| `block` | `u64` | Block |

*Defined at line 277*

---

### `StakingEngine`

Staking Engine — manages the validator set

| Field | Type | Description |
|-------|------|-------------|
| `validators` | `[MAX_VALIDATORS]Validator` | Validators |
| `validator_count` | `usize` | Validator_count |
| `total_staked` | `u64` | Total_staked |
| `current_epoch` | `u64` | Current_epoch |
| `total_slashes` | `u32` | Total_slashes |
| `slash_records` | `[MAX_TOTAL_SLASH_RECORDS]SlashRecord` | Slash_records |
| `slash_record_count` | `usize` | Slash_record_count |
| `total_slashed_amount` | `u64` | Total_slashed_amount |
| `total_reporter_rewards` | `u64` | Total_reporter_rewards |

*Defined at line 286*

---

### `SlashHistoryResult`

Result container for slash history queries (fixed-size, no allocation)

| Field | Type | Description |
|-------|------|-------------|
| `records` | `[MAX_RESULTS]SlashRecord` | Records |
| `count` | `usize` | Count |

*Defined at line 650*

---

### `ValidatorInfo`

Validator info summary for RPC responses

| Field | Type | Description |
|-------|------|-------------|
| `address` | `[64]u8` | Address |
| `addr_len` | `u8` | Addr_len |
| `total_stake` | `u64` | Total_stake |
| `self_stake` | `u64` | Self_stake |
| `delegated_stake` | `u64` | Delegated_stake |
| `status` | `ValidatorStatus` | Status |
| `slash_count` | `u8` | Slash_count |
| `total_rewards` | `u64` | Total_rewards |
| `uptime_pct` | `u8` | Uptime_pct |
| `slash_history_count` | `u8` | Slash_history_count |
| `blocks_produced` | `u32` | Blocks_produced |
| `commission_pct` | `u8` | Commission_pct |

*Defined at line 661*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `VALIDATOR_MIN_STAKE` | `u64 = 100_000_000_000` | V a l i d a t o r_ m i n_ s t a k e |
| `MAX_VALIDATORS` | `usize = 128` | M a x_ v a l i d a t o r s |
| `UNBONDING_PERIOD` | `u64 = 604_800` | U n b o n d i n g_ p e r i o d |
| `SlashReason` | `enum(u8) {` | Slash reason |
| `SLASH_DOUBLE_SIGN_PCT` | `u64 = 33` | S l a s h_ d o u b l e_ s i g n_ p c t |
| `SLASH_INVALID_BLOCK_PCT` | `u64 = 10` | S l a s h_ i n v a l i d_ b l o c k_ p c t |
| `DOWNTIME_PENALTY_PCT` | `u64 = 1` | D o w n t i m e_ p e n a l t y_ p c t |
| `MIN_SLASH_AMOUNT` | `u64 = 1_000_000` | M i n_ s l a s h_ a m o u n t |
| `REPORTER_REWARD_PCT` | `u64 = 10` | R e p o r t e r_ r e w a r d_ p c t |
| `MAX_SLASH_RECORDS` | `usize = 64` | M a x_ s l a s h_ r e c o r d s |
| `MAX_TOTAL_SLASH_RECORDS` | `usize = 512` | M a x_ t o t a l_ s l a s h_ r e c o r d s |
| `SLASH_EQUIVOCATION_PCT` | `u64 = SLASH_DOUBLE_SIGN_PCT` | S l a s h_ e q u i v o c a t i o n_ p c t |
| `SLASH_DOWNTIME_PERMILLE` | `u64 = 10` | S l a s h_ d o w n t i m e_ p e r m i l l e |
| `MIN_UPTIME_PCT` | `u8 = 95` | M i n_ u p t i m e_ p c t |
| `REWARD_EPOCH_BLOCKS` | `u64 = 100` | R e w a r d_ e p o c h_ b l o c k s |
| `ValidatorStatus` | `enum(u8) {` | Validator status |
| `MAX_RESULTS` | `usize = MAX_SLASH_RECORDS` | M a x_ r e s u l t s |

---

## Functions

### `getValidatorAddress()`

Returns the current validator address.

```zig
pub fn getValidatorAddress(self: *const SlashEvidence) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SlashEvidence` | The instance |

**Returns:** `[]const u8`

*Defined at line 95*

---

### `getReporterAddress()`

Returns the current reporter address.

```zig
pub fn getReporterAddress(self: *const SlashEvidence) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SlashEvidence` | The instance |

**Returns:** `[]const u8`

*Defined at line 99*

---

### `getReason()`

Returns the current reason.

```zig
pub fn getReason(self: *const SlashResult) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SlashResult` | The instance |

**Returns:** `[]const u8`

*Defined at line 146*

---

### `rejected()`

Performs the rejected operation on the staking module.

```zig
pub fn rejected(msg: []const u8) SlashResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `msg` | `[]const u8` | Msg |

**Returns:** `SlashResult`

*Defined at line 156*

---

### `getValidator()`

Returns the current validator.

```zig
pub fn getValidator(self: *const SlashRecord) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SlashRecord` | The instance |

**Returns:** `[]const u8`

*Defined at line 183*

---

### `getReporter()`

Returns the current reporter.

```zig
pub fn getReporter(self: *const SlashRecord) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SlashRecord` | The instance |

**Returns:** `[]const u8`

*Defined at line 187*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(address: []const u8, stake: u64, block: u64) Validator {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `address` | `[]const u8` | Address |
| `stake` | `u64` | Stake |
| `block` | `u64` | Block |

**Returns:** `Validator`

*Defined at line 239*

---

### `uptimePct()`

Uptime percentage (0-100)

```zig
pub fn uptimePct(self: *const Validator) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Validator` | The instance |

**Returns:** `u8`

*Defined at line 253*

---

### `votingPower()`

Voting power (proportional to total stake)

```zig
pub fn votingPower(self: *const Validator) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Validator` | The instance |

**Returns:** `u64`

*Defined at line 260*

---

### `shouldSlashDowntime()`

Check if validator can be slashed for downtime

```zig
pub fn shouldSlashDowntime(self: *const Validator) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Validator` | The instance |

**Returns:** `bool`

*Defined at line 266*

---

### `getAddress()`

Returns the current address.

```zig
pub fn getAddress(self: *const Validator) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Validator` | The instance |

**Returns:** `[]const u8`

*Defined at line 271*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() StakingEngine {
```

**Returns:** `StakingEngine`

*Defined at line 303*

---

### `registerValidator()`

Register a new validator with initial stake

```zig
pub fn registerValidator(self: *StakingEngine, address: []const u8, stake: u64, current_block: u64) !u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StakingEngine` | The instance |
| `address` | `[]const u8` | Address |
| `stake` | `u64` | Stake |
| `current_block` | `u64` | Current_block |

**Returns:** `!u8`

*Defined at line 318*

---

### `activateValidator()`

Activate a pending validator

```zig
pub fn activateValidator(self: *StakingEngine, index: u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StakingEngine` | The instance |
| `index` | `u8` | Index |

**Returns:** `!void`

*Defined at line 335*

---

### `startUnbonding()`

Start unbonding process

```zig
pub fn startUnbonding(self: *StakingEngine, index: u8, current_block: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StakingEngine` | The instance |
| `index` | `u8` | Index |
| `current_block` | `u64` | Current_block |

**Returns:** `!void`

*Defined at line 343*

---

### `completeUnbonding()`

Complete unbonding (after UNBONDING_PERIOD blocks)

```zig
pub fn completeUnbonding(self: *StakingEngine, index: u8, current_block: u64) !u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StakingEngine` | The instance |
| `index` | `u8` | Index |
| `current_block` | `u64` | Current_block |

**Returns:** `!u64`

*Defined at line 352*

---

### `slashEquivocation()`

Slash a validator for equivocation (double signing)

```zig
pub fn slashEquivocation(self: *StakingEngine, index: u8) !u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StakingEngine` | The instance |
| `index` | `u8` | Index |

**Returns:** `!u64`

*Defined at line 367*

---

### `slashDowntime()`

Slash for downtime

```zig
pub fn slashDowntime(self: *StakingEngine, index: u8) !u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StakingEngine` | The instance |
| `index` | `u8` | Index |

**Returns:** `!u64`

*Defined at line 384*

---

### `selectProposer()`

Select block proposer (weighted random by stake)
Uses block_hash as randomness source (like EGLD SPoS)

```zig
pub fn selectProposer(self: *const StakingEngine, block_hash: [32]u8) ?u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StakingEngine` | The instance |
| `block_hash` | `[32]u8` | Block_hash |

**Returns:** `?u8`

*Defined at line 403*

---

### `activeCount()`

Get number of active validators

```zig
pub fn activeCount(self: *const StakingEngine) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StakingEngine` | The instance |

**Returns:** `usize`

*Defined at line 420*

---

### `totalVotingPower()`

Total active voting power

```zig
pub fn totalVotingPower(self: *const StakingEngine) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StakingEngine` | The instance |

**Returns:** `u64`

*Defined at line 429*

---

### `distributeRewards()`

Distribute rewards to active validators proportional to stake

```zig
pub fn distributeRewards(self: *StakingEngine, total_reward: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StakingEngine` | The instance |
| `total_reward` | `u64` | Total_reward |

*Defined at line 438*

---

### `submitSlashEvidence()`

Submit slash evidence — verify the proof and execute the slash if valid.
Returns a SlashResult indicating success/failure and amounts.

Philosophy: Slash ONLY validators who intentionally cheat.
Normal users cannot be slashed (they have no stake).

```zig
pub fn submitSlashEvidence(self: *StakingEngine, evidence: SlashEvidence) SlashResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*StakingEngine` | The instance |
| `evidence` | `SlashEvidence` | Evidence |

**Returns:** `SlashResult`

*Defined at line 457*

---

### `findValidatorIndex()`

Look up a validator by address. Returns index or null.

```zig
pub fn findValidatorIndex(self: *const StakingEngine, address: []const u8) ?usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StakingEngine` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `?usize`

*Defined at line 604*

---

### `getSlashHistory()`

Get slash history for a specific validator.
Returns a slice of the internal slash_records array matching the address.
Caller should copy if needed — returned data points into engine storage.

```zig
pub fn getSlashHistory(self: *const StakingEngine, address: []const u8) SlashHistoryResult {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StakingEngine` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `SlashHistoryResult`

*Defined at line 614*

---

### `getValidatorInfo()`

Get staking info for a validator (for RPC getstakinginfo)

```zig
pub fn getValidatorInfo(self: *const StakingEngine, address: []const u8) ?ValidatorInfo {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const StakingEngine` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `?ValidatorInfo`

*Defined at line 628*

---

### `slice()`

Performs the slice operation on the staking module.

```zig
pub fn slice(self: *const SlashHistoryResult) []const SlashRecord {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SlashHistoryResult` | The instance |

**Returns:** `[]const SlashRecord`

*Defined at line 655*

---

### `getAddress()`

Returns the current address.

```zig
pub fn getAddress(self: *const ValidatorInfo) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ValidatorInfo` | The instance |

**Returns:** `[]const u8`

*Defined at line 675*

---

### `statusString()`

Performs the status string operation on the staking module.

```zig
pub fn statusString(self: *const ValidatorInfo) []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ValidatorInfo` | The instance |

**Returns:** `[]const u8`

*Defined at line 679*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
