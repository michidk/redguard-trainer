const std = @import("std");
const windows = std.os.windows;

const BOOL = windows.BOOL;
const DWORD = u32;
const HANDLE = windows.HANDLE;
const HINSTANCE = *anyopaque;
const LPVOID = ?*anyopaque;
const HWND = windows.HWND;
const UINT = u32;
const HRESULT = i32;

const DLL_PROCESS_ATTACH: DWORD = 1;
const PAGE_EXECUTE_READWRITE: DWORD = 0x40;
const D3D_SDK_VERSION: UINT = 32;

extern "kernel32" fn OutputDebugStringA(s: [*:0]const u8) callconv(.winapi) void;
extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(mod: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, new: DWORD, old: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn CreateThread(attr: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) DWORD, param: ?*anyopaque, flags: DWORD, id: ?*DWORD) callconv(.winapi) ?HANDLE;

// D3DPRESENT_PARAMETERS field offsets (32-bit)
const PP_WINDOWED: usize = 32;
const PP_REFRESH_RATE: usize = 48;

// IDirect3D9::CreateDevice signature (vtable index 16)
const CreateDeviceFn = *const fn (
    this: *anyopaque,
    adapter: UINT,
    device_type: UINT,
    focus_window: ?HWND,
    behavior_flags: DWORD,
    present_params: [*]u8,
    pp_device: *?*anyopaque,
) callconv(.winapi) HRESULT;

var original_create_device: CreateDeviceFn = undefined;

fn hookedCreateDevice(
    this: *anyopaque,
    adapter: UINT,
    device_type: UINT,
    focus_window: ?HWND,
    behavior_flags: DWORD,
    present_params: [*]u8,
    pp_device: *?*anyopaque,
) callconv(.winapi) HRESULT {
    OutputDebugStringA("redguard_hook: CreateDevice intercepted! Forcing windowed mode.");

    // Flip Windowed = TRUE
    const windowed_ptr: *align(1) BOOL = @ptrCast(present_params + PP_WINDOWED);
    windowed_ptr.* = 1;

    // FullScreen_RefreshRateInHz must be 0 for windowed mode
    const refresh_ptr: *align(1) UINT = @ptrCast(present_params + PP_REFRESH_RATE);
    refresh_ptr.* = 0;

    OutputDebugStringA("redguard_hook: D3D params patched: Windowed=TRUE, RefreshRate=0");

    return original_create_device(this, adapter, device_type, focus_window, behavior_flags, present_params, pp_device);
}

fn workerThread(_: ?*anyopaque) callconv(.winapi) DWORD {
    OutputDebugStringA("redguard_hook: waiting for d3d9.dll to load...");

    // Poll for d3d9.dll — nGlide loads it when grSstWinOpen is called
    var d3d9_mod: ?*anyopaque = null;
    var attempts: u32 = 0;
    while (attempts < 120) : (attempts += 1) {
        d3d9_mod = GetModuleHandleA("d3d9.dll");
        if (d3d9_mod != null) break;
        Sleep(250);
    }

    if (d3d9_mod == null) {
        OutputDebugStringA("redguard_hook: d3d9.dll never loaded after 30s, giving up");
        return 1;
    }

    OutputDebugStringA("redguard_hook: d3d9.dll found, hooking CreateDevice vtable");

    // Get Direct3DCreate9
    const create_fn_ptr = GetProcAddress(d3d9_mod.?, "Direct3DCreate9") orelse {
        OutputDebugStringA("redguard_hook: Direct3DCreate9 not found!");
        return 1;
    };
    const Direct3DCreate9: *const fn (UINT) callconv(.winapi) ?*anyopaque = @ptrCast(create_fn_ptr);

    // Create temp IDirect3D9 to get the vtable
    const d3d9_obj = Direct3DCreate9(D3D_SDK_VERSION) orelse {
        OutputDebugStringA("redguard_hook: Direct3DCreate9 returned NULL!");
        return 1;
    };

    // obj -> vtable_ptr -> vtable[16] = CreateDevice
    const vtable: [*]*anyopaque = @as(*[*]*anyopaque, @ptrCast(@alignCast(d3d9_obj))).*;

    // Save original
    original_create_device = @ptrCast(vtable[16]);

    // Make vtable entry writable and overwrite
    var old_protect: DWORD = 0;
    if (VirtualProtect(@ptrCast(&vtable[16]), @sizeOf(*anyopaque), PAGE_EXECUTE_READWRITE, &old_protect) == 0) {
        OutputDebugStringA("redguard_hook: VirtualProtect on vtable failed!");
        const release: *const fn (*anyopaque) callconv(.winapi) u32 = @ptrCast(vtable[2]);
        _ = release(d3d9_obj);
        return 1;
    }

    vtable[16] = @ptrCast(@constCast(&hookedCreateDevice));
    _ = VirtualProtect(@ptrCast(&vtable[16]), @sizeOf(*anyopaque), old_protect, &old_protect);

    OutputDebugStringA("redguard_hook: IDirect3D9::CreateDevice hooked successfully!");

    // Release temp object — vtable is shared, hook persists
    const release: *const fn (*anyopaque) callconv(.winapi) u32 = @ptrCast(vtable[2]);
    _ = release(d3d9_obj);

    return 0;
}

pub export fn DllMain(inst: HINSTANCE, reason: DWORD, reserved: LPVOID) callconv(.winapi) BOOL {
    _ = inst;
    _ = reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        _ = CreateThread(null, 0, &workerThread, null, 0, null);
    }
    return 1;
}
