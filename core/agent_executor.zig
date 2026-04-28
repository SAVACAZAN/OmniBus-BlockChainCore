/// agent_executor.zig — Loop autonom pentru AI Agents
///
/// Pentru fiecare agent inregistrat, executor-ul evalueaza la `tick_ms` interval:
///   1. Citeste capital curent (balance + stake + LP locked).
///   2. Recalculeaza tier-ul (cu hysteresis).
///   3. Aplica reguli user-scrise (deterministe, in ordinea declarata).
///   4. Daca nicio regula nu trage, aplica strategia preset pentru tier.
///   5. Genereaza decizii (TX intent), care sunt apoi semnate si trimise
///      spre mempool de catre nodul gazda.
///
/// Executor-ul NU semneaza TX direct — emite un `Decision`, iar caller-ul
/// (main.zig sau RPC handler) apeleaza `wallet.sign(...)` si `mempool.add(...)`.
/// Asa pastram executor-ul testabil fara wallet real.

const std = @import("std");
const tier_mod = @import("agent_tier.zig");
const cfg_mod = @import("agent_config.zig");

pub const Tier = tier_mod.Tier;
pub const AgentConfig = cfg_mod.AgentConfig;
pub const Strategy = cfg_mod.Strategy;

/// Snapshot al starii agentului la un tick.
pub const AgentState = struct {
    /// Adresa wallet-ului agentului (slice peste buffer extern, nu detinut).
    address: []const u8,
    /// Balance lichid in SAT.
    balance_sat: u64,
    /// Stake locked ca validator in SAT.
    staked_sat: u64,
    /// Liquidity locked in order book in SAT.
    lp_locked_sat: u64,
    /// P&L cumulat in sesiune (poate fi negativ — folosim i64).
    pnl_session_sat: i64,
    /// Tier curent (memorat intre tick-uri pentru hysteresis).
    tier: Tier,
    /// Ultima inaltime de bloc procesata.
    last_block_height: u64,
    /// Daca agentul e oprit manual (kill-switch) sau de regula `halt`.
    halted: bool = false,
    /// Numar tick-uri executate de la start.
    ticks: u64 = 0,

    pub fn capitalSat(self: AgentState) u64 {
        return self.balance_sat + self.staked_sat + self.lp_locked_sat;
    }
};

/// Snapshot oracle on-chain — alimentat de oracle_fetcher.zig la fiecare 10 blocks.
pub const OracleSnapshot = struct {
    /// BTC/USD median din 3 exchange-uri, in micro-USD (price * 1_000_000).
    btc_usd_micro: u64 = 0,
    /// LCX/USD median, in micro-USD.
    lcx_usd_micro: u64 = 0,
    /// Variatia BTC/USD in ultima ora, procente (poate fi negativa).
    btc_change_1h_pct: f64 = 0.0,
    /// Variatia BTC/USD in 24h.
    btc_change_24h_pct: f64 = 0.0,
    /// Spread mediu observat pe perechea principala (bps).
    spread_bps: u32 = 0,
    /// Inaltimea blocului la care s-a luat snapshot-ul.
    block_height: u64 = 0,
    /// Daca snapshot-ul e proaspat (a fost actualizat in ultimele N blocks).
    fresh: bool = false,
};

/// Decizie emisa de executor — caller-ul o transforma in TX semnata.
pub const DecisionKind = enum(u8) {
    none, // niciun plan in tick-ul asta
    claim_faucet,
    mine, // ramai in mining (no-op explicit)
    stake,
    unstake,
    provide_liquidity,
    withdraw_liquidity,
    buy, // cumpara pe venue indicat
    sell, // vinde pe venue indicat
    halt, // kill-switch — opreste agentul
};

