/// timelock_vault.zig — Pure CLTV (CheckLockTimeVerify) timelocked vaults.
///
/// Different from HTLC (no hash preimage needed). Funds are locked until
/// block height N, then can ONLY be released to one pre-committed destination.
/// This is a covenant: the destination is fixed at creation time.
///
/// State machine: locked → unlocked (current_block >= unlock_block) → spent.
/// The `timelock_spend` RPC checks the state and broadcasts the release TX.
///
/// Persistence: data/timelocks.jsonl

const std = @import("std");
const array_list = std.array_list;
const Crypto = @import("crypto.zig").Crypto;

pub const ADDR_MAX: usize = 128;
pub const ID_HEX_LEN: usize = 64;    // sha256 hex
pub const TX_HEX_LEN: usize = 64;
pub const MAX_VAULTS: usize = 50_000;

pub const VaultState = enum(u8) {
    locked   = 0,
    unlocked = 1,
    spent    = 2,

    pub fn str(self: VaultState) []const u8 {
        return switch (self) {
            .locked   => "locked",
            .unlocked => "unlocked",
            .spent    => "spent",
        };
    }
};

pub const TimelockVault = struct {
    id:            [ID_HEX_LEN]u8  = [_]u8{0} ** ID_HEX_LEN,
    owner_address: [ADDR_MAX]u8    = [_]u8{0} ** ADDR_MAX,
    owner_len:     u8              = 0,
    dest_address:  [ADDR_MAX]u8    = [_]u8{0} ** ADDR_MAX,
    dest_len:      u8              = 0,
    amount_sat:    u64             = 0,
    unlock_block:  u64             = 0,
    created_block: u64             = 0,
    state:         VaultState      = .locked,
    lock_tx_hash:  [TX_HEX_LEN]u8 = [_]u8{0} ** TX_HEX_LEN,
    lock_tx_len:   u8              = 0,
    spend_tx_hash: [TX_HEX_LEN]u8 = [_]u8{0} ** TX_HEX_LEN,
    spend_tx_len:  u8              = 0,

    pub fn idSlice(self: *const TimelockVault) []const u8     { return self.id[0..ID_HEX_LEN]; }
    pub fn ownerSlice(self: *const TimelockVault) []const u8  { return self.owner_address[0..self.owner_len]; }
    pub fn destSlice(self: *const TimelockVault) []const u8   { return self.dest_address[0..self.dest_len]; }
    pub fn lockTxSlice(self: *const TimelockVault) []const u8 { return self.lock_tx_hash[0..self.lock_tx_len]; }
    pub fn spendTxSlice(self: *const TimelockVault) []const u8{ return self.spend_tx_hash[0..self.spend_tx_len]; }

    pub fn isUnlocked(self: *const TimelockVault, current_block: u64) bool {
        return current_block >= self.unlock_block and self.state != .spent;
    }

    pub fn blocksRemaining(self: *const TimelockVault, current_block: u64) u64 {
        if (current_block >= self.unlock_block) return 0;
        return self.unlock_block - current_block;
    }
};

/// Compute vault ID as sha256(owner || dest || unlock_block_le8).
pub fn computeVaultId(owner: []const u8, dest: []const u8, unlock_block: u64, out: *[32]u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(owner);
    h.update(dest);
    var blk_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &blk_bytes, unlock_block, .little);
    h.update(&blk_bytes);
    h.final(out);
}

pub fn bytesToHex(bytes: []const u8, out: []u8) void {
    const hex_chars = "0123456789abcdef";
    var i: usize = 0;
    for (bytes) |b| {
        out[i]   = hex_chars[b >> 4];
        out[i+1] = hex_chars[b & 0xf];
        i += 2;
    }
}

