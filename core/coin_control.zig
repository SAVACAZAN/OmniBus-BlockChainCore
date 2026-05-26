//! Coin Control — manual UTXO selection + freeze pentru OmniBus.
//!
//! Decuplat de core/utxo.zig: nu stocheaza UTXO-uri proprii, ci doar
//! seturi de outpoints (`txid:vout`) cu un status (frozen/reserved).
//! `core/utxo.zig::UTXOSet.selectUTXOs` interogheaza acest layer ca sa
//! sara peste UTXO-urile frozen/reserved, sau sa forteze o lista manuala.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Status = enum(u8) {
    normal = 0,
    frozen = 1,
    reserved = 2,
};

pub const Outpoint = struct {
    txid: [32]u8,
    vout: u32,

    pub fn key(self: Outpoint) [36]u8 {
        var out: [36]u8 = undefined;
        @memcpy(out[0..32], &self.txid);
        std.mem.writeInt(u32, out[32..36], self.vout, .little);
        return out;
    }
};

pub const Entry = struct {
    status: Status,
    /// Tx id (hex) pentru care e rezervat. owned, free la unreserve.
    reserved_for: ?[]u8 = null,
};

/// Layer simplu peste UTXOSet — tine status per outpoint plus o lista de
/// selectie manuala (override la coin selection automat).
pub const CoinControl = struct {
    allocator: Allocator,
    entries: std.AutoHashMap([36]u8, Entry),
    /// Cand non-null, selectUTXOs ignora greedy si foloseste DOAR aceste outpoints.
    manual_selection: ?std.ArrayList(Outpoint) = null,
    lock: std.Thread.RwLock = .{},

    pub fn init(allocator: Allocator) CoinControl {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap([36]u8, Entry).init(allocator),
        };
    }

    pub fn deinit(self: *CoinControl) void {
        var it = self.entries.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.reserved_for) |r| self.allocator.free(r);
        }
        self.entries.deinit();
        if (self.manual_selection) |*ms| {
            ms.deinit(self.allocator);
            self.manual_selection = null;
        }
    }

    pub fn freeze(self: *CoinControl, op: Outpoint) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const gop = try self.entries.getOrPut(op.key());
        if (!gop.found_existing) gop.value_ptr.* = .{ .status = .normal };
        gop.value_ptr.status = .frozen;
    }

    pub fn unfreeze(self: *CoinControl, op: Outpoint) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.entries.getPtr(op.key())) |e| {
            if (e.status == .frozen) e.status = .normal;
        }
    }

    pub fn isFrozen(self: *CoinControl, op: Outpoint) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.entries.get(op.key())) |e| return e.status == .frozen;
        return false;
    }

    pub fn isReserved(self: *CoinControl, op: Outpoint) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.entries.get(op.key())) |e| return e.status == .reserved;
        return false;
    }

    /// Marcheaza outpoints ca rezervate pentru un TX in zbor.
    /// Eroare daca vreun outpoint e deja rezervat pentru alt TX (sau frozen).
    pub fn reserve(self: *CoinControl, ops: []const Outpoint, tx_id_hex: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();

        for (ops) |op| {
            const k = op.key();
            if (self.entries.get(k)) |existing| {
                switch (existing.status) {
                    .frozen => return error.UtxoFrozen,
                    .reserved => {
                        if (existing.reserved_for) |r| {
                            if (!std.mem.eql(u8, r, tx_id_hex)) return error.UtxoReservedByOtherTx;
                        }
                    },
                    .normal => {},
                }
            }
        }

        // toate ok — aplica
        for (ops) |op| {
            const gop = try self.entries.getOrPut(op.key());
            if (!gop.found_existing) gop.value_ptr.* = .{ .status = .normal };
            if (gop.value_ptr.reserved_for) |old| self.allocator.free(old);
            gop.value_ptr.status = .reserved;
            gop.value_ptr.reserved_for = try self.allocator.dupe(u8, tx_id_hex);
        }
    }

    /// Elibereaza rezervarile asociate unui tx (ex: TX-ul a esuat / a fost dropped).
    pub fn release(self: *CoinControl, tx_id_hex: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();

        var it = self.entries.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.status == .reserved) {
                if (e.value_ptr.reserved_for) |r| {
                    if (std.mem.eql(u8, r, tx_id_hex)) {
                        self.allocator.free(r);
                        e.value_ptr.reserved_for = null;
                        e.value_ptr.status = .normal;
                    }
                }
            }
        }
    }

    /// Seteaza o lista de outpoints care vor fi folosite EXCLUSIV de coin selection.
    /// Daca user-ul cere selectie automata cu manual_selection setat, se foloseste lista asta.
    pub fn setManualSelection(self: *CoinControl, ops: []const Outpoint) !void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.manual_selection) |*ms| ms.deinit(self.allocator);
        var list: std.ArrayList(Outpoint) = .empty;
        try list.appendSlice(self.allocator, ops);
        self.manual_selection = list;
    }

    pub fn clearManualSelection(self: *CoinControl) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.manual_selection) |*ms| {
            ms.deinit(self.allocator);
            self.manual_selection = null;
        }
    }

    /// Returneaza copia listei manuale (caller free).
    pub fn getManualSelection(self: *CoinControl) !?[]Outpoint {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.manual_selection) |ms| {
            const copy = try self.allocator.alloc(Outpoint, ms.items.len);
            @memcpy(copy, ms.items);
            return copy;
        }
        return null;
    }

    /// Verdict pentru coin selection: poate fi folosit acest outpoint la selectie automata?
    pub fn isSpendable(self: *CoinControl, op: Outpoint) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.entries.get(op.key())) |e| return e.status == .normal;
        return true; // niciun status setat => default normal
    }

    /// Cati outpoints sunt in fiecare status — util pentru RPC `coin_control_stats`.
    pub const Stats = struct { normal: u64, frozen: u64, reserved: u64 };

    pub fn stats(self: *CoinControl) Stats {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        var s = Stats{ .normal = 0, .frozen = 0, .reserved = 0 };
        var it = self.entries.iterator();
        while (it.next()) |e| {
            switch (e.value_ptr.status) {
                .normal => s.normal += 1,
                .frozen => s.frozen += 1,
                .reserved => s.reserved += 1,
            }
        }
        return s;
    }
};

