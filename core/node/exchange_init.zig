// core/node/exchange_init.zig
//
// Helpers extracted from main.zig to keep node startup readable:
//
//   - initEvmEscrowWatcher: bind 6 EVM testnets, spawn poller for
//     OmnibusDEX OrderPlaced events.
//   - initDexSettler:       derive operator key (slot 2 = m/44'/60'/0'/0/2),
//                           build pair × chain bindings, spawn settler thread.
//
// Behavior is preserved verbatim from the pre-extract main.zig (same chain
// IDs, RPC URLs, contract addresses, poll intervals, log messages).

const std = @import("std");
const evm_escrow_mod   = @import("../evm_escrow_watcher.zig");
const dex_settler_mod  = @import("../dex_settler.zig");
const evm_signer_mod   = @import("../evm_signer.zig");
const matching_mod     = @import("../matching_engine.zig");
const bip32_wallet_mod = @import("../bip32_wallet.zig");
const fills_log_mod    = @import("../fills_log.zig");

/// Spawns the EVM escrow watcher (6 chains). Returns null on any allocation
/// failure — original behavior was silent disable.
pub fn initEvmEscrowWatcher(allocator: std.mem.Allocator) ?*evm_escrow_mod.Watcher {
    const bindings = allocator.alloc(evm_escrow_mod.Binding, 6) catch return null;
    bindings[0] = .{
        .chain_id = 11155111,
        .rpc_url = "https://ethereum-sepolia-rpc.publicnode.com",
        .contract = "0xC21fD92e5f568a7981d16b9008E3C190842818aE",
    };
    bindings[1] = .{
        .chain_id = 84532,
        .rpc_url = "https://sepolia.base.org",
        .contract = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB",
    };
    bindings[2] = .{
        .chain_id = 421614,
        .rpc_url = "https://sepolia-rollup.arbitrum.io/rpc",
        .contract = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB",
    };
    bindings[3] = .{
        .chain_id = 11155420,
        .rpc_url = "https://sepolia.optimism.io",
        .contract = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB",
    };
    bindings[4] = .{
        .chain_id = 1946,
        .rpc_url = "https://rpc.minato.soneium.org",
        .contract = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB",
    };
    bindings[5] = .{
        .chain_id = 76847801,
        .rpc_url = "https://testnet-rpc.lcx.com",
        .contract = "0xE4a3965C4B5205D28259D1CC82fD54060B0bCd19",
    };

    const watcher_ptr = allocator.create(evm_escrow_mod.Watcher) catch return null;
    watcher_ptr.* = evm_escrow_mod.Watcher.init(
        allocator,
        .{
            .bindings = bindings,
            .poll_ms = 5_000,
            .cursor_path = "data/evm_escrow_cursor.bin",
        },
    );
    watcher_ptr.start() catch {};
    std.debug.print("[EVM_ESCROW] ON — watching {d} chain(s) for OrderPlaced events\n",
        .{bindings.len});
    return watcher_ptr;
}

