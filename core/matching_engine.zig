/// matching_engine.zig — Motor de potrivire ordine pentru DEX OmniBus
///
/// Ruleza in fiecare nod miner. Matching-ul este DETERMINIST:
///   - Aceleasi ordine de intrare → aceleasi rezultate pe toti minerii
///   - Price-time priority: pret mai bun -> primul; la acelasi pret -> FIFO (timestamp)
///   - Self-trade prevention: nu se face match daca buyer == seller
///
/// Matching-ul se face la fiecare sub-block (0.1s). Rezultatele (Fill-uri)
/// sunt incluse in block data impreuna cu Merkle root al orderbook-ului.
///
/// Unitati:
///   - Preturi: micro-USD (u64, 1_000_000 = $1.00) — compatibil cu oracle.zig
///   - Cantitati: SAT (u64, 1 OMNI = 1_000_000_000 SAT)
///   - Timestamps: millisecunde Unix (i64)
const std = @import("std");

// --- CONSTANTE ---------------------------------------------------------------

/// Numar maxim de ordine per parte (bids / asks) — productie
pub const MAX_ORDERS: usize = 10_000;

/// Numar maxim de fill-uri per sub-block — productie
pub const MAX_FILLS: usize = 1_000;

/// Numar maxim de perechi de tranzactionare suportate
pub const MAX_PAIRS: usize = 64;

// --- TIPURI ------------------------------------------------------------------

/// Partea ordinii: cumparare sau vanzare
pub const Side = enum(u8) {
    buy = 0,
    sell = 1,

    pub fn name(self: Side) []const u8 {
        return switch (self) {
            .buy => "BUY",
            .sell => "SELL",
        };
    }

    pub fn opposite(self: Side) Side {
        return switch (self) {
            .buy => .sell,
            .sell => .buy,
        };
    }
};

/// Statusul unei ordini in orderbook
pub const OrderStatus = enum(u8) {
    /// Activa — asteapta sa fie matched
    active = 0,
    /// Partial umpluta — ramane in book cu cantitate redusa
    partial = 1,
    /// Complet umpluta — scoasa din book
    filled = 2,
    /// Anulata de trader
    cancelled = 3,
};

/// O ordine in orderbook
pub const Order = struct {
    order_id: u64,
    trader_address: [64]u8,
    trader_addr_len: u8,
    pair_id: u16, // perechea de tranzactionare (0 = OMNI/USD, 1 = BTC/USD, etc.)
    side: Side,
    price_micro_usd: u64, // pret limita in micro-USD
    amount_sat: u64, // cantitate originala in SAT
    filled_sat: u64, // cat a fost deja umplut
    timestamp_ms: i64, // cand a fost plasata ordinea
    status: OrderStatus,

    /// Cantitatea ramasa de umplut
    pub fn remainingSat(self: *const Order) u64 {
        if (self.filled_sat >= self.amount_sat) return 0;
        return self.amount_sat - self.filled_sat;
    }

    /// Este ordine de cumparare?
    pub fn isBuy(self: *const Order) bool {
        return self.side == .buy;
    }

    /// Returneaza adresa traderului ca slice
    pub fn getTraderAddress(self: *const Order) []const u8 {
        return self.trader_address[0..self.trader_addr_len];
    }

    /// Ordine goala (slot liber in array)
    pub fn empty() Order {
        return Order{
            .order_id = 0,
            .trader_address = [_]u8{0} ** 64,
            .trader_addr_len = 0,
            .pair_id = 0,
            .side = .buy,
            .price_micro_usd = 0,
            .amount_sat = 0,
            .filled_sat = 0,
            .timestamp_ms = 0,
            .status = .cancelled,
        };
    }

    /// Compara doua adrese — folosit pentru self-trade prevention
    pub fn sameTrader(self: *const Order, other: *const Order) bool {
        if (self.trader_addr_len != other.trader_addr_len) return false;
        const a = self.trader_address[0..self.trader_addr_len];
        const b = other.trader_address[0..other.trader_addr_len];
        return std.mem.eql(u8, a, b);
    }
};

