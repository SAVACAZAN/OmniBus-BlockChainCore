const std = @import("std");

// liboqs paths — Windows native (compilat cu MinGW in liboqs-src/build)
const LIBOQS_INCLUDE = "C:/Kits work/limaje de programare/liboqs-src/build/include";
const LIBOQS_LIB     = "C:/Kits work/limaje de programare/liboqs-src/build/lib/liboqs.a";

fn addOqs(step: *std.Build.Step.Compile, enable: bool) void {
    if (enable) {
        step.addIncludePath(.{ .cwd_relative = LIBOQS_INCLUDE });
        step.addObjectFile(.{ .cwd_relative = LIBOQS_LIB });
        step.linkLibC();
    }
}

/// Adauga un test fara dependinte externe (fara liboqs)
fn addTest(b: *std.Build, name: []const u8, path: []const u8,
           target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Run {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target   = target,
            .optimize = optimize,
        }),
    });
    _ = name;
    return b.addRunArtifact(t);
}

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_oqs  = b.option(bool, "oqs", "Link liboqs for PQ crypto (default: auto-detect)") orelse true;

    // ── Executabile ───────────────────────────────────────────────────────────

    const blockchain_exe = b.addExecutable(.{
        .name        = "omnibus-node",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/main.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    addOqs(blockchain_exe, use_oqs);
    // p2p.zig uses std.posix.recvfrom (UDP knock-knock) which requires libc
    // Link it unconditionally so -Doqs=false still builds
    blockchain_exe.linkLibC();
    b.installArtifact(blockchain_exe);

    const rpc_exe = b.addExecutable(.{
        .name        = "omnibus-rpc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/rpc_server.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    addOqs(rpc_exe, use_oqs);
    b.installArtifact(rpc_exe);

    // ── Benchmark executable ────────────────────────────────────────────────
    const bench_exe = b.addExecutable(.{
        .name        = "omnibus-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/benchmark.zig"),
            .target           = target,
            .optimize         = .ReleaseFast,
        }),
    });
    b.installArtifact(bench_exe);

    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run performance benchmarks");
    bench_step.dependOn(&bench_run.step);

    // ── WASM wallet (build with: zig build-exe core/wasm_exports.zig -target wasm32-freestanding -OReleaseFast -fno-entry -femit-bin=wasm/omnibus-wallet.wasm --export-memory)
    // Note: build.zig addExecutable doesn't support -fno-entry for wasm yet,
    // use the command above or: zig build wasm-info
    const wasm_info = b.step("wasm", "Show WASM build command");
    _ = wasm_info; // WASM build: zig build-exe core/wasm_exports.zig -target wasm32-freestanding -OReleaseFast -fno-entry -femit-bin=wasm/omnibus-wallet.wasm --export-memory

    // ── Run step ──────────────────────────────────────────────────────────────
    const run_blockchain = b.addRunArtifact(blockchain_exe);
    const run_step = b.step("run", "Run blockchain node");
    run_step.dependOn(&run_blockchain.step);

    // ── Tests: crypto (fara PQ, fara liboqs) ─────────────────────────────────
    const test_crypto_step = b.step("test-crypto", "Test secp256k1 + BIP32 + crypto");
    test_crypto_step.dependOn(&addTest(b, "secp256k1",  "core/secp256k1.zig",  target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "bip32",      "core/bip32_wallet.zig", target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "crypto",     "core/crypto.zig",     target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "ripemd160",  "core/ripemd160.zig",  target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "schnorr",    "core/schnorr.zig",    target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "multisig",   "core/multisig.zig",   target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "peer-score", "core/peer_scoring.zig", target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "chain-cfg",  "core/chain_config.zig", target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "bls",        "core/bls_signatures.zig", target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "staking",    "core/staking.zig",      target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "tx-receipt", "core/tx_receipt.zig",   target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "dns",        "core/dns_registry.zig", target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "guardian",   "core/guardian.zig",     target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "compact-blk","core/compact_blocks.zig", target, optimize).step);
    test_crypto_step.dependOn(&addTest(b, "kademlia",   "core/kademlia_dht.zig", target, optimize).step);

    // ── Tests: blockchain core ────────────────────────────────────────────────
    const test_chain_step = b.step("test-chain", "Test blockchain + genesis + consensus");
    test_chain_step.dependOn(&addTest(b, "block",       "core/block.zig",       target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "finality",    "core/finality.zig",    target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "governance",  "core/governance.zig",  target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "transaction", "core/transaction.zig", target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "blockchain",  "core/blockchain.zig",  target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "genesis",     "core/genesis.zig",     target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "mempool",     "core/mempool.zig",     target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "consensus",   "core/consensus.zig",   target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "database",    "core/database.zig",    target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "miner-genesis", "core/miner_genesis.zig", target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "e2e-mining",   "core/e2e_mining.zig",   target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "script",       "core/script.zig",       target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "miner-wallet", "core/miner_wallet.zig", target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "payment-ch",  "core/payment_channel.zig", target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "metachain",   "core/metachain.zig",      target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "shard-coord", "core/shard_coordinator.zig", target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "oracle",      "core/oracle.zig",         target, optimize).step);
    test_chain_step.dependOn(&addTest(b, "spark-inv",   "core/spark_invariants.zig", target, optimize).step);

    // ── Tests: network + P2P + sync ───────────────────────────────────────────
    const test_net_step = b.step("test-net", "Test P2P + sync + network");
    test_net_step.dependOn(&addTest(b, "rpc",     "core/rpc_server.zig", target, optimize).step);
    test_net_step.dependOn(&addTest(b, "p2p",     "core/p2p.zig",     target, optimize).step);
    test_net_step.dependOn(&addTest(b, "sync",    "core/sync.zig",    target, optimize).step);
    test_net_step.dependOn(&addTest(b, "network", "core/network.zig", target, optimize).step);
    test_net_step.dependOn(&addTest(b, "node-launcher", "core/node_launcher.zig", target, optimize).step);
    test_net_step.dependOn(&addTest(b, "bootstrap", "core/bootstrap.zig", target, optimize).step);
    test_net_step.dependOn(&addTest(b, "cli",          "core/cli.zig",          target, optimize).step);
    test_net_step.dependOn(&addTest(b, "vault-reader", "core/vault_reader.zig", target, optimize).step);
    test_net_step.dependOn(&addTest(b, "ws-server",    "core/ws_server.zig",    target, optimize).step);

    // ── Tests: sub-blocks + sharding ─────────────────────────────────────────
    const test_shard_step = b.step("test-shard", "Test sub-blocks + sharding");
    test_shard_step.dependOn(&addTest(b, "sub-block",   "core/sub_block.zig",   target, optimize).step);
    test_shard_step.dependOn(&addTest(b, "shard-config", "core/shard_config.zig", target, optimize).step);
    test_shard_step.dependOn(&addTest(b, "blockchain-v2", "core/blockchain_v2.zig", target, optimize).step);

    // ── Tests: storage + binary + archive ────────────────────────────────────
    const test_storage_step = b.step("test-storage", "Test storage + binary codec");
    test_storage_step.dependOn(&addTest(b, "storage",        "core/storage.zig",          target, optimize).step);
    test_storage_step.dependOn(&addTest(b, "binary-codec",   "core/binary_codec.zig",     target, optimize).step);
    test_storage_step.dependOn(&addTest(b, "archive",        "core/archive_manager.zig",  target, optimize).step);
    test_storage_step.dependOn(&addTest(b, "prune-config",   "core/prune_config.zig",     target, optimize).step);
    test_storage_step.dependOn(&addTest(b, "state-trie",     "core/state_trie.zig",       target, optimize).step);
    test_storage_step.dependOn(&addTest(b, "compact-tx",     "core/compact_transaction.zig", target, optimize).step);
    test_storage_step.dependOn(&addTest(b, "witness",        "core/witness_data.zig",     target, optimize).step);

    // ── Tests: light client + miner ───────────────────────────────────────────
    const test_light_step = b.step("test-light", "Test light client + light miner");
    test_light_step.dependOn(&addTest(b, "light-client", "core/light_client.zig", target, optimize).step);
    test_light_step.dependOn(&addTest(b, "light-miner",  "core/light_miner.zig",  target, optimize).step);
    test_light_step.dependOn(&addTest(b, "mining-pool",  "core/mining_pool.zig",  target, optimize).step);
    test_light_step.dependOn(&addTest(b, "key-encryption", "core/key_encryption.zig", target, optimize).step);

    // ── Tests: economic + ecosystem ──────────────────────────────────────────
    const test_econ_step = b.step("test-econ", "Test economic modules (UBI, bread, bridge, vault, domain, brain)");
    test_econ_step.dependOn(&addTest(b, "bread-ledger",  "core/bread_ledger.zig",     target, optimize).step);
    test_econ_step.dependOn(&addTest(b, "bridge-relay",  "core/bridge_relay.zig",     target, optimize).step);
    test_econ_step.dependOn(&addTest(b, "domain-minter", "core/domain_minter.zig",    target, optimize).step);
    test_econ_step.dependOn(&addTest(b, "ubi-dist",      "core/ubi_distributor.zig",  target, optimize).step);
    test_econ_step.dependOn(&addTest(b, "vault-engine",  "core/vault_engine.zig",     target, optimize).step);
    test_econ_step.dependOn(&addTest(b, "omni-brain",    "core/omni_brain.zig",       target, optimize).step);
    test_econ_step.dependOn(&addTest(b, "os-mode",       "core/os_mode.zig",          target, optimize).step);
    test_econ_step.dependOn(&addTest(b, "synapse-prio",  "core/synapse_priority.zig", target, optimize).step);

    // ── Tests: benchmark + metrics ──────────────────────────────────────────
    const test_bench_step = b.step("test-bench", "Test benchmark + metrics");
    test_bench_step.dependOn(&addTest(b, "benchmark", "core/benchmark.zig", target, optimize).step);

    // ── Tests: PQ crypto pure Zig (fara liboqs) ───────────────────────────────
    const test_pq_step = b.step("test-pq", "Test PQ crypto pure Zig + wallet (necesita liboqs pt wallet)");
    test_pq_step.dependOn(&addTest(b, "pq-crypto", "core/pq_crypto.zig", target, optimize).step);

    // ── Tests: wallet (necesita liboqs) ──────────────────────────────────────
    const test_pq_wallet = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/wallet.zig"),
            .target = target, .optimize = optimize,
        }),
    });
    addOqs(test_pq_wallet, use_oqs);
    const test_wallet_step = b.step("test-wallet", "Test wallet (necesita liboqs)");
    test_wallet_step.dependOn(&b.addRunArtifact(test_pq_wallet).step);

    // ── test (toate fara PQ) ──────────────────────────────────────────────────
    const test_all_step = b.step("test", "Run all tests (fara liboqs)");
    test_all_step.dependOn(&addTest(b, "secp256k1",    "core/secp256k1.zig",    target, optimize).step);
    test_all_step.dependOn(&addTest(b, "bip32",        "core/bip32_wallet.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "crypto",       "core/crypto.zig",       target, optimize).step);
    test_all_step.dependOn(&addTest(b, "ripemd160",    "core/ripemd160.zig",    target, optimize).step);
    test_all_step.dependOn(&addTest(b, "block",        "core/block.zig",        target, optimize).step);
    test_all_step.dependOn(&addTest(b, "blockchain",   "core/blockchain.zig",   target, optimize).step);
    test_all_step.dependOn(&addTest(b, "transaction",  "core/transaction.zig",  target, optimize).step);
    test_all_step.dependOn(&addTest(b, "genesis",      "core/genesis.zig",      target, optimize).step);
    test_all_step.dependOn(&addTest(b, "mempool",      "core/mempool.zig",      target, optimize).step);
    test_all_step.dependOn(&addTest(b, "consensus",    "core/consensus.zig",    target, optimize).step);
    test_all_step.dependOn(&addTest(b, "database",     "core/database.zig",     target, optimize).step);
    test_all_step.dependOn(&addTest(b, "e2e-mining",   "core/e2e_mining.zig",   target, optimize).step);
    test_all_step.dependOn(&addTest(b, "miner-genesis","core/miner_genesis.zig",target, optimize).step);
    test_all_step.dependOn(&addTest(b, "rpc",          "core/rpc_server.zig",   target, optimize).step);
    test_all_step.dependOn(&addTest(b, "p2p",          "core/p2p.zig",          target, optimize).step);
    test_all_step.dependOn(&addTest(b, "sync",         "core/sync.zig",         target, optimize).step);
    test_all_step.dependOn(&addTest(b, "network",      "core/network.zig",      target, optimize).step);
    test_all_step.dependOn(&addTest(b, "node-launcher","core/node_launcher.zig",target, optimize).step);
    test_all_step.dependOn(&addTest(b, "bootstrap",    "core/bootstrap.zig",    target, optimize).step);
    test_all_step.dependOn(&addTest(b, "cli",          "core/cli.zig",          target, optimize).step);
    test_all_step.dependOn(&addTest(b, "vault-reader", "core/vault_reader.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "sub-block",    "core/sub_block.zig",    target, optimize).step);
    test_all_step.dependOn(&addTest(b, "shard-config", "core/shard_config.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "blockchain-v2","core/blockchain_v2.zig",target, optimize).step);
    test_all_step.dependOn(&addTest(b, "storage",      "core/storage.zig",      target, optimize).step);
    test_all_step.dependOn(&addTest(b, "binary-codec", "core/binary_codec.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "archive",      "core/archive_manager.zig",target, optimize).step);
    test_all_step.dependOn(&addTest(b, "prune-config", "core/prune_config.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "state-trie",   "core/state_trie.zig",   target, optimize).step);
    test_all_step.dependOn(&addTest(b, "compact-tx",   "core/compact_transaction.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "witness",      "core/witness_data.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "light-client", "core/light_client.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "light-miner",  "core/light_miner.zig",  target, optimize).step);
    test_all_step.dependOn(&addTest(b, "mining-pool",  "core/mining_pool.zig",  target, optimize).step);
    test_all_step.dependOn(&addTest(b, "key-encryption","core/key_encryption.zig",target, optimize).step);
    test_all_step.dependOn(&addTest(b, "pq-crypto",    "core/pq_crypto.zig",    target, optimize).step);
    test_all_step.dependOn(&addTest(b, "schnorr",      "core/schnorr.zig",      target, optimize).step);
    test_all_step.dependOn(&addTest(b, "multisig",     "core/multisig.zig",     target, optimize).step);
    test_all_step.dependOn(&addTest(b, "finality",     "core/finality.zig",     target, optimize).step);
    test_all_step.dependOn(&addTest(b, "governance",   "core/governance.zig",   target, optimize).step);
    test_all_step.dependOn(&addTest(b, "peer-score",   "core/peer_scoring.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "chain-cfg",    "core/chain_config.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "bls",          "core/bls_signatures.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "staking",      "core/staking.zig",      target, optimize).step);
    test_all_step.dependOn(&addTest(b, "tx-receipt",   "core/tx_receipt.zig",   target, optimize).step);
    test_all_step.dependOn(&addTest(b, "dns",          "core/dns_registry.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "guardian",     "core/guardian.zig",     target, optimize).step);
    test_all_step.dependOn(&addTest(b, "compact-blk", "core/compact_blocks.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "kademlia",    "core/kademlia_dht.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "hex-utils",   "core/hex_utils.zig",    target, optimize).step);
    test_all_step.dependOn(&addTest(b, "script",      "core/script.zig",       target, optimize).step);
    test_all_step.dependOn(&addTest(b, "miner-wallet","core/miner_wallet.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "payment-ch", "core/payment_channel.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "benchmark",  "core/benchmark.zig",    target, optimize).step);
    test_all_step.dependOn(&addTest(b, "bread-ledger",  "core/bread_ledger.zig",     target, optimize).step);
    test_all_step.dependOn(&addTest(b, "bridge-relay",  "core/bridge_relay.zig",     target, optimize).step);
    test_all_step.dependOn(&addTest(b, "domain-minter", "core/domain_minter.zig",    target, optimize).step);
    test_all_step.dependOn(&addTest(b, "metachain",     "core/metachain.zig",        target, optimize).step);
    test_all_step.dependOn(&addTest(b, "omni-brain",    "core/omni_brain.zig",       target, optimize).step);
    test_all_step.dependOn(&addTest(b, "oracle",        "core/oracle.zig",           target, optimize).step);
    test_all_step.dependOn(&addTest(b, "os-mode",       "core/os_mode.zig",          target, optimize).step);
    test_all_step.dependOn(&addTest(b, "shard-coord",   "core/shard_coordinator.zig",target, optimize).step);
    test_all_step.dependOn(&addTest(b, "spark-inv",     "core/spark_invariants.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "synapse-prio",  "core/synapse_priority.zig", target, optimize).step);
    test_all_step.dependOn(&addTest(b, "ubi-dist",      "core/ubi_distributor.zig",  target, optimize).step);
    test_all_step.dependOn(&addTest(b, "vault-engine",  "core/vault_engine.zig",     target, optimize).step);
    test_all_step.dependOn(&addTest(b, "ws-server",     "core/ws_server.zig",        target, optimize).step);
}
