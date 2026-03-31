# API Reference Complet - OmniBus BlockChain Core

**Data:** 2026-03-30  
**RPC Version:** JSON-RPC 2.0  
**HTTP Port:** 8332  
**WebSocket Port:** 8334

---

## Cuprins

1. [Conexiune și Protocol](#1-conexiune-și-protocol)
2. [Metode Blockchain](#2-metode-blockchain)
3. [Metode Wallet](#3-metode-wallet)
4. [Metode Tranzacții](#4-metode-tranzacții)
5. [Metode Mining Pool](#5-metode-mining-pool)
6. [Metode Network](#6-metode-network)
7. [Metode Sharding](#7-metode-sharding)
8. [WebSocket Events](#8-websocket-events)
9. [Error Codes](#9-error-codes)
10. [Exemple Complete](#10-exemple-complete)

---

## 1. Conexiune și Protocol

### Endpoint HTTP
```
POST http://127.0.0.1:8332
Content-Type: application/json
```

### Format Request
```json
{
  "jsonrpc": "2.0",
  "method": "methodName",
  "params": [param1, param2],
  "id": 1
}
```

### Format Response
```json
{
  "jsonrpc": "2.0",
  "result": { ... },
  "id": 1
}
```

### Format Error
```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": -32600,
    "message": "Invalid Request"
  },
  "id": null
}
```

---

## 2. Metode Blockchain

### getblockcount
Returnează numărul de blocuri din chain (inclusiv genesis).

**Parametri:** Niciunul

**Return:** `number`

**Exemple:**
```bash
curl -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getblockcount","params":[],"id":1}'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": 150,
  "id": 1
}
```

---

### getblock
Returnează un bloc după index.

**Parametri:**
| Parametru | Tip | Descriere |
|-----------|-----|-----------|
| index | number | Block height (0 = genesis) |

**Return:** `Block object`

**Exemple:**
```bash
curl -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "getblock",
    "params": [10],
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "index": 10,
    "timestamp": 1711800000,
    "previousHash": "0000abc123...",
    "hash": "0000def456...",
    "nonce": 12345,
    "difficulty": 4,
    "merkleRoot": "abc123...",
    "transactions": [
      {
        "hash": "tx123...",
        "from": "ob_omni_abc...",
        "to": "ob_omni_def...",
        "amount": 1000000000,
        "fee": 1000000,
        "timestamp": 1711800000
      }
    ],
    "transactionCount": 1
  },
  "id": 1
}
```

---

### getlatestblock
Returnează cel mai recent bloc minat.

**Parametri:** Niciunul

**Return:** `Block object`

---

### getblockhash
Returnează hash-ul unui bloc după index.

**Parametri:**
| Parametru | Tip | Descriere |
|-----------|-----|-----------|
| index | number | Block height |

**Return:** `string` (hex hash)

---

### getbestblockhash
Returnează hash-ul celui mai recent bloc din chain.

**Parametri:** Niciunul

**Return:** `string` (hex hash)

---

### getdifficulty
Returnează dificultatea curentă.

**Parametri:** Niciunul

**Return:** `number`

---

## 3. Metode Wallet

### getbalance
Returnează balanța wallet-ului curent.

**Parametri:** Niciunul

**Return:** `Balance object`

**Exemple:**
```bash
curl -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getbalance","params":[],"id":1}'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "address": "ob_omni_1a2b3c4d5e6f",
    "balance": 500000000000,
    "balanceOMNI": 500.0,
    "nodeHeight": 150,
    "addresses": [
      {"domain": "omni", "address": "ob_omni_1a2b3c...", "type": "ML-DSA-87+KEM"},
      {"domain": "love", "address": "ob_k1_2b3c4d...", "type": "ML-DSA-87"},
      {"domain": "food", "address": "ob_f5_3c4d5e...", "type": "Falcon-512"},
      {"domain": "rent", "address": "ob_d5_4d5e6f...", "type": "ML-DSA-87"},
      {"domain": "vacation", "address": "ob_s3_5e6f7g...", "type": "SLH-DSA"}
    ]
  },
  "id": 1
}
```

---

### getaddresses
Returnează toate cele 5 adrese PQ.

**Parametri:** Niciunul

**Return:** `Array<Address>`

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": [
    {"prefix": "ob_omni_", "coinType": 777, "algorithm": "ML-DSA-87+KEM"},
    {"prefix": "ob_k1_", "coinType": 778, "algorithm": "ML-DSA-87"},
    {"prefix": "ob_f5_", "coinType": 779, "algorithm": "Falcon-512"},
    {"prefix": "ob_d5_", "coinType": 780, "algorithm": "ML-DSA-87"},
    {"prefix": "ob_s3_", "coinType": 781, "algorithm": "SLH-DSA-256s"}
  ],
  "id": 1
}
```

---

## 4. Metode Tranzacții

### sendtransaction
Trimite o tranzacție nouă.

**Parametri:**
| Parametru | Tip | Descriere |
|-----------|-----|-----------|
| to | string | Adresa destinatar |
| amount | number | Sumă în SAT (1 OMNI = 1e9 SAT) |

**Return:** `TransactionResult`

**Exemple:**
```bash
curl -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "sendtransaction",
    "params": ["ob_omni_receiver123", 1000000000],
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "txid": "abc123def456...",
    "from": "ob_omni_sender789",
    "to": "ob_omni_receiver123",
    "amount": 1000000000,
    "amountOMNI": 1.0,
    "fee": 1000000,
    "status": "pending",
    "timestamp": 1711800123
  },
  "id": 1
}
```

---

### gettransactions
Returnează tranzacțiile pentru o adresă (sau toate).

**Parametri:**
| Parametru | Tip | Opțional | Descriere |
|-----------|-----|----------|-----------|
| address | string | Da | Adresa pentru filtrare |
| limit | number | Da | Max rezultate (default: 100) |

**Return:** `Array<Transaction>`

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": [
    {
      "txid": "abc123...",
      "from": "ob_omni_abc...",
      "to": "ob_omni_def...",
      "amount": 1000000000,
      "fee": 1000000,
      "status": "confirmed",
      "direction": "incoming",
      "blockHeight": 145,
      "timestamp": 1711800000
    }
  ],
  "id": 1
}
```

---

### getmempoolsize
Returnează numărul de tranzacții în așteptare.

**Parametri:** Niciunul

**Return:** `number`

---

### getmempool
Returnează lista tranzacțiilor din mempool.

**Parametri:** Niciunul

**Return:** `Array<Transaction>`

---

### gettransaction
Returnează o tranzacție după TXID.

**Parametri:**
| Parametru | Tip | Descriere |
|-----------|-----|-----------|
| txid | string | Transaction hash |

**Return:** `Transaction`

---

### createrawtransaction
Creează o tranzacție raw (nesemnată).

**Parametri:**
| Parametru | Tip | Descriere |
|-----------|-----|-----------|
| inputs | Array | Inputs (UTXO sau account) |
| outputs | Array | Outputs (address, amount) |

**Return:** `string` (hex transaction)

---

### signrawtransaction
Semnează o tranzacție raw.

**Parametri:**
| Parametru | Tip | Descriere |
|-----------|-----|-----------|
| hex | string | Raw transaction hex |

**Return:** `SignedTransaction`

---

## 5. Metode Mining Pool

### registerminer
Înregistrează un miner nou în pool.

**Parametri:**
| Parametru | Tip | Descriere |
|-----------|-----|-----------|
| minerData | object | {id, name, address, hashrate} |

**Return:** `RegistrationResult`

**Exemple:**
```bash
curl -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "registerminer",
    "params": [{
      "id": "miner-001",
      "name": "Miner Alpha",
      "address": "ob_omni_miner001",
      "hashrate": 1000
    }],
    "id": 1
  }'
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "success": true,
    "minerCount": 11,
    "message": "Miner registered successfully"
  },
  "id": 1
}
```

---

### minerkeepalive
Keepalive pentru un miner activ.

**Parametri:**
| Parametru | Tip | Descriere |
|-----------|-----|-----------|
| address | string | Miner address |

**Return:** `boolean`

---

### getminers
Returnează lista minerilor activi.

**Parametri:** Niciunul

**Return:** `Array<Miner>`

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": [
    {
      "id": "miner-001",
      "name": "Miner Alpha",
      "address": "ob_omni_miner001",
      "hashrate": 1000,
      "lastKeepalive": 1711800123,
      "status": "active"
    }
  ],
  "id": 1
}
```

---

### getminerstatus
Returnează statusul complet al pool-ului.

**Parametri:** Niciunul

**Return:** `PoolStatus`

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "totalMiners": 110,
    "activeMiningMiners": 108,
    "inactiveMiners": 2,
    "totalHashrate": 110000,
    "blocksMined": 500,
    "currentBlock": 501,
    "rewardPerBlock": 50,
    "rewardPerMiner": 0.46296296
  },
  "id": 1
}
```

---

### getminerbalances
Returnează balanțele tuturor minerilor.

**Parametri:** Niciunul

**Return:** `Array<MinerBalance>`

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": [
    {
      "address": "ob_omni_miner001",
      "balanceSat": 25000000000,
      "balanceOmni": 25.0,
      "blocksContributed": 50
    }
  ],
  "id": 1
}
```

---

### getpoolstats
Returnează statistici complete pool.

**Parametri:** Niciunul

**Return:** `PoolStats`

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "registeredMiners": 110,
    "activeMiners": 108,
    "totalBlocks": 500,
    "totalTransactions": 5500,
    "currentReward": 50,
    "averageHashrate": 1000,
    "uptime": 86400
  },
  "id": 1
}
```

---

## 6. Metode Network

### getstatus
Returnează statusul complet al nodului.

**Parametri:** Niciunul

**Return:** `NodeStatus`

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "status": "ready",
    "blockCount": 150,
    "mempoolSize": 23,
    "address": "ob_omni_abc123",
    "balance": 500000000000,
    "balanceOMNI": 500,
    "version": "1.0.0-dev",
    "platform": "windows",
    "uptime": 3600
  },
  "id": 1
}
```

---

### getpeerinfo
Returnează informații despre peers conectați.

**Parametri:** Niciunul

**Return:** `Array<Peer>`

---

### getconnectioncount
Returnează numărul de conexiuni active.

**Parametri:** Niciunul

**Return:** `number`

---

## 7. Metode Sharding

### getshardinginfo
Returnează informații despre sharding.

**Parametri:** Niciunul

**Return:** `ShardingInfo`

**Response:**
```json
{
  "jsonrpc": "2.0",
  "result": {
    "shardCount": 7,
    "validatorsPerShard": 100,
    "blockTimeMs": 1000,
    "subBlockTimeMs": 100,
    "currentEpoch": 10,
    "shards": [
      {"id": 0, "name": "OMNI", "status": "active", "txCount": 1500},
      {"id": 1, "name": "LOVE", "status": "active", "txCount": 1200},
      {"id": 2, "name": "FOOD", "status": "active", "txCount": 900},
      {"id": 3, "name": "RENT", "status": "active", "txCount": 800},
      {"id": 4, "name": "VACATION", "status": "active", "txCount": 600},
      {"id": 5, "name": "Shard-5", "status": "active", "txCount": 400},
      {"id": 6, "name": "Shard-6", "status": "active", "txCount": 300}
    ]
  },
  "id": 1
}
```

---

### getmetachainheaders
Returnează metachain headers.

**Parametri:**
| Parametru | Tip | Opțional | Descriere |
|-----------|-----|----------|-----------|
| count | number | Da | Număr de headers (default: 10) |

**Return:** `Array<MetaHeader>`

---

### getshardforaddress
Returnează shard-ul pentru o adresă.

**Parametri:**
| Parametru | Tip | Descriere |
|-----------|-----|-----------|
| address | string | Adresa OMNI |

**Return:** `number` (shard ID 0-6)

---

## 8. WebSocket Events

### Conectare
```javascript
const ws = new WebSocket('ws://127.0.0.1:8334');

