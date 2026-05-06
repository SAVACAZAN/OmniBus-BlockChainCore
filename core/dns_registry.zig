const std = @import("std");
const registrar_mod = @import("registrar_addresses.zig");

/// Built-in DNS / Herotag System
///
/// On-chain name-to-address registry (ca EGLD Herotag, ETH ENS, Solana SNS):
///   - @username -> ob_omni_address
///   - Human-readable names instead of long hex addresses
///   - Names are unique, first-come-first-served
///   - Transfer + expiry support
///
/// Diferenta fata de domain_minter.zig:
///   domain_minter = PQ domain derivation (ob_omni_, ob_k1_, etc.)
///   dns_registry  = human-readable names mapped to addresses (@alice -> ob_omni_...)

/// Maximum name length (like EGLD herotag: 25 chars)
pub const MAX_NAME_LEN: usize = 25;
/// Minimum name length
pub const MIN_NAME_LEN: usize = 3;
/// Maximum registry entries (per-node tracking, full registry on disk)
pub const MAX_ENTRIES: usize = 4096;
/// Registration cost in SAT (1 OMNI = 1e9 SAT).
/// Default cost — used if no per-TLD override.
pub const REGISTER_COST_SAT: u64 = 1_000_000_000;
/// Per-TLD fees. Alex (2026-04-27): "5 sau 10 OMNI"
pub const COST_OMNIBUS_SAT: u64 = 5_000_000_000;   // 5 OMNI per .omnibus name
pub const COST_ARBITRAJE_SAT: u64 = 10_000_000_000; // 10 OMNI per .arbitraje name (premium)
/// Phase 2 — institutional / themed TLDs added 2026-05-06.
/// On TESTNET all of them cost a flat 1_000_000 SAT (0.001 OMNI) so we can
/// test allocation without burning balance. The mainnet target tiers (set in
/// comments) reflect anti-squatting + institutional gravity:
///   .quantum  = 10 OMNI   (premium personal tier)
///   .bank     = 50 OMNI   (financial institution)
///   .gov      = 100 OMNI  (top tier; phase-2 will gate via on-chain attestation)
///   .mil      = 50 OMNI   (military / defense)
///   .fin      = 50 OMNI   (financial trustees, funds, pensions)
///   .edu      = 20 OMNI   (academic, with discount)
///   .org      = 10 OMNI   (non-profit / NGO discount)
///   .dev      = 5 OMNI    (developer, baseline)
pub const COST_TESTNET_TIER_SAT: u64 = 1_000_000;  // 0.001 OMNI on testnet
pub const COST_QUANTUM_SAT: u64 = COST_TESTNET_TIER_SAT;
pub const COST_BANK_SAT: u64    = COST_TESTNET_TIER_SAT;
pub const COST_GOV_SAT: u64     = COST_TESTNET_TIER_SAT;
pub const COST_MIL_SAT: u64     = COST_TESTNET_TIER_SAT;
pub const COST_FIN_SAT: u64     = COST_TESTNET_TIER_SAT;
pub const COST_EDU_SAT: u64     = COST_TESTNET_TIER_SAT;
pub const COST_ORG_SAT: u64     = COST_TESTNET_TIER_SAT;
pub const COST_DEV_SAT: u64     = COST_TESTNET_TIER_SAT;
/// Block time assumption: ~1 second per block. Adjust constants if chain
/// retargets to a different cadence.
pub const BLOCKS_PER_YEAR: u64 = 31_557_600;        // 365.25 * 86_400

/// Default registration period if owner doesn't specify `years`. Stays at
/// 1 year for backward compatibility with v1/v2 entries.
pub const RENEWAL_PERIOD_BLOCKS: u64 = BLOCKS_PER_YEAR;

/// Grace period after expiry — owner can still renew. Other parties remain
/// blocked. After this, the name + cross-TLD lock release entirely.
pub const GRACE_PERIOD_BLOCKS: u64 = 2_592_000;     // ~30 days

/// Allowed registration durations (years) — owner picks one of these tiers
/// at register/renew time. More years up-front = better OMNI/year ratio.
pub const ALLOWED_YEARS = [_]u32{ 1, 2, 3, 4, 5, 10, 25, 50, 100 };
/// Maximum years a single registration can lock. Hard cap.
pub const MAX_REGISTRATION_YEARS: u32 = 100;
/// Minimum years.
pub const MIN_REGISTRATION_YEARS: u32 = 1;

/// Returns `true` if `years` is one of the allowed durations.
pub fn isValidYears(years: u32) bool {
    for (ALLOWED_YEARS) |y| {
        if (y == years) return true;
    }
    return false;
}

/// Multiplier (in basis-points × 10, i.e. integer × 1000 for precision)
/// applied to the per-year fee to get the total fee for `years`.
/// Curve rewards long-term commitments with progressively better /year rate.
///
/// Examples (base fee = 5 OMNI on .omnibus, mainnet):
///   1y:  5 OMNI   × 1.000 = 5 OMNI            (5 OMNI/yr)
///   2y:  5 OMNI   × 1.900 = 9.5 OMNI          (4.75 OMNI/yr — 5% off)
///   3y:  5 OMNI   × 2.800 = 14 OMNI           (4.67 OMNI/yr)
///   5y:  5 OMNI   × 4.500 = 22.5 OMNI         (4.50 OMNI/yr — 10% off)
///   10y: 5 OMNI   × 8.000 = 40 OMNI           (4.00 OMNI/yr — 20% off)
///   25y: 5 OMNI   × 18.000 = 90 OMNI          (3.60 OMNI/yr — 28% off)
///   50y: 5 OMNI   × 32.000 = 160 OMNI         (3.20 OMNI/yr — 36% off)
///   100y:5 OMNI   × 55.000 = 275 OMNI         (2.75 OMNI/yr — 45% off)
pub fn yearsMultiplierMilli(years: u32) u64 {
    return switch (years) {
        1   => 1_000,
        2   => 1_900,
        3   => 2_800,
        4   => 3_700,
        5   => 4_500,
        10  => 8_000,
        25  => 18_000,
        50  => 32_000,
        100 => 55_000,
        else => 0, // invalid
    };
}

/// Compute total fee for `years` registration on a given TLD + name length.
/// = feeForName(name, tld) × yearsMultiplierMilli(years) / 1000.
pub fn feeForRegistration(name: []const u8, tld: []const u8, years: u32) u64 {
    const base = feeForName(name, tld);
    const mul = yearsMultiplierMilli(years);
    if (mul == 0) return 0; // invalid years
    return (base * mul) / 1_000;
}

/// Phase 2 — renewal fee for `additional_years`. Same multiplier curve as
/// registration: 1y costs base, 100y costs ~55× base instead of 100×.
/// The renewal pricing intentionally matches registration so the owner
/// always sees a single, simple price table.
pub fn feeForRenewal(name: []const u8, tld: []const u8, additional_years: u32) u64 {
    return feeForRegistration(name, tld, additional_years);
}