/// Venue de execuție pentru o decizie.
/// `omnibus_native` → executat de nod (mining/stake/transfer chain native)
/// celelalte → trimise prin RPC `agent_pending_decisions` la client extern
/// (Python pentru CEX, ulterior Rust/TS pentru DEX).
pub const Venue = enum(u8) {
    /// Nu necesita venue (mine/halt/none).
    none = 0,
    /// Operatii on-chain native pe OmniBus (stake, unstake, transfer).
    omnibus_native = 1,
    /// CEX LCX prin Connect SDK Python.
    lcx = 2,
    /// CEX Kraken prin Connect SDK Python.
    kraken = 3,
    /// CEX Coinbase Advanced prin Connect SDK Python.
    coinbase = 4,
    /// DEX intern OmniBus-EX (Liberty Chain) — executat din aweb3 Tauri.
    omnibus_ex = 5,
    /// DEX Uniswap pe ETH/L2 — executat din aweb3 Tauri (ethers-rs).
    uniswap = 6,

    pub fn name(self: Venue) []const u8 {
        return switch (self) {
            .none => "none",
            .omnibus_native => "omnibus_native",
            .lcx => "lcx",
            .kraken => "kraken",
            .coinbase => "coinbase",
            .omnibus_ex => "omnibus_ex",
            .uniswap => "uniswap",
        };
    }

    /// Decision-urile pentru acest venue se executa de nod (true) sau de client extern (false).
    pub fn isNative(self: Venue) bool {
        return self == .omnibus_native;
    }
};

pub const Decision = struct {
    kind: DecisionKind,
    /// Venue de executie — decide cine ridica decision-ul (nod sau client extern).
    venue: Venue = .none,
    /// Suma in SAT relevanta pentru actiune (stake amount, trade amount, etc.).
    amount_sat: u64 = 0,
    /// Pereche (ex: "BTC/USD") — gol pentru actiuni care nu cer pereche.
    pair: [cfg_mod.MAX_PAIR_LEN]u8 = std.mem.zeroes([cfg_mod.MAX_PAIR_LEN]u8),
    pair_len: u8 = 0,
    /// Reason text pentru log (max 64 chars).
    reason: [64]u8 = std.mem.zeroes([64]u8),
    reason_len: u8 = 0,

    pub fn getPair(self: *const Decision) []const u8 {
        return self.pair[0..self.pair_len];
    }
    pub fn getReason(self: *const Decision) []const u8 {
        return self.reason[0..self.reason_len];
    }

    pub fn setReason(self: *Decision, r: []const u8) void {
        const len = @min(r.len, self.reason.len);
        @memcpy(self.reason[0..len], r[0..len]);
        self.reason_len = @intCast(len);
    }
    pub fn setPair(self: *Decision, p: []const u8) void {
        const len = @min(p.len, self.pair.len);
        @memcpy(self.pair[0..len], p[0..len]);
        self.pair_len = @intCast(len);
    }
};

pub const NoOp = Decision{ .kind = .none };

