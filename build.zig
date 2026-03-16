const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // DOSBox SVN-Daum is 32-bit — both DLL and exe must be x86
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
    });

    // Hook DLL — gets injected into DOSBox process
    const hook_dll = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "redguard_hook",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hook.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(hook_dll);

    // Trainer exe — launches DOSBox, injects DLL
    const clap = b.dependency("clap", .{});
    const exe = b.addExecutable(.{
        .name = "redguard-trainer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clap", .module = clap.module("clap") },
            },
        }),
    });
    b.installArtifact(exe);

    // Can't use addRunArtifact for cross-compiled x86 on x64 host
    // Just build — run manually from zig-out/bin/
}
