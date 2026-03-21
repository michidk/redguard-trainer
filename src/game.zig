const win32 = @import("win32.zig");
const logging = @import("log.zig");

// Game memory offsets (Ghidra virtual addresses from LE loader)
// Runtime address = ghidra_addr + game_slide (slide detected via world name table scan)
pub const GAME_CURRENT_WORLD: usize = 0x001a3f5c; // DAT_001a3f5c: current world ID
pub const GAME_TESTMAPS_FLAG: usize = 0x001a1e3b; // DAT_001a1e3b: testmaps mode flag (byte, 1 = enabled)
pub const GAME_PENDING_WORLD: usize = 0x001a3f60; // DAT_001a3f60: world ID to load (-1 = none)
pub const GAME_PENDING_MARKER: usize = 0x001a3f64; // DAT_001a3f64: spawn marker (0 = default)
pub const GAME_WORLD_NAMES: usize = 0x001e05b8; // DAT_001e05b8: world name table (0x18c bytes/entry)
pub const GAME_WORLD_STRIDE: usize = 0x18c; // 396 bytes per world entry

// Camera/Player position (floats, clamped 0-65535)
pub const GAME_CAMERA_X: usize = 0x002ca268; // DAT_002ca268: X coordinate
pub const GAME_CAMERA_Y: usize = 0x002ca26c; // DAT_002ca26c: Y coordinate (height)
pub const GAME_CAMERA_Z: usize = 0x002ca270; // DAT_002ca270: Z coordinate
pub const GAME_CAMERA_YAW: usize = 0x002ca274; // DAT_002ca274: Yaw angle (horizontal rotation)
pub const GAME_CAMERA_PITCH: usize = 0x002ca264; // DAT_002ca264: Pitch angle (vertical rotation)

// Player entity pointer and position offsets
pub const GAME_PLAYER_PTR: usize = 0x001a3865; // DAT_001a3865: pointer to player entity (Cyrus)
pub const PLAYER_POS_X_OFF: usize = 0xcb; // Player X position (int, within entity struct)
pub const PLAYER_POS_Y_OFF: usize = 0xcf; // Player Y position (int, within entity struct)
pub const PLAYER_POS_Z_OFF: usize = 0xd3; // Player Z position (int, within entity struct)
// Velocity vectors (animation system uses these to move player)
pub const PLAYER_VEL1_X_OFF: usize = 0xd7; // Velocity vector 1 X
pub const PLAYER_VEL1_Y_OFF: usize = 0xdb; // Velocity vector 1 Y
pub const PLAYER_VEL1_Z_OFF: usize = 0xdf; // Velocity vector 1 Z
pub const PLAYER_VEL2_X_OFF: usize = 0xe3; // Velocity vector 2 X
pub const PLAYER_VEL2_Y_OFF: usize = 0xe7; // Velocity vector 2 Y
pub const PLAYER_VEL2_Z_OFF: usize = 0xeb; // Velocity vector 2 Z

// "Working" position variables - these directly feed into camera calculation
// Camera = DAT_001de98x >> 8 (divide by 256)
pub const GAME_POS_X: usize = 0x001de984; // DAT_001de984: current X position (int)
pub const GAME_POS_Y: usize = 0x001de988; // DAT_001de988: current Y position (int)
pub const GAME_POS_Z: usize = 0x001de98c; // DAT_001de98c: current Z position (int)
pub const GAME_POS_YAW: usize = 0x001de994; // DAT_001de994: working yaw (camera copies from this)
pub const GAME_POS_PITCH: usize = 0x001de998; // DAT_001de998: working pitch

// Magic carpet cheat flag - disables collision/gravity when set to 1
pub const GAME_MAGIC_CARPET: usize = 0x001f29c4; // DAT_001f29c4: magic carpet cheat (1 = enabled)

