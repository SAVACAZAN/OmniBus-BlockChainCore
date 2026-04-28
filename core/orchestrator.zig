/// orchestrator.zig — TimeOrchestrator + AtomicClock
///
/// Single source of time for the whole node. Every component (mining
/// loop, sub-block engine, matching engine, ws_exchange_feed, arbitrage
/// scanner, stabilizer) reads from one clock, not from raw OS calls.
///
/// Why this matters:
///   1) Determinism — on baremetal we'll swap the implementation to
///      read TSC (rdtsc) for nanosecond resolution; nothing else
///      changes.
///   2) Reproducibility — tests can inject a fake clock and advance
///      it manually instead of sleeping.
///   3) Cross-component coherence — when arbitrage scanner says
///      "tick at t=12345ms" and matching engine logs "filled at
///      12347ms", the 2ms is real, not the result of two unsynchronized
///      `std.time.milliTimestamp()` calls drifting against each other.
///
/// Two layers, both lock-free on the hot path:
///   - AtomicClock: monotonic millisecond counter, swappable backend
///     (real OS time / fake test clock / future TSC reader).
///   - TimeOrchestrator: registry of named timers (slot, sub-block,
///     shard, ws-tick, stabilizer) with last-fired and next-due
///     timestamps. The mining loop calls `orchestrator.tick()` once
///     per iteration; the orchestrator returns which timers should
///     fire now and updates their next-due times.

const std = @import("std");

// ─── Hardware Cycle Counter (RDTSC) ─────────────────────────────────────────

const builtin = @import("builtin");

/// Read the CPU cycle counter directly. On x86_64 this compiles down to a
/// single `rdtscp` instruction — ~10-30 cycles latency, ~0.3ns resolution
/// on a 3GHz core. This is the "atomic clock at the bare metal" timer
/// HFT firms (Jump, Citadel) use for nanosecond-class measurements.
///
/// On non-x86_64 platforms we fall back to OS nanosecond timer.
///
/// NOTE: RDTSC drifts between cores on multi-CPU systems unless
/// invariant TSC is supported (true on every Intel/AMD chip from
/// ~2010 onwards). For our use case (single mining loop thread)
/// this is not an issue.
pub fn nowCycles() u64 {
    if (comptime builtin.cpu.arch == .x86_64) {
        // rdtscp returns:
        //   EDX:EAX = 64-bit cycle counter
        //   ECX     = processor ID (auxiliary, ignored)
        // We read EDX:EAX as a single u64 by combining the two halves.
        // RDTSCP returns EDX:EAX = 64-bit cycle counter, ECX = processor
        // ID. We don't use the proc-id (we don't pin to a core), but the
        // asm output binding still has to declare ECX so the register
        // doesn't get reused mid-instruction.
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        var aux: u32 = undefined;
        asm volatile ("rdtscp"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
              [aux] "={ecx}" (aux),
            :
            : .{}
        );
        return (@as(u64, hi) << 32) | @as(u64, lo);
    }
    // Fallback for non-x86 (ARM baremetal will need cntvct_el0 inline asm).
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

/// 64-bit cycle counter unpacked into individual bits. Each element is 0
/// or 1 — bit 63 first (most significant), bit 0 last (least significant,
/// fastest-toggling). Used for bit-level "spectrum analyzer" visualizations
/// of clock jitter: stable high bits, oscillating low bits, and visible
/// scheduler pauses as broken bit patterns.
pub fn binarySpectrum(cycles: u64) [64]u1 {
    var bits: [64]u1 = undefined;
    var c = cycles;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        bits[63 - i] = @intCast(c & 1);
        c >>= 1;
    }
    return bits;
}

/// Format binary spectrum as a fixed-width string for log output.
/// 64 chars '0'/'1', no spaces. Caller-provided buffer must be ≥ 64 bytes.
pub fn formatSpectrum(cycles: u64, out: *[64]u8) void {
    const bits = binarySpectrum(cycles);
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        out[i] = if (bits[i] == 1) '1' else '0';
    }
}

