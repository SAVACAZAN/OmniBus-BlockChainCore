# 5. Transactions & Script

> OmniBus vs Bitcoin — Category 5/10
> Generated: 2026-03-31 16:50

| # | Component | BTC | OMNI | File | Notes |
|:-:|-----------|:---:|:----:|------|-------|
| 81 | UTXO Model | Y | Y | state_trie.zig | Account-based (partial UTXO) |
| 82 | Transaction Inputs | Y | Y | transaction.zig | from_address |
| 83 | Transaction Outputs | Y | Y | transaction.zig | to_address + amount |
| 84 | Transaction Fee | Y | Y | transaction.zig | 50% burn + 50% miner |
| 85 | Change Address (chain=1) | Y | N | - | NOT YET IMPLEMENTED |
| 86 | Satoshi unit (1e9) | Y | Y | transaction.zig | 1 OMNI = 1e9 SAT |
| 87 | Bitcoin Script (language) | Y | Y | script.zig | P2PKH opcodes |
| 88 | OP_CHECKSIG | Y | Y | script.zig | ECDSA verification |
| 89 | OP_RETURN (data embed) | Y | Y | transaction.zig | Max 80 bytes |
| 90 | Locktime | Y | Y | transaction.zig | Block-height timelock |
| 91 | Nonce (anti-replay) | Y | Y | transaction.zig | Nonce field |
| 92 | Sequence Number | Y | N | - | NOT YET |
| 93 | Witness Data (SegWit) | Y | Y | transaction.zig | script_sig field (partial) |
| 94 | Replace-By-Fee (RBF) | Y | N | - | NOT YET |
| 95 | Child-Pays-For-Parent | Y | N | - | NOT YET |
| 96 | vSize / Weight Units | Y | Y | block.zig | Sub-block weight (partial) |
| 97 | Dust Limit | Y | Y | blockchain.zig | Anti-spam threshold |
| 98 | TX Signing (ECDSA) | Y | Y | transaction.zig | sign() method |
| 99 | TX Verification | Y | Y | transaction.zig | verify() method |
| 100 | TX Hash (TXID) | Y | Y | transaction.zig | SHA256d hash |

---

**BTC has: 20 items**
**OmniBus: 16 implemented, 0 partial, 4 missing, 0 extras**
**Score: 80%** (16/20 BTC features)

### Missing (TODO):
- [ ] Change Address (chain=1) — NOT YET IMPLEMENTED
- [ ] Sequence Number — NOT YET
- [ ] Replace-By-Fee (RBF) — NOT YET
- [ ] Child-Pays-For-Parent — NOT YET