// Godmode cheat flag - disables damage when set to 1
pub const GAME_GODMODE: usize = 0x001f29c0; // DAT_001f29c0: invulnerability cheat (1 = enabled)

// Save game loading — the game's main loop checks DAT_001e9f74 every frame;
// when it equals 0x1772, LoadGame(DAT_001f9c0c, 1) is called.
pub const GAME_SAVE_LOAD_SLOT: usize = 0x001f9c0c; // DAT_001f9c0c: save slot number to load
pub const GAME_SAVE_LOAD_CMD: usize = 0x001e9f74; // DAT_001e9f74: in-game command flag
pub const LOAD_SAVE_CMD_CODE: u32 = 0x1772; // command code that triggers LoadGame

// Debug mode flag — when non-zero, the main menu (FUN_000ab924) is bypassed
// inside the game loop. Set from SYSTEM.INI "debug" key or command-line args.
// We temporarily set this to 1 to prevent the menu from blocking the save load.
pub const GAME_DEBUG_MODE: usize = 0x001a1df3; // DAT_001a1df3: debug/dev mode flag

// ── State ──
pub var mem_base: ?[*]u8 = null;
pub var game_slide: isize = 0; // Offset: runtime address = ghidra address + slide
pub var slide_attempts: u32 = 0; // Throttle scan retries
pub var game_hwnd: ?win32.HWND = null; // Game window handle for focus check
pub var selected_world: c_int = 0;

// Fly mode state
pub var fly_mode_enabled: bool = false;
pub var fly_speed: f32 = 600.0; // Units per second

// Cheat toggles
pub var noclip_enabled: bool = false;
pub var godmode_enabled: bool = false;

// Auto-load save game state (set from --load-save CLI flag via env var)
pub var pending_load_save: ?u32 = null; // save slot to load, null = no pending
var load_save_frames: u32 = 0; // total frames since slide detected
var load_save_written: bool = false; // true once we've started writing the command

