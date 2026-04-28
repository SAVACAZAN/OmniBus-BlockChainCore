/// agent_config.zig — Configuratie persistenta pentru AI Agents
///
/// User-facing format: JSON (TOML poate fi adaugat later, std are JSON nativ).
/// Userul scrie un fisier `agent.json` o singura data, apoi nodul il incarca:
///
///   omnibus-node --agent-config agent.json
///
/// Strategii: 4 preset-uri + reguli custom user-scrise (deterministe).
/// Tier-ul curent (din agent_tier.zig) decide ce capabilitati sunt active.

const std = @import("std");
const tier_mod = @import("agent_tier.zig");

pub const MAX_AGENTS_PER_NODE: usize = 16;
pub const MAX_NAME_LEN: usize = 32;
pub const MAX_RULES_PER_AGENT: usize = 16;
pub const MAX_PAIRS_PER_AGENT: usize = 8;
pub const MAX_PAIR_LEN: usize = 16;

/// Strategie pre-built — defaults rezonabili per profil de risc.
pub const Strategy = enum(u8) {
    /// Doar mining + staking pasiv. Zero risc de trading.
    conservative = 0,
    /// Mining + staking + LP cu spread larg (low risk).
    balanced = 1,
    /// LP cu spread strans + arbitraj agresiv.
    aggressive = 2,
    /// Doar arbitraj cross-exchange (trebuie tier T4).
    arbitrage_only = 3,
    /// LP focus — market making cu volume mare.
    market_maker = 4,

    pub fn name(self: Strategy) []const u8 {
        return switch (self) {
            .conservative => "conservative",
            .balanced => "balanced",
            .aggressive => "aggressive",
            .arbitrage_only => "arbitrage_only",
            .market_maker => "market_maker",
        };
    }

    pub fn fromString(s: []const u8) ?Strategy {
        if (std.mem.eql(u8, s, "conservative")) return .conservative;
        if (std.mem.eql(u8, s, "balanced")) return .balanced;
        if (std.mem.eql(u8, s, "aggressive")) return .aggressive;
        if (std.mem.eql(u8, s, "arbitrage_only")) return .arbitrage_only;
        if (std.mem.eql(u8, s, "market_maker")) return .market_maker;
        return null;
    }
};

/// Regula deterministica scrisa de user — evaluata la fiecare tick.
///
/// Forma: "if <metric> <op> <threshold> then <action> <amount_pct>"
/// Exemplu serialized:
///   { "metric": "btc_drop_1h_pct", "op": ">=", "threshold": 5.0,
///     "action": "buy", "amount_pct": 10 }
pub const Op = enum(u8) { gt, gte, lt, lte, eq };
pub const Action = enum(u8) {
    /// Cumpara la oracle median.
    buy,
    /// Vinde la oracle median.
    sell,
    /// Stake suma indicata din balance disponibil.
    stake,
    /// Provide liquidity la spread default.
    provide_liquidity,
    /// Pause agentul (kill-switch).
    halt,
};

pub const Metric = enum(u8) {
    /// Variatia BTC/USD in ultima ora, in procente.
    btc_drop_1h_pct,
    /// Variatia BTC/USD in 24h.
    btc_change_24h_pct,
    /// Capital total al agentului in OMNI.
    capital_omni,
    /// P&L cumulat sesiune curenta in OMNI.
    pnl_session_omni,
    /// Spread mediu pe perechea preferata in basis points.
    spread_bps,
};

pub const Rule = struct {
    metric: Metric,
    op: Op,
    threshold: f64,
    action: Action,
    /// Procent din capital alocat acțiunii (1..100).
    amount_pct: u8,
};

