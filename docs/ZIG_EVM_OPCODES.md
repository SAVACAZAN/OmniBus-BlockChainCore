# ZIG_EVM_OPCODES.md — OmniBus EVM Opcode Reference

> Port target: replace `revm` in `core-rust/src/evm/executor.rs` with a
> native Zig EVM. Swap `use crate::evm::executor` for `use crate::evm::zig_executor`
> in `interface.rs` — nothing else changes.
>
> chain_id = **7771** (CHAINID opcode must return this)

---

## How to read the table

```
0xNN  MNEMONIC  — stack-in → stack-out  — base gas  — notes
```

Stack notation: `a, b` = `a` is top, `b` is second.  
`*` in gas = variable (see subsection notes).

---

## 1. Stop & Arithmetic

| Hex  | Mnemonic | Stack effect         | Gas | Notes |
|------|----------|----------------------|-----|-------|
| 0x00 | STOP     | — → —                | 0   | Halt, success |
| 0x01 | ADD      | a, b → a+b           | 3   | mod 2²⁵⁶ |
| 0x02 | MUL      | a, b → a*b           | 5   | mod 2²⁵⁶ |
| 0x03 | SUB      | a, b → a-b           | 3   | mod 2²⁵⁶ |
| 0x04 | DIV      | a, b → a/b           | 5   | 0 if b=0 |
| 0x05 | SDIV     | a, b → a/b (signed)  | 5   | two's-complement |
| 0x06 | MOD      | a, b → a mod b       | 5   | 0 if b=0 |
| 0x07 | SMOD     | a, b → a smod b      | 5   | sign follows a |
| 0x08 | ADDMOD   | a, b, N → (a+b) mod N| 8   | 0 if N=0 |
| 0x09 | MULMOD   | a, b, N → (a*b) mod N| 8   | 0 if N=0 |
| 0x0a | EXP      | a, b → a**b          | *   | 10 + 50*byte_len(b) |
| 0x0b | SIGNEXTEND | b, x → y           | 5   | sign-extend x from b-th byte |

---

## 2. Comparison & Bitwise

| Hex  | Mnemonic | Stack effect     | Gas | Notes |
|------|----------|------------------|-----|-------|
| 0x10 | LT       | a, b → a<b       | 3   | 1 if true, else 0 |
| 0x11 | GT       | a, b → a>b       | 3   | |
| 0x12 | SLT      | a, b → a<b (s)   | 3   | signed |
| 0x13 | SGT      | a, b → a>b (s)   | 3   | signed |
| 0x14 | EQ       | a, b → a==b      | 3   | |
| 0x15 | ISZERO   | a → a==0         | 3   | |
| 0x16 | AND      | a, b → a&b       | 3   | |
| 0x17 | OR       | a, b → a\|b      | 3   | |
| 0x18 | XOR      | a, b → a^b       | 3   | |
| 0x19 | NOT      | a → ~a           | 3   | bitwise NOT |
| 0x1a | BYTE     | i, x → y        | 3   | i-th byte of x (BE) |
| 0x1b | SHL      | shift, val → val<<shift | 3 | EIP-145 |
| 0x1c | SHR      | shift, val → val>>shift | 3 | EIP-145, logical |
| 0x1d | SAR      | shift, val → val>>shift | 3 | EIP-145, arithmetic |

---

## 3. SHA3 / Keccak

| Hex  | Mnemonic | Stack effect          | Gas | Notes |
|------|----------|-----------------------|-----|-------|
| 0x20 | KECCAK256| offset, size → hash   | *   | 30 + 6*ceil(size/32) + mem expansion |

---

## 4. Environmental Information

