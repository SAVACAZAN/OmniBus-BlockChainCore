# OMNIBUS PROTOCOL — ENCYCLOPEDIC REFERENCE v1.0
*Citizendium / Infoplease style — 2026-03-26*

---

## CE ESTE OMNIBUS PROTOCOL

**Omnibus Protocol** este un ecosistem software complet pentru trading algoritmici de înaltă frecvență și stocare securizată de valoare, construit pe criptografie post-quantum. Proiectul cuprinde 6 repository-uri publice pe GitHub, acoperind tot stackul de la bare-metal OS până la wallet desktop și interfețe web.

**Creat de:** SAVACAZAN / OmniBusDSL
**Limbaje principale:** Zig, C++, Python, TypeScript/React, Ada, Assembly x86-64
**Securitate:** Post-quantum (ML-DSA-87, Falcon-512, SLH-DSA-256s, ML-KEM-768 via liboqs)

---

## CELE 6 COMPONENTE

### 1. OmniBus — Bare-Metal HFT OS
`github.com/SAVACAZAN/OmniBus` | Zig + Ada + ASM | 28MB

**Ce este:** Un sistem de operare complet (fără Linux) care rulează direct pe hardware x86-64, dedicat exclusiv trading-ului de ultra-înaltă frecvență.

**Arhitectură (5 niveluri, 54+ module):**
- **Tier 1** (Trading): `analytics_os`, `execution_os`, `grid_os`, `bot_strategies` (25 fișiere)
- **Tier 2** (Sistem): `database_os`, `audit_log_os`
- **Tier 3** (Coordonare): `consensus_engine_os`, `bank_os` (SWIFT/ACH)
- **Tier 4** (Protecție): `cross_chain_bridge_os`, `dao_governance_os`, `domain_resolver`
- **Tier 5** (Verificare): Ada SPARK + Coq + Why3 (formal proofs)

**Performanță țintă:** Latență Tier 1 ~40µs | Memorie 3.2MB | Verificare formală 99%+

**Unic în ecosistem:** `bank_os` — integrare SWIFT (8KB) și ACH (11.8KB) pentru settlement bancar real.

---

### 2. OmniBus-BlockChainCore — Nodul Blockchain
`github.com/SAVACAZAN/OmniBus-BlockChainCore` | Zig 0.15.2 + Node.js + React | Scor: ~87%

**Ce este:** Nod blockchain complet, rulabil, cu criptografie post-quantum nativă și compatibilitate Bitcoin.

**Parametri blockchain:**

| Parametru | Valoare |
|-----------|---------|
| Supply maxim | 21,000,000 OMNI |
| 1 OMNI | 1,000,000,000 SAT |
| Block time | 10s |
| Difficulty | 4 zerouri hex (SHA256d PoW) |
| Block reward | 50 OMNI, halving la 210,000 |
| Semnătură | secp256k1 ECDSA |

**5 domenii PQ (coin types 777–781):**

| Prefix | CoinType | Algoritm |
|--------|----------|----------|
| `ob_omni_` | 777 | ML-DSA-87 + ML-KEM-768 |
| `ob_k1_` | 778 | ML-DSA-87 (Dilithium-5) |
| `ob_f5_` | 779 | Falcon-512 |
| `ob_d5_` | 780 | ML-DSA-87 |
| `ob_s3_` | 781 | SLH-DSA-256s (SPHINCS+) |

**RPC API (port 8332):**

| Metodă | Descriere |
|--------|-----------|
| `getbalance` | address, balance, balanceOMNI, nodeHeight |
| `sendtransaction` | txid, from, to, amount, status=accepted |
| `gettransactions` | TX history per adresă: txid/from/to/amount/status/direction/blockHeight |
| `getblockcount` | Număr blocuri în chain |
| `getlatestblock` | index, hash, timestamp, nonce, txCount |
| `getmempoolsize` | TX pending |
| `getstatus` | Status complet nod |

**Implementat 2026-03-26:**
- `validateTransaction` — verificare hash integrity SHA256d (anti-tampering)
- `gettransactions` — scanare mempool + blocuri, filtru opțional adresă
- `database.zig` — persistență binară (`omnibus-chain.dat`), atomic write tmp→rename
- `storage.zig` — fix deinit memory leak (iterator duplex)

---

### 3. v5-CppMono — Grid-DSL Trading Engine
`github.com/SAVACAZAN/v5-CppMono` | C++ | 250 opcodes | <50ns parsing

