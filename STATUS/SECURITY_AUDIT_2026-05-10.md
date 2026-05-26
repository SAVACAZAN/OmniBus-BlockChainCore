# OmniBus BlockChainCore - Security Audit Report v4
**Date**: 2026-05-10 | **Pass**: 4 of N | **Auditor**: blockchain-security-auditor agent

## Carried-Forward Findings

| ID | Status | Severity | File | Notes |
|----|--------|----------|------|-|
| SEV-01 | OPEN | HIGH | rpc_server.zig:7215 | std.mem.eql used; constantTimeEql at :7186 not called |
| SEV-03 | OPEN | HIGH | mempool.zig:541-570 | replaceByNonce skips self.verifier |
| SEV-04 | OPEN | HIGH | key_encryption.zig:165-169 | verifyPassword is length-check stub |
| SEV-11 | OPEN | HIGH | price_oracle.zig:221-250 | submitPrice stores sig but never verifies |
| SEV-09 | OPEN | MEDIUM | rpc_server.zig:722-738 | No SO_RCVTIMEO on accepted sockets |
| SEV-02 | FIXED | HIGH | p2p.zig | Eclipse per-subnet limits corrected in v2 |

## New Findings

### [NEW-01] CRITICAL - encrypted_p2p.zig:62-86 - Broken ECDH (HMAC not scalar-multiply)
Implementation uses HMAC(local_privkey, remote_pubkey) instead of EC scalar multiply.
Alice and Bob derive different session keys; all AES-GCM decrypts fail. No forward secrecy.
Tests mask this at lines 166-168 by manually assigning bob_session.recv_key = alice.send_key.
Fix: secp256k1 scalar_multiply(local_privkey, remote_pubkey_point) + SHA256 + HKDF.
Remove manual key-copy from tests.

### [NEW-02] HIGH - governance.zig:200-219 - No per-voter deduplication
vote() accepts voting_power with no record of who voted. VoteRecord struct never stored/checked.
Call vote() twice with maxInt(u64)/2 -> votes_yes overflows -> tallyResult returns Approved instantly.
Any proposal (ProtocolUpgrade, Emergency freeze) passable by one attacker.
Fix: per-proposal voted-address set; require signed on-chain tx.

### [NEW-03] HIGH - finality.zig:157-201 - Attestation voting_power not bounded by stake
attest() blindly adds caller-supplied voting_power. hasSupermajority = attested*3 >= total*2.
Any registered validator submits power=total_voting_power -> epoch justified -> parent irreversibly finalized.
Fix: look up validator in staking registry; cap at validator total_stake; reject if exceeded.

### [NEW-04] HIGH - sync.zig:466-514 - applyBlock skips PoW validation
Only checks sequential height and timestamp > 0. No prev_hash link check, no PoW difficulty check.
Malicious sync peer feeds 10k fake headers -> victim chain replaced with zero-difficulty work.
Fix: verify prev_hash == local tip hash; verify header hash meets difficulty; reject timestamp drift > 7200s.

### [NEW-05] MEDIUM - staking.zig:401-417 - selectProposer stake grinding
Seed = block_hash[0..8] as u64. Miner controls nonce -> block hash -> proposer selection.
Validator with 5% stake and 20% hashrate can inflate selection to 20%.
Fix: commit-reveal VRF or RANDAO-style accumulated entropy.

### [NEW-06] MEDIUM - staking.zig:496-523 - verifyDoubleSign accepts any non-zero sig bytes
Comment at lines 517-520 explicitly omits secp256k1 verification. Any 64 non-zero bytes pass.
Attacker submits fabricated SlashEvidence; target validator loses 33% stake (attacker gains 10%).
Fix: Secp256k1Crypto.verify(sig, block_hash, validator_pubkey) for both sigs; reject if either fails.

### [NEW-07] MEDIUM - ws_server.zig:130-173 - No WebSocket client connection limit
acceptLoop spawns unlimited threads. No MAX_CLIENTS. No Origin header check.
Bot opens 65535 connections -> OOM / OS thread limit crash.
Fix: const MAX_WS_CLIENTS: usize = 64; reject when exceeded.

### [NEW-08] MEDIUM - ws_server.zig:233-249 - WS frame parser breaks on extended-length frames
Extended length bytes read and discarded, then reads pay_len (126/127) bytes - wrong length.
frame_buf only 128 bytes. Any browser message >= 126 bytes corrupts frame stream.
Fix: decode extended payload length per RFC 6455 section 5.2; increase frame_buf.

### [NEW-09] MEDIUM - ws_server.zig:269-290 - removeClient use-after-free race (self-documented)
stream.close() and connected=false called before acquiring srv.mutex. broadcastTopic checks
connected and calls sendText under lock -> UAF on WsClient struct.
Fix: acquire mutex first; build send-list under lock; send outside lock.