/// Engine-ul de decizie — pur, fara side-effects (nu semneaza, nu trimite).
pub const AgentExecutor = struct {
    config: AgentConfig,
    state: AgentState,

    pub fn init(config: AgentConfig, address: []const u8) AgentExecutor {
        return .{
            .config = config,
            .state = AgentState{
                .address = address,
                .balance_sat = 0,
                .staked_sat = 0,
                .lp_locked_sat = 0,
                .pnl_session_sat = 0,
                .tier = .t1_mining,
                .last_block_height = 0,
            },
        };
    }

    /// Actualizeaza starea financiara (chemata inainte de tick).
    pub fn updateBalance(self: *AgentExecutor, balance: u64, staked: u64, lp: u64, pnl: i64) void {
        self.state.balance_sat = balance;
        self.state.staked_sat = staked;
        self.state.lp_locked_sat = lp;
        self.state.pnl_session_sat = pnl;
    }

    /// Recalculeaza tier-ul cu hysteresis. Returneaza tranzitia daca s-a schimbat.
    pub fn recomputeTier(self: *AgentExecutor, block_height: u64) ?tier_mod.TierTransition {
        const old = self.state.tier;
        var new = tier_mod.computeTier(old, self.state.capitalSat());
        // Aplica tier_cap daca userul a setat unul.
        if (self.config.tier_cap) |cap| {
            if (@intFromEnum(new) > @intFromEnum(cap)) new = cap;
        }
        // Daca auto_tier e off, ramai la cel din state (dar respecta cap).
        if (!self.config.auto_tier) {
            new = old;
            if (self.config.tier_cap) |cap| {
                if (@intFromEnum(new) > @intFromEnum(cap)) new = cap;
            }
        }
        self.state.tier = new;
        if (new == old) return null;
        return tier_mod.TierTransition{
            .from = old,
            .to = new,
            .capital_sat = self.state.capitalSat(),
            .block_height = block_height,
        };
    }

    /// Tick principal — produce o decizie (sau NoOp) pe baza starii + oracle.
    pub fn tick(self: *AgentExecutor, oracle: OracleSnapshot) Decision {
        self.state.ticks += 1;

        // 1. Halt are precedenta absoluta.
        if (self.state.halted) return NoOp;

        // 2. Risc daily-loss — daca am pierdut peste pragul setat, halt.
        const cap = self.state.capitalSat();
        if (cap > 0 and self.state.pnl_session_sat < 0) {
            const loss_abs: u64 = @intCast(-self.state.pnl_session_sat);
            const max_loss = (cap * @as(u64, self.config.risk.max_daily_loss_pct)) / 100;
            if (loss_abs >= max_loss) {
                self.state.halted = true;
                var d = Decision{ .kind = .halt };
                d.setReason("daily_loss_limit_breached");
                return d;
            }
        }

        // 3. Faucet — daca avem 0 capital si auto_claim e on, claim.
        if (cap == 0 and self.config.auto_claim_faucet) {
            var d = Decision{ .kind = .claim_faucet, .amount_sat = tier_mod.FAUCET_GRANT_SAT };
            d.setReason("bootstrap_faucet");
            return d;
        }

        // 4. Reguli user-scrise — prima care trage, castiga.
        for (self.config.rules[0..self.config.rules_count]) |rule| {
            const m = readMetric(rule.metric, self.state, oracle);
            if (matchOp(m, rule.op, rule.threshold)) {
                return ruleToDecision(rule, self.state, self.config);
            }
        }

        // 5. Strategy preset pentru tier-ul curent.
        return strategyDecision(self.state.tier, self.config.strategy, self.state, oracle);
    }
};

/// Citeste valoarea unei metrici din state + oracle.
fn readMetric(metric: cfg_mod.Metric, state: AgentState, oracle: OracleSnapshot) f64 {
    return switch (metric) {
        .btc_drop_1h_pct => -oracle.btc_change_1h_pct, // drop pozitiv cand pretul scade
        .btc_change_24h_pct => oracle.btc_change_24h_pct,
        .capital_omni => @as(f64, @floatFromInt(state.capitalSat())) / 1_000_000_000.0,
        .pnl_session_omni => @as(f64, @floatFromInt(state.pnl_session_sat)) / 1_000_000_000.0,
        .spread_bps => @floatFromInt(oracle.spread_bps),
    };
}

fn matchOp(value: f64, op: cfg_mod.Op, threshold: f64) bool {
    return switch (op) {
        .gt => value > threshold,
        .gte => value >= threshold,
        .lt => value < threshold,
        .lte => value <= threshold,
        .eq => value == threshold,
    };
}

fn ruleToDecision(rule: cfg_mod.Rule, state: AgentState, config: AgentConfig) Decision {
    const cap = state.capitalSat();
    const max_trade = (cap * @as(u64, config.risk.max_trade_pct)) / 100;
    const requested = (cap * @as(u64, rule.amount_pct)) / 100;
    const amount = @min(requested, max_trade);

    var d = Decision{ .kind = .none, .amount_sat = amount };
    d.kind = switch (rule.action) {
        .buy => .buy,
        .sell => .sell,
        .stake => .stake,
        .provide_liquidity => .provide_liquidity,
        .halt => .halt,
    };
    d.setReason("user_rule");
    if (config.pairs_count > 0) d.setPair(config.getPair(0));
    return d;
}