**Ce este:** Un DSL (Domain-Specific Language) pentru strategii de trading algorithmic, expus via C-ABI pentru 92+ limbaje de programare.

**Categorii de comenzi (12 categorii, 250 keywords):**
Grid strategies, risk management, order placement, backtesting, alerts, position sizing, indicators, automation, exchange-specific, monitoring, DCA, statistical analysis.

**Bindings generate automat (SWIG):**
Python, Java, C#, Go, Node.js, Rust, Zig, Ada + 84 altele.

**Platforme:** 100+ (Windows, Linux, macOS, BSD, Android, iOS, WebAssembly, FreeRTOS, Solaris, AIX)

**Exemplu DSL:**
```
grid.set_range(95000, 105000)
grid.set_levels(20)
risk.max_drawdown(5%)
order.buy_limit(BTC/USDT, 0.01, 98000)
alert.price_above(110000, "Take profit!")
```

---

### 4. HFT-MultiExchange — Agregator Exchange
`github.com/OmniBusDSL/HFT-MultiExchange` | Zig (backend) + TypeScript/React (frontend) | ⭐1

**Ce este:** Platformă HFT cu agregare real-time a order book-urilor de la LCX, Kraken, Coinbase + scanner arbitraj.

**Backend Zig:**
- 37 endpoint REST (HTTP/1.1)
- SQLite WAL mode pentru persistență
- JWT (HMAC-SHA256) + PBKDF2 auth
- XChaCha20-Poly1305 pentru cheile API stocate
- Thread-safe concurrent requests

**Suite avansată (ORDERBOOKDOMINATOR/):**
- `lcx-sentinel/` (TypeScript) — monitorizare LCX
- `order-shield/` — protecție ordine private
- `shield-dashboard/` — Zig desktop monitor
- Integrare Gemini AI

**Notă:** Bug gzip Zig 0.14.0 pentru răspunsuri compressed — workaround prin HTTP polling.

---

### 5. OmnibusSidebar — Desktop Trading App
`github.com/OmniBusDSL/OmnibusSidebar` | C++17 + Raylib 5.0 + Dear ImGui 1.92 | ~2.3MB exe

**Ce este:** Aplicație desktop Windows (sidebar lateral, always-on-top, transparent) cu 5 tab-uri de trading și wallet integrat.

**Tab-uri:**

| Tab | Funcționalitate | Status |
|-----|----------------|--------|
| PRICES | Prețuri live 3 exchange-uri, 1s polling | ✅ 100% |
| CHARTS | Candlestick OHLCV, 5 timeframes, zoom | ✅ 100% |
| WALLET | Balance + send → RPC Zig port 8332 | ✅ 90% |
| TRADE | Buy/sell UI + modal confirmare | ⚠️ 15% (HMAC TODO) |
| VAULT | DPAPI encrypted storage | ✅ 90% |

**SuperVault (subsistem criptare):**
- Protocol: `[opcode:1][exchange:1][slot:2][payload_len:2][payload]`
- Pipe: `\\.\pipe\OmnibusVault`
- `vault.dat` format v4, magic `OMNV`
- `vault_manager.py` — 2130 linii, Tkinter GUI, 4 tab-uri

**OmnibusWallet Python (19 chain-uri + 5 domenii PQ):**
BTC, ETH, SOL, BNB, ADA, DOT, XRP, XLM, LTC, BCH, OP, ATOM, EGLD, DOGE + OMNI + 5 PQ domains

---

### 6. OmniBus-Connect — Python Exchange Gateway
`github.com/OmniBusDSL/OmniBus-Connect-Multi-Exchange-EndPointss` | Python | 7,900+ linii

**Ce este:** Gateway Python unificat pentru 9 exchange-uri, cu DSL de trading și module de intelligence.

**Exchange-uri (Tier 1):** LCX, Kraken, Coinbase — full DSL + WebSocket + private endpoints
**Exchange-uri (Tier 2):** Binance, OKX, Bybit, Gate.io, Bitget, KuCoin
**Succes rate testare:** 85.1% din 74 endpoint-uri publice

**Module DSL intelligence:**

| Modul | Funcție |
|-------|---------|
| `arbitrage_dsl.py` | Detecție discrepanțe multi-exchange, profit fee-adjusted |
| `bot_trading_dsl.py` | Grid trading, DCA, TP/SL, trend-following |
| `indicators_dsl.py` | SMA, EMA, RSI, MACD, Bollinger, semnale automate |
| `stats_dsl.py` | Sharpe/Sortino, drawdown, corelație, rapoarte |
| `live_data_integration.py` | Streaming real-time, fallback graceful |

