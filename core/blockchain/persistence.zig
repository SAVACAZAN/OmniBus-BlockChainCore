// Persistence helpers for the Blockchain struct.
//
// Extracted from blockchain.zig as part of the file-size cleanup. Two concerns
// live here:
//   1) Whole-chain auto-save via PersistentBlockchain (checkAutoSave/saveToDisc).
//   2) PQ identity sidecar log (data/<chain>/pq_identities.jsonl) — replayed
//      at startup so first-claim-wins pq_attest_v1 records survive restarts.
//
// Pattern: free functions taking `*Blockchain`. Thin delegating method shims
// stay on the struct in blockchain.zig so external callers (bc.saveToDisc(),
// blockchain_mod.loadPqIdentitiesFromDisk, etc.) keep working.

const std = @import("std");
const blockchain_mod = @import("../blockchain.zig");

const Blockchain  = blockchain_mod.Blockchain;
const PqIdentity  = blockchain_mod.PqIdentity;

// ── Whole-chain auto-save ───────────────────────────────────────────────────

/// Trigger a save when block- or tx-since-last-save thresholds are exceeded.
/// No-op if no persistent_db is attached (unit tests).
pub fn checkAutoSave(self: *Blockchain) void {
    const BLOCK_THRESHOLD: u32 = 100;
    const TX_THRESHOLD: u32 = 1000;
    if (self.blocks_since_save >= BLOCK_THRESHOLD or self.txs_since_save >= TX_THRESHOLD) {
        if (self.persistent_db != null) {
            saveToDisc(self) catch |err| {
                std.debug.print("[AUTOSAVE] saveToDisc failed: {}\n", .{err});
            };
        }
        self.blocks_since_save = 0;
        self.txs_since_save = 0;
    }
}

/// Save full blockchain state to disc via PersistentBlockchain.
/// No-op if persistent_db has not been attached (e.g. in unit tests).
///
/// Thread-safety: takes self.mutex for the duration of the write. The
/// background save thread (g_state_save_thread in main.zig) calls this
/// every 30 s as backup, plus the mining loop calls it after every block
/// for primary persistence; the mining loop holds the mutex briefly to
/// apply each block's TXs, so the saver and the miner serialise cleanly.
pub fn saveToDisc(self: *Blockchain) !void {
    const pdb = self.persistent_db orelse return;
    self.mutex.lock();
    defer self.mutex.unlock();
    try pdb.saveBlockchain(self, self.db_path);
    // Update bookkeeping so a graceful-shutdown save reports fresh numbers.
    self.last_save_time = std.time.timestamp();
    self.blocks_since_save = 0;
    self.txs_since_save = 0;
    std.debug.print("[DB] Auto-saved: {d} blocks, {d} addresses\n", .{ self.chain.items.len, self.balances.count() });
}

// ── PQ identity persistence ─────────────────────────────────────────────────
// pq_identity_map needs to survive restarts. We append-only-log every accepted
// pq_attest_v1 to a JSONL sidecar file at data/<chain>/pq_identities.jsonl,
// then re-hydrate the in-memory map at startup (see loadPqIdentitiesFromDisk
// below — called from main.zig after database restore).

var g_pq_persist_path_buf: [512]u8 = @splat(0);
var g_pq_persist_path_len: usize = 0;
var g_pq_persist_mutex: std.Thread.Mutex = .{};

pub fn pqPersistSetPath(path: []const u8) void {
    g_pq_persist_mutex.lock();
    defer g_pq_persist_mutex.unlock();
    const n = @min(path.len, g_pq_persist_path_buf.len);
    @memcpy(g_pq_persist_path_buf[0..n], path[0..n]);
    g_pq_persist_path_len = n;
}

fn pqPersistPath() ?[]const u8 {
    if (g_pq_persist_path_len == 0) return null;
    return g_pq_persist_path_buf[0..g_pq_persist_path_len];
}

