/// matching_engine.zig — Motor de potrivire ordine pentru DEX OmniBus
///
/// Ruleza in fiecare nod miner. Matching-ul este DETERMINIST:
///   - Aceleasi ordine de intrare → aceleasi rezultate pe toti minerii
///   - Price-time priority: pret mai bun -> primul; la acelasi pret -> FIFO (timestamp)
///   - Self-trade is ALLOWED — a trader can match their own resting order.
///     Useful for single-wallet paper testing, and the operator collects
///     maker+taker fees on both sides anyway. (Old behavior was to skip;
///     changed 2026-04-28 by founder request.)
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
    /// For SELL orders on OMNI/<EVM-token> pairs: the seller's EVM address
    /// where the dex_settler should deliver the quote token (USDC/ETH/etc).
    /// All-zero = not provided; settler will skip the EVM leg.
    seller_evm: [20]u8 = [_]u8{0} ** 20,
    /// For BUY orders on OMNI/<EVM-token> pairs: the orderId the user
    /// already locked in the OmnibusDEX contract on the EVM side. The
    /// chain verifies escrow exists via evm_escrow_watcher BEFORE
    /// accepting the BID, so a match always has real funds backing it.
    /// 0 = not provided; allowed only for pairs without an EVM leg.
    evm_order_id: u64 = 0,

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
            .seller_evm = [_]u8{0} ** 20,
            .evm_order_id = 0,
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
    /// Copy of the seller's `seller_evm` field — propagated from the SELL
    /// order so the dex_settler thread knows where to deliver the EVM
    /// quote token. All-zero = no EVM leg requested.
    seller_evm: [20]u8 = [_]u8{0} ** 20,
    /// Copy of the buyer's `evm_order_id` — settler uses this as the
    /// OmnibusDEX orderId for `settle(orderId, sellerEvm)`. 0 = no EVM
    /// settlement needed for this fill.
    evm_order_id: u64 = 0,

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
            .seller_evm = [_]u8{0} ** 20,
            .evm_order_id = 0,
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

                // Self-trade is allowed: a trader can fill their own
                // resting order if they want (useful for paper-trader
                // single-wallet testing, and for legitimate wash-trade
                // strategies that pay the maker+taker fees). Operator
                // collects fees on both sides — that's the cost of doing it.

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

                // Self-trade allowed — see matchBuyOrder above for rationale.

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

            // Propagate the seller's EVM target (zero if not provided).
            // dex_settler.zig reads f.seller_evm to know where to deliver
            // the quote token on the EVM chain.
            fill.seller_evm = sell_order.seller_evm;
            // BUY order carries the on-chain escrow orderId.
            fill.evm_order_id = buy_order.evm_order_id;

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