// World IDs and names from WORLD.INI (note: 9, 10, 16 don't exist)
pub const WorldEntry = struct { id: u32, name: [*:0]const u8 };
pub const world_list = [_]WorldEntry{
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

// ── DOSBox MemBase discovery ──
// Scans DOSBox .text for GetMemBase(): A1 XX XX XX XX C3 (MOV EAX,[addr]; RETN)
// Verifies candidate by checking multiple BIOS Data Area signatures.
pub fn findMemBase() ?[*]u8 {
    // Method 1: Pattern scan for GetMemBase() — A1 XX XX XX XX C3
    if (findMemBasePattern()) |mb| return mb;

    // Method 2: Scan DOSBox's data sections for pointers to DOS memory
    if (findMemBaseDataScan()) |mb| return mb;

    return null;
}

fn findMemBasePattern() ?[*]u8 {
    const base = win32.GetModuleHandleA(null) orelse return null;
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
        var mbi: win32.MEMORY_BASIC_INFORMATION = undefined;
        if (win32.VirtualQuery(@ptrFromInt(addr), &mbi, @sizeOf(win32.MEMORY_BASIC_INFORMATION)) == 0) break;

        const region_base = @intFromPtr(mbi.BaseAddress orelse break);
        const region_size = mbi.RegionSize;
        if (region_size == 0) break;

        // Look for large (>= 16MB) committed read/write regions
        if (mbi.State == win32.MEM_COMMIT and region_size >= 0x01000000 and
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
    var mbi: win32.MEMORY_BASIC_INFORMATION = undefined;
    if (win32.VirtualQuery(@ptrFromInt(global_addr), &mbi, @sizeOf(win32.MEMORY_BASIC_INFORMATION)) == 0) return null;
    if (mbi.State != win32.MEM_COMMIT or (mbi.Protect & win32.PAGE_NOACCESS) != 0) return null;

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
    var mbi: win32.MEMORY_BASIC_INFORMATION = undefined;

    // Check that the candidate region is readable (check at offset 0x500 — well into BDA)
    if (win32.VirtualQuery(@ptrCast(candidate + 0x500), &mbi, @sizeOf(win32.MEMORY_BASIC_INFORMATION)) == 0) return false;
    if (mbi.State != win32.MEM_COMMIT or (mbi.Protect & win32.PAGE_NOACCESS) != 0) return false;

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

// ── Game memory read/write helpers ──

pub fn readGameU32(offset: usize) ?u32 {
    const base = mem_base orelse return null;
    const actual = @as(usize, @intCast(@as(isize, @intCast(offset)) + game_slide));
    return @as(*align(1) const u32, @ptrCast(base + actual)).*;
}

pub fn readGameF32(offset: usize) ?f32 {
    const base = mem_base orelse return null;
    const actual = @as(usize, @intCast(@as(isize, @intCast(offset)) + game_slide));
    return @as(*align(1) const f32, @ptrCast(base + actual)).*;
}

pub fn writeGameU8(offset: usize, value: u8) void {
    const base = mem_base orelse return;
    const actual = @as(usize, @intCast(@as(isize, @intCast(offset)) + game_slide));
    base[actual] = value;
}

pub fn writeGameU32(offset: usize, value: u32) void {
    const base = mem_base orelse return;
    const actual = @as(usize, @intCast(@as(isize, @intCast(offset)) + game_slide));
    @as(*align(1) u32, @ptrCast(base + actual)).* = value;
}

pub fn writeGameF32(offset: usize, value: f32) void {
    const base = mem_base orelse return;
    const actual = @as(usize, @intCast(@as(isize, @intCast(offset)) + game_slide));
    @as(*align(1) f32, @ptrCast(base + actual)).* = value;
}

// Read/write through player entity pointer (DAT_001a3865 -> entity struct)
pub fn getPlayerPtr() ?u32 {
    return readGameU32(GAME_PLAYER_PTR);
}

pub fn readPlayerI32(entity_offset: usize) ?i32 {
    const base = mem_base orelse return null;
    const player_ptr = getPlayerPtr() orelse return null;
    if (player_ptr == 0) return null;
    // player_ptr is a flat DOS address - NO slide needed (slide only for Ghidra addrs)
    const addr = player_ptr + @as(u32, @intCast(entity_offset));
    return @as(*align(1) const i32, @ptrCast(base + addr)).*;
}

pub fn writePlayerI32(entity_offset: usize, value: i32) void {
    const base = mem_base orelse return;
    const player_ptr = getPlayerPtr() orelse return;
    if (player_ptr == 0) return;
    // player_ptr is a flat DOS address - NO slide needed
    const addr = player_ptr + @as(u32, @intCast(entity_offset));
    @as(*align(1) i32, @ptrCast(base + addr)).* = value;
}

/// Scan emulated DOS memory for a known embedded string to compute the slide
/// between Ghidra addresses and actual runtime addresses.
/// "testmaps\0" is hardcoded in RGFX.EXE at Ghidra address 0x00170d3a.
pub fn detectGameSlide() bool {
    const base = mem_base orelse return false;
    const scan_end: usize = 0x2000000; // 32MB
    const ghidra_addr: usize = 0x00170d3a; // From strings.txt

    logging.logDebug("detectSlide: MemBase=0x{x} scanning 0x10000..0x{x}", .{ @intFromPtr(base), scan_end });

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
                logging.logInfo("Slide detected: {d} (0x{x}) — verified at 0x{x} and 0x{x}", .{
                    slide, @as(usize, @intCast(if (slide >= 0) slide else -slide)), off, expected2,
                });
                return true;
            }
        }
    }

    logging.logWarn("Slide detection failed: {d} candidates, none verified", .{hits});
    return false;
}