/// Calibrate TSC frequency (cycles per second) by measuring how many
/// cycles elapse over a known wall-clock interval. `sleep_ms` is the
/// calibration window — 100ms is the sweet spot: long enough to amortise
/// the rdtscp latency and any scheduler hiccup, short enough not to
/// stall startup. Returns 0 on non-x86_64 (where nowCycles falls back
/// to a nanosecond timer).
///
/// Typical results on a 3GHz core: ~3,000,000,000. On a hypervisor with
/// invariant TSC clamped to nominal frequency, this matches the
/// "sticker" speed regardless of turbo / power-saving state.
///
/// One-shot at startup is enough — we don't re-calibrate per slot
/// because invariant TSC means the rate is constant for the lifetime
/// of the process.
pub fn calibrateTscPerSec(sleep_ms: u64) u64 {
    if (comptime builtin.cpu.arch != .x86_64) return 0;
    const t1 = nowCycles();
    std.Thread.sleep(sleep_ms * std.time.ns_per_ms);
    const t2 = nowCycles();
    const delta = t2 - t1;
    // Scale to per-second: cycles_per_ms × 1000.
    return (delta * 1000) / sleep_ms;
}

// ─── AtomicClock ────────────────────────────────────────────────────────────

/// Backend for the clock. `real` reads `std.time.milliTimestamp()`;
/// `fake` reads from a manually-advanced counter (used in tests).
pub const ClockBackend = enum { real, fake };

pub const AtomicClock = struct {
    backend: ClockBackend,
    /// Only used when backend == .fake. Atomically advanced by tests
    /// via `advance(ms)`. Initial value is 0 by default.
    fake_now_ms: std.atomic.Value(i64),
    /// Snapshot of the wall-clock at start, so we can offer "uptime
    /// in ms" cheaply for the stabilizer's rolling-window math.
    started_at_wall_ms: i64,

    pub fn initReal() AtomicClock {
        return .{
            .backend = .real,
            .fake_now_ms = std.atomic.Value(i64).init(0),
            .started_at_wall_ms = std.time.milliTimestamp(),
        };
    }

    pub fn initFake(start_ms: i64) AtomicClock {
        return .{
            .backend = .fake,
            .fake_now_ms = std.atomic.Value(i64).init(start_ms),
            .started_at_wall_ms = start_ms,
        };
    }

    /// Returns "now" in milliseconds. Hot path — must be cheap.
    pub fn nowMs(self: *const AtomicClock) i64 {
        return switch (self.backend) {
            .real => std.time.milliTimestamp(),
            .fake => self.fake_now_ms.load(.acquire),
        };
    }

    /// Test-only: advance the fake clock by `ms` milliseconds. No-op
    /// when backend is .real (asserts in debug to catch misuse).
    pub fn advance(self: *AtomicClock, ms: i64) void {
        std.debug.assert(self.backend == .fake);
        _ = self.fake_now_ms.fetchAdd(ms, .release);
    }

    /// Milliseconds since the clock was created. Useful for logs and
    /// rolling-window aggregations that don't care about wall-clock.
    pub fn uptimeMs(self: *const AtomicClock) i64 {
        return self.nowMs() - self.started_at_wall_ms;
    }
};

// ─── TimerKind ──────────────────────────────────────────────────────────────

/// Named timers — these are the only event sources the orchestrator
/// schedules. Adding a new one means adding it to this enum and to
/// the corresponding handler in whichever module owns it.
pub const TimerKind = enum {
    /// Mining-loop slot tick — leader rotation, block production.
    slot,
    /// Sub-block tick — TX batching inside a slot.
    sub_block,
    /// Shard tick — per-shard sub-block dispatch (4 shards × offset).
    shard,
    /// Exchange WebSocket tick — feed snapshot, arbitrage scan.
    ws_exchange,
    /// Stabilizer tick — rate measurement + timeout adjustment.
    stabilizer,
};

pub const TIMER_COUNT: usize = @typeInfo(TimerKind).@"enum".fields.len;

// ─── Timer ──────────────────────────────────────────────────────────────────

