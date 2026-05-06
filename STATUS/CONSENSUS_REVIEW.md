# OmniBus Consensus Review — Pre-Mainnet Audit

**Date:** 2026-05-07
**Branch:** `feat/onchain-orderbook`
**Auditor:** blockchain-consensus-expert agent
**Trigger:** Mainnet just restarted at `blocks=1`. Need consensus parameter sign-off before genuine launch.

> Read-only audit. No code modified. Findings reference exact file paths + line numbers.

---

## 1. Executive summary

Status: **NOT READY FOR MAINNET LAUNCH.**

The consensus code itself is well-structured (PoW + sub-blocks + Casper FFG + 4-shard metachain), but several parameters in `chain_config.zig` / `blockchain.zig` / `genesis.zig` are **inconsistent with the documented "10s block / 50 OMNI reward / Bitcoin-parity halving"** described in agent context and the README.

The biggest gaps:

1. **Block time is 1s (not 10s).** Mainnet `block_time_ms = 1000`. Halving at 126,144,000 blocks ≈ 4 years works *because* of 1s blocks, but the documented 10s target nowhere matches code. The two stories must reconcile before launch.
2. **Halving uses block height but the constant is sized for 1s blocks** (`126_144_000` blocks ≈ 4 years × 31.5M s). Drift between block target and actual rate will silently shift the halving schedule.
3. **`GENESIS_VALIDATORS` is an empty array** (`validator_registry.zig:57`). Casper FFG cannot finalize anything until validators stake in. There is no documented launch ceremony, no bootstrap validator set, no opening attestation procedure. **Finality is paper-only on day 1.**
4. **Genesis hash in `chain_config.zig:162` and `genesis.zig:28` is a hardcoded placeholder** (`"0000000a1b2c3d4e..."`) — not a real SHA-256, only 63 hex chars in `genesis.zig` and 64 in `chain_config.zig`. They disagree. Mainnet identity is broken until this is computed and frozen.
5. **`SUB_BLOCK_INTERVAL_MS = 40` (`sub_block.zig:19`)** while config says `block_time_ms = 1000` and `sub_blocks_per_block = 10`. 10 × 40ms = 400ms, not 1000ms. The sub-block engine sleeps half as long as config says — block cadence is implicit, not enforced.

These are not bugs that crash the chain; they are **specification drift**. Parameters in code do not match parameters in docs and parameters in different files do not match each other. That is the #1 risk before launch.

---

## 2. Current values table

