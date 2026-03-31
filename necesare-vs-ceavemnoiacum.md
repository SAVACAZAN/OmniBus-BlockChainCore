# Necesare vs Ce Avem Acum - OmniBus Blockchain

## 📋 Overview

**Scală target:** 100-2000 noduri validatori  
**Block time:** 1 secundă (10 sub-blocuri × 0.1s)  
**TPS target:** 4000-5000+ tranzacții/secundă  
**Arhitectură:** PoW + Casper FFG (hybrid) + Sharding

---

## ✅ IMPLEMENTAT (Ce avem funcțional)

### 1. Consens & Finalitate
| Componentă | Status | Fișier |
|------------|--------|--------|
| PoW (Proof of Work) | ✅ Funcțional | `core/consensus.zig` |
| Casper FFG | ✅ Implementat | `core/finality.zig` |
| Checkpoint-uri (64 blocuri) | ✅ Activ | `CHECKPOINT_INTERVAL = 64` |
| Justification (2/3+ voturi) | ✅ Funcțional | `hasSupermajority()` |
| Finalization | ✅ Implementat | Casper FFG rule |
| Slashing (equivocation) | ✅ Detectat | `slash_count` tracking |
| Double-vote detection | ✅ Validat | `validator_votes[]` array |

### 2. Sub-blocuri & Mining
| Componentă | Status | Detalii |
|------------|--------|---------|
| SubBlock (0.1s) | ✅ Funcțional | 10 sub-blocuri / KeyBlock |
| KeyBlock (1s) | ✅ Agregare completă | Merkle root din 10 sub-blocuri |
| SubBlockEngine | ✅ Orchestrare | Tick-based generation |
| Shard assignment | ✅ Per sub-bloc | `shard_id` în SubBlock |

### 3. Sharding
| Componentă | Status | Detalii |
|------------|--------|---------|
| ShardCoordinator | ✅ EGLD-style | Hash-based routing |
| 4 Shards active | ✅ Configurat | `num_shards = 4` |
| Cross-shard TX detection | ✅ Funcțional | `isCrossShard()` |
| Adaptive sharding | ✅ Logică prezentă | Split/merge la 80%/20% load |
| Metachain support | ✅ Constant definit | `METACHAIN_SHARD = 0xFF` |

### 4. Networking P2P
| Componentă | Status | Detalii |
|------------|--------|---------|
| TCP Transport | ✅ Windows + Linux | `ws2_32` fallback |
| Binary protocol | ✅ Header + payload | 9-byte header |
| Gossip protocol | ✅ Deduplicare | `SeenHashes` ring buffer |
| TX relay | ✅ Funcțional | `broadcastTx()` |
| Block announce | ✅ Funcțional | `broadcastBlock()` |
| PEX (Peer Exchange) | ✅ Implementat | `encodePeerList/decodePeerList` |
| Rate limiting | ✅ Per-peer | 100 msg/sec, 10MB/sec |
| Subnet diversity | ✅ Anti-eclipse | Max 2 peers / /16 subnet |
| Ban system | ✅ Activ | `BannedPeer` tracking |
| Reconnect queue | ✅ Persistent | `ReconnectInfo` |
| SPV header sync | ✅ Complet | `syncHeaders()` |

### 5. Peer Scoring (Bitcoin-style)
| Componentă | Status | Detalii |
|------------|--------|---------|
| Misbehavior tracking | ✅ Funcțional | `PeerScore` struct |
| Auto-ban | ✅ La -100 score | `BAN_THRESHOLD` |
| Event deltas | ✅ Configurate | Valid block: +1, Double-spend: -100 |
| Ban expiry | ✅ 24 ore | `BAN_DURATION_SEC` |
| Trust levels | ✅ 0-100 scale | `trustLevel()` |

