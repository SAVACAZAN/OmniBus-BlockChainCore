# DeepSearch Prompt — Port OmniBus blockchain to Go (full node, no stubs)

**proj**: `omnibus-node-go`
**run**: `2026-06-01-go-v1`
**target files**: `100-150` (FULL port — NOT a minimal subset). Chunk across multiple responses if needed.

**Coverage rule**: produce **EVERY file needed** for a working node — `.go` source + `_test.go` for every module listed below, plus `go.mod`, `go.sum` (generated), main entries, CLI tools, integration tests. The Rust sibling at `core-rust/src/` has ~70 files and is ~35% of the Zig source (~338 files). Aim higher than Rust: a `.go` file for every Zig module under `core/*.zig` that isn't trivially deprecated, plus `_test.go` companions.
**input attachments** (you upload these before running):
- Entire `1_CORE/BlockChainCore/core/` directory (Zig source, ~338 files)
- Entire `1_CORE/BlockChainCore/core-rust/src/` directory (Rust sibling port, ~70 files)
- `1_CORE/BlockChainCore/CLAUDE.md` (parameters + DEX rules)
- `1_CORE/BlockChainCore/EVM_MODULE_DESIGN.md`

---

## Task

You are porting the OmniBus blockchain to **Go 1.22+** as a fourth sibling implementation alongside Zig (`core/`), Rust (`core-rust/`), and the future C++ port. The Go port must:

1. **Wire-compatible** with Zig, Rust, and C++ nodes — same TCP message format byte-for-byte.
2. **Chain-compatible** — produces identical block hashes, state roots, chain.dat binary files.
3. **No stubs** — every function fully implemented. Hardware mining backends may be sentinel `// TODO: hardware backend` comments inside named functions only.
4. **Idiomatic Go** — channels for actor patterns, context.Context for cancellation, errors via wrapping, no panic in library code.

## Hard constraints (NON-NEGOTIABLE — protocol invariants)

| Value | Mandatory |
|---|---|
| Genesis hash | `82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982` |
| Genesis timestamp | `1743000000` (2026-03-26 UTC) |
| Network magics | mainnet=`OMNI`, testnet=`TEST`, devnet=`DEVN`, regtest=`REGT` |
| Block reward sat | `8333333` |
| Halving interval | `126144000` blocks |
| Target block time | `1` second |
| Sub-blocks per block | `10` (40 ms each) |
| SAT per OMNI | `1000000000` (1e9) |
| Max supply | `21000000` OMNI |
| Retarget | every `2016` blocks; `new = old * 2016 / clamp(actual, 504, 8064)` |
| Max block size | `1048576` bytes |
| Max block tx | `4096` |
| Coinbase maturity | `100` blocks |
| Fee burn pct | `50%` |
| Native bech32 HRP | `"ob"` (NOT `"omni"`) — produces `ob1q…` (42 chars) |
| EVM chain ID | `7771` |
| RPC port | `8332` (native), `8333` (EVM JSON-RPC), `8334` (WebSocket), `9000` (P2P) |
| PQ prefixes | soulbound: `ob_k1_/ob_f5_/ob_d5_/ob_s3_`; transferable: `obk1_/obf5_/obd5_/obs3_` |
| DEX pair_id | 0=OMNI/USDC, 2=LCX/USDC, 3=ETH/USDC, 5=OMNI/LCX, 6=OMNI/ETH; 1+4 RESERVED |
| BIP-44 coin_types | OMNI native=`777'`, EVM=`60'` |
| DB version | `4` (chain.dat 8-section layout, CRC32-IEEE per section) |

## Expected file layout