| Parameter | Source | Mainnet | Testnet | Regtest | Recommendation |
|---|---|---|---|---|---|
| Block time target | `chain_config.zig:168` | **1000 ms** | 1000 ms | 100 ms | Pick one and document. If you really mean 10s, change to `10_000`. If 1s is intentional, update CLAUDE.md / agent context (currently says "10s") |
| Sub-blocks per block | `chain_config.zig:173` | 10 | 10 | 10 | OK |
| Sub-block interval | `sub_block.zig:19` (constant, not config) | **40 ms** (× 10 = 400ms) | 40 ms | 40 ms | **Contradicts config.** Move to `ChainConfig` and derive: `block_time_ms / sub_blocks_per_block`. Currently independent of network |
| Initial difficulty | `chain_config.zig:167` | 4 (leading hex zeros) | 1 | 1 | 4 = 16 bits ≈ 65k expected hashes. Fine for cold-start, but see retarget notes |
| Retarget interval | `chain_config.zig:172` + `blockchain.zig:67` | **2016 blocks** | 2016 | 10 | Bitcoin uses 2016. With 1s blocks that is 33 minutes (very fast retarget) — good for tracking hashrate. With 10s blocks it would be 5.6 hours (still reasonable). **Either way, document tradeoff.** |
| TARGET_INTERVAL_S | `blockchain.zig:71` | **2016 s** (= retarget × 1) | 2016 | 10 | Hardcoded `@intCast(RETARGET_INTERVAL)` assumes 1s blocks. **If block target ever changes, this breaks silently.** Should be `RETARGET_INTERVAL * (block_time_ms / 1000)` |
| Difficulty clamp | `blockchain.zig:107` | ±4× per retarget | same | same | Bitcoin-equivalent, sane |
| MIN/MAX difficulty | `blockchain.zig:75-76` | 1 / 256 | same | same | OK |
| Initial reward | `chain_config.zig:170` | **8,333,333 SAT** (≈ 0.00833 OMNI) | same | same | **NOT 50 OMNI** as agent context claims. The 8,333,333 SAT value is `5 OMNI / 600 blocks` — i.e., reward-shaped to give 5 OMNI per 10-min ("Bitcoin-equivalent in OMNI/min"). Document this clearly; it's intentional but counter-intuitive |
| Halving interval | `chain_config.zig:171` | **126,144,000 blocks** (~4 yr @ 1s) | same | 150 (regtest) | OK *if* block time is 1s. **Incompatible with 10s blocks** (would be 40 years). Test in `genesis.zig:357` confirms ±1 day of 4 yr |
| Max supply | `chain_config.zig:169` | 21M OMNI (21e15 SAT) | same | same | OK, Bitcoin parity |
| Checkpoint interval (FFG) | `finality.zig:18` | **64 blocks** | 64 | 64 | At 1s = 1 min between checkpoints. Reasonable |
| Soft finality | `finality.zig:21` | 6 confirmations | 6 | 6 | OK |
| Supermajority threshold | `finality.zig:62` | 2/3 (strict `>`) | same | same | Correct Casper FFG rule |
| MAX_VALIDATORS | `finality.zig:27` | 128 | 128 | 128 | Fixed-size, fine for bare-metal but caps decentralization |
| GENESIS_VALIDATORS | `validator_registry.zig:57` | **EMPTY ARRAY** | empty | empty | **CRITICAL**: see §7 |
| Shard count | `metachain.zig` (caller-provided) | 4 (per agent docs) | 4 | 4 | OK; supports 1..32 via `MAX_SHARDS` |
| Shard split threshold | `shard_coordinator.zig:12` | 80% capacity | same | same | OK |
| Shard merge threshold | `shard_coordinator.zig:13` | 20% capacity | same | same | OK |
| Genesis hash | `chain_config.zig:162` | `"0000000a1b2c…7d80"` (64) | `"00…01"` | `"00…00"` | **Placeholder only.** Must be replaced with real SHA-256 of finalized genesis block before launch |
| Genesis hash (alt) | `genesis.zig:28` | `"0000000a1b2c…7d8"` (**63 chars!**) | same | same | **Length mismatch** with chain_config.zig. Truncated by 1 char. Bug |
| Genesis timestamp | `chain_config.zig:163` | 1,743,000,000 (26 Mar 2026) | same | same | Already in past. Re-anchor at actual launch |

---

## 3. Audit dimension findings

### 3.1 Block time stability — 🟡 needs tuning

- **Claim:** "10s block time (10 × 0.1s sub-blocks)" — agent context, README narrative.
- **Reality:** `chain_config.zig:168` sets `block_time_ms = 1000`. `blockchain.zig:69` sets `TARGET_BLOCK_TIME_S = 1`. `sub_block.zig:19` sets `SUB_BLOCK_INTERVAL_MS = 40`.
- **Drift:** 10 × 40ms = 400ms actual sub-block cadence; PoW retarget assumes 1000ms. The retarget will pull difficulty up to make blocks actually take ~1s (PoW dominates). But a node running pure sub-block cadence without PoW (light miner / regtest) ticks at 400ms.
- **Difficulty algo:** `retargetDifficulty()` is solid — clamps at ±4× per period (Bitcoin parity), uses integer math (no float drift), handles edge cases (`actual_time <= 0` returns old). Window of 2016 blocks at 1s = ~33 min, **fast enough** to track hashrate without oscillation. ✅
- **Risk:** Time-warp attack is partially mitigated by clamp but `blockchain.zig:1219-1227` reads timestamps from `chain.items[retarget_start]` and `latest` directly with no median-of-11 filter. **Single-block timestamp manipulation by adversarial miner can shift retarget by up to 4× via clamp.** Bitcoin uses median-of-11; OmniBus does not.
- **Recommend:**
  1. Reconcile docs and code: which is canonical, 1s or 10s?
  2. Add median-of-11 timestamp filter in `retargetDifficulty()` (Bitcoin BIP-113).
  3. Make `SUB_BLOCK_INTERVAL_MS` derived from `ChainConfig.block_time_ms / sub_blocks_per_block` rather than hardcoded.

