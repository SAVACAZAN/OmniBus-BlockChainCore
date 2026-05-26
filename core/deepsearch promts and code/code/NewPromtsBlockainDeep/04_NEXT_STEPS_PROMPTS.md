# 04 — Prompts executabile pentru modulele lipsă

Fiecare prompt e self-contained: copy-paste în Claude Code și pornește implementarea.
Ordinea respectă prioritizarea din `03_GAP_ANALYSIS.md`.

---

## P0.1 — Fix build.zig aggregation

```
În repo C:\Kits work\limaje de programare\1_CORE\BlockChainCore, `zig build test` falie
la aggregation chiar dacă toate modulele individual pass (vezi MEMORY.md
test_status_2026_05_11). Citește build.zig, identifică parser issue în secțiunea care
agregă test steps (test, test-crypto, test-chain, test-net, test-shard, test-storage,
test-light, test-pq, test-wallet), fix root cause. Verifică cu `zig build test-crypto`
și `zig build test-chain`. Estimat: 15-30 min.
```

---

## P0.2 — Fix oracle_fetcher const/mutable

```
În core/oracle_fetcher.zig din BlockChainCore, există blocker const/mutable raportat în
MEMORY.md (test_run_2026_05_07). Identifică declarațiile const care ar trebui var și fix.
Rulează `zig test core/oracle_fetcher.zig` ca să confirmi.
```

---

## P1.1 — fee_estimator.zig dinamic

```
Creează core/fee_estimator.zig în BlockChainCore. Înlocuiește FeeEstimator-ul minimal din
core/chain_config.zig cu unul dinamic:

- struct FeeEstimator { allocator, sample_window: u64, samples: ArrayList(FeeSample) }
- 3 priority classes: slow (1h, P10), normal (10min, P50), fast (2 blocks, P90)
- API: estimate(target_blocks: u32) -> sat_per_vbyte (u64)
- Subscribe la mempool events: la fiecare TX confirm, calc effective_fee_rate și push în samples
- Decay sliding window: drop samples mai vechi decât sample_window
- Tests: în același fișier, mock 100 samples, verifică P10/P50/P90 sunt corect calculate

Integrează în main.zig: instanțiază odată cu mempool, expune via RPC `estimate_fee`.
Estimat: 4h.
```

---

## P1.2 — SIGHASH flags în transaction.zig

```
Extinde core/transaction.zig din BlockChainCore cu SIGHASH multi-mode.
Vezi draft existent: core/deepsearch promts and code/code/23_test_sighash.zig.

Adaugă:
- pub const SighashFlag = enum(u8) { ALL=0x01, NONE=0x02, SINGLE=0x03, ANYONECANPAY_ALL=0x81,
  ANYONECANPAY_NONE=0x82, ANYONECANPAY_SINGLE=0x83 }
- fn computeSighash(tx: *Transaction, input_index: usize, flag: SighashFlag) -> [32]u8
- ALL: hash all inputs + all outputs (curent default)
- NONE: hash all inputs, ZERO outputs
- SINGLE: hash all inputs + DOAR output[input_index]
- ANYONECANPAY_*: hash DOAR input curent + outputs per flag

Folosește algoritm BIP-143 pentru segwit-style (dublu SHA-256).
Tests: vector din BIP-143 + edge case SINGLE când input_index >= outputs.len (return all-ones hash per spec).
Estimat: 3-4h.
```

---

## P1.3 — P2WPKH + P2TR în script.zig

```
Extinde core/script.zig din BlockChainCore cu P2WPKH (segwit native) și P2TR (taproot).
Wire core/schnorr.zig la script engine pentru P2TR.

Adaugă:
- fn createP2WPKH(pubkey_hash: [20]u8) -> Script — OP_0 <hash160>
- fn createP2TR(internal_pubkey: [32]u8, merkle_root: ?[32]u8) -> Script — OP_1 <taptweak(P, m)>
- fn taptweak(P: [32]u8, m: ?[32]u8) -> [32]u8 — BIP-341 tweak
- ScriptVM extension: la executeOp OP_CHECKSIG dacă context.is_taproot atunci schnorr.verify

Tests:
- Vector P2WPKH din BIP-141
- Vector P2TR din BIP-341 (key-path spend)
- Vector P2TR script-path spend cu un singur leaf

Adaugă în core/bech32.zig: encode bech32m pentru P2TR (witness version 1).
Estimat: 4-6h.
```

