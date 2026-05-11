//! identity.zig — single import surface for the OmniBus ID module.
//!
//! Other parts of the chain (rpc_server.zig, cli_audit.zig, etc.) should
//! `const identity = @import("identity/identity.zig");` and reach every
//! sub-module through this aggregator. Keeps `core/` clean.

pub const types        = @import("id_types.zig");
pub const base58       = @import("id_base58.zig");
pub const did          = @import("id_did.zig");
pub const merkle       = @import("id_merkle.zig");
pub const manifest     = @import("id_manifest.zig");
pub const obm          = @import("id_obm.zig");
pub const disclosure   = @import("id_disclosure.zig");
pub const salt         = @import("id_salt.zig");
pub const compliance   = @import("id_compliance.zig");
pub const social       = @import("id_social.zig");
pub const professional = @import("id_professional.zig");
pub const cultural     = @import("id_cultural.zig");
pub const economic     = @import("id_economic.zig");

test "all submodules compile (no PQ dependency)" {
    _ = types;
    _ = base58;
    _ = did;
    _ = merkle;
    _ = manifest;
    _ = obm;
    _ = disclosure;
    _ = salt;
    _ = compliance;
}
