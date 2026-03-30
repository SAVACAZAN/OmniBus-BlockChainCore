# OmniBus Wallet Integration Roadmap
## Integrare cu Wallet-uri Externe - Plan Complet

---

## 📊 Ce aveți acum (Analiză)

### Arhitectură curentă OmniBus:

```
┌─────────────────────────────────────────────────────────────────┐
│                    OMNIUS BLOCKCHAIN CORE                        │
├─────────────────────────────────────────────────────────────────┤
│  Wallet (bip32_wallet.zig)                                      │
│  ├── BIP-39 mnemonic → seed (PBKDF2-HMAC-SHA512)               │
│  ├── BIP-32 HD derivation (HMAC-SHA512 + secp256k1 real)       │
│  └── 5 domenii PQ:                                              │
│      • ob_omni_     (777) - ML-DSA-87                          │
│      • ob_k1_       (778) - ML-DSA-87                          │
│      • ob_f5_       (779) - Falcon-512                         │
│      • ob_d5_       (780) - ML-DSA-87                          │
│      • ob_s3_       (781) - SLH-DSA-256s                       │
│                                                                 │
│  RPC Server (rpc_server.zig) - Port 8332                       │
│  ├── getbalance, getblockcount, getlatestblock                 │
│  ├── sendtransaction, gettransactions                          │
│  ├── getnonce, estimatefee, gettransaction                     │
│  └── registerminer, getpoolstats, getnetworkinfo               │
│                                                                 │
│  Transaction (transaction.zig)                                  │
│  ├── SHA256d hashing (Bitcoin style)                           │
│  ├── ECDSA secp256k1 signing (REAL)                            │
│  ├── Nonce-based replay protection                             │
│  ├── OP_RETURN support (80 bytes max)                          │
│  └── Locktime support                                          │
└─────────────────────────────────────────────────────────────────┘
```

### Puncte forte:
- ✅ BIP-32/39 implementare reală și testată
- ✅ secp256k1 nativ (compatibil cu toate wallet-urile)
- ✅ 5 domenii PQ cu algoritmi diferiți
- ✅ RPC JSON funcțional
- ✅ Cod Zig pur, fără dependințe externe critice

### Puncte care necesită adaptare:
- ⚠️ Format adresă custom (nu EVM nativ)
- ⚠️ RPC propriu (nu standard EVM)
- ⚠️ Post-quantum semnare separată de flow-ul standard

---

## 🏗️ SOLUȚII OPEN SOURCE PENTRU WALLET OMNIBUS

### Opțiuni Identificate (100% Open Source)

| # | Proiect | GitHub | Licență | Stack | Crypto PQ | Platformă | Relevanță |
|---|---------|--------|---------|-------|-----------|-----------|-----------|
| 1 | **QRL Wallet** | theQRL/qrl-wallet | MIT | Meteor + NodeJS + Electron | XMSS (hash-based) | Web + Desktop | 🟢🟢🟢 Arhitectură matură, Ledger integration |
| 2 | **eStream App** | polyquantum/estream-app | Open | React Native + Rust | **Dilithium5** + Kyber | Mobile (iOS/Android) | 🟢🟢🟢 **Dilithium5 ca voi!** |
| 3 | **Tether WDK** | tetherto/wdk | Open | TypeScript SDK | Extensibil | Any (SDK multi-chain) | 🟢🟢🟢 Wallet SDK complet |
| 4 | **PQC Vault** | SimedruF/PQC_Vault | Open | Tauri + Rust | Kyber + AES | Desktop | 🟢🟢 Implementare liboqs |
| 5 | **Quantum Safe** | (ETHGlobal winner) | Open | Rust + STM32 | Falcon-512 | Embedded/Hardware | 🟢🟢 Firmware hardware |
| 6 | **Trezor Safe 7** | trezor/trezor-firmware | GPL | C + MicroPython | SLH-DSA-128 | Hardware | 🟢🟢🟢 Open source complet |
| 7 | **MetaMask Snaps** | metamask/snaps | Open | TypeScript | Extensibil | Browser extension | 🟢🟢🟢 Standard industry |

---

## 🎯 ARHITECTURĂ HIBRIDĂ UNIFICATĂ: "OmniBus Universal Wallet"

