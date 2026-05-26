// ============================================
// build.zig - Complete build configuration
// ============================================
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Main executable
    const exe = b.addExecutable(.{
        .name = "omnibus",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    
    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    
    // Tests - individual modules
    const test_modules = [_][]const u8{
        "core/utxo.zig",
        "core/mempool.zig",
        "core/transaction.zig",
        "core/script.zig",
        "core/psbt.zig",
        "core/block.zig",
        "core/multisig.zig",
        "core/bech32.zig",
        "core/fee_estimator.zig",
        "core/coin_control.zig",
        "core/sighash.zig",
        "core/segwit.zig",
        "core/pq_handshake.zig",
        "core/hybrid_signature.zig",
        "core/fast_sync.zig",
        "core/package_relay.zig",
        "core/slashing_evidence.zig",
        "core/double_ratchet.zig",
        "core/sub_block.zig",
        "core/consensus_pouw.zig",
        "core/finality.zig",
        "core/staking.zig",
        "core/governance.zig",
        "core/validator_registry.zig",
        "core/metachain.zig",
        "core/shard_coordinator.zig",
        "core/secp256k1.zig",
        "core/schnorr.zig",
        "core/bls_signatures.zig",
        "core/pq_crypto.zig",
        "core/bip32_wallet.zig",
        "core/wallet.zig",
        "core/network.zig",
        "core/p2p.zig",
        "core/encrypted_p2p.zig",
        "core/kademlia_dht.zig",
        "core/storage.zig",
        "core/state_trie.zig",
        "core/bridge_native.zig",
        "core/htlc.zig",
        "core/matching_engine.zig",
        "core/orderbook_sync.zig",
        "core/oracle.zig",
    };
    
    // Create test steps
    const test_step = b.step("test", "Run all tests");
    
    for (test_modules) |module_path| {
        const test_exe = b.addTest(.{
            .root_source_file = b.path(module_path),
            .target = target,
            .optimize = optimize,
        });
        const run_test = b.addRunArtifact(test_exe);
        const step_name = "test-" ++ std.fs.path.stem(module_path);
        const step = b.step(step_name, b.fmt("Run tests for {s}", .{module_path}));
        step.dependOn(&run_test.step);
        test_step.dependOn(&run_test.step);
    }
    
    // Group tests
    const test_crypto = b.step("test-crypto", "Run crypto tests");
    const crypto_modules = [_][]const u8{
        "core/secp256k1.zig",
        "core/schnorr.zig",
        "core/bls_signatures.zig",
        "core/pq_crypto.zig",
        "core/bip32_wallet.zig",
        "core/wallet.zig",
        "core/hybrid_signature.zig",
    };
    for (crypto_modules) |mod| {
        const test_exe = b.addTest(.{ .root_source_file = b.path(mod), .target = target, .optimize = optimize });
        const run_test = b.addRunArtifact(test_exe);
        test_crypto.dependOn(&run_test.step);
    }
    
    const test_chain = b.step("test-chain", "Run chain tests");
    const chain_modules = [_][]const u8{
        "core/utxo.zig",
        "core/mempool.zig",
        "core/transaction.zig",
        "core/script.zig",
        "core/block.zig",
        "core/consensus_pouw.zig",
        "core/finality.zig",
        "core/staking.zig",
    };
    for (chain_modules) |mod| {
        const test_exe = b.addTest(.{ .root_source_file = b.path(mod), .target = target, .optimize = optimize });
        const run_test = b.addRunArtifact(test_exe);
        test_chain.dependOn(&run_test.step);
    }
    
    const test_net = b.step("test-net", "Run network tests");
    const net_modules = [_][]const u8{
        "core/network.zig",
        "core/p2p.zig",
        "core/encrypted_p2p.zig",
        "core/kademlia_dht.zig",
        "core/pq_handshake.zig",
    };
    for (net_modules) |mod| {
        const test_exe = b.addTest(.{ .root_source_file = b.path(mod), .target = target, .optimize = optimize });
        const run_test = b.addRunArtifact(test_exe);
        test_net.dependOn(&run_test.step);
    }
    
    const test_pq = b.step("test-pq", "Run post-quantum tests");
    const pq_modules = [_][]const u8{
        "core/pq_crypto.zig",
        "core/pq_handshake.zig",
        "core/hybrid_signature.zig",
    };
    for (pq_modules) |mod| {
        const test_exe = b.addTest(.{ .root_source_file = b.path(mod), .target = target, .optimize = optimize });
        const run_test = b.addRunArtifact(test_exe);
        test_pq.dependOn(&run_test.step);
    }
}