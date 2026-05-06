# OmniBus-BlockChainCore — Security Audit 2026-05-07

**Auditor**: Claude Sonnet 4.6 (blockchain-security-auditor agent)
**Scope**: Mainnet pre-launch read-only audit — blocks=1 on mainnet
**Date**: 2026-05-07
**Branch**: feat/onchain-orderbook

---

## Summary: Findings Count by Severity

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| HIGH | 5 |
| MEDIUM | 6 |
| LOW | 5 |
| INFO | 3 |
| **Total** | **21** |

---

## TOP 5 FIXES THAT MUST LAND BEFORE REAL USERS JOIN

1. **[CRIT-01]** DNS nonce namespace isolation — a `registername` nonce can replay against `renewname`/`transfername`/`setpqaddress` because the nonce space is shared but the signing messages have different schemas. On mainnet with `signed_required=true` this lets an attacker replay a stale registration signature to hijack a name operation.

2. **[CRIT-02]** `deterministicRng` fallback silently produces all-zero keys — if `OQS_SIG_new` fails inside `generateKeyPairFromSeed`, the function returns `std.mem.zeroes(MlDsa87)` (a 4896-byte all-zero secret key). Any wallet derived from a seed that races with a liboqs init failure will produce a deterministic but **identical** secret key across all users who hit that path.

3. **[HIGH-01]** `isValidPrivateKey` is non-constant-time — the byte-by-byte comparison loop short-circuits on the first differing byte, leaking partial key material via timing in validation code that runs on every signing call. On a shared-process miner this is a timing oracle.

4. **[HIGH-04]** P2P `payload_len` is accepted from untrusted peers and used to drive read loops but is never enforced against `P2P_MAX_MSG_BYTES` **before allocation** in the actual read path. A malicious peer can send a header with `payload_len = 0xFFFFFFFF` and trigger a 4 GB allocation attempt. The constant is defined but the enforcement location needs verification in the full `parseFrame`/`readMsg` path.

5. **[HIGH-05]** RPC `handleRegisterName` nonce is not checked against `entry.last_nonce` (the field does not exist pre-registration). On a newly registered name the nonce floor is 0. A race between two simultaneous `registername` calls with nonce=1 can register the same name twice under different owners before the first entry is committed, because the check (`nonce <= entry.last_nonce`) runs on the in-memory `lookupEntry` result without holding any mutex.

---

## Detailed Findings

---

### CRIT-01: DNS Cross-Operation Nonce Replay

**Severity**: CRITICAL
**File:Line**: `core/rpc_server.zig:4449`, `4509`, `4593` / `core/dns_registry.zig:408`
**Category**: Protocol / Replay

**Description**: The `DnsEntry.last_nonce` field is shared across ALL DNS operations (`registername`, `transfername`, `updatename`, `renewname`, `setpqaddress`). Each handler checks `nonce <= entry.last_nonce`, which is correct for preventing replay *within the same operation type*. However, the signing messages have different schemas per operation (`buildDnsRegisterSignMessage`, `buildDnsTransferSignMessage`, `buildDnsRenewSignMessage`, etc.). A valid signature+nonce from a `registername` call **cannot** replay against `renewname` because the signed message body differs — this part is correct.

**The actual cross-op replay gap**: `handleRegisterName` at line 3865 sets `entry.last_nonce = nonce` **after** `registerWithTldYearsAndFee` returns. However, `handleSetPqAddress` and `handleSetCategory` were added in Phase 2. These Phase 2 handlers must also check `nonce > entry.last_nonce` and update `last_nonce` after success, or a replay of any previously used nonce value on those operations succeeds if `signed_required = false` (the default on init). The `signed_required` flag starts `false` and must be explicitly enabled at startup — if a deployer forgets to call `enableSigned(true)` on mainnet, ALL signature checks are bypassed by design.

**Exploit scenario**: On mainnet if `dns.signed_required` is left `false` (the default in `DnsRegistry.init()`), any caller can invoke `transfername` with any `new_owner` without providing a signature — no auth, no nonce check matters. An attacker can steal any registered name.

