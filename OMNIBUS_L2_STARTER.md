# OmniBus Layer 2 - Starter Kit Complet

Acest doc conține toate fișierele și codul pe care trebuie să le folosești pentru a construi propriul Layer 2 pe OP Stack.

---

## 🚀 PASUL 1: Smart Contracts (Solidity)

### 1.1 PriceFeed.sol - Oracle Contract
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract PriceFeed {
    struct PriceData {
        uint256 price;          // Prețul în wei (ex: 2502 * 10^8)
        uint256 timestamp;      // Cand s-a updatat
        string source;          // Sursa: "LCX", "Coinbase", "Kraken"
    }

    mapping(bytes32 => PriceData) public prices;  // symbol => PriceData
    mapping(bytes32 => PriceData[]) public priceHistory;  // Istoric

    address public oracleAdmin;
    uint256 public updateFee = 0;  // Taxa pentru update (0 pe propriul L2)

    event PriceUpdated(bytes32 indexed symbol, uint256 price, uint256 timestamp);

    constructor() {
        oracleAdmin = msg.sender;
    }

    // Admin update preț
    function updatePrice(
        string memory _symbol,
        uint256 _price,
        string memory _source
    ) external {
        require(msg.sender == oracleAdmin, "Only oracle can update");

        bytes32 symbolHash = keccak256(abi.encodePacked(_symbol));

        PriceData memory newData = PriceData({
            price: _price,
            timestamp: block.timestamp,
            source: _source
        });

        prices[symbolHash] = newData;
        priceHistory[symbolHash].push(newData);

        emit PriceUpdated(symbolHash, _price, block.timestamp);
    }

    // Citeste ultimul preț
    function getLatestPrice(string memory _symbol) public view returns (uint256) {
        bytes32 symbolHash = keccak256(abi.encodePacked(_symbol));
        PriceData memory data = prices[symbolHash];

        // Verifica ca prețul nu e mai vechi de 1 oră
        require(data.timestamp > block.timestamp - 1 hours, "Price expired");

        return data.price;
    }

    // Citeste prețul + timestamp
    function getPriceWithTime(string memory _symbol)
        public view returns (uint256, uint256)
    {
        bytes32 symbolHash = keccak256(abi.encodePacked(_symbol));
        PriceData memory data = prices[symbolHash];
        return (data.price, data.timestamp);
    }

    // Schimba admin
    function setAdmin(address _newAdmin) external {
        require(msg.sender == oracleAdmin, "Only admin");
        oracleAdmin = _newAdmin;
    }
}
```

### 1.2 OmnibusToken.sol - Token Nativ
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract OmnibusToken is ERC20, Ownable {
    // Staking
    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public stakingTime;
    uint256 public stakingRewardRate = 5;  // 5% APY

    constructor() ERC20("OmniBus Layer2", "OMNIB") {
        _mint(msg.sender, 1_000_000 * 10 ** 18);  // 1M tokens la creator
    }

    // Stake tokens
    function stake(uint256 _amount) external {
        require(_amount > 0, "Amount must be > 0");
        require(balanceOf(msg.sender) >= _amount, "Insufficient balance");

        _transfer(msg.sender, address(this), _amount);
        stakedBalance[msg.sender] += _amount;
        stakingTime[msg.sender] = block.timestamp;
    }

    // Unstake + rewards
    function unstake(uint256 _amount) external {
        require(_amount > 0, "Amount must be > 0");
        require(stakedBalance[msg.sender] >= _amount, "Insufficient staked balance");

        // Calculeaza rewards
        uint256 stakingDuration = block.timestamp - stakingTime[msg.sender];
        uint256 rewards = (_amount * stakingRewardRate * stakingDuration) / (100 * 365 days);

        stakedBalance[msg.sender] -= _amount;
        _transfer(address(this), msg.sender, _amount + rewards);
    }

    // Mint noi tokeni (governance/recompense)
    function mint(address _to, uint256 _amount) external onlyOwner {
        _mint(_to, _amount);
    }

    // Burn tokens
    function burn(uint256 _amount) external {
        _burn(msg.sender, _amount);
    }
}
```

