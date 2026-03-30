# OmniBus Wallet: Stare Actuală vs. Toate Opțiunile
## Analiză Completă a Ecosistemului de Wallet-uri

---

## ✅ CE AVEȚI DEJA CONSTRUIT (Status Quo)

### 1. WALLET CORE ZIG (`core/wallet.zig` + `core/bip32_wallet.zig`)

```
┌─────────────────────────────────────────────────────────────────┐
│                    OMNIUS CORE WALLET (Zig)                      │
├─────────────────────────────────────────────────────────────────┤
│  Status: ✅ PRODUCȚIE-READY                                      │
│  Locație: core/wallet.zig, core/bip32_wallet.zig                │
├─────────────────────────────────────────────────────────────────┤
│  Features:                                                       │
│  • BIP-39 mnemonic → seed (PBKDF2-HMAC-SHA512)                  │
│  • BIP-32 HD derivation (real, cu secp256k1 nativ)              │
│  • 5 domenii Post-Quantum:                                      │
│    - ob_omni_  (777) - ML-DSA-87                               │
│    - ob_k1_    (778) - ML-DSA-87                               │
│    - ob_f5_    (779) - Falcon-512                              │
│    - ob_d5_    (780) - ML-DSA-87                               │
│    - ob_s3_    (781) - SLH-DSA-256s                            │
│  • Semnare tranzacții secp256k1 ECDSA                           │
│  • Base58Check encoding (version 0x4F)                          │
│  • Generare adresă deterministă din seed                        │
└─────────────────────────────────────────────────────────────────┘
```

**Utilizare:**
```zig
const wallet = try Wallet.fromMnemonic(mnemonic, "", allocator);
// wallet.address = "ob_omni_abc123..."
// wallet.addresses[0..5] = toate cele 5 adrese PQ
```

---

### 2. WEB WALLET REACT (`frontend/src/components/wallet/`)

```
┌─────────────────────────────────────────────────────────────────┐
│                    OMNIUS WEB WALLET                             │
├─────────────────────────────────────────────────────────────────┤
│  Status: ✅ FUNCȚIONAL                                           │
│  Locație: frontend/src/components/wallet/WalletPage.tsx         │
├─────────────────────────────────────────────────────────────────┤
│  Stack: React + TypeScript + Vite                               │
│  UI: Tailwind CSS (stil Mempool-like)                           │
├─────────────────────────────────────────────────────────────────┤
│  Features:                                                       │
│  • Login cu BIP-39 mnemonic                                     │
│  • Afișare balance în OMNI și SAT                               │
│  • Send/Receive tranzacții                                      │
│  • Afișare 5 adrese PQ (omni, love, food, rent, vacation)       │
│  • Transaction history                                          │
│  • Auto-refresh la fiecare 5 secunde                            │
│  • Conectare via RPC la omnibus-node (port 8332)                │
└─────────────────────────────────────────────────────────────────┘
```

**Acces:** `http://localhost:5173` (când rulează dev server)

---

### 3. SIDEBAR DESKTOP WALLET (`OmnibusSidebar/`)

