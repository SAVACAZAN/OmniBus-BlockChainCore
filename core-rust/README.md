# omnibus-node-rust

Rust sibling implementation of BlockChainCore — the same chain as `core/` (Zig), in a different language. Like `reth ↔ geth` for Ethereum or `btcd ↔ bitcoin-core` for Bitcoin: same wire protocol, same chain hashes, both can peer with each other.

## Status (2026-06-01)

**Ported skeleton** — 22 files, ~5,500 LoC, organized by domain:

```
src/
├── main.rs          CLI orchestrator, dispatch by --mode {seed,miner,evm}
├── state.rs         Persistent sled state (accounts, txs, receipts, blocks)
├── types.rs         Shared stubs (SpvBlockHeader, BloomFilter)
├── tx.rs            EIP-1559 + legacy raw tx parse, ECDSA sender recovery
├── block_exec.rs    Transfer-only execution (M2). M3 = revm contracts.
├── rpc/             140+ JSON-RPC methods (eth_* + native OmniBus)
│   ├── mod.rs
│   ├── eth_methods.rs
│   └── native_methods.rs
├── p2p/             Wire-compatible with Zig (byte-for-byte)
│   ├── mod.rs
│   ├── wire.rs      MsgHeader/Hello/Welcome/Stable/BlockAnnounce/PEX/SPV
│   ├── peer.rs      TCP + knock-knock UDP duplicate detection
│   ├── scoring.rs   Peer reputation + persistent ban list (Zig LE format)
│   ├── sync.rs      Block header sync state machine
│   └── bootstrap.rs Peer discovery, seed list, anti-eclipse /16 check
├── consensus/       PoW + Casper FFG + sub-blocks
│   ├── mod.rs       Canonical constants (see below)
│   ├── block.rs     Block, Tx, Merkle root (hash matches Zig exactly)
│   ├── genesis.rs   Locked genesis (mainnet/testnet/devnet/regtest)
│   ├── consensus.rs PoW retarget, block_work, block_reward_at
│   ├── sub_block.rs 10 × 40ms sub-blocks → 1 KeyBlock
│   ├── finality.rs  Casper FFG attestations (domain-separated)
│   └── mempool.rs   FIFO + BIP-125 RBF
├── storage/         chain.dat v4 reader/writer
│   ├── mod.rs
│   ├── codec.rs     LEB128 varint + LE u8/u16/u32/u64 + lp1/lp4
│   ├── database.rs  8-section chain.dat with CRC32-IEEE per section
│   ├── state_trie.rs
│   ├── archive.rs   stub (75% compression estimate, matches Zig)
│   └── compact.rs   161-byte SegWit-style CompactTransaction
├── crypto/          Cryptographic primitives
│   ├── mod.rs
│   ├── secp256k1.rs k256 wrapper (compressed + uncompressed pubkey + hash160)
│   ├── bip32.rs     BIP-39 PBKDF2 + BIP-32 CKD + derive_pq_seed
│   ├── bech32.rs    bech32/bech32m, HRP "ob"
│   ├── ripemd160.rs ripemd crate wrapper, hash160()
│   └── pq.rs        Re-exports omnibus-crypto-core (HKDF-SHA512 + liboqs)
│                    + OmniBus prefixes ob_k1_/ob_f5_/ob_d5_/ob_s3_
└── wallet/          HD wallet
    ├── mod.rs
    ├── hd.rs        from_mnemonic, omni_address(idx), evm_address(idx)
    └── address.rs   EIP-55 checksum, AddressKind enum
```

## Build

### Dev (debug, MSVC OK)
```powershell
cd 1_CORE/BlockChainCore/core-rust
cargo check
cargo build
```

### Release (Windows requires GNU toolchain)
`omnibus-crypto-core` with `pq-oqs` feature links `liboqs.a` built with MinGW. MSVC toolchain fails with `__chkstk_ms` unresolved and assorted stack-overrun crashes in deep deps. Switch to GNU:
```powershell
rustup default stable-x86_64-pc-windows-gnu
cargo build --release
```

