# BlockChainCore EVM Module — Design Doc

**Status**: design committed 2026-06-01. Implementation: module EVM există DEJA în `evm/` ca Rust staticlib cu revm + C ABI FFI; rămâne să adăugăm persistență + wire-up în Zig RPC.
**Owner**: Alex Cazan
**Decision context**: Liberty (LCX testnet) ștergea repetat contractele orderbook. OmniRollup ca OP Stack L2 a fost respins în favoarea **un singur chain, două VM-uri**. Acest document descrie cum BlockChainCore Zig L1 absoarbe EVM execution.

## Implementation status (2026-06-01)

- ✅ `evm/` Rust staticlib EXISTĂ — `omnibus-evm` cu `revm 14` + C ABI: `omnibus_evm_init/deploy/call/get_balance/get_code/estimate_gas`. Linked în Zig binary, NU proces separat.
- ❌ State `InMemoryDB` (volatile) — needs persistence adapter
- ❌ Zig RPC `eth_*` routes — needs wiring în `core/rpc_server.zig` să cheme FFI-ul
- ❌ Sidecar approach abandonat — pe scurt am construit `evm_sidecar/` separat din necunoștință că `evm/` există. Șters 2026-06-01.

---

## Principle

**One chain, one OMNI, two VMs.**

| VM | Purpose | Tx format | Sig scheme |
|---|---|---|---|
| Native (Zig) | ENS .omnibus, soulbound LOVE/FOOD/RENT/VACATION, OMNI mining, PQ attestations, identity merkle proofs | OmniBus native (HKDF + multi-PQ) | ECDSA + ML-DSA + Falcon + SLH-DSA + ML-KEM (the `pq_attest` 7-sig binding) |
| EVM (revm sidecar) | Smart contracts Solidity (orderbook, escrow, AMM), DeFi, cross-chain settler, partener external EVM tools (MetaMask, Foundry, Hardhat) | EIP-1559 / EIP-712 standard Ethereum | secp256k1 ECDSA |

OMNI coin e **același**. State-ul de balance e un singur leger; vizibil prin ambele JSON-RPC-uri (`getbalance` nativ + `eth_getBalance` EVM).

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      BlockChainCore Node                         │
│                                                                  │
│  ┌──────────────────┐                  ┌────────────────────┐   │
│  │ Native JSON-RPC  │                  │  EVM JSON-RPC      │   │
│  │   port 8332      │                  │   port 8333        │   │
│  │   (Zig server)   │                  │   (Rust sidecar)   │   │
│  └────────┬─────────┘                  └─────────┬──────────┘   │
│           │                                       │              │
│           │  IPC / shared storage                 │              │
│           ▼                                       ▼              │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Unified State Database (LMDB / RocksDB)      │   │
│  │                                                            │   │
│  │  ┌──────────────────┐    ┌──────────────────────────┐    │   │
│  │  │ Native accounts  │    │ EVM accounts             │    │   │
│  │  │  (addr → balance │    │  (addr → balance, code,  │    │   │
│  │  │   + nonce + PQ)  │    │   storage[key→val],      │    │   │
│  │  │                  │    │   nonce)                 │    │   │
│  │  └────────┬─────────┘    └────────┬─────────────────┘    │   │
│  │           │                        │                       │   │
│  │           └────────┬───────────────┘                       │   │
│  │                    ▼                                        │   │
│  │         OMNI ledger (unified)                              │   │
│  │         — balances visibile prin ambele VMs                │   │
│  │         — derivare cross-VM via address mapping            │   │
│  └──────────────────────────────────────────────────────────┘   │
│                              │                                   │
│                              ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                Block production (consensus)               │   │
│  │   - Tx pool include atât native cât și EVM tx-uri        │   │
│  │   - Block contains: native_txs[] + evm_txs[]             │   │
│  │   - Producer execută secvențial: native first, EVM second│   │
│  │   - State root combinat = hash(native_root || evm_root)  │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Address mapping (cross-VM)

Userul are **un singur seed (mnemonic)**. Derivă două adrese:
- **Native**: existing BIP-44 path 777'/0'/0'/0/idx → 33-byte compressed pubkey → 20-byte hash → `omni1...` bech32
- **EVM**: BIP-44 path 60'/0'/0'/0/idx → 33-byte compressed pubkey → 20-byte keccak (last 20 of keccak256(uncompressed)) → `0x...` checksum

Ele sunt **două adrese diferite** pentru același user. Pentru a transfera OMNI între ele, există două abordări:

1. **Mapping în chain**: tabel `evm_addr → native_addr` (sau invers) populat de user la primul use. Tx pe ambele VMs văd balance comun din contul "owner". Simplu, dar necesită registration.

2. **No mapping, dual wallets**: utilizatorul are 2 balances separate, le mută prin tx normale. UI-ul afișează ambele și suma. Mai puțin elegant, dar nu cere registration upfront.

**Decizie inițială**: opțiunea 2 (no mapping). Wallet UI-ul afișează combined balance. Userul transferă între ele prin `omni_to_evm` tx (special tx type ce decrementează native balance + incrementează EVM balance la aceeași user). Identitate post-quantum pe partea nativă; trading pe EVM.

---

## Implementation phases

### Phase 0 — Stopgap (1 zi)
Deploy `OmniOrderbookCoreV2` pe **Base Sepolia** ca primary orderbook temporar până se construiește EVM module. Update `settler.json` să arate la Base. Re-listează 38 pairs (14 native + 24 stable/LINK). Continuitate operațională.