/// Returneaza fee-ul required pentru un TLD (in SAT).
pub fn feeForTld(tld: []const u8) u64 {
    if (std.mem.eql(u8, tld, "omnibus"))   return COST_OMNIBUS_SAT;
    if (std.mem.eql(u8, tld, "arbitraje")) return COST_ARBITRAJE_SAT;
    if (std.mem.eql(u8, tld, "quantum"))   return COST_QUANTUM_SAT;
    if (std.mem.eql(u8, tld, "bank"))      return COST_BANK_SAT;
    if (std.mem.eql(u8, tld, "gov"))       return COST_GOV_SAT;
    if (std.mem.eql(u8, tld, "mil"))       return COST_MIL_SAT;
    if (std.mem.eql(u8, tld, "fin"))       return COST_FIN_SAT;
    if (std.mem.eql(u8, tld, "edu"))       return COST_EDU_SAT;
    if (std.mem.eql(u8, tld, "org"))       return COST_ORG_SAT;
    if (std.mem.eql(u8, tld, "dev"))       return COST_DEV_SAT;
    return REGISTER_COST_SAT; // fallback
}

/// Premium pricing — anti-squatting. Short names cost more, exponentially.
/// Multiplier applied on top of feeForTld(tld).
///   1 char  = base * 200  (e.g. 1000 OMNI on .omnibus, 2000 OMNI on .arbitraje)
///   2 chars = base * 100
///   3 chars = base * 20
///   4 chars = base * 4
///   5+      = base (5 OMNI on .omnibus, 10 OMNI on .arbitraje)
///
/// MIN_NAME_LEN currently 3, so 1- and 2-char tiers are dormant unless the
/// floor lowers in the future. Kept here so opening shorter names becomes
/// a one-line policy change instead of a fee table rewrite.
pub fn feeForName(name: []const u8, tld: []const u8) u64 {
    const base = feeForTld(tld);
    return switch (name.len) {
        1 => base * 200,
        2 => base * 100,
        3 => base * 20,
        4 => base * 4,
        else => base,
    };
}

/// Maximum names a single owner can hold. Anti-hoarding for the
/// pay-to-claim flow; the registrar slots in registrar_addresses.zig
/// are exempt (they need many reserved names by design).
pub const MAX_NAMES_PER_OWNER: usize = 10;

/// op_return prefix that turns a regular transfer into a name claim.
/// A TX with `op_return = "ns_claim:<name>.<tld>"`, `to == NS_TREASURY`,
/// `amount >= feeForName(name, tld)` causes the chain to auto-register
/// `<name>.<tld>` to the sender's address at applyBlock time. No separate
/// signed RPC needed — the TX signature itself proves the sender owns
/// the address being registered.
pub const CLAIM_MEMO_PREFIX: []const u8 = "ns_claim:";

/// Parse a `ns_claim:<name>.<tld>` op_return memo. Returns the parsed
/// name + tld on success. The TLD must be in ALLOWED_TLDS, the name must
/// pass `isValidName`. Whitespace is rejected; we do NOT trim — strict
/// matching only, so a malformed memo can never accidentally register.
///
/// Returns null when the memo isn't a claim or fails validation; the
/// caller treats it as a regular non-claim transfer.
pub fn parseClaimMemo(op_return: []const u8) ?struct { name: []const u8, tld: []const u8 } {
    if (op_return.len <= CLAIM_MEMO_PREFIX.len) return null;
    if (!std.mem.startsWith(u8, op_return, CLAIM_MEMO_PREFIX)) return null;
    const body = op_return[CLAIM_MEMO_PREFIX.len..];

    // Split at the last '.' — name may not contain '.', tld is everything after.
    const dot_pos = std.mem.lastIndexOfScalar(u8, body, '.') orelse return null;
    const name = body[0..dot_pos];
    const tld = body[dot_pos + 1 ..];

    if (!isValidName(name)) return null;
    if (!isValidTld(tld)) return null;
    return .{ .name = name, .tld = tld };
}

/// Maximum TLD length. ".omnibus" = 7 chars (no dot), ".arbitraje" = 9 chars.
pub const MAX_TLD_LEN: usize = 16;
/// Default TLD if caller doesn't specify (backward compat).
pub const DEFAULT_TLD: []const u8 = "omnibus";

/// Currently allowed TLDs. Add new ones here.
///
/// Phase 1 (open registration on all): omnibus, arbitraje, quantum, bank,
/// gov, mil, fin, edu, org, dev. The institutional TLDs (bank/gov/mil/fin)
/// are open for now on testnet — Phase 2 will gate them via on-chain
/// attestation (only verified entities can register).
pub const ALLOWED_TLDS = [_][]const u8{
    "omnibus",   // base TLD — personal default
    "arbitraje", // for arbitrage agents / market-making nodes
    "quantum",   // premium personal tier (PQ-aware identities)
    "bank",      // banks, financial institutions
    "gov",       // government, prefectures, state agencies
    "mil",       // military, defense contractors
    "fin",       // financial trustees, funds, pensions
    "edu",       // universities, research institutes
    "org",       // NGOs, charities, non-profits
    "dev",       // developers, open-source projects
};

pub fn isValidTld(tld: []const u8) bool {
    for (ALLOWED_TLDS) |t| {
        if (std.mem.eql(u8, tld, t)) return true;
    }
    return false;
}

/// Valid characters for names (alphanumeric + underscore, like EGLD herotag)
fn isValidNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// Validate a name
pub fn isValidName(name: []const u8) bool {
    if (name.len < MIN_NAME_LEN or name.len > MAX_NAME_LEN) return false;
    // Must start with letter
    if (name[0] < 'a' or name[0] > 'z') return false;
    for (name) |c| {
        if (!isValidNameChar(c)) return false;
    }
    return true;
}

/// Hardcoded reserved names (brands + ecosystem internals + institutional).
/// These are reserved across ALL TLDs (so `bcr.omnibus`, `bcr.bank`,
/// `bcr.fin` are all blocked unless claimed by the legitimate entity in
/// Phase 2 via on-chain attestation).
pub const RESERVED_NAMES = [_][]const u8{
    // OmniBus / ecosystem self-references
    "omnibus", "omni", "blockchain", "satoshi", "nakamoto",
    "exchange", "wallet", "node", "miner", "validator", "treasury",
    "admin", "root", "system", "api", "support",
    // Top global brands
    "google", "apple", "microsoft", "amazon", "meta", "facebook",
    "tesla", "spacex", "twitter", "x", "openai", "anthropic",
    "binance", "coinbase", "kraken", "uniswap", "metamask", "ledger",
    "ethereum", "bitcoin", "solana", "polygon", "arbitrum", "base",
    "lcx", "liberty",
    // Stablecoins / financial
    "usdc", "usdt", "dai", "tether", "circle",
    "visa", "mastercard", "paypal", "stripe",
    // RO banks (.bank — protect Romanian banking brands)
    "bcr", "brd", "bt", "ing", "raiffeisen", "unicredit", "cec",
    "alpha", "garanti", "patria", "libra", "exim",
    // Government / official RO (.gov — protect state agencies)
    "guvern", "presedintie", "parlament", "senat", "camera",
    "mae",      // Ministerul Afacerilor Externe
    "mapn",     // Ministerul Apararii Nationale
    "mai",      // Ministerul Afacerilor Interne
    "mfp",      // Ministerul Finantelor Publice
    "mts",      // Ministerul Tineretului si Sportului
    "mmediu",   // Ministerul Mediului
    "mt",       // Ministerul Transporturilor
    "msanatate","ministerul",
    "anaf", "bnr", "asf", "csm", "ccr", "iccj",
    // Government / official global (top-level abbreviations)
    "fbi", "cia", "nsa", "dod", "irs", "sec", "fcc", "fda", "epa",
    "europa", "ec", "eu", "nato", "un", "who", "imf", "worldbank",
    // Military (.mil — protect armed forces brands)
    "us-army", "usarmy", "navy", "airforce", "marines",
    "smfa",     // Statul Major al Fortelor Aeriene (RO)
    "smfn",     // Statul Major al Fortelor Navale (RO)
    "smfr",     // Statul Major al Fortelor Terestre (RO)
    // Education (.edu — protect top RO + global universities)
    "ubb",       // Universitatea Babes-Bolyai
    "ub",        // Universitatea Bucuresti
    "upb",       // Politehnica Bucuresti
    "utcn",      // Tehnica Cluj-Napoca
    "ase",       // Academia de Studii Economice
    "tum", "umfst",
    "harvard", "mit", "stanford", "oxford", "cambridge",
    // Major NGOs (.org)
    "redcross", "unicef", "amnesty", "wwf", "greenpeace", "msf",
};

