# Plan Fix-uri OmniBus BlockChainCore

**Data:** 2026-03-30 | **Branch:** feat/frontend-mempool-miners-tx

---

## CRITICE (crash/data corruption)

### F1. Segfault sub heavy load — RPC thread stack overflow
- **Simptom:** Node crashează după 1000+ TX-uri rapide (3x paralel)
- **Cauză:** `handleMinerSt` alocă ~80KB pe stack (MinerEntry array + RegisteredMiner copy + 32KB buffer) pe thread-uri cu 1MB stack
- **Fix:** Mut arrays pe heap (allocator) sau procesez mining stats pe main thread cu mutex, nu pe fiecare RPC thread
- **Fișiere:** `core/rpc_server.zig` (handleMinerSt, handleConnCounted)

### F2. Address derivation JS ≠ Zig (hex vs Base58)
- **Simptom:** Adresele generate de Node.js (`ob_omni_5ddb63d7...` hex) nu corespund cu Zig (`ob_omni_YyWLQndt...` Base58)
- **Cauză:** JS face SHA256→hex, Zig face BIP32→secp256k1→RIPEMD160→Base58Check
- **Fix:** Implementare Base58Check în JS identic cu Zig (sau: Zig CLI tool `omnibus-node --generate-wallet` care printează adresa și iese)
- **Fișiere:** `scripts/start-simulated.js`, nou: `core/cli.zig` (--generate-wallet flag)

### F3. P2P inbound recv broken pe Windows
- **Simptom:** `error.Unexpected` pe `stream.read()` la conexiuni TCP inbound (accept)
- **Cauză:** Zig std `ReadFile` nu merge pe socket-uri acceptate pe Windows — trebuie `ws2_32.recv`
- **Fix:** Același fix ca ws_server.zig — funcții `wsRecv/wsSend` în p2p.zig
- **Fișiere:** `core/p2p.zig` (handleInboundPeer, recv, send)

### F4. TX segfault la calculateHash cu adrese trunchiate
- **Simptom:** `Segmentation fault at address` la `transaction.calculateHash → hasher.update(self.to_address)`
- **Cauză:** TX `to_address` slice din MinerPool poate fi invalid dacă adresa e < 32 chars
- **Fix:** Validare minimă lungime adresă (>= 8 chars) la addTransaction + guard la MinerPool
- **Fișiere:** `core/blockchain.zig` (validateTransaction), `core/main.zig` (MinerPool)

---

## IMPORTANTE (funcționalitate lipsă)

### F5. Blockchain nu persistă corect la restart cu difficulty diferit
- **Simptom:** Node nu pornește dacă omnibus-chain.dat a fost creat cu difficulty 4 dar binara are difficulty 1
- **Cauză:** Genesis hash diferit → validation fail
- **Fix:** Stochează difficulty în DB header sau verifică doar structura, nu hash-ul exact
- **Fișiere:** `core/database.zig`, `core/genesis.zig`

### F6. Balance check greșit — TX-urile rapide se resping reciproc
- **Simptom:** Prima TX merge, următoarele pică cu "balance insufficient" chiar dacă balance e suficient
- **Cauză:** `getAddressBalance` citește din chain (confirmat), nu include pending TX-uri din mempool
- **Fix:** Scade pending outgoing amounts din balance check la validateTransaction
- **Fișiere:** `core/blockchain.zig` (validateTransaction, getAddressBalance)

### F7. Frontend se blochează sub load
- **Simptom:** UI freeze când blocuri vin la fiecare secundă cu WS events
- **Cauză:** Prea multe re-renders, fiecare WS event declanșează dispatch → full component tree update
- **Fix:** `React.memo` pe componente heavy, `useMemo` pe liste, virtualizare (window) pe MinerTable
- **Fișiere:** `frontend/src/components/dashboard/*.tsx`, `frontend/src/components/network/MinerTable.tsx`

### F8. Mineri virtuali nu au wallet real (nu pot semna TX)
- **Simptom:** Doar seed-ul poate trimite TX (singurul cu private key), minerii virtuali pot doar primi
- **Cauză:** Minerii sunt doar adrese înregistrate, nu au wallet Zig cu private key
- **Fix:** TX-uri între mineri: fiecare miner virtual are key pair derivat din mnemonic, stocat în MinerPool
- **Fișiere:** `core/main.zig` (MinerPool), `core/wallet.zig`

---

## NICE-TO-HAVE (quality of life)

### F9. Peers counter mereu 0
- **Simptom:** Frontend arată Peers: 0 chiar cu mineri conectați
- **Cauză:** P2P inbound nu adaugă peers în lista (F3) + mineri virtuali nu sunt peers
- **Fix:** Afișează registered miners ca "nodes" în loc de "peers" pentru simulare
- **Fișiere:** `frontend/src/components/layout/Header.tsx`

### F10. TX history pe frontend nu arată nimic
- **Simptom:** Tab Wallet → Transaction History gol
- **Cauză:** `gettransactions` scanează doar chain blocks, nu mempool
- **Fix:** Include pending TX-uri din mempool în response
- **Fișiere:** `core/rpc_server.zig` (handleGetTxs)

### F11. Block detail nu afișează TX-uri reale din bloc
- **Simptom:** Click pe block → arată doar coinbase, nu user TXs
- **Cauză:** `gettransactions` filtrează pe adresă, nu pe block height
- **Fix:** Adaugă RPC `getblocktxs` care returnează TX-urile unui bloc specific
- **Fișiere:** `core/rpc_server.zig`, `frontend/src/components/blocks/BlockDetail.tsx`

### F12. Wiki sync tool nu detectează funcții noi
- **Simptom:** `wiki_sync.py` raportează funcții lipsă dar nu le fixează automat
- **Fix:** Mode `--auto-fix` care regenerează docs/api/*.md din cod
- **Fișiere:** `tools/SYNC/wiki_sync.py`

---

## Ordine recomandată
1. **F2** (address derivation) — fără asta TX-urile la mineri sunt invalide
2. **F3** (P2P Windows fix) — fără asta nu avem rețea reală
3. **F1** (stack overflow) — fără asta node-ul pică sub load
4. **F4** (TX segfault) — legat de F2
5. **F6** (balance check) — TX-uri rapide
6. **F5** (DB persist) — restart fără pierdere date
7. **F8** (miner wallets) — TX-uri între mineri
8. **F7** (frontend perf) — UI fluid
9. **F9-F12** (nice-to-have)
