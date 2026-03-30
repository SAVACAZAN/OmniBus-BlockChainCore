# Module: `p2p`

## Contents

- [Structs](#structs)
- [Constants](#constants)
- [Functions](#functions)

## Structs

### `MsgHeader`

*Line: 44*

### `MsgPing`

*Line: 79*

### `MsgPeerList`

*Line: 104*

### `PeerAddr`

*Line: 107*

### `MsgBlockAnnounce`

*Line: 113*

### `PeerConnection`

*Line: 145*

### `P2PNode`

*Line: 263*

### `AcceptArgs`

*Line: 487*

### `PeerArgs`

*Line: 510*

## Constants

| Name | Type | Value |
|------|------|-------|
| `NetworkNode` | auto | `network_mod.NetworkNode` |
| `MessageType` | auto | `network_mod.MessageType` |
| `Blockchain` | auto | `blockchain_mod.Blockchain` |
| `Block` | auto | `block_mod.Block` |
| `SyncManager` | auto | `sync_mod.SyncManager` |
| `P2P_PORT_DEFAULT` | auto | `u16 = 8333` |
| `P2P_VERSION` | auto | `u8 = 1` |
| `P2P_MAX_MSG_BYTES` | auto | `u32 = 1_048_576` |
| `P2P_CONNECT_TIMEOUT_MS` | auto | `u64 = 3_000` |
| `P2P_READ_TIMEOUT_MS` | auto | `u64 = 5_000` |
| `MSG_HEADER_SIZE` | auto | `usize = 9` |
| `KnockResult` | auto | `enum {` |

## Functions

### `encode`

```zig
pub fn encode(self: MsgHeader, buf: *[MSG_HEADER_SIZE]u8) void {
```

**Parameters:**

- `self`: `MsgHeader`
- `buf`: `*[MSG_HEADER_SIZE]u8`

*Line: 51*

---

### `decode`

```zig
pub fn decode(buf: *const [MSG_HEADER_SIZE]u8) MsgHeader {
```

**Parameters:**

- `buf`: `*const [MSG_HEADER_SIZE]u8`

**Returns:** `MsgHeader`

*Line: 59*

---

### `calcChecksum`

Checksum simplu: suma tuturor byte-ilor payload mod 65536

```zig
pub fn calcChecksum(data: []const u8) u16 {
```

**Parameters:**

- `data`: `[]const u8`

**Returns:** `u16`

*Line: 71*

---

### `encode`

```zig
pub fn encode(self: MsgPing, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `MsgPing`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 84*

---

### `decode`

```zig
pub fn decode(data: []const u8) ?MsgPing {
```

**Parameters:**

- `data`: `[]const u8`

**Returns:** `?MsgPing`

*Line: 92*

---

### `encode`

```zig
pub fn encode(self: MsgBlockAnnounce, allocator: std.mem.Allocator) ![]u8 {
```

**Parameters:**

- `self`: `MsgBlockAnnounce`
- `allocator`: `std.mem.Allocator`

**Returns:** `![]u8`

*Line: 119*

---

### `decode`

```zig
pub fn decode(data: []const u8) ?MsgBlockAnnounce {
```

**Parameters:**

- `data`: `[]const u8`

**Returns:** `?MsgBlockAnnounce`

*Line: 128*

---

### `send`

Trimite un mesaj binar catre peer

```zig
pub fn send(self: *PeerConnection, msg_type: u8, payload: []const u8) !void {
```

**Parameters:**

- `self`: `*PeerConnection`
- `msg_type`: `u8`
- `payload`: `[]const u8`

**Returns:** `!void`

*Line: 155*

---

### `recv`

Citeste un mesaj binar de la peer
Caller trebuie sa elibereze payload-ul cu allocator.free()

```zig
pub fn recv(self: *PeerConnection) !struct { msg_type: u8, payload: []u8 } {
```

**Parameters:**

- `self`: `*PeerConnection`

**Returns:** `!struct`

*Line: 175*

---

### `sendPing`

Trimite PING cu inaltimea curenta a lantului

```zig
pub fn sendPing(self: *PeerConnection, node_id: []const u8, height: u64) !void {
```

**Parameters:**

- `self`: `*PeerConnection`
- `node_id`: `[]const u8`
- `height`: `u64`

**Returns:** `!void`

*Line: 204*

---

### `close`

```zig
pub fn close(self: *PeerConnection) void {
```

**Parameters:**

- `self`: `*PeerConnection`

*Line: 243*

---

### `attachBlockchain`

Ataseaza blockchain si sync_mgr — apelat din main dupa init P2PNode
Necesar pentru ca dispatchMessage sa poata aplica blocuri primite

```zig
pub fn attachBlockchain(self: *P2PNode, bc: *Blockchain, sm: *SyncManager) void {
```

**Parameters:**

- `self`: `*P2PNode`
- `bc`: `*Blockchain`
- `sm`: `*SyncManager`

*Line: 298*

---

### `deinit`

```zig
pub fn deinit(self: *P2PNode) void {
```

**Parameters:**

- `self`: `*P2PNode`

*Line: 303*

---

### `connectToPeer`

Conecteaza la un peer (TCP outbound)

```zig
pub fn connectToPeer(self: *P2PNode, host: []const u8, port: u16, node_id: []const u8) !void {
```

**Parameters:**

- `self`: `*P2PNode`
- `host`: `[]const u8`
- `port`: `u16`
- `node_id`: `[]const u8`

**Returns:** `!void`

*Line: 309*

---

### `attachToNetwork`

Ataseaza acest P2PNode la un P2PNetwork — de apelat din main.zig dupa init

```zig
pub fn attachToNetwork(self: *P2PNode, net: *network_mod.P2PNetwork) void {
```

**Parameters:**

- `self`: `*P2PNode`
- `net`: `*network_mod.P2PNetwork`

*Line: 367*

---

### `peerCount`

Numarul de peeri conectati

```zig
pub fn peerCount(self: *const P2PNode) usize {
```

**Parameters:**

- `self`: `*const P2PNode`

**Returns:** `usize`

*Line: 372*

---

### `cleanDeadPeers`

Deconecteaza peerii morti (nu mai raspund)

```zig
pub fn cleanDeadPeers(self: *P2PNode) void {
```

**Parameters:**

- `self`: `*P2PNode`

*Line: 381*

---

### `knockKnock`

Knock Knock — anunta reteaua + verifica daca exista duplicat pe acelasi IP

Pasi:
1. Trimite UDP broadcast "OMNI:we are here:<node_id>:<height>" pe 3 porturi
2. Asculta 3 secunde raspunsuri UDP pe portul principal
3. Daca primeste acelasi mesaj de pe acelasi IP → seteaza is_idle = true
4. VPN/Tor: daca IP-ul sursa e acelasi cu al nostru (loopback sau LAN) → idle

Returneaza KnockResult pentru logging in main

```zig
pub fn knockKnock(self: *P2PNode) KnockResult {
```

**Parameters:**

- `self`: `*P2PNode`

**Returns:** `KnockResult`

*Line: 402*

---

### `printStatus`

```zig
pub fn printStatus(self: *const P2PNode) void {
```

**Parameters:**

- `self`: `*const P2PNode`

*Line: 468*

---

### `startListener`

Porneste server TCP inbound pe `local_port` — thread detached.
Fiecare peer inbound primeste propriul thread handler.
Returneaza error daca bind/listen esueaza (port ocupat, permisiuni etc.)

```zig
pub fn startListener(self: *P2PNode) !void {
```

**Parameters:**

- `self`: `*P2PNode`

**Returns:** `!void`

*Line: 480*

---

### `sendToPeer`

Trimite un mesaj raw la un peer specific (dupa node_id)
Folosit de SyncManager pentru GetHeaders etc.

```zig
pub fn sendToPeer(self: *P2PNode, node_id: []const u8, msg_type: u8, payload: []const u8) !void {
```

**Parameters:**

- `self`: `*P2PNode`
- `node_id`: `[]const u8`
- `msg_type`: `u8`
- `payload`: `[]const u8`

**Returns:** `!void`

*Line: 734*

---

### `requestSync`

Trimite sync_request la primul peer conectat mai sus decat noi
Payload: [from_height: u64 LE]

```zig
pub fn requestSync(self: *P2PNode, from_height: u64) void {
```

**Parameters:**

- `self`: `*P2PNode`
- `from_height`: `u64`

*Line: 746*

---

