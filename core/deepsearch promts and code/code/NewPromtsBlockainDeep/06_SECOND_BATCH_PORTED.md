# 06 — Al doilea batch portat din `NewPromtsBlockainDeep/code/`

Sesiune: 2026-05-19 (continuare)

## Module noi în `core/` (toate compilează clean, teste pass)

| Modul | LOC | Teste | Sursă draft |
|-------|-----|-------|-------------|
| `core/package_relay.zig` | ~180 | 5/5 ✓ | `18_package_relay.zig` |
| `core/slashing_evidence.zig` | ~160 | 4/4 ✓ | `19_slashing_evidence.zig` |
| `core/double_ratchet.zig` | ~180 | 5/5 ✓ | `20_double_ratchet.zig` |
| `core/fee_estimator.zig` | ~140 | 5/5 ✓ | scris from scratch (drafturile erau mislabelled) |

## Drafturi BLOCATE (nu pot fi portate direct fără adapter)

Drafturile au folosit API-uri care NU EXISTĂ în formele lor în `core/`. Trebuie rescrise
ca să se potrivească cu API-ul real, NU portate.

### `15_pq_handshake.zig` — pq_handshake
**Probleme**:
- `pq_crypto.MLKEM768.encapsulate(allocator, pubkey)` — API-ul real e `self.encapsulate(allocator)` instance-based, fără arg pubkey explicit
- `pq_crypto.MLKEM768.keypair(allocator)` — nu există, MlKem768 are alt constructor
- `X25519.KeyPair.create(&priv, &pub)` — API-ul std.crypto din Zig 0.15 e `KeyPair.generate()` care returnează struct

**Soluție**: rewrite cu API real (1-2 zile).
**Valoare**: HIGH — diferențiator PQ pentru P2P. Vezi `04_NEXT_STEPS_PROMPTS.md` P2.1.

### `16_hybrid_signature.zig` — hybrid_signature
**Probleme**:
- `secp256k1.sign(msg, sk)` — API real: `keypair.sign(message)` cu KeyPair instance
- `secp256k1.Signature.r` / `.s` ca `[32]u8` fields — API real folosește `r_be` și `s_be` sau Signature ca opaque
- `secp256k1.verify(msg, sig, pk)` — API real diferit
- `pq_crypto.MLDSA65` — există MlDsa87 dar nu MlDsa65; trebuie ajustat
- `allocator.duplicate` — nu există, e `allocator.dupe`

**Soluție**: rewrite cu API real (1 zi).
**Valoare**: HIGH — defense-in-depth pentru TX-uri în era PQ.

### `17_fast_sync.zig` — fast_sync
**Probleme**: scaffold-only — funcțiile sunt stub-uri (`downloadHeaders` doar pune entries fake în array, `downloadStateSnapshot` returnează gol, `verifySnapshot` returnează `true` mereu).

**Soluție**: implementare reală necesită integrare cu `sync.zig`, `state_trie.zig` și protocolul de network — proiect mare (2-3 zile minimum).
**Valoare**: MEDIUM — important dar nu blocker.

### `21_transaction.zig` extension — SighashFlag în transaction.zig
**Probleme**:
- Implementarea e incompletă — `// Hash each input` ca comentariu fără cod
- Avem deja `core/sighash.zig` (portat în primul batch) care e mai complet și se cuplează cu `core/transaction.zig` prin tipuri locale

**Soluție**: skip — folosim `core/sighash.zig` direct. Wire la `transaction.zig` doar dacă vrem helper inline; momentan nu e necesar.

### `22_build.zig` și `2-6_build.zig`, `9_build.zig`, `10_build.zig`, `23_build.zig`
**Probleme**: drafturi pentru `build.zig` aggregation fix. Trebuie unificate și aplicate manual la `build.zig` existent.

**Soluție**: sesiune dedicată la fix-uri build (vezi `04_NEXT_STEPS_PROMPTS.md` P0.1, 15-30 min).

### `27_oracle_fetcher.zig` — oracle_fetcher fix
**Probleme**: draft-ul propune `var cache: ... ` ca **field** într-un struct — sintaxa asta NU EXISTĂ în Zig (struct fields nu au `var`/`const`, declarațiile cu `var` ar fi static-storage la nivel de fișier).

**Soluție**: bug-ul real în `oracle_fetcher.zig` e altul (vezi MEMORY.md `test_run_2026_05_07`). Trebuie debug live, nu aplicat draftul.

## EIP-1559 — `26_eth_eip1559_demo.zig` + `19_test_eip1559.zig`

Draftul `26_eth_eip1559_demo.zig` are RLP encoder pentru EIP-1559 dar:
- Folosește `secp256k1.sign(hash, priv)` (API greșit)
- RLP encoding incomplet — `rlp.append(0xf8)` hard-coded list prefix, nu calculează lungimea reală
- Funcțiile helper `rlpEncodeU64` returnează slice către buf local (use-after-free)

**Soluție**: avem un RLP encoder corect în `core/evm_signer.zig` și `core/evm_rpc_client.zig`. EIP-1559 trebuie adăugat ca extensie folosind helper-ele existente. Vezi `04_NEXT_STEPS_PROMPTS.md` P1.4 (2-3h).

## Status total — 7 module noi în `core/`

Primul batch (sesiunea anterioară):
- `core/sighash.zig` (5 tests pass)
- `core/coin_control.zig` (6 tests pass)
- `core/segwit.zig` (5 tests pass + 6 bech32)

Al doilea batch (sesiunea curentă):
- `core/package_relay.zig` (5 tests pass)
- `core/slashing_evidence.zig` (4 tests pass)
- `core/double_ratchet.zig` (5 tests pass)
- `core/fee_estimator.zig` (5 tests pass)

**Total**: 7 module noi, 35 teste noi, toate pass individual.

## Următoarele acțiuni recomandate

1. Wire `core/sighash.zig` în `core/transaction.zig` (helper inline `tx.sighash(input_idx, flag, ...)`)
2. Wire `core/coin_control.zig` în `core/utxo.zig::UTXOSet.selectUTXOs` (skip frozen)
3. Wire `core/package_relay.zig` în `core/mempool.zig::canBeReplacedBy` (CPFP path)
4. Wire `core/slashing_evidence.zig` în `core/staking.zig` (slashing trigger via evidence)
5. Wire `core/double_ratchet.zig` în `core/encrypted_p2p.zig` (per-session forward secrecy)
6. Wire `core/fee_estimator.zig` în `core/mempool.zig` (record samples la block confirm) + RPC `estimate_fee`
7. Adaugă cele 7 module în `build.zig` `test-crypto` / `test-chain` / `test-net` aggregation
8. Fix `build.zig` parser issue (P0.1)
9. Rewrite `pq_handshake.zig` și `hybrid_signature.zig` cu API real (P2.1, P2.2)