/// Decizie default per (tier, strategy) — folosita cand nicio regula nu trage.
fn strategyDecision(tier: Tier, strat: Strategy, state: AgentState, oracle: OracleSnapshot) Decision {
    _ = oracle; // strategiile preset sunt simple; oracle e folosit in reguli
    const cap = state.capitalSat();
    const reserve = 500_000_000; // 0.5 OMNI rezerva pentru fees
    const idle = if (state.balance_sat > reserve) state.balance_sat - reserve else 0;

    return switch (tier) {
        .t1_mining => mineDecision(),
        .t2_staking => switch (strat) {
            .conservative, .balanced, .market_maker => stakeIdle(idle, cap),
            .aggressive, .arbitrage_only => mineDecision(),
        },
        .t3_liquidity => switch (strat) {
            .conservative => stakeIdle(idle, cap),
            .balanced, .market_maker => provideLP(idle, cap),
            .aggressive, .arbitrage_only => provideLP(idle, cap),
        },
        .t4_arbitrage => switch (strat) {
            .conservative => stakeIdle(idle, cap),
            .balanced, .market_maker => provideLP(idle, cap),
            .aggressive, .arbitrage_only => mineDecision(), // arbitrajul e event-driven, nu permanent
        },
    };
}

fn mineDecision() Decision {
    var d = Decision{ .kind = .mine };
    d.setReason("preset_mine");
    return d;
}

fn stakeIdle(idle: u64, cap: u64) Decision {
    if (idle < tier_mod.T2_MIN_SAT) return mineDecision();
    _ = cap;
    var d = Decision{ .kind = .stake, .amount_sat = idle };
    d.setReason("preset_stake_idle");
    return d;
}

fn provideLP(idle: u64, cap: u64) Decision {
    _ = cap;
    if (idle < 10_000_000_000) return mineDecision(); // sub 10 OMNI lichid, ramai in mining
    var d = Decision{ .kind = .provide_liquidity, .amount_sat = idle };
    d.setReason("preset_provide_lp");
    return d;
}

// ─── Teste ────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "fresh agent claims faucet" {
    const cfg = AgentConfig.defaults("a", 1);
    var ex = AgentExecutor.init(cfg, "ob1q_test_addr");
    const d = ex.tick(.{});
    try testing.expectEqual(DecisionKind.claim_faucet, d.kind);
    try testing.expectEqual(tier_mod.FAUCET_GRANT_SAT, d.amount_sat);
}

test "T1 agent mines (no rules, default conservative)" {
    var cfg = AgentConfig.defaults("a", 1);
    cfg.auto_claim_faucet = false;
    var ex = AgentExecutor.init(cfg, "addr");
    ex.updateBalance(50_000_000_000, 0, 0, 0); // 50 OMNI — tot T1
    _ = ex.recomputeTier(1);
    const d = ex.tick(.{});
    try testing.expectEqual(DecisionKind.mine, d.kind);
    try testing.expectEqual(Tier.t1_mining, ex.state.tier);
}

test "T2 agent stakes idle balance with conservative preset" {
    var cfg = AgentConfig.defaults("a", 1);
    cfg.auto_claim_faucet = false;
    cfg.strategy = .conservative;
    var ex = AgentExecutor.init(cfg, "addr");
    // 200 OMNI in balance lichid -> capital >= T2_MIN, idle > T2_MIN
    ex.updateBalance(200_000_000_000, 0, 0, 0);
    const tr = ex.recomputeTier(10);
    try testing.expect(tr != null);
    try testing.expectEqual(Tier.t2_staking, ex.state.tier);
    const d = ex.tick(.{});
    try testing.expectEqual(DecisionKind.stake, d.kind);
}

test "tier upgrade T1 -> T2 -> T3 -> T4" {
    const cfg = AgentConfig.defaults("a", 1);
    var ex = AgentExecutor.init(cfg, "addr");

    ex.updateBalance(50_000_000_000, 0, 0, 0); // 50 OMNI
    _ = ex.recomputeTier(1);
    try testing.expectEqual(Tier.t1_mining, ex.state.tier);

    ex.updateBalance(150_000_000_000, 0, 0, 0); // 150 OMNI
    _ = ex.recomputeTier(2);
    try testing.expectEqual(Tier.t2_staking, ex.state.tier);

    ex.updateBalance(0, 1_500_000_000_000, 0, 0); // 1500 OMNI staked
    _ = ex.recomputeTier(3);
    try testing.expectEqual(Tier.t3_liquidity, ex.state.tier);

    ex.updateBalance(0, 1_500_000_000_000, 11_000_000_000_000, 0); // 12500 OMNI total
    _ = ex.recomputeTier(4);
    try testing.expectEqual(Tier.t4_arbitrage, ex.state.tier);
}

