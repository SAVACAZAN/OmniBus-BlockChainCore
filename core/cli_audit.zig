/// cli_audit.zig — `omnibus-cli` standalone audit tool.
///
/// Thin dispatcher: parses argv, resolves the JSON-RPC endpoint, and routes
/// each subcommand to a handler implemented in `core/cli/<domain>.zig`.
/// The actual handler bodies + shared helpers live in `core/cli/common.zig`;
/// the per-domain files (`health.zig`, `wallet.zig`, `stake.zig`, `audit.zig`,
/// `exchange.zig`, `grid.zig`, `htlc.zig`, `oracle.zig`, `chain.zig`,
/// `net.zig`, `mining.zig`, `admin.zig`, `ns.zig`, `agents.zig`, `gov.zig`,
/// `escrow.zig`, `notarize.zig`, `multisig.zig`, `pq.zig`, `social.zig`,
/// `profile.zig`, `vault.zig`) re-export the handlers grouped by topic so
/// developers can navigate the codebase by domain rather than by one 6k-line
/// blob.
///
/// Build: `zig build install` → zig-out/bin/omnibus-cli(.exe)

const std = @import("std");
const c = @import("cli/common.zig");

// Per-domain re-export modules. They contain `pub const cmdX = c.cmdX;` lines
// so future refactors can move handler bodies out of common.zig one domain at
// a time without touching this dispatcher.
const health = @import("cli/health.zig");
const wallet = @import("cli/wallet.zig");
const stake_mod = @import("cli/stake.zig");
const audit_mod = @import("cli/audit.zig");
const exchange = @import("cli/exchange.zig");
const grid = @import("cli/grid.zig");
const htlc = @import("cli/htlc.zig");
const oracle = @import("cli/oracle.zig");
const chain = @import("cli/chain.zig");
const net = @import("cli/net.zig");
const mining = @import("cli/mining.zig");
const admin = @import("cli/admin.zig");
const ns_mod = @import("cli/ns.zig");
const agents = @import("cli/agents.zig");
const gov = @import("cli/gov.zig");
const escrow = @import("cli/escrow.zig");
const notarize = @import("cli/notarize.zig");
const multisig_mod = @import("cli/multisig.zig");
const pq = @import("cli/pq.zig");
const social = @import("cli/social.zig");
const profile_mod = @import("cli/profile.zig");
const vault = @import("cli/vault.zig");

