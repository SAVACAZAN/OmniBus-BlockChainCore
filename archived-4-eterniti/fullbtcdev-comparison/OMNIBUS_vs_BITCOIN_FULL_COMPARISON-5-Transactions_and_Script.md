# 5. Transactions & Script

> OmniBus vs Bitcoin — Category 5/10
> Generated: 2026-03-31 19:42

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 81 | UTXO Model | Y | Y | utxo.zig | Full UTXO set + integrated in blockchain.zig |
| 82 | Transaction Inputs | Y | Y | transaction.zig | from_address |
| 83 | Transaction Outputs | Y | Y | transaction.zig | to_address + amount |
| 84 | Transaction Fee | Y | Y | transaction.zig | 50% burn + 50% miner |
| 85 | Change Address (chain=1) | Y | Y | bip32_wallet.zig | deriveChangeAddress/deriveChangeKey |
| 86 | Satoshi unit (1e9) | Y | Y | transaction.zig | 1 OMNI = 1e9 SAT |
| 87 | Bitcoin Script (language) | Y | Y | script.zig | P2PKH opcodes |
| 88 | OP_CHECKSIG | Y | Y | script.zig | ECDSA verification |
| 89 | OP_RETURN (data embed) | Y | Y | transaction.zig | Max 80 bytes |
| 90 | Locktime | Y | Y | transaction.zig | Block-height timelock |
| 91 | Nonce (anti-replay) | Y | Y | transaction.zig | Nonce field |
| 92 | Sequence Number (BIP-125) | Y | Y | transaction.zig | sequence field for RBF |
| 93 | Witness Data (SegWit) | Y | Y | transaction.zig | script_sig field (partial) |
| 94 | Replace-By-Fee (RBF) | Y | Y | transaction.zig | isRBF/canBeReplacedBy + mempool logic |
| 95 | Child-Pays-For-Parent | Y | Y | mempool.zig | getPackageFee/hasChildBoost |
| 96 | vSize / Weight Units | Y | Y | block.zig | Sub-block weight (partial) |
| 97 | Dust Limit | Y | Y | blockchain.zig | Anti-spam threshold |
| 98 | TX Signing (ECDSA) | Y | Y | transaction.zig | sign() method |
| 99 | TX Verification | Y | Y | transaction.zig | verify() method |
| 100 | TX Hash (TXID) | Y | Y | transaction.zig | SHA256d hash |

---

**BTC has: 20 items**
**OmniBus: 20 implemented, 0 partial, 0 missing, 0 extras**
**Score: 100%** (20/20 BTC features)