| Hex  | Mnemonic       | Stack effect         | Gas | Notes |
|------|----------------|----------------------|-----|-------|
| 0x30 | ADDRESS        | — → addr             | 2   | current executing contract |
| 0x31 | BALANCE        | addr → bal           | *   | 2600 cold / 100 warm (EIP-2929) |
| 0x32 | ORIGIN         | — → addr             | 2   | tx origin (EOA) |
| 0x33 | CALLER         | — → addr             | 2   | msg.sender |
| 0x34 | CALLVALUE      | — → val              | 2   | msg.value (wei) |
| 0x35 | CALLDATALOAD   | i → data[i:i+32]     | 3   | |
| 0x36 | CALLDATASIZE   | — → size             | 2   | |
| 0x37 | CALLDATACOPY   | dstOff, srcOff, size | 3+* | 3 + 3*ceil(size/32) + mem |
| 0x38 | CODESIZE       | — → size             | 2   | |
| 0x39 | CODECOPY       | dstOff, srcOff, size | 3+* | |
| 0x3a | GASPRICE       | — → price            | 2   | effective gas price |
| 0x3b | EXTCODESIZE    | addr → size          | *   | 2600 cold / 100 warm |
| 0x3c | EXTCODECOPY    | addr,dOff,sOff,size  | *   | cold/warm + copy cost |
| 0x3d | RETURNDATASIZE | — → size             | 2   | EIP-211 |
| 0x3e | RETURNDATACOPY | dOff, sOff, size     | 3+* | EIP-211 |
| 0x3f | EXTCODEHASH    | addr → hash          | *   | 2600 cold / 100 warm; EIP-1052 |

---

## 5. Block Information

| Hex  | Mnemonic    | Stack effect     | Gas | Notes |
|------|-------------|------------------|-----|-------|
| 0x40 | BLOCKHASH   | N → hash         | 20  | last 256 blocks; 0 if out of range |
| 0x41 | COINBASE    | — → addr         | 2   | block beneficiary |
| 0x42 | TIMESTAMP   | — → t            | 2   | Unix seconds |
| 0x43 | NUMBER      | — → N            | 2   | current block number |
| 0x44 | PREVRANDAO  | — → mix          | 2   | was DIFFICULTY; EIP-4399 |
| 0x45 | GASLIMIT    | — → lim          | 2   | |
| 0x46 | CHAINID     | — → id           | 2   | **7771** for OmniBus |
| 0x47 | SELFBALANCE | — → bal          | 5   | EIP-1884 |
| 0x48 | BASEFEE     | — → fee          | 2   | EIP-3198 |
| 0x49 | BLOBHASH    | i → hash         | 3   | EIP-4844; empty on OmniBus |
| 0x4a | BLOBBASEFEE | — → fee          | 2   | EIP-7516 |

---

## 6. Stack, Memory, Storage, Flow

### Stack

| Hex  | Mnemonic | Stack effect          | Gas | Notes |
|------|----------|-----------------------|-----|-------|
| 0x50 | POP      | a → —                 | 2   | discard top |
| 0x5b | JUMPDEST | — → —                 | 1   | valid jump target marker |

### Memory

| Hex  | Mnemonic | Stack effect             | Gas | Notes |
|------|----------|--------------------------|-----|-------|
| 0x51 | MLOAD    | offset → val             | 3+* | 32 bytes from memory |
| 0x52 | MSTORE   | offset, val              | 3+* | write 32 bytes |
| 0x53 | MSTORE8  | offset, val              | 3+* | write 1 byte (low byte of val) |
| 0x59 | MSIZE    | — → size                 | 2   | current memory size in bytes |
| 0x5e | MCOPY    | dOff, sOff, size         | 3+* | EIP-5656; in-memory copy |

### Storage

> **EIP-2929 cold/warm access:**
> - First access to (addr, slot) in tx → **cold**: SLOAD=2100, SSTORE=20000 (new) or 2900 (modified)
> - Subsequent accesses → **warm**: SLOAD=100, SSTORE=100
> - tx.access_list (EIP-2930) pre-warms slots at 2400 per slot.

| Hex  | Mnemonic | Stack effect          | Gas        | Notes |
|------|----------|-----------------------|------------|-------|
| 0x54 | SLOAD    | slot → val            | 2100/100   | cold/warm EIP-2929 |
| 0x55 | SSTORE   | slot, val             | *          | cold 20000 new, 2900 dirty; warm 100; EIP-2929 + EIP-3529 refunds |
| 0x5c | TLOAD    | slot → val            | 100        | EIP-1153 transient storage |
| 0x5d | TSTORE   | slot, val             | 100        | EIP-1153 |

