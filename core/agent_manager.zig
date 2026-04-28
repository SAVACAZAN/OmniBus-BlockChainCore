/// agent_manager.zig — Manager pentru AI Agents inregistrati pe nod
///
/// Tine evidenta agentilor activi (cei incarcati din `agent.json` sau prin RPC).
/// Fiecare agent are: config, executor, last_decision, statistici cumulate.
///
/// Caller-ul (main.zig) apeleaza `tickAll(oracle, block_height)` la intervale
/// regulate — managerul itereaza si decide pentru fiecare agent. Decizia
/// returnata e apoi semnata si trimisa de caller.
///
/// NB: Vechiul fisier `agent/agent_manager.zig` (standalone, cu main())
/// ramane intact pentru compat. Acest modul e versiunea integrata in nod.

const std = @import("std");
const tier_mod = @import("agent_tier.zig");
const cfg_mod = @import("agent_config.zig");
const exec_mod = @import("agent_executor.zig");
const agent_wallet_mod = @import("agent_wallet.zig");

pub const AgentConfig = cfg_mod.AgentConfig;
pub const AgentBundle = cfg_mod.AgentBundle;
pub const AgentExecutor = exec_mod.AgentExecutor;
pub const Decision = exec_mod.Decision;
pub const DecisionKind = exec_mod.DecisionKind;
pub const OracleSnapshot = exec_mod.OracleSnapshot;
pub const Tier = tier_mod.Tier;
pub const TierTransition = tier_mod.TierTransition;
pub const MinerWallet = agent_wallet_mod.MinerWallet;

pub const MAX_AGENTS: usize = cfg_mod.MAX_AGENTS_PER_NODE;
pub const MAX_ADDRESS_LEN: usize = 96;
/// Cate decizii non-native pot astepta in queue inainte ca clientul extern
/// sa le ridice. Daca queue-ul e plin, decizii noi sunt scapate (drop oldest).
pub const MAX_PENDING_DECISIONS: usize = 256;
pub const Venue = exec_mod.Venue;

/// Decizie pending in queue — astepta sa fie ridicata de un client extern
/// prin RPC `agent_pending_decisions`. Dupa ce clientul executa, raporteaza
/// rezultatul prin RPC `agent_report_execution` cu acelasi `id`.
pub const PendingDecision = struct {
    /// ID unic, monotonic crescator. Folosit ca handle pentru report.
    id: u64,
    /// Wallet index al agentului care a emis decizia.
    wallet_index: u32,
    /// Inaltimea blocului cand a fost emisa decizia.
    block_height: u64,
    /// Timestamp ms al emisiunii.
    emitted_ms: i64,
    /// Decizia in sine.
    decision: Decision,
    /// True dupa ce clientul a confirmat executia (success sau fail).
    settled: bool = false,
};

pub const ExecStatus = enum(u8) {
    /// Executat cu succes pe venue extern.
    success = 0,
    /// Esec — venue a respins ordinul (insufficient funds, market closed, etc.).
    rejected = 1,
    /// Eroare retea — clientul reincearca.
    network_error = 2,
    /// Timeout — clientul nu a primit ack in timpul X.
    timeout = 3,
    /// Cancelled de user inainte sa fie executat.
    cancelled = 4,
};

