# OmniBus Blockchain — API Reference

> Version: 1.0 | Chain: OmniBus (OMNI) | Last updated: 2026-05-05

---

## JSON-RPC 2.0 (HTTP)

**Base URL (testnet)**  `https://omnibusblockchain.cc:8443/api-testnet`  
**Base URL (local)**    `http://localhost:8332`  
**Auth**                `Authorization: Bearer <64-hex-token>` (production nodes)  
**Content-Type**        `application/json`  
**Method**              `POST /`

All calls use the JSON-RPC 2.0 envelope:

```json
{
  "jsonrpc": "2.0",
  "method": "<method_name>",
  "params": [<positional>] | {<named_key>: <value>},
  "id": 1
}
```

All amounts are in **SAT** (satoshi). 1 OMNI = 1,000,000,000 SAT.  
Prices on the exchange are in **micro-USD** (1 USD = 1,000,000 µUSD).

### Error codes

| Code    | Meaning                        |
|---------|--------------------------------|
| -32700  | Parse error / TX pool full     |
| -32600  | Invalid request                |
| -32601  | Method not found               |
| -32602  | Invalid params                 |
| -32603  | Internal error                 |
| -32000  | Application error (see message)|
| -32010  | Faucet not enabled             |
| -32011  | Faucet: address already claimed|
| -32012  | Faucet drained                 |
| -32030  | DNS registry not enabled       |
| -32031  | DNS fee / name error           |
| -32400  | DNS name not found             |
| -32401  | DNS signature mismatch         |
| -32402  | DNS nonce replay               |

---

## Blockchain Methods

### `getblockcount`
Returns the current chain height.

**Params:** none

**Response:**
```json
{"jsonrpc":"2.0","result":189623,"id":1}
```

---

### `getblock`
Get block by height (integer) or hash (0x-prefixed hex).

**Params:** `[block_id: integer|string]`

**Response:**
```json
{
  "result": {
    "height": 189623,
    "hash": "0xabc...",
    "prev_hash": "0xdef...",
    "merkle_root": "0x...",
    "timestamp": 1714924800,
    "difficulty": 131072,
    "nonce": 9042,
    "tx_count": 5,
    "reward": 50000000000
  }
}
```

---

### `getblocks`
Get a range of blocks.

**Params:** `[from_height: integer, to_height: integer]`

**Response:** `array[Block]`

---

### `getlatestblock`
Returns the latest block header (lightweight, no TX list).

**Params:** none

**Response:**
```json
{
  "result": {
    "index": 189623,
    "timestamp": 1714924800,
    "hash": "0xabc...",
    "previousHash": "0xdef...",
    "nonce": 9042,
    "txCount": 5
  }
}
```

---

### `getblockchaininfo`
Node info: version, chain, sync status.

**Params:** none

**Response:**
```json
{
  "result": {
    "version": "1.0.0",
    "chain": "testnet",
    "height": 189623,
    "sync": true,
    "peers": 3,
    "difficulty": 131072
  }
}
```

---

### `getchainmetrics`
High-level explorer dashboard stats.

**Params:** none

**Response:**
```json
{
  "result": {
    "height": 189623,
    "tipHash": "0xabc...",
    "totalSupply": 1580274936789,
    "addressesWithBalance": 142,
    "validators": 5,
    "validatorSetSize": 5,
    "minValidatorBalance": 100000000000,
    "mempoolSize": 3,
    "peerCount": 2,
    "currentBlockReward": 50000000000,
    "satPerOmni": 1000000000
  }
}
```

---

### `getstatus`
Quick node health check.

**Params:** none

**Response:**
```json
{
  "result": {
    "status": "running",
    "blockCount": 189623,
    "mempoolSize": 3,
    "address": "ob1q...",
    "balance": 1580274936789
  }
}
```

---

### `getmempoolsize`
Number of transactions in the mempool.

**Params:** none

**Response:** `{"result": 3}`

---

### `getmempoolstats`
Detailed mempool statistics (count, size, fee stats).

**Params:** none

---

### `gettransaction`
Get a single transaction by hash. Searches mempool first, then mined blocks.

**Params:** `["txid_hex"]` or `{"txid": "..."}`