### Flow Control

| Hex  | Mnemonic | Stack effect   | Gas | Notes |
|------|----------|----------------|-----|-------|
| 0x56 | JUMP     | dest → —       | 8   | dest must be JUMPDEST |
| 0x57 | JUMPI    | dest, cond → — | 10  | jump if cond≠0 |
| 0x58 | PC       | — → pc         | 2   | program counter before this instruction |
| 0x5a | GAS      | — → gas        | 2   | remaining gas |

---

## 7. PUSH / DUP / SWAP / LOG

### PUSH (0x5f – 0x7f)

| Hex  | Mnemonic  | Bytes pushed | Gas |
|------|-----------|--------------|-----|
| 0x5f | PUSH0     | 0            | 2   | EIP-3855 |
| 0x60 | PUSH1     | 1            | 3   | |
| 0x61 | PUSH2     | 2            | 3   | |
| …    | …         | …            | 3   | |
| 0x7f | PUSH32    | 32           | 3   | |

### DUP (0x80 – 0x8f)

| Hex  | Mnemonic | Stack effect   | Gas |
|------|----------|----------------|-----|
| 0x80 | DUP1     | a → a, a       | 3   | duplicate 1st item |
| 0x81 | DUP2     | …              | 3   | duplicate 2nd item |
| …    | …        | …              | 3   | |
| 0x8f | DUP16    | …              | 3   | duplicate 16th item |

### SWAP (0x90 – 0x9f)

| Hex  | Mnemonic | Stack effect         | Gas |
|------|----------|----------------------|-----|
| 0x90 | SWAP1    | a, b → b, a          | 3   | |
| 0x91 | SWAP2    | a, _, b → b, _, a    | 3   | |
| …    | …        | …                    | 3   | |
| 0x9f | SWAP16   | …                    | 3   | |

### LOG (0xa0 – 0xa4)

| Hex  | Mnemonic | Stack effect                      | Gas   | Notes |
|------|----------|-----------------------------------|-------|-------|
| 0xa0 | LOG0     | offset, size                      | 375 + 8*size + mem | 0 topics |
| 0xa1 | LOG1     | offset, size, t1                  | 375 + 8*size + 375 | |
| 0xa2 | LOG2     | offset, size, t1, t2              | 375 + 8*size + 750 | |
| 0xa3 | LOG3     | offset, size, t1, t2, t3          | 375 + 8*size + 1125| |
| 0xa4 | LOG4     | offset, size, t1, t2, t3, t4      | 375 + 8*size + 1500| |

> LOGn is **forbidden** inside STATICCALL (WriteProtection).

---

## 8. System Operations

| Hex  | Mnemonic     | Stack effect                                    | Gas | Notes |
|------|--------------|-------------------------------------------------|-----|-------|
| 0xf0 | CREATE       | value, offset, size → addr                      | *   | 32000 + init_code_cost + mem |
| 0xf1 | CALL         | gas, addr, value, inOff, inSz, outOff, outSz → success | * | cold 2600, warm 100 + value_cost |
| 0xf2 | CALLCODE     | gas, addr, value, inOff, inSz, outOff, outSz → success | * | deprecated; caller's storage |
| 0xf3 | RETURN       | offset, size → (halt)                           | 0+* | mem expansion |
| 0xf4 | DELEGATECALL | gas, addr, inOff, inSz, outOff, outSz → success | *   | no value; inherits storage+caller |
| 0xf5 | CREATE2      | value, offset, size, salt → addr                | *   | EIP-1014; addr = keccak256(0xff++sender++salt++keccak256(init)) |
| 0xfa | STATICCALL   | gas, addr, inOff, inSz, outOff, outSz → success | *   | read-only sub-context |
| 0xfd | REVERT       | offset, size → (halt)                           | 0+* | revert with data; gas refunded |
| 0xfe | INVALID      | — → (halt)                                      | all | consume all gas, InvalidOpcode |
| 0xff | SELFDESTRUCT | addr → (halt)                                   | *   | EIP-6780: only in same tx as CREATE |

