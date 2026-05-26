# HTLC Stress Report

- chain: `testnet`
- rpc:   `https://omnibusblockchain.cc:8443/api-testnet`
- mode:  read-only
- ts:    2026-05-10T12:37:31.338Z

| pair | flow | opened | lockM | lockT | settled | refunded | timeout | failed | skipped |
|:--|---:|:--:|:--:|:--:|:--:|:--:|:--:|---:|---:|
| OMNI-ETH | 0 | y | · | · | · | · | · | 3 | 0 |
| OMNI-ETH | 1 | y | · | · | · | · | · | 2 | 0 |
| OMNI-ETH | 2 | y | · | · | · | · | · | 1 | 0 |
| OMNI-BTC | 0 | y | · | · | · | · | · | 3 | 0 |
| OMNI-BTC | 1 | y | · | · | · | · | · | 2 | 0 |
| OMNI-BTC | 2 | y | · | · | · | · | · | 1 | 0 |
| OMNI-LCX | 0 | y | · | · | · | · | · | 3 | 0 |
| OMNI-LCX | 1 | y | · | · | · | · | · | 2 | 0 |
| OMNI-LCX | 2 | y | · | · | · | · | · | 1 | 0 |

**Total**: open=9, lockMaker=0, lockTaker=0, settled=0, refunded=0, failed=18, skipped=0.

## Errors
### OMNI-ETH flow 0
- lockMaker: Missing param: swap_id
- lockTaker: Missing param: swap_id
- proveSettle: Missing param: swap_id
### OMNI-ETH flow 1
- lockMaker: Missing param: swap_id
- refund: missing htlc_id
### OMNI-ETH flow 2
- lockMaker: Missing param: swap_id
### OMNI-BTC flow 0
- lockMaker: Missing param: swap_id
- lockTaker: Missing param: swap_id
- proveSettle: Missing param: swap_id
### OMNI-BTC flow 1
- lockMaker: Missing param: swap_id
- refund: missing htlc_id
### OMNI-BTC flow 2
- lockMaker: Missing param: swap_id
### OMNI-LCX flow 0
- lockMaker: Missing param: swap_id
- lockTaker: Missing param: swap_id
- proveSettle: Missing param: swap_id
### OMNI-LCX flow 1
- lockMaker: Missing param: swap_id
- refund: missing htlc_id
### OMNI-LCX flow 2
- lockMaker: Missing param: swap_id