// core/evm/interpreter.zig — OmniBus EVM bytecode interpreter
//
// MVP subset — enough opcodes to pass tests and run basic DeFi contracts.
// chain_id = 7771 (CHAINID opcode).
//
// KECCAK256 stub: uses std.crypto.hash.sha2.Sha256 — KNOWN INCORRECT.
// Will be replaced with real Keccak-256 when keccak port lands in std.
//
// No liboqs dependency. Pure Zig + std only.

const std = @import("std");
const types = @import("types.zig");
const state_mod = @import("state.zig");

pub const U256 = types.U256;
pub const Address = types.Address;
pub const ExecStatus = types.ExecStatus;
pub const ExecResult = types.ExecResult;
pub const Log = types.Log;
pub const EvmState = state_mod.EvmState;
pub const Account = state_mod.Account;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const STACK_MAX: usize = 1024;
const CHAIN_ID: u64 = 7771;

// ---------------------------------------------------------------------------
// Stack
// ---------------------------------------------------------------------------
pub const Stack = struct {
    data: [STACK_MAX]U256,
    top: usize, // number of items on stack

    pub fn init() Stack {
        return Stack{ .data = undefined, .top = 0 };
    }

    pub fn push(self: *Stack, v: U256) !void {
        if (self.top >= STACK_MAX) return error.StackOverflow;
        self.data[self.top] = v;
        self.top += 1;
    }

    pub fn pop(self: *Stack) !U256 {
        if (self.top == 0) return error.StackUnderflow;
        self.top -= 1;
        return self.data[self.top];
    }

    pub fn peek(self: *const Stack) !U256 {
        if (self.top == 0) return error.StackUnderflow;
        return self.data[self.top - 1];
    }

    /// Peek at position n from top (0=top, 1=second, ...)
    pub fn peek_n(self: *const Stack, n: usize) !U256 {
        if (n >= self.top) return error.StackUnderflow;
        return self.data[self.top - 1 - n];
    }

    pub fn set_n(self: *Stack, n: usize, v: U256) !void {
        if (n >= self.top) return error.StackUnderflow;
        self.data[self.top - 1 - n] = v;
    }
};

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------
pub const Memory = struct {
    data: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) Memory {
        return Memory{ .data = .empty, .alloc = a };
    }

    pub fn deinit(self: *Memory) void {
        self.data.deinit(self.alloc);
    }

    /// Ensure memory is at least `offset + sz` bytes, zero-filling new space.
    pub fn ensure(self: *Memory, offset: u64, sz: u64) !void {
        if (sz == 0) return;
        const needed = offset + sz;
        if (needed > self.data.items.len) {
            const old_len = self.data.items.len;
            try self.data.resize(self.alloc, needed);
            @memset(self.data.items[old_len..needed], 0);
        }
    }

    pub fn mem_size(self: *const Memory) u64 {
        return self.data.items.len;
    }

    pub fn load32(self: *Memory, offset: u64) !U256 {
        try self.ensure(offset, 32);
        var b: [32]u8 = undefined;
        @memcpy(&b, self.data.items[offset .. offset + 32]);
        return U256.from_bytes32(b);
    }

    pub fn store32(self: *Memory, offset: u64, v: U256) !void {
        try self.ensure(offset, 32);
        const b = v.to_bytes32();
        @memcpy(self.data.items[offset .. offset + 32], &b);
    }

    pub fn store8(self: *Memory, offset: u64, byte: u8) !void {
        try self.ensure(offset, 1);
        self.data.items[offset] = byte;
    }

    pub fn read_bytes(self: *Memory, offset: u64, size_: u64) ![]u8 {
        try self.ensure(offset, size_);
        return self.data.items[offset .. offset + size_];
    }

    pub fn copy_into(self: *Memory, dst: u64, src: u64, sz: u64) !void {
        try self.ensure(@max(dst, src) + sz, 0);
        try self.ensure(dst, sz);
        try self.ensure(src, sz);
        if (sz == 0) return;
        // Handle overlapping ranges safely
        std.mem.copyForwards(u8, self.data.items[dst .. dst + sz], self.data.items[src .. src + sz]);
    }
};