### [NEW-10] LOW - kademlia_dht.zig:183-190 - total_peers double-counts on updates
KBucket.addPeer returns true for both new additions AND updates. total_peers grows unboundedly.
Fix: return tagged union {.added,.updated,.rejected}; increment total_peers only on .added.

### [NEW-11] MEDIUM - transaction.zig:319-424 - calculateHash omits chain_id (cross-network replay)
No chain_id in hash pre-image. Testnet tx has identical hash and valid sig on mainnet.
Pre-EIP-155 class attack: attacker replays testnet tx on mainnet, drains same-key wallets.
Fix: include chain_id in calculateHash; validate at acceptance time.

### [NEW-12] LOW - tor_proxy.zig:30-58 - DNS leak prevention declared but not enforced
TorConfig.dns_through_tor = true is a flag with no enforcement code anywhere.
OS resolver used for seed hostnames -> real IP exposed even in Tor mode.
Fix: SOCKS5_ATYPE_DOMAIN for all peer lookups when Tor enabled; audit bootstrap.zig + p2p.zig.

### [NEW-13] MEDIUM - ws_server.zig:646-697 - wsHandshake no read timeout (slow-read DoS)
Reads until CRLFCRLF with no socket timeout. 1 byte/sec attacker holds thread 2048 seconds.
100 attackers x 8MB thread stack = 800MB; node unresponsive.
Fix: SO_RCVTIMEO = 5s on accepted socket before wsHandshake.

## Summary Table

| ID | Severity | Category | File | Status |
|----|----------|----------|------|--------|
| SEV-01 | HIGH | Timing | rpc_server.zig:7215 | OPEN |
| SEV-03 | HIGH | Logic | mempool.zig:541-570 | OPEN |
| SEV-04 | HIGH | Logic | key_encryption.zig:165-169 | OPEN |
| SEV-11 | HIGH | Crypto | price_oracle.zig:221-250 | OPEN |
| SEV-09 | MEDIUM | DoS | rpc_server.zig:722-738 | OPEN |
| NEW-01 | CRITICAL | Crypto | encrypted_p2p.zig:62-86 | NEW |
| NEW-02 | HIGH | Logic | governance.zig:200-219 | NEW |
| NEW-03 | HIGH | Logic | finality.zig:157-201 | NEW |
| NEW-04 | HIGH | Protocol | sync.zig:466-514 | NEW |
| NEW-05 | MEDIUM | Logic | staking.zig:401-417 | NEW |
| NEW-06 | MEDIUM | Crypto | staking.zig:496-523 | NEW |
| NEW-07 | MEDIUM | DoS | ws_server.zig:130-173 | NEW |
| NEW-08 | MEDIUM | Protocol | ws_server.zig:233-249 | NEW |
| NEW-09 | MEDIUM | Logic/DoS | ws_server.zig:269-290 | NEW |
| NEW-10 | LOW | Logic | kademlia_dht.zig:183-190 | NEW |
| NEW-11 | MEDIUM | Protocol | transaction.zig:319-424 | NEW |
| NEW-12 | LOW | Protocol | tor_proxy.zig:30-58 | NEW |
| NEW-13 | MEDIUM | DoS | ws_server.zig:646-697 | NEW |

## Top Fixes Before Mainnet

1. NEW-01 CRITICAL - encrypted_p2p.zig:68: Real secp256k1 scalar multiply (not HMAC). Tests mask bug.
2. NEW-04 HIGH - sync.zig:484-509: prev_hash link + PoW difficulty + timestamp drift checks.
3. NEW-03 HIGH - finality.zig:181: Cap voting_power against staking registry.
4. NEW-02 HIGH - governance.zig:208-219: Per-voter deduplication.
5. SEV-01 HIGH - rpc_server.zig:7215: One-line fix; constantTimeEql already at :7186.
6. SEV-04 HIGH - key_encryption.zig:165-169: Implement real PBKDF2 in verifyPassword.
7. SEV-03 HIGH - mempool.zig:541: Call self.verifier in replaceByNonce.
8. SEV-11 HIGH - price_oracle.zig:221-250: Verify secp256k1 sig on each MinerPriceSubmission.
9. NEW-06 MEDIUM - staking.zig:496-523: Real secp256k1 verify in verifyDoubleSign.
10. NEW-11 MEDIUM - transaction.zig:319: Mix chain_id into calculateHash pre-image.
11. NEW-07+NEW-13 MEDIUM - ws_server.zig: MAX_WS_CLIENTS cap + SO_RCVTIMEO = 5s.
12. SEV-09 MEDIUM - rpc_server.zig:722: SO_RCVTIMEO on accepted RPC sockets.
