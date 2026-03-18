const std = @import("std");

pub const Transaction = struct {
    id: u32,
    from_address: []const u8,
    to_address: []const u8,
    amount: u64, // in SAT
    timestamp: i64,
    signature: []const u8,
    hash: []const u8,

    pub fn calculateHash(self: *const Transaction) ![32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        var buffer: [1024]u8 = undefined;
        const str = try std.fmt.bufPrint(&buffer, "{d}{s}{s}{d}{d}", .{
            self.id,
            self.from_address,
            self.to_address,
            self.amount,
            self.timestamp,
        });

        hasher.update(str);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }

    pub fn isValid(self: *const Transaction) bool {
        // Basic validation
        if (self.amount == 0) {
            return false;
        }

        if (self.from_address.len == 0 or self.to_address.len == 0) {
            return false;
        }

        // Addresses must start with appropriate prefix (ob_omni_, ob_k1_, etc.)
        const valid_prefixes = [_][]const u8{ "ob_omni_", "ob_k1_", "ob_f5_", "ob_d5_", "ob_s3_", "0x" };

        var has_valid_prefix = false;
        for (valid_prefixes) |prefix| {
            if (std.mem.startsWith(u8, self.from_address, prefix) and
                std.mem.startsWith(u8, self.to_address, prefix)) {
                has_valid_prefix = true;
                break;
            }
        }

        return has_valid_prefix;
    }

    pub fn sign(self: *Transaction, private_key: []const u8) !void {
        // TODO: Implement actual signature algorithm
        // For now, create a placeholder signature
        _ = private_key;
        self.signature = "signature_placeholder";
    }

    pub fn verify(self: *const Transaction, public_key: []const u8) bool {
        // TODO: Implement actual signature verification
        _ = public_key;
        return self.signature.len > 0;
    }
};