// ---------------------------------------------------------------------------
// Keccak256 stub (SHA-256 — known incorrect, placeholder)
// NOTE: Replace with real Keccak-256 when std.crypto.hash.keccak lands or
//       a port becomes available. Tagged as STUB in comments throughout.
// ---------------------------------------------------------------------------
fn keccak256_stub(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

// ---------------------------------------------------------------------------
// Context passed to interpret()
// ---------------------------------------------------------------------------
pub const CallContext = struct {
    caller: Address,
    callee: Address,
    value: u64,
    calldata: []const u8,
    gas_limit: u64,
    is_static: bool,
    block_number: u64,
    timestamp: u64,
    chain_id: u64,
};

// ---------------------------------------------------------------------------
// interpret — main bytecode execution loop
// ---------------------------------------------------------------------------
/// Execute `bytecode` with given context. State changes are applied to `state`
/// directly (caller is responsible for cloning for read-only semantics).
/// Returns ExecResult allocated with `alloc`.
pub fn interpret(
    alloc: std.mem.Allocator,
    state: *EvmState,
    bytecode: []const u8,
    ctx: CallContext,
) !ExecResult {
    var stack = Stack.init();
    var memory = Memory.init(alloc);
    defer memory.deinit();
    var gas: u64 = ctx.gas_limit;
    var pc: u64 = 0;
    var logs: std.ArrayList(Log) = .empty;
    errdefer logs.deinit(alloc);

    // Track warm storage slots (address+slot pairs accessed this tx)
    // (simplified: we don't implement full EIP-2929 cold/warm accounting,
    //  just flat gas costs per the MVP constraints)

    // Pre-scan JUMPDEST set
    var jumpdest_set = std.AutoHashMap(u64, void).init(alloc);
    defer jumpdest_set.deinit();
    {
        var i: u64 = 0;
        while (i < bytecode.len) {
            const op = bytecode[@intCast(i)];
            if (op == 0x5b) { // JUMPDEST
                try jumpdest_set.put(i, {});
            }
            if (op >= 0x60 and op <= 0x7f) {
                i += @as(u64, op - 0x60 + 2); // skip push bytes
            } else {
                i += 1;
            }
        }
    }

    const use_gas = struct {
        fn f(g: *u64, cost: u64) bool {
            if (g.* < cost) return false;
            g.* -= cost;
            return true;
        }
    }.f;

    while (pc < bytecode.len) {
        const opcode = bytecode[@intCast(pc)];
        pc += 1;

        switch (opcode) {
            // --- STOP ---
            0x00 => {
                return ExecResult{
                    .gas_used = ctx.gas_limit - gas,
                    .status = .success,
                    .output = try alloc.dupe(u8, &.{}),
                    .contract_addr = null,
                    .logs = try logs.toOwnedSlice(alloc),
                };
            },

            // --- ADD ---
            0x01 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.add(b));
            },

            // --- MUL ---
            0x02 => {
                if (!use_gas(&gas, 5)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.mul(b));
            },

            // --- SUB ---
            0x03 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.sub(b));
            },

            // --- DIV ---
            0x04 => {
                if (!use_gas(&gas, 5)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.div(b));
            },

            // --- SDIV (signed) — simplified: treat as unsigned for MVP ---
            0x05 => {
                if (!use_gas(&gas, 5)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.div(b));
            },

            // --- MOD ---
            0x06 => {
                if (!use_gas(&gas, 5)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.mod(b));
            },

            // --- SMOD (signed mod) — simplified: treat as unsigned for MVP ---
            0x07 => {
                if (!use_gas(&gas, 5)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.mod(b));
            },

            // --- ADDMOD ---
            0x08 => {
                if (!use_gas(&gas, 8)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                const n = try stack.pop();
                if (n.is_zero()) {
                    try stack.push(U256.ZERO);
                } else {
                    try stack.push(a.add(b).mod(n));
                }
            },

            // --- MULMOD ---
            0x09 => {
                if (!use_gas(&gas, 8)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                const n = try stack.pop();
                if (n.is_zero()) {
                    try stack.push(U256.ZERO);
                } else {
                    try stack.push(a.mul(b).mod(n));
                }
            },

            // --- EXP (simplified: 10 + 50*byte_len(exponent)) ---
            0x0a => {
                const base_val = try stack.peek_n(0);
                const exp_val = try stack.peek_n(1);
                _ = base_val;
                // Compute significant byte count of exponent
                const exp_bytes = exp_val.to_bytes32();
                var byte_len: u64 = 0;
                for (exp_bytes) |b| {
                    if (b != 0) { byte_len = 32; break; }
                }
                if (byte_len == 0) {
                    // find last nonzero byte from MSB
                    var bl: u64 = 32;
                    for (exp_bytes) |b| {
                        if (b != 0) break;
                        bl -= 1;
                    }
                    byte_len = bl;
                }
                const gas_cost = 10 + 50 * byte_len;
                if (!use_gas(&gas, gas_cost)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                // Simple exp via repeated squaring (mod 2^256)
                var result = U256.ONE;
                var base = a;
                var exp = b;
                while (!exp.is_zero()) {
                    if (exp.words[3] & 1 == 1) {
                        result = result.mul(base);
                    }
                    base = base.mul(base);
                    exp = exp.shr(1);
                }
                try stack.push(result);
            },

            // --- SIGNEXTEND ---
            0x0b => {
                if (!use_gas(&gas, 5)) return halt(alloc, ctx.gas_limit, &logs);
                const b = try stack.pop();
                const x = try stack.pop();
                const byte_num = b.to_u64();
                if (byte_num >= 31) {
                    try stack.push(x);
                } else {
                    const bit_index = byte_num * 8 + 7;
                    const xbytes = x.to_bytes32();
                    const byte_idx: usize = 31 - @as(usize, @intCast(byte_num));
                    const sign_bit = (xbytes[byte_idx] >> 7) & 1;
                    var result_bytes = xbytes;
                    if (sign_bit == 1) {
                        // Fill upper bytes with 0xFF
                        var i: usize = 0;
                        while (i < byte_idx) : (i += 1) {
                            result_bytes[i] = 0xFF;
                        }
                        result_bytes[byte_idx] |= @as(u8, 0xFF) << @intCast((bit_index % 8) + 1 - (if (bit_index % 8 == 7) @as(u8, 0) else @as(u8, 0)));
                    } else {
                        var i: usize = 0;
                        while (i < byte_idx) : (i += 1) {
                            result_bytes[i] = 0;
                        }
                        result_bytes[byte_idx] &= (@as(u8, 0xFF) >> @intCast(7 - bit_index % 8));
                    }
                    try stack.push(U256.from_bytes32(result_bytes));
                }
            },

            // --- LT ---
            0x10 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(if (a.lt(b)) U256.ONE else U256.ZERO);
            },

            // --- GT ---
            0x11 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(if (a.gt(b)) U256.ONE else U256.ZERO);
            },

            // --- SLT (signed) — simplified as unsigned ---
            0x12 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(if (a.lt(b)) U256.ONE else U256.ZERO);
            },

            // --- SGT (signed) — simplified as unsigned ---
            0x13 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(if (a.gt(b)) U256.ONE else U256.ZERO);
            },

            // --- EQ ---
            0x14 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(if (a.eq(b)) U256.ONE else U256.ZERO);
            },

            // --- ISZERO ---
            0x15 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                try stack.push(if (a.is_zero()) U256.ONE else U256.ZERO);
            },

            // --- AND ---
            0x16 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.bitAnd(b));
            },

            // --- OR ---
            0x17 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.bitOr(b));
            },

            // --- XOR ---
            0x18 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                const b = try stack.pop();
                try stack.push(a.bitXor(b));
            },

            // --- NOT ---
            0x19 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const a = try stack.pop();
                try stack.push(a.bitNot());
            },

            // --- BYTE --- i-th byte of x (big-endian, i=0=MSB)
            0x1a => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const i = try stack.pop();
                const x = try stack.pop();
                const idx = i.to_u64();
                try stack.push(U256.from_u64(if (idx < 32) x.byte_at(idx) else 0));
            },

            // --- SHL ---
            0x1b => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const shift = try stack.pop();
                const val = try stack.pop();
                try stack.push(val.shl(shift.to_u64()));
            },

            // --- SHR ---
            0x1c => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const shift = try stack.pop();
                const val = try stack.pop();
                try stack.push(val.shr(shift.to_u64()));
            },

            // --- SAR (arithmetic shift right — simplified as logical for MVP) ---
            0x1d => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const shift = try stack.pop();
                const val = try stack.pop();
                try stack.push(val.shr(shift.to_u64()));
            },

            // --- KECCAK256 (SHA-256 stub — see note at top of file) ---
            0x20 => {
                const offset_v = try stack.peek_n(0);
                const size_v = try stack.peek_n(1);
                const offset = offset_v.to_u64();
                const sz = size_v.to_u64();
                const gas_cost: u64 = 30 + 6 * ((sz + 31) / 32);
                if (!use_gas(&gas, gas_cost)) return halt(alloc, ctx.gas_limit, &logs);
                _ = try stack.pop();
                _ = try stack.pop();
                const data = try memory.read_bytes(offset, sz);
                const hash = keccak256_stub(data);
                try stack.push(U256.from_bytes32(hash));
            },

            // --- ADDRESS ---
            0x30 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                var addr_u256 = U256.ZERO;
                // Store address in low 20 bytes
                var b = addr_u256.to_bytes32();
                @memcpy(b[12..32], &ctx.callee);
                try stack.push(U256.from_bytes32(b));
            },

            // --- BALANCE ---
            0x31 => {
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs); // warm cost
                const addr_v = try stack.pop();
                const addr_bytes = addr_v.to_bytes32();
                var addr: Address = undefined;
                @memcpy(&addr, addr_bytes[12..32]);
                const bal = state.getBalance(addr);
                try stack.push(U256.from_u64(bal));
            },

            // --- ORIGIN ---
            0x32 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                var b = [_]u8{0} ** 32;
                @memcpy(b[12..32], &ctx.caller);
                try stack.push(U256.from_bytes32(b));
            },

            // --- CALLER ---
            0x33 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                var b = [_]u8{0} ** 32;
                @memcpy(b[12..32], &ctx.caller);
                try stack.push(U256.from_bytes32(b));
            },

            // --- CALLVALUE ---
            0x34 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(ctx.value));
            },

            // --- CALLDATALOAD ---
            0x35 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const i = try stack.pop();
                const offset = i.to_u64();
                var b = [_]u8{0} ** 32;
                const cd = ctx.calldata;
                var j: usize = 0;
                while (j < 32 and offset + j < cd.len) : (j += 1) {
                    b[j] = cd[offset + j];
                }
                try stack.push(U256.from_bytes32(b));
            },

            // --- CALLDATASIZE ---
            0x36 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(ctx.calldata.len));
            },

            // --- CALLDATACOPY ---
            0x37 => {
                const dst_v = try stack.peek_n(0);
                const src_v = try stack.peek_n(1);
                const sz_v = try stack.peek_n(2);
                const sz = sz_v.to_u64();
                const gas_cost: u64 = 3 + 3 * ((sz + 31) / 32);
                if (!use_gas(&gas, gas_cost)) return halt(alloc, ctx.gas_limit, &logs);
                const dst = dst_v.to_u64();
                const src = src_v.to_u64();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                try memory.ensure(dst, sz);
                var j: u64 = 0;
                while (j < sz) : (j += 1) {
                    const cd_idx = src + j;
                    memory.data.items[dst + j] = if (cd_idx < ctx.calldata.len) ctx.calldata[@intCast(cd_idx)] else 0;
                }
            },

            // --- CODESIZE ---
            0x38 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(bytecode.len));
            },

            // --- CODECOPY ---
            0x39 => {
                const dst_v = try stack.peek_n(0);
                const src_v = try stack.peek_n(1);
                const sz_v = try stack.peek_n(2);
                const sz = sz_v.to_u64();
                const gas_cost: u64 = 3 + 3 * ((sz + 31) / 32);
                if (!use_gas(&gas, gas_cost)) return halt(alloc, ctx.gas_limit, &logs);
                const dst = dst_v.to_u64();
                const src = src_v.to_u64();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                try memory.ensure(dst, sz);
                var j: u64 = 0;
                while (j < sz) : (j += 1) {
                    const bc_idx = src + j;
                    memory.data.items[dst + j] = if (bc_idx < bytecode.len) bytecode[@intCast(bc_idx)] else 0;
                }
            },

            // --- GASPRICE (return 1 gwei placeholder) ---
            0x3a => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(1_000_000_000));
            },

            // --- EXTCODESIZE (return 0 for unknown addresses, MVP stub) ---
            0x3b => {
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs);
                const addr_v = try stack.pop();
                const addr_bytes = addr_v.to_bytes32();
                var addr: Address = undefined;
                @memcpy(&addr, addr_bytes[12..32]);
                const code_size = if (state.getAccountConst(addr)) |a| a.code.len else 0;
                try stack.push(U256.from_u64(code_size));
            },

            // --- EXTCODECOPY ---
            0x3c => {
                _ = try stack.pop(); // addr
                const dst_v = try stack.pop();
                _ = try stack.pop(); // srcOffset
                const sz_v = try stack.pop();
                const sz = sz_v.to_u64();
                const gas_cost: u64 = 100 + 3 * ((sz + 31) / 32);
                if (!use_gas(&gas, gas_cost)) return halt(alloc, ctx.gas_limit, &logs);
                // Stub: fill destination with zeros
                try memory.ensure(dst_v.to_u64(), sz);
            },

            // --- RETURNDATASIZE (stub: 0) ---
            0x3d => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.ZERO);
            },

            // --- RETURNDATACOPY (stub: fill zeros) ---
            0x3e => {
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
            },

            // --- EXTCODEHASH (stub: zeros) ---
            0x3f => {
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs);
                _ = try stack.pop();
                try stack.push(U256.ZERO);
            },

            // --- BLOCKHASH (stub: hash of block number string) ---
            0x40 => {
                if (!use_gas(&gas, 20)) return halt(alloc, ctx.gas_limit, &logs);
                const n = try stack.pop();
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "block-{}", .{n.to_u64()}) catch "block-0";
                try stack.push(U256.from_bytes32(keccak256_stub(s)));
            },

            // --- COINBASE (zero address stub) ---
            0x41 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.ZERO);
            },

            // --- TIMESTAMP ---
            0x42 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(ctx.timestamp));
            },

            // --- NUMBER ---
            0x43 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(ctx.block_number));
            },

            // --- PREVRANDAO / DIFFICULTY (stub: 0) ---
            0x44 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.ZERO);
            },

            // --- GASLIMIT ---
            0x45 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(ctx.gas_limit));
            },

            // --- CHAINID — OmniBus chain_id = 7771 ---
            0x46 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(ctx.chain_id));
            },

            // --- SELFBALANCE ---
            0x47 => {
                if (!use_gas(&gas, 5)) return halt(alloc, ctx.gas_limit, &logs);
                const bal = state.getBalance(ctx.callee);
                try stack.push(U256.from_u64(bal));
            },

            // --- BASEFEE (stub: 1 gwei) ---
            0x48 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(1_000_000_000));
            },

            // --- BLOBHASH (stub: 0) ---
            0x49 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                _ = try stack.pop();
                try stack.push(U256.ZERO);
            },

            // --- BLOBBASEFEE (stub: 0) ---
            0x4a => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.ZERO);
            },

            // --- POP ---
            0x50 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                _ = try stack.pop();
            },

            // --- MLOAD ---
            0x51 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const off = try stack.pop();
                const v = try memory.load32(off.to_u64());
                try stack.push(v);
            },

            // --- MSTORE ---
            0x52 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const off = try stack.pop();
                const val = try stack.pop();
                try memory.store32(off.to_u64(), val);
            },

            // --- MSTORE8 ---
            0x53 => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const off = try stack.pop();
                const val = try stack.pop();
                const byte_val: u8 = @intCast(val.to_u64() & 0xFF);
                try memory.store8(off.to_u64(), byte_val);
            },

            // --- SLOAD ---
            0x54 => {
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs); // warm cost
                const slot_v = try stack.pop();
                const slot = slot_v.to_bytes32();
                const val = state.readStorage(ctx.callee, slot);
                try stack.push(U256.from_bytes32(val));
            },

            // --- SSTORE ---
            0x55 => {
                if (ctx.is_static) return revert_result(alloc, ctx.gas_limit, gas, &.{}, &logs);
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs); // warm cost
                const slot_v = try stack.pop();
                const val_v = try stack.pop();
                const slot = slot_v.to_bytes32();
                const val = val_v.to_bytes32();
                try state.writeStorage(ctx.callee, slot, val);
            },

            // --- JUMP ---
            0x56 => {
                if (!use_gas(&gas, 8)) return halt(alloc, ctx.gas_limit, &logs);
                const dest = try stack.pop();
                const d = dest.to_u64();
                if (!jumpdest_set.contains(d)) return halt(alloc, ctx.gas_limit, &logs);
                pc = d + 1; // +1 because loop increments pc before opcode read
                // Actually we already incremented pc before switch, so set to d
                pc = d + 1;
            },

            // --- JUMPI ---
            0x57 => {
                if (!use_gas(&gas, 10)) return halt(alloc, ctx.gas_limit, &logs);
                const dest = try stack.pop();
                const cond = try stack.pop();
                if (!cond.is_zero()) {
                    const d = dest.to_u64();
                    if (!jumpdest_set.contains(d)) return halt(alloc, ctx.gas_limit, &logs);
                    pc = d + 1;
                }
            },

            // --- PC ---
            0x58 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                // pc was incremented past this opcode already
                try stack.push(U256.from_u64(pc - 1));
            },

            // --- MSIZE ---
            0x59 => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(memory.mem_size()));
            },

            // --- GAS ---
            0x5a => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.from_u64(gas));
            },

            // --- JUMPDEST ---
            0x5b => {
                if (!use_gas(&gas, 1)) return halt(alloc, ctx.gas_limit, &logs);
                // No-op marker; valid jump target already in set
            },

            // --- TLOAD (EIP-1153 transient, stub: 0) ---
            0x5c => {
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs);
                _ = try stack.pop();
                try stack.push(U256.ZERO);
            },

            // --- TSTORE (EIP-1153 transient, stub: discard) ---
            0x5d => {
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs);
                _ = try stack.pop();
                _ = try stack.pop();
            },

            // --- MCOPY (EIP-5656) ---
            0x5e => {
                const dst_v = try stack.pop();
                const src_v = try stack.pop();
                const sz_v = try stack.pop();
                const sz = sz_v.to_u64();
                const gas_cost: u64 = 3 + 3 * ((sz + 31) / 32);
                if (!use_gas(&gas, gas_cost)) return halt(alloc, ctx.gas_limit, &logs);
                try memory.copy_into(dst_v.to_u64(), src_v.to_u64(), sz);
            },

            // --- PUSH0 (EIP-3855) ---
            0x5f => {
                if (!use_gas(&gas, 2)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.ZERO);
            },

            // --- PUSH1..PUSH32 (0x60..0x7f) ---
            0x60...0x7f => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const n_bytes: u64 = opcode - 0x60 + 1;
                var bytes = [_]u8{0} ** 32;
                const dst_start = 32 - n_bytes;
                var i: u64 = 0;
                while (i < n_bytes and pc + i < bytecode.len) : (i += 1) {
                    bytes[dst_start + i] = bytecode[@intCast(pc + i)];
                }
                pc += n_bytes;
                try stack.push(U256.from_bytes32(bytes));
            },

            // --- DUP1..DUP16 (0x80..0x8f) ---
            0x80...0x8f => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const n = opcode - 0x80; // 0-indexed, DUP1 = duplicate top (index 0)
                const v = try stack.peek_n(n);
                try stack.push(v);
            },

            // --- SWAP1..SWAP16 (0x90..0x9f) ---
            0x90...0x9f => {
                if (!use_gas(&gas, 3)) return halt(alloc, ctx.gas_limit, &logs);
                const n = opcode - 0x90 + 1; // SWAP1 swaps top with index 1
                const top = try stack.peek_n(0);
                const other = try stack.peek_n(n);
                try stack.set_n(0, other);
                try stack.set_n(n, top);
            },

            // --- LOG0..LOG4 (0xa0..0xa4) ---
            0xa0...0xa4 => {
                if (ctx.is_static) return revert_result(alloc, ctx.gas_limit, gas, &.{}, &logs);
                const n_topics = opcode - 0xa0;
                const offset_v = try stack.pop();
                const sz_v = try stack.pop();
                const offset = offset_v.to_u64();
                const sz = sz_v.to_u64();
                const gas_cost: u64 = 375 + 8 * sz + 375 * @as(u64, n_topics);
                if (!use_gas(&gas, gas_cost)) return halt(alloc, ctx.gas_limit, &logs);

                var topics = try alloc.alloc([32]u8, n_topics);
                errdefer alloc.free(topics);
                var ti: u64 = 0;
                while (ti < n_topics) : (ti += 1) {
                    const t = try stack.pop();
                    topics[ti] = t.to_bytes32();
                }

                const log_data = try memory.read_bytes(offset, sz);
                const log_data_copy = try alloc.dupe(u8, log_data);
                errdefer alloc.free(log_data_copy);

                try logs.append(alloc, Log{
                    .address = ctx.callee,
                    .topics = topics,
                    .data = log_data_copy,
                    .block = ctx.block_number,
                    .tx_hash = [_]u8{0} ** 32,
                });
            },

            // --- CREATE (stub: deploy initcode, return zero address for now) ---
            0xf0 => {
                const value_v = try stack.pop();
                const offset_v = try stack.pop();
                const sz_v = try stack.pop();
                _ = value_v;
                const offset = offset_v.to_u64();
                const sz = sz_v.to_u64();
                const gas_cost: u64 = 32000 + 2 * ((sz + 31) / 32);
                if (!use_gas(&gas, gas_cost)) return halt(alloc, ctx.gas_limit, &logs);
                // Read initcode
                const initcode = try memory.read_bytes(offset, sz);
                // Compute contract address: sha256(caller || nonce) — stub
                var input: [28]u8 = undefined;
                @memcpy(input[0..20], &ctx.caller);
                const nonce = state.getNonce(ctx.caller);
                std.mem.writeInt(u64, input[20..28], nonce, .big);
                const addr_hash = keccak256_stub(&input);
                var new_addr: Address = undefined;
                @memcpy(&new_addr, addr_hash[12..32]);

                // Run initcode
                const init_ctx = CallContext{
                    .caller = ctx.caller,
                    .callee = new_addr,
                    .value = 0,
                    .calldata = &.{},
                    .gas_limit = gas / 2,
                    .is_static = ctx.is_static,
                    .block_number = ctx.block_number,
                    .timestamp = ctx.timestamp,
                    .chain_id = ctx.chain_id,
                };
                const init_result = try interpret(alloc, state, initcode, init_ctx);
                defer alloc.free(init_result.output);
                defer alloc.free(init_result.logs);

                if (init_result.status == .success) {
                    // Store returned bytecode as contract code
                    const code_hash = keccak256_stub(init_result.output);
                    try state.setAccount(new_addr, Account{
                        .balance = 0,
                        .nonce = 0,
                        .code = init_result.output,
                        .code_hash = code_hash,
                    });
                    // Return address on stack
                    var b = [_]u8{0} ** 32;
                    @memcpy(b[12..32], &new_addr);
                    try stack.push(U256.from_bytes32(b));
                } else {
                    try stack.push(U256.ZERO);
                }
            },

            // --- CALL (simple ETH transfer, no sub-context for MVP) ---
            0xf1 => {
                const gas_param = try stack.pop();
                const addr_v = try stack.pop();
                const value_v = try stack.pop();
                _ = try stack.pop(); // inOff
                _ = try stack.pop(); // inSz
                _ = try stack.pop(); // outOff
                _ = try stack.pop(); // outSz
                _ = gas_param;

                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs);

                const addr_bytes = addr_v.to_bytes32();
                var target_addr: Address = undefined;
                @memcpy(&target_addr, addr_bytes[12..32]);
                const transfer_val = value_v.to_u64();

                if (ctx.is_static and transfer_val > 0) {
                    // WriteProtection
                    try stack.push(U256.ZERO);
                } else {
                    const sender_bal = state.getBalance(ctx.callee);
                    if (sender_bal >= transfer_val) {
                        // Deduct from sender
                        var sender_acc = state.getAccount(ctx.callee) orelse Account{
                            .balance = sender_bal, .nonce = 0, .code = &.{}, .code_hash = [_]u8{0} ** 32,
                        };
                        sender_acc.balance -= transfer_val;
                        try state.setAccount(ctx.callee, sender_acc);

                        // Credit recipient
                        var recv_acc = state.getAccount(target_addr) orelse Account{
                            .balance = 0, .nonce = 0, .code = &.{}, .code_hash = [_]u8{0} ** 32,
                        };
                        recv_acc.balance += transfer_val;
                        try state.setAccount(target_addr, recv_acc);
                        try stack.push(U256.ONE);
                    } else {
                        try stack.push(U256.ZERO);
                    }
                }
            },

            // --- CALLCODE (deprecated, stub: push 0) ---
            0xf2 => {
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.ZERO);
            },

            // --- RETURN ---
            0xf3 => {
                const offset_v = try stack.pop();
                const sz_v = try stack.pop();
                const offset = offset_v.to_u64();
                const sz = sz_v.to_u64();
                if (!use_gas(&gas, 0)) return halt(alloc, ctx.gas_limit, &logs);
                const ret_data = try memory.read_bytes(offset, sz);
                return ExecResult{
                    .gas_used = ctx.gas_limit - gas,
                    .status = .success,
                    .output = try alloc.dupe(u8, ret_data),
                    .contract_addr = null,
                    .logs = try logs.toOwnedSlice(alloc),
                };
            },

            // --- DELEGATECALL (stub: push 0) ---
            0xf4 => {
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.ZERO);
            },

            // --- CREATE2 (stub: push 0 address) ---
            0xf5 => {
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                if (!use_gas(&gas, 32000)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.ZERO);
            },

            // --- STATICCALL (stub: push 0) ---
            0xfa => {
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                _ = try stack.pop();
                if (!use_gas(&gas, 100)) return halt(alloc, ctx.gas_limit, &logs);
                try stack.push(U256.ZERO);
            },

            // --- REVERT ---
            0xfd => {
                const offset_v = try stack.pop();
                const sz_v = try stack.pop();
                const offset = offset_v.to_u64();
                const sz = sz_v.to_u64();
                const ret_data = try memory.read_bytes(offset, sz);
                return revert_result(alloc, ctx.gas_limit, gas, ret_data, &logs);
            },

            // --- INVALID (0xfe) and any unrecognized opcode ---
            0xfe => {
                return halt(alloc, ctx.gas_limit, &logs);
            },

            // --- SELFDESTRUCT ---
            0xff => {
                if (ctx.is_static) return revert_result(alloc, ctx.gas_limit, gas, &.{}, &logs);
                _ = try stack.pop(); // beneficiary addr (ignored in MVP)
                if (!use_gas(&gas, 5000)) return halt(alloc, ctx.gas_limit, &logs);
                // Zero out the account
                try state.setAccount(ctx.callee, Account{
                    .balance = 0,
                    .nonce = 0,
                    .code = &.{},
                    .code_hash = [_]u8{0} ** 32,
                });
                return ExecResult{
                    .gas_used = ctx.gas_limit - gas,
                    .status = .success,
                    .output = try alloc.dupe(u8, &.{}),
                    .contract_addr = null,
                    .logs = try logs.toOwnedSlice(alloc),
                };
            },

            else => {
                // Unrecognized opcode → INVALID
                return halt(alloc, ctx.gas_limit, &logs);
            },
        }
    }

    // Fell off the end of bytecode → implicit STOP
    return ExecResult{
        .gas_used = ctx.gas_limit - gas,
        .status = .success,
        .output = try alloc.dupe(u8, &.{}),
        .contract_addr = null,
        .logs = try logs.toOwnedSlice(alloc),
    };
}

fn halt(alloc: std.mem.Allocator, gas_limit: u64, logs: *std.ArrayList(Log)) !ExecResult {
    _ = gas_limit;
    return ExecResult{
        .gas_used = 0, // consumed all gas
        .status = .halt,
        .output = try alloc.dupe(u8, &.{}),
        .contract_addr = null,
        .logs = try logs.toOwnedSlice(alloc),
    };
}

fn revert_result(alloc: std.mem.Allocator, gas_limit: u64, gas: u64, data: []const u8, logs: *std.ArrayList(Log)) !ExecResult {
    return ExecResult{
        .gas_used = gas_limit - gas,
        .status = .revert,
        .output = try alloc.dupe(u8, data),
        .contract_addr = null,
        .logs = try logs.toOwnedSlice(alloc),
    };
}