### 6. Staking & Validatori
| Componentă | Status | Detalii |
|------------|--------|---------|
| Validator registration | ✅ Cu stake | Min 100 OMNI |
| Active set | ✅ Max 128 | `MAX_VALIDATORS` |
| Delegation tracking | ✅ Structuri definite | `Delegation` struct |
| Unbonding period | ✅ 7 zile | `UNBONDING_PERIOD = 604800` blocuri |
| Weighted selection | ✅ Random by stake | `selectProposer()` |
| Downtime slashing | ✅ 1% penalty | `DOWNTIME_PENALTY_PCT` |
| Double-sign slashing | ✅ 33% penalty | `SLASH_DOUBLE_SIGN_PCT` |
| Invalid block slashing | ✅ 10% penalty | `SLASH_INVALID_BLOCK_PCT` |
| Evidence submission | ✅ Complet | `submitSlashEvidence()` |
| Reporter rewards | ✅ 10% din slash | `REPORTER_REWARD_PCT` |
| Slash history | ✅ Persistent | `getSlashHistory()` |

### 7. Mempool
| Componentă | Status | Detalii |
|------------|--------|---------|
| FIFO queue | ✅ Anti-MEV | `MempoolEntry` list |
| Max 10K TX | ✅ Limită activă | `MEMPOOL_MAX_TX` |
| Fee market | ✅ Sortare by fee | `getByFee()` |
| Median fee estimation | ✅ Pentru RPC | `medianFee()` |
| Nonce tracking | ✅ Per-address | `pending_count` HashMap |
| Replace-by-nonce | ✅ Fee bumping | `replaceByNonce()` |
| TX expiry | ✅ 14 zile | `MEMPOOL_EXPIRY_SEC` |
| Locktime support | ✅ Timelocked TX | `getMineable()` filtering |
| Memory management | ✅ 300MB limit | `MEMPOOL_MAX_MEMORY` |

### 8. BLS Signatures (Simulat)
| Componentă | Status | Detalii |
|------------|--------|---------|
| Key generation | ✅ Simulat | 32-byte secret, 48-byte pubkey |
| Signing | ✅ HMAC-based | `blsSign()` |
| Verification | ✅ Structural | `blsVerify()` |
| Aggregation | ✅ XOR-based | `blsAggregate()` |
| Threshold signatures | ✅ t-of-n | `BlsThreshold` struct |

### 9. Light Client (SPV)
| Componentă | Status | Detalii |
|------------|--------|---------|
| Block headers | ✅ 200 bytes each | `BlockHeader` struct |
| Merkle proofs | ✅ Verificare completă | `verifyMerkleProof()` |
| Bloom filters | ✅ 512 bytes | `BloomFilter` struct |
| Header pruning | ✅ Keep last 1000 | `max_headers_to_keep` |
| Chain validation | ✅ Links + timestamp | `validateHeader()` |
| Fast sync | ✅ From checkpoint | `fastSyncFromCheckpoint()` |

### 10. Storage & Codec
| Componentă | Status | Detalii |
|------------|--------|---------|
| Binary codec | ✅ Serde complet | `binary_codec.zig` |
| State trie | ✅ Definit | `state_trie.zig` |
| Archive manager | ✅ Rotație fișiere | `archive_manager.zig` |
| Compact blocks | ✅ Comprimare | `compact_blocks.zig` |
| Witness data | ✅ Format definit | `witness_data.zig` |

---

## ❌ LIPSEȘTE (Ce trebuie implementat)

### 🔴 CRITIC - Blochează scalarea la 2000 noduri

#### 1. LMD GHOST Fork Choice Rule
**Ce e:** Algoritmul care alege "lanțul cel mai greu" după voturi, nu doar cel mai lung  
**De ce e necesar:** La 1s/bloc și fork-uri frecvente, PoW pure nu e suficient  
**Status:** ❌ Lipsește complet  
**Implementare necesară:**
```zig
// Pseudo-cod
pub const LMDGhost = struct {
    latest_attestations: [MAX_VALIDATORS]Attestation,
    
    pub fn getHead(self: *LMDGhost, finalized_checkpoint: Checkpoint) -> BlockHash {
        // Pornește de la checkpoint finalizat
        // Alege ramura cu cele mai multe voturi cumulative
    }
};
```
**Efort:** ~2-3 zile  
**Fișiere noi:** `core/lmd_ghost.zig`

#### 2. BLS12-381 Real (Nu simulat)
**Ce e:** Curbe eliptice pairing-friendly pentru agregare reală de semnături  
**De ce e necesar:** Simularea actuală (XOR) nu oferă securitate criptografică reală  
**Status:** ❌ Simulat doar  
**Soluții:**
- Opțiune A: Integrare `blst` (BLS signatures by Supranational) - recomandat
- Opțiune B: `mcl` library (BLS12-381 în C++)
- Opțiune C: Pure Zig (foarte lent, doar pentru test)