/// Rezultatul unui match (fill) — doua ordine s-au potrivit
pub const Fill = struct {
    fill_id: u64,
    buy_order_id: u64,
    sell_order_id: u64,
    price_micro_usd: u64, // pretul de executie
    amount_sat: u64, // cantitatea umpluta
    timestamp_ms: i64, // cand s-a facut match-ul
    pair_id: u16,
    buyer_address: [64]u8,
    buyer_addr_len: u8,
    seller_address: [64]u8,
    seller_addr_len: u8,

    pub fn empty() Fill {
        return Fill{
            .fill_id = 0,
            .buy_order_id = 0,
            .sell_order_id = 0,
            .price_micro_usd = 0,
            .amount_sat = 0,
            .timestamp_ms = 0,
            .pair_id = 0,
            .buyer_address = [_]u8{0} ** 64,
            .buyer_addr_len = 0,
            .seller_address = [_]u8{0} ** 64,
            .seller_addr_len = 0,
        };
    }

    /// Returneaza adresa cumparatorului ca slice
    pub fn getBuyerAddress(self: *const Fill) []const u8 {
        return self.buyer_address[0..self.buyer_addr_len];
    }

    /// Returneaza adresa vanzatorului ca slice
    pub fn getSellerAddress(self: *const Fill) []const u8 {
        return self.seller_address[0..self.seller_addr_len];
    }
};

// --- ERORI -------------------------------------------------------------------

pub const MatchingError = error{
    OrderbookFull,
    FillBufferFull,
    OrderNotFound,
    InvalidOrder,
    InvalidPrice,
    InvalidAmount,
    InvalidPair,
};

// --- MATCHING ENGINE (parametrizat) ------------------------------------------

