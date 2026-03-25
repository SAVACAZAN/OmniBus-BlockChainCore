const std = @import("std");
const block_mod = @import("block.zig");
const transaction_mod = @import("transaction.zig");
const array_list = std.array_list;

pub const Block = block_mod.Block;
pub const Transaction = transaction_mod.Transaction;

pub const Blockchain = struct {
    chain: array_list.Managed(Block),
    mempool: array_list.Managed(Transaction),
    difficulty: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Blockchain {
        var chain = array_list.Managed(Block).init(allocator);
        const mempool = array_list.Managed(Transaction).init(allocator);

        // Create genesis block
        const genesis = Block{
            .index = 0,
            .timestamp = 0,
            .transactions = array_list.Managed(Transaction).init(allocator),
            .previous_hash = "0",
            .nonce = 0,
            .hash = "genesis_hash_placeholder",
        };

        try chain.append(genesis);

        return Blockchain{
            .chain = chain,
            .mempool = mempool,
            .difficulty = 4, // Start with difficulty 4 (4 leading zeros)
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Blockchain) void {
        for (self.chain.items) |*block| {
            block.transactions.deinit();
        }
        self.chain.deinit();
        self.mempool.deinit();
    }

    pub fn addTransaction(self: *Blockchain, tx: Transaction) !void {
        // Validate transaction
        if (!try self.validateTransaction(&tx)) {
            return error.InvalidTransaction;
        }

        try self.mempool.append(tx);
    }

    pub fn validateTransaction(self: *Blockchain, tx: *const Transaction) !bool {
        _ = self;

        // 1. Amount trebuie > 0
        if (tx.amount == 0) return false;

        // 2. Adrese nu pot fi goale
        if (tx.from_address.len == 0 or tx.to_address.len == 0) return false;

        // 3. Prefix valid (isValid verifică prefix + amount)
        if (!tx.isValid()) return false;

        // 4. Dacă TX are semnătură — verifică integritatea hash-ului
        //    (signature = 128 hex chars = 64 bytes R||S, hash = 64 hex chars)
        //    Nu putem verifica semnătura fără public key, dar verificăm că
        //    hash-ul stocat corespunde conținutului TX (anti-tampering)
        if (tx.signature.len == 128 and tx.hash.len == 64) {
            const expected_hash = tx.calculateHash();
            // Reconvertim hash stocat din hex
            var stored_hash: [32]u8 = undefined;
            var ok = true;
            for (0..32) |i| {
                const hi = charToNibble(tx.hash[i * 2]) catch { ok = false; break; };
                const lo = charToNibble(tx.hash[i * 2 + 1]) catch { ok = false; break; };
                stored_hash[i] = (hi << 4) | lo;
            }
            if (!ok) return false;
            if (!std.mem.eql(u8, &stored_hash, &expected_hash)) return false;
        } else if (tx.signature.len > 0) {
            // Semnătură incompletă — respinge
            return false;
        }

        return true;
    }

    fn charToNibble(c: u8) !u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => error.InvalidChar,
        };
    }

    pub fn mineBlock(self: *Blockchain) !Block {
        if (self.chain.items.len == 0) {
            return error.EmptyChain;
        }

        const previous_block = self.chain.items[self.chain.items.len - 1];
        const index = self.chain.items.len;
        const timestamp = std.time.timestamp();

        var block = Block{
            .index = @intCast(index),
            .timestamp = timestamp,
            .transactions = self.mempool,
            .previous_hash = previous_block.hash,
            .nonce = 0,
            .hash = "",
        };

        // Proof-of-Work
        var nonce: u64 = 0;
        while (true) {
            block.nonce = nonce;
            const hash = try self.calculateBlockHash(&block);

            // Check if hash meets difficulty requirement
            if (try self.isValidHash(hash)) {
                block.hash = hash;
                break;
            }

            nonce += 1;
        }

        // Add block to chain
        try self.chain.append(block);

        // Reset mempool for next block
        self.mempool = array_list.Managed(Transaction).init(self.allocator);

        return block;
    }

    pub fn calculateBlockHash(self: *Blockchain, block: *const Block) ![]const u8 {
        _ = self;
        // Simplified hash calculation (in production, use SHA-256)
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Hash block header
        var buffer: [256]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, "{d}{d}{d}{d}", .{
            block.index,
            block.timestamp,
            block.previous_hash.len,
            block.nonce,
        });

        hasher.update(str);

        // Hash transactions
        for (block.transactions.items) |tx| {
            hasher.update(tx.hash);
        }

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        // Convert to hex string (simplified - return first 8 bytes as demo)
        var result: [16]u8 = undefined;
        for (0..8) |i| {
            _ = std.fmt.bufPrint(result[i * 2 .. (i + 1) * 2], "{x:0>2}", .{hash[i]}) catch "";
        }

        return &result;
    }

    pub fn isValidHash(self: *Blockchain, hash: []const u8) !bool {
        // Check if hash meets difficulty (leading zeros)
        var zero_count: u32 = 0;
        for (hash) |char| {
            if (char == '0') {
                zero_count += 1;
            } else {
                break;
            }
        }

        return zero_count >= self.difficulty;
    }

    pub fn getBlock(self: *Blockchain, index: u32) ?Block {
        if (index < self.chain.items.len) {
            return self.chain.items[index];
        }
        return null;
    }

    pub fn getLatestBlock(self: *Blockchain) Block {
        return self.chain.items[self.chain.items.len - 1];
    }

    pub fn getBlockCount(self: *Blockchain) u32 {
        return @intCast(self.chain.items.len);
    }
};
