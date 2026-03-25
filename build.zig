const std = @import("std");

// liboqs paths — Windows native (compilat cu MinGW in liboqs-src/build)
const LIBOQS_INCLUDE = "C:/Kits work/limaje de programare/liboqs-src/build/include";
const LIBOQS_LIB     = "C:/Kits work/limaje de programare/liboqs-src/build/lib/liboqs.a";

fn addOqs(step: *std.Build.Step.Compile) void {
    step.addIncludePath(.{ .cwd_relative = LIBOQS_INCLUDE });
    step.addObjectFile(.{ .cwd_relative = LIBOQS_LIB });
    step.linkLibC();
}

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Blockchain node ───────────────────────────────────────────────────
    const blockchain_exe = b.addExecutable(.{
        .name        = "omnibus-node",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/main.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    addOqs(blockchain_exe);
    b.installArtifact(blockchain_exe);

    // ── RPC server ────────────────────────────────────────────────────────
    const rpc_exe = b.addExecutable(.{
        .name        = "omnibus-rpc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/rpc_server.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    addOqs(rpc_exe);
    b.installArtifact(rpc_exe);

    // ── Tests ─────────────────────────────────────────────────────────────
    const test_secp256k1 = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/secp256k1.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });

    const test_bip32 = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/bip32_wallet.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });

    const test_transaction = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/transaction.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });

    // test_wallet si test_pq necesita liboqs
    const test_wallet = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/wallet.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    addOqs(test_wallet);

    const test_pq = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/pq_crypto.zig"),
            .target           = target,
            .optimize         = optimize,
        }),
    });
    addOqs(test_pq);

    const run_secp256k1   = b.addRunArtifact(test_secp256k1);
    const run_bip32       = b.addRunArtifact(test_bip32);
    const run_transaction = b.addRunArtifact(test_transaction);
    const run_wallet      = b.addRunArtifact(test_wallet);
    const run_pq          = b.addRunArtifact(test_pq);

    // test = toate (cu PQ)
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_secp256k1.step);
    test_step.dependOn(&run_bip32.step);
    test_step.dependOn(&run_transaction.step);
    test_step.dependOn(&run_wallet.step);
    test_step.dependOn(&run_pq.step);

    // test-crypto = secp256k1 + bip32 (fara PQ)
    const test_crypto_step = b.step("test-crypto", "Test secp256k1 + BIP32");
    test_crypto_step.dependOn(&run_secp256k1.step);
    test_crypto_step.dependOn(&run_bip32.step);

    // test-pq = doar PQ crypto
    const test_pq_step = b.step("test-pq", "Test PQ crypto (liboqs)");
    test_pq_step.dependOn(&run_pq.step);

    // test-wallet = wallet complet cu PQ signing (Test H)
    const test_wallet_step = b.step("test-wallet", "Test wallet + PQ signing (Test H)");
    test_wallet_step.dependOn(&run_wallet.step);

    // ── Run step ──────────────────────────────────────────────────────────
    const run_blockchain = b.addRunArtifact(blockchain_exe);
    const run_step = b.step("run", "Run blockchain node");
    run_step.dependOn(&run_blockchain.step);
}
