# OmniBus Multi-Chain Wallet API Documentation

## Overview

OmniBus wallet supports multiple blockchains through a unified interface. Currently supported chains:

- **OmniBus** (Native L1) - Full support
- **Bitcoin** - P2WPKH, P2TR addresses, transaction building, RPC
- **Ethereum** - Legacy and EIP-1559 transactions, ERC-20 tokens
- **Solana** - Address generation, PDAs, transaction building
- **TON** - Bounceable/non-bounceable addresses, Cell serialization
- **LCX Liberty** - EVM compatible

## Quick Start

### Initialization

```zig
const wallet = @import("wallet");
const btc = @import("wallet/btc");
const eth = @import("wallet/eth");

// Bitcoin
const btc_config = btc.rpc.RpcConfig{
    .url = "http://localhost:8332",
    .username = "user",
    .password = "pass",
    .network = .testnet,
};
var btc_client = try btc.rpc.BtcRpcClient.init(allocator, btc_config);

// Ethereum
const eth_config = eth.rpc.RpcConfig{
    .url = "https://mainnet.infura.io/v3/YOUR_KEY",
    .chain_id = 1,
};
var eth_client = try eth.rpc.EthRpcClient.init(allocator, eth_config);