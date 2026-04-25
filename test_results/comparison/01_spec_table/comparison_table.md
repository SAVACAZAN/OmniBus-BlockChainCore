# Blockchain Comparison Table — 17 Chains

**Generated:** 2026-04-25
**Data as-of:** 2025-Q1
**Methodology:** TPS-realistic = sustained mainnet observed (block explorers / public benchmarks). TPS-theoretical = whitepaper / docs claim. Finality = practical wait (not just probabilistic).
**Honesty note:** OmniBus is **testnet/devnet only** — no mainnet exists. All OmniBus economic / TVL / TPS-realistic values are `null` or `0`.

---

## 1. Performance

| Chain | Block time | TPS theoretical | TPS realistic | Finality |
|---|---|---|---|---|
| **OmniBus** | 1000 ms (sub-block 100 ms) | n/a | n/a (no mainnet) | ~1 s (design) |
| Bitcoin | 600 000 ms | 7 | ~4.6 | ~3600 s (6 conf) |
| Ethereum | 12 000 ms | 30 | ~15 | 900 s (2 epochs) |
| MultiversX (EGLD) | 6 000 ms | 263 000 (peak) | ~30 000 (peak) | ~6 s |
| Solana | 400 ms | 65 000 | 1 500–3 000 | ~13 s |
| Sui | 390 ms | 297 000 (peak) | 500–1 500 | <1 s |
| Optimism | 2 000 ms | ~2 000 | 10–20 | 7 days (challenge) |
| Cardano | 20 000 ms | 250 | ~7 | ~720 s |
| Polygon PoS | 2 000 ms | 7 000 | 30–100 | ~256 s |
| Avalanche C-Chain | ~2 000 ms | 4 500 | 10–50 | <2 s |
| Aptos | 250 ms | 160 000 (peak) | 1 000–3 000 | ~1 s |
| NEAR | 1 100 ms | 100 000 (sharded) | 50–200 | ~2 s |
| Cosmos Hub | 6 000 ms | 10 000 | ~30 | 6 s |
| Polkadot | 6 000 ms | 1 000 000 (full set) | ~100 | ~60 s |
| **QRL** | 60 000 ms | 70 | ~1 | ~600 s |
| **QANplatform** | 3 000 ms | 1 600 | n/a (no mainnet) | ~3 s |
| **IOTA (Rebased)** | 200 ms | ~1 000 | ~20 | ~5 s |

---

## 2. Architecture

| Chain | Consensus | VM | Sharding | Layer | Language |
|---|---|---|---|---|---|
| **OmniBus** | PoUW + sub-blocks | native | planned (4) | L1 | Zig |
| Bitcoin | PoW (SHA-256d) | Script | no | L1 | C++ |
| Ethereum | PoS (Gasper) | EVM | no (blobs only) | L1 | Go/Rust/Java |
| MultiversX | Secure PoS | WASM | yes (3+meta) | L1 | Go |
| Solana | PoH + Tower BFT | SVM (BPF) | no | L1 | Rust |
| Sui | Mysticeti DAG-BFT | MoveVM | no (object-parallel) | L1 | Rust |
| Optimism | OP Rollup | EVM | no | L2 (Eth) | Go/Rust |
| Cardano | Ouroboros Praos | Plutus (UTxO) | no (Hydra L2) | L1 | Haskell |
| Polygon PoS | Tendermint+Bor | EVM | no | sidechain | Go |
| Avalanche C | Snowman | EVM | no (subnets) | L1 | Go |
| Aptos | AptosBFT (Jolteon) | MoveVM + Block-STM | no | L1 | Rust |
| NEAR | Doomslug + PoS | WASM | yes (6 shards) | L1 | Rust |
| Cosmos Hub | CometBFT | CosmWasm | no (zones via IBC) | L1 | Go |
| Polkadot | BABE + GRANDPA | WASM | yes (~50 parachains) | L0+parachains | Rust |
| QRL | PoS (post-Zond) | EVM | no | L1 | Python/Go |
| QANplatform | PoR (BFT) | QVM (multi-lang) | no | L1 (testnet) | Rust |
| IOTA Rebased | Mysticeti DAG-BFT | MoveVM | no | L1 | Rust |

---

## 3. Crypto

