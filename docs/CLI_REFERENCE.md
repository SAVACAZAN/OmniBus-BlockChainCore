# omnibus-cli — Reference Manual

Pure-stdlib Zig binary that connects to a running OmniBus node via JSON-RPC HTTP
(8332 mainnet · 18332 testnet · 28332 regtest) and prints balance, stake,
reputation, daily breakdown and chain-vs-history sanity reports.

> **Source of truth:** `core/cli_audit.zig` (≈1200 lines). This document
> reflects the subcommands actually compiled into the v0.3.0-dev build. Newer
> versions may add subcommands; consult `omnibus-cli --help` for the live list.

---

## Synopsis

```
omnibus-cli [global flags] <subcommand> [args]
```

Exit codes:
- `0` — success
- `1` — RPC/parse error or sanity-check mismatch (`verify`)
- `2` — usage error (unknown command, missing address)

---

## Global Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--rpc <url>`     | `http://127.0.0.1:8332` | Override RPC URL. Accepts `http://host:port[/path]` or `https://...` (HTTPS routes through `curl`). |
| `--chain <c>`     | `mainnet` | Selects port: `mainnet`=8332, `testnet`=18332, `regtest`=28332. |
| `--remote`        | off | Use `https://omnibusblockchain.cc:8443/api-{chain}`. Requires `curl` in `PATH`. |
| `--token <bearer>`| none | Sets `Authorization: Bearer <token>` header. |
| `--json`          | off | Emit raw JSON-RPC response (no pretty-print). |
| `--no-color`      | off | Disable ANSI colors. (Auto-disabled when stdout is not a TTY.) |
| `-h`, `--help`    | — | Print usage and exit. |

### Endpoint resolution order

1. `--remote` → `https://omnibusblockchain.cc:8443/api-{chain}` (curl fallback)
2. `--rpc <url>` → parsed; `https://` triggers curl fallback
3. `--chain <c>` → maps to localhost port (8332/18332/28332)
4. Default → `127.0.0.1:8332`

---

## Environment Variables

The Zig binary itself reads no environment variables — all configuration is
passed via flags. However, the install scripts and shell completions honor:

| Variable | Used by | Description |
|----------|---------|-------------|
| `OMNIBUS_RPC_URL`  | shell wrappers / `~/.omnibus/cli.conf` | Default `--rpc` value. |
| `OMNIBUS_RPC_TOKEN`| shell wrappers / `~/.omnibus/cli.conf` | Default `--token` value. |
| `OMNIBUS_CHAIN`    | shell wrappers / `~/.omnibus/cli.conf` | Default `--chain` value (mainnet/testnet/regtest). |
| `OMNIBUS_MNEMONIC` | wallet-signing helpers (not used by audit-only CLI) | BIP-39 mnemonic for client-side signing flows. The current CLI is read-only and never reads this. |
| `NO_COLOR`         | (POSIX standard) | When set, completions and the wrapper add `--no-color`. |

> The current `omnibus-cli` binary is **read-only**: it only invokes RPC methods
> that query state. It never signs, broadcasts, or mutates the chain. There is
> therefore no `--yes` / `--mnemonic` consumption inside the binary itself.

---

## Subcommands — Chain Inspection

### `health`

Print chain stats (height, supply, mempool, peers, sync state).

**Synopsis:** `omnibus-cli health`

**RPC methods:** `getchainmetrics`, `getsyncstatus`

**Example (pretty):**
```
$ omnibus-cli health
=== Chain Health ===
Height:           4128931
Tip hash:         00000000000000000a3f7e...
Total supply:     243.0916 OMNI
Addresses w/bal:  812
Validators:       17
Mempool size:     3
Peers:            8
Block reward:     50.0000 OMNI
Sync status:      SYNCED (local=4128931 peer=4128931)
```

**Example (`--json`):**
```json
{"jsonrpc":"2.0","id":1,"result":{"height":4128931,"tipHash":"00000000...","totalSupply":243091600000,"addressesWithBalance":812,"validators":17,"mempoolSize":3,"peerCount":8,"currentBlockReward":50000000000}}
```

---

### `validators`

List all active validators with weight and entry block.

**Synopsis:** `omnibus-cli validators`

**RPC method:** `getvalidators`

**Example:**
```
$ omnibus-cli validators
=== Validators (3) ===
   1. ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0   weight=325    since_h=1820
   2. ob1q8x2v...                                   weight=100    since_h=2104
   3. ob1qpool...                                   weight=100    since_h=2750
```

---

### `stakers [limit]`

Top stakers sorted by amount (desc).

