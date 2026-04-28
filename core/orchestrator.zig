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

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

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