**Response:**
```json
{
  "result": {
    "txid": "0xabc...",
    "from": "ob1q...",
    "to": "ob1q...",
    "amount": 1000000000,
    "fee": 1000,
    "confirmations": 12,
    "blockHeight": 189611,
    "status": "confirmed"
  }
}
```
Pending TXs: `"confirmations": 0, "blockHeight": null, "status": "pending"`

---

### `gettransactions`
Get transactions for an address (paginated).

**Params:** `[address: string, page?: integer, limit?: integer]`

**Response:** `array[Transaction]`

---

### `listtransactions`
List recent transactions (by block range or address).

**Params:** `{"address": "ob1q...", "from_height": 0, "to_height": 9999}`

---

### `getaddresshistory`
Full transaction history for an address with amounts.

**Params:** `[address: string]` or `{"address": "..."}`

---

### `sendtransaction`
Broadcast a signed transaction. Also aliased as `sendtx`.

**Params:**
```json
[{
  "nonce": 0,
  "from": "ob1q...",
  "to": "ob1q...",
  "amount": 1000000000,
  "fee": 1000,
  "memo": "payment",
  "sig": "0xabcdef...",
  "pq_sig": "optional_pq_hex"
}]
```

**Response:**
```json
{
  "result": {
    "txid": "0xabc...",
    "status": "accepted"
  }
}
```

**Errors:** Invalid signature (-32602), insufficient balance (-32602), double-spend (-32602), pool full (-32700)

---

### `sendrawtransaction`
Send a raw signed TX (hex-encoded binary format).

**Params:** `["raw_tx_hex"]`

---

### `sendopreturn`
Send a TX with an OP_RETURN data field (used for name registration, staking, agent commands).

**Params:** `{"from": "...", "to": "...", "amount": 0, "op_return": "ns_claim:alice.omnibus", "sig": "...", "pubkey": "..."}`

---

### `estimatefee`
Estimate network fee for a TX. Returns the minimum fee (currently flat).

**Params:** none (or `{"size_bytes": 250, "urgency": "normal"}`)

**Response:**
```json
{"result": {"fee_per_byte": 4, "estimated_fee": 1000, "urgency": "normal"}}
```

---

### `getnonce`
Get next usable nonce for an address (avoids mempool conflicts).

**Params:** `["ob1q..."]` or `{"address": "..."}`

**Response:**
```json
{
  "result": {
    "address": "ob1q...",
    "nonce": 42,
    "chainNonce": 40,
    "pendingCount": 2
  }
}
```

---

### `getrichlist`
Top N addresses by balance, with roles and TX stats.

**Params:** `[limit: integer]` (max 1000, default 100)

**Response:**
```json
{
  "result": {
    "entries": [
      {
        "rank": 1,
        "address": "ob1q...",
        "balance": 1580274936789,
        "roles": ["validator", "miner"],
        "stake": 100000000000,
        "blocksMined": 312,
        "isValidator": true,
        "txCount": 148,
        "received": 2000000000000,
        "sent": 419725063211,
        "firstHeight": 0,
        "lastHeight": 189610
      }
    ],
    "total": 142,
    "shown": 100,
    "totalSupply": 9461274936789
  }
}
```

Roles: `"validator"` (staked ≥ MIN), `"miner"` (mined ≥ 1 block), `"agent"` (registered via op_return), `"user"` (none of the above).

---

### `getheaders`
Get block headers (lightweight, no TX data) for a range.

**Params:** `[from_height: integer, to_height: integer]`

---

### `getmerkleproof`
Get Merkle proof for a TX in a block.

**Params:** `{"txid": "0x...", "block_height": 189611}`

---

### `getperformance`
Internal performance counters (RPC latency, block processing time).

**Params:** none

---

## Wallet / Address Methods

### `getbalance`
Get address balance.

**Params:** `["ob1q...", confirmations?]` or `{"address": "...", "confirmations": 0}`

**Response:** `{"result": 1580274936789}`

---

### `getaddressbalance`
Alias for `getbalance`.

---

### `listunspent`
List UTXOs for one or more addresses.

**Params:** `[["ob1q...", "ob1q..."], min_conf?]`

**Response:**
```json
{
  "result": [
    {
      "txid": "0x...",
      "vout": 0,
      "amount": 1000000000,
      "address": "ob1q...",
      "script_pubkey": "76a914...",
      "block_height": 189600,
      "confirmations": 23
    }
  ]
}
```

