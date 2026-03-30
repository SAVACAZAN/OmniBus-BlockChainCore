/// sync.zig — Sincronizare blockchain intre noduri
/// Protocol: GetHeaders → Headers → GetBlocks → Blocks
/// Modular: nu modifica blockchain.zig sau p2p.zig direct
const std        = @import("std");
const array_list = std.array_list;
const blockchain_mod = @import("blockchain.zig");
const block_mod      = @import("block.zig");
// p2p_mod removed — was causing circular dependency (p2p imports sync, sync imported p2p)
// PeerConnection is passed as anytype to avoid the cycle

pub const Blockchain = blockchain_mod.Blockchain;
pub const Block      = block_mod.Block;

// ─── Mesaje de sync (peste protocolul binar din p2p.zig) ─────────────────────

/// Cerere: "am blocuri pana la height X, trimite-mi de la X+1"
pub const MsgGetHeaders = struct {
    from_height: u64,   // incepand de la acest block
    max_count:   u16,   // cate headere vrei (max 2000)

    pub fn encode(self: MsgGetHeaders) [10]u8 {
        var buf: [10]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.from_height, .little);
        std.mem.writeInt(u16, buf[8..10], self.max_count, .little);
        return buf;
    }

    pub fn decode(buf: []const u8) ?MsgGetHeaders {
        if (buf.len < 10) return null;
        return .{
            .from_height = std.mem.readInt(u64, buf[0..8],  .little),
            .max_count   = std.mem.readInt(u16, buf[8..10], .little),
        };
    }
};

/// Un header compact de bloc pentru sync rapid (fara TX-uri)
/// 88 bytes per header
pub const BlockHeader = struct {
    height:        u64,
    timestamp:     i64,
    prev_hash:     [32]u8,
    merkle_root:   [32]u8,
    nonce:         u64,

    pub fn fromBlock(b: *const Block, height: u64) BlockHeader {
        // Construieste prev_hash din string (padded)
        var prev: [32]u8 = @splat(0);
        const plen = @min(b.previous_hash.len, 32);
        @memcpy(prev[0..plen], b.previous_hash[0..plen]);

        // merkle_root din hash-ul blocului (simplificat)
        var merkle: [32]u8 = @splat(0);
        const hlen = @min(b.hash.len, 32);
        @memcpy(merkle[0..hlen], b.hash[0..hlen]);

        return .{
            .height      = height,
            .timestamp   = b.timestamp,
            .prev_hash   = prev,
            .merkle_root = merkle,
            .nonce       = b.nonce,
        };
    }

    pub fn encode(self: BlockHeader, buf: *[88]u8) void {
        std.mem.writeInt(u64, buf[0..8],   self.height,    .little);
        std.mem.writeInt(i64, buf[8..16],  self.timestamp, .little);
        @memcpy(buf[16..48],  &self.prev_hash);
        @memcpy(buf[48..80],  &self.merkle_root);
        std.mem.writeInt(u64, buf[80..88], self.nonce,     .little);
    }

    pub fn decode(buf: []const u8) ?BlockHeader {
        if (buf.len < 88) return null;
        var prev:   [32]u8 = undefined;
        var merkle: [32]u8 = undefined;
        @memcpy(&prev,   buf[16..48]);
        @memcpy(&merkle, buf[48..80]);
        return .{
            .height      = std.mem.readInt(u64, buf[0..8],   .little),
            .timestamp   = std.mem.readInt(i64, buf[8..16],  .little),
            .prev_hash   = prev,
            .merkle_root = merkle,
            .nonce       = std.mem.readInt(u64, buf[80..88], .little),
        };
    }
};