**Synopsis:** `omnibus-cli stakers [limit=10]`

**Args:** `limit` — integer 1..N (default 10)

**RPC method:** `getstakers`

**Example:**
```
$ omnibus-cli stakers 5
=== Top Stakers (limit 5) ===
   1. ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0   325.0000 OMNI
   2. ob1q8x2v...                                   100.0000 OMNI
   3. ob1qpool...                                   100.0000 OMNI
   4. ob1qmm01...                                    50.0000 OMNI
   5. ob1qmm02...                                    50.0000 OMNI
```

---

## Subcommands — Wallet & Balance

### `balance <addr>`

Full balance breakdown: wallet total, staked subset, available (= total − stake),
reputation tier and 4 cups (LOVE/FOOD/RENT/VACATION).

**Synopsis:** `omnibus-cli balance <addr>`

**Args:** `addr` — bech32 OmniBus address (`ob1q...`) or PQ prefix
(`obk1_`, `obf5_`, `obs3_`, `obd5_`).

**RPC methods:** `getbalance`, `getstake`, `getreputation`

**Example (pretty):**
```
$ omnibus-cli balance ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0
=== Balance: ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0 ===
Wallet:    1245.0000 OMNI
Staked:    325.0000 OMNI (active)
Available: 920.0000 OMNI

Reputation: 8421 / 1,000,000  Tier OMNI
  LOVE:     12.45 / 100
  FOOD:     8.10 / 100
  RENT:     0.00 / 100
  VACATION: 4.20 / 100
```

**Example (`--json`):**
```json
{"balance":{"jsonrpc":"2.0","id":1,"result":{"balance":1245000000000}},"stake":{"jsonrpc":"2.0","id":1,"result":{"stakes":[{"amount_sat":325000000000}]}},"reputation":{"jsonrpc":"2.0","id":1,"result":{"total":8421,"tier":"OMNI","cups":{"love":"12.45","food":"8.10","rent":"0.00","vacation":"4.20"}}}}
```

---

### `history <addr> [filter]`

Transaction history with optional kind filter. Capped at 200 rows.

**Synopsis:** `omnibus-cli history <addr> [filter]`

**Args:**
- `addr` — bech32 address.
- `filter` — one of: `all` (default), `stake`, `sent`, `received`, `mined`.
  - `stake` → `kind ∈ {stake, unstake}`
  - `sent` → `direction = sent`
  - `received` → `direction = received`
  - `mined` → `kind ∈ {coinbase, mined, block_reward}`

**RPC method:** `getaddresshistory`

**Example:**
```
$ omnibus-cli history ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0 mined
=== History: ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0 (filter=mined) ===
  block 4128812  coinbase   received  50.0000 OMNI  abcdef012345...
  block 4128744  coinbase   received  50.0000 OMNI  bcdef0123456...
  block 4128201  coinbase   received  50.0000 OMNI  cdef01234567...
```

---

## Subcommands — Stake & Validators

### `stake <addr>`

Current stake plus full activity log of `stake`/`unstake` transactions, ending
with a self-consistency check (running total vs chain stake).

**Synopsis:** `omnibus-cli stake <addr>`

**RPC methods:** `getstake`, `getaddresshistory`

**Example:**
```
$ omnibus-cli stake ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0
=== Stake: ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0 ===
Current stake: 325.0000 OMNI (active)

Recent stake activity:
  block    1820  +100.0000 OMNI  STAKE    abcdef01...
  block    2300  +200.0000 OMNI  STAKE    bcdef012...
  block    3105  + 25.0000 OMNI  STAKE    cdef0123...

Running total: 325.0000 OMNI (matches chain)
```

If the running total does NOT match the chain, the line turns red and reads
`(MISMATCH chain=X OMNI)` — that's a known recovery scenario, see `verify`.

---

## Subcommands — Reputation

### `reputation <addr>`

Reputation total (0..1,000,000), tier, the 4 cups, and lifetime metrics
(first/last active block, total mined, violations).

**Synopsis:** `omnibus-cli reputation <addr>`

**RPC method:** `getreputation`

**Example:**
```
$ omnibus-cli reputation ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0
=== Reputation: ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0 ===
Total: 8421 / 1,000,000
Tier:  OMNI

Cups:
  LOVE:     12.45 / 100
  FOOD:     8.10 / 100
  RENT:     0.00 / 100
  VACATION: 4.20 / 100

First block: 1810
Last block:  4128812
Mined:       427
Violations:  0
```

Tiers (see `STATUS/PROJECT_OMNIBUS_VALIDATOR_VISION.md`):
`OMNI < LOVE < FOOD < RENT < VACATION` — soulbound ladder.

