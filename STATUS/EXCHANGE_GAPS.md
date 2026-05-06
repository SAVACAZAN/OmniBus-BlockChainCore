# Exchange RPC Audit — 2026-05-07

Branch: `feat/onchain-orderbook`
Auditor: Opus 4.7 (1M)
Scope: 19 `exchange_*` RPCs in `core/rpc_server.zig`, plus matching engine,
pair registry, transaction types, on-chain orderbook integration.

## Summary

- Total RPCs audited: 19
- ✅ REAL (real impl, persists, integrated): **8**
- 🟡 PARTIAL (works but has gaps — single-source state, missing chain submit, etc): **9**
- 🔴 STUB (placeholder / hardcoded / missing): **2**
- ❓ UNCLEAR: 0

Important architectural finding (ROOT CAUSE OF MOST "PARTIAL" RATINGS):

The RPC `exchange_placeOrder` / `exchange_cancelOrder` operate **directly on the
in-memory matching engine** (`ctx.exchange`) and call `createOrderTransaction`
which builds a JSON + double-SHA256 hash but **never submits it to mempool**
(`addTransaction` is NOT called for order TXs). Meanwhile the canonical chain
side at `core/blockchain.zig:2307 applyOrderTxs` matches `tx.tx_type ==
.order_place` / `.order_cancel` TXs taken from blocks. These two paths are
parallel, not unified — the matching engine state on a node that received an
order via RPC is **not the same** as the matching engine state replayed from
chain history on a fresh node. Fees ARE collected on chain via
`applyExchangeFees` (rpc_server.zig:9454), but the order itself isn't a chain TX.

Until the RPC handler submits a real `order_place` tx into mempool (or this
audit is corrected by pointing me to a hidden submission path), every node
that wasn't connected when the RPC fired will have a divergent orderbook —
this is the single biggest gap to "real CEX/DEX parity".

---

## Per-RPC analysis

