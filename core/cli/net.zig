//! Network / peers subcommands — re-exports from common.zig.
const c = @import("common.zig");
pub const cmdPeers = c.cmdPeers;
pub const cmdPeerInfo = c.cmdPeerInfo;
pub const cmdBans = c.cmdBans;
pub const cmdConnectPeer = c.cmdConnectPeer;
pub const cmdDisconnectPeer = c.cmdDisconnectPeer;
pub const cmdP2pStats = c.cmdP2pStats;
