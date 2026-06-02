# Segfault Scan Report — OmniBus BlockChainCore

**Scan date:** 2026-04-25
**Scope:** `core/*.zig` (Zig 0.15.2)
**Trigger investigated:** Segfault at `Thread.zig:509` in `callFn` under stress RPC + active mining
**Reference logs:**
- `test_results/comparison/02_omnibus_scanner/node.log` (lines 76-93)
- `test_results/comparison/02_omnibus_scanner/node2.log` (lines 76-93)

The crash addresses (`0x24decf10080`, `0x24ded280080`, `0x1ed3a330080`, `0x1ed3a350080`) are all aligned at `0x...0080` — looks like dereferencing a struct field at offset 0x80 of an already-freed/corrupted heap chunk. The offset is the same on each crash, which is consistent with a use-after-free on a recurring struct (likely `Block`, `PeerConnection`, or `WsClient`).

---

## Summary

| Severity | Count |
|----------|-------|
| HIGH     | 5     |
| MEDIUM   | 6     |
| LOW      | 2     |
| **Total**| **13**|

13 dangerous sites flagged in 4 files. Categories:
- **Missing mutex on shared collection** (5 sites) — strongest match for the crash
- **By-value return of struct holding heap slices** (1 site) — root primitive
- **Non-atomic read-modify-write counters** (2 sites)
- **Cross-thread destroy-before-lock** (1 site)
- **Cross-thread mutation of scalar shared state** (2 sites)
- **Allocator pressure** (1 site, low)
- **getBlockCount caller contract** (1 site, low)

---

## Most probable cause of `Thread.zig:509` segfault

**Race on `P2PNode.peers: ArrayList(PeerConnection)` between RPC handler thread and P2P accept/clean threads** — secondary suspect: **race on `Blockchain.chain` between mining loop and unlocked RPC `getlatestblock` / `getbestblockhash` handlers**.

Both share the same shape: an `ArrayList` is `append`-ed (or `swapRemove`-ed) on one thread while another thread iterates `.items` and dereferences slice fields of struct elements. When the underlying buffer is reallocated, the reader follows a stale pointer at offset 0x80 → segfault.

The RPC server is the prime suspect because:
1. The crash occurs immediately after `[RPC] HTTP JSON-RPC 2.0 listening on http://0.0.0.0:8332` (log line 75-76).
2. The trigger reported by the user is "100+ sequential RPC calls while mining active" — exactly the contention pattern.
3. `P2PNode` has **zero** mutex protection on `self.peers`. `Blockchain` has a mutex but it is **not** acquired in `getlatestblock`, `getbestblockhash`, `getmempoolstats`, `getnetworkinfo`, `getpoolstats`.

---

## Top 3 priority fixes

### 1. Add `peers_mutex` to `P2PNode` and lock all `self.peers` access  *(HIGHEST priority)*

**File:** `core/p2p.zig`

`P2PNode.peers` is mutated by `connectTo()` (append, line 922), by `cleanDeadPeers()` (swapRemove, line 1158), and read by 25+ call sites including RPC handlers, broadcast loops, gossip maintenance, and per-peer threads. There is currently **no synchronization** at all.

```zig
pub const P2PNode = struct {
    peers: ArrayList(PeerConnection),
    peers_mutex: std.Thread.Mutex = .{},  // ADD
    inbound_count: std.atomic.Value(u32) = .{ .raw = 0 },   // promote
    outbound_count: std.atomic.Value(u32) = .{ .raw = 0 },  // promote
    ...
};
```

Lock around every `peers.append`, `peers.swapRemove`, and every iteration. For long iterations (broadcast), snapshot the list under lock then iterate the snapshot.

### 2. Acquire `bc.mutex` in unlocked RPC handlers  *(HIGH priority)*

**File:** `core/rpc_server.zig`

The following handlers touch `ctx.bc` without locking and run concurrently with the mining loop's `chain.append`:

| Function | Line | Reads |
|----------|------|-------|
| `handleGetLatestBlock` | ~325 | `getLatestBlock()` then `blk.hash`, `blk.transactions.items.len` |
| `handleGetBestBlockHash` | ~1968 | `getLatestBlock()` then `blk.hash` |
| `handlePoolStats` | ~870 | `ctx.bc.mempool.items.len` |
| `handleNetInfo` | ~917 | `p2p.peers.items.len` and `bc.mempool.items.len` |
| `handleMpStats` | ~885 | `ctx.bc.mempool.items.len` |

Pattern: lock → snapshot scalars + dupe strings into local buffer → unlock → format. Never hold `allocator.allocPrint` calls while the mutex is held.

### 3. Make `getLatestBlock` / `getBlock` lock-aware *(HIGH priority — root primitive)*

**File:** `core/blockchain.zig`

`getLatestBlock` returns `Block` by value but `Block` contains `array_list.Managed(Transaction)` (heap pointer) and slice fields (`hash`, `previous_hash`). The returned struct is logically a borrow with no enforced lifetime. Every caller currently can race against mining.

Two acceptable fixes:
- **Option A** (strict): require caller to hold `self.mutex`; add `assert(self.mutex.tryLock() == false)` debug check at top.
- **Option B** (safe-default): return `BlockSnapshot` — a flat POD struct with copied scalars and `[64]u8` hash buffers; do the deep copy inside `getLatestBlock` while holding the lock internally.

