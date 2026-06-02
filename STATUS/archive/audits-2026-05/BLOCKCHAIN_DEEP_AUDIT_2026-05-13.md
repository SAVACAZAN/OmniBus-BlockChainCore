# BlockChainCore Deep Audit — 2026-05-13

Audit complet în 3 părți: **toate RPC endpoint-urile**, **stiva DEX completă**, **runtime agenți AI**.

---

## PARTEA 1 — RPC ENDPOINTS (130+ metode)

### Distribuție status

| Status | Count | % |
|--------|-------|----|
| **REAL** — citește/scrie state real | 110 | 85% |
| **PARTIAL** — TODO sau limitări | 10 | 8% |
| **MOCK** — placeholder hardcoded | 5 | 4% |
| **ERROR** — întoarce -32xxx explicit | 5 | 3% |

### Top 10 RPCs de reparat

1. `handleGetMiningInfo` — hashrate hardcoded `1000` când metrics nu sunt attached
2. `handleOmnibusPrices` — PARTIAL: fallback empty array dacă oracle unavailable
3. `handleExchangeDepositDemo` — paper trading, neintegrat cu real exchange
4. `handleGetAgent` — MOCK: returnează null
5. `eth_sendRawTransaction` — ERROR explicit `-32004` (by design)
6. `eth_call` — PARTIAL EVM simulation
7. `ns_expiringSoon` — TODO reindex
8. `ns_pruneExpired` — wired în mining loop ✅ (fix aplicat astăzi)
9. `generatewallet` — ERROR by design ("use CLI")
10. `handleGridStatus` — calculus dependent pe memory state

### Categorii complete (REAL)
- **Blockchain core** (8): getblockcount, getblock, getblockchaininfo, etc.
- **Wallet** (10): getbalance, getwalletsummary, listunspent
- **Staking** (10): stake, unstake, validators
- **DNS/ENS** (16): registername, resolvename, transfername
- **DEX/Exchange** (25): orderbook, matching, API keys
- **HTLC/swap** (6+9): full lifecycle
- **Identity** (14): DID, OBM, facets, KYC
- **Bridge** (10): cross-chain locks, SPV verify

**Concluzie RPC**: ~85% REAL, sistemul e production-ready pe RPC layer. Singurele găuri reale sunt 5 itemi minori (hashrate placeholder, ns reindex, paper deposit).

---

## PARTEA 2 — DEX STACK (memorie vs cod)

### ✅ Complet implementat
- Matching engine determinist (986 LOC, price-time priority)
- Grid engine (627 LOC, persistence binary + JSON)
- 24 RPCs DEX: `exchange_*` (18) + `grid_*` (4) + `htlc_*` (5)
- HTLC OmniBus state machine cu registry persistent
- Paper mode toggle (2 engines izolate)
- Auth: nonce + login + API keys + KYC
- Multi-chain routing (ASSET_CHAINS, htlcContractFor)

### 🟡 PARȚIAL — gap-uri reale
| Feature | Issue |
|---------|-------|
| **Grid auto-tick** | `tick()` există dar **NU e apelat** în mining loop. Grid-urile sunt vizibile dar nu execută |
| **HTLC trigger la fill** | `exchange_placeOrder` **NU apelează** `htlc_init` automat pe cross-chain fills |
| **Treasury agent operational** | `treasury_agent.zig` există ca design, dar **NU e thread-spawned** din main.zig |
| **ERC-20 HTLC contract** | `OmnibusHTLC.sol` doar ETH (msg.value). `lockToken()` lipsește pentru USDC/LCX |
| **Pair_id 7-9** | OMNI/SOL/EURC/XRP în EXCHANGE_PAIRS dar **fără routing** în order_swap_link.zig |

### ❌ Lipsă completă
- Grid follow-orders auto-placement după fill
- Consensus price oracle (mineri broadcast price, median 2/3)
- HTLC ERC-20 deploy pe Base Sepolia