/// Returns true if `name.tld` is reserved.
///
/// Two layers:
///   1. RESERVED_NAMES (global brand list) — applies to every TLD.
///      "google" is unclaimable as both google.omnibus and google.arbitraje.
///   2. Registrar slot reservations (savacazan, ens, faucet, etc.) — these
///      are slot-tied to a SPECIFIC full label like "savacazan.omnibus".
///      They do NOT carry over to other TLDs. So `savacazan.arbitraje` is
///      free even though `savacazan.omnibus` is locked to slot 0.
pub fn isReservedName(name: []const u8, tld: []const u8) bool {
    // Layer 1: global brand list — TLD-agnostic.
    for (RESERVED_NAMES) |r| {
        if (std.mem.eql(u8, r, name)) return true;
    }
    // Layer 2: registrar slot reservations are full-label specific.
    // Check the actual `<name>.<tld>` pair, not just the bare label.
    var buf: [80]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}.{s}", .{ name, tld }) catch return false;
    if (registrar_mod.isReservedName(full)) return true;
    return false;
}

/// Returns true if `addr` is a registrar slot address (exempt from per-owner cap).
fn isRegistrarAddress(addr: []const u8) bool {
    for (registrar_mod.REGISTRAR_ADDRESSES) |slot| {
        if (slot.address.len == 0) continue;
        if (std.mem.eql(u8, slot.address, addr)) return true;
    }
    return false;
}

/// Maximum address length used by every slot. ECDSA bech32 = ~42 chars,
/// PQ-OMNI base58 ~38 chars; 64 fits all with margin.
pub const MAX_ADDR_LEN: usize = 64;

/// Phase 2 category tag — institutional / themed badge applied to a name.
/// Bag of 8 fixed slugs. `none` = legacy entries that pre-date Phase 2.
pub const Category = enum(u8) {
    none = 0,
    personal = 1,    // .omnibus / .quantum default human user
    bank = 2,        // .bank — financial institution
    gov = 3,         // .gov — government agency
    mil = 4,         // .mil — military
    fin = 5,         // .fin — financial trustee / fund / pension
    edu = 6,         // .edu — academic
    org = 7,         // .org — non-profit
    dev = 8,         // .dev — developer / open-source
    trading = 9,     // .arbitraje — market-making agent

    pub fn fromTld(tld: []const u8) Category {
        if (std.mem.eql(u8, tld, "omnibus"))   return .personal;
        if (std.mem.eql(u8, tld, "arbitraje")) return .trading;
        if (std.mem.eql(u8, tld, "quantum"))   return .personal;
        if (std.mem.eql(u8, tld, "bank"))      return .bank;
        if (std.mem.eql(u8, tld, "gov"))       return .gov;
        if (std.mem.eql(u8, tld, "mil"))       return .mil;
        if (std.mem.eql(u8, tld, "fin"))       return .fin;
        if (std.mem.eql(u8, tld, "edu"))       return .edu;
        if (std.mem.eql(u8, tld, "org"))       return .org;
        if (std.mem.eql(u8, tld, "dev"))       return .dev;
        return .none;
    }

    pub fn toString(self: Category) []const u8 {
        return switch (self) {
            .none => "none",
            .personal => "personal",
            .bank => "bank",
            .gov => "gov",
            .mil => "mil",
            .fin => "fin",
            .edu => "edu",
            .org => "org",
            .dev => "dev",
            .trading => "trading",
        };
    }
};

/// PQ scheme slot index — what `addr_pq_<X>` resolves to.
/// Aligns with isolated_wallet.Scheme codes 5..8 minus 5 (offset zero).
pub const PqSlot = enum(u8) {
    ml_dsa = 0,    // obk1_  → ML-DSA-87 (FIPS 204)
    falcon = 1,    // obf5_  → Falcon-512 (FIPS 206)
    dilithium = 2, // obs3_  → Dilithium-5 (ML-DSA-87 alias)
    slh_dsa = 3,   // obd5_  → SLH-DSA-256s (FIPS 205)
};

pub const PQ_SLOT_COUNT: usize = 4;