/// Receipt de la clientul extern dupa executie.
pub const ExecReceipt = struct {
    /// ID-ul decision-ului raportat.
    decision_id: u64,
    /// Status final.
    status: ExecStatus,
    /// TX/order ID extern (de pe Coinbase/LCX/Kraken). Buffer fix.
    external_id_buf: [64]u8 = std.mem.zeroes([64]u8),
    external_id_len: u8 = 0,
    /// Suma efectiv executata (poate diferi de amount_sat din decision pe slippage).
    filled_amount_sat: u64 = 0,
    /// Pret efectiv obtinut, in micro-USD (price * 1_000_000).
    fill_price_micro_usd: u64 = 0,
    /// Mesaj de eroare (gol pentru success). Buffer fix.
    error_msg_buf: [128]u8 = std.mem.zeroes([128]u8),
    error_msg_len: u8 = 0,
    /// Cand a fost raportat.
    reported_ms: i64 = 0,

    pub fn getExternalId(self: *const ExecReceipt) []const u8 {
        return self.external_id_buf[0..self.external_id_len];
    }
    pub fn getErrorMsg(self: *const ExecReceipt) []const u8 {
        return self.error_msg_buf[0..self.error_msg_len];
    }
    pub fn setExternalId(self: *ExecReceipt, s: []const u8) void {
        const len = @min(s.len, self.external_id_buf.len);
        @memcpy(self.external_id_buf[0..len], s[0..len]);
        self.external_id_len = @intCast(len);
    }
    pub fn setErrorMsg(self: *ExecReceipt, s: []const u8) void {
        const len = @min(s.len, self.error_msg_buf.len);
        @memcpy(self.error_msg_buf[0..len], s[0..len]);
        self.error_msg_len = @intCast(len);
    }
};

/// Statistici cumulate pentru un agent — vizibile prin RPC `agent_status`.
pub const AgentStats = struct {
    /// Numarul total de tick-uri.
    ticks: u64 = 0,
    /// Decizii non-NoOp emise.
    decisions_emitted: u64 = 0,
    /// TX-uri trimise spre mempool de caller (incrementate de afara prin
    /// `recordSubmittedTx`).
    txs_submitted: u64 = 0,
    /// Tranzitii tier reusite.
    tier_transitions: u32 = 0,
    /// Recompense de minat acumulate (caller raporteaza prin `recordReward`).
    total_mined_sat: u64 = 0,
    /// Decizii puse in queue pentru execution extern (LCX/Kraken/Coinbase/DEX).
    decisions_queued: u64 = 0,
    /// Decizii executate cu succes pe venue extern.
    exec_success: u64 = 0,
    /// Decizii respinse / esuate pe venue extern.
    exec_failed: u64 = 0,
};

/// Slot per agent — config + executor + stats + ultimul decision.
pub const AgentSlot = struct {
    /// Activ in slot (false = slot liber).
    used: bool = false,
    config: AgentConfig = .{},
    /// Adresa wallet derivata (bech32). Buffer fix ca sa nu cerem allocator.
    address_buf: [MAX_ADDRESS_LEN]u8 = std.mem.zeroes([MAX_ADDRESS_LEN]u8),
    address_len: u8 = 0,
    /// Wallet propriu derivat din mnemonic + wallet_index (BIP-44 m/44'/777'/0'/0/N).
    /// Null daca a fost adaugat fara mnemonic (compat: doar adresa, fara semnare TX).
    wallet: ?MinerWallet = null,
    executor: AgentExecutor = undefined,
    stats: AgentStats = .{},
    last_decision: Decision = exec_mod.NoOp,
    last_transition: ?TierTransition = null,

    pub fn getAddress(self: *const AgentSlot) []const u8 {
        return self.address_buf[0..self.address_len];
    }

    /// Poate semna TX? (true = wallet derivat din mnemonic disponibil).
    pub fn canSign(self: *const AgentSlot) bool {
        return self.wallet != null;
    }

    fn setAddress(self: *AgentSlot, addr: []const u8) void {
        const len = @min(addr.len, MAX_ADDRESS_LEN);
        @memcpy(self.address_buf[0..len], addr[0..len]);
        self.address_len = @intCast(len);
    }
};

pub const ManagerError = error{
    NoSlotAvailable,
    DuplicateWalletIndex,
    AgentNotFound,
};