### 1.3 SimpleDEX.sol - Exchange cu Prețuri din Oracle
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PriceFeed.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SimpleDEX {
    PriceFeed public oracle;
    IERC20 public tokenA;
    IERC20 public tokenB;

    uint256 public reserveA;
    uint256 public reserveB;
    uint256 public feePercentage = 25;  // 0.25%

    event Swap(address indexed user, uint256 amountIn, uint256 amountOut);

    constructor(address _oracle, address _tokenA, address _tokenB) {
        oracle = PriceFeed(_oracle);
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    // Swap folosind Oracle pentru determinare preț
    function swapAtoB(uint256 _amountA) external returns (uint256) {
        // Citeste prețurile din Oracle
        uint256 priceA = oracle.getLatestPrice("ETH/USD");
        uint256 priceB = oracle.getLatestPrice("USDC/USD");

        // Calculeaza output: (amountIn * priceIn) / priceOut
        uint256 amountB = (_amountA * priceA) / priceB;

        // Scade taxa
        uint256 fee = (amountB * feePercentage) / 10000;
        uint256 amountBAfterFee = amountB - fee;

        // Transfer tokens
        require(tokenA.transferFrom(msg.sender, address(this), _amountA), "TransferFrom failed");
        require(tokenB.transfer(msg.sender, amountBAfterFee), "Transfer failed");

        reserveA += _amountA;
        reserveB -= amountBAfterFee;

        emit Swap(msg.sender, _amountA, amountBAfterFee);

        return amountBAfterFee;
    }

    // View: estimare output
    function getSwapAmount(uint256 _amountIn, string memory _symbolIn, string memory _symbolOut)
        external view returns (uint256)
    {
        uint256 priceIn = oracle.getLatestPrice(_symbolIn);
        uint256 priceOut = oracle.getLatestPrice(_symbolOut);
        return (_amountIn * priceIn) / priceOut;
    }
}
```

---

## 🖥️ PASUL 2: Oracle Service (Node.js)

### 2.1 aggregator.js - Citeste API-uri și actualizează preț
```javascript
const axios = require('axios');
const { ethers } = require('ethers');
require('dotenv').config();

// Configurații exchange
const EXCHANGES = {
  coinbase: {
    url: 'https://api.exchange.coinbase.com',
    products: ['BTC-USD', 'ETH-USD'],
  },
  kraken: {
    url: 'https://api.kraken.com/0/public',
    pairs: ['XBTUSDT', 'ETHUSDT'],
  },
  lcx: {
    url: 'https://api.exchange.lcx.com',
    pairs: ['BTC/USD', 'ETH/USD'],
  },
};

// Citeste preț Coinbase
async function getPriceFromCoinbase(product) {
  try {
    const response = await axios.get(`${EXCHANGES.coinbase.url}/products/${product}/ticker`);
    return parseFloat(response.data.price);
  } catch (error) {
    console.error(`❌ Coinbase error: ${error.message}`);
    return null;
  }
}

// Citeste preț Kraken
async function getPriceFromKraken(pair) {
  try {
    const response = await axios.get(`${EXCHANGES.kraken.url}/Ticker`, {
      params: { pair },
    });
    const tickerData = Object.values(response.data.result)[0];
    return parseFloat(tickerData.c[0]);  // Close price
  } catch (error) {
    console.error(`❌ Kraken error: ${error.message}`);
    return null;
  }
}

// Citeste preț LCX
async function getPriceFromLCX(symbol) {
  try {
    const response = await axios.get(`${EXCHANGES.lcx.url}/ticker/${symbol}`);
    return parseFloat(response.data.price);
  } catch (error) {
    console.error(`❌ LCX error: ${error.message}`);
    return null;
  }
}

// Agregrează prețuri (median)
async function aggregatePrices(symbol) {
  const prices = [];

  const cbPrice = await getPriceFromCoinbase(symbol);
  if (cbPrice) prices.push(cbPrice);

  const krPrice = await getPriceFromKraken(symbol);
  if (krPrice) prices.push(krPrice);

  const lcxPrice = await getPriceFromLCX(symbol);
  if (lcxPrice) prices.push(lcxPrice);

  if (prices.length === 0) throw new Error(`No prices found for ${symbol}`);

  // Median
  prices.sort((a, b) => a - b);
  const median = prices[Math.floor(prices.length / 2)];

  return {
    symbol,
    price: median,
    sources: prices.length,
    timestamp: new Date().toISOString(),
  };
}

// Trimite pe L2 via Smart Contract
async function updatePriceOnL2(symbol, price) {
  const provider = new ethers.JsonRpcProvider(process.env.L2_RPC_URL);
  const signer = new ethers.Wallet(process.env.ORACLE_PRIVATE_KEY, provider);

  const priceFeedABI = [
    'function updatePrice(string memory _symbol, uint256 _price, string memory _source) external',
  ];

  const contract = new ethers.Contract(
    process.env.PRICE_FEED_ADDRESS,
    priceFeedABI,
    signer
  );

  try {
    const tx = await contract.updatePrice(symbol, ethers.parseEther(price.toString()), 'aggregated');
    await tx.wait();
    console.log(`✅ Updated ${symbol}: $${price} (tx: ${tx.hash})`);
    return true;
  } catch (error) {
    console.error(`❌ L2 update error: ${error.message}`);
    return false;
  }
}

// Main loop
async function runOracle() {
  console.log('🚀 OmniBus Oracle Started');

  const symbols = ['BTC/USD', 'ETH/USD'];

  setInterval(async () => {
    for (const symbol of symbols) {
      try {
        const aggregated = await aggregatePrices(symbol);
        console.log(
          `📊 ${aggregated.symbol}: $${aggregated.price} (${aggregated.sources} sources)`
        );

        await updatePriceOnL2(symbol, aggregated.price);
      } catch (error) {
        console.error(`❌ Error processing ${symbol}: ${error.message}`);
      }
    }
  }, 10000);  // Actualizează la 10 secunde
}

runOracle();
```

### 2.2 .env.example
```env
# L2 Configuration
L2_RPC_URL=http://localhost:8545
PRICE_FEED_ADDRESS=0x...  # Adresa contractului PriceFeed pe L2

# Oracle Wallet
ORACLE_PRIVATE_KEY=0x...  # Private key-ul care actualizează prețurile

# Exchange APIs
COINBASE_API_KEY=...
KRAKEN_API_KEY=...
LCX_API_KEY=...

# Monitoring
SLACK_WEBHOOK=...
```

### 2.3 package.json
```json
{
  "name": "omnibus-oracle",
  "version": "1.0.0",
  "scripts": {
    "start": "node src/aggregator.js",
    "test": "jest"
  },
  "dependencies": {
    "axios": "^1.6.0",
    "ethers": "^6.9.0",
    "dotenv": "^16.3.1"
  }
}
```

---

## 🎨 PASUL 3: Frontend (React)

### 3.1 pages/index.tsx - Dashboard
```typescript
import React, { useEffect, useState } from 'react';
import { useContractRead } from 'wagmi';
import PriceChart from '@/components/PriceChart';

const Dashboard: React.FC = () => {
  const [prices, setPrices] = useState<Record<string, number>>({});
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Citeste prețuri din contract la fiecare 5 secunde
    const interval = setInterval(async () => {
      try {
        const response = await fetch('/api/prices');
        const data = await response.json();
        setPrices(data);
        setLoading(false);
      } catch (error) {
        console.error('Error fetching prices:', error);
      }
    }, 5000);

    return () => clearInterval(interval);
  }, []);

  return (
    <div className="p-8 bg-gradient-to-br from-blue-50 to-indigo-100 min-h-screen">
      <h1 className="text-4xl font-bold text-indigo-900 mb-8">
        🚀 OmniBus L2 Dashboard
      </h1>

      {loading ? (
        <p>Loading prices...</p>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          {Object.entries(prices).map(([symbol, price]) => (
            <div
              key={symbol}
              className="bg-white rounded-lg shadow-lg p-6"
            >
              <h2 className="text-xl font-semibold text-gray-800">{symbol}</h2>
              <p className="text-3xl font-bold text-green-600">${price.toFixed(2)}</p>
              <PriceChart symbol={symbol} />
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default Dashboard;
```

### 3.2 hooks/usePrices.ts
```typescript
import { useContractRead } from 'wagmi';
import PriceFeedABI from '@/abi/PriceFeed.json';

export function usePrices(symbols: string[]) {
  const [prices, setPrices] = React.useState<Record<string, number>>({});

  React.useEffect(() => {
    const fetchPrices = async () => {
      for (const symbol of symbols) {
        const { data } = useContractRead({
          address: process.env.NEXT_PUBLIC_PRICE_FEED_ADDRESS,
          abi: PriceFeedABI,
          functionName: 'getLatestPrice',
          args: [symbol],
        });

        if (data) {
          setPrices((prev) => ({
            ...prev,
            [symbol]: parseFloat(data),
          }));
        }
      }
    };

    fetchPrices();
    const interval = setInterval(fetchPrices, 5000);
    return () => clearInterval(interval);
  }, [symbols]);

  return prices;
}
```

---

## 🏃 QUICK START - 5 Minute Setup

### 1️⃣ Setup Folder & Files
```bash
mkdir -p OmniBus-OptimismLayer2/{smart-contracts,oracle-service,frontend}
cd OmniBus-OptimismLayer2
```

### 2️⃣ Smart Contracts (Foundry)
```bash
cd smart-contracts
forge init . --no-git

# Copiază PriceFeed.sol, OmnibusToken.sol, SimpleDEX.sol în contracts/

# Deploy (local)
forge create contracts/PriceFeed.sol --rpc-url http://localhost:8545 \
  --private-key $PRIVATE_KEY
```

### 3️⃣ Oracle Service
```bash
cd ../oracle-service
npm init -y
npm install axios ethers dotenv

# Copiază aggregator.js
node src/aggregator.js
```

### 4️⃣ Frontend
```bash
cd ../frontend
npx create-next-app@latest . --typescript

npm install wagmi viem @rainbow-me/rainbowkit axios
npm run dev
```

### 5️⃣ Test
```bash
# Terminal 1: Oracle
npm run start

# Terminal 2: Frontend
npm run dev

# Terminal 3: Monitor
curl http://localhost:8545 -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[],"id":1}'
```

---

## ✅ Verificare Completed

- [ ] PriceFeed.sol deployed pe L2
- [ ] OmnibusToken.sol distributed la users
- [ ] Oracle service citind de la 3 exchange-uri
- [ ] Frontend afișând prețuri live
- [ ] SimpleDEX permitând swaps cu Oracle prices

---

**Status**: 🟢 Ready to Deploy!