```
core-go/
├── go.mod
├── go.sum
├── README.md
├── cmd/
│   ├── omnibus-node/main.go        // CLI --mode {seed,miner,evm}
│   └── omnibus-cli/main.go         // wallet ops CLI
├── pkg/
│   ├── types/
│   │   └── types.go                // Address, Hash256, U256 (math/big), Sig64
│   ├── codec/
│   │   └── codec.go                // LEB128 varint, LE u8/u16/u32/u64, lp1/lp4
│   ├── crypto/
│   │   ├── sha256.go               // wraps crypto/sha256
│   │   ├── keccak.go               // wraps golang.org/x/crypto/sha3
│   │   ├── ripemd160.go            // wraps golang.org/x/crypto/ripemd160
│   │   ├── secp256k1.go            // wraps github.com/decred/dcrd/dcrec/secp256k1/v4
│   │   ├── bech32.go               // HRP "ob"
│   │   ├── bip32.go                // BIP-39 PBKDF2 + BIP-32 CKD
│   │   └── pq.go                   // liboqs cgo bindings (ML-DSA, Falcon, SLH-DSA, ML-KEM)
│   ├── wallet/
│   │   ├── hd.go                   // OmniAddress(idx), EVMAddress(idx)
│   │   └── address.go              // EIP-55, AddressKind enum
│   ├── consensus/
│   │   ├── params.go               // hard constants
│   │   ├── block.go                // Block, Tx, Merkle root (hash matches Zig)
│   │   ├── sub_block.go            // SubBlock, KeyBlock
│   │   ├── genesis.go              // BuildGenesisBlock(network)
│   │   ├── pow.go                  // SHA-256d + target + Retarget
│   │   ├── finality.go             // Casper FFG attestation
│   │   └── mempool.go              // FIFO + BIP-125 RBF
│   ├── storage/
│   │   ├── chain_db.go             // chain.dat v4
│   │   ├── state_trie.go
│   │   └── compact_tx.go           // 161-byte
│   ├── p2p/
│   │   ├── wire.go                 // MsgHeader 9B, Hello 79B, Welcome 46B, etc.
│   │   ├── peer.go                 // PeerConnection over net.Conn
│   │   ├── scoring.go              // peer reputation + ban list
│   │   ├── sync.go                 // BlockHeader V3 130B
│   │   ├── bootstrap.go            // PeerManager, /16 anti-eclipse
│   │   └── node.go                 // P2PNode orchestrator
│   ├── dex/
│   │   ├── pair.go                 // ASSET_CHAINS, PAIR_ROUTES
│   │   ├── order.go
│   │   ├── matching.go             // price-time FIFO + Merkle root
│   │   ├── htlc.go                 // preimage backend-only
│   │   ├── grid.go
│   │   └── oracle.go
│   ├── identity/
│   │   ├── did.go                  // did:omnibus:<base58>
│   │   ├── obm.go
│   │   ├── manifest.go             // 10-leaf Merkle
│   │   ├── salt.go                 // 32-byte, file perms 0600
│   │   ├── kyc.go
│   │   ├── mica.go                 // canonical JSON pre-hash
│   │   ├── ns.go                   // .omnibus / .arbitraje
│   │   └── facets/{social,professional,cultural,economic}.go
│   ├── governance/
│   │   └── proposal.go
│   ├── validator/
│   │   ├── tier.go                 // Omni/Love/Food/Rent/Vacation
│   │   ├── staking.go
│   │   ├── set.go
│   │   └── slashing.go
│   ├── mining/
│   │   ├── engine.go
│   │   ├── pool.go
│   │   └── stratum.go              // v1 JSON-RPC
│   ├── light/
│   │   ├── spv.go                  // 124-byte header
│   │   ├── bloom.go                // 513-byte, Murmur seed-rotation
│   │   └── client.go
│   ├── rpc/
│   │   ├── server.go               // HTTP JSON-RPC :8332
│   │   ├── eth.go                  // eth_* methods :8333
│   │   └── native.go               // ~140 OmniBus native methods
│   ├── ws/
│   │   ├── server.go               // WebSocket :8334 (gorilla/websocket)
│   │   └── events.go               // 17 event types + topic bitmask
│   ├── shard/
│   │   ├── coordinator.go          // 4-shard, SHA-256(addr)[0..2] % NUM_SHARDS
│   │   └── metachain.go
│   ├── agents/
│   │   ├── tier.go                 // T1Mining → T4Arbitrage
│   │   ├── executor.go
│   │   └── manager.go
│   ├── vault/
│   │   └── vault.go                // Windows pipe `\\.\pipe\OmnibusVault`; Unix /var/run/omnibus/vault.sock
│   ├── guardian/
│   │   └── guardian.go             // BlockGuardian + AccountGuardian (2FA)
│   └── dns/
│       └── dns.go
└── tests/                          // _test.go files alongside, plus integration
    └── ...
```

## Dependencies allowed

- `github.com/decred/dcrd/dcrec/secp256k1/v4` — secp256k1 ECDSA (Bitcoin-compatible)
- `golang.org/x/crypto/{sha3,ripemd160,pbkdf2,hkdf}` — extra primitives
- `github.com/gorilla/websocket` — WebSocket server :8334
- `github.com/cockroachdb/pebble` or `go.etcd.io/bbolt` — KV store (replaces `sled` in Rust port)
- `github.com/stretchr/testify` — test assertions
- `github.com/open-quantum-safe/liboqs-go` — PQ (or cgo bindings to liboqs.a)
- `github.com/cosmos/btcutil/bech32` — bech32 (custom HRP "ob")
- `golang.org/x/sys/windows` — for Named Pipe on Windows
- Standard library `encoding/binary`, `crypto/sha256`, `crypto/hmac`, `net`, `net/http`, `context` — preferred over third-party where possible

## Test vectors that MUST pass

In `tests/test_vectors_test.go`:

```go
func TestBIP39PBKDF2Official(t *testing.T) {
    mnemonic := "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
    seed := crypto.MnemonicToSeed(mnemonic, "TREZOR")
    want := "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e5349553"
    require.Equal(t, want, hex.EncodeToString(seed[:32]))
}

func TestTrezorBIP44ETH(t *testing.T) {
    seed := crypto.MnemonicToSeed("abandon abandon ... about", "TREZOR")
    hd := wallet.FromSeed(seed)
    addr := hd.EVMAddress(0)
    require.Equal(t, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", addr)
}

func TestBech32OB1qRoundtrip(t *testing.T) { /* hash160 → ob1q... 42 chars */ }
func TestEIP55Checksum(t *testing.T) {
    require.Equal(t, "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", wallet.EIP55("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"))
}
func TestCRC32IEEE(t *testing.T) { require.Equal(t, uint32(0xCBF43926), codec.CRC32([]byte("123456789"))) }
func TestGenesisHash(t *testing.T) {
    g := consensus.BuildGenesisBlock(consensus.NetworkMainnet)
    require.Equal(t, "82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982", hex.EncodeToString(g.Hash[:]))
}
func TestPQDeterministic(t *testing.T) { /* derive twice, expect identical pubkey */ }
func TestHTLCPreimageHidden(t *testing.T) { /* before Claim, revealed returns nil */ }
func TestReservedPairs(t *testing.T) { /* matching.PlaceOrder pair_id 1 or 4 → error */ }
```

## Cross-impl peering test (document in README)

```bash
# Start a Go seed
./bin/omnibus-node --mode seed --port 9000

# In another terminal, start a Zig miner
./bin/omnibus-node.exe --mode miner --seed-host 127.0.0.1 --seed-port 9000

# Expected log on Go seed:
#   inbound peer accepted
#   HELLO received
#   WELCOME sent
```

## Idioms required

- Use `context.Context` as FIRST argument of all blocking methods (`P2PNode.Run(ctx)`, `Mining.Engine.Run(ctx)`, etc.).
- Errors wrapped: `fmt.Errorf("decoding hello: %w", err)`.
- No global mutable state except `sync.Once`-protected init.
- Use `t.Helper()` in test helpers.
- Goroutines must be cancellable through context or explicit shutdown channels — no leaks.
- Use channels for actor patterns (mempool, P2P sync, mining engine).
- Atomic operations via `sync/atomic` not `sync.Mutex` where possible.

## What NOT to do

- Do NOT use `interface{}` (use `any` only when truly heterogeneous; prefer typed channels and interfaces).
- Do NOT use `panic` in library code; return errors.
- Do NOT use `reflect` for serialization — write explicit `encoding/binary` calls.
- Do NOT change pair_id, port numbers, magic bytes, chain_id, genesis hash, block reward — protocol invariants.
- Do NOT generate stubs that return `errors.New("TODO")` — implement fully or omit the file.

---

## OUTPUT FORMAT — OEP-1 (Omni Extraction Protocol v1)

Your response MUST emit each file in its own fenced code block. The FIRST LINE inside each block is an OEP-1 metadata header in the language-appropriate single-line comment:

  `// OEP-1 <seq>/<total> | path=<relative-path> | proj=omnibus-node-go | run=2026-06-01-go-v1`

For go.mod use `//`; for README.md use `<!-- ... -->`.

After the last block, emit ONE trailer line outside any code block:
  `END OEP-1 RUN: proj=omnibus-node-go | run=2026-06-01-go-v1 | files=<N>/<N> | status=complete`

Example:
```go
// OEP-1 1/30 | path=pkg/types/types.go | proj=omnibus-node-go | run=2026-06-01-go-v1
package types

type Hash256 [32]byte
type Address [20]byte
// ... rest of file ...
```

## Chunking strategy (USE IT — output WILL exceed one response)

You are producing 100-150 files. A single response can hold ~30-50 medium files before truncation. Plan to chunk:

1. **First response**: emit files seq=1 to seq=N₁ (the most you can fit cleanly). End trailer with `status=partial` and `files=N₁/TOTAL`.
2. **User reruns** with the same prompt + says "continue from seq=N₁+1". You emit seq=N₁+1 onward.
3. Each chunk = complete files only. NEVER split a single file across chunks.
4. Final chunk's trailer = `status=complete` + `files=TOTAL/TOTAL`.

When in doubt, **prefer more, smaller files** (single-responsibility) over fewer mega-files. Each Go file ≤ ~400 lines.

If you reach the response limit mid-file, drop that file entirely from the chunk and emit it complete in the next chunk. Never emit half a file.

## What "complete coverage" means in practice (Go)

Each module gets at least these files:
- `<module>.go` — public API
- `<module>_test.go` — unit tests + test vectors
- Sub-files where the module is large (e.g., `dex/matching.go` + `dex/matching_orderbook.go` + `dex/matching_fills.go`)
- One `doc.go` per package with `// Package <name> ...` summary referencing the equivalent Zig file

Plus integration tests under `tests/integration/`:
- `peering_test.go` — start two Go nodes, verify HELLO/WELCOME
- `block_sync_test.go` — sync 100 blocks between two nodes
- `cross_impl_test.go` — connect to Zig/Rust node (skipped under `// +build cross_impl`)

Plus `cmd/` binaries: `omnibus-node` (main full node) + `omnibus-cli` (wallet CLI) + `omnibus-keygen` (key generation) + `omnibus-explorer` (read-only block explorer).