Option B is preferred for RPC — handlers can stay concise and any future caller is safe.

---

## Full site list

| # | Severity | File | Line | Category | Description |
|---|----------|------|------|----------|-------------|
| 1 | HIGH | core/blockchain.zig | 1019 | Borrow-without-lock | `getLatestBlock` returns Block by value with live heap slice/pointer fields |
| 2 | HIGH | core/rpc_server.zig | 325 | Missing mutex | `handleGetLatestBlock` accesses blk fields without bc.mutex |
| 3 | HIGH | core/rpc_server.zig | 1973 | Missing mutex | `handleGetBestBlockHash` reads blk.hash without bc.mutex |
| 4 | HIGH | core/rpc_server.zig | 902 | Missing mutex (peers) | `handlePeers` iterates `p2p.peers.items` with no peers_mutex |
| 5 | HIGH | core/p2p.zig | 922 | Append without mutex | `self.peers.append(conn)` with no synchronization vs concurrent readers |
| 6 | HIGH | core/p2p.zig | 1158 | swapRemove without mutex | `cleanDeadPeers` mutates `self.peers` while RPC iterates |
| 7 | MEDIUM | core/rpc_server.zig | 869 | Missing mutex | `handlePoolStats` reads `ctx.bc.mempool.items.len` unlocked |
| 8 | MEDIUM | core/rpc_server.zig | 917 | Missing mutex | `handleNetInfo` reads peers.items.len + mempool.items.len unlocked |
| 9 | MEDIUM | core/p2p.zig | 1556 | Non-atomic counter | `node.inbound_count += 1/-= 1` racy across handler threads |
| 10 | MEDIUM | core/p2p.zig | 1599 | Cross-thread shared state | `dispatchMessage` writes node.chain_height / peer.height without lock |
| 11 | MEDIUM | core/ws_server.zig | 211 | Free-before-lock | `removeClient` closes stream + sets connected=false BEFORE acquiring srv.mutex |
| 12 | LOW | core/blockchain.zig | 1023 | Caller-contract | `getBlockCount` len read encourages unlocked compound reads in callers |
| 13 | LOW | core/rpc_server.zig | 149 | Allocator pressure | 4 concurrent RPC threads sharing GPA — amplifies latent UB elsewhere |

---

## Code snippets for top sites

### Site 1 — `core/blockchain.zig:1019`

```zig
// FIXME: SEGFAULT-RISK [scan-2026-04-25] HIGH
pub fn getLatestBlock(self: *Blockchain) Block {
    return self.chain.items[self.chain.items.len - 1];
}
```

### Site 5 — `core/p2p.zig:922`

```zig
// FIXME: SEGFAULT-RISK [scan-2026-04-25] HIGH
try self.peers.append(conn);   // realloc may invalidate readers
self.outbound_count += 1;       // racy r-m-w
```

### Site 4 — `core/rpc_server.zig:902`

```zig
// FIXME: SEGFAULT-RISK [scan-2026-04-25] HIGH
fn handlePeers(ctx: *ServerCtx, id: u64) ![]u8 {
    ...
    for (p2p.peers.items) |peer| {  // no mutex; reallocator races here
        ...peer.node_id... peer.host...
```

### Site 2 — `core/rpc_server.zig:~325`

```zig
// FIXME: SEGFAULT-RISK [scan-2026-04-25] HIGH
fn handleGetLatestBlock(ctx: *ServerCtx, id: u64) ![]u8 {
    const blk = ctx.bc.getLatestBlock();
    return std.fmt.allocPrint(ctx.allocator,
        "...,\"hash\":\"{s}\",\"previousHash\":\"{s}\",...",
        .{ ..., blk.hash, blk.previous_hash, ..., blk.transactions.items.len });
}
```

### Site 11 — `core/ws_server.zig:211`

```zig
// FIXME: SEGFAULT-RISK [scan-2026-04-25] MEDIUM
fn removeClient(srv: *WsServer, client: *WsClient) void {
    client.stream.close();        // <-- before lock!
    client.connected = false;     // <-- before lock!
    srv.mutex.lock();
    defer srv.mutex.unlock();
    ...
    srv.allocator.destroy(client);
}
```

---

## Files modified (FIXME comments only — no logic changes)

- `core/blockchain.zig` — 2 FIXME comments (sites #1, #12)
- `core/rpc_server.zig` — 6 FIXME comments (sites #2, #3, #4, #7, #8, #13)
- `core/p2p.zig` — 4 FIXME comments (sites #5, #6, #9, #10)
- `core/ws_server.zig` — 1 FIXME comment (site #11)

---

## Notes on what was NOT flagged

- **`Thread.spawn` arg lifetime**: Reviewed `RPCThreadArgs` in `main.zig:195` and the WS/P2P heap-allocated arg structs in `ws_server.zig:84` / `p2p.zig:1506`. All are either passed by value containing only pointers to objects whose lifetime is `main()` itself (which never returns while threads run), or are heap-allocated with explicit `defer destroy(args)` inside the worker. Not a bug.
- **`@ptrCast` between size-different types**: All 6 occurrences in `core/` are `@alignCast(@ptrCast(...))` round-trips between matching opaque pointer ABIs — safe.
- **GPA thread-safety**: `GeneralPurposeAllocator(.{}){}` defaults to `thread_safe = !builtin.single_threaded` in 0.15.2, so concurrent use is safe (slow but correct).