/// Motor de potrivire a ordinilor — parametrizat cu capacitatea orderbook-ului.
/// Foloseste comptime params pentru a permite atat instante de productie (10K ordine)
/// cat si instante mici de test care incap pe stack.
pub fn MatchingEngineWith(comptime max_orders: usize, comptime max_fills: usize) type {
    return struct {
        const Self = @This();

        /// Bids: sortate descrescator dupa pret, apoi crescator dupa timestamp (FIFO)
        bids: [max_orders]Order,
        bid_count: u32,

        /// Asks: sortate crescator dupa pret, apoi crescator dupa timestamp (FIFO)
        asks: [max_orders]Order,
        ask_count: u32,

        /// Fill-uri produse in sub-blocul curent
        fills: [max_fills]Fill,
        fill_count: u32,

        /// Contoare pentru ID-uri unice
        next_order_id: u64,
        next_fill_id: u64,

        /// Initializeaza un engine gol
        pub fn init() Self {
            return Self{
                .bids = [_]Order{Order.empty()} ** max_orders,
                .bid_count = 0,
                .asks = [_]Order{Order.empty()} ** max_orders,
                .ask_count = 0,
                .fills = [_]Fill{Fill.empty()} ** max_fills,
                .fill_count = 0,
                .next_order_id = 1,
                .next_fill_id = 1,
            };
        }

        /// Plaseaza o ordine: mai intai incearca sa faca match, apoi adauga restul in book
        pub fn placeOrder(self: *Self, incoming: Order) MatchingError!void {
            // Validari
            if (incoming.price_micro_usd == 0) return MatchingError.InvalidPrice;
            if (incoming.amount_sat == 0) return MatchingError.InvalidAmount;
            if (incoming.pair_id >= MAX_PAIRS) return MatchingError.InvalidPair;

            // Copiaza ordinea si asigneaza ID
            var order = incoming;
            order.order_id = self.next_order_id;
            self.next_order_id += 1;
            order.status = .active;
            order.filled_sat = 0;

            // Matching
            self.matchOrder(&order);

            // Daca mai are cantitate ramasa, adauga in orderbook
            if (order.remainingSat() > 0) {
                if (order.filled_sat > 0) {
                    order.status = .partial;
                }
                switch (order.side) {
                    .buy => self.insertBid(order) catch return MatchingError.OrderbookFull,
                    .sell => self.insertAsk(order) catch return MatchingError.OrderbookFull,
                }
            }
        }

        /// Anuleaza o ordine dupa ID — o scoate din orderbook
        pub fn cancelOrder(self: *Self, order_id: u64) MatchingError!void {
            // Cauta in bids
            for (0..self.bid_count) |i| {
                if (self.bids[i].order_id == order_id) {
                    self.bids[i].status = .cancelled;
                    self.removeBidAt(i);
                    return;
                }
            }
            // Cauta in asks
            for (0..self.ask_count) |i| {
                if (self.asks[i].order_id == order_id) {
                    self.asks[i].status = .cancelled;
                    self.removeAskAt(i);
                    return;
                }
            }
            return MatchingError.OrderNotFound;
        }

        /// Sterge fill-urile dupa ce au fost incluse in block
        pub fn clearFills(self: *Self) void {
            self.fill_count = 0;
        }

        /// Calculeaza Merkle root (SHA256) al starii orderbook-ului
        /// Toti minerii produc acelasi hash pentru aceleasi ordine
        pub fn orderbookMerkleRoot(self: *const Self) [32]u8 {
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});

            // Hash bids
            for (0..self.bid_count) |i| {
                hashOrder(&hasher, &self.bids[i]);
            }

            // Separator intre bids si asks
            hasher.update(&[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF });

            // Hash asks
            for (0..self.ask_count) |i| {
                hashOrder(&hasher, &self.asks[i]);
            }

            var root: [32]u8 = undefined;
            hasher.final(&root);
            return root;
        }

        /// Cel mai bun pret de cumparare pentru o pereche (cel mai mare bid)
        pub fn bestBid(self: *const Self, pair_id: u16) ?u64 {
            for (0..self.bid_count) |i| {
                if (self.bids[i].pair_id == pair_id) {
                    return self.bids[i].price_micro_usd;
                }
            }
            return null;
        }

        /// Cel mai bun pret de vanzare pentru o pereche (cel mai mic ask)
        pub fn bestAsk(self: *const Self, pair_id: u16) ?u64 {
            for (0..self.ask_count) |i| {
                if (self.asks[i].pair_id == pair_id) {
                    return self.asks[i].price_micro_usd;
                }
            }
            return null;
        }

        /// Spread-ul (diferenta ask - bid) pentru o pereche
        pub fn spread(self: *const Self, pair_id: u16) ?u64 {
            const bb = self.bestBid(pair_id) orelse return null;
            const ba = self.bestAsk(pair_id) orelse return null;
            if (ba <= bb) return 0;
            return ba - bb;
        }

        /// Numarul total de ordine active in book (bids + asks)
        pub fn orderCount(self: *const Self) u32 {
            return self.bid_count + self.ask_count;
        }

        /// Numarul de ordine active pentru o pereche specifica
        pub fn orderCountForPair(self: *const Self, pair_id: u16) u32 {
            var count: u32 = 0;
            for (0..self.bid_count) |i| {
                if (self.bids[i].pair_id == pair_id) count += 1;
            }
            for (0..self.ask_count) |i| {
                if (self.asks[i].pair_id == pair_id) count += 1;
            }
            return count;
        }

        /// Returneaza o ordine dupa ID (cauta in bids si asks)
        pub fn getOrder(self: *const Self, order_id: u64) ?*const Order {
            for (0..self.bid_count) |i| {
                if (self.bids[i].order_id == order_id) {
                    return &self.bids[i];
                }
            }
            for (0..self.ask_count) |i| {
                if (self.asks[i].order_id == order_id) {
                    return &self.asks[i];
                }
            }
            return null;
        }

        // --- FUNCTII PRIVATE ---------------------------------------------------------

        /// Logica principala de matching — price-time priority
        ///
        /// Daca ordinea este BUY: compara cu asks (de la cel mai mic pret in sus)
        /// Daca ordinea este SELL: compara cu bids (de la cel mai mare pret in jos)
        ///
        /// Se opreste cand:
        ///   - ordinea este complet umpluta
        ///   - nu mai sunt contra-ordine cu pret compatibil
        ///   - buffer-ul de fill-uri este plin
        fn matchOrder(self: *Self, order: *Order) void {
            switch (order.side) {
                .buy => self.matchBuyOrder(order),
                .sell => self.matchSellOrder(order),
            }
        }

        /// Match o ordine BUY contra asks-urilor existente
        fn matchBuyOrder(self: *Self, buy: *Order) void {
            var i: u32 = 0;
            while (i < self.ask_count and buy.remainingSat() > 0) {
                // Asks sunt sortate crescator — daca ask price > buy price, stop
                if (self.asks[i].price_micro_usd > buy.price_micro_usd) break;

                // Doar ordine din aceeasi pereche
                if (self.asks[i].pair_id != buy.pair_id) {
                    i += 1;
                    continue;
                }

                // Self-trade prevention
                if (buy.sameTrader(&self.asks[i])) {
                    i += 1;
                    continue;
                }

                // Fill buffer plin — oprim matching-ul
                if (self.fill_count >= max_fills) break;

                // Calculeaza cantitatea de match
                const ask_remaining = self.asks[i].remainingSat();
                const buy_remaining = buy.remainingSat();
                const fill_amount = @min(buy_remaining, ask_remaining);

                // Pretul de executie este al ordinii resting (ask-ul existent)
                const exec_price = self.asks[i].price_micro_usd;

                // Creeaza fill
                self.recordFill(buy, &self.asks[i], exec_price, fill_amount);

                // Actualizeaza cantitatile
                buy.filled_sat += fill_amount;
                self.asks[i].filled_sat += fill_amount;

                // Daca ask-ul a fost complet umplut, scoate-l din book
                if (self.asks[i].remainingSat() == 0) {
                    self.asks[i].status = .filled;
                    self.removeAskAt(i);
                    // Nu incrementa i — urmatorul element a venit pe pozitia curenta
                } else {
                    self.asks[i].status = .partial;
                    i += 1;
                }
            }

            // Actualizeaza statusul buy-ului
            if (buy.remainingSat() == 0) {
                buy.status = .filled;
            }
        }

        /// Match o ordine SELL contra bids-urilor existente
        fn matchSellOrder(self: *Self, sell: *Order) void {
            var i: u32 = 0;
            while (i < self.bid_count and sell.remainingSat() > 0) {
                // Bids sunt sortate descrescator — daca bid price < sell price, stop
                if (self.bids[i].price_micro_usd < sell.price_micro_usd) break;

                // Doar ordine din aceeasi pereche
                if (self.bids[i].pair_id != sell.pair_id) {
                    i += 1;
                    continue;
                }

                // Self-trade prevention
                if (sell.sameTrader(&self.bids[i])) {
                    i += 1;
                    continue;
                }

                // Fill buffer plin
                if (self.fill_count >= max_fills) break;

                // Calculeaza cantitatea de match
                const bid_remaining = self.bids[i].remainingSat();
                const sell_remaining = sell.remainingSat();
                const fill_amount = @min(sell_remaining, bid_remaining);

                // Pretul de executie este al ordinii resting (bid-ul existent)
                const exec_price = self.bids[i].price_micro_usd;

                // Creeaza fill
                self.recordFill(&self.bids[i], sell, exec_price, fill_amount);

                // Actualizeaza cantitatile
                sell.filled_sat += fill_amount;
                self.bids[i].filled_sat += fill_amount;

                // Daca bid-ul a fost complet umplut, scoate-l din book
                if (self.bids[i].remainingSat() == 0) {
                    self.bids[i].status = .filled;
                    self.removeBidAt(i);
                } else {
                    self.bids[i].status = .partial;
                    i += 1;
                }
            }

            if (sell.remainingSat() == 0) {
                sell.status = .filled;
            }
        }

        /// Inregistreaza un fill in buffer
        fn recordFill(
            self: *Self,
            buy_order: *const Order,
            sell_order: *Order,
            exec_price: u64,
            fill_amount: u64,
        ) void {
            if (self.fill_count >= max_fills) return;

            var fill = Fill.empty();
            fill.fill_id = self.next_fill_id;
            self.next_fill_id += 1;
            fill.buy_order_id = buy_order.order_id;
            fill.sell_order_id = sell_order.order_id;
            fill.price_micro_usd = exec_price;
            fill.amount_sat = fill_amount;
            fill.timestamp_ms = @max(buy_order.timestamp_ms, sell_order.timestamp_ms);
            fill.pair_id = buy_order.pair_id;

            // Copiaza adresele
            fill.buyer_addr_len = buy_order.trader_addr_len;
            @memcpy(fill.buyer_address[0..buy_order.trader_addr_len], buy_order.trader_address[0..buy_order.trader_addr_len]);

            fill.seller_addr_len = sell_order.trader_addr_len;
            @memcpy(fill.seller_address[0..sell_order.trader_addr_len], sell_order.trader_address[0..sell_order.trader_addr_len]);

            self.fills[self.fill_count] = fill;
            self.fill_count += 1;
        }

        /// Insereaza un bid in pozitia corecta (descrescator dupa pret, FIFO la acelasi pret)
        /// Insertion sort — mentine ordinea sortata fara allocator
        fn insertBid(self: *Self, order: Order) !void {
            if (self.bid_count >= max_orders) return MatchingError.OrderbookFull;

            // Gaseste pozitia de insertie
            var pos: u32 = self.bid_count;
            for (0..self.bid_count) |i| {
                const idx: u32 = @intCast(i);
                // Sortare descrescatoare dupa pret
                if (order.price_micro_usd > self.bids[idx].price_micro_usd) {
                    pos = idx;
                    break;
                }
                // La acelasi pret, FIFO: ordinea mai veche sta mai sus
                if (order.price_micro_usd == self.bids[idx].price_micro_usd and
                    order.timestamp_ms < self.bids[idx].timestamp_ms)
                {
                    pos = idx;
                    break;
                }
            }

            // Shift dreapta de la pozitia de insertie
            var j: u32 = self.bid_count;
            while (j > pos) {
                self.bids[j] = self.bids[j - 1];
                j -= 1;
            }

            self.bids[pos] = order;
            self.bid_count += 1;
        }

        /// Insereaza un ask in pozitia corecta (crescator dupa pret, FIFO la acelasi pret)
        fn insertAsk(self: *Self, order: Order) !void {
            if (self.ask_count >= max_orders) return MatchingError.OrderbookFull;

            var pos: u32 = self.ask_count;
            for (0..self.ask_count) |i| {
                const idx: u32 = @intCast(i);
                // Sortare crescatoare dupa pret
                if (order.price_micro_usd < self.asks[idx].price_micro_usd) {
                    pos = idx;
                    break;
                }
                // La acelasi pret, FIFO
                if (order.price_micro_usd == self.asks[idx].price_micro_usd and
                    order.timestamp_ms < self.asks[idx].timestamp_ms)
                {
                    pos = idx;
                    break;
                }
            }

            var j: u32 = self.ask_count;
            while (j > pos) {
                self.asks[j] = self.asks[j - 1];
                j -= 1;
            }

            self.asks[pos] = order;
            self.ask_count += 1;
        }

        /// Scoate un bid din pozitia data (shift stanga)
        fn removeBidAt(self: *Self, pos: usize) void {
            if (self.bid_count == 0) return;
            const count = self.bid_count;
            var i: usize = pos;
            while (i + 1 < count) {
                self.bids[i] = self.bids[i + 1];
                i += 1;
            }
            self.bids[count - 1] = Order.empty();
            self.bid_count -= 1;
        }

        /// Scoate un ask din pozitia data (shift stanga)
        fn removeAskAt(self: *Self, pos: usize) void {
            if (self.ask_count == 0) return;
            const count = self.ask_count;
            var i: usize = pos;
            while (i + 1 < count) {
                self.asks[i] = self.asks[i + 1];
                i += 1;
            }
            self.asks[count - 1] = Order.empty();
            self.ask_count -= 1;
        }

        /// Hash o ordine individuala in hasher-ul SHA256 (pentru Merkle root)
        fn hashOrder(hasher: *std.crypto.hash.sha2.Sha256, order: *const Order) void {
            // order_id
            const id_bytes = std.mem.asBytes(&order.order_id);
            hasher.update(id_bytes);
            // pair_id
            const pair_bytes = std.mem.asBytes(&order.pair_id);
            hasher.update(pair_bytes);
            // side
            const side_byte = [_]u8{@intFromEnum(order.side)};
            hasher.update(&side_byte);
            // price
            const price_bytes = std.mem.asBytes(&order.price_micro_usd);
            hasher.update(price_bytes);
            // remaining amount (nu amount original — starea curenta conteaza)
            const remaining = order.remainingSat();
            const rem_bytes = std.mem.asBytes(&remaining);
            hasher.update(rem_bytes);
            // timestamp
            const ts_bytes = std.mem.asBytes(&order.timestamp_ms);
            hasher.update(ts_bytes);
            // trader address
            hasher.update(order.trader_address[0..order.trader_addr_len]);
        }
    };
}