### CALL gas rules

```
call_cost = cold_access_cost           // 2600 cold, 100 warm (EIP-2929)
          + value_transfer_cost        // 9000 if value > 0
          + new_account_creation_cost  // 25000 if dest is new and value > 0
          + memory_expansion_cost
```

Gas forwarded to callee: `min(gas_remaining - gas_remaining/64, gas_param)` (EIP-150).

---

## 9. Precompiles (0x01 – 0x09)

| Addr | Name        | Gas formula                            | Notes |
|------|-------------|----------------------------------------|-------|
| 0x01 | ecRecover   | 3000                                   | ECDSA secp256k1 recovery |
| 0x02 | SHA2-256    | 60 + 12*ceil(len/32)                   | |
| 0x03 | RIPEMD-160  | 600 + 120*ceil(len/32)                 | output padded to 32 bytes |
| 0x04 | identity    | 15 + 3*ceil(len/32)                    | copy input to output |
| 0x05 | modexp      | EIP-198 formula (bigint exponentiation)| |
| 0x06 | ecAdd       | 150                                    | BN254 G1 addition (EIP-196) |
| 0x07 | ecMul       | 6000                                   | BN254 G1 scalar mul (EIP-196) |
| 0x08 | ecPairing   | 45000 + 34000*pairs                    | BN254 (EIP-197) |
| 0x09 | blake2f     | rounds                                 | BLAKE2b-F (EIP-152) |

---

## 10. Memory Expansion Gas

```
mem_cost(words) = 3 * words + words² / 512
expansion_gas   = mem_cost(new_words) - mem_cost(old_words)
```

where `words = ceil(bytes / 32)`.

---

## 11. EIP-2929 Cold/Warm Access Summary

```
COLD_ACCOUNT_ACCESS    = 2600   // first BALANCE / EXTCODE* / CALL to an address
WARM_ACCOUNT_ACCESS    = 100    // subsequent accesses in same tx
COLD_SLOAD             = 2100   // first SLOAD of a (addr, slot) in tx
WARM_SLOAD             = 100
SSTORE_SET             = 20000  // slot was 0 → non-zero
SSTORE_RESET           = 2900   // slot was non-zero → different non-zero
SSTORE_CLEARS_REFUND   = 4800   // EIP-3529: reduced refund cap
```

Pre-warming via `access_list` (EIP-2930): 2400 per slot, 2400 per address.

---

## 12. Intrinsic Gas (per transaction)

```
base_gas = 21_000                                // plain transfer
         + 4  * count(zero_data_bytes)           // EIP-3529
         + 16 * count(nonzero_data_bytes)        // EIP-2028
         + 32_000                                // CREATE
         + 2  * ceil(initcode_len / 32)          // EIP-3860 initcode cost
```

---

## 13. Zig Implementation Notes

1. **U256 representation**: use a `[4]u64` array, big-endian word order (word[0] = most significant).
2. **Stack**: a fixed `[1024]U256` array; top-of-stack pointer is an index.
3. **Memory**: a `std.ArrayList(u8)` or a slab allocator; always zero on first access.
4. **JUMPDEST validation**: pre-scan bytecode once at deploy time; cache valid JUMPDEST set.
5. **Nested calls**: recursive or iterative frame stack; max depth 1024 (EIP-150).
6. **Error handling**: return a tagged union `ExecResult` instead of panicking.
7. **Database interface**: match `EvmState` API:
   - `read_storage_slot(addr: [20]u8, slot: [32]u8) [32]u8`
   - `write_storage_slot(addr: [20]u8, slot: [32]u8, val: [32]u8) !void`
   - `code(addr: [20]u8) []const u8`
   - `balance(addr: [20]u8) u128`
   - `nonce(addr: [20]u8) u64`
8. **chain_id**: read from `EvmState.chain_id()` — do NOT hardcode; pass via block env.
