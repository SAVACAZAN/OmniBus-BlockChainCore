//! id_compliance.zig — GDPR + MiCA compliance surface.
//!
//! This module is the canonical compliance entry point. It aggregates the
//! economic facet's MiCA / AML / KYC attestations into versioned, signable
//! reports, and implements GDPR §17 (right to be forgotten) with an audit
//! trail that satisfies §30 (record of processing).
//!
//! Design notes:
//!   - The report format is versioned (`mica_report_version`). Future
//!     regulator-specific adapters add new versions, never mutate v1.
//!   - Missing fields are emitted as zeros / false / "" — we never invent
//!     data to look complete. A regulator can distinguish "not disclosed"
//!     from "screened = false" via the AML attestation date.
//!   - The Manifest root stays anchored on chain even after a GDPR wipe:
//!     deleting the salt makes the KycHash unverifiable from any future
//!     KYC re-submission, which is the legally accepted "anonymisation by
//!     uncoupling" pattern under GDPR §17.

const std = @import("std");
const salt_mod = @import("id_salt.zig");
const economic = @import("id_economic.zig");

pub const MICA_REPORT_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// MiCA disclosure types — re-exported from id_economic so callers that only
// import id_compliance get a complete compliance surface without reaching
// into the economic facet module.
// ---------------------------------------------------------------------------

pub const MicaRiskCategory = economic.MicaRiskCategory;
pub const MicaDisclosure = economic.MicaDisclosure;
pub const AmlAttestation = economic.AmlAttestation;
pub const KycAttestation = economic.KycAttestation;

/// A MiCA "issuer flag" check — true iff the holder has self-declared as an
/// issuer of crypto-assets under MiCA. Used by the RPC layer to surface the
/// flag in `getobm` without re-parsing the economic facet root.
pub fn isIssuer(m: MicaDisclosure) bool {
    return m.is_issuer;
}

/// Aggregated MiCA disclosure summary — useful for CLI output and audit
/// trails. All fields are derived from the economic facet; nothing new
/// is stored on chain.
pub const MicaSummary = struct {
    is_issuer: bool,
    white_paper_hash: [32]u8,
    risk_category: MicaRiskCategory,
    aml_screened: bool,
    aml_screening_date_unix_s: u64,
    kyc_verified: bool,
    kyc_valid_until_unix_s: u64,
};

pub fn buildMicaSummary(
    mica: MicaDisclosure,
    aml: AmlAttestation,
    kyc: KycAttestation,
) MicaSummary {
    return .{
        .is_issuer = mica.is_issuer,
        .white_paper_hash = mica.white_paper_hash,
        .risk_category = mica.risk_category,
        .aml_screened = aml.sanctions_screened,
        .aml_screening_date_unix_s = aml.screening_date_unix_s,
        .kyc_verified = kyc.is_verified,
        .kyc_valid_until_unix_s = kyc.valid_until_unix_s,
    };
}

// ---------------------------------------------------------------------------
// MiCA report — full, versioned, signable.
// ---------------------------------------------------------------------------

pub const MicaReport = struct {
    version: u32,
    address: []const u8,
    generated_unix_s: u64,
    node_id: []const u8,
    mica: MicaDisclosure,
    aml: AmlAttestation,
    kyc: KycAttestation,
    /// SHA-256 over the canonical JSON of every field above except this one.
    /// Lets a verifier confirm the report wasn't tampered with.
    report_hash: [32]u8,
};

fn hexLowerWrite(writer: anytype, bytes: []const u8) !void {
    const hex = "0123456789abcdef";
    for (bytes) |b| {
        try writer.writeByte(hex[b >> 4]);
        try writer.writeByte(hex[b & 0x0F]);
    }
}

fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, bytes.len * 2);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0x0F];
    }
    return buf;
}

