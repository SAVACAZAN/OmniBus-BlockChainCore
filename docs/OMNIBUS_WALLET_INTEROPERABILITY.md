# Interoperabilitate Wallet-uri OmniBus
## Cum se recunosc toate wallet-urile între ele

---

## 🎯 Principiul de Bază

**Toate wallet-urile OmniBus trebuie să:**
1. Recunoască cele 5 formate de adresă (ob_omni_, ob_k1_, ob_f5_, ob_d5_, ob_s3_)
2. Folosească același BIP-39 seed pentru a deriva toate adresele
3. Suporte același BIP-32 derivation path (m/44'/777'/0'/0/0 etc.)
4. Comunice prin același protocol RPC (JSON-RPC 2.0)
5. Export/Import în format standardizat

---

## 🏷️ Sistem de Recunoaștere Automată

### 1. Address Validation Standard

```zig
// Validează orice adresă OmniBus (indiferent de wallet)
pub fn isValidOmniBusAddress(address: []const u8) bool {
    // Lista prefixurilor oficiale
    const PREFIXES = [_][]const u8{
        "ob_omni_",    // Coin 777 - ML-DSA-87
        "ob_k1_",      // Coin 778 - ML-DSA-87
        "ob_f5_",      // Coin 779 - Falcon-512
        "ob_d5_",      // Coin 780 - ML-DSA-87
        "ob_s3_",      // Coin 781 - SLH-DSA-256s
        "ob1q",        // SegWit
        "0x",          // EVM format
    };
    
    // Verifică prefix
    var has_valid_prefix = false;
    for (PREFIXES) |prefix| {
        if (std.mem.startsWith(u8, address, prefix)) {
            has_valid_prefix = true;
            break;
        }
    }
    
    if (!has_valid_prefix) return false;
    
    // Verifică Base58Check valid
    return validateBase58Check(address);
}

// Detectează domeniul din adresă
pub fn detectDomain(address: []const u8) ?OmniBusDomain {
    if (std.mem.startsWith(u8, address, "ob_omni_")) return .omni;
    if (std.mem.startsWith(u8, address, "ob_k1_")) return .love;
    if (std.mem.startsWith(u8, address, "ob_f5_")) return .food;
    if (std.mem.startsWith(u8, address, "ob_d5_")) return .rent;
    if (std.mem.startsWith(u8, address, "ob_s3_")) return .vacation;
    return null;
}
```

### 2. Wallet Capability Negotiation

```typescript
// Fiecare wallet anunță ce poate face
interface WalletCapabilities {
  version: "1.0.0";
  wallet_type: "mobile" | "desktop" | "web" | "sdk" | "hardware";
  
  // Ce domenii suportă
  supported_domains: {
    omni: { coin_type: 777; algorithm: "ML-DSA-87"; can_sign: boolean };
    love: { coin_type: 778; algorithm: "ML-DSA-87"; can_sign: boolean };
    food: { coin_type: 779; algorithm: "Falcon-512"; can_sign: boolean };
    rent: { coin_type: 780; algorithm: "ML-DSA-87"; can_sign: boolean };
    vacation: { coin_type: 781; algorithm: "SLH-DSA-256s"; can_sign: boolean };
  };
  
  // Ce protocoale vorbește
  protocols: ("evm_rpc" | "walletconnect_v2" | "omnibus_native" | "ledger" | "trezor")[];
  
  // Capabilități hardware
  hardware_backed: boolean;
  secure_enclave: boolean;
}

// Exemplu: Mobile wallet (eStream-based)
const mobileWalletCaps: WalletCapabilities = {
  version: "1.0.0",
  wallet_type: "mobile",
  supported_domains: {
    omni: { coin_type: 777, algorithm: "ML-DSA-87", can_sign: true },
    love: { coin_type: 778, algorithm: "ML-DSA-87", can_sign: true },
    food: { coin_type: 779, algorithm: "Falcon-512", can_sign: true },
    rent: { coin_type: 780, algorithm: "ML-DSA-87", can_sign: true },
    vacation: { coin_type: 781, algorithm: "SLH-DSA-256s", can_sign: true }
  },
  protocols: ["walletconnect_v2", "omnibus_native"],
  hardware_backed: true,
  secure_enclave: true  // Seeker Secure Enclave
};

// Exemplu: MetaMask Snap
const snapWalletCaps: WalletCapabilities = {
  version: "1.0.0", 
  wallet_type: "sdk",
  supported_domains: {
    omni: { coin_type: 777, algorithm: "ML-DSA-87", can_sign: true },
    // ... toate celelalte
  },
  protocols: ["evm_rpc"],  // Prin MetaMask
  hardware_backed: false,
  secure_enclave: false
};
```

---

## 🔄 Import/Export Universal

### Format Standard de Export

```json
{
  "$schema": "https://omnibus.network/schemas/wallet-export-v1.json",
  "format": "omnibus-wallet-backup-v1",
  "created_at": "2025-03-30T12:00:00Z",
  "wallet_type": "omnibus_universal",
  
  "mnemonic": {
    "type": "bip39",
    "words": "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
    "word_count": 12,
    "language": "english",
    "passphrase_protected": false
  },
  
  "derivation": {
    "standard": "bip44",
    "purpose": 44,
    "master_seed": "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553f7a97469b2e58f2c69ee557e6f76e5e0de0e22259b6d8d90b0a6c1f9c5b88f40"
  },
  
  "addresses": [
    {
      "domain": "omni",
      "name": "OmniBus Native",
      "coin_type": 777,
      "algorithm": "ML-DSA-87",
      "prefix": "ob_omni_",
      "address": "ob_omni_a1b2c3d4e5f6...",
      "derivation_path": "m/44'/777'/0'/0/0",
      "public_key": "02a1b2c3d4e5f6...",
      "pq_public_key": "2592_bytes_hex_here..."
    },
    {
      "domain": "love",
      "name": "OmniBus Love",
      "coin_type": 778,
      "algorithm": "ML-DSA-87",
      "prefix": "ob_k1_",
      "address": "ob_k1_g7h8i9j0k1...",
      "derivation_path": "m/44'/778'/0'/0/0",
      "public_key": "03g7h8i9j0k1...",
      "pq_public_key": "2592_bytes_hex_here..."
    },
    {
      "domain": "food",
      "name": "OmniBus Food", 
      "coin_type": 779,
      "algorithm": "Falcon-512",
      "prefix": "ob_f5_",
      "address": "ob_f5_l2m3n4o5p6...",
      "derivation_path": "m/44'/779'/0'/0/0",
      "public_key": "02l2m3n4o5p6...",
      "pq_public_key": "897_bytes_hex_here..."
    },
    {
      "domain": "rent",
      "name": "OmniBus Rent",
      "coin_type": 780,
      "algorithm": "ML-DSA-87",
      "prefix": "ob_d5_",
      "address": "ob_d5_q7r8s9t0u1...",
      "derivation_path": "m/44'/780'/0'/0/0",
      "public_key": "03q7r8s9t0u1...",
      "pq_public_key": "2592_bytes_hex_here..."
    },
    {
      "domain": "vacation",
      "name": "OmniBus Vacation",
      "coin_type": 781,
      "algorithm": "SLH-DSA-256s",
      "prefix": "ob_s3_",
      "address": "ob_s3_v2w3x4y5z6...",
      "derivation_path": "m/44'/781'/0'/0/0",
      "public_key": "02v2w3x4y5z6...",
      "pq_public_key": "64_bytes_hex_here..."
    }
  ],
  
  "settings": {
    "default_domain": "omni",
    "default_fee": 1000,
    "auto_lock_timeout": 300
  }
}
```

### Flow de Import în orice wallet

```typescript
// În orice wallet OmniBus (mobile, desktop, web)
async function importOmniBusWallet(backupJson: string): Promise<Wallet> {
  const backup = JSON.parse(backupJson);
  
  // Validează schema
  if (!validateSchema(backup)) {
    throw new Error("Invalid wallet backup format");
  }
  
  // Generează toate adresele din mnemonic pentru a verifica
  const generated = await generateAllAddresses(backup.mnemonic.words);
  
  // Verifică că adresele coincid (opțional, pentru integritate)
  for (const addr of backup.addresses) {
    const generated_addr = generated[addr.domain];
    if (generated_addr.address !== addr.address) {
      throw new Error(`Address mismatch for domain ${addr.domain}`);
    }
  }
  
  // Import reușit - toate wallet-urile au aceleași date
  return new OmniBusWallet({
    mnemonic: backup.mnemonic.words,
    addresses: generated,
    settings: backup.settings
  });
}
```

---

## 🔗 Deep Linking & QR Standard

### URI Scheme: `omnibus://`

```
// Plată simplă
omnibus://pay?to=ob_omni_abc123&amount=1000000000

// Plată cu domeniu specific
omnibus://pay?to=ob_f5_def456&amount=500000000&domain=food

// Plată cu memo
omnibus://pay?to=ob_omni_abc123&amount=1000000000&memo=Plata%20factura%20123

// Conectare dApp
omnibus://connect?uri=wc:abc123@2?relay-protocol=irn&symKey=xyz789

// Deschidere adresă specifică în wallet
omnibus://wallet?address=ob_omni_abc123&action=receive
```

### QR Code Standard

```typescript
// Format QR pentru OmniBus
interface OmniBusQRCode {
  type: "omnibus_payment" | "omnibus_connect" | "omnibus_wallet";
  version: 1;
  
  // Pentru payments
  to?: string;           // Adresa destinatar
  amount?: string;       // Cantitate în SAT (string pentru bigint)
  domain?: string;       // Domeniu opțional
  memo?: string;         // Memo opțional
  
  // Pentru wallet connect
  uri?: string;          // WalletConnect URI
  
  // Pentru wallet info
  address?: string;      // Adresa proprie
  action?: "receive" | "send" | "swap";
}

// Exemplu QR pentru plată
const paymentQR: OmniBusQRCode = {
  type: "omnibus_payment",
  version: 1,
  to: "ob_omni_abc123...",
  amount: "1000000000",  // 1 OMNI
  domain: "omni",
  memo: "Plata servicii"
};

// Generare QR
const qrString = JSON.stringify(paymentQR);
// → Afișează în orice wallet pentru scanare
```

---

## 🔐 Protocol de Handshake între Wallet-uri

### Caz: Mobile Wallet → Desktop Wallet (sync)

```
1. Desktop generează QR cu pairing request
   
   {
     "type": "omnibus_pairing",
     "version": 1,
     "device_id": "desktop_abc123",
     "public_key": "02abc...",
     "timestamp": 1700000000,
     "expires": 1700000300
   }

2. Mobile scanează QR și acceptă

3. Mobile trimite encrypted response cu propriul public key

4. Ambele device-uri derivă shared secret (ECDH)

5. Comunicare criptată end-to-end pentru sync wallet
```

### Implementare Zig

```zig
// Pairing protocol între wallet-uri OmniBus
pub const WalletPairing = struct {
    const KeyPair = struct {
        public_key: [33]u8,
        private_key: [32]u8,
    };
    
    /// Generează pairing request
    pub fn generateRequest(allocator: Allocator) !PairingRequest {
        const kp = try generateEphemeralKeyPair();
        
        return PairingRequest{
            .device_id = try generateDeviceId(allocator),
            .public_key = kp.public_key,
            .timestamp = std.time.timestamp(),
            .expires = std.time.timestamp() + 300, // 5 min
        };
    }
    
    /// Acceptă pairing request
    pub fn acceptRequest(
        request: PairingRequest,
        wallet_mnemonic: []const u8
    ) !PairingSession {
        // Generează ephemeral keypair
        const local_kp = try generateEphemeralKeyPair();
        
        // Derivează shared secret
        const shared_secret = try ecdhSharedSecret(
            local_kp.private_key,
            request.public_key
        );
        
        // Confirmă wallet ownership (semnează challenge)
        const challenge_sig = try signChallenge(
            wallet_mnemonic,
            request.device_id,
            shared_secret
        );
        
        return PairingSession{
            .device_id = request.device_id,
            .local_public_key = local_kp.public_key,
            .shared_secret = shared_secret,
            .challenge_signature = challenge_sig,
        };
    }
};
```

---

## 📱📲📱 Matrice de Compatibilitate

### Recunoaștere între Wallet-uri

| Wallet A | Wallet B | Compatibilitate | Metodă |
|----------|----------|-----------------|--------|
| Mobile (eStream) | Desktop (QRL) | ✅ 100% | Import JSON + Sync |
| Mobile (eStream) | Web (WASM) | ✅ 100% | Import JSON + WC |
| Desktop (QRL) | MetaMask Snap | ✅ 100% | EVM + Seed import |
| SDK (Tether WDK) | Mobile (eStream) | ✅ 100% | API + Import JSON |
| Hardware (Trezor) | Mobile (eStream) | ✅ 100% | Trezor Bridge |
| Hardware (Ledger) | Desktop (QRL) | ✅ 100% | Ledger Live |
| MetaMask Snap | Desktop (QRL) | ✅ 100% | Seed import |
| SDK (WDK) | Hardware (Trezor) | ✅ 100% | USB/BLE bridge |

### Sincronizare automată

```typescript
// Când adaugi un wallet nou, detectează celelalte
class OmniBusWalletSync {
  async discoverWallets(): Promise<DiscoveredWallet[]> {
    const discovered = [];
    
    // 1. Scan QR (desktop)
    const desktopQR = await this.scanForDesktopWallets();
    if (desktopQR) discovered.push(desktopQR);
    
    // 2. Check local storage (browser extension)
    const browserWallet = await this.checkBrowserExtension();
    if (browserWallet) discovered.push(browserWallet);
    
    // 3. Check hardware (Ledger/Trezor connected)
    const hardware = await this.detectHardwareWallets();
    discovered.push(...hardware);
    
    // 4. Check mobile (WalletConnect)
    const mobile = await this.connectMobileWallet();
    if (mobile) discovered.push(mobile);
    
    return discovered;
  }
  
  async syncWallets(wallets: DiscoveredWallet[]): Promise<void> {
    // Aduce toate wallet-urile la aceeași stare
    const masterState = await this.getMasterState();
    
    for (const wallet of wallets) {
      await wallet.sync(masterState);
    }
  }
}
```

---

## 🎁 Beneficii pentru Utilizatori

1. **Un singur seed** = Toate wallet-urile
   - Configurezi odată, folosești peste tot
   - Backup unic pentru toate platformele

2. **Interoperabilitate totală**
   - Poți crea TX pe mobile și semna pe hardware
   - Poți vedea balanța pe desktop și trimite de pe web

3. **Alegere liberă**
   - Preferi mobile? → Folosești eStream fork
   - Preferi desktop? → Folosești QRL fork
   - Preferi SDK? → Folosești Tether WDK
   - Toate vorbesc aceeași limbă

4. **Securitate maximă**
   - Cheile PQ pot fi în hardware (Trezor/Ledger)
   - Cheile clasice pe orice platformă
   - Seed-ul niciodată expus

---

## 📋 Checklist Implementare

### Pentru fiecare wallet nou:

- [ ] Suportă toate 5 prefixurile de adresă
- [ ] Validează Base58Check cu version 0x4F
- [ ] Folosește BIP-39 pentru seed
- [ ] Folosește BIP-32 cu path m/44'/777'/0'/0/0 (etc.)
- [ ] Exportă în format JSON standard
- [ ] Importă din format JSON standard
- [ ] Suportă URI scheme `omnibus://`
- [ ] Generează/citește QR code standard
- [ ] Implementează Wallet Capabilities
- [ ] Documentează protocoale suportate

---

*Document pentru interoperability între toate wallet-urile OmniBus*
*Standard pentru recunoaștere automată*
