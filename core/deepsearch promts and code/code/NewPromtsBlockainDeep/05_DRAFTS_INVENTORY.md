# 05 — Inventar drafturi în `code/` și destinație

Snapshot: 2026-05-19

Drafturile din `core/deepsearch promts and code/code/` (acest director părinte) sunt scheme
neintegrate. Fiecare are o destinație clară: fie `core/` (L1 OmniBus), fie `wallet-core/`
(repo separat pentru multi-chain wallet).

## Grupa A — OmniBus L1 internals → `core/` (de portat ACUM)

| Draft (în code/) | Destinație | LOC | Status |
|------------------|------------|-----|--------|
| `sighash.zig` | `core/sighash.zig` | 11540 | TO PORT |
| `coin_control.zig` | `core/coin_control.zig` | 11168 | TO PORT |
| `segwit.zig` | `core/segwit.zig` | 11382 | TO PORT |
| `tx_builder.zig` (stub mic) | merge în `core/transaction.zig` ca extensie | 267 | STUB — needs filling |
| `23_test_sighash.zig` | test pentru `core/sighash.zig` | 1902 | TO PORT |
| `24_test_coin_control.zig` | test pentru `core/coin_control.zig` | 3518 | TO PORT |

## Grupa B — BTC stack → `wallet-core/btc/` (repo SEPARAT)

Drafturile cu prefix BTC sunt rețete pentru wallet-core/btc/. NU se pun în BlockChainCore/core/.

| Draft | Destinație în wallet-core | Conținut |
|-------|---------------------------|----------|
| `25_btc_wallet_demo.zig` | examples/btc_demo.zig | Demo cum se folosește stack-ul |
| `30_btc.rpc.RpcConfig` | wallet-core/btc/rpc_client.zig | RpcConfig struct |
| `31_btc.address.deriveP2WP` | wallet-core/btc/address.zig | deriveP2WPKH |
| `32_btc.tx_builder.TxBuilder.init` | wallet-core/btc/tx_builder.zig | TxBuilder.init |
| `33_btc_client.getBalance` | wallet-core/btc/rpc_client.zig | getBalance method |
| `45_BTC_INTEGRATION.md` | wallet-core/btc/README.md | Doc |
| `46_btc_address.deriveP2TR` | wallet-core/btc/address.zig | deriveP2TR (taproot) |
| `47_bip39.mnemonicTo` | folosește bip32_wallet existent | reference |
| `48_btc_rpc.BtcRpcClient.init` | wallet-core/btc/rpc_client.zig | Init pattern |
| `49_btc_tx.TxBuilder.init` | wallet-core/btc/tx_builder.zig | TxBuilder init |
| `50_builder.sign` | wallet-core/btc/tx_builder.zig | sign method (BIP-143) |
| `51_rpc.sendTransa` | wallet-core/btc/rpc_client.zig | sendRawTransaction |
| `52_rpc.estimateFe` | wallet-core/btc/fee_estimator.zig | estimateSmartFee |
| `53_btc_fee.FeeEstimator.init` | wallet-core/btc/fee_estimator.zig | Init |
| `54_btc_utils.TxSizeEstimator.estimateP2...` | wallet-core/btc/tx_size.zig | estimateP2WPKH/P2TR vbytes |

## Grupa C — ETH stack → `wallet-core/eth/` (repo SEPARAT)

| Draft | Destinație |
|-------|------------|
| `19_test_eip1559.zig` | test pentru `core/evm_signer.zig` extension SAU `wallet-core/eth/tx_builder.zig` |
| `20_test_erc20.zig` | wallet-core/eth/erc20_test.zig |
| `26_eth_eip1559_demo.zig` | examples/eth_demo.zig |
| `34_eth.address.deriveAddr` | wallet-core/eth/address.zig (sau extension la evm_signer.zig) |
| `35_eth.tx_builder.EthTxBuilder.init` | wallet-core/eth/tx_builder.zig (EIP-1559) |
| `36_eth.erc20.Erc20TxBuilder.init` | wallet-core/eth/erc20.zig |

**Notă**: Pentru ETH avem deja `core/evm_signer.zig` (legacy) + `core/evm_rpc_client.zig`.
Două opțiuni:
- **Opțiunea 1 (recomandată)**: Extinde `core/evm_signer.zig` cu EIP-1559 (rămâne în L1
  pentru că OmniBus DEX folosește direct EVM bridge-uri Sepolia/Base/LCX/Arc)