ws.onopen = () => {
  console.log('Connected to OmniBus WebSocket');
};

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log('Received:', data);
};
```

### Events

#### newblock
Emis când un nou bloc este minat.

```json
{
  "type": "newblock",
  "data": {
    "index": 151,
    "hash": "0000abc123...",
    "timestamp": 1711800123,
    "transactionCount": 10,
    "miner": "ob_omni_miner001"
  }
}
```

#### newtransaction
Emis când o tranzacție nouă este adăugată în mempool.

```json
{
  "type": "newtransaction",
  "data": {
    "txid": "tx123...",
    "from": "ob_omni_abc...",
    "to": "ob_omni_def...",
    "amount": 1000000000,
    "fee": 1000000
  }
}
```

#### mempoolupdate
Emis când mempool-ul se schimbă.

```json
{
  "type": "mempoolupdate",
  "data": {
    "size": 25,
    "totalBytes": 4096
  }
}
```

#### poolupdate
Emis când statusul pool-ului se schimbă.

```json
{
  "type": "poolupdate",
  "data": {
    "activeMiners": 110,
    "blocksMined": 501,
    "totalHashrate": 110000
  }
}
```

---

## 9. Error Codes

| Code | Message | Descriere |
|------|---------|-----------|
| -32700 | Parse error | JSON invalid |
| -32600 | Invalid Request | Request format invalid |
| -32601 | Method not found | Metoda nu există |
| -32602 | Invalid params | Parametri invalizi |
| -32603 | Internal error | Eroare internă server |
| -32000 | Server error | Eroare generică server |
| -32001 | Invalid address | Format adresă invalid |
| -32002 | Insufficient funds | Fonduri insuficiente |
| -32003 | Invalid amount | Sumă invalidă |
| -32004 | Transaction rejected | TX respinsă |
| -32005 | Mempool full | Mempool plin |
| -32006 | Invalid signature | Semnătură invalidă |
| -32007 | Block not found | Bloc inexistent |
| -32008 | Transaction not found | TX inexistentă |
| -32009 | Miner already registered | Miner deja înregistrat |
| -32010 | Invalid hashrate | Hashrate invalid |

---

## 10. Exemple Complete

### Exemplu 1: Verificare Balanță și Trimitere

```bash
#!/bin/bash