/// Limite hard de risc — agentul NU le incalca indiferent de strategie/reguli.
pub const RiskLimits = struct {
    /// Max % din capital intr-un singur trade (default 5%).
    max_trade_pct: u8 = 5,
    /// Max pierdere per zi inainte de halt (default 10%).
    max_daily_loss_pct: u8 = 10,
    /// Min capital de retinut pentru fees (default 0.5 OMNI).
    min_reserve_sat: u64 = 500_000_000,
    /// Slippage maxim acceptat in bps (default 50 = 0.5%).
    max_slippage_bps: u32 = 50,
};

/// Configuratia unui singur agent.
pub const AgentConfig = struct {
    /// Nume display, max 32 chars.
    name: [MAX_NAME_LEN]u8 = std.mem.zeroes([MAX_NAME_LEN]u8),
    name_len: u8 = 0,
    /// BIP-44 derivation index pentru wallet (1..n, 0 e wallet-ul nodului).
    wallet_index: u32 = 1,
    /// Strategy preset.
    strategy: Strategy = .conservative,
    /// Auto-progress prin tier-uri pe masura ce capital creste.
    auto_tier: bool = true,
    /// Tier maxim permis (cap manual). null = fara cap.
    tier_cap: ?tier_mod.Tier = null,
    /// Reguli user-scrise (override peste preset).
    rules: [MAX_RULES_PER_AGENT]Rule = std.mem.zeroes([MAX_RULES_PER_AGENT]Rule),
    rules_count: u8 = 0,
    /// Perechi preferate pentru LP/arbitraj (ex: "BTC/USD", "ETH/USD").
    pairs: [MAX_PAIRS_PER_AGENT][MAX_PAIR_LEN]u8 = std.mem.zeroes([MAX_PAIRS_PER_AGENT][MAX_PAIR_LEN]u8),
    pairs_len: [MAX_PAIRS_PER_AGENT]u8 = std.mem.zeroes([MAX_PAIRS_PER_AGENT]u8),
    pairs_count: u8 = 0,
    /// Limitele de risc.
    risk: RiskLimits = .{},
    /// Frecventa decizie in milisecunde (default 5s).
    tick_ms: u32 = 5_000,
    /// Activeaza claim faucet automat la start (pentru agenti new).
    auto_claim_faucet: bool = true,

    pub fn getName(self: *const AgentConfig) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *AgentConfig, n: []const u8) void {
        const len = @min(n.len, MAX_NAME_LEN);
        @memcpy(self.name[0..len], n[0..len]);
        self.name_len = @intCast(len);
    }

    pub fn addPair(self: *AgentConfig, pair: []const u8) !void {
        if (self.pairs_count >= MAX_PAIRS_PER_AGENT) return error.TooManyPairs;
        const idx = self.pairs_count;
        const len = @min(pair.len, MAX_PAIR_LEN);
        @memcpy(self.pairs[idx][0..len], pair[0..len]);
        self.pairs_len[idx] = @intCast(len);
        self.pairs_count += 1;
    }

    pub fn getPair(self: *const AgentConfig, idx: usize) []const u8 {
        if (idx >= self.pairs_count) return "";
        return self.pairs[idx][0..self.pairs_len[idx]];
    }

    pub fn addRule(self: *AgentConfig, rule: Rule) !void {
        if (self.rules_count >= MAX_RULES_PER_AGENT) return error.TooManyRules;
        if (rule.amount_pct == 0 or rule.amount_pct > 100) return error.InvalidAmountPct;
        self.rules[self.rules_count] = rule;
        self.rules_count += 1;
    }

    /// Default sane pentru un agent nou cu strategie conservative.
    pub fn defaults(name: []const u8, wallet_index: u32) AgentConfig {
        var cfg = AgentConfig{};
        cfg.setName(name);
        cfg.wallet_index = wallet_index;
        cfg.strategy = .conservative;
        cfg.auto_tier = true;
        cfg.tick_ms = 5_000;
        cfg.auto_claim_faucet = true;
        return cfg;
    }
};