---

### `minersendtx`
Internal: miner node uses this to broadcast self-signed transactions.

---

## Faucet Methods

### `claimfaucet`
Request testnet OMNI from the faucet. Each address can claim once.

**Params:** `["ob1q..."]` or `{"address": "ob1q..."}`

**Response:**
```json
{
  "result": {
    "txid": "0xabc...",
    "recipient": "ob1q...",
    "amount": 10000000000,
    "fee": 1000,
    "status": "accepted"
  }
}
```

**Errors:** Already claimed (-32011), faucet drained (-32012), faucet not enabled (-32010)

---

### `getfaucetstatus`
Check faucet balance and configuration.

**Params:** none

**Response:**
```json
{
  "result": {
    "enabled": true,
    "address": "ob1q...",
    "balance": 5000000000000,
    "grantPerClaim": 10000000000,
    "claimsServed": 47
  }
}
```

---

## Name System Methods (ENS-like)

TLDs supported: `.omnibus` (5 OMNI fee), `.arbitraje` (10 OMNI fee).  
Names: 3-25 chars, lowercase `a-z 0-9 _`, must start with a letter. Max 10 names per owner.

### `registername`
Register a `.omnibus` or `.arbitraje` name.

**Params:**
```json
{
  "name": "alice",
  "address": "ob1q...",
  "owner": "ob1q...",
  "tld": "omnibus",
  "fee_txid": "abcdef1234...",
  "nonce": 1,
  "signature": "0x...",
  "publicKey": "02abc..."
}
```
Positional: `[name, address, owner?, tld?, fee_txid?]`

**Response:**
```json
{
  "result": {
    "name": "alice",
    "tld": "omnibus",
    "fullLabel": "alice.omnibus",
    "address": "ob1q...",
    "registeredAtBlock": 189600,
    "fee_paid_sat": 5000000000,
    "fee_txid": "abcdef1234..."
  }
}
```

---

### `resolvename`
Resolve a name to its owner address.

**Params:** `["alice.omnibus"]` or `{"name": "alice", "tld": "omnibus"}`  
Accepts full label `"alice.omnibus"` or split `"alice" + "omnibus"`.

**Response:**
```json
{
  "result": {
    "name": "alice",
    "tld": "omnibus",
    "fullLabel": "alice.omnibus",
    "address": "ob1q...",
    "found": true
  }
}
```
Not found: `"address": null, "found": false`

---

### `reverseresolvename`
Look up names registered to an address.

**Params:** `["ob1q..."]` or `{"address": "..."}`

**Response:**
```json
{"result": {"address": "ob1q...", "name": "alice.omnibus", "found": true}}
```

---

### `transfername`
Transfer name ownership to a new address (requires signature from current owner).

**Params:**
```json
{
  "name": "alice",
  "tld": "omnibus",
  "new_owner": "ob1q...",
  "nonce": 2,
  "signature": "0x...",
  "publicKey": "02abc..."
}
```

---

### `updatename`
Update the resolved address of a name (requires owner signature).

**Params:** `{"name": "alice", "tld": "omnibus", "address": "ob1q_new...", "nonce": 3, "signature": "0x...", "publicKey": "..."}`

---

### `renewname`
Renew a name before expiry.

**Params:** `{"name": "alice", "tld": "omnibus", "fee_txid": "...", "nonce": 4, "signature": "...", "publicKey": "..."}`

---

### `listnames`
List all active registered names.

**Params:** none

**Response:**
```json
{
  "result": {
    "entries": [
      {
        "name": "alice",
        "tld": "omnibus",
        "fullLabel": "alice.omnibus",
        "address": "ob1q...",
        "registeredAtBlock": 189500,
        "expiresAtBlock": 229500
      }
    ],
    "total": 12
  }
}
```

---

### `getensfee`
Query current name registration fees and treasury address.

**Params:** none

**Response:**
```json
{
  "result": {
    "treasury": "ob1q...",
    "enforcement": true,
    "cost_omnibus_omni": 5,
    "cost_arbitraje_omni": 10
  }
}
```

---

## Network / Peer Methods

### `getpeers`
List connected peers.

**Params:** none

**Response:** `array[{address, port, node_id, version, height}]`

---

### `getnodelist`
All known nodes (peers + bootstrap).