---

## P1.4 — EIP-1559 în evm_signer.zig

```
Extinde core/evm_signer.zig din BlockChainCore cu EIP-1559 (type 2 transaction).
Vezi draft test: core/deepsearch promts and code/code/19_test_eip1559.zig.

Adaugă:
- pub const Eip1559Tx = struct {
    chain_id: u64, nonce: u64, max_priority_fee_per_gas: u128, max_fee_per_gas: u128,
    gas_limit: u64, to: ?[20]u8, value: u128, data: []const u8, access_list: []AccessListEntry
  }
- fn rlpEncodeEip1559(tx: *const Eip1559Tx) -> []u8 (prefix 0x02 + RLP list)
- fn signEip1559(tx, privkey) -> SignedTx (keccak256 over 0x02||rlp, ECDSA, recovery_id 0/1)
- fn serializeSigned(...) -> []u8 (0x02 + RLP list cu v, r, s appended)

Tests:
- Vector reference de pe ethereum.org / EIP-1559 spec
- Round-trip: encode → sign → decode → verify signer address

Estimat: 2-3h.
```

---

## P1.5 — coin_control.zig

```
Creează core/coin_control.zig în BlockChainCore. Vezi draft test:
core/deepsearch promts and code/code/24_test_coin_control.zig.

API:
- pub const CoinControl = struct {
    allocator, frozen: HashMap(OutPoint, void), manual_selection: ?ArrayList(OutPoint)
  }
- fn freeze(self, outpoint) / unfreeze / isFrozen
- fn selectManual(self, list: []OutPoint)
- fn clearManual(self)
- Hook în core/utxo.zig selectUTXOs: dacă coin_control.manual_selection != null → folosește acea listă
  validând că suma >= target_amount + fee. Altfel skip outpoint frozen.

Tests:
- Freeze 1 UTXO, selectUTXOs greedy NU îl include
- Manual select 2 UTXO, selectUTXOs returnează DOAR acelea
- Manual select insufficient amount → return error.InsufficientFunds

Estimat: 3h.
```

---

## P1.6 — Mempool persistence + CPFP

```
Extinde core/mempool.zig din BlockChainCore:

(a) Persistence:
- Pe shutdown: serialize toate TX-urile via core/binary_codec.zig → mempool.dat
- Pe startup: deserialize și revalidează fiecare TX (skip cele expired/invalid)
- File path: data/<network>/mempool.dat

(b) Package relay / CPFP:
- fn computeAncestorFeeRate(tx) -> u64 — average fee_rate(self) + all unconfirmed ancestors
- Modify accept logic: dacă TX standalone are fee_rate sub minimum DAR ancestor_fee_rate >= minimum → accept
- Limit package size: max 25 TX-uri în ancestor set (Bitcoin Core default)
- Adaugă RPC `getmempoolancestors(txid)` și `getmempooldescendants(txid)`

Tests:
- Persistence: add 3 TX, simulate shutdown, restart, verifică toate 3 sunt înapoi
- CPFP: child cu fee mare salvează parent cu fee 0

Estimat: 1 zi.
```

---

## P2.1 — pq_handshake.zig (X25519 + ML-KEM-768 hybrid)

```
Creează core/pq_handshake.zig în BlockChainCore. Implementează Noise XK pattern dar cu
hybrid KEM:

- Local key pair: X25519 (clasic) + ML-KEM-768 (PQ via liboqs)
- Handshake steps:
  1. Initiator → Responder: e_classic (X25519 pubkey) || e_pq (ML-KEM-768 ciphertext encrypted to responder's static PQ key)
  2. Responder decapsulates → shared_secret_pq, also DH(e_classic, s_classic) → shared_secret_classic
  3. Final session key: HKDF-SHA256(shared_secret_classic || shared_secret_pq, info="OmniBus-Hybrid-v1")
- Replace core/encrypted_p2p.zig handshake calls cu noul handler. Păstrează API
  încât p2p.zig să nu schimbe call-site.

Folosește core/pq_crypto.zig pentru ML-KEM-768 (există deja wrapper liboqs).
Folosește std.crypto.dh.X25519 din Zig stdlib.

Tests:
- Round-trip: initiator + responder generate shared_key identic
- Tampered ciphertext → handshake error
- Active MITM cu key replacement → handshake error (signature check pe static keys)

Estimat: 1-2 zile.
```

