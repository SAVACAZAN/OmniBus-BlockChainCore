// dns_registry_tests.zig — Extracted inline tests from dns_registry.zig.
// All symbols referenced are exported (pub) from dns_registry.zig.

const std = @import("std");
const dns = @import("dns_registry.zig");

// Re-export commonly used symbols so test bodies stay verbatim.
const DnsRegistry = dns.DnsRegistry;
const DnsEntry = dns.DnsEntry;
const isValidName = dns.isValidName;
const feeForName = dns.feeForName;
const feeForRegistration = dns.feeForRegistration;
const feeForRegistrationWithOwnerCount = dns.feeForRegistrationWithOwnerCount;
const feeForRenewal = dns.feeForRenewal;
const sybilFeeMultiplierMilli = dns.sybilFeeMultiplierMilli;
const MAX_NAMES_PER_OWNER = dns.MAX_NAMES_PER_OWNER;
const TXID_LEN = dns.TXID_LEN;
const RENEWAL_PERIOD_BLOCKS = dns.RENEWAL_PERIOD_BLOCKS;
const GRACE_PERIOD_BLOCKS = dns.GRACE_PERIOD_BLOCKS;
const BLOCKS_PER_YEAR = dns.BLOCKS_PER_YEAR;
const COST_OMNIBUS_SAT = dns.COST_OMNIBUS_SAT;

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "isValidName — valid names" {
    try testing.expect(isValidName("alice"));
    try testing.expect(isValidName("bob_123"));
    try testing.expect(isValidName("validator_node_01"));
}

test "isValidName — invalid names" {
    try testing.expect(!isValidName("ab"));          // too short
    try testing.expect(!isValidName("ALICE"));        // uppercase
    try testing.expect(!isValidName("alice.bob"));    // dot
    try testing.expect(!isValidName("1alice"));       // starts with number
    try testing.expect(!isValidName("alice bob"));    // space
    try testing.expect(!isValidName("abcdefghijklmnopqrstuvwxyz1")); // too long (27)
}

test "DnsRegistry — register and resolve" {
    var reg = DnsRegistry.init();
    try reg.register("alice", "ob1qxyca6f2cuw906ecwkzj9spdvrtpq0qwmzdefxf", "ob1qxyca6f2cuw906ecwkzj9spdvrtpq0qwmzdefxf", 1000);
    const addr = reg.resolve("alice", 1001);
    try testing.expect(addr != null);
    try testing.expectEqualStrings("ob1qxyca6f2cuw906ecwkzj9spdvrtpq0qwmzdefxf", addr.?);
}

test "DnsRegistry — name taken" {
    var reg = DnsRegistry.init();
    try reg.register("bob", "ob1qvkpmansk8z28n9v9g5rx07x3r9xht7kcv5tkvc", "ob1qvkpmansk8z28n9v9g5rx07x3r9xht7kcv5tkvc", 1000);
    try testing.expectError(error.NameTakenCrossTld,
        reg.register("bob", "ob1q632e5a5f9njdlucpm2g7cqsf7p2gk3u8h25wah", "ob1q632e5a5f9njdlucpm2g7cqsf7p2gk3u8h25wah", 1001));
}

test "DnsRegistry — expired name can be re-registered" {
    var reg = DnsRegistry.init();
    try reg.register("temp", "ob1qu48cza4ny77jw762kjky6gvsjqz4vmn09suwl9", "ob1qu48cza4ny77jw762kjky6gvsjqz4vmn09suwl9", 1000);
    // After expiry + grace, name is auctionable and can be re-registered
    const future_block = 1000 + RENEWAL_PERIOD_BLOCKS + GRACE_PERIOD_BLOCKS + 1;
    try testing.expect(reg.resolve("temp", future_block) == null);
    // Can re-register
    try reg.register("temp", "ob1q2rjzulwvagksc9wu2eym26jzkyjqnjdl4qgevt", "ob1q2rjzulwvagksc9wu2eym26jzkyjqnjdl4qgevt", future_block);
    try testing.expectEqualStrings("ob1q2rjzulwvagksc9wu2eym26jzkyjqnjdl4qgevt", reg.resolve("temp", future_block + 1).?);
}