---

### `getnetworkinfo`
Network topology stats.

**Response:** `{connections, inbound, outbound, relay_fee, version}`

---

### `getsyncstatus`
IBD sync progress.

**Response:** `{synced: bool, local_height, peer_height, behind, progress_pct}`

---

### `getclockstatus`
Hardware clock status (RDTSC + spectrum).

**Params:** none

**Response:**
```json
{
  "result": {
    "now_ms": 1714924800000,
    "rdtsc": 987654321098765,
    "spectrum": "0011001100110011..."
  }
}
```

---

### `getslotleader`
Who is the current slot leader (next block producer).

**Params:** none

**Response:**
```json
{"result": {"slot": 189624, "leader": "ob1q...", "weight": 325000000000}}
```

---

### `getslotcalendar`
Next 60 pre-computed slot assignments.

**Params:** none

**Response:** `{head_slot, slot_interval_ms, entries: [{slot_id, leader, expected_arrival_ms, state}]}`  
`state`: `"future"` | `"in_flight"` | `"finalized"` | `"missed"`

---

### `getvalidators`
Active validator set.

**Params:** none

**Response:**
```json
{
  "result": {
    "count": 5,
    "validators": [
      {"address": "ob1q...", "weight": 325000000000, "since_height": 1000}
    ]
  }
}
```

---

### `getstakinginfo`
Detailed staking/validator info for an address.

**Params:** `["ob1q..."]` or `{"address": "..."}`

**Response:**
```json
{
  "result": {
    "address": "ob1q...",
    "status": "active",
    "total_stake": 325000000000,
    "self_stake": 325000000000,
    "delegated_stake": 0,
    "slash_count": 0,
    "slash_history_count": 0,
    "total_rewards": 1500000000,
    "uptime_pct": 99,
    "blocks_produced": 312,
    "commission_pct": 5
  }
}
```

---

### `getminerstats`
Mining statistics (hash rate, blocks per hour, recent block times).

---

### `getminerinfo`
This node's miner identity and current mining state.

---

### `getpoolstats`
Mining pool stats (if pool mode enabled).

---

### `registerminer`
Register a miner address with the pool.

**Params:** `{"address": "ob1q...", "worker": "rig-1"}`

---

### `submitslashevidence`
Submit double-sign evidence against a validator.

**Params:** `{"validator": "ob1q...", "block_a": {...}, "block_b": {...}, "sig_a": "...", "sig_b": "..."}`

---

### `getslashhistory`
Get slash events for a validator.

**Params:** `{"address": "ob1q..."}`

---

### `getfuturepool`
Transactions scheduled for future blocks.

---

## Oracle / Price Methods

### `omnibus_getoracleprices`
All current oracle price feeds (median of exchange feeds).

**Params:** none

**Response:**
```json
{
  "result": {
    "BTC/USDC": {"price_micro_usd": 80211980000, "sources": 3, "timestamp": 1714924800},
    "OMNI/USDC": {"price_micro_usd": 1500000, "sources": 2, "timestamp": 1714924800}
  }
}
```

---

### `omnibus_getallprices`
All prices from all connected exchange feeds.

---

### `omnibus_getblockprices`
Oracle prices at a specific block height.

**Params:** `{"height": 189600}`

---

### `omnibus_getpricerange`
Price history for a pair over a block range.

**Params:** `{"pair": "BTC/USDC", "from_height": 189500, "to_height": 189623}`

---

### `omnibus_getexchangefeed`
Raw feeds from each connected exchange (Kraken, LCX, etc.).

---

### `omnibus_getfxrate`
Fiat FX rates (USD/EUR etc.) from oracle aggregation.

---

### `omnibus_getorderbook`
Oracle-aggregated orderbook (composite across exchanges).

**Params:** `{"pair": "BTC/USDC"}`

---

### `omnibus_getarbitrage`
Current arbitrage opportunities detected between exchanges.

---

### `omnibus_getbridgestatus`
OmniBus ↔ external chain bridge status.

---

### `omnibus_getoraclepolicy`
Current oracle update policy (min sources, max staleness).

---

### `omnibus_setoraclepolicy`
Update oracle policy (admin only).

**Params:** `{"min_sources": 2, "max_age_seconds": 30}`

---

### `omnibus_getminers`
All known miners and their recent block production stats.