/// Tipul de productie — 10,000 ordine per parte, 1,000 fill-uri per sub-block.
/// Atentie: ~3MB pe instanta, NU se pune pe stack in contexte limitate.
/// In productie se aloca static (var globala) sau prin page allocator.
pub const MatchingEngine = MatchingEngineWith(MAX_ORDERS, MAX_FILLS);

// --- HELPER: creeaza ordine de test -------------------------------------------

fn makeTestOrder(
    side: Side,
    price: u64,
    amount: u64,
    ts: i64,
    addr: []const u8,
    pair_id: u16,
) Order {
    var order = Order.empty();
    order.side = side;
    order.price_micro_usd = price;
    order.amount_sat = amount;
    order.timestamp_ms = ts;
    order.pair_id = pair_id;
    order.status = .active;
    order.trader_addr_len = @intCast(addr.len);
    @memcpy(order.trader_address[0..addr.len], addr);
    return order;
}

/// Engine mic pentru teste — incape pe stack (~15KB)
const TestEngine = MatchingEngineWith(64, 32);

// --- TESTE -------------------------------------------------------------------

test "init matching engine" {
    const engine = TestEngine.init();
    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
    try std.testing.expectEqual(@as(u64, 1), engine.next_order_id);
    try std.testing.expectEqual(@as(u64, 1), engine.next_fill_id);
    try std.testing.expectEqual(@as(u32, 0), engine.orderCount());
}