### Viziune: Un singur wallet care le recunoaște pe toate

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    OMNIUS UNIVERSAL WALLET ARCHITECTURE                          │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                    ADAPTER LAYER (Multi-Protocol)                        │   │
│  │  ┌──────────┐  ┌──────────────┐  ┌─────────────┐  ┌──────────────────┐  │   │
│  │  │  EVM     │  │ WalletConnect│  │   OmniBus   │  │   Hardware       │  │   │
│  │  │ Adapter  │  │   Provider   │  │    Native   │  │   Bridge         │  │   │
│  │  │ (MetaMask│  │   (v2)       │  │   (RPC)     │  │ (Ledger/Trezor)  │  │   │
│  │  │  etc.)   │  │              │  │             │  │                  │  │   │
│  │  └──────────┘  └──────────────┘  └─────────────┘  └──────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                    │                                            │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                 WALLET CORE (BIP-32/39 + PQ Manager)                     │   │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │   │
│  │  │                    BIP-39 Mnemonic Seed                         │   │   │
│  │  │                         │                                      │   │   │
│  │  │                         ▼                                      │   │   │
│  │  │  ┌─────────────────────────────────────────────────────────┐  │   │   │
│  │  │  │              BIP-32 Master Key                          │  │   │   │
│  │  │  │   m/44'/777'/0'/0/0  →  secp256k1  →  ob_omni_...     │  │   │   │
│  │  │  │   m/44'/778'/0'/0/0  →  secp256k1  →  ob_k1_...       │  │   │   │
│  │  │  │   m/44'/779'/0'/0/0  →  secp256k1  →  ob_f5_...       │  │   │   │
│  │  │  │   m/44'/780'/0'/0/0  →  secp256k1  →  ob_d5_...       │  │   │   │
│  │  │  │   m/44'/781'/0'/0/0  →  secp256k1  →  ob_s3_...       │  │   │   │
│  │  │  └─────────────────────────────────────────────────────────┘  │   │   │
│  │  │                         │                                      │   │   │
│  │  │                         ▼                                      │   │   │
│  │  │  ┌─────────────────────────────────────────────────────────┐  │   │   │
│  │  │  │              POST-QUANTUM KEY GENERATOR                  │  │   │   │
│  │  │  │  Entropy from BIP-32  →  ML-DSA-87  (2592B pk)         │  │   │   │
│  │  │  │  Entropy from BIP-32  →  Falcon-512 (897B pk)          │  │   │   │
│  │  │  │  Entropy from BIP-32  →  SLH-DSA-256s (64B pk)         │  │   │   │
│  │  │  └─────────────────────────────────────────────────────────┘  │   │   │
│  │  └─────────────────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                    │                                            │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │                    UI FRONTEND (Multi-Platform)                          │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │   │
│  │  │   Desktop    │  │    Mobile    │  │     Web      │  │   Browser    │  │   │
│  │  │  (Electron)  │  │(React Native)│  │   (WASM)     │  │  Extension   │  │   │
│  │  │              │  │              │  │              │  │              │  │   │
│  │  │ • QRL style  │  │ • eStream    │  │ • PQC Vault  │  │ • MetaMask   │  │   │
│  │  │ • Full node  │  │   style      │  │   style      │  │   Snap       │  │   │
│  │  │ • PQ crypto  │  │ • Seeker     │  │ • Cross-plat │  │ • Injected   │  │   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🚀 IMPLEMENTARE PRACTICĂ: "OmniBus Hybrid Wallet"

### Concept: Fork + Adaptare Inteligentă

#### A. Mobile Wallet (bazat pe eStream)

```typescript
// wallet-omnibus-mobile/
// Fork din estream-app, adaptat pentru 5 domenii

// src/services/vault/OmniBusVault.ts
export class OmniBusVault {
  // Suportă toți algoritmii
  private algorithms = {
    omni: { name: 'ML-DSA-87', coinType: 777, prefix: 'ob_omni_' },
    love: { name: 'ML-DSA-87', coinType: 778, prefix: 'ob_k1_' },
    food: { name: 'Falcon-512', coinType: 779, prefix: 'ob_f5_' },
    rent: { name: 'ML-DSA-87', coinType: 780, prefix: 'ob_d5_' },
    vacation: { name: 'SLH-DSA-256s', coinType: 781, prefix: 'ob_s3_' }
  };

  async generateAddresses(mnemonic: string): Promise<OmniBusAddresses> {
    // Generează toate cele 5 adrese din același seed
    return {
      omni: await this.deriveAddress(mnemonic, 777, 'ML-DSA-87'),
      love: await this.deriveAddress(mnemonic, 778, 'ML-DSA-87'),
      food: await this.deriveAddress(mnemonic, 779, 'Falcon-512'),
      rent: await this.deriveAddress(mnemonic, 780, 'ML-DSA-87'),
      vacation: await this.deriveAddress(mnemonic, 781, 'SLH-DSA-256s')
    };
  }
  
  async signTransaction(domain: string, tx: Transaction): Promise<Signature> {
    // Alege algoritmul corect în funcție de domeniu
    switch(domain) {
      case 'food': return this.falconSign(tx);
      case 'vacation': return this.slhDsaSign(tx);
      default: return this.mlDsaSign(tx);
    }
  }
}
```

