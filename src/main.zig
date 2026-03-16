const std = @import("std");
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
extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn keybd_event(bVk: u8, bScan: u8, dwFlags: DWORD, dwExtra: usize) callconv(.winapi) void;

// ── Helpers ──
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

// ── DLL Injection ──
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

// ── RGFX.EXE patch restore ──
fn patchByte(path: []const u8, offset: usize, byte: u8) bool {
    const f = fs.openFileAbsolute(path, .{ .mode = .read_write }) catch return false;
    defer f.close();
    _ = f.pwrite(&[_]u8{byte}, offset) catch return false;
    return true;
}

fn restoreRgfx(patched: bool, path: []const u8, offset: usize) void {
    if (!patched) return;
    if (patchByte(path, offset, 0x74)) {
        print("RGFX.EXE restored (intro patch reverted).\n");
    } else {
        print("Warning: could not restore RGFX.EXE\n");
    }
}

// ── Main ──
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse game path from args
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip exe name

    const game_dir = args.next() orelse {
        print("Usage: redguard-trainer [options] <game-path>\n\n");
        print("  <game-path>    Path to the Redguard installation directory\n");
        print("                 (contains DOSBOX/ folder and dosbox_redguard.conf)\n\n");
        print("Options:\n");
        print("  --skip-intro   Skip intro cinematics\n\n");
        print("Example:\n");
        print("  redguard-trainer --skip-intro \"D:\\Games\\GOG Galaxy\\Redguard\"\n");
        return;
    };

    // Check for --skip-intro (may appear before or after game_dir)
    var skip_intro = false;
    if (std.mem.eql(u8, game_dir, "--skip-intro")) {
        skip_intro = true;
    }
    // Check remaining args
    var actual_game_dir = game_dir;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--skip-intro")) {
            skip_intro = true;
        } else {
            actual_game_dir = arg;
        }
    }
    if (skip_intro and std.mem.eql(u8, actual_game_dir, "--skip-intro")) {
        print("Error: missing <game-path>\n");
        return;
    }
    const game_path = actual_game_dir;

    // Build paths relative to game path
    var dosbox_exe_buf: [fs.max_path_bytes]u8 = undefined;
    var conf_main_buf: [fs.max_path_bytes]u8 = undefined;
    var conf_game_buf: [fs.max_path_bytes]u8 = undefined;
    var dosbox_dir_buf: [fs.max_path_bytes]u8 = undefined;
    var conf_tmp_buf: [fs.max_path_bytes]u8 = undefined;

    const dosbox_exe = std.fmt.bufPrint(&dosbox_exe_buf, "{s}\\DOSBOX\\dosbox.exe", .{game_path}) catch return;
    const dosbox_dir = std.fmt.bufPrint(&dosbox_dir_buf, "{s}\\DOSBOX", .{game_path}) catch return;
    const conf_main = std.fmt.bufPrint(&conf_main_buf, "{s}\\dosbox_redguard.conf", .{game_path}) catch return;
    const conf_game = std.fmt.bufPrint(&conf_game_buf, "{s}\\dosbox_redguard_single.conf", .{game_path}) catch return;
    const conf_tmp = std.fmt.bufPrint(&conf_tmp_buf, "{s}\\DOSBOX\\trainer_autoexec.conf", .{game_path}) catch return;

    dosbox_exe_buf[dosbox_exe.len] = 0;
    dosbox_dir_buf[dosbox_dir.len] = 0;
    conf_main_buf[conf_main.len] = 0;
    conf_game_buf[conf_game.len] = 0;
    conf_tmp_buf[conf_tmp.len] = 0;

    // Write temp DOSBox config: override fullscreen=false + autoexec
    {
        const tmp_content =
            "[sdl]\r\n" ++
            "fullscreen=false\r\n" ++
            "\r\n" ++
            "[glide]\r\n" ++
            "splash=false\r\n" ++
            "\r\n" ++
            "[autoexec]\r\n" ++
            "@echo off\r\n" ++
            "cls\r\n" ++
            "mount C \"..\" -freesize 512\r\n" ++
            "imgmount d \"..\\game.ins\" -t iso\r\n" ++
            "c:\r\n" ++
            "cd redguard\r\n" ++
            "cls\r\n" ++
            "rgfx.exe\r\n" ++
            "exit\r\n";
        const file = fs.createFileAbsolute(conf_tmp, .{}) catch {
            print("Error: could not write temp config\n");
            return;
        };
        file.writeAll(tmp_content) catch {};
        file.close();
    }
    defer fs.deleteFileAbsolute(conf_tmp) catch {};

    // Patch RGFX.EXE to skip intro cinematics (single byte: JZ→JMP)
    // Pattern: 83 3D BD 38 1A 00 00 74 0C C7 45 F0 8A 13
    //          CMP [DAT_001a38bd],0 / JZ +0C / MOV [EBP-10],0x138a
    //          Patch byte at offset +7: 0x74 (JZ) → 0xEB (JMP)
    var rgfx_exe_buf: [fs.max_path_bytes]u8 = undefined;
    const rgfx_exe = std.fmt.bufPrint(&rgfx_exe_buf, "{s}\\Redguard\\RGFX.EXE", .{game_path}) catch return;
    rgfx_exe_buf[rgfx_exe.len] = 0;

    const intro_pattern = [_]u8{ 0x83, 0x3D, 0xBD, 0x38, 0x1A, 0x00, 0x00, 0x74, 0x0C, 0xC7, 0x45, 0xF0, 0x8A, 0x13 };
    const patch_offset: usize = 7; // byte index of JZ within the pattern
    var rgfx_patched = false;
    var rgfx_patch_file_offset: usize = 0;

    if (skip_intro) patch_intro: {
        print("Patching RGFX.EXE to skip intro...\n");
        const rgfx_file = fs.openFileAbsolute(rgfx_exe, .{ .mode = .read_write }) catch {
            print("Warning: could not open RGFX.EXE for patching\n");
            break :patch_intro;
        };

        const rgfx_data = rgfx_file.readToEndAlloc(allocator, 8 * 1024 * 1024) catch {
            print("Warning: could not read RGFX.EXE\n");
            rgfx_file.close();
            break :patch_intro;
        };
        defer allocator.free(rgfx_data);

        // Search for the pattern
        for (0..rgfx_data.len - intro_pattern.len) |i| {
            if (std.mem.eql(u8, rgfx_data[i .. i + intro_pattern.len], &intro_pattern)) {
                rgfx_patch_file_offset = i + patch_offset;
                rgfx_file.close();
                if (rgfx_data[rgfx_patch_file_offset] == 0x74) {
                    if (patchByte(rgfx_exe, rgfx_patch_file_offset, 0xEB)) {
                        rgfx_patched = true;
                        printFmt("  Patched at offset 0x{x}: JZ->JMP (intro skip)\n", .{rgfx_patch_file_offset});
                    }
                }
                break :patch_intro;
            }
        }
        rgfx_file.close();
        print("Warning: intro skip pattern not found in RGFX.EXE\n");
    }

    // Restore RGFX.EXE after DOSBox exits
    defer restoreRgfx(rgfx_patched, rgfx_exe, rgfx_patch_file_offset);

    // Resolve hook DLL path (next to our exe)
    const self_path = try fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    const self_dir = fs.path.dirname(self_path) orelse ".";
    var dll_buf: [fs.max_path_bytes]u8 = undefined;
    const dll_path = std.fmt.bufPrint(&dll_buf, "{s}\\redguard_hook.dll", .{self_dir}) catch return;
    dll_buf[dll_path.len] = 0;

    printFmt("Game dir:  {s}\n", .{game_path});
    printFmt("DOSBox:    {s}\n", .{dosbox_exe});
    printFmt("Hook DLL:  {s}\n", .{dll_path});
    if (skip_intro) print("Intro:     SKIP (binary patch)\n");

    // Launch DOSBox with our temp config (overrides fullscreen + optionally skips intro)
    print("Launching DOSBox...\n");
    var child = std.process.Child.init(
        &.{ dosbox_exe, "-conf", conf_main, "-conf", conf_tmp, "-noconsole" },
        allocator,
    );
    child.cwd = dosbox_dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    // Wait for SDL window
    print("Waiting for SDL window...\n");
    var hwnd: HWND = undefined;
    while (true) {
        if (FindWindowA("SDL_app", null)) |found| {
            hwnd = found;
            break;
        }
        sleep(200);
    }

    // Get PID and inject
    var pid: DWORD = 0;
    _ = GetWindowThreadProcessId(hwnd, &pid);
    printFmt("DOSBox PID: {d} — injecting hook...\n", .{pid});

    injectDll(pid, dll_path[0 .. dll_path.len + 1]) catch |err| {
        printFmt("Injection failed: {s}\n", .{@errorName(err)});
        return;
    };

    print("Hook injected. Game will run windowed.\n");
    _ = try child.wait();
}
