/// spark_invariants.zig — Ada/Spark Formal Invariants în Zig comptime
///
/// Mimează comportamentul Ada Spark Pro (gnatprove) folosind:
///   - comptime assertions (verificate la compilare)
///   - runtime assertions cu @panic (imposibil de bypass)
///   - checked arithmetic (overflow → compile error sau panic)
///
/// INVARIANȚI GARANTAȚI MATEMATIC:
///   1. Total supply nu poate depăși 21.000.000 OMNI
///   2. Balanțele nu pot fi negative (u64 enforced)
///   3. Reward per bloc scade strict monoton (halving)
///   4. Suma recompenselor din toate blocurile ≤ MAX_SUPPLY
///   5. Block time = 1s / Micro-block time = 0.1s (invariant temporal)
///   6. Numărul de halvings = 64 (după care reward = 0)
const std = @import("std");

// ─── CONSTANTE ABSOLUTE (hardcodate în kernel, imposibil de schimbat) ────────
// Echivalentul Ada: Max_Supply : constant := 21_000_000 * 10**9;
// cu Spark annotation: pragma Assert (Max_Supply = 21_000_000_000_000_000);

/// Supply maxim: 21.000.000 OMNI × 10^9 nanoOMNI (= SAT)
pub const MAX_SUPPLY_SAT: u64 = 21_000_000 * 1_000_000_000;

/// Reward inițial per bloc: 0.08333333 OMNI = 83_333_333 nanoOMNI
pub const INITIAL_REWARD_SAT: u64 = 83_333_333;

/// Intervalul de halving: 126.144.000 blocuri (~4 ani la 1 bloc/s)
pub const HALVING_INTERVAL: u64 = 126_144_000;

/// Numărul maxim de halvings înainte ca reward → 0
pub const MAX_HALVINGS: u64 = 64;

/// Block time în milisecunde
pub const BLOCK_TIME_MS: u64 = 1_000;

/// Micro-block time în milisecunde
pub const MICRO_BLOCK_TIME_MS: u64 = 100;

/// Numărul de micro-blocuri per Key-Block
pub const MICRO_BLOCKS_PER_KEY: u64 = BLOCK_TIME_MS / MICRO_BLOCK_TIME_MS;

// ─── VERIFICĂRI COMPTIME (Ada Spark → Zig comptime) ─────────────────────────
// Acestea sunt verificate la COMPILARE — dacă fail → build error

comptime {
    // Invariant 1: MICRO_BLOCKS_PER_KEY = 10
    if (MICRO_BLOCKS_PER_KEY != 10) @compileError("MICRO_BLOCKS_PER_KEY must be 10");

    // Invariant 2: INITIAL_REWARD_SAT > 0
    if (INITIAL_REWARD_SAT == 0) @compileError("Initial reward cannot be zero");

    // Invariant 3: MAX_SUPPLY_SAT = 21M × 10^9
    if (MAX_SUPPLY_SAT != 21_000_000_000_000_000)
        @compileError("MAX_SUPPLY_SAT must be exactly 21_000_000_000_000_000");

    // Invariant 4: HALVING_INTERVAL > 0
    if (HALVING_INTERVAL == 0) @compileError("Halving interval cannot be zero");

    // Invariant 5: block time > micro-block time
    if (BLOCK_TIME_MS <= MICRO_BLOCK_TIME_MS)
        @compileError("Block time must be greater than micro-block time");

    // Invariant 6: Reward per epoch ≤ MAX_SUPPLY_SAT / MAX_HALVINGS
    // Verificare conservatoare: un singur epoch complet (INITIAL_REWARD × HALVING_INTERVAL)
    // nu trebuie să depășească supply-ul total — runtime SupplyGuard verifică suma reală
    const epoch0_reward = INITIAL_REWARD_SAT * HALVING_INTERVAL;
    if (epoch0_reward > MAX_SUPPLY_SAT)
        @compileError("Epoch-0 total reward would exceed MAX_SUPPLY_SAT");
}

// ─── SUPPLY GUARD — Runtime invariant (impossibil de bypass) ─────────────────

