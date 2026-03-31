# Module: `blockchain`

> Core blockchain engine — manages the chain, validates blocks, handles reorgs, tracks balances per address, and implements difficulty retargeting (Bitcoin-style, every 2016 blocks).

**Source:** `core/blockchain.zig` | **Lines:** 2128 | **Functions:** 33 | **Structs:** 2 | **Tests:** 72

---

## Contents

### Structs
- [`MultisigConfigEntry`](#multisigconfigentry) — Entry for storing a multisig config alongside its address string.
- [`Blockchain`](#blockchain) — The main blockchain state — manages the chain of blocks, validates additions, tr...

### Constants
- [16 constants defined](#constants)

### Functions
- [`retargetDifficulty()`](#retargetdifficulty) — Calculeaza noua dificultate dupa un interval de retarget.
Formula: new...
- [`blockRewardAt()`](#blockrewardat) — Performs the block reward at operation on the blockchain module.
- [`init()`](#init) — Initialize a new instance. Allocates required memory and sets default ...
- [`deinit()`](#deinit) — Clean up and free all allocated memory. Must be called when done.
- [`getAddressBalance()`](#getaddressbalance) — Returneaza balanta unei adrese (0 daca nu exista)
- [`getConfirmations()`](#getconfirmations) — Returns the number of confirmations for a TX (null if TX not found in ...
- [`getTxBlockHeight()`](#gettxblockheight) — Returns the block height that contains a given TX (null if not found)
- [`indexAddressTx()`](#indexaddresstx) — Index a TX hash for a given address in address_tx_index.
Creates the l...
- [`getAddressHistory()`](#getaddresshistory) — Returns the list of TX hashes associated with an address (both sent an...
- [`creditBalance()`](#creditbalance) — Adauga reward la balanta minerului
- [`debitBalance()`](#debitbalance) — Scade din balanta (pentru tranzactii)
- [`registerPubkey()`](#registerpubkey) — Inregistreaza public key-ul unei adrese (pentru verificare semnatura T...
- [`registerMultisig()`](#registermultisig) — Register a multisig wallet configuration (address → M-of-N config).
Ca...
- [`getMultisigConfig()`](#getmultisigconfig) — Look up a multisig config by address.
- [`addTransaction()`](#addtransaction) — Adds a new transaction to the collection.
- [`getPendingOutgoing()`](#getpendingoutgoing) — Returneaza totalul outgoing pending din mempool pentru o adresa (amoun...
- [`getNextNonce()`](#getnextnonce) — Returneaza urmatorul nonce confirmat pentru o adresa (0 daca nu exista...
- [`getNextAvailableNonce()`](#getnextavailablenonce) — Returneaza urmatorul nonce disponibil pentru o adresa,
incluzand TX-ur...
- [`validateTransaction()`](#validatetransaction) — Validates the transaction. Returns true if valid, false otherwise.
- [`mineBlock()`](#mineblock) — Executes mining operation — finds valid nonce for the next block.
- [`mineBlockForMiner()`](#mineblockforminer) — Mine block + acorda reward minerului + proceseaza TX-urile din mempool
- [`calculateBlockHash()`](#calculateblockhash) — Calculate block hash as 64-char hex string (shared implementation in h...
- [`isValidHash()`](#isvalidhash) — Check if hash meets difficulty (delegates to shared hex_utils)
- [`validateBlock()`](#validateblock) — Validate a block against all consensus rules (Bitcoin-level validation...
- [`addExternalBlock()`](#addexternalblock) — Accept a block from a P2P peer. Fully validates before appending.
Hand...
- [`reorg()`](#reorg) — Accept a full chain from a peer and reorg if it's longer.
Validates al...
- [`checkAutoSave()`](#checkautosave) — Check if auto-save should trigger based on block count or time elapsed...
- [`saveToDisc()`](#savetodisc) — Convenience method: save full blockchain state to disc via PersistentB...
- [`findForkPoint()`](#findforkpoint) — Find the highest block index where both chains have the same hash.
Ret...
- [`processOrphans()`](#processorphans) — Process orphan blocks: check if any now connect to our chain tip.
Keep...
- [`getBlock()`](#getblock) — Returns the block for the given index.
- [`getLatestBlock()`](#getlatestblock) — Returns the current latest block.
- [`getBlockCount()`](#getblockcount) — Returns the current block count.

---

## Structs

### `MultisigConfigEntry`

Entry for storing a multisig config alongside its address string.

*Defined at line 87*

---

### `Blockchain`

The main blockchain state — manages the chain of blocks, validates additions, tracks balances, and handles reorganizations.

| Field | Type | Description |
|-------|------|-------------|
| `chain` | `array_list.Managed(Block)` | Chain |
| `mempool` | `array_list.Managed(Transaction)` | Mempool |
| `difficulty` | `u32` | Difficulty |
| `allocator` | `std.mem.Allocator` | Allocator |
| `balances` | `std.StringHashMap(u64)` | Balances |
| `nonces` | `std.StringHashMap(u64)` | Nonces |
| `tx_block_height` | `std.StringHashMap(u64)` | Tx_block_height |
| `orphan_blocks` | `array_list.Managed(Block)` | Orphan_blocks |
| `address_tx_index` | `std.StringHashMap(std.ArrayList([]const u8))` | Address_tx_index |

*Defined at line 98*

---

## Constants

| Name | Value | Description |
|------|-------|-------------|
| `Block` | `block_mod.Block` | Block |
| `Transaction` | `transaction_mod.Transaction` | Transaction |
| `BLOCK_REWARD_SAT` | `u64 = 8_333_333` | B l o c k_ r e w a r d_ s a t |
| `HALVING_INTERVAL` | `u64 = 126_144_000` | H a l v i n g_ i n t e r v a l |
| `MAX_SUPPLY_SAT` | `u64 = 21_000_000_000_000_000` | M a x_ s u p p l y_ s a t |
| `COINBASE_MATURITY` | `u32 = 100` | C o i n b a s e_ m a t u r i t y |
| `DUST_THRESHOLD_SAT` | `u64 = 100` | D u s t_ t h r e s h o l d_ s a t |
| `MAX_REORG_DEPTH` | `usize = 100` | M a x_ r e o r g_ d e p t h |
| `MAX_ORPHAN_POOL` | `usize = 64` | M a x_ o r p h a n_ p o o l |
| `RETARGET_INTERVAL` | `u64 = 2016` | R e t a r g e t_ i n t e r v a l |
| `TARGET_BLOCK_TIME_S` | `i64 = 1` | T a r g e t_ b l o c k_ t i m e_ s |
| `TARGET_INTERVAL_S` | `i64 = @intCast(RETARGET_INTERVAL)` | T a r g e t_ i n t e r v a l_ s |
| `MIN_DIFFICULTY` | `u32 = 1` | M i n_ d i f f i c u l t y |
| `MAX_DIFFICULTY` | `u32 = 256` | M a x_ d i f f i c u l t y |
| `FEE_BURN_PCT` | `u64 = 50` | F e e_ b u r n_ p c t |
| `TX_MIN_FEE` | `u64 = 1` | T x_ m i n_ f e e |

---

## Functions

### `retargetDifficulty()`

Calculeaza noua dificultate dupa un interval de retarget.
Formula: new_difficulty = old_difficulty * TARGET_INTERVAL / actual_time
Clamped la ±4x fata de dificultatea anterioara (ca Bitcoin) si [MIN, MAX].

```zig
pub fn retargetDifficulty(old_difficulty: u32, actual_time_s: i64) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `old_difficulty` | `u32` | Old_difficulty |
| `actual_time_s` | `i64` | Actual_time_s |

**Returns:** `u32`

*Defined at line 64*

---

### `blockRewardAt()`

Performs the block reward at operation on the blockchain module.

```zig
pub fn blockRewardAt(height: u64) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `height` | `u64` | Height |

**Returns:** `u64`

*Defined at line 80*

---

### `init()`

Initialize a new instance. Allocates required memory and sets default values.

```zig
pub fn init(allocator: std.mem.Allocator) !Blockchain {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `allocator` | `std.mem.Allocator` | Allocator |

**Returns:** `!Blockchain`

*Defined at line 138*

---

### `deinit()`

Clean up and free all allocated memory. Must be called when done.

```zig
pub fn deinit(self: *Blockchain) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |

*Defined at line 168*

---

### `getAddressBalance()`

Returneaza balanta unei adrese (0 daca nu exista)

```zig
pub fn getAddressBalance(self: *const Blockchain, address: []const u8) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Blockchain` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `u64`

*Defined at line 209*

---

### `getConfirmations()`

Returns the number of confirmations for a TX (null if TX not found in any block).
confirmations = current_chain_height - block_height_containing_tx

```zig
pub fn getConfirmations(self: *const Blockchain, tx_hash: []const u8) ?u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Blockchain` | The instance |
| `tx_hash` | `[]const u8` | Tx_hash |

**Returns:** `?u64`

*Defined at line 215*

---

### `getTxBlockHeight()`

Returns the block height that contains a given TX (null if not found)

```zig
pub fn getTxBlockHeight(self: *const Blockchain, tx_hash: []const u8) ?u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Blockchain` | The instance |
| `tx_hash` | `[]const u8` | Tx_hash |

**Returns:** `?u64`

*Defined at line 223*

---

### `indexAddressTx()`

Index a TX hash for a given address in address_tx_index.
Creates the list if address not yet tracked.

```zig
pub fn indexAddressTx(self: *Blockchain, address: []const u8, tx_hash: []const u8) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `address` | `[]const u8` | Address |
| `tx_hash` | `[]const u8` | Tx_hash |

*Defined at line 229*

---

### `getAddressHistory()`

Returns the list of TX hashes associated with an address (both sent and received).
Returns null if address has no history.

```zig
pub fn getAddressHistory(self: *const Blockchain, address: []const u8) ?[]const []const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Blockchain` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `?[]const []const u8`

*Defined at line 243*

---

### `creditBalance()`

Adauga reward la balanta minerului

```zig
pub fn creditBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `address` | `[]const u8` | Address |
| `amount` | `u64` | Amount |

**Returns:** `!void`

*Defined at line 250*

---

### `debitBalance()`

Scade din balanta (pentru tranzactii)

```zig
pub fn debitBalance(self: *Blockchain, address: []const u8, amount: u64) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `address` | `[]const u8` | Address |
| `amount` | `u64` | Amount |

**Returns:** `!void`

*Defined at line 256*

---

### `registerPubkey()`

Inregistreaza public key-ul unei adrese (pentru verificare semnatura TX)
pubkey_hex = compressed secp256k1 public key, 66 hex chars

```zig
pub fn registerPubkey(self: *Blockchain, address: []const u8, pubkey_hex: []const u8) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `address` | `[]const u8` | Address |
| `pubkey_hex` | `[]const u8` | Pubkey_hex |

**Returns:** `!void`

*Defined at line 264*

---

### `registerMultisig()`

Register a multisig wallet configuration (address → M-of-N config).
Called by the "createmultisig" RPC handler.

```zig
pub fn registerMultisig(self: *Blockchain, address: []const u8, config: multisig_mod.MultisigConfig) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `address` | `[]const u8` | Address |
| `config` | `multisig_mod.MultisigConfig` | Config |

**Returns:** `!void`

*Defined at line 276*

---

### `getMultisigConfig()`

Look up a multisig config by address.

```zig
pub fn getMultisigConfig(self: *const Blockchain, address: []const u8) ?*const multisig_mod.MultisigConfig {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Blockchain` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `?*const multisig_mod.MultisigConfig`

*Defined at line 294*

---

### `addTransaction()`

Adds a new transaction to the collection.

```zig
pub fn addTransaction(self: *Blockchain, tx: Transaction) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `tx` | `Transaction` | Tx |

**Returns:** `!void`

*Defined at line 303*

---

### `getPendingOutgoing()`

Returneaza totalul outgoing pending din mempool pentru o adresa (amount + fee per TX)
Folosit in validateTransaction() pentru a preveni double-spend cu TX-uri rapide

```zig
pub fn getPendingOutgoing(self: *const Blockchain, address: []const u8) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Blockchain` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `u64`

*Defined at line 314*

---

### `getNextNonce()`

Returneaza urmatorul nonce confirmat pentru o adresa (0 daca nu exista)
Acesta este nonce-ul pe chain — NU include TX-urile pending din mempool

```zig
pub fn getNextNonce(self: *const Blockchain, address: []const u8) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Blockchain` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `u64`

*Defined at line 326*

---

### `getNextAvailableNonce()`

Returneaza urmatorul nonce disponibil pentru o adresa,
incluzand TX-urile pending din mempool (chain_nonce + pending_count).
Aceasta metoda este utila pentru RPC "getnonce" — clientul stie ce nonce sa puna pe urmatoarea TX.

```zig
pub fn getNextAvailableNonce(self: *const Blockchain, address: []const u8) u64 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Blockchain` | The instance |
| `address` | `[]const u8` | Address |

**Returns:** `u64`

*Defined at line 333*

---

### `validateTransaction()`

Validates the transaction. Returns true if valid, false otherwise.

```zig
pub fn validateTransaction(self: *Blockchain, tx: *const Transaction) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `tx` | `*const Transaction` | Tx |

**Returns:** `!bool`

*Defined at line 345*

---

### `mineBlock()`

Executes mining operation — finds valid nonce for the next block.

```zig
pub fn mineBlock(self: *Blockchain) !Block {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |

**Returns:** `!Block`

*Defined at line 445*

---

### `mineBlockForMiner()`

Mine block + acorda reward minerului + proceseaza TX-urile din mempool

```zig
pub fn mineBlockForMiner(self: *Blockchain, miner_address: []const u8) !Block {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `miner_address` | `[]const u8` | Miner_address |

**Returns:** `!Block`

*Defined at line 450*

---

### `calculateBlockHash()`

Calculate block hash as 64-char hex string (shared implementation in hex_utils)

```zig
pub fn calculateBlockHash(self: *Blockchain, block: *const Block) ![]const u8 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `block` | `*const Block` | Block |

**Returns:** `![]const u8`

*Defined at line 553*

---

### `isValidHash()`

Check if hash meets difficulty (delegates to shared hex_utils)

```zig
pub fn isValidHash(self: *Blockchain, hash: []const u8) !bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `hash` | `[]const u8` | Hash |

**Returns:** `!bool`

*Defined at line 558*

---

### `validateBlock()`

Validate a block against all consensus rules (Bitcoin-level validation).
Returns true if the block passes all checks, false otherwise.
Checks: merkle root, timestamp, previous hash, difficulty, fees/reward, TX validity.

```zig
pub fn validateBlock(self: *Blockchain, block: *const Block) bool {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `block` | `*const Block` | Block |

**Returns:** `bool`

*Defined at line 568*

---

### `addExternalBlock()`

Accept a block from a P2P peer. Fully validates before appending.
Handles three cases:
1. Block extends our chain tip -> append normally
2. Block forks from our chain and creates a longer chain -> reorg
3. Block's parent is unknown -> store in orphan pool
After appending, checks if any orphan blocks now connect.

```zig
pub fn addExternalBlock(self: *Blockchain, block: Block) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `block` | `Block` | Block |

**Returns:** `!void`

*Defined at line 643*

---

### `reorg()`

Accept a full chain from a peer and reorg if it's longer.
Validates all blocks in the new chain from the fork point.
Returns orphaned TXs to mempool for re-mining.

```zig
pub fn reorg(self: *Blockchain, new_chain: []const Block) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `new_chain` | `[]const Block` | New_chain |

**Returns:** `!void`

*Defined at line 717*

---

### `checkAutoSave()`

Check if auto-save should trigger based on block count or time elapsed.
Called after each mined block. Saves at 100 blocks, 60s, or 1000 TXs.

```zig
pub fn checkAutoSave(self: *Blockchain) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |

*Defined at line 800*

---

### `saveToDisc()`

Convenience method: save full blockchain state to disc via PersistentBlockchain.
No-op if persistent_db has not been attached (e.g. in unit tests).

```zig
pub fn saveToDisc(self: *Blockchain) !void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |

**Returns:** `!void`

*Defined at line 818*

---

### `findForkPoint()`

Find the highest block index where both chains have the same hash.
Returns null if no common ancestor found (completely divergent chains).

```zig
pub fn findForkPoint(self: *const Blockchain, other_chain: []const Block) ?usize {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*const Blockchain` | The instance |
| `other_chain` | `[]const Block` | Other_chain |

**Returns:** `?usize`

*Defined at line 826*

---

### `processOrphans()`

Process orphan blocks: check if any now connect to our chain tip.
Keeps trying until no more orphans connect (cascading resolution).

```zig
pub fn processOrphans(self: *Blockchain) void {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |

*Defined at line 972*

---

### `getBlock()`

Returns the block for the given index.

```zig
pub fn getBlock(self: *Blockchain, index: u32) ?Block {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |
| `index` | `u32` | Index |

**Returns:** `?Block`

*Defined at line 1003*

---

### `getLatestBlock()`

Returns the current latest block.

```zig
pub fn getLatestBlock(self: *Blockchain) Block {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |

**Returns:** `Block`

*Defined at line 1010*

---

### `getBlockCount()`

Returns the current block count.

```zig
pub fn getBlockCount(self: *Blockchain) u32 {
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `self` | `*Blockchain` | The instance |

**Returns:** `u32`

*Defined at line 1014*

---


---

*Generated by OmniBus Doc Generator v2.0 — 2026-03-31 11:17*