/// Manager fara allocator — slot array fix de MAX_AGENTS.
pub const AgentManager = struct {
    slots: [MAX_AGENTS]AgentSlot = std.mem.zeroes([MAX_AGENTS]AgentSlot),

    /// Queue ring de decizii pending — clientul extern le ridica prin RPC.
    /// `pending_used[i]` = true daca slotul are decizie nesettled.
    pending: [MAX_PENDING_DECISIONS]PendingDecision = std.mem.zeroes([MAX_PENDING_DECISIONS]PendingDecision),
    pending_used: [MAX_PENDING_DECISIONS]bool = [_]bool{false} ** MAX_PENDING_DECISIONS,
    /// Index unde se va pune urmatoarea decizie (round-robin overwrite oldest settled).
    pending_head: usize = 0,
    /// ID monotonic crescator pentru fiecare decizie pusa in queue.
    next_decision_id: u64 = 1,

    pub fn init() AgentManager {
        return .{};
    }

    /// Adauga un agent cu wallet derivat din mnemonic + config.wallet_index.
    /// Aceasta e calea recomandata — agentul va putea semna TX native automat.
    /// Caller-ul (main.zig) cunoaste mnemonic-ul nodului si il pasa o singura
    /// data la incarcarea config-ului.
    pub fn addAgentFromMnemonic(
        self: *AgentManager,
        config: AgentConfig,
        mnemonic: []const u8,
        allocator: std.mem.Allocator,
    ) !*AgentSlot {
        // Detecteaza wallet_index duplicat.
        for (self.slots) |s| {
            if (s.used and s.config.wallet_index == config.wallet_index) {
                return ManagerError.DuplicateWalletIndex;
            }
        }
        // Derivare BIP-44 m/44'/777'/0'/0/wallet_index.
        const w = try agent_wallet_mod.deriveAgentWallet(mnemonic, config.wallet_index, allocator);
        for (&self.slots) |*s| {
            if (!s.used) {
                s.used = true;
                s.config = config;
                s.setAddress(w.getAddress());
                s.wallet = w;
                s.executor = AgentExecutor.init(config, s.getAddress());
                s.stats = .{};
                s.last_decision = exec_mod.NoOp;
                s.last_transition = null;
                return s;
            }
        }
        return ManagerError.NoSlotAvailable;
    }

    /// Adauga un agent fara wallet propriu (compat). Adresa e furnizata de caller.
    /// Agentul nu va putea semna TX native — se foloseste pentru testing
    /// sau pentru agenti read-only (statistici doar, fara executie).
    pub fn addAgent(self: *AgentManager, config: AgentConfig, address: []const u8) ManagerError!*AgentSlot {
        // Detecteaza wallet_index duplicat.
        for (self.slots) |s| {
            if (s.used and s.config.wallet_index == config.wallet_index) {
                return ManagerError.DuplicateWalletIndex;
            }
        }
        for (&self.slots) |*s| {
            if (!s.used) {
                s.used = true;
                s.config = config;
                s.setAddress(address);
                s.executor = AgentExecutor.init(config, s.getAddress());
                s.stats = .{};
                s.last_decision = exec_mod.NoOp;
                s.last_transition = null;
                return s;
            }
        }
        return ManagerError.NoSlotAvailable;
    }

    /// Adauga toti agentii dintr-un bundle. Caller-ul deriva adresele
    /// si le pasea prin callback `deriveAddr(wallet_index, out_buf) -> usize`.
    /// Returneaza numarul de agenti adaugati cu succes.
    pub fn addBundle(
        self: *AgentManager,
        bundle: AgentBundle,
        ctx: anytype,
        comptime deriveAddr: fn (@TypeOf(ctx), u32, *[MAX_ADDRESS_LEN]u8) usize,
    ) u8 {
        var added: u8 = 0;
        for (bundle.agents[0..bundle.count]) |cfg| {
            var buf: [MAX_ADDRESS_LEN]u8 = undefined;
            const len = deriveAddr(ctx, cfg.wallet_index, &buf);
            _ = self.addAgent(cfg, buf[0..len]) catch continue;
            added += 1;
        }
        return added;
    }

    pub fn count(self: *const AgentManager) u8 {
        var c: u8 = 0;
        for (self.slots) |s| {
            if (s.used) c += 1;
        }
        return c;
    }

    pub fn findByWalletIndex(self: *AgentManager, idx: u32) ?*AgentSlot {
        for (&self.slots) |*s| {
            if (s.used and s.config.wallet_index == idx) return s;
        }
        return null;
    }

    pub fn findByName(self: *AgentManager, name: []const u8) ?*AgentSlot {
        for (&self.slots) |*s| {
            if (s.used and std.mem.eql(u8, s.config.getName(), name)) return s;
        }
        return null;
    }

    pub fn remove(self: *AgentManager, wallet_index: u32) ManagerError!void {
        if (self.findByWalletIndex(wallet_index)) |s| {
            s.used = false;
            return;
        }
        return ManagerError.AgentNotFound;
    }

    pub fn halt(self: *AgentManager, wallet_index: u32) ManagerError!void {
        if (self.findByWalletIndex(wallet_index)) |s| {
            s.executor.state.halted = true;
            return;
        }
        return ManagerError.AgentNotFound;
    }

    pub fn resume_(self: *AgentManager, wallet_index: u32) ManagerError!void {
        if (self.findByWalletIndex(wallet_index)) |s| {
            s.executor.state.halted = false;
            return;
        }
        return ManagerError.AgentNotFound;
    }

    /// Tick pentru un singur agent. Caller-ul actualizeaza balantele inainte.
    pub fn tickOne(self: *AgentManager, idx: usize, oracle: OracleSnapshot, block_height: u64) ?Decision {
        if (idx >= MAX_AGENTS) return null;
        const s = &self.slots[idx];
        if (!s.used) return null;

        if (s.executor.recomputeTier(block_height)) |tr| {
            s.last_transition = tr;
            s.stats.tier_transitions += 1;
        }

        const d = s.executor.tick(oracle);
        s.last_decision = d;
        s.stats.ticks += 1;
        if (d.kind != .none) s.stats.decisions_emitted += 1;
        s.executor.state.last_block_height = block_height;
        return d;
    }

    /// Pune o decizie non-native in queue pentru ridicare de catre clientul extern.
    /// Caller-ul (main.zig agentTickAll) decide ce intra aici (venue != .omnibus_native si != .none).
    /// Daca queue-ul e plin, suprascrie cea mai veche decizie SETTLED. Daca toate
    /// sunt nesettled, suprascrie cea mai veche (drop oldest unsettled).
    /// Returneaza id-ul atribuit, sau 0 daca operatia a esuat.
    pub fn queueDecision(self: *AgentManager, wallet_index: u32, block_height: u64, d: Decision) u64 {
        // Cauta slot liber sau slot settled.
        var target_idx: ?usize = null;
        var oldest_settled_idx: ?usize = null;
        var oldest_settled_id: u64 = std.math.maxInt(u64);

        for (0..MAX_PENDING_DECISIONS) |i| {
            if (!self.pending_used[i]) {
                target_idx = i;
                break;
            }
            if (self.pending[i].settled and self.pending[i].id < oldest_settled_id) {
                oldest_settled_id = self.pending[i].id;
                oldest_settled_idx = i;
            }
        }
        if (target_idx == null) target_idx = oldest_settled_idx;
        // Daca toate sunt unsettled, suprascrie pending_head (cel mai vechi prin convenție).
        if (target_idx == null) {
            target_idx = self.pending_head;
            self.pending_head = (self.pending_head + 1) % MAX_PENDING_DECISIONS;
        }

        const i = target_idx.?;
        const id = self.next_decision_id;
        self.next_decision_id += 1;
        self.pending[i] = .{
            .id = id,
            .wallet_index = wallet_index,
            .block_height = block_height,
            .emitted_ms = std.time.milliTimestamp(),
            .decision = d,
            .settled = false,
        };
        self.pending_used[i] = true;

        if (self.findByWalletIndex(wallet_index)) |s| {
            s.stats.decisions_queued += 1;
        }
        return id;
    }

    /// Cate decizii nesettled sunt in queue.
    pub fn pendingCount(self: *const AgentManager) usize {
        var c: usize = 0;
        for (0..MAX_PENDING_DECISIONS) |i| {
            if (self.pending_used[i] and !self.pending[i].settled) c += 1;
        }
        return c;
    }

    /// Snapshot decizii nesettled (pentru RPC `agent_pending_decisions`).
    /// Filtreaza optional dupa wallet_index. Returneaza numarul scris in `out`.
    pub fn snapshotPending(
        self: *const AgentManager,
        out: []PendingDecision,
        filter_wallet: ?u32,
    ) usize {
        var n: usize = 0;
        for (0..MAX_PENDING_DECISIONS) |i| {
            if (n >= out.len) break;
            if (!self.pending_used[i]) continue;
            if (self.pending[i].settled) continue;
            if (filter_wallet) |w| {
                if (self.pending[i].wallet_index != w) continue;
            }
            out[n] = self.pending[i];
            n += 1;
        }
        return n;
    }

    /// Aplica un receipt — marcheaza decizia ca settled si actualizeaza stats.
    /// Returneaza true daca decizia a fost gasita si actualizata.
    pub fn applyReceipt(self: *AgentManager, receipt: ExecReceipt) bool {
        for (0..MAX_PENDING_DECISIONS) |i| {
            if (!self.pending_used[i]) continue;
            if (self.pending[i].id != receipt.decision_id) continue;
            if (self.pending[i].settled) return false; // double-report
            self.pending[i].settled = true;

            const wi = self.pending[i].wallet_index;
            if (self.findByWalletIndex(wi)) |s| {
                switch (receipt.status) {
                    .success => s.stats.exec_success += 1,
                    .rejected, .network_error, .timeout, .cancelled => s.stats.exec_failed += 1,
                }
            }
            return true;
        }
        return false;
    }

    /// Inregistreaza ca o decizie a fost convertita in TX si trimisa.
    pub fn recordSubmittedTx(self: *AgentManager, wallet_index: u32) void {
        if (self.findByWalletIndex(wallet_index)) |s| {
            s.stats.txs_submitted += 1;
        }
    }

    /// Inregistreaza recompensa de minat primita de agent.
    pub fn recordReward(self: *AgentManager, wallet_index: u32, amount_sat: u64) void {
        if (self.findByWalletIndex(wallet_index)) |s| {
            s.stats.total_mined_sat += amount_sat;
        }
    }

    /// Snapshot al tuturor agentilor — folosit de RPC `agent_list`.
    pub fn snapshot(self: *const AgentManager, out: []AgentSnapshotItem) usize {
        var n: usize = 0;
        for (self.slots) |s| {
            if (!s.used) continue;
            if (n >= out.len) break;
            out[n] = .{
                .name_buf = s.config.name,
                .name_len = s.config.name_len,
                .wallet_index = s.config.wallet_index,
                .address_buf = s.address_buf,
                .address_len = s.address_len,
                .strategy = s.config.strategy,
                .tier = s.executor.state.tier,
                .balance_sat = s.executor.state.balance_sat,
                .staked_sat = s.executor.state.staked_sat,
                .lp_locked_sat = s.executor.state.lp_locked_sat,
                .pnl_session_sat = s.executor.state.pnl_session_sat,
                .halted = s.executor.state.halted,
                .stats = s.stats,
            };
            n += 1;
        }
        return n;
    }
};