/// DNS entry (v3 layout — Phase 2: multi-address per name + category).
/// Backward compat: entries created in v1/v2 have `category == .none` and
/// all PQ slots `addr_pq_<X>_len == 0`. Resolvers fall back to `address`
/// (primary ECDSA) when the requested PQ slot is unset.
pub const DnsEntry = struct {
    /// Registered name (lowercase, alphanumeric)
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    /// TLD (e.g. "omnibus", "arbitraje"). Default = DEFAULT_TLD.
    tld: [MAX_TLD_LEN]u8,
    tld_len: u8,
    /// Primary address this name resolves to (ECDSA `ob1q…` typically).
    /// Backward compat: legacy entries store everything here.
    address: [MAX_ADDR_LEN]u8,
    addr_len: u8,
    /// Owner who registered (may differ from address)
    owner: [MAX_ADDR_LEN]u8,
    owner_len: u8,
    /// Block when registered
    registered_block: u64,
    /// Block when registration expires
    expires_block: u64,
    /// Is this entry active
    active: bool,
    /// Phase 1: last accepted nonce for this owner+name pair (replay protection)
    last_nonce: u64,
    /// Phase 1: block height of last register/transfer/update/renew
    last_action_block: u64,
    /// Phase 1: grace period end = expires_block + GRACE_PERIOD_BLOCKS
    grace_until_block: u64,
    /// Phase 2: category badge derived from TLD by default; owners may
    /// override via `updatename`. Legacy entries = .none until updated.
    category: Category = .none,
    /// Phase 2: 4 optional PQ-scheme address slots. Index by PqSlot.
    /// `addr_pq_lens[i] == 0` means "slot empty, fall back to primary".
    /// Same MAX_ADDR_LEN cap. All zero on legacy entries.
    addr_pq: [PQ_SLOT_COUNT][MAX_ADDR_LEN]u8 = [_][MAX_ADDR_LEN]u8{[_]u8{0} ** MAX_ADDR_LEN} ** PQ_SLOT_COUNT,
    addr_pq_lens: [PQ_SLOT_COUNT]u8 = [_]u8{0} ** PQ_SLOT_COUNT,
    /// Phase 2: owner's preferred scheme to receive funds. 0 = primary,
    /// 1..4 = PqSlot+1. Legacy entries = 0.
    preferred_slot: u8 = 0,
    /// Phase 2: years the owner registered/renewed for. Drives expires_block
    /// computation. Legacy entries default to 1 (single year, current behavior).
    registered_years: u32 = 1,

    pub fn getName(self: *const DnsEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getTld(self: *const DnsEntry) []const u8 {
        if (self.tld_len == 0) return DEFAULT_TLD;
        return self.tld[0..self.tld_len];
    }

    /// Full label including TLD: "alice.omnibus" sau "arb_hunter.arbitraje".
    /// `out_buf` must be >= MAX_NAME_LEN + 1 + MAX_TLD_LEN.
    pub fn fullLabel(self: *const DnsEntry, out_buf: []u8) []const u8 {
        const n = self.getName();
        const t = self.getTld();
        const total = n.len + 1 + t.len;
        if (out_buf.len < total) return n; // safety fallback
        @memcpy(out_buf[0..n.len], n);
        out_buf[n.len] = '.';
        @memcpy(out_buf[n.len + 1 .. n.len + 1 + t.len], t);
        return out_buf[0..total];
    }

    pub fn getAddress(self: *const DnsEntry) []const u8 {
        return self.address[0..self.addr_len];
    }

    pub fn getOwner(self: *const DnsEntry) []const u8 {
        return self.owner[0..self.owner_len];
    }

    /// Phase 2: get the address for a specific PQ scheme slot, or fall back
    /// to the primary address when the slot is empty (legacy entry / not set).
    pub fn getPqAddress(self: *const DnsEntry, slot: PqSlot) []const u8 {
        const idx = @intFromEnum(slot);
        const len = self.addr_pq_lens[idx];
        if (len == 0) return self.getAddress(); // fallback to primary
        return self.addr_pq[idx][0..len];
    }

    /// Phase 2: returns true when this entry has any PQ slot configured.
    pub fn hasAnyPqSlot(self: *const DnsEntry) bool {
        for (self.addr_pq_lens) |len| {
            if (len > 0) return true;
        }
        return false;
    }

    /// Phase 2: pick the address the owner most likely wants funds delivered to.
    /// `preferred_slot == 0` → primary (ECDSA). 1..4 → PqSlot index+1.
    pub fn getPreferredAddress(self: *const DnsEntry) []const u8 {
        if (self.preferred_slot == 0) return self.getAddress();
        if (self.preferred_slot >= 1 and self.preferred_slot <= PQ_SLOT_COUNT) {
            const slot: PqSlot = @enumFromInt(self.preferred_slot - 1);
            return self.getPqAddress(slot);
        }
        return self.getAddress();
    }

    /// Phase 2: set a PQ slot address. `addr.len == 0` clears the slot.
    pub fn setPqAddress(self: *DnsEntry, slot: PqSlot, addr: []const u8) error{AddrTooLong}!void {
        if (addr.len > MAX_ADDR_LEN) return error.AddrTooLong;
        const idx = @intFromEnum(slot);
        if (addr.len > 0) @memcpy(self.addr_pq[idx][0..addr.len], addr);
        self.addr_pq_lens[idx] = @intCast(addr.len);
    }

    pub fn isExpired(self: *const DnsEntry, current_block: u64) bool {
        return current_block >= self.expires_block;
    }

    /// Phase 1: name is in grace period (expired but within grace window).
    pub fn isInGrace(self: *const DnsEntry, current_block: u64) bool {
        return current_block >= self.expires_block and current_block < self.grace_until_block;
    }

    /// Phase 1: name is fully expired + past grace (auctionable / re-registerable).
    pub fn isAuctionable(self: *const DnsEntry, current_block: u64) bool {
        return current_block >= self.grace_until_block;
    }
};

/// Maximum tracked consumed-txid entries (anti-replay pentru fee TX-uri).
/// 4096 ar insemna 4096 nume inregistrate cu fee — generos pentru testnet.
pub const MAX_CONSUMED_TXIDS: usize = 4096;
/// Length of a TX hash hex (SHA256d -> 64 hex chars).
pub const TXID_LEN: usize = 64;

/// DNS Registry Engine
pub const DnsRegistry = struct {
    entries: [MAX_ENTRIES]DnsEntry,
    entry_count: usize,
    /// Treasury address — fee-urile ENS trebuie sa mearga aici. Setat de
    /// caller via setTreasury() la startup. Empty = no fee enforcement (testnet).
    treasury_address: [64]u8,
    treasury_addr_len: u8,
    /// Fee enforcement on/off. Cand off, registername merge fara fee (testnet
    /// dev mode). Cand on, mandatory.
    fee_enforcement: bool,
    /// Phase 1: when true, all state-changing operations require ECDSA signature.
    signed_required: bool,
    /// Set of consumed fee-txids (anti-replay).
    consumed_txids: [MAX_CONSUMED_TXIDS][TXID_LEN]u8,
    consumed_count: usize,

    pub fn init() DnsRegistry {
        return .{
            .entries = undefined,
            .entry_count = 0,
            .treasury_address = std.mem.zeroes([64]u8),
            .treasury_addr_len = 0,
            .fee_enforcement = false,
            .signed_required = true,
            .consumed_txids = std.mem.zeroes([MAX_CONSUMED_TXIDS][TXID_LEN]u8),
            .consumed_count = 0,
        };
    }

    /// Set the treasury address pentru fee-uri. Apelat la startup din main.zig
    /// dupa ce wallet-ul e derivat (idx 3 = ens.omnibus per memory).
    pub fn setTreasury(self: *DnsRegistry, address: []const u8) void {
        const len = @min(address.len, 64);
        @memcpy(self.treasury_address[0..len], address[0..len]);
        self.treasury_addr_len = @intCast(len);
    }

    pub fn getTreasury(self: *const DnsRegistry) []const u8 {
        return self.treasury_address[0..self.treasury_addr_len];
    }

    pub fn enableFee(self: *DnsRegistry, enable: bool) void {
        self.fee_enforcement = enable;
    }

    pub fn enableSigned(self: *DnsRegistry, enable: bool) void {
        self.signed_required = enable;
    }

    pub fn isTxidConsumed(self: *const DnsRegistry, txid: []const u8) bool {
        if (txid.len != TXID_LEN) return false;
        for (self.consumed_txids[0..self.consumed_count]) |t| {
            if (std.mem.eql(u8, &t, txid[0..TXID_LEN])) return true;
        }
        return false;
    }

    pub fn consumeTxid(self: *DnsRegistry, txid: []const u8) !void {
        if (txid.len != TXID_LEN) return error.InvalidTxid;
        if (self.consumed_count >= MAX_CONSUMED_TXIDS) return error.ConsumedTxidsFull;
        @memcpy(self.consumed_txids[self.consumed_count][0..], txid[0..TXID_LEN]);
        self.consumed_count += 1;
    }

    /// Phase 1: count active non-expired names owned by `owner`.
    pub fn countNamesOwnedBy(self: *const DnsRegistry, owner: []const u8, current_block: u64) usize {
        var count: usize = 0;
        for (self.entries[0..self.entry_count]) |e| {
            if (!e.active) continue;
            if (e.isExpired(current_block)) continue;
            if (!std.mem.eql(u8, e.getOwner(), owner)) continue;
            count += 1;
        }
        return count;
    }

    /// Phase 1: check if owner has reached the per-owner cap.
    /// Registrar slot addresses are exempt.
    pub fn isOwnerCapped(self: *const DnsRegistry, owner: []const u8, current_block: u64) bool {
        if (isRegistrarAddress(owner)) return false;
        return self.countNamesOwnedBy(owner, current_block) >= MAX_NAMES_PER_OWNER;
    }

    /// Phase 1: look up an entry by name + tld (including expired, for transfers/updates/renewals).
    pub fn lookupEntry(self: *DnsRegistry, name: []const u8, tld: []const u8) ?*DnsEntry {
        for (self.entries[0..self.entry_count]) |*e| {
            if (!e.active) continue;
            if (!std.mem.eql(u8, e.getName(), name)) continue;
            if (!std.mem.eql(u8, e.getTld(), tld)) continue;
            return e;
        }
        return null;
    }

    /// Pay-to-claim entry point — invoked from applyBlock when a TX with
    /// `op_return = "ns_claim:<name>.<tld>"` lands on the chain. The TX
    /// signature itself proves the claimer owns `claimer_address`, so no
    /// separate canonical message + sig verification is needed at this
    /// layer; the chain's TX validator already did that work.
    ///
    /// Caller (applyBlock in blockchain.zig) MUST have verified before
    /// calling this:
    ///   1. tx.to == NS_TREASURY (slot 5 ens.omnibus)
    ///   2. tx.amount >= feeForName(name, tld)
    ///   3. tx.op_return parses to (name, tld) via parseClaimMemo
    ///
    /// We then enforce the registry-level rules:
    ///   - name not reserved (RESERVED_NAMES list ∪ registrar slots)
    ///   - claimer not over the per-owner cap (registrar slots exempt)
    ///   - name not already taken under that TLD
    ///
    /// Returns void on success; an error tells the caller why we rejected.
    /// The fee TX is NOT consumed here — pay-to-claim is one-shot per TX,
    /// the consumed_txids set is for the legacy signed-register flow.
    pub fn claimByPayment(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        claimer_address: []const u8,
        current_block: u64,
    ) !void {
        if (!isValidName(name)) return error.InvalidName;
        if (!isValidTld(tld)) return error.InvalidTld;
        if (isReservedName(name, tld)) return error.NameReserved;
        if (self.isOwnerCapped(claimer_address, current_block)) return error.OwnerCapped;
        if (self.entry_count >= MAX_ENTRIES) return error.RegistryFull;
        if (self.resolveWithTld(name, tld, current_block) != null) return error.NameTaken;

        // Storage layer rejects on the same conditions; idempotent guard.
        try self.registerWithTld(name, tld, claimer_address, claimer_address, current_block);
    }

    /// Register a new name (default TLD = "omnibus" for backward compat).
    pub fn register(
        self: *DnsRegistry,
        name: []const u8,
        address: []const u8,
        owner: []const u8,
        current_block: u64,
    ) !void {
        return self.registerWithTld(name, DEFAULT_TLD, address, owner, current_block);
    }

    /// Verify fee context BEFORE register. Caller-ul (rpc_server) face check-uri:
    ///   - tx confirmed in chain
    ///   - tx.to == treasury_address
    ///   - tx.amount >= feeForName(name, tld)
    ///   - tx.txid not already consumed
    /// Apoi apeleaza registerWithTldAndFee(...) care consume txid-ul atomic.
    /// Daca fee_enforcement = false, fee_txid e ignorat (testnet dev mode).
    pub fn registerWithTldAndFee(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        address: []const u8,
        owner: []const u8,
        current_block: u64,
        fee_txid: ?[]const u8,
    ) !void {
        return self.registerWithTldYearsAndFee(name, tld, address, owner, current_block, fee_txid, 1);
    }

    /// Phase 2: register with explicit years tier.
    pub fn registerWithTldYearsAndFee(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        address: []const u8,
        owner: []const u8,
        current_block: u64,
        fee_txid: ?[]const u8,
        years: u32,
    ) !void {
        if (self.fee_enforcement) {
            const txid = fee_txid orelse return error.FeeRequired;
            if (txid.len != TXID_LEN) return error.InvalidTxid;
            if (self.isTxidConsumed(txid)) return error.TxidAlreadyUsed;
            // Caller (rpc_server) trebuie sa fi validat ca TX exista, are
            // amount corect, si destinatie e treasury. Aici doar consume.
            try self.consumeTxid(txid);
        }
        try self.registerWithTldYears(name, tld, address, owner, current_block, years);
    }

    /// Register with explicit TLD + years tier. Backward-compat wrapper
    /// `registerWithTld` (no years) defaults to 1 year.
    pub fn registerWithTld(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        address: []const u8,
        owner: []const u8,
        current_block: u64,
    ) !void {
        return self.registerWithTldYears(name, tld, address, owner, current_block, 1);
    }

    /// Same as registerWithTld but takes a years tier (1, 2, 3, 4, 5, 10, 25, 50, 100).
    /// expires_block = current_block + years * BLOCKS_PER_YEAR.
    pub fn registerWithTldYears(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        address: []const u8,
        owner: []const u8,
        current_block: u64,
        years: u32,
    ) !void {
        if (!isValidYears(years)) return error.InvalidYears;
        if (!isValidName(name)) return error.InvalidName;
        if (!isValidTld(tld)) return error.InvalidTld;
        if (self.entry_count >= MAX_ENTRIES) return error.RegistryFull;
        if (isReservedName(name, tld)) return error.ReservedName;
        if (self.isOwnerCapped(owner, current_block)) return error.OwnerCapExceeded;

        // Phase 2 — STRICT CROSS-TLD UNIQUENESS for brand protection.
        // If `name` is held by ANYONE on ANY TLD (active, not expired past
        // grace), reject unless the new claim is from the SAME owner.
        // Rationale: prevents `bcr.bank` (owner X) and `bcr.gov` (owner Y)
        // from coexisting under different parties — that's brand confusion.
        // Same owner CAN claim the same name across TLDs (alice.omnibus +
        // alice.bank if Alice is a banker).
        for (self.entries[0..self.entry_count]) |*e| {
            if (!e.active) continue;
            if (e.isAuctionable(current_block)) continue; // released / squat-bait
            if (!std.mem.eql(u8, e.getName(), name)) continue;
            // same name held — owner-match check
            if (!std.mem.eql(u8, e.getOwner(), owner)) {
                return error.NameTakenCrossTld;
            }
            // same owner: allowed across TLDs, but NameTaken on identical pair
            if (std.mem.eql(u8, e.getTld(), tld)) {
                return error.NameTaken;
            }
        }

        // Allow re-registration if the existing entry is auctionable (expired + past grace).
        if (self.lookupEntry(name, tld)) |existing| {
            if (!existing.isAuctionable(current_block)) return error.NameTaken;
            // Mark old entry inactive so new registration can take its slot.
            existing.active = false;
        }

        var entry: DnsEntry = std.mem.zeroes(DnsEntry);
        const nlen = @min(name.len, MAX_NAME_LEN);
        @memcpy(entry.name[0..nlen], name[0..nlen]);
        entry.name_len = @intCast(nlen);

        const tlen = @min(tld.len, MAX_TLD_LEN);
        @memcpy(entry.tld[0..tlen], tld[0..tlen]);
        entry.tld_len = @intCast(tlen);

        const alen = @min(address.len, 64);
        @memcpy(entry.address[0..alen], address[0..alen]);
        entry.addr_len = @intCast(alen);

        const olen = @min(owner.len, 64);
        @memcpy(entry.owner[0..olen], owner[0..olen]);
        entry.owner_len = @intCast(olen);

        entry.registered_block = current_block;
        // Phase 2: expires after `years * BLOCKS_PER_YEAR` (was hardcoded 1y).
        entry.expires_block = current_block + (@as(u64, years) * BLOCKS_PER_YEAR);
        entry.registered_years = years;
        entry.active = true;
        // Phase 1 v2 fields
        entry.last_nonce = 0;
        entry.last_action_block = current_block;
        entry.grace_until_block = entry.expires_block + GRACE_PERIOD_BLOCKS;
        // Phase 2: auto-derive category from TLD. Owners can override
        // later via updatename if they want a non-default category.
        // PQ slots remain empty; setPqAddress lets owners populate them.
        entry.category = Category.fromTld(tld);

        self.entries[self.entry_count] = entry;
        self.entry_count += 1;
    }

    /// Resolve name (default TLD = "omnibus" for backward compat).
    pub fn resolve(self: *const DnsRegistry, name: []const u8, current_block: u64) ?[]const u8 {
        return self.resolveWithTld(name, DEFAULT_TLD, current_block);
    }

    /// Resolve with explicit TLD.
    pub fn resolveWithTld(
        self: *const DnsRegistry,
        name: []const u8,
        tld: []const u8,
        current_block: u64,
    ) ?[]const u8 {
        for (self.entries[0..self.entry_count]) |*e| {
            if (!e.active or e.isExpired(current_block)) continue;
            if (!std.mem.eql(u8, e.getName(), name)) continue;
            if (!std.mem.eql(u8, e.getTld(), tld)) continue;
            return e.getAddress();
        }
        return null;
    }

    /// Reverse resolve: address to name (returns first match across TLDs).
    pub fn reverseResolve(self: *const DnsRegistry, address: []const u8, current_block: u64) ?[]const u8 {
        for (self.entries[0..self.entry_count]) |*e| {
            if (e.active and !e.isExpired(current_block) and
                std.mem.eql(u8, e.getAddress(), address))
            {
                return e.getName();
            }
        }
        return null;
    }

    // ── Persistence ─────────────────────────────────────────────────────────

    /// Magic header for the persistence file format.
    /// Layout: 8B magic | 4B version | 4B entry_count | entries...
    ///
    /// v1 entry: 1B name_len + 25B name | 1B tld_len + 16B tld |
    ///           1B addr_len + 64B addr | 1B owner_len + 64B owner |
    ///           8B reg_block | 8B exp_block | 1B active
    /// = 1+25+1+16+1+64+1+64+8+8+1 = 190 bytes per entry.
    ///
    /// v2 entry: v1 fields + 8B last_nonce + 8B last_action_block + 8B grace_until_block
    /// = 190 + 24 = 214 bytes per entry.
    const MAGIC: [8]u8 = [_]u8{ 'O', 'M', 'N', 'I', 'D', 'N', 'S', '1' };
    const VERSION: u32 = 3;
    const HEADER_SIZE: usize = 8 + 4 + 4;
    const V1_ENTRY_SIZE: usize = 190;
    const V2_ENTRY_SIZE: usize = 214;
    // v3 adds: category(1) + addr_pq(4*64=256) + addr_pq_lens(4)
    //         + preferred_slot(1) + registered_years(4) = 266 bytes.
    const V3_ENTRY_SIZE: usize = V2_ENTRY_SIZE + 1 + (PQ_SLOT_COUNT * MAX_ADDR_LEN) + PQ_SLOT_COUNT + 1 + 4;

    pub fn saveToFile(self: *const DnsRegistry, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        var buf: [HEADER_SIZE]u8 = undefined;
        @memcpy(buf[0..8], &MAGIC);
        std.mem.writeInt(u32, buf[8..12], VERSION, .little);
        std.mem.writeInt(u32, buf[12..16], @intCast(self.entry_count), .little);
        try file.writeAll(&buf);
        var rec: [V3_ENTRY_SIZE]u8 = undefined;
        for (self.entries[0..self.entry_count]) |e| {
            @memset(&rec, 0);
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
            // v2 fields
            std.mem.writeInt(u64, rec[190..198], e.last_nonce, .little);
            std.mem.writeInt(u64, rec[198..206], e.last_action_block, .little);
            std.mem.writeInt(u64, rec[206..214], e.grace_until_block, .little);
            // v3 fields (Phase 2)
            var off: usize = V2_ENTRY_SIZE;
            rec[off] = @intFromEnum(e.category);
            off += 1;
            // addr_pq[4][64]
            var s: usize = 0;
            while (s < PQ_SLOT_COUNT) : (s += 1) {
                @memcpy(rec[off .. off + MAX_ADDR_LEN], &e.addr_pq[s]);
                off += MAX_ADDR_LEN;
            }
            // addr_pq_lens[4]
            @memcpy(rec[off .. off + PQ_SLOT_COUNT], &e.addr_pq_lens);
            off += PQ_SLOT_COUNT;
            rec[off] = e.preferred_slot;
            off += 1;
            std.mem.writeInt(u32, rec[off..][0..4], e.registered_years, .little);
            try file.writeAll(&rec);
        }
    }

    pub fn loadFromFile(self: *DnsRegistry, path: []const u8) !void {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // First run — empty registry. Not an error.
                self.entry_count = 0;
                return;
            },
            else => return err,
        };
        defer file.close();
        var hdr: [HEADER_SIZE]u8 = undefined;
        const n = try file.readAll(&hdr);
        if (n < HEADER_SIZE) return error.CorruptFile;
        if (!std.mem.eql(u8, hdr[0..8], &MAGIC)) return error.BadMagic;
        const ver = std.mem.readInt(u32, hdr[8..12], .little);
        const count = std.mem.readInt(u32, hdr[12..16], .little);
        if (count > MAX_ENTRIES) return error.TooManyEntries;
        self.entry_count = 0;

        if (ver == 3) {
            var rec: [V3_ENTRY_SIZE]u8 = undefined;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const r = try file.readAll(&rec);
                if (r < V3_ENTRY_SIZE) return error.CorruptFile;
                var e: DnsEntry = std.mem.zeroes(DnsEntry);
                e.name_len = rec[0];
                @memcpy(&e.name, rec[1..26]);
                e.tld_len = rec[26];
                @memcpy(&e.tld, rec[27..43]);
                e.addr_len = rec[43];
                @memcpy(&e.address, rec[44..108]);
                e.owner_len = rec[108];
                @memcpy(&e.owner, rec[109..173]);
                e.registered_block = std.mem.readInt(u64, rec[173..181], .little);
                e.expires_block = std.mem.readInt(u64, rec[181..189], .little);
                e.active = rec[189] != 0;
                e.last_nonce = std.mem.readInt(u64, rec[190..198], .little);
                e.last_action_block = std.mem.readInt(u64, rec[198..206], .little);
                e.grace_until_block = std.mem.readInt(u64, rec[206..214], .little);
                // v3 fields
                var off: usize = V2_ENTRY_SIZE;
                const cat_byte = rec[off];
                e.category = std.meta.intToEnum(Category, cat_byte) catch .none;
                off += 1;
                var s: usize = 0;
                while (s < PQ_SLOT_COUNT) : (s += 1) {
                    @memcpy(&e.addr_pq[s], rec[off .. off + MAX_ADDR_LEN]);
                    off += MAX_ADDR_LEN;
                }
                @memcpy(&e.addr_pq_lens, rec[off .. off + PQ_SLOT_COUNT]);
                off += PQ_SLOT_COUNT;
                e.preferred_slot = rec[off];
                off += 1;
                e.registered_years = std.mem.readInt(u32, rec[off..][0..4], .little);
                self.entries[self.entry_count] = e;
                self.entry_count += 1;
            }
        } else if (ver == 2) {
            var rec: [V2_ENTRY_SIZE]u8 = undefined;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const r = try file.readAll(&rec);
                if (r < V2_ENTRY_SIZE) return error.CorruptFile;
                var e: DnsEntry = std.mem.zeroes(DnsEntry);
                e.name_len = rec[0];
                @memcpy(&e.name, rec[1..26]);
                e.tld_len = rec[26];
                @memcpy(&e.tld, rec[27..43]);
                e.addr_len = rec[43];
                @memcpy(&e.address, rec[44..108]);
                e.owner_len = rec[108];
                @memcpy(&e.owner, rec[109..173]);
                e.registered_block = std.mem.readInt(u64, rec[173..181], .little);
                e.expires_block = std.mem.readInt(u64, rec[181..189], .little);
                e.active = rec[189] != 0;
                e.last_nonce = std.mem.readInt(u64, rec[190..198], .little);
                e.last_action_block = std.mem.readInt(u64, rec[198..206], .little);
                e.grace_until_block = std.mem.readInt(u64, rec[206..214], .little);
                // v3 fields default to zero (category=.none, all slots empty,
                // preferred_slot=0, registered_years=0). migrateLegacyEntries()
                // backfills these to sensible values after load.
                self.entries[self.entry_count] = e;
                self.entry_count += 1;
            }
        } else if (ver == 1) {
            // v1 migration: read 190-byte records, fill v2 fields with defaults.
            var rec: [V1_ENTRY_SIZE]u8 = undefined;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const r = try file.readAll(&rec);
                if (r < V1_ENTRY_SIZE) return error.CorruptFile;
                var e: DnsEntry = std.mem.zeroes(DnsEntry);
                e.name_len = rec[0];
                @memcpy(&e.name, rec[1..26]);
                e.tld_len = rec[26];
                @memcpy(&e.tld, rec[27..43]);
                e.addr_len = rec[43];
                @memcpy(&e.address, rec[44..108]);
                e.owner_len = rec[108];
                @memcpy(&e.owner, rec[109..173]);
                e.registered_block = std.mem.readInt(u64, rec[173..181], .little);
                e.expires_block = std.mem.readInt(u64, rec[181..189], .little);
                e.active = rec[189] != 0;
                // v2 defaults
                e.last_nonce = 0;
                e.last_action_block = e.registered_block;
                e.grace_until_block = e.expires_block + GRACE_PERIOD_BLOCKS;
                self.entries[self.entry_count] = e;
                self.entry_count += 1;
            }
        } else {
            return error.UnsupportedVersion;
        }
    }

    /// Renew a name (extend expiry). Phase 1: requires current owner, updates nonce.
    pub fn renew(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        owner: []const u8,
        current_block: u64,
    ) !void {
        const e = self.lookupEntry(name, tld) orelse return error.NameNotFound;
        if (!std.mem.eql(u8, e.getOwner(), owner)) return error.NotOwner;
        e.expires_block = current_block + RENEWAL_PERIOD_BLOCKS;
        e.grace_until_block = e.expires_block + GRACE_PERIOD_BLOCKS;
        e.last_action_block = current_block;
    }

    /// Phase 2 — years-aware renewal. Extends `expires_block` by
    /// `additional_years * BLOCKS_PER_YEAR` (relative to the current expiry,
    /// NOT current_block, so renewing early doesn't waste already-paid time).
    /// Caps cumulative `registered_years` at MAX_REGISTRATION_YEARS.
    ///
    /// Backward compat: legacy entries with `registered_years == 0` are
    /// treated as 1y (the default duration of all v1/v2 records). After
    /// renewWithYears they're brought up to `1 + additional_years`.
    ///
    /// Errors:
    ///   error.NameNotFound     — entry missing
    ///   error.NotOwner         — caller is not current owner
    ///   error.InvalidYears     — `additional_years` not in ALLOWED_YEARS
    ///   error.YearsCapExceeded — total registered_years would exceed 100
    pub fn renewWithYears(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        owner: []const u8,
        additional_years: u32,
        current_block: u64,
    ) !void {
        if (!isValidYears(additional_years)) return error.InvalidYears;
        const e = self.lookupEntry(name, tld) orelse return error.NameNotFound;
        if (!std.mem.eql(u8, e.getOwner(), owner)) return error.NotOwner;

        // Treat legacy `registered_years == 0` as 1y (the implicit v1 default).
        const effective_existing: u32 = if (e.registered_years == 0) 1 else e.registered_years;
        const new_total: u64 = @as(u64, effective_existing) + @as(u64, additional_years);
        if (new_total > MAX_REGISTRATION_YEARS) return error.YearsCapExceeded;

        // Add to the EXISTING expiry, not current_block — renewing 6 months
        // before expiry shouldn't burn 6 months. If the entry is already past
        // expiry (in grace), anchor to current_block instead so the new
        // window is `additional_years` from now.
        const anchor: u64 = if (e.expires_block > current_block) e.expires_block else current_block;
        e.expires_block = anchor + (@as(u64, additional_years) * BLOCKS_PER_YEAR);
        e.grace_until_block = e.expires_block + GRACE_PERIOD_BLOCKS;
        e.registered_years = @intCast(new_total);
        e.last_action_block = current_block;
    }

    /// Phase 2 — drop entries whose grace period has fully elapsed. Returns
    /// the number of entries removed. Safe to call periodically (e.g. every
    /// N blocks from main.zig). The deletion is in-place + compact, so
    /// `entry_count` shrinks by the returned value.
    ///
    /// We prune past-grace, NOT past-expiry: an expired-but-in-grace name
    /// can still be renewed by its owner, so dropping it would lose data.
    pub fn pruneExpiredNames(self: *DnsRegistry, current_block: u64) usize {
        var removed: usize = 0;
        var i: usize = 0;
        while (i < self.entry_count) {
            const e = &self.entries[i];
            // Only consider truly auctionable (past grace) entries. Inactive
            // entries (already marked dead) also get compacted.
            const is_dead_past_grace = e.active and e.isAuctionable(current_block);
            if (is_dead_past_grace or !e.active) {
                // Swap-with-last to compact in O(1) per removal.
                if (i + 1 < self.entry_count) {
                    self.entries[i] = self.entries[self.entry_count - 1];
                }
                self.entry_count -= 1;
                removed += 1;
                // Don't advance i — the swapped-in entry needs checking too.
                continue;
            }
            i += 1;
        }
        return removed;
    }

    /// Phase 2 — list names owned by `owner` that expire within
    /// `blocks_threshold` blocks from `current_block`. Writes up to
    /// `out.len` entries and returns the number written. Used by the UI
    /// to surface "your N name(s) expire soon" warnings in the header pill.
    ///
    /// Selection: entry must be active, NOT yet expired, and
    /// (expires_block - current_block) <= blocks_threshold. Already-expired
    /// names (in grace) are also included since the owner urgently needs
    /// to renew them before they auction off.
    pub fn getExpiringNames(
        self: *const DnsRegistry,
        owner: []const u8,
        current_block: u64,
        blocks_threshold: u64,
        out: []*const DnsEntry,
    ) usize {
        var n: usize = 0;
        for (self.entries[0..self.entry_count]) |*e| {
            if (n >= out.len) break;
            if (!e.active) continue;
            if (!std.mem.eql(u8, e.getOwner(), owner)) continue;
            // Past-grace entries are auctionable — owner already lost them.
            if (e.isAuctionable(current_block)) continue;
            // In-grace entries always count as "expiring" (urgent).
            if (e.isInGrace(current_block)) {
                out[n] = e;
                n += 1;
                continue;
            }
            // Pre-expiry: include if within threshold.
            const remaining = e.expires_block - current_block;
            if (remaining <= blocks_threshold) {
                out[n] = e;
                n += 1;
            }
        }
        return n;
    }

    /// Transfer name to new owner/address. Phase 1: updates nonce, checks cap.
    pub fn transfer(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        current_owner: []const u8,
        new_address: []const u8,
        new_owner: []const u8,
        current_block: u64,
    ) !void {
        const e = self.lookupEntry(name, tld) orelse return error.NameNotFound;
        if (!std.mem.eql(u8, e.getOwner(), current_owner)) return error.NotOwner;
        if (!std.mem.eql(u8, current_owner, new_owner)) {
            // Transfer-in cap check for the new owner (registrar exempt)
            if (!isRegistrarAddress(new_owner) and
                self.countNamesOwnedBy(new_owner, current_block) >= MAX_NAMES_PER_OWNER)
            {
                return error.OwnerCapExceeded;
            }
        }
        const alen = @min(new_address.len, 64);
        @memcpy(e.address[0..alen], new_address[0..alen]);
        e.addr_len = @intCast(alen);
        const olen = @min(new_owner.len, 64);
        @memcpy(e.owner[0..olen], new_owner[0..olen]);
        e.owner_len = @intCast(olen);
        e.last_action_block = current_block;
    }

    /// Update resolve target without changing ownership.
    pub fn updateAddress(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        owner: []const u8,
        new_address: []const u8,
        current_block: u64,
    ) !void {
        const e = self.lookupEntry(name, tld) orelse return error.NameNotFound;
        if (!std.mem.eql(u8, e.getOwner(), owner)) return error.NotOwner;
        const alen = @min(new_address.len, 64);
        @memcpy(e.address[0..alen], new_address[0..alen]);
        e.addr_len = @intCast(alen);
        e.last_action_block = current_block;
    }

    /// Phase 2: set or clear a PQ-scheme slot on an existing name.
    /// `new_address.len == 0` clears the slot (resolver falls back to primary).
    pub fn updatePqAddress(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        owner: []const u8,
        slot: PqSlot,
        new_address: []const u8,
        current_block: u64,
    ) !void {
        const e = self.lookupEntry(name, tld) orelse return error.NameNotFound;
        if (!std.mem.eql(u8, e.getOwner(), owner)) return error.NotOwner;
        try e.setPqAddress(slot, new_address);
        e.last_action_block = current_block;
    }

    /// Phase 2: change the category badge on an existing name. Owners can
    /// override the auto-derived TLD category (e.g. mark `alice.omnibus`
    /// as `bank` if they're a regulated entity using the default TLD).
    pub fn updateCategory(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        owner: []const u8,
        new_cat: Category,
        current_block: u64,
    ) !void {
        const e = self.lookupEntry(name, tld) orelse return error.NameNotFound;
        if (!std.mem.eql(u8, e.getOwner(), owner)) return error.NotOwner;
        e.category = new_cat;
        e.last_action_block = current_block;
    }

    /// Phase 2: set the owner's preferred receiving slot.
    /// `slot_idx == 0` → primary; 1..4 → matching PqSlot.
    pub fn updatePreferredSlot(
        self: *DnsRegistry,
        name: []const u8,
        tld: []const u8,
        owner: []const u8,
        slot_idx: u8,
        current_block: u64,
    ) !void {
        if (slot_idx > PQ_SLOT_COUNT) return error.InvalidSlot;
        const e = self.lookupEntry(name, tld) orelse return error.NameNotFound;
        if (!std.mem.eql(u8, e.getOwner(), owner)) return error.NotOwner;
        e.preferred_slot = slot_idx;
        e.last_action_block = current_block;
    }

    /// Phase 2: list all entries with a specific category. Useful for
    /// `getNamesByCategory` RPC — returns banks, gov agencies, etc.
    pub fn listByCategory(self: *const DnsRegistry, cat: Category, out: []*const DnsEntry, current_block: u64) usize {
        var i: usize = 0;
        for (self.entries[0..self.entry_count]) |*e| {
            if (i >= out.len) break;
            if (!e.active or e.isExpired(current_block)) continue;
            if (e.category == cat) {
                out[i] = e;
                i += 1;
            }
        }
        return i;
    }

    /// Phase 2: backfill `category` and `registered_years` on legacy entries
    /// that were saved with v1/v2 layouts (category=.none, registered_years=0).
    /// Idempotent — safe to call repeatedly. Returns count of migrated entries.
    ///
    /// Triggers:
    ///   - category == .none → derive from TLD via Category.fromTld(tld).
    ///     Owners can still override later with setcategory.
    ///   - registered_years == 0 → set to 1 (the legacy default duration).
    pub fn migrateLegacyEntries(self: *DnsRegistry) usize {
        var migrated: usize = 0;
        for (self.entries[0..self.entry_count]) |*e| {
            if (!e.active) continue;
            var changed = false;
            if (e.category == .none) {
                const c = Category.fromTld(e.getTld());
                if (c != .none) {
                    e.category = c;
                    changed = true;
                }
            }
            if (e.registered_years == 0) {
                e.registered_years = 1;
                changed = true;
            }
            if (changed) migrated += 1;
        }
        return migrated;
    }

    /// Count active (non-expired) entries
    pub fn activeCount(self: *const DnsRegistry, current_block: u64) usize {
        var count: usize = 0;
        for (self.entries[0..self.entry_count]) |e| {
            if (e.active and !e.isExpired(current_block)) count += 1;
        }
        return count;
    }

    /// Phase 2: aggregate registry health snapshot in a single pass.
    /// Powers the `ns_stats` RPC so the NS Health Dashboard avoids
    /// fan-out queries per category / TLD / years tier.
    pub fn getStats(self: *const DnsRegistry, current_block: u64) NsStats {
        var s = NsStats{
            .total_active = 0,
            .total_expired = 0,
            .counts_by_category = [_]usize{0} ** 10,
            .counts_by_tld = [_]usize{0} ** 10,
            .counts_by_years = [_]usize{0} ** 9,
            .pq_slots_set = 0,
            .preferred_slot_set = 0,
        };
        for (self.entries[0..self.entry_count]) |*e| {
            if (!e.active) continue;
            if (e.isExpired(current_block)) {
                s.total_expired += 1;
            } else {
                s.total_active += 1;
            }
            // category bucket (enum value 0..9 maps 1:1 to slot index)
            const cat_idx = @intFromEnum(e.category);
            if (cat_idx < s.counts_by_category.len) {
                s.counts_by_category[cat_idx] += 1;
            }
            // TLD bucket — match against ALLOWED_TLDS order
            const tld = e.getTld();
            for (ALLOWED_TLDS, 0..) |t, i| {
                if (std.mem.eql(u8, t, tld)) {
                    s.counts_by_tld[i] += 1;
                    break;
                }
            }
            // years bucket — match against ALLOWED_YEARS
            for (ALLOWED_YEARS, 0..) |y, i| {
                if (e.registered_years == y) {
                    s.counts_by_years[i] += 1;
                    break;
                }
            }
            if (e.hasAnyPqSlot()) s.pq_slots_set += 1;
            if (e.preferred_slot != 0) s.preferred_slot_set += 1;
        }
        return s;
    }
};

/// Aggregate registry-wide stats — see DnsRegistry.getStats.
pub const NsStats = struct {
    total_active: usize,
    total_expired: usize,
    counts_by_category: [10]usize, // indexed by Category enum (none=0 .. trading=9)
    counts_by_tld: [10]usize,      // indexed by ALLOWED_TLDS order
    counts_by_years: [9]usize,     // indexed by ALLOWED_YEARS
    pq_slots_set: usize,
    preferred_slot_set: usize,
};

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
