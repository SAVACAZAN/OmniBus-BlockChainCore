# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.1.0] - 2026-03-30

### Added

- sub_block.zig â€” 10 Ã— 0.1s â†’ 1 KeyBlock + integrat in main (a5e66f3)
- p2p.zig â€” transport TCP real + integrat in main (78b1153)
- integreaza genesis + mempool + consensus in main.zig (bef7070)
- genesis + mempool + consensus â€” modulare, nu afecteaza trecutul (87e03e2)
- adauga BFT, Oracle, Slashing, Bots, MEV in arhitectura OMNI (555d2ab)
- corect parametri economici OMNI + doc arhitectura completa (4f5187f)
- Base58Check address encoding â€” match Python OmnibusWallet (a910943)
- genesis-ready â€” block reward, balance tracking, public RPC, miner registration (5d4984a)
- validateTransaction real, gettransactions RPC, database persistence (4f5d4a1)