### 3.2 Difficulty adjustment window — ✅ ready (with caveat)

- 2016 blocks matches Bitcoin choice. With OmniBus's 1s blocks, this means retarget every ~33 min — fast enough to track 4× hashrate swings within an hour. Not so fast as to oscillate.
- Compared to Ethereum's per-block retarget (very reactive, but jittery) and Bitcoin's 2-week retarget (smooth but slow), OmniBus 33-min window is a reasonable middle.
- **Caveat:** `TARGET_INTERVAL_S` (`blockchain.zig:71`) = 2016 s, hardcoded as `RETARGET_INTERVAL` (a block count). Coincidentally correct only because block time is 1s. If `block_time_ms` ever changes per-network, this constant will not auto-update. **This is a footgun.**

### 3.3 Block reward + halving — 🟡 needs tuning (counter-intuitive but intentional)

- The agent context claims "50 OMNI reward, halve every 210k blocks". The code says **8,333,333 SAT (≈ 0.00833 OMNI) per block, halve every 126,144,000 blocks**.
- Reading the test (`genesis.zig:311-318`): `8,333,333 × 600 = 5 OMNI per 10 min`. So OmniBus produces the *same OMNI/minute as Bitcoin produces BTC/minute*, just spread across more, smaller blocks.
- Halving period: 126,144,000 blocks × 1s = 4 years. **Matches Bitcoin's 4-year halving cadence in wall-clock time**, even though the block count is 600× higher.
- Total emission to all halvings (sum 8,333,333 × 126.144M × 2 = ~21M OMNI): consistent with `max_supply_sat`.
- **The math works.** The narrative ("50 OMNI / 210k blocks") in the agent context is wrong/outdated. Reward is intentionally Bitcoin-economy-equivalent but block-rate-different.
- **Recommend:** Add an explicit doc in `STATUS/` titled "Reward Economics" explaining: 5 OMNI/10min ≡ Bitcoin's 6.25 BTC/10min in cadence terms, but spread across 600 blocks per 10min instead of 1. Update agent context to say `0.00833 OMNI / block, ~5 OMNI / 10min, halving every ~4 years` instead of "50 OMNI / 210k blocks".

### 3.4 Sub-block consensus — 🟡 needs tuning

- `SubBlockEngine` is single-actor: one miner produces all 10 sub-blocks per key-block (`sub_block.zig:227-301`). This is **not Byzantine-tolerant at the sub-block level** — it's a soft-confirmation latency hack, not a real consensus layer.
- Under high P2P latency: a peer that misses sub-block N gets `null` in `kb.sub_blocks[N]`. `calcSubMerkleRoot()` (line 186) hashes a zero placeholder for missing sub-blocks → **two nodes can finalize the same key-block with different `sub_merkle_root` if they disagree on which sub-blocks arrived**. Two valid hashes for the same block height. Fork.
- No orphan-rate budget defined. No mechanism to reject a key-block whose sub-blocks have stale timestamps. `SubBlock.isValid()` (line 93) only checks `sub_id < 10` and TX validity — does not validate timestamp ordering, miner identity, or shard match.
- Light client handling: not visible in `sub_block.zig`. Light clients almost certainly cannot validate sub-blocks without full TX data — they trust the key-block hash. That's fine, but undocumented.
- **Recommend:**
  1. **Reject key-blocks with any missing sub-block on mainnet.** `calcSubMerkleRoot` should refuse to compute if `received < 10`. Today it silently substitutes zero hashes.
  2. Add timestamp monotonicity check inside `KeyBlock.addSubBlock`: each `sub.timestamp_ms > previous.timestamp_ms`.
  3. Define orphan-rate budget (e.g., < 2% of key-blocks orphaned at network of N nodes). Add a metric.
  4. Document light-client trust model: "light client trusts PoW on key-block; sub-blocks are non-binding".