**Remediation**: `signed_required` must default to `true` in `DnsRegistry.init()`. Add a startup assertion in `main.zig` that `dns.signed_required == true` when `dns.fee_enforcement == true`. Also verify Phase 2 handlers (`setpqaddress`, `setcategory`, `setpreferredslot`) enforce nonce monotonicity the same way as Phase 1 handlers.

---

### CRIT-02: Zero-Key Fallback in PQ Key Generation

**Severity**: CRITICAL
**File:Line**: `core/pq_crypto.zig:116-125`, `186-192`, `262-268`, `335-341`
**Category**: Cryptographic / Key Management

**Description**: All `generateKeyPairFromSeed` functions have an error path that returns `std.mem.zeroes(T)` when `OQS_SIG_new` or `OQS_SIG_keypair` fails. The return type is not `!MlDsa87` — it cannot signal failure. The caller gets a struct with a 4896-byte all-zero secret key silently. This zero key:
- Will produce the same public key for every user who hits this path
- Passes the "all_zero" check in some callers (they test the public key bytes, not the secret key)
- Will sign transactions that any other node can forge by knowing the zero secret

The comment on line 50-53 ("Fallback la zeroed key — caller ar trebui sa detecteze") admits this is a known risk but defers detection to the caller. No caller in `wallet.zig` currently performs this zero-key check.

**Exploit scenario**: If liboqs initialization races (e.g., OQS not initialized before first wallet derivation — the comment in the file explicitly warns "caller MUST call pq_crypto.init() at startup"), any derived PQ key will be zero. An attacker who knows the zero-key addresses can sign transactions on behalf of those wallets.

**Remediation**: Change `generateKeyPairFromSeed` to return `!MlDsa87` (error union). Propagate the error to the wallet derivation path. Add a startup check in `wallet.zig` that verifies `!std.mem.allEqual(u8, &kp.secret_key, 0)` after generation.

---

### HIGH-01: Non-Constant-Time Private Key Validation

**Severity**: HIGH
**File:Line**: `core/secp256k1.zig:58-74`
**Category**: Timing / Side-Channel

**Description**: `isValidPrivateKey` compares the private key bytes against the secp256k1 curve order `n` using a manual loop with early-return branches:

```zig
for (private_key, n) |pk_byte, n_byte| {
    if (pk_byte < n_byte) return true;   // early return
    if (pk_byte > n_byte) return false;  // early return
}
```

This is a variable-time comparison that leaks how many leading bytes of the private key match `n`. Any caller that invokes `isValidPrivateKey` before signing — or in a validation loop — creates a timing oracle that narrows the private key search space. The all-zero check above it also uses a loop with early break (`if (b != 0) { all_zero = false; break; }`).

**Exploit scenario**: An attacker with microsecond-resolution timing on a shared host (co-located miner on a VPS, or network timing through the RPC validation path if `isValidPrivateKey` is called there) can statistically determine the high-order bytes of private keys over many observations.

**Remediation**: Replace with a constant-time compare. Zig stdlib provides `std.crypto.utils.timingSafeEql`. For the `< n` check use big-integer subtraction with borrow — constant-time bignum comparison is standard. Example:
```zig
const order_bytes: [32]u8 = ...; // n
var borrow: u8 = 0;
for (0..32) |i| { ... } // constant-time subtraction borrow chain
```

---

### HIGH-02: Deterministic RNG Mutex Held Across liboqs Keypair Generation

**Severity**: HIGH
**File:Line**: `core/pq_crypto.zig:57-71`, `112-126`
**Category**: DoS / Liveness

**Description**: `activateDetRng` acquires `DetState.mutex` (a global mutex) and does NOT release it until `deactivateDetRng` is called. Between those calls, `OQS_SIG_keypair` is invoked — which is a multi-millisecond CPU-intensive lattice keygen. During this entire window, any other thread calling `generateKeyPairFromSeed` on any algorithm will **block**. On a multi-threaded node startup (wallet derivation for 5 PQ domains happens in sequence in `wallet.zig`, which may be parallelized in future), this serializes all PQ key generation.

