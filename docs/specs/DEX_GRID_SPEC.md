# OmniBus DEX — Grid Trading Specification

> **Acest fișier este sursa de adevăr pentru DEX + Grid.**
> Nu se rediscută arhitectura de bază. Se extinde doar cu implementări noi.

## 1. Principii fundamentale

### OmniBus ca matching engine și notary

- OmniBus chain = **matching engine** (Zig, on-chain) + **notary** (înregistrează swap-urile)
- OmniBus NU stochează fondurile userilor — fondurile stau mereu pe chain-ul lor
- Settlement = HTLC atomic cross-chain (nu custodial, nu trust)

### Surse de preț

1. **Trade intern** — doi useri se întâlnesc în orderbook → prețul fill-ului devine "last price"
2. **Oracle extern** — `price_oracle.zig` fetches preț real (CoinGecko / Chainlink / Pyth)

Oracle-ul nu execută trades — doar informează grid-ul la ce preț să activeze orders.

---

## 2. Perechi (pair_id fix — append-only, niciodată reordonat)

| pair_id | Pereche | Maker asset | Maker chain | Taker asset | Taker chains |
|---------|---------|-------------|-------------|-------------|--------------|
| 0 | OMNI/USDC | OMNI | OmniBus native | USDC | Sepolia, Base Sepolia |
| 1 | OMNI/EURC | OMNI | OmniBus native | EURC | Sepolia, Base Sepolia |
| 2 | LCX/USDC | LCX | LCX Liberty | USDC | (rezervat) |
| 3 | ETH/USDC | ETH | Sepolia, Base | USDC | (rezervat) |
| 4 | OMNI/BTC | OMNI | OmniBus native | BTC | (rezervat) |
| 5 | OMNI/LCX | OMNI | OmniBus native | LCX | (rezervat) |
| 6 | OMNI/ETH | OMNI | OmniBus native | ETH | Sepolia, Base, Arb, OP, Minato, Liberty |
| 7 | OMNI/LINK | OMNI | OmniBus native | LINK | Sepolia, Base, Arb, OP |

> **Update 2026-05-17:** flow real e Hyperliquid-style escrow (single
> `settle()` call de la operator), NU HTLC cu preimage. Vezi
> [`DEX_STATUS_2026-05-17.md`](DEX_STATUS_2026-05-17.md) §4.

**Contracte OmnibusDEX deployate (operator unic `0xA662...46A6`):**
- Sepolia 11155111: `0xC21fD92e5f568a7981d16b9008E3C190842818aE`
- Base Sepolia 84532: `0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB`
- Arb Sepolia 421614: `0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB`
- OP Sepolia 11155420: `0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB`
- Soneium Minato 1946: `0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB`
- LCX Liberty 76847801: `0xE4a3965C4B5205D28259D1CC82fD54060B0bCd19`

Sursă autoritativă: [`evm/deployed_addresses.json`](evm/deployed_addresses.json).

**Contracte HTLC (legacy, doar pt ETH cross-chain experimental):**
- Sepolia: `0xC95cAED3179B8D2899acAC193411CC65759cEC81` (`OmnibusHTLC`)

---

## 3. HTLC — reguli fixe

```
preimage  = random 32 bytes generat în Zig backend (NICIODATĂ în frontend)
hash_lock = SHA256(preimage)
```

**Cine știe preimage-ul:**
- Zig backend (stocat în swap_registry + swap_bindings.bin)
- Revelat on-chain DOAR la momentul claim-ului (devine public)
- Userul NU primește preimage — primește doar hash_lock pentru a face lockToken pe EVM

**Momentul HTLC:**
- Order plasat → NU se creează HTLC (order e "rezervat" intern)
- Fill trigger → HTLC creat automat în Zig
- Preimage revelat automat după confirmarea ambelor legs

**State machine per swap:**
```
pending → both_locked → claimed
    ↓           ↓
 timeout     timeout
    └─────────→ timed_out (ambii refund)
```

---

## 4. Grid Engine — `core/grid_engine.zig`

### GridConfig (stocat on-chain + persist în grid_registry.bin)

```zig
pub const GridConfig = struct {
    id:           u64,        // auto-increment
    owner:        [64]u8,     // adresă OmniBus (ob1q...)
    owner_len:    u8,
    pair_id:      u16,
    price_low:    u64,        // micro-USD, 6 decimale (ex: 100000 = $0.10)
    price_high:   u64,        // micro-USD
    levels:       u16,        // câte levels pe fiecare parte (max 100)
    total_base:   u64,        // cantitate asset BASE disponibil (satoshi/wei)
    total_quote:  u64,        // cantitate asset QUOTE disponibil (micro-USD)
    filled_count: u32,        // câte fills s-au făcut
    profit_quote: i64,        // profit acumulat în quote asset
    active:       bool,
    created_block: u64,
};
```

### Generare levels

```
price_step = (price_high - price_low) / (levels * 2)

buy levels:  price_low, price_low + step, ..., price_mid - step
sell levels: price_mid, price_mid + step, ..., price_high

Exemplu: range $0.10-$0.20, 10 levels:
  step = $0.005
  buy:  0.100, 0.105, 0.110, 0.115, 0.120, 0.125, 0.130, 0.135, 0.140, 0.145
  sell: 0.150, 0.155, 0.160, 0.165, 0.170, 0.175, 0.180, 0.185, 0.190, 0.195
```