### 3.5 Finality — 🔴 broken or missing on mainnet

- `FinalityEngine` itself (Casper FFG) is **correctly implemented**: 2/3+ supermajority strict (`finality.zig:62`), justify→finalize cascade rule (line 191-198), equivocation slashing (line 165-172). Tests cover all the right cases.
- **But:** finality is dead-on-arrival because `validator_registry.GENESIS_VALIDATORS = [_]Validator{}` (`validator_registry.zig:57`).
- With zero validators: `total_voting_power = 0`, `hasSupermajority()` returns `false` always (line 60: `if (total_power == 0) return false`), no checkpoint can be justified, no block ever finalized via FFG.
- The chain falls back to "soft finality" (6 confirmations PoW-only). That's Bitcoin-level — but the README/agent context promises Casper FFG finality.
- Checkpoint interval: 64 blocks at 1s = 1 min. Sane.
- **Recommend:**
  1. Define a launch validator set: minimum 4 known parties (founder + 2-3 community-known operators) with stakes published before genesis.
  2. Either hardcode them into `GENESIS_VALIDATORS` (centralized launch, document "decentralizes after epoch N") or run a 1-epoch staking-only phase where the only valid TXs are stake deposits.
  3. Until this is decided, **disable the "finality" claim publicly.** Mainnet provides PoW soft finality (~6 confirms) only.

### 3.6 Shard coordination — 🟡 needs tuning

- `ShardCoordinator` routes by `SHA256(addr)[0..2] mod num_shards` (`shard_coordinator.zig:51-63`). Deterministic, reasonably uniform. ✅
- `Metachain` aggregates shard headers per second and records cross-shard receipts in 2 phases (debit, credit) — EGLD-style. ✅
- **Cross-shard finality is undefined.** `MetaBlock.calculateHash` includes shard headers, but there is no rule like "MetaBlock #N is finalized when its shard headers are each individually included in their shard's finalized FFG checkpoint". Today: a MetaBlock can be finalized at the metachain level while one of its shard headers refers to a shard block that gets reorganized away. **Atomicity is paper-only.**
- `pending_receipts` (line 147) is a flat queue with no per-receipt timeout. If `phase2_credit` never lands (e.g., destination shard is offline), the receipt sits forever. No DLQ, no rollback.
- `splitShard` / `mergeShards` modify `num_shards` mid-flight — but addresses are routed by `% num_shards`. **A split changes the routing of every existing address**, breaking every in-flight cross-shard receipt and every account's "home shard". This is an implicit hard fork.
- **Recommend:**
  1. **Disable adaptive sharding on mainnet.** Set `num_shards = 4`, hard. Re-enable only after a documented split protocol with address-rerouting + state migration.
  2. Define cross-shard finality rule: "MetaBlock M is finalized iff all shard blocks referenced by M's shard headers are each finalized by their shard's FFG."
  3. Add receipt timeout: if `phase2_credit` does not land within K MetaBlocks, refund (revert phase1).
  4. Add cross-shard atomicity test: simulate a phase1-debit followed by destination-shard rollback; confirm refund.

### 3.7 Genesis validator set — 🔴 missing

- `GENESIS_VALIDATORS = [_]Validator{}` — empty.
- Comment in `validator_registry.zig:222` ("dynamic onboarding") suggests intentional, but there is no on-chain bootstrap mechanism: the only way validators can be added is via "governance proposals" (TODO note in `blockchain.zig:190`), which themselves require validators to vote.
- **Chicken-and-egg.** Until the first validator is added by some out-of-band mechanism, the validator set is empty forever.
- **Recommend launch ceremony:**
  1. **Day -7 to Day 0:** founder publishes Genesis Manifesto with hash of intended `GENESIS_VALIDATORS` array (4-5 known parties, including founder). Public review.
  2. **Day 0:** chain launches with `GENESIS_VALIDATORS` populated. Stake = 1 OMNI each, cosmetic (founder funds via initial reward over first epoch).
  3. **Epoch 1 (block 64):** first FFG checkpoint. 4-of-5 attest → justified. PoW continues.
  4. **Epoch 2 (block 128):** justified → epoch 1 finalized.
  5. **From block 1000:** open staking. Anyone with > MIN_STAKE can join validator set via on-chain TX.
  6. **Document slashing:** equivocation = lose stake; offline > N epochs = soft eject.

