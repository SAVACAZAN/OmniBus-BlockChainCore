/// vault_reader.zig
/// Citeste mnemonic/secret din SuperVault via Named Pipe \\.\pipe\OmnibusVault
/// Protocol VaaS: [opcode:1][exchange:1][slot:2][payload_len:2][payload]
/// Response:      [error:1][payload_len:2][payload]
///
/// Fallback priority:
///   1. Named Pipe (vault_service.exe ruleaza)
///   2. Env var OMNIBUS_MNEMONIC
///   3. Default dev mnemonic (abandon x11 + about)

const std    = @import("std");
const windows = std.os.windows;
const ws2    = std.os.windows.ws2_32;

// VaaS opcodes (din vault_core.h)
const VAULT_OP_GET_SECRET: u8 = 0x4A;
const VAULT_EXCHANGE_LCX:  u8 = 0x00; // folosim LCX slot 0 pentru mnemonic OMNI

const PIPE_NAME = "\\\\.\\pipe\\OmnibusVault";

const DEV_MNEMONIC = "abandon abandon abandon abandon abandon " ++
                     "abandon abandon abandon abandon abandon abandon about";

/// Rezultat: mnemonic slice (owned de allocator) sau eroare
pub fn readMnemonic(allocator: std.mem.Allocator) ![]const u8 {
    // 1. Incearca Named Pipe (vault_service)
    if (readFromVault(allocator)) |mnemonic| {
        std.debug.print("[VAULT] Mnemonic loaded from vault_service\n", .{});
        return mnemonic;
    } else |_| {}

    // 2. Env var OMNIBUS_MNEMONIC
    {
        var env_map = std.process.getEnvMap(allocator) catch {
            return try allocator.dupe(u8, DEV_MNEMONIC);
        };
        defer env_map.deinit();
        if (env_map.get("OMNIBUS_MNEMONIC")) |val| {
            std.debug.print("[VAULT] Mnemonic loaded from OMNIBUS_MNEMONIC env var\n", .{});
            return try allocator.dupe(u8, val);
        }
    }

    // 3. Dev default
    std.debug.print("[VAULT] Using dev default mnemonic (set OMNIBUS_MNEMONIC or start vault_service)\n", .{});
    return try allocator.dupe(u8, DEV_MNEMONIC);
}

/// Citeste secret din vault_service via Named Pipe
/// Request:  [0x4A][exchange:1][slot:2=0x0000][payload_len:2=0x0000]
/// Response: [error:1][payload_len:2][secret_bytes]
fn readFromVault(allocator: std.mem.Allocator) ![]const u8 {
    // Deschide Named Pipe
    const pipe_name_w = std.unicode.utf8ToUtf16LeStringLiteral(PIPE_NAME);
    const handle = windows.kernel32.CreateFileW(
        pipe_name_w,
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        0,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.PipeNotAvailable;
    defer windows.CloseHandle(handle);

    // Request: GET_SECRET pentru LCX exchange, slot 0
    const req = [_]u8{
        VAULT_OP_GET_SECRET,  // opcode
        VAULT_EXCHANGE_LCX,   // exchange = 0 (LCX, folosit pentru OMNI wallet)
        0x00, 0x00,           // slot = 0 (u16 LE)
        0x00, 0x00,           // payload_len = 0
    };

    var written: windows.DWORD = 0;
    const write_ok = windows.kernel32.WriteFile(handle, &req, req.len, &written, null);
    if (write_ok == 0 or written != req.len) return error.PipeWriteFailed;

    // Response: [error:1][len:2][secret]
    var resp_buf: [16384 + 3]u8 = undefined;
    var read_bytes: windows.DWORD = 0;
    const read_ok = windows.kernel32.ReadFile(handle, &resp_buf, resp_buf.len, &read_bytes, null);
    if (read_ok == 0 or read_bytes < 3) return error.PipeReadFailed;

    const vault_err = resp_buf[0];
    if (vault_err != 0) return error.VaultError;

    const payload_len: u16 = @as(u16, resp_buf[1]) | (@as(u16, resp_buf[2]) << 8);
    if (payload_len == 0 or read_bytes < 3 + @as(u32, payload_len)) return error.EmptySecret;

    const secret = resp_buf[3..3 + payload_len];
    return try allocator.dupe(u8, secret);
}
