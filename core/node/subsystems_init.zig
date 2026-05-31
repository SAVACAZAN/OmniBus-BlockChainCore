// core/node/subsystems_init.zig
//
// Bundle of 6 sequential subsystem-init blocks extracted from main.zig.
// Same args, same print lines, same behavior — pure refactor to reduce
// main.zig surface area.
//
// Callers must keep the deinit defers in main.zig:
//   defer subs.metachain.deinit();
//   defer subs.state_trie.deinit();
// and wire `g_staking_engine = &subs.staking;` after the call.

const std = @import("std");

const consensus_mod   = @import("../consensus.zig");
const metachain_mod   = @import("../metachain.zig");
const state_trie_mod  = @import("../state_trie.zig");
const finality_mod    = @import("../finality.zig");
const staking_mod     = @import("../staking.zig");
const governance_mod  = @import("../governance.zig");
const secp256k1_mod   = @import("../secp256k1.zig");
const evm_executor_mod = @import("../evm_executor.zig");

pub const Subsystems = struct {
    consensus_cfg: consensus_mod.ConsensusConfig,
    consensus:     consensus_mod.ConsensusEngine,
    metachain:     metachain_mod.Metachain,
    state_trie:    state_trie_mod.StateTrie,
    finality:      finality_mod.FinalityEngine,
    staking:       staking_mod.StakingEngine,
    governance:    governance_mod.GovernanceEngine,
};

/// Initialize the 6 core subsystems in the canonical order used by main().
/// `wallet_priv` is the miner wallet private key used to register validator 0
/// in the finality engine (so self-attestations are cryptographically verified).
pub fn initSubsystems(
    allocator: std.mem.Allocator,
    num_shards: u8,
    wallet_priv: [32]u8,
) !Subsystems {
    // ── Init Consensus Engine ─────────────────────────────────────────────────
    const consensus_cfg = consensus_mod.ConsensusConfig.init(.ProofOfWork, 1);
    const consensus = consensus_mod.ConsensusEngine.init(consensus_cfg, allocator);
    consensus_cfg.print();

    // ── Init Metachain + ShardCoordinator (Sprint 1) ──────────────────────────
    const metachain = try metachain_mod.Metachain.init(allocator, num_shards);
    std.debug.print("[METACHAIN] Init | {d} shards | genesis MetaBlock height 0\n\n", .{num_shards});

    // ── Init State Trie (account state compression) ──────────────────────────
    const state_trie = state_trie_mod.StateTrie.init(allocator);

    // ── Init Finality Engine (Casper FFG checkpoints) ────────────────────────
    var finality = finality_mod.FinalityEngine.init(1000); // initial voting power
    // Register this node's miner wallet as validator 0 so its self-attestations
    // can be cryptographically verified (secp256k1) instead of trusted by id.
    // Power 1000 == total init voting power → a solo miner still finalises.
    const finality_pubkey = secp256k1_mod.Secp256k1Crypto.privateKeyToPublicKey(wallet_priv) catch [_]u8{0} ** 33;
    finality.registerValidator(0, finality_pubkey, 1000) catch {};
    std.debug.print("[FINALITY] Casper FFG init | checkpoint every {d} blocks | soft finality: {d} confirms\n",
        .{ finality_mod.CHECKPOINT_INTERVAL, finality_mod.SOFT_FINALITY_CONFIRMS });

    // ── Init Staking Engine ──────────────────────────────────────────────────
    const staking = staking_mod.StakingEngine.init();
    std.debug.print("[STAKING] Engine init | min stake: {d} SAT | unbonding: {d} blocks\n",
        .{ staking_mod.VALIDATOR_MIN_STAKE, staking_mod.UNBONDING_PERIOD });

    // ── Init Governance ──────────────────────────────────────────────────────
    const governance = governance_mod.GovernanceEngine.init(governance_mod.GovernanceParams{});
    std.debug.print("[GOVERNANCE] Init | quorum: {d}% | threshold: {d}% | veto: {d}%\n",
        .{ governance.params.quorum_pct, governance.params.threshold_pct, governance.params.veto_pct });

    return .{
        .consensus_cfg = consensus_cfg,
        .consensus     = consensus,
        .metachain     = metachain,
        .state_trie    = state_trie,
        .finality      = finality,
        .staking       = staking,
        .governance    = governance,
    };
}

/// Initialize the EVM (revm) engine. Called separately after the P2P stack
/// and before the RPC server starts, so eth_* JSON-RPC methods can dispatch
/// into a live executor. Failure is non-fatal — eth_* methods just return
/// errors until the operator restarts. Caller must pair with `shutdownEvm()`
/// via `defer` so revm resources are released on clean shutdown.
pub fn initEvm() void {
    evm_executor_mod.init() catch |err| {
        std.debug.print("[EVM] init failed: {} — eth_* RPC methods will return errors\n", .{err});
    };
    std.debug.print("[EVM] Engine initialized (revm)\n", .{});
}

pub fn shutdownEvm() void {
    evm_executor_mod.shutdown();
}