test "DnsRegistry — reverse resolve" {
    var reg = DnsRegistry.init();
    try reg.register("carol", "ob1qygr9gcwr2nke94levj9ymmfkdt2as03ln4xeth", "ob1qygr9gcwr2nke94levj9ymmfkdt2as03ln4xeth", 1000);
    const name = reg.reverseResolve("ob1qygr9gcwr2nke94levj9ymmfkdt2as03ln4xeth", 1001);
    try testing.expect(name != null);
    try testing.expectEqualStrings("carol", name.?);
}

test "DnsRegistry — transfer" {
    var reg = DnsRegistry.init();
    try reg.register("dave", "ob1qagagaf3lr3wk4j4ht28atd9hsgu3cxdm765d7n", "ob1qagagaf3lr3wk4j4ht28atd9hsgu3cxdm765d7n", 1000);
    try reg.transfer("dave", "omnibus", "ob1qagagaf3lr3wk4j4ht28atd9hsgu3cxdm765d7n", "ob1qf7wv3txfsxwrxw5nypvpe5r0c3p2srkuqv4clx", "ob1qf7wv3txfsxwrxw5nypvpe5r0c3p2srkuqv4clx", 1000);
    try testing.expectEqualStrings("ob1qf7wv3txfsxwrxw5nypvpe5r0c3p2srkuqv4clx", reg.resolve("dave", 1001).?);
}

test "DnsRegistry — transfer by non-owner fails" {
    var reg = DnsRegistry.init();
    try reg.register("eve", "ob1qdz28c9t6r9qy33pu2agsnmms9nje88ejxrltgt", "ob1qdz28c9t6r9qy33pu2agsnmms9nje88ejxrltgt", 1000);
    try testing.expectError(error.NotOwner,
        reg.transfer("eve", "omnibus", "ob1q4h8ygpvx96d8u3mkdt0phyyunmzevgc5k96qgg", "ob1q4h8ygpvx96d8u3mkdt0phyyunmzevgc5k96qgg", "ob1q4h8ygpvx96d8u3mkdt0phyyunmzevgc5k96qgg", 1000));
}

test "DnsRegistry — renew" {
    var reg = DnsRegistry.init();
    try reg.register("frank", "ob1q8lrgnmdspgyj3lwt5d8zehlarzqrdxffsgx5u0", "ob1q8lrgnmdspgyj3lwt5d8zehlarzqrdxffsgx5u0", 1000);
    try reg.renew("frank", "omnibus", "ob1q8lrgnmdspgyj3lwt5d8zehlarzqrdxffsgx5u0", 2000);
    // Should be valid far in the future
    try testing.expect(reg.resolve("frank", 2000 + RENEWAL_PERIOD_BLOCKS - 1) != null);
}

test "DnsRegistry — active count" {
    var reg = DnsRegistry.init();
    try reg.register("aaa", "ob1qrgq6jnvvhcmp03ur849a85mhdvsvaqf6dprzn4", "ob1qrgq6jnvvhcmp03ur849a85mhdvsvaqf6dprzn4", 1000);
    try reg.register("bbb", "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0", "ob1qn8hr9y543qdvegeueffktd9lkrt2vq6q457xa0", 1000);
    try testing.expectEqual(@as(usize, 2), reg.activeCount(1001));
}

test "DnsRegistry — same name, different TLDs coexist" {
    var reg = DnsRegistry.init();
    try reg.registerWithTld("alpha_brand", "omnibus", "ob1qaaa", "ob1qaaa", 1000);
    // Phase 2 brand-protection: a *different* owner cannot grab the same name on
    // a different TLD — cross-TLD uniqueness fires first.
    try testing.expectError(error.NameTakenCrossTld,
        reg.registerWithTld("alpha_brand", "arbitraje", "ob1qbbb", "ob1qbbb", 1000));
    // Same owner is still allowed across TLDs.
    try reg.registerWithTld("alpha_brand", "arbitraje", "ob1qaaa", "ob1qaaa", 1000);
    try testing.expectEqualStrings("ob1qaaa", reg.resolveWithTld("alpha_brand", "omnibus", 1001).?);
    try testing.expectEqualStrings("ob1qaaa", reg.resolveWithTld("alpha_brand", "arbitraje", 1001).?);
}

test "DnsRegistry — invalid TLD rejected" {
    var reg = DnsRegistry.init();
    try testing.expectError(error.InvalidTld,
        reg.registerWithTld("alice", "eth", "ob1qaaa", "ob1qaaa", 1000));
}