---

## Exchange (Native DEX) Methods

The native on-chain DEX uses signed orders. All price values are in **micro-USD per unit** (1 USD = 1,000,000 µUSD). All amounts are in **SAT**.

### Trading Pairs

| ID | Pair      |
|----|-----------|
| 0  | OMNI/USDC |
| 1  | BTC/USDC  |
| 2  | LCX/USDC  |
| 3  | ETH/USDC  |
| 4  | OMNI/BTC  |
| 5  | OMNI/LCX  |
| 6  | OMNI/ETH  |

### Fee Model
- Network fee: 1000 SAT flat per fill (goes to block miner)
- Taker fee: 10 bps (0.10%) in USDC
- Maker fee: 5 bps (0.05%) in USDC

### Paper vs. Real Mode
Add `"mode": "paper"` to any exchange request to use the paper-trading engine (separate orderbook, demo balances).

---

### `exchange_listPairs`
List all supported trading pairs.

**Params:** none

**Response:**
```json
{
  "result": [
    {"id": 0, "base": "OMNI", "quote": "USDC", "label": "OMNI/USDC"},
    {"id": 1, "base": "BTC",  "quote": "USDC", "label": "BTC/USDC"},
    {"id": 2, "base": "LCX",  "quote": "USDC", "label": "LCX/USDC"},
    {"id": 3, "base": "ETH",  "quote": "USDC", "label": "ETH/USDC"},
    {"id": 4, "base": "OMNI", "quote": "BTC",  "label": "OMNI/BTC"},
    {"id": 5, "base": "OMNI", "quote": "LCX",  "label": "OMNI/LCX"},
    {"id": 6, "base": "OMNI", "quote": "ETH",  "label": "OMNI/ETH"}
  ]
}
```

---

### `exchange_getOrderbook`
Top-N bids and asks for a pair.

**Params:**
```json
{"pair": "OMNI/USDC", "depth": 25, "mode": "real"}
```
or `{"pairId": 0, "depth": 25}`

**Response:**
```json
{
  "result": {
    "pairId": 0,
    "bids": [
      {"orderId": 42, "price": 1500000, "amount": 1000000000, "remaining": 1000000000, "trader": "ob1q...", "ts": 1714924800000}
    ],
    "asks": [
      {"orderId": 43, "price": 1510000, "amount": 500000000, "remaining": 500000000, "trader": "ob1q...", "ts": 1714924801000}
    ],
    "bestBid": 1500000,
    "bestAsk": 1510000,
    "spread": 10000,
    "orderCount": 7
  }
}
```

---

### `exchange_getStats`
Global DEX summary: order counts, fills, best prices per pair.

**Params:** `{"mode": "real"}` (optional)

**Response:**
```json
{
  "result": {
    "mode": "real",
    "totalOrders": 42,
    "bidCount": 20,
    "askCount": 22,
    "trades": 18,
    "pairs": [
      {"id": 0, "label": "OMNI/USDC", "bestBid": 1500000, "bestAsk": 1510000, "spread": 10000, "orderCount": 7}
    ]
  }
}
```

---

### `exchange_getTrades`
Recent fills (trades). Newest first. Up to 256.

**Params:**
```json
{"pair": "OMNI/USDC", "limit": 50, "address": "ob1q...", "mode": "real"}
```
`pair` and `address` are optional filters.

**Response:**
```json
{
  "result": [
    {
      "fillId": 18,
      "pairId": 0,
      "price": 1505000,
      "amount": 500000000,
      "buyer": "ob1q...",
      "seller": "ob1q...",
      "buyOrderId": 42,
      "sellOrderId": 43,
      "ts": 1714924802000
    }
  ]
}
```

---

### `exchange_placeOrder`
Place a limit order. Requires ECDSA signature.

**Params:**
```json
{
  "trader":    "ob1q...",
  "side":      "buy",
  "pair":      "OMNI/USDC",
  "price":     1500000,
  "amount":    1000000000,
  "nonce":     1,
  "signature": "0xabcdef...",
  "publicKey": "02abc...",
  "mode":      "real"
}
```
`pair` (string like `"OMNI/USDC"`) or `pairId` (integer 0-6).  
Use `"signature": "REST_HMAC_BYPASS"` for HMAC-authenticated REST calls.

