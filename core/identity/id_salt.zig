//! id_salt.zig — Salt manager with a file-backed default implementation.
//!
//! The KYC hash is `SHA-256(salt || kyc_document_bytes)`. The salt MUST be
//! 32 bytes of cryptographic randomness, stored in a place the holder
//! controls (preferably a hardware keystore). For local testing and for
//! servers without Secure Enclave / TPM, we provide a `FileSaltManager`
//! that keeps the salt in a 0600 file.
//!
//! Deleting the salt is GDPR's "right to be forgotten": without it the
//! same KYC document cannot be re-hashed to match the previous KycHash,
//! so all prior attestations referencing that hash become unprovable.

const std = @import("std");
const fs = std.fs;
const Salt = @import("id_types.zig").Salt;

/// Vtable-based interface so hardware-backed implementations can plug in
/// later without changing call sites. All methods can fail (I/O, hw lock).
pub const SaltManager = struct {
    vtable: *const VTable,
    ctx: *anyopaque,

    pub const VTable = struct {
        /// Read existing salt, OR generate+store a fresh one if absent.
        getOrCreate: *const fn (ctx: *anyopaque) anyerror!Salt,
        /// Wipe the stored salt. Subsequent getOrCreate returns a NEW salt.
        delete:      *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub fn getOrCreate(self: SaltManager) !Salt {
        return self.vtable.getOrCreate(self.ctx);
    }

    pub fn delete(self: SaltManager) !void {
        return self.vtable.delete(self.ctx);
    }
};

/// File-backed implementation. The path is owned by the caller — we don't
/// dup it because the SaltManager has a lifetime tied to the program.
pub const FileSaltManager = struct {
    path: []const u8,

    const vtable_impl = SaltManager.VTable{
        .getOrCreate = getOrCreateImpl,
        .delete = deleteImpl,
    };

    pub fn init(path: []const u8) FileSaltManager {
        return .{ .path = path };
    }

    pub fn manager(self: *FileSaltManager) SaltManager {
        return .{ .vtable = &vtable_impl, .ctx = self };
    }

    fn getOrCreateImpl(ctx: *anyopaque) anyerror!Salt {
        const self: *FileSaltManager = @ptrCast(@alignCast(ctx));
        // Try to read first; if it exists and is the right size, return it.
        if (fs.cwd().openFile(self.path, .{})) |file| {
            defer file.close();
            var buf: Salt = undefined;
            const n = try file.readAll(&buf);
            if (n == buf.len) return buf;
            // Wrong size on disk → corrupt; fall through and regenerate.
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        var fresh: Salt = undefined;
        std.crypto.random.bytes(&fresh);
        // chmod 0600 so other users on the box can't read the salt.
        const file = try fs.cwd().createFile(self.path, .{ .mode = 0o600, .truncate = true });
        defer file.close();
        try file.writeAll(&fresh);
        return fresh;
    }

    fn deleteImpl(ctx: *anyopaque) anyerror!void {
        const self: *FileSaltManager = @ptrCast(@alignCast(ctx));
        fs.cwd().deleteFile(self.path) catch |err| switch (err) {
            error.FileNotFound => {}, // already gone — idempotent
            else => return err,
        };
    }
};

/// In-memory implementation for unit tests — no filesystem access.
pub const MemorySaltManager = struct {
    salt: ?Salt = null,

    const vtable_impl = SaltManager.VTable{
        .getOrCreate = getOrCreateImpl,
        .delete = deleteImpl,
    };

    pub fn manager(self: *MemorySaltManager) SaltManager {
        return .{ .vtable = &vtable_impl, .ctx = self };
    }

    fn getOrCreateImpl(ctx: *anyopaque) anyerror!Salt {
        const self: *MemorySaltManager = @ptrCast(@alignCast(ctx));
        if (self.salt) |s| return s;
        var fresh: Salt = undefined;
        std.crypto.random.bytes(&fresh);
        self.salt = fresh;
        return fresh;
    }

    fn deleteImpl(ctx: *anyopaque) anyerror!void {
        const self: *MemorySaltManager = @ptrCast(@alignCast(ctx));
        self.salt = null;
    }
};

test "MemorySaltManager: get-twice returns the same salt" {
    var mem = MemorySaltManager{};
    const mgr = mem.manager();
    const a = try mgr.getOrCreate();
    const b = try mgr.getOrCreate();
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "MemorySaltManager: delete forgets the salt" {
    var mem = MemorySaltManager{};
    const mgr = mem.manager();
    const a = try mgr.getOrCreate();
    try mgr.delete();
    const b = try mgr.getOrCreate();
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}

test "MemorySaltManager: delete is idempotent" {
    var mem = MemorySaltManager{};
    const mgr = mem.manager();
    try mgr.delete(); // no salt yet → must not error
    try mgr.delete();
}

test "FileSaltManager: roundtrip in tmp" {
    // tmpDir().dir works in 0.15.2; we use the cwd-based open inside the
    // implementation, so we set cwd into the tmp by passing a relative
    // path that lives there.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Materialize a stable absolute path under the tmp dir.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buf, "{s}/salt.bin", .{dir_path});

    var fm = FileSaltManager.init(full_path);
    const mgr = fm.manager();
    const a = try mgr.getOrCreate();
    const b = try mgr.getOrCreate();
    try std.testing.expectEqualSlices(u8, &a, &b);

    try mgr.delete();
    const c = try mgr.getOrCreate();
    try std.testing.expect(!std.mem.eql(u8, &a, &c));
}