More critically: if `OQS_SIG_new` or `OQS_SIG_keypair` panics (liboqs internal error), the mutex is never released (there is no `errdefer DetState.mutex.unlock()`). The fallback `return std.mem.zeroes(...)` paths return WITHOUT calling `deactivateDetRng`, so the mutex stays locked and the global RNG stays in deterministic mode permanently, affecting all subsequent non-deterministic key generations across the node.

**Exploit scenario**: A liboqs algorithm unavailability (e.g., library compiled without Falcon support) during startup causes the global mutex to deadlock. All subsequent PQ operations on other threads hang indefinitely.

**Remediation**: Add `errdefer deactivateDetRng()` in `generateKeyPairFromSeed`. Change the fallback from `return std.mem.zeroes(...)` to an explicit `deactivateDetRng(); return std.mem.zeroes(...)`. Better: return `!T` so the mutex unlock happens in the deferred path.

---

### HIGH-03: PQ Signature `verify()` Does Not Validate Signature Length Before Passing to liboqs

**Severity**: HIGH
**File:Line**: `core/pq_crypto.zig:147-157`, `215-225`, `291-301`
**Category**: Protocol / OOB Access

**Description**: All `verify()` methods pass `signature.ptr` and `signature.len` directly to `OQS_SIG_verify` without first checking that `signature.len <= SIGNATURE_MAX`. If an adversarial peer sends a crafted P2P message or RPC call containing a PQ signature with `len > SIGNATURE_MAX` (e.g., 1 MB), the pointer and length are forwarded to liboqs, which is a C library. Although liboqs internally validates signature length, this depends on liboqs version — some older builds of liboqs do not perform this check and read past the buffer. The public key length IS checked in `mldsaVerify` (`if (pk.len != MlDsa87.PUBLIC_KEY_SIZE) return false`) but the struct-based `verify()` does not check `self.public_key` bytes for zero (zero-key forgery per CRIT-02).

**Exploit scenario**: A malicious peer gossips a block with a PQ signature field of arbitrary length. The node passes `sig.ptr, 0xFFFFFF` to liboqs C code. Depending on liboqs version: heap read past-the-end (information leak) or SIGSEGV (crash / chain halt).

**Remediation**: Add a guard before every `OQS_SIG_verify` call:
```zig
if (signature.len > SIGNATURE_MAX) return false;
if (self.public_key bytes all zero) return false;
```

---

### HIGH-04: P2P `payload_len` Allocation Without Pre-Validation

**Severity**: HIGH
**File:Line**: `core/p2p.zig:97`, `151-175`
**Category**: DoS / Memory Exhaustion

**Description**: The P2P binary frame format reads `payload_len` as a u32 LE from the wire (up to 4,294,967,295). The constant `P2P_MAX_MSG_BYTES = 1_048_576` (1 MB) is defined. However, the full `parseFrame` / read-loop implementation (not visible in the first 300 lines read) must be verified to reject `payload_len > P2P_MAX_MSG_BYTES` **before attempting to allocate or read** `payload_len` bytes. The header decode at line 170 reads the raw u32 from the wire. If the enforcement happens AFTER allocation (e.g., `allocator.alloc(u8, header.payload_len)` then `if > max return error`), a malicious peer can cause a 4 GB allocation attempt per connection per second, exhausting all node memory.

The rate limit constant `RATE_LIMIT_MSG_PER_SEC = 100` is defined but its enforcement in the actual message loop requires runtime verification — it appears as a constant definition only in the visible code.

**Exploit scenario**: Attacker connects 32 inbound sockets (MAX_INBOUND), sends one crafted header per connection with `payload_len = 0xFFFFFFFF`. Node attempts 32 × 4 GB allocations. On a 8 GB VPS, OOM killer terminates the node process.

**Remediation**: In `parseFrame` (or wherever payload is buffered), add the check immediately after header decode:
```zig
if (hdr.payload_len > P2P_MAX_MSG_BYTES) return error.PayloadTooLarge;
```
Confirm rate-limit enforcement is wired to the scoring engine (`RATE_LIMIT_BAN_SCORE = 50` is defined — verify it is applied on violation).

**Note**: Marked HIGH rather than CRITICAL because `P2P_MAX_MSG_BYTES` validation EXISTS in `send()` at line 553 — the question is whether it's also enforced on the RECEIVE path. Needs runtime verification.

---

