# Module: `peer_scoring`

> Peer reputation system — score peers based on behavior, ban misbehaving peers, reward good behavior.

**Source:** `core/peer_scoring.zig` | **Lines:** 281 | **Functions:** 11 | **Structs:** 2 | **Tests:** 10

---

## Contents

### Structs
- [`PeerScore`](#peerscore) — Peer score record
- [`PeerScoringEngine`](#peerscoringengine) — Peer Scoring Engine

### Constants
- [4 constants defined](#constants)

### Functions
- [`delta()`](#delta) — Performs the delta operation on the peer_scoring module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`applyEvent()`](#applyevent) — Apply a scoring event
- [`isBanExpired()`](#isbanexpired) — Check if ban has expired
- [`checkUnban()`](#checkunban) — Unban if expired
- [`trustLevel()`](#trustlevel) — Trust level (0-100)
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`getOrCreate()`](#getorcreate) — Get or create peer score
- [`scoreEvent()`](#scoreevent) — Score an event for a peer
- [`isAllowed()`](#isallowed) — Check if peer is allowed to connect
- [`bannedCount()`](#bannedcount) — Get number of currently banned peers

---

## Structs

### `PeerScore`

Peer score record

| Field | Type | Description |
|-------|------|-------------|
| `peer_id` | `[16]u8` | Peer_id |
| `score` | `i32` | Score |
| `valid_blocks` | `u32` | Valid_blocks |
| `violations` | `u32` | Violations |
| `banned` | `bool` | Banned |
| `ban_until` | `i64` | Ban_until |
| `first_seen` | `i64` | First_seen |
| `last_active` | `i64` | Last_active |

*Defined at line 53*

---

### `PeerScoringEngine`

Peer Scoring Engine

| Field | Type | Description |
|-------|------|-------------|
| `peers` | `[MAX_TRACKED_PEERS]PeerScore` | Peers |
| `peer_count` | `usize` | Peer_count |
| `total_bans` | `u32` | Total_bans |

*Defined at line 128*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `BAN_THRESHOLD` | `i32 = -100` | B a n_ t h r e s h o l d |
| `BAN_DURATION_SEC` | `i64 = 86400` | B a n_ d u r a t i o n_ s e c |
| `MAX_TRACKED_PEERS` | `usize = 256` | M a x_ t r a c k e d_ p e e r s |
| `ScoreEvent` | `enum {` | Score event |

---

## Functions

### `delta()`

Performs the delta operation on the peer_scoring module.

```zig
pub fn delta(self: ScoreEvent) i32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `ScoreEvent` | The instance |

**Returns:** `i32`

*Defined at line 36*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(peer_id: [16]u8) PeerScore {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `peer_id` | `[16]u8` | Peer_id |

**Returns:** `PeerScore`

*Defined at line 71*

---

### `applyEvent()`

Apply a scoring event

```zig
pub fn applyEvent(self: *PeerScore, event: ScoreEvent) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerScore` | The instance |
| `event` | `ScoreEvent` | Event |

*Defined at line 85*

---

### `isBanExpired()`

Check if ban has expired

```zig
pub fn isBanExpired(self: *const PeerScore) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PeerScore` | The instance |

**Returns:** `bool`

*Defined at line 104*

---

### `checkUnban()`

Unban if expired

```zig
pub fn checkUnban(self: *PeerScore) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerScore` | The instance |

*Defined at line 110*

---

### `trustLevel()`

Trust level (0-100)

```zig
pub fn trustLevel(self: *const PeerScore) u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PeerScore` | The instance |

**Returns:** `u8`

*Defined at line 119*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() PeerScoringEngine {
```

**Returns:** `PeerScoringEngine`

*Defined at line 133*

---

### `getOrCreate()`

Get or create peer score

```zig
pub fn getOrCreate(self: *PeerScoringEngine, peer_id: [16]u8) *PeerScore {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerScoringEngine` | The instance |
| `peer_id` | `[16]u8` | Peer_id |

**Returns:** `*PeerScore`

*Defined at line 142*

---

### `scoreEvent()`

Score an event for a peer

```zig
pub fn scoreEvent(self: *PeerScoringEngine, peer_id: [16]u8, event: ScoreEvent) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerScoringEngine` | The instance |
| `peer_id` | `[16]u8` | Peer_id |
| `event` | `ScoreEvent` | Event |

*Defined at line 167*

---

### `isAllowed()`

Check if peer is allowed to connect

```zig
pub fn isAllowed(self: *PeerScoringEngine, peer_id: [16]u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerScoringEngine` | The instance |
| `peer_id` | `[16]u8` | Peer_id |

**Returns:** `bool`

*Defined at line 177*

---

### `bannedCount()`

Get number of currently banned peers

```zig
pub fn bannedCount(self: *const PeerScoringEngine) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const PeerScoringEngine` | The instance |

**Returns:** `usize`

*Defined at line 188*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