/// Spawns the DEX settler thread. Returns null if the operator key cannot be
/// derived, bindings cannot be allocated, or the settler thread fails to
/// start. The caller is expected to keep the returned pointer alive for the
/// lifetime of the process (matches original main.zig behavior — no shutdown).
pub fn initDexSettler(
    allocator: std.mem.Allocator,
    mnemonic: []const u8,
    engine: *matching_mod.MatchingEngine,
    fills_log_handle: ?*fills_log_mod.FillsLog,
    evm_watcher_handle: ?*evm_escrow_mod.Watcher,
) ?*dex_settler_mod.Settler {
    var bip32_dex = bip32_wallet_mod.BIP32Wallet.initFromMnemonic(mnemonic, allocator) catch |e| {
        std.debug.print("[DEX_SETTLER] cannot derive operator key: {s} — settler not spawned\n", .{@errorName(e)});
        return null;
    };
    const op_priv = bip32_dex.deriveChildKeyForPath(44, 60, 2) catch |e| {
        std.debug.print("[DEX_SETTLER] derive(44,60,2) failed: {s}\n", .{@errorName(e)});
        return null;
    };
    // Derive operator EVM address from the privkey so the settler can
    // log it / cross-check against the contract's `operator` storage.
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaSecp256k1Sha256;
    const sk = Ecdsa.SecretKey.fromBytes(op_priv) catch return null;
    const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch return null;
    const pub_unc = kp.public_key.toUncompressedSec1();
    var keccak_buf: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(pub_unc[1..65], &keccak_buf, .{});
    var op_addr20: [20]u8 = undefined;
    @memcpy(&op_addr20, keccak_buf[12..32]);

    const operator_key = evm_signer_mod.SigningKey{
        .private_key = op_priv,
        .address = op_addr20,
    };

    // Multi-chain bindings. Same logical pair_id settles on the chain
    // whose escrow the watcher saw — settler picks via findBindingForChain.
    // CREATE deterministic = same deployer + nonce 0 → same DEX address
    // across EVM chains: 0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB.
    // Exception: Sepolia (deployed before the multi-chain reset) uses
    // 0xC21fD92e5f568a7981d16b9008E3C190842818aE.
    const dex_sepolia      = "0xC21fD92e5f568a7981d16b9008E3C190842818aE";
    const dex_create2_addr = "0xAEE1B7dC7a010b6C6D6097BD7d9dDf227aF719EB";
    // Pair_id × chain_id grid. EURC (pair 1) only where Circle has it
    // deployed (Sepolia + Base Sepolia). USDC + native everywhere else.
    // pair_id 5 (OMNI/LCX) reserved for Liberty when RPC comes back.
    const bindings = allocator.alloc(dex_settler_mod.PairBinding, 16) catch return null;
    // Sepolia
    bindings[0] = .{ .pair_id = 0, .chain_id = 11155111, .rpc_url = "https://ethereum-sepolia-rpc.publicnode.com", .dex_contract = dex_sepolia };
    bindings[1] = .{ .pair_id = 6, .chain_id = 11155111, .rpc_url = "https://ethereum-sepolia-rpc.publicnode.com", .dex_contract = dex_sepolia };
    bindings[2] = .{ .pair_id = 1, .chain_id = 11155111, .rpc_url = "https://ethereum-sepolia-rpc.publicnode.com", .dex_contract = dex_sepolia };
    // Base Sepolia
    bindings[3] = .{ .pair_id = 0, .chain_id = 84532, .rpc_url = "https://sepolia.base.org", .dex_contract = dex_create2_addr };
    bindings[4] = .{ .pair_id = 6, .chain_id = 84532, .rpc_url = "https://sepolia.base.org", .dex_contract = dex_create2_addr };
    bindings[5] = .{ .pair_id = 1, .chain_id = 84532, .rpc_url = "https://sepolia.base.org", .dex_contract = dex_create2_addr };
    // Arbitrum Sepolia (deployed 2026-05-16)
    bindings[6] = .{ .pair_id = 0, .chain_id = 421614, .rpc_url = "https://sepolia-rollup.arbitrum.io/rpc", .dex_contract = dex_create2_addr };
    bindings[7] = .{ .pair_id = 6, .chain_id = 421614, .rpc_url = "https://sepolia-rollup.arbitrum.io/rpc", .dex_contract = dex_create2_addr };
    // OP Sepolia (deployed 2026-05-16)
    bindings[8] = .{ .pair_id = 0, .chain_id = 11155420, .rpc_url = "https://sepolia.optimism.io", .dex_contract = dex_create2_addr };
    bindings[9] = .{ .pair_id = 6, .chain_id = 11155420, .rpc_url = "https://sepolia.optimism.io", .dex_contract = dex_create2_addr };
    // Soneium Minato (deployed 2026-05-16 via Sepolia bridge)
    // No USDC oficial Circle on Minato yet; only native ETH pair_id=6.
    bindings[10] = .{ .pair_id = 6, .chain_id = 1946, .rpc_url = "https://rpc.minato.soneium.org", .dex_contract = dex_create2_addr };
    // LCX Liberty Chain testnet (OP Stack L2 on Sepolia, ETH gas).
    // Different deploy address because slot 6 had prior nonce on Liberty.
    bindings[11] = .{ .pair_id = 6, .chain_id = 76847801, .rpc_url = "https://testnet-rpc.lcx.com", .dex_contract = "0xE4a3965C4B5205D28259D1CC82fD54060B0bCd19" };
    // pair_id 7 (OMNI/LINK) on chains where DEX deployed and LINK confirmed.
    bindings[12] = .{ .pair_id = 7, .chain_id = 11155111, .rpc_url = "https://ethereum-sepolia-rpc.publicnode.com", .dex_contract = dex_sepolia };
    bindings[13] = .{ .pair_id = 7, .chain_id = 84532, .rpc_url = "https://sepolia.base.org", .dex_contract = dex_create2_addr };
    bindings[14] = .{ .pair_id = 7, .chain_id = 421614, .rpc_url = "https://sepolia-rollup.arbitrum.io/rpc", .dex_contract = dex_create2_addr };
    bindings[15] = .{ .pair_id = 7, .chain_id = 11155420, .rpc_url = "https://sepolia.optimism.io", .dex_contract = dex_create2_addr };

    const settler = allocator.create(dex_settler_mod.Settler) catch return null;
    settler.* = dex_settler_mod.Settler.init(
        allocator,
        .{
            .operator_key = operator_key,
            .bindings = bindings,
            .poll_ms = 2_000,
            .cursor_path = "data/dex_settler_cursor.bin",
            .fills_log = fills_log_handle,
            .escrow_watcher = evm_watcher_handle,
        },
        engine,
    );
    settler.start() catch |e| {
        std.debug.print("[DEX_SETTLER] start failed: {s}\n", .{@errorName(e)});
        return null;
    };

    // Print the operator address using same hex format as on the contract.
    std.debug.print("[DEX_SETTLER] ON — operator 0x", .{});
    for (op_addr20) |b| std.debug.print("{x:0>2}", .{b});
    std.debug.print(" watches engine, sepolia binding active\n", .{});
    return settler;
}
