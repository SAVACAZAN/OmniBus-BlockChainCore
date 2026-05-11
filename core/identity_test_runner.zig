//! identity_test_runner.zig — test root for `zig build test-id`.
//!
//! Placed at `core/` (NOT inside core/identity/) because Zig 0.15.2 forbids
//! `@import("../...")` from a test root file. From here, identity modules
//! reach back into `core/wallet.zig` etc. through relative paths that stay
//! inside the module tree. Pulls in every identity sub-module's tests.

test {
    _ = @import("identity/id_types.zig");
    _ = @import("identity/id_base58.zig");
    _ = @import("identity/id_merkle.zig");
    _ = @import("identity/id_manifest.zig");
    _ = @import("identity/id_disclosure.zig");
    _ = @import("identity/id_salt.zig");
    _ = @import("identity/id_compliance.zig");
    _ = @import("identity/id_obm.zig");
    _ = @import("identity/id_did.zig");
    _ = @import("identity/id_social.zig");
    _ = @import("identity/id_professional.zig");
    _ = @import("identity/id_cultural.zig");
    _ = @import("identity/id_economic.zig");
    _ = @import("identity/identity.zig");
}
