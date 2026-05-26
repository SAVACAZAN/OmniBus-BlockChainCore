const std = @import("std");

// liboqs paths — detectate automat per OS:
//   Windows: C:/Kits work/... (MinGW build)
//   Linux:   /root/liboqs-src/build (compilat nativ pe VPS)
fn liboqsPaths() struct { include: []const u8, lib: []const u8 } {
    return switch (@import("builtin").os.tag) {
        .linux   => .{
            .include = "/root/liboqs-src/build/include",
            .lib     = "/root/liboqs-src/build/lib/liboqs.a",
        },
        else     => .{
            .include = "C:/Kits work/limaje de programare/1_CORE/liboqs-src/build/include",
            .lib     = "C:/Kits work/limaje de programare/1_CORE/liboqs-src/build/lib/liboqs.a",
        },
    };
}

fn addOqs(step: *std.Build.Step.Compile, enable: bool) void {
    if (enable) {
        const paths = liboqsPaths();
        step.root_module.addIncludePath(.{ .cwd_relative = paths.include });
        step.root_module.addObjectFile(.{ .cwd_relative = paths.lib });
        step.root_module.link_libc = true;
    }
}

// omnibus-evm Rust static lib (revm wrapper).
// Build with: cd evm && cargo build --release
// Output: evm/target/release/omnibus_evm.lib (MSVC) / libomnibus_evm.a (gnu/unix).
const EVM_LIB_DIR = "evm/target/release";

fn addEvm(step: *std.Build.Step.Compile, enable: bool) void {
    if (!enable) return;
    // Zig 0.16: linker config moved onto root_module. linkSystemLibrary now
    // takes an options struct (use empty .{} for defaults) and linkFramework
    // also takes options.
    const m = step.root_module;
    m.addLibraryPath(.{ .cwd_relative = EVM_LIB_DIR });
    m.linkSystemLibrary("omnibus_evm", .{});
    m.link_libc = true;
    const tag = step.rootModuleTarget().os.tag;
    // The Rust static lib pulls in OS system deps (ring, std::sync,
    // std::time, randomness). Different platforms need different libs.
    if (tag == .windows) {
        m.linkSystemLibrary("ntdll", .{});
        m.linkSystemLibrary("userenv", .{});
        m.linkSystemLibrary("bcrypt", .{});
        m.linkSystemLibrary("advapi32", .{});
        m.linkSystemLibrary("ws2_32", .{});
        m.linkSystemLibrary("kernel32", .{});
        m.linkSystemLibrary("user32", .{});
        // MSVC compatibility shim: Rust staticlib (MSVC ABI) references
        // _fltused (FP usage flag) which MinGW/lld-link doesn't provide.
        m.addCSourceFile(.{
            .file  = .{ .cwd_relative = "evm/msvc_compat.c" },
            .flags = &.{},
        });
    } else if (tag == .linux) {
        // Rust glibc staticlib needs: pthread (sync), dl (dynamic loading),
        // m (math), util (random), rt (timers), gcc_s (_Unwind_* for panics).
        m.linkSystemLibrary("pthread", .{});
        m.linkSystemLibrary("dl", .{});
        m.linkSystemLibrary("m", .{});
        m.linkSystemLibrary("util", .{});
        m.linkSystemLibrary("rt", .{});
        m.linkSystemLibrary("gcc_s", .{});
    } else if (tag == .macos) {
        m.linkFramework("Security", .{});
        m.linkFramework("CoreFoundation", .{});
    }
}

