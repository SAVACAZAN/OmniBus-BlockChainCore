# 4. Wallet & Key Management

> OmniBus vs Bitcoin — Category 4/10
> Generated: 2026-03-31 19:42

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 61 | HD Wallet (BIP-32) | Y | Y | bip32_wallet.zig | Full HMAC-SHA512 derivation |
| 62 | Mnemonic (BIP-39) | Y | Y | bip32_wallet.zig | PBKDF2, 12 words |
| 63 | BIP-44 (Multi-coin) | Y | Y | bip32_wallet.zig | m/44'/coin'/0'/0/idx |
| 64 | BIP-49 (SegWit P2SH) | Y | P | - | Python script only (partial) |
| 65 | BIP-84 (Native SegWit) | Y | Y | bech32.zig | ob1q... addresses |
| 66 | BIP-86 (Taproot) | Y | Y | bech32.zig | ob1p... encoding ready |
| 67 | xpub / xprv | Y | Y | bip32_wallet.zig | serializeXpub/Xprv |
| 68 | WIF (Private Key Format) | Y | Y | bip32_wallet.zig | encodeWIF() |
| 69 | Master Fingerprint | Y | Y | bip32_wallet.zig | masterFingerprint() |
| 70 | Parent Fingerprint | Y | Y | bip32_wallet.zig | parentFingerprint() |
| 71 | Derivation Path String | Y | Y | bip32_wallet.zig | derivationPathString() |
| 72 | Script Pubkey | Y | Y | bip32_wallet.zig | deriveScriptPubkey() |
| 73 | Witness Version | Y | Y | wallet.zig | 0=SegWit, 1=Taproot |
| 74 | Address Type Detection | Y | Y | wallet.zig | NATIVE_SEGWIT, TAPROOT |
| 75 | Network (mainnet/testnet) | Y | Y | bip32_wallet.zig | Network enum |
| 76 | Passphrase (25th word) | Y | Y | bip32_wallet.zig | initFromMnemonicPassphrase |
| 77 | Key Encryption | Y | Y | key_encryption.zig | AES-256-GCM |
| 78 | Cold Storage / Vault | Y | Y | vault_reader.zig | Named Pipe from SuperVault |
| 79 | Multi-chain Derivation | N | + | - | 19 chains from 1 seed [EXTRA] |
| 80 | 5 PQ Domain Addresses | N | + | bip32_wallet.zig | coin_type 777-781 [EXTRA] |

---

**BTC has: 18 items**
**OmniBus: 19 implemented, 1 partial, 0 missing, 2 extras**
**Score: 105%** (19/18 BTC features + 2 unique extras)

### Extras (OmniBus-only):
- Multi-chain Derivation — 19 chains from 1 seed [EXTRA]
- 5 PQ Domain Addresses — coin_type 777-781 [EXTRA]

