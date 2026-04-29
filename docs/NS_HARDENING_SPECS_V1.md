# OmniBus NS Hardening — v1 Specs

Authored 2026-04-29. Source of truth for the NS rewrite. Implementer (Kimi or Claude) **must not deviate** without amending this doc first.

## Goals

Add to the existing `dns_registry.zig` the same security patterns the exchange already enjoys (signed canonical messages + HMAC REST bypass + on-disk audit log), so an institutional KYC-only chain can:

1. Prove that every NS state change was authorized by the holder of the private key matching the on-chain owner address — **no impostor registration, transfer, or update**.
2. Enforce realistic name lifecycle: registrations expire, owners renew, premium names cost more, reserved names cannot be squatted.
3. Hand a regulator a tamper-evident append-only audit trail of every NS operation.

## Non-goals (Phase 1)

- Multisig owners (Phase 3)
- Freezable names (Phase 3)
- ZK-attested KYC tied to NS (Phase 4)
- Auctions / commit-reveal / front-running protection (post-Phase 1)

## Source of truth — files to read first

- `core/dns_registry.zig` — current registry storage + `registerWithTldAndFee` + `consumed_txids`
- `core/rpc_server.zig:1358-1361` — current 4 NS RPCs
- `core/rpc_server.zig:6269-6296` — `buildOrderSignMessage` / `buildCancelSignMessage` — canonical message format pattern (mimic exactly)
- `core/rpc_server.zig:6300-6321` — pubkey → ob1q address derivation + `verifyPayloadSignature`
- `core/rpc_server.zig:7124-7203` — `handleExchangeGetAuthNonce` / `handleExchangeLogin` / `handleExchangeCreateApiKey` — REST HMAC pattern with `REST_HMAC_BYPASS` sentinel for the `signature` field
- `core/secp256k1.zig` — Secp256k1Crypto.verify
- `core/registrar_addresses.zig` — reserved names tied to registrar slots (genesis-protected)

## Canonical messages

All four payloads use the same SHA256d + secp256k1 ECDSA + low-S + 33-byte compressed pubkey contract as the exchange. Lines are joined with `\n`. **No trailing newline.** UTF-8 bytes only.

### DNS_REGISTER_V1

```
DNS_REGISTER_V1
<name>
<tld>
<address>
<owner>
<nonce>
```

Fields:
- `name` — lowercase a-z 0-9 _, 3..25 chars, must start with a-z
- `tld` — `omnibus` or `arbitraje`
- `address` — bech32 ob1q… (the resolve target, may equal owner)
- `owner` — bech32 ob1q… (signer, becomes registry owner)
- `nonce` — u64, monotonically increasing per-owner (server tracks last-seen)

The signer must be the holder of `owner`. Server verifies `pubkey → hash160 → bech32("ob", 0, h160) == owner`. Mismatch ⇒ -32602 `signing pubkey does not match owner address`.

### DNS_TRANSFER_V1

```
DNS_TRANSFER_V1
<name>
<tld>
<new_owner>
<nonce>
```

Signer must be the **current owner** at time of transfer. The new owner does not need to sign (one-sided transfer, identical to ENS).

### DNS_UPDATE_V1

Updates the resolve target (`address` field) without changing ownership.

```
DNS_UPDATE_V1
<name>
<tld>
<new_address>
<nonce>
```

Signer must be the current owner.

### DNS_RENEW_V1

Extends `expires_block` by `RENEWAL_PERIOD_BLOCKS` (~1 year). Owner must sign and either pay the per-TLD fee on mainnet (same `fee_txid` flow as register) or pay nothing on testnet.

```
DNS_RENEW_V1
<name>
<tld>
<nonce>
```

Signer must be the current owner. After grace period (30 days = 2_592_000 blocks at 1s/block), name is auctionable; renewal during grace is allowed but doesn't reset the start of the grace window.

## DnsEntry — v2 fields (additive only — preserves Phase 1 binary compat for existing entries)

Add to `DnsEntry`:

| Field | Type | Notes |
|---|---|---|
| `last_nonce` | u64 | Last accepted nonce for this owner+name pair. Reject `nonce <= last_nonce`. Init to 0 on register. |
| `last_action_block` | u64 | Block height of last register/transfer/update/renew. |
| `grace_until_block` | u64 | `expires_block + 2_592_000`. Zero = no grace (unset for legacy v1 entries). |

Existing `expires_block` already exists. New entries set `expires_block = registered_block + RENEWAL_PERIOD_BLOCKS`. Legacy entries (loaded from old `dns_registry.bin`) keep their pre-v2 values; the registry treats them as renewable but does not enforce signed-only register on them retroactively.

## Reserved names

Hardcoded list; extensible by editing the array. **Reservation = name is reserved across ALL TLDs.**