**Response:**
```json
{
  "result": {
    "mode": "real",
    "orderId": 44,
    "txHash": "0xabc...",
    "side": "buy",
    "pairId": 0,
    "price": 1500000,
    "amount": 1000000000,
    "filled": 500000000,
    "remaining": 500000000,
    "status": "partial",
    "fees": {
      "networkFeeSat": 1000,
      "exchangeTakerFeeMicroUsd": 750,
      "exchangeMakerFeeMicroUsd": 375,
      "takerBps": 10,
      "makerBps": 5
    }
  }
}
```
`status`: `"filled"` | `"partial"` | `"active"`

---

### `exchange_cancelOrder`
Cancel an active order. Requires ECDSA signature from order owner.

**Params:**
```json
{
  "orderId":   44,
  "trader":    "ob1q...",
  "nonce":     2,
  "signature": "0xabc...",
  "publicKey": "02abc...",
  "mode":      "real"
}
```

**Response:**
```json
{"result": {"orderId": 44, "cancelled": true}}
```

---

### `exchange_getUserOrders`
All active orders for a trader address.

**Params:**
```json
{"trader": "ob1q...", "pair": "OMNI/USDC", "mode": "real"}
```
`pair`/`pairId` is optional filter.

**Response:**
```json
{
  "result": [
    {
      "orderId": 44,
      "side": "buy",
      "pairId": 0,
      "price": 1500000,
      "amount": 1000000000,
      "filled": 500000000,
      "remaining": 500000000,
      "status": "partial",
      "ts": 1714924800000
    }
  ]
}
```

---

### `exchange_getAuthNonce`
Get a challenge nonce for exchange login.

**Params:** `{"address": "ob1q..."}`

---

### `exchange_login`
Authenticate to the exchange (session or API key based).

**Params:** `{"address": "ob1q...", "nonce": 42, "signature": "0x...", "publicKey": "..."}`

---

### `exchange_createApiKey`
Create a new API key for an authenticated account.

---

### `exchange_listApiKeys`
List API keys for an account.

---

### `exchange_revokeApiKey`
Revoke an API key.

---

### `exchange_getBalance`
Get single-asset exchange balance for an address.

**Params:** `{"address": "ob1q...", "asset": "OMNI", "mode": "real"}`

---

### `exchange_getBalances`
Get all exchange balances for an address.

**Params:** `{"address": "ob1q...", "mode": "real"}`

**Response:**
```json
{
  "result": {
    "mode": "real",
    "assets": {
      "OMNI": {"balance": 10000000000, "hold": 1000000000},
      "USDC": {"balance": 500000000,   "hold": 0}
    }
  }
}
```

---

### `exchange_deposit`
Record a deposit to the exchange internal ledger.

---

### `exchange_depositReal`
Deposit real on-chain funds to exchange escrow.

---

### `exchange_depositDemo`
Add demo/paper balance (testnet only).

---

### `exchange_withdraw`
Withdraw from exchange internal ledger back to on-chain address.

---

### `exchange_getEscrowAddress`
Get the exchange escrow address for deposits.

**Params:** none

---

## PQ Crypto Methods

OmniBus supports 13 address schemes. Codes 1-4 are **soulbound** (non-transferable). Codes 5-12 are transferable quantum-safe variants.

| Code | Scheme              | Prefix    | Transferable |
|------|---------------------|-----------|--------------|
| 0    | omni_ecdsa          | ob1q      | Yes          |
| 1    | love_dilithium      | ob_k1_    | No (soulbound)|
| 2    | food_falcon         | ob_f5_    | No (soulbound)|
| 3    | rent_slh_dsa        | ob_d5_    | No (soulbound)|
| 4    | vacation_kem        | ob_s3_    | No (KEM only) |
| 5    | pq_omni_ml_dsa      | ob_q1_    | Yes          |
| 6    | pq_omni_falcon      | ob_q2_    | Yes          |
| 7    | pq_omni_dilithium   | ob_q3_    | Yes          |
| 8    | pq_omni_slh_dsa     | ob_q4_    | Yes          |
| 9    | hybrid_q1           | ob_h1_    | Yes          |
| 10   | hybrid_q2           | ob_h2_    | Yes          |
| 11   | hybrid_q3           | ob_h3_    | Yes          |
| 12   | hybrid_q4           | ob_h4_    | Yes          |

