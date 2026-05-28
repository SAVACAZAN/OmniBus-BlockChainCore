# core/rpc/ — JSON-RPC handler domains

This directory holds JSON-RPC method handlers grouped by domain, in the
style of Bitcoin Core's `src/rpc/`. Each file exports `pub fn handle*`
functions called by the dispatcher in `../rpc_server.zig`.

## Why this layout

Before the split, `core/rpc_server.zig` was 18 701 lines containing
253 handlers across ~20 unrelated domains (wallet, exchange, oracle,
governance, EVM-compat, identity, …). Every cross-cutting edit risked
unrelated regressions. We mirror Bitcoin Core's `src/rpc/{blockchain,
mining,net,rawtransaction,wallet,...}.cpp` partitioning so a contributor
touching one domain only opens one file.

## Shared state

The dispatcher owns `pub const ServerCtx` (declared in `rpc_server.zig`).
Domain handlers import it back via:

```zig
const rpc = @import("../rpc_server.zig");
const ServerCtx = rpc.ServerCtx;
```

Common JSON helpers (`extractStr`, `errorJson`, `extractArrayStr`,
`extractParamObjectField`, `extractParamObjectU64`,
`extractStringFromArrayParams`) live in `rpc_server.zig` as `pub fn` so
all domain files share one implementation. This mild back-import is
intentional — splitting them into a third file (`common.zig`) would
duplicate the type-binding work without simplifying the dependency
graph.

## Files (planned, executed incrementally)

| File | Domain | Status |
|------|--------|--------|
| `eth.zig` | `eth_*`, `net_version` (Ethereum-compat JSON-RPC) | **DONE** |
| `chain.zig` | `getblockcount`, `getblock`, `getbestblockhash`, `getheaders`, … | pending |
| `wallet.zig` | `getbalance`, `sendtransaction`, `listtx`, `getaddrhistory`, … | pending |
| `mempool.zig` | `getmempoolsize`, `getpendingtxs`, `estimatefee`, … | pending |
| `net.zig` | `getpeers`, `getnetworkinfo`, `getsyncstatus`, … | pending |
| `mining.zig` | `registerminer`, `getpoolstats`, `getminerstats`, … | pending |
| `consensus.zig` | `stake`, `unstake`, `getvalidators`, `getslotleader`, … | pending |
| `oracle.zig` | `omnibus_prices`, `oracle_*`, `arbitrage`, … | pending |
| `spv.zig` | `spvbtc_*`, `spveth_*` | pending |
| `agents.zig` | `agent_*` | pending |
| `ns.zig` | `registername`, `resolvename`, `ns_*` | pending |
| `exchange.zig` | `exchange_*`, `grid_*` | pending |
| `swap.zig` | `swap_*`, `htlc_*`, `bridge_*`, `intent_*` | pending |
| `lightning.zig` | `openchannel`, `channelpay`, `closechannel` | pending |
| `identity.zig` | `getdid`, `getobm`, `kyc_*`, `profile_*`, `disclose_*` | pending |
| `pq.zig` | `pq_*`, `sendpqattest` | pending |
| `social.zig` | `follow`, `label`, `poap_*` | pending |
| `governance.zig` | `gov_*`, proposals | pending |
| `escrow.zig` | `escrow_*` | pending |
| `notarize.zig` | `notarize_*` | pending |
| `subscription.zig` | `sub_*` | pending |
| `wallet_advanced.zig` | `coldwallet_*`, `timelock_*`, `covenant_*`, `treasury_*` | pending |

After every batch the build must stay green (`zig build` + relevant
`zig build test-*`). No batch is merged that breaks running testnet RPC.

## Adding a new RPC method

1. Identify the domain. Pick (or create) `core/rpc/<domain>.zig`.
2. Add `pub fn handleX(body: []const u8, ctx: *ServerCtx, id: u64) ![]u8`.
3. In `rpc_server.zig` dispatcher, add the routing line:
   `if (std.mem.eql(u8, method, "myMethod")) return <domain>.handleX(body, ctx, id);`
4. Keep handler bodies under ~100 LOC. Extract sub-helpers in the same file.