| # | RPC | Status | File:Line | Evidence | Gaps |
|---|-----|--------|-----------|----------|------|
| 1 | `exchange_placeOrder` | 🟡 PARTIAL | rpc_server.zig:9245 | Verifies ECDSA sig, derives addr from pubkey, replay-protects via `nonceLookup`, oracle price-band, KYC tier cap, balance check w/ `computeReservedFromOrderbook`, calls `engine.placeOrder`, calls `applyExchangeFees` per fill, journals to `orders.jsonl`. **Builds tx hash via `createOrderTransaction` but never `addTransaction`** — order not in chain. | (a) RPC path doesn't submit `order_place` TX into mempool/chain; only in-memory engine state changes. (b) No TIF (GTC/IOC/FOK), only naive limit. (c) No stop / market / OCO. (d) Self-trade allowed by design. |
| 2 | `exchange_cancelOrder` | 🟡 PARTIAL | rpc_server.zig:9547 | ECDSA sig + ownership + nonce check; calls `engine.cancelOrder`; journals "cancel". | Same: no on-chain `order_cancel` TX submitted. Cancel only mutates in-memory engine. |
| 3 | `exchange_getOrderbook` | ✅ REAL | rpc_server.zig:9627 | Walks `engine.bids[]` / `engine.asks[]`, depth capped 50, returns bestBid/bestAsk/spread. Reflects engine state truthfully. | Engine state itself is the issue (see #1), but the RPC accurately exposes it. |
| 4 | `exchange_getUserOrders` | ✅ REAL | rpc_server.zig:9699 | Filters bids+asks by trader address (and optional pair). | Only ACTIVE orders — no closed-orders history scan from journal. |
| 5 | `exchange_getTrades` | ✅ REAL | rpc_server.zig:9748 | Reads ring buffer `es.trade_log[]` (256 entries), per-mode (paper/real), filters by pair/address. | Ring is 256 only — older trades disappear. No full history index from journal/chain. |
| 6 | `exchange_listPairs` | 🟡 PARTIAL | rpc_server.zig:9805 | Iterates compile-time `EXCHANGE_PAIRS` (7 hardcoded pairs at rpc_server.zig:8698). | Static — no admin RPC to add/remove pairs at runtime. Note: `core/pair_registry.zig` exists but is for *off-chain price feeds* (LCX/Kraken/Coinbase tracking), NOT tradable pair config. |
| 7 | `exchange_getStats` | ✅ REAL | rpc_server.zig:9825 | Walks engine + trade log per pair, returns bb/ba/spread/orderCount/totalOrders/trades. | Pulled from same in-memory state (subject to #1 divergence). |
| 8 | `exchange_getAuthNonce` | ✅ REAL | rpc_server.zig:10222 | 32-byte CSPRNG nonce, stored with `authNoncePut`, TTL purge. | None for auth scope; design is stateless / no JWT. |
| 9 | `exchange_login` | 🟡 PARTIAL | rpc_server.zig:10254 | Verifies sig over "OmniBus Exchange Login: <nonce>", consumes nonce, allocates default OMNI balance row. | "loggedIn:true" return is symbolic — there's no session token, no rate-limit binding, no logout. Subsequent calls re-verify per request via signature OR HMAC. Not a real session manager. |
| 10 | `exchange_createApiKey` | ✅ REAL | rpc_server.zig:10301 | ECDSA-gated (sig over `EXCHANGE_APIKEY_V1\n…`), CSPRNG key+secret, SHA256-hashed secret, base64 raw secret for HMAC, journals to `exchange-users.jsonl`. Replayed on startup via `replayUsersJournal`. | None major. |
| 11 | `exchange_listApiKeys` | ✅ REAL | rpc_server.zig:10385 | Walks `ctx.exstate.api_keys[]` filtered by owner; reveals only `secret_hash` (never plaintext). | None. |
| 12 | `exchange_revokeApiKey` | ✅ REAL | rpc_server.zig:10417 | Sig over `EXCHANGE_APIKEY_REVOKE_V1\n…`, owner check, marks revoked, journals. | None. |
| 13 | `exchange_deposit` | 🟡 PARTIAL | rpc_server.zig:10474 | Verifies sig over `EXCHANGE_DEPOSIT_V1\n…`, replay-protected nonce, `balanceCredit` to internal table, journals. **Comment explicitly says "fakes" the credit on testnet** (rpc_server.zig:10470-10473). | This IS the fake/dev path — credits internal balance with NO on-chain TX. The proper path is `exchange_depositReal`. Should arguably be testnet/paper-only. |
| 14 | `exchange_withdraw` | 🟡 PARTIAL | rpc_server.zig:10534 | Paper mode: debit `OMNI_DEMO` internal table. Real mode: builds Transaction { from=owner, to=destination, amount, signature, public_key } and calls `ctx.bc.addTransaction` — **real on-chain TX is created**. Replay-protected nonce. | (a) Sets `tx.hash="pending"` and lets `addTransaction` recompute; assumes that's done. (b) No withdraw confirmation flow / cooldown / 2FA / cold-storage gate — single TX, immediate. (c) No daily withdrawal limit. (d) For real mode, the internal balance table is NOT debited — solely on-chain UTXO is used. Symmetric inconsistency with `exchange_deposit`/`exchange_depositReal`. |
| 15 | `exchange_getBalance` | ✅ REAL | rpc_server.zig:10673 | Real mode: `ctx.bc.getAddressBalance` + `computeReservedFromOrderbook`. Paper: `OMNI_DEMO` internal. | None — single source of truth (UTXO + orderbook-derived reserve). |
| 16 | `exchange_getBalances` | ✅ REAL | rpc_server.zig:10710 | Same as #15, returns array form. Paper walks `_DEMO`-suffixed tokens. | None. |
| 17 | `exchange_depositDemo` | 🟡 PARTIAL | rpc_server.zig:10814 | Per-address rolling 24h quota (max 10/req, 100/24h), credits `OMNI_DEMO`. **No signature required** at all — anyone can request demo for any address. | Address spoofable (no sig). Acceptable for testnet faucet, dangerous if exposed mainnet. |
| 18 | `exchange_depositReal` | ✅ REAL | rpc_server.zig:10895 | Looks up `txid` in chain via `tx_block_height` index (with linear-scan fallback), verifies `tx.from_address == owner`, `tx.to_address == escrow`, `confirmations >= 1`, idempotency via `realDepositTxidUsed`, credits `OMNI` token, journals. | Hardcoded 1 confirmation — should be configurable per token / amount. |
| 19 | `exchange_getEscrowAddress` | 🔴 STUB-ish | rpc_server.zig:10767 | **Returns `ctx.wallet.address`** — i.e. the running node's own wallet, not a dedicated treasury slot. Comment admits "On testnet this is the local node's wallet... On mainnet this would be the dedicated `exchange.omnibus` registrar wallet (slot #1...)". | This is dangerously wrong for mainnet: every node would advertise its own miner wallet as escrow. Must wire `registrar_mod.addressOf(.exchange)` (already used by `applyExchangeFees`). Misleading-by-design until then. |

Also note the bonus method `exchange_listApiKeys` does NOT enforce caller authentication beyond knowing the owner address — anyone can list anyone's keys. Secrets aren't exposed (only hashes), but it leaks ownership / count / lastUsedMs metadata. Marginally PARTIAL but listed REAL above since it doesn't expose secrets.

`exchange_deposit` "STUB" downgrade candidate: comment explicitly says it "fakes the credit on testnet" — leaving on prod RPC would let anyone with their own pubkey self-credit unbounded balance. Currently the only thing stopping that is the in-memory `balance_count` table cap.

Final classification: 8 REAL / 9 PARTIAL / 2 STUB-ish (`exchange_getEscrowAddress`, `exchange_deposit`).

---

## Missing CEX features

Priority key: **P0** = critical correctness/security gap, **P1** = needed for real exchange, **P2** = nice-to-have.

- **P0 — On-chain order TX submission.** `exchange_placeOrder` / `exchange_cancelOrder` build a `tx_hash` but never call `addTransaction`. `applyOrderTxs` (`blockchain.zig:2307`) only runs over chain TXs. Net result: divergent orderbook between RPC node and replaying nodes. Either (a) submit `order_place` TXs into mempool from the RPC handler, or (b) document that the matching engine is intentionally non-canonical / off-chain.
- **P0 — Hardcoded testnet escrow.** `exchange_getEscrowAddress` returns the node's own wallet. Must use `registrar_mod.addressOf(.exchange)` consistently with `applyExchangeFees`.
- **P0 — `exchange_deposit` fake-credit.** Should be disabled outside testnet/paper; currently any signed user can credit the internal `OMNI` (NOT `OMNI_DEMO`) balance table without an on-chain TX.
- **P1 — Order types beyond naive limit.** No market, stop, stop-limit, take-profit, OCO, iceberg, hidden, post-only. No TIF flags (GTC default; no IOC/FOK). Engine signature `placeOrder(Order)` has no flags field — schema change required.
- **P1 — `order_modify` (TxType 0x12) not exposed via RPC.** Only `placeOrder` + `cancelOrder` are wired. No `exchange_replaceOrder` / `exchange_modifyOrder` even though chain TX type exists.
- **P1 — Pair admin RPC.** `EXCHANGE_PAIRS` is compile-time. Need `exchange_addPair` / `exchange_setPairFees` / `exchange_setPairLimits` / `exchange_pausePair`, gated by governance/owner.
- **P1 — Fee tiers (volume-based maker/taker).** Currently `EXCHANGE_FEE_TAKER_BPS=10` / `EXCHANGE_FEE_MAKER_BPS=5` are global constants. No 30-day-volume tiers (Kraken has 9 tiers). No VIP / market-maker discount.
- **P1 — Withdraw confirmation flow.** `exchange_withdraw` real mode is one-shot, no email confirm / TOTP / withdrawal whitelist / 24h cooldown after key rotation / daily aggregate cap. Cold-storage hot-wallet split is absent.
- **P1 — Per-user rate limiting.** No request budget per address / API key. A single attacker can spam `exchange_placeOrder`. The HMAC header path doesn't enforce a token-bucket.
- **P1 — WebSocket trade feed.** Confirmed missing (per task description). `ws_server.zig` exists but exchange-specific `trade`/`book`/`ticker` channels need wiring. Currently clients must poll `getTrades` / `getOrderbook`.
- **P1 — Real KYC integration.** `kyc.zig` provides level enum (`none`/`starter`/`verified`/`pro`) and per-tier notional caps in `kycMaxNotionalMicro`, but on-chain attestation is the only source. No Sumsub / Onfido / Persona integration. Acceptable for a sovereign chain, but not "real CEX" parity.
- **P2 — Cross-asset / multi-pair atomic settlement.** `Order` has one `pair_id`. No basket orders, no triangular arb routing, no swap-style cross-asset fills. `MatchingEngine` is per-pair-segregated within one global `bids[]`/`asks[]` array.
- **P2 — Margin / leverage / perpetuals.** Zero presence in code. No funding rate, no liquidation engine, no isolated/cross-margin accounting.
- **P2 — Order book depth aggregation.** `getOrderbook` returns raw orders, not L2 (price-aggregated) or L3 streams. Real CEXs offer aggregation tiers.
- **P2 — Closed order history.** `getUserOrders` only walks active books. No `getClosedOrders` / `getOrderHistory` from journal — `orders.jsonl` exists with `place`/`cancel`/`fill` events but isn't queryable.
- **P2 — Trade history full archive.** `trade_log[]` is 256-entry ring. Older trades require journal scan.
- **P2 — Self-trade prevention flag.** Self-trade explicitly allowed per founder request 2026-04-28 (rpc_server.zig:8723); but most CEXs offer optional STP modes (DC/CO/CN/CB).
- **P2 — Treasury collection accounting reporting RPC.** Fees ARE collected via `applyExchangeFees` to `registrar.exchange`, but no `exchange_getTreasuryStats` endpoint surfaces totals. Auditors must scan chain.
- **P2 — Network fee routing to miner.** TODO at `blockchain.zig:709`: network fee currently goes to treasury, not block miner. Real chain economics require it routed to the miner who included the fill.

---

## Recommended next implementation order

Ranked by ROI = (security/correctness impact) × (implementation cost inverse) × (user-visible value):

1. **Fix `exchange_getEscrowAddress` to use `registrar.exchange` slot** — 1-line fix, stops the "every node advertises miner wallet" disaster path. Touches one function, plus tests. 30 min.
2. **Wire `exchange_placeOrder` / `exchange_cancelOrder` to actually submit `order_place` / `order_cancel` chain TXs** — closes the determinism gap so `applyOrderTxs` is the single source of truth. The infrastructure (TxType, `tx_payload.OrderPlacePayload`, `applyOrderTxs`) already exists; just need to build the TX in the RPC handler, sign with HMAC bypass or pass the user's sig through, and hand to mempool. ~1 day. **This is the single biggest correctness win.**
3. **Restrict `exchange_deposit` to testnet only OR delete it** — collapses one entire fake-credit path; users still have `exchange_depositDemo` (rate-limited) and `exchange_depositReal` (chain-verified). 2 hours.
4. **Add TIF (GTC/IOC/FOK) + market orders to matching engine** — adds a flags field to `Order`, modifies `matchOrder` to early-return when flag dictates; unblocks any non-toy trading client. ~half-day.
5. **Pair-admin RPC + persisted pair table** — moves `EXCHANGE_PAIRS` from compile-time to runtime config persisted in `data/<chain>/pairs.json`, gated by governance signature. Without this, every new pair requires a recompile + redeploy. ~1 day.

Items 1–3 are in scope of "fix what's already there"; items 4–5 are the smallest steps toward real CEX parity. Margin / WS feed / fee tiers come after.

---

## Out-of-scope notes

- The `tools/inventory-scan.py --json` was not run during this audit because the Bash/PowerShell tools were sandbox-blocked for me in this session. The 19 RPC methods were instead enumerated directly from the dispatcher table at `core/rpc_server.zig:2938-2956` — that is the authoritative source for what's actually wired. If a method exists in code but isn't in the dispatcher, it isn't reachable; if a method is in the dispatcher, it's audited above. Re-running inventory-scan after this audit is recommended to cross-check.
- I did NOT modify any code or commit anything, per task instructions.