---

## 4. Top 3 changes required before mainnet launch

### #1 — Reconcile genesis hash and freeze it

Both `chain_config.zig:162` and `genesis.zig:28` contain placeholder genesis hashes that disagree (one is 64 chars, the other 63 — meaning one is a typo). Neither is a real SHA-256 of the genesis block. Until this is computed deterministically from the real genesis block (timestamp + message + initial difficulty + empty TX list), **the chain has no canonical identity** and any node that joins is choosing arbitrarily.

**Action:** Build genesis once, take its real hash, hardcode it in both files (and add a unit test that asserts `chain_config == genesis`). Re-anchor genesis_timestamp to a future date (currently 26 Mar 2026, already in the past).

### #2 — Define and populate `GENESIS_VALIDATORS` + run a launch ceremony

Without this, FFG finality never engages. `finality.zig` is dead code on mainnet.

**Action:**
- Choose 4-5 launch validators (founder + 2-3 trusted operators).
- Publish their public keys and stake commitments 7 days before launch.
- Populate `validator_registry.GENESIS_VALIDATORS`.
- Document the staking-open block height (e.g., block 1000).
- Disable public claims of "Casper FFG finality" until checkpoint #1 is observed finalized in production.

### #3 — Reconcile block-time spec drift and add median-of-11 timestamp filter

Three places say three things: agent context says 10s, `chain_config.zig` says 1000ms, `sub_block.zig` says 40ms × 10 = 400ms. Whatever the canonical answer is, **one source of truth.**

**Action:**
- Pick canonical block time. Recommended: keep 1s — code and economics are sized for it. Update agent context, README, and CLAUDE.md to say "1s blocks" not "10s blocks".
- Make `SUB_BLOCK_INTERVAL_MS` derived from `ChainConfig.block_time_ms / sub_blocks_per_block` so they cannot drift.
- Make `TARGET_INTERVAL_S` in `blockchain.zig:71` derived from `RETARGET_INTERVAL × block_time_ms / 1000` (currently coincidentally correct only because block time is 1s).
- Add median-of-11 timestamp filter in `retargetDifficulty()` to prevent single-block timewarp manipulation.

---