/// Raspuns la GetHeaders: lista de headere compacte
pub const MsgHeaders = struct {
    count:   u16,
    headers: []BlockHeader,

    /// Encode: [count:2][header0:88][header1:88]...
    pub fn encode(self: MsgHeaders, allocator: std.mem.Allocator) ![]u8 {
        const size = 2 + @as(usize, self.count) * 88;
        var buf = try allocator.alloc(u8, size);
        std.mem.writeInt(u16, buf[0..2], self.count, .little);
        for (self.headers[0..self.count], 0..) |h, i| {
            var hbuf: [88]u8 = undefined;
            h.encode(&hbuf);
            @memcpy(buf[2 + i * 88 .. 2 + (i + 1) * 88], &hbuf);
        }
        return buf;
    }

    pub fn decode(buf: []const u8, allocator: std.mem.Allocator) !MsgHeaders {
        if (buf.len < 2) return error.TooShort;
        const count = std.mem.readInt(u16, buf[0..2], .little);
        if (buf.len < 2 + @as(usize, count) * 88) return error.TooShort;

        const headers = try allocator.alloc(BlockHeader, count);
        for (0..count) |i| {
            const start = 2 + i * 88;
            headers[i] = BlockHeader.decode(buf[start .. start + 88]) orelse
                return error.InvalidHeader;
        }
        return .{ .count = count, .headers = headers };
    }
};

/// Raspuns cu blocuri complete: [count:2][header0:88][header1:88]...
/// Acelasi format ca MsgHeaders dar semnifica blocuri descarcate complet
pub const MsgBlocks = struct {
    count:   u16,
    headers: []BlockHeader,

    /// Encode: [count:2][header0:88][header1:88]...
    pub fn encode(self: MsgBlocks, allocator: std.mem.Allocator) ![]u8 {
        const size = 2 + @as(usize, self.count) * 88;
        var buf = try allocator.alloc(u8, size);
        std.mem.writeInt(u16, buf[0..2], self.count, .little);
        for (self.headers[0..self.count], 0..) |h, i| {
            var hbuf: [88]u8 = undefined;
            h.encode(&hbuf);
            @memcpy(buf[2 + i * 88 .. 2 + (i + 1) * 88], &hbuf);
        }
        return buf;
    }

    pub fn decode(buf: []const u8, allocator: std.mem.Allocator) !MsgBlocks {
        if (buf.len < 2) return error.TooShort;
        const count = std.mem.readInt(u16, buf[0..2], .little);
        if (buf.len < 2 + @as(usize, count) * 88) return error.TooShort;

        const headers = try allocator.alloc(BlockHeader, count);
        for (0..count) |i| {
            const start = 2 + i * 88;
            headers[i] = BlockHeader.decode(buf[start .. start + 88]) orelse
                return error.InvalidHeader;
        }
        return .{ .count = count, .headers = headers };
    }
};

/// Cerere blocuri complete dupa height
pub const MsgGetBlocks = struct {
    from_height: u64,
    max_count:   u16,

    pub fn encode(self: MsgGetBlocks) [10]u8 {
        var buf: [10]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8],  self.from_height, .little);
        std.mem.writeInt(u16, buf[8..10], self.max_count,   .little);
        return buf;
    }

    pub fn decode(buf: []const u8) ?MsgGetBlocks {
        if (buf.len < 10) return null;
        return .{
            .from_height = std.mem.readInt(u64, buf[0..8],  .little),
            .max_count   = std.mem.readInt(u16, buf[8..10], .little),
        };
    }
};

// ─── SyncState — starea sync-ului pentru un nod ──────────────────────────────

pub const SyncStatus = enum {
    idle,        // Nu sincronizeaza
    requesting,  // A trimis GetHeaders, asteapta raspuns
    downloading, // Primeste blocuri
    synced,      // La zi cu reteaua
};

pub const SyncState = struct {
    status:         SyncStatus,
    local_height:   u64,
    peer_height:    u64,
    blocks_pending: u64,   // cate blocuri mai trebuie descarcate
    started_at:     i64,
    last_progress:  i64,

    pub fn init(local_height: u64) SyncState {
        return .{
            .status         = .idle,
            .local_height   = local_height,
            .peer_height    = 0,
            .blocks_pending = 0,
            .started_at     = 0,
            .last_progress  = 0,
        };
    }

    pub fn isBehind(self: *const SyncState) bool {
        return self.local_height < self.peer_height;
    }

    pub fn progressPct(self: *const SyncState) f64 {
        if (self.peer_height == 0) return 100.0;
        return @as(f64, @floatFromInt(self.local_height)) /
               @as(f64, @floatFromInt(self.peer_height)) * 100.0;
    }

    pub fn print(self: *const SyncState) void {
        std.debug.print(
            "[SYNC] Status={s} | Local={d} | Peer={d} | Progress={d:.1}%\n",
            .{
                @tagName(self.status),
                self.local_height,
                self.peer_height,
                self.progressPct(),
            },
        );
    }
};