| Chain | Signature | Hash | PQ-resistant? | PQ scheme |
|---|---|---|---|---|
| **OmniBus** | secp256k1 ECDSA + liboqs PQ | SHA-256, Blake3 | **YES** (native) | ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768 |
| Bitcoin | secp256k1 ECDSA + Schnorr | SHA-256, RIPEMD-160 | no | — |
| Ethereum | secp256k1 + BLS12-381 | Keccak-256 | no | — |
| MultiversX | BLS + Ed25519 | Blake2b, Keccak | no | — |
| Solana | Ed25519 | SHA-256, Blake3 | no | — |
| Sui | Ed25519/ECDSA/BLS/zkLogin | Blake2b | no | — |
| Optimism | secp256k1 (inherits Eth) | Keccak-256 | no | — |
| Cardano | Ed25519 + KES + VRF | Blake2b-256 | no | — |
| Polygon PoS | secp256k1 + BLS | Keccak-256 | no | — |
| Avalanche | secp256k1 + BLS (Warp) | Keccak/SHA-256 | no | — |
| Aptos | Ed25519/secp256k1/BLS | SHA-3, Blake3 | no | — |
| NEAR | Ed25519, secp256k1 | SHA-256 | no | — |
| Cosmos Hub | secp256k1, Ed25519 | SHA-256 | no | — |
| Polkadot | sr25519 / Ed25519 / ECDSA | Blake2b, Keccak | no | — |
| **QRL** | XMSS (hash-based, RFC 8391) | SHA-256, SHAKE-128 | **YES** (live since 2018) | XMSS stateful; Dilithium planned (Zond) |
| **QANplatform** | CRYSTALS-Dilithium (ML-DSA) | SHA-3 | **YES** (testnet) | ML-DSA / FIPS 204 |
| IOTA Rebased | Ed25519 (current) | Blake2b | **NO** (Winternitz abandoned) | PQ on roadmap, not live |

---

## 4. Economics

| Chain | Max supply | Block reward (current) | Halving | Avg fee USD |
|---|---|---|---|---|
| **OmniBus** | 21 M OMNI | 0.00833333 OMNI | every 126 144 000 blocks | n/a |
| Bitcoin | 21 M BTC | 3.125 BTC | every 210 000 blocks | ~$1.50 |
| Ethereum | unlimited (deflationary) | ~0 net (issuance ≈ burn) | none | ~$2.00 |
| MultiversX | 31.42 M EGLD | decreasing schedule | none | ~$0.001 |
| Solana | unlimited (5%→1.5%) | inflation + fees | none | ~$0.00025 |
| Sui | 10 B SUI | stake + storage fund | none | ~$0.001 |
| Optimism | 4.29 B OP | sequencer fees only | none | ~$0.05 |
| Cardano | 45 B ADA | reserve decay + fees | none | ~$0.15 |
| Polygon PoS | 10 B POL | inflation + fees | none | ~$0.02 |
| Avalanche | 720 M AVAX | stake + fees (burn) | none | ~$0.05 |
| Aptos | unlimited (capped curve) | ~7%/y stake | none | ~$0.00012 |
| NEAR | 1 B + 5%/y | 5% inflation | none | ~$0.0008 |
| Cosmos Hub | unlimited (7-20%) | inflation | none | ~$0.005 |
| Polkadot | unlimited (~10%) | stake + treasury | none | ~$0.05 |
| QRL | 105 M QRL | decreasing | smooth decay | ~$0.005 |
| QANplatform | 3.33 B QANX (ERC-20) | n/a (no mainnet) | none | n/a |
| IOTA | 4.6 B IOTA | validator rewards | none | ~$0.001 |

---

## 5. Networking

