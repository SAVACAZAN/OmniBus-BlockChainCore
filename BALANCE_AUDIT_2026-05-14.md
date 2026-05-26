# Balance Consistency Audit — 2026-05-14

Auditat de la chain (Zig) până la UI, peste toate layerele.

---

## REZUMAT VERDICT

| Layer | Status |
|-------|--------|
| **Chain (Zig)** | ✅ FUNCȚIONAL — `utxo_set` e canonical, toate RPC-urile derivă din el |
| **RPC** | ✅ CONSISTENT — `getbalance/getaddressbalance/getwalletsummary/listunspent` returnează același număr |
| **CLI** | ✅ CONSISTENT — consumă RPC, nu există surse paralele |
| **Frontend** | 🟡 INCONSISTENT — 6 corecte / 2 partial / 6 greșite |

**Adevăr canonical pe chain**:
- Wallet balance = `bc.utxo_set.getBalance(addr)` (sum UTXOs)
- Staked = `bc.stake_amounts.get(addr)` (separat)
- In orders = sum sell orders deschise (calculat live în RPC)
- Available = wallet - staked - in_orders

---

## BACKEND (Zig + RPC + CLI)

### Surse de balance în chain

| Câmp | Rol | Stare |
|------|-----|-------|
| `utxo_set` | **CANONIC** wallet balance | ✅ |
| `bc.balances` (StringHashMap) | Cache legacy în RAM | 🟡 Pe cale de deprecare (Phase C.5) |
| `stake_amounts` | Sum stake (separat de wallet) | ✅ |
| `stake_meta` | Lock metadata (started_at_block + lock_blocks) | ✅ Nou |
| `chainstate KV` | Snapshot persistat | 🟡 Dual-write pentru validare |
| `exchange_state.balances` | Sub-ledger paper mode | ✅ By design separat |
| `wallet.balance` (wallet.zig) | Local computed | ⚠️ Nu se sincronizează auto |

### RPC handlers — toate consistente

| RPC | Source | Returns |
|-----|--------|---------|
| `getbalance` | `utxo_set.getBalance()` | wallet SAT |
| `getaddressbalance` | `utxo_set.getBalance()` | wallet SAT + OMNI |
| `getwalletsummary` | `utxo_set` + `stake_amounts` + sell orders | **ATOMIC**: wallet/staked/orders/available |
| `listunspent` | `utxo_set.address_index` | array UTXO |
| `getrichlist` | `utxo_set` iterate | top N |
| `getstake` | `stake_amounts.get()` | sum per address |
| `getstakers` | `stake_amounts.iterator()` | top stakers |
| `exchange_getBalances` | `exstate.balances[]` | **paper-mode only, separat** |

### Verdict backend: ✅ CONSISTENT
- Toate RPC-urile mainstream **citesc același UTXO set**
- `getwalletsummary` e cel **mai complet** (atomic snapshot cu mutex)
- Singura divergență: `bc.balances` cache poate rămâne în urmă, **dar nu e folosit de niciun RPC user-facing** (doar log [AUDIT-DIVERGE])
- Phantom writes (outside `in_apply_block`) sunt detectate prin counter `stray_balance_writes`

### CLI (`cli_audit.zig`)
- ✅ Folosește RPC HTTP, nu accesează chain in-process
- Singura sursă oficială pe care o consumă: `getwalletsummary` + `getstake`

---

## FRONTEND (React/TypeScript)

### Distribuție
- ✅ **CORECT**: 6 (WalletPage, ExchangePage header, MultiWalletBalances, GlobalBalancePill, TreasuryPanel, FaucetPage)
- 🟡 **PARTIAL**: 2 (PlaceOrderForm, AgentsPage)
- ❌ **GREȘIT**: 6 (QuickSendDialog, BalancesPanel, StakePage, MultisigPanel, ColdWalletPanel + alte)

### Top 3 de fixat imediat

1. **StakePage.tsx** — critical path. Folosește `getbalance()` + `getstake()` direct, nu `useGlobalBalance()`. Funcționează corect azi (din coincidență), dar nu respectă `useActiveSlot()`. Fix: înlocuiește cu `useGlobalBalance()`.

2. **QuickSendDialog.tsx** — userul trimite OMNI direct din dialog dar vede `wallet` total, NU `available`. Dacă are stake, poate să trimită mai mult decât are liber → eroare la submit. Fix: arată `available_sat` din `useGlobalBalance()`.

3. **BalancesPanel.tsx** (Exchange) — folosește `exchange_getBalances` (paper mode sub-ledger) + `getbalance` direct, dar **nu vede stake/orders**. Userul vede balance diferit în Exchange tab vs Wallet tab pentru aceeași adresă. Fix: integrează `useGlobalBalance()` în panel.

### Top 3 corecte (referință)

1. **WalletPage.tsx** — folosește `useAllSlotsBalance()` + `useGlobalBalance()` → afișează wallet/staked/orders/available + tabel per-slot
2. **GlobalBalancePill.tsx** — chip de Header cu `useGlobalBalance()`, sincron cu toate paginile
3. **MultiWalletBalances.tsx** — fetch `getwalletsummary` per slot (după fix-ul de azi)

---

## Recomandări prioritate

### 🔴 IMMEDIATE (frontend, ~1-2h)
1. Înlocuiește `getBalance()` direct cu `useGlobalBalance()` în:
   - `QuickSendDialog.tsx`
   - `BalancesPanel.tsx`
   - `StakePage.tsx` (StakeNewTab)
   - `MultisigPanel.tsx`
2. AgentsPage: invalidează cache la `refreshGlobalBalance()`
3. PlaceOrderForm: arată context staked/in_orders deasupra formular

### 🟡 SHORT-TERM (backend Zig, ~1h)
1. **Phase C.5**: șterge `Blockchain.balances` cache (legacy). Tot codul citește deja `utxo_set`, dar cache-ul produce [AUDIT-DIVERGE] noise.
2. Strict mode pentru `in_apply_block`: `@panic()` în debug, log în production.

### 🟢 MEDIUM-TERM
1. Documentează clar pe site: paper-mode `exchange_getBalances` e separat — nu confuza cu wallet balance.
2. Wallet.balance (în `wallet.zig`) → polling de la `getwalletsummary` la fiecare 8s.

---

## Concluzie

**Backend (Zig)**: **NU sunt bug-uri serioase**. `utxo_set` e source of truth, toate RPC-urile derivă consistent. Singurele "frecușuri" sunt:
- `bc.balances` cache (cosmetic, planificat de șters)
- Phantom writes (rare, detectate, logate)
- exchange paper ledger (by design separat)

**Frontend**: **Bug-uri reale** — pages folosesc RPC-uri diferite cu interpretări diferite ale balance-ului. Există hook unificat (`useGlobalBalance`, `useAllSlotsBalance`) — trebuie folosit consistent peste tot.

**Decizia ta**: 6 fix-uri frontend pentru consistency totală. Pot ataca toate în următoarele 1-2h dacă vrei.
