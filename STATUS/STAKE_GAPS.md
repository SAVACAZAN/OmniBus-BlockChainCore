# Staking + Rewards Audit — 2026-05-07

## Summary

OmniBus is a **PoW chain with stub PoS scaffolding**. The chain is fully driven by Proof-of-Work: miners mine blocks, the entire `block_reward_sat + fees_to_miner` is credited to the single `miner_address` (`blockchain.zig:1184–1190, 1991–1993, 2197–2199`), and that's the end of the reward story for everyone except the miner. The `StakingEngine` (`core/staking.zig`) is a fully-tested standalone module wired into the node (`main.zig:1257`, passed into `ServerCtx.staking`) but **never receives any input from chain state**: `registerValidator` / `activateValidator` / `startUnbonding` / `completeUnbonding` are called only in unit tests, never from `applyBlock`, never from a TX type, never from RPC. As a result `staking.validator_count == 0` for the entire lifetime of any node, so `staking.distributeRewards()` (called every 100 blocks at `main.zig:2561`) is a guaranteed no-op (it early-returns when `total_voting_power == 0`). Slot-leader rotation is real and integrated, but uses a *different* validator set (`bc.validator_set`, derived from the set of past miners with balance ≥ 1 sat — see `validator_registry.zig:73, 181`) that has nothing to do with stake. There is no on-chain TX type for stake / unstake / delegate / claim — only an `op_return` prefix `"stake:"`/`"unstake:"` that updates a *tracking-only* `stake_amounts` HashMap (`blockchain.zig:1652–1675`) which does not lock funds, does not register a validator, and does not affect consensus. Slashing has working logic in `staking.zig` but the RPC handler `submitslashevidence` (`rpc_server.zig:5805–5818`) hard-codes placeholder block hashes/signatures, so it can never verify a real double-sign and would only ever slash a validator that doesn't exist (since none are registered). Finality is wired into the mining loop and self-attests every 64 blocks, but with a fixed `validator_id=0, voting_power=1000` so it's solo-finalising its own blocks without any real BFT.

Net: there is a lot of code, well-tested in isolation, but **the staking module is not connected to chain state at any point**. The only on-chain reward flow that actually runs is "100% of (reward + fees_to_miner) → miner". This is a PoW chain.

## Per-area analysis

### 1. Staking flow — 🔴 MISSING (chain integration)
- `core/staking.zig:318` — `StakingEngine.registerValidator(addr, stake, block)` exists and is tested.
- **No call site outside tests**. `Grep` for `registerValidator` shows zero hits in `main.zig`, `blockchain.zig`, `rpc_server.zig`, `consensus.zig`, etc.
- The only "stake" path in the chain is the prefix-match in `applyOpReturnRoles` at `blockchain.zig:1652–1675`: a TX with `op_return = "stake:<n>"` increments `bc.stake_amounts[from_address]` (saturating add). It does **not** lock the sender's coins, does **not** register a validator in `StakingEngine`, does **not** require min-stake, and there is no enforcement that the staked amount ≤ balance.
- Validator set is hard-coded empty at genesis (`validator_registry.zig:57` — `GENESIS_VALIDATORS = [_]Validator{}`); validator membership is derived from "anyone who ever mined a block and currently has ≥ 1 sat" (`validator_registry.zig:181 rebuildValidatorSet`).

### 2. Validator registration — 🔴 MISSING (post-genesis bond path)
- No TX type to bond a validator. Cannot exit `pending → active` via a chain event — only via direct test calls to `engine.activateValidator(idx)`.
- `VALIDATOR_MIN_STAKE = 100 OMNI` (`staking.zig:18`) and `UNBONDING_PERIOD = 604_800` (`staking.zig:24`) constants exist but are never enforced because the entry path doesn't exist.
- The "real" validator path used by consensus (`bc.validator_set`) requires only `balance ≥ MIN_VALIDATOR_BALANCE = 1 sat` (`validator_registry.zig:73`) — i.e., having ever mined a block. No bond, no lockup, no stake.

### 3. Delegation — 📝 SCAFFOLD
- `Validator.delegated_stake` field exists (`staking.zig:221`), `Delegation` struct exists (`staking.zig:277–283`), but `StakingEngine` has **no `delegate()` / `undelegate()` methods**, no delegation array, no delegation tracking. The `delegated_stake` field is never written by anything except `std.mem.zeroes` at init.
- No TX type, no RPC handler.