/// Adauga un test fara dependinte externe (fara liboqs).
/// Injecteaza build_options (oqs_enabled/evm_enabled) in toate modulele de test
/// ca sa nu apara erori "module not found" in fisiere precum pq_crypto.zig.
fn addTest(b: *std.Build, name: []const u8, path: []const u8,
           target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode,
           opts: *std.Build.Step.Options) *std.Build.Step.Run {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target   = target,
            .optimize = optimize,
        }),
    });
    _ = name;
    t.root_module.addOptions("build_options", opts);
    return b.addRunArtifact(t);
}

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_oqs  = b.option(bool, "oqs", "Link liboqs for PQ crypto (default: auto-detect)") orelse true;
    // EVM (revm) is OFF by default — the Rust crate at evm/ is optional and many
    // build hosts (VPS, CI) don't have the Rust toolchain. Opt in with `-Devm=true`
    // after building the crate: `cd evm && cargo build --release`.
    const use_evm  = b.option(bool, "evm", "Link omnibus-evm (revm) Rust static lib") orelse false;

    // build_options module — exposes feature flags to Zig code so we can
    // compile-out FFI declarations and stub handlers when a dependency is
    // disabled. Without this, ffi files still declare `extern "c" fn ...`
    // and the linker complains about undefined symbols even with -Dfoo=false.
    const build_options = b.addOptions();
    build_options.addOption(bool, "evm_enabled", use_evm);
    build_options.addOption(bool, "oqs_enabled", use_oqs);

    // ── Executabile ───────────────────────────────────────────────────────────

    const blockchain_exe = b.addExecutable(.{
        .name        = "omnibus-node",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/main.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    blockchain_exe.root_module.addOptions("build_options", build_options);
    addOqs(blockchain_exe, use_oqs);
    addEvm(blockchain_exe, use_evm);
    // p2p.zig uses std.posix.recvfrom (UDP knock-knock) which requires libc
    // Link it unconditionally so -Doqs=false still builds
    // Zig 0.16: link_libc is a Module field, set via assignment.
    blockchain_exe.root_module.link_libc = true;
    // Windows default exe stack is 1MB; Blockchain struct + genesis arrays overflow it.
    // Match Linux thread stack (LimitSTACK=infinity workaround on VPS).
    blockchain_exe.stack_size = 64 * 1024 * 1024;
    b.installArtifact(blockchain_exe);

    const rpc_exe = b.addExecutable(.{
        .name        = "omnibus-rpc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/rpc_server.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    rpc_exe.root_module.addOptions("build_options", build_options);
    addOqs(rpc_exe, use_oqs);
    addEvm(rpc_exe, use_evm);
    rpc_exe.root_module.link_libc = true;
    b.installArtifact(rpc_exe);

    // ── omnibus-oracle ───────────────────────────────────────────────────────
    // Standalone process — runs the WS exchange feed (Coinbase, Kraken, LCX)
    // out-of-process from the chain so mining-loop CPU isn't shared with
    // 3 always-on WebSocket workers + JSON parsers + price hashmap mutex.
    // BTC pattern: chain-only daemon, oracle is a separate service.
    const oracle_exe = b.addExecutable(.{
        .name        = "omnibus-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/oracle_main.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    oracle_exe.root_module.link_libc = true;
    b.installArtifact(oracle_exe);

    // ── omnibus-cli ───────────────────────────────────────────────────────────
    // Standalone audit tool. Connects to a running node via JSON-RPC and prints
    // balance / stake / reputation / daily-breakdown / verify reports — same
    // data the React DailyAuditPage shows, but no browser required.
    // Pure stdlib + libc (no liboqs, no EVM). Build: `zig build install`.
    const cli_exe = b.addExecutable(.{
        .name = "omnibus-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/cli_audit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_exe.linkLibC();
    b.installArtifact(cli_exe);

    // ── omnibus-agents ───────────────────────────────────────────────────────
    // Stub binary — same multi-process pattern as omnibus-oracle. The chain
    // skips its in-process AgentManager when OMNIBUS_EXTERNAL_AGENTS=1, so
    // running this stub idle is enough to validate the plumbing. Real
    // agent_executor migration is a follow-up session.
    const agents_exe = b.addExecutable(.{
        .name        = "omnibus-agents",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/agents_main.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    agents_exe.root_module.link_libc = true;
    b.installArtifact(agents_exe);

    // ── omnibus-explorer ─────────────────────────────────────────────────────
    // Stub binary for the future block-explorer / WebSocket-broadcast
    // service. Real frontend HTTP/WS migration is a follow-up session.
    const explorer_exe = b.addExecutable(.{
        .name        = "omnibus-explorer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/explorer_main.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    explorer_exe.root_module.link_libc = true;
    b.installArtifact(explorer_exe);

    // ── omnibus-exchange ─────────────────────────────────────────────────────
    // Stub binary for the future DEX matching-engine service. Sensitive
    // component (orderbook, fees, paper/real isolation, balance updates) —
    // intentionally deferred to a dedicated session with thorough
    // integration testing.
    const exchange_exe = b.addExecutable(.{
        .name        = "omnibus-exchange",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/exchange_main.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    exchange_exe.root_module.link_libc = true;
    b.installArtifact(exchange_exe);

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
    test_crypto_step.dependOn(&addTest(b, "secp256k1",  "core/secp256k1.zig",  target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "bip32",      "core/bip32_wallet.zig", target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "crypto",     "core/crypto.zig",     target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "ripemd160",  "core/ripemd160.zig",  target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "schnorr",    "core/schnorr.zig",    target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "multisig",   "core/multisig.zig",   target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "peer-score", "core/peer_scoring.zig", target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "chain-cfg",  "core/chain_config.zig", target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "bls",        "core/bls_signatures.zig", target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "staking",    "core/staking.zig",      target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "tx-receipt", "core/tx_receipt.zig",   target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "dns",        "core/dns_registry.zig", target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "guardian",   "core/guardian.zig",     target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "compact-blk","core/compact_blocks.zig", target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "kademlia",   "core/kademlia_dht.zig", target, optimize, build_options).step);

    // New v0.2.0 modules
    test_crypto_step.dependOn(&addTest(b, "bech32",       "core/bech32.zig",       target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "encrypted-p2p","core/encrypted_p2p.zig",target, optimize, build_options).step);
    test_crypto_step.dependOn(&addTest(b, "isolated-wallet","core/isolated_wallet_test.zig", target, optimize, build_options).step);

    // ── Tests: blockchain core ────────────────────────────────────────────────
    const test_chain_step = b.step("test-chain", "Test blockchain + genesis + consensus");
    test_chain_step.dependOn(&addTest(b, "block",       "core/block.zig",       target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "finality",    "core/finality.zig",    target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "governance",  "core/governance.zig",  target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "transaction", "core/transaction.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "blockchain",  "core/blockchain.zig",  target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "genesis",     "core/genesis.zig",     target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "mempool",     "core/mempool.zig",     target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "consensus",   "core/consensus.zig",   target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "database",    "core/database.zig",    target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "miner-genesis", "core/miner_genesis.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "e2e-mining",   "core/e2e_mining.zig",   target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "script",       "core/script.zig",       target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "miner-wallet", "core/miner_wallet.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "payment-ch",  "core/payment_channel.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "metachain",   "core/metachain.zig",      target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "shard-coord", "core/shard_coordinator.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "oracle",      "core/oracle.zig",         target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "spark-inv",   "core/spark_invariants.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "utxo",        "core/utxo.zig",           target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "psbt",        "core/psbt.zig",           target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "htlc",        "core/htlc.zig",           target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "htlc-btc",    "core/htlc_btc.zig",       target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "lightning",   "core/lightning.zig",       target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "block-filter","core/block_filter.zig",    target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "matching",   "core/matching_engine.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "price-oracle","core/price_oracle.zig",   target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "pouw",       "core/consensus_pouw.zig",  target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "oracle-fetcher", "core/oracle_fetcher.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "agent-tier",     "core/agent_tier.zig",     target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "agent-config",   "core/agent_config.zig",   target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "agent-executor", "core/agent_executor.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "agent-manager",  "core/agent_manager.zig",  target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "agent-wallet",   "core/agent_wallet.zig",   target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "pair-registry",  "core/pair_registry.zig",  target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "order-swap-link","core/order_swap_link.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "intent-registry","core/intent_registry.zig", target, optimize, build_options).step);
    test_chain_step.dependOn(&addTest(b, "grid-engine",   "core/grid_engine.zig",     target, optimize, build_options).step);

    // ── Tests: network + P2P + sync ───────────────────────────────────────────
    const test_net_step = b.step("test-net", "Test P2P + sync + network");
    test_net_step.dependOn(&addTest(b, "rpc",     "core/rpc_server.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "p2p",     "core/p2p.zig",     target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "sync",    "core/sync.zig",    target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "network", "core/network.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "node-launcher", "core/node_launcher.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "bootstrap", "core/bootstrap.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "cli",          "core/cli.zig",          target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "vault-reader", "core/vault_reader.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "ws-server",    "core/ws_server.zig",    target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "tor-proxy",    "core/tor_proxy.zig",    target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "ob-sync",     "core/orderbook_sync.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "br-listener", "core/bridge_listener.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "settlement",  "core/settlement_submitter.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "peer-persist","core/peer_persist.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "spv-btc",    "core/spv_btc.zig",       target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "spv-eth",    "core/spv_eth.zig",       target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "spv-eth-tv", "core/spv_eth_test_vectors.zig", target, optimize, build_options).step);
    test_net_step.dependOn(&addTest(b, "xchain-oracle","core/cross_chain_oracle.zig", target, optimize, build_options).step);

    // ── Tests: sub-blocks + sharding ─────────────────────────────────────────
    const test_shard_step = b.step("test-shard", "Test sub-blocks + sharding");
    test_shard_step.dependOn(&addTest(b, "sub-block",   "core/sub_block.zig",   target, optimize, build_options).step);
    test_shard_step.dependOn(&addTest(b, "shard-config", "core/shard_config.zig", target, optimize, build_options).step);
    test_shard_step.dependOn(&addTest(b, "blockchain-v2", "core/blockchain_v2.zig", target, optimize, build_options).step);

    // ── Tests: storage + binary + archive ────────────────────────────────────
    const test_storage_step = b.step("test-storage", "Test storage + binary codec");
    test_storage_step.dependOn(&addTest(b, "storage",        "core/storage.zig",          target, optimize, build_options).step);
    test_storage_step.dependOn(&addTest(b, "binary-codec",   "core/binary_codec.zig",     target, optimize, build_options).step);
    test_storage_step.dependOn(&addTest(b, "archive",        "core/archive_manager.zig",  target, optimize, build_options).step);
    test_storage_step.dependOn(&addTest(b, "prune-config",   "core/prune_config.zig",     target, optimize, build_options).step);
    test_storage_step.dependOn(&addTest(b, "state-trie",     "core/state_trie.zig",       target, optimize, build_options).step);
    test_storage_step.dependOn(&addTest(b, "compact-tx",     "core/compact_transaction.zig", target, optimize, build_options).step);
    test_storage_step.dependOn(&addTest(b, "witness",        "core/witness_data.zig",     target, optimize, build_options).step);

    // ── Tests: light client + miner ───────────────────────────────────────────
    const test_light_step = b.step("test-light", "Test light client + light miner");
    test_light_step.dependOn(&addTest(b, "light-client", "core/light_client.zig", target, optimize, build_options).step);
    test_light_step.dependOn(&addTest(b, "light-miner",  "core/light_miner.zig",  target, optimize, build_options).step);
    test_light_step.dependOn(&addTest(b, "mining-pool",  "core/mining_pool.zig",  target, optimize, build_options).step);
    test_light_step.dependOn(&addTest(b, "key-encryption", "core/key_encryption.zig", target, optimize, build_options).step);

    // ── Tests: economic + ecosystem ──────────────────────────────────────────
    const test_econ_step = b.step("test-econ", "Test economic modules (UBI, bread, bridge, vault, domain, brain)");
    test_econ_step.dependOn(&addTest(b, "bread-ledger",  "core/bread_ledger.zig",     target, optimize, build_options).step);
    test_econ_step.dependOn(&addTest(b, "bridge-relay",  "core/bridge_relay.zig",     target, optimize, build_options).step);
    test_econ_step.dependOn(&addTest(b, "domain-minter", "core/domain_minter.zig",    target, optimize, build_options).step);
    test_econ_step.dependOn(&addTest(b, "ubi-dist",      "core/ubi_distributor.zig",  target, optimize, build_options).step);
    test_econ_step.dependOn(&addTest(b, "vault-engine",  "core/vault_engine.zig",     target, optimize, build_options).step);
    test_econ_step.dependOn(&addTest(b, "omni-brain",    "core/omni_brain.zig",       target, optimize, build_options).step);
    test_econ_step.dependOn(&addTest(b, "os-mode",       "core/os_mode.zig",          target, optimize, build_options).step);
    test_econ_step.dependOn(&addTest(b, "synapse-prio",  "core/synapse_priority.zig", target, optimize, build_options).step);

    // ── Tests: benchmark + metrics ──────────────────────────────────────────
    const test_bench_step = b.step("test-bench", "Test benchmark + metrics");
    test_bench_step.dependOn(&addTest(b, "benchmark", "core/benchmark.zig", target, optimize, build_options).step);

    // ── Tests: OmniBus ID (identity layer) ──────────────────────────────────
    // The test runner lives at core/ (NOT inside core/identity/) because Zig
    // 0.15.2 forbids `@import("../...")` from a test root file. No liboqs
    // required — all crypto goes through std.crypto.sha2.
    const test_id_step = b.step("test-id", "Test OmniBus ID layer (DID, manifest, OBM, disclosure)");
    test_id_step.dependOn(&addTest(b, "identity",
        "core/identity_test_runner.zig", target, optimize, build_options).step);

    // ── Tests: PQ crypto cu liboqs ───────────────────────────────────────────
    // pq_crypto.zig cheama liboqs C bindings via @cImport — necesita link.
    // build_options (oqs_enabled) injected ca sa poate gate-ui @cImport comptime.
    const test_pq_crypto = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/pq_crypto.zig"),
            .target = target, .optimize = optimize,
        }),
    });
    test_pq_crypto.root_module.addOptions("build_options", build_options);
    addOqs(test_pq_crypto, use_oqs);
    test_pq_crypto.root_module.link_libc = true;
    const test_pq_step = b.step("test-pq", "Test PQ crypto cu liboqs (real FIPS 203/204/205/206)");
    test_pq_step.dependOn(&b.addRunArtifact(test_pq_crypto).step);

    // FAZA 6 — PQ migration consensus module + standalone tests
    const test_pq_migrate = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/pq_migrate_consensus.zig"),
            .target = target, .optimize = optimize,
        }),
    });
    test_pq_migrate.root_module.addOptions("build_options", build_options);
    addOqs(test_pq_migrate, use_oqs);
    test_pq_migrate.root_module.link_libc = true;
    test_pq_step.dependOn(&b.addRunArtifact(test_pq_migrate).step);

    const test_pq_migrate_ext = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/pq_migrate_test.zig"),
            .target = target, .optimize = optimize,
        }),
    });
    test_pq_migrate_ext.root_module.addOptions("build_options", build_options);
    addOqs(test_pq_migrate_ext, use_oqs);
    test_pq_migrate_ext.root_module.link_libc = true;
    test_pq_step.dependOn(&b.addRunArtifact(test_pq_migrate_ext).step);

    // ── Tests: wallet (necesita liboqs) ──────────────────────────────────────
    const test_pq_wallet = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/wallet.zig"),
            .target = target, .optimize = optimize,
        }),
    });
    test_pq_wallet.root_module.addOptions("build_options", build_options);
    addOqs(test_pq_wallet, use_oqs);
    const test_wallet_step = b.step("test-wallet", "Test wallet (necesita liboqs)");
    test_wallet_step.dependOn(&b.addRunArtifact(test_pq_wallet).step);

    // FAZA 6 — deterministic PQ signing tests
    const test_sign_det = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/sign_all_pq_domains_deterministic_test.zig"),
            .target = target, .optimize = optimize,
        }),
    });
    test_sign_det.root_module.addOptions("build_options", build_options);
    addOqs(test_sign_det, use_oqs);
    test_sign_det.root_module.link_libc = true;
    test_wallet_step.dependOn(&b.addRunArtifact(test_sign_det).step);

    // ── test (toate fara PQ) ──────────────────────────────────────────────────
    const test_all_step = b.step("test", "Run all tests (fara liboqs)");
    test_all_step.dependOn(&addTest(b, "secp256k1",    "core/secp256k1.zig",    target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "bip32",        "core/bip32_wallet.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "crypto",       "core/crypto.zig",       target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "ripemd160",    "core/ripemd160.zig",    target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "block",        "core/block.zig",        target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "blockchain",   "core/blockchain.zig",   target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "transaction",  "core/transaction.zig",  target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "genesis",      "core/genesis.zig",      target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "mempool",      "core/mempool.zig",      target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "consensus",    "core/consensus.zig",    target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "database",     "core/database.zig",     target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "e2e-mining",   "core/e2e_mining.zig",   target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "miner-genesis","core/miner_genesis.zig",target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "rpc",          "core/rpc_server.zig",   target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "p2p",          "core/p2p.zig",          target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "sync",         "core/sync.zig",         target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "network",      "core/network.zig",      target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "node-launcher","core/node_launcher.zig",target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "bootstrap",    "core/bootstrap.zig",    target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "cli",          "core/cli.zig",          target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "vault-reader", "core/vault_reader.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "sub-block",    "core/sub_block.zig",    target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "shard-config", "core/shard_config.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "blockchain-v2","core/blockchain_v2.zig",target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "storage",      "core/storage.zig",      target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "binary-codec", "core/binary_codec.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "archive",      "core/archive_manager.zig",target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "prune-config", "core/prune_config.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "state-trie",   "core/state_trie.zig",   target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "compact-tx",   "core/compact_transaction.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "witness",      "core/witness_data.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "light-client", "core/light_client.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "light-miner",  "core/light_miner.zig",  target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "mining-pool",  "core/mining_pool.zig",  target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "key-encryption","core/key_encryption.zig",target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "pq-crypto",    "core/pq_crypto.zig",    target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "schnorr",      "core/schnorr.zig",      target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "multisig",     "core/multisig.zig",     target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "finality",     "core/finality.zig",     target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "governance",   "core/governance.zig",   target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "peer-score",   "core/peer_scoring.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "peer-persist", "core/peer_persist.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "chain-cfg",    "core/chain_config.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "bls",          "core/bls_signatures.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "staking",      "core/staking.zig",      target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "tx-receipt",   "core/tx_receipt.zig",   target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "dns",          "core/dns_registry.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "guardian",     "core/guardian.zig",     target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "compact-blk", "core/compact_blocks.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "kademlia",    "core/kademlia_dht.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "hex-utils",   "core/hex_utils.zig",    target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "script",      "core/script.zig",       target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "miner-wallet","core/miner_wallet.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "payment-ch", "core/payment_channel.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "benchmark",  "core/benchmark.zig",    target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "bread-ledger",  "core/bread_ledger.zig",     target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "bridge-relay",  "core/bridge_relay.zig",     target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "domain-minter", "core/domain_minter.zig",    target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "metachain",     "core/metachain.zig",        target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "omni-brain",    "core/omni_brain.zig",       target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "oracle",        "core/oracle.zig",           target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "os-mode",       "core/os_mode.zig",          target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "shard-coord",   "core/shard_coordinator.zig",target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "spark-inv",     "core/spark_invariants.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "synapse-prio",  "core/synapse_priority.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "ubi-dist",      "core/ubi_distributor.zig",  target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "vault-engine",  "core/vault_engine.zig",     target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "ws-server",     "core/ws_server.zig",        target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "matching",      "core/matching_engine.zig",  target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "order-swap-link","core/order_swap_link.zig",  target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "intent-registry","core/intent_registry.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "grid-engine",   "core/grid_engine.zig",      target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "price-oracle",  "core/price_oracle.zig",     target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "pouw",          "core/consensus_pouw.zig",   target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "ob-sync",       "core/orderbook_sync.zig",   target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "br-listener",   "core/bridge_listener.zig",  target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "settlement",    "core/settlement_submitter.zig", target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "integration",   "core/integration_test.zig",     target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "oracle-fetcher","core/oracle_fetcher.zig",       target, optimize, build_options).step);
    test_all_step.dependOn(&addTest(b, "isolated-wallet","core/isolated_wallet_test.zig", target, optimize, build_options).step);
}