pub const TimelockStore = struct {
    vaults:    array_list.Managed(TimelockVault),
    mutex:     std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TimelockStore {
        return .{
            .vaults    = array_list.Managed(TimelockVault).init(allocator),
            .mutex     = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TimelockStore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.vaults.deinit();
    }

    /// Create a new vault. Returns the hex vault ID or error.
    pub fn create(
        self:          *TimelockStore,
        owner:         []const u8,
        dest:          []const u8,
        amount_sat:    u64,
        unlock_block:  u64,
        created_block: u64,
        lock_tx_hash:  []const u8,
    ) ![ID_HEX_LEN]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.vaults.items.len >= MAX_VAULTS) return error.StoreFull;

        var id_bytes: [32]u8 = undefined;
        computeVaultId(owner, dest, unlock_block, &id_bytes);
        var id_hex: [ID_HEX_LEN]u8 = undefined;
        bytesToHex(&id_bytes, &id_hex);

        // Reject duplicate id
        for (self.vaults.items) |v| {
            if (std.mem.eql(u8, &v.id, &id_hex)) return error.DuplicateVault;
        }

        var vault = TimelockVault{
            .amount_sat    = amount_sat,
            .unlock_block  = unlock_block,
            .created_block = created_block,
            .state         = .locked,
        };
        vault.id = id_hex;

        const oc = @min(owner.len, ADDR_MAX - 1);
        @memcpy(vault.owner_address[0..oc], owner[0..oc]);
        vault.owner_len = @intCast(oc);

        const dc = @min(dest.len, ADDR_MAX - 1);
        @memcpy(vault.dest_address[0..dc], dest[0..dc]);
        vault.dest_len = @intCast(dc);

        const tc = @min(lock_tx_hash.len, TX_HEX_LEN);
        @memcpy(vault.lock_tx_hash[0..tc], lock_tx_hash[0..tc]);
        vault.lock_tx_len = @intCast(tc);

        try self.vaults.append(vault);
        return id_hex;
    }

    /// Mark vault as spent (called by blockchain validate + apply). Returns false if invalid.
    pub fn markSpent(
        self:          *TimelockStore,
        id_hex:        []const u8,
        spend_tx_hash: []const u8,
        current_block: u64,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.vaults.items) |*v| {
            if (!std.mem.eql(u8, &v.id, id_hex)) continue;
            if (current_block < v.unlock_block) return false; // still locked
            if (v.state == .spent) return false;              // already spent
            v.state = .spent;
            const sc = @min(spend_tx_hash.len, TX_HEX_LEN);
            @memcpy(v.spend_tx_hash[0..sc], spend_tx_hash[0..sc]);
            v.spend_tx_len = @intCast(sc);
            return true;
        }
        return false; // not found
    }

    /// Get vault by hex id (returns a copy).
    pub fn getById(self: *TimelockStore, id_hex: []const u8) ?TimelockVault {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.vaults.items) |v| {
            if (std.mem.eql(u8, v.id[0..ID_HEX_LEN], id_hex)) return v;
        }
        return null;
    }

    /// Validate a spend attempt (called from blockchain validateTransaction).
    /// Returns true if the spend is valid (block >= unlock, dest matches, amount matches).
    pub fn validateSpend(
        self:          *TimelockStore,
        id_hex:        []const u8,
        to_address:    []const u8,
        amount_sat:    u64,
        current_block: u64,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.vaults.items) |v| {
            if (!std.mem.eql(u8, v.id[0..ID_HEX_LEN], id_hex)) continue;
            if (v.state == .spent) return false;
            if (current_block < v.unlock_block) return false;
            if (!std.mem.eql(u8, v.destSlice(), to_address)) return false;
            if (amount_sat != v.amount_sat) return false;
            return true;
        }
        return false; // vault not found
    }

    /// List all vaults for a given owner (max out.len).
    pub fn listByOwner(self: *TimelockStore, owner: []const u8, out: []TimelockVault) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.vaults.items) |v| {
            if (!std.mem.eql(u8, v.ownerSlice(), owner)) continue;
            if (n >= out.len) break;
            out[n] = v;
            n += 1;
        }
        return n;
    }
};