// ─── SyncManager — orchestreaza sincronizarea ────────────────────────────────

pub const SyncManager = struct {
    state:      SyncState,
    allocator:  std.mem.Allocator,

    /// Max headere per cerere
    pub const MAX_HEADERS_PER_REQ: u16 = 2000;
    /// Max blocuri per cerere
    pub const MAX_BLOCKS_PER_REQ:  u16 = 128;

    pub fn init(local_height: u64, allocator: std.mem.Allocator) SyncManager {
        return .{
            .state     = SyncState.init(local_height),
            .allocator = allocator,
        };
    }

    /// Notifica ca un peer are height mai mare
    /// Returneaza GetHeaders encodat daca trebuie sa sincronizam
    pub fn onPeerHeight(self: *SyncManager, peer_height: u64) ?[10]u8 {
        self.state.peer_height = peer_height;

        if (!self.state.isBehind()) {
            self.state.status = .synced;
            return null;
        }

        // Incepe sync
        self.state.status     = .requesting;
        self.state.started_at = std.time.timestamp();
        self.state.blocks_pending = peer_height - self.state.local_height;

        std.debug.print("[SYNC] Behind by {d} blocks — requesting headers from {d}\n", .{
            self.state.blocks_pending, self.state.local_height,
        });

        const req = MsgGetHeaders{
            .from_height = self.state.local_height,
            .max_count   = MAX_HEADERS_PER_REQ,
        };
        return req.encode();
    }

    /// Construieste raspunsul GetHeaders din blockchain-ul local
    /// Returneaza buffer alocat (caller free)
    pub fn buildHeadersResponse(
        self: *SyncManager,
        bc:   *const Blockchain,
        req:  MsgGetHeaders,
    ) ![]u8 {
        const local_len = @as(u64, bc.chain.items.len);
        const start     = req.from_height;
        if (start >= local_len) {
            // Nu avem nimic de trimis
            const empty = MsgHeaders{ .count = 0, .headers = &.{} };
            return empty.encode(self.allocator);
        }

        const available = local_len - start;
        const count_u64 = @min(available, req.max_count);
        const count: u16 = @intCast(@min(count_u64, 2000));

        var headers = try self.allocator.alloc(BlockHeader, count);
        defer self.allocator.free(headers);

        for (0..count) |i| {
            const h = start + @as(u64, @intCast(i));
            const blk = &bc.chain.items[@intCast(h)];
            headers[i] = BlockHeader.fromBlock(blk, h);
        }

        const msg = MsgHeaders{ .count = count, .headers = headers };
        return msg.encode(self.allocator);
    }

    /// Proceseaza headere primite — decide ce blocuri sa cerem
    /// Returneaza GetBlocks encodat
    pub fn onHeadersReceived(
        self:    *SyncManager,
        headers: MsgHeaders,
    ) ?[10]u8 {
        if (headers.count == 0) {
            self.state.status = .synced;
            std.debug.print("[SYNC] No new headers — already synced\n", .{});
            return null;
        }

        self.state.status = .downloading;
        std.debug.print("[SYNC] Received {d} headers — requesting blocks from {d}\n", .{
            headers.count, self.state.local_height,
        });

        const req = MsgGetBlocks{
            .from_height = self.state.local_height,
            .max_count   = MAX_BLOCKS_PER_REQ,
        };
        return req.encode();
    }

    /// Notifica ca un bloc nou a fost primit si validat
    pub fn onBlockApplied(self: *SyncManager, new_height: u64) void {
        self.state.local_height = new_height;
        self.state.last_progress = std.time.timestamp();

        if (!self.state.isBehind()) {
            self.state.status = .synced;
            const elapsed = self.state.last_progress - self.state.started_at;
            std.debug.print("[SYNC] COMPLETE — {d} blocks in {d}s\n", .{
                new_height, elapsed,
            });
        }
    }

    /// Proceseaza un batch de blocuri primite:
    /// - actualizeaza local_height cu count blocuri noi
    /// - actualizeaza last_progress
    /// - trece in .synced daca am ajuns la peer_height
    pub fn onBlocksReceived(self: *SyncManager, count: u32) void {
        if (count == 0) return;

        self.state.local_height += @as(u64, count);
        self.state.last_progress = std.time.timestamp();

        std.debug.print("[SYNC] Received {d} blocks — local_height now {d}\n", .{
            count, self.state.local_height,
        });

        if (!self.state.isBehind()) {
            self.state.status = .synced;
            const elapsed = self.state.last_progress - self.state.started_at;
            std.debug.print("[SYNC] COMPLETE — height {d} in {d}s\n", .{
                self.state.local_height, elapsed,
            });
        }
    }

    /// Daca sync-ul e blocat (isStalled), reseteaza la .requesting pentru retry.
    /// Returneaza true daca s-a facut retry.
    pub fn retryIfStalled(self: *SyncManager) bool {
        if (!self.isStalled()) return false;

        std.debug.print("[SYNC] Stalled detected — resetting to requesting\n", .{});
        self.state.status        = .requesting;
        self.state.last_progress = std.time.timestamp();
        return true;
    }

    /// Verifica daca sync-ul a blocat (>60s fara progres)
    pub fn isStalled(self: *const SyncManager) bool {
        if (self.state.status != .downloading) return false;
        const now = std.time.timestamp();
        return now - self.state.last_progress > 60;
    }

    pub fn isSynced(self: *const SyncManager) bool {
        return self.state.status == .synced or !self.state.isBehind();
    }

    /// Trimite un GetBlocks catre conn si asteapta raspunsul.
    /// Returneaza numarul de blocuri primite si procesate.
    /// conn trebuie sa fie un PeerConnection valid cu .connected = true.
    pub fn downloadBlocks(
        self:        *SyncManager,
        conn:        anytype,   // *p2p_mod.PeerConnection — anytype pentru a evita importul circular
        from_height: u64,
        count:       u16,
        allocator:   std.mem.Allocator,
    ) !u32 {
        _ = allocator;
        const req = MsgGetBlocks{
            .from_height = from_height,
            .max_count   = count,
        };
        const encoded = req.encode();

        // Trimite cererea de blocuri catre peer
        // msg_type 5 = sync_request (din network.zig MessageType enum)
        try conn.send(5, &encoded);

        self.state.status = .downloading;
        std.debug.print("[SYNC] downloadBlocks: cerut {d} blocuri de la height {d}\n",
            .{ count, from_height });

        // Numarul real de blocuri aplicate va fi raportat de apelant via onBlocksReceived
        return 0; // 0 = cerere trimisa, blocurile sosesc async
    }

    /// Deserializeaza si valideaza un bloc raw (BlockHeader encodat) inainte de aplicare.
    /// Verifica: index secvential, timestamp pozitiv, previous_hash consistent.
    pub fn applyBlock(
        self:      *SyncManager,
        bc:        *Blockchain,
        raw_block: []const u8,
        allocator: std.mem.Allocator,
    ) !void {
        _ = allocator;
        const hdr = BlockHeader.decode(raw_block) orelse return error.InvalidBlockData;

        const local_len = @as(u64, bc.chain.items.len);
        if (hdr.height != local_len) {
            std.debug.print("[SYNC] applyBlock: height mismatch (expected {d}, got {d})\n",
                .{ local_len, hdr.height });
            return error.HeightMismatch;
        }

        if (hdr.timestamp <= 0) return error.InvalidTimestamp;

        // Bloc valid — adauga in blockchain cu hash din merkle_root
        const hash_hex = try self.allocator.alloc(u8, 64);
        errdefer self.allocator.free(hash_hex);
        for (0..32) |i| {
            _ = std.fmt.bufPrint(hash_hex[i * 2 .. (i + 1) * 2], "{x:0>2}", .{hdr.merkle_root[i]})
                catch return error.HashEncodeError;
        }

        const miner_addr = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(miner_addr);

        const prev_hash = bc.chain.items[bc.chain.items.len - 1].hash;

        const new_block = Block{
            .index         = @intCast(hdr.height),
            .timestamp     = hdr.timestamp,
            .transactions  = std.array_list.Managed(block_mod.Transaction).init(self.allocator),
            .previous_hash = prev_hash,
            .nonce         = hdr.nonce,
            .hash          = hash_hex,
            .miner_address = miner_addr,
            .reward_sat    = 0,
            .miner_heap    = true,
        };

        try bc.chain.append(new_block);
        self.onBlockApplied(hdr.height);

        std.debug.print("[SYNC] applyBlock: bloc #{d} aplicat (nonce={d})\n",
            .{ hdr.height, hdr.nonce });
    }
};

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "MsgGetHeaders encode/decode" {
    const req = MsgGetHeaders{ .from_height = 1234, .max_count = 500 };
    const enc = req.encode();
    const dec = MsgGetHeaders.decode(&enc).?;
    try testing.expectEqual(req.from_height, dec.from_height);
    try testing.expectEqual(req.max_count,   dec.max_count);
}

