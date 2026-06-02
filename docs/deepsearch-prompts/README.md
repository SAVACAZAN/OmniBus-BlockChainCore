# DeepSearch prompts — OmniBus C++ + Go ports

Two self-contained prompts for **DeepSearch** (or any other multi-shot LLM that follows OEP-1).
Both produce a **full sibling implementation** of OmniBus blockchain in their target language,
peering wire-compatibly with the existing Zig (`core/`) and Rust (`core-rust/`) impls.

## Files

| Prompt | Target | Output project | Estimated files |
|---|---|---|---|
| [`PROMPT_CPP_omnibus_node.md`](PROMPT_CPP_omnibus_node.md) | C++20 | `omnibus-node-cpp` (→ `core-cpp/`) | 100-150 (chunked) |
| [`PROMPT_GO_omnibus_node.md`](PROMPT_GO_omnibus_node.md) | Go 1.22+ | `omnibus-node-go` (→ `core-go/`) | 100-150 (chunked) |

**Chunking**: DeepSearch response has a token cap. Each prompt instructs the model to emit `status=partial` on the trailer of intermediate chunks, then continue with `seq=N₁+1` on the next run. Re-paste the prompt + "continue from seq=N₁+1" until the final chunk says `status=complete`.

## How to use

1. Open DeepSearch (or any LLM that handles file uploads + long context).
2. **Upload these as attachments** (the prompt references them by name):
   - The entire `core/` directory (Zig source).
   - The entire `core-rust/src/` directory (Rust sibling).
   - `CLAUDE.md` (parameters + DEX rules table).
   - `EVM_MODULE_DESIGN.md`.
3. Paste the whole prompt file contents into the prompt box.
4. Run.
5. Output will be a series of OEP-1 fenced blocks. Each block = one file with a header like:
   ```
   // OEP-1 1/30 | path=include/omnibus/types.hpp | proj=omnibus-node-cpp | run=2026-06-01-cpp-v1
   ```
6. Pipe the response through the omni-extractor:
   ```bash
   # JavaScript browser extension extracts automatically
   # OR Python CLI:
   python 6_INFRA/omni-extractor/parsers/python/oep1.py \
          < deepsearch-response.txt \
          --out-dir 1_CORE/BlockChainCore/core-cpp/
   ```
7. The extractor writes each file at its declared `path` relative to `--out-dir`.

## Protocol invariants (NON-NEGOTIABLE)

Both prompts hard-code the same canonical values to ensure chain compatibility:

| Value | Across all impls |
|---|---|
| Genesis hash | `82ec46e83af37b1ea0e6b3fe66a8f04795a8e8aae7db414d451eff1154245982` |
| Genesis timestamp | `1743000000` |
| Network magics | `OMNI` / `TEST` / `DEVN` / `REGT` |
| Block reward | `8333333` sat |
| Halving | every `126144000` blocks |
| Block time | `1` second |
| Sub-blocks/block | `10` × `40 ms` |
| Native HRP | `"ob"` → `ob1q…` 42-char addresses |
| EVM chainId | `7771` |
| Ports | 8332 (native RPC), 8333 (EVM), 8334 (WS), 9000 (P2P) |
| DEX pair_id | 0/2/3/5/6 (1+4 reserved) |
| DB version | `4` |

Any impl that disagrees on any of these would fork the chain on the first block.

## Test vectors (must pass in all impls)

1. BIP-39 PBKDF2 official: `abandon × 11 + about` + `TREZOR` → `c55257c360c07c72…`
2. Trezor BIP-44 ETH: same seed, `m/44'/60'/0'/0/0` → `0x9858EfFD232B4033E47d90003D41EC34EcaEda94`
3. bech32 `ob1q…` roundtrip with HRP `ob`
4. EIP-55 checksum: `0x5aaeb6053f...` → `0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed`
5. CRC32-IEEE: `b"123456789"` → `0xCBF43926`
6. Genesis hash matches the constant above

## After DeepSearch returns

1. Extract files using `omni-extractor`.
2. Place at `1_CORE/BlockChainCore/core-cpp/` or `1_CORE/BlockChainCore/core-go/`.
3. Build:
   - C++: `cd core-cpp && cmake -B build && cmake --build build`
   - Go: `cd core-go && go build ./...`
4. Run tests: `ctest` (C++) or `go test ./...` (Go).
5. Cross-impl peer test:
   - Start C++/Go seed: `./omnibus-node --mode seed --port 9000`
   - Connect Zig miner: `./omnibus-node.exe --mode miner --seed-host 127.0.0.1 --seed-port 9000`
   - Both logs should show `HELLO received`, `WELCOME sent`, `STABLE received`.

## Why we do this

**Client diversity**. Same bug class doesn't hit two different language implementations:
- Buffer overflow in C++ → doesn't exist in safe Rust / Go.
- Race condition in Go runtime → not the same in Zig threads.
- 0-day in `libc` glibc → no-std Zig untouched.

A network of 4 impls (Zig + Rust + C++ + Go) is the same defense Ethereum and Bitcoin use to
keep their chains running through years of vulnerabilities. One impl going down doesn't take
the chain with it.

## Order of operations (recommended)

1. Run **PROMPT_GO** first (Go has best DeepSearch coverage of standard primitives).
2. Verify Go port compiles + passes test vectors.
3. Run **PROMPT_CPP**.
4. Verify C++ port compiles + passes test vectors.
5. Bring up cross-impl peer test on a private testnet (chain_magic = `TEST`).
6. Run 1000 blocks; diff chain.dat. Should be byte-identical.

If any step fails: tighten the prompt with the specific gap and re-run that step only.
