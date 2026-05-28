// core/node/platform_lock.zig
//
// Single-instance lock — un singur miner per masina.
//   Windows: lock file exclusiv  omnibus-miner.lock (in directorul curent)
//   Linux/macOS: flock()         /tmp/omnibus-miner.lock
//
// Extras din main.zig pentru a tine entrypoint-ul curat. Comportament identic
// cu versiunea originala — nu accepta parametri si nu returneaza eroare; pe
// conflict tipareste mesajul si face std.process.exit(1).

const std = @import("std");
const builtin = @import("builtin");

// Windows-only single-instance lock via CreateFileW exclusive — wrapped so
// kernel32 symbol references don't leak into non-Windows builds.
const windows_lock = if (builtin.os.tag == .windows) struct {
    pub fn acquire() void {
        const lock_path_w = std.unicode.utf8ToUtf16LeStringLiteral("omnibus-miner.lock");
        const handle = std.os.windows.kernel32.CreateFileW(
            lock_path_w,
            std.os.windows.GENERIC_WRITE,
            0, // ShareMode = 0 → exclusiv, alt proces nu poate deschide
            null,
            std.os.windows.OPEN_ALWAYS,
            std.os.windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (handle == std.os.windows.INVALID_HANDLE_VALUE) {
            std.debug.print("\n[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC!\n", .{});
            std.debug.print("          Un singur miner per masina — regula de retea.\n", .{});
            std.debug.print("          Opreste instanta curenta inainte sa pornesti alta.\n\n", .{});
            std.process.exit(1);
        }
    }
} else struct {
    pub fn acquire() void {}
};

pub fn acquireSingleInstanceLock() void {
    if (comptime builtin.os.tag == .windows) {
        windows_lock.acquire();
        // handle ramas deschis pana la exit — OS il elibereaza + sterge fisierul
    } else {
        // Linux / macOS / BSD: flock pe /tmp/omnibus-miner.lock
        const lock_path = "/tmp/omnibus-miner.lock";
        var file = std.fs.createFileAbsolute(lock_path, .{}) catch {
            std.debug.print("[LOCK] Nu pot crea {s} — continuam fara lock\n", .{lock_path});
            return;
        };
        // flock(fd, LOCK_EX | LOCK_NB) = 6
        const rc = std.posix.flock(file.handle, 6) catch {
            std.debug.print("\n[BLOCKED] Un miner OmniBus ruleaza deja pe acest PC!\n", .{});
            std.debug.print("          Un singur miner per masina — regula de retea.\n", .{});
            std.debug.print("          Opreste instanta curenta inainte sa pornesti alta.\n\n", .{});
            std.process.exit(1);
            return;
        };
        _ = rc;
        // Scrie PID in lock file
        var pid_buf: [32]u8 = undefined;
        const pid_str = std.fmt.bufPrint(&pid_buf, "{d}\n",
            .{std.os.linux.getpid()}) catch "";
        file.writeAll(pid_str) catch {};
        // NU inchidem — lock activ pana la exit procesului (intentional leak)
        std.mem.doNotOptimizeAway(&file);
    }
}