test "DnsRegistry — fullLabel renders <name>.<tld>" {
    var reg = DnsRegistry.init();
    try reg.registerWithTld("kimi_alpha", "arbitraje", "ob1qaaa", "ob1qaaa", 1000);
    var buf: [64]u8 = undefined;
    const label = reg.entries[0].fullLabel(&buf);
    try testing.expectEqualStrings("kimi_alpha.arbitraje", label);
}

test "DnsRegistry — save and load round-trip (v2)" {
    var reg = DnsRegistry.init();
    try reg.registerWithTld("alice", "omnibus", "ob1qaaa", "ob1qaaa", 1000);
    try reg.registerWithTld("arb_bot", "arbitraje", "ob1qbbb", "ob1qbbb", 2000);

    const tmp_path = "test_dns_roundtrip_v2.bin";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    try reg.saveToFile(tmp_path);

    var reg2 = DnsRegistry.init();
    try reg2.loadFromFile(tmp_path);
    try testing.expectEqual(@as(usize, 2), reg2.entry_count);
    try testing.expectEqualStrings("ob1qaaa", reg2.resolveWithTld("alice", "omnibus", 1001).?);
    try testing.expectEqualStrings("ob1qbbb", reg2.resolveWithTld("arb_bot", "arbitraje", 2001).?);
    // Verify v2 fields preserved
    try testing.expectEqual(@as(u64, 0), reg2.entries[0].last_nonce);
    try testing.expectEqual(@as(u64, 1000), reg2.entries[0].last_action_block);
    try testing.expectEqual(@as(u64, 1000 + RENEWAL_PERIOD_BLOCKS + GRACE_PERIOD_BLOCKS), reg2.entries[0].grace_until_block);
}

test "DnsRegistry — v1 to v2 migration" {
    // Build a v1 file manually and verify loader upgrades it.
    var reg = DnsRegistry.init();
    try reg.registerWithTld("legacy", "omnibus", "ob1qlegacy", "ob1qlegacy", 500);

    // Save as v1 by temporarily writing raw bytes
    const tmp_path = "test_dns_v1_migration.bin";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    {
        var file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer file.close();
        var hdr: [16]u8 = undefined;
        @memcpy(hdr[0..8], &DnsRegistry.MAGIC);
        std.mem.writeInt(u32, hdr[8..12], 1, .little); // v1
        std.mem.writeInt(u32, hdr[12..16], 1, .little);
        try file.writeAll(&hdr);
        var rec: [190]u8 = undefined;
        @memset(&rec, 0);
        const e = reg.entries[0];
        rec[0] = e.name_len;
        @memcpy(rec[1..26], &e.name);
        rec[26] = e.tld_len;
        @memcpy(rec[27..43], &e.tld);
        rec[43] = e.addr_len;
        @memcpy(rec[44..108], &e.address);
        rec[108] = e.owner_len;
        @memcpy(rec[109..173], &e.owner);
        std.mem.writeInt(u64, rec[173..181], e.registered_block, .little);
        std.mem.writeInt(u64, rec[181..189], e.expires_block, .little);
        rec[189] = if (e.active) 1 else 0;
        try file.writeAll(&rec);
    }

    var reg2 = DnsRegistry.init();
    try reg2.loadFromFile(tmp_path);
    try testing.expectEqual(@as(usize, 1), reg2.entry_count);
    try testing.expectEqualStrings("legacy", reg2.entries[0].getName());
    // v2 defaults filled in
    try testing.expectEqual(@as(u64, 0), reg2.entries[0].last_nonce);
    try testing.expectEqual(@as(u64, 500), reg2.entries[0].last_action_block);
    try testing.expectEqual(@as(u64, 500 + RENEWAL_PERIOD_BLOCKS + GRACE_PERIOD_BLOCKS), reg2.entries[0].grace_until_block);
}