---

## P2.2 — hybrid_signature.zig (ECDSA + ML-DSA în același TX)

```
Creează core/hybrid_signature.zig în BlockChainCore.

- pub const HybridSig = struct {
    classic: secp256k1.Signature, pq: ml_dsa.Signature, scheme: enum { ECDSA_MLDSA65, ECDSA_MLDSA87, ECDSA_FALCON512 }
  }
- fn signHybrid(msg, sk_classic, sk_pq, scheme) -> HybridSig
- fn verifyHybrid(msg, sig: *const HybridSig, pk_classic, pk_pq) -> bool
  (return true DOAR dacă AMBELE verify ok — defense-in-depth)

Extinde core/transaction.zig pentru a accepta witness cu HybridSig (witness_type: u8 = 0xFE).

Tests:
- Sign + verify ok
- Tampered classic sig → verify false
- Tampered PQ sig → verify false
- Wrong scheme tag → verify error

Estimat: 1 zi.
```

---

## P3.1 — fast_sync.zig

```
Creează core/fast_sync.zig în BlockChainCore. Implementare:

- Phase 1: download all block headers de la trusted peer set (10 peers majority)
- Phase 2: pick most recent finalized block (via finality.zig checkpoints), request state snapshot:
  - Request /state_snapshot?block=<hash> → peer returns Merkle-Patricia trie chunks
  - Verify chunks against state_root din header
- Phase 3: replay last ~100 blocks la normal (ca să avem mempool consistent)

Folosește core/state_trie.zig pentru verification.
Hook în main.zig: dacă local height == 0 și --fast-sync flag → use fast_sync path în loc de
sync.zig normal.

Estimat: 2-3 zile.
```

---

## P4.1 — wallet-core/btc/ (repo separat)

```
Creează repo nou C:\Kits work\limaje de programare\1_CORE\wallet-core\ cu submodule btc/.
NU pune în BlockChainCore/core/ — păstrează L1 pur.

Submodule btc/:
- btc/address.zig — deriveP2WPKH (bc1q...), deriveP2TR (bc1p...) folosind bip32_wallet din BlockChainCore
- btc/tx_builder.zig — construiește raw BTC TX cu SIGHASH proper (folosește BIP-143 sighash)
- btc/rpc_client.zig — JSON-RPC client pentru bitcoind: sendrawtransaction, estimatesmartfee, getblockchaininfo
- btc/fee_estimator.zig — interogare estimatesmartfee + cache
- btc/psbt.zig — BIP-174 PSBT pentru BTC (diferit de OmniBus PSBT)

Draft-uri existente în BlockChainCore/core/deepsearch promts and code/code/:
- 30_btc.rpc.RpcConfig, 31_btc.address.deriveP2WP, 32_btc.tx_builder.TxBuilder.init
- 33_btc_client.getBalance, 45_BTC_INTEGRATION.md, 46_btc_address.deriveP2TR
- 48_btc_rpc.BtcRpcClient.init, 49_btc_tx.TxBuilder.init, 50_builder.sign
- 51_rpc.sendTransa, 52_rpc.estimateFe, 53_btc_fee.FeeEstimator.init

Folosește acele draft-uri ca punct de pornire.

Trait pattern: common/Signer.zig, common/TxBuilder.zig, common/RpcClient.zig — pentru
ca eth/, sol/, ton/ să urmeze același pattern.

Build: wallet-core/build.zig dependă de BlockChainCore (path import) doar pentru bip32_wallet
+ secp256k1 + crypto primitives.

Estimat: 6-8h pentru BTC stack complet cu tests.
```

---

## Cum folosești promptele

1. Deschide Claude Code în root `BlockChainCore`
2. Alege un prompt din ordine (P0 → P4)
3. Copy-paste tot blocul ```...``` în Claude
4. Lasă-l să implementeze, rulează `zig build test-<grup>` ca să verifici
5. Commit cu mesaj `core(<modul>): implement X` și cei 9 co-authors din CLAUDE.md
6. Next prompt

Total effort estimativ pentru P0+P1+P2 (L1 production-grade + PQ diferențiator):
**~3 săptămâni full-time** sau ~6 săptămâni part-time.
