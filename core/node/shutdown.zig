// core/node/shutdown.zig
// Graceful Shutdown — Ctrl+C / SIGINT handler.
// Atomic flag checked by the mining loop; set by OS signal handler.
//
// Extracted from main.zig (2026-05-29). Re-exported by main.zig as
// `main_mod.g_shutdown` for any future cross-module consumers.

const std = @import("std");
const builtin = @import("builtin");

pub var g_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn installShutdownHandlers() void {
    if (comptime builtin.os.tag == .windows) {
        // Windows: use std.os.windows.SetConsoleCtrlHandler wrapper
        std.os.windows.SetConsoleCtrlHandler(&windows_handlers.windowsCtrlHandler, true) catch {
            std.debug.print("[SHUTDOWN] Failed to install Ctrl+C handler\n", .{});
        };
    } else {
        // POSIX: catch SIGINT + SIGTERM
        // empty_sigset removed in Zig 0.15 — use zeroes for portable empty mask.
        const act = std.posix.Sigaction{
            .handler = .{ .handler = posixSignalHandler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
}

// Windows-only handler — wrapped in a struct so std.os.windows.DWORD/BOOL
// type references don't get resolved on non-Windows targets.
const windows_handlers = if (builtin.os.tag == .windows) struct {
    pub fn windowsCtrlHandler(dwCtrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
        _ = dwCtrlType;
        g_shutdown.store(true, .monotonic);
        return std.os.windows.TRUE; // handled, don't terminate immediately
    }
} else struct {};

fn posixSignalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    g_shutdown.store(true, .monotonic);
}