## 5. Risk register — things that can break consensus post-launch

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Timewarp attack via single-block timestamp manipulation; up to 4× difficulty shift | Medium | Block rate doubles/halves; chain throughput collapses | Median-of-11 filter (BIP-113) |
| R2 | Sub-block missing → two valid `sub_merkle_root` for same key-block height → soft fork | High under poor network | Persistent fork between datacenters | Reject key-blocks with `received < 10`; require all 10 sub-blocks |
| R3 | `GENESIS_VALIDATORS` empty → FFG never finalizes → marketing "instant finality" claim is false | **Certain on day 1** | Reputational; users assume finality and lose funds in long reorgs | Launch ceremony with 4-5 validators + 1 OMNI cosmetic stakes |
| R4 | Adaptive sharding `splitShard`/`mergeShards` on live mainnet rebuckets every address → implicit hard fork | Medium (tied to load) | All in-flight cross-shard TXs lost; UTXO routing breaks | Pin `num_shards = 4` on mainnet; gate split/merge behind governance vote |
| R5 | Cross-shard `phase2_credit` never lands due to destination-shard outage → funds lost in pending_receipts | Medium | User funds permanently inaccessible | Receipt timeout + refund path; metric on pending receipt age |
| R6 | Halving-interval drift if block time changes (e.g., baremetal reduces to 100ms) → halving every 4 months instead of 4 years → supply emitted 12× too fast | Low (requires config change) | Total supply blown past 21M | Express halving in seconds, not blocks: `halving_seconds = 4 * 365 * 86400` |
| R7 | Genesis hash placeholder (63-char vs 64-char mismatch) → two nodes compute different chain identity at startup | **Certain** | Network-split-on-launch | Compute real hash, freeze in both files, unit-test equality |
| R8 | `total_fees_burned_sat` is a `pub var` global (`blockchain.zig:87`) — not per-Blockchain instance | Medium | State leaks across test runs; non-deterministic in concurrent contexts | Move into `Blockchain` struct |
| R9 | `MAX_VALIDATORS = 128` (`finality.zig:27`) caps decentralization; once 128th joins, no more can | Low (long-term) | Centralization ceiling; 129th validator forever excluded | Bump to 1024+ or use dynamic allocation; document as "soft cap, governance-changeable" |
| R10 | `MAX_REORG_DEPTH = 100` blocks (`blockchain.zig:61`) at 1s = 100 seconds. Bitcoin's equivalent is ~16 hours of work. Easier to attack | Medium | Deep-reorg attack feasible with ~10 min of 51% hashrate | Either raise to 6000 (~100 min) or rely entirely on FFG finality (which itself is currently broken; see R3) |
| R11 | Equivocation slashing in `finality.zig:171` only marks `slash_count++` but does NOT actually burn stake — slashing is observation-only | High | Validators can equivocate with zero economic cost → safety violations free | Wire equivocation to staking module: on slash, reduce validator stake to 0 |
| R12 | `attest()` rejects re-vote in same epoch (line 167) — but does NOT detect surround-votes (Casper's other slashing condition) | Medium | Long-range attack via surround voting unpunished | Add surround-vote detection: reject if `(new.source < existing.source && new.target > existing.target)` |

---

## 6. What is solid (positive findings)

- `retargetDifficulty()` arithmetic — integer-only, ±4× clamp, Min/Max bounds. Bitcoin-equivalent. Well-tested.
- `Checkpoint.hasSupermajority` uses strict `>` 2/3 (line 62), preventing the "exactly 2/3" ambiguity that bit early Cosmos chains.
- `FinalityEngine` Casper FFG cascade rule (justify N → justify N+1 → finalize N) is correctly implemented (line 191).
- Cumulative-work fork choice (`blockchain.zig:185`) is the correct heaviest-chain rule, not naive longest-chain.
- Hardcoded mainnet checkpoints (`chain_config.zig:298`) anchor the chain identity — a peer cannot reorg below them.
- `ShardCoordinator.getShardForAddress` — deterministic, uniform via SHA-256.
- `MetaBlock.calculateHash` covers all shard headers and cross-receipts → tampering with any sub-element changes the meta hash.
- Equivocation detection in attest() — at least the *detection* exists, even if slashing is observation-only.

---

## 7. Sign-off checklist for mainnet launch

Before announcing real-money mainnet:

- [ ] Genesis hash computed and frozen in `chain_config.zig` AND `genesis.zig`, identical, 64 hex chars
- [ ] `genesis_timestamp` re-anchored to actual launch instant (not 26 Mar 2026)
- [ ] `GENESIS_VALIDATORS` populated with ≥ 4 published validators + manifesto signed
- [ ] Block-time canonical answer documented in `STATUS/CONSENSUS_PARAMETERS.md`
- [ ] `SUB_BLOCK_INTERVAL_MS` derived from config, not hardcoded
- [ ] `TARGET_INTERVAL_S` derived from `block_time_ms × retarget_interval`, not coincidentally correct
- [ ] Median-of-11 timestamp filter added to retarget
- [ ] Key-blocks rejected if `received < 10` sub-blocks
- [ ] Adaptive sharding gated off (`num_shards = 4`, immutable)
- [ ] Cross-shard receipt timeout + refund path implemented
- [ ] Equivocation slashing wired to actual stake reduction (currently observation-only)
- [ ] Surround-vote detection added to `FinalityEngine.attest`
- [ ] First FFG checkpoint (epoch 1) observed finalized in a 7-day testnet rehearsal
- [ ] Reorg test: simulate 50-block reorg vs. checkpoint; confirm rejection
- [ ] Public bug-bounty open ≥ 30 days before mainnet

When all 14 are checked, mainnet launch is technically defensible. Today, **0 of 14** are met.
