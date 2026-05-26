// ============================================
// tests/test_sighash.zig
// ============================================
const std = @import("std");
const sighash = @import("../core/sighash.zig");
const Transaction = sighash.Transaction;
const Input = sighash.Input;
const Output = sighash.Output;
const OutPoint = sighash.OutPoint;
const SighashFlag = sighash.SighashFlag;

test "SIGHASH_ALL with no inputs" {
    const tx = Transaction{
        .inputs = &[_]Input{},
        .outputs = &[_]Output{},
        .locktime = 0,
    };
    const hash = try tx.computeSighash(0, SighashFlag.ALL, null, null);
    try std.testing.expect(hash.len == 32);
}

test "SIGHASH_NONE" {
    const tx = Transaction{
        .inputs = &[_]Input{Input{
            .outpoint = OutPoint{ .txid = [_]u8{0} ** 32, .index = 0 },
            .script_sig = &[_]u8{},
            .sequence = 0xFFFFFFFF,
        }},
        .outputs = &[_]Output{},
        .locktime = 0,
    };
    const hash = try tx.computeSighash(0, SighashFlag.NONE, null, null);
    try std.testing.expect(hash.len == 32);
}

test "SIGHASH_SINGLE with matching output" {
    const tx = Transaction{
        .inputs = &[_]Input{Input{
            .outpoint = OutPoint{ .txid = [_]u8{0} ** 32, .index = 0 },
            .script_sig = &[_]u8{},
            .sequence = 0xFFFFFFFF,
        }},
        .outputs = &[_]Output{Output{
            .amount = 1000,
            .script = &[_]u8{},
        }},
        .locktime = 0,
    };
    const hash = try tx.computeSighash(0, SighashFlag.SINGLE, null, null);
    try std.testing.expect(hash.len == 32);
}