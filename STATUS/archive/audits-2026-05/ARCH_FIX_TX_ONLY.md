# Architectural fix: every state change MUST be a chain TX

## The bug we just hit (2026-04-28)

After commit `b363095` we removed the in-mining-loop state save (full
chain rewrite was the dominant p99 latency outlier). The argument was:
*"the blockchain itself is the database — balances reconstruct from
chain replay on startup, restart resyncs from peers."*

That is correct **only when every balance change is a TX on chain**.
It was not.

Concrete loss:

- 54 addresses had successfully called `claimfaucet` (logged in
  `data/testnet/faucet-claims.json`)
- 51 of those balances vanished at the next restart
- Only the 3 addresses with mining rewards survived (because mining
  rewards ARE proper coinbase TXs in chain blocks)
- Rich list now shows 3 entries instead of ~100

The faucet grants lived in `bc.balances` (in-memory `StringHashMap`)
without a corresponding TX in any block. Chain replay rebuilt the
HashMap from coinbase TXs only → faucet grants gone.

## The rule

**Anything that changes balance MUST be a transaction on chain.**

If you can't audit it via `getblock` + `gettransaction`, it's a bug.
The mempool is the *only* place TXs live before they hit a block.
Once they hit a block, they're permanent. Nothing else exists.

## What needs to become TX-on-chain

| State today | Sketch of fix |
|-------------|---------------|
| `claimfaucet` writes `bc.balances` directly | Create a signed TX `from = faucet wallet` (key from `OMNIBUS_FAUCET_PRIVKEY`), `to = user`, `amount = grant`. Push to mempool. Block inclusion → balance materialised through normal apply path. |
| `faucet-claims.json` rate-limit file | Remove. Anti-double-claim becomes "is there a faucet→user TX in the last N blocks?" — answered by the address-history index that `getaddresshistory` already builds. |
| Reputation FOOD/LOVE/RENT/VACATION credits | Each credit becomes a TX with a custom op-return-style payload that the apply path interprets. Or a dedicated "REPUTATION_CREDIT_V1" TX type with its own validator. |
| Agent native-action decisions | Each decision (claim, swap, stake) becomes a signed TX from the agent's derived wallet. The chain validates the signature and enforces the on-chain rules; the agent process never edits balances directly. |
| Exchange match fills | Already TX-equivalent (paper engine emits per-fill JSONL, real engine touches `bc.balances`). The real-engine path needs the same TX-ification: a `MATCH_SETTLE_V1` TX so a fresh node replaying the chain reaches the exact same balance state. |
| Bridge mint/burn | Already designed as TX in `bridge_native.zig`; verify nothing else writes balances on the bridge path. |

## What stays in memory (legitimately)

- `bc.balances` — kept as a hot read cache. Source of truth is the
  chain; this is just an O(1) lookup index rebuilt from replay.
- Mempool — by definition pre-confirmation, pre-block. Allowed.
- `g_clock`, `g_oracle_fetcher.prices`, RDTSC counters — runtime
  telemetry, not consensus state.
- WebSocket subscriber lists, RPC connection pool — transport.
- `g_slot_calendar` — derived from validator set + tip hash, can be
  rebuilt at any time.

If a value affects who owns what, it must be a TX. Everything else
is fair game for in-memory.

## Migration plan (separate dedicated session)

### Phase 1 — Faucet TX-ification (~3–4 h)

1. At startup, derive the faucet wallet from `OMNIBUS_FAUCET_PRIVKEY`
   exactly as we do for the miner wallet. Store as `g_faucet_wallet`.
2. Pre-mine: include a single coinbase TX in the genesis block that
   funds `g_faucet_wallet` with the testnet faucet pool (e.g. 1 M OMNI).
   Or: pin a height-0 funding TX checked into `genesis.zig`.
3. Replace the body of `handleFaucetClaim`:
     - sign a real `TX{from=faucet, to=user, amount=GRANT, fee=0}`
     - submit it to the mempool via the same code path as
       `sendrawtransaction`
     - return the TX hash to the caller
4. Anti-double-claim: scan address history for `from=faucet, to=user`
   in the last `FAUCET_COOLDOWN_BLOCKS`. If present → reject. No
   separate JSON file.
5. Remove `data/<chain>/faucet-claims.json` entirely. Migrate
   existing claim list to backfilled TXs in a one-shot block at
   migration height (or accept the loss on testnet).

### Phase 2 — Reputation TX-ification (~4–6 h)

`reputation_manager.zig` currently mutates 4 in-memory counters per
address (`LOVE`, `FOOD`, `RENT`, `VACATION`) on every block. After
Phase 1 finishes, design `REPUTATION_CREDIT_V1` payload:

  - `tx.kind = .reputation_credit`
  - `tx.payload = { addr, dimension: love|food|rent|vacation, delta }`
  - emitted by the chain itself per block (kind of like coinbase)
  - signed by the slot-leader's miner key

Validator: rebuild the 4 counters from the TX history.

### Phase 3 — Agent TX-ification (~3 h)

Agents already submit TXs for their `claim_faucet` actions; check
that swap/stake/withdraw also flow through the mempool, not direct
state writes. Audit `agent_executor.zig` for any `bc.balances.put`
calls outside of TX submission.

### Phase 4 — Exchange match settlement (~5–8 h)

The hardest. Match fills currently mutate balances directly in the
mining loop's RPC handler. Convert to a `MATCH_SETTLE_V1` TX:

  - emitted by the real-engine matcher when a fill occurs
  - `payload = { taker, maker, base_amount, quote_amount, fee }`
  - block apply path handles balance debits/credits with the same
    code that handles a normal transfer
  - paper engine stays out of chain (it's already isolated)

This one's tricky because of nonces — match settlements aren't
initiated by a user, so they need a chain-level "operator nonce" or
they need to be tied to the slot-leader's nonce.

### Phase 5 — Audit + tooling (~2 h)

Grep the entire codebase for `bc.balances.put` and `bc.balances.getOrPut`.
Every callsite must either be:
  - inside `applyTransaction` (chain replay path) — fine
  - inside genesis bootstrap — fine, document it
  - flagged as a bug

Add a debug assertion in non-replay code paths that fires if
`bc.balances` is mutated outside `applyTransaction`. Catch the next
regression before it hits production.

## Acceptance criteria

A migration is "done" when:

1. `wipe data/<chain>/`
2. start node from genesis
3. Multiple users claim faucet, mine, trade, withdraw
4. Stop node with SIGKILL (worst case, no graceful shutdown)
5. Restart from genesis (force re-replay)
6. **All balances match exactly what they were before the kill.**

Until that test passes, "the chain is the database" is a slogan,
not a guarantee.

## What we do today (interim)

For testnet, until the migration runs:

- Restart the testnet seed only with `systemctl restart` (graceful
  → SIGTERM → save-on-shutdown still runs, balances persist).
- Do NOT `kill -9` the node.
- Users who lose balance to a hard restart: re-claim faucet. It's
  testnet, no real value lost.

A complete state snapshot (the old `checkAutoSave` behaviour) was a
band-aid for this exact scenario. Bringing it back as an async-thread
60s-tick would mask the root cause; we should fix the root cause
instead.