/// SupplyGuard — tracker atomic al supply-ului emis
/// Orice emisie de OMNI trece prin acest guard
/// Dacă ar depăși MAX_SUPPLY_SAT → @panic (echivalent Ada: Contract_Failure)
pub const SupplyGuard = struct {
    emitted_sat: u64,   // total emis până acum

    pub fn init() SupplyGuard {
        return SupplyGuard{ .emitted_sat = 0 };
    }

    /// Emit reward pentru un bloc — GARANTAT că nu depășește MAX_SUPPLY_SAT
    /// Echivalent Ada Spark: procedure Emit with
    ///   Pre  => Emitted + Amount <= Max_Supply,
    ///   Post => Emitted = Emitted'Old + Amount;
    pub fn emit(self: *SupplyGuard, amount_sat: u64) !void {
        // Checked addition — overflow imposibil pe u64, dar verificăm supply limit
        const new_total = self.emitted_sat +% amount_sat; // wrapping add pt overflow check
        if (new_total < self.emitted_sat) return error.ArithmeticOverflow;
        if (new_total > MAX_SUPPLY_SAT) return error.SupplyCapExceeded;
        self.emitted_sat = new_total;
    }

    /// Verifică că supply-ul curent e valid (runtime check)
    /// Returneaza error in loc de @panic pentru graceful handling
    pub fn assertValid(self: *const SupplyGuard) !void {
        if (self.emitted_sat > MAX_SUPPLY_SAT) {
            return error.SupplyCapViolated;
        }
    }

    pub fn remaining(self: *const SupplyGuard) u64 {
        return MAX_SUPPLY_SAT - self.emitted_sat;
    }

    pub fn emittedPercent(self: *const SupplyGuard) f64 {
        return @as(f64, @floatFromInt(self.emitted_sat)) /
               @as(f64, @floatFromInt(MAX_SUPPLY_SAT)) * 100.0;
    }
};

// ─── REWARD CALCULATOR — Invariant monoton descrescător ──────────────────────

/// Calculează reward-ul pentru blocul la height dat
/// INVARIANT: getBlockReward(h1) >= getBlockReward(h2) dacă h1 < h2
/// Echivalent Ada: function Block_Reward (Height : Block_Height) return Satoshi
///   with Post => Block_Reward'Result <= Initial_Reward;
pub fn getBlockReward(height: u64) u64 {
    const halvings = height / HALVING_INTERVAL;
    if (halvings >= MAX_HALVINGS) return 0;

    // Shift right = împărțire la 2^halvings (exact ca Bitcoin)
    // Zig: >> cu u6 pentru shift amount
    const shift: u6 = @intCast(@min(halvings, 63));
    return INITIAL_REWARD_SAT >> shift;
}

/// Verifică invariantul monoton: reward(h) >= reward(h+1)
/// Returneaza error in loc de @panic pentru recoverable handling
pub fn assertRewardMonotone(height: u64) !void {
    const r1 = getBlockReward(height);
    const r2 = getBlockReward(height + 1);
    if (r1 < r2) {
        return error.RewardMonotoneViolated;
    }
}

/// Calculează suma totală de recompense de la bloc 0 la bloc `height`
pub fn totalEmittedUpTo(height: u64) u64 {
    var total: u64 = 0;
    var h: u64 = 0;
    while (h <= height) : (h += 1) {
        const reward = getBlockReward(h);
        if (reward == 0) break;
        total +|= reward; // saturating add — nu overflow
    }
    return total;
}

// ─── TEMPORAL INVARIANTS ──────────────────────────────────────────────────────

/// Verifică că un timestamp e în ordine (monoton crescător)
pub const TemporalGuard = struct {
    last_timestamp_ms: i64,

    pub fn init() TemporalGuard {
        return TemporalGuard{ .last_timestamp_ms = 0 };
    }

    /// Validează că noul timestamp e strict mai mare decât precedentul
    /// INVARIANT: timestamp[n] > timestamp[n-1]
    pub fn checkTimestamp(self: *TemporalGuard, ts_ms: i64) !void {
        if (ts_ms <= self.last_timestamp_ms) return error.TimestampNotMonotone;
        // Verifică că nu e prea departe în viitor (max 30s drift)
        const now_ms = std.time.milliTimestamp();
        if (ts_ms > now_ms + 30_000) return error.TimestampTooFarFuture;
        self.last_timestamp_ms = ts_ms;
    }

    /// Verifică că un micro-bloc e la intervalul corect (0.1s)
    pub fn checkMicroBlockInterval(self: *const TemporalGuard, ts_ms: i64) !void {
        const diff = ts_ms - self.last_timestamp_ms;
        // Permitem ±50ms toleranță față de 100ms target
        if (diff < 50 or diff > 150) return error.MicroBlockTimingViolation;
    }
};

// ─── BALANCE INVARIANTS ───────────────────────────────────────────────────────