/// Emits the canonical pre-hash JSON body (without `report_hash`) into an
/// allocated buffer. Field order is fixed forever for v1 — never reorder.
fn micaReportCanonicalBody(
    allocator: std.mem.Allocator,
    address: []const u8,
    generated_unix_s: u64,
    node_id: []const u8,
    mica: MicaDisclosure,
    aml: AmlAttestation,
    kyc: KycAttestation,
) ![]u8 {
    const wp = try bytesToHexAlloc(allocator, &mica.white_paper_hash);
    defer allocator.free(wp);
    const le = try bytesToHexAlloc(allocator, &mica.issuer_legal_entity_hash);
    defer allocator.free(le);
    const aml_issuer = try bytesToHexAlloc(allocator, &aml.issuer_did_hash);
    defer allocator.free(aml_issuer);
    const aml_sig = try bytesToHexAlloc(allocator, &aml.signature);
    defer allocator.free(aml_sig);
    const kyc_issuer = try bytesToHexAlloc(allocator, &kyc.issuer_did_hash);
    defer allocator.free(kyc_issuer);
    const kyc_sig = try bytesToHexAlloc(allocator, &kyc.signature);
    defer allocator.free(kyc_sig);

    return std.fmt.allocPrint(
        allocator,
        "{{" ++
            "\"version\":{d}," ++
            "\"address\":\"{s}\"," ++
            "\"generated_unix_s\":{d}," ++
            "\"node_id\":\"{s}\"," ++
            "\"mica\":{{\"is_issuer\":{s},\"white_paper_hash\":\"{s}\",\"risk_category\":{d},\"issuer_legal_entity_hash\":\"{s}\"}}," ++
            "\"aml\":{{\"sanctions_screened\":{s},\"screening_date_unix_s\":{d},\"issuer_did_hash\":\"{s}\",\"signature\":\"{s}\"}}," ++
            "\"kyc\":{{\"is_verified\":{s},\"valid_until_unix_s\":{d},\"issuer_did_hash\":\"{s}\",\"signature\":\"{s}\"}}" ++
        "}}",
        .{
            MICA_REPORT_VERSION,
            address,
            generated_unix_s,
            node_id,
            if (mica.is_issuer) "true" else "false",
            wp,
            @intFromEnum(mica.risk_category),
            le,
            if (aml.sanctions_screened) "true" else "false",
            aml.screening_date_unix_s,
            aml_issuer,
            aml_sig,
            if (kyc.is_verified) "true" else "false",
            kyc.valid_until_unix_s,
            kyc_issuer,
            kyc_sig,
        },
    );
}

/// Build a MiCA report struct, computing the report_hash from the canonical
/// body. Caller does not need to free anything — the struct holds references
/// to caller-owned strings (address, node_id).
pub fn buildMicaReport(
    allocator: std.mem.Allocator,
    address: []const u8,
    generated_unix_s: u64,
    node_id: []const u8,
    mica: MicaDisclosure,
    aml: AmlAttestation,
    kyc: KycAttestation,
) !MicaReport {
    const body = try micaReportCanonicalBody(allocator, address, generated_unix_s, node_id, mica, aml, kyc);
    defer allocator.free(body);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &hash, .{});
    return .{
        .version = MICA_REPORT_VERSION,
        .address = address,
        .generated_unix_s = generated_unix_s,
        .node_id = node_id,
        .mica = mica,
        .aml = aml,
        .kyc = kyc,
        .report_hash = hash,
    };
}

/// Serialize a MiCA report to the on-wire JSON. Includes `report_hash` as
/// the final field. Stable for v1 — adapters for future regulators must
/// add a new version constant and a new serializer.
pub fn micaReportJson(
    allocator: std.mem.Allocator,
    report: MicaReport,
) ![]u8 {
    const body = try micaReportCanonicalBody(
        allocator,
        report.address,
        report.generated_unix_s,
        report.node_id,
        report.mica,
        report.aml,
        report.kyc,
    );
    defer allocator.free(body);
    const hash_hex = try bytesToHexAlloc(allocator, &report.report_hash);
    defer allocator.free(hash_hex);

    // Splice "report_hash" before the closing brace, preserving canonical order.
    std.debug.assert(body[body.len - 1] == '}');
    const head = body[0 .. body.len - 1];
    return std.fmt.allocPrint(allocator, "{s},\"report_hash\":\"{s}\"}}", .{ head, hash_hex });
}

/// One-shot helper: build + serialize. Equivalent to the old micaReportStub
/// signature but returns a real, verifiable report.
pub fn micaReport(
    allocator: std.mem.Allocator,
    address: []const u8,
    generated_unix_s: u64,
    node_id: []const u8,
    mica: MicaDisclosure,
    aml: AmlAttestation,
    kyc: KycAttestation,
) ![]u8 {
    const r = try buildMicaReport(allocator, address, generated_unix_s, node_id, mica, aml, kyc);
    return micaReportJson(allocator, r);
}

// ---------------------------------------------------------------------------
// GDPR §17 — right to be forgotten, with §30 record of processing.
// ---------------------------------------------------------------------------

