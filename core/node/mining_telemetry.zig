// core/node/mining_telemetry.zig
//
// STABILIZER reporting + CHAINSTATE audit, extracted verbatim from
// the mining loop in core/main.zig. Same print lines, same cadence.
//
// The mining loop in main.zig holds the stabilizer state as a handful
// of local mutables (rate_ring*, stabilizer_last_report_ms,
// stabilizer_timeout_mult). We take pointers so the helpers can mutate
// in place — that keeps the call site a single line and preserves the
// original semantics exactly.

const std = @import("std");
const orchestrator_mod = @import("../orchestrator.zig");

/// Stabilizer reporting + slot-calendar refresh + balance/stray audits.
/// Call once per mined block. Internally checks the 60s cadence
/// (orch.tick fired OR manual fallback) and only prints/updates state
/// when due. Also invokes the chainstate audit on the same cadence.
pub fn maybeReportStabilizer(
    comptime RATE_RING_SIZE: usize,
    comptime TARGET_BLOCKS_PER_MIN: f64,
    rate_ring: *[RATE_RING_SIZE]i64,
    rate_ring_head: *usize,
    rate_ring_count: *usize,
    stabilizer_last_report_ms: *i64,
    stabilizer_timeout_mult: *f64,
    arrival_ms: i64,
    orch_fired: bool,
    bc: anytype,
    chainstate_opt: anytype, // *?ChainState
    slot_calendar: anytype,  // *SlotCalendar
    block_count: u64,
) void {
    rate_ring[rate_ring_head.*] = arrival_ms;
    rate_ring_head.* = (rate_ring_head.* + 1) % RATE_RING_SIZE;
    if (rate_ring_count.* < RATE_RING_SIZE) rate_ring_count.* += 1;

    const manual_due = (arrival_ms - stabilizer_last_report_ms.*) >= 60_000;
    if (!(orch_fired or manual_due)) return;

    // Count blocks within the last 60s and last 60min windows.
    var blocks_1m: u32 = 0;
    var blocks_60m: u32 = 0;
    const cutoff_1m = arrival_ms - 60_000;
    const cutoff_60m = arrival_ms - 60 * 60_000;
    var i: usize = 0;
    while (i < rate_ring_count.*) : (i += 1) {
        const ts = rate_ring[i];
        if (ts >= cutoff_60m) blocks_60m += 1;
        if (ts >= cutoff_1m)  blocks_1m  += 1;
    }
    const ratio = @as(f64, @floatFromInt(blocks_1m)) /
                  TARGET_BLOCKS_PER_MIN;
    // Direct adjust: low rate (ratio < 1) → shrink timeout
    // (faster failover, more aggressive); high rate (ratio > 1)
    // → relax timeout (less CPU pressure). Multiplier *is* the
    // ratio, clamped to [0.2, 2.0]: at ratio=0.6 we set
    // timeout to 60% of base (300ms × 0.6 = 180ms).
    var new_mult = ratio;
    if (new_mult < 0.2) new_mult = 0.2;
    if (new_mult > 2.0) new_mult = 2.0;
    stabilizer_timeout_mult.* = new_mult;

    // Clock health score: how close was the actual wall-
    // clock 60s span to the expected 60_000ms? On a
    // shared VPS the scheduler can pause us for seconds —
    // that drags the score down and tells the operator
    // the timing layer is unreliable. On baremetal we
    // expect 100 always.
    const score = orchestrator_mod.clockScore60s(
        stabilizer_last_report_ms.*, arrival_ms,
    );

    // Hardware cycle counter snapshot — direct rdtscp.
    // The 64-bit spectrum line lets the operator visually
    // see CPU clock progression. On a stable system the
    // high 16 bits stay constant minute-to-minute; the
    // low bits oscillate every cycle. Anomalies (suspended
    // process, frequency scaling, hypervisor migration)
    // show up as broken bit patterns.
    const cycles = orchestrator_mod.nowCycles();
    var spec_buf: [64]u8 = undefined;
    orchestrator_mod.formatSpectrum(cycles, &spec_buf);

    std.debug.print(
        "[STABILIZER] last 60s = {d} blocks ({d:.1}/min) | " ++
        "last 60min = {d} blocks | target = {d:.0}/min | " ++
        "ratio = {d:.2} | timeout_mult = {d:.2} | " ++
        "clock_score = {d}/100 | rdtsc = {d}\n" ++
        "[CLOCK-BITS] {s}\n",
        .{
            blocks_1m, @as(f64, @floatFromInt(blocks_1m)),
            blocks_60m, TARGET_BLOCKS_PER_MIN,
            ratio, stabilizer_timeout_mult.*, score, cycles,
            spec_buf,
        },
    );

    // Slot-calendar status snapshot — refresh entry states
    // and log the next future leader so the operator can
    // see who'll mine the upcoming slot before it lands.
    slot_calendar.refreshStates(arrival_ms, block_count);
    if (slot_calendar.nextFutureSlot()) |next| {
        const leader = next.leaderSlice();
        const leader_short = leader[0..@min(12, leader.len)];
        const ms_until = next.expected_arrival_ms - arrival_ms;
        std.debug.print(
            "[CALENDAR] next slot {d} in {d}ms | leader = {s}\n",
            .{ next.slot_id, ms_until, leader_short },
        );
    }
    // ── PHASE-B: audit balance consistency ─────────────────────
    const audit = bc.auditBalanceConsistency();
    if (audit.divergences > 0) {
        std.debug.print(
            "[ALERT] Balance divergence detected: {d}/{d} addresses diverged from UTXO set\n",
            .{ audit.divergences, audit.addresses_checked },
        );
    }
    // ── PHASE-C.3: stray-write detector ────────────────────────
    // Every legitimate balance mutation comes through
    // applyBlock / mineBlockForMiner / recalculateFromHeight
    // / p2p sync — all of those set bc.in_apply_block=true
    // for the duration of the work. Anything outside that
    // window is a phantom write that won't survive replay.
    // Counter is process-lifetime; non-zero means we have
    // a regression to find before C.4 deletes bc.balances
    // entirely.
    if (bc.stray_balance_writes > 0) {
        std.debug.print(
            "[ALERT] Stray balance writes since startup: {d} — phantom credits/debits, find the callsite\n",
            .{bc.stray_balance_writes},
        );
    }
    // ── PHASE-C.4: chainstate audit + sync ────────────────────
    maybeAuditChainstate(bc, chainstate_opt);

    stabilizer_last_report_ms.* = arrival_ms;
}