**Extensie VSCode:** syntax highlighting pentru `.omnibus` script files.

---

## ARHITECTURA GLOBALĂ

```
USER INTERFACES
├── OmnibusSidebar (C++ desktop, Windows)
├── HFT-MultiExchange Frontend (React, browser)
└── CLI (Python, Node.js)
        │
INTEGRATION LAYER
├── HTTP/JSON-RPC (port 8332) ── BlockchainCore ← Sidebar mod_wallet
├── Named Pipe (\\.\pipe\OmnibusVault) ── SuperVault ← Sidebar
├── REST API (port 8000) ── HFT-MultiExchange ← React Frontend
├── C-ABI / SWIG ── v5-CppMono DSL ← Python Connect
└── [PLANIFICAT] gRPC / WASM / FFI
        │
CORE ENGINES
├── Zig Blockchain Node (secp256k1, PQ, BIP-32/39, PoW)
├── C++ DSL Engine (250 opcodes, <50ns, 92 limbaje)
├── Python Exchange Gateway (9 exchange-uri, DSL AI)
└── Zig HFT Aggregator (37 REST, SQLite, JWT)
        │
INFRASTRUCTURE
├── OmniBus bare-metal OS (Zig/Ada/ASM, 54 module)
├── Mining Pool (Node.js, dynamic registration)
└── Exchange APIs (LCX, Kraken, Coinbase + 6 altele)
```

---

## INTERCONEXIUNI REALE

```
OmniBus-BlockChainCore (port 8332)
    ← WinHTTP POST: OmnibusSidebar mod_wallet.cpp
    ← React frontend (BlockchainCore/frontend)

OmnibusSidebar (C++)
    → Named Pipe \\.\pipe\OmnibusVault → SuperVault (Python)
    → WinHTTP → BlockchainCore port 8332

v5-CppMono DSL (C-ABI)
    → Python ctypes bindings → OmniBus-Connect
    → Ada bindings → OmniBus bare-metal formal verification

HFT-MultiExchange openapi.json
    → generate_dsl_from_json.py → OmniBus-Connect cod-gen

OmniBus (bare-metal)
    → execution_os: Dilithium PQ signing (pattern comun cu BlockChainCore)
    → bank_os: SWIFT/ACH (unic în ecosistem)
```

---

## WHITEPAPER OMNIBUS PROTOCOL v1.0

**Titlu:** Multi-Chain HD Wallet with Post-Quantum Security and Utility Domains
**Autori:** SAVACAZAN | **Data:** 2026-03-26 | **Versiune:** 1.0

### Layers

| Layer | Nume | Descriere |
|-------|------|-----------|
| L0 | Identity | Single BIP39 seed → HD derivare multi-chain |
| L1 | OMNI | Store-of-value, 21M supply fix, transferabil |
| L2 | Utility Domains | omnibus.omni/.love/.food/.rent/.vacation — non-transferabile |
| L3 | Cross-Chain Anchors | Settlement proofs pe BTC/ETH |
| L4 | Applications | Marketplaces, loyalty, HFT, subscriptions |

### Derivare HD
- OMNI: `m/84'/777'/0'/0/i`
- BTC: `m/84'/0'/0'/0/i`
- Domains: `m/44'/777'/domain_index'/0/i`
- Format adresă: `prefix` + primii 12 hex din `RIPEMD160(SHA256(pubkey))`

---

## PLAN MULTI-LANGUAGE (WASM / FFI / gRPC)

### De ce
Toate componentele rulează izolat. Scopul este să fie apelabile din orice limbaj fără a copia logica criptografică.

### WASM
- Zig core (`bip32_wallet.zig`, `pq_crypto.zig`, `transaction.zig`) → compilat `wasm32-freestanding`
- C++ DSL (`grid_dsl.cpp`) → WASM via Emscripten
- Integrare în React frontends existente pentru wallet în browser

### FFI
- Zig → static lib `libomnibus_core.a` + header `omnibus_core.h` → link în C++ (OmnibusSidebar)
- Zig → shared lib `.dll/.so` → Python ctypes (SuperVault, OmniBus-Connect)
- C++ DSL → deja SWIG pentru Python (extins la toate modulele)

