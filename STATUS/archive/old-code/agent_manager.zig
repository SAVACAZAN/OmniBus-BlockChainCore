const std = @import("std");

pub const Agent = struct {
    id: u32,
    name: []const u8,
    wallet_address: []const u8,
    balance: u64,
    active: bool,

    pub fn init(id: u32, name: []const u8, wallet_address: []const u8) Agent {
        return Agent{
            .id = id,
            .name = name,
            .wallet_address = wallet_address,
            .balance = 50_000_000_000, // 500 OMNI in SAT
            .active = true,
        };
    }
};

pub const AgentManager = struct {
    agents: std.ArrayList(Agent),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AgentManager {
        return AgentManager{
            .agents = std.ArrayList(Agent).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AgentManager) void {
        self.agents.deinit();
    }

    pub fn addAgent(self: *AgentManager, id: u32, name: []const u8, wallet_address: []const u8) !void {
        const agent = Agent.init(id, name, wallet_address);
        try self.agents.append(agent);
    }

    pub fn getAgent(self: *AgentManager, id: u32) ?Agent {
        for (self.agents.items) |agent| {
            if (agent.id == id) {
                return agent;
            }
        }
        return null;
    }

    pub fn getAgentCount(self: *AgentManager) u32 {
        return @intCast(self.agents.items.len);
    }

    pub fn getBalance(self: *AgentManager, id: u32) ?u64 {
        for (self.agents.items) |agent| {
            if (agent.id == id) {
                return agent.balance;
            }
        }
        return null;
    }

    pub fn getTotalBalance(self: *AgentManager) u64 {
        var total: u64 = 0;
        for (self.agents.items) |agent| {
            total += agent.balance;
        }
        return total;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout = std.io.getStdOut().writer();

    try stdout.print("=== OmniBus Agent Manager ===\n", .{});
    try stdout.print("Version: 1.0.0-dev\n\n", .{});

    var manager = AgentManager.init(allocator);
    defer manager.deinit();

    // Create sample agents
    try manager.addAgent(1, "Trading Agent 1", "ob_omni_1q2w3e4r5t6y7u8i9o0p");
    try manager.addAgent(2, "Arbitrage Bot", "ob_k1_1a2s3d4f5g6h7j8k9l0z");
    try manager.addAgent(3, "Market Maker", "ob_f5_1q2w3e4r5t6y7u8i9o0p");

    try stdout.print("Registered Agents: {d}\n\n", .{manager.getAgentCount()});

    for (manager.agents.items) |agent| {
        try stdout.print("Agent {d}: {s}\n", .{ agent.id, agent.name });
        try stdout.print("  Wallet: {s}\n", .{agent.wallet_address});
        try stdout.print("  Balance: {d} SAT ({d} OMNI)\n", .{ agent.balance, agent.balance / 100_000_000 });
        try stdout.print("  Status: {s}\n\n", .{if (agent.active) "Active" else "Inactive"});
    }

    try stdout.print("Total Assets: {d} SAT ({d} OMNI)\n", .{
        manager.getTotalBalance(),
        manager.getTotalBalance() / 100_000_000,
    });
}