/// Snapshot serializabil pentru RPC.
pub const AgentSnapshotItem = struct {
    name_buf: [cfg_mod.MAX_NAME_LEN]u8,
    name_len: u8,
    wallet_index: u32,
    address_buf: [MAX_ADDRESS_LEN]u8,
    address_len: u8,
    strategy: cfg_mod.Strategy,
    tier: Tier,
    balance_sat: u64,
    staked_sat: u64,
    lp_locked_sat: u64,
    pnl_session_sat: i64,
    halted: bool,
    stats: AgentStats,

    pub fn getName(self: *const AgentSnapshotItem) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn getAddress(self: *const AgentSnapshotItem) []const u8 {
        return self.address_buf[0..self.address_len];
    }
};

// ─── Teste ────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "AgentManager add + count + find" {
    var mgr = AgentManager.init();
    _ = try mgr.addAgent(AgentConfig.defaults("alpha", 1), "ob1q_alpha");
    _ = try mgr.addAgent(AgentConfig.defaults("beta", 2), "ob1q_beta");

    try testing.expectEqual(@as(u8, 2), mgr.count());

    const found = mgr.findByWalletIndex(1).?;
    try testing.expectEqualStrings("alpha", found.config.getName());
    try testing.expectEqualStrings("ob1q_alpha", found.getAddress());

    const by_name = mgr.findByName("beta").?;
    try testing.expectEqual(@as(u32, 2), by_name.config.wallet_index);
}

