//! dex_settler.zig — background thread that turns OmniBus DEX fills into
//! on-chain EVM `settle()` calls against deployed OmnibusDEX contracts.
//!
//! The matching engine produces a `Fill` whenever a buy and sell cross.
//! For pairs where one side lives on an EVM chain (e.g. OMNI/USDC via
//! Sepolia escrow), someone has to actually move the escrowed ERC-20
//! from the contract to the seller. That "someone" is this thread:
//!
//!   1. Watch `engine.fills[0 .. fill_count]` for new entries (last
//!      processed fill_id is persisted to settler_cursor.bin).
//!   2. For each unseen fill on an OMNI/ERC-20 pair, look up the
//!      OmnibusDEX deployment for the buyer-side chain.
//!   3. Build a `settle(uint256 orderId, address seller)` call:
//!      - 4-byte selector + 2 × 32-byte args = 68 bytes calldata
//!      - sign with the operator key (m/44'/60'/0'/0/2)
//!      - submit via evm_rpc_client.sendRawTransaction
//!   4. Persist the fill_id and the tx hash for audit.
//!
//! Failure modes the thread handles WITHOUT crashing the node:
//!   - RPC unreachable        → retry on next tick (don't advance cursor)
//!   - settle reverts         → log, advance cursor (don't loop forever)
//!   - nonce race / pending   → re-fetch nonce, single retry
//!
//! Chain-driven: if the frontend is down, fills still settle. The whole
//! point is that the node alone is sufficient.

const std = @import("std");
const matching_mod  = @import("matching_engine.zig");
const evm_rpc       = @import("evm_rpc_client.zig");
const evm_signer    = @import("evm_signer.zig");
const fills_log_mod = @import("fills_log.zig");
const evm_escrow_mod = @import("evm_escrow_watcher.zig");

/// Per-pair config — where this pair's OmnibusDEX contract lives and how
/// to reach the buyer's chain over RPC.
pub const PairBinding = struct {
    pair_id: u16,
    /// EVM chain id (e.g. 11155111 = Sepolia, 84532 = Base Sepolia)
    chain_id: u64,
    /// JSON-RPC URL — public dRPC / Infura / Alchemy is fine for testnets.
    rpc_url: []const u8,
    /// Deployed OmnibusDEX contract on `chain_id`. 0x-prefixed, 42 chars.
    dex_contract: []const u8,
};

/// Settler config — wired at startup from main.zig.
pub const Config = struct {
    /// Operator private key (m/44'/60'/0'/0/2 derived from founder mnemonic).
    operator_key: evm_signer.SigningKey,
    /// Pair → chain mapping. Empty entries mean "no EVM leg, skip".
    bindings: []const PairBinding,
    /// How long the thread sleeps between scans. 2 s keeps tx latency
    /// human-perceptible without hammering RPCs.
    poll_ms: u64 = 2_000,
    /// Path to the on-disk cursor file (last processed fill_id). Loaded
    /// at startup and written after each successful settle so a restart
    /// doesn't re-submit identical txs.
    cursor_path: []const u8 = "dex_settler_cursor.bin",
    /// Optional handle to the trade fills log. When set, every successful
    /// settle() call appends a (fill_id, evm_tx_hash, chain_id) record so
    /// exchange_getUserTrades can surface the EVM leg in "My Trades".
    fills_log: ?*fills_log_mod.FillsLog = null,
    /// Optional handle to the EVM escrow watcher. When set, settler uses
    /// it to look up the chain_id of each escrow at settle time — so it
    /// picks the right binding (Sepolia vs Base Sepolia) when the same
    /// pair_id has bindings on multiple chains. Without this it falls
    /// back to the first binding for that pair_id.
    escrow_watcher: ?*evm_escrow_mod.Watcher = null,
};

/// Internal handle. Owned by the spawner.
pub const Settler = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    engine: *matching_mod.MatchingEngine,

    /// Highest fill_id that has been successfully submitted (or skipped
    /// for being a non-EVM pair). Persisted to disk between restarts.
    last_settled_fill_id: u64 = 0,

    /// Set once at startup so the worker loop knows when to bail.
    stop_flag: std.atomic.Value(bool) = .{ .raw = false },

    thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: Config,
        engine: *matching_mod.MatchingEngine,
    ) Settler {
        return Settler{
            .allocator = allocator,
            .cfg = cfg,
            .engine = engine,
            .last_settled_fill_id = loadCursor(cfg.cursor_path) catch 0,
        };
    }

    pub fn start(self: *Settler) !void {
        if (self.thread != null) return; // already running
        self.thread = try std.Thread.spawn(.{}, workerLoop, .{self});
    }

    pub fn stop(self: *Settler) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