### 🔴 Recomandări prioritate DEX (8-10h muncă)
1. **CRITIC** (1-2h) — Wire `grid_mod.tick()` în mining loop
2. **CRITIC** (3-4h) — Auto-HTLC la cross-chain fill în `exchange_placeOrder`
3. **HIGH** (2-3h) — Spawn treasury_agent runtime în main.zig
4. **HIGH** (2-3h + audit) — Deploy HTLC ERC-20 contract pe Sepolia + Base
5. **MEDIUM** (1h) — Clarifică pair_id 7-9 (listed sau disabled)

---

## PARTEA 3 — AGENT RUNTIME

### Ce trebuiau să facă (viziune originală)
- Executori de **smart-contracts JSON** (format OpenAI-readable, nu Solidity)
- **Treasury autonom**: agenți NS/ENS/Exchange/Faucet nu pot extrage bani, doar plasează grid orders
- **Market makers** pe arbitraj + LP
- **Scalare per-founder**: Alex = creator, useri co-operatori la tieruri inferioare

### Ce fac efectiv

| Modul | LOC | Tests | Status | Wired |
|-------|-----|-------|--------|-------|
| `agent_executor.zig` | 433 | 9 | COMPLETE | ✅ tick/block |
| `agent_manager.zig` | 596 | 13 | COMPLETE | ✅ |
| `agent_config.zig` | 421 | 7 | COMPLETE | ✅ JSON parser |
| `agent_tier.zig` | 152 | 6 | COMPLETE | ✅ |
| `agent_wallet.zig` | 97 | 4 | COMPLETE | ✅ BIP-44 m/44'/777' |
| `agents_main.zig` | 134 | 0 | STUB | ❌ daemon placeholder |
| `treasury_agent.zig` | 200+ | 0 | DESIGN ONLY | ❌ neintegrat |

- **39 teste unit** toate pass
- **Mining loop integration** ✅ (agentTickAll fiecare bloc)
- **Decision routing**: native via mempool TX (acum cu **stake/unstake real** după fix-ul azi), external via RPC queue

### Lipsuri tactice (nu strategic)
- `agent_register/edit` RPC handlers — placeholders, nu mutează managerul real
- `treasury_agent` design bun, dar nu spawn-uit
- LP per-agent — decision există, dar `.provide_liquidity` nu e implementat în `submitNativeTx`
- Multi-source oracle (Chainlink/Pyth) nu wired

### Verdict: **KEEP + REWORK (HIGH PRIORITY)**

**Motivație**:
1. Aliniat 100% cu viziunea JSON-smart-contracts (executori AI cu reguli deterministe)
2. Production-ready core (39 teste, RPC complet, mining loop wired)
3. Incomplete = **tactical** (1-2h wire-up pentru treasury, 1.5h LP handler), **nu strategic** (deadweight)
4. Cost mentenanță minimal
5. Pierdere prin kill: tier progression + treasury autonomy + market-making leverage

**Plan rework (5-7h, 2-3 sesiuni)**:
1. Treasury agent wire-up (2h) — spawn în mining loop, RPCs grid_*
2. LP handler completare (1.5h) — `.provide_liquidity` end-to-end
3. External client example Python (1.5h) — consume `agent_pending_decisions`
4. Docs `AGENT_RUNTIME.md` (1h)

---

## CONCLUZIE COMBINATĂ

**Stadiu BlockChainCore (2026-05-13)**:
- ✅ RPC layer ~85% real (top 10 itemi minori de polish)
- 🟡 DEX engine completă, dar **3 punți critice lipsă**: grid auto-tick, auto-HTLC la fill, treasury runtime
- ✅ Agent runtime 80% complet, viziune intactă, completion straightforward

**Total muncă rămasă pentru "produs final"**: **15-20h**, în 3-5 sesiuni:
- DEX 3 itemi critici (8-10h)
- Agent runtime rework (5-7h)
- RPC polish top 10 (2-3h)

**Ce funcționează LIVE acum** (pe testnet):
- Toate RPC core, wallet, mining, staking, DNS, identity
- Order placement (paper + real)
- HTLC OmniBus side
- Grid create/list/cancel/status (statice, fără execuție automată)

**Ce e BLOCAT pe testnet**:
- Grid orders rămân stuck (`tick()` nu rulează)
- Cross-chain fills nu generează HTLC automat
- USDC/LCX swaps fail (ERC-20 contract lipsă)
- Treasury sta idle (agent neactiv)
