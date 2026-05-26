//! Tests for Bitcoin transaction builder

const std = @import("std");
const testing = std.testing;
const tx_builder = @import("../../../wallet/btc/tx_builder.zig");
const utils = @import("../../../wallet/btc/utils.zig");

test "BTC: Transaction serialization" {
    var builder = tx_builder.TxBuilder.init(testing.allocator);
    
    const utxos = [_]tx_builder.Utxo{};
    const outputs = [_]tx_builder.TxOut{};
    
    const result = try builder.build(&utxos, &outputs, "", "", 1);
    defer result.tx.deinit();
    
    try testing.expect(result.tx.version == 2);
    try testing.expect(result.tx.locktime == 0);
}

test "BTC: Transaction fee calculation" {
    var builder = tx_builder.TxBuilder.init(testing.allocator);
    
    const utxos = [_]tx_builder.Utxo{
        .{
            .txid = [_]u8{0x01} ** 32,
            .vout = 0,
            .amount = 100000,
            .script_pubkey = &[_]u8{},
            .address_type = .p2wpkh,
        },
    };
    
    const outputs = [_]tx_builder.TxOut{
        .{
            .amount = 50000,
            .script_pubkey = &[_]u8{0x00, 0x14} ++ [_]u8{0xAA} ** 20,
        },
    };
    
    const result = try builder.build(&utxos, &outputs, "bc1...", &[_]u8{}, 10);
    defer result.tx.deinit();
    
    // Fee should be positive
    try testing.expect(result.fee > 0);
    try testing.expect(result.fee < 50000);
}

test "BTC: Transaction size estimation" {
    const p2wpkh_size = utils.TxSizeEstimator.estimateP2WPKHSize(2, 1);
    const p2tr_size = utils.TxSizeEstimator.estimateP2TRSize(2, 1);
    const legacy_size = utils.TxSizeEstimator.estimateLegacySize(2, 1);
    
    // Segwit should be smaller than legacy
    try testing.expect(p2wpkh_size < legacy_size);
    try testing.expect(p2tr_size < legacy_size);
    
    // P2TR should be slightly smaller than P2WPKH
    try testing.expect(p2tr_size <= p2wpkh_size);
}

test "BTC: Varint encoding/decoding" {
    const test_values = [_]u64{ 0, 1, 0xFC, 0xFD, 0xFFFF, 0x10000, 0xFFFFFFFF, 0x100000000 };
    
    for (test_values) |value| {
        const encoded = utils.writeVarInt(value);
        defer testing.allocator.free(encoded);
        
        var offset: usize = 0;
        const decoded = try utils.readVarInt(encoded, &offset);
        
        try testing.expectEqual(value, decoded);
        try testing.expect(offset == encoded.len);
    }
}

test "BTC: Satoshi conversion" {
    const satoshis: u64 = 12345678;
    const btc_str = utils.satoshisToBTC(satoshis);
    defer testing.allocator.free(btc_str);
    
    // Should be approximately 0.12345678
    try testing.expect(btc_str.len > 0);
    
    const back_to_sats = try utils.btcToSatoshis(btc_str);
    try testing.expectEqual(satoshis, back_to_sats);
}

test "BTC: Double SHA256" {
    const input = "Hello Bitcoin";
    const hash = utils.doubleSha256(input);
    
    // Should be 32 bytes
    try testing.expect(hash.len == 32);
}

test "BTC: Transaction with change output" {
    var builder = tx_builder.TxBuilder.init(testing.allocator);
    
    const utxos = [_]tx_builder.Utxo{
        .{
            .txid = [_]u8{0x01} ** 32,
            .vout = 0,
            .amount = 100000,
            .script_pubkey = &[_]u8{},
            .address_type = .p2wpkh,
        },
    };
    
    const outputs = [_]tx_builder.TxOut{
        .{
            .amount = 80000,
            .script_pubkey = &[_]u8{0x00, 0x14} ++ [_]u8{0xAA} ** 20,
        },
    };
    
    const result = try builder.build(&utxos, &outputs, "bc1...", &[_]u8{}, 10);
    defer result.tx.deinit();
    
    // Should have 2 outputs (destination + change)
    try testing.expect(result.tx.outputs.len == 2);
}

test "BTC: Dust threshold" {
    var builder = tx_builder.TxBuilder.init(testing.allocator);
    
    const utxos = [_]tx_builder.Utxo{
        .{
            .txid = [_]u8{0x01} ** 32,
            .vout = 0,
            .amount = 1000,
            .script_pubkey = &[_]u8{},
            .address_type = .p2wpkh,
        },
    };
    
    const outputs = [_]tx_builder.TxOut{
        .{
            .amount = 900,
            .script_pubkey = &[_]u8{},
        },
    };
    
    const result = try builder.build(&utxos, &outputs, "bc1...", &[_]u8{}, 1);
    defer result.tx.deinit();
    
    // Change would be below dust threshold (546 sats), so no change output
    try testing.expect(result.tx.outputs.len == 1);
}