---

### `pq_listSchemes`
List all supported PQ address schemes.

**Params:** none

**Response:**
```json
{
  "result": [
    {"scheme": "omni_ecdsa",     "code": 0, "address_prefix": "ob1q",   "transferable": true},
    {"scheme": "love_dilithium", "code": 1, "address_prefix": "ob_k1_", "transferable": false},
    {"scheme": "food_falcon",    "code": 2, "address_prefix": "ob_f5_", "transferable": false},
    {"scheme": "rent_slh_dsa",   "code": 3, "address_prefix": "ob_d5_", "transferable": false},
    {"scheme": "vacation_kem",   "code": 4, "address_prefix": "ob_s3_", "transferable": false},
    {"scheme": "pq_omni_ml_dsa", "code": 5, "address_prefix": "ob_q1_", "transferable": true}
  ]
}
```

---

### `pq_balance`
Balance of a PQ address (any scheme).

**Params:** `["ob_k1_..."]` or `{"address": "..."}`

**Response:**
```json
{
  "result": {
    "address": "ob_k1_...",
    "scheme": "love_dilithium",
    "code": 1,
    "address_prefix": "ob_k1_",
    "balance": 500000000
  }
}
```

---

### `pq_send`
Send a transaction signed with a PQ scheme.

**Params:**
```json
{
  "from":       "ob_k1_...",
  "to":         "ob1q...",
  "amount":     1000000000,
  "fee":        1000,
  "scheme":     "love_dilithium",
  "signature":  "hex_of_pq_signature",
  "public_key": "hex_of_pq_pubkey",
  "op_return":  "",
  "nonce":      1,
  "id":         42,
  "timestamp":  1714924800
}
```
`scheme` can be the name string or integer code 0-12.  
`vacation_kem` (code 4) cannot sign transactions.

**Response:**
```json
{"result": {"txid": "0xabc...", "status": "accepted"}}
```

---

### `pq_attestation`
Submit or verify a post-quantum attestation (login proof, vote proof).

**Params:** `{"address": "ob_k1_...", "message": "...", "signature": "hex...", "public_key": "hex..."}`

---

## Identity / KYC Methods

### `identity_set`
Set on-chain identity metadata for an address.

**Params:** `{"address": "ob1q...", "alias": "alice", "email_hash": "sha256_hex", "signature": "...", "publicKey": "..."}`

---

### `identity_get`
Retrieve identity metadata for an address.

**Params:** `{"address": "ob1q..."}`

---

### `identity_search`
Search addresses by identity alias.

**Params:** `{"query": "alice"}`

---

### `kyc_getStatus`
Get KYC attestation status for an address.

**Params:** `{"address": "ob1q..."}`

---

### `kyc_attest`
Submit a KYC attestation (issuer-signed).

**Params:** `{"address": "ob1q...", "issuer": "ob1q...", "level": 1, "signature": "..."}`

---

### `kyc_listIssuers`
List trusted KYC issuers.

**Params:** none

---

## Utility Methods

### `getinfo`
Node identity and chain info.

---

### `help`
Get help text for a specific method or list all methods.

**Params:** `["method_name"]` (optional)

---

### `generatewallet`
Not available via RPC. Use the CLI wallet generation tools.

**Response:** `error -32601: Use CLI wallet generation`

---

## Not Yet Implemented

These methods are registered in the dispatch table but return `-32601`:

| Method           | Status                     |
|------------------|----------------------------|
| `createmultisig` | Planned                    |
| `sendmultisig`   | Planned                    |
| `openchannel`    | Payment channels — planned |
| `channelpay`     | Payment channels — planned |
| `closechannel`   | Payment channels — planned |
| `getchannels`    | Payment channels — planned |

---

## WebSocket Events

**Local URL:** `ws://127.0.0.1:8334`  
**Production URL:** `wss://omnibusblockchain.cc:8443/ws-testnet`

WebSocket uses unencrypted `ws://` on localhost. Production connections go through the nginx TLS proxy at 8443.

### Subscription Protocol

Send a JSON text frame to subscribe or unsubscribe:

```json
{"subscribe": "blocks"}
{"unsubscribe": "txs"}
```

**Topics:** `blocks` | `txs` | `trades` | `orderbook` | `oracle` | `all`