### Linux / Mac
```bash
cargo build --release
```

### Without pq-oqs (PQ ops return Unsupported)
Edit Cargo.toml to remove `features = ["pq-oqs"]` from `omnibus-crypto-core`:
```bash
cargo build --no-default-features
```

## Run

```bash
# EVM-only mode (default, no P2P, no consensus — useful for MetaMask dev)
omnibus-node-rust --mode evm
# JSON-RPC at http://localhost:8333, chainId 7771

# Seed node (P2P + consensus + RPC) — when wire-up is complete
omnibus-node-rust --mode seed --node-id node-1 --port 9000

# Miner — when wire-up is complete
omnibus-node-rust --mode miner --node-id miner-1 --seed-host 127.0.0.1 --seed-port 9000

# CLI help
omnibus-node-rust --help
```

## MetaMask setup (EVM mode)

| Field | Value |
|---|---|
| Network name | OmniBus |
| RPC URL | `http://localhost:8333` |
| Chain ID | `7771` |
| Currency symbol | `OMNI` |
| Block explorer URL | (none yet) |

## Verified test vectors (in code, `#[cfg(test)]`)

| Test | Input | Output |
|---|---|---|
| BIP-39 PBKDF2 official | `abandon × 11 + about` + `TREZOR` | `c55257c360c07c72…` |
| Trezor BIP-44 ETH | same + path `m/44'/60'/0'/0/0` | `0x9858EfFD232B4033E47d90003D41EC34EcaEda94` |
| Bech32 `ob1q…` roundtrip | hash160 → 42-char bech32 | matches Zig output |
| EIP-55 reference | `0x5aaeb6053f...` mixed case | `0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed` |
| HKDF PQ seed determinism | (mnemonic, coin_type, scheme, idx) | same bytes on each call |
| Genesis hash | mainnet/testnet/devnet/regtest | `82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982` |
| CRC32-IEEE | `b"123456789"` | `0xCBF43926` |

## Wire protocol compat with Zig

P2P MessageType discriminants are hardcoded `#[repr(u8)]` matching `core/network.zig` lines 182-214 (Ping=0 … Stable=22). Wire format is byte-for-byte: same field order, same endianness (LE), same length-prefix conventions.

| Message | Size | Notes |
|---|---|---|
| MsgHeader | 9 B | type:u8 + length:u32 + checksum:u32 (LE) |
| MsgHello | 79 B | + genesis_hash:32B (legacy 47B accepted) |
| MsgWelcome | 46 B | — |
| MsgStable | 10 B | — |
| MsgBlockAnnounce | 90 B | V2 layout |
| BlockHeader (sync) | 130 B | V3, includes miner_id[42] |
| SpvBlockHeader | 124 B | for light clients |
| BloomFilter | 513 B | — |
| CompactTransaction | 161 B | SegWit-style |

## Pending integration

- [ ] Wire `p2p::P2PNode` into `main.rs` for `--mode seed/miner` (currently falls back to EVM-only)
- [ ] Bridge `consensus::ConsensusEngine` + `storage::ChainDb` for actual block production
- [ ] revm integration (M3): connect `block_exec.rs` to `omnibus_crypto::pq` + revm for contract calls and deploys
- [ ] Cross-impl peer test: bring up Zig node + Rust node on same LAN, watch them sync
- [ ] Native RPC: connect handlers in `rpc/native_methods.rs` to the real state (currently most are stubs)

## Why a sibling implementation

- **Redundancy**: bugs that hit one impl don't necessarily hit the other (consensus bug surface diversity)
- **Tooling**: Rust ecosystem brings revm, alloy, k256, sled, axum — easier to integrate with the modern EVM/PQ tooling stack
- **Onboarding**: contributors who prefer Rust can hack on the same chain
- **Performance comparison**: head-to-head measurements between Zig and Rust paths on hot loops

Same chain. Two minds. One OMNI.
