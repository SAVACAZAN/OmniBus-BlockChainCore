//! core/node/config_setup.zig
//!
//! Bundles three small init blocks extracted from main.zig:
//!   1. resolveChainConfig  — ChainMode → ChainConfig + chain_name (label).
//!   2. buildOraclePolicy   — defaults per chain_id + CLI overrides; prints
//!                            the `[ORACLE-POLICY]` banner. Caller assigns
//!                            the return value into the root g_oracle_policy
//!                            (we don't touch globals here to avoid an import
//!                            cycle on @import("root")).
//!   3. resolveMnemonic     — CLI flag → SuperVault Named Pipe → env → dev
//!                            default (delegated to vault_reader).
//!
//! All print lines preserved verbatim from the originals.

const std = @import("std");
const oracle_policy_mod = @import("../oracle_policy.zig");
const chain_config_mod  = @import("../chain_config.zig");
const cli_mod           = @import("../cli.zig");
const vault_reader      = @import("../vault_reader.zig");

const ChainConfig = chain_config_mod.ChainConfig;
const ChainMode   = cli_mod.ChainMode;
const OraclePolicy = oracle_policy_mod.OraclePolicy;

pub const ChainResolved = struct {
    net_cfg: ChainConfig,
    chain_name: []const u8,
};

/// ChainMode → ChainConfig. devnet not yet wired through CLI (see cli.zig).
pub fn resolveChainConfig(chain_mode: ChainMode) ChainResolved {
    const net_cfg: ChainConfig = switch (chain_mode) {
        .mainnet => ChainConfig.mainnet(),
        .testnet => ChainConfig.testnet(),
        .regtest => ChainConfig.regtest(),
    };
    return .{ .net_cfg = net_cfg, .chain_name = net_cfg.name };
}

/// Build the OraclePolicy: per-chain defaults overridden by CLI flags.
/// Prints the `[ORACLE-POLICY]` banner. Caller is responsible for storing
/// the returned policy into the root `g_oracle_policy` global.
pub fn buildOraclePolicy(
    chain_id: chain_config_mod.ChainId,
    price_warn_pct: ?f64,
    price_reject_pct: ?f64,
    price_fillgap_pct: ?f64,
    price_validation_disabled: bool,
) OraclePolicy {
    var pol = oracle_policy_mod.defaultsFor(chain_id);
    if (price_warn_pct) |v| pol.warn_pct = v;
    if (price_reject_pct) |v| pol.reject_pct = v;
    if (price_fillgap_pct) |v| pol.fillgap_pct = v;
    if (price_validation_disabled) pol.enabled = false;
    std.debug.print(
        "[ORACLE-POLICY] warn={d:.1}% reject={d:.1}% fillgap={d:.1}% enabled={s}\n",
        .{ pol.warn_pct, pol.reject_pct, pol.fillgap_pct, if (pol.enabled) "true" else "false" },
    );
    return pol;
}

/// CLI flag → SuperVault Named Pipe → env var → dev default.
/// Prints `[WALLET]` line when CLI flag was the source.
pub fn resolveMnemonic(
    cli_mnemonic: ?[]const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const mnemonic = if (cli_mnemonic) |m|
        try allocator.dupe(u8, m)
    else
        try vault_reader.readMnemonic(allocator);

    if (cli_mnemonic != null) {
        std.debug.print("[WALLET] Using mnemonic from --mnemonic CLI flag\n", .{});
    }
    return mnemonic;
}