**Avantaje:**
- ✅ React Native = iOS + Android
- ✅ Rust module = performanță nativă
- ✅ Are deja Dilithium5 (similar ML-DSA-87)
- ✅ Hardware-backed keys (Seeker Secure Enclave)

#### B. Desktop Wallet (bazat pe QRL)

```javascript
// wallet-omnibus-desktop/
// Fork din qrl-wallet, adaptat pentru OmniBus

// Adaptări necesare:
// 1. Înlocuiește XMSS cu ML-DSA/Falcon/SLH-DSA
// 2. Adaugă suport pentru 5 coin types
// 3. Păstrează arhitectura Meteor + Electron

// imports/ui/pages/create/create.js
Template.appCreateOmniBus.onRendered(() => {
  // Generează wallet cu 5 domenii
  const mnemonic = generateMnemonic(256); // 24 cuvinte
  const wallet = {
    mnemonic,
    addresses: {
      omni: generateOmniAddress(mnemonic, 777),
      love: generateOmniAddress(mnemonic, 778),
      food: generateOmniAddress(mnemonic, 779),
      rent: generateOmniAddress(mnemonic, 780),
      vacation: generateOmniAddress(mnemonic, 781)
    }
  };
});
```

**Avantaje:**
- ✅ Matur și testat (QRL rulează de ani)
- ✅ WebAssembly pentru crypto în browser
- ✅ Electron = Windows, Mac, Linux
- ✅ Ledger integration deja funcțional

#### C. SDK Wallet (bazat pe Tether WDK)

```typescript
// omnibus-wdk-sdk/
// Extensie Tether WDK pentru OmniBus

import { Wallet } from '@tether/wdk';
import { OmniBusCrypto } from '@omnibus/crypto-pq';

export class OmniBusWallet extends Wallet {
  private pqCrypto: OmniBusCrypto;
  
  constructor(config: OmniBusConfig) {
    super({
      ...config,
      chainId: 777,
      rpcUrl: config.omnibusRpc || 'https://rpc.omnibus.network'
    });
    this.pqCrypto = new OmniBusCrypto();
  }
  
  // Metodă unică pentru toate cele 5 domenii
  async getAllBalances(): Promise<OmniBusBalances> {
    const addresses = await this.getAllAddresses();
    return {
      omni: await this.getBalance(addresses.omni),
      love: await this.getBalance(addresses.love),
      food: await this.getBalance(addresses.food),
      rent: await this.getBalance(addresses.rent),
      vacation: await this.getBalance(addresses.vacation)
    };
  }
  
  async sendToDomain(
    domain: 'omni' | 'love' | 'food' | 'rent' | 'vacation',
    to: string,
    amount: bigint
  ): Promise<TransactionHash> {
    const coinType = this.getCoinTypeForDomain(domain);
    const algorithm = this.getAlgorithmForDomain(domain);
    
    // Semnează cu algoritmul corespunzător
    const signature = await this.pqCrypto.sign(algorithm, txHash);
    
    return this.broadcastTransaction({...tx, signature});
  }
}
```

**Avantaje:**
- ✅ SDK profesional, production-ready
- ✅ Suport embedded devices
- ✅ Multi-chain nativ
- ✅ Poate crea wallet-uri AI/machine

---

## 🔄 INTEROPERABILITATE: Recunoaștere între Wallet-uri

### 1. Format Adresă Unificat

Toate wallet-urile OmniBus trebuie să recunoască:

```zig
// Format adresă: prefix + base58check(hash160(pubkey))
// Prefixuri oficiale:
const PREFIXES = {
    .omni = "ob_omni_",      // Coin 777
    .love = "ob_k1_",        // Coin 778
    .food = "ob_f5_",        // Coin 779
    .rent = "ob_d5_",        // Coin 780
    .vacation = "ob_s3_"     // Coin 781
};

// Version byte: 0x4F (79) - unic OmniBus
const VERSION_BYTE = 0x4F;
```

### 2. Export/Import Wallet