// ============================================================
// Tests
// ============================================================

test "freeze and unfreeze" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();

    const op = Outpoint{ .txid = [_]u8{0x11} ** 32, .vout = 0 };
    try std.testing.expect(cc.isSpendable(op));
    try cc.freeze(op);
    try std.testing.expect(!cc.isSpendable(op));
    try std.testing.expect(cc.isFrozen(op));
    cc.unfreeze(op);
    try std.testing.expect(cc.isSpendable(op));
    try std.testing.expect(!cc.isFrozen(op));
}

test "reserve and release" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();

    const op1 = Outpoint{ .txid = [_]u8{0x01} ** 32, .vout = 0 };
    const op2 = Outpoint{ .txid = [_]u8{0x02} ** 32, .vout = 1 };
    const ops = [_]Outpoint{ op1, op2 };

    try cc.reserve(&ops, "abc123");
    try std.testing.expect(cc.isReserved(op1));
    try std.testing.expect(cc.isReserved(op2));
    try std.testing.expect(!cc.isSpendable(op1));

    cc.release("abc123");
    try std.testing.expect(!cc.isReserved(op1));
    try std.testing.expect(cc.isSpendable(op1));
}

test "reserve rejects when reserved by other tx" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();

    const op = Outpoint{ .txid = [_]u8{0x03} ** 32, .vout = 0 };
    const ops = [_]Outpoint{op};

    try cc.reserve(&ops, "tx_a");
    try std.testing.expectError(error.UtxoReservedByOtherTx, cc.reserve(&ops, "tx_b"));
    // re-reserve cu acelasi tx id e idempotent
    try cc.reserve(&ops, "tx_a");
}

test "reserve rejects frozen utxo" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();

    const op = Outpoint{ .txid = [_]u8{0x04} ** 32, .vout = 0 };
    try cc.freeze(op);

    const ops = [_]Outpoint{op};
    try std.testing.expectError(error.UtxoFrozen, cc.reserve(&ops, "tx"));
}

test "manual selection set/get/clear" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();

    const op1 = Outpoint{ .txid = [_]u8{0xAA} ** 32, .vout = 0 };
    const op2 = Outpoint{ .txid = [_]u8{0xBB} ** 32, .vout = 1 };
    const ops = [_]Outpoint{ op1, op2 };

    try cc.setManualSelection(&ops);
    const got = try cc.getManualSelection();
    try std.testing.expect(got != null);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqual(@as(usize, 2), got.?.len);

    cc.clearManualSelection();
    const got2 = try cc.getManualSelection();
    try std.testing.expect(got2 == null);
}

test "stats counts each status" {
    var cc = CoinControl.init(std.testing.allocator);
    defer cc.deinit();

    try cc.freeze(.{ .txid = [_]u8{0x01} ** 32, .vout = 0 });
    try cc.freeze(.{ .txid = [_]u8{0x02} ** 32, .vout = 0 });
    const ops = [_]Outpoint{.{ .txid = [_]u8{0x03} ** 32, .vout = 0 }};
    try cc.reserve(&ops, "tx");

    const s = cc.stats();
    try std.testing.expectEqual(@as(u64, 0), s.normal);
    try std.testing.expectEqual(@as(u64, 2), s.frozen);
    try std.testing.expectEqual(@as(u64, 1), s.reserved);
}
