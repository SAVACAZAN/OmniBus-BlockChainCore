const std = @import("std");
const transaction_mod = @import("transaction.zig");
const array_list = std.array_list;

pub const Transaction = transaction_mod.Transaction;

/// Limite mempool
pub const MEMPOOL_MAX_TX:       usize = 10_000;
pub const MEMPOOL_MAX_BYTES:    usize = 1_048_576; // 1 MB
pub const TX_MAX_BYTES:         usize = 512;       // max 512 bytes per TX
pub const TX_MIN_FEE_SAT:       u64   = 1;         // min 1 SAT fee (anti-spam)

pub const MempoolError = error{
    Full,
    TxTooLarge,
    TxInvalid,
    TxDuplicate,
    FeeTooLow,
};

/// Intrare in mempool — TX + metadata
pub const MempoolEntry = struct {
    tx:           Transaction,
    received_at:  i64,   // Unix timestamp cand a sosit
    fee_sat:      u64,   // Fee estimat (amount-ul din TX pentru simplitate)
    size_bytes:   usize, // Marimea aproximativa
};

/// Mempool FIFO — First In First Out, anti-MEV
/// Modulul e independent de blockchain.zig — nu il modifica
pub const Mempool = struct {
    entries:     array_list.Managed(MempoolEntry),
    tx_hashes:   std.StringHashMap(void),
    total_bytes: usize,
    allocator:   std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Mempool {
        return .{
            .entries     = array_list.Managed(MempoolEntry).init(allocator),
            .tx_hashes   = std.StringHashMap(void).init(allocator),
            .total_bytes = 0,
            .allocator   = allocator,
        };
    }

    pub fn deinit(self: *Mempool) void {
        self.entries.deinit();
        self.tx_hashes.deinit();
    }

    /// Adauga o TX in mempool (FIFO — la coada)
    /// Returneaza eroare daca e plina, invalida, duplicata sau fee prea mic
    pub fn add(self: *Mempool, tx: Transaction) MempoolError!void {
        // 1. Verifica limita numar TX
        if (self.entries.items.len >= MEMPOOL_MAX_TX) {
            return MempoolError.Full;
        }

        // 2. Verifica marimea TX
        const tx_size = estimateTxSize(&tx);
        if (tx_size > TX_MAX_BYTES) {
            return MempoolError.TxTooLarge;
        }

        // 3. Verifica limita bytes totali
        if (self.total_bytes + tx_size > MEMPOOL_MAX_BYTES) {
            return MempoolError.Full;
        }

        // 4. Valideaza TX (prefix valid, amount > 0, adrese non-goale)
        if (!tx.isValid()) {
            return MempoolError.TxInvalid;
        }

        // 5. Fee minim anti-spam
        if (tx.amount < TX_MIN_FEE_SAT) {
            return MempoolError.FeeTooLow;
        }

        // 6. Detectie duplicate dupa hash
        const hash_key = tx.hash;
        if (hash_key.len > 0 and self.tx_hashes.contains(hash_key)) {
            return MempoolError.TxDuplicate;
        }

        // Adauga in FIFO (la coada)
        self.entries.append(.{
            .tx          = tx,
            .received_at = std.time.timestamp(),
            .fee_sat     = tx.amount, // simplificat: amount = fee pentru acum
            .size_bytes  = tx_size,
        }) catch return MempoolError.Full;

        if (hash_key.len > 0) {
            self.tx_hashes.put(hash_key, {}) catch {};
        }

        self.total_bytes += tx_size;
    }

    /// Scoate primele N TX-uri din mempool (FIFO — din fata)
    /// Folosit de miner la construirea unui bloc
    pub fn popN(self: *Mempool, n: usize, allocator: std.mem.Allocator) ![]Transaction {
        const count = @min(n, self.entries.items.len);
        var result = try allocator.alloc(Transaction, count);

        for (0..count) |i| {
            result[i] = self.entries.items[i].tx;
        }

        // Sterge primele `count` elemente din FIFO
        const remaining = self.entries.items.len - count;
        for (0..remaining) |i| {
            self.entries.items[i] = self.entries.items[i + count];
        }
        self.entries.shrinkRetainingCapacity(remaining);

        // Recalculeaza total_bytes
        self.total_bytes = 0;
        for (self.entries.items) |e| {
            self.total_bytes += e.size_bytes;
        }

        return result;
    }

    /// Sterge toate TX-urile confirmate (dupa minarea unui bloc)
    pub fn removeConfirmed(self: *Mempool, confirmed: []const Transaction) void {
        for (confirmed) |conf| {
            // Sterge din hash index
            if (conf.hash.len > 0) {
                _ = self.tx_hashes.remove(conf.hash);
            }
        }
        // Rebuild entries fara cele confirmate
        var new_entries = array_list.Managed(MempoolEntry).init(self.allocator);
        for (self.entries.items) |entry| {
            var found = false;
            for (confirmed) |conf| {
                if (entry.tx.id == conf.id) { found = true; break; }
            }
            if (!found) {
                new_entries.append(entry) catch {};
            }
        }
        self.entries.deinit();
        self.entries = new_entries;

        // Recalculeaza bytes
        self.total_bytes = 0;
        for (self.entries.items) |e| {
            self.total_bytes += e.size_bytes;
        }
    }

    /// Numarul de TX in asteptare
    pub fn size(self: *const Mempool) usize {
        return self.entries.items.len;
    }

    /// Bytes totali ocupati
    pub fn bytes(self: *const Mempool) usize {
        return self.total_bytes;
    }

    /// Verifica daca mempool-ul e gol
    pub fn isEmpty(self: *const Mempool) bool {
        return self.entries.items.len == 0;
    }

    /// Elimina TX-urile mai vechi de `max_age_sec` secunde (anti-bloat)
    pub fn evictOld(self: *Mempool, max_age_sec: i64) void {
        const now = std.time.timestamp();
        var new_entries = array_list.Managed(MempoolEntry).init(self.allocator);
        for (self.entries.items) |entry| {
            if (now - entry.received_at <= max_age_sec) {
                new_entries.append(entry) catch {};
            } else {
                if (entry.tx.hash.len > 0) {
                    _ = self.tx_hashes.remove(entry.tx.hash);
                }
            }
        }
        self.entries.deinit();
        self.entries = new_entries;
        self.total_bytes = 0;
        for (self.entries.items) |e| self.total_bytes += e.size_bytes;
    }

    pub fn printStats(self: *const Mempool) void {
        std.debug.print("[MEMPOOL] TX: {d}/{d} | Bytes: {d}/{d} | Empty: {}\n", .{
            self.size(), MEMPOOL_MAX_TX,
            self.bytes(), MEMPOOL_MAX_BYTES,
            self.isEmpty(),
        });
    }
};