```json
{
  "omnibus_wallet_version": "1.0.0",
  "format": "bip39-mnemonic",
  "mnemonic": "abandon abandon abandon ... about",
  "derivation_path": "m/44'/777'/0'/0/0",
  "addresses": {
    "omni": {
      "address": "ob_omni_1A2B3C...",
      "coin_type": 777,
      "algorithm": "ML-DSA-87",
      "public_key": "02abc..."
    },
    "love": {
      "address": "ob_k1_4D5E6F...",
      "coin_type": 778,
      "algorithm": "ML-DSA-87",
      "public_key": "02def..."
    },
    // ... toate cele 5
  }
}
```

### 3. Deep Linking Standard

```
// URI Scheme pentru OmniBus
omnibus://pay?to=ob_omni_abc123&amount=1000000000&domain=omni
omnibus://pay?to=ob_f5_def456&amount=500000000&domain=food

// QR Code standard
{
  "type": "omnibus_payment",
  "version": 1,
  "domain": "omni",
  "to": "ob_omni_abc123...",
  "amount": "1000000000",
  "memo": "optional"
}
```

### 4. Protocol Discovery

```zig
// Wallet capability negotiation
const WalletCapabilities = struct {
    version: []const u8,
    supported_domains: []const DomainCapability,
    supported_protocols: []const Protocol,
    
    pub const DomainCapability = struct {
        name: []const u8,      // "omni", "love", etc.
        coin_type: u32,
        algorithm: []const u8, // "ML-DSA-87", "Falcon-512", etc.
        can_sign: bool,
        hardware_backed: bool,
    };
    
    pub const Protocol = enum {
        omnibus_native_rpc,
        evm_json_rpc,
        walletconnect_v2,
        ledger_hid,
        trezor_bridge,
    };
};
```

---

## 📋 ROADMAP IMPLEMENTARE

### Faza 1: SDK Core (2-3 săptămâni)
```
core/wallet/
├── sdk/
│   ├── typescript/     # SDK Tether WDK-style
│   ├── rust/           # Module native (din eStream)
│   └── zig/            # Core logic (vostru)
├── crypto/
│   ├── pq/             # ML-DSA, Falcon, SLH-DSA
│   └── classic/        # secp256k1
└── protocols/
    ├── evm.ts          # EVM adapter
    ├── walletconnect.ts # WC provider
    └── hardware.ts     # Ledger/Trezor bridge
```

### Faza 2: Mobile Wallet (2-3 săptămâni)
```
wallet-omnibus-mobile/
├── Fork eStream App
├── Adaugă suport Falcon + SLH-DSA
├── UI pentru 5 domenii
└── Deep linking
```

### Faza 3: Desktop Wallet (2-3 săptămâni)
```
wallet-omnibus-desktop/
├── Fork QRL Wallet
├── Adaugă suport 5 domenii
├── WebAssembly PQ crypto
└── Ledger integration
```

### Faza 4: MetaMask Snap (1-2 săptămâni)
```
wallet-omnibus-snap/
├── Snap manifest
├── PQ signing (WASM)
└── Multi-domain UI
```

---

## 🎯 RECOMANDARE FINALĂ

### Strategia "3-Wallet Unified"

1. **Mobile** = Fork eStream App (React Native + Rust)
2. **Desktop** = Fork QRL Wallet (Meteor + Electron + WASM)
3. **SDK** = Extend Tether WDK (TypeScript, pentru integratori)

Toate trei folosesc **același core Zig** compilat în:
- Rust (pentru mobile native modules)
- WASM (pentru web/desktop)
- Node-API (pentru SDK)

### Avantaje:
- ✅ **Code reuse maxim** - Core Zig unic
- ✅ **Platform coverage total** - Mobile, Desktop, Web, SDK
- ✅ **Interoperabilitate** - Aceleași adrese, aceleași seed
- ✅ **Open source** - Toate bazele sunt OSS
- ✅ **Timp rapid** - Fork + adaptare, nu de la zero

---

## 📚 Referințe Open Source

| Proiect | Link | Folosit pentru |
|---------|------|----------------|
| QRL Wallet | github.com/theQRL/qrl-wallet | Desktop wallet architecture |
| eStream App | github.com/polyquantum/estream-app | Mobile wallet (React Native) |
| Tether WDK | docs.wdk.tether.io | SDK multi-chain |
| PQC Vault | github.com/SimedruF/PQC_Vault | Desktop PQ reference |
| Trezor FW | github.com/trezor/trezor-firmware | Hardware wallet |
| MetaMask Snaps | github.com/MetaMask/snaps-monorepo | Browser extension |
| OKX Go SDK | github.com/okx/go-wallet-sdk | Go SDK reference |
| WalletConnect | github.com/WalletConnect/walletconnect-monorepo | Mobile connection |

---

*Document actualizat cu soluții open source concrete*
*Arhitectură hibridă pentru suport universal wallet*