test "DnsRegistry — consumed_txids persist across save/load (MEDIUM-03)" {
    var reg = DnsRegistry.init();
    try reg.registerWithTld("alice", "omnibus", "ob1qaaa", "ob1qaaa", 1000);

    // Mark two distinct fee TXids as consumed.
    const tx1 = "a" ** TXID_LEN; // 64 'a'
    const tx2 = "b" ** TXID_LEN; // 64 'b'
    try reg.consumeTxid(tx1);
    try reg.consumeTxid(tx2);
    try testing.expect(reg.isTxidConsumed(tx1));
    try testing.expect(reg.isTxidConsumed(tx2));

    const tmp_path = "test_dns_consumed_v4.bin";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};
    try reg.saveToFile(tmp_path);

    var reg2 = DnsRegistry.init();
    try reg2.loadFromFile(tmp_path);
    try testing.expectEqual(@as(usize, 2), reg2.consumed_count);
    try testing.expect(reg2.isTxidConsumed(tx1));
    try testing.expect(reg2.isTxidConsumed(tx2));

    // A previously-unseen TXid must NOT match.
    const tx3 = "c" ** TXID_LEN;
    try testing.expect(!reg2.isTxidConsumed(tx3));

    // Replay attack simulation: attacker tries to re-consume tx1 after restart.
    // Without persistence this would have succeeded; with v4 it must fail.
    try testing.expect(reg2.isTxidConsumed(tx1));
}

test "DnsRegistry — load from missing file returns empty registry" {
    var reg = DnsRegistry.init();
    try reg.loadFromFile("definitely_does_not_exist_12345.bin");
    try testing.expectEqual(@as(usize, 0), reg.entry_count);
}

// ─── Phase 1 new tests ─────────────────────────────────────────────────────

test "DnsRegistry — reserved name rejected" {
    var reg = DnsRegistry.init();
    try testing.expectError(error.ReservedName,
        reg.register("google", "ob1qaaa", "ob1qaaa", 1000));
    try testing.expectError(error.ReservedName,
        reg.register("omnibus", "ob1qaaa", "ob1qaaa", 1000));
}

test "DnsRegistry — per-owner cap enforced" {
    var reg = DnsRegistry.init();
    const owner = "ob1qcapowner000000000000000000000000000000";
    var i: usize = 0;
    while (i < MAX_NAMES_PER_OWNER) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "user{d}", .{i}) catch continue;
        try reg.register(name, owner, owner, 1000);
    }
    // 11th should fail
    try testing.expectError(error.OwnerCapExceeded,
        reg.register("user_overflow", owner, owner, 1000));
}

test "DnsRegistry — premium pricing tiers" {
    try testing.expectEqual(feeForName("a", "omnibus") , COST_OMNIBUS_SAT * 200);
    try testing.expectEqual(feeForName("ab", "omnibus"), COST_OMNIBUS_SAT * 100);
    try testing.expectEqual(feeForName("abc", "omnibus"), COST_OMNIBUS_SAT * 20);
    try testing.expectEqual(feeForName("abcd", "omnibus"), COST_OMNIBUS_SAT * 4);
    try testing.expectEqual(feeForName("abcde", "omnibus"), COST_OMNIBUS_SAT);
}

test "DnsRegistry — update address by owner" {
    var reg = DnsRegistry.init();
    try reg.register("updateme", "ob1qold", "ob1qold", 1000);
    try reg.updateAddress("updateme", "omnibus", "ob1qold", "ob1qnew", 1001);
    try testing.expectEqualStrings("ob1qnew", reg.resolve("updateme", 1001).?);
    try testing.expectEqual(@as(u64, 1001), reg.entries[0].last_action_block);
}

test "DnsRegistry — update by non-owner fails" {
    var reg = DnsRegistry.init();
    try reg.register("secure", "ob1qowner", "ob1qowner", 1000);
    try testing.expectError(error.NotOwner,
        reg.updateAddress("secure", "omnibus", "ob1qimpostor", "ob1qnew", 1001));
}

test "DnsRegistry — renew extends expires_block exactly" {
    var reg = DnsRegistry.init();
    try reg.register("renewme", "ob1qaaa", "ob1qaaa", 1000);
    try reg.renew("renewme", "omnibus", "ob1qaaa", 5000);
    try testing.expectEqual(@as(u64, 5000 + RENEWAL_PERIOD_BLOCKS), reg.entries[0].expires_block);
}