test "AgentManager rejects duplicate wallet_index" {
    var mgr = AgentManager.init();
    _ = try mgr.addAgent(AgentConfig.defaults("a", 1), "addr1");
    try testing.expectError(ManagerError.DuplicateWalletIndex, mgr.addAgent(AgentConfig.defaults("b", 1), "addr2"));
}

test "AgentManager remove + halt + resume" {
    var mgr = AgentManager.init();
    _ = try mgr.addAgent(AgentConfig.defaults("a", 1), "addr1");

    try mgr.halt(1);
    const s = mgr.findByWalletIndex(1).?;
    try testing.expect(s.executor.state.halted);

    try mgr.resume_(1);
    try testing.expect(!s.executor.state.halted);

    try mgr.remove(1);
    try testing.expectEqual(@as(u8, 0), mgr.count());
    try testing.expect(mgr.findByWalletIndex(1) == null);
}

test "tickOne emits decision and updates stats" {
    var mgr = AgentManager.init();
    var cfg = AgentConfig.defaults("a", 1);
    cfg.auto_claim_faucet = false;
    _ = try mgr.addAgent(cfg, "addr");
    const s = mgr.findByWalletIndex(1).?;
    s.executor.updateBalance(50_000_000_000, 0, 0, 0); // 50 OMNI = T1

    const d = mgr.tickOne(0, .{}, 100).?;
    try testing.expectEqual(DecisionKind.mine, d.kind);
    try testing.expectEqual(@as(u64, 1), s.stats.ticks);
    try testing.expectEqual(@as(u64, 1), s.stats.decisions_emitted);
}