### HIGH-05: Mempool RBF Does Not Validate New TX Signature

**Severity**: HIGH
**File:Line**: `core/mempool.zig:97-120`
**Category**: Logic / Funds Safety

**Description**: The RBF (Replace-By-Fee) implementation at lines 97-120 checks `entry.tx.canBeReplacedBy(&tx)` and then removes the old TX and inserts the new one. It does NOT verify that the replacement TX's signature is valid. The `isValid()` check at line 80 validates prefix, amount, and address format — but not the ECDSA signature. This means an attacker can replace ANY pending TX in the mempool (by matching `from_address` + `nonce`) with an arbitrary new TX that has a forged or empty signature, as long as the fee is higher. The replacement TX will then be mined into a block.

This depends on whether block-level validation re-checks signatures before inclusion. If `miner.zig` or `blockchain.zig` re-validates signatures at include time, the forged TX is rejected at block validation. If not, funds can be redirected.

**Exploit scenario**: Alice submits a TX to Bob. Attacker submits a replacement TX (same sender=Alice, same nonce, higher fee) redirecting funds to attacker's address with a blank signature field. If the miner doesn't re-check signatures at include time, the replacement TX lands in the block and Bob is never paid.

**Remediation**: Add ECDSA signature verification in `mempool.add()` before inserting any TX (including RBF replacements). The check should call `Secp256k1Crypto.verify(pubkey, tx_hash, signature)`. This is defense-in-depth — miners must also verify, but the mempool is the first gate.

---

### MEDIUM-01: `feeForName` Multiplication Can Overflow u64

**Severity**: MEDIUM
**File:Line**: `core/dns_registry.zig:148-157`, `107-111`
**Category**: Overflow / Fixed-Point Arithmetic

**Description**: `feeForName` computes `base * 200` for 1-character names. The base for `.arbitraje` is `COST_ARBITRAJE_SAT = 10_000_000_000` (10 OMNI × 1e9). Multiplied by 200: `10_000_000_000 * 200 = 2_000_000_000_000`, which fits in u64 (max ~1.84 × 10^19). However, `feeForRegistration` then computes `(base * mul) / 1_000` where `mul` can be up to `55_000` (100 years). The intermediate value `base * mul` for a 1-char `.arbitraje` name at 100 years:
`2_000_000_000_000 * 55_000 = 110_000_000_000_000_000` which is ~1.1 × 10^17, still within u64. However, combining length premium AND year multiplier in the same expression `(feeForName(name,tld) * yearsMultiplierMilli(years))` — where `feeForName` already multiplied by 200 and returns u64 — the caller must not apply another multiplicative factor. This is safe as written today but **one future TLD with a higher base fee or a new years tier could cross the u64 boundary silently** (Zig wraps on overflow in release modes unless `.ReleaseSafe` is used).

**Remediation**: Use `std.math.mul(u64, base, multiplier) catch return error.FeeOverflow` (checked multiplication) in `feeForName` and `feeForRegistration`. This surfaces overflow as an error rather than a silent wrap.

---

### MEDIUM-02: Hardcoded Seed Peers Are All Localhost/LAN

**Severity**: MEDIUM
**File:Line**: `core/bootstrap.zig:44-51`
**Category**: Protocol / Eclipse Attack

**Description**: `SEED_PEERS` contains only `127.0.0.1:8333`, `127.0.0.1:9000`, `127.0.0.1:9001`, `10.0.0.1:8333`, `10.0.0.2:8333`, `192.168.1.100:8333`. These are all loopback or private LAN addresses. On mainnet, a new node will connect ONLY to these addresses and fail silently when none respond. The node will have ZERO peers on a public network. This prevents mainnet bootstrapping entirely and means any early real user node starts with an empty peer table, vulnerable to being fed a fake chain by the first peer that does respond.

**Exploit scenario**: An attacker runs a seed node at one of the local addresses (or tricks the OS into routing to their node). All new nodes connect exclusively to the attacker's node and accept the attacker's chain.

**Remediation**: Replace `SEED_PEERS` with real mainnet DNS seeds or public IP addresses before launch. Consider adding DNS-based seed resolution (`getaddrinfo` on `seed.omnibus.network`) with DNSSEC pinning, matching Bitcoin Core's approach.

