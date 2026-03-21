const ig = @import("cimgui");
const win32 = @import("win32.zig");
const logging = @import("log.zig");
const game = @import("game.zig");
const overlay = @import("overlay.zig");

// ── ImGui backend bridge functions (from vendor/imgui_bridge.cpp) ──
extern fn bridge_ImplDX9_Init(device: ?*anyopaque) callconv(.c) bool;
extern fn bridge_ImplDX9_NewFrame() callconv(.c) void;
extern fn bridge_ImplDX9_RenderDrawData(draw_data: ?*anyopaque) callconv(.c) void;
extern fn bridge_ImplDX9_InvalidateDeviceObjects() callconv(.c) void;
extern fn bridge_ImplDX9_CreateDeviceObjects() callconv(.c) bool;
extern fn bridge_ImplWin32_Init(hwnd: ?*anyopaque) callconv(.c) bool;
extern fn bridge_ImplWin32_NewFrame() callconv(.c) void;
extern fn bridge_ImplWin32_WndProcHandler(hwnd: ?*anyopaque, msg: win32.UINT, wparam: usize, lparam: isize) callconv(.c) isize;
extern fn bridge_SetBackBufferRenderTarget(device: ?*anyopaque) callconv(.c) void;

// ── D3D9 vtable function signatures (COM stdcall with explicit `this`) ──
const CreateDeviceFn = *const fn (*anyopaque, win32.UINT, win32.UINT, ?win32.HWND, win32.DWORD, [*]u8, *?*anyopaque) callconv(.winapi) win32.HRESULT;
const EndSceneFn = *const fn (*anyopaque) callconv(.winapi) win32.HRESULT;
const ResetFn = *const fn (*anyopaque, *anyopaque) callconv(.winapi) win32.HRESULT;
const PresentFn = *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, ?win32.HWND, ?*anyopaque) callconv(.winapi) win32.HRESULT;

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
var force_windowed: bool = false; // Set from REDGUARD_WINDOWED env var
var trainer_enabled: bool = false; // Set from REDGUARD_TRAINER env var

// Original SetCursorPos — saved during IAT hook
var real_set_cursor_pos: ?*const fn (c_int, c_int) callconv(.winapi) win32.BOOL = null;

// Our SetCursorPos replacement — blocks when overlay is active
fn mySetCursorPos(x: c_int, y: c_int) callconv(.winapi) win32.BOOL {
    if (show_overlay) return 1; // Pretend success but do nothing
    if (real_set_cursor_pos) |f| return f(x, y);
    return 0;
}

// Hook SetCursorPos via IAT patching in dosbox.exe
fn hookSetCursorPos() void {
    const base = win32.GetModuleHandleA(null) orelse return;
    const base_addr = @intFromPtr(base);
    const base_bytes: [*]const u8 = @ptrCast(base);

    // Get real SetCursorPos address
    const user32 = win32.GetModuleHandleA("user32.dll") orelse return;
    const real_addr = @intFromPtr(win32.GetProcAddress(user32, "SetCursorPos") orelse return);
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
                var old_prot: win32.DWORD = 0;
                if (win32.VirtualProtect(@ptrFromInt(iat), 4, win32.PAGE_EXECUTE_READWRITE, &old_prot) != 0) {
                    entry.* = @truncate(@intFromPtr(&mySetCursorPos));
                    _ = win32.VirtualProtect(@ptrFromInt(iat), 4, old_prot, &old_prot);
                }
                return;
            }
            iat += 4;
        }
        desc += 20;
    }
}

// ── WndProc hook (forwards input to ImGui) ──
fn hookedWndProc(hwnd: ?win32.HWND, msg: win32.UINT, wparam: usize, lparam: isize) callconv(.winapi) isize {
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

        // When fly mode is active, block movement keys from reaching the game
        // A/D/Left/Right are NOT blocked - let game handle camera rotation naturally
        if (game.fly_mode_enabled) {
            if (msg == win32.WM_KEYDOWN or msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYDOWN or msg == win32.WM_SYSKEYUP) {
                const vk = wparam;
                if (vk == @as(usize, @intCast(win32.VK_SPACE)) or
                    vk == @as(usize, @intCast(win32.VK_CONTROL)) or
                    vk == @as(usize, @intCast(win32.VK_LCONTROL)) or
                    vk == @as(usize, @intCast(win32.VK_RCONTROL)) or
                    vk == @as(usize, @intCast(win32.VK_W)) or
                    vk == @as(usize, @intCast(win32.VK_S)) or
                    vk == @as(usize, @intCast(win32.VK_R)) or
                    vk == @as(usize, @intCast(win32.VK_F)) or
                    vk == @as(usize, @intCast(win32.VK_UP)) or
                    vk == @as(usize, @intCast(win32.VK_DOWN)) or
                    vk == @as(usize, @intCast(win32.VK_SHIFT)))
                {
                    return 0; // Eat the key
                }
            }
        }
    }
    return win32.CallWindowProcA(original_wndproc, hwnd, msg, wparam, lparam);
}