Default subscription (on connect): **all** topics.

Topics are bitmask-based internally:

| Topic      | Bitmask |
|------------|---------|
| blocks     | 0x01    |
| txs        | 0x02    |
| trades     | 0x04    |
| orderbook  | 0x08    |
| oracle     | 0x10    |
| all        | 0x1F    |

---

### Event: `new_block`

Emitted every time a new block is mined and accepted.

```json
{
  "event":       "new_block",
  "height":      189624,
  "hash":        "0xabc...",
  "reward_sat":  50000000000,
  "difficulty":  131072,
  "mempool_size": 2,
  "timestamp":   1714924810
}
```
`timestamp` is Unix seconds. Multiply by 1000 for JavaScript `new Date()`.

---

### Event: `new_tx`

Emitted when a transaction enters the mempool.

```json
{
  "event":      "new_tx",
  "txid":       "0xabc...",
  "from":       "ob1q...",
  "amount_sat": 1000000000
}
```

---

### Event: `new_trade`

Emitted when a DEX fill occurs.

```json
{
  "event":     "new_trade",
  "pair_id":   0,
  "pair":      "OMNI/USDC",
  "price_sat": 1505000,
  "qty_sat":   500000000,
  "side":      "buy",
  "height":    189624,
  "timestamp": 1714924810
}
```

---

### Event: `orderbook_update`

Emitted after any orderbook change (place or cancel).

```json
{
  "event":       "orderbook_update",
  "pair_id":     0,
  "pair":        "OMNI/USDC",
  "best_bid":    1500000,
  "best_ask":    1510000,
  "spread":      10000,
  "order_count": 7,
  "height":      189624
}
```

---

### Event: `oracle_price`

Emitted when an oracle price update is received from an exchange feed.

```json
{
  "event":     "oracle_price",
  "pair":      "BTC/USD",
  "price_usd": 80211.9800,
  "sources":   3,
  "timestamp": 1714924810
}
```

---

### Event: `ibd_progress`

Emitted during Initial Block Download (IBD) sync phase.

```json
{
  "event":        "ibd_progress",
  "local_height": 50000,
  "peer_height":  189623,
  "behind":       139623,
  "progress":     26,
  "active":       true
}
```
`progress` is 0-100 (percent).

---

### Event: `heartbeat`

Sent every 25 seconds to all connected clients. No subscription needed.

```json
{"event": "heartbeat", "timestamp": 1714924835}
```

---

## Signing Reference

### ECDSA (ob1q addresses)

Sign message with secp256k1 private key. Message format for orders:

```
OMNIBUS_ORDER:<side>:<pair_id>:<price>:<amount>:<nonce>:<trader>
```

Example: `OMNIBUS_ORDER:buy:0:1500000:1000000000:1:ob1q...`

For DNS operations:
```
OMNIBUS_DNS_REGISTER:<name>:<tld>:<address>:<owner>:<nonce>
OMNIBUS_DNS_TRANSFER:<name>:<tld>:<new_owner>:<nonce>
```

### PQ Signatures

The canonical TX hash (`calculateHash()` = SHA-256 of the serialized TX fields) is what gets signed. Include `id` and `timestamp` in the `pq_send` params to match what was signed.

### HMAC Bypass

REST layer (nginx HMAC-SHA512 authenticated) can set `"signature": "REST_HMAC_BYPASS"` in RPC calls. The RPC server trusts the HMAC verification already done at the proxy layer.

---

## Key Constants

| Parameter            | Value                |
|----------------------|----------------------|
| Block time           | 10s (10×0.1s sub-blocks) |
| RPC port             | 8332 (HTTP)          |
| WebSocket port       | 8334                 |
| P2P port             | 9000+                |
| Max supply           | 21,000,000 OMNI      |
| Block reward (initial)| 50 OMNI             |
| Halving interval     | 210,000 blocks       |
| SAT per OMNI         | 1,000,000,000        |
| Min validator stake  | 100 OMNI             |
| ENS fee (.omnibus)   | 5 OMNI               |
| ENS fee (.arbitraje) | 10 OMNI              |
| Exchange taker fee   | 10 bps (0.10%)       |
| Exchange maker fee   | 5 bps (0.05%)        |
| Network fill fee     | 1,000 SAT flat       |