### Phase 1 — revm sidecar (1-2 săptămâni)
- Cargo crate nou: `core/evm_sidecar/` în Rust.
- Dependencies: `revm = "14"`, `axum`, `tokio`, `serde_json`.
- Implementare:
  - JSON-RPC server pe port 8333 (`eth_chainId`, `eth_getBalance`, `eth_call`, `eth_sendRawTransaction`, `eth_getTransactionReceipt`, `eth_blockNumber`, `eth_getLogs`).
  - In-memory state DB inițial (pentru testing). Persistență vine în Phase 2.
  - Tx pool simplu — accept signed tx, validate ECDSA, queue.
- Test: deploy un contract simplu via Hardhat la `http://127.0.0.1:8333`.

### Phase 2 — State persistence (1 săptămână)
- EVM state persisted alongside native state.
- Snapshot per block (post-block-execution).
- Genesis: pre-allocate 0 EVM accounts; users create via first tx (sending tx funds the EVM address).

### Phase 3 — Block production unified (1 săptămână)
- Tx pool dual: accept both formats.
- Block format extended: `block.native_txs[]` + `block.evm_txs[]`.
- Block hash = hash(prev_hash || timestamp || native_root || evm_root || extra).
- Block producer (miner/validator) executes both classes, computes both roots.

### Phase 4 — OMNI cross-VM transfer (3 zile)
- Special tx type `OmniBridgeIntra` (în-chain, NOT cross-chain):
  - From native side: `bridge_native_to_evm(amount, evm_addr)` — burns native balance, mints EVM balance at evm_addr.
  - From EVM side: `OmniBridge.evmToNative(bytes20 nativeAddr)` payable contract — burns EVM balance, mints native at nativeAddr.
- Atomic, intra-block. No external relayer.

### Phase 5 — Migrate DeFi (1-2 săptămâni)
- Deploy `OmniOrderbookCoreV2` + `OmniOrderbookEscrowV3` pe BlockChainCore EVM side (chainId TBD, propunere 7771).
- List all pairs (38 from current Liberty work).
- Update `settler.json`: core_rpc = `http://your-node:8333`.
- Update frontend: replace Liberty RPC with BlockChainCore EVM.
- Cutover: announce, freeze Liberty deposits, run final settlement.

### Phase 6 — External tools (ongoing)
- Block explorer support (`eth_*` works → Blockscout/Etherscan-style)
- MetaMask: add custom network (chainId + RPC URL + symbol OMNI)
- Hardhat/Foundry: standard JSON-RPC → "just works"

---

## chainId allocation

Propunere: **chainId = 7771** (avantaj: 7 = OMNI BIP-44 prefix 777, 71 = "OmniBus" inițiale-like).

Alternative:
- `8332` (clash cu port — confuz)
- `77777` (5 cifre, lung)
- `1001` (clash cu Kaia)

**Decizie inițială**: chainId = **7771**, document-uit oficial în genesis.

---

## Tradeoffs admise

1. **revm e Rust**, nu Zig. Sidecar separat = un alt limbaj de menținut. Acceptat pentru viteza de a livra; portare Zig nativă vine în 6-12 luni dacă vrem.
2. **EVM e single-threaded** prin design. Block production pe EVM va fi mai lent decât native PQ. Acceptat — orderbook nu cere TPS extrem inițial.
3. **Two address formats per user.** UX needs to surface ambele. Wallet-ul afișează "Native: omni1…" și "EVM: 0x…" pentru același user.
4. **EVM bytecode = surface de atac diferit**. EVM smart contracts au reentrancy, integer overflow, MEV. Acceptat — toate chain-urile EVM au asta. Soluție: audit + bug bounty.

---

## What does NOT change

- OmniBus OS modules — neafectate.
- Native PQ chain — neafectat, rulează identic.
- ENS .omnibus, soulbound LOVE/FOOD/RENT/VACATION, mining, treasury — pe partea nativă, nu mută.
- BIP-44 derivation pentru native (path 777') — neschimbat.
- JSON-RPC nativ pe port 8332 — neschimbat.
- 22 V3 escrow-uri externe (Sepolia, Base, etc.) — neschimbate, rămân ca parteneri pentru cross-chain locks.

---

## Code locations (planned)

```
1_CORE/BlockChainCore/
├── core/                          # existing Zig L1 code (PQ, native consensus)
├── evm/                           # existing — Rust contracts compiled for external deploys
├── evm_sidecar/                   # NEW — Rust revm-based EVM execution engine
│   ├── Cargo.toml
│   ├── src/
│   │   ├── main.rs               # JSON-RPC server
│   │   ├── rpc.rs                # eth_* method handlers
│   │   ├── state.rs              # revm DB adapter → LMDB/native storage
│   │   ├── txpool.rs             # accept + validate EVM tx
│   │   └── block_exec.rs         # execute EVM tx list during block production
│   └── README.md
└── EVM_MODULE_DESIGN.md           # this doc
```

---

## First milestone (when implementation starts)

`evm_sidecar` accepts a simple `eth_getBalance` call and returns 0. Then `eth_sendRawTransaction` accepts a signed tx that transfers 0 OMNI between two EVM addresses. After that — deploy a "Hello World" contract via Hardhat. Three weekends of work.