### gRPC
```protobuf
service WalletService {
    rpc DeriveKey (DeriveRequest) returns (KeyPair);
    rpc SignTransaction (SignRequest) returns (Signature);
    rpc GetBalance (BalanceRequest) returns (Balance);
}
service TradingDSL {
    rpc Execute (DSLCommand) returns (ExecutionResult);
}
service ExchangeAggregator {
    rpc GetTicker (TickerRequest) returns (Ticker);
    rpc DetectArbitrage (ArbitrageRequest) returns (ArbitrageResponse);
}
```

---

## SCOR GENERAL ECOSISTEM

| Componentă | Scor | Status |
|-----------|------|--------|
| Blockchain Core (Zig) | 87% | Rulabil, validateTx + persistence REAL |
| Crypto (secp256k1, PQ, BIP-32) | 92% | Funcțional; crypto.zig AES=XOR stub |
| RPC Server (JSON-RPC 2.0) | 97% | Complet + gettransactions |
| Mining Pool (Node.js) | 95% | Dynamic, persistent |
| Desktop App (C++ sidebar) | 82% | Funcțional; trading execution 15% |
| SuperVault (DPAPI/Python) | 88% | Windows OK; Linux TODO |
| DSL Engine (C++) | 85% | Engine OK; integration tests lipsesc |
| HFT Aggregator (Zig+React) | 80% | Funcțional; gzip bug, JWT TODO |
| Python Exchange Gateway | 78% | 85% endpoint success; live auth TODO |
| Bare-metal OS | 60% | Design + docs; boot real neconfirmat |
| P2P Network (Zig) | 35% | Framework; TCP real lipsește |
| Cross-language bindings | 20% | Planificat (WASM/FFI/gRPC) |

**MEDIE GLOBALĂ: ~78%**

---

## NEXT STEPS PRIORITARE

1. **P2P TCP real** — `network.zig` → `std.net` socket, peer sync
2. **HMAC trading signing** — `mod_trade.cpp` → Kraken/LCX HMAC-SHA256 real
3. **WASM wallet** — compila `bip32_wallet.zig` + `pq_crypto.zig` → WASM pentru browser
4. **gRPC proto** — `omnibus.proto` cu WalletService + TradingDSL + ExchangeAggregator
5. **key_encryption.zig** — AES-256 real (`std.crypto.aes`), nu XOR
6. **Linux SuperVault** — libsodium înlocuiește DPAPI pe non-Windows
7. **HFT gzip fix** — Zig 0.15.2 gzip decompression pentru Kraken/Coinbase
8. **Database sync** — `blockchain.chain` → `database.db.blocks` la fiecare bloc minat
9. **vault_client.cpp** — update opcodes la v4 (acum are v1/v2)
10. **Docker Compose** — full stack: nod Zig + mining pool + HFT aggregator + sidebar

---

## INSTRUCȚIUNI PENTRU AGENT AI

Dacă ești un agent AI care citești acest document, iată contextul complet:

**Proiectul este real și funcțional** — nu este un proiect demo. Codul compilează și rulează.

**Limbaje și build tools:**
- Zig 0.15.2: `zig build` în `OmniBus-BlockChainCore/`
- C++17 MinGW: `mingw32-make` în `OmnibusSidebar/`
- Python 3.x: `pip install bip_utils secp256k1`
- Node.js: `node rpc-server.js` pentru mining pool

**Zig 0.15.2 — diferențe față de versiuni mai vechi:**
- `std.ArrayList` → `std.array_list.Managed(T)`
- `file.reader()` → `file.reader(buffer: []u8)` (necesită buffer explicit)
- `catch |_|` → `catch` (discard error capture interzis)
- `std.io.bufferedReader` → nu există; folosește `file.readAll(buf)` + `std.mem.readInt`

**Windows specifics:**
- RPC server folosește `ws2_32.recv` direct (nu `ReadFile` pe socket)
- DPAPI disponibil via `CryptProtectData/CryptUnprotectData`
- Named Pipe: `\\.\pipe\OmnibusVault`
- Build C++: `g++ -std=c++17 ... -lwinhttp -lwininet -lraylib -lcrypt32`

**Structura locală:**
```
C:\Kits work\limaje de programare\
├── OmniBus-BlockChainCore\   (git: SAVACAZAN/OmniBus-BlockChainCore)
├── OmnibusSidebar\           (git: OmniBusDSL/OmnibusSidebar)
└── liboqs-src\build\lib\liboqs.a   (compilat MinGW)
```

---

*Document generat din analiza directă a codului sursă și documentației din toate 6 repository-uri.*
*Versiune: 1.0 | Data: 2026-03-26 | Autor: SAVACAZAN*