- **Opțiunea 2**: Mută tot în `wallet-core/eth/` și `core/evm_signer.zig` rămâne basic

Decizie: **Opțiunea 1** — EIP-1559 este folosit de DEX-ul OmniBus pe chain-urile EVM.
Deci `19_test_eip1559.zig` se portează ca extensie la `core/evm_signer.zig`.

## Grupa D — SOL stack → `wallet-core/sol/` (repo SEPARAT)

| Draft | Destinație |
|-------|------------|
| `1_ed25519.zig` | wallet-core/sol/ed25519.zig (wrapper peste std.crypto) |
| `2_borsh.zig` | wallet-core/sol/borsh.zig |
| `3_address.zig` (Solana) | wallet-core/sol/address.zig |
| `4_instruction.zig` | wallet-core/sol/instruction.zig |
| `5_tx_builder.zig` (Solana) | wallet-core/sol/tx_builder.zig |
| `6_rpc_client.zig` (Solana) | wallet-core/sol/rpc_client.zig |
| `7_program.zig` (Solana) | wallet-core/sol/program.zig |
| `8_commitment.zig` | wallet-core/sol/commitment.zig |
| `21_test_address.zig` (Solana) | wallet-core/sol/address_test.zig |
| `27_sol_wallet_demo.zig` | examples/sol_demo.zig |
| `37_sol.address.AddressGenerator.init` | wallet-core/sol/address.zig |
| `38_sol.address.findProgra` | wallet-core/sol/address.zig (findProgramAddress / PDA) |
| `39_sol.tx_builder.TxBuilder.init` | wallet-core/sol/tx_builder.zig |

## Grupa E — TON stack → `wallet-core/ton/` (repo SEPARAT)

| Draft | Destinație |
|-------|------------|
| `9_cell.zig` | wallet-core/ton/cell.zig |
| `10_tl_b.zig` | wallet-core/ton/tl_b.zig |
| `11_address.zig` (TON) | wallet-core/ton/address.zig |
| `12_contract.zig` (TON) | wallet-core/ton/contract.zig |
| `13_tx_builder.zig` (TON) | wallet-core/ton/tx_builder.zig |
| `14_rpc_client.zig` (TON) | wallet-core/ton/rpc_client.zig |
| `15_jetton.zig` | wallet-core/ton/jetton.zig |
| `16_test_address.zig` (TON) | wallet-core/ton/address_test.zig |
| `17_test_tx_builder.zig` | wallet-core/ton/tx_builder_test.zig |
| `18_test_rpc.zig` | wallet-core/ton/rpc_client_test.zig |
| `22_test_cell.zig` | wallet-core/ton/cell_test.zig |
| `28_ton_wallet_demo.zig` | examples/ton_demo.zig |
| `40_ton.address.TonAddress.init` | wallet-core/ton/address.zig |
| `41_ton.cell.CellBuilder.init` | wallet-core/ton/cell.zig |
| `42_ton.cell.CellBuilder.init` (dup) | wallet-core/ton/cell.zig |

## Grupa F — Docs

| Draft | Destinație |
|-------|------------|
| `29_WALLET_API.md` | wallet-core/README.md |
| `43_block.txt` (excerpt) | reference, no port |
| `44_toncenter.com` (URL) | reference, no port |
| `45_BTC_INTEGRATION.md` | wallet-core/btc/README.md |

## Ordinea de execuție (în această sesiune)

1. ✅ Doc-uri NewPromtsBlockainDeep create (00-04)
2. ✅ Inventory (acest fișier 05)
3. → Port `code/sighash.zig` → `core/sighash.zig` (+ test)
4. → Port `code/coin_control.zig` → `core/coin_control.zig` (+ test)
5. → Port `code/segwit.zig` → `core/segwit.zig` (+ test)
6. → Compile check pe fiecare (`zig test core/<file>.zig`)
7. → STOP — grupele B/C/D/E necesită un repo nou `wallet-core/`, sesiune separată

Drafturile BTC/ETH/SOL/TON le marcăm ca "rămase pentru wallet-core" — vor fi atacate
într-o sesiune dedicată odată ce L1 OmniBus extension (sighash/coin_control/segwit) compilează.