/// Per-timer state. `interval_ms` is the target cadence. `next_due_ms`
/// is when the timer should next fire (in clock-ms). `last_fired_ms`
/// is the last actual firing (for drift detection). `enabled` lets a
/// component temporarily disable a timer without removing it.
pub const Timer = struct {
    kind: TimerKind,
    interval_ms: i64,
    next_due_ms: i64,
    last_fired_ms: i64,
    fire_count: u64,
    drift_warnings: u32,
    enabled: bool,
};

// ─── TickResult ─────────────────────────────────────────────────────────────

/// Bitmask of timers that fired during a single `tick()` call.
/// The mining loop checks `result.fired(.sub_block)` to decide whether
/// to run the sub-block engine this iteration.
pub const TickResult = struct {
    mask: u32,

    pub fn fired(self: TickResult, kind: TimerKind) bool {
        const bit: u32 = @as(u32, 1) << @intCast(@intFromEnum(kind));
        return (self.mask & bit) != 0;
    }

    pub fn anyFired(self: TickResult) bool {
        return self.mask != 0;
    }
};

// ─── TimeOrchestrator ───────────────────────────────────────────────────────

pub const TimeOrchestrator = struct {
    clock: *AtomicClock,
    timers: [TIMER_COUNT]Timer,

    /// Initialise with all 5 timers disabled — caller enables and
    /// configures the ones they need via `configure()`. Default
    /// intervals match the post-fix mining loop:
    ///   slot=1000ms, sub_block=40ms, shard=40ms, ws_exchange=1000ms,
    ///   stabilizer=60000ms.
    pub fn init(clock: *AtomicClock) TimeOrchestrator {
        const now = clock.nowMs();
        var orch: TimeOrchestrator = .{
            .clock = clock,
            .timers = undefined,
        };
        const defaults = [_]struct { kind: TimerKind, interval: i64 }{
            .{ .kind = .slot,        .interval = 1000  },
            .{ .kind = .sub_block,   .interval = 40    },
            .{ .kind = .shard,       .interval = 40    },
            .{ .kind = .ws_exchange, .interval = 1000  },
            .{ .kind = .stabilizer,  .interval = 60_000 },
        };
        for (defaults, 0..) |d, i| {
            orch.timers[i] = .{
                .kind = d.kind,
                .interval_ms = d.interval,
                .next_due_ms = now + d.interval,
                .last_fired_ms = 0,
                .fire_count = 0,
                .drift_warnings = 0,
                .enabled = false,
            };
        }
        return orch;
    }

    /// Enable a timer + set its interval. Resets next_due_ms to
    /// `now + interval` so the first firing is on cadence.
    pub fn configure(self: *TimeOrchestrator, kind: TimerKind, interval_ms: i64) void {
        const idx = @intFromEnum(kind);
        const now = self.clock.nowMs();
        self.timers[idx].interval_ms = interval_ms;
        self.timers[idx].next_due_ms = now + interval_ms;
        self.timers[idx].enabled = true;
    }

    pub fn disable(self: *TimeOrchestrator, kind: TimerKind) void {
        self.timers[@intFromEnum(kind)].enabled = false;
    }

    /// Hot path. Called once per mining-loop iteration. Returns a
    /// bitmask of which timers fired. Updates `next_due_ms` to either:
    ///   - `next_due + interval` (normal case, clean cadence)
    ///   - `now + interval` (skip-when-late case, when we're more
    ///      than 2× interval behind — prevents the loop from trying
    ///      to "catch up" by firing 50 sub-block ticks back-to-back
    ///      after a GC pause).
    pub fn tick(self: *TimeOrchestrator) TickResult {
        const now = self.clock.nowMs();
        var mask: u32 = 0;

        for (&self.timers, 0..) |*t, i| {
            if (!t.enabled) continue;
            if (now < t.next_due_ms) continue;

            // Fire.
            mask |= @as(u32, 1) << @intCast(i);
            t.last_fired_ms = now;
            t.fire_count += 1;

            // Schedule next firing. If we're more than 2× interval
            // late, don't stack catch-up firings — jump to "now +
            // interval" and log a drift warning.
            const delta = now - t.next_due_ms;
            if (delta > t.interval_ms * 2) {
                t.drift_warnings += 1;
                t.next_due_ms = now + t.interval_ms;
            } else {
                t.next_due_ms += t.interval_ms;
            }
        }

        return .{ .mask = mask };
    }

    /// Read-only snapshot of a timer's state, for stabilizer reports
    /// or operator dashboards.
    pub fn snapshot(self: *const TimeOrchestrator, kind: TimerKind) Timer {
        return self.timers[@intFromEnum(kind)];
    }

    /// How long until the next firing of `kind`, in milliseconds.
    /// Negative if the timer is overdue.
    pub fn timeUntil(self: *const TimeOrchestrator, kind: TimerKind) i64 {
        const t = self.timers[@intFromEnum(kind)];
        return t.next_due_ms - self.clock.nowMs();
    }
};