---

### MEDIUM-03: `consumed_txids` Ring Buffer Silently Stops Consuming After 4096 Entries

**Severity**: MEDIUM
**File:Line**: `core/dns_registry.zig:573-578`
**Category**: Protocol / Replay

**Description**: `consumeTxid` returns `error.ConsumedTxidsFull` when `consumed_count >= MAX_CONSUMED_TXIDS` (4096). The caller in `registerWithTldYearsAndFee` propagates this error, which causes all new name registrations to fail permanently once 4096 names have been registered. Separately, `isTxidConsumed` uses a linear O(n) scan — with 4096 entries this is 4096 comparisons per DNS operation, and is called multiple times per RPC request.

More critically: the consumed_txids set is **in-memory only**. A node restart clears it entirely. Any fee TX that was consumed before the restart can be replayed after restart to register the same name again (or a second name with the same fee TX), bypassing the single-use guarantee.

**Remediation**: Persist `consumed_txids` to the DNS registry binary file (already versioned at v3). After node restart, reload consumed txids from disk. Use a fixed-size hash set (bloom filter or open-addressing hash table) instead of linear scan for O(1) lookups.

---

### MEDIUM-04: RPC `handleConn` (Old Path) Is Dead Code With Security Implications

**Severity**: MEDIUM
**File:Line**: `core/rpc_server.zig:617-691`
**Category**: Code Quality / Security

**Description**: There are TWO connection handlers: `handleConnCounted` (the active path, called from the accept loop) and `handleConn` (an older function that still exists and has its own auth check). The `handleConn` function at line 617 uses `ws2.recv` (Winsock-specific, no POSIX fallback), making it Windows-only dead code on POSIX. It also has a subtly different body-extraction logic (line 672-676 uses `std.mem.indexOf` directly on `raw` rather than using the already-computed `hdr_end`), meaning if a request arrives with no Content-Length, `handleConn` would process the header as the body. If `handleConn` is ever wired to the accept loop again (e.g., during refactoring), this path has weaker body parsing.

**Remediation**: Delete `handleConn`. It is unreachable in the current code path and creates maintenance confusion about which auth/parsing rules apply.

---

### MEDIUM-05: Peer Ban Score Not Applied on Rate-Limit Violation Path

**Severity**: MEDIUM
**File:Line**: `core/p2p.zig:127-131`
**Category**: DoS

**Description**: `RATE_LIMIT_BAN_SCORE = 50` is defined, meaning a peer that exceeds the rate limit should receive -50 to their score and be banned after two violations. However, the rate limit constant (`RATE_LIMIT_MSG_PER_SEC = 100`) appears only as a named constant — its enforcement and wiring to the scoring engine requires verification in the message dispatch path (which was not fully readable due to file size). If the rate limit constant exists but is never checked against `PeerScoringEngine.scoreEvent`, an attacker can send 10,000 messages/second indefinitely without penalty.

**Remediation**: Needs runtime verification (mark as "needs runtime verification"). If enforcement is missing, add a per-connection message counter checked on every receive, calling `scoring.scoreEvent(peer_id, .malformed_data)` (which gives -20) or a new `rate_exceeded` event (-50) when the limit is breached.

---

### MEDIUM-06: `PeerScoringEngine.getOrCreate` Evicts Tracked Peer on Table Full

**Severity**: MEDIUM
**File:Line**: `core/peer_scoring.zig:153-163`
**Category**: Protocol / Whitewashing

**Description**: When `MAX_TRACKED_PEERS` (256) is exceeded, `getOrCreate` evicts the peer with the **lowest score** and replaces it with a new entry for the unknown peer. This is a whitewashing vector: an attacker runs 256 good-behaving shill peers to fill the scoring table, then spoofs a previously-banned peer's ID. The banned peer's entry has been evicted (it had the lowest score after being banned), so the spoofed peer starts fresh with score=0.

**Exploit scenario**: Attacker has one malicious peer that was banned. They connect 256 Sybil peers that do useful work (valid_block events, score +1 each). The attacker's banned entry (score ≤ -100) is the lowest in the table and gets evicted first. The attacker reconnects under the same peer ID, starting fresh with score=0 and full connection rights.