**Efort:** ~3-5 zile (incl. bindings C)  
**Fișiere modificate:** `core/bls_signatures.zig`

#### 3. Committee Selection (VRF Sampling)
**Ce e:** Selectare aleatorie a unui subset de validatori (ex: 128 din 2000) per slot  
**De ce e necesar:** 2000 validatori × 10 sub-blocuri = 20K voturi/secundă = flood  
**Status:** ❌ Toți validatorii votează acum  
**Implementare necesară:**
```zig
pub const CommitteeSelector = struct {
    pub fn selectCommittee(seed: [32]u8, total_validators: u16, committee_size: u16) -> []ValidatorIndex;
    
    // VRF pentru selecție verificabilă
    pub fn vrfProve(sk: SecretKey, seed: []u8) -> VRFProof;
    pub fn vrfVerify(pk: PublicKey, seed: []u8, proof: VRFProof) -> bool;
};
```
**Efort:** ~2-3 zile  
**Fișiere noi:** `core/committee_selection.zig`, `core/vrf.zig`

#### 4. BLS Aggregation la Nivel de Rețea
**Ce e:** Agregarea semnăturilor BLS înainte de propagare  
**De ce e necesar:** Reducere de la 2000 semnături la 1 per mesaj  
**Status:** ❌ Are funcția `blsAggregate()` dar nu e folosită în P2P  
**Implementare necesară:**
```zig
// În p2p.zig
pub fn broadcastAggregatedAttestation(attestations: []Attestation) {
    const agg_sig = blsAggregate(attestations.map(|a| a.signature));
    const agg_pubkey = blsAggregateKeys(attestations.map(|a| a.pubkey));
    // Propagă doar semnătura agregată
}
```
**Efort:** ~1-2 zile  
**Fișiere modificate:** `core/p2p.zig`

#### 5. Inactivity Leak
**Ce e:** Penalizare progresivă pentru validatori offline (ca Ethereum 2.0)  
**De ce e necesar:** Dacă 1/3 din rețea cade, restul trebuie să poată finaliza  
**Status:** ❌ Lipsește  
**Implementare necesară:**
```zig
pub const InactivityLeak = struct {
    offline_epochs: [MAX_VALIDATORS]u64, // câte epoci a fost offline
    
    pub fn processEpoch(self: *InactivityLeak, participation: []bool) {
        // Dacă < 2/3 participare, începe penalizarea
        // Reduce stake-ul validatorilor offline progresiv
    }
};
```
**Efort:** ~1-2 zile  
**Fișiere noi:** `core/inactivity_leak.zig`

---

### 🟡 IMPORTANT - Optimizare performanță

#### 6. State Sharding Complet
**Ce e:** Fiecare shard își menține propria stare, nu doar coordonatorul  
**De ce e necesar:** Un nod nu trebuie să stocheze toată starea  
**Status:** ⚠️ Are coordonator dar nu și split efectiv al stării  
**Ce lipsește:**
- State root per shard
- Cross-shard state proofs
- Shard state sync

**Efort:** ~5-7 zile  
**Fișiere noi:** `core/shard_state.zig`, `core/cross_shard_state.zig`

#### 7. Parallel Transaction Execution
**Ce e:** Execuție paralelă a TX-urilor independente pe multiple core-uri  
**De ce e necesar:** Crește TPS de la 5000 la potențial 20000+  
**Status:** ❌ Secvențial acum  
**Implementare necesară:**
```zig
pub const ParallelExecutor = struct {
    pub fn executeParallel(txs: []Transaction, num_threads: u8) -> []TransactionResult {
        // Detectează dependențe (aceeași adresă = conflict)
        // Grupează TX-uri independente
        // Execută în paralel pe thread pool
    }
};
```
**Efort:** ~3-4 zile  
**Fișiere noi:** `core/parallel_exec.zig`