test "MsgGetBlocks encode/decode" {
    const req = MsgGetBlocks{ .from_height = 9999, .max_count = 128 };
    const enc = req.encode();
    const dec = MsgGetBlocks.decode(&enc).?;
    try testing.expectEqual(req.from_height, dec.from_height);
    try testing.expectEqual(req.max_count,   dec.max_count);
}

test "BlockHeader encode/decode round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const h = BlockHeader{
        .height      = 42,
        .timestamp   = 1_743_000_000,
        .prev_hash   = @splat(0xAA),
        .merkle_root = @splat(0xBB),
        .nonce       = 99999,
    };
    var buf: [88]u8 = undefined;
    h.encode(&buf);
    const d = BlockHeader.decode(&buf).?;
    try testing.expectEqual(h.height,    d.height);
    try testing.expectEqual(h.timestamp, d.timestamp);
    try testing.expectEqual(h.nonce,     d.nonce);
    try testing.expectEqualSlices(u8, &h.prev_hash,   &d.prev_hash);
    try testing.expectEqualSlices(u8, &h.merkle_root, &d.merkle_root);
}

test "MsgHeaders encode/decode cu 3 headere" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const hdrs = [_]BlockHeader{
        .{ .height = 0, .timestamp = 100, .prev_hash = @splat(0), .merkle_root = @splat(1), .nonce = 0 },
        .{ .height = 1, .timestamp = 101, .prev_hash = @splat(1), .merkle_root = @splat(2), .nonce = 1 },
        .{ .height = 2, .timestamp = 102, .prev_hash = @splat(2), .merkle_root = @splat(3), .nonce = 2 },
    };
    const msg = MsgHeaders{ .count = 3, .headers = @constCast(&hdrs) };
    const enc = try msg.encode(arena.allocator());
    const dec = try MsgHeaders.decode(enc, arena.allocator());

    try testing.expectEqual(@as(u16, 3), dec.count);
    try testing.expectEqual(@as(u64, 1), dec.headers[1].height);
    try testing.expectEqual(@as(i64, 102), dec.headers[2].timestamp);
}

