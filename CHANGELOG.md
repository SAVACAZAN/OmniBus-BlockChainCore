# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.2.0] - 2026-03-31

### Added — Bech32 Addresses + Full BTC Parity (115%)

**8 New Core Modules:**
- `bech32.zig` — Bech32/Bech32m encoder/decoder (BIP-173/350), HRP="ob"
- `utxo.zig` — Full UTXO set with address index, coin selection, coinbase maturity
- `psbt.zig` — Partially Signed Bitcoin Transactions (BIP-174), multisig workflow
- `block_filter.zig` — Compact Block Filters (BIP-157/158), GCS encoding
- `htlc.zig` — Hash Time-Locked Contracts + registry (Lightning prereq)
- `lightning.zig` — Lightning Network: channels, invoices, routing, liquidity
- `tor_proxy.zig` — Tor SOCKS5 proxy support, .onion detection
- `encrypted_p2p.zig` — BIP-324 encrypted P2P transport (ECDH + AES-256-GCM)

**Bech32 Address Migration:**
- Native OMNI (coin 777): `ob_omni_` -> `ob1q...` (42 chars, identical to BTC `bc1q`)
- PQ domains keep unique prefixes: `ob_k1_`, `ob_f5_`, `ob_d5_`, `ob_s3_`
- 346 test addresses migrated across 28 files

**Full BTC Wallet Metadata:**
- master_fingerprint, parent_fingerprint, network (OMNI/TOMNI)
- xpub/xprv extended key serialization (Base58Check) per domain
- WIF private key encoding, hash160, script_pubkey, witness_version
- Full derivation path string (m/44'/777'/0'/0/0)
- Passphrase support (BIP-39, was TODO)

**Transaction Upgrades:**
- RBF (Replace-By-Fee): sequence field, opt-in, mempool replacement
- CPFP (Child-Pays-For-Parent): package feerate calculation
- Change addresses: chain=1 derivation (deriveChangeAddress/Key)
- UTXO tracking integrated in blockchain.zig addBlock flow

**19-Chain Multi-Wallet:**
- `scripts/generate_multiwallet.py`: OMNI(5) + BTC(4) + ETH + SOL + ADA + DOT + EGLD + ATOM + XLM + XRP + BNB + OP + LTC(2) + DOGE + BCH
- 138 addresses from 1 mnemonic, account-based structure with xpub/xprv

**Comparison Tool:**
- `FULLBTCDEV/generate_comparison.py`: auto-scans 78 .zig modules vs Bitcoin
- 10 category reports: 115% BTC parity + 30 unique extras

### Changed
- `build.zig` — fixed WASM step (addLog not available in Zig 0.15)
- `blockchain.zig` — log truncation increased from 20 to 42 chars (full Bech32)
- `mempool.zig` — nonce per TX in test helpers (prevents RBF conflicts)

---

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