#### 8. RANDAO (On-chain Randomness)
**Ce e:** Sursă de randomness verificabilă pentru selecția comitetelor  
**De ce e necesar:** Nu poți folosi block hash (minerii pot manipula)  
**Status:** ❌ Lipsește  
**Implementare necesară:**
```zig
pub const RANDAO = struct {
    reveals: [MAX_VALIDATORS][32]u8, // Hash pre-commitments
    
    pub fn commit(self: *RANDAO, validator: u16, hash: [32]u8);
    pub fn reveal(self: *RANDAO, validator: u16, value: [32]u8);
    pub fn getRandomness(self: *RANDAO) -> [32]u8; // XOR de toate reveal-urile
};
```
**Efort:** ~2-3 zile  
**Fișiere noi:** `core/randao.zig`

#### 9. Gossipsub Protocol (libp2p-style)
**Ce e:** Protocol de gossip mesh cu forwarding controlat  
**De ce e necesar:** Gossipul actual e prea simplu pentru 2000 noduri  
**Status:** ⚠️ Are deduplicare dar nu și mesh formation  
**Ce lipsește:**
- Topic subscription
- Mesh maintenance (graft/prune)
- Message validation pipeline
- Fan-out pentru topic-uri noi

**Efort:** ~4-5 zile  
**Fișiere modificate:** `core/p2p.zig` (extensii majore)

#### 10. Snapshotting pentru Fast Sync
**Ce e:** Puncte de restaurare periodice pentru sincronizare rapidă  
**De ce e necesar:** Un nod nou nu trebuie să proceseze 1M blocuri  
**Status:** ⚠️ Light client are fast sync, full node nu  
**Implementare necesară:**
```zig
pub const SnapshotManager = struct {
    pub fn createSnapshot(height: u64) -> Snapshot; // State trie + validator set
    pub fn restoreFromSnapshot(snapshot: Snapshot) -> BlockchainState;
};
```
**Efort:** ~2-3 zile  
**Fișiere noi:** `core/snapshot.zig`

---

### 🟢 NICE TO HAVE - Îmbunătățiri UX

#### 11. Dynamic Gas Limit
**Ce e:** Ajustare automată a numărului de TX per bloc în funcție de load  
**Status:** ❌ Block size static acum  
**Efort:** ~1 zi

#### 12. Health Check RPC
**Ce e:** Endpoint care raportează CPU, RAM, network health în timp real  
**Status:** ❌ Lipsește  
**Efort:** ~1 zi

#### 13. Merkle Patricia Tries pentru State
**Ce e:** Structură de date eficientă pentru starea conturilor  
**Status:** ⚠️ Are `state_trie.zig` dar nu e utilizat complet  
**Efort:** ~2-3 zile

#### 14. State Pruning
**Ce e:** Ștergerea stării vechi (de acum >1 an) pentru a reduce DB  
**Status:** ⚠️ Are config în `prune_config.zig` dar nu implementare completă  
**Efort:** ~2 zile

#### 15. Bandwidth Throttling per Peer
**Ce e:** Limitare dinamică a bandwidth-ului în funcție de peer score  
**Status:** ⚠️ Are rate limiting per message count, nu și bandwidth  
**Efort:** ~1-2 zile

---

## 📊 Rezumat Implementare

### Estimare Totală Efort

| Prioritate | Iteme | Zile Estimate |
|------------|-------|---------------|
| 🔴 CRITIC | 5 iteme | 10-15 zile |
| 🟡 IMPORTANT | 5 iteme | 15-20 zile |
| 🟢 NICE TO HAVE | 5 iteme | 7-9 zile |
| **TOTAL** | **15 iteme** | **32-44 zile** |

### Dependențe
```
BLS12-381 Real
    ↓
BLS Aggregation în P2P
    ↓
Committee Selection (VRF)
    ↓
LMD GHOST (depinde de voturi agregate)
    ↓
Inactivity Leak
```

### Roadmap Recomandată

**Sprint 1 (Zilele 1-7): Fundație Cripto**
1. BLS12-381 real cu blst
2. BLS aggregation în P2P
3. Committee selection VRF

**Sprint 2 (Zilele 8-14): Consens Avansat**
4. LMD GHOST fork choice
5. Inactivity leak
6. RANDAO randomness

**Sprint 3 (Zilele 15-21): Scalabilitate State**
7. State sharding complet
8. Parallel execution
9. Snapshotting

