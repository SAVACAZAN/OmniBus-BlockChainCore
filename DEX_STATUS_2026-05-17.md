# OmniBus DEX — Status Recap (2026-05-17)

> Snapshot al stării reale după sesiunile 2026-05-14 → 2026-05-17.
> Sursă autoritativă pentru adrese: [`evm/deployed_addresses.json`](evm/deployed_addresses.json).
> Pentru spec arhitectural: [`DEX_GRID_SPEC.md`](DEX_GRID_SPEC.md).

## 1. Contracte live (6 chains)

Toate cu **același operator** `0xA66235662c363e9915b6353f79df309F67D146A6`
(slot 2 din founder mnemonic — `exchange.omnibus` registrar slot).

| Chain | chain_id | OmnibusDEX address | Deployed |
|---|---|---|---|
| Sepolia | 11155111 | `0xC21fD92e5f568a7981d16b9008E3C190842818aE` | 2026-05-15 |
| Base Sepolia | 84532 | `0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB` | 2026-05-15 |
| Arb Sepolia | 421614 | `0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB` | 2026-05-16 |
| OP Sepolia | 11155420 | `0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB` | 2026-05-16 |
| Soneium Minato | 1946 | `0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB` | 2026-05-16 |
| LCX Liberty | 76847801 | `0xE4a3965C4B5205D28259D1CC82fD54060B0bCd19` | 2026-05-16 |

Address CREATE-deterministic (nonce 0 al deployer-ului `0xc5A63d78...C938`)
identic pe 5 chains. Sepolia + Liberty diferite (deployer cu nonce != 0 atunci).

## 2. Pairs configurate

| pair_id | Pereche | Chains active | Status e2e |
|---|---|---|---|
| 0 | OMNI/USDC | Sepolia, Base | ✅ trade live 2026-05-15 |
| 1 | OMNI/EURC | Sepolia, Base | binding OK, netestat |
| 6 | OMNI/ETH | Sepolia, Base, Arb, OP, Minato, Liberty | ✅ trade live 5 chains |
| 7 | OMNI/LINK | Sepolia, Base, Arb, OP | ⚠️ blocat (vezi §5) |

Pairs `2` LCX/USDC, `3` ETH/USDC, `4` OMNI/BTC, `5` OMNI/LCX — rezervate, nu sunt active.

## 3. Token whitelist (anti-fake-token)

Hardcoded in [`core/token_whitelist.zig`](core/token_whitelist.zig). Escrow EVM
respins dacă `(pair_id, chain_id, token_addr)` nu e în listă. Conține:

- USDC (Circle official) pe 6 chains
- EURC (Circle) pe 2 chains
- ETH native pe 8 chains (sentinel `token=0x0`)
- LINK (Chainlink) pe 7 chains (4 cu DEX, 3 pregătite pt deploy viitor)

## 4. Fluxul de trade (Hyperliquid-style escrow)

```
1. Buyer locks ERC-20 → OmnibusDEX.placeBuyOrder() pe chain EVM
2. evm_escrow_watcher (Zig) vede OrderPlaced event → notează în RAM
3. Buyer face exchange_placeOrder cu evmOrderId → engine cross
4. Seller face exchange_placeOrder cu sellerEvm → engine cross
5. matching_engine produce Fill → fills_log.bin (224-byte records)
6. dex_settler (Zig thread) → settle(orderId, sellerEvm) pe chain EVM
7. Contract trimite ERC-20 către seller, OMNI deja mutat intern
```

Nu e HTLC — nu există preimage / refund branch. Single-call settle. Refund
prin `cancelOrder` (owner) sau `expireRefund` (anyone, după expiresAt).

## 5. Bug deschis — pair 7 LINK fill #14

**Order**: `1778969273121603` pe Sepolia (1 LINK lockat din slot 6).
**Stare**: `state=1 (open)` pe-chain. OMNI deja mutat intern în engine.
**Cauză**: nodul testnet rulează cu dev mnemonic (`abandon abandon...`).
Slot 2 al dev mnemonic = `0xb6716976a3ebe8d39aceb04372f22ff8e6802d7a`
≠ operator-ul contractelor (`0xA662...`). Orice `settle()` → revert `NotOperator()`.

