//! Tests for Bitcoin RPC client (mock)

const std = @import("std");
const testing = std.testing;
const rpc = @import("../../../wallet/btc/rpc_client.zig");

test "BTC: RPC config validation" {
    const config = rpc.RpcConfig{
        .url = "http://localhost:8332",
        .username = "testuser",
        .password = "testpass",
        .network = .testnet,
    };
    
    try testing.expectEqualStrings(config.url, "http://localhost:8332");
    try testing.expect(config.network == .testnet);
}

test "BTC: Fee estimation struct" {
    const fees = rpc.FeeEstimate{
        .slow = 2,
        .normal = 5,
        .fast = 10,
        .urgent = 20,
    };
    
    try testing.expect(fees.slow < fees.normal);
    try testing.expect(fees.normal < fees.fast);
    try testing.expect(fees.fast < fees.urgent);
}

test "BTC: Network parameters" {
    try testing.expectEqual(@as(u16, 8333), rpc.NetworkParams.MAINNET.port);
    try testing.expectEqual(@as(u16, 18333), rpc.NetworkParams.TESTNET.port);
    try testing.expectEqual(@as(u16, 18444), rpc.NetworkParams.REGTEST.port);
    
    try testing.expectEqualStrings("bc", rpc.NetworkParams.MAINNET.witness_program_prefix);
    try testing.expectEqualStrings("tb", rpc.NetworkParams.TESTNET.witness_program_prefix);
}

test "BTC: RPC client initialization" {
    const config = rpc.RpcConfig{
        .url = "http://localhost:8332",
        .username = "",
        .password = "",
        .network = .mainnet,
    };
    
    // Should not crash
    _ = rpc.BtcRpcClient.init(testing.allocator, config) catch {};
}

test "BTC: Transaction info structure" {
    var tx_info = rpc.TxInfo{
        .txid = [_]u8{0x01} ** 32,
        .confirmations = 6,
        .block_hash = null,
        .block_height = null,
        .fee = 10000,
        .hex = try testing.allocator.dupe(u8, "01000000..."),
    };
    defer tx_info.deinit();
    
    try testing.expect(tx_info.confirmations == 6);
    try testing.expect(tx_info.fee == 10000);
    try testing.expect(tx_info.hex.len > 0);
}

test "BTC: UTXO info structure" {
    var utxo = rpc.UtxoInfo{
        .txid = [_]u8{0x01} ** 32,
        .vout = 0,
        .amount = 100000,
        .script_pubkey = try testing.allocator.dupe(u8, "76a914..."),
        .confirmations = 10,
    };
    defer utxo.deinit();
    
    try testing.expect(utxo.amount == 100000);
    try testing.expect(utxo.vout == 0);
    try testing.expect(utxo.confirmations == 10);
}