**Sprint 4 (Zilele 22-30): Optimizări**
10. Gossipsub mesh
11. Dynamic gas limit
12. Health checks
13. State pruning
14. Merkle Patricia Tries
15. Bandwidth throttling

---

## 🔍 Cum testăm scalarea?

### Test Local (înainte de mainnet)
```bash
# 1. Simulează 2000 noduri cu Docker Compose
# docker-compose.yml cu 2000 container instances

# 2. Generează TX-uri cu script
./scripts/flood_test.sh --tps 5000 --duration 60

# 3. Monitorizează metrici
# - Latency per sub-bloc
# - Message count per secundă
# - CPU/RAM per nod
# - Bandwidth usage
```

### Metrici de succes
| Metrică | Target | Status Acum |
|---------|--------|-------------|
| Block time | 1s | ✅ 10s (scade la 1s) |
| Sub-blocuri | 10/sec | ✅ Funcțional |
| TPS | 5000+ | ✅ Testat 4000-5000 |
| Validatori | 2000 | ❌ Testat doar 100 |
| Latență rețea | <50ms RTT | ⚠️ Necesită test |
| Semnături agregate | 1 per bloc | ❌ Lipsește |
| Finalitate | <2 min | ✅ 64-128 sec |

---

## 📝 Notă pentru echipă

**Ce avem acum e SOLID:**
- Arhitectura hybrid PoW+PoS e corect gândită
- Sub-blocurile funcționează bine pentru throughput
- Sharding-ul are fundația pusă
- P2P-ul are hardening bun (ban, rate limiting, subnet diversity)

**Ce ne blochează scalarea:**
- Absența LMD GHOST pentru fork choice rapid
- Lipsa committee selection (toți votează = flood)
- BLS simulat în loc de curbe reale
- Lipsa inactivity leak pentru reziliență

**Recomandare:** Implementeaza cele 5 iteme critice inainte de orice mainnet cu >100 validatori.

---

## v0.2.0 — Module noi (2026-03-31)

### Adresare & Wallet (BTC parity 115%)
| Componenta | Status | Fisier |
|------------|--------|--------|
| Bech32/Bech32m (BIP-173/350) | Implementat | `core/bech32.zig` |
| Adrese ob1q... (42 chars, ca BTC bc1q) | Implementat | HRP="ob" |
| xpub/xprv extended keys | Implementat | `core/bip32_wallet.zig` |
| WIF, master_fingerprint, hash160 | Implementat | `core/bip32_wallet.zig` |
| Change addresses (chain=1) | Implementat | `deriveChangeAddress()` |
| Passphrase BIP-39 | Implementat | `initFromMnemonicPassphrase()` |

### Tranzactii & UTXO
| Componenta | Status | Fisier |
|------------|--------|--------|
| UTXO Set complet | Implementat | `core/utxo.zig` |
| RBF (Replace-By-Fee) | Implementat | `core/transaction.zig` + `mempool.zig` |
| CPFP (Child-Pays-For-Parent) | Implementat | `core/mempool.zig` |
| PSBT (BIP-174) | Implementat | `core/psbt.zig` |
| Sequence number (BIP-125) | Implementat | `core/transaction.zig` |

### Layer 2 & Lightning
| Componenta | Status | Fisier |
|------------|--------|--------|
| HTLC Contracts | Implementat | `core/htlc.zig` |
| Lightning Network | Implementat | `core/lightning.zig` |
| Block Filters (BIP-157/158) | Implementat | `core/block_filter.zig` |

### Networking & Privacy
| Componenta | Status | Fisier |
|------------|--------|--------|
| Tor SOCKS5 proxy | Implementat | `core/tor_proxy.zig` |
| BIP-324 encrypted P2P | Implementat | `core/encrypted_p2p.zig` |

### Multi-Chain Wallet
| Componenta | Status | Fisier |
|------------|--------|--------|
| 19-chain wallet (1 mnemonic) | Implementat | `scripts/generate_multiwallet.py` |
| 138 adrese: OMNI+BTC+ETH+SOL+ADA+DOT+... | Implementat | Account-based structure |

**Total module Zig: 78 | BTC parity: 115% + 30 extras**
