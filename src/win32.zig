const windows = @import("std").os.windows;

// ── Win32 types ──
pub const BOOL = windows.BOOL;
pub const DWORD = u32;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = *anyopaque;
pub const LPVOID = ?*anyopaque;
pub const HWND = windows.HWND;
pub const UINT = u32;
pub const HRESULT = i32;
pub const LONG = i32;

// ── Win32 constants ──
pub const DLL_PROCESS_ATTACH: DWORD = 1;
pub const PAGE_EXECUTE_READWRITE: DWORD = 0x40;
pub const D3D_SDK_VERSION: UINT = 32;
pub const GWL_WNDPROC: i32 = -4;

// D3DPRESENT_PARAMETERS field offsets (32-bit)
pub const PP_WINDOWED: usize = 32;
pub const PP_REFRESH_RATE: usize = 48;

// ── File I/O constants ──
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const CREATE_ALWAYS: DWORD = 2;
pub const FILE_APPEND_DATA: DWORD = 0x00000004;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const OPEN_ALWAYS: DWORD = 4;
pub const INVALID_HANDLE: HANDLE = @ptrFromInt(0xFFFFFFFF);

// ── Memory constants ──
pub const MEMORY_BASIC_INFORMATION = extern struct {
    BaseAddress: ?*anyopaque,
    AllocationBase: ?*anyopaque,
    AllocationProtect: DWORD,
    RegionSize: usize,
    State: DWORD,
    Protect: DWORD,
    Type: DWORD,
};
pub const MEM_COMMIT: DWORD = 0x1000;
pub const PAGE_NOACCESS: DWORD = 0x01;

// ── Virtual key codes ──
pub const VK_OEM_3: c_int = 0xC0; // ` ~ (tilde)
pub const VK_W: c_int = 0x57;
pub const VK_A: c_int = 0x41;
pub const VK_S: c_int = 0x53;
pub const VK_D: c_int = 0x44;
pub const VK_SPACE: c_int = 0x20;
pub const VK_CONTROL: c_int = 0x11;
pub const VK_LCONTROL: c_int = 0xA2;
pub const VK_RCONTROL: c_int = 0xA3;
pub const VK_SHIFT: c_int = 0x10;
pub const VK_R: c_int = 0x52; // Alternative for up
pub const VK_F: c_int = 0x46; // Alternative for down
pub const VK_UP: c_int = 0x26; // Arrow up
pub const VK_DOWN: c_int = 0x28; // Arrow down
pub const VK_LEFT: c_int = 0x25; // Arrow left
pub const VK_RIGHT: c_int = 0x27; // Arrow right

// ── Window message constants ──
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;

// ── kernel32 imports ──
pub extern "kernel32" fn OutputDebugStringA(s: [*:0]const u8) callconv(.winapi) void;
pub extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GetProcAddress(mod: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, new: DWORD, old: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn CreateThread(attr: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) DWORD, param: ?*anyopaque, flags: DWORD, id: ?*DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: ?[*]u8, size: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateFileA(name: [*:0]const u8, access: DWORD, share: DWORD, sa: ?*anyopaque, disp: DWORD, flags: DWORD, tmpl: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WriteFile(file: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, ovl: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetFilePointer(file: HANDLE, dist: i32, dist_high: ?*i32, method: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn VirtualQuery(addr: ?*const anyopaque, buf: *MEMORY_BASIC_INFORMATION, len: usize) callconv(.winapi) usize;

// ── user32 imports ──
pub extern "user32" fn FindWindowA(class: ?[*:0]const u8, window: ?[*:0]const u8) callconv(.winapi) ?HWND;
pub extern "user32" fn SetWindowLongA(hwnd: ?HWND, index: i32, new_long: LONG) callconv(.winapi) LONG;
pub extern "user32" fn CallWindowProcA(prev: ?*anyopaque, hwnd: ?HWND, msg: UINT, wparam: usize, lparam: isize) callconv(.winapi) isize;
pub extern "user32" fn GetAsyncKeyState(vkey: c_int) callconv(.winapi) c_short;
pub extern "user32" fn ClipCursor(rect: ?*const anyopaque) callconv(.winapi) BOOL;
pub extern "user32" fn ShowCursor(show: BOOL) callconv(.winapi) c_int;
pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