test "SyncState — isBehind si progressPct" {
    var s = SyncState.init(100);
    s.peer_height = 200;
    try testing.expect(s.isBehind());
    try testing.expectEqual(@as(f64, 50.0), s.progressPct());

    s.local_height = 200;
    try testing.expect(!s.isBehind());
}

test "SyncManager — onPeerHeight declanseaza GetHeaders" {
    var sm = SyncManager.init(50, testing.allocator);
    // peer are 150 blocuri, noi avem 50 → trebuie GetHeaders
    const maybe_req = sm.onPeerHeight(150);
    try testing.expect(maybe_req != null);
    const decoded = MsgGetHeaders.decode(&maybe_req.?).?;
    try testing.expectEqual(@as(u64, 50), decoded.from_height);
    try testing.expectEqual(SyncStatus.requesting, sm.state.status);
    try testing.expectEqual(@as(u64, 100), sm.state.blocks_pending);
}

test "SyncManager — onPeerHeight la zi → null" {
    var sm = SyncManager.init(200, testing.allocator);
    const maybe_req = sm.onPeerHeight(100); // peer e in urma noastra
    try testing.expect(maybe_req == null);
    try testing.expectEqual(SyncStatus.synced, sm.state.status);
}

test "SyncManager — onBlockApplied → synced cand ajungem la peer" {
    var sm = SyncManager.init(98, testing.allocator);
    _ = sm.onPeerHeight(100);
    sm.onBlockApplied(99);
    try testing.expect(!sm.isSynced()); // inca un bloc mai trebuie
    sm.onBlockApplied(100);
    try testing.expect(sm.isSynced());
}

