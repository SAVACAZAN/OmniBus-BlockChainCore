# Plan: Bitcoin Feature Parity — Ce are Bitcoin și ne trebuie și nouă

**Data:** 2026-03-30 | **Scop:** OmniBus BlockChainCore trebuie să aibă cel puțin ce are Bitcoin Core pe partea de tranzacții, networking, și consens.

---

## CE ARE BITCOIN ȘI NOI AVEM

| Feature | Bitcoin | OmniBus | Status |
|---------|---------|---------|--------|
| PoW mining | SHA256d | SHA256d | ✅ Real |
| Block reward + halving | 50→25→12.5 BTC | 0.0083 OMNI, halving 126M | ✅ Real |
| Mempool (TX pool) | Priority by fee | FIFO + fee | ✅ Real |
| UTXO model | Da | Nu — account-based (ca Ethereum) | ⚠️ Diferit (OK) |
| secp256k1 ECDSA signing | Da | Da — pur Zig | ✅ Real |
| BIP-32 HD Wallet | Da | Da — HMAC-SHA512 derivation | ✅ Real |
| BIP-39 Mnemonic | Da | Da — 12/24 words | ✅ Real |
| Difficulty retarget | Every 2016 blocks | Every 2016 blocks | ✅ Real |
| Merkle root in block | Da | Da | ✅ Real |
| Coinbase maturity (100 blocks) | Da | Da | ✅ Real |
| Dust threshold | 546 sat | 100 sat | ✅ Real |
| JSON-RPC API | Da | Da — 19 metode | ✅ Real |
| Block explorer (frontend) | mempool.space | mempool.space style | ✅ Real |

---

## CE ARE BITCOIN ȘI NE LIPSEȘTE

### B1. UTXO vs Account Model
**Bitcoin:** Fiecare TX consumă UTXOs (Unspent Transaction Outputs) și creează altele noi. Nu există "balance" — balance se calculează din UTXOs.
**OmniBus:** Account-based (ca Ethereum) — fiecare adresă are un balance direct.
**Decizie:** Păstrăm account model — e mai simplu, mai rapid, și funcționează. Ethereum, Solana, MultiversX toate folosesc account model. Nu e un defect.

### B2. TX Inputs/Outputs (UTXO)
**Bitcoin:** TX are multiple inputs (UTXOs consumate) și multiple outputs (UTXOs create).
**OmniBus:** TX are 1 from, 1 to, 1 amount.
**Fix necesar:** Adăugăm câmp `fee` explicit + `change_address` pentru rest.
**Fișiere:** `core/transaction.zig`

### B3. TX Fee Market
**Bitcoin:** Minerii selectează TX-uri cu fee mai mare. Fee = input_total - output_total.
**OmniBus:** FIFO (first in, first out) — nu există prioritizare pe fee.
**Fix necesar:**
- Adaugă `fee_sat` câmp în Transaction
- Mempool sortare pe fee/byte (nu FIFO)
- Miner selectează TX-uri cu fee maxim (greedy)
- `estimatefee` RPC method
**Fișiere:** `core/transaction.zig`, `core/mempool.zig`, `core/rpc_server.zig`

### B4. Script System (Bitcoin Script)
**Bitcoin:** Fiecare TX are `scriptPubKey` (lock) și `scriptSig` (unlock). Permite multisig, timelock, etc.
**OmniBus:** Doar ECDSA signature pe TX hash.
**Fix necesar:** NU implementăm Bitcoin Script complet (prea complex). Dar adăugăm:
- Timelock (TX nu e valid înainte de block X)
- Multisig (M-of-N semnături — deja avem `core/multisig.zig`)
- OP_RETURN (date arbitrare în TX — pentru NFTs, timestamps)
**Fișiere:** `core/transaction.zig` (add locktime, op_return fields)

### B5. TX Verification completă
**Bitcoin:** Verifică semnătura ECDSA cu public key din UTXO.
**OmniBus:** Verifică doar hash integrity, NU verifică semnătura cu public key (comment: "Nu putem verifica semnătura fără public key").
**Fix necesar CRITIC:**
- La `sendtransaction`, stochează public key-ul sender-ului în TX
- La `validateTransaction`, verifică ECDSA signature cu stored public key
- Fără asta, oricine poate falsifica TX-uri
**Fișiere:** `core/transaction.zig` (add pub_key field), `core/blockchain.zig` (validateTransaction), `core/wallet.zig`

### B6. P2P Network Protocol Real
**Bitcoin:** Gossip protocol — fiecare nod trimite TX-uri și blocuri la peers. Bloom filters, compact blocks, inv/getdata.
**OmniBus:** TCP connect + broadcastBlock (unidirecțional). P2P inbound nu funcționează pe Windows (F3).
**Fix necesar:**
- Fix recv pe Windows (ws2_32) — F3
- Implementare mesaje: `inv`, `getdata`, `tx`, `block`, `getblocks`, `getheaders`
- Gossip: când primești TX/block, retransmite la toți peers
- Bloom filters pentru SPV (deja avem `core/light_client.zig`)
**Fișiere:** `core/p2p.zig`, `core/sync.zig`, `core/network.zig`

### B7. Block Validation completă
**Bitcoin:** Validează: merkle root, previous_hash, difficulty, timestamp, TX-uri, coinbase, total fees.
**OmniBus:** Validează: hash difficulty, previous_hash. NU validează merkle root corect, nu verifică total fees.
**Fix necesar:**
- `validateBlock()` verifică merkle root recalculat
- Verifică timestamp (nu în viitor, nu prea vechi)
- Verifică total fees = sum(tx.fee) și reward <= expected + fees
**Fișiere:** `core/block.zig`, `core/blockchain.zig`