```
┌─────────────────────────────────────────────────────────────────┐
│                  OMNIUS SIDEBAR WALLET                           │
├─────────────────────────────────────────────────────────────────┤
│  Status: ✅ FUNCȚIONAL (v4.0)                                    │
│  Locație: C:\Kits work\limaje de programare\OmnibusSidebar      │
├─────────────────────────────────────────────────────────────────┤
│  Stack: C++17 + ImGui + Raylib                                  │
│  UI: ImGui cu tema dark (Win11 style)                           │
│  Build: MinGW-w64 (Windows), Makefile pentru FreeBSD            │
├─────────────────────────────────────────────────────────────────┤
│  Features:                                                       │
│  • Tab WALLET complet funcțional                                │
│  • Import wallet din JSON (generate_miners.py)                  │
│  • Setare OMNIBUS_MNEMONIC în environment                       │
│  • Balance live + TX history                                    │
│  • Send OMNI cu confirmare                                      │
│  • Auto-refresh la fiecare 5 secunde                            │
│  • Conectare RPC direct la 127.0.0.1:8332 (WinHTTP)             │
│  • UI nativ, fereastră transparentă, sidebar dreapta            │
├─────────────────────────────────────────────────────────────────┤
│  Module:                                                         │
│  • mod_wallet.cpp    - Wallet tab (import, send, history)       │
│  • mod_prices.cpp    - Prețuri de la exchanges (LCX, Kraken)    │
│  • mod_trade.cpp     - Trading interface                        │
│  • mod_charts.cpp    - Grafice preț                             │
│  • mod_log.cpp       - Log system                               │
│  • mod_toast.cpp     - Notificări toast                         │
│  • fetch.cpp         - HTTP client pentru API externe           │
└─────────────────────────────────────────────────────────────────┘
```

**Executable:** `OmnibusSidebar.exe` (Windows)

**Screenshot mental:**
```
┌─────────────────────────────────────────────────────────────────────────┐
│  [OMNIBUS TERMINAL v4]                    [PRICES] [TRADE] [LOG] [WALLET]│
│                                                                         │
│  ┌─────────────────────────────────────┐  ┌──────────────────────────┐ │
│  │                                     │  │  NODE OK  block 12345    │ │
│  │   CHART AREA (transparent)          │  │                          │ │
│  │   (afișează grafice prețuri)        │  │  123.4567 OMNI           │ │
│  │                                     │  │  ob_omni_abc123...       │ │
│  │                                     │  │  15 tranzactii           │ │
│  │                                     │  │                          │ │
│  │                                     │  │  [Refresh] [Auto 5s]     │ │
│  │                                     │  │                          │ │
│  │                                     │  │  [IMPORT WALLET]         │ │
│  │                                     │  │                          │ │
│  │                                     │  │  ─TRIMITE OMNI─────────  │ │
│  │                                     │  │  Adresa: [____________]  │ │
│  │                                     │  │  Cantitate: [1.0] OMNI   │ │
│  │                                     │  │                          │ │
│  │                                     │  │  [  SEND  ]              │ │
│  │                                     │  │                          │ │
│  │                                     │  │  ─TRANZACTII RECENTE───  │ │
│  │                                     │  │  confirmed  sent    10.0 │ │
│  │                                     │  │  confirmed  recv     5.0 │ │
│  └─────────────────────────────────────┘  └──────────────────────────┘ │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
        ▲                                           ▲
        │                                           │
   Chart transparent                    Sidebar wallet (430px)
   (tot ecranul)                        (bg: #07080C, rounded)
```

---

### 4. CLI WALLET (`core/cli.zig`)