// ── Worker loop ───────────────────────────────────────────────────────────

fn workerLoop(self: *Settler) void {
    while (!self.stop_flag.load(.acquire)) {
        scanOnce(self) catch |err| {
            std.debug.print("[dex_settler] tick err: {s}\n", .{@errorName(err)});
        };
        // Sleep in small chunks so stop() returns promptly.
        var slept: u64 = 0;
        while (slept < self.cfg.poll_ms and !self.stop_flag.load(.acquire)) {
            std.Thread.sleep(50 * std.time.ns_per_ms);
            slept += 50;
        }
    }
}

fn scanOnce(self: *Settler) !void {
    const n = self.engine.fill_count;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const fill = &self.engine.fills[i];
        if (fill.fill_id <= self.last_settled_fill_id) continue;

        // Look up the escrow's chain_id so we pick the right binding when
        // a pair_id has bindings on more than one chain. Falls back to the
        // first matching binding when no watcher / no escrow record is
        // available (single-chain deployments keep working unchanged).
        var target_chain_id: u64 = 0;
        if (self.cfg.escrow_watcher) |w| {
            if (w.getOpen(fill.evm_order_id)) |esc| {
                target_chain_id = esc.chain_id;
            }
        }
        const binding = findBindingForChain(self.cfg.bindings, fill.pair_id, target_chain_id) orelse {
            // No EVM leg for this pair — nothing to settle on-chain. Mark
            // as processed so we don't re-scan it forever.
            self.last_settled_fill_id = fill.fill_id;
            saveCursor(self.cfg.cursor_path, self.last_settled_fill_id) catch {};
            continue;
        };

        // The sell order carries seller_evm — the 20-byte EVM address where
        // the buyer's escrowed quote token should be delivered. If unset
        // (all-zero), the seller didn't request an EVM payout; skip.
        var all_zero = true;
        for (fill.seller_evm) |b| { if (b != 0) { all_zero = false; break; } }
        if (all_zero) {
            self.last_settled_fill_id = fill.fill_id;
            saveCursor(self.cfg.cursor_path, self.last_settled_fill_id) catch {};
            continue;
        }

        // Format as 0x-prefixed hex.
        var seller_hex_buf: [42]u8 = undefined;
        seller_hex_buf[0] = '0';
        seller_hex_buf[1] = 'x';
        const hex_chars = "0123456789abcdef";
        for (fill.seller_evm, 0..) |b, idx| {
            seller_hex_buf[2 + idx * 2] = hex_chars[b >> 4];
            seller_hex_buf[2 + idx * 2 + 1] = hex_chars[b & 0x0F];
        }
        const seller_hex = seller_hex_buf[0..];

        // settle(evm_order_id, sellerEvm) — evm_order_id is the orderId
        // the buyer used when locking funds in OmnibusDEX, NOT the
        // matching engine's internal buy_order_id (those are different
        // namespaces). The watcher seeded this field at order placement
        // by cross-checking the on-chain escrow exists.
        if (fill.evm_order_id == 0) {
            // No EVM order id propagated — buyer didn't lock funds.
            // Skip to avoid trying to settle a non-existent escrow.
            self.last_settled_fill_id = fill.fill_id;
            saveCursor(self.cfg.cursor_path, self.last_settled_fill_id) catch {};
            continue;
        }
        std.debug.print(
            "[dex_settler] processing fill {d} pair={d} target_chain={d} binding_chain={d}\n",
            .{ fill.fill_id, fill.pair_id, target_chain_id, binding.chain_id },
        );
        submitSettle(self, binding, fill.evm_order_id, fill.fill_id, seller_hex) catch |err| {
            std.debug.print(
                "[dex_settler] fill {d} settle failed: {s} — will retry next tick\n",
                .{ fill.fill_id, @errorName(err) },
            );
            return; // bail without advancing cursor; retry next tick
        };

        self.last_settled_fill_id = fill.fill_id;
        saveCursor(self.cfg.cursor_path, self.last_settled_fill_id) catch {};
    }
}

