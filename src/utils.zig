pub fn readFromSocket(socket: i32, buffer: []u8) isize {
    const read_count = c.read(socket, buffer[0..buffer.len].ptr, buffer.len);
    const result = posix.errno(read_count);
    if (result != .SUCCESS) {
        std.log.err("call to read failed: {any}", .{result});
        GlobalState.requestShutdown();
    }
    return read_count;
}

pub fn sendToSocket(socket: i32, bytes: []const u8) void {
    const result = posix.errno(c.send(socket, bytes[0..bytes.len].ptr, bytes.len, 0));
    if (result != .SUCCESS) {
        std.log.err("proxy send call failed, {any}", .{result});
        GlobalState.requestShutdown();
    }
}

const std = @import("std");
const GlobalState = @import("GlobalState.zig");
const c = std.c;
const posix = std.posix;
