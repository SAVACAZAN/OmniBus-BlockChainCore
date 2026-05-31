// core/node/slot_leader.zig
//
// Slot-leader gate extracted from main.zig mining loop (2026-06-01).
// Pure refactor — same gating logic, same print lines, same behavior.
//
// Decides whether the current node should mine the next slot:
//   1. Normal: only the slot's deterministic leader produces.
//   2. Liveness: if the slot leader hasn't produced in SLOT_TIMEOUT_MS,
//      the lex-min active validator takes the slot (Tendermint-style
//      leader skip). Without this, a 2-validator network freezes whenever
//      one is offline.
//   3. Bootstrap: when the validator set is "effectively empty" (only the
//      genesis placeholder), any node with --miner-address can produce —
//      but yields to a recently-active peer so two fresh nodes don't fork.
//
// Also enforces MIN_BLOCK_GAP_MS pacing if last_block_produced_ms is set
// (sleeps inside the helper so main.zig stays linear).
//
// Returns .skip when the caller should `continue` the outer mining loop,
// or .mine when it should fall through to produce the next block.

const std = @import("std");

const blockchain_mod = @import("../blockchain.zig");
const validator_mod  = @import("../validator_registry.zig");
const p2p_mod        = @import("../p2p.zig");
const orchestrator_mod = @import("../orchestrator.zig");

pub const SlotDecision = enum { mine, skip };

pub const SlotContext = struct {
    bc: *blockchain_mod.Blockchain,
    p2p: *p2p_mod.P2PNode,
    clock: *orchestrator_mod.AtomicClock,
    effective_miner_addr: []const u8,
    stabilizer_timeout_mult: f64,
    MIN_BLOCK_GAP_MS: i64,
    SLOT_TIMEOUT_MS: i64,
    last_tip_height_ptr: *usize,
    tip_arrival_ms_ptr: *i64,
    last_block_produced_ms: i64,
    block_count: u32,
};