// ── Cheat Updates ──
// Called every frame to sync cheat flags with game memory
pub fn updateCheats() void {
    if (mem_base == null or game_slide == 0) return;

    // Noclip (magic carpet)
    const current_noclip = readGameU32(GAME_MAGIC_CARPET) orelse 0;
    if (noclip_enabled and current_noclip != 1) {
        writeGameU32(GAME_MAGIC_CARPET, 1);
    } else if (!noclip_enabled and current_noclip == 1) {
        writeGameU32(GAME_MAGIC_CARPET, 0);
    }

    // Godmode (invulnerability)
    const current_godmode = readGameU32(GAME_GODMODE) orelse 0;
    if (godmode_enabled and current_godmode != 1) {
        writeGameU32(GAME_GODMODE, 1);
    } else if (!godmode_enabled and current_godmode == 1) {
        writeGameU32(GAME_GODMODE, 0);
    }
}

// ── Auto-load Save Game ──
// The game's main menu (FUN_000ab924) is a BLOCKING call inside the world loop
// (FUN_00053e15). While active, it overwrites DAT_001e9f74 on return, defeating
// any writes we make to it. The menu is only called when:
//     DAT_001a1df3 == 0 && (short)DAT_00205612 != 0
//
// Strategy: temporarily set DAT_001a1df3 = 1 (debug mode) to bypass the menu
// entirely. With no menu blocking, DAT_001e9f74 = 0x1772 persists through the
// game loop check and triggers LoadGame(DAT_001f9c0c, 1). After the save loads,
// we restore DAT_001a1df3 = 0.
pub fn updateAutoLoadSave() void {
    const slot = pending_load_save orelse return;
    if (mem_base == null or game_slide == 0) return;

    load_save_frames += 1;

    // Give up after ~10 seconds (600 frames) — restore debug flag and bail
    if (load_save_frames > 600) {
        logging.logWarn("Auto-load save: gave up after 600 frames", .{});
        writeGameU32(GAME_DEBUG_MODE, 0);
        pending_load_save = null;
        load_save_frames = 0;
        load_save_written = false;
        return;
    }

    // If we've already started writing, check if the game processed our command.
    // LoadGame clears DAT_001f9c0c to 0 after loading — that's our success signal.
    if (load_save_written) {
        const current_slot = readGameU32(GAME_SAVE_LOAD_SLOT) orelse slot;
        if (current_slot == 0) {
            // Success — restore normal mode
            writeGameU32(GAME_DEBUG_MODE, 0);
            logging.logInfo("Auto-load save slot {d}: completed", .{slot});
            pending_load_save = null;
            load_save_frames = 0;
            load_save_written = false;
            return;
        }
    }

    // Every frame: bypass the menu and write load command.
    // DAT_001a1df3 = 1 prevents FUN_000ab924 from being called, so our
    // DAT_001e9f74 write survives to the 0x1772 check on the next iteration.
    writeGameU32(GAME_DEBUG_MODE, 1);
    writeGameU32(GAME_SAVE_LOAD_SLOT, slot);
    writeGameU32(GAME_SAVE_LOAD_CMD, LOAD_SAVE_CMD_CODE);
    load_save_written = true;
}

// ── Fly Mode ──
// Updates player position based on keyboard input when fly mode is enabled.
// Called every frame from Present hook.
pub var last_fly_time: i64 = 0;

fn isKeyDown(vkey: c_int) bool {
    return (win32.GetAsyncKeyState(vkey) & @as(c_short, -32768)) != 0;
}

