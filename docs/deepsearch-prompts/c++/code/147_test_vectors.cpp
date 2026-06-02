// OEP-1 143/150 | path=docs/API.md | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
<!-- OEP-1 143/150 | path=docs/API.md | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1 -->
# OmniBus C++ Node API Documentation

## RPC Methods

### Native OmniBus RPC (port 8332)

#### Blockchain
- `getblockhash(height)` - Returns block hash at given height
- `getblock(block_hash)` - Returns block data
- `getblockcount()` - Returns current chain height
- `getbestblockhash()` - Returns best block hash

#### Transactions
- `getrawtransaction(txid)` - Returns raw transaction data
- `sendrawtransaction(hex)` - Broadcasts raw transaction
- `getbalance(address)` - Returns address balance
- `listunspent(address)` - Lists unspent outputs

#### Wallet
- `getnewaddress()` - Generates new address
- `sendtoaddress(address, amount)` - Sends OMNI
- `dumpprivkey(address)` - Exports private key
- `importprivkey(privkey)` - Imports private key

#### DEX
- `dex_place_order(pair_id, side, amount, price)` - Places order
- `dex_cancel_order(order_id)` - Cancels order
- `dex_get_orderbook(pair_id)` - Returns order book
- `dex_get_orders(address)` - Returns user orders

#### Staking
- `stake_validator(validator, amount)` - Stakes to validator
- `unstake_validator(validator, amount)` - Unstakes
- `get_staking_info(validator)` - Returns staking info

#### Governance
- `governance_propose(title, description, actions)` - Creates proposal
- `governance_vote(proposal_id, choice)` - Votes on proposal
- `governance_get_proposal(proposal_id)` - Returns proposal details

#### Mining
- `mining_getmininginfo()` - Mining statistics
- `mining_submitblock(hex)` - Submits mined block

### EVM JSON-RPC (port 8333)

Standard Ethereum JSON-RPC methods:
- `eth_blockNumber`
- `eth_getBalance`
- `eth_getTransactionCount`
- `eth_getBlockByNumber`
- `eth_getBlockByHash`
- `eth_sendRawTransaction`
- `eth_call`
- `eth_estimateGas`
- `eth_gasPrice`
- `eth_getLogs`
- `eth_getCode`
- `eth_getStorageAt`
- `web3_clientVersion`
- `net_version`
- `net_peerCount`

### WebSocket Events (port 8334)

Subscribe to events using bitmask:
```javascript
ws.send('{"subscribe": 0xFFFF}') // Subscribe to all events