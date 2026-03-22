const std = @import("std");
const clap = @import("clap");
const windows = std.os.windows;
const fs = std.fs;

// ── Win32 types ──
const BOOL = windows.BOOL;
const DWORD = u32;
const HANDLE = windows.HANDLE;
const HMODULE = *anyopaque;
const LPVOID = ?*anyopaque;
const LPCVOID = ?*const anyopaque;
const SIZE_T = usize;
const HWND = windows.HWND;

const INFINITE: DWORD = 0xFFFFFFFF;
const MEM_COMMIT: DWORD = 0x00001000;
const MEM_RESERVE: DWORD = 0x00002000;
const MEM_RELEASE: DWORD = 0x00008000;
const PAGE_READWRITE: DWORD = 0x04;
const PROCESS_ALL_ACCESS: DWORD = 0x001F0FFF;

// ── Win32 imports ──
extern "kernel32" fn OpenProcess(dwAccess: DWORD, bInherit: BOOL, dwPid: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn VirtualAllocEx(hProc: HANDLE, lpAddr: LPVOID, dwSize: SIZE_T, flType: DWORD, flProt: DWORD) callconv(.winapi) LPVOID;
extern "kernel32" fn VirtualFreeEx(hProc: HANDLE, lpAddr: LPVOID, dwSize: SIZE_T, dwType: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn WriteProcessMemory(hProc: HANDLE, lpBase: LPVOID, lpBuf: LPCVOID, nSize: SIZE_T, lpWritten: ?*SIZE_T) callconv(.winapi) BOOL;
extern "kernel32" fn CreateRemoteThread(hProc: HANDLE, lpAttr: ?*anyopaque, dwStack: SIZE_T, lpStart: ?*anyopaque, lpParam: LPVOID, dwFlags: DWORD, lpId: ?*DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetModuleHandleA(lpName: [*:0]const u8) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(hMod: HMODULE, lpName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMs: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CloseHandle(hObj: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: *DWORD) callconv(.winapi) DWORD;
extern "user32" fn FindWindowA(lpClass: ?[*:0]const u8, lpWindow: ?[*:0]const u8) callconv(.winapi) ?HWND;
extern "kernel32" fn SetEnvironmentVariableA(name: [*:0]const u8, value: ?[*:0]const u8) callconv(.winapi) BOOL;

// ── Output helpers ──
fn print(comptime msg: []const u8) void {
    fs.File.stdout().writeAll(msg) catch {};
}

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    fs.File.stdout().writeAll(msg) catch {};
}

fn sleep(ms: u64) void {
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

// ── DLL injection ──
fn injectDll(pid: DWORD, dll_path: []const u8) !void {
    const process = OpenProcess(PROCESS_ALL_ACCESS, 0, pid) orelse {
        printFmt("  OpenProcess failed: {d}\n", .{GetLastError()});
        return error.OpenProcessFailed;
    };
    defer _ = CloseHandle(process);

    const remote_mem = VirtualAllocEx(process, null, dll_path.len + 1, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse {
        printFmt("  VirtualAllocEx failed: {d}\n", .{GetLastError()});
        return error.AllocFailed;
    };

    if (WriteProcessMemory(process, remote_mem, @ptrCast(dll_path.ptr), dll_path.len + 1, null) == 0) {
        printFmt("  WriteProcessMemory failed: {d}\n", .{GetLastError()});
        return error.WriteFailed;
    }

    const kernel32 = GetModuleHandleA("kernel32.dll") orelse return error.NoKernel32;
    const load_lib = GetProcAddress(kernel32, "LoadLibraryA") orelse return error.NoLoadLibrary;

    const thread = CreateRemoteThread(process, null, 0, load_lib, remote_mem, 0, null) orelse {
        printFmt("  CreateRemoteThread failed: {d}\n", .{GetLastError()});
        return error.ThreadFailed;
    };

    _ = WaitForSingleObject(thread, INFINITE);
    _ = CloseHandle(thread);
    _ = VirtualFreeEx(process, remote_mem, 0, MEM_RELEASE);
}

// ── RGFX.EXE binary patching ──
const W: u8 = 0xAA; // wildcard — matches any byte in pattern search

fn patchByte(path: []const u8, offset: usize, byte: u8) bool {
    const f = fs.openFileAbsolute(path, .{ .mode = .read_write }) catch return false;
    defer f.close();
    _ = f.pwrite(&[_]u8{byte}, offset) catch return false;
    return true;
}

fn findPattern(data: []const u8, pattern: []const u8) ?usize {
    if (data.len < pattern.len) return null;
    for (0..data.len - pattern.len) |i| {
        var match = true;
        for (pattern, 0..) |p, j| {
            if (p != W and data[i + j] != p) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

// ── Main ──
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ── CLI argument parsing ──
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Show this help message
        \\-s, --skip-intro      Skip intro cinematic, 3dfx splash, and outro animation
        \\-w, --windowed        Force windowed mode (default is fullscreen)
        \\-t, --trainer         Enable trainer overlay (cheats, level loader, fly mode)
        \\-l, --load-save <str> Load save game slot on startup (e.g. --load-save 3)
        \\<str>                 Path to Redguard installation (contains DOSBOX/ folder)
        \\
    );

    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, .{ .str = clap.parsers.string }, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
        diag.reportToFile(fs.File.stderr(), err) catch {};
        return err;
    };
    defer res.deinit();

    const help_text =
        \\Usage: redguard-trainer [options] <game-path>
        \\
        \\Options:
        \\  -s, --skip-intro      Skip intro cinematic, 3dfx splash, and outro animation
        \\  -w, --windowed        Force windowed mode (default is fullscreen)
        \\  -t, --trainer         Enable trainer overlay (cheats, level loader, fly mode)
        \\  -l, --load-save <N>   Load save game slot N on startup (skips main menu)
        \\  -h, --help            Show this help message
        \\
        \\Arguments:
        \\  <game-path>       Path to Redguard installation (contains DOSBOX/ folder)
        \\
        \\Example:
        \\  redguard-trainer --skip-intro --windowed --trainer "D:\Games\GOG Galaxy\Redguard"
        \\  redguard-trainer --skip-intro --load-save 3 "D:\Games\GOG Galaxy\Redguard"
        \\
    ;

    if (res.args.help != 0) {
        print(help_text);
        return;
    }

    const game_path: []const u8 = if (res.positionals.len > 0) (res.positionals[0] orelse {
        print("Error: missing <game-path>\n\n");
        print(help_text);
        return;
    }) else {
        print("Error: missing <game-path>\n\n");
        print(help_text);
        return;
    };

    const skip_intro = res.args.@"skip-intro" != 0;
    const windowed = res.args.windowed != 0;
    const load_save = res.args.@"load-save";
    const trainer = res.args.trainer != 0;
    const inject_hook = trainer or windowed or load_save != null;

    // ── Build paths ──
    var dosbox_exe_buf: [fs.max_path_bytes]u8 = undefined;
    var conf_main_buf: [fs.max_path_bytes]u8 = undefined;
    var dosbox_dir_buf: [fs.max_path_bytes]u8 = undefined;
    var conf_tmp_buf: [fs.max_path_bytes]u8 = undefined;
    var rgfx_exe_buf: [fs.max_path_bytes]u8 = undefined;

    const dosbox_exe = std.fmt.bufPrint(&dosbox_exe_buf, "{s}\\DOSBOX\\dosbox.exe", .{game_path}) catch return;
    const dosbox_dir = std.fmt.bufPrint(&dosbox_dir_buf, "{s}\\DOSBOX", .{game_path}) catch return;
    const conf_main = std.fmt.bufPrint(&conf_main_buf, "{s}\\dosbox_redguard.conf", .{game_path}) catch return;
    const conf_tmp = std.fmt.bufPrint(&conf_tmp_buf, "{s}\\DOSBOX\\trainer_autoexec.conf", .{game_path}) catch return;
    const rgfx_exe = std.fmt.bufPrint(&rgfx_exe_buf, "{s}\\Redguard\\RGFX.EXE", .{game_path}) catch return;

    dosbox_exe_buf[dosbox_exe.len] = 0;
    dosbox_dir_buf[dosbox_dir.len] = 0;
    conf_main_buf[conf_main.len] = 0;
    conf_tmp_buf[conf_tmp.len] = 0;
    rgfx_exe_buf[rgfx_exe.len] = 0;

    // ── Write temp DOSBox config ──
    // Only override settings when explicitly requested to avoid interfering
    // with nGlide's rendering pipeline (e.g. invisible character bug).
    {
        const file = fs.createFileAbsolute(conf_tmp, .{}) catch {
            print("Error: could not write temp config\n");
            return;
        };
        if (windowed) {
            file.writeAll("[sdl]\r\nfullscreen=false\r\n\r\n") catch {};
        }
        if (skip_intro) {
            file.writeAll("[glide]\r\nsplash=false\r\n\r\n") catch {};
        }
        file.writeAll(
            "[autoexec]\r\n" ++
                "@echo off\r\n" ++
                "cls\r\n" ++
                "mount C \"..\" -freesize 512\r\n" ++
                "imgmount d \"..\\game.ins\" -t iso\r\n" ++
                "c:\r\n" ++
                "cd redguard\r\n" ++
                "cls\r\n" ++
                "rgfx.exe\r\n" ++
                "exit\r\n",
        ) catch {};
        file.close();
    }
    defer fs.deleteFileAbsolute(conf_tmp) catch {};

    // ── Patch RGFX.EXE (intro/outro skip, save auto-load) ──
    // Wildcard (W) on address bytes for LE relocation compatibility
    const intro_pattern = [_]u8{ 0x83, 0x3D, W, W, W, W, 0x00, 0x74, 0x0C, 0xC7, 0x45, 0xF0, 0x8A, 0x13 };
    const outro_pattern = [_]u8{ 0x75, 0x7C, 0xC6, 0x05, W, W, W, W, 0x02, 0xB9, 0x02, 0x00, 0x00, 0x00 };
    // Save auto-load: Two binary patches bypass the menu for auto-loading.
    //
    // Patch 1: FUN_000ab924 (menu function) → MOV EAX,0x1771; RET
    // Skips the blocking menu UI, returns "new game" code which triggers full
    // game initialization (FUN_000678ce + FUN_000502f9). The Present hook then
    // writes the LoadGame command once the game loop is active.
    const menufn_pattern = [_]u8{ 0x53, 0x51, 0x52, 0x56, 0x57, 0x55, 0x89, 0xE5, 0x81, 0xEC, 0x48, 0x00, 0x00, 0x00, 0x89, 0x45, 0xD8 };
    //
    // Patch 2: JZ retarget inside FUN_00053e15's loop — redirects the menu
    // branch past both menu paths A and B to the quit check, preventing the
    // inner menu from blocking the game loop after the save loads.
    const menu_jz_pattern = [_]u8{ 0x83, 0x3D, W, W, W, W, 0x00, 0x74, 0x52, 0xA1, W, W, W, W };

    const PatchDef = struct { pattern: []const u8, offset: usize, patch: []const u8, orig: []const u8, name: []const u8, enabled: bool };
    const patch_defs = [_]PatchDef{
        .{ .pattern = &intro_pattern, .offset = 7, .patch = &.{0xEB}, .orig = &.{0x74}, .name = "intro skip (JZ->JMP)", .enabled = skip_intro },
        .{ .pattern = &outro_pattern, .offset = 9, .patch = &.{ 0xEB, 0x73 }, .orig = &.{ 0xB9, 0x02 }, .name = "outro skip (JMP over anims)", .enabled = skip_intro },
        .{ .pattern = &menufn_pattern, .offset = 0, .patch = &.{ 0xB8, 0x71, 0x17, 0x00, 0x00, 0xC3, 0x90, 0x90 }, .orig = &.{ 0x53, 0x51, 0x52, 0x56, 0x57, 0x55, 0x89, 0xE5 }, .name = "menu fn (ret 0x1771)", .enabled = load_save != null },
        .{ .pattern = &menu_jz_pattern, .offset = 8, .patch = &.{0x40}, .orig = &.{0x52}, .name = "menu jz retarget", .enabled = load_save != null },
    };

    const PatchState = struct { offset: usize, orig: []const u8, applied: bool };
    var patches: [patch_defs.len]PatchState = undefined;
    for (&patches, 0..) |*p, i| {
        p.* = .{ .offset = 0, .orig = patch_defs[i].orig, .applied = false };
    }

    const needs_patching = skip_intro or load_save != null;
    if (needs_patching) apply_patches: {
        print("Patching RGFX.EXE...\n");
        const rgfx_file = fs.openFileAbsolute(rgfx_exe, .{ .mode = .read_write }) catch {
            print("Warning: could not open RGFX.EXE for patching\n");
            break :apply_patches;
        };
        const rgfx_data = rgfx_file.readToEndAlloc(allocator, 8 * 1024 * 1024) catch {
            print("Warning: could not read RGFX.EXE\n");
            rgfx_file.close();
            break :apply_patches;
        };
        rgfx_file.close();
        defer allocator.free(rgfx_data);

        for (&patch_defs, 0..) |def, idx| {
            if (!def.enabled) continue;
            if (findPattern(rgfx_data, def.pattern)) |i| {
                const file_off = i + def.offset;
                var ok = true;
                for (def.patch, 0..) |byte, j| {
                    if (!patchByte(rgfx_exe, file_off + j, byte)) {
                        ok = false;
                        break;
                    }
                }
                if (ok) {
                    patches[idx].offset = file_off;
                    patches[idx].applied = true;
                    printFmt("  0x{x}: {s}\n", .{ file_off, def.name });
                }
            } else {
                printFmt("  Warning: pattern not found for {s}\n", .{def.name});
            }
        }
    }

    defer {
        var restored = false;
        for (&patches) |*p| {
            if (p.applied) {
                for (p.orig, 0..) |byte, j| {
                    if (!patchByte(rgfx_exe, p.offset + j, byte)) break;
                }
                p.applied = false;
                restored = true;
            }
        }
        if (restored) print("RGFX.EXE restored.\n");
    }

    // ── Resolve hook DLL path ──
    var dll_buf: [fs.max_path_bytes]u8 = undefined;
    var dll_path: []const u8 = &.{};
    if (inject_hook) {
        const self_path = try fs.selfExePathAlloc(allocator);
        defer allocator.free(self_path);
        const self_dir = fs.path.dirname(self_path) orelse ".";
        dll_path = std.fmt.bufPrint(&dll_buf, "{s}\\redguard_hook.dll", .{self_dir}) catch return;
        dll_buf[dll_path.len] = 0;
    }

    // ── Launch ──
    printFmt("Game dir:  {s}\n", .{game_path});
    if (skip_intro) print("Intro:     SKIP\n");
    if (windowed) print("Window:    WINDOWED\n");
    if (trainer) print("Trainer:   ON\n");
    if (load_save) |s| printFmt("Load save: slot {s}\n", .{s});
    print("Launching DOSBox...\n");

    // Tell the hook DLL which features to enable
    if (windowed) {
        _ = SetEnvironmentVariableA("REDGUARD_WINDOWED", "1");
    }
    if (trainer) {
        _ = SetEnvironmentVariableA("REDGUARD_TRAINER", "1");
    }
    if (load_save) |slot_str| {
        // Pass the slot number string directly to the hook DLL
        // (validated and parsed on the hook side)
        const z: [*:0]const u8 = @ptrCast(slot_str.ptr);
        _ = SetEnvironmentVariableA("REDGUARD_LOAD_SAVE", z);
    }

    var child = std.process.Child.init(
        &.{ dosbox_exe, "-conf", conf_main, "-conf", conf_tmp, "-noconsole" },
        allocator,
    );
    child.cwd = dosbox_dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    // ── Wait for SDL window + inject ──
    if (inject_hook) {
        var hwnd: HWND = undefined;
        while (true) {
            if (FindWindowA("SDL_app", null)) |found| {
                hwnd = found;
                break;
            }
            sleep(200);
        }

        var pid: DWORD = 0;
        _ = GetWindowThreadProcessId(hwnd, &pid);
        printFmt("DOSBox PID: {d} -- injecting hook...\n", .{pid});

        injectDll(pid, dll_path[0 .. dll_path.len + 1]) catch |err| {
            printFmt("Injection failed: {s}\n", .{@errorName(err)});
            return;
        };

        if (windowed)
            print("Hook injected. Game will run windowed.\n")
        else
            print("Hook injected.\n");
    }

    _ = try child.wait();
}
