const std = @import("std");
const cimgui = @import("cimgui");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // DOSBox SVN-Daum is 32-bit — both DLL and exe must be x86
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .windows,
    });

    // dcimgui dependency
    const cimgui_conf = cimgui.getConfig(false);
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    // Hook DLL — gets injected into DOSBox process
    const hook_mod = b.createModule(.{
        .root_source_file = b.path("src/hook.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = cimgui_conf.module_name, .module = dep_cimgui.module(cimgui_conf.module_name) },
        },
    });

    // Include paths for C++ compilation
    hook_mod.addIncludePath(dep_cimgui.path(cimgui_conf.include_dir)); // imgui.h
    hook_mod.addIncludePath(b.path("vendor")); // backend headers

    // Compile vendor C++ backend sources
    const cpp_flags: []const []const u8 = &.{
        "-DIMGUI_IMPL_WIN32_DISABLE_GAMEPAD",
        "-DIMGUI_USE_BGRA_PACKED_COLOR",
    };
    for ([_][]const u8{
        "vendor/imgui_impl_dx9.cpp",
        "vendor/imgui_impl_win32.cpp",
        "vendor/imgui_bridge.cpp",
    }) |src| {
        hook_mod.addCSourceFile(.{
            .file = b.path(src),
            .flags = cpp_flags,
        });
    }

    const hook_dll = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "redguard_hook",
        .root_module = hook_mod,
    });

    // Link system libraries needed by the D3D9/Win32 backends
    hook_dll.linkSystemLibrary("d3d9");
    hook_dll.linkSystemLibrary("dwmapi");
    hook_dll.linkSystemLibrary("gdi32");

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