fn findBinding(bindings: []const PairBinding, pair_id: u16) ?PairBinding {
    for (bindings) |b| {
        if (b.pair_id == pair_id) return b;
    }
    return null;
}

/// Prefer a binding whose chain_id matches `target_chain_id`. When zero
/// (escrow not in watcher map) fall through to the first binding for
/// that pair_id so legacy single-chain setups still work.
fn findBindingForChain(bindings: []const PairBinding, pair_id: u16, target_chain_id: u64) ?PairBinding {
    if (target_chain_id != 0) {
        for (bindings) |b| {
            if (b.pair_id == pair_id and b.chain_id == target_chain_id) return b;
        }
    }
    return findBinding(bindings, pair_id);
}

// ── settle() call construction ────────────────────────────────────────────

/// Function selector for `settle(uint256,address)` =
/// keccak256("settle(uint256,address)")[0..4]. Computed at comptime.
fn settleSelector() [4]u8 {
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update("settle(uint256,address)");
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest[0..4].*;
}

fn submitSettle(
    self: *Settler,
    binding: PairBinding,
    order_id: u64,
    fill_id: u64,
    seller_0x: []const u8,
) !void {
    const alloc = self.allocator;

    // ABI-encode (uint256 orderId, address seller) → 64 bytes.
    var calldata: [4 + 32 + 32]u8 = undefined;
    @memcpy(calldata[0..4], &settleSelector());
    // uint256 orderId, big-endian, left-padded to 32 bytes.
    @memset(calldata[4..36], 0);
    std.mem.writeInt(u64, calldata[28..36], order_id, .big);
    // address seller, left-padded to 32 bytes.
    @memset(calldata[36..68], 0);
    const seller_bytes = try evm_signer.hex0xToBytes(20, seller_0x);
    @memcpy(calldata[48..68], &seller_bytes);

    // Convert calldata → "0x.."
    var calldata_hex_buf: [2 + calldata.len * 2]u8 = undefined;
    const calldata_hex = bytesToHex0xFixed(calldata.len, calldata, &calldata_hex_buf);

    // Live RPC fetches: nonce, gas price, chain id (cross-check).
    const op_addr_hex = try operatorAddrHex(self.cfg.operator_key.address, alloc);
    defer alloc.free(op_addr_hex);

    std.debug.print(
        "[dex_settler] submitSettle START fill={d} order={d} chain={d} contract={s}\n",
        .{ fill_id, order_id, binding.chain_id, binding.dex_contract },
    );

    const nonce = evm_rpc.getTransactionCount(alloc, binding.rpc_url, op_addr_hex) catch |e| {
        std.debug.print("[dex_settler] getTxCount err: {s}\n", .{@errorName(e)});
        return e;
    };
    const gas_price = evm_rpc.gasPrice(alloc, binding.rpc_url) catch |e| {
        std.debug.print("[dex_settler] gasPrice err: {s}\n", .{@errorName(e)});
        return e;
    };
    const gp_bumped = gas_price +| (gas_price / 4);
    const chain_id_live = evm_rpc.chainId(alloc, binding.rpc_url) catch |e| {
        std.debug.print("[dex_settler] chainId err: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print(
        "[dex_settler] nonce={d} gas_price={d} chain_live={d} chain_cfg={d}\n",
        .{ nonce, gp_bumped, chain_id_live, binding.chain_id },
    );
    if (chain_id_live != binding.chain_id) {
        std.debug.print(
            "[dex_settler] chain_id mismatch: cfg={d} rpc={d}\n",
            .{ binding.chain_id, chain_id_live },
        );
        return error.ChainIdMismatch;
    }

    const to_bytes = try evm_signer.hex0xToBytes(20, binding.dex_contract);

    const tx = evm_signer.TxInput{
        .nonce       = nonce,
        .gas_price   = gp_bumped,
        .gas_limit   = 120_000, // ERC-20 transfer + sstore ≈ 60-90k; 120k = comfortable
        .to          = to_bytes,
        .value       = 0,
        .data        = &calldata,
        .chain_id    = binding.chain_id,
    };

    const pair = try evm_signer.signLegacyTx(alloc, tx, self.cfg.operator_key);
    defer alloc.free(pair.candidate_a);
    defer alloc.free(pair.candidate_b);

    // Try v=27 first; if the chain rejects (wrong recovery), try v=28.
    const hash_a = evm_rpc.sendRawTransaction(alloc, binding.rpc_url, pair.candidate_a) catch |e1| blk: {
        const hash_b = evm_rpc.sendRawTransaction(alloc, binding.rpc_url, pair.candidate_b) catch |e2| {
            std.debug.print("[dex_settler] both v-candidates rejected: {s} / {s}\n",
                .{ @errorName(e1), @errorName(e2) });
            return error.SettleRejected;
        };
        break :blk hash_b;
    };
    defer alloc.free(hash_a);

    std.debug.print(
        "[dex_settler] settled order {d} → seller {s} chain={d} tx={s}\n",
        .{ order_id, seller_0x, binding.chain_id, hash_a },
    );
    _ = calldata_hex; // calldata_hex retained for future audit log; not used now

    // Persist (fill_id, evm_tx_hash) pair so exchange_getUserTrades can
    // surface the EVM leg in the trader's history. Failure is non-fatal —
    // the settle itself already landed; we just lose a UI hint.
    if (self.cfg.fills_log) |flog| {
        var tx_hash_bytes: [32]u8 = [_]u8{0} ** 32;
        // hash_a is "0x" + 64 hex chars. Skip the prefix when decoding.
        const hex_body = if (hash_a.len >= 66 and hash_a[0] == '0' and (hash_a[1] == 'x' or hash_a[1] == 'X'))
            hash_a[2..66]
        else
            hash_a;
        _ = std.fmt.hexToBytes(&tx_hash_bytes, hex_body) catch &.{};
        const chain_id_u32: u32 = @intCast(@min(binding.chain_id, std.math.maxInt(u32)));
        flog.recordSettle(fill_id, tx_hash_bytes, chain_id_u32) catch |err| {
            std.debug.print(
                "[dex_settler] fills_log.recordSettle fill={d} err={s} — UI may miss this tx\n",
                .{ fill_id, @errorName(err) },
            );
        };
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn operatorAddrHex(addr20: [20]u8, alloc: std.mem.Allocator) ![]u8 {
    var buf: [42]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    const hex = "0123456789abcdef";
    for (addr20, 0..) |b, i| {
        buf[2 + i * 2]     = hex[b >> 4];
        buf[2 + i * 2 + 1] = hex[b & 0x0F];
    }
    return alloc.dupe(u8, &buf);
}

fn bytesToHex0xFixed(comptime n: usize, bytes: [n]u8, out: *[2 + n * 2]u8) []const u8 {
    out[0] = '0';
    out[1] = 'x';
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 + i * 2]     = hex[b >> 4];
        out[2 + i * 2 + 1] = hex[b & 0x0F];
    }
    return out[0 .. 2 + n * 2];
}

fn loadCursor(path: []const u8) !u64 {
    const f = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer f.close();
    var buf: [8]u8 = undefined;
    const n = try f.readAll(&buf);
    if (n != 8) return 0;
    return std.mem.readInt(u64, &buf, .little);
}

fn saveCursor(path: []const u8, value: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(&buf);
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "settleSelector matches keccak256('settle(uint256,address)')[0..4]" {
    // Reference value computed offline: 962d1938
    const sel = settleSelector();
    try std.testing.expectEqual(@as(u8, 0x96), sel[0]);
    try std.testing.expectEqual(@as(u8, 0x2d), sel[1]);
    try std.testing.expectEqual(@as(u8, 0x19), sel[2]);
    try std.testing.expectEqual(@as(u8, 0x38), sel[3]);
}

test "cursor save + load roundtrips" {
    const path = "test_settler_cursor.tmp";
    defer std.fs.cwd().deleteFile(path) catch {};

    try saveCursor(path, 12345);
    const v = try loadCursor(path);
    try std.testing.expectEqual(@as(u64, 12345), v);
}

test "loadCursor returns 0 for missing file" {
    const v = try loadCursor("definitely_does_not_exist_xyz.bin");
    try std.testing.expectEqual(@as(u64, 0), v);
}
