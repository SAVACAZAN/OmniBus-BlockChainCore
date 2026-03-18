const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Blockchain node executable
    const blockchain_exe = b.addExecutable(.{
        .name = "omnibus-node",
        .root_module = .{
            .source_file = b.path("core/main.zig"),
            .target = target,
            .optimize = optimize,
        },
    });
    b.installArtifact(blockchain_exe);

    // RPC server executable
    const rpc_exe = b.addExecutable(.{
        .name = "omnibus-rpc",
        .root_module = .{
            .source_file = b.path("core/rpc_server.zig"),
            .target = target,
            .optimize = optimize,
        },
    });
    b.installArtifact(rpc_exe);

    // Agent system executable
    const agent_exe = b.addExecutable(.{
        .name = "omnibus-agent",
        .root_module = .{
            .source_file = b.path("agent/agent_manager.zig"),
            .target = target,
            .optimize = optimize,
        },
    });
    b.installArtifact(agent_exe);

    // Tests
    const tests = b.addTest(.{
        .root_module = .{
            .source_file = b.path("test/blockchain_test.zig"),
            .target = target,
            .optimize = optimize,
        },
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // Run step
    const run_blockchain = b.addRunArtifact(blockchain_exe);
    const run_step = b.step("run", "Run blockchain node");
    run_step.dependOn(&run_blockchain.step);
}