test "user rule overrides preset" {
    var cfg = AgentConfig.defaults("a", 1);
    cfg.auto_claim_faucet = false;
    try cfg.addPair("BTC/USD");
    try cfg.addRule(.{
        .metric = .btc_drop_1h_pct,
        .op = .gte,
        .threshold = 5.0,
        .action = .buy,
        .amount_pct = 10,
    });
    var ex = AgentExecutor.init(cfg, "addr");
    ex.updateBalance(100_000_000_000, 0, 0, 0); // 100 OMNI
    _ = ex.recomputeTier(1);

    // BTC a scazut 6% in ultima ora -> regula trage
    const d = ex.tick(.{ .btc_change_1h_pct = -6.0, .fresh = true });
    try testing.expectEqual(DecisionKind.buy, d.kind);
    try testing.expectEqualStrings("BTC/USD", d.getPair());
    try testing.expectEqualStrings("user_rule", d.getReason());
    // 10% requested, dar max_trade default e 5% -> capeaza la 5 OMNI
    try testing.expectEqual(@as(u64, 5_000_000_000), d.amount_sat);
}

test "halt rule kills agent" {
    var cfg = AgentConfig.defaults("a", 1);
    cfg.auto_claim_faucet = false;
    try cfg.addRule(.{
        .metric = .pnl_session_omni,
        .op = .lte,
        .threshold = -10.0,
        .action = .halt,
        .amount_pct = 100,
    });
    var ex = AgentExecutor.init(cfg, "addr");
    ex.updateBalance(100_000_000_000, 0, 0, -15_000_000_000); // -15 OMNI P&L
    _ = ex.recomputeTier(1);
    const d = ex.tick(.{});
    try testing.expectEqual(DecisionKind.halt, d.kind);

    // Tick urmator: agent ramane halt -> NoOp
    const d2 = ex.tick(.{});
    try testing.expectEqual(DecisionKind.none, d2.kind);
}

test "daily loss limit triggers auto-halt" {
    var cfg = AgentConfig.defaults("a", 1);
    cfg.auto_claim_faucet = false;
    cfg.risk.max_daily_loss_pct = 10;
    var ex = AgentExecutor.init(cfg, "addr");
    // 100 OMNI capital, -15 OMNI P&L = 15% loss -> halt automat
    ex.updateBalance(100_000_000_000, 0, 0, -15_000_000_000);
    _ = ex.recomputeTier(1);
    const d = ex.tick(.{});
    try testing.expectEqual(DecisionKind.halt, d.kind);
    try testing.expect(ex.state.halted);
}

test "tier_cap restricts agent capability" {
    var cfg = AgentConfig.defaults("a", 1);
    cfg.tier_cap = .t2_staking; // user nu vrea peste T2 chiar daca are capital
    var ex = AgentExecutor.init(cfg, "addr");
    ex.updateBalance(0, 5_000_000_000_000, 0, 0); // 5000 OMNI — ar fi T3 normal
    _ = ex.recomputeTier(1);
    try testing.expectEqual(Tier.t2_staking, ex.state.tier);
}

test "first rule wins (priority by declaration order)" {
    var cfg = AgentConfig.defaults("a", 1);
    cfg.auto_claim_faucet = false;
    try cfg.addPair("BTC/USD");
    try cfg.addRule(.{
        .metric = .capital_omni,
        .op = .gte,
        .threshold = 50.0,
        .action = .stake,
        .amount_pct = 50,
    });
    try cfg.addRule(.{
        .metric = .capital_omni,
        .op = .gte,
        .threshold = 50.0,
        .action = .buy,
        .amount_pct = 10,
    });
    var ex = AgentExecutor.init(cfg, "addr");
    ex.updateBalance(100_000_000_000, 0, 0, 0);
    _ = ex.recomputeTier(1);
    const d = ex.tick(.{});
    try testing.expectEqual(DecisionKind.stake, d.kind); // prima regula
}