/// Bundle de agenti pentru un nod — incarcat dintr-un fisier `agent.json`.
pub const AgentBundle = struct {
    agents: [MAX_AGENTS_PER_NODE]AgentConfig = std.mem.zeroes([MAX_AGENTS_PER_NODE]AgentConfig),
    count: u8 = 0,

    pub fn add(self: *AgentBundle, cfg: AgentConfig) !void {
        if (self.count >= MAX_AGENTS_PER_NODE) return error.TooManyAgents;
        self.agents[self.count] = cfg;
        self.count += 1;
    }
};

// ─── JSON Parser ─────────────────────────────────────────────────────────────

pub const ParseError = error{
    InvalidJson,
    MissingField,
    UnknownStrategy,
    UnknownMetric,
    UnknownOp,
    UnknownAction,
    InvalidAmountPct,
    TooManyAgents,
    TooManyRules,
    TooManyPairs,
    OutOfMemory,
};

/// Parseaza un fisier JSON cu agent configs. Format asteptat:
/// {
///   "agents": [
///     {
///       "name": "alpha",
///       "wallet_index": 1,
///       "strategy": "balanced",
///       "auto_tier": true,
///       "auto_claim_faucet": true,
///       "tick_ms": 5000,
///       "pairs": ["BTC/USD", "ETH/USD"],
///       "risk": { "max_trade_pct": 5, "max_daily_loss_pct": 10 },
///       "rules": [
///         { "metric": "btc_drop_1h_pct", "op": "gte", "threshold": 5.0,
///           "action": "buy", "amount_pct": 10 }
///       ]
///     }
///   ]
/// }
pub fn parseJson(allocator: std.mem.Allocator, json_text: []const u8) ParseError!AgentBundle {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return ParseError.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return ParseError.InvalidJson;
    const agents_val = root.object.get("agents") orelse return ParseError.MissingField;
    if (agents_val != .array) return ParseError.InvalidJson;

    var bundle = AgentBundle{};
    for (agents_val.array.items) |agent_val| {
        if (agent_val != .object) return ParseError.InvalidJson;
        const cfg = try parseAgent(agent_val);
        try bundle.add(cfg);
    }
    return bundle;
}

fn parseAgent(v: std.json.Value) ParseError!AgentConfig {
    const obj = v.object;
    var cfg = AgentConfig{};

    if (obj.get("name")) |nv| {
        if (nv == .string) cfg.setName(nv.string);
    }
    if (obj.get("wallet_index")) |wv| {
        if (wv == .integer and wv.integer >= 0) cfg.wallet_index = @intCast(wv.integer);
    }
    if (obj.get("strategy")) |sv| {
        if (sv == .string) {
            cfg.strategy = Strategy.fromString(sv.string) orelse return ParseError.UnknownStrategy;
        }
    }
    if (obj.get("auto_tier")) |av| {
        if (av == .bool) cfg.auto_tier = av.bool;
    }
    if (obj.get("auto_claim_faucet")) |av| {
        if (av == .bool) cfg.auto_claim_faucet = av.bool;
    }
    if (obj.get("tick_ms")) |tv| {
        if (tv == .integer and tv.integer > 0) cfg.tick_ms = @intCast(tv.integer);
    }
    if (obj.get("pairs")) |pv| {
        if (pv == .array) {
            for (pv.array.items) |p| {
                if (p == .string) try cfg.addPair(p.string);
            }
        }
    }
    if (obj.get("risk")) |rv| {
        if (rv == .object) cfg.risk = parseRisk(rv);
    }
    if (obj.get("rules")) |rv| {
        if (rv == .array) {
            for (rv.array.items) |rule_val| {
                if (rule_val != .object) continue;
                const rule = try parseRule(rule_val);
                try cfg.addRule(rule);
            }
        }
    }
    return cfg;
}

