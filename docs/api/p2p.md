# Module: `p2p`

> TCP P2P networking — binary protocol for peer connections, block/TX propagation, peer discovery, knock-knock duplicate detection, and message broadcasting.

**Source:** `core/p2p.zig` | **Lines:** 2718 | **Functions:** 63 | **Structs:** 15 | **Tests:** 47

---

## Contents

### Structs
- [`MsgHeader`](#msgheader) — Data structure for msg header. Fields include: version, msg_type, payload_len, c...
- [`MsgPing`](#msgping) — Data structure for msg ping. Fields include: node_id, height, version.
- [`MsgPeerList`](#msgpeerlist) — Data structure for msg peer list. Fields include: peers.
- [`PeerAddr`](#peeraddr) — Data structure for peer addr. Fields include: ip, port.
- [`MsgBlockAnnounce`](#msgblockannounce) — Data structure for msg block announce. Fields include: block_height, block_hash,...
- [`BannedPeer`](#bannedpeer) — Banned peer entry — tracks host:port + ban expiry
- [`ReconnectInfo`](#reconnectinfo) — Per-peer reconnect tracking
- [`RateLimitState`](#ratelimitstate) — Per-peer rate limiting state
- [`PeerConnection`](#peerconnection) — Data structure for peer connection. Fields include: stream, node_id, host, port,...
- [`SeenHashes`](#seenhashes) — Tracks recently seen TX/block hashes to prevent infinite relay loops.
Fixed-size...
- [`Entry`](#entry) — Data structure for entry. Fields include: hash, hash_len, timestamp, active.
- [`GossipTxPayload`](#gossiptxpayload) — Gossip TX payload: JSON-encoded transaction for simplicity.
Wire format: [hash_l...
- [`P2PNode`](#p2pnode) — Data structure for p2 p node. Fields include: local_id, local_host, local_port, ...
- [`AcceptArgs`](#acceptargs) — Data structure representing a accept args in the p2p module.
- [`PeerArgs`](#peerargs) — Data structure representing a peer args in the p2p module.

### Constants
- [29 constants defined](#constants)

### Functions
- [`encode()`](#encode) — Decodes the encoded data back to its original format.
- [`decode()`](#decode) — Performs the decode operation on the p2p module.
- [`calcChecksum()`](#calcchecksum) — Checksum simplu: suma tuturor byte-ilor payload mod 65536
- [`encode()`](#encode) — Decodes the encoded data back to its original format.
- [`decode()`](#decode) — Attempts to find decode. Returns null if not found.
- [`encodePeerList()`](#encodepeerlist) — Encode a list of PeerAddr into a peer_list payload.
- [`decodePeerList()`](#decodepeerlist) — Decode a peer_list payload into a slice of PeerAddr.
Caller must free ...
- [`encode()`](#encode) — Decodes the encoded data back to its original format.
- [`decode()`](#decode) — Attempts to find decode. Returns null if not found.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`isExpired()`](#isexpired) — Checks whether the expired condition is true.
- [`matchesHost()`](#matcheshost) — Checks matches host condition. Returns a boolean result.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`recordMessage()`](#recordmessage) — Record a message. Returns true if within limits, false if exceeded.
- [`send()`](#send) — Trimite un mesaj binar catre peer
- [`recv()`](#recv) — Citeste un mesaj binar de la peer
Caller trebuie sa elibereze payload-...
- [`sendPing()`](#sendping) — Trimite PING cu inaltimea curenta a lantului
- [`close()`](#close) — Closes the  and releases associated resources.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`contains()`](#contains) — Returns true if the hash was already seen (still fresh).
- [`insert()`](#insert) — Inserts a hash. Returns false if it was already present (duplicate).
- [`evictExpired()`](#evictexpired) — Evict entries older than SEEN_HASH_EXPIRY_S
- [`encode()`](#encode) — Decodes the encoded data back to its original format.
- [`decode()`](#decode) — Attempts to find decode. Returns null if not found.
- [`encodeGetHeaders()`](#encodegetheaders) — Encode a getheaders_p2p request payload
- [`decodeGetHeaders()`](#decodegetheaders) — Decode a getheaders_p2p request payload
- [`serializeSpvHeader()`](#serializespvheader) — Serialize a light_client BlockHeader into the 120-byte wire format.
Fi...
- [`deserializeSpvHeader()`](#deserializespvheader) — Deserialize a 120-byte wire header into a light_client BlockHeader.
- [`encodeBloomFilter()`](#encodebloomfilter) — Encode a filterload payload: [num_hash_funcs:u8][bits:512]
- [`decodeBloomFilter()`](#decodebloomfilter) — Decode a filterload payload into a BloomFilter.
- [`attachBlockchain()`](#attachblockchain) — Ataseaza blockchain si sync_mgr — apelat din main dupa init P2PNode
Ne...
- [`attachLightClient()`](#attachlightclient) — Attach a light client for SPV header sync mode
- [`syncHeaders()`](#syncheaders) — SPV: Send getheaders_p2p to all connected peers.
Requests headers star...
- [`requestMerkleProof()`](#requestmerkleproof) — SPV: Request a Merkle proof for a specific TX hash in a specific block...
- [`sendBloomFilter()`](#sendbloomfilter) — SPV: Send our Bloom filter to all connected peers (filterload).
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`connectToPeer()`](#connecttopeer) — Conecteaza la un peer (TCP outbound)
- [`broadcastTx()`](#broadcasttx) — Broadcast a TX to all connected peers via gossip.
Deduplicates: if we ...
- [`gossipMaintenance()`](#gossipmaintenance) — Periodic maintenance: evict expired seen hashes
- [`getGossipStats()`](#getgossipstats) — Returns gossip statistics for logging
- [`sendGetPeers()`](#sendgetpeers) — Send a get_peers request to a specific peer
- [`requestPeersFromAll()`](#requestpeersfromall) — Send get_peers to all connected peers
- [`buildPeerListPayload()`](#buildpeerlistpayload) — Build a peer_list payload from our known connected peers
Returns encod...
- [`attachToNetwork()`](#attachtonetwork) — Ataseaza acest P2PNode la un P2PNetwork — de apelat din main.zig dupa ...
- [`peerCount()`](#peercount) — Numarul de peeri conectati
- [`cleanDeadPeers()`](#cleandeadpeers) — Deconecteaza peerii morti — adauga la reconnect queue in loc de sterge...
- [`knockKnock()`](#knockknock) — Knock Knock — anunta reteaua + verifica daca exista duplicat pe acelas...
- [`isBanned()`](#isbanned) — Check if a host:port is currently banned
- [`banPeer()`](#banpeer) — Ban a peer by host:port for the configured duration
- [`evictExpiredBans()`](#evictexpiredbans) — Evict expired bans
- [`scorePeer()`](#scorepeer) — Score a peer event and auto-ban if threshold reached
- [`checkRateLimit()`](#checkratelimit) — Check rate limit for a peer. Returns true if within limits.
If exceede...
- [`processReconnects()`](#processreconnects) — Process reconnect queue — attempt reconnects for peers past the delay
- [`checkSubnetDiversity()`](#checksubnetdiversity) — Check if adding a peer with this IP would violate subnet diversity rul...
- [`subnetCount()`](#subnetcount) — Count the number of distinct /16 subnets among connected peers
- [`hasMinSubnetDiversity()`](#hasminsubnetdiversity) — Check if we have enough subnet diversity (at least MIN_SUBNET_DIVERSIT...
- [`canAcceptInbound()`](#canacceptinbound) — Check if we can accept an inbound connection
- [`hardeningMaintenance()`](#hardeningmaintenance) — Periodic hardening maintenance
- [`printStatus()`](#printstatus) — Performs the print status operation on the p2p module.
- [`startListener()`](#startlistener) — Porneste server TCP inbound pe `local_port` — thread detached.
Fiecare...
- [`sendToPeer()`](#sendtopeer) — Trimite un mesaj raw la un peer specific (dupa node_id)
Folosit de Syn...
- [`requestSync()`](#requestsync) — Trimite sync_request la primul peer conectat mai sus decat noi
Payload...

---

## Structs

### `MsgHeader`

Data structure for msg header. Fields include: version, msg_type, payload_len, checksum, flags.

| Field | Type | Description |
|-------|------|-------------|
| `version` | `u8` | Version |
| `msg_type` | `u8` | Msg_type |
| `payload_len` | `u32` | Payload_len |
| `checksum` | `u16` | Checksum |
| `flags` | `u8` | Flags |

*Defined at line 103*

---

### `MsgPing`

Data structure for msg ping. Fields include: node_id, height, version.

| Field | Type | Description |
|-------|------|-------------|
| `node_id` | `[32]u8` | Node_id |
| `height` | `u64` | Height |
| `version` | `u8` | Version |

*Defined at line 138*

---

### `MsgPeerList`

Data structure for msg peer list. Fields include: peers.

| Field | Type | Description |
|-------|------|-------------|
| `peers` | `[]PeerAddr` | Peers |

*Defined at line 163*

---

### `PeerAddr`

Data structure for peer addr. Fields include: ip, port.

| Field | Type | Description |
|-------|------|-------------|
| `ip` | `[4]u8` | Ip |
| `port` | `u16` | Port |

*Defined at line 166*

---

### `MsgBlockAnnounce`

Data structure for msg block announce. Fields include: block_height, block_hash, miner_id, reward_sat.

| Field | Type | Description |
|-------|------|-------------|
| `block_height` | `u64` | Block_height |
| `block_hash` | `[32]u8` | Block_hash |
| `miner_id` | `[32]u8` | Miner_id |
| `reward_sat` | `u64` | Reward_sat |

*Defined at line 212*

---

### `BannedPeer`

Banned peer entry — tracks host:port + ban expiry

| Field | Type | Description |
|-------|------|-------------|
| `host` | `[64]u8` | Host |
| `host_len` | `u8` | Host_len |
| `port` | `u16` | Port |
| `banned_until` | `i64` | Banned_until |
| `reason` | `[64]u8` | Reason |
| `reason_len` | `u8` | Reason_len |
| `active` | `bool` | Active |

*Defined at line 245*

---

### `ReconnectInfo`

Per-peer reconnect tracking

| Field | Type | Description |
|-------|------|-------------|
| `host` | `[64]u8` | Host |
| `host_len` | `u8` | Host_len |
| `port` | `u16` | Port |
| `node_id` | `[64]u8` | Node_id |
| `node_id_len` | `u8` | Node_id_len |
| `attempts` | `u8` | Attempts |
| `last_disconnect` | `i64` | Last_disconnect |
| `active` | `bool` | Active |

*Defined at line 282*

---

### `RateLimitState`

Per-peer rate limiting state

| Field | Type | Description |
|-------|------|-------------|
| `msg_count` | `u32` | Msg_count |
| `byte_count` | `u64` | Byte_count |
| `window_start` | `i64` | Window_start |

*Defined at line 310*

---

### `PeerConnection`

Data structure for peer connection. Fields include: stream, node_id, host, port, height.

| Field | Type | Description |
|-------|------|-------------|
| `stream` | `std.net.Stream` | Stream |
| `node_id` | `[]const u8` | Node_id |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `height` | `u64` | Height |
| `connected` | `bool` | Connected |
| `allocator` | `std.mem.Allocator` | Allocator |
| `direction` | `ConnDirection` | Direction |
| `rate_limit` | `RateLimitState` | Rate_limit |

*Defined at line 347*

---

### `SeenHashes`

Tracks recently seen TX/block hashes to prevent infinite relay loops.
Fixed-size ring buffer — no dynamic allocation after init.

| Field | Type | Description |
|-------|------|-------------|
| `entries` | `[SEEN_HASHES_MAX]Entry` | Entries |
| `count` | `usize` | Count |
| `next_slot` | `usize` | Next_slot |

*Defined at line 466*

---

### `Entry`

Data structure for entry. Fields include: hash, hash_len, timestamp, active.

| Field | Type | Description |
|-------|------|-------------|
| `hash` | `[64]u8` | Hash |
| `hash_len` | `u8` | Hash_len |
| `timestamp` | `i64` | Timestamp |
| `active` | `bool` | Active |

*Defined at line 467*

---

### `GossipTxPayload`

Gossip TX payload: JSON-encoded transaction for simplicity.
Wire format: [hash_len:1][hash:N][json_len:4LE][json:M]

| Field | Type | Description |
|-------|------|-------------|
| `tx_hash` | `[]const u8` | Tx_hash |
| `tx_json` | `[]const u8` | Tx_json |

*Defined at line 536*

---

### `P2PNode`

Data structure for p2 p node. Fields include: local_id, local_host, local_port, peers, allocator.

| Field | Type | Description |
|-------|------|-------------|
| `local_id` | `[]const u8` | Local_id |
| `local_host` | `[]const u8` | Local_host |
| `local_port` | `u16` | Local_port |
| `peers` | `array_list.Managed(PeerConnection)` | Peers |
| `allocator` | `std.mem.Allocator` | Allocator |
| `chain_height` | `u64` | Chain_height |
| `is_idle` | `bool` | Is_idle |
| `blockchain` | `?*Blockchain` | Blockchain |
| `sync_mgr` | `?*SyncManager` | Sync_mgr |
| `light_client` | `?*light_client_mod.LightClient` | Light_client |
| `seen_tx_hashes` | `SeenHashes` | Seen_tx_hashes |
| `seen_block_hashes` | `SeenHashes` | Seen_block_hashes |
| `gossip_tx_count` | `u64` | Gossip_tx_count |
| `gossip_block_count` | `u64` | Gossip_block_count |
| `scoring_engine` | `scoring_mod.PeerScoringEngine` | Scoring_engine |
| `banned_peers` | `[MAX_BANNED_PEERS]BannedPeer` | Banned_peers |
| `banned_count` | `u16` | Banned_count |
| `reconnect_queue` | `[MAX_PEERS]ReconnectInfo` | Reconnect_queue |
| `reconnect_count` | `u16` | Reconnect_count |
| `inbound_count` | `u16` | Inbound_count |

*Defined at line 712*

---

### `AcceptArgs`

Data structure representing a accept args in the p2p module.

*Defined at line 1489*

---

### `PeerArgs`

Data structure representing a peer args in the p2p module.

*Defined at line 1519*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `NetworkNode` | `network_mod.NetworkNode` | Network node |
| `MessageType` | `network_mod.MessageType` | Message type |
| `Blockchain` | `blockchain_mod.Blockchain` | Blockchain |
| `Block` | `block_mod.Block` | Block |
| `SyncManager` | `sync_mod.SyncManager` | Sync manager |
| `P2P_PORT_DEFAULT` | `u16 = 8333` | P2 p_ p o r t_ d e f a u l t |
| `P2P_VERSION` | `u8 = 1` | P2 p_ v e r s i o n |
| `P2P_MAX_MSG_BYTES` | `u32 = 1_048_576` | P2 p_ m a x_ m s g_ b y t e s |
| `P2P_CONNECT_TIMEOUT_MS` | `u64 = 3_000` | P2 p_ c o n n e c t_ t i m e o u t_ m s |
| `P2P_READ_TIMEOUT_MS` | `u64 = 5_000` | P2 p_ r e a d_ t i m e o u t_ m s |
| `MAX_INBOUND` | `usize = 32` | M a x_ i n b o u n d |
| `MAX_OUTBOUND` | `usize = 8` | M a x_ o u t b o u n d |
| `MAX_PEERS` | `usize = MAX_INBOUND + MAX_OUTBOUND` | M a x_ p e e r s |
| `MAX_RECONNECT_ATTEMPTS` | `u8 = 3` | M a x_ r e c o n n e c t_ a t t e m p t s |
| `RECONNECT_DELAY_SEC` | `i64 = 30` | R e c o n n e c t_ d e l a y_ s e c |
| `RATE_LIMIT_MSG_PER_SEC` | `u32 = 100` | R a t e_ l i m i t_ m s g_ p e r_ s e c |
| `RATE_LIMIT_BYTES_PER_SEC` | `u64 = 10 * 1024 * 1024` | R a t e_ l i m i t_ b y t e s_ p e r_ s e c |
| `RATE_LIMIT_BAN_SCORE` | `i32 = 50` | R a t e_ l i m i t_ b a n_ s c o r e |
| `MAX_BANNED_PEERS` | `usize = 256` | M a x_ b a n n e d_ p e e r s |
| `MAX_PEERS_PER_SUBNET` | `usize = 2` | M a x_ p e e r s_ p e r_ s u b n e t |
| `MIN_SUBNET_DIVERSITY` | `usize = 4` | M i n_ s u b n e t_ d i v e r s i t y |
| `MSG_HEADER_SIZE` | `usize = 9` | M s g_ h e a d e r_ s i z e |
| `PEX_MAX_PEERS` | `usize = 100` | P e x_ m a x_ p e e r s |
| `PEX_PEER_SIZE` | `usize = 6` | P e x_ p e e r_ s i z e |
| `ConnDirection` | `enum {` | Conn direction |
| `GossipBlockPayload` | `MsgBlockAnnounce` | Gossip block payload |
| `SPV_HEADER_SIZE` | `usize = 124` | S p v_ h e a d e r_ s i z e |
| `SPV_MAX_HEADERS_PER_MSG` | `u32 = 2000` | S p v_ m a x_ h e a d e r s_ p e r_ m s g |
| `KnockResult` | `enum {` | Knock result |

---

## Functions

### `encode()`

Decodes the encoded data back to its original format.

```zig
pub fn encode(self: MsgHeader, buf: *[MSG_HEADER_SIZE]u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `MsgHeader` | The instance |
| `buf` | `*[MSG_HEADER_SIZE]u8` | Buf |

*Defined at line 110*

---

### `decode()`

Performs the decode operation on the p2p module.

```zig
pub fn decode(buf: *const [MSG_HEADER_SIZE]u8) MsgHeader {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `buf` | `*const [MSG_HEADER_SIZE]u8` | Buf |

**Returns:** `MsgHeader`

*Defined at line 118*

---

### `calcChecksum()`

Checksum simplu: suma tuturor byte-ilor payload mod 65536

```zig
pub fn calcChecksum(data: []const u8) u16 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `u16`

*Defined at line 130*

---

### `encode()`

Decodes the encoded data back to its original format.

```zig
pub fn encode(self: MsgPing, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `MsgPing` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 143*

---

### `decode()`

Attempts to find decode. Returns null if not found.

```zig
pub fn decode(data: []const u8) ?MsgPing {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `?MsgPing`

*Defined at line 151*

---

### `encodePeerList()`

Encode a list of PeerAddr into a peer_list payload.

```zig
pub fn encodePeerList(peers: []const MsgPeerList.PeerAddr, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `peers` | `[]const MsgPeerList.PeerAddr` | Peers |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 183*

---

### `decodePeerList()`

Decode a peer_list payload into a slice of PeerAddr.
Caller must free the returned slice with allocator.free().

```zig
pub fn decodePeerList(data: []const u8, allocator: std.mem.Allocator) ![]MsgPeerList.PeerAddr {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]MsgPeerList.PeerAddr`

*Defined at line 198*

---

### `encode()`

Decodes the encoded data back to its original format.

```zig
pub fn encode(self: MsgBlockAnnounce, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `MsgBlockAnnounce` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 218*

---

### `decode()`

Attempts to find decode. Returns null if not found.

```zig
pub fn decode(data: []const u8) ?MsgBlockAnnounce {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `?MsgBlockAnnounce`

*Defined at line 227*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(host: []const u8, port: u16, duration_sec: i64, reason: []const u8) BannedPeer {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `duration_sec` | `i64` | Duration_sec |
| `reason` | `[]const u8` | Reason |

**Returns:** `BannedPeer`

*Defined at line 254*

---

### `isExpired()`

Checks whether the expired condition is true.

```zig
pub fn isExpired(self: *const BannedPeer) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BannedPeer` | The instance |

**Returns:** `bool`

*Defined at line 269*

---

### `matchesHost()`

Checks matches host condition. Returns a boolean result.

```zig
pub fn matchesHost(self: *const BannedPeer, host: []const u8, port: u16) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BannedPeer` | The instance |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |

**Returns:** `bool`

*Defined at line 273*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(host: []const u8, port: u16, node_id: []const u8) ReconnectInfo {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `node_id` | `[]const u8` | Node_id |

**Returns:** `ReconnectInfo`

*Defined at line 292*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() RateLimitState {
```

**Returns:** `RateLimitState`

*Defined at line 315*

---

### `recordMessage()`

Record a message. Returns true if within limits, false if exceeded.

```zig
pub fn recordMessage(self: *RateLimitState, msg_size: usize) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*RateLimitState` | The instance |
| `msg_size` | `usize` | Msg_size |

**Returns:** `bool`

*Defined at line 324*

---

### `send()`

Trimite un mesaj binar catre peer

```zig
pub fn send(self: *PeerConnection, msg_type: u8, payload: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerConnection` | The instance |
| `msg_type` | `u8` | Msg_type |
| `payload` | `[]const u8` | Payload |

**Returns:** `!void`

*Defined at line 361*

---

### `recv()`

Citeste un mesaj binar de la peer
Caller trebuie sa elibereze payload-ul cu allocator.free()

```zig
pub fn recv(self: *PeerConnection) !struct { msg_type: u8, payload: []u8 } {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerConnection` | The instance |

**Returns:** `!struct`

*Defined at line 381*

---

### `sendPing()`

Trimite PING cu inaltimea curenta a lantului

```zig
pub fn sendPing(self: *PeerConnection, node_id: []const u8, height: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerConnection` | The instance |
| `node_id` | `[]const u8` | Node_id |
| `height` | `u64` | Height |

**Returns:** `!void`

*Defined at line 410*

---

### `close()`

Closes the  and releases associated resources.

```zig
pub fn close(self: *PeerConnection) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*PeerConnection` | The instance |

*Defined at line 449*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init() SeenHashes {
```

**Returns:** `SeenHashes`

*Defined at line 478*

---

### `contains()`

Returns true if the hash was already seen (still fresh).

```zig
pub fn contains(self: *const SeenHashes, hash: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SeenHashes` | The instance |
| `hash` | `[]const u8` | Hash |

**Returns:** `bool`

*Defined at line 490*

---

### `insert()`

Inserts a hash. Returns false if it was already present (duplicate).

```zig
pub fn insert(self: *SeenHashes, hash: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SeenHashes` | The instance |
| `hash` | `[]const u8` | Hash |

**Returns:** `bool`

*Defined at line 503*

---

### `evictExpired()`

Evict entries older than SEEN_HASH_EXPIRY_S

```zig
pub fn evictExpired(self: *SeenHashes) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SeenHashes` | The instance |

*Defined at line 523*

---

### `encode()`

Decodes the encoded data back to its original format.

```zig
pub fn encode(self: GossipTxPayload, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `GossipTxPayload` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 540*

---

### `decode()`

Attempts to find decode. Returns null if not found.

```zig
pub fn decode(data: []const u8) ?GossipTxPayload {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `?GossipTxPayload`

*Defined at line 552*

---

### `encodeGetHeaders()`

Encode a getheaders_p2p request payload

```zig
pub fn encodeGetHeaders(start_height: u32, count: u32, buf: *[8]u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `start_height` | `u32` | Start_height |
| `count` | `u32` | Count |
| `buf` | `*[8]u8` | Buf |

*Defined at line 597*

---

### `decodeGetHeaders()`

Decode a getheaders_p2p request payload

```zig
pub fn decodeGetHeaders(data: []const u8) ?struct { start_height: u32, count: u32 } {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `?struct`

*Defined at line 603*

---

### `serializeSpvHeader()`

Serialize a light_client BlockHeader into the 120-byte wire format.
Fields: index(8) + timestamp(8) + prev_hash(32) + merkle_root(32) + hash(32) + difficulty(4) + nonce(8) = 120

```zig
pub fn serializeSpvHeader(header: *const light_client_mod.BlockHeader, buf: *[SPV_HEADER_SIZE]u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `header` | `*const light_client_mod.BlockHeader` | Header |
| `buf` | `*[SPV_HEADER_SIZE]u8` | Buf |

*Defined at line 613*

---

### `deserializeSpvHeader()`

Deserialize a 120-byte wire header into a light_client BlockHeader.

```zig
pub fn deserializeSpvHeader(data: *const [SPV_HEADER_SIZE]u8) light_client_mod.BlockHeader {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `*const [SPV_HEADER_SIZE]u8` | Data |

**Returns:** `light_client_mod.BlockHeader`

*Defined at line 631*

---

### `encodeBloomFilter()`

Encode a filterload payload: [num_hash_funcs:u8][bits:512]

```zig
pub fn encodeBloomFilter(filter: *const light_client_mod.BloomFilter, buf: *[513]u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `filter` | `*const light_client_mod.BloomFilter` | Filter |
| `buf` | `*[513]u8` | Buf |

*Defined at line 687*

---

### `decodeBloomFilter()`

Decode a filterload payload into a BloomFilter.

```zig
pub fn decodeBloomFilter(data: []const u8) ?light_client_mod.BloomFilter {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[]const u8` | Data |

**Returns:** `?light_client_mod.BloomFilter`

*Defined at line 693*

---

### `attachBlockchain()`

Ataseaza blockchain si sync_mgr — apelat din main dupa init P2PNode
Necesar pentru ca dispatchMessage sa poata aplica blocuri primite

```zig
pub fn attachBlockchain(self: *P2PNode, bc: *Blockchain, sm: *SyncManager) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `bc` | `*Blockchain` | Bc |
| `sm` | `*SyncManager` | Sm |

*Defined at line 780*

---

### `attachLightClient()`

Attach a light client for SPV header sync mode

```zig
pub fn attachLightClient(self: *P2PNode, lc: *light_client_mod.LightClient) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `lc` | `*light_client_mod.LightClient` | Lc |

*Defined at line 786*

---

### `syncHeaders()`

SPV: Send getheaders_p2p to all connected peers.
Requests headers starting from our current header chain height.

```zig
pub fn syncHeaders(self: *P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

*Defined at line 792*

---

### `requestMerkleProof()`

SPV: Request a Merkle proof for a specific TX hash in a specific block.

```zig
pub fn requestMerkleProof(self: *P2PNode, tx_hash: [32]u8, block_index: u32) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `tx_hash` | `[32]u8` | Tx_hash |
| `block_index` | `u32` | Block_index |

*Defined at line 817*

---

### `sendBloomFilter()`

SPV: Send our Bloom filter to all connected peers (filterload).

```zig
pub fn sendBloomFilter(self: *P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

*Defined at line 832*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

*Defined at line 848*

---

### `connectToPeer()`

Conecteaza la un peer (TCP outbound)

```zig
pub fn connectToPeer(self: *P2PNode, host: []const u8, port: u16, node_id: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `node_id` | `[]const u8` | Node_id |

**Returns:** `!void`

*Defined at line 854*

---

### `broadcastTx()`

Broadcast a TX to all connected peers via gossip.
Deduplicates: if we already saw this TX hash, skip.
tx_hash: hex hash of the transaction (64 chars)
tx_json: JSON-encoded transaction payload

```zig
pub fn broadcastTx(self: *P2PNode, tx_hash: []const u8, tx_json: []const u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `tx_hash` | `[]const u8` | Tx_hash |
| `tx_json` | `[]const u8` | Tx_json |

*Defined at line 945*

---

### `gossipMaintenance()`

Periodic maintenance: evict expired seen hashes

```zig
pub fn gossipMaintenance(self: *P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

*Defined at line 1050*

---

### `getGossipStats()`

Returns gossip statistics for logging

```zig
pub fn getGossipStats(self: *const P2PNode) struct { tx_relayed: u64, blocks_relayed: u64, seen_tx: usize, seen_blocks: usize } {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNode` | The instance |

**Returns:** `struct`

*Defined at line 1056*

---

### `sendGetPeers()`

Send a get_peers request to a specific peer

```zig
pub fn sendGetPeers(_: *P2PNode, peer: *PeerConnection) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `_` | `*P2PNode` | _ |
| `peer` | `*PeerConnection` | Peer |

*Defined at line 1068*

---

### `requestPeersFromAll()`

Send get_peers to all connected peers

```zig
pub fn requestPeersFromAll(self: *P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

*Defined at line 1076*

---

### `buildPeerListPayload()`

Build a peer_list payload from our known connected peers
Returns encoded bytes; caller must free with allocator.

```zig
pub fn buildPeerListPayload(self: *P2PNode) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

**Returns:** `![]u8`

*Defined at line 1085*

---

### `attachToNetwork()`

Ataseaza acest P2PNode la un P2PNetwork — de apelat din main.zig dupa init

```zig
pub fn attachToNetwork(self: *P2PNode, net: *network_mod.P2PNetwork) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `net` | `*network_mod.P2PNetwork` | Net |

*Defined at line 1112*

---

### `peerCount()`

Numarul de peeri conectati

```zig
pub fn peerCount(self: *const P2PNode) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNode` | The instance |

**Returns:** `usize`

*Defined at line 1117*

---

### `cleanDeadPeers()`

Deconecteaza peerii morti — adauga la reconnect queue in loc de stergere directa

```zig
pub fn cleanDeadPeers(self: *P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

*Defined at line 1126*

---

### `knockKnock()`

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

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

**Returns:** `KnockResult`

*Defined at line 1158*

---

### `isBanned()`

Check if a host:port is currently banned

```zig
pub fn isBanned(self: *const P2PNode, host: []const u8, port: u16) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNode` | The instance |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |

**Returns:** `bool`

*Defined at line 1227*

---

### `banPeer()`

Ban a peer by host:port for the configured duration

```zig
pub fn banPeer(self: *P2PNode, host: []const u8, port: u16, reason: []const u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `host` | `[]const u8` | Host |
| `port` | `u16` | Port |
| `reason` | `[]const u8` | Reason |

*Defined at line 1238*

---

### `evictExpiredBans()`

Evict expired bans

```zig
pub fn evictExpiredBans(self: *P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

*Defined at line 1287*

---

### `scorePeer()`

Score a peer event and auto-ban if threshold reached

```zig
pub fn scorePeer(self: *P2PNode, peer: *PeerConnection, event: scoring_mod.ScoreEvent) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `peer` | `*PeerConnection` | Peer |
| `event` | `scoring_mod.ScoreEvent` | Event |

*Defined at line 1297*

---

### `checkRateLimit()`

Check rate limit for a peer. Returns true if within limits.
If exceeded, adds ban score and returns false.

```zig
pub fn checkRateLimit(self: *P2PNode, peer: *PeerConnection, msg_size: usize) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `peer` | `*PeerConnection` | Peer |
| `msg_size` | `usize` | Msg_size |

**Returns:** `bool`

*Defined at line 1317*

---

### `processReconnects()`

Process reconnect queue — attempt reconnects for peers past the delay

```zig
pub fn processReconnects(self: *P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

*Defined at line 1376*

---

### `checkSubnetDiversity()`

Check if adding a peer with this IP would violate subnet diversity rules.
Returns true if the peer is allowed, false if too many from same /16 subnet.

```zig
pub fn checkSubnetDiversity(self: *const P2PNode, ip: [4]u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNode` | The instance |
| `ip` | `[4]u8` | Ip |

**Returns:** `bool`

*Defined at line 1412*

---

### `subnetCount()`

Count the number of distinct /16 subnets among connected peers

```zig
pub fn subnetCount(self: *const P2PNode) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNode` | The instance |

**Returns:** `usize`

*Defined at line 1424*

---

### `hasMinSubnetDiversity()`

Check if we have enough subnet diversity (at least MIN_SUBNET_DIVERSITY)

```zig
pub fn hasMinSubnetDiversity(self: *const P2PNode) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNode` | The instance |

**Returns:** `bool`

*Defined at line 1447*

---

### `canAcceptInbound()`

Check if we can accept an inbound connection

```zig
pub fn canAcceptInbound(self: *const P2PNode) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNode` | The instance |

**Returns:** `bool`

*Defined at line 1456*

---

### `hardeningMaintenance()`

Periodic hardening maintenance

```zig
pub fn hardeningMaintenance(self: *P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

*Defined at line 1461*

---

### `printStatus()`

Performs the print status operation on the p2p module.

```zig
pub fn printStatus(self: *const P2PNode) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const P2PNode` | The instance |

*Defined at line 1467*

---

### `startListener()`

Porneste server TCP inbound pe `local_port` — thread detached.
Fiecare peer inbound primeste propriul thread handler.
Returneaza error daca bind/listen esueaza (port ocupat, permisiuni etc.)

```zig
pub fn startListener(self: *P2PNode) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |

**Returns:** `!void`

*Defined at line 1482*

---

### `sendToPeer()`

Trimite un mesaj raw la un peer specific (dupa node_id)
Folosit de SyncManager pentru GetHeaders etc.

```zig
pub fn sendToPeer(self: *P2PNode, node_id: []const u8, msg_type: u8, payload: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `node_id` | `[]const u8` | Node_id |
| `msg_type` | `u8` | Msg_type |
| `payload` | `[]const u8` | Payload |

**Returns:** `!void`

*Defined at line 1966*

---

### `requestSync()`

Trimite sync_request la primul peer conectat mai sus decat noi
Payload: [from_height: u64 LE]

```zig
pub fn requestSync(self: *P2PNode, from_height: u64) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*P2PNode` | The instance |
| `from_height` | `u64` | From_height |

*Defined at line 1978*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