test "DnsRegistry — grace period fields set correctly" {
    var reg = DnsRegistry.init();
    try reg.register("grace_test", "ob1qaaa", "ob1qaaa", 1000);
    const e = reg.entries[0];
    try testing.expectEqual(@as(u64, 1000 + RENEWAL_PERIOD_BLOCKS), e.expires_block);
    try testing.expectEqual(@as(u64, 1000 + RENEWAL_PERIOD_BLOCKS + GRACE_PERIOD_BLOCKS), e.grace_until_block);
    try testing.expect(e.isInGrace(1000 + RENEWAL_PERIOD_BLOCKS + 1));
    try testing.expect(e.isInGrace(1000 + RENEWAL_PERIOD_BLOCKS + GRACE_PERIOD_BLOCKS - 1));
    try testing.expect(!e.isAuctionable(1000 + RENEWAL_PERIOD_BLOCKS + GRACE_PERIOD_BLOCKS - 1));
    try testing.expect(e.isAuctionable(1000 + RENEWAL_PERIOD_BLOCKS + GRACE_PERIOD_BLOCKS));
}

test "DnsRegistry — renewWithYears extends expiry from existing expires_block" {
    var reg = DnsRegistry.init();
    try reg.registerWithTldYears("rny", "omnibus", "ob1qaaa", "ob1qaaa", 1000, 5);
    const initial_expires = reg.entries[0].expires_block;
    try testing.expectEqual(@as(u64, 1000 + 5 * BLOCKS_PER_YEAR), initial_expires);
    try testing.expectEqual(@as(u32, 5), reg.entries[0].registered_years);

    // Renew +10y BEFORE expiry — anchor at existing expires_block, no time burned.
    try reg.renewWithYears("rny", "omnibus", "ob1qaaa", 10, 2000);
    try testing.expectEqual(@as(u64, initial_expires + 10 * BLOCKS_PER_YEAR), reg.entries[0].expires_block);
    try testing.expectEqual(@as(u32, 15), reg.entries[0].registered_years);
    try testing.expectEqual(@as(u64, reg.entries[0].expires_block + GRACE_PERIOD_BLOCKS), reg.entries[0].grace_until_block);
}

test "DnsRegistry — renewWithYears caps at MAX_REGISTRATION_YEARS" {
    var reg = DnsRegistry.init();
    try reg.registerWithTldYears("rcap", "omnibus", "ob1qaaa", "ob1qaaa", 1000, 100);
    try testing.expectError(error.YearsCapExceeded,
        reg.renewWithYears("rcap", "omnibus", "ob1qaaa", 1, 2000));
}

test "DnsRegistry — renewWithYears rejects invalid years tier" {
    var reg = DnsRegistry.init();
    try reg.registerWithTldYears("rinv", "omnibus", "ob1qaaa", "ob1qaaa", 1000, 1);
    try testing.expectError(error.InvalidYears,
        reg.renewWithYears("rinv", "omnibus", "ob1qaaa", 7, 2000));
}

test "DnsRegistry — renewWithYears rejects non-owner" {
    var reg = DnsRegistry.init();
    try reg.registerWithTldYears("rno", "omnibus", "ob1qaaa", "ob1qaaa", 1000, 1);
    try testing.expectError(error.NotOwner,
        reg.renewWithYears("rno", "omnibus", "ob1qbbb", 1, 2000));
}

test "DnsRegistry — renewWithYears legacy entry (registered_years==0) treats as 1y" {
    var reg = DnsRegistry.init();
    try reg.registerWithTldYears("rlegacy", "omnibus", "ob1qaaa", "ob1qaaa", 1000, 1);
    // Simulate a legacy v1 record where years was never written.
    reg.entries[0].registered_years = 0;
    try reg.renewWithYears("rlegacy", "omnibus", "ob1qaaa", 4, 2000);
    // 0 (treated as 1) + 4 = 5 total
    try testing.expectEqual(@as(u32, 5), reg.entries[0].registered_years);
}

test "DnsRegistry — renewWithYears anchors to current_block when in grace" {
    var reg = DnsRegistry.init();
    try reg.registerWithTldYears("rgrace", "omnibus", "ob1qaaa", "ob1qaaa", 1000, 1);
    const post_expiry = 1000 + BLOCKS_PER_YEAR + 100; // in grace
    try reg.renewWithYears("rgrace", "omnibus", "ob1qaaa", 2, post_expiry);
    try testing.expectEqual(@as(u64, post_expiry + 2 * BLOCKS_PER_YEAR), reg.entries[0].expires_block);
}

