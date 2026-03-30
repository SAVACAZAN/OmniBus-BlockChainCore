# Module: `peer_scoring`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `PeerScore`

Peer score record

*Line: 53*

### `PeerScoringEngine`

Peer Scoring Engine

*Line: 128*

## Constants

| Name | Type | Value |
|------|------|-------|
| `BAN_THRESHOLD` | auto | `i32 = -100` |
| `BAN_DURATION_SEC` | auto | `i64 = 86400` |
| `MAX_TRACKED_PEERS` | auto | `usize = 256` |
| `ScoreEvent` | auto | `enum {` |

## Functions

### `delta`

```zig
pub fn delta(self: ScoreEvent) i32 {
```

**Parameters:**

- `self`: `ScoreEvent`

**Returns:** `i32`

*Line: 36*

---

### `init`

```zig
pub fn init(peer_id: [16]u8) PeerScore {
```

**Parameters:**

- `peer_id`: `[16]u8`

**Returns:** `PeerScore`

*Line: 71*

---

### `applyEvent`

Apply a scoring event

```zig
pub fn applyEvent(self: *PeerScore, event: ScoreEvent) void {
```

**Parameters:**

- `self`: `*PeerScore`
- `event`: `ScoreEvent`

*Line: 85*

---

### `isBanExpired`

Check if ban has expired

```zig
pub fn isBanExpired(self: *const PeerScore) bool {
```

**Parameters:**

- `self`: `*const PeerScore`

**Returns:** `bool`

*Line: 104*

---

### `checkUnban`

Unban if expired

```zig
pub fn checkUnban(self: *PeerScore) void {
```

**Parameters:**

- `self`: `*PeerScore`

*Line: 110*

---

### `trustLevel`

Trust level (0-100)

```zig
pub fn trustLevel(self: *const PeerScore) u8 {
```

**Parameters:**

- `self`: `*const PeerScore`

**Returns:** `u8`

*Line: 119*

---

### `init`

```zig
pub fn init() PeerScoringEngine {
```

**Returns:** `PeerScoringEngine`

*Line: 133*

---

### `getOrCreate`

Get or create peer score

```zig
pub fn getOrCreate(self: *PeerScoringEngine, peer_id: [16]u8) *PeerScore {
```

**Parameters:**

- `self`: `*PeerScoringEngine`
- `peer_id`: `[16]u8`

**Returns:** `*PeerScore`

*Line: 142*

---

### `scoreEvent`

Score an event for a peer

```zig
pub fn scoreEvent(self: *PeerScoringEngine, peer_id: [16]u8, event: ScoreEvent) void {
```

**Parameters:**

- `self`: `*PeerScoringEngine`
- `peer_id`: `[16]u8`
- `event`: `ScoreEvent`

*Line: 167*

---

### `isAllowed`

Check if peer is allowed to connect

```zig
pub fn isAllowed(self: *PeerScoringEngine, peer_id: [16]u8) bool {
```

**Parameters:**

- `self`: `*PeerScoringEngine`
- `peer_id`: `[16]u8`

**Returns:** `bool`

*Line: 177*

---

### `bannedCount`

Get number of currently banned peers

```zig
pub fn bannedCount(self: *const PeerScoringEngine) usize {
```

**Parameters:**

- `self`: `*const PeerScoringEngine`

**Returns:** `usize`

*Line: 188*

---

