//! Admin / config / logs / services / 0day / faucet / benchmark — re-exports.
const c = @import("common.zig");
pub const cmdSetRpcToken = c.cmdSetRpcToken;
pub const cmdConfig = c.cmdConfig;
pub const cmdLogs = c.cmdLogs;
pub const cmdVpsHealth = c.cmdVpsHealth;
pub const cmdStressQuick = c.cmdStressQuick;
pub const cmdBenchmark = c.cmdBenchmark;
pub const cmdFaucetStatus = c.cmdFaucetStatus;
pub const cmdFaucetClaim = c.cmdFaucetClaim;
pub const cmdFaucetClaims = c.cmdFaucetClaims;
pub const cmdZerodayEvents = c.cmdZerodayEvents;
pub const cmdZerodayReport = c.cmdZerodayReport;
pub const cmdSybilCheck = c.cmdSybilCheck;
pub const cmdServicesStatus = c.cmdServicesStatus;
pub const cmdServiceRestart = c.cmdServiceRestart;
