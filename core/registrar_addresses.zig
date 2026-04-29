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

/// Index into REGISTRAR_ADDRESSES. Numbers are BIP-44 path indices
/// (`m/44'/777'/0'/0/<idx>`) and they MUST match what the aweb3 wallet
/// derivation shows in the OmniWallets UI — that UI is the operational
/// source of truth for which address is which role.
///
/// Reconciliation 2026-04-29: we previously had bridge=1, kyc=4, ens=5
/// here, but the live wallet derivation produces ens at index 3 and
/// faucet at index 7. The other slots are now relabelled to match what
/// the UI labels them (admin, exchange, sava, blockchain, tornetwork,
/// cazan, database).
pub const Slot = enum(u8) {
    savacazan   = 0, // Founder mining wallet (also dev/seed signing key).
    admin       = 1, // Operator / admin actions.
    exchange    = 2, // Exchange treasury (fees, market-making).
    ens         = 3, // ENS / .omnibus name registrar — pay-to-claim sink.
    sava        = 4, // Sava ops (legacy alias).
    blockchain  = 5, // Chain ops / system reserve.
    tornetwork  = 6, // TorNetworkExchange bridge.
    faucet      = 7, // Testnet faucet — wired via OMNIBUS_FAUCET_PRIVKEY.
    cazan       = 8, // Cazan ops (legacy alias).
    database    = 9, // Database / state ops.
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
    .{ .index = 1, .address = "ob1q8wm5est4fft7mrj937sg9uyaz2nskgttf3ku5u", .role = "admin",      .reserved_name = "admin.omnibus" },
    .{ .index = 2, .address = "ob1qpjt7gngkj79663a298schx6dkjxqf37hwfggw2", .role = "exchange",   .reserved_name = "exchange.omnibus" },
    .{ .index = 3, .address = "ob1qqcmwu5txqt5m3wv6p3ugxp6a3q4jsntd0mxyxa", .role = "ens",        .reserved_name = "ens.omnibus" },
    .{ .index = 4, .address = "ob1q5stczt5xxxphedadlqej09f5hww22qhvrj2nln", .role = "sava",       .reserved_name = "sava.omnibus" },
    .{ .index = 5, .address = "ob1quax5e9hyyzmft2m2lzn735asswsw9gh4gtgess", .role = "blockchain", .reserved_name = "blockchain.omnibus" },
    .{ .index = 6, .address = "ob1qcdep7azzrr8t3x8tgn9wp6p69fc884g8g80v09", .role = "tornetwork", .reserved_name = "tornetwork.omnibus" },
    .{ .index = 7, .address = "ob1qvetjtq3swujv0jqsmw0gq84fymtfuaz5p5cjdv", .role = "faucet",     .reserved_name = "faucet.omnibus" },
    .{ .index = 8, .address = "ob1qdpknh5kapc22fv6s7jv0ntj7kwepqf3hcq4jrj", .role = "cazan",      .reserved_name = "cazan.omnibus" },
    .{ .index = 9, .address = "ob1qw8sltuapku7g5c4fmkzplhns0sde9rc6cunu57", .role = "database",   .reserved_name = "database.omnibus" },
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

test "addressOf returns hardcoded canonical addresses" {
    // All 10 slots are populated as of 2026-04-29 (sourced from aweb3
    // wallet UI). Each acts as a native smart contract — has an address,
    // no key. Chain enforces rules per slot.
    try std.testing.expect(addressOf(.savacazan) != null);
    try std.testing.expect(addressOf(.ens) != null);
    try std.testing.expect(addressOf(.faucet) != null);
    try std.testing.expect(addressOf(.exchange) != null);
    try std.testing.expectEqualStrings(
        "ob1qqcmwu5txqt5m3wv6p3ugxp6a3q4jsntd0mxyxa",
        addressOf(.ens).?,
    );
}