fn printHelp() !void {
    const out = c.stdout();
    try out.print(
        \\omnibus-cli — OmniBus blockchain audit tool
        \\
        \\USAGE
        \\  omnibus-cli <command> [args] [flags]
        \\
        \\COMMANDS — audit
        \\  balance <addr>             Full balance breakdown (wallet/stake/avail/rep)
        \\  stake <addr>               Current stake + activity log
        \\  reputation <addr>          Cups + tier
        \\  did <addr>                 OmniBus ID DID (did:omnibus:...)
        \\  obm <addr>                 OmniBus Binary Map (1 byte = 8 flags)
        \\  facets <addr>              ID facets (Social / Professional / Cultural)
        \\  daily <addr> [days=30]     Per-day TX breakdown
        \\  validators                 List of all validators
        \\  stakers [limit=10]         Top stakers
        \\  health                     Chain stats (height, mempool, peers)
        \\  history <addr> [filter]    TX history (filter: stake|sent|received|mined|all)
        \\  verify <addr>              Sanity check: chain stake vs sum(STAKE TXs)
        \\
        \\COMMANDS — exchange
        \\  exchange-pairs                              List 7 trading pairs + chain mapping
        \\  exchange-orderbook <pair_id>                Bids+asks+spread for a pair
        \\  exchange-trades <pair_id> [limit=50]        Recent trades for a pair
        \\  exchange-orders <addr>                      User's open orders
        \\  exchange-place <addr> <pair> <side> <price> <amount>  Submit signed order (write)
        \\  exchange-cancel <addr> <order_id>           Cancel order (write)
        \\  exchange-pair-info <pair_id>                Pair details (chains, contracts)
        \\  exchange-stats <pair_id>                    24h stats: vol, high, low, last
        \\
        \\COMMANDS — grid
        \\  grid-list [owner_addr]                      List grid trading positions
        \\  grid-status <grid_id>                       Single grid details
        \\  grid-create <addr> <pair> <low> <high> <levels> <total_base> <total_quote>  (write)
        \\  grid-cancel <addr> <grid_id>                (write)
        \\
        \\COMMANDS — htlc / swap
        \\  htlc-list                                   Open HTLC swaps
        \\  htlc-status <swap_id>                       Single swap status
        \\  htlc-init <addr> <recipient> <amount> <secret_hash> <lock_blocks>  (write)
        \\  htlc-claim <addr> <swap_id> <preimage>      (write)
        \\  htlc-refund <addr> <swap_id>                (write)
        \\  swap-list                                   All atomic swaps
        \\  swap-status <swap_id>                       Single atomic swap
        \\
        \\COMMANDS — oracle / bridge
        \\  oracle-prices                               BTC/LCX × 3 exchanges
        \\  oracle-arbitrage                            Cross-exchange arbitrage opps
        \\  oracle-feed                                 Full ws exchange feed (~700 pairs)
        \\  bridge-status                               Bridge limits + state
        \\  bridge-lock <addr> <to_chain> <amount>      (write)
        \\
        \\COMMANDS — chain inspection
        \\  block <height>                              Full block details
        \\  block-hash <hash>                           Block by hash
        \\  tx <txid>                                   Full TX details
        \\  mempool                                     Mempool snapshot
        \\  sync-status                                 IBD progress, peer height vs local
        \\  chain-info                                  Height, difficulty, network, consensus
        \\  supply                                      Total emitted OMNI, halving info
        \\  halving                                     Next halving estimate
        \\  prices [block]                              Block-level oracle prices (block.prices)
        \\
        \\COMMANDS — network / peers
        \\  peers                                       List connected peers
        \\  peer-info <peer_id>                         Peer details + score
        \\  bans                                        Banned peers
        \\  connect <ip:port>                           Manual peer connect (write)
        \\  disconnect <peer_id>                        Disconnect a peer (write)
        \\  p2p-stats                                   Total in/out, traffic, knock-knock count
        \\
        \\COMMANDS — mining
        \\  mining-status                               Current miner, hashrate, blocks/min
        \\  miners                                      List of all miners with block counts
        \\  miner-stats <addr>                          Single miner stats
        \\  pool-stats                                  Mining pool stats
        \\  slot-leader                                 Current slot leader + rotation
        \\  register-miner <addr> [node-id]             Register as miner (write)
        \\
        \\COMMANDS — wallet utilities
        \\  wallet-summary <addr>                       Atomic balance/stake/orders snapshot
        \\  derive-key <index>                          Print privkey+address for m/44'/777'/0'/0/<index>
        \\  wallet-list <count>                         List first N addresses from one mnemonic
        \\  wallet-derive <mnemonic> <index>            Derive address at index (legacy)
        \\  wallet-pq-derive <mnemonic>                 Derive 4 PQ addresses
        \\  wallet-multichain <mnemonic>                Derive BTC/ETH/SOL/etc addresses
        \\  wallet-export <mnemonic>                    JSON metadata bundle
        \\  sign-message <mnemonic> <message>           Sign arbitrary message (ECDSA)
        \\  verify-signature <pubkey> <signature> <message>
        \\  send <from> <to> <amount> [fee=1]           Basic transfer (write)
        \\
        \\SIGNING SOURCES (in priority order — for any write command):
        \\  --privkey <hex>                             Raw 32-byte privkey
        \\  OMNIBUS_PRIVKEY env                         Same, via environment
        \\  --keyfile <path>                            Load privkey hex from file
        \\  --mnemonic <words> [--key-index N]          Derive child N from seed
        \\  --passphrase <p>  /  OMNIBUS_PASSPHRASE     BIP-39 "25th word"
        \\  OMNIBUS_MNEMONIC env [--key-index N]        Same, via environment
        \\
        \\COMMANDS — Profile / MiCA / Cold Wallet / Timelock / Covenant / Treasury / Multisig
        \\  profile (init|get|wizard|export|import|social|professional|cultural|economic) ...
        \\  mica (attest|disclose) ...
        \\  coldwallet (add|list|remove|history|balance) ...
        \\  timelock (create|list|spend|status) ...
        \\  covenant (create|list|get|remove) ...
        \\  treasury (create|list|distribute|status) ...
        \\  multisig (create|info|send|balance) ...
        \\
        \\COMMANDS — admin / debug / audit / faucet / 0day / restart
        \\  set-rpc-token <token>                       Persist token to ~/.omnibus/cli.conf
        \\  config                                      Print active config
        \\  watch <command> [interval=5]                Repeat a subcommand every N sec
        \\  logs [tail=50]                              Recent journal lines
        \\  vps-health                                  SSH wrapper to test-scripts/_vps-health.sh
        \\  stress-quick                                Wrapper around _quick-stake-test.sh
        \\  benchmark                                   RPC latency benchmark (1000 calls)
        \\  faucet-(status|claim|claims)
        \\  zeroday-(events|report) / sybil-check
        \\  audit-(totals|stakes|supply|mempool|fees)
        \\  services-status / service-restart / oracle-(restart|snapshot)
        \\
        \\FLAGS
        \\  --rpc <url>            Override RPC URL (default http://127.0.0.1:8332)
        \\  --chain <c>            mainnet|testnet|regtest (8332/18332/28332)
        \\  --remote               Use https://omnibusblockchain.cc:8443
        \\  --token <bearer>       RPC bearer token if needed
        \\  --json                 Raw JSON output (no pretty-print)
        \\  --no-color             Disable ANSI colors
        \\  --yes / -y             Confirm a write command
        \\  --mnemonic "<12 words>"   Override OMNIBUS_MNEMONIC env var
        \\  --foo-bar=baz          Generic key-value flag
        \\
        \\Run any subcommand with --json | jq for machine-readable output.
        \\
    , .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const args = try c.parseArgs(allocator, argv);
    defer allocator.free(args.pos);
    defer allocator.free(args.kvs);
    if (args.no_color) c.g_color = false;
    if (!std.fs.File.stdout().isTty()) c.g_color = false;

    if (args.cmd.len == 0 or std.mem.eql(u8, args.cmd, "help")) {
        try printHelp();
        return;
    }

    const ep = c.resolveEndpoint(args);

    const code = blk: {
        if (std.mem.eql(u8, args.cmd, "health")) break :blk try health.cmdHealth(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "validators")) break :blk try stake_mod.cmdValidators(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "stakers")) {
            const limit: u64 = if (args.pos.len > 0)
                std.fmt.parseInt(u64, args.pos[0], 10) catch 10
            else 10;
            break :blk try stake_mod.cmdStakers(allocator, ep, limit, args.json);
        }

        // exchange (read)
        if (std.mem.eql(u8, args.cmd, "exchange-pairs")) break :blk try exchange.cmdExchangePairs(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "exchange-orderbook")) break :blk try exchange.cmdExchangeOrderbook(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "exchange-trades")) break :blk try exchange.cmdExchangeTrades(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "exchange-pair-info")) break :blk try exchange.cmdExchangePairInfo(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "exchange-stats")) break :blk try audit_mod.cmdExchangeStats(allocator, ep, args);

        // htlc / swap / oracle / bridge (read)
        if (std.mem.eql(u8, args.cmd, "htlc-list")) break :blk try htlc.cmdHtlcList(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "htlc-status")) break :blk try htlc.cmdHtlcStatus(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "swap-list")) break :blk try htlc.cmdSwapList(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "swap-status")) break :blk try htlc.cmdSwapStatus(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "oracle-prices")) break :blk try oracle.cmdOraclePrices(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "oracle-arbitrage")) break :blk try oracle.cmdOracleArbitrage(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "oracle-feed")) break :blk try oracle.cmdOracleFeed(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "bridge-status")) break :blk try oracle.cmdBridgeStatus(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "grid-list")) {
            const owner: ?[]const u8 = if (args.pos.len > 0) args.pos[0] else null;
            break :blk try grid.cmdGridList(allocator, ep, owner, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "grid-status")) break :blk try grid.cmdGridStatus(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "dex-settler-status")) break :blk try htlc.cmdDexSettlerStatus(allocator, args);

        // write-side
        if (std.mem.eql(u8, args.cmd, "exchange-orders")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("exchange-orders <addr>");
            break :blk try exchange.cmdExchangeOrders(allocator, ep, args.pos[0], args);
        }
        if (std.mem.eql(u8, args.cmd, "exchange-place")) break :blk try exchange.cmdExchangePlace(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "exchange-cancel")) break :blk try exchange.cmdExchangeCancel(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "grid-create")) break :blk try grid.cmdGridCreate(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "grid-cancel")) break :blk try grid.cmdGridCancel(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "htlc-init")) break :blk try htlc.cmdHtlcInit(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "htlc-claim")) break :blk try htlc.cmdHtlcClaim(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "htlc-refund")) break :blk try htlc.cmdHtlcRefund(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "bridge-lock")) break :blk try oracle.cmdBridgeLock(allocator, ep, args);

        // chain inspection
        if (std.mem.eql(u8, args.cmd, "mempool")) break :blk try chain.cmdMempool(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "sync-status")) break :blk try chain.cmdSyncStatus(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "chain-info")) break :blk try chain.cmdChainInfo(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "supply")) break :blk try chain.cmdSupply(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "halving")) break :blk try chain.cmdHalving(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "prices")) break :blk try chain.cmdPrices(allocator, ep, args);

        // network / peers
        if (std.mem.eql(u8, args.cmd, "peers")) break :blk try net.cmdPeers(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "bans")) break :blk try net.cmdBans(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "p2p-stats")) break :blk try net.cmdP2pStats(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "connect")) break :blk try net.cmdConnectPeer(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "disconnect")) break :blk try net.cmdDisconnectPeer(allocator, ep, args);

        // mining
        if (std.mem.eql(u8, args.cmd, "mining-status")) break :blk try mining.cmdMiningStatus(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "miners")) break :blk try mining.cmdMiners(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "pool-stats")) break :blk try mining.cmdPoolStats(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "slot-leader")) break :blk try mining.cmdSlotLeader(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "register-miner")) break :blk try mining.cmdRegisterMiner(allocator, ep, args);

        // wallet utilities
        if (std.mem.eql(u8, args.cmd, "wallet-derive")) break :blk try wallet.cmdWalletDerive(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "wallet-pq-derive")) break :blk try wallet.cmdWalletPqDerive(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "wallet-multichain")) break :blk try wallet.cmdWalletMultichain(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "wallet-export")) break :blk try wallet.cmdWalletExport(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "sign-message")) break :blk try wallet.cmdSignMessage(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "verify-signature")) break :blk try wallet.cmdVerifySignature(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "send")) break :blk try wallet.cmdSend(allocator, ep, args);

        // admin / debug
        if (std.mem.eql(u8, args.cmd, "set-rpc-token")) break :blk try admin.cmdSetRpcToken(allocator, args);
        if (std.mem.eql(u8, args.cmd, "config")) break :blk try admin.cmdConfig(allocator, args, ep);
        if (std.mem.eql(u8, args.cmd, "logs")) break :blk try admin.cmdLogs(allocator, args);
        if (std.mem.eql(u8, args.cmd, "vps-health")) break :blk try admin.cmdVpsHealth(allocator);
        if (std.mem.eql(u8, args.cmd, "stress-quick")) break :blk try admin.cmdStressQuick(allocator);
        if (std.mem.eql(u8, args.cmd, "benchmark")) break :blk try admin.cmdBenchmark(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "watch")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("watch <command> [interval=5]");
            const interval: u64 = if (args.pos.len > 1)
                std.fmt.parseInt(u64, args.pos[1], 10) catch 5
            else 5;
            var i_loop: usize = 0;
            while (i_loop < 100) : (i_loop += 1) {
                try c.stdout().print("{s}--- watch tick {d} ---{s}\n",
                    .{ c.col(c.C_GRAY), i_loop, c.rst() });
                _ = c.runProcess(allocator, &.{
                    "omnibus-cli", args.pos[0],
                }) catch 1;
                std.Thread.sleep(interval * std.time.ns_per_s);
            }
            break :blk @as(u8, 0);
        }

        // faucet
        if (std.mem.eql(u8, args.cmd, "faucet-status")) break :blk try admin.cmdFaucetStatus(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "faucet-claim")) break :blk try admin.cmdFaucetClaim(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "faucet-claims")) break :blk try admin.cmdFaucetClaims(allocator, ep, args.json);

        // 0day / security
        if (std.mem.eql(u8, args.cmd, "zeroday-events")) break :blk try admin.cmdZerodayEvents(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "zeroday-report")) break :blk try admin.cmdZerodayReport(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "sybil-check")) break :blk try admin.cmdSybilCheck(allocator, ep, args);

        // audit chain consistency
        if (std.mem.eql(u8, args.cmd, "audit-totals")) break :blk try audit_mod.cmdAuditTotals(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "audit-stakes")) break :blk try audit_mod.cmdAuditStakes(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "audit-supply")) break :blk try audit_mod.cmdAuditSupply(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "audit-mempool")) break :blk try audit_mod.cmdAuditMempool(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "audit-fees")) break :blk try audit_mod.cmdAuditFees(allocator, ep, args.json);

        // restart / control (SSH wrappers)
        if (std.mem.eql(u8, args.cmd, "services-status")) break :blk try admin.cmdServicesStatus(allocator);
        if (std.mem.eql(u8, args.cmd, "service-restart")) break :blk try admin.cmdServiceRestart(allocator, args);
        if (std.mem.eql(u8, args.cmd, "oracle-restart")) break :blk try oracle.cmdOracleRestart(allocator, args);
        if (std.mem.eql(u8, args.cmd, "oracle-snapshot")) break :blk try oracle.cmdOracleSnapshot(allocator);

        // names
        if (std.mem.eql(u8, args.cmd, "ns-tlds")) break :blk try ns_mod.cmdNsTlds(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "ns-stats")) break :blk try ns_mod.cmdNsStats(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "ns-list")) {
            const owner: ?[]const u8 = if (args.pos.len > 0) args.pos[0] else null;
            break :blk try ns_mod.cmdNsList(allocator, ep, owner, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-resolve")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("ns-resolve <name>");
            break :blk try ns_mod.cmdNsResolve(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-reverse")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("ns-reverse <addr>");
            break :blk try ns_mod.cmdNsReverse(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-fee")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("ns-fee <tld>");
            break :blk try ns_mod.cmdNsFee(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-expiring")) {
            const days: u64 = if (args.pos.len > 0)
                std.fmt.parseInt(u64, args.pos[0], 10) catch 30
            else 30;
            break :blk try ns_mod.cmdNsExpiring(allocator, ep, days, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-by-category")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("ns-by-category <category>");
            break :blk try ns_mod.cmdNsByCategory(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "ns-register")) break :blk try ns_mod.cmdNsRegister(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "ns-renew")) break :blk try ns_mod.cmdNsRenew(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "ns-transfer")) break :blk try ns_mod.cmdNsTransfer(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "ns-update")) break :blk try ns_mod.cmdNsUpdate(allocator, ep, args);

        // agents
        if (std.mem.eql(u8, args.cmd, "agents-list")) break :blk try agents.cmdAgentsList(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "agent-info")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("agent-info <agent_id>");
            break :blk try agents.cmdAgentInfo(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "agent-decisions")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("agent-decisions <agent_id>");
            break :blk try agents.cmdAgentDecisions(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "agent-register")) break :blk try agents.cmdAgentRegister(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "agent-unregister")) break :blk try agents.cmdAgentUnregister(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "agent-edit")) break :blk try agents.cmdAgentEdit(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "agent-follow")) break :blk try agents.cmdAgentFollow(allocator, ep, args);

        // governance
        if (std.mem.eql(u8, args.cmd, "gov-proposals")) break :blk try gov.cmdGovProposals(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "gov-treasury")) break :blk try gov.cmdGovTreasury(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "gov-proposal")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("gov-proposal <id>");
            break :blk try gov.cmdGovProposal(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "gov-propose")) break :blk try gov.cmdGovPropose(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "gov-vote")) break :blk try gov.cmdGovVote(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "gov-execute")) break :blk try gov.cmdGovExecute(allocator, ep, args);

        // escrow
        if (std.mem.eql(u8, args.cmd, "escrow-list")) {
            const a: ?[]const u8 = if (args.pos.len > 0) args.pos[0] else null;
            break :blk try escrow.cmdEscrowList(allocator, ep, a, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "escrow-info")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("escrow-info <escrow_id>");
            break :blk try escrow.cmdEscrowInfo(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "escrow-create")) break :blk try escrow.cmdEscrowCreate(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "escrow-release")) break :blk try escrow.cmdEscrowAction(allocator, ep, args, "escrow_release", "escrow-release");
        if (std.mem.eql(u8, args.cmd, "escrow-refund")) break :blk try escrow.cmdEscrowAction(allocator, ep, args, "escrow_refund", "escrow-refund");
        if (std.mem.eql(u8, args.cmd, "escrow-dispute")) break :blk try escrow.cmdEscrowAction(allocator, ep, args, "escrow_dispute", "escrow-dispute");

        // payment channels
        if (std.mem.eql(u8, args.cmd, "channels-list")) {
            const a: ?[]const u8 = if (args.pos.len > 0) args.pos[0] else null;
            break :blk try escrow.cmdChannelsList(allocator, ep, a, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "channel-info")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("channel-info <channel_id>");
            break :blk try escrow.cmdChannelInfo(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "channel-open")) break :blk try escrow.cmdChannelOpen(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "channel-pay")) break :blk try escrow.cmdChannelPay(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "channel-close")) break :blk try escrow.cmdChannelClose(allocator, ep, args);

        // notarization
        if (std.mem.eql(u8, args.cmd, "notarize-list")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("notarize-list <addr>");
            break :blk try notarize.cmdNotarizeList(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "notarize-verify")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("notarize-verify <doc_hash>");
            break :blk try notarize.cmdNotarizeVerify(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "notarize-doc")) break :blk try notarize.cmdNotarizeDoc(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "notarize-revoke")) break :blk try notarize.cmdNotarizeRevoke(allocator, ep, args);

        // subscriptions
        if (std.mem.eql(u8, args.cmd, "sub-list")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("sub-list <addr>");
            break :blk try notarize.cmdSubList(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "sub-create")) break :blk try notarize.cmdSubCreate(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "sub-cancel")) break :blk try notarize.cmdSubCancel(allocator, ep, args);

        // multisig
        if (std.mem.eql(u8, args.cmd, "multisig-create")) break :blk try multisig_mod.cmdMultisigCreate(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "multisig-info")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("multisig-info <addr>");
            break :blk try multisig_mod.cmdMultisigInfo(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "multisig-send")) break :blk try multisig_mod.cmdMultisigSend(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "multisig")) break :blk try multisig_mod.cmdMultisig(allocator, ep, args);

        // coldwallet
        if (std.mem.eql(u8, args.cmd, "coldwallet")) break :blk try vault.cmdColdwallet(allocator, ep, args);
        // timelock
        if (std.mem.eql(u8, args.cmd, "timelock")) break :blk try vault.cmdTimelock(allocator, ep, args);
        // covenant
        if (std.mem.eql(u8, args.cmd, "covenant")) break :blk try vault.cmdCovenant(allocator, ep, args);
        // treasury
        if (std.mem.eql(u8, args.cmd, "treasury")) break :blk try vault.cmdTreasury(allocator, ep, args);

        // PQ identity
        if (std.mem.eql(u8, args.cmd, "pq-schemes")) break :blk try pq.cmdPqSchemes(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "pq-identity")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("pq-identity <addr>");
            break :blk try pq.cmdPqIdentity(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "pq-balance")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("pq-balance <addr>");
            break :blk try pq.cmdPqBalance(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "pq-attest")) break :blk try pq.cmdPqAttest(allocator, ep, args);

        // Profile / MiCA
        if (std.mem.eql(u8, args.cmd, "profile")) break :blk try profile_mod.cmdProfile(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "mica")) break :blk try profile_mod.cmdMica(allocator, ep, args);

        // POAP / Social
        if (std.mem.eql(u8, args.cmd, "poap-events")) break :blk try social.cmdPoapEvents(allocator, ep, args.json);
        if (std.mem.eql(u8, args.cmd, "poap-claim")) break :blk try social.cmdPoapClaim(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "follow")) break :blk try social.cmdFollow(allocator, ep, args);
        if (std.mem.eql(u8, args.cmd, "followers")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("followers <addr>");
            break :blk try social.cmdFollowers(allocator, ep, args.pos[0], args.json);
        }
        if (std.mem.eql(u8, args.cmd, "following")) {
            if (args.pos.len < 1) break :blk try c.writeMissing("following <addr>");
            break :blk try social.cmdFollowing(allocator, ep, args.pos[0], args.json);
        }

        // key management (local, no RPC)
        if (std.mem.eql(u8, args.cmd, "derive-key")) break :blk try wallet.cmdDeriveKey(allocator, args);
        if (std.mem.eql(u8, args.cmd, "wallet-list") or std.mem.eql(u8, args.cmd, "list-keys")) {
            break :blk try wallet.cmdWalletList(allocator, args);
        }

        // address-required commands
        if (args.pos.len == 0) {
            try c.stderr().print(
                "{s}error:{s} `{s}` requires an address argument\n",
                .{ c.col(c.C_RED), c.rst(), args.cmd });
            try printHelp();
            break :blk @as(u8, 2);
        }
        const addr = args.pos[0];
        if (std.mem.eql(u8, args.cmd, "balance")) break :blk try wallet.cmdBalance(allocator, ep, addr, args.json);
        if (std.mem.eql(u8, args.cmd, "wallet-summary") or
            std.mem.eql(u8, args.cmd, "summary") or
            std.mem.eql(u8, args.cmd, "ws"))
        {
            break :blk try wallet.cmdWalletSummary(allocator, ep, addr, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "stake")) break :blk try stake_mod.cmdStake(allocator, ep, addr, args.json);
        if (std.mem.eql(u8, args.cmd, "reputation")) break :blk try stake_mod.cmdReputation(allocator, ep, addr, args.json);
        if (std.mem.eql(u8, args.cmd, "did")) {
            break :blk try c.dumpRpcResult(allocator, ep, "getdid",
                try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr}),
                args.json, "DID");
        }
        if (std.mem.eql(u8, args.cmd, "obm")) {
            break :blk try c.dumpRpcResult(allocator, ep, "getobm",
                try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr}),
                args.json, "OmniBus Binary Map");
        }
        if (std.mem.eql(u8, args.cmd, "facets")) {
            break :blk try c.dumpRpcResult(allocator, ep, "getfacets",
                try std.fmt.allocPrint(allocator, "[\"{s}\"]", .{addr}),
                args.json, "ID Facets (Social / Professional / Cultural)");
        }
        if (std.mem.eql(u8, args.cmd, "daily")) {
            const days: u64 = if (args.pos.len > 1)
                std.fmt.parseInt(u64, args.pos[1], 10) catch 30
            else 30;
            break :blk try audit_mod.cmdDaily(allocator, ep, addr, days, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "history")) {
            const filter: []const u8 = if (args.pos.len > 1) args.pos[1] else "all";
            break :blk try audit_mod.cmdHistory(allocator, ep, addr, filter, args.json);
        }
        if (std.mem.eql(u8, args.cmd, "verify")) break :blk try audit_mod.cmdVerify(allocator, ep, addr, args.json);
        if (std.mem.eql(u8, args.cmd, "block")) break :blk try chain.cmdBlock(allocator, ep, addr, args.json);
        if (std.mem.eql(u8, args.cmd, "block-hash")) break :blk try chain.cmdBlockByHash(allocator, ep, addr, args.json);
        if (std.mem.eql(u8, args.cmd, "tx")) break :blk try chain.cmdTx(allocator, ep, addr, args.json);
        if (std.mem.eql(u8, args.cmd, "peer-info")) break :blk try net.cmdPeerInfo(allocator, ep, addr, args.json);
        if (std.mem.eql(u8, args.cmd, "miner-stats")) break :blk try mining.cmdMinerStats(allocator, ep, addr, args.json);

        try c.stderr().print(
            "{s}error:{s} unknown command `{s}`\n\n",
            .{ c.col(c.C_RED), c.rst(), args.cmd });
        try printHelp();
        break :blk @as(u8, 2);
    };
    std.process.exit(code);
}
