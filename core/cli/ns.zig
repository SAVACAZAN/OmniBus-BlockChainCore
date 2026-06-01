//! Name service (.omnibus / .arbitraje / etc.) subcommands — re-exports.
const c = @import("common.zig");
pub const cmdNsResolve = c.cmdNsResolve;
pub const cmdNsReverse = c.cmdNsReverse;
pub const cmdNsList = c.cmdNsList;
pub const cmdNsTlds = c.cmdNsTlds;
pub const cmdNsFee = c.cmdNsFee;
pub const cmdNsStats = c.cmdNsStats;
pub const cmdNsExpiring = c.cmdNsExpiring;
pub const cmdNsRegister = c.cmdNsRegister;
pub const cmdNsRenew = c.cmdNsRenew;
pub const cmdNsTransfer = c.cmdNsTransfer;
pub const cmdNsUpdate = c.cmdNsUpdate;
pub const cmdNsByCategory = c.cmdNsByCategory;