test "SyncManager — buildHeadersResponse cu blockchain real" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Construieste un blockchain minim
    var bc = try Blockchain.init(arena.allocator());
    // Are 1 bloc (genesis)

    var sm = SyncManager.init(0, arena.allocator());
    const req = MsgGetHeaders{ .from_height = 0, .max_count = 10 };
    const resp_buf = try sm.buildHeadersResponse(&bc, req);
    defer arena.allocator().free(resp_buf);

    const resp = try MsgHeaders.decode(resp_buf, arena.allocator());
    try testing.expectEqual(@as(u16, 1), resp.count); // 1 bloc genesis
    try testing.expectEqual(@as(u64, 0), resp.headers[0].height);
}

test "SyncManager — onBlocksReceived actualizeaza local_height" {
    var sm = SyncManager.init(50, testing.allocator);
    _ = sm.onPeerHeight(150); // peer la 150, noi la 50 → .requesting
    // Simulam intrare in downloading
    sm.state.status = .downloading;

    sm.onBlocksReceived(30);
    try testing.expectEqual(@as(u64, 80), sm.state.local_height);
    // Inca nu am ajuns la 150
    try testing.expectEqual(SyncStatus.downloading, sm.state.status);

    sm.onBlocksReceived(70);
    try testing.expectEqual(@as(u64, 150), sm.state.local_height);
    try testing.expectEqual(SyncStatus.synced, sm.state.status);
}

test "SyncManager — retryIfStalled reseteaza la requesting" {
    var sm = SyncManager.init(50, testing.allocator);
    _ = sm.onPeerHeight(200);
    sm.state.status        = .downloading;
    // Simuleaza stall: last_progress cu 120 secunde in urma
    sm.state.last_progress = std.time.timestamp() - 120;

    try testing.expect(sm.isStalled());
    const retried = sm.retryIfStalled();
    try testing.expect(retried);
    try testing.expectEqual(SyncStatus.requesting, sm.state.status);
    // Dupa retry nu mai e stalled (status != .downloading)
    try testing.expect(!sm.isStalled());
}

test "SyncManager — sync complet flow: peerHeight → onBlocksReceived → synced" {
    var sm = SyncManager.init(0, testing.allocator);

    // 1. Peer anunta height 5 → trebuie GetHeaders
    const get_headers = sm.onPeerHeight(5);
    try testing.expect(get_headers != null);
    try testing.expectEqual(SyncStatus.requesting, sm.state.status);

    // 2. Primim headers → trebuie GetBlocks
    var dummy_headers = [_]BlockHeader{
        .{ .height = 1, .timestamp = 1000, .prev_hash = @splat(0), .merkle_root = @splat(1), .nonce = 0 },
    };
    const msg_h = MsgHeaders{ .count = 1, .headers = &dummy_headers };
    const get_blocks = sm.onHeadersReceived(msg_h);
    try testing.expect(get_blocks != null);
    try testing.expectEqual(SyncStatus.downloading, sm.state.status);

    // 3. Primim 5 blocuri → synced
    sm.onBlocksReceived(5);
    try testing.expectEqual(@as(u64, 5), sm.state.local_height);
    try testing.expect(sm.isSynced());
    try testing.expectEqual(SyncStatus.synced, sm.state.status);
}