// ─── ClockScore ─────────────────────────────────────────────────────────────

/// Quality score for a 60-second span: how close is the wall-clock
/// span to the expected 60_000ms? On a baremetal box this is always
/// 100; on a shared VPS the scheduler can pause the process for
/// seconds at a time, dragging the score down.
///
/// Returns a score in [0, 100]:
///   actual ∈ [59_000, 61_000]ms       → 100 (perfect)
///   actual ∈ [55_000, 65_000]ms       → linear 80-99
///   actual ∈ [50_000, 70_000]ms       → linear 50-79
///   else                              → max(0, 50 - drift_pct)
///
/// Pure function — easy to port to Ada SPARK later for formal
/// verification of the contract bounds (we already have 300+ Ada
/// SPARK files in 1_CORE/refs/ada-spark/ that follow the same
/// pattern).
pub fn clockScore60s(start_ms: i64, end_ms: i64) u8 {
    if (end_ms <= start_ms) return 0;
    const actual_ms = end_ms - start_ms;
    const expected_ms: i64 = 60_000;
    const drift_ms: i64 = if (actual_ms > expected_ms)
        actual_ms - expected_ms
    else
        expected_ms - actual_ms;

    if (drift_ms <= 1_000) return 100;
    if (drift_ms <= 5_000) {
        // 1000-5000ms → score 80-99 (linear)
        const within = drift_ms - 1_000;       // 0..4_000
        const decrement: i64 = @divTrunc(within * 19, 4_000);
        return @intCast(99 - decrement);
    }
    if (drift_ms <= 10_000) {
        // 5000-10000ms → score 50-79 (linear)
        const within = drift_ms - 5_000;       // 0..5_000
        const decrement: i64 = @divTrunc(within * 29, 5_000);
        return @intCast(79 - decrement);
    }
    // >10s drift — score scales down to 0 at 30s drift.
    if (drift_ms >= 30_000) return 0;
    const remaining = 30_000 - drift_ms;       // 0..20_000
    return @intCast(@divTrunc(remaining * 49, 20_000));
}

test "clockScore60s: perfect 60s gets 100" {
    try testing.expectEqual(@as(u8, 100), clockScore60s(1000, 61_000));
    try testing.expectEqual(@as(u8, 100), clockScore60s(0, 60_500));
    try testing.expectEqual(@as(u8, 100), clockScore60s(0, 59_500));
}

test "clockScore60s: 1-5s drift gets 80-99" {
    const s = clockScore60s(0, 62_000); // 2s drift
    try testing.expect(s >= 80 and s <= 99);
}

test "clockScore60s: 5-10s drift gets 50-79" {
    const s = clockScore60s(0, 67_000); // 7s drift
    try testing.expect(s >= 50 and s <= 79);
}

test "clockScore60s: 30s+ drift gets 0" {
    try testing.expectEqual(@as(u8, 0), clockScore60s(0, 95_000));
    try testing.expectEqual(@as(u8, 0), clockScore60s(0, 0));
    try testing.expectEqual(@as(u8, 0), clockScore60s(100, 50));
}

test "nowCycles is monotonic and non-zero" {
    const t1 = nowCycles();
    const t2 = nowCycles();
    try testing.expect(t1 != 0);
    try testing.expect(t2 >= t1); // RDTSC always counts up
}

