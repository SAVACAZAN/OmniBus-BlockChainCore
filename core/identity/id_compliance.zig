//! id_compliance.zig — GDPR-related operations and MiCA hook points.
//!
//! GDPR "right to be forgotten" is the only feature implemented here: it
//! erases the salt so the chain's stored KycHash can no longer be matched
//! to any KYC document the user might re-submit. The Manifest root stays
//! on chain as immutable history, but verifiers can't re-derive it.
//!
//! MiCA reporting is deferred — leave the hook signature stable so the
//! reporter module can be added later without changing call sites.

const std = @import("std");
const salt_mod = @import("id_salt.zig");
const economic = @import("id_economic.zig");

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

/// GDPR §17 — delete the salt. The Manifest root remains anchored but
/// becomes unverifiable from future KYC re-submissions.
pub fn rightToBeForgotten(manager: salt_mod.SaltManager) !void {
    try manager.delete();
}

/// MiCA Article 60 reporting hook — placeholder until the reporter is
/// implemented in its own module. Returning a sentinel string lets the
/// CLI / RPC surface a clear "not yet implemented" without crashing.
pub fn micaReportStub(address: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"address\":\"{s}\",\"mica_report\":\"deferred\"}}",
        .{address},
    );
}

/// Lightweight JSON serializer for a MiCA summary — used by RPC `getmica`.
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

test "rightToBeForgotten wipes the salt" {
    var mem = salt_mod.MemorySaltManager{};
    const mgr = mem.manager();
    _ = try mgr.getOrCreate();
    try rightToBeForgotten(mgr);
    try std.testing.expect(mem.salt == null);
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

test "mica stub returns json-shaped string" {
    const out = try micaReportStub("ob1qtest", std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"address\":\"ob1qtest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"mica_report\":\"deferred\"") != null);
}