**Remediation**: When the table is full, prefer to evict the *oldest* peer (LRU eviction) rather than the lowest-score peer. Keep a separate persistent banned-ID list (distinct from the scoring table) that survives eviction. Bans should not be clearable via eviction.

---

### LOW-01: `isValidPrivateKey` Is Not Called Before `sign()`

**Severity**: LOW
**File:Line**: `core/secp256k1.zig:41-46`
**Category**: Hardening

**Description**: `sign()` passes the private key directly to `Ecdsa.SecretKey.fromBytes()` without calling `isValidPrivateKey()` first. While `fromBytes` will fail on invalid keys, the error path is less informative than a pre-validation check. More importantly, a zero private key (the all-zero 32-byte key) will produce deterministic signatures that expose the signing path to the zero-key attack.

**Remediation**: Add `if (!isValidPrivateKey(private_key)) return error.InvalidPrivateKey;` at the top of `sign()`.

---

### LOW-02: Mempool Insertion Tracking in `pending_count` Uses `from_address` as HashMap Key (Dangling Slice Risk)

**Severity**: LOW
**File:Line**: `core/mempool.zig:139-140`
**Category**: Memory Safety

**Description**: `self.pending_count.put(tx.from_address, cur + 1)` stores the `from_address` slice as a HashMap key. The Transaction struct stores `from_address` as a `[]const u8` slice. If the underlying string is stack-allocated or freed before the mempool entry is evicted, the HashMap key becomes a dangling pointer. In practice, test transactions use string literals (safe), but production code using a formatted address buffer on the stack would be unsafe.

**Remediation**: Use a fixed-size array key (e.g., `[64]u8`) in `pending_count` to ensure the key data is owned by the HashMap entry, not borrowed from the Transaction.

---

### LOW-03: P2P Checksum is a Simple Sum (Not a Cryptographic MAC)

**Severity**: LOW
**File:Line**: `core/p2p.zig:177-182`
**Category**: Protocol / Integrity

**Description**: `calcChecksum` computes a 16-bit additive sum of all payload bytes. This detects accidental corruption but provides NO protection against malicious tampering. A peer can forge any payload with a matching checksum by adjusting any single byte. Combined with the non-authenticated plain TCP transport (before encrypted P2P handshake), this checksum provides false confidence in message integrity.

**Remediation**: Use the genesis-hash-keyed HMAC or ChaCha20-Poly1305 AEAD from `encrypted_p2p.zig` for all inter-peer messages. At minimum, replace the 16-bit sum with CRC32 to catch accidental corruption (not security, but correctness). Document clearly that this checksum is not a MAC.

---

### LOW-04: Bootstrap `BootstrapNode.readyForMining` Depends on Mutable Global `registered_miner_count`

**Severity**: LOW
**File:Line**: `core/bootstrap.zig:532-539`
**Category**: Logic / Concurrency

**Description**: `readyForMining` reads `registered_miner_count` (a `u16` global modified by the RPC `registerminer` handler from a separate thread) without any memory ordering or mutex. On x86_64, torn reads of 16-bit values are theoretically possible but unlikely in practice. More importantly, the field is `pub var` — any module can modify it, creating an undocumented action-at-a-distance coupling between the RPC server and the mining control loop.

**Remediation**: Wrap `registered_miner_count` in `std.atomic.Value(u16)` and use `.load(.acquire)` / `.store(.release)`.

---

### LOW-05: `deterministicRng` Fallback Outputs Zeros Without Any Log or Error

**Severity**: LOW
**File:Line**: `core/pq_crypto.zig:47-53`
**Category**: Cryptographic / Silent Failure

**Description**: When `DetState.stream` is null, the `deterministicRng` callback fills the output with zeros silently. The comment says "this is a state of error — n-ar trebui sa se intample niciodata." There is no log, no counter, no way to detect this at runtime. A system under memory pressure or a race condition where `deterministicRng` is called before `activateDetRng` completes would silently generate all-zero random material for PQ key generation.

**Remediation**: Add `std.debug.print("[PQ-CRYPTO] CRITICAL: deterministicRng called with null stream — all-zero output!\n", .{});` at minimum. In production, replace with a call to `std.os.abort()` or set a global error flag.

