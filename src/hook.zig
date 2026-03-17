const ig = @import("cimgui");
const windows = @import("std").os.windows;

// ── Win32 types ──
const BOOL = windows.BOOL;
const DWORD = u32;
const HANDLE = windows.HANDLE;
const HINSTANCE = *anyopaque;
const LPVOID = ?*anyopaque;
const HWND = windows.HWND;
const UINT = u32;
const HRESULT = i32;
const LONG = i32;

const DLL_PROCESS_ATTACH: DWORD = 1;
const PAGE_EXECUTE_READWRITE: DWORD = 0x40;
const D3D_SDK_VERSION: UINT = 32;
const GWL_WNDPROC: i32 = -4;

// D3DPRESENT_PARAMETERS field offsets (32-bit)
const PP_WINDOWED: usize = 32;
const PP_REFRESH_RATE: usize = 48;

// ── Win32 imports ──
extern "kernel32" fn OutputDebugStringA(s: [*:0]const u8) callconv(.winapi) void;
extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(mod: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualProtect(addr: *anyopaque, size: usize, new: DWORD, old: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn CreateThread(attr: ?*anyopaque, stack: usize, start: *const fn (?*anyopaque) callconv(.winapi) DWORD, param: ?*anyopaque, flags: DWORD, id: ?*DWORD) callconv(.winapi) ?HANDLE;

// ── Logging ──
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_SHARE_READ: DWORD = 0x00000001;
const CREATE_ALWAYS: DWORD = 2;
const FILE_APPEND_DATA: DWORD = 0x00000004;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
const OPEN_ALWAYS: DWORD = 4;
const INVALID_HANDLE: HANDLE = @ptrFromInt(0xFFFFFFFF);
extern "kernel32" fn CreateFileA(name: [*:0]const u8, access: DWORD, share: DWORD, sa: ?*anyopaque, disp: DWORD, flags: DWORD, tmpl: ?HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn WriteFile(file: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, ovl: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SetFilePointer(file: HANDLE, dist: i32, dist_high: ?*i32, method: DWORD) callconv(.winapi) DWORD;

const LogLevel = enum { debug, info, warn, err };
const LOG_FILE = "redguard_hook.log";
var log_enabled: bool = true;

fn log(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (!log_enabled) return;
    const std = @import("std");

    // Format: "[LEVEL] message\r\n"
    var buf: [512]u8 = undefined;
    const prefix = switch (level) {
        .debug => "[DEBUG] ",
        .info => "[INFO]  ",
        .warn => "[WARN]  ",
        .err => "[ERROR] ",
    };

    var fbs = std.io.fixedBufferStream(&buf);
    fbs.writer().writeAll(prefix) catch return;
    fbs.writer().print(fmt, args) catch return;
    fbs.writer().writeAll("\r\n") catch return;

    const msg = fbs.getWritten();

    // Open file in append mode
    const h = CreateFileA(LOG_FILE, FILE_APPEND_DATA, FILE_SHARE_READ, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE) return;
    defer _ = CloseHandle(h);

    _ = SetFilePointer(h, 0, null, 2); // FILE_END
    _ = WriteFile(h, msg.ptr, @intCast(msg.len), null, null);
}

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

fn logDebug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

fn logErr(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}
extern "user32" fn FindWindowA(class: ?[*:0]const u8, window: ?[*:0]const u8) callconv(.winapi) ?HWND;
extern "user32" fn SetWindowLongA(hwnd: ?HWND, index: i32, new_long: LONG) callconv(.winapi) LONG;
extern "user32" fn CallWindowProcA(prev: ?*anyopaque, hwnd: ?HWND, msg: UINT, wparam: usize, lparam: isize) callconv(.winapi) isize;
extern "user32" fn GetAsyncKeyState(vkey: c_int) callconv(.winapi) c_short;
extern "user32" fn ClipCursor(rect: ?*const anyopaque) callconv(.winapi) BOOL;
extern "user32" fn ShowCursor(show: BOOL) callconv(.winapi) c_int;
extern "kernel32" fn VirtualQuery(addr: ?*const anyopaque, buf: *MEMORY_BASIC_INFORMATION, len: usize) callconv(.winapi) usize;

const MEMORY_BASIC_INFORMATION = extern struct {
    BaseAddress: ?*anyopaque,
    AllocationBase: ?*anyopaque,
    AllocationProtect: DWORD,
    RegionSize: usize,
    State: DWORD,
    Protect: DWORD,
    Type: DWORD,
};
const MEM_COMMIT: DWORD = 0x1000;
const PAGE_NOACCESS: DWORD = 0x01;

// ── ImGui backend bridge functions (from vendor/imgui_bridge.cpp) ──
extern fn bridge_ImplDX9_Init(device: ?*anyopaque) callconv(.c) bool;
extern fn bridge_ImplDX9_NewFrame() callconv(.c) void;
extern fn bridge_ImplDX9_RenderDrawData(draw_data: ?*anyopaque) callconv(.c) void;
extern fn bridge_ImplDX9_InvalidateDeviceObjects() callconv(.c) void;
extern fn bridge_ImplDX9_CreateDeviceObjects() callconv(.c) bool;
extern fn bridge_ImplWin32_Init(hwnd: ?*anyopaque) callconv(.c) bool;
extern fn bridge_ImplWin32_NewFrame() callconv(.c) void;
extern fn bridge_ImplWin32_WndProcHandler(hwnd: ?*anyopaque, msg: UINT, wparam: usize, lparam: isize) callconv(.c) isize;
extern fn bridge_SetBackBufferRenderTarget(device: ?*anyopaque) callconv(.c) void;

// ── D3D9 vtable function signatures (COM stdcall with explicit `this`) ──
const CreateDeviceFn = *const fn (*anyopaque, UINT, UINT, ?HWND, DWORD, [*]u8, *?*anyopaque) callconv(.winapi) HRESULT;
const EndSceneFn = *const fn (*anyopaque) callconv(.winapi) HRESULT;
const ResetFn = *const fn (*anyopaque, *anyopaque) callconv(.winapi) HRESULT;
const PresentFn = *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?HWND, ?*anyopaque) callconv(.winapi) HRESULT;

// ── Saved originals ──
var original_create_device: CreateDeviceFn = undefined;
var real_end_scene: EndSceneFn = undefined;
var real_reset: ResetFn = undefined;
var real_present: PresentFn = undefined;
var original_wndproc: ?*anyopaque = null;

// ── State ──
var imgui_initialized: bool = false;
var show_overlay: bool = false; // Press ` to open
var prev_toggle_down: bool = false;
var selected_world: c_int = 0;

var mem_base: ?[*]u8 = null;
var game_slide: isize = 0; // Offset: runtime address = ghidra address + slide
var slide_attempts: u32 = 0; // Throttle scan retries

const VK_OEM_3: c_int = 0xC0; // ` ~ (tilde)

// Game memory offsets (Ghidra virtual addresses from LE loader)
// Runtime address = ghidra_addr + game_slide (slide detected via world name table scan)
const GAME_CURRENT_WORLD: usize = 0x001a3f5c; // DAT_001a3f5c: current world ID
const GAME_TESTMAPS_FLAG: usize = 0x001a1e3b; // DAT_001a1e3b: testmaps mode flag (byte, 1 = enabled)
const GAME_PENDING_WORLD: usize = 0x001a3f60; // DAT_001a3f60: world ID to load (-1 = none)
const GAME_PENDING_MARKER: usize = 0x001a3f64; // DAT_001a3f64: spawn marker (0 = default)
const GAME_WORLD_NAMES: usize = 0x001e05b8; // DAT_001e05b8: world name table (0x18c bytes/entry)
const GAME_WORLD_STRIDE: usize = 0x18c; // 396 bytes per world entry

// Original SetCursorPos — saved during IAT hook
var real_set_cursor_pos: ?*const fn (c_int, c_int) callconv(.winapi) BOOL = null;

// Our SetCursorPos replacement — blocks when overlay is active
fn mySetCursorPos(x: c_int, y: c_int) callconv(.winapi) BOOL {
    if (show_overlay) return 1; // Pretend success but do nothing
    if (real_set_cursor_pos) |f| return f(x, y);
    return 0;
}

// Hook SetCursorPos via IAT patching in dosbox.exe
fn hookSetCursorPos() void {
    const base = GetModuleHandleA(null) orelse return;
    const base_addr = @intFromPtr(base);
    const base_bytes: [*]const u8 = @ptrCast(base);

    // Get real SetCursorPos address
    const user32 = GetModuleHandleA("user32.dll") orelse return;
    const real_addr = @intFromPtr(GetProcAddress(user32, "SetCursorPos") orelse return);
    real_set_cursor_pos = @ptrFromInt(real_addr);

    // Parse PE: e_lfanew → import directory RVA
    const e_lfanew: u32 = @as(*align(1) const u32, @ptrCast(base_bytes + 0x3C)).*;
    const import_dir_rva: u32 = @as(*align(1) const u32, @ptrCast(base_bytes + e_lfanew + 0x80)).*;
    if (import_dir_rva == 0) return;

    // Walk IMAGE_IMPORT_DESCRIPTORs (20 bytes each)
    var desc: [*]const u8 = base_bytes + import_dir_rva;
    while (true) {
        const first_thunk: u32 = @as(*align(1) const u32, @ptrCast(desc + 16)).*;
        const name_rva: u32 = @as(*align(1) const u32, @ptrCast(desc + 12)).*;
        if (first_thunk == 0 and name_rva == 0) break;

        // Walk IAT entries for this DLL
        var iat: usize = base_addr + first_thunk;
        while (true) {
            const entry: *align(1) u32 = @ptrFromInt(iat);
            if (entry.* == 0) break;
            if (entry.* == @as(u32, @truncate(real_addr))) {
                // Found SetCursorPos in IAT — replace with our hook
                var old_prot: DWORD = 0;
                if (VirtualProtect(@ptrFromInt(iat), 4, PAGE_EXECUTE_READWRITE, &old_prot) != 0) {
                    entry.* = @truncate(@intFromPtr(&mySetCursorPos));
                    _ = VirtualProtect(@ptrFromInt(iat), 4, old_prot, &old_prot);
                }
                return;
            }
            iat += 4;
        }
        desc += 20;
    }
}

// ── DOSBox MemBase discovery ──
// Scans DOSBox .text for GetMemBase(): A1 XX XX XX XX C3 (MOV EAX,[addr]; RETN)
// Verifies candidate by checking multiple BIOS Data Area signatures.
fn findMemBase() ?[*]u8 {
    // Method 1: Pattern scan for GetMemBase() — A1 XX XX XX XX C3
    if (findMemBasePattern()) |mb| return mb;

    // Method 2: Scan DOSBox's data sections for pointers to DOS memory
    if (findMemBaseDataScan()) |mb| return mb;

    return null;
}

fn findMemBasePattern() ?[*]u8 {
    const base = GetModuleHandleA(null) orelse return null;
    const base_addr = @intFromPtr(base);
    const base_ptr: [*]const u8 = @ptrCast(base);

    const e_lfanew: u32 = @as(*align(1) const u32, @ptrCast(base_ptr + 0x3C)).*;
    const size_of_image: u32 = @as(*align(1) const u32, @ptrCast(base_ptr + e_lfanew + 0x50)).*;
    if (size_of_image < 6) return null;

    // Try multiple patterns for GetMemBase:
    // Pattern 1: A1 XX XX XX XX C3 (MOV EAX,[addr]; RETN — no frame pointer)
    // Pattern 2: 8B 0D XX XX XX XX C3 (MOV ECX,[addr]; RETN)
    var i: u32 = 0;
    while (i < size_of_image - 7) : (i += 1) {
        var global_addr: u32 = 0;

        if (base_ptr[i] == 0xA1 and base_ptr[i + 5] == 0xC3) {
            global_addr = @as(*align(1) const u32, @ptrCast(base_ptr + i + 1)).*;
        } else if (base_ptr[i] == 0x8B and base_ptr[i + 1] == 0x0D and base_ptr[i + 6] == 0xC3) {
            global_addr = @as(*align(1) const u32, @ptrCast(base_ptr + i + 2)).*;
        } else continue;

        if (global_addr < base_addr or global_addr >= base_addr + size_of_image) continue;
        if (tryReadMemBase(global_addr)) |mb| return mb;
    }
    return null;
}

fn findMemBaseDataScan() ?[*]u8 {
    // DOSBox allocates MemBase via malloc (~16-32MB). The allocation sits inside
    // a larger VirtualAlloc region, so MemBase may not start at the region boundary.
    // Strategy: find large committed RW regions, then scan within for the BDA
    // COM1 port signature (0x03F8) at offset 0x400 from a candidate MemBase.
    var addr: usize = 0x01000000;
    while (addr < 0x7FFF0000) {
        var mbi: MEMORY_BASIC_INFORMATION = undefined;
        if (VirtualQuery(@ptrFromInt(addr), &mbi, @sizeOf(MEMORY_BASIC_INFORMATION)) == 0) break;

        const region_base = @intFromPtr(mbi.BaseAddress orelse break);
        const region_size = mbi.RegionSize;
        if (region_size == 0) break;

        // Look for large (>= 16MB) committed read/write regions
        if (mbi.State == MEM_COMMIT and region_size >= 0x01000000 and
            (mbi.Protect == 0x04 or mbi.Protect == 0x40))
        {
            // Scan first 64KB for COM1 port (0x03F8) which sits at MemBase+0x400
            const scan_limit: usize = @min(0x10000, region_size - 0x500);
            var off: usize = 0;
            while (off < scan_limit) : (off += 0x10) { // malloc returns 16-byte aligned
                const candidate: [*]u8 = @ptrFromInt(region_base + off);
                const com1: u16 = @as(*align(1) const u16, @ptrCast(candidate + 0x400)).*;
                if (com1 == 0x03F8) {
                    // Double-check with video mode and equipment word
                    if (verifyMemBase(candidate)) return candidate;
                }
            }
        }

        addr = region_base + region_size;
    }
    return null;
}

fn tryReadMemBase(global_addr: u32) ?[*]u8 {
    var mbi: MEMORY_BASIC_INFORMATION = undefined;
    if (VirtualQuery(@ptrFromInt(global_addr), &mbi, @sizeOf(MEMORY_BASIC_INFORMATION)) == 0) return null;
    if (mbi.State != MEM_COMMIT or (mbi.Protect & PAGE_NOACCESS) != 0) return null;

    const candidate = @as(*const ?[*]u8, @ptrFromInt(global_addr)).* orelse return null;
    return tryReadMemBasePtr(@intFromPtr(candidate));
}

fn tryReadMemBasePtr(ptr_val: u32) ?[*]u8 {
    if (ptr_val < 0x01000000 or ptr_val > 0x7FFFFFFF) return null;

    const candidate: [*]u8 = @ptrFromInt(ptr_val);
    if (verifyMemBase(candidate)) return candidate;
    return null;
}

fn verifyMemBase(candidate: [*]u8) bool {
    var mbi: MEMORY_BASIC_INFORMATION = undefined;

    // Check that the candidate region is readable (check at offset 0x500 — well into BDA)
    if (VirtualQuery(@ptrCast(candidate + 0x500), &mbi, @sizeOf(MEMORY_BASIC_INFORMATION)) == 0) return false;
    if (mbi.State != MEM_COMMIT or (mbi.Protect & PAGE_NOACCESS) != 0) return false;

    // Verify with multiple BDA signatures:
    // 1. COM1 port at offset 0x400 should be 0x03F8
    const com1: u16 = @as(*align(1) const u16, @ptrCast(candidate + 0x400)).*;
    if (com1 == 0x03F8) return true;

    // 2. Conventional memory size at offset 0x413 should be 640 (0x0280)
    const conv_mem: u16 = @as(*align(1) const u16, @ptrCast(candidate + 0x413)).*;
    if (conv_mem == 0x0280) return true;

    // 3. Video mode at offset 0x449 — common values: 0x03 (80x25 text), 0x13 (320x200)
    const vmode: u8 = candidate[0x449];
    if (vmode == 0x03 or vmode == 0x13) {
        // Also check: number of columns at 0x44A should be 80 or 40 or 320
        const cols: u16 = @as(*align(1) const u16, @ptrCast(candidate + 0x44A)).*;
        if (cols == 80 or cols == 40 or cols == 320) return true;
    }

    return false;
}

fn readGameU32(offset: usize) ?u32 {
    const base = mem_base orelse return null;
    const actual = @as(usize, @intCast(@as(isize, @intCast(offset)) + game_slide));
    return @as(*align(1) const u32, @ptrCast(base + actual)).*;
}

fn writeGameU8(offset: usize, value: u8) void {
    const base = mem_base orelse return;
    const actual = @as(usize, @intCast(@as(isize, @intCast(offset)) + game_slide));
    base[actual] = value;
}

fn writeGameU32(offset: usize, value: u32) void {
    const base = mem_base orelse return;
    const actual = @as(usize, @intCast(@as(isize, @intCast(offset)) + game_slide));
    @as(*align(1) u32, @ptrCast(base + actual)).* = value;
}

/// Scan emulated DOS memory for a known embedded string to compute the slide
/// between Ghidra addresses and actual runtime addresses.
/// "testmaps\0" is hardcoded in RGFX.EXE at Ghidra address 0x00170d3a.
fn detectGameSlide() bool {
    const base = mem_base orelse return false;
    const scan_end: usize = 0x2000000; // 32MB
    const ghidra_addr: usize = 0x00170d3a; // From strings.txt

    logDebug("detectSlide: MemBase=0x{x} scanning 0x10000..0x{x}", .{ @intFromPtr(base), scan_end });

    // Scan for "testmaps\0"
    var hits: u32 = 0;
    var off: usize = 0x10000;
    while (off < scan_end - 9) : (off += 1) {
        if (base[off] == 't' and base[off + 1] == 'e' and base[off + 2] == 's' and
            base[off + 3] == 't' and base[off + 4] == 'm' and base[off + 5] == 'a' and
            base[off + 6] == 'p' and base[off + 7] == 's' and base[off + 8] == 0)
        {
            hits += 1;
            const slide = @as(isize, @intCast(off)) - @as(isize, @intCast(ghidra_addr));

            // Verify with second "testmaps" instance at 0x171c1f
            const ghidra_addr2: usize = 0x00171c1f;
            const expected2 = @as(usize, @intCast(@as(isize, @intCast(ghidra_addr2)) + slide));
            if (expected2 + 8 < scan_end and
                base[expected2] == 't' and base[expected2 + 1] == 'e' and
                base[expected2 + 2] == 's' and base[expected2 + 3] == 't' and
                base[expected2 + 4] == 'm' and base[expected2 + 5] == 'a' and
                base[expected2 + 6] == 'p' and base[expected2 + 7] == 's')
            {
                game_slide = slide;
                logInfo("Slide detected: {d} (0x{x}) — verified at 0x{x} and 0x{x}", .{
                    slide, @as(usize, @intCast(if (slide >= 0) slide else -slide)), off, expected2,
                });
                return true;
            }
        }
    }

    logWarn("Slide detection failed: {d} candidates, none verified", .{hits});
    return false;
}

// World IDs and names from WORLD.INI (note: 9, 10, 16 don't exist)
const WorldEntry = struct { id: u32, name: [*:0]const u8 };
const world_list = [_]WorldEntry{
    .{ .id = 0, .name = "Hideout (Start)" },
    .{ .id = 1, .name = "Stros M'Kai Island" },
    .{ .id = 2, .name = "Catacombs" },
    .{ .id = 3, .name = "Palace Interior" },
    .{ .id = 4, .name = "Dwarven Caverns" },
    .{ .id = 5, .name = "Observatory" },
    .{ .id = 6, .name = "N'Gasta's Island" },
    .{ .id = 7, .name = "N'Gasta's Tower" },
    .{ .id = 8, .name = "Dwarven Ruins Interior" },
    .{ .id = 11, .name = "Jail" },
    .{ .id = 12, .name = "Temple" },
    .{ .id = 13, .name = "Mages Guild" },
    .{ .id = 14, .name = "Vile Lair" },
    .{ .id = 15, .name = "Draggin Tale Inn" },
    .{ .id = 17, .name = "League Hideout" },
    .{ .id = 18, .name = "Silversmith (1F)" },
    .{ .id = 19, .name = "Silversmith (2F)" },
    .{ .id = 20, .name = "Bell Tower" },
    .{ .id = 21, .name = "Harbor Tower" },
    .{ .id = 22, .name = "Gerrick's" },
    .{ .id = 23, .name = "Cartographer" },
    .{ .id = 24, .name = "Smuggler's Den" },
    .{ .id = 25, .name = "Rollo's" },
    .{ .id = 26, .name = "J'ffer's" },
    .{ .id = 27, .name = "Island (Sunset)" },
    .{ .id = 28, .name = "Island (Night)" },
    .{ .id = 29, .name = "Brennan's" },
    .{ .id = 30, .name = "Palace Exterior" },
};

// ── WndProc hook (forwards input to ImGui) ──
fn hookedWndProc(hwnd: ?HWND, msg: UINT, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (imgui_initialized) {
        // Always let ImGui process the message
        _ = bridge_ImplWin32_WndProcHandler(@ptrCast(hwnd), msg, wparam, lparam);

        // When overlay is active, block ALL mouse messages from reaching DOSBox's SDL.
        // SDL re-centers the cursor every frame via SetCursorPos — blocking WM_MOUSEMOVE
        // prevents it from seeing mouse input and re-grabbing.
        if (show_overlay) {
            if ((msg >= 0x0200 and msg <= 0x020E) or // WM_MOUSEMOVE..WM_MOUSEHWHEEL
                (msg >= 0x00A0 and msg <= 0x00A9) or // WM_NCMOUSEMOVE..WM_NCXBUTTONDBLCLK
                msg == 0x00FF) // WM_INPUT (raw input)
                return 0;
        }
    }
    return CallWindowProcA(original_wndproc, hwnd, msg, wparam, lparam);
}

// ── EndScene hook — passthrough (we render in Present instead) ──
fn hookedEndScene(this: *anyopaque) callconv(.winapi) HRESULT {
    return real_end_scene(this);
}

// ── Present hook — renders ImGui overlay right before frame display ──
// nGlide composites Glide→D3D9 output after EndScene, so we render here
// in our own BeginScene/EndScene pair to guarantee visibility.
fn hookedPresent(this: *anyopaque, src: ?*anyopaque, dst: ?*anyopaque, wnd: ?HWND, rgn: ?*anyopaque) callconv(.winapi) HRESULT {
    if (!imgui_initialized) {
        initImGui(this);
    }

    if (imgui_initialized) {
        // Retry slide detection periodically (not every frame — scan is expensive)
        if (mem_base != null and game_slide == 0 and slide_attempts < 10) {
            slide_attempts += 1;
            _ = detectGameSlide();
        }

        // Toggle overlay with ` (tilde)
        const toggle_down = (GetAsyncKeyState(VK_OEM_3) & @as(c_short, -32768)) != 0;
        if (toggle_down and !prev_toggle_down) {
            show_overlay = !show_overlay;
        }
        prev_toggle_down = toggle_down;

        // Render ImGui in its own scene, targeting the backbuffer
        const dev_vtable: [*]*anyopaque = @as(*[*]*anyopaque, @ptrCast(@alignCast(this))).*;
        const beginScene: *const fn (*anyopaque) callconv(.winapi) HRESULT = @ptrCast(dev_vtable[41]);
        _ = beginScene(this);
        bridge_SetBackBufferRenderTarget(this);

        bridge_ImplDX9_NewFrame();
        bridge_ImplWin32_NewFrame();
        ig.igNewFrame();

        // When overlay is active: show cursor and release DOSBox's mouse grab
        ig.igGetIO().*.MouseDrawCursor = show_overlay;
        if (show_overlay) {
            _ = ClipCursor(null); // Release SDL mouse confinement
        }

        if (show_overlay) {
            drawOverlay();
        }

        ig.igRender();
        if (ig.igGetDrawData()) |dd| {
            bridge_ImplDX9_RenderDrawData(@ptrCast(dd));
        }

        _ = real_end_scene(this);
    }

    return real_present(this, src, dst, wnd, rgn);
}

// ── Reset hook — invalidate/recreate ImGui D3D9 resources ──
fn hookedReset(this: *anyopaque, present_params: *anyopaque) callconv(.winapi) HRESULT {
    if (imgui_initialized) bridge_ImplDX9_InvalidateDeviceObjects();
    const hr = real_reset(this, present_params);
    if (hr >= 0 and imgui_initialized) _ = bridge_ImplDX9_CreateDeviceObjects();
    return hr;
}

// ── Overlay UI ──
fn drawOverlay() void {
    const std = @import("std");

    ig.igSetNextWindowSize(.{ .x = 320, .y = 0 }, ig.ImGuiCond_FirstUseEver);
    ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, ig.ImGuiCond_FirstUseEver);

    if (ig.igBegin("Redguard Trainer", null, 0)) {
        ig.igTextUnformatted("Level Loader");
        ig.igSeparator();

        // Show current world
        if (readGameU32(GAME_CURRENT_WORLD)) |cw| {
            var buf: [64:0]u8 = @splat(0);
            if (cw == 0xFFFFFFFF) {
                _ = std.fmt.bufPrint(&buf, "Current world: none", .{}) catch {};
            } else {
                _ = std.fmt.bufPrint(&buf, "Current world: {d}", .{cw}) catch {};
            }
            ig.igTextUnformatted(&buf);
            ig.igSpacing();
        }

        // World selector listbox
        if (ig.igBeginListBox("##worlds", .{ .x = -1, .y = ig.igGetTextLineHeightWithSpacing() * 8 })) {
            for (world_list, 0..) |entry, idx| {
                const is_selected = selected_world == @as(c_int, @intCast(idx));
                if (ig.igSelectableEx(entry.name, is_selected, 0, .{ .x = 0, .y = 0 })) {
                    selected_world = @intCast(idx);
                }
            }
            ig.igEndListBox();
        }
        ig.igSpacing();

        if (mem_base == null or game_slide == 0) ig.igBeginDisabled(true);
        if (ig.igButton("Load Level")) {
            const world_id = world_list[@intCast(selected_world)].id;
            // Trigger world load: set pending world ID.
            // FUN_00053e15 checks DAT_001a3f60 != -1 every frame and returns
            // the world ID, which the main loop routes to LAB_00020930
            // (FUN_000502f9 call) via: local_24 < 5000 → goto LAB_00020930.
            writeGameU32(GAME_PENDING_WORLD, world_id);
            writeGameU32(GAME_PENDING_MARKER, 0);
        }
        if (mem_base == null or game_slide == 0) {
            ig.igEndDisabled();
            if (mem_base == null) {
                ig.igTextUnformatted("MemBase not found");
            } else {
                ig.igTextUnformatted("Slide not detected (game still loading?)");
            }
        }

        ig.igSpacing();
        ig.igSeparator();

        // Diagnostics section
        if (ig.igCollapsingHeader("Diagnostics", 0)) {
            if (mem_base) |mb| {
                var dbuf: [128:0]u8 = @splat(0);
                _ = std.fmt.bufPrint(&dbuf, "MemBase: 0x{x}  Slide: {d} (0x{x})", .{ @intFromPtr(mb), game_slide, @as(usize, @intCast(@as(isize, @intCast(@as(u32, 0))) + game_slide)) }) catch {};
                ig.igTextUnformatted(&dbuf);

                if (readGameU32(GAME_CURRENT_WORLD)) |v| {
                    dbuf = @splat(0);
                    _ = std.fmt.bufPrint(&dbuf, "Current world: {d}  Pending: {d}", .{ v, if (readGameU32(GAME_PENDING_WORLD)) |p| p else 0 }) catch {};
                    ig.igTextUnformatted(&dbuf);
                }
            } else {
                ig.igTextUnformatted("MemBase not found");
            }
        }

        ig.igSpacing();
        ig.igSeparator();
        ig.igTextUnformatted("Press ` to toggle");
    }
    ig.igEnd();
}

// ── ImGui initialization (called once on first Present) ──
fn initImGui(device: *anyopaque) void {
    const hwnd = FindWindowA("SDL_app", null) orelse return;

    _ = ig.igCreateContext(null);
    const io = ig.igGetIO();
    io.*.ConfigFlags |= ig.ImGuiConfigFlags_NavEnableKeyboard;
    io.*.IniFilename = null; // No persistent config (we're injected)

    if (!bridge_ImplWin32_Init(@ptrCast(hwnd))) {
        ig.igDestroyContext(null);
        return;
    }
    if (!bridge_ImplDX9_Init(device)) {
        ig.igDestroyContext(null);
        return;
    }

    // Subclass WndProc for ImGui input
    const new_wndproc: LONG = @bitCast(@as(u32, @truncate(@intFromPtr(&hookedWndProc))));
    const old_long = SetWindowLongA(hwnd, GWL_WNDPROC, new_wndproc);
    const old_usize: usize = @bitCast(@as(u32, @bitCast(old_long)));
    original_wndproc = if (old_usize == 0) null else @ptrFromInt(old_usize);

    // Hook SetCursorPos to prevent DOSBox from re-centering mouse when overlay is active
    if (real_set_cursor_pos == null) hookSetCursorPos();

    // Discover DOSBox MemBase for game memory access
    if (mem_base == null) mem_base = findMemBase();

    // Detect address slide (DOS/4GW may load LE at different base than Ghidra assumed)
    if (mem_base != null and game_slide == 0) _ = detectGameSlide();

    imgui_initialized = true;
}

// ══════════════════════════════════════════════════════════════
// CreateDevice hook — forces windowed mode, hooks device vtable
// ══════════════════════════════════════════════════════════════

fn hookedCreateDevice(
    this: *anyopaque,
    adapter: UINT,
    device_type: UINT,
    focus_window: ?HWND,
    behavior_flags: DWORD,
    present_params: [*]u8,
    pp_device: *?*anyopaque,
) callconv(.winapi) HRESULT {
    // Force windowed mode
    const windowed_ptr: *align(1) BOOL = @ptrCast(present_params + PP_WINDOWED);
    windowed_ptr.* = 1;
    const refresh_ptr: *align(1) UINT = @ptrCast(present_params + PP_REFRESH_RATE);
    refresh_ptr.* = 0;

    const hr = original_create_device(this, adapter, device_type, focus_window, behavior_flags, present_params, pp_device);

    if (hr >= 0) {
        if (pp_device.*) |device| {
            hookDeviceVtable(device);
        }
    }

    return hr;
}

fn hookDeviceVtable(device: *anyopaque) void {
    const dev_vtable: [*]*anyopaque = @as(*[*]*anyopaque, @ptrCast(@alignCast(device))).*;
    const my_end_scene: *anyopaque = @ptrCast(@constCast(&hookedEndScene));
    const my_reset: *anyopaque = @ptrCast(@constCast(&hookedReset));
    const my_present: *anyopaque = @ptrCast(@constCast(&hookedPresent));
    var old_protect: DWORD = 0;

    // EndScene (vtable 42) — passthrough, needed for real_end_scene pointer
    if (dev_vtable[42] != my_end_scene) {
        real_end_scene = @ptrCast(dev_vtable[42]);
        if (VirtualProtect(@ptrCast(&dev_vtable[42]), @sizeOf(*anyopaque), PAGE_EXECUTE_READWRITE, &old_protect) != 0) {
            dev_vtable[42] = my_end_scene;
            _ = VirtualProtect(@ptrCast(&dev_vtable[42]), @sizeOf(*anyopaque), old_protect, &old_protect);
        }
    }

    // Present (vtable 17) — ImGui renders here
    if (dev_vtable[17] != my_present) {
        real_present = @ptrCast(dev_vtable[17]);
        if (VirtualProtect(@ptrCast(&dev_vtable[17]), @sizeOf(*anyopaque), PAGE_EXECUTE_READWRITE, &old_protect) != 0) {
            dev_vtable[17] = my_present;
            _ = VirtualProtect(@ptrCast(&dev_vtable[17]), @sizeOf(*anyopaque), old_protect, &old_protect);
        }
    }

    // Reset (vtable 16) — handles device lost
    if (dev_vtable[16] != my_reset) {
        real_reset = @ptrCast(dev_vtable[16]);
        if (VirtualProtect(@ptrCast(&dev_vtable[16]), @sizeOf(*anyopaque), PAGE_EXECUTE_READWRITE, &old_protect) != 0) {
            dev_vtable[16] = my_reset;
            _ = VirtualProtect(@ptrCast(&dev_vtable[16]), @sizeOf(*anyopaque), old_protect, &old_protect);
        }
    }
}

// ══════════════════════════════════════════════════════════════
// Worker thread + DllMain
// ══════════════════════════════════════════════════════════════

fn workerThread(_: ?*anyopaque) callconv(.winapi) DWORD {
    // Poll for d3d9.dll — nGlide loads it during initialization
    var d3d9_mod: ?*anyopaque = null;
    var attempts: u32 = 0;
    while (attempts < 120) : (attempts += 1) {
        d3d9_mod = GetModuleHandleA("d3d9.dll");
        if (d3d9_mod != null) break;
        Sleep(250);
    }
    if (d3d9_mod == null) return 1;

    // Get Direct3DCreate9 and create temp IDirect3D9 for vtable access
    const create_fn_ptr = GetProcAddress(d3d9_mod.?, "Direct3DCreate9") orelse return 1;
    const Direct3DCreate9: *const fn (UINT) callconv(.winapi) ?*anyopaque = @ptrCast(create_fn_ptr);
    const d3d9_obj = Direct3DCreate9(D3D_SDK_VERSION) orelse return 1;

    const vtable: [*]*anyopaque = @as(*[*]*anyopaque, @ptrCast(@alignCast(d3d9_obj))).*;
    original_create_device = @ptrCast(vtable[16]);

    // Hook IDirect3D9::CreateDevice
    var old_protect: DWORD = 0;
    if (VirtualProtect(@ptrCast(&vtable[16]), @sizeOf(*anyopaque), PAGE_EXECUTE_READWRITE, &old_protect) == 0) {
        const release: *const fn (*anyopaque) callconv(.winapi) u32 = @ptrCast(vtable[2]);
        _ = release(d3d9_obj);
        return 1;
    }
    vtable[16] = @ptrCast(@constCast(&hookedCreateDevice));
    _ = VirtualProtect(@ptrCast(&vtable[16]), @sizeOf(*anyopaque), old_protect, &old_protect);

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