test "place buy order — no match" {
    var engine = TestEngine.init();
    const order = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice123", 0);
    try engine.placeOrder(order);

    try std.testing.expectEqual(@as(u32, 1), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 1), engine.orderCount());

    // Verifica ordinea in book
    try std.testing.expectEqual(@as(u64, 50_000_000), engine.bids[0].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), engine.bids[0].amount_sat);
    try std.testing.expectEqual(OrderStatus.active, engine.bids[0].status);
}

test "place sell order — no match" {
    var engine = TestEngine.init();
    const order = makeTestOrder(.sell, 51_000_000, 500_000_000, 2000, "bob456", 0);
    try engine.placeOrder(order);

    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
    try std.testing.expectEqual(@as(u64, 51_000_000), engine.asks[0].price_micro_usd);
}

test "exact match — full fill" {
    var engine = TestEngine.init();

    // Alice pune un sell la $50
    const sell = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice123", 0);
    try engine.placeOrder(sell);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count);

    // Bob pune un buy la $50 — trebuie sa faca match complet
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 2000, "bob456", 0);
    try engine.placeOrder(buy);

    // Ambele ordine au fost complet umplute
    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);

    // Verifica fill-ul
    const fill = engine.fills[0];
    try std.testing.expectEqual(@as(u64, 50_000_000), fill.price_micro_usd);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), fill.amount_sat);
    try std.testing.expect(std.mem.eql(u8, fill.getBuyerAddress(), "bob456"));
    try std.testing.expect(std.mem.eql(u8, fill.getSellerAddress(), "alice123"));
}

