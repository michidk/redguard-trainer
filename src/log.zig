const win32 = @import("win32.zig");

const LogLevel = enum { debug, info, warn, err };
const LOG_FILE = "redguard_hook.log";
pub var log_enabled: bool = true;

pub fn log(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
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
    const h = win32.CreateFileA(LOG_FILE, win32.FILE_APPEND_DATA, win32.FILE_SHARE_READ, null, win32.OPEN_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (h == win32.INVALID_HANDLE) return;
    defer _ = win32.CloseHandle(h);

    _ = win32.SetFilePointer(h, 0, null, 2); // FILE_END
    _ = win32.WriteFile(h, msg.ptr, @intCast(msg.len), null, null);
}

pub fn logInfo(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn logDebug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn logWarn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn logErr(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}
