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
        print("Usage: redguard-trainer <game-path>\n\n");
        print("  <game-path>  Path to the Redguard installation directory\n");
        print("               (contains DOSBOX/ folder and dosbox_redguard.conf)\n\n");
        print("Example:\n");
        print("  redguard-trainer \"D:\\Games\\GOG Galaxy\\Redguard\"\n");
        return;
    };

    // Build paths relative to game dir
    //   <game_dir>/DOSBOX/dosbox.exe
    //   <game_dir>/dosbox_redguard.conf
    //   <game_dir>/dosbox_redguard_single.conf
    var dosbox_exe_buf: [fs.max_path_bytes]u8 = undefined;
    var conf_main_buf: [fs.max_path_bytes]u8 = undefined;
    var conf_game_buf: [fs.max_path_bytes]u8 = undefined;
    var dosbox_dir_buf: [fs.max_path_bytes]u8 = undefined;

    const dosbox_exe = std.fmt.bufPrint(&dosbox_exe_buf, "{s}\\DOSBOX\\dosbox.exe", .{game_dir}) catch return;
    const dosbox_dir = std.fmt.bufPrint(&dosbox_dir_buf, "{s}\\DOSBOX", .{game_dir}) catch return;
    const conf_main = std.fmt.bufPrint(&conf_main_buf, "{s}\\dosbox_redguard.conf", .{game_dir}) catch return;
    const conf_game = std.fmt.bufPrint(&conf_game_buf, "{s}\\dosbox_redguard_single.conf", .{game_dir}) catch return;

    // Null-terminate for C interop
    dosbox_exe_buf[dosbox_exe.len] = 0;
    dosbox_dir_buf[dosbox_dir.len] = 0;
    conf_main_buf[conf_main.len] = 0;
    conf_game_buf[conf_game.len] = 0;

    // Resolve hook DLL path (next to our exe)
    const self_path = try fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    const self_dir = fs.path.dirname(self_path) orelse ".";
    var dll_buf: [fs.max_path_bytes]u8 = undefined;
    const dll_path = std.fmt.bufPrint(&dll_buf, "{s}\\redguard_hook.dll", .{self_dir}) catch return;
    dll_buf[dll_path.len] = 0;

    printFmt("Game dir:  {s}\n", .{game_dir});
    printFmt("DOSBox:    {s}\n", .{dosbox_exe});
    printFmt("Hook DLL:  {s}\n", .{dll_path});

    // Launch DOSBox
    print("Launching DOSBox...\n");
    var child = std.process.Child.init(
        &.{ dosbox_exe, "-conf", conf_main, "-conf", conf_game, "-noconsole" },
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