test "DnsRegistry — pruneExpiredNames drops only past-grace entries" {
    var reg = DnsRegistry.init();
    try reg.registerWithTldYears("alive", "omnibus", "ob1qa", "ob1qa", 1000, 1);
    try reg.registerWithTldYears("ingrace", "omnibus", "ob1qb", "ob1qb", 1000, 1);
    try reg.registerWithTldYears("dead", "omnibus", "ob1qc", "ob1qc", 1000, 1);
    // Make `dead` past grace, `ingrace` in grace, `alive` still valid.
    reg.entries[2].expires_block = 1100;
    reg.entries[2].grace_until_block = 1200;
    reg.entries[1].expires_block = 1100;
    reg.entries[1].grace_until_block = 5000;

    const removed = reg.pruneExpiredNames(1500);
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(usize, 2), reg.entry_count);
    // `alive` and `ingrace` survive
    try testing.expect(reg.lookupEntry("alive", "omnibus") != null);
    try testing.expect(reg.lookupEntry("ingrace", "omnibus") != null);
    try testing.expect(reg.lookupEntry("dead", "omnibus") == null);
}

test "DnsRegistry — getExpiringNames returns only owner's about-to-expire" {
    var reg = DnsRegistry.init();
    try reg.registerWithTldYears("mine_soon", "omnibus", "ob1qme", "ob1qme", 1000, 1);
    try reg.registerWithTldYears("mine_far",  "omnibus", "ob1qme", "ob1qme", 1000, 100);
    try reg.registerWithTldYears("yours",     "bank",    "ob1qyou","ob1qyou",1000, 1);

    var buf: [10]*const DnsEntry = undefined;
    // 30-day threshold, current ~6 months before mine_soon expires
    const threshold: u64 = 30 * 86_400; // 30 days in seconds (=blocks at 1s/block)
    const cb: u64 = 1000 + BLOCKS_PER_YEAR - threshold + 100; // inside the window
    const n = reg.getExpiringNames("ob1qme", cb, threshold, &buf);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqualStrings("mine_soon", buf[0].getName());
}

test "DnsRegistry — feeForRenewal mirrors feeForRegistration curve" {
    try testing.expectEqual(feeForRegistration("alice", "omnibus", 1),
                            feeForRenewal("alice", "omnibus", 1));
    try testing.expectEqual(feeForRegistration("alice", "omnibus", 100),
                            feeForRenewal("alice", "omnibus", 100));
}

test "DnsRegistry — sybilFeeMultiplierMilli curve (anti-bulk-squat)" {
    // 0 names → 1.0×
    try testing.expectEqual(@as(u64, 1000), sybilFeeMultiplierMilli(0));
    // 5 names → 2.0×
    try testing.expectEqual(@as(u64, 2000), sybilFeeMultiplierMilli(5));
    // 50 names → 11.0×
    try testing.expectEqual(@as(u64, 11000), sybilFeeMultiplierMilli(50));
    // 100 names → 21.0×
    try testing.expectEqual(@as(u64, 21000), sybilFeeMultiplierMilli(100));
}

test "DnsRegistry — feeForRegistrationWithOwnerCount applies multiplier" {
    const base = feeForRegistration("alice", "omnibus", 1);
    // First-time registrant pays exactly the base fee.
    try testing.expectEqual(base, feeForRegistrationWithOwnerCount("alice", "omnibus", 1, 0));
    // After 5 prior names, pays 2× the base fee.
    try testing.expectEqual(base * 2, feeForRegistrationWithOwnerCount("alice", "omnibus", 1, 5));
    // After 50 prior names, pays 11× — bulk squatting becomes costly.
    try testing.expectEqual(base * 11, feeForRegistrationWithOwnerCount("alice", "omnibus", 1, 50));
}

test "DnsRegistry — lookupEntry finds expired but active names" {
    var reg = DnsRegistry.init();
    try reg.register("expired_but_exists", "ob1qaaa", "ob1qaaa", 1000);
    // Expired but still in registry
    const future = 1000 + RENEWAL_PERIOD_BLOCKS + 10;
    try testing.expect(reg.resolve("expired_but_exists", future) == null);
    const e = reg.lookupEntry("expired_but_exists", "omnibus");
    try testing.expect(e != null);
    try testing.expectEqualStrings("ob1qaaa", e.?.getOwner());
}