```zig
// dns_registry.zig
pub const RESERVED_NAMES = [_][]const u8{
    // OmniBus / ecosystem self-references
    "omnibus", "omni", "blockchain", "satoshi", "nakamoto",
    "exchange", "wallet", "node", "miner", "validator", "treasury",
    "admin", "root", "system", "api", "support",
    // Top global brands (start small — easy to extend without forking)
    "google", "apple", "microsoft", "amazon", "meta", "facebook",
    "tesla", "spacex", "twitter", "x", "openai", "anthropic",
    "binance", "coinbase", "kraken", "uniswap", "metamask", "ledger",
    "ethereum", "bitcoin", "solana", "polygon", "arbitrum", "base",
    "lcx", "liberty",
    // Stablecoins / financial
    "usdc", "usdt", "dai", "tether", "circle",
    "visa", "mastercard", "paypal", "stripe",
    // Add more as needed.
};
```

Plus the `registrar_addresses.zig` reservations are still authoritative (slot-tied). `isReservedName(name)` returns true if EITHER list contains `name`.

## Premium pricing — anti-squatting

Replace the flat `feeForTld(tld)` with a 2D function `feeForName(name, tld)`:

```zig
pub fn feeForName(name: []const u8, tld: []const u8) u64 {
    const base = feeForTld(tld); // 5_000_000_000 omnibus, 10_000_000_000 arbitraje
    return switch (name.len) {
        1 => base * 200,    // 1 char = 1000 OMNI on .omnibus
        2 => base * 100,    // 2 chars = 500 OMNI
        3 => base * 20,     // 3 chars = 100 OMNI
        4 => base * 4,      // 4 chars = 20 OMNI
        else => base,       // 5+ chars = base fee (5 OMNI)
    };
}
```

But: current `MIN_NAME_LEN = 3`. So 1- and 2-char branches are dormant unless we lower the floor. Keep them — future-proof if we open shorter names as auctions.

## Per-owner cap — anti-hoarding

```zig
pub const MAX_NAMES_PER_OWNER: usize = 10;
```

Walk `entries[]`, count active non-expired with matching owner. If `>= MAX`, reject register / transfer-in.

Exempt: registrar slot owners (savacazan, faucet, etc.) — they need many names by design.

## Audit log