test "binarySpectrum unpacks bits MSB-first" {
    // 0xFF00000000000000 = bits 56..63 set, rest zero
    const bits = binarySpectrum(0xFF00000000000000);
    var i: usize = 0;
    while (i < 8) : (i += 1) try testing.expectEqual(@as(u1, 1), bits[i]);
    while (i < 64) : (i += 1) try testing.expectEqual(@as(u1, 0), bits[i]);
}

test "binarySpectrum LSB" {
    // 0x0000000000000001 = only bit 0 set → last element of array
    const bits = binarySpectrum(0x1);
    try testing.expectEqual(@as(u1, 1), bits[63]);
    var i: usize = 0;
    while (i < 63) : (i += 1) try testing.expectEqual(@as(u1, 0), bits[i]);
}

test "calibrateTscPerSec returns plausible value on x86_64" {
    if (comptime builtin.cpu.arch != .x86_64) return;
    const freq = calibrateTscPerSec(50); // 50ms calibration
    // Anywhere from 500 MHz to 10 GHz is plausible for a real CPU.
    try testing.expect(freq > 500_000_000);
    try testing.expect(freq < 10_000_000_000);
}

test "formatSpectrum produces 64-char binary string" {
    var buf: [64]u8 = undefined;
    formatSpectrum(0xAA00000000000055, &buf);
    // 0xAA = 10101010, 0x55 = 01010101
    try testing.expectEqualStrings(
        "1010101000000000000000000000000000000000000000000000000001010101",
        &buf,
    );
}

test "clockScore60s: monotonic in drift" {
    // More drift should never give a higher score.
    var prev_score: u8 = 100;
    var span: i64 = 60_000;
    while (span <= 90_000) : (span += 1000) {
        const s = clockScore60s(0, span);
        try testing.expect(s <= prev_score);
        prev_score = s;
    }
}

// ─── SlotCalendar ───────────────────────────────────────────────────────────

/// Status of a future slot's pre-computed entry.
pub const SlotState = enum(u8) {
    /// Slot is in the future, leader assigned but no block yet.
    future = 0,
    /// Slot's expected_arrival has passed, waiting for block to land.
    in_flight = 1,
    /// Block has been observed for this slot.
    finalized = 2,
    /// Slot's expected_arrival has passed by > 2× slot interval — leader
    /// missed it and someone else (or no-one) took over.
    missed = 3,
};

/// One pre-computed future slot. The leader address is held as a fixed
/// 64-byte buffer so the entry is allocator-free (slot calendar is
/// hot-path; no malloc per entry).
pub const SlotEntry = struct {
    slot_id: u64,
    /// 0 = no leader assigned (validator set was empty when computed).
    leader_addr_len: u8,
    leader_addr: [64]u8,
    /// Wall-clock ms when this slot is *expected* to land (clock.nowMs()
    /// at the time of computation + N × slot_interval_ms).
    expected_arrival_ms: i64,
    /// Hash of the most-recent finalized block at calendar-build time.
    /// Used to detect calendar staleness — if tip hash changed, the
    /// leader assignments are no longer valid (leaderForSlot mixes the
    /// prev_hash into its seed).
    base_tip_hash_first8: [8]u8,
    state: SlotState,

    pub fn leaderSlice(self: *const SlotEntry) []const u8 {
        return self.leader_addr[0..self.leader_addr_len];
    }
};

/// Read-only ring buffer of the next N slots. Filled by `rebuild()`,
/// consumed by frontends + RPC + future-block-pool routing logic.
///
/// Capacity 60 = 60 slots × 1s = 1 minute look-ahead. Bigger than that
/// is risky — reorg + governance changes invalidate the calendar, and
/// a 1-minute window is enough for trading-flow scheduling without
/// being wasteful.
pub const SLOT_CALENDAR_CAP: usize = 60;