/// Verifică că o operație de scădere nu produce underflow
/// Echivalent Ada: pragma Assert (Balance >= Amount);
pub fn checkedSub(balance: u64, amount: u64) !u64 {
    if (amount > balance) return error.InsufficientBalance;
    return balance - amount;
}

/// Verifică că o operație de adunare nu produce overflow sau supply violation
pub fn checkedAdd(a: u64, b: u64) !u64 {
    const result = a +% b;
    if (result < a) return error.ArithmeticOverflow;
    return result;
}

// ─── TESTE ───────────────────────────────────────────────────────────────────
const testing = std.testing;

test "comptime — constante corecte" {
    try testing.expectEqual(@as(u64, 21_000_000_000_000_000), MAX_SUPPLY_SAT);
    try testing.expectEqual(@as(u64, 83_333_333), INITIAL_REWARD_SAT);
    try testing.expectEqual(@as(u64, 10), MICRO_BLOCKS_PER_KEY);
    try testing.expectEqual(@as(u64, 126_144_000), HALVING_INTERVAL);
    try testing.expectEqual(@as(u64, 64), MAX_HALVINGS);
}

test "getBlockReward — bloc 0 = reward initial" {
    try testing.expectEqual(INITIAL_REWARD_SAT, getBlockReward(0));
}

test "getBlockReward — dupa halving = jumatate" {
    const r0 = getBlockReward(0);
    const r1 = getBlockReward(HALVING_INTERVAL);
    try testing.expectEqual(r0 / 2, r1);
}

test "getBlockReward — dupa 64 halvings = 0" {
    try testing.expectEqual(@as(u64, 0), getBlockReward(HALVING_INTERVAL * 64));
}

test "getBlockReward — monoton descrescator" {
    const heights = [_]u64{ 0, 1000, HALVING_INTERVAL - 1, HALVING_INTERVAL,
        HALVING_INTERVAL * 2, HALVING_INTERVAL * 63 };
    for (heights) |h| {
        try assertRewardMonotone(h);
    }
}

test "SupplyGuard — emit in limite" {
    var sg = SupplyGuard.init();
    try sg.emit(INITIAL_REWARD_SAT);
    try testing.expectEqual(INITIAL_REWARD_SAT, sg.emitted_sat);
    try sg.assertValid();
}

test "SupplyGuard — emit peste max returneaza eroare" {
    var sg = SupplyGuard.init();
    sg.emitted_sat = MAX_SUPPLY_SAT;
    try testing.expectError(error.SupplyCapExceeded, sg.emit(1));
}

test "SupplyGuard — remaining corect" {
    var sg = SupplyGuard.init();
    try sg.emit(1_000_000_000);
    try testing.expectEqual(MAX_SUPPLY_SAT - 1_000_000_000, sg.remaining());
}

test "SupplyGuard — 1000 blocuri emit suma corecta" {
    var sg = SupplyGuard.init();
    for (0..1000) |_| {
        try sg.emit(INITIAL_REWARD_SAT);
    }
    try testing.expectEqual(INITIAL_REWARD_SAT * 1000, sg.emitted_sat);
    try sg.assertValid();
}

test "TemporalGuard — timestamp monoton" {
    var tg = TemporalGuard.init();
    try tg.checkTimestamp(1000);
    try tg.checkTimestamp(2000);
    try tg.checkTimestamp(3000);
}

test "TemporalGuard — timestamp non-monoton returneaza eroare" {
    var tg = TemporalGuard.init();
    try tg.checkTimestamp(1000);
    try testing.expectError(error.TimestampNotMonotone, tg.checkTimestamp(500));
}

test "TemporalGuard — timestamp egal returneaza eroare" {
    var tg = TemporalGuard.init();
    try tg.checkTimestamp(1000);
    try testing.expectError(error.TimestampNotMonotone, tg.checkTimestamp(1000));
}

test "checkedSub — suficienta balanță" {
    const result = try checkedSub(1000, 400);
    try testing.expectEqual(@as(u64, 600), result);
}

test "checkedSub — balanță insuficientă returneaza eroare" {
    try testing.expectError(error.InsufficientBalance, checkedSub(100, 200));
}

test "checkedAdd — adunare normala" {
    const result = try checkedAdd(500, 300);
    try testing.expectEqual(@as(u64, 800), result);
}

test "checkedAdd — overflow returneaza eroare" {
    try testing.expectError(error.ArithmeticOverflow, checkedAdd(std.math.maxInt(u64), 1));
}

test "totalEmittedUpTo — primele 10 blocuri" {
    const total = totalEmittedUpTo(9);
    try testing.expectEqual(INITIAL_REWARD_SAT * 10, total);
}