pub fn persistPqIdentityAppend(alloc: std.mem.Allocator, from: []const u8, idt: *const PqIdentity) void {
    g_pq_persist_mutex.lock();
    defer g_pq_persist_mutex.unlock();
    const path = pqPersistPath() orelse return;

    const f = std.fs.cwd().createFile(path, .{ .truncate = false, .read = false }) catch |err| {
        std.debug.print("[PQ-IDENT] persist open {s} failed: {}\n", .{ path, err });
        return;
    };
    defer f.close();
    f.seekFromEnd(0) catch return;

    // Layout:
    //  {"from":"...","love":"...","food":"...","rent":"...","vacation":"...",
    //   "btc":"...","eth":"...","attest_block":N,"attest_tx":"..."}\n
    var buf = std.array_list.Managed(u8).init(alloc);
    defer buf.deinit();
    buf.writer().print(
        "{{\"from\":\"{s}\",\"love\":\"{s}\",\"food\":\"{s}\",\"rent\":\"{s}\",\"vacation\":\"{s}\"," ++
        "\"btc\":\"{s}\",\"eth\":\"{s}\",\"attest_block\":{d},\"attest_tx\":\"{s}\"}}\n",
        .{
            from,
            idt.loveSlice(), idt.foodSlice(), idt.rentSlice(), idt.vacationSlice(),
            idt.btcSlice(), idt.ethSlice(),
            idt.attest_block, idt.attestTxSlice(),
        },
    ) catch return;
    _ = f.writeAll(buf.items) catch |err| {
        std.debug.print("[PQ-IDENT] append failed: {}\n", .{err});
    };
}

/// Reload pq_identity_map from the JSONL sidecar. Called once at startup
/// after the database restore. Idempotent — duplicate `from` entries are
/// silently skipped (first-claim wins, matches on-chain semantics).
pub fn loadPqIdentitiesFromDisk(bc: *Blockchain, path: []const u8) !void {
    pqPersistSetPath(path);
    const f = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer f.close();
    const stat = try f.stat();
    if (stat.size == 0) return;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const buf = try arena.allocator().alloc(u8, @intCast(stat.size));
    _ = try f.readAll(buf);

    var lines = std.mem.splitScalar(u8, buf, '\n');
    var loaded: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const from = extractJsonStr(line, "\"from\":\"") orelse continue;
        if (bc.pq_identity_map.contains(from)) continue;

        var ident = PqIdentity{};
        if (extractJsonStr(line, "\"love\":\""))     |s| { copyToFixed(&ident.love,     &ident.love_len,     s); }
        if (extractJsonStr(line, "\"food\":\""))     |s| { copyToFixed(&ident.food,     &ident.food_len,     s); }
        if (extractJsonStr(line, "\"rent\":\""))     |s| { copyToFixed(&ident.rent,     &ident.rent_len,     s); }
        if (extractJsonStr(line, "\"vacation\":\"")) |s| { copyToFixed(&ident.vacation, &ident.vacation_len, s); }
        if (extractJsonStr(line, "\"btc\":\""))      |s| { copyToFixed(&ident.btc,      &ident.btc_len,      s); }
        if (extractJsonStr(line, "\"eth\":\""))      |s| { copyToFixed(&ident.eth,      &ident.eth_len,      s); }
        if (extractJsonStr(line, "\"attest_tx\":\"")) |s| {
            const c = @min(s.len, ident.attest_tx.len - 1);
            @memcpy(ident.attest_tx[0..c], s[0..c]);
            ident.attest_tx_len = @intCast(c);
        }
        if (extractJsonU64(line, "\"attest_block\":")) |n| ident.attest_block = n;

        const owned = bc.allocator.dupe(u8, from) catch continue;
        bc.pq_identity_map.put(owned, ident) catch {
            bc.allocator.free(owned);
            continue;
        };
        loaded += 1;
    }
    std.debug.print("[PQ-IDENT] Loaded {d} identity record(s) from {s}\n", .{ loaded, path });
}

pub fn extractJsonStr(line: []const u8, key: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    const from = start + key.len;
    if (from >= line.len) return null;
    const end = std.mem.indexOfScalarPos(u8, line, from, '"') orelse return null;
    return line[from..end];
}

pub fn extractJsonU64(line: []const u8, key: []const u8) ?u64 {
    const start = std.mem.indexOf(u8, line, key) orelse return null;
    const from = start + key.len;
    var end = from;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {}
    if (end == from) return null;
    return std.fmt.parseInt(u64, line[from..end], 10) catch null;
}

pub fn copyToFixed(buf: []u8, len_field: *u8, src: []const u8) void {
    const c = @min(src.len, buf.len);
    @memcpy(buf[0..c], src[0..c]);
    len_field.* = @intCast(c);
}