### Flow fill automat

```
La fiecare bloc, grid_engine.tick(current_price):
  1. Pentru fiecare grid activ:
     a. Verifică dacă oracle_price atinge un nivel
     b. Dacă DA → trigger fill pentru acel nivel
     c. Fill = matching_engine.fill(buy_order, sell_order)
     d. HTLC generat automat pentru fill
     e. Plasează automat order opus:
        - sell filled @ P → plasează buy @ P - step
        - buy filled @ P  → plasează sell @ P + step
     f. Actualizează filled_count + profit_quote
```

### Sursa de preț pentru trigger

```
oracle_price = price_oracle.getLastPrice(pair_id)
  → dacă oracle_price >= sell_level → fill sell
  → dacă oracle_price <= buy_level  → fill buy
  → dacă există counterparty order în orderbook la același preț → fill imediat
```

---

## 5. RPC-uri Grid

### `grid_create`
```json
Request:  { "pair_id": 0, "price_low": 100000, "price_high": 200000,
            "levels": 10, "total_base": 500000000, "total_quote": 500000000,
            "owner": "ob1q..." }
Response: { "grid_id": 42, "levels_generated": 20, "buy_orders": 10, "sell_orders": 10 }
```

### `grid_list`
```json
Request:  { "owner": "ob1q..." }   // opțional, fără owner = toate
Response: [{ "grid_id": 42, "pair": "OMNI/USDC", "active": true,
             "filled_count": 7, "profit_quote": 350000,
             "open_buys": 9, "open_sells": 10 }]
```

### `grid_status`
```json
Request:  { "grid_id": 42 }
Response: { "grid_id": 42, "pair_id": 0, "price_low": 100000, "price_high": 200000,
            "levels": 10, "active": true, "filled_count": 7,
            "profit_quote": 350000,
            "open_orders": [{ "side": "buy", "price": 145000, "amount": 50000000 }, ...] }
```

### `grid_cancel`
```json
Request:  { "grid_id": 42, "owner": "ob1q..." }
Response: { "grid_id": 42, "cancelled": true, "orders_removed": 13 }
```

---

## 6. Orderbook display — status orders

Fiecare order în orderbook are:
```
status: "open"     = plasat, în așteptare match
        "filled"   = matched + HTLC settled + fonduri mutate
        "refunded" = timeout HTLC, fonduri returnate
        "grid"     = generat de grid engine (label vizual)
```

Frontend afișează:
- Coloana `Type`: `grid` sau `manual`
- Coloana `Status`: `open` / `filled` / `refunded`
- Timestamp fill + chain pe care s-a executat

---

## 7. Capital efficiency

```
Grid cu 10 levels, total 100 USDC + 100 OMNI:

La crearea grid-ului:
  → 0 HTLC-uri deschise
  → 0 fonduri locked
  → 20 orders "virtuale" în orderbook

La primul fill:
  → 1 HTLC deschis (10 USDC + echivalentul în OMNI)
  → fill automat
  → HTLC closed
  → order opus plasat automat

Maximum la orice moment: 1 HTLC activ per grid
```

Comparativ cu "HTLC per order":
- 20 orders → 1 HTLC (noi) vs 20 HTLC-uri (naive)
- Fee-uri: 1 TX per fill vs 20 TX-uri upfront

---

## 8. Scenariul cu 2 useri — bootstrap lichiditate

```
User A (founder/market maker):
  grid OMNI/USDC, range $0.10-$0.20, 10 levels
  buy:  0.100 ... 0.145  (10 orders)
  sell: 0.150 ... 0.195  (10 orders)

User B:
  grid OMNI/USDC, range $0.11-$0.19, 8 levels  
  buy:  0.110 ... 0.145  (8 orders)
  sell: 0.150 ... 0.185  (8 orders)

Overlap: sell @ 0.150 (A) + buy @ 0.150 (B) → FILL IMEDIAT
  → A primește USDC pe Base Sepolia
  → B primește OMNI pe OmniBus
  → ambii grids se rebalansează automat
  → next fill când oracle ajunge la 0.155
```

---

## 9. Fișiere implementare

| Fișier | Status | Rol |
|--------|--------|-----|
| `core/grid_engine.zig` | **TODO** | Engine principal grid |
| `core/matching_engine.zig` | DONE | Matching orders — grid e wrapper |
| `core/price_oracle.zig` | DONE | Preț oracle extern |
| `core/order_swap_link.zig` | DONE | HTLC routing + ASSET_CHAINS |
| `core/rpc_server.zig` | DONE + extend | Adaugă grid_create/list/cancel/status |
| `core/main.zig` | DONE + extend | Inițializează grid_engine, tick per bloc |
| `frontend/src/components/GridPanel.tsx` | **TODO** | UI configurare grid |

---

## 10. Regulă generală DEX

> **Orice tranzacție între doi useri pe perechi diferite (ETH/USDC, LCX/USDC, OMNI/ETH etc.)
> folosește OmniBus chain DOAR ca matching engine și notary.
> Fondurile se mișcă direct între walletele userilor via HTLC atomic swap.
> Nu există deposit. Nu există withdrawal. Nu există custody.**