// ── EndScene hook — passthrough (we render in Present instead) ──
fn hookedEndScene(this: *anyopaque) callconv(.winapi) win32.HRESULT {
    return real_end_scene(this);
}

// ── Present hook — renders ImGui overlay right before frame display ──
// nGlide composites Glide→D3D9 output after EndScene, so we render here
// in our own BeginScene/EndScene pair to guarantee visibility.
fn hookedPresent(this: *anyopaque, src: ?*anyopaque, dst: ?*anyopaque, wnd: ?win32.HWND, rgn: ?*anyopaque) callconv(.winapi) win32.HRESULT {
    // Trainer features (overlay, cheats, fly mode) only when --trainer is passed
    if (trainer_enabled) {
        if (!imgui_initialized) {
            initImGui(this);
        }

        if (imgui_initialized) {
            // Retry slide detection periodically (not every frame — scan is expensive)
            if (game.mem_base != null and game.game_slide == 0 and game.slide_attempts < 10) {
                game.slide_attempts += 1;
                _ = game.detectGameSlide();
            }

            // Update cheats (noclip, godmode)
            game.updateCheats();

            // Update fly mode (every frame, even when overlay closed)
            game.updateFlyMode();

            // Toggle overlay with ` (tilde)
            const toggle_down = (win32.GetAsyncKeyState(win32.VK_OEM_3) & @as(c_short, -32768)) != 0;
            if (toggle_down and !prev_toggle_down) {
                show_overlay = !show_overlay;
            }
            prev_toggle_down = toggle_down;

            // Render ImGui in its own scene, targeting the backbuffer
            const dev_vtable: [*]*anyopaque = @as(*[*]*anyopaque, @ptrCast(@alignCast(this))).*;
            const beginScene: *const fn (*anyopaque) callconv(.winapi) win32.HRESULT = @ptrCast(dev_vtable[41]);
            _ = beginScene(this);
            bridge_SetBackBufferRenderTarget(this);

            bridge_ImplDX9_NewFrame();
            bridge_ImplWin32_NewFrame();
            ig.igNewFrame();

            // When overlay is active: show cursor and release DOSBox's mouse grab
            ig.igGetIO().*.MouseDrawCursor = show_overlay;
            if (show_overlay) {
                _ = win32.ClipCursor(null); // Release SDL mouse confinement
            }

            if (show_overlay) {
                overlay.drawOverlay();
            }

            ig.igRender();
            if (ig.igGetDrawData()) |dd| {
                bridge_ImplDX9_RenderDrawData(@ptrCast(dd));
            }

            _ = real_end_scene(this);
        }
    }

    return real_present(this, src, dst, wnd, rgn);
}

// ── Reset hook — invalidate/recreate ImGui D3D9 resources ──
fn hookedReset(this: *anyopaque, present_params: *anyopaque) callconv(.winapi) win32.HRESULT {
    if (imgui_initialized) bridge_ImplDX9_InvalidateDeviceObjects();
    const hr = real_reset(this, present_params);
    if (hr >= 0 and imgui_initialized) _ = bridge_ImplDX9_CreateDeviceObjects();
    return hr;
}

// ── ImGui initialization (called once on first Present) ──
fn initImGui(device: *anyopaque) void {
    const hwnd = win32.FindWindowA("SDL_app", null) orelse return;
    game.game_hwnd = hwnd; // Save for focus checking

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
    const new_wndproc: win32.LONG = @bitCast(@as(u32, @truncate(@intFromPtr(&hookedWndProc))));
    const old_long = win32.SetWindowLongA(hwnd, win32.GWL_WNDPROC, new_wndproc);
    const old_usize: usize = @bitCast(@as(u32, @bitCast(old_long)));
    original_wndproc = if (old_usize == 0) null else @ptrFromInt(old_usize);

    // Hook SetCursorPos to prevent DOSBox from re-centering mouse when overlay is active
    if (real_set_cursor_pos == null) hookSetCursorPos();

    // Discover DOSBox MemBase for game memory access
    if (game.mem_base == null) game.mem_base = game.findMemBase();

    // Detect address slide (DOS/4GW may load LE at different base than Ghidra assumed)
    if (game.mem_base != null and game.game_slide == 0) _ = game.detectGameSlide();

    imgui_initialized = true;
}

// ══════════════════════════════════════════════════════════════
// CreateDevice hook — forces windowed mode, hooks device vtable
// ══════════════════════════════════════════════════════════════

