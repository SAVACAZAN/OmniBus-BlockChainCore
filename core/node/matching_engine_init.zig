//! core/node/matching_engine_init.zig
//!
//! Native DEX matching engine bootstrap extracted from main.zig.
//!
//! The MatchingEngine is ~3MB (10K orders × 2 sides + 1K fills). Allocated on
//! the heap (page_allocator → mmap on Linux) once at startup and shared
//! across RPC threads; mutex lives inside ServerCtx. `orders.jsonl` is
//! per-chain so testnet/regtest don't pollute each other's books.
//!
//! Two engines are spun up:
//!   - real  (disabled with OMNIBUS_EXCHANGE_OFF)
//!   - paper (disabled with OMNIBUS_PAPER_OFF)
//!
//! The `chain_subdir` selector ("mainnet"/"testnet"/"regtest") is built by
//! the caller from config flags. `orders_path_owned` (when non-null) is owned
//! by `allocator` and must be freed by the caller.

const std = @import("std");
const matching_mod = @import("../matching_engine.zig");

pub const RealEngineResult = struct {
    /// Heap-allocated engine (page_allocator) or null when disabled / OOM.
    engine: ?*matching_mod.MatchingEngine,
    /// Per-chain orders.jsonl path. Owned by `allocator`. Null when
    /// engine is disabled or path allocation failed (in-memory only).
    orders_path: ?[]u8,
};

/// Init the real matching engine + per-chain orders.jsonl path.
/// Prints the `[EXCHANGE] ...` banners verbatim from main.zig.
pub fn initRealEngine(
    allocator: std.mem.Allocator,
    chain_subdir: []const u8,
    exchange_disabled: bool,
) RealEngineResult {
    if (exchange_disabled) {
        std.debug.print("[EXCHANGE] disabled by OMNIBUS_EXCHANGE_OFF\n", .{});
        return .{ .engine = null, .orders_path = null };
    }
    // Use page_allocator for the 3MB MatchingEngine — it's a single
    // long-lived object and the gpa's small-bin path doesn't help. Goes
    // straight to mmap() on Linux which is what we want for big blocks.
    const page_alloc = std.heap.page_allocator;
    const maybe_e = page_alloc.create(matching_mod.MatchingEngine) catch null;
    if (maybe_e) |e| {
        // Zero the whole struct in place, then set the scalar fields.
        // `e.* = .init()` would materialize a 3MB temporary on the stack
        // and segfault. `@memset` is byte-wise so it can't blow the stack.
        const bytes = std.mem.asBytes(e);
        @memset(bytes, 0);
        e.next_order_id = 1;
        e.next_fill_id = 1;
        const orders_path = std.fmt.allocPrint(allocator, "data/{s}/orders.jsonl", .{chain_subdir}) catch null;
        if (orders_path) |p| {
            std.fs.cwd().makePath(std.fs.path.dirname(p) orelse ".") catch {};
            std.debug.print("[EXCHANGE] DEX matching engine ON — orders.jsonl: {s}\n", .{p});
        } else {
            std.debug.print("[EXCHANGE] DEX matching engine ON (in-memory only)\n", .{});
        }
        return .{ .engine = e, .orders_path = orders_path };
    }
    return .{ .engine = null, .orders_path = null };
}

/// Init the paper-trading matching engine (same shape, isolated state).
/// Lets users practice strategies with OMNI_DEMO without touching real
/// funds. Disabled with OMNIBUS_PAPER_OFF (rare — most nodes want it).
/// Skipped entirely when the real engine is disabled.
pub fn initPaperEngine(
    exchange_disabled: bool,
    paper_disabled: bool,
) ?*matching_mod.MatchingEngine {
    if (exchange_disabled or paper_disabled) return null;
    const page_alloc = std.heap.page_allocator;
    const maybe_e = page_alloc.create(matching_mod.MatchingEngine) catch null;
    if (maybe_e) |e| {
        const bytes = std.mem.asBytes(e);
        @memset(bytes, 0);
        e.next_order_id = 1;
        e.next_fill_id = 1;
        std.debug.print("[EXCHANGE] paper-trading engine ON\n", .{});
        return e;
    }
    return null;
}