/// RAM balance map vs chainstate KV audit + sync + checkpoint.
/// Runs on the stabilizer cadence (every ~60s) — the WAL fsync per
/// record would dominate latency at per-block frequency.
pub fn maybeAuditChainstate(bc: anytype, chainstate_opt: anytype) void {
    if (chainstate_opt.*) |*cs| {
        // Sync RAM → chainstate. We do this once a minute,
        // not per block — the WAL fsync per record would
        // dominate latency at 60 blocks/min. A future
        // applyBlock-time hook will narrow the window
        // when we're ready to make chainstate primary.
        var sync_count: usize = 0;
        var sync_diff: usize = 0;
        var bit2 = bc.balances.iterator();
        while (bit2.next()) |kv| {
            const ram_bal = kv.value_ptr.*;
            const cs_bal = cs.getBalance(kv.key_ptr.*);
            if (ram_bal != cs_bal) {
                cs.putBalance(kv.key_ptr.*, ram_bal) catch {};
                sync_diff += 1;
            }
            sync_count += 1;
        }
        const cs_addrs = cs.balanceCount();
        const cs_supply = cs.totalSupply();
        std.debug.print(
            "[CHAINSTATE] audit: ram_addrs={d} cs_addrs={d} cs_supply={d} sat | synced={d} diff this tick\n",
            .{ sync_count, cs_addrs, cs_supply, sync_diff },
        );
        // Persist the chainstate snapshot. Cheap (data is
        // small for now) and keeps WAL bounded.
        cs.checkpoint() catch |err| {
            std.debug.print("[CHAINSTATE] checkpoint failed: {}\n", .{err});
        };
    }
}