### B8. Orphan Blocks / Chain Reorganization
**Bitcoin:** Când două mineri găsesc block simultan, rețeaua alege chain-ul mai lung. Blocurile "perdante" devin orphans.
**OmniBus:** Nu avem chain reorganization — un singur miner minează secvențial.
**Fix necesar:**
- `reorg()` — când primim un chain mai lung, facem switch
- Orphan block detection
- Mempool: TX-urile din blocuri invalidate revin în mempool
**Fișiere:** `core/blockchain.zig` (addBlock, reorg), `core/mempool.zig`

### B9. Nonce Management (Anti-replay)
**Bitcoin:** Nu are nonce (UTXO model previne replay). Ethereum are nonce per account.
**OmniBus:** Are nonce dar implementarea e buggy (F6 — nonce setat greșit duce la TX rejection).
**Fix necesar:**
- Nonce strict sequential (expected_nonce = last_confirmed + pending_count)
- Mempool tracks pending nonces per address
- `getnonce` RPC method
**Fișiere:** `core/blockchain.zig`, `core/mempool.zig`, `core/rpc_server.zig`

### B10. Confirmations Count
**Bitcoin:** TX are N confirmations (câte blocuri au fost minate după blocul care conține TX-ul).
**OmniBus:** TX are doar "pending" sau "confirmed" — fără count.
**Fix necesar:**
- `gettransaction` returnează `confirmations: current_height - tx_block_height`
- Frontend arată confirmations count pe TX
**Fișiere:** `core/rpc_server.zig`, `frontend/src/components/blocks/BlockDetail.tsx`

### B11. Address Balance History
**Bitcoin:** `listunspent`, `listtransactions` — istoric complet per adresă.
**OmniBus:** `getbalance` returnează doar balance-ul curent. Nu avem istoric.
**Fix necesar:**
- `getaddresshistory` RPC — toate TX-urile per adresă cu timestamps
- `listunspent` equivalent (toate incoming TX-uri neconsumate)
**Fișiere:** `core/rpc_server.zig`

### B12. Network Discovery (DNS Seeds)
**Bitcoin:** La pornire, nodurile contactează DNS seeds hardcodate care returnează liste de peers activi.
**OmniBus:** Hardcodat seed host (`--seed-host`). Avem `core/bootstrap.zig` dar nu DNS real.
**Fix necesar:**
- Lista hardcodată de seed nodes (IP-uri)
- Peer exchange (PEX) — peers share liste de peers
- Kademlia DHT (deja avem `core/kademlia_dht.zig` — integrare)
**Fișiere:** `core/bootstrap.zig`, `core/kademlia_dht.zig`, `core/p2p.zig`

---

## CE ARE BITCOIN ȘI NU NE TREBUIE (by design)

| Feature | De ce nu | Alternativa noastră |
|---------|----------|-------------------|
| Bitcoin Script (complet) | Prea complex, securitate | Multisig + Timelock + OP_RETURN |
| Replace-By-Fee (RBF) | Confuz pentru useri | Fee bump prin TX nouă |
| Segregated Witness (SegWit) | UTXO-specific | Avem witness_data.zig (SegWit-style) |
| Lightning Network | Layer 2 | Avem payment_channel.zig (Hydra L2) |
| Taproot/Schnorr | Complex | Avem schnorr.zig + multisig.zig |
| BIP-141 (SegWit addresses) | UTXO-specific | 5 domenii PQ (ob_omni_, ob_k1_, etc) |

---

## CE AVEM NOI ȘI BITCOIN NU ARE

| Feature | OmniBus | Bitcoin echivalent |
|---------|---------|-------------------|
| Post-Quantum Crypto | 5 domenii PQ (ML-DSA, Falcon, SLH-DSA) | Nu |
| Sub-blocks (0.1s soft confirm) | 10 sub-blocks per block | Nu (10 min blocks) |
| Metachain + Sharding | 4 sharduri, cross-shard | Nu |
| Governance on-chain | Propuneri + voturi | Nu (BIP off-chain) |
| Staking + Slashing | Validator system | Nu (doar PoW) |
| UBI Distribution | 1 OMNI/day per beneficiar | Nu |
| DNS Registry on-chain | Domenii descentralizate | Nu |
| Account Guardians | Recovery mechanism | Nu |
| OmniBrain orchestrator | Auto node-type detection | Nu |

---

## ORDINE IMPLEMENTARE RECOMANDATĂ

### Sprint 1: TX Engine complet (CRITIC)
1. **B5** — TX signature verification cu public key (securitate)
2. **B3** — Fee market (mempool sorting, estimatefee)
3. **B2** — Fee field + change address în TX
4. **B9** — Nonce management corect
5. **B10** — Confirmations count

### Sprint 2: Block Validation
6. **B7** — Block validation completă (merkle, timestamp, fees)
7. **B4** — Timelock + OP_RETURN în TX

### Sprint 3: Networking
8. **B6** — P2P protocol real (gossip, inv/getdata)
9. **B12** — Network discovery (DNS seeds, PEX)
10. **B8** — Chain reorganization + orphan blocks

### Sprint 4: API + UX
11. **B11** — Address history, listtransactions
12. Frontend: confirmation count, fee estimation, TX details
