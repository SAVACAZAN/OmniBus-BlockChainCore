// Smoke test that ws_client.zig at least parses + type-checks.
// Pulls in all `test {...}` blocks from ws_client.zig as well.
const std = @import("std");
const ws = @import("ws_client.zig");

test "ws_client public API surface compiles" {
    // Reference public types and functions to force semantic analysis.
    const T1 = ws.WsClient;
    const T2 = ws.Message;
    const T3 = ws.MessageKind;
    const T4 = ws.WsError;
    _ = T1;
    _ = T2;
    _ = T3;
    _ = T4;

    // Reference function signatures (no actual call — would need a real server).
    const connect_fn = ws.WsClient.connect;
    const send_fn = ws.WsClient.send;
    const recv_fn = ws.WsClient.recv;
    const ping_fn = ws.WsClient.sendPing;
    const pong_fn = ws.WsClient.sendPong;
    const close_fn = ws.WsClient.close;
    _ = connect_fn;
    _ = send_fn;
    _ = recv_fn;
    _ = ping_fn;
    _ = pong_fn;
    _ = close_fn;
}

test {
    // Re-run all unit tests embedded in ws_client.zig.
    std.testing.refAllDecls(ws);
}