test "partial fill" {
    var engine = TestEngine.init();

    // Alice vinde 5 OMNI la $100
    const sell = makeTestOrder(.sell, 100_000_000, 5_000_000_000, 1000, "alice123", 0);
    try engine.placeOrder(sell);

    // Bob cumpara 10 OMNI la $100 — doar 5 se umplu, restul 5 ramane in bids
    const buy = makeTestOrder(.buy, 100_000_000, 10_000_000_000, 2000, "bob456", 0);
    try engine.placeOrder(buy);

    // Sell complet umplut, buy partial
    try std.testing.expectEqual(@as(u32, 0), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 1), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);

    // Verifica fill-ul
    try std.testing.expectEqual(@as(u64, 5_000_000_000), engine.fills[0].amount_sat);

    // Restul buy-ului ramane in bids cu status partial
    try std.testing.expectEqual(OrderStatus.partial, engine.bids[0].status);
    try std.testing.expectEqual(@as(u64, 5_000_000_000), engine.bids[0].remainingSat());
}

test "price-time priority" {
    var engine = TestEngine.init();

    // Doua sell-uri la acelasi pret — primul plasat trebuie sa fie matched primul
    const sell_early = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    const sell_late = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 2000, "carol", 0);
    try engine.placeOrder(sell_early);
    try engine.placeOrder(sell_late);

    try std.testing.expectEqual(@as(u32, 2), engine.ask_count);

    // Verificam ordinea: cel mai vechi ask e pe pozitia 0
    try std.testing.expectEqual(@as(i64, 1000), engine.asks[0].timestamp_ms);
    try std.testing.expectEqual(@as(i64, 2000), engine.asks[1].timestamp_ms);

    // Bob cumpara 1 OMNI — trebuie sa faca match cu alice (FIFO)
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 3000, "bob", 0);
    try engine.placeOrder(buy);

    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count);

    // Fill-ul trebuie sa fie cu alice (sell_early), nu carol
    try std.testing.expect(std.mem.eql(u8, engine.fills[0].getSellerAddress(), "alice"));

    // Carol ramane in book
    try std.testing.expect(std.mem.eql(u8, engine.asks[0].getTraderAddress(), "carol"));
}