pub const SlotCalendar = struct {
    entries: [SLOT_CALENDAR_CAP]SlotEntry,
    /// Number of currently-valid entries (0..CAP). Bumps to CAP after
    /// the first rebuild and stays there.
    count: usize,
    /// Slot interval used when this calendar was built. If the chain's
    /// configured slot interval changes, we throw the calendar away.
    slot_interval_ms: i64,
    /// Tip hash hex (64 chars) at last rebuild — first 8 bytes only
    /// stored for cheap staleness compare. If the live tip's first 8
    /// bytes differ from this, the calendar is stale.
    last_built_tip_first8: [8]u8,
    /// Slot id of the first entry — useful for "next leader is …" queries.
    head_slot_id: u64,

    pub fn empty() SlotCalendar {
        return .{
            .entries = undefined,
            .count = 0,
            .slot_interval_ms = 1000,
            .last_built_tip_first8 = std.mem.zeroes([8]u8),
            .head_slot_id = 0,
        };
    }

    /// Rebuild the calendar from a snapshot of the validator set + tip.
    /// Pure deterministic given inputs — same args produce same output
    /// on every node. Caller passes a `leaderFn` to avoid coupling
    /// orchestrator.zig to validator_registry.zig.
    pub fn rebuild(
        self: *SlotCalendar,
        comptime ValidatorT: type,
        validators: []const ValidatorT,
        tip_slot_id: u64,
        tip_hash_hex: []const u8,
        now_ms: i64,
        slot_interval_ms: i64,
        leaderFn: fn (slot_id: u64, prev_hash: []const u8, vs: []const ValidatorT) ?ValidatorT,
    ) void {
        self.slot_interval_ms = slot_interval_ms;
        self.head_slot_id = tip_slot_id + 1;
        if (tip_hash_hex.len >= 8) {
            @memcpy(&self.last_built_tip_first8, tip_hash_hex[0..8]);
        } else {
            self.last_built_tip_first8 = std.mem.zeroes([8]u8);
        }

        var i: usize = 0;
        while (i < SLOT_CALENDAR_CAP) : (i += 1) {
            const future_slot_id = tip_slot_id + 1 + i;
            const arrival_ms = now_ms + @as(i64, @intCast(i + 1)) * slot_interval_ms;

            var entry: SlotEntry = .{
                .slot_id = future_slot_id,
                .leader_addr_len = 0,
                .leader_addr = std.mem.zeroes([64]u8),
                .expected_arrival_ms = arrival_ms,
                .base_tip_hash_first8 = self.last_built_tip_first8,
                .state = .future,
            };

            const maybe_leader = leaderFn(future_slot_id, tip_hash_hex, validators);
            if (maybe_leader) |l| {
                const addr = l.address;
                const copy_len = @min(addr.len, 64);
                @memcpy(entry.leader_addr[0..copy_len], addr[0..copy_len]);
                entry.leader_addr_len = @intCast(copy_len);
            }
            self.entries[i] = entry;
        }
        self.count = SLOT_CALENDAR_CAP;
    }

    /// Walk the calendar and update entry states based on `now_ms` and
    /// `current_chain_height`. Cheap O(N) sweep — call from the mining
    /// loop after each block.
    pub fn refreshStates(
        self: *SlotCalendar,
        now_ms: i64,
        current_chain_height: u64,
    ) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            var e = &self.entries[i];
            const slot_id = e.slot_id;
            if (current_chain_height >= slot_id) {
                e.state = .finalized;
                continue;
            }
            const overdue_ms = now_ms - e.expected_arrival_ms;
            if (overdue_ms >= self.slot_interval_ms * 2) {
                e.state = .missed;
            } else if (overdue_ms >= 0) {
                e.state = .in_flight;
            } else {
                e.state = .future;
            }
        }
    }

    /// Returns the next entry whose state is .future, or null if none.
    pub fn nextFutureSlot(self: *const SlotCalendar) ?*const SlotEntry {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.entries[i].state == .future) return &self.entries[i];
        }
        return null;
    }

    /// True if the live tip's first 8 hex chars no longer match what
    /// we built against — calendar stale, schedule a rebuild.
    pub fn isStale(self: *const SlotCalendar, live_tip_hex: []const u8) bool {
        if (live_tip_hex.len < 8) return true;
        return !std.mem.eql(u8, &self.last_built_tip_first8, live_tip_hex[0..8]);
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

const FakeValidator = struct {
    address: []const u8,
    weight: u32 = 1,
};

fn fakeLeaderRoundRobin(
    slot_id: u64,
    prev_hash: []const u8,
    vs: []const FakeValidator,
) ?FakeValidator {
    _ = prev_hash;
    if (vs.len == 0) return null;
    return vs[@intCast(slot_id % vs.len)];
}

test "SlotCalendar empty starts at count 0" {
    var cal = SlotCalendar.empty();
    try testing.expectEqual(@as(usize, 0), cal.count);
    try testing.expectEqual(@as(?*const SlotEntry, null), cal.nextFutureSlot());
}

test "SlotCalendar rebuild fills 60 entries with correct slot ids and arrivals" {
    var cal = SlotCalendar.empty();
    const vs = [_]FakeValidator{
        .{ .address = "alice" },
        .{ .address = "bob" },
    };
    const tip_hash = "deadbeefcafebabe1234567890abcdef" ++
                     "deadbeefcafebabe1234567890abcdef";
    cal.rebuild(FakeValidator, &vs, 100, tip_hash, 5_000_000, 1000,
                fakeLeaderRoundRobin);

    try testing.expectEqual(@as(usize, 60), cal.count);
    try testing.expectEqual(@as(u64, 101), cal.entries[0].slot_id);
    try testing.expectEqual(@as(u64, 160), cal.entries[59].slot_id);
    try testing.expectEqual(@as(i64, 5_001_000), cal.entries[0].expected_arrival_ms);
    try testing.expectEqual(@as(i64, 5_060_000), cal.entries[59].expected_arrival_ms);
    // Round-robin: slot 101 → bob (101%2=1), slot 102 → alice (102%2=0).
    try testing.expectEqualStrings("bob", cal.entries[0].leaderSlice());
    try testing.expectEqualStrings("alice", cal.entries[1].leaderSlice());
}

test "SlotCalendar rebuild handles empty validator set (no leader assigned)" {
    var cal = SlotCalendar.empty();
    const vs = [_]FakeValidator{};
    const tip_hash = "deadbeefcafebabe" ** 4;
    cal.rebuild(FakeValidator, &vs, 0, tip_hash, 0, 1000, fakeLeaderRoundRobin);
    try testing.expectEqual(@as(usize, 60), cal.count);
    try testing.expectEqual(@as(u8, 0), cal.entries[0].leader_addr_len);
}

test "SlotCalendar refreshStates marks finalized + missed + in_flight" {
    var cal = SlotCalendar.empty();
    const vs = [_]FakeValidator{ .{ .address = "x" } };
    const tip_hash = "0011223344556677" ** 4;
    cal.rebuild(FakeValidator, &vs, 100, tip_hash, 1_000_000, 1000,
                fakeLeaderRoundRobin);

    // Chain advanced to height 105 (5 blocks) and 7.5s have passed.
    // Slot ids: entries[0]=101 ... entries[4]=105, entries[5]=106, ...
    // Expected arrivals: entries[i] at 1_000_000 + (i+1)*1000.
    //   entries[5] expected at 1_006_000 — at now=1_007_500 overdue 1.5s → in_flight
    //   entries[6] expected at 1_007_000 — overdue 0.5s → in_flight
    //   entries[7] expected at 1_008_000 — not yet → future
    cal.refreshStates(1_007_500, 105);

    // First 5 entries finalized (chain_height >= slot_id).
    var i: usize = 0;
    while (i < 5) : (i += 1)
        try testing.expectEqual(SlotState.finalized, cal.entries[i].state);

    try testing.expectEqual(SlotState.in_flight, cal.entries[5].state);
    try testing.expectEqual(SlotState.in_flight, cal.entries[6].state);
    try testing.expectEqual(SlotState.future, cal.entries[7].state);

    // Entry 8+ still in the future.
    try testing.expectEqual(SlotState.future, cal.entries[8].state);

    // Now advance further to test missed: 4s past arrival of entry[5].
    cal.refreshStates(1_010_000, 105);
    try testing.expectEqual(SlotState.missed, cal.entries[5].state);
}

test "SlotCalendar isStale detects tip change" {
    var cal = SlotCalendar.empty();
    const vs = [_]FakeValidator{ .{ .address = "x" } };
    const tip = "11223344" ++ "55667788" ** 7;
    cal.rebuild(FakeValidator, &vs, 1, tip, 0, 1000, fakeLeaderRoundRobin);
    try testing.expect(!cal.isStale(tip));
    const new_tip = "99aabbcc" ++ "55667788" ** 7;
    try testing.expect(cal.isStale(new_tip));
}

test "AtomicClock fake backend advances on demand" {
    var clk = AtomicClock.initFake(1000);
    try testing.expectEqual(@as(i64, 1000), clk.nowMs());
    clk.advance(250);
    try testing.expectEqual(@as(i64, 1250), clk.nowMs());
    clk.advance(7_500);
    try testing.expectEqual(@as(i64, 8_750), clk.nowMs());
}

test "AtomicClock real backend returns sane wall-clock time" {
    var clk = AtomicClock.initReal();
    const t1 = clk.nowMs();
    std.Thread.sleep(2 * std.time.ns_per_ms);
    const t2 = clk.nowMs();
    try testing.expect(t2 >= t1);
    try testing.expect(t2 - t1 < 1_000); // less than 1s for a 2ms sleep
}

test "TimeOrchestrator: default-disabled timers don't fire" {
    var clk = AtomicClock.initFake(0);
    var orch = TimeOrchestrator.init(&clk);
    clk.advance(10_000); // 10s
    const r = orch.tick();
    try testing.expectEqual(@as(u32, 0), r.mask);
}

test "TimeOrchestrator: configured timer fires on cadence" {
    var clk = AtomicClock.initFake(0);
    var orch = TimeOrchestrator.init(&clk);
    orch.configure(.sub_block, 40);

    // Not yet due.
    clk.advance(20);
    try testing.expect(!orch.tick().fired(.sub_block));

    // Now due.
    clk.advance(25);
    try testing.expect(orch.tick().fired(.sub_block));

    // Already fired this slot — not due again until the next 40ms.
    clk.advance(10);
    try testing.expect(!orch.tick().fired(.sub_block));

    // Next firing.
    clk.advance(35);
    try testing.expect(orch.tick().fired(.sub_block));
}

test "TimeOrchestrator: skip-when-late prevents catch-up storm" {
    var clk = AtomicClock.initFake(0);
    var orch = TimeOrchestrator.init(&clk);
    orch.configure(.sub_block, 40);

    // Simulate a 500ms GC pause / scheduler starvation. Naive
    // implementation would fire 12 catch-up ticks in a single
    // tick() call. We expect just one firing + a drift warning.
    clk.advance(500);
    const r = orch.tick();
    try testing.expect(r.fired(.sub_block));

    const snap = orch.snapshot(.sub_block);
    try testing.expectEqual(@as(u64, 1), snap.fire_count);
    try testing.expectEqual(@as(u32, 1), snap.drift_warnings);

    // Next due should be ~now + interval, not far in the past.
    const until = orch.timeUntil(.sub_block);
    try testing.expect(until > 0 and until <= 40);
}

test "TimeOrchestrator: multiple timers fire independently" {
    var clk = AtomicClock.initFake(0);
    var orch = TimeOrchestrator.init(&clk);
    orch.configure(.slot, 1000);
    orch.configure(.sub_block, 40);
    orch.configure(.stabilizer, 60_000);

    // Advance 100ms — only sub_block should fire (it's at 40ms cadence).
    clk.advance(100);
    const r1 = orch.tick();
    try testing.expect(r1.fired(.sub_block));
    try testing.expect(!r1.fired(.slot));
    try testing.expect(!r1.fired(.stabilizer));

    // Advance to 1100ms — slot should fire too (1000ms cadence).
    clk.advance(1000);
    const r2 = orch.tick();
    try testing.expect(r2.fired(.slot));
    try testing.expect(r2.fired(.sub_block));
    try testing.expect(!r2.fired(.stabilizer));
}

test "TimeOrchestrator: disable stops a timer cleanly" {
    var clk = AtomicClock.initFake(0);
    var orch = TimeOrchestrator.init(&clk);
    orch.configure(.sub_block, 40);

    clk.advance(50);
    try testing.expect(orch.tick().fired(.sub_block));

    orch.disable(.sub_block);
    clk.advance(1000);
    try testing.expect(!orch.tick().fired(.sub_block));
}