/// Estimare marime TX in bytes (aproximare conservatoare)
fn estimateTxSize(tx: *const Transaction) usize {
    return 8                       // id + amount + timestamp
        + tx.from_address.len
        + tx.to_address.len
        + tx.signature.len
        + tx.hash.len
        + 32;                      // overhead struct
}

// ─── Teste ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTx(id: u32, from: []const u8, to: []const u8, amount: u64) Transaction {
    return Transaction{
        .id           = id,
        .from_address = from,
        .to_address   = to,
        .amount       = amount,
        .timestamp    = 1_743_000_000,
        .signature    = "",
        .hash         = "",
    };
}

test "Mempool — add si size" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    const tx = makeTx(1, "ob_omni_AAAA", "ob_omni_BBBB", 1_000_000);
    try mp.add(tx);
    try testing.expectEqual(@as(usize, 1), mp.size());
}

test "Mempool — FIFO: ordinea e pastrata" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try mp.add(makeTx(10, "ob_omni_AAAA", "ob_omni_BBBB", 100));
    try mp.add(makeTx(20, "ob_omni_CCCC", "ob_omni_DDDD", 200));
    try mp.add(makeTx(30, "ob_omni_EEEE", "ob_omni_FFFF", 300));

    const popped = try mp.popN(2, testing.allocator);
    defer testing.allocator.free(popped);

    try testing.expectEqual(@as(u32, 10), popped[0].id);
    try testing.expectEqual(@as(u32, 20), popped[1].id);
    try testing.expectEqual(@as(usize, 1), mp.size()); // mai ramas 1
}

test "Mempool — TX invalida respinsa" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    // Adresa fara prefix valid
    const bad_tx = makeTx(1, "invalid_addr", "also_invalid", 1000);
    const result = mp.add(bad_tx);
    try testing.expectError(MempoolError.TxInvalid, result);
    try testing.expectEqual(@as(usize, 0), mp.size());
}

test "Mempool — amount zero respins" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    // amount=0 e prins de isValid() (TxInvalid) sau FeeTooLow — ambele OK
    const tx = makeTx(1, "ob_omni_AAAA", "ob_omni_BBBB", 0);
    const result = mp.add(tx);
    try testing.expect(result == MempoolError.TxInvalid or result == MempoolError.FeeTooLow);
}

test "Mempool — isEmpty si printStats" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try testing.expect(mp.isEmpty());
    try mp.add(makeTx(1, "ob_omni_AAAA", "ob_omni_BBBB", 500));
    try testing.expect(!mp.isEmpty());
    mp.printStats();
}

test "Mempool — popN mai mult decat exista" {
    var mp = Mempool.init(testing.allocator);
    defer mp.deinit();

    try mp.add(makeTx(1, "ob_omni_AAAA", "ob_omni_BBBB", 100));

    const popped = try mp.popN(100, testing.allocator); // cere 100, are 1
    defer testing.allocator.free(popped);

    try testing.expectEqual(@as(usize, 1), popped.len);
    try testing.expectEqual(@as(usize, 0), mp.size());
}