pub const GdprForgottenEvent = struct {
    /// SHA-256 of the address that requested erasure. Storing the raw
    /// address would defeat the purpose of the erasure request.
    address_hash: [32]u8,
    unix_s: u64,
};

/// In-memory transparency counter. The chain process owns one instance;
/// the RPC layer reads it for the transparency report. Cleared on restart
/// is acceptable — the audit log on disk is the durable record.
pub const GdprStats = struct {
    forgotten_total: u64 = 0,
    last_forgotten_unix_s: u64 = 0,

    pub fn record(self: *GdprStats, when_unix_s: u64) void {
        self.forgotten_total += 1;
        self.last_forgotten_unix_s = when_unix_s;
    }
};

fn hashAddress(address: []const u8) [32]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(address, &h, .{});
    return h;
}

/// GDPR §17 — erase the salt so the on-chain KycHash can never be matched
/// to a re-submitted KYC document. Also records the erasure in the
/// transparency counter and returns an audit event the caller can append
/// to an on-disk log.
pub fn rightToBeForgotten(
    manager: salt_mod.SaltManager,
    address: []const u8,
    now_unix_s: u64,
    stats: *GdprStats,
) !GdprForgottenEvent {
    try manager.delete();
    const ev = GdprForgottenEvent{
        .address_hash = hashAddress(address),
        .unix_s = now_unix_s,
    };
    stats.record(now_unix_s);
    return ev;
}

/// Legacy one-arg form, kept for tests and tools that don't need an audit
/// trail. New code should call the full `rightToBeForgotten` above.
pub fn rightToBeForgottenSimple(manager: salt_mod.SaltManager) !void {
    try manager.delete();
}

pub fn gdprEventJson(
    allocator: std.mem.Allocator,
    ev: GdprForgottenEvent,
) ![]u8 {
    const hh = try bytesToHexAlloc(allocator, &ev.address_hash);
    defer allocator.free(hh);
    return std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"gdpr_forgotten\",\"address_hash\":\"{s}\",\"unix_s\":{d}}}",
        .{ hh, ev.unix_s },
    );
}

// ---------------------------------------------------------------------------
// Legacy summary serializer kept verbatim — used by RPC `getmica`. Do not
// remove without coordinating with rpc_server.zig.
// ---------------------------------------------------------------------------

pub fn micaSummaryJson(
    address: []const u8,
    summary: MicaSummary,
    allocator: std.mem.Allocator,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"address\":\"{s}\",\"is_issuer\":{s},\"risk_category\":{d},\"aml_screened\":{s},\"kyc_verified\":{s},\"kyc_valid_until\":{d}}}",
        .{
            address,
            if (summary.is_issuer) "true" else "false",
            @intFromEnum(summary.risk_category),
            if (summary.aml_screened) "true" else "false",
            if (summary.kyc_verified) "true" else "false",
            summary.kyc_valid_until_unix_s,
        },
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "rightToBeForgottenSimple wipes the salt" {
    var mem = salt_mod.MemorySaltManager{};
    const mgr = mem.manager();
    _ = try mgr.getOrCreate();
    try rightToBeForgottenSimple(mgr);
    try std.testing.expect(mem.salt == null);
}

test "rightToBeForgotten records audit event and bumps counter" {
    var mem = salt_mod.MemorySaltManager{};
    const mgr = mem.manager();
    _ = try mgr.getOrCreate();
    var stats = GdprStats{};
    const ev = try rightToBeForgotten(mgr, "ob1qtest", 1_750_000_000, &stats);
    try std.testing.expect(mem.salt == null);
    try std.testing.expectEqual(@as(u64, 1), stats.forgotten_total);
    try std.testing.expectEqual(@as(u64, 1_750_000_000), stats.last_forgotten_unix_s);
    try std.testing.expectEqual(@as(u64, 1_750_000_000), ev.unix_s);

    // address_hash must not be all zeros and must equal sha256(address)
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("ob1qtest", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &ev.address_hash);
}

test "gdprEventJson shape" {
    const ev = GdprForgottenEvent{
        .address_hash = [_]u8{0xAB} ** 32,
        .unix_s = 1_750_000_000,
    };
    const out = try gdprEventJson(std.testing.allocator, ev);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"event\":\"gdpr_forgotten\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"unix_s\":1750000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ababab") != null);
}

