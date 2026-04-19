const std = @import("std");

// Raylib paths (pre-built Windows MinGW)
const RAYLIB_INCLUDE = "C:/tmp/raylib-5.5/raylib-5.5_win64_msvc16/include";
const RAYLIB_LIB = "C:/tmp/raylib-mingw/raylib-5.5_win64_mingw-w64/lib/libraylib.a";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "omnibus-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Raylib C headers
    exe.root_module.addIncludePath(.{ .cwd_relative = RAYLIB_INCLUDE });

    // Link raylib static (MinGW .a format)
    exe.addObjectFile(.{ .cwd_relative = RAYLIB_LIB });

    // Windows system libs needed by raylib
    exe.linkSystemLibrary("winmm");
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("shell32");
    exe.linkSystemLibrary("opengl32");
    exe.linkLibC();

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the OmniBus GUI");
    run_step.dependOn(&run_cmd.step);
}
