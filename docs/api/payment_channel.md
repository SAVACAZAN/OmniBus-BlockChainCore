# Module: `payment_channel`

> Lightning-style Layer 2 — open/close channels, HTLC (Hash Time-Locked Contracts), off-chain payments, cooperative/unilateral close.

**Source:** `core/payment_channel.zig` | **Lines:** 984 | **Functions:** 25 | **Structs:** 5 | **Tests:** 27

---

## Contents

### Structs
- [`ChannelUpdate`](#channelupdate) — ChannelUpdate — signed off-chain state between two parties.
Both parties must si...
- [`SettleTx`](#settletx) — SettleTx — on-chain settlement transaction pair.
When a channel closes, two on-c...
- [`HTLC`](#htlc) — HTLC — Hash Time Lock Contract (for multi-hop routing)
A sends to B conditional ...
- [`PaymentChannel`](#paymentchannel) — PaymentChannel — bidirectional off-chain payment channel between two parties.

U...
- [`ChannelManager`](#channelmanager) — ChannelManager — fixed-size registry of payment channels.
No dynamic allocation ...

### Constants
- [6 constants defined](#constants)

### Functions
- [`hash()`](#hash) — Compute deterministic hash of this state update (for on-chain verifica...
- [`verify()`](#verify) — Verify that both signatures are non-zero (placeholder for real sig ver...
- [`totalBalance()`](#totalbalance) — Performs the total balance operation on the payment_channel module.
- [`fromUpdate()`](#fromupdate) — Generate deterministic TX hashes from channel state
- [`reveal()`](#reveal) — Check if preimage unlocks the HTLC
- [`isExpired()`](#isexpired) — Checks whether the expired condition is true.
- [`open()`](#open) — Open a new payment channel between two parties.
Both parties lock fund...
- [`openWithId()`](#openwithid) — Open with explicit channel_id (deterministic, for testing)
- [`pay()`](#pay) — Off-chain payment: transfer amount from one party to the other.
Both p...
- [`cooperativeClose()`](#cooperativeclose) — Cooperative close: both parties agree on final state, no dispute neede...
- [`unilateralClose()`](#unilateralclose) — Unilateral close: one party submits their latest signed state.
Starts ...
- [`dispute()`](#dispute) — Dispute: counterparty submits a state with higher sequence_num.
Return...
- [`settle()`](#settle) — Settle: finalize the channel on-chain after dispute window expires.
Ca...
- [`addHTLC()`](#addhtlc) — Add an HTLC to this channel (for multi-hop routing)
- [`revealHTLC()`](#revealhtlc) — Reveal preimage for an HTLC (unlocks payment)
- [`currentUpdate()`](#currentupdate) — Get the current state as a ChannelUpdate
- [`getChannelIdHex()`](#getchannelidhex) — Format channel_id as hex string into provided buffer
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`openChannel()`](#openchannel) — Open a new channel and add it to the registry.
Returns a pointer to th...
- [`findChannel()`](#findchannel) — Find a channel by its ID. Returns null if not found.
- [`closeChannel()`](#closechannel) — Close a channel (cooperative close). Returns the settlement TX.
- [`getAllChannels()`](#getallchannels) — Get a slice of all channels (active and inactive).
- [`countByState()`](#countbystate) — Count channels in a specific state.
- [`getTotalLockedSat()`](#gettotallockedsat) — Get total SAT locked across all open/closing channels.
- [`printStatus()`](#printstatus) — Performs the print status operation on the payment_channel module.

---

## Structs

### `ChannelUpdate`

ChannelUpdate — signed off-chain state between two parties.
Both parties must sign each update. Higher sequence_num = newer state.

| Field | Type | Description |
|-------|------|-------------|
| `channel_id` | `[32]u8` | Channel_id |
| `sequence_num` | `u64` | Sequence_num |
| `balance_a` | `u64` | Balance_a |
| `balance_b` | `u64` | Balance_b |
| `sig_a` | `[64]u8` | Sig_a |
| `sig_b` | `[64]u8` | Sig_b |

*Defined at line 35*

---

### `SettleTx`

SettleTx — on-chain settlement transaction pair.
When a channel closes, two on-chain TXs are created:
tx_hash_a: returns A's final balance to A's address
tx_hash_b: returns B's final balance to B's address

| Field | Type | Description |
|-------|------|-------------|
| `channel_id` | `[32]u8` | Channel_id |
| `final_balance_a` | `u64` | Final_balance_a |
| `final_balance_b` | `u64` | Final_balance_b |
| `settle_block` | `u64` | Settle_block |
| `tx_hash_a` | `[32]u8` | Tx_hash_a |
| `tx_hash_b` | `[32]u8` | Tx_hash_b |

*Defined at line 99*

---

### `HTLC`

HTLC — Hash Time Lock Contract (for multi-hop routing)
A sends to B conditional on revealing a secret (preimage)

| Field | Type | Description |
|-------|------|-------------|
| `htlc_id` | `u32` | Htlc_id |
| `hash_lock` | `[32]u8` | Hash_lock |
| `amount_sat` | `u64` | Amount_sat |
| `timeout_block` | `u64` | Timeout_block |
| `revealed` | `bool` | Revealed |
| `preimage` | `[32]u8` | Preimage |
| `preimage_set` | `bool` | Preimage_set |

*Defined at line 141*

---

### `PaymentChannel`

PaymentChannel — bidirectional off-chain payment channel between two parties.

Uses fixed-size arrays (no dynamic allocation after init) for bare-metal compat.
Each channel holds up to MAX_HTLCS_PER_CHANNEL pending HTLCs.

| Field | Type | Description |
|-------|------|-------------|
| `channel_id` | `[32]u8` | Channel_id |
| `party_a` | `[33]u8` | Party_a |
| `party_b` | `[33]u8` | Party_b |
| `balance_a` | `u64` | Balance_a |
| `balance_b` | `u64` | Balance_b |
| `total_locked` | `u64` | Total_locked |
| `sequence_num` | `u64` | Sequence_num |
| `state` | `ChannelState` | State |
| `funding_tx_hash` | `[32]u8` | Funding_tx_hash |
| `timeout_blocks` | `u64` | Timeout_blocks |
| `created_at` | `i64` | Created_at |
| `close_block` | `u64` | Close_block |
| `pending_close_update` | `?ChannelUpdate` | Pending_close_update |
| `htlcs` | `[MAX_HTLCS_PER_CHANNEL]HTLC` | Htlcs |
| `htlc_count` | `u8` | Htlc_count |

*Defined at line 175*

---

### `ChannelManager`

ChannelManager — fixed-size registry of payment channels.
No dynamic allocation — holds up to MAX_CHANNELS channels in a flat array.
Thread-safe via mutex for concurrent RPC access.

| Field | Type | Description |
|-------|------|-------------|
| `channels` | `[MAX_CHANNELS]PaymentChannel` | Channels |
| `channel_count` | `u8` | Channel_count |
| `mutex` | `std.Thread.Mutex` | Mutex |

*Defined at line 455*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `DISPUTE_WINDOW_BLOCKS` | `u64 = 144` | D i s p u t e_ w i n d o w_ b l o c k s |
| `MAX_CHANNEL_AMOUNT` | `u64 = 21_000_000 * 1_000_000_000` | M a x_ c h a n n e l_ a m o u n t |
| `MAX_CHANNELS` | `usize = 64` | M a x_ c h a n n e l s |
| `MAX_HTLCS_PER_CHANNEL` | `usize = 16` | M a x_ h t l c s_ p e r_ c h a n n e l |
| `SAT_PER_OMNI` | `u64 = 1_000_000_000` | S a t_ p e r_ o m n i |
| `ChannelState` | `enum(u8) {` | Channel state |

---

## Functions

### `hash()`

Compute deterministic hash of this state update (for on-chain verification).
Hash covers channel_id + sequence + balances — signatures are NOT included
(they authenticate the hash, not the other way around).

```zig
pub fn hash(self: *const ChannelUpdate) [32]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ChannelUpdate` | The instance |

**Returns:** `[32]u8`

*Defined at line 46*

---

### `verify()`

Verify that both signatures are non-zero (placeholder for real sig verification).
In production this would verify ECDSA/Schnorr sigs against pk_a and pk_b.
For now: checks that at least one byte of each sig is non-zero,
and that the update hash matches what was signed.

```zig
pub fn verify(self: *const ChannelUpdate, pk_a: [33]u8, pk_b: [33]u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ChannelUpdate` | The instance |
| `pk_a` | `[33]u8` | Pk_a |
| `pk_b` | `[33]u8` | Pk_b |

**Returns:** `bool`

*Defined at line 69*

---

### `totalBalance()`

Performs the total balance operation on the payment_channel module.

```zig
pub fn totalBalance(self: *const ChannelUpdate) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ChannelUpdate` | The instance |

**Returns:** `u64`

*Defined at line 90*

---

### `fromUpdate()`

Generate deterministic TX hashes from channel state

```zig
pub fn fromUpdate(update: *const ChannelUpdate, settle_block: u64) SettleTx {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `update` | `*const ChannelUpdate` | Update |
| `settle_block` | `u64` | Settle_block |

**Returns:** `SettleTx`

*Defined at line 108*

---

### `reveal()`

Check if preimage unlocks the HTLC

```zig
pub fn reveal(self: *HTLC, pre: [32]u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*HTLC` | The instance |
| `pre` | `[32]u8` | Pre |

**Returns:** `bool`

*Defined at line 151*

---

### `isExpired()`

Checks whether the expired condition is true.

```zig
pub fn isExpired(self: *const HTLC, current_block: u64) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const HTLC` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `bool`

*Defined at line 166*

---

### `open()`

Open a new payment channel between two parties.
Both parties lock funds on-chain; initial off-chain balances = deposits.

```zig
pub fn open(party_a: [33]u8, party_b: [33]u8, amount_a: u64, amount_b: u64) error{ExceedsMaxAmount,ZeroDeposit}!PaymentChannel {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `party_a` | `[33]u8` | Party_a |
| `party_b` | `[33]u8` | Party_b |
| `amount_a` | `u64` | Amount_a |
| `amount_b` | `u64` | Amount_b |

**Returns:** `error`

*Defined at line 198*

---

### `openWithId()`

Open with explicit channel_id (deterministic, for testing)

```zig
pub fn openWithId(channel_id: [32]u8, party_a: [33]u8, party_b: [33]u8, amount_a: u64, amount_b: u64) error{ExceedsMaxAmount,ZeroDeposit}!PaymentChannel {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `channel_id` | `[32]u8` | Channel_id |
| `party_a` | `[33]u8` | Party_a |
| `party_b` | `[33]u8` | Party_b |
| `amount_a` | `u64` | Amount_a |
| `amount_b` | `u64` | Amount_b |

**Returns:** `error`

*Defined at line 247*

---

### `pay()`

Off-chain payment: transfer amount from one party to the other.
Both parties must sign the new state. Sequence number increments atomically.
Total balance is conserved (invariant: balance_a + balance_b == total_locked).

```zig
pub fn pay(self: *PaymentChannel, from_a_to_b: bool, amount: u64, sig_a: [64]u8, sig_b: [64]u8) error{ ChannelNotOpen, InsufficientBalance, BalanceMismatch }!ChannelUpdate {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PaymentChannel` | The instance |
| `from_a_to_b` | `bool` | From_a_to_b |
| `amount` | `u64` | Amount |
| `sig_a` | `[64]u8` | Sig_a |
| `sig_b` | `[64]u8` | Sig_b |

**Returns:** `error`

*Defined at line 280*

---

### `cooperativeClose()`

Cooperative close: both parties agree on final state, no dispute needed.
Returns a SettleTx with the final on-chain transactions.

```zig
pub fn cooperativeClose(self: *PaymentChannel, sig_a: [64]u8, sig_b: [64]u8) error{ChannelNotOpen}!SettleTx {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PaymentChannel` | The instance |
| `sig_a` | `[64]u8` | Sig_a |
| `sig_b` | `[64]u8` | Sig_b |

**Returns:** `error`

*Defined at line 321*

---

### `unilateralClose()`

Unilateral close: one party submits their latest signed state.
Starts the dispute window — counterparty has timeout_blocks to submit newer state.

```zig
pub fn unilateralClose(self: *PaymentChannel, submitted_state: ChannelUpdate, current_block: u64) error{ ChannelNotOpen, InvalidChannelId, BalanceMismatch }!SettleTx {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PaymentChannel` | The instance |
| `submitted_state` | `ChannelUpdate` | Submitted_state |
| `current_block` | `u64` | Current_block |

**Returns:** `error`

*Defined at line 341*

---

### `dispute()`

Dispute: counterparty submits a state with higher sequence_num.
Returns true if the dispute was successful (newer state accepted).

```zig
pub fn dispute(self: *PaymentChannel, newer_state: ChannelUpdate) error{ ChannelNotClosing, InvalidChannelId, StateNotNewer, BalanceMismatch }!bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PaymentChannel` | The instance |
| `newer_state` | `ChannelUpdate` | Newer_state |

**Returns:** `error`

*Defined at line 364*

---

### `settle()`

Settle: finalize the channel on-chain after dispute window expires.
Can be called after closing or disputed state, once timeout has passed.

```zig
pub fn settle(self: *PaymentChannel, current_block: u64) error{ ChannelNotClosable, DisputeWindowActive }!SettleTx {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PaymentChannel` | The instance |
| `current_block` | `u64` | Current_block |

**Returns:** `error`

*Defined at line 386*

---

### `addHTLC()`

Add an HTLC to this channel (for multi-hop routing)

```zig
pub fn addHTLC(self: *PaymentChannel, hash_lock: [32]u8, amount_sat: u64, timeout_block: u64) error{ ChannelNotOpen, TooManyHTLCs }!u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PaymentChannel` | The instance |
| `hash_lock` | `[32]u8` | Hash_lock |
| `amount_sat` | `u64` | Amount_sat |
| `timeout_block` | `u64` | Timeout_block |

**Returns:** `error`

*Defined at line 409*

---

### `revealHTLC()`

Reveal preimage for an HTLC (unlocks payment)

```zig
pub fn revealHTLC(self: *PaymentChannel, htlc_id: u32, preimage: [32]u8) error{ HTLCNotFound, InvalidPreimage }!void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PaymentChannel` | The instance |
| `htlc_id` | `u32` | Htlc_id |
| `preimage` | `[32]u8` | Preimage |

**Returns:** `error`

*Defined at line 427*

---

### `currentUpdate()`

Get the current state as a ChannelUpdate

```zig
pub fn currentUpdate(self: *const PaymentChannel) ChannelUpdate {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PaymentChannel` | The instance |

**Returns:** `ChannelUpdate`

*Defined at line 435*

---

### `getChannelIdHex()`

Format channel_id as hex string into provided buffer

```zig
pub fn getChannelIdHex(self: *const PaymentChannel, buf: []u8) []u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PaymentChannel` | The instance |
| `buf` | `[]u8` | Buf |

**Returns:** `[]u8`

*Defined at line 447*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() ChannelManager {
```

**Returns:** `ChannelManager`

*Defined at line 460*

---

### `openChannel()`

Open a new channel and add it to the registry.
Returns a pointer to the newly created channel.

```zig
pub fn openChannel(self: *ChannelManager, party_a: [33]u8, party_b: [33]u8, amount_a: u64, amount_b: u64) !*PaymentChannel {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ChannelManager` | The instance |
| `party_a` | `[33]u8` | Party_a |
| `party_b` | `[33]u8` | Party_b |
| `amount_a` | `u64` | Amount_a |
| `amount_b` | `u64` | Amount_b |

**Returns:** `!*PaymentChannel`

*Defined at line 470*

---

### `findChannel()`

Find a channel by its ID. Returns null if not found.

```zig
pub fn findChannel(self: *ChannelManager, channel_id: [32]u8) ?*PaymentChannel {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ChannelManager` | The instance |
| `channel_id` | `[32]u8` | Channel_id |

**Returns:** `?*PaymentChannel`

*Defined at line 484*

---

### `closeChannel()`

Close a channel (cooperative close). Returns the settlement TX.

```zig
pub fn closeChannel(self: *ChannelManager, channel_id: [32]u8, sig_a: [64]u8, sig_b: [64]u8) !SettleTx {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ChannelManager` | The instance |
| `channel_id` | `[32]u8` | Channel_id |
| `sig_a` | `[64]u8` | Sig_a |
| `sig_b` | `[64]u8` | Sig_b |

**Returns:** `!SettleTx`

*Defined at line 492*

---

### `getAllChannels()`

Get a slice of all channels (active and inactive).

```zig
pub fn getAllChannels(self: *ChannelManager) []PaymentChannel {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*ChannelManager` | The instance |

**Returns:** `[]PaymentChannel`

*Defined at line 501*

---

### `countByState()`

Count channels in a specific state.

```zig
pub fn countByState(self: *const ChannelManager, target_state: ChannelState) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ChannelManager` | The instance |
| `target_state` | `ChannelState` | Target_state |

**Returns:** `u8`

*Defined at line 506*

---

### `getTotalLockedSat()`

Get total SAT locked across all open/closing channels.

```zig
pub fn getTotalLockedSat(self: *const ChannelManager) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ChannelManager` | The instance |

**Returns:** `u64`

*Defined at line 515*

---

### `printStatus()`

Performs the print status operation on the payment_channel module.

```zig
pub fn printStatus(self: *const ChannelManager) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const ChannelManager` | The instance |

*Defined at line 525*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
