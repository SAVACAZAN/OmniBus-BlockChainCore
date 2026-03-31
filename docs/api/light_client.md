# Module: `light_client`

> SPV (Simplified Payment Verification) — header-only sync, Bloom filters, Merkle proofs for TX inclusion, mobile-friendly (200B per header).

**Source:** `core/light_client.zig` | **Lines:** 979 | **Functions:** 36 | **Structs:** 6 | **Tests:** 27

---

## Contents

### Structs
- [`BlockHeader`](#blockheader) — Minimal block header for light client (only ~200 bytes vs 35KB full block)
- [`MerkleProof`](#merkleproof) — Merkle inclusion proof for a single transaction.
Allows a light client to verify...
- [`BloomFilter`](#bloomfilter) — Bloom filter for SPV transaction filtering.
Light clients send a Bloom filter to...
- [`LightClient`](#lightclient) — Light Client - minimal blockchain for low-resource devices.
Downloads only block...
- [`SPVProof`](#spvproof) — SPV (Simplified Payment Verification) proof for light clients (legacy compat)
- [`SyncTracker`](#synctracker) — Data structure representing a sync tracker in the light_client module.

### Functions
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`serialize()`](#serialize) — Serialize header to binary (lightweight)
- [`deserialize()`](#deserialize) — Deserialize header from binary
- [`print()`](#print) — Performs the print operation on the light_client module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addStep()`](#addstep) — Add a sibling hash to the proof path
- [`verifyMerkleProof()`](#verifymerkleproof) — Verify a merkle proof: hash the TX with siblings up to root.
Returns t...
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`add()`](#add) — Insert data (address, txid, pubkey) into the filter
- [`contains()`](#contains) — Check if data might be in the filter. May return false positives, neve...
- [`clear()`](#clear) — Clear the filter (reset all bits)
- [`estimateFalsePositivePct()`](#estimatefalsepositivepct) — Estimate false positive rate given number of elements inserted.
Formul...
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`addHeader()`](#addheader) — Add block header to chain after validation
- [`validateHeader()`](#validateheader) — Validate a header before adding it:
1. previous_hash must match the ha...
- [`addValidatedHeader()`](#addvalidatedheader) — Validate and add a header. Returns error if validation fails.
- [`verifyChain()`](#verifychain) — Verify header chain (check previous_hash links)
- [`getHeight()`](#getheight) — Get current header chain height
- [`getHeader()`](#getheader) — Get header by block height
- [`getLatestHeader()`](#getlatestheader) — Get latest header
- [`getHeaderCount()`](#getheadercount) — Get header count
- [`verifyTransaction()`](#verifytransaction) — Verify a TX is in a block using a Merkle proof and our header chain
- [`watchAddress()`](#watchaddress) — Add an address to the Bloom filter (for TX matching)
- [`matchesFilter()`](#matchesfilter) — Check if a TX matches any watched address
- [`getConfirmations()`](#getconfirmations) — Get number of confirmations for a proven TX
- [`estimateStorageSize()`](#estimatestoragesize) — Estimate storage used (headers only)
- [`fastSyncFromCheckpoint()`](#fastsyncfromcheckpoint) — Fast sync from trusted checkpoint
- [`getDifficulty()`](#getdifficulty) — Get proof-of-work difficulty at height
- [`serializeToFile()`](#serializetofile) — Serialize headers to file format
- [`deserializeFromFile()`](#deserializefromfile) — Deserialize headers from file format
- [`syncHeaders()`](#syncheaders) — Trigger SPV header sync via P2P.
Accepts an opaque pointer to P2PNode ...
- [`printStats()`](#printstats) — Statistics about light client
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`verifyProof()`](#verifyproof) — Verify SPV proof against block header
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.

---

## Structs

### `BlockHeader`

Minimal block header for light client (only ~200 bytes vs 35KB full block)

| Field | Type | Description |
|-------|------|-------------|
| `index` | `u32` | Index |
| `timestamp` | `i64` | Timestamp |
| `previous_hash` | `[32]u8` | Previous_hash |
| `merkle_root` | `[32]u8` | Merkle_root |
| `nonce` | `u64` | Nonce |
| `hash` | `[32]u8` | Hash |
| `difficulty` | `u32` | Difficulty |
| `transaction_count` | `u32` | Transaction_count |
| `sub_blocks` | `u8` | Sub_blocks |

*Defined at line 6*

---

### `MerkleProof`

Merkle inclusion proof for a single transaction.
Allows a light client to verify that a TX is included in a block
using only the block header's merkle_root, without the full block.

| Field | Type | Description |
|-------|------|-------------|
| `tx_hash` | `[32]u8` | Tx_hash |
| `proof_hashes` | `[MAX_MERKLE_DEPTH][32]u8` | Proof_hashes |
| `directions` | `[MAX_MERKLE_DEPTH]bool` | Directions |
| `depth` | `u8` | Depth |
| `merkle_root` | `[32]u8` | Merkle_root |
| `block_index` | `u32` | Block_index |
| `tx_index` | `u32` | Tx_index |

*Defined at line 133*

---

### `BloomFilter`

Bloom filter for SPV transaction filtering.
Light clients send a Bloom filter to full nodes describing which addresses
they are interested in. The full node only relays matching TXs.
Uses multiple hash functions (murmur-style rotation) for low false-positive rate.

| Field | Type | Description |
|-------|------|-------------|
| `bits` | `[512]u8` | Bits |
| `num_hash_funcs` | `u8` | Num_hash_funcs |

*Defined at line 201*

---

### `LightClient`

Light Client - minimal blockchain for low-resource devices.
Downloads only block headers (~200 bytes each vs ~35KB full blocks).
Verifies TX inclusion via Merkle proofs (SPV).
Uses Bloom filters to request only relevant TXs from full nodes.

| Field | Type | Description |
|-------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `headers` | `std.array_list.Managed(BlockHeader)` | Headers |
| `trusted_root` | `[32]u8` | Trusted_root |
| `sync_height` | `u32` | Sync_height |
| `max_headers_to_keep` | `u32` | Max_headers_to_keep |
| `bloom` | `BloomFilter` | Bloom |

*Defined at line 283*

---

### `SPVProof`

SPV (Simplified Payment Verification) proof for light clients (legacy compat)

| Field | Type | Description |
|-------|------|-------------|
| `tx_hash` | `[32]u8` | Tx_hash |
| `merkle_proof` | `std.array_list.Managed([32]u8)` | Merkle_proof |
| `block_header` | `BlockHeader` | Block_header |
| `position_in_block` | `u32` | Position_in_block |

*Defined at line 537*

---

### `SyncTracker`

Data structure representing a sync tracker in the light_client module.

*Defined at line 966*

---

## Functions

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(index: u32) BlockHeader {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `index` | `u32` | Index |

**Returns:** `BlockHeader`

*Defined at line 17*

---

### `serialize()`

Serialize header to binary (lightweight)

```zig
pub fn serialize(self: *const BlockHeader) [200]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockHeader` | The instance |

**Returns:** `[200]u8`

*Defined at line 32*

---

### `deserialize()`

Deserialize header from binary

```zig
pub fn deserialize(data: [200]u8) BlockHeader {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `data` | `[200]u8` | Data |

**Returns:** `BlockHeader`

*Defined at line 75*

---

### `print()`

Performs the print operation on the light_client module.

```zig
pub fn print(self: *const BlockHeader) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BlockHeader` | The instance |

*Defined at line 117*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(tx_hash: [32]u8, root: [32]u8, block_idx: u32, tx_idx: u32) MerkleProof {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `tx_hash` | `[32]u8` | Tx_hash |
| `root` | `[32]u8` | Root |
| `block_idx` | `u32` | Block_idx |
| `tx_idx` | `u32` | Tx_idx |

**Returns:** `MerkleProof`

*Defined at line 142*

---

### `addStep()`

Add a sibling hash to the proof path

```zig
pub fn addStep(self: *MerkleProof, sibling: [32]u8, is_right: bool) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*MerkleProof` | The instance |
| `sibling` | `[32]u8` | Sibling |
| `is_right` | `bool` | Is_right |

*Defined at line 155*

---

### `verifyMerkleProof()`

Verify a merkle proof: hash the TX with siblings up to root.
Returns true if the computed root matches the expected merkle_root.
This is the core of SPV — proves TX inclusion without full block data.
Special case: depth=0 means single-TX block where tx_hash IS the merkle root.

```zig
pub fn verifyMerkleProof(proof: *const MerkleProof) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `proof` | `*const MerkleProof` | Proof |

**Returns:** `bool`

*Defined at line 168*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(num_funcs: u8) BloomFilter {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `num_funcs` | `u8` | Num_funcs |

**Returns:** `BloomFilter`

*Defined at line 205*

---

### `add()`

Insert data (address, txid, pubkey) into the filter

```zig
pub fn add(self: *BloomFilter, data: []const u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BloomFilter` | The instance |
| `data` | `[]const u8` | Data |

*Defined at line 213*

---

### `contains()`

Check if data might be in the filter. May return false positives, never false negatives.

```zig
pub fn contains(self: *const BloomFilter, data: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BloomFilter` | The instance |
| `data` | `[]const u8` | Data |

**Returns:** `bool`

*Defined at line 224*

---

### `clear()`

Clear the filter (reset all bits)

```zig
pub fn clear(self: *BloomFilter) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*BloomFilter` | The instance |

*Defined at line 238*

---

### `estimateFalsePositivePct()`

Estimate false positive rate given number of elements inserted.
Formula: (1 - e^(-kn/m))^k where k=hash_funcs, n=elements, m=bits
Returns a rough integer percentage (0-100).

```zig
pub fn estimateFalsePositivePct(self: *const BloomFilter, num_elements: u32) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const BloomFilter` | The instance |
| `num_elements` | `u32` | Num_elements |

**Returns:** `u32`

*Defined at line 245*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) LightClient {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `LightClient`

*Defined at line 291*

---

### `addHeader()`

Add block header to chain after validation

```zig
pub fn addHeader(self: *LightClient, header: BlockHeader) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightClient` | The instance |
| `header` | `BlockHeader` | Header |

**Returns:** `!void`

*Defined at line 301*

---

### `validateHeader()`

Validate a header before adding it:
1. previous_hash must match the hash of the last known header
2. index must be sequential
3. timestamp must not be in the future (with 2h tolerance, like Bitcoin)
4. difficulty must be > 0

```zig
pub fn validateHeader(self: *const LightClient, header: *const BlockHeader) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |
| `header` | `*const BlockHeader` | Header |

**Returns:** `bool`

*Defined at line 319*

---

### `addValidatedHeader()`

Validate and add a header. Returns error if validation fails.

```zig
pub fn addValidatedHeader(self: *LightClient, header: BlockHeader) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightClient` | The instance |
| `header` | `BlockHeader` | Header |

**Returns:** `!void`

*Defined at line 348*

---

### `verifyChain()`

Verify header chain (check previous_hash links)

```zig
pub fn verifyChain(self: *const LightClient) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |

**Returns:** `bool`

*Defined at line 356*

---

### `getHeight()`

Get current header chain height

```zig
pub fn getHeight(self: *const LightClient) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |

**Returns:** `u32`

*Defined at line 378*

---

### `getHeader()`

Get header by block height

```zig
pub fn getHeader(self: *const LightClient, height: u32) ?*const BlockHeader {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |
| `height` | `u32` | Height |

**Returns:** `?*const BlockHeader`

*Defined at line 384*

---

### `getLatestHeader()`

Get latest header

```zig
pub fn getLatestHeader(self: *const LightClient) ?*const BlockHeader {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |

**Returns:** `?*const BlockHeader`

*Defined at line 394*

---

### `getHeaderCount()`

Get header count

```zig
pub fn getHeaderCount(self: *const LightClient) usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |

**Returns:** `usize`

*Defined at line 400*

---

### `verifyTransaction()`

Verify a TX is in a block using a Merkle proof and our header chain

```zig
pub fn verifyTransaction(self: *const LightClient, proof: *const MerkleProof) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |
| `proof` | `*const MerkleProof` | Proof |

**Returns:** `bool`

*Defined at line 405*

---

### `watchAddress()`

Add an address to the Bloom filter (for TX matching)

```zig
pub fn watchAddress(self: *LightClient, address: []const u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightClient` | The instance |
| `address` | `[]const u8` | Address |

*Defined at line 417*

---

### `matchesFilter()`

Check if a TX matches any watched address

```zig
pub fn matchesFilter(self: *const LightClient, address: []const u8) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `bool`

*Defined at line 422*

---

### `getConfirmations()`

Get number of confirmations for a proven TX

```zig
pub fn getConfirmations(self: *const LightClient, proof: *const MerkleProof) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |
| `proof` | `*const MerkleProof` | Proof |

**Returns:** `u32`

*Defined at line 427*

---

### `estimateStorageSize()`

Estimate storage used (headers only)

```zig
pub fn estimateStorageSize(self: *const LightClient) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |

**Returns:** `u64`

*Defined at line 434*

---

### `fastSyncFromCheckpoint()`

Fast sync from trusted checkpoint

```zig
pub fn fastSyncFromCheckpoint(self: *LightClient, trusted_header: BlockHeader, new_headers: []const BlockHeader) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightClient` | The instance |
| `trusted_header` | `BlockHeader` | Trusted_header |
| `new_headers` | `[]const BlockHeader` | New_headers |

**Returns:** `!void`

*Defined at line 440*

---

### `getDifficulty()`

Get proof-of-work difficulty at height

```zig
pub fn getDifficulty(self: *const LightClient, height: u32) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |
| `height` | `u32` | Height |

**Returns:** `u32`

*Defined at line 456*

---

### `serializeToFile()`

Serialize headers to file format

```zig
pub fn serializeToFile(self: *const LightClient, allocator: std.mem.Allocator) ![]u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `![]u8`

*Defined at line 464*

---

### `deserializeFromFile()`

Deserialize headers from file format

```zig
pub fn deserializeFromFile(self: *LightClient, data: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightClient` | The instance |
| `data` | `[]const u8` | Data |

**Returns:** `!void`

*Defined at line 480*

---

### `syncHeaders()`

Trigger SPV header sync via P2P.
Accepts an opaque pointer to P2PNode and a function pointer that calls
P2PNode.syncHeaders(). This avoids circular imports (light_client cannot
import p2p.zig directly).

```zig
pub fn syncHeaders(self: *LightClient, p2p_ptr: *anyopaque, sync_fn: *const fn (*anyopaque) void) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightClient` | The instance |
| `p2p_ptr` | `*anyopaque` | P2p_ptr |
| `sync_fn` | `*const fn (*anyopaque` | Sync_fn |

**Returns:** `void) void`

*Defined at line 506*

---

### `printStats()`

Statistics about light client

```zig
pub fn printStats(self: *const LightClient) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const LightClient` | The instance |

*Defined at line 512*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *LightClient) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*LightClient` | The instance |

*Defined at line 531*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator, tx_hash: [32]u8, header: BlockHeader) SPVProof {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |
| `tx_hash` | `[32]u8` | Tx_hash |
| `header` | `BlockHeader` | Header |

**Returns:** `SPVProof`

*Defined at line 543*

---

### `verifyProof()`

Verify SPV proof against block header

```zig
pub fn verifyProof(self: *const SPVProof) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const SPVProof` | The instance |

**Returns:** `bool`

*Defined at line 553*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *SPVProof) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*SPVProof` | The instance |

*Defined at line 559*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 02:16*
