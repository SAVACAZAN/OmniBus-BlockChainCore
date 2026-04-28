# OmniBus Chain Constants — Reference

**Verified against source 2026-04-27.** Use these exact values when writing scripts,
agents, or UI. Don't guess.

## Money

| Constant | Value | Source | Note |
|---|---|---|---|
| `1 OMNI` | `1_000_000_000 SAT` | Genesis spec | 1e9, NOT 1e8 like Bitcoin |
| `MAX_SUPPLY_SAT` | `21_000_000_000_000_000` | `consensus_pouw.zig:40` | 21M OMNI cap |
| `INITIAL_BLOCK_REWARD_SAT` | `50_000_000_000` | `consensus_pouw.zig:32` | 50 OMNI/block initial |
| `HALVING_INTERVAL` | `210_000` blocks (PoUW) | `consensus_pouw.zig:33` | Bitcoin-style halvings |
| Effective reward (post-halvings) | `~0.0083 OMNI` | live testnet | ≈8.3M SAT after many halvings |

## Transaction limits

| Constant | Value | Source | Behavior |
|---|---|---|---|
| `DUST_THRESHOLD_SAT` | `100` | `blockchain.zig:43` | TX with `amount < 100 SAT` rejected (unless OP_RETURN) |
| `TX_MIN_FEE_SAT` | `1` | `mempool.zig:12` | TX with `fee < 1 SAT` rejected |
| `MAX_OP_RETURN` | `80` bytes | `transaction.zig:44` | OP_RETURN payload cap |
| `op_return TX with amount=0` | allowed | `transaction.zig:122` | Only if `op_return.len > 0` |
| Address prefix | `ob1q` (SegWit v0), `ob1p` (Taproot) | `transaction.zig:48` | Bech32 / Bech32m |

## Block timing

| Constant | Value | Source |
|---|---|---|
| Block time target | `1s` (with sub-blocks 0.1s) | `genesis.zig`, parent `CLAUDE.md` |
| Sub-blocks per block | `10` | `genesis.zig` |
| Live testnet observed | `~3.1s/block` | `getperformance` 2026-04-27 |

## Faucet (testnet only)

| Constant | Value | Source |
|---|---|---|
| `FAUCET_IP_COOLDOWN_S` | `60` | `rpc_server.zig:791` |
| `FAUCET_MAX_CLAIMED_ADDRS` | `4096` | `rpc_server.zig:792` |
| Default grant | `100_000_000 SAT` (0.1 OMNI) | `node_launcher.zig:45` |
| Refill threshold | tracked per node | `main.zig` faucet refill loop |

## Staking (designed; not yet wired into consensus)

| Constant | Value | Source |
|---|---|---|
| `VALIDATOR_MIN_STAKE` | `100_000_000_000 SAT` (100 OMNI) | `staking.zig:18` |
| `MAX_VALIDATORS` | `128` | `staking.zig:21` |
| `UNBONDING_PERIOD` | `604_800` blocks (~7 days at 1s) | `staking.zig:24` |
| `SLASH_DOUBLE_SIGN_PCT` | `33%` | `staking.zig:41` |
| `SLASH_INVALID_BLOCK_PCT` | `10%` | `staking.zig:44` |
| `DOWNTIME_PENALTY_PCT` | `1%` | `staking.zig:47` |

## Networking

| Port | Purpose | Notes |
|---|---|---|
| `8332` | Mainnet RPC (HTTP JSON-RPC 2.0) | |
| `18332` | Testnet RPC | |
| `28332` | Regtest RPC | |
| `8334` | WebSocket (frontend events) | |
| `9000+` | P2P TCP | per-node configurable |
| Port `18333` | **NOT RPC** — likely P2P testnet | Don't use for RPC calls |

## Auth

| Variable | Value | Notes |
|---|---|---|
| `OMNIBUS_RPC_TOKEN` | 64-hex bearer | Required for non-loopback (VPS). Loopback (127.0.0.1) bypasses. |

See `~/.claude/...memory/reference_omnibus_vps_rpc_token.md` for the actual VPS token.

## UI display precision (frontend)

| Field | Format | Notes |
|---|---|---|
| OMNI amount | `toFixed(8)` | 9 decimals available (1e9), 8 chosen for Bitcoin-familiarity |
| `balanceOMNI` from RPC | `"0.000000000"` (9-decimal string) | `rpc_server.zig:427` formats `{d}.{d:0>9}` |

**Why 8 decimals matter:** at 4 decimals, a 9279-SAT balance shows as `0.0000` (looks
empty). At 8 decimals it shows `0.00000928` (clearly small but non-zero). Anything
below 100 SAT is dust and can't be sent anyway.

## Common gotchas

1. **DUST_THRESHOLD applies to `amount`, not `fee`.** A TX with `amount=99, fee=1` is
   rejected (dust amount). A TX with `amount=100, fee=1` is accepted.

2. **OP_RETURN TXs** can have `amount=0` AND `fee>=1`. They're metadata carriers,
   not payments — `to_address` is set but ignored at validation level.

3. **Nonce per address.** Every TX from address `A` must have `nonce = previous_nonce + 1`.
   Mempool rejects with "nonce conflict" if you reuse or skip. Use `getnonce` before
   each TX or maintain a local counter that never decrements.

4. **`sendtransaction` always signs with the node's primary wallet.** If you want to
   send from a different address, use `sendrawtransaction` with a client-side signed
   TX blob (see `transaction.zig:Transaction` schema).

5. **`balanceOMNI` from RPC is a STRING** (e.g., `"0.100024230"`), not a number. Don't
   `parseFloat` it for display — show the string directly to keep precision.

6. **Faucet cooldown is per-IP, not per-account.** Running 100 claims from one IP
   needs 60s × 100 = 100 min minimum. Multiple IPs (separate VPS) can parallelize.
