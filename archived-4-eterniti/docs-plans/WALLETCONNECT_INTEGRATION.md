# Integrare WalletConnect v2 pentru OmniBus

## Ce este WalletConnect?

Protocol standard pentru conectare wallet-dApp, folosit de 65.000+ aplicații. Suportă:
- QR code scanning
- Deep linking
- Chain-agnostic (funcționează cu orice blockchain)

## Implementare OmniBus

### 1. Provider WalletConnect

```zig
// core/walletconnect_provider.zig

const std = @import("std");
const ws = @import("ws_server.zig");
const rpc = @import("rpc_server.zig");

/// WalletConnect v2 Provider pentru OmniBus
pub const WalletConnectProvider = struct {
    allocator: std.mem.Allocator,
    rpc_server: *rpc.RPCServer,
    ws_server: *ws.WSServer,
    
    const SUPPORTED_CHAINS = [_]struct { 
        chainId: []const u8,  // eip155:777
        name: []const u8,
        rpcUrl: []const u8,
    }{
        .{ .chainId = "eip155:777", .name = "OmniBus Mainnet", .rpcUrl = "https://rpc.omnibus.network" },
        .{ .chainId = "eip155:778", .name = "OmniBus Testnet", .rpcUrl = "https://testnet.omnibus.network" },
    };
    
    /// Inițializează sesiune WalletConnect
    pub fn createSession(self: *WalletConnectProvider) !SessionProposal {
        const uri = try std.fmt.allocPrint(self.allocator, 
            "wc:????@2?relay-protocol=irn&symKey=????", .{});
        
        return SessionProposal{
            .uri = uri,
            .qr_code = try generateQR(uri),
            .chains = &SUPPORTED_CHAINS,
        };
    }
    
    /// Handler pentru cereri de la wallet
    pub fn handleRequest(self: *WalletConnectProvider, request: WCRequest) !WCResponse {
        switch (request.method) {
            .eth_sendTransaction => |tx| {
                // Convertește TX EVM în TX OmniBus
                const omni_tx = try self.evmToOmniTx(tx);
                const result = try self.rpc_server.sendTransaction(omni_tx);
                return WCResponse{ .tx_hash = result.txid };
            },
            .eth_sign => |params| {
                // Semnează mesaj cu cheia wallet-ului
                return try self.signMessage(params);
            },
            .personal_sign => |params| {
                return try self.personalSign(params);
            },
            .eth_getBalance => |address| {
                const balance = try self.rpc_server.getBalance(address);
                return WCResponse{ .balance = balance };
            },
        }
    }
};

/// Structuri WC
pub const WCRequest = union(enum) {
    eth_sendTransaction: EvmTransaction,
    eth_sign: SignParams,
    personal_sign: PersonalSignParams,
    eth_getBalance: []const u8,
};

pub const EvmTransaction = struct {
    from: []const u8,      // 0x...
    to: []const u8,        // 0x...
    value: []const u8,     // hex wei
    data: ?[]const u8,     // hex data (op_return)
    gas: ?[]const u8,      // hex
    gasPrice: ?[]const u8, // hex
    nonce: []const u8,     // hex
};
```

### 2. Wallet-uri suportate prin WalletConnect

| Wallet | Platformă | Suport PQ | Observații |
|--------|-----------|-----------|------------|
| Trust Wallet | iOS/Android | ✅ Indirect | Cel mai popular mobile wallet |
| Rainbow | iOS/Android | ✅ Indirect | Design excelent |
| MetaMask Mobile | iOS/Android | ✅ Indirect | Standardul industry |
| Zerion | iOS/Android | ✅ Indirect | DeFi focus |
| Argent | iOS/Android | ✅ Indirect | Smart wallet |
| Gnosis Safe | Web/Mobile | ✅ Indirect | Multi-sig |
| Coinbase Wallet | iOS/Android | ✅ Indirect | Exchange integrat |
| imToken | iOS/Android | ✅ Indirect | Popular în Asia |
| TokenPocket | iOS/Android | ✅ Indirect | Multi-chain |
| Math Wallet | iOS/Android | ✅ Indirect | Multi-chain |

### 3. Configurare OmniBus în WalletConnect Cloud

```json
{
  "name": "OmniBus Network",
  "chains": ["eip155:777", "eip155:778", "eip155:779", "eip155:780", "eip155:781"],
  "rpc": {
    "777": "https://rpc.omnibus.network",
    "778": "https://rpc.omnibus.network",
    "779": "https://rpc.omnibus.network",
    "780": "https://rpc.omnibus.network",
    "781": "https://rpc.omnibus.network"
  },
  "nativeCurrency": {
    "name": "OmniBus",
    "symbol": "OMNI",
    "decimals": 9
  },
  "features": ["send", "receive", "swap"],
  "postQuantum": {
    "enabled": true,
    "algorithms": ["ML-DSA-87", "Falcon-512", "SLH-DSA-256s"]
  }
}
```

### 4. Flow utilizator

1. Utilizatorul deschide dApp OmniBus
2. Apasă "Connect Wallet"
3. Se generează QR code / deep link
4. Utilizatorul scanează cu Trust Wallet / MetaMask Mobile
5. Wallet-ul arată cererea de conectare
6. Utilizatorul confirmă
7. dApp poate trimite tranzacții spre semnare

```javascript
// Exemplu integrare în frontend dApp
import { EthereumProvider } from '@walletconnect/ethereum-provider';

const provider = await EthereumProvider.init({
  projectId: 'OMNIBUS_PROJECT_ID',
  chains: [777, 778, 779, 780, 781], // OmniBus chains
  showQrModal: true,
  methods: ['eth_sendTransaction', 'eth_sign', 'personal_sign'],
  events: ['chainChanged', 'accountsChanged'],
});

await provider.enable();

// Trimite tranzacție
const tx = await provider.request({
  method: 'eth_sendTransaction',
  params: [{
    from: provider.accounts[0],
    to: '0x...', // adresă destinatar
    value: '0x...', // în wei
    data: '0x...' // op_return opțional
  }]
});
```

## Avantaje WalletConnect

- ✅ Funcționează cu toate wallet-urile mobile populare
- ✅ Nu necesită modificări în wallet-uri existente
- ✅ Securitate prin encriptare end-to-end
- ✅ QR code + deep linking
- ✅ Standard industry (65.000+ dApps)