test "tier transition counted" {
    var mgr = AgentManager.init();
    var cfg = AgentConfig.defaults("a", 1);
    cfg.auto_claim_faucet = false;
    _ = try mgr.addAgent(cfg, "addr");
    const s = mgr.findByWalletIndex(1).?;

    // T1 initial
    s.executor.updateBalance(50_000_000_000, 0, 0, 0);
    _ = mgr.tickOne(0, .{}, 1);
    try testing.expectEqual(@as(u32, 0), s.stats.tier_transitions);

    // Capital creste -> T2
    s.executor.updateBalance(150_000_000_000, 0, 0, 0);
    _ = mgr.tickOne(0, .{}, 2);
    try testing.expectEqual(@as(u32, 1), s.stats.tier_transitions);
    try testing.expectEqual(Tier.t2_staking, s.executor.state.tier);
}

test "snapshot returns visible agents only" {
    var mgr = AgentManager.init();
    _ = try mgr.addAgent(AgentConfig.defaults("a", 1), "addr1");
    _ = try mgr.addAgent(AgentConfig.defaults("b", 2), "addr2");

    var buf: [4]AgentSnapshotItem = undefined;
    const n = mgr.snapshot(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("a", buf[0].getName());
    try testing.expectEqualStrings("b", buf[1].getName());
}

test "queueDecision + snapshotPending + applyReceipt cycle" {
    var mgr = AgentManager.init();
    _ = try mgr.addAgent(AgentConfig.defaults("a", 1), "addr1");

    var d = exec_mod.Decision{ .kind = .buy, .venue = .lcx, .amount_sat = 1_000_000 };
    d.setReason("test_buy_lcx");
    d.setPair("BTC/USD");

    const id1 = mgr.queueDecision(1, 100, d);
    try testing.expectEqual(@as(u64, 1), id1);
    try testing.expectEqual(@as(usize, 1), mgr.pendingCount());

    var buf: [16]PendingDecision = undefined;
    const n = mgr.snapshotPending(&buf, null);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u64, 1), buf[0].id);
    try testing.expectEqual(Venue.lcx, buf[0].decision.venue);
    try testing.expectEqualStrings("BTC/USD", buf[0].decision.getPair());

    // Stats updated
    const slot = mgr.findByWalletIndex(1).?;
    try testing.expectEqual(@as(u64, 1), slot.stats.decisions_queued);

    // Apply success receipt
    var r = ExecReceipt{ .decision_id = id1, .status = .success, .filled_amount_sat = 1_000_000 };
    r.setExternalId("LCX-ORDER-12345");
    try testing.expect(mgr.applyReceipt(r));

    try testing.expectEqual(@as(u64, 1), slot.stats.exec_success);
    try testing.expectEqual(@as(u64, 0), slot.stats.exec_failed);
    try testing.expectEqual(@as(usize, 0), mgr.pendingCount()); // settled
}