### 4. Rewards distribution — 🟡 PARTIAL (winner-takes-all only)
- Block reward + miner fees: 100% to `miner_address` (`blockchain.zig:1184–1190, 1991–1993, 2197–2199`).
- Fee burn: 50% burn / 50% miner is mentioned in `transaction.zig:214` comment, and `fees_burned` accounting exists (`blockchain.zig:1189, 1297, 1510, 1636`), so partial fee split is real.
- Validator reward distribution: `staking.distributeRewards(reward_sat)` is called every `REWARD_EPOCH_BLOCKS = 100` (`main.zig:2561`), but **guaranteed no-op** because `staking.activeCount() == 0` always (no validators ever registered). Even if it did fire, it credits `validator.total_rewards` in memory only — there is no on-chain credit, no UTXO emission, no balance change.
- Commission (`Validator.commission_pct = 10` default) is collected nowhere.

### 5. Slashing — 🟡 PARTIAL (logic real, evidence verification fake at RPC boundary)
- Slash logic is real and well-tested (`staking.zig:457–601`, plus 12 test blocks).
- `handleSubmitSlashEvidence` (`rpc_server.zig:5782–5825`) accepts validator address + reason + height + reporter, then **hard-codes the cryptographic evidence**: `block_hash_1 = [0xAA]*32`, `block_hash_2 = [0xBB]*32`, signatures `[0x11]*64` / `[0x22]*64`. The comment claims "full cryptographic verification happens at the consensus layer" — but no consensus-layer slash path exists; the RPC handler is the only entry point. So `verifyDoubleSign` (`staking.zig:498`) only checks "hashes differ and are non-zero", which is trivially satisfied by the placeholders.
- Penalty is applied to `engine.validators[idx]` in memory. **It does not touch on-chain balances**. The slashed validator's `bc.balances[address]` is unaffected — slashing is purely in the in-memory StakingEngine which is itself disconnected from chain state.
- Reporter reward (10%) is tracked in `engine.total_reporter_rewards` but never paid out.

### 6. Unstaking / withdraw — 🔴 MISSING
- `startUnbonding` / `completeUnbonding` exist on the engine (`staking.zig:343, 352`) but no TX type, no RPC, no caller.
- `op_return = "unstake:<n>"` decrements `stake_amounts` (`blockchain.zig:1664–1675`) — purely a counter, no funds returned (because none were locked).

### 7. Reward claim — 🔴 MISSING
- No claim TX, no RPC. `validator.total_rewards` accrues in memory inside StakingEngine but cannot be withdrawn. On node restart it is lost (StakingEngine is `init()`-ed fresh in `main.zig:1257`, never persisted to `omnibus-chain.dat`).

### 8. Slot leader rotation — ✅ REAL (but not stake-weighted)
- `validator_registry.leaderForSlot(slot_id, prev_block_hash, validators)` (`validator_registry.zig:83`) is deterministic, weighted-random, well-tested, and integrated into the mining loop (`main.zig:1872`) and into `validateBlockLeader` for peer block acceptance (`validator_registry.zig:152`). RPC `getslotleader` returns the next-slot leader (`rpc_server.zig:5277`).
- **However**: weights are uniform (`weight = 1` for everyone — `validator_registry.zig:202`), so this is round-robin-by-hash among all past miners with ≥ 1 sat — **not stake-weighted**. The `StakingEngine.selectProposer(block_hash)` function (`staking.zig:403`, weighted by `total_stake`) exists but is never called.
- Anti-Sybil is "must have mined at least one block" + "balance ≥ 1 sat" + faucet rate-limit (`validator_registry.zig:54–72`).

### 9. Finality / Casper FFG — 🟡 PARTIAL (running but not BFT)
- `FinalityEngine` is initialised with hardcoded `total_voting_power = 1000` (`main.zig:1252`) and never updated when validator set changes.
- Mining loop calls `proposeCheckpoint` + `self-attest` every 64 blocks (`main.zig:2544–2557`) with hardcoded `validator_id=0, voting_power=1000`. Single attestation immediately satisfies 2/3+ supermajority of the hardcoded total_voting_power, so checkpoints justify on the first self-vote. No second validator ever attests; there is no P2P attestation gossip; no real BFT vote.
- Equivocation detection in `FinalityEngine.attest` (`finality.zig:163–171`) is real, but unreachable because no peer ever attests.
- `isFinalized(height)` is queryable but reflects only solo-finalised checkpoints.

## Missing TX types

The following TX types should exist for a real PoS / hybrid chain but are absent from `TxType` enum (`transaction.zig:60`):