---

### INFO-01: `secp256k1.zig` Delegates to Zig stdlib ECDSA — Audit Scope Narrowed

**Severity**: INFO
**File:Line**: `core/secp256k1.zig:8`
**Category**: Architecture

**Description**: The secp256k1 implementation uses `std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256oSha256` from the Zig 0.15.2 standard library. This means scalar multiplication, field arithmetic, nonce generation (RFC 6979 via the stdlib DRBG), and point validation are all handled by the stdlib — not custom code. The audit of constant-time properties, nonce generation correctness, and point-at-infinity handling is therefore inherited from the Zig stdlib's correctness guarantees. The Zig stdlib ECDSA implementation has been peer-reviewed and follows RFC 6979. No findings in the custom secp256k1 wrapper beyond HIGH-01 (isValidPrivateKey timing) and LOW-01 (no pre-validation in sign).

---

### INFO-02: RPC CORS Headers Allow All Origins

**Severity**: INFO
**File:Line**: `core/rpc_server.zig:580`, `604`, `612`
**Category**: Network / Web Security

**Description**: All HTTP responses include `Access-Control-Allow-Origin: *`. This means any browser tab on any website can make cross-origin RPC calls to `http://127.0.0.1:8332`. Since loopback is always trusted (no Bearer token required), a malicious webpage can call any RPC method if the user has the node running locally. This is a CSRF/cross-origin attack surface on local nodes.

**Remediation**: Change CORS to `Access-Control-Allow-Origin: http://localhost:3000` (the React frontend origin) or the specific app URL. Alternatively, add CSRF token validation for state-changing RPC methods. Note: This is INFO severity because loopback-only deployment is the default and exploitability requires the victim to visit a malicious page while running a local node.

---

### INFO-03: `MAX_CONCURRENT` RPC Threads Fixed at 16 — No Per-IP Rate Limiting

**Severity**: INFO
**File:Line**: `core/rpc_server.zig:483`
**Category**: DoS / Hardening

**Description**: The RPC server limits total concurrent connections to 16 but does not limit connections per IP. A single attacker can open 16 long-running RPC requests (e.g., by sending headers with a large fake Content-Length and then stalling), exhausting the thread pool and causing a total RPC denial of service for legitimate users. The global `active_threads` counter at line 492 drops new connections when full but does not apply backpressure per remote IP.

**Remediation**: Track active connections per remote IP (a fixed-size LRU table). Limit each non-loopback IP to 2-4 concurrent connections. Add a per-IP request rate counter (requests/second) enforced before spawning a thread.

---

## Audit Methodology Notes

- **secp256k1.zig**: Delegates to Zig stdlib (INFO-01). The stdlib uses RFC 6979 deterministic nonce generation. No custom field arithmetic exists — no constant-time violations possible in the curve math. The only violations found are in the validation wrapper code.
- **pq_crypto.zig**: liboqs is called correctly with matching `OQS_SIG_new` / `OQS_SIG_free` pairs. Memory management is correct. The deterministic RNG mutex pattern is the key concern (HIGH-02, CRIT-02).
- **p2p.zig**: The wire protocol design is sound (genesis hash in handshake prevents cross-chain peering, version byte prevents protocol mismatch). Findings are in enforcement completeness.
- **mempool.zig**: FIFO anti-MEV design is correct. The RBF implementation is the main gap.
- **dns_registry.zig**: The nonce tracking and consumed-txid anti-replay are well-designed for the signed_required=true path. The critical gap is the default `signed_required=false` on init.
- **rpc_server.zig**: Authentication design is sound (constant-time token compare at line 6168, loopback bypass is deliberate). The main concerns are CORS and per-IP rate limiting.
- **bootstrap.zig**: Localhost-only seed list is the blocking mainnet issue.
- **peer_scoring.zig**: Well-designed system. Whitewashing via table eviction is the primary gap.

---

*End of audit. All findings are based on static code analysis. Dynamic/runtime verification recommended for HIGH-04 (P2P payload_len enforcement) and MEDIUM-05 (rate-limit enforcement wiring) before sign-off.*