pub fn updateFlyMode() void {
    if (!fly_mode_enabled) return;
    if (mem_base == null or game_slide == 0) return;

    // Only process input when game window is focused
    if (game_hwnd != null and win32.GetForegroundWindow() != game_hwnd) return;

    // Check player entity exists
    const player_ptr = getPlayerPtr() orelse return;
    if (player_ptr == 0) return;

    // Get current time for delta calculation
    const GetTickCount = @extern(*const fn () callconv(.winapi) win32.DWORD, .{ .library_name = "kernel32", .name = "GetTickCount" });
    const current_time: i64 = @intCast(GetTickCount());

    // Calculate delta time (cap at 100ms to prevent huge jumps)
    var delta_ms: i64 = current_time - last_fly_time;
    if (last_fly_time == 0 or delta_ms > 100) delta_ms = 16; // ~60fps default
    last_fly_time = current_time;
    const delta_sec: f32 = @as(f32, @floatFromInt(delta_ms)) / 1000.0;

    // Read current position from PLAYER ENTITY (not camera)
    var x: f32 = @floatFromInt(readPlayerI32(PLAYER_POS_X_OFF) orelse return);
    var y: f32 = @floatFromInt(readPlayerI32(PLAYER_POS_Y_OFF) orelse return);
    var z: f32 = @floatFromInt(readPlayerI32(PLAYER_POS_Z_OFF) orelse return);

    // Read camera yaw for directional movement (0-2047 range, where 2048 = 360 degrees)
    const yaw_raw = readGameU32(GAME_CAMERA_YAW) orelse 0;
    const yaw_rad: f32 = @as(f32, @floatFromInt(yaw_raw)) * (3.14159265 * 2.0 / 2048.0);

    // Calculate movement direction based on yaw
    const std = @import("std");
    const sin_yaw = std.math.sin(yaw_rad);
    const cos_yaw = std.math.cos(yaw_rad);

    // Speed modifier (shift = faster)
    const speed = if (isKeyDown(win32.VK_SHIFT)) fly_speed * 3.0 * 256.0 else fly_speed * 256.0;
    const move = speed * delta_sec;

    // Forward/Backward (W/S/Up/Down arrows) - move player in facing direction
    if (isKeyDown(win32.VK_W) or isKeyDown(win32.VK_UP)) {
        x += sin_yaw * move;
        z += cos_yaw * move;
    }
    if (isKeyDown(win32.VK_S) or isKeyDown(win32.VK_DOWN)) {
        x -= sin_yaw * move;
        z -= cos_yaw * move;
    }

    // A/D/Left/Right arrows - let game handle camera rotation naturally (don't override)

    // Up/Down (R/F or Space/Ctrl) - Space/R = up, Ctrl/F = down
    const space_down = isKeyDown(win32.VK_SPACE);
    const ctrl_down = isKeyDown(win32.VK_CONTROL) or isKeyDown(win32.VK_LCONTROL) or isKeyDown(win32.VK_RCONTROL);
    const r_down = isKeyDown(win32.VK_R);
    const f_down = isKeyDown(win32.VK_F);

    if (space_down or r_down) {
        y -= move; // Up (Y decreases = higher in world)
    }
    if (ctrl_down or f_down) {
        y += move; // Down (Y increases = lower in world)
    }

    // Clamp to valid range (Y can be negative!)
    const max_pos: f32 = 65535.0 * 256.0;
    const min_pos: f32 = -65535.0 * 256.0;
    x = @max(0.0, @min(max_pos, x));
    y = @max(min_pos, @min(max_pos, y)); // Y can be negative
    z = @max(0.0, @min(max_pos, z));

    // Write to player entity position
    writePlayerI32(PLAYER_POS_X_OFF, @intFromFloat(x));
    writePlayerI32(PLAYER_POS_Y_OFF, @intFromFloat(y));
    writePlayerI32(PLAYER_POS_Z_OFF, @intFromFloat(z));

    // Zero out velocity vectors to stop animation system from fighting us
    writePlayerI32(PLAYER_VEL1_X_OFF, 0);
    writePlayerI32(PLAYER_VEL1_Y_OFF, 0);
    writePlayerI32(PLAYER_VEL1_Z_OFF, 0);
    writePlayerI32(PLAYER_VEL2_X_OFF, 0);
    writePlayerI32(PLAYER_VEL2_Y_OFF, 0);
    writePlayerI32(PLAYER_VEL2_Z_OFF, 0);
}
