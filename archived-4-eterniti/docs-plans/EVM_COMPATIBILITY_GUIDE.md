# Ghid Compatibilitate EVM pentru OmniBus

## 1. Mapare adresă OmniBus → EVM

OmniBus folosește adrese cu prefix `ob1q...` dar wallet-urile EVM așteaptă format `0x...`.

### Soluție: Conversie duală

```zig
// core/evm_adapter.zig

/// Convertește adresă OmniBus (ob1q...) în adresă EVM (0x...)
pub fn omniToEvmAddress(omni_addr: []const u8) ![20]u8 {
    // Extrage hash160 din adresă (fără prefix)
    const hash160 = try decodeBase58Check(omni_addr);
    // Returnează direct ca adresă EVM (20 bytes)
    return hash160;
}

/// Convertește adresă EVM (0x...) în adresă OmniBus
pub fn evmToOmniAddress(evm_addr: []const u8, prefix: []const u8, allocator: Allocator) ![]u8 {
    var hash160: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hash160, evm_addr[2..]); // skip "0x"
    return try encodeBase58Check(&hash160, prefix, allocator);
}
```

## 2. Adapter RPC EVM → OmniBus

Wallet-urile EVM folosesc metode standard. Trebuie să mapați:

| Metodă EVM | Metodă OmniBus | Implementare |
|------------|----------------|--------------|
| `eth_getBalance` | `getbalance` | Returnează balance în wei (SAT * 10^9) |
| `eth_sendTransaction` | `sendtransaction` | Convertește TX EVM în TX OmniBus |
| `eth_getTransactionCount` | `getnonce` | Returnează nonce |
| `eth_estimateGas` | `estimatefee` | Returnează fee estimat |
| `eth_chainId` | - | Returnează 777 (0x309) |
| `eth_blockNumber` | `getblockcount` | Returnează block height |
| `eth_getBlockByNumber` | `getblock` | Returnează block format EVM |

### Exemplu implementare adapter:

```zig
// core/evm_rpc_adapter.zig

pub const EvmAdapter = struct {
    omni_rpc: *RPCServer,
    
    pub fn dispatchEvm(self: *EvmAdapter, method: []const u8, params: json.Value) !json.Value {
        if (std.mem.eql(u8, method, "eth_getBalance")) {
            const evm_addr = params.array.items[0].string;
            const omni_addr = try evmToOmniAddress(evm_addr, "ob1q", self.allocator);
            const balance_sat = try self.omni_rpc.getBalance(omni_addr);
            // Returnează în format hex EVM (wei)
            return json.Value{ .string = try std.fmt.allocPrint(self.allocator, "0x{x}", .{balance_sat * 1_000_000_000}) };
        }
        // ... alte metode
    }
};
```

## 3. Semnătură tranzacție

Wallet-urile EVM semnează cu secp256k1 (la fel ca OmniBus), deci compatibilitatea este directă.

Format TX EVM → OmniBus:
```
EVM TX: { to, value, gas, gasPrice, nonce, data }
       ↓
OmniBus TX: {
    from_address: "ob1q...",
    to_address: "ob1q...",
    amount: value / 10^9,  // wei → SAT
    fee: gas * gasPrice / 10^9,
    nonce: nonce,
    op_return: data (opțional)
}
```

## 4. Pași implementare

1. **Creează `core/evm_adapter.zig`** - conversie adrese + TX
2. **Extinde `rpc_server.zig`** - adaugă endpoint `/evm` pentru RPC EVM
3. **Implementează metodele EVM standard** - eth_*
4. **Testează cu MetaMask** - adaugă rețea custom
5. **Publică pe Chainlist.org** - pentru descoperire automată

## 5. Wallet-uri suportate imediat

După implementare, OmniBus va funcționa cu:

| Wallet | Suport | Observații |
|--------|--------|------------|
| MetaMask | ✅ Full | Via wallet_addEthereumChain |
| Trust Wallet | ✅ Full | Suportă custom EVM networks |
| Rabby Wallet | ✅ Full | Specializat DeFi |
| Coinbase Wallet | ✅ Full | Via WalletConnect sau direct |
| Rainbow | ✅ Full | Wallet EVM modern |
| Frame | ✅ Full | Desktop wallet |
| Taho | ✅ Full | Fost Tally Ho |
| Zerion | ✅ Full | Mobile wallet |
| RainbowKit | ✅ Full | Pentru dApp integration |

## 6. Post-Quantum în context EVM

Wallet-urile EVM semnează standard cu secp256k1. Pentru PQ:

- **Faza 1**: Semnătură hibridă - wallet-ul semnează cu secp256k1, node-ul adaugă semnătură PQ
- **Faza 2**: MetaMask Snap custom pentru semnătură directă PQ

```javascript
// MetaMask Snap pentru PQ (opțional, Faza 2)
const signature = await ethereum.request({
  method: 'wallet_invokeSnap',
  params: {
    snapId: 'npm:omnibus-pq-snap',
    request: {
      method: 'signWithMlDsa87',
      params: { tx: transactionData }
    }
  }
});
```