```
┌─────────────────────────────────────────────────────────────────┐
│                    OMNIUS CLI WALLET                             │
├─────────────────────────────────────────────────────────────────┤
│  Status: ✅ FUNCȚIONAL                                           │
│  Locație: core/cli.zig                                          │
├─────────────────────────────────────────────────────────────────┤
│  Comenzi disponibile:                                            │
│  • --generate-wallet    Generează wallet și afișează JSON       │
│  • --mode seed/miner    Rulează nod                             │
│  • --help               Ajutor                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Exemplu:**
```bash
omnibus-node --generate-wallet
# Output: {"address":"ob_omni_...","mnemonic":"abandon abandon..."}
```

---

## 📊 SUMAR: CE AVEȚI vs. CE LIPSEȘTE

| Componentă | Aveți? | Detalii | Prioritate |
|------------|--------|---------|------------|
| **Core wallet Zig** | ✅ | BIP-32/39 + 5 domenii PQ | - |
| **Web wallet React** | ✅ | Browser-based, RPC | - |
| **Sidebar desktop C++** | ✅ | ImGui+Raylib, nativ | - |
| **CLI wallet** | ✅ | Command-line | - |
| Mobile wallet (iOS/Android) | ❌ | React Native / Flutter | 🔴 HIGH |
| Hardware wallet (Trezor) | ❌ | Firmware custom | 🟡 MED |
| Hardware wallet (Ledger) | ❌ | App + audit | 🟡 MED |
| MetaMask Snap | ❌ | Browser extension PQ | 🟡 MED |
| SDK pentru integratori | ❌ | TypeScript/Go | 🟢 LOW |
| EVM compatibility | ❌ | MetaMask/Trust via EVM | 🔴 HIGH |
| WalletConnect v2 | ❌ | Mobile wallets | 🔴 HIGH |

---

## 🎯 OPȚIUNI PENTRU EXTINDERE

### Grupa A: Mobile (Prioritate HIGH)

| Opțiune | Tech Stack | Pro | Contra | Timp |
|---------|-----------|-----|--------|------|
| **eStream Fork** | React Native + Rust | Are Dilithium5, hardware enclave | Trebuie adăugat Falcon+SLH | 2-3 săpt |
| **QRL Fork** | React Native (Meteor) | XMSS matur, Ledger integration | Trebuie înlocuit XMSS cu PQ | 3-4 săpt |
| **Tether WDK** | TypeScript SDK | Multi-chain, profesional | Mai puțin control UI | 1-2 săpt |
| **From scratch** | Flutter + Zig bindings | Control total | Timp mare dezvoltare | 1-2 luni |

**Recomandare:** Fork eStream App (are deja Dilithium5, similar cu ML-DSA-87)

---

### Grupa B: Hardware Wallets (Prioritate MED)

| Opțiune | Cost | Timp | Dificultate |
|---------|------|------|-------------|
| **Trezor Safe 7** | Gratuit (open source) | 2-4 săpt | Medie |
| **Ledger Nano S/X** | €15K-50K audit | 3-6 luni | Mare |
| **AirGap Vault** | Open source | 2-3 săpt | Medie |

**Recomandare:** Trezor Safe 7 (firmware complet open source, are SLH-DSA-128)

---

### Grupa C: Browser Extension (Prioritate MED)

| Opțiune | Tech | Pro | Contra |
|---------|------|-----|--------|
| **MetaMask Snap** | TypeScript | Standard industry, ușor de distribuit | Depinde de MetaMask |
| **From scratch** | Zig→WASM + WebExtension API | Control total | Timp mare |

**Recomandare:** MetaMask Snap pentru PQ nativ în browser

---

### Grupa D: Compatibilitate Externă (Prioritate HIGH)

| Opțiune | Wallet-uri activate | Timp | Dificultate |
|---------|---------------------|------|-------------|
| **EVM Adapter** | MetaMask, Trust, Rabby, Rainbow (50+) | 1-2 săpt | Mică |
| **WalletConnect v2** | Trust Mobile, Rainbow, Argent (30+) | 1-2 săpt | Mică |
| **Ambele** | Toate de mai sus | 2-3 săpt | Medie |

**Recomandare:** Implementați ambele pentru adopție maximă

---

## 🏗️ ARHITECTURA ȚINTĂ (Viziune Completă)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                       OMNIUS UNIVERSAL WALLET ECOSYSTEM                          │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────────┐ │
│  │                        CORE LAYER (Zig)                                    │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐  │ │
│  │  │  BIP-39/32  │ │  secp256k1  │ │  ML-DSA-87  │ │  Falcon-512         │  │ │
│  │  │  HD Wallet  │ │  ECDSA Sign │ │  PQ Sign    │ │  PQ Sign            │  │ │
│  │  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────────────┘  │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐  │ │
│  │  │ SLH-DSA-256s│ │ Base58Check │ │ Transaction │ │  RPC Client         │  │ │
│  │  │  PQ Sign    │ │  Encoding   │ │  Builder    │ │  (JSON-RPC 2.0)     │  │ │
│  │  └─────────────┘ └─────────────┘ └─────────────┘ └─────────────────────┘  │ │
│  └───────────────────────────────────────────────────────────────────────────┘ │
│                                    │                                            │
│  ┌─────────────────────────────────┼────────────────────────────────────────┐  │
│  │                    ADAPTER LAYER (Multi-Platform)                        │  │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────────┐ │  │
│  │  │ Zig → WASM   │ │ Zig → C lib  │ │ Zig → Node   │ │  EVM Adapter     │ │  │
│  │  │ (Web)        │ │ (Mobile/Desk)│ │ (SDK)        │ │  (MetaMask)      │ │  │
│  │  └──────────────┘ └──────────────┘ └──────────────┘ └──────────────────┘ │  │
│  └─────────────────────────────────┼────────────────────────────────────────┘  │
│                                    │                                            │
│  ┌─────────────────────────────────┼────────────────────────────────────────┐  │
│  │                    UI LAYER (Wallet Applications)                        │  │
│  │                                                                          │  │
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐  ┌───────────┐ │  │
│  │  │  WEB          │  │  DESKTOP      │  │  MOBILE       │  │  HARDWARE │ │  │
│  │  │  (React)      │  │  (C++/ImGui)  │  │  (React Nat.) │  │  (Trezor) │ │  │
│  │  │               │  │               │  │               │  │           │ │  │
│  │  │ ✅ Aveți      │  │ ✅ Aveți      │  │ ❌ De făcut   │  │ ❌ De făcut│ │  │
│  │  │ frontend/     │  │ OmnibusSidebar│  │ (eStream fork)│  │           │ │  │
│  │  │               │  │               │  │               │  │           │ │  │
│  │  │ Browser       │  │ Windows/Linux │  │ iOS/Android   │  │ USB/BLE   │ │  │
│  │  └───────────────┘  └───────────────┘  └───────────────┘  └───────────┘ │  │
│  │                                                                          │  │
│  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐                │  │
│  │  │  BROWSER EXT  │  │  SDK          │  │  EXTERNAL     │                │  │
│  │  │  (MetaMask)   │  │  (TypeScript) │  │  WALLETS      │                │  │
│  │  │               │  │               │  │               │                │  │
│  │  │ ❌ De făcut   │  │ ❌ De făcut   │  │ ❌ De făcut   │                │  │
│  │  │               │  │               │  │ (EVM+WC)      │                │  │
│  │  │ Snap          │  │ npm package   │  │               │                │  │
│  │  └───────────────┘  └───────────────┘  └───────────────┘                │  │
│  │                                                                          │  │
│  └──────────────────────────────────────────────────────────────────────────┘  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📋 ROADMAP RECOMANDAT

### Faza 1: Consolidare (Acum - Săptămâna 2)
**Scop:** Faceți ce aveți să lucreze perfect împreună

- [ ] Compilează core Zig în WASM pentru web wallet
- [ ] Sidebar: Adaugă afișare 5 adrese PQ (acum doar primary)
- [ ] Sidebar: Export wallet în format JSON standard
- [ ] Unifică formatul export/import între toate wallet-urile

### Faza 2: Mobile (Săptămâna 3-5)
**Scop:** Portofel mobil nativ

- [ ] Fork eStream App
- [ ] Adaugă module Zig (ML-DSA, Falcon, SLH-DSA) ca Rust bindings
- [ ] UI pentru 5 domenii PQ
- [ ] QR code pentru send/receive

### Faza 3: Compatibilitate Externă (Săptămâna 6-8)
**Scop:** MetaMask, Trust, etc.

- [ ] EVM Adapter (eth_getBalance, eth_sendTransaction)
- [ ] WalletConnect v2 provider
- [ ] Testare cu MetaMask, Trust Wallet

### Faza 4: Hardware & Advanced (Săptămâna 9-12)
**Scop:** Securitate maximă

- [ ] Trezor Safe 7 firmware fork
- [ ] MetaMask Snap pentru PQ
- [ ] SDK public pentru integratori

---

## 🔄 INTEROPERABILITATE - CUM SE RECUNOSC

### Format Adresă (Toate wallet-urile)
```
ob_omni_<hash160>   - Coin 777 - ML-DSA-87
ob_k1_<hash160>     - Coin 778 - ML-DSA-87  
ob_f5_<hash160>     - Coin 779 - Falcon-512
ob_d5_<hash160>     - Coin 780 - ML-DSA-87
ob_s3_<hash160>     - Coin 781 - SLH-DSA-256s
```

### Export/Import JSON Standard
```json
{
  "format": "omnibus-wallet-v1",
  "mnemonic": "abandon abandon ... about",
  "created_with": "omnibus-sidebar-v4.0",
  "addresses": {
    "omni":     { "address": "ob_omni_...", "path": "m/44'/777'/0'/0/0" },
    "love":     { "address": "ob_k1_...",   "path": "m/44'/778'/0'/0/0" },
    "food":     { "address": "ob_f5_...",   "path": "m/44'/779'/0'/0/0" },
    "rent":     { "address": "ob_d5_...",   "path": "m/44'/780'/0'/0/0" },
    "vacation": { "address": "ob_s3_...",   "path": "m/44'/781'/0'/0/0" }
  }
}
```

### Deep Linking
```
omnibus://pay?to=ob_omni_abc123&amount=1000000000&domain=omni
```

---

## 📊 COMPARAȚIE: Soluții Open Source Identificate

| Proiect | GitHub | Stack | PQ Support | Relevanță |
|---------|--------|-------|------------|-----------|
| **QRL Wallet** | theQRL/qrl-wallet | Meteor+Electron | XMSS | 🟢🟢🟢 Desktop reference |
| **eStream App** | polyquantum/estream-app | React Native+Rust | **Dilithium5** | 🟢🟢🟢 **Mobile (folosiți!)** |
| **Tether WDK** | tetherto/wdk | TypeScript SDK | Extensibil | 🟢🟢🟢 SDK reference |
| **PQC Vault** | SimedruF/PQC_Vault | Tauri+Rust | Kyber+AES | 🟢🟢 Desktop PQ |
| **Quantum Safe** | ETHGlobal winner | Rust+STM32 | Falcon-512 | 🟢🟢 Hardware firmware |
| **Trezor Safe 7** | trezor/trezor-firmware | C+MicroPython | **SLH-DSA-128** | 🟢🟢🟢 **Hardware (folosiți!)** |
| **MetaMask Snaps** | metamask/snaps | TypeScript | Extensibil | 🟢🟢🟢 Browser standard |

---

## ✅ CHECKLIST ACȚIUNI IMEDIATE

### Pentru Sidebar (săptămâna aceasta):
- [ ] Adaugă afișare toate 5 adrese PQ în tab WALLET
- [ ] Adaugă buton "Export Wallet" cu JSON standard
- [ ] Verifică că importă JSON din generate_miners.py

### Pentru Core Zig:
- [ ] Compilează în WASM: `zig build -Dtarget=wasm32-wasi`
- [ ] Testează în web wallet (înlocuiește RPC cu WASM direct)

### Pentru Web Wallet:
- [ ] Adaugă fallback la RPC dacă WASM nu e disponibil
- [ ] Unifică stilul cu Sidebar (temă dark similară)

### Pentru Mobile (următoarele 2 săptămâni):
- [ ] Clonează eStream App
- [ ] Înlocuiește crypto lor cu Zig compilat ca Rust crate

---

*Document actualizat cu analiza completă OmnibusSidebar*
*Comparativ cu toate opțiunile open source identificate*
*Roadmap practic pentru extindere*