pub fn shouldMineThisSlot(ctx: SlotContext) SlotDecision {
    const bc = ctx.bc;
    const p2p = ctx.p2p;
    const SLOT_TIMEOUT_MS = ctx.SLOT_TIMEOUT_MS;
    const block_count = ctx.block_count;

    // Guard: chain should always contain genesis, but if another thread
    // is mid-reset (DB reload, fork resolution), len can transiently be 0.
    // Skip this slot rather than panic on out-of-bounds index.
    if (bc.chain.items.len == 0) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        return .skip;
    }
    const tip = bc.chain.items[bc.chain.items.len - 1];
    const slot_id: u64 = @intCast(bc.chain.items.len); // = next block index
    const leader = validator_mod.leaderForSlot(
        slot_id,
        tip.hash,
        bc.validator_set.items,
    );
    const my_addr = ctx.effective_miner_addr;

    // Refresh tip_arrival_ms whenever the chain extended (tip changed).
    // Bumping it to "now" effectively restarts the slot timer at every
    // block — the leader for slot N gets SLOT_TIMEOUT_MS *after* slot
    // N-1 landed, not from some absolute past wall-clock.
    if (bc.chain.items.len != ctx.last_tip_height_ptr.*) {
        ctx.last_tip_height_ptr.* = bc.chain.items.len;
        ctx.tip_arrival_ms_ptr.* = ctx.clock.nowMs();
    }

    // Am I a validator at all? (Required for liveness fallback.)
    var i_am_validator = false;
    for (bc.validator_set.items) |v| {
        if (std.mem.eql(u8, v.address, my_addr)) { i_am_validator = true; break; }
    }

    // Has the slot timed out (leader inactive)?
    //
    // Adaptive timeout: if NO peer has been active in the last 5s,
    // we're effectively solo-mining — there's nobody to wait for.
    // Drop the timeout to 50ms (just enough to let any in-flight
    // block_announce arrive) so each leader-skip slot doesn't burn
    // 300ms of wall-clock. This was the dominant cost in the 35
    // blocks/min steady state: half the slots had a missing peer
    // leader → 300ms × 0.5 ≈ 150ms wasted per block on average.
    const now_ms: i64 = ctx.clock.nowMs();
    const now_s: i64 = @divTrunc(now_ms, 1000);
    const tip_age_ms: i64 = now_ms - ctx.tip_arrival_ms_ptr.*;
    const peer_active_ts_ms = p2p.lastPeerActivityTs() * 1000;
    const peer_offline = peer_active_ts_ms == 0 or
        (now_ms - peer_active_ts_ms) >= 5_000;
    const base_timeout_ms: i64 = if (peer_offline) 50 else SLOT_TIMEOUT_MS;
    // Apply stabilizer multiplier (clamped to [0.2, 2.0] in updater).
    // Floor at 30ms — anything tighter than that and we hit the OS
    // sleep-quantum noise floor and burn CPU without producing blocks.
    const scaled_ms = @as(f64, @floatFromInt(base_timeout_ms)) *
                      ctx.stabilizer_timeout_mult;
    const effective_timeout_ms: i64 = @max(@as(i64, 30),
        @as(i64, @intFromFloat(scaled_ms)));
    const slot_timed_out = tip_age_ms >= effective_timeout_ms;

    const is_my_turn = blk: {
        // Bootstrap free-for-all — when no validator yet has crossed
        // MIN_VALIDATOR_BALANCE, the chain would freeze (no slot
        // leader to pick → mining loop sleeps forever). To break
        // the catch-22 (need to mine to gain balance to be a
        // validator), we let any node with `--miner-address`
        // produce blocks while the validator set is empty.
        //
        // Safety: we only bootstrap when there are NO peers
        // connected. If we have peers, we sync from them instead
        // of producing our own (otherwise two fresh nodes with no
        // common chain history both mine block 1 and fork forever).
        // The yield-to-active-peer check below covers the dual-
        // online case once at least one node has bootstrapped.
        const peers_connected = p2p.peers.items.len;
        // Treat the validator_set as "effectively empty" when it
        // contains ONLY the genesis placeholder ("…replaceformainnet")
        // and no real wallet has been promoted yet. Without this gate,
        // the slot-leader check below ALWAYS rejects me (placeholder
        // address never matches a real wallet) → mining spins forever
        // without producing blocks. See validator_registry.zig:63-69
        // for the placeholder seed.
        var has_real_validator = false;
        for (bc.validator_set.items) |v| {
            if (std.mem.indexOf(u8, v.address, "replaceformainnet") == null and
                std.mem.indexOf(u8, v.address, "bootstrapvalidator") == null) {
                has_real_validator = true;
                break;
            }
        }
        if (!has_real_validator and my_addr.len > 0) {
            const PEER_ACTIVE_BOOT_S: i64 = 2;
            const peer_active_ts = p2p.lastPeerActivityTs();
            const peer_recently_active =
                peer_active_ts > 0 and (now_s - peer_active_ts) <= PEER_ACTIVE_BOOT_S;
            if (peers_connected > 0 and peer_recently_active) {
                std.debug.print(
                    "[BOOTSTRAP] Validator set placeholder-only but peer active {d}s ago — yielding to let them seed\n",
                    .{now_s - peer_active_ts},
                );
                break :blk false;
            }
            if (block_count % 30 == 0) {
                std.debug.print(
                    "[BOOTSTRAP] No real validators yet ({d} blocks, {d} peers, set_size={d}) — producing slot {d}\n",
                    .{ bc.chain.items.len, peers_connected, bc.validator_set.items.len, slot_id },
                );
            }
            break :blk true;
        }

        if (leader) |l| {
            if (std.mem.eql(u8, l.address, my_addr)) break :blk true;
        }
        // Liveness: leader missed the slot — any validator picks up.
        // Anti-fork via deterministic tiebreak: when both validators
        // see the timeout at the same time, they both want to take
        // the slot. Naive yield-to-active-peer deadlocks (both yield
        // to each other → 6s gap, 17 blocks/min instead of 60).
        //
        // Fix: rank candidate fallback validators by address ascending.
        // Only the lowest-ranked validator (lex-smallest address) takes
        // the orphan slot; everyone else yields. This is symmetric
        // *visible* state (the validator set is identical on every
        // node) so both sides reach the same decision without any
        // extra coordination message.
        if (slot_timed_out and i_am_validator) {
            var lowest_addr: []const u8 = my_addr;
            for (bc.validator_set.items) |v| {
                // Skip the missing leader — they're the one who silenced.
                if (leader) |l| {
                    if (std.mem.eql(u8, l.address, v.address)) continue;
                }
                if (std.mem.lessThan(u8, v.address, lowest_addr)) {
                    lowest_addr = v.address;
                }
            }
            const i_am_fallback = std.mem.eql(u8, lowest_addr, my_addr);
            if (!i_am_fallback) {
                if (block_count % 30 == 0) {
                    std.debug.print(
                        "[SLOT-YIELD] Tip aged {d}ms at slot {d} — yielding to {s} (lex-min validator)\n",
                        .{ tip_age_ms, slot_id,
                           lowest_addr[0..@min(12, lowest_addr.len)] },
                    );
                }
                break :blk false;
            }
            std.debug.print(
                "[SLOT-SKIP] Leader {s} silent for {d}ms at slot {d}, taking the slot (I am lex-min fallback)\n",
                .{ if (leader) |l| l.address[0..@min(12, l.address.len)] else "<none>",
                   tip_age_ms, slot_id },
            );
            break :blk true;
        }
        break :blk false;
    };
    if (!is_my_turn) {
        if (block_count % 30 == 0 and leader != null) {
            std.debug.print(
                "[SLOT] Not my turn at slot {d} — leader is {s} (I am {s})\n",
                .{ slot_id, leader.?.address[0..@min(12, leader.?.address.len)], my_addr[0..@min(12, my_addr.len)] },
            );
        }
        // Tight poll (50ms) so we react within ~half a SLOT_TIMEOUT.
        // The previous 500ms added avoidable latency: at 1s/block we
        // could miss the failover window entirely on one iteration.
        std.Thread.sleep(50 * std.time.ns_per_ms);
        return .skip;
    }

    // Block-rate enforcement: never produce a new block faster
    // than MIN_BLOCK_GAP_MS after the previous one. With the
    // gap set to 1000 ms this locks the chain to exactly the
    // 60 blocks/min target from the whitepaper.
    //
    // Hardware capacity is ~3× this rate (we measured 180-185
    // blocks/min uncapped on the same VPS). The headroom is
    // intentional safety margin — when scheduler pauses or
    // network jitter eat into a slot, the next iteration still
    // produces inside the same wall-clock second; we never fall
    // behind the published schedule.
    //
    // Previously this smoothing was conditional on
    // `stabilizer_timeout_mult >= 1.0`, but that escape hatch
    // existed only because we were chasing 60/min and didn't
    // want to suppress recovery bursts. With the oracle_fetcher
    // unblocked (no more 8-9 s spikes) we have no reason to
    // burst — the unconditional gap keeps tokenomics honest.
    if (ctx.last_block_produced_ms != 0) {
        const since_last = now_ms - ctx.last_block_produced_ms;
        if (since_last < ctx.MIN_BLOCK_GAP_MS) {
            const wait_ms: u64 = @intCast(ctx.MIN_BLOCK_GAP_MS - since_last);
            std.Thread.sleep(wait_ms * std.time.ns_per_ms);
        }
    }

    return .mine;
}