| Chain | P2P protocol | P2P port | RPC protocol |
|---|---|---|---|
| **OmniBus** | custom TCP (magic "OMNI") | 8333 | JSON-RPC 2.0 (port 8332) |
| Bitcoin | custom TCP | 8333 | JSON-RPC over HTTP |
| Ethereum | devp2p/RLPx + libp2p (CL) | 30303 | JSON-RPC 2.0 |
| MultiversX | libp2p | 37373 | REST + WebSocket |
| Solana | Gulf Stream / QUIC | 8001 | JSON-RPC + WS |
| Sui | anemo (QUIC) | 8084 | JSON-RPC + GraphQL |
| Optimism | libp2p | 9003 | JSON-RPC 2.0 |
| Cardano | Ouroboros networking | 3001 | Ogmios WS / Blockfrost |
| Polygon PoS | devp2p + Tendermint | 30303 | JSON-RPC 2.0 |
| Avalanche | TCP (custom) | 9651 | JSON-RPC 2.0 |
| Aptos | AptosNet (Noise) | 6180 | REST (OpenAPI) |
| NEAR | custom TCP | 24567 | JSON-RPC 2.0 |
| Cosmos Hub | Tendermint p2p | 26656 | RPC + gRPC + REST |
| Polkadot | libp2p | 30333 | Substrate JSON-RPC + WS |
| QRL | custom TCP | 19000 | gRPC |
| QANplatform | libp2p | n/a | JSON-RPC + REST |
| IOTA Rebased | libp2p | 15600 | REST + gRPC |

---

## 6. Ecosystem

| Chain | TVL USD | Daily active addr. | Mainnet | Audit |
|---|---|---|---|---|
| **OmniBus** | $0 | 0 | **NONE (testnet only)** | none |
| Bitcoin | ~$6 B (defi) | ~850 k | 2009 | most-reviewed; no formal verif |
| Ethereum | ~$60 B | ~450 k | 2015 | spec-tested + audits |
| MultiversX | ~$80 M | ~25 k | 2020 | Trail of Bits + others |
| Solana | ~$8 B | ~1.5 M | 2020 | multiple audits |
| Sui | ~$1.5 B | ~400 k | 2023 | OtterSec, Zellic |
| Optimism | ~$850 M | ~80 k | 2021 | Sigma Prime, ToB, Spearbit |
| Cardano | ~$350 M | ~35 k | 2017 | peer-reviewed papers |
| Polygon PoS | ~$800 M | ~350 k | 2020 | multiple audits |
| Avalanche C | ~$1.1 B | ~60 k | 2020 | ToB, Halborn |
| Aptos | ~$1.0 B | ~600 k | 2022 | Move Prover + audits |
| NEAR | ~$200 M | ~1.5 M | 2020 | Halborn, ToB |
| Cosmos Hub | ~$50 M (hub) | ~8 k | 2019 | Informal Systems |
| Polkadot | ~$150 M | ~15 k | 2020 | SR Labs, Halborn, ToB |
| QRL | ~$0 | ~200 | 2018 | X1 Five Bears (XMSS) |
| QANplatform | $0 | n/a | **NONE (testnet)** | internal only |
| IOTA Rebased | ~$50 M | ~5 k | May 2025 (Rebased) | multiple over years |

---

## Summary

### Stats

- **17 chains catalogued** (OmniBus + 6 user-requested + 10 recommended).
- **PQ-resistant chains: 3** with live PQ crypto (OmniBus, QRL) and 1 with PQ on testnet (QANplatform). IOTA's PQ legacy was abandoned.
- **Highest sustained TPS** observed in production:
  1. **Solana** ~1 500–3 000 sustained, peaks ~7 000
  2. **Aptos** ~1 000–3 000 sustained
  3. **Sui** ~500–1 500 sustained
  (MultiversX claims 263k peak in stress test but is not sustained.)
- **Sub-second finality:** Sui, Aptos, Avalanche C-Chain, OmniBus (design).

### Honest takes

- **OmniBus** has best PQ story on paper (4 NIST schemes) but **zero economic security and no mainnet** — purely a research / dev project at 2025-Q1.
- **QRL** has the longest live PQ track record (since 2018) but tiny ecosystem and 2-4 KB signatures hurt UX.
- **IOTA** is widely cited as PQ — **this is incorrect post-Chrysalis**: current Ed25519 sigs are not PQ. Marketing legacy from Winternitz era.
- **Solana** "65k TPS" includes vote tx; user-facing throughput is ~10x lower but still highest of any L1.
- **Polkadot** "1M TPS" requires the full parachain set fully utilized — observed <100 TPS aggregate in practice.
- **MultiversX** 263k TPS is a stress-test peak with idle shards, not real production load.

### Files

- `comparison_table.md` (this file)
- `comparison_data.json` — structured data for dashboard
- `sources.md` — citation list per chain