fn parseRisk(v: std.json.Value) RiskLimits {
    var r = RiskLimits{};
    const obj = v.object;
    if (obj.get("max_trade_pct")) |x| {
        if (x == .integer and x.integer >= 0 and x.integer <= 100) r.max_trade_pct = @intCast(x.integer);
    }
    if (obj.get("max_daily_loss_pct")) |x| {
        if (x == .integer and x.integer >= 0 and x.integer <= 100) r.max_daily_loss_pct = @intCast(x.integer);
    }
    if (obj.get("min_reserve_sat")) |x| {
        if (x == .integer and x.integer >= 0) r.min_reserve_sat = @intCast(x.integer);
    }
    if (obj.get("max_slippage_bps")) |x| {
        if (x == .integer and x.integer >= 0) r.max_slippage_bps = @intCast(x.integer);
    }
    return r;
}

fn parseRule(v: std.json.Value) ParseError!Rule {
    const obj = v.object;
    const metric_str = (obj.get("metric") orelse return ParseError.MissingField).string;
    const op_str = (obj.get("op") orelse return ParseError.MissingField).string;
    const action_str = (obj.get("action") orelse return ParseError.MissingField).string;

    const threshold_val = obj.get("threshold") orelse return ParseError.MissingField;
    const threshold: f64 = switch (threshold_val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return ParseError.InvalidJson,
    };

    const amount_val = obj.get("amount_pct") orelse return ParseError.MissingField;
    if (amount_val != .integer or amount_val.integer < 1 or amount_val.integer > 100) {
        return ParseError.InvalidAmountPct;
    }

    return Rule{
        .metric = parseMetric(metric_str) orelse return ParseError.UnknownMetric,
        .op = parseOp(op_str) orelse return ParseError.UnknownOp,
        .action = parseAction(action_str) orelse return ParseError.UnknownAction,
        .threshold = threshold,
        .amount_pct = @intCast(amount_val.integer),
    };
}

fn parseMetric(s: []const u8) ?Metric {
    if (std.mem.eql(u8, s, "btc_drop_1h_pct")) return .btc_drop_1h_pct;
    if (std.mem.eql(u8, s, "btc_change_24h_pct")) return .btc_change_24h_pct;
    if (std.mem.eql(u8, s, "capital_omni")) return .capital_omni;
    if (std.mem.eql(u8, s, "pnl_session_omni")) return .pnl_session_omni;
    if (std.mem.eql(u8, s, "spread_bps")) return .spread_bps;
    return null;
}

fn parseOp(s: []const u8) ?Op {
    if (std.mem.eql(u8, s, "gt") or std.mem.eql(u8, s, ">")) return .gt;
    if (std.mem.eql(u8, s, "gte") or std.mem.eql(u8, s, ">=")) return .gte;
    if (std.mem.eql(u8, s, "lt") or std.mem.eql(u8, s, "<")) return .lt;
    if (std.mem.eql(u8, s, "lte") or std.mem.eql(u8, s, "<=")) return .lte;
    if (std.mem.eql(u8, s, "eq") or std.mem.eql(u8, s, "==")) return .eq;
    return null;
}

fn parseAction(s: []const u8) ?Action {
    if (std.mem.eql(u8, s, "buy")) return .buy;
    if (std.mem.eql(u8, s, "sell")) return .sell;
    if (std.mem.eql(u8, s, "stake")) return .stake;
    if (std.mem.eql(u8, s, "provide_liquidity")) return .provide_liquidity;
    if (std.mem.eql(u8, s, "halt")) return .halt;
    return null;
}

/// Citeste un fisier JSON de la disk si parseaza in AgentBundle.
pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) ParseError!AgentBundle {
    const max_size: usize = 1 << 20; // 1 MiB max
    const file = std.fs.cwd().openFile(path, .{}) catch return ParseError.InvalidJson;
    defer file.close();
    const data = file.readToEndAlloc(allocator, max_size) catch return ParseError.InvalidJson;
    defer allocator.free(data);
    return parseJson(allocator, data);
}