test "cancel order" {
    var engine = TestEngine.init();

    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    try engine.placeOrder(buy);
    try std.testing.expectEqual(@as(u32, 1), engine.bid_count);

    // Ordinea are ID-ul 1 (prima ordine)
    const order_id = engine.bids[0].order_id;
    try engine.cancelOrder(order_id);

    try std.testing.expectEqual(@as(u32, 0), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 0), engine.orderCount());

    // Incercarea de a anula o ordine inexistenta da eroare
    const result = engine.cancelOrder(999);
    try std.testing.expectError(MatchingError.OrderNotFound, result);
}

test "orderbook merkle root — deterministic" {
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    const sell = makeTestOrder(.sell, 51_000_000, 500_000_000, 2000, "bob", 0);

    // Prima rulare — calculam root1
    var root1: [32]u8 = undefined;
    {
        var engine = TestEngine.init();
        try engine.placeOrder(buy);
        try engine.placeOrder(sell);
        root1 = engine.orderbookMerkleRoot();
    }

    // Engine gol — root diferit
    var empty_root: [32]u8 = undefined;
    {
        const engine = TestEngine.init();
        empty_root = engine.orderbookMerkleRoot();
    }
    try std.testing.expect(!std.mem.eql(u8, &root1, &empty_root));

    // A doua rulare cu aceleasi ordine — trebuie sa dea acelasi root
    var root2: [32]u8 = undefined;
    {
        var engine = TestEngine.init();
        try engine.placeOrder(buy);
        try engine.placeOrder(sell);
        root2 = engine.orderbookMerkleRoot();
    }

    try std.testing.expect(std.mem.eql(u8, &root1, &root2));
}

test "self-trade prevention" {
    var engine = TestEngine.init();

    // Alice pune un sell
    const sell = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    try engine.placeOrder(sell);

    // Alice pune un buy la acelasi pret — nu trebuie sa faca match cu sine
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 2000, "alice", 0);
    try engine.placeOrder(buy);

    // Ambele ordine raman in book, zero fill-uri
    try std.testing.expectEqual(@as(u32, 1), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count);
    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
}

test "spread calculation" {
    var engine = TestEngine.init();

    // Inainte de ordine, spread-ul este null
    try std.testing.expect(engine.spread(0) == null);

    // Bid la $49, Ask la $51 → spread = $2
    const buy = makeTestOrder(.buy, 49_000_000, 1_000_000_000, 1000, "alice", 0);
    const sell = makeTestOrder(.sell, 51_000_000, 1_000_000_000, 2000, "bob", 0);
    try engine.placeOrder(buy);
    try engine.placeOrder(sell);

    try std.testing.expectEqual(@as(u64, 49_000_000), engine.bestBid(0).?);
    try std.testing.expectEqual(@as(u64, 51_000_000), engine.bestAsk(0).?);
    try std.testing.expectEqual(@as(u64, 2_000_000), engine.spread(0).?);

    // Pair 1 nu are ordine
    try std.testing.expect(engine.spread(1) == null);
}

test "multiple fills — price levels" {
    var engine = TestEngine.init();

    // Trei sell-uri la preturi diferite
    const sell1 = makeTestOrder(.sell, 100_000_000, 1_000_000_000, 1000, "seller_a", 0); // $100
    const sell2 = makeTestOrder(.sell, 101_000_000, 1_000_000_000, 2000, "seller_b", 0); // $101
    const sell3 = makeTestOrder(.sell, 102_000_000, 1_000_000_000, 3000, "seller_c", 0); // $102
    try engine.placeOrder(sell1);
    try engine.placeOrder(sell2);
    try engine.placeOrder(sell3);

    try std.testing.expectEqual(@as(u32, 3), engine.ask_count);

    // Un buy mare care mananca primele doua nivele de pret
    const buy = makeTestOrder(.buy, 101_000_000, 2_000_000_000, 4000, "buyer_x", 0);
    try engine.placeOrder(buy);

    // 2 fill-uri: $100 si $101
    try std.testing.expectEqual(@as(u32, 2), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count); // $102 ramane

    // Primul fill la $100 (pretul cel mai mic, resting order)
    try std.testing.expectEqual(@as(u64, 100_000_000), engine.fills[0].price_micro_usd);
    // Al doilea fill la $101
    try std.testing.expectEqual(@as(u64, 101_000_000), engine.fills[1].price_micro_usd);

    // Ask-ul ramas este cel de $102
    try std.testing.expectEqual(@as(u64, 102_000_000), engine.asks[0].price_micro_usd);
}