- `stake_deposit = 0x70` — bond N OMNI to become a validator (locks UTXOs, creates `Validator` record).
- `stake_topup = 0x71` — increase own bond.
- `validator_activate = 0x72` — voluntary self-activation after queue delay (or auto by chain).
- `unstake_request = 0x73` — start unbonding (transitions `active → unbonding`, records unbonding_block).
- `unstake_withdraw = 0x74` — claim coins after `UNBONDING_PERIOD`.
- `delegate = 0x75` — delegator locks N OMNI on a validator.
- `undelegate = 0x76` — delegator starts unbonding their delegation.
- `claim_rewards = 0x77` — withdraw accrued `total_rewards` to delegator/validator address.
- `validator_commission_set = 0x78` — validator updates `commission_pct`.
- `slash_evidence = 0x79` — submit cryptographic evidence on-chain (replaces fake-evidence RPC); evidence becomes part of block, deterministically applied.
- `validator_unjail = 0x7A` — recovery from `jailed` (downtime) status after timeout.
- `attest_checkpoint = 0x7B` — gossip-able attestation for `finality.zig` so checkpoints justify across peers, not via solo self-vote.

The slot 0x70..0x7F is already reserved in the `TxType` comment (`transaction.zig:119–120`) — "currently piggy-back on op_return prefix strings; will migrate here in a later phase".

## Missing RPCs

Currently present: `getvalidators`, `getslotleader`, `getstakinginfo`, `getslashhistory`, `submitslashevidence`. Missing for full UX:

- `stake` / `senstaketx` — build & submit `stake_deposit` TX (mirrors current `sendtransaction` for transfers).
- `unstake` — build & submit `unstake_request` TX.
- `withdrawstake` — claim after unbonding period.
- `delegate` / `undelegate` — for delegators.
- `claimrewards` — pull accrued rewards.
- `getdelegations` — list delegations for an address (both as delegator and as validator).
- `getrewardhistory` — paginated rewards earned per epoch.
- `getfinality` — return `last_finalized_epoch`, `last_finalized_height`, `last_justified_epoch`, current attestation status of pending checkpoint. (`finality.zig` has the data; nothing exposes it.)
- `getepochinfo` — current epoch, blocks until next checkpoint, validator turnout.
- `getvalidatorset` (richer) — combine `bc.validator_set` (slot-leader set) with `StakingEngine.validators` (bonded set) so the UI can show both.
- `unjailvalidator` — admin/owner unjail after downtime jail.

## Recommended implementation order

Ranked by user-value unlock per unit of work, easiest-to-hardest among items at the same tier:

1. **Persist StakingEngine state to chain.dat** — without this, every restart wipes validator records and rewards. This is a 1-day fix and is the prerequisite for everything else having any meaning.

2. **`stake_deposit` TX type (0x70) + balance lock** — single most impactful change. Implement payload `{validator_addr, amount, commission_pct}`, deduct `amount` from sender's UTXOs, call `StakingEngine.registerValidator`. Auto-`activate` after a small queue delay (e.g. 10 blocks) or immediately if validator slot is free. Unlocks the entire PoS narrative.

3. **`unstake_request` + `unstake_withdraw` TXs** — locks must be exitable; without this nobody will stake. Honour `UNBONDING_PERIOD` already in `staking.zig`.

4. **Real reward distribution into on-chain balances** — replace the in-memory `validator.total_rewards += share` with actual UTXO emission to validator address (or accrual into a withdrawable on-chain `pending_rewards` map). Either auto-credit each epoch (simpler) or add `claim_rewards` TX (more flexible). Pair with reward split: e.g. `60% miner / 30% active validators (stake-weighted) / 10% burn`.

5. **Stake-weighted slot leader** — switch mining loop and `validateBlockLeader` from `bc.validator_set` (uniform-weight) to `StakingEngine.selectProposer(block_hash)` once at least N validators are bonded. The function already exists at `staking.zig:403`.

6. **Real slash evidence path** — `slash_evidence` TX type. Verify both ECDSA signatures over the two block hashes against the validator's registered public key. Apply slash from on-chain locked stake (not just in-memory). Pay reporter reward as real UTXO. Replace `handleSubmitSlashEvidence` placeholder hashes with actual params from caller.

7. **Delegation** — `delegate` / `undelegate` / `claim_rewards` TXs. Delegators get `(1 - commission_pct)` of validator's share. Adds significant UX/economic depth but only useful after items 1-4 work.

8. **Real finality / Casper FFG attestation gossip** — make `attest_checkpoint` a TX (or a P2P-only message), set `FinalityEngine.total_voting_power` to live `staking.totalVotingPower()`, accumulate real cross-peer attestations. This is the largest engineering item; without items 1–5 it has no honest validators to vote with anyway.

9. **Migrate `op_return = "stake:..."` legacy path** — once the typed TX path is live, remove the prefix-matching code in `applyOpReturnRoles` (`blockchain.zig:1652–1675`) and the dead `bc.stake_amounts` map. They are misleading: today they look like staking but do nothing real.

10. **Commission, unjail, validator metadata RPCs** — polish layer; only worth doing once everything above ships.