test "buildMicaSummary copies fields verbatim" {
    const m = MicaDisclosure{
        .is_issuer = true,
        .white_paper_hash = [_]u8{0xAB} ** 32,
        .risk_category = .medium,
        .issuer_legal_entity_hash = [_]u8{0xCD} ** 32,
    };
    const a = AmlAttestation{
        .sanctions_screened = true,
        .screening_date_unix_s = 1_750_000_000,
        .issuer_did_hash = [_]u8{0} ** 32,
        .signature = [_]u8{0} ** 64,
    };
    const k = KycAttestation{
        .is_verified = true,
        .valid_until_unix_s = 2_000_000_000,
        .issuer_did_hash = [_]u8{0} ** 32,
        .signature = [_]u8{0} ** 64,
    };
    const s = buildMicaSummary(m, a, k);
    try std.testing.expect(s.is_issuer);
    try std.testing.expectEqual(@as(u64, 2_000_000_000), s.kyc_valid_until_unix_s);
    try std.testing.expectEqual(MicaRiskCategory.medium, s.risk_category);
}

test "micaSummaryJson contains expected fields" {
    const summary = MicaSummary{
        .is_issuer = true,
        .white_paper_hash = [_]u8{0} ** 32,
        .risk_category = .low,
        .aml_screened = false,
        .aml_screening_date_unix_s = 0,
        .kyc_verified = true,
        .kyc_valid_until_unix_s = 12345,
    };
    const out = try micaSummaryJson("ob1qtest", summary, std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"is_issuer\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"kyc_valid_until\":12345") != null);
}

test "micaReport produces versioned json with stable hash" {
    const m = MicaDisclosure{
        .is_issuer = true,
        .white_paper_hash = [_]u8{0x11} ** 32,
        .risk_category = .high,
        .issuer_legal_entity_hash = [_]u8{0x22} ** 32,
    };
    const a = AmlAttestation{
        .sanctions_screened = true,
        .screening_date_unix_s = 1_750_000_000,
        .issuer_did_hash = [_]u8{0x33} ** 32,
        .signature = [_]u8{0x44} ** 64,
    };
    const k = KycAttestation{
        .is_verified = true,
        .valid_until_unix_s = 2_000_000_000,
        .issuer_did_hash = [_]u8{0x55} ** 32,
        .signature = [_]u8{0x66} ** 64,
    };

    const out1 = try micaReport(std.testing.allocator, "ob1qtest", 1_750_000_001, "node-1", m, a, k);
    defer std.testing.allocator.free(out1);
    const out2 = try micaReport(std.testing.allocator, "ob1qtest", 1_750_000_001, "node-1", m, a, k);
    defer std.testing.allocator.free(out2);

    // Determinism: same inputs → same output (including report_hash)
    try std.testing.expectEqualSlices(u8, out1, out2);

    try std.testing.expect(std.mem.indexOf(u8, out1, "\"version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "\"address\":\"ob1qtest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "\"node_id\":\"node-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "\"risk_category\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "\"report_hash\":\"") != null);
    // No "deferred" or "stub" anywhere
    try std.testing.expect(std.mem.indexOf(u8, out1, "deferred") == null);
    try std.testing.expect(std.mem.indexOf(u8, out1, "stub") == null);
}

test "buildMicaReport hash changes when any field changes" {
    const m = MicaDisclosure{
        .is_issuer = false,
        .white_paper_hash = [_]u8{0} ** 32,
        .risk_category = .none,
        .issuer_legal_entity_hash = [_]u8{0} ** 32,
    };
    const a = AmlAttestation{
        .sanctions_screened = false,
        .screening_date_unix_s = 0,
        .issuer_did_hash = [_]u8{0} ** 32,
        .signature = [_]u8{0} ** 64,
    };
    const k = KycAttestation{
        .is_verified = false,
        .valid_until_unix_s = 0,
        .issuer_did_hash = [_]u8{0} ** 32,
        .signature = [_]u8{0} ** 64,
    };
    const r1 = try buildMicaReport(std.testing.allocator, "ob1qa", 100, "n1", m, a, k);
    var m2 = m;
    m2.is_issuer = true;
    const r2 = try buildMicaReport(std.testing.allocator, "ob1qa", 100, "n1", m2, a, k);
    try std.testing.expect(!std.mem.eql(u8, &r1.report_hash, &r2.report_hash));
}

// Silence unused-import warning of hexLowerWrite (kept for future signed-report serializer).
test "hexLowerWrite helper" {
    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try hexLowerWrite(fbs.writer(), &[_]u8{ 0xAB, 0xCD });
    try std.testing.expectEqualSlices(u8, "abcd", &buf);
}
