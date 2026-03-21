const ig = @import("cimgui");
const game = @import("game.zig");

// ── Overlay UI ──
pub fn drawOverlay() void {
    const std = @import("std");

    ig.igSetNextWindowSize(.{ .x = 320, .y = 0 }, ig.ImGuiCond_FirstUseEver);
    ig.igSetNextWindowPos(.{ .x = 10, .y = 10 }, ig.ImGuiCond_FirstUseEver);

    if (ig.igBegin("Redguard Trainer", null, 0)) {
        ig.igTextUnformatted("Level Loader");
        ig.igSeparator();

        // Show current world
        if (game.readGameU32(game.GAME_CURRENT_WORLD)) |cw| {
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
            for (game.world_list, 0..) |entry, idx| {
                const is_selected = game.selected_world == @as(c_int, @intCast(idx));
                if (ig.igSelectableEx(entry.name, is_selected, 0, .{ .x = 0, .y = 0 })) {
                    game.selected_world = @intCast(idx);
                }
            }
            ig.igEndListBox();
        }
        ig.igSpacing();

        if (game.mem_base == null or game.game_slide == 0) ig.igBeginDisabled(true);
        if (ig.igButton("Load Level")) {
            const world_id = game.world_list[@intCast(game.selected_world)].id;
            // Trigger world load: set pending world ID.
            // FUN_00053e15 checks DAT_001a3f60 != -1 every frame and returns
            // the world ID, which the main loop routes to LAB_00020930
            // (FUN_000502f9 call) via: local_24 < 5000 → goto LAB_00020930.
            game.writeGameU32(game.GAME_PENDING_WORLD, world_id);
            game.writeGameU32(game.GAME_PENDING_MARKER, 0);
        }
        if (game.mem_base == null or game.game_slide == 0) {
            ig.igEndDisabled();
            if (game.mem_base == null) {
                ig.igTextUnformatted("MemBase not found");
            } else {
                ig.igTextUnformatted("Slide not detected (game still loading?)");
            }
        }

        ig.igSpacing();
        ig.igSeparator();

        // Cheats section
        ig.igTextUnformatted("Cheats");
        ig.igSeparator();

        if (game.mem_base == null or game.game_slide == 0) ig.igBeginDisabled(true);

        _ = ig.igCheckbox("Godmode", &game.godmode_enabled);
        ig.igSameLine();
        _ = ig.igCheckbox("Noclip", &game.noclip_enabled);

        if (game.mem_base == null or game.game_slide == 0) ig.igEndDisabled();

        ig.igSpacing();
        ig.igSeparator();

        // Fly Mode section
        ig.igTextUnformatted("Fly Mode");
        ig.igSeparator();

        if (game.mem_base == null or game.game_slide == 0) ig.igBeginDisabled(true);

        _ = ig.igCheckbox("Enable Fly Mode", &game.fly_mode_enabled);
        if (game.fly_mode_enabled) {
            ig.igTextUnformatted("W/S/Arrows: Forward/Back");
            ig.igTextUnformatted("A/D/Left/Right: Camera rotation");
            ig.igTextUnformatted("Space/R: Up, Ctrl/F: Down");
            ig.igTextUnformatted("Hold Shift for fast movement");
        }

        // Speed slider
        _ = ig.igSliderFloat("Speed", &game.fly_speed, 100.0, 2000.0);

        // Position display (show working position)
        if (game.fly_mode_enabled) {
            if (game.readGameU32(game.GAME_POS_X)) |px| {
                if (game.readGameU32(game.GAME_POS_Y)) |py| {
                    if (game.readGameU32(game.GAME_POS_Z)) |pz| {
                        var pos_buf: [80:0]u8 = @splat(0);
                        const x: i32 = @bitCast(px);
                        const y: i32 = @bitCast(py);
                        const z: i32 = @bitCast(pz);
                        _ = std.fmt.bufPrint(&pos_buf, "Pos: {d}, {d}, {d}", .{ x, y, z }) catch {};
                        ig.igTextUnformatted(&pos_buf);
                    }
                }
            }
        }

        if (game.mem_base == null or game.game_slide == 0) ig.igEndDisabled();

        ig.igSpacing();
        ig.igSeparator();

        // Diagnostics section
        if (ig.igCollapsingHeader("Diagnostics", 0)) {
            if (game.mem_base) |mb| {
                var dbuf: [128:0]u8 = @splat(0);
                _ = std.fmt.bufPrint(&dbuf, "MemBase: 0x{x}  Slide: {d} (0x{x})", .{ @intFromPtr(mb), game.game_slide, @as(usize, @intCast(@as(isize, @intCast(@as(u32, 0))) + game.game_slide)) }) catch {};
                ig.igTextUnformatted(&dbuf);

                if (game.readGameU32(game.GAME_CURRENT_WORLD)) |v| {
                    dbuf = @splat(0);
                    _ = std.fmt.bufPrint(&dbuf, "Current world: {d}  Pending: {d}", .{ v, if (game.readGameU32(game.GAME_PENDING_WORLD)) |p| p else 0 }) catch {};
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