fn hookedCreateDevice(
    this: *anyopaque,
    adapter: win32.UINT,
    device_type: win32.UINT,
    focus_window: ?win32.HWND,
    behavior_flags: win32.DWORD,
    present_params: [*]u8,
    pp_device: *?*anyopaque,
) callconv(.winapi) win32.HRESULT {
    // Force windowed mode if requested
    if (force_windowed) {
        const windowed_ptr: *align(1) win32.BOOL = @ptrCast(present_params + win32.PP_WINDOWED);
        windowed_ptr.* = 1;
        const refresh_ptr: *align(1) win32.UINT = @ptrCast(present_params + win32.PP_REFRESH_RATE);
        refresh_ptr.* = 0;
    }

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
    var old_protect: win32.DWORD = 0;

    // EndScene (vtable 42) — passthrough, needed for real_end_scene pointer
    if (dev_vtable[42] != my_end_scene) {
        real_end_scene = @ptrCast(dev_vtable[42]);
        if (win32.VirtualProtect(@ptrCast(&dev_vtable[42]), @sizeOf(*anyopaque), win32.PAGE_EXECUTE_READWRITE, &old_protect) != 0) {
            dev_vtable[42] = my_end_scene;
            _ = win32.VirtualProtect(@ptrCast(&dev_vtable[42]), @sizeOf(*anyopaque), old_protect, &old_protect);
        }
    }

    // Present (vtable 17) — ImGui renders here
    if (dev_vtable[17] != my_present) {
        real_present = @ptrCast(dev_vtable[17]);
        if (win32.VirtualProtect(@ptrCast(&dev_vtable[17]), @sizeOf(*anyopaque), win32.PAGE_EXECUTE_READWRITE, &old_protect) != 0) {
            dev_vtable[17] = my_present;
            _ = win32.VirtualProtect(@ptrCast(&dev_vtable[17]), @sizeOf(*anyopaque), old_protect, &old_protect);
        }
    }

    // Reset (vtable 16) — handles device lost
    if (dev_vtable[16] != my_reset) {
        real_reset = @ptrCast(dev_vtable[16]);
        if (win32.VirtualProtect(@ptrCast(&dev_vtable[16]), @sizeOf(*anyopaque), win32.PAGE_EXECUTE_READWRITE, &old_protect) != 0) {
            dev_vtable[16] = my_reset;
            _ = win32.VirtualProtect(@ptrCast(&dev_vtable[16]), @sizeOf(*anyopaque), old_protect, &old_protect);
        }
    }
}

// ══════════════════════════════════════════════════════════════
// Worker thread + DllMain
// ══════════════════════════════════════════════════════════════

fn workerThread(_: ?*anyopaque) callconv(.winapi) win32.DWORD {
    // Check launcher flags via environment variables
    var env_buf: [2]u8 = undefined;
    const env_len = win32.GetEnvironmentVariableA("REDGUARD_WINDOWED", &env_buf, 2);
    force_windowed = (env_len > 0 and env_buf[0] == '1');

    var env_buf2: [2]u8 = undefined;
    const env_len2 = win32.GetEnvironmentVariableA("REDGUARD_TRAINER", &env_buf2, 2);
    trainer_enabled = (env_len2 > 0 and env_buf2[0] == '1');

    // Poll for d3d9.dll — nGlide loads it during initialization
    var d3d9_mod: ?*anyopaque = null;
    var attempts: u32 = 0;
    while (attempts < 120) : (attempts += 1) {
        d3d9_mod = win32.GetModuleHandleA("d3d9.dll");
        if (d3d9_mod != null) break;
        win32.Sleep(250);
    }
    if (d3d9_mod == null) return 1;

    // Get Direct3DCreate9 and create temp IDirect3D9 for vtable access
    const create_fn_ptr = win32.GetProcAddress(d3d9_mod.?, "Direct3DCreate9") orelse return 1;
    const Direct3DCreate9: *const fn (win32.UINT) callconv(.winapi) ?*anyopaque = @ptrCast(create_fn_ptr);
    const d3d9_obj = Direct3DCreate9(win32.D3D_SDK_VERSION) orelse return 1;

    const vtable: [*]*anyopaque = @as(*[*]*anyopaque, @ptrCast(@alignCast(d3d9_obj))).*;
    original_create_device = @ptrCast(vtable[16]);

    // Hook IDirect3D9::CreateDevice
    var old_protect: win32.DWORD = 0;
    if (win32.VirtualProtect(@ptrCast(&vtable[16]), @sizeOf(*anyopaque), win32.PAGE_EXECUTE_READWRITE, &old_protect) == 0) {
        const release: *const fn (*anyopaque) callconv(.winapi) u32 = @ptrCast(vtable[2]);
        _ = release(d3d9_obj);
        return 1;
    }
    vtable[16] = @ptrCast(@constCast(&hookedCreateDevice));
    _ = win32.VirtualProtect(@ptrCast(&vtable[16]), @sizeOf(*anyopaque), old_protect, &old_protect);

    // Release temp object — vtable is shared, hook persists
    const release: *const fn (*anyopaque) callconv(.winapi) u32 = @ptrCast(vtable[2]);
    _ = release(d3d9_obj);
    return 0;
}

pub export fn DllMain(inst: win32.HINSTANCE, reason: win32.DWORD, reserved: win32.LPVOID) callconv(.winapi) win32.BOOL {
    _ = inst;
    _ = reserved;
    if (reason == win32.DLL_PROCESS_ATTACH) {
        _ = win32.CreateThread(null, 0, &workerThread, null, 0, null);
    }
    return 1;
}
