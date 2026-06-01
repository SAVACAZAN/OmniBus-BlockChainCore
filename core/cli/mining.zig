//! Mining subcommands — re-exports from common.zig.
const c = @import("common.zig");
pub const cmdMiningStatus = c.cmdMiningStatus;
pub const cmdMiners = c.cmdMiners;
pub const cmdMinerStats = c.cmdMinerStats;
pub const cmdPoolStats = c.cmdPoolStats;
pub const cmdSlotLeader = c.cmdSlotLeader;
pub const cmdRegisterMiner = c.cmdRegisterMiner;
