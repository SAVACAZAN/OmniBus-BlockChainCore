// core/node/agents.zig
// ──────────────────────────────────────────────────────────────────────────────
// AI Agent system glue — extracted from core/main.zig (2026-05-29).
//
// `loadAgentConfig` is called once at startup from main() if --agent-config is
// passed. `agentTickAll` is called from the mining loop on every new block.
//
// Adresa wallet pentru fiecare agent este derivata din mnemonic + wallet_index
// (BIP-44). Pentru MVP, folosim adresa miner-ului ca placeholder — derivarea
// reala per-agent va fi adaugata cand integram cu wallet.zig deriveByIndex.
//
// `submitNativeTx` routes per-decision-kind TXs (stake/unstake → op_return,
// trade demo → self-transfer). `agentTickAll` walks all loaded agents on
// each new block, asks the executor for a decision, submits native TXs or
// queues external ones for the Python/Rust client to fetch via RPC.
//
// `backfillReputationFromChain` is a one-shot retro scan: counts blocks per
// miner at startup, then assigns FOOD + VACATION reputation slugs to each.
// ──────────────────────────────────────────────────────────────────────────────

const std = @import("std");
const root = @import("root");

const blockchain_mod       = @import("../blockchain.zig");
const agent_config_mod     = @import("../agent_config.zig");
const agent_executor_mod   = @import("../agent_executor.zig");
const agent_manager_mod    = @import("../agent_manager.zig");
const reputation_manager_mod = @import("../reputation_manager.zig");

const Blockchain = blockchain_mod.Blockchain;

/// Checks the OMNIBUS_EXTERNAL_AGENTS env var. Prints the appropriate banner.
/// Returns true when the in-process AgentManager should load agents from
/// --agent-config (i.e., external agents NOT enabled). Caller then invokes
/// `loadAgentConfig` if `parsed.agent_config_path` is set.
pub fn checkAgentsActive(allocator: std.mem.Allocator) bool {
    const external_agents = std.process.getEnvVarOwned(
        allocator, "OMNIBUS_EXTERNAL_AGENTS",
    ) catch null;
    defer if (external_agents) |s| allocator.free(s);
    const agents_use_external = external_agents != null and
        std.mem.eql(u8, external_agents.?, "1");
    if (agents_use_external) {
        std.debug.print(
            "[AGENT] external agents enabled (OMNIBUS_EXTERNAL_AGENTS=1) " ++
            "— in-process agent manager disabled. Expect omnibus-agents on :28200\n", .{});
        return false;
    }
    return true;
}