# 1. Verifică balanța
BALANCE=$(curl -s -X POST http://127.0.0.1:8332 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"getbalance","params":[],"id":1}' \
  | jq -r '.result.balanceOMNI')

echo "Balance: $BALANCE OMNI"

# 2. Trimite 10 OMNI
if (( $(echo "$BALANCE > 10" | bc -l) )); then
  RESULT=$(curl -s -X POST http://127.0.0.1:8332 \
    -H "Content-Type: application/json" \
    -d "{
      \"jsonrpc\": \"2.0\",
      \"method\": \"sendtransaction\",
      \"params\": [\"ob_omni_receiver123\", 10000000000],
      \"id\": 1
    }")
  
  echo "Transaction: $(echo $RESULT | jq -r '.result.txid')"
fi
```

---

### Exemplu 2: Monitorizare Blocuri în Timp Real

```javascript
const WebSocket = require('ws');

const ws = new WebSocket('ws://127.0.0.1:8334');

ws.on('message', (data) => {
  const event = JSON.parse(data);
  
  switch(event.type) {
    case 'newblock':
      console.log(`New block #${event.data.index} mined by ${event.data.miner}`);
      break;
    case 'newtransaction':
      console.log(`New TX: ${event.data.amount / 1e9} OMNI to ${event.data.to}`);
      break;
  }
});
```

---

### Exemplu 3: Înregistrare Miner și Monitorizare

```python
import requests
import time

