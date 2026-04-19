# Integrare Hardware Wallet (Ledger/Trezor) pentru OmniBus

## Sumar arhitectură OmniBus PQ

| Domeniu | Prefix | Coin Type | Algoritm PQ | Ledger | Trezor |
|---------|--------|-----------|-------------|--------|--------|
| omnibus.omni | ob_omni_ | 777 | ML-DSA-87 | ⚠️ Custom app | ✅ Open source |
| omnibus.love | ob_k1_ | 778 | ML-DSA-87 | ⚠️ Custom app | ✅ Open source |
| omnibus.food | ob_f5_ | 779 | Falcon-512 | ⚠️ Custom app | ✅ Open source |
| omnibus.rent | ob_d5_ | 780 | ML-DSA-87 | ⚠️ Custom app | ✅ Open source |
| omnibus.vacation | ob_s3_ | 781 | SLH-DSA-256s | ⚠️ Custom app | ✅ Open source |

## Opțiunea 3A: Trezor Safe 7 (Recomandat - Open Source)

Trezor Safe 7 este **complet open source** și are deja suport pentru SLH-DSA-128 (SPHINCS+) în bootloader.

### Pași implementare:

```c
// Integrare în firmware-ul Trezor (simplificat)
// vendor/omnibus.c

#include "omnibus.h"
#include "bip32.h"
#include "curves.h"
#include "sha2.h"
#include "sha3.h"

// Derivează cheie OmniBus din seed BIP-39
bool omnibus_derive_key(const uint32_t *path, uint32_t path_len, 
                        uint8_t *private_key, uint8_t *public_key) {
    // Path standard: m/44'/777'/0'/0/0
    HDNode node;
    if (!hdnode_from_seed(seed, seed_len, SECP256K1_NAME, &node)) return false;
    
    for (uint32_t i = 0; i < path_len; i++) {
        if (!hdnode_private_ckd(&node, path[i])) return false;
    }
    
    memcpy(private_key, node.private_key, 32);
    hdnode_fill_public_key(&node);
    memcpy(public_key, node.public_key, 33); // compressed
    return true;
}

// Generează adresă OmniBus: prefix + Base58Check(0x4F || hash160)
bool omnibus_get_address(const char *prefix, char *address, size_t max_len) {
    uint8_t public_key[33];
    uint8_t hash160[20];
    
    // Derivează cheie
    uint32_t path[] = {44 | BIP32_HARDENED, 777 | BIP32_HARDENED, 
                       0 | BIP32_HARDENED, 0, 0};
    if (!omnibus_derive_key(path, 5, NULL, public_key)) return false;
    
    // Calculează hash160
    hasher_Raw(HASHER_SHA2, public_key, 33, hash160); // SHA256
    ripemd160(hash160, 32, hash160); // RIPEMD160
    
    // Base58Check cu version 0x4F
    b58enc_check(address, &max_len, 0x4F, hash160, 20);
    
    // Adaugă prefix
    char prefixed[128];
    snprintf(prefixed, sizeof(prefixed), "%s%s", prefix, address);
    strncpy(address, prefixed, max_len);
    return true;
}

// Semnează tranzacție OmniBus cu secp256k1
bool omnibus_sign_tx(const uint8_t *tx_hash, const uint32_t *path, uint32_t path_len,
                     uint8_t *signature, size_t *sig_len) {
    uint8_t private_key[32];
    if (!omnibus_derive_key(path, path_len, private_key, NULL)) return false;
    
    // ECDSA sign cu secp256k1
    ecdsa_sign_digest(&secp256k1, private_key, tx_hash, signature, sig_len, NULL);
    return true;
}
```

### Aplicație Trezor pentru OmniBus:

```python
# Aplicație Python pentru Trezor (model după QRL)
# trezor-omnibus/app.py

from trezorlib import client, btc
from trezorlib.transport import get_transport
from trezorlib.tools import parse_path

def get_omnibus_address(coin_type=777, prefix="ob1q"):
    """Generează adresă OmniBus pe Trezor"""
    transport = get_transport()
    c = client.TrezorClient(transport)
    
    # Path BIP-44: m/44'/777'/0'/0/0
    path = parse_path("44'/777'/0'/0/0")
    
    # Adresa
    address = btc.get_address(
        c, 
        coin_name="OmniBus",
        n=path,
        script_type=0,  // P2PKH
        show_display=True
    )
    
    return f"{prefix}{address}"

def sign_omnibus_transaction(tx_hash: bytes, coin_type=777):
    """Semnează tranzacție pe Trezor"""
    transport = get_transport()
    c = client.TrezorClient(transport)
    
    path = parse_path(f"44'/{coin_type}'/0'/0/0")
    
    signature = btc.sign_tx(
        c,
        coin_name="OmniBus",
        inputs=[...],
        outputs=[...],
        prev_txes={}
    )
    
    return signature
```

## Opțiunea 3B: Ledger (Necesită aplicație custom)

Ledger necesită dezvoltarea unei aplicații C sau Rust pentru dispozitiv.

### Structură aplicație Ledger:

```c
// src/omnibus_app.c

#include "os.h"
#include "cx.h"
#include "ux.h"

// Coin types OmniBus
#define COIN_OMNI 777
#define COIN_LOVE 778
#define COIN_FOOD 779
#define COIN_RENT 780
#define COIN_VACATION 781

// Derivează cheie pentru coin type specific
void derive_omnibus_keypair(uint32_t coin_type, cx_ecfp_public_key_t *pubkey, cx_ecfp_private_key_t *privkey) {
    uint32_t path[5] = {
        0x8000002C, // 44' hardened
        0x80000000 + coin_type, // coin_type' hardened
        0x80000000, // 0' hardened
        0,          // 0
        0           // 0
    };
    
    uint8_t raw_privkey[32];
    os_perso_derive_node_bip32(CX_CURVE_SECP256K1, path, 5, raw_privkey, NULL);
    
    cx_ecfp_init_private_key(CX_CURVE_SECP256K1, raw_privkey, 32, privkey);
    cx_ecfp_generate_pair(CX_CURVE_SECP256K1, pubkey, privkey, 1);
}

// Generează adresă OmniBus
void get_omnibus_address(uint32_t coin_type, const char *prefix, char *output) {
    cx_ecfp_public_key_t pubkey;
    cx_ecfp_private_key_t privkey;
    
    derive_omnibus_keypair(coin_type, &pubkey, &privkey);
    
    // Hash160
    uint8_t sha256[32];
    uint8_t hash160[20];
    cx_hash_sha256(pubkey.W, 33, sha256, 32);
    ripemd160(sha256, 32, hash160);
    
    // Base58Check cu version 0x4F
    base58_encode_check(hash160, 20, 0x4F, output);
    
    // Adaugă prefix
    char temp[128];
    snprintf(temp, sizeof(temp), "%s%s", prefix, output);
    strcpy(output, temp);
}
```

### Costuri Ledger:

| Componentă | Cost | Durată |
|------------|------|--------|
| Audit securitate | €15,000 - €50,000 | 2-3 luni |
| Developer license | Gratuit | - |
| Listing Ledger Live | Negociere | 3-6 luni |

## Opțiunea 3C: MetaMask Snap Post-Quantum (Revoluționar)

Cea mai modernă abordare pentru PQ - fără hardware modificat.

```typescript
// snaps/omnibus-pq-snap/src/index.ts

import { OnRpcRequestHandler } from '@metamask/snaps-types';
import { SLIP10Node } from '@metamask/key-tree';
import { derivePath, getPublicKey } from 'ed25519-hd-key';

// liboqs WASM bindings
import * as oqs from './liboqs-wasm';

export const onRpcRequest: OnRpcRequestHandler = async ({ origin, request }) => {
  switch (request.method) {
    case 'getOmniBusAddress':
      return await getOmniBusAddress(request.params.coinType);
      
    case 'signWithMlDsa87':
      return await signWithMlDsa87(request.params.message);
      
    case 'signWithFalcon512':
      return await signWithFalcon512(request.params.message);
      
    case 'signWithSlhDsa256s':
      return await signWithSlhDsa256s(request.params.message);
      
    default:
      throw new Error('Method not found');
  }
};

async function getOmniBusAddress(coinType: number): Promise<string> {
  // Derivează din seed MetaMask
  const node = await snap.request({
    method: 'snap_getBip32Entropy',
    params: {
      path: ['m', "44'", `${coinType}'`, "0'", '0', '0'],
      curve: 'secp256k1',
    },
  });
  
  // Calculează adresă OmniBus
  const publicKey = node.publicKey;
  const hash160 = await sha256ripemd160(publicKey);
  const base58 = base58CheckEncode(hash160, 0x4F);
  
  const prefix = getPrefixForCoinType(coinType);
  return `${prefix}${base58}`;
}

async function signWithMlDsa87(message: string): Promise<string> {
  // Inițializează liboqs
  await oqs.init();
  
  // Generează keypair PQ din entropie derivată
  const entropy = await snap.request({
    method: 'snap_getEntropy',
    params: { version: 1 },
  });
  
  // ML-DSA-87 sign
  const signature = await oqs.mldsa87_sign(
    Buffer.from(message, 'utf8'),
    entropy
  );
  
  return signature.toString('hex');
}
```

## Recomandare pentru OmniBus

| Prioritate | Integrare | Efort | Impact |
|------------|-----------|-------|--------|
| 1 | EVM Adapter | Mediu | Maxim - toate wallet-urile EVM |
| 2 | WalletConnect | Mediu | Maxim - mobile wallets |
| 3 | Trezor (open source) | Mare | Mediu - utilizatori avansați |
| 4 | MetaMask Snap PQ | Mare | Mediu - early adopters PQ |
| 5 | Ledger custom | Foarte mare | Mic - cost ridicat |

## Resurse Open Source Relevante

1. **Trezor Firmware**: github.com/trezor/trezor-firmware
2. **QRL Ledger App**: github.com/theQRL/ledger-qrl
3. **MetaMask Snaps**: docs.metamask.io/snaps
4. **WalletConnect**: github.com/WalletConnect