pub fn loadAgentConfig(
    path: []const u8,
    mnemonic: []const u8,
    fallback_address: []const u8,
    allocator: std.mem.Allocator,
) void {
    const bundle = agent_config_mod.loadFile(allocator, path) catch |err| {
        std.debug.print("[AGENT] Eroare incarcare {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    if (bundle.count == 0) {
        std.debug.print("[AGENT] Fisier {s} nu contine agenti.\n", .{path});
        return;
    }
    var added: u8 = 0;
    for (bundle.agents[0..bundle.count]) |cfg| {
        // Derivare wallet propriu per-agent (BIP-44 cu wallet_index unic).
        // Daca derivarea esueaza, fallback la addAgent fara wallet (compat).
        if (root.g_agent_manager.addAgentFromMnemonic(cfg, mnemonic, allocator)) |slot| {
            std.debug.print(
                "[AGENT] Loaded {s} | wallet_index={d} | addr={s} | tier={s}\n",
                .{ cfg.getName(), cfg.wallet_index, slot.getAddress(), @tagName(slot.executor.state.tier) },
            );
            added += 1;
        } else |err| {
            std.debug.print(
                "[AGENT] Wallet derivation failed for {s} (idx={d}): {s} — fallback la fallback_address\n",
                .{ cfg.getName(), cfg.wallet_index, @errorName(err) },
            );
            _ = root.g_agent_manager.addAgent(cfg, fallback_address) catch |err2| {
                std.debug.print("[AGENT] Skip {s}: {s}\n", .{ cfg.getName(), @errorName(err2) });
                continue;
            };
            added += 1;
        }
    }
    if (added > 0) {
        root.g_agents_active = true;
        std.debug.print("[AGENT] {d} agent(i) incarcati din {s}.\n", .{ added, path });
    }
}

/// Snapshot oracle din state-ul global pentru a-l hrani agentilor.
pub fn buildOracleSnapshot(block_height: u64) agent_executor_mod.OracleSnapshot {
    var snap = agent_executor_mod.OracleSnapshot{ .block_height = block_height };
    if (root.g_oracle_fetcher) |*fetcher| {
        if (fetcher.getMedianPrice()) |btc| {
            snap.btc_usd_micro = btc;
            snap.fresh = true;
        }
        if (fetcher.getMedianLcxPrice()) |lcx| {
            snap.lcx_usd_micro = lcx;
        }
    }
    return snap;
}

/// Counter pentru tx_id la TX-urile generate automat de agenți.
/// Range mare ca să nu coliziune cu auto-TX miner (1_000_000+) și cu RPC-uri.
var g_agent_tx_id_counter: u32 = 5_000_000;

/// Submit TX automat pentru o decizie nativă. Returneaza eroare daca:
///   - agentul n-are wallet propriu (canSign() == false)
///   - kind nu cere TX (mine/halt/none — log-only)
///   - createSignedTx esueaza (privkey corupt)
///   - mempool respinge (insufficient funds, nonce conflict, etc.)
///
/// Routing per decision.kind:
///   - .stake / .unstake → TX self-transfer cu op_return "stake:<amt>" /
///     "unstake:<amt>". Chain-ul aplica via applyOpReturnRoles in
///     blockchain.zig (linia 1889). Agentul devine validator atunci.
///   - .claim_faucet → log-only (faucet real prin handshake RPC).
///   - .mine / .halt / .none → log-only.
///   - .buy / .sell / .provide_liquidity / .withdraw_liquidity → transfer
///     self demo (până când LP module e wired).
pub fn submitNativeTx(bc: *Blockchain, slot: *agent_manager_mod.AgentSlot, decision: agent_executor_mod.Decision) !void {
    if (!slot.canSign()) return error.NoWallet;
    const w = &slot.wallet.?;

    const op_return_text: ?[]u8 = switch (decision.kind) {
        .stake => try std.fmt.allocPrint(bc.allocator, "stake:{d}", .{decision.amount_sat}),
        .unstake => try std.fmt.allocPrint(bc.allocator, "unstake:{d}", .{decision.amount_sat}),
        .claim_faucet, .mine, .halt, .none => null,
        .buy, .sell, .provide_liquidity, .withdraw_liquidity => null,
    };

    const should_emit_tx = switch (decision.kind) {
        .stake, .unstake => true,
        .claim_faucet, .mine, .halt, .none => false,
        .buy, .sell, .provide_liquidity, .withdraw_liquidity => true,
    };
    if (!should_emit_tx) return;

    const balance = bc.getAddressBalance(w.getAddress());
    const reserve: u64 = 1_000;
    if (balance <= reserve) return error.InsufficientFunds;

    // Pentru stake: muta `amount` din balance in stake (TX self-transfer cu
    // op_return). Pentru unstake: amount poate fi 0 (chain-ul aplica
    // unstake-ul total din applyOpReturnRoles), dar lasam amount_sat ca
    // hint. Pentru trade demo: cap la balance-reserve.
    const amount: u64 = switch (decision.kind) {
        .stake => @min(decision.amount_sat, balance - reserve),
        .unstake => 0, // self-transfer 0, op_return face treaba
        else => @min(decision.amount_sat, balance - reserve),
    };
    if (decision.kind != .unstake and amount == 0) return error.AmountZero;

    const fee: u64 = 1;
    const nonce = bc.getNextAvailableNonce(w.getAddress());
    g_agent_tx_id_counter += 1;
    const tx_id = g_agent_tx_id_counter;

    var tx = try w.createSignedTx(w.getAddress(), amount, tx_id, nonce, fee, bc.allocator);
    if (op_return_text) |opr| {
        tx.op_return = opr;
        // Re-sign cu op_return inclus in hash-ul TX-ului, altfel signature
        // nu valideaza op_return-ul si applyOpReturnRoles vede un payload
        // care nu a fost autorizat de wallet.
        try tx.sign(w.private_key, bc.allocator);
    }

    bc.registerPubkey(w.getAddress(), &w.public_key_hex) catch {};

    try bc.addTransaction(tx);
    slot.stats.txs_submitted += 1;
    std.debug.print(
        "[AGENT-TX] {s} kind={s} tx_id={d} amount={d} nonce={d}{s}\n",
        .{
            slot.config.getName(),
            @tagName(decision.kind),
            tx_id, amount, nonce,
            if (op_return_text) |_| " (op_return wired)" else "",
        },
    );
}

/// Tick toti agentii. Apelat din mining loop pe fiecare bloc nou.
///
/// Routing dupa venue:
///   * `omnibus_native` / `none` → executat in nod (log doar; TX submission
///     urmeaza dupa wallet derivation per-agent).
///   * `lcx` / `kraken` / `coinbase` / `omnibus_ex` / `uniswap` → pus in
///     `g_agent_manager.pending` queue, ridicat de clientul extern Python/Rust
///     prin RPC `agent_pending_decisions`.
pub fn agentTickAll(bc: *Blockchain, block_height: u64) void {
    if (!root.g_agents_active) return;
    const oracle = buildOracleSnapshot(block_height);

    var idx: usize = 0;
    while (idx < agent_manager_mod.MAX_AGENTS) : (idx += 1) {
        const slot = &root.g_agent_manager.slots[idx];
        if (!slot.used) continue;

        const balance = bc.getAddressBalance(slot.getAddress());
        // Live stake lookup: agent.address e validator daca a emis stake:<amt>
        // op_return — findValidatorIndex + getValidatorInfo intorc starea
        // curenta (incluziv stake + status). LP locked ramane 0 pana cand
        // modulul LP per-agent e wired (separate de DEX grid trading).
        var staked: u64 = 0;
        if (root.g_staking_engine) |se| {
            if (se.getValidatorInfo(slot.getAddress())) |vi| {
                staked = vi.total_stake;
            }
        }
        slot.executor.updateBalance(balance, staked, 0, 0);

        const decision = root.g_agent_manager.tickOne(idx, oracle, block_height) orelse continue;
        if (decision.kind == .none) continue;

        // Tier transition log (o singura data per transition).
        if (slot.last_transition) |tr| {
            if (tr.block_height == block_height) {
                std.debug.print(
                    "[AGENT] {s} tier transition {s} -> {s} @ block {d} cap={d} SAT\n",
                    .{ slot.config.getName(), @tagName(tr.from), @tagName(tr.to), tr.block_height, tr.capital_sat },
                );
            }
        }

        // Routing dupa venue.
        const native = decision.venue == .omnibus_native or decision.venue == .none;
        if (native) {
            std.debug.print(
                "[AGENT-NATIVE] {s} tier={s} kind={s} amount={d} reason={s}\n",
                .{
                    slot.config.getName(),
                    @tagName(slot.executor.state.tier),
                    @tagName(decision.kind),
                    decision.amount_sat,
                    decision.getReason(),
                },
            );
            // Submit TX automat dacă agentul are wallet propriu și kind-ul cere TX.
            const tx_ok = blk: {
                submitNativeTx(bc, slot, decision) catch |err| {
                    std.debug.print("[AGENT-NATIVE] {s} TX skip: {s}\n", .{ slot.config.getName(), @errorName(err) });
                    break :blk false;
                };
                break :blk true;
            };
            // FOOD reputation credit la fiecare decizie reusita (creditAgentDecision).
            if (tx_ok) {
                if (root.g_reputation) |*rep_mgr| {
                    if (slot.canSign()) {
                        rep_mgr.creditAgentDecision(
                            slot.wallet.?.getAddress(),
                            block_height,
                        );
                    }
                }
            }
        } else {
            const decision_id = root.g_agent_manager.queueDecision(slot.config.wallet_index, block_height, decision);
            std.debug.print(
                "[AGENT-QUEUE] id={d} {s} venue={s} kind={s} pair={s} amount={d} reason={s}\n",
                .{
                    decision_id,
                    slot.config.getName(),
                    decision.venue.name(),
                    @tagName(decision.kind),
                    decision.getPair(),
                    decision.amount_sat,
                    decision.getReason(),
                },
            );
        }
    }
}

/// Retro backfill — scan all blocks at startup, count blocks per miner,
/// assign FOOD + VACATION to each miner address. One-shot: doar la primul
/// boot al binarului cu reputation system. Nu reaplică pentru blocuri viitoare
/// (care primesc credit incremental in mining loop via creditMinedBlock).
pub fn backfillReputationFromChain(
    bc: *Blockchain,
    rep_mgr: *reputation_manager_mod.ReputationManager,
) void {
    const total_blocks: u64 = @intCast(bc.chain.items.len);
    if (total_blocks == 0) return;
    const current_height: u64 = total_blocks - 1;

    // Tally blocks-per-miner + first-block-per-miner.
    // We use the same allocator as the chain — short-lived.
    const alloc = bc.allocator;
    var counts = std.StringHashMap(u64).init(alloc);
    defer counts.deinit();
    var first_seen = std.StringHashMap(u64).init(alloc);
    defer first_seen.deinit();

    for (bc.chain.items, 0..) |blk, idx| {
        const miner = blk.miner_address;
        if (miner.len == 0) continue;
        const gop = counts.getOrPut(miner) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        const fs = first_seen.getOrPut(miner) catch continue;
        if (!fs.found_existing) fs.value_ptr.* = idx;
    }

    var miners_seen: u64 = 0;
    var it = counts.iterator();
    while (it.next()) |entry| {
        const miner = entry.key_ptr.*;
        const n_blocks = entry.value_ptr.*;
        const first_block = first_seen.get(miner) orelse 0;
        rep_mgr.backfill(miner, n_blocks, first_block, current_height);
        miners_seen += 1;
    }
    std.debug.print(
        "[REPUTATION] Retro backfill complete: {d} miners, {d} blocks scanned (current height {d})\n",
        .{ miners_seen, total_blocks, current_height },
    );
}
