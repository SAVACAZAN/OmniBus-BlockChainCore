//! Oracle / bridge subcommands — re-exports from common.zig.
const c = @import("common.zig");
pub const cmdOraclePrices = c.cmdOraclePrices;
pub const cmdOracleArbitrage = c.cmdOracleArbitrage;
pub const cmdOracleFeed = c.cmdOracleFeed;
pub const cmdBridgeStatus = c.cmdBridgeStatus;
pub const cmdBridgeLock = c.cmdBridgeLock;
pub const cmdOracleRestart = c.cmdOracleRestart;
pub const cmdOracleSnapshot = c.cmdOracleSnapshot;