// ─── Teste ────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "AgentConfig defaults" {
    const cfg = AgentConfig.defaults("alpha", 1);
    try testing.expectEqualStrings("alpha", cfg.getName());
    try testing.expectEqual(@as(u32, 1), cfg.wallet_index);
    try testing.expectEqual(Strategy.conservative, cfg.strategy);
    try testing.expect(cfg.auto_tier);
    try testing.expect(cfg.auto_claim_faucet);
}

test "Strategy.fromString" {
    try testing.expectEqual(Strategy.balanced, Strategy.fromString("balanced").?);
    try testing.expectEqual(Strategy.market_maker, Strategy.fromString("market_maker").?);
    try testing.expect(Strategy.fromString("nonsense") == null);
}

test "addPair / getPair" {
    var cfg = AgentConfig.defaults("a", 1);
    try cfg.addPair("BTC/USD");
    try cfg.addPair("ETH/USD");
    try testing.expectEqualStrings("BTC/USD", cfg.getPair(0));
    try testing.expectEqualStrings("ETH/USD", cfg.getPair(1));
    try testing.expectEqual(@as(u8, 2), cfg.pairs_count);
}

test "addRule rejects invalid amount_pct" {
    var cfg = AgentConfig.defaults("a", 1);
    try testing.expectError(error.InvalidAmountPct, cfg.addRule(.{
        .metric = .btc_drop_1h_pct,
        .op = .gte,
        .threshold = 5.0,
        .action = .buy,
        .amount_pct = 0,
    }));
    try testing.expectError(error.InvalidAmountPct, cfg.addRule(.{
        .metric = .btc_drop_1h_pct,
        .op = .gte,
        .threshold = 5.0,
        .action = .buy,
        .amount_pct = 101,
    }));
}

test "parseJson — agent simplu" {
    const json =
        \\{ "agents": [
        \\    { "name": "alpha", "wallet_index": 1, "strategy": "balanced",
        \\      "auto_tier": true, "tick_ms": 3000,
        \\      "pairs": ["BTC/USD", "ETH/USD"],
        \\      "risk": { "max_trade_pct": 3, "max_daily_loss_pct": 8 } }
        \\] }
    ;
    const bundle = try parseJson(testing.allocator, json);
    try testing.expectEqual(@as(u8, 1), bundle.count);
    const a = bundle.agents[0];
    try testing.expectEqualStrings("alpha", a.getName());
    try testing.expectEqual(@as(u32, 1), a.wallet_index);
    try testing.expectEqual(Strategy.balanced, a.strategy);
    try testing.expectEqual(@as(u32, 3000), a.tick_ms);
    try testing.expectEqual(@as(u8, 2), a.pairs_count);
    try testing.expectEqual(@as(u8, 3), a.risk.max_trade_pct);
}

test "parseJson — rule completa" {
    const json =
        \\{ "agents": [
        \\    { "name": "r", "wallet_index": 2, "strategy": "aggressive",
        \\      "rules": [
        \\        { "metric": "btc_drop_1h_pct", "op": "gte", "threshold": 5.0,
        \\          "action": "buy", "amount_pct": 10 },
        \\        { "metric": "pnl_session_omni", "op": "lte", "threshold": -50.0,
        \\          "action": "halt", "amount_pct": 100 }
        \\      ] }
        \\] }
    ;
    const bundle = try parseJson(testing.allocator, json);
    const a = bundle.agents[0];
    try testing.expectEqual(@as(u8, 2), a.rules_count);
    try testing.expectEqual(Metric.btc_drop_1h_pct, a.rules[0].metric);
    try testing.expectEqual(Op.gte, a.rules[0].op);
    try testing.expectEqual(Action.buy, a.rules[0].action);
    try testing.expectEqual(@as(u8, 10), a.rules[0].amount_pct);
    try testing.expectEqual(Action.halt, a.rules[1].action);
}

test "parseJson — strategy necunoscuta returneaza eroare" {
    const json =
        \\{ "agents": [ { "name": "x", "strategy": "yolo" } ] }
    ;
    try testing.expectError(ParseError.UnknownStrategy, parseJson(testing.allocator, json));
}
