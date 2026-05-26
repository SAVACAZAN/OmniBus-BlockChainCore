# 02 — Module ÎN CURS DE IMPLEMENTARE

Snapshot: 2026-05-19

## A. Parțial implementate în `core/` (🟡 PARTIAL)

### A1. `core/evm_signer.zig` — EVM signing
- **Ce e**: ECDSA + EIP-155 chain_id, recovery_id parity v=27/28
- **Lipsește**: EIP-1559 dynamic fee (`max_fee_per_gas`, `max_priority_fee_per_gas`)
- **Impact**: Pe Sepolia / Base Sepolia trimitem doar legacy TX — pe mainnet ETH ar fi suboptim
- **Effort**: 2-3h

### A2. `core/transaction.zig` — SIGHASH flags
- **Ce e**: Single mod implicit (echivalent SIGHASH_ALL)
- **Lipsește**: SIGHASH_NONE / SINGLE / ANYONECANPAY + combinații
- **Impact**: Nu se pot face TX-uri parțiale (e.g. partial-fill orders)
- **Effort**: 3-4h

### A3. `core/script.zig` — P2WPKH + P2TR
- **Ce e**: P2PKH, P2SH, multisig
- **Lipsește**: P2WPKH (segwit native), P2TR (taproot via `schnorr.zig`)
- **Impact**: `schnorr.zig` există dar nu poate fi folosit la nivelul script
- **Effort**: 4-6h

### A4. `core/chain_config.zig::FeeEstimator` — Fee estimation
- **Ce e**: Estimator simplu bazat pe mempool pressure
- **Lipsește**: Priority classes (slow / normal / fast), sat/vbyte real, târg de prețuri
- **Impact**: Userii plătesc fie prea mult, fie prea puțin
- **Effort**: 4h, separat în `core/fee_estimator.zig`

### A5. `core/encrypted_p2p.zig` — PQ Hybrid Handshake
- **Ce e**: Noise-style symmetric encryption clasic
- **Lipsește**: Hybrid KEM (X25519 + ML-KEM-768), session key ratcheting
- **Impact**: P2P transport NU e PQ-resistant — diferențiatorul OmniBus dispare
- **Effort**: 1-2 zile

### A6. `core/sync.zig` — Sync enhancements
- **Ce e**: Block sync basic, request + apply
- **Lipsește**: Fast sync (headers + state snapshot), warp sync, checkpoint sync, batching
- **Impact**: Nodurile noi sync foarte încet din genesis
- **Effort**: 2-3 zile

### A7. `core/mempool.zig` — package relay (CPFP)
- **Ce e**: RBF există, orphan tracking există
- **Lipsește**: Child-pays-for-parent (CPFP), persistence între restarts
- **Impact**: TX-urile blocate cu fee mic nu pot fi salvate de copii cu fee mare
- **Effort**: 1 zi

## B. Module experimentale (🟣) — există ca draft, neintegrate

În `core/deepsearch promts and code/code/` (acest director părinte) sunt fișiere numerotate cu draft-uri:

| Fișier | Pentru ce |
|--------|-----------|
| `1_ed25519.zig` | Ed25519 wrapper (necesar SOL / TON) |
| `2_borsh.zig` | Borsh serializer (Solana) |
| `3_address.zig` (multiple) | Adrese SOL / TON |
| `4_instruction.zig` | Solana instruction builder |
| `5_tx_builder.zig` | TX builder generic |
| `10_tl_b.zig` | TON TL-B serializer |
| `12_contract.zig` | TON contract (wallet/jetton/nft) |
| `13_tx_builder.zig`, `14_rpc_client.zig`, `15_jetton.zig` | TON stack |
| `19_test_eip1559.zig` | Teste EIP-1559 (pre-pregătite) |
| `20_test_erc20.zig`, `21-22` | ERC-20 + cell |
| `23_test_sighash.zig` | Teste SIGHASH multi-mode |
| `24_test_coin_control.zig` | Teste coin control |
| `25-28_*demo.zig` | Demo-uri BTC/ETH/SOL/TON wallet |
| `29_WALLET_API.md`, `45_BTC_INTEGRATION.md` | Documentație API |

**Status**: aceste fișiere NU sunt în `core/` și NU compilează cu `zig build`.
Sunt schițe / referințe pentru implementarea modulelor lipsă.
**Decizie**: să fie portate fie în `core/` (pentru ce extinde L1), fie într-un repo nou
`wallet-core/` (pentru chain integrations BTC/SOL/TON).

## C. Lucru activ pe branch `feat/onchain-orderbook`

Commits recente:
- `3e91909` core(dex): deploy on LCX Liberty Chain + ETH e2e live on 6 chains
- `72a52c9` core(dex): deploy DEX on Soneium Minato + add Arc Testnet config
- `2621572` core(dex_settler): granular logging for submitSettle debug
- `cab9471` core(dex): deploy DEX on Arb + OP Sepolia
- `25121dd` core(fills_log): record actual escrow chain_id

Concentrare: **DEX cross-chain deploy + settlement debugging**. NU se lucrează pe wallet
multi-chain sau PQ-hybrid handshake.

## D. Issues cunoscute (din MEMORY.md)

- **Build aggregation broken** în `build.zig` (parser issue) — toate modulele individual pass,
  dar `zig build test` falie aggregation. Fix estimat 15-30 min. (vezi memory `test_status_2026_05_11`)
- **oracle_fetcher const/mutable blocker** (vezi `test_run_2026_05_07`)
- **dns_registry test mismatch** (vezi `test_run_2026_05_07`)
