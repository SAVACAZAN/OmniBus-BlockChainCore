// Adauga aceasta functie in main.zig si apeleaz-o la inceputul main()
// Necesar: const builtin = @import("builtin");


// ── Single-instance guard — un singur miner per masina ───────────────────────
fn acquireSingleInstanceLock() !void {
    if (builtin.os.tag == .windows) {
        const kernel32 = std.os.windows.kernel32;
        const name = std.unicode.utf8ToUtf16LeStringLiteral("Global\\OmniBusMiner");
        const mutex = kernel32.CreateMutexW(null, 1, name);
        if (mutex == null) return error.MutexFailed;
        if (std.os.windows.kernel32.GetLastError() == 183) { // ERROR_ALREADY_EXISTS
            std.debug.print("[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC!\n", .{});
            std.debug.print("          Un singur miner per masina — regula de retea.\n", .{});
            std.process.exit(1);
        }
        // mutex ramas deschis pana la exit — eliberat automat de OS
    } else {
        // Linux / macOS: flock pe /tmp/omnibus-miner.lock
        const lock_path = "/tmp/omnibus-miner.lock";
        const file = std.fs.cwd().createFile(lock_path, .{ .exclusive = false }) catch |e| {
            std.debug.print("[LOCK] Nu pot crea lock file: {}\n", .{e});
            return;
        };
        // Non-blocking exclusive lock
        const LOCK_EX: u32 = 2;
        const LOCK_NB: u32 = 4;
        const fd = file.handle;
        const rc = std.os.linux.flock(fd, LOCK_EX | LOCK_NB);
        if (rc != 0) {
            std.debug.print("[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC!\n", .{});
            std.debug.print("          Un singur miner per masina — regula de retea.\n", .{});
            std.process.exit(1);
        }
        // Scrie PID in lock file
        var pid_buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.os.linux.getpid()}) catch "";
        _ = file.write(pid_str) catch {};
        // NU inchidem file — lock ramas activ pana la exit
        _ = file; // supress unused warning; intentional leak pentru lock
    }
}
