/// registrar_addresses.zig — the 10 fixed-forever registrar wallets.
///
/// Derived once from the founder mnemonic at `m/44'/777'/0'/0/<idx>` for
/// idx 0..9 and HARDCODED here. The chain validates at boot that the
/// running mnemonic re-derives the same addresses, otherwise it bails
/// with `error.WrongMnemonic`. This is the bridge between Alex's seed
/// and the on-chain treasury slots — same role as Bitcoin's checkpoint
/// `pchMessageStart`: wrong key, wrong chain.
///
/// Slots are append-only and never re-purposed (memory:
/// `project_omnibus_registrar_addresses`). Re-using a slot would break
/// the "1000 years" promise and the `.omnibus` reservation logic.
const std = @import("std");

/// Index into REGISTRAR_ADDRESSES. Use these symbolic names anywhere a
/// slot is referenced — never hardcode a u8.
pub const Slot = enum(u8) {
    savacazan = 0,        // Founder mining wallet (also the dev/seed
                          // node's signing key). Public.
    bridge = 1,           // Cross-chain bridge treasury (placeholder).
                          // Was tentatively "exchange" but bridge takes
                          // priority — exchange uses chain-state tx flow,
                          // bridge needs an on-chain account.
    // 2..3 reserved for future treasury slots
    kyc = 4,              // KYC issuer — signs `kyc_attestations` table.
                          // The only slot allowed to call `kyc_attest`.
    ens = 5,              // ENS / .omnibus name registrar fees.
    // 6 reserved
    faucet = 7,           // Testnet faucet — already wired via
                          // OMNIBUS_FAUCET_PRIVKEY env var.
    // 8..9 reserved (exchange treasury / agent license / community DAO)
};

/// One slot. Hardcoded canonical address + role label.
pub const RegistrarSlot = struct {
    index: u8,
    address: []const u8,
    role: []const u8,
    /// `.omnibus` ENS name reserved for this slot at genesis. Cannot be
    /// registered by random users — the registrar code checks the slot
    /// table before accepting `registername` for any of these.
    reserved_name: []const u8,
};

/// CANONICAL address list. Derived once from the founder mnemonic at
/// path `m/44'/777'/0'/0/<idx>` and PASTED here. The boot validator
/// re-derives and asserts equality — wrong mnemonic = chain refuses
/// to start. This protects against accidentally booting mainnet from
/// a dev mnemonic.
///
/// The .omnibus names are reserved at genesis (DnsRegistry plants them
/// as `treasury` so `registername` for these strings is rejected).
pub const REGISTRAR_ADDRESSES = [_]RegistrarSlot{
    .{ .index = 0, .address = "ob1qzhrauq0xe9hg033ccup7vlgsdmj6kcxyza9zp0", .role = "savacazan",  .reserved_name = "savacazan.omnibus" },
    .{ .index = 1, .address = "",                                            .role = "bridge",     .reserved_name = "bridge.omnibus" },
    .{ .index = 2, .address = "",                                            .role = "reserved-2", .reserved_name = "" },
    .{ .index = 3, .address = "",                                            .role = "reserved-3", .reserved_name = "" },
    .{ .index = 4, .address = "",                                            .role = "kyc",        .reserved_name = "kyc.omnibus" },
    .{ .index = 5, .address = "ob1qqcmwu5txqt5m3wv6p3ugxp6a3q4jsntd0mxyxa", .role = "ens",        .reserved_name = "ens.omnibus" },
    .{ .index = 6, .address = "",                                            .role = "reserved-6", .reserved_name = "" },
    .{ .index = 7, .address = "ob1qvetjtq3swujv0jqsmw0gq84fymtfuaz5p5cjdv", .role = "faucet",     .reserved_name = "faucet.omnibus" },
    .{ .index = 8, .address = "",                                            .role = "reserved-8", .reserved_name = "" },
    .{ .index = 9, .address = "",                                            .role = "reserved-9", .reserved_name = "" },
};

/// Look up a slot's canonical address. Returns null if the slot is
/// reserved-but-unfilled (we know slots 0/5/7 from history; 1/4 etc
/// will be filled when the founder pastes the derived address here
/// after one boot of `--export-registrar` — see CLI tools).
pub fn addressOf(slot: Slot) ?[]const u8 {
    const entry = REGISTRAR_ADDRESSES[@intFromEnum(slot)];
    if (entry.address.len == 0) return null;
    return entry.address;
}

/// Returns true if `name` (lowercase, no leading dot) is one of the
/// genesis-reserved `.omnibus` names. DnsRegistry checks this on every
/// `registername` call so `kyc.omnibus` etc. cannot be squatted.
pub fn isReservedName(name: []const u8) bool {
    for (REGISTRAR_ADDRESSES) |slot| {
        if (slot.reserved_name.len == 0) continue;
        if (std.mem.eql(u8, slot.reserved_name, name)) return true;
    }
    return false;
}

/// Boot-time sanity: re-derive idx 0/5/7 from the live wallet's
/// underlying mnemonic and compare against the hardcoded values. Logs
/// a warning if mismatched (testnet) or returns error.WrongMnemonic
/// (mainnet — caller decides).
///
/// Slots that are still empty in REGISTRAR_ADDRESSES are skipped.
pub fn validateAgainstMnemonic(
    derive: *const fn (idx: u8, allocator: std.mem.Allocator) anyerror![]u8,
    allocator: std.mem.Allocator,
    strict: bool,
) !void {
    for (REGISTRAR_ADDRESSES) |slot| {
        if (slot.address.len == 0) continue;
        const got = try derive(slot.index, allocator);
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, slot.address)) {
            std.debug.print("[REGISTRAR] mismatch at slot {d} ({s}): expected {s}, derived {s}\n",
                .{ slot.index, slot.role, slot.address, got });
            if (strict) return error.WrongMnemonic;
        }
    }
}

test "isReservedName matches known names" {
    try std.testing.expect(isReservedName("savacazan.omnibus"));
    try std.testing.expect(isReservedName("ens.omnibus"));
    try std.testing.expect(isReservedName("faucet.omnibus"));
    try std.testing.expect(!isReservedName("alice.omnibus"));
    try std.testing.expect(!isReservedName(""));
}

test "addressOf returns null for empty slots" {
    try std.testing.expect(addressOf(.savacazan) != null);
    try std.testing.expect(addressOf(.kyc) == null); // not yet derived/pasted
}
