# 10. BIP Standards Compliance

> OmniBus vs Bitcoin — Category 10/10
> Generated: 2026-03-31 18:17

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 181 | BIP-32 (HD Wallets) | Y | Y | bip32_wallet.zig | Full implementation |
| 182 | BIP-39 (Mnemonic) | Y | Y | bip32_wallet.zig | 12-word, PBKDF2 |
| 183 | BIP-44 (Multi-coin paths) | Y | Y | bip32_wallet.zig | m/44'/coin'/0'/0/idx |
| 184 | BIP-49 (SegWit P2SH) | Y | P | - | Python only (partial) |
| 185 | BIP-84 (Native SegWit) | Y | Y | bech32.zig | ob1q... addresses |
| 186 | BIP-86 (Taproot paths) | Y | Y | bech32.zig | ob1p... ready |
| 187 | BIP-141 (SegWit) | Y | Y | bech32.zig | Witness v0/v1 |
| 188 | BIP-173 (Bech32) | Y | Y | bech32.zig | Full encoder/decoder |
| 189 | BIP-350 (Bech32m) | Y | Y | bech32.zig | Taproot encoding |
| 190 | BIP-340 (Schnorr) | Y | Y | schnorr.zig | Schnorr signatures |
| 191 | BIP-125 (RBF) | Y | Y | transaction.zig | sequence + opt-in RBF |
| 192 | BIP-174 (PSBT) | Y | Y | psbt.zig | Partially Signed TX, multisig workflow |
| 193 | BIP-324 (V2 P2P) | Y | Y | encrypted_p2p.zig | ECDH + AES-256-GCM |
| 194 | BIP-152 (Compact Blocks) | Y | Y | binary_codec.zig | Binary codec |
| 195 | BIP-157/158 (Block Filters) | Y | Y | block_filter.zig | GCS filters + header chain |
| 196 | BIP-199 (HTLC) | Y | Y | htlc.zig | Hash Time-Locked Contracts |

---

**BTC has: 16 items**
**OmniBus: 15 implemented, 1 partial, 0 missing, 0 extras**
**Score: 93%** (15/16 BTC features)