3 opțiuni de fix (vezi sesiunea 2026-05-17):
- A: Repornit nodul cu founder mnemonic (cea mai simplă)
- B: Redeploy contracte cu operator = testnet slot 2 (split mainnet/testnet curat)
- C: Settle manual din ethers + documentat split-ul

## 6. Fixes aplicate azi (2026-05-17)

| Fișier | Schimbare |
|---|---|
| `core/token_whitelist.zig` | + LINK pe Sepolia/Base/Arb/OP/Fuji/BNB/Gnosis, pair_id=7 entries |
| `core/main.zig` | + 4 settler bindings pair 7 (bindings[12..16]) |
| `core/rpc_server.zig:12779` | Guard `omni_evm_pair` include pair_id=7 (SELL→sellerEvm obligat, BUY→evmOrderId obligat) |
| `core/dex_settler.zig:158` | Refuză avansare cursor dacă `seller_evm=0 && evm_order_id!=0` (era leak silențios — cf. fill #13) |
| `core/evm_rpc_client.zig:95` | Log primele 300 chars din body la RPC error (debug-ability) |
| `core/dex_settler.zig:280` | Log operator address în submitSettle START |
| `evm/deploy/sell_link.js`, `buy_link_match.js`, `cancel_link_order.js`, `probe_settle.js`, `settle_link_manual.js`, `bridge_to_scroll.js` | scripturi noi pt pair 7 e2e |

## 7. Pending (notat pt sesiunea următoare)

### Deploy chains încă neacoperite
- Polygon Amoy 80002 — await MATIC faucet pe slot 6
- Avalanche Fuji 43113 — await AVAX faucet pe slot 6
- BNB Testnet 97 — LINK whitelisted, no DEX
- Gnosis Chiado 10200 — LINK whitelisted, no DEX
- Scroll Sepolia 534351 — bridge ETH în curs (`0x323feb89...`), DEX TBD
- Arc Testnet — necesită USDC pt gas
- Abstract, Humanity, Shape, WEMIX, ZKsync — chains noted, faucet/bridge needed

### Bug-uri cunoscute
- **Settler cursor restart** — pierde fills RAM-only la repornire (cursor persistă, fills nu)
- **Watcher cursor head+1** — pierde events post-restart dacă chain head a avansat
- **Node stability cu 6 chains watcher** — crash random după 5-10 min uptime
- **Testnet vs mainnet operator split** — vezi §5

### Bridge Sepolia → L2
Adresa `0xc5A63d78...C938` poate primi ETH prin bridge oficial pe:
- Base, Arb, OP, Minato, Liberty — scripts existente în `evm/deploy/bridge_to_*.js`

## 8. Scripturi de audit/raport/test disponibile

Vezi [`TOOLS_INDEX.md`](TOOLS_INDEX.md) pt index complet (~100 scripturi Python).

Pentru DEX, cele mai relevante:
- `scripts/cross/omnibus-dashboard.py` — dashboard text live (block height, peers, mempool)
- `scripts/cross/unified-health-check.py` — health BlockChainCore + aweb3 → JSON
- `scripts/cross/sync-deployments.py` — sync adrese contracte între repo-uri
- `tools/MONITORING/node-status-monitor.py` — poll RPC, afișează status
- `tools/audit-pq-conventions.py` — audit convenții PQ scheme/prefix
- `tools/inventory-scan.py` — count operations, TX types, schemes, RPC methods
- `tools/SECURITY/crypto-audit.py` — audit implementări crypto din `core/`

## 9. Comenzi rapide

```bash
# Pornire nod testnet (PC, sync cu VPS)
./zig-out/bin/omnibus-node.exe --mode miner --node-id pc-miner --port 9002 \
  --seed-host 38.143.19.97 --seed-port 9001 --testnet

# Verificare order EVM
cd evm/deploy && node check_link_order.js   # editează orderId în fișier

# Verificare LINK balance pe toate chains
node check_link_all2.js

# Health check rapid
python scripts/cross/unified-health-check.py

# Dashboard live
python scripts/cross/omnibus-dashboard.py
```
