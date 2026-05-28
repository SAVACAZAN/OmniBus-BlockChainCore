// Low-level TCP socket primitives for the P2P transport.
//
// Three operations:
//   * enableTcpNoDelay — disable Nagle (40ms batch delay) on a connected stream.
//     P2P sends are small + time-critical (block announces, heartbeats).
//   * p2pRecv / p2pSend — platform-portable single read/write. Windows can't
//     use std.net.Stream.read directly on accepted sockets (it routes through
//     ReadFile which fails on sockets), so we fall back to ws2_32 there.
//   * readAllFromStream — loop p2pRecv until buf is full or the peer closes.
//
// Pure leaf: depends only on std + builtin. No P2P state involved.

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const ws2 = if (is_windows) std.os.windows.ws2_32 else undefined;

/// Disable Nagle's algorithm on a TCP socket. Without this, the OS
/// buffers small writes for ~40ms hoping to batch them. For block
/// announces and peer-to-peer signalling, every send is small and
/// time-critical — Nagle adds ~40ms per hop, which on a 1s block
/// time is 4% of slot budget burnt before the packet leaves the box.
///
/// Best-effort: setsockopt errors are logged but do not fail the
/// connection. On platforms without IPPROTO_TCP / TCP_NODELAY (rare)
/// the call is a no-op.
pub fn enableTcpNoDelay(stream: std.net.Stream) void {
    const opt: i32 = 1;
    std.posix.setsockopt(
        stream.handle,
        6, // IPPROTO_TCP
        1, // TCP_NODELAY
        std.mem.asBytes(&opt),
    ) catch |err| {
        std.debug.print("[P2P] TCP_NODELAY setsockopt failed: {}\n", .{err});
    };
}

pub fn p2pRecv(stream: std.net.Stream, buf: []u8) !usize {
    if (comptime is_windows) {
        const got = ws2.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (got <= 0) return error.ConnectionClosed;
        return @intCast(got);
    } else {
        const n = try stream.read(buf);
        if (n == 0) return error.ConnectionClosed;
        return n;
    }
}

pub fn p2pSend(stream: std.net.Stream, data: []const u8) !void {
    if (comptime is_windows) {
        var sent: usize = 0;
        while (sent < data.len) {
            const remaining: c_int = @intCast(data.len - sent);
            const n = ws2.send(stream.handle, data[sent..].ptr, remaining, 0);
            if (n <= 0) return error.ConnectionClosed;
            sent += @intCast(n);
        }
    } else {
        // Bypass std.net.Stream.writeAll() because it uses sendmsg() which
        // panics on BADF (closed-fd race with a peer-disconnect thread).
        // posix.write returns NotOpenForWriting instead of panicking, so
        // heartbeat/gossip threads can survive a parallel close cleanly.
        var sent: usize = 0;
        while (sent < data.len) {
            const n = std.posix.write(stream.handle, data[sent..]) catch {
                return error.ConnectionClosed;
            };
            if (n == 0) return error.ConnectionClosed;
            sent += n;
        }
    }
}

pub fn readAllFromStream(stream: std.net.Stream, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = p2pRecv(stream, buf[total..]) catch break;
        total += n;
    }
    return total;
}