test "clearFills resets fill buffer" {
    var engine = TestEngine.init();

    const sell = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 2000, "bob", 0);
    try engine.placeOrder(sell);
    try engine.placeOrder(buy);

    try std.testing.expectEqual(@as(u32, 1), engine.fill_count);

    engine.clearFills();

    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
}

test "invalid order rejection" {
    var engine = TestEngine.init();

    // Pret zero
    const bad_price = makeTestOrder(.buy, 0, 1_000_000_000, 1000, "alice", 0);
    try std.testing.expectError(MatchingError.InvalidPrice, engine.placeOrder(bad_price));

    // Cantitate zero
    const bad_amount = makeTestOrder(.buy, 50_000_000, 0, 1000, "alice", 0);
    try std.testing.expectError(MatchingError.InvalidAmount, engine.placeOrder(bad_amount));

    // Pair ID invalid
    var bad_pair = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    bad_pair.pair_id = MAX_PAIRS;
    try std.testing.expectError(MatchingError.InvalidPair, engine.placeOrder(bad_pair));

    // Niciuna din cele de sus nu trebuie sa fi fost adaugata
    try std.testing.expectEqual(@as(u32, 0), engine.orderCount());
}

test "bid sorting — descending price" {
    var engine = TestEngine.init();

    // Insereaza bids in ordine aleatoare
    const b1 = makeTestOrder(.buy, 49_000_000, 1_000_000_000, 1000, "a", 0);
    const b2 = makeTestOrder(.buy, 51_000_000, 1_000_000_000, 2000, "b", 0);
    const b3 = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 3000, "c", 0);

    try engine.placeOrder(b1); // $49
    try engine.placeOrder(b2); // $51
    try engine.placeOrder(b3); // $50

    // Trebuie sortate: $51, $50, $49
    try std.testing.expectEqual(@as(u64, 51_000_000), engine.bids[0].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 50_000_000), engine.bids[1].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 49_000_000), engine.bids[2].price_micro_usd);
}

test "ask sorting — ascending price" {
    var engine = TestEngine.init();

    const a1 = makeTestOrder(.sell, 102_000_000, 1_000_000_000, 1000, "a", 0);
    const a2 = makeTestOrder(.sell, 100_000_000, 1_000_000_000, 2000, "b", 0);
    const a3 = makeTestOrder(.sell, 101_000_000, 1_000_000_000, 3000, "c", 0);

    try engine.placeOrder(a1); // $102
    try engine.placeOrder(a2); // $100
    try engine.placeOrder(a3); // $101

    // Trebuie sortate: $100, $101, $102
    try std.testing.expectEqual(@as(u64, 100_000_000), engine.asks[0].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 101_000_000), engine.asks[1].price_micro_usd);
    try std.testing.expectEqual(@as(u64, 102_000_000), engine.asks[2].price_micro_usd);
}

test "different pairs do not match" {
    var engine = TestEngine.init();

    // Sell OMNI/USD (pair 0) la $50
    const sell = makeTestOrder(.sell, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    try engine.placeOrder(sell);

    // Buy BTC/USD (pair 1) la $50 — nu trebuie sa faca match
    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 2000, "bob", 1);
    try engine.placeOrder(buy);

    try std.testing.expectEqual(@as(u32, 0), engine.fill_count);
    try std.testing.expectEqual(@as(u32, 1), engine.bid_count);
    try std.testing.expectEqual(@as(u32, 1), engine.ask_count);
}

test "getOrder finds by ID" {
    var engine = TestEngine.init();

    const buy = makeTestOrder(.buy, 50_000_000, 1_000_000_000, 1000, "alice", 0);
    try engine.placeOrder(buy);

    const found = engine.getOrder(1); // primul order_id = 1
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u64, 50_000_000), found.?.price_micro_usd);

    const not_found = engine.getOrder(999);
    try std.testing.expect(not_found == null);
}