test "applyReceipt double-report rejected" {
    var mgr = AgentManager.init();
    _ = try mgr.addAgent(AgentConfig.defaults("a", 1), "addr1");

    const id = mgr.queueDecision(1, 1, .{ .kind = .buy, .venue = .lcx });
    const r = ExecReceipt{ .decision_id = id, .status = .success };
    try testing.expect(mgr.applyReceipt(r));
    try testing.expect(!mgr.applyReceipt(r)); // a doua oara — false
}

test "applyReceipt for unknown decision returns false" {
    var mgr = AgentManager.init();
    const r = ExecReceipt{ .decision_id = 999, .status = .success };
    try testing.expect(!mgr.applyReceipt(r));
}

test "snapshotPending filters by wallet_index" {
    var mgr = AgentManager.init();
    _ = try mgr.addAgent(AgentConfig.defaults("a", 1), "addr1");
    _ = try mgr.addAgent(AgentConfig.defaults("b", 2), "addr2");

    _ = mgr.queueDecision(1, 1, .{ .kind = .buy, .venue = .lcx });
    _ = mgr.queueDecision(2, 1, .{ .kind = .sell, .venue = .kraken });
    _ = mgr.queueDecision(1, 1, .{ .kind = .buy, .venue = .coinbase });

    var buf: [16]PendingDecision = undefined;
    const n_all = mgr.snapshotPending(&buf, null);
    try testing.expectEqual(@as(usize, 3), n_all);

    const n_w1 = mgr.snapshotPending(&buf, 1);
    try testing.expectEqual(@as(usize, 2), n_w1);

    const n_w2 = mgr.snapshotPending(&buf, 2);
    try testing.expectEqual(@as(usize, 1), n_w2);
}

test "addAgentFromMnemonic — derives wallet + sets address from BIP-44" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var mgr = AgentManager.init();
    const cfg1 = AgentConfig.defaults("alpha", 1);
    const cfg2 = AgentConfig.defaults("beta", 2);

    const slot1 = try mgr.addAgentFromMnemonic(cfg1, mnemonic, arena.allocator());
    const slot2 = try mgr.addAgentFromMnemonic(cfg2, mnemonic, arena.allocator());

    try testing.expect(slot1.canSign());
    try testing.expect(slot2.canSign());
    // Adresele trebuie sa difere (wallet_index diferit).
    try testing.expect(!std.mem.eql(u8, slot1.getAddress(), slot2.getAddress()));
    try testing.expect(std.mem.startsWith(u8, slot1.getAddress(), "ob1q"));
}

test "addAgent (legacy) — without mnemonic, canSign() is false" {
    var mgr = AgentManager.init();
    const slot = try mgr.addAgent(AgentConfig.defaults("a", 1), "ob1q_addr");
    try testing.expect(!slot.canSign());
}

test "rejected receipt counts as failed" {
    var mgr = AgentManager.init();
    _ = try mgr.addAgent(AgentConfig.defaults("a", 1), "addr1");
    const id = mgr.queueDecision(1, 1, .{ .kind = .buy, .venue = .lcx });

    var r = ExecReceipt{ .decision_id = id, .status = .rejected };
    r.setErrorMsg("insufficient funds");
    try testing.expect(mgr.applyReceipt(r));

    const slot = mgr.findByWalletIndex(1).?;
    try testing.expectEqual(@as(u64, 1), slot.stats.exec_failed);
    try testing.expectEqual(@as(u64, 0), slot.stats.exec_success);
}