Append-only line-delimited JSON file at `data/<chain>/dns_audit.log`. Every successful state change writes one line; failed verifies are NOT logged here (they're already in stderr).

```jsonl
{"ts":1714400000,"block":64132,"op":"register","name":"alice","tld":"omnibus","address":"ob1q…","owner":"ob1q…","nonce":1,"signer_pubkey":"02a1…","signature":"abcd…","fee_paid_sat":5000000000,"fee_txid":"…64hex…"}
{"ts":1714400060,"block":64133,"op":"transfer","name":"alice","tld":"omnibus","old_owner":"ob1q…","new_owner":"ob1q…","nonce":2,"signer_pubkey":"02a1…","signature":"abcd…"}
{"ts":1714400120,"block":64134,"op":"update","name":"alice","tld":"omnibus","old_address":"ob1q…A","new_address":"ob1q…B","nonce":3,"signer_pubkey":"02a1…","signature":"abcd…"}
{"ts":1714400180,"block":64135,"op":"renew","name":"alice","tld":"omnibus","new_expires_block":95689760,"nonce":4,"signer_pubkey":"02a1…","signature":"abcd…","fee_paid_sat":5000000000,"fee_txid":"…64hex…"}
```

Writer: open in append mode + line buffer + flush per write. **Never truncate.** Rotation is operator's job (logrotate config).

## RPC surface — JSON-RPC

Existing 4 stay. Add 3 new methods:

```
transfername(name, tld, new_owner, nonce, signature, publicKey)
  → { name, tld, old_owner, new_owner, transferredAtBlock }
  Errors:
    -32602 Missing param X
    -32400 Name not found
    -32401 Signing pubkey does not match current owner
    -32402 Nonce too low (replay)
    -32403 Per-owner cap exceeded for new_owner

updatename(name, tld, new_address, nonce, signature, publicKey)
  → { name, tld, old_address, new_address, updatedAtBlock }
  Same -3240x errors.

renewname(name, tld, nonce, signature, publicKey, fee_txid?)
  → { name, tld, old_expires_block, new_expires_block, fee_paid_sat }
  -32602 / -32401 / -32402, plus -32031 fee TX invalid (mainnet only).
```

`registername` keeps current 5 positional params for backward compat BUT new params 5-7 added: `nonce`, `signature`, `publicKey`. When `signature == ""` (or absent) AND `fee_enforcement == false`, registry runs in legacy permissionless mode (testnet bootstrap). Once `fee_enforcement` flips on, signature becomes mandatory. `REST_HMAC_BYPASS` sentinel works the same as in PlaceOrder for REST clients with valid HMAC.

## REST surface — Kraken-style

After the existing `/exchange/0/...` and `/paper/0/...`, add `/dns/0/...`:

```
GET  /dns/0/public/Resolve?name=alice&tld=omnibus
GET  /dns/0/public/ReverseLookup?address=ob1q…
GET  /dns/0/public/List?offset=0&limit=50
POST /dns/0/private/Register      { name, tld, address, owner, nonce, signature, publicKey, fee_txid? }
POST /dns/0/private/Transfer      { name, tld, new_owner, nonce, signature, publicKey }
POST /dns/0/private/Update        { name, tld, new_address, nonce, signature, publicKey }
POST /dns/0/private/Renew         { name, tld, nonce, signature, publicKey, fee_txid? }
```

Private methods accept `signature: "REST_HMAC_BYPASS"` plus a valid HMAC-SHA512 header per the existing exchange flow. OpenAPI spec must be auto-extended at `/openapi.json` and `/swagger-ui` reflects automatically.

## Test plan — pattern

Place new tests in `core/dns_registry_test.zig` (new file) AND extend `tests/rpc/dns_test.zig` (or create if missing). One canonical test:

```zig
// core/dns_registry_test.zig — Phase 1 acceptance test (Claude-authored, Kimi extends)
const std = @import("std");
const dns = @import("dns_registry.zig");
const sig_mod = @import("secp256k1.zig");
const rpc = @import("rpc_server.zig");

test "DNS_REGISTER_V1 — happy path: matching pubkey, monotonic nonce, audit line written" {
    var reg = dns.DnsRegistry.init();

    const priv = [_]u8{0x42} ** 32;
    const pub_compressed = try sig_mod.Secp256k1Crypto.privateKeyToPublicKey(priv);
    // Address = bech32(hash160(pub_compressed))
    var addr_buf: [64]u8 = undefined;
    const owner_addr = try rpc.deriveOBAddressFromPubkey(pub_compressed, std.testing.allocator);
    defer std.testing.allocator.free(owner_addr);

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf,
        "DNS_REGISTER_V1\nalice\nomnibus\n{s}\n{s}\n1",
        .{ owner_addr, owner_addr });

    const sig = try sig_mod.Secp256k1Crypto.sign(priv, msg);

    // Server-side verify path
    const valid = sig_mod.Secp256k1Crypto.verify(pub_compressed, msg, sig);
    try std.testing.expect(valid);

    // Apply to registry
    try reg.registerWithTld("alice", "omnibus", owner_addr, owner_addr, 100);
    const resolved = reg.resolveWithTld("alice", "omnibus", 100);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings(owner_addr, resolved.?.getAddress());
}
```

Kimi extends with: tampered signature rejected, pubkey-vs-owner mismatch rejected, replay (nonce reuse) rejected, transfer requires current owner, update requires current owner, renew extends expiry, renewing during grace works, renewing after grace+expiry works, reserved name rejected, premium fee scaling, per-owner cap, audit line format check, REST HMAC path, etc. ~16-20 tests total.

## Migration

Phase 1 deploy:
1. `dns_registry.bin` v2 layout adds 3 trailing fields per entry (24 extra bytes). Loader detects file version (current = no version byte, treat as v1, fill new fields with defaults: `last_nonce=0`, `last_action_block=registered_block`, `grace_until_block=expires_block+grace`).
2. Save in v2 format always.
3. Audit log bootstraps empty.
4. Testnet wipe acceptable per user direction (zero real users).

Mainnet:
- Set `dns.fee_enforcement = true` AND `dns.signed_required = true` simultaneously at activation block. Pre-activation entries grandfathered (signature optional for read-only resolves; signed required for any state change going forward).

## Out of scope this phase

| Feature | Phase | Why deferred |
|---|---|---|
| Multisig owners (M-of-N) | 3 | Wire format change; needs MuSig2 |
| Frozen names (regulator) | 3 | Politically sensitive — needs governance design |
| Time-locked recovery | 3 | Needs robust on-chain clock + cancel logic |
| ZK-KYC attestation | 4 | Library not present (need arkworks/halo2); months of work |
| Vickrey auction for premium | post-Ph1 | UX heavy, low priority pre-launch |
| Commit-reveal anti-front-run | post-Ph1 | Low ROI under KYC threat model |

## Acceptance criteria

- [ ] All canonical messages defined match this doc exactly (code + tests + docs)
- [ ] `transfername` / `updatename` / `renewname` JSON-RPC + REST handlers compile and pass tests
- [ ] `registername` accepts both legacy (no sig) AND signed paths during testnet, mandates sig when `signed_required`
- [ ] Reserved names list rejected with `-32601 Reserved name`
- [ ] Premium pricing applied per `feeForName(name, tld)`
- [ ] Per-owner cap of 10 enforced (registrar slots exempt)
- [ ] `dns_audit.log` written line-per-op, format matches spec
- [ ] OpenAPI spec auto-includes new methods
- [ ] Test count ≥ 16, all pass, zero leaks
- [ ] Build clean, `zig build test` exits 0