---

## Subcommands — Daily Audit

### `daily <addr> [days]`

Per-day TX bucket, grouped via `block_height / 86400` (1s blocks → 1 calendar
day). Same data the React `DailyAuditPage` displays.

**Synopsis:** `omnibus-cli daily <addr> [days=30]`

**Args:** `days` — number of most-recent days with activity to show.

**RPC method:** `getaddresshistory`

**Example:**
```
$ omnibus-cli daily ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0 7
=== Daily breakdown: ob1q...zp0 (last 7 days w/ activity) ===
Day#       TXs           Sent       Received          Mined        Fees         StakeΔ
47           24       0.0000        50.0000        50.0000     0.0000        +0.0000
46           36       1.0000       150.0000       150.0000     0.0001       +25.0000
45           18       0.0000        20.0000        20.0000     0.0000        +0.0000
Total        78       1.0000       220.0000       220.0000     0.0001       +25.0000
```

Pipe `--json` through `jq` for CSV / dashboard integration:

```sh
omnibus-cli daily ob1q... 30 --json | jq -r '.result.transactions[] | [.blockHeight,.kind,.direction,.amount,.fee] | @csv'
```

---

## Subcommands — Audit & Verify

### `verify <addr>`

Sanity check: chain `getstake` total vs `Σ stake_TX − Σ unstake_TX` from
`getaddresshistory`. Exit code `0` on match, `1` on mismatch.

**Synopsis:** `omnibus-cli verify <addr>`

**RPC methods:** `getstake`, `getaddresshistory`

**Example (match):**
```
$ omnibus-cli verify ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0
=== Sanity check: ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0 ===
================================
Chain stake_amounts:    325.0000 OMNI  (from getstake)
Sum of STAKE TXs:       325.0000 OMNI  (from getaddresshistory, kind=stake)
Sum of UNSTAKE TXs:     0.0000 OMNI
Computed = stake - unstake = 325.0000 OMNI
Chain == Computed: MATCH (in sync)
```

**Example (mismatch):** exit code `1`, stderr-style hint to restart node so the
TX log is replayed and `applyOpReturnRoles` re-derives state.

---

## RPC Methods Used

| Subcommand | RPC method(s) |
|------------|---------------|
| `health` | `getchainmetrics`, `getsyncstatus` |
| `balance` | `getbalance`, `getstake`, `getreputation` |
| `stake` | `getstake`, `getaddresshistory` |
| `reputation` | `getreputation` |
| `daily` | `getaddresshistory` |
| `validators` | `getvalidators` |
| `stakers` | `getstakers` |
| `history` | `getaddresshistory` |
| `verify` | `getstake`, `getaddresshistory` |

For the full chain RPC surface (≈80 methods including `htlc_init`,
`grid_create`, `ns_register`, `agent_register`, `governance_propose`,
`escrow_open`, `notarize`, `subscribe`, `multisig_*`, `pq_attest`, `mining_*`,
network admin), see `API_REFERENCE.md`. They are reachable via `--rpc` with
`curl` directly until the CLI grows wrappers in a future version.

---

## Reserved For Future Versions

The following categories are NOT yet implemented as `omnibus-cli`
subcommands. Use raw RPC (`curl … getrpc …`) for now; CLI wrappers are tracked
in the roadmap:

- **Exchange & DEX** — `exchange_*` / `grid_*` (8 RPCs)
- **Cross-chain HTLC** — `htlc_init`, `htlc_redeem`, `htlc_refund`, `swap_*`
- **Names (.omnibus, .arbitraje, ...)** — `ns_register`, `ns_resolve`, `ns_renew`
- **Agents** — `agent_register`, `agent_follow`, `agent_reward`
- **Governance** — `governance_propose`, `governance_vote`, `governance_status`
- **Escrow / Channels / Notarize / Subscriptions / Multisig**
- **PQ Identity** — `pq_attest`, `pq_verify` (chain-side; UI in aweb3)
- **Mining ops** — `mining_start`, `mining_status` (chain-side; CLI uses `health`)
- **Network admin** — `addnode`, `removenode`, `getpeerinfo` (raw RPC)

---

## See Also

- `docs/CLI_TUTORIAL.md` — step-by-step tutorials în română
- `docs/CLI_COOKBOOK.md` — recipe-style examples
- `docs/cli/omnibus-cli.1` — Linux man page (nroff)
- `scripts/completion/omnibus-cli.{bash,zsh,fish}` — shell completions
- `scripts/install-cli.sh` — installer
- `API_REFERENCE.md` — full JSON-RPC surface