RPC_URL = "http://127.0.0.1:8332"

def register_miner(miner_id, name, address, hashrate):
    response = requests.post(RPC_URL, json={
        "jsonrpc": "2.0",
        "method": "registerminer",
        "params": [{
            "id": miner_id,
            "name": name,
            "address": address,
            "hashrate": hashrate
        }],
        "id": 1
    })
    return response.json()

def keepalive(address):
    response = requests.post(RPC_URL, json={
        "jsonrpc": "2.0",
        "method": "minerkeepalive",
        "params": [address],
        "id": 1
    })
    return response.json()

def get_pool_stats():
    response = requests.post(RPC_URL, json={
        "jsonrpc": "2.0",
        "method": "getpoolstats",
        "params": [],
        "id": 1
    })
    return response.json()

# Înregistrează miner
result = register_miner("miner-py-001", "Python Miner", "ob_omni_py001", 5000)
print(f"Registered: {result}")

# Keepalive loop
try:
    while True:
        keepalive("ob_omni_py001")
        stats = get_pool_stats()
        print(f"Active miners: {stats['result']['activeMiners']}, "
              f"Blocks: {stats['result']['totalBlocks']}")
        time.sleep(5)
except KeyboardInterrupt:
    print("Stopped")
```

---

### Exemplu 4: Explorer Simplu

```javascript
// React Component
import { useState, useEffect } from 'react';

function BlockExplorer() {
  const [blocks, setBlocks] = useState([]);
  
  useEffect(() => {
    const fetchBlocks = async () => {
      const response = await fetch('http://127.0.0.1:8332', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          method: 'getblockcount',
          params: [],
          id: 1
        })
      });
      
      const { result: count } = await response.json();
      
      // Fetch last 10 blocks
      const blockPromises = [];
      for (let i = Math.max(0, count - 10); i < count; i++) {
        blockPromises.push(
          fetch('http://127.0.0.1:8332', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0',
              method: 'getblock',
              params: [i],
              id: 1
            })
          }).then(r => r.json())
        );
      }
      
      const blocksData = await Promise.all(blockPromises);
      setBlocks(blocksData.map(b => b.result).reverse());
    };
    
    fetchBlocks();
    const interval = setInterval(fetchBlocks, 5000);
    return () => clearInterval(interval);
  }, []);
  
  return (
    <div>
      <h2>Block Explorer</h2>
      {blocks.map(block => (
        <div key={block.index} className="block-card">
          <h3>Block #{block.index}</h3>
          <p>Hash: {block.hash.substring(0, 20)}...</p>
          <p>Transactions: {block.transactionCount}</p>
          <p>Time: {new Date(block.timestamp * 1000).toLocaleString()}</p>
        </div>
      ))}
    </div>
  );
}

export default BlockExplorer;
```

---

## Referințe

- **JSON-RPC 2.0 Spec:** https://www.jsonrpc.org/specification
- **OmniBus Wiki:** wiki-omnibus/INDEX.md
- **GitHub:** https://github.com/SAVACAZAN/OmniBus-BlockChainCore
