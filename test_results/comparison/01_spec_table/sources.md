# Sources — Blockchain Comparison Table

All URLs verified accessible at time of writing. For metrics flagged as "controversial" (TPS, finality, TVL), the primary source is cited; secondary cross-checks where used are also listed.

---

## OmniBus
- **Local:** `1_CORE/BlockChainCore/core/chain_config.zig` — block_time_ms (1000), max_supply (21M OMNI in SAT), p2p (8333), rpc (8332), ws (8334), sub_blocks_per_block (10), halving_interval (126,144,000)
- **Local:** `CLAUDE.md` — BlockChainCore section: liboqs PQ schemes (ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768), secp256k1 ECDSA, JSON-RPC port 8332, mining pool Node.js
- **Local:** `1_CORE/BlockChainCore/ARCHITECTURE_DUAL_OS.md` (referenced from CLAUDE.md)
- **Note:** TPS / TVL / DAU all `null`/0 — no mainnet exists. Sub-block design (10×100ms) and 4-shard plan from CLAUDE.md highlights.

## Bitcoin
- Whitepaper: https://bitcoin.org/bitcoin.pdf
- Source: https://github.com/bitcoin/bitcoin
- TPS realistic: https://www.blockchain.com/explorer/charts/n-transactions-per-second
- BIP-340 Schnorr: https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki

## Ethereum
- Whitepaper: https://ethereum.org/en/whitepaper/
- Consensus specs: https://github.com/ethereum/consensus-specs
- TPS observed: https://etherscan.io
- EIP-1559: https://eips.ethereum.org/EIPS/eip-1559
- EIP-4844 blobs: https://eips.ethereum.org/EIPS/eip-4844

## MultiversX (EGLD)
- Whitepaper: https://multiversx.com/assets/files/multiversx-whitepaper.pdf
- Docs: https://docs.multiversx.com/
- Explorer: https://explorer.multiversx.com/
- 263k TPS: https://multiversx.com/blog/elrond-mainnet-stress-test (stress-test peak, not sustained)

## Solana
- Whitepaper: https://solana.com/solana-whitepaper.pdf
- TPS dashboard: https://solanacompass.com/statistics/tps
- Source: https://github.com/anza-xyz/agave
- Firedancer: https://jumpcrypto.com/firedancer/

## Sui
- Architecture: https://docs.sui.io/concepts/sui-architecture
- Source: https://github.com/MystenLabs/sui
- Mysticeti paper / blog: https://blog.sui.io/mysticeti-consensus/

## Optimism
- Docs: https://docs.optimism.io/
- Source: https://github.com/ethereum-optimism/optimism
- L2Beat (TVL, fees): https://l2beat.com/scaling/projects/optimism
- OP Stack: https://stack.optimism.io/

## Cardano
- Docs: https://docs.cardano.org/
- Ouroboros Praos paper: https://iohk.io/en/research/library/papers/ouroboros-praos/
- Explorer: https://cardanoscan.io/
- Plutus: https://plutus.readthedocs.io/

## Polygon PoS
- Site: https://polygon.technology/
- PoS docs: https://docs.polygon.technology/pos/
- Explorer: https://polygonscan.com/
- POL upgrade: https://polygon.technology/blog/polygon-2-0-tokenomics

## Avalanche (C-Chain)
- Docs: https://docs.avax.network/
- Source: https://github.com/ava-labs/avalanchego
- Explorer: https://snowtrace.io/
- Snowman/Avalanche papers: https://www.avalabs.org/whitepapers

## Aptos
- Docs: https://aptos.dev/
- Whitepaper: https://aptosfoundation.org/whitepaper
- Source: https://github.com/aptos-labs/aptos-core
- Block-STM paper: https://arxiv.org/abs/2203.06871

## NEAR
- Whitepaper: https://near.org/papers/the-official-near-white-paper
- Docs: https://docs.near.org/
- Explorer: https://nearblocks.io/
- Nightshade: https://near.org/papers/nightshade

## Cosmos Hub
- Whitepaper: https://cosmos.network/cosmos-whitepaper.pdf
- SDK docs: https://docs.cosmos.network/
- Explorer: https://www.mintscan.io/cosmos
- CometBFT: https://docs.cometbft.com/

## Polkadot
- Whitepaper: https://polkadot.com/papers/Polkadot-whitepaper.pdf
- Wiki: https://wiki.polkadot.network/
- Source: https://github.com/paritytech/polkadot-sdk
- GRANDPA paper: https://github.com/w3f/consensus

## QRL (Quantum Resistant Ledger)
- Whitepaper: https://www.theqrl.org/whitepaper/QRL_whitepaper.pdf
- Docs: https://docs.theqrl.org/
- XMSS RFC 8391: https://datatracker.ietf.org/doc/html/rfc8391
- NIST SP 800-208 (XMSS, LMS): https://csrc.nist.gov/publications/detail/sp/800-208/final
- Zond upgrade: https://www.theqrl.org/blog/qrl-zond/

## QANplatform
- PQ page: https://www.qanplatform.com/en/post-quantum-security
- Docs: https://docs.qanplatform.com/
- NIST FIPS 204 (ML-DSA / Dilithium): https://csrc.nist.gov/pubs/fips/204/final
- Note: QANX is currently an ERC-20 placeholder on Ethereum. Mainnet not live as of 2025-Q1.

## IOTA (Stardust / Rebased)
- Research: https://www.iota.org/foundation/research-papers
- Wiki: https://wiki.iota.org/
- Rebased upgrade: https://blog.iota.org/iota-rebased-upgrade/
- Coordicide: https://files.iota.org/papers/Coordicide_WP.pdf
- **Important correction:** IOTA's original Winternitz one-time hash-based signatures (PQ) were **abandoned with the Chrysalis upgrade (April 2021)**. Current chain (Stardust + Rebased 2025) uses Ed25519 (NOT PQ-resistant). PQ is on roadmap, not implemented.

---

## Methodology notes

- **TPS realistic** uses sustained on-chain non-vote/non-internal throughput where measurable. For Solana this means TrueTPS / non-vote tx per second.
- **Finality** is reported as the practical wait time before a transaction is irreversibly confirmed by major exchanges/applications, not just probabilistic.
- **TVL** values from DefiLlama-style aggregators where DeFi exists; "0" for chains without smart-contract DeFi.
- **Mainnet date** is the date of public mainnet token genesis, not testnet/devnet.
- **Where ambiguous**, the lower bound is reported, with notes flagging stress-test peaks vs. sustained values